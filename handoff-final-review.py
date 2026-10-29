#!/usr/bin/env python3
"""Run one bounded, read-only final review and persist its revision-bound verdict."""
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HEX = re.compile(r"^[0-9a-fA-F]{40}$")
BLOCK = re.compile(
    r"(?m)^FINAL REVIEW\nverdict: (PASS|FAIL)\nhead: ([0-9a-fA-F]{40})\n"
    r"base: ([0-9a-fA-F]{40})\nblockers: ([^\r\n]+)\nEND FINAL REVIEW$"
)


def fail_before(message):
    print(f"handoff-final-review.py: {message}", file=sys.stderr)
    return 1


def scalar_frontmatter(path):
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ValueError(f"cannot read {path}: {exc}") from exc
    if not lines or lines[0].strip() != "---":
        raise ValueError(f"{path}: missing frontmatter")
    end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
    if end is None:
        raise ValueError(f"{path}: unterminated frontmatter")
    values = {}
    for line in lines[1:end]:
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*?)\s*$", line)
        if m and m.group(2):
            values[m.group(1)] = m.group(2).strip("\"'")
    return lines[1:end], values


def plan_briefs(lines, plan):
    result = []
    phase = None
    in_phases = False
    in_briefs = False
    for line in lines:
        indent = len(line) - len(line.lstrip())
        text = line.strip()
        if text == "phases:":
            in_phases, in_briefs = True, False
            continue
        if in_phases and indent == 0 and text and not text.startswith("#"):
            in_phases, in_briefs = False, False
        if in_phases:
            if indent <= 2 and re.match(r"^-\s+", text):
                in_briefs = False
            if re.match(r"briefs:\s*", text):
                in_briefs = True
                value = text.partition(":")[2].strip()
                if value.startswith("["):
                    value = value.strip("[]")
                    result.extend(x.strip().strip("\"'") for x in value.split(",") if x.strip())
                elif value:
                    result.append(value.strip("\"'"))
                continue
            if in_briefs and indent >= 4 and text.startswith("-"):
                result.append(text[1:].strip().strip("\"'"))
    if not result:
        raise ValueError(f"{plan}: plan has no phase briefs")
    return [Path(p if os.path.isabs(p) else plan.parent / p).resolve() for p in result]


def atomic_json(path, data):
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
    try:
        with tmp.open("w", encoding="utf-8") as stream:
            json.dump(data, stream, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def main(argv):
    if len(argv) < 5:
        return fail_before("usage: handoff-launch.sh final-review <feature> --head <sha> --base <sha> [--backend <backend>]")
    feature_arg = argv[1]
    options = argv[2:]
    try:
        head = options[options.index("--head") + 1]
        base = options[options.index("--base") + 1]
    except (ValueError, IndexError):
        return fail_before("final-review requires --head <sha> and --base <sha>")
    backend = ""
    if "--backend" in options:
        try:
            backend = options[options.index("--backend") + 1]
        except IndexError:
            return fail_before("--backend requires a value")
    if not HEX.fullmatch(head) or not HEX.fullmatch(base):
        return fail_before("--head and --base must each be 40 hexadecimal characters")
    feature = Path(feature_arg)
    if not feature.is_absolute():
        feature = Path(os.environ.get("VAULT", ".")) / feature
    try:
        feature = feature.resolve(strict=True)
        lines, meta = scalar_frontmatter(feature)
        if feature.name.endswith(".md") and "phases:" in "\n".join(lines):
            briefs = plan_briefs(lines, feature)
        else:
            briefs = [feature]
        repos = []
        for brief in briefs:
            if not brief.is_file():
                raise ValueError(f"plan brief is missing: {brief}")
            _, bm = scalar_frontmatter(brief)
            if not bm.get("repo"):
                raise ValueError(f"brief has no repo: field: {brief}")
            repo = Path(bm["repo"])
            if not repo.is_absolute():
                repo = brief.parent / repo
            repos.append(repo.resolve(strict=True))
        if len(set(repos)) != 1:
            raise ValueError("briefs resolve to different repositories: " + ", ".join(map(str, briefs)))
        repo = repos[0]
        git_check = subprocess.run(["git", "-C", str(repo), "rev-parse", "--git-dir"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        if not repo.is_dir() or git_check.returncode:
            raise ValueError(f"repo is not a git checkout: {repo}")
    except (OSError, ValueError, IndexError) as exc:
        return fail_before(str(exc))

    evidence = feature.with_name(feature.name[:-3] + ".final-review.json" if feature.name.endswith(".md") else feature.name + ".final-review.json")
    record = {"feature": str(feature), "repo": str(repo), "head": head.lower(), "base": base.lower(),
              "verdict": "FAIL", "blockers": "", "backend": backend or "claude", "created": int(time.time())}
    if evidence.is_file():
        try:
            old = json.loads(evidence.read_text(encoding="utf-8"))
            if all(old.get(k) == record[k] for k in ("feature", "head", "base")):
                current = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"],
                                         text=True, stdout=subprocess.PIPE,
                                         stderr=subprocess.DEVNULL, check=False).stdout.strip()
                if current.lower() != head.lower():
                    record["reason"] = "repo HEAD does not match requested head"
                    atomic_json(evidence, record)
                    print(f"FINAL REVIEW FAIL {head[:7]} — {record['reason']}")
                    return 1
                print(f"FINAL REVIEW {old.get('verdict', 'FAIL')} {head[:7]}" + (f" — {old.get('reason')}" if old.get("reason") else ""))
                return 0 if old.get("verdict") == "PASS" else 1
        except (OSError, ValueError):
            pass

    def write_fail(reason):
        record["verdict"] = "FAIL"
        record["reason"] = reason
        atomic_json(evidence, record)
        print(f"FINAL REVIEW FAIL {head[:7]} — {reason}")
        return 1

    current = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"],
                             text=True, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, check=False).stdout.strip()
    if current.lower() != head.lower():
        return write_fail("repo HEAD does not match requested head")

    if not backend:
        backend = "hermes" if os.environ.get("HERMES_BACKEND") or not (
            os.environ.get("CLAUDE_BIN") or shutil.which("claude")) else "claude"
    record["backend"] = backend
    timeout_s = os.environ.get("HANDOFF_FINAL_REVIEW_TIMEOUT", "1800")
    if not timeout_s.isdigit() or int(timeout_s) < 1:
        return write_fail("invalid timeout")
    if backend == "hermes":
        home = Path(os.environ.get("HOME", "~")).expanduser()
        profile = home / ".hermes/profiles/final-review"
        if not profile.is_dir():
            return write_fail("hermes profile final-review missing")
        binary = os.environ.get("HERMES_BIN") or shutil.which("hermes")
        cmd = [binary, "-p", "final-review", "--in", str(repo), "-z"]
    elif backend == "claude":
        binary = os.environ.get("CLAUDE_BIN") or shutil.which("claude")
        cmd = [binary, "-p", "--disallowedTools", "Edit,Write,NotebookEdit", "--name", "final-review", "--"]
    elif backend == "devin":
        binary = os.environ.get("DEVIN_BIN") or shutil.which("devin")
        cmd = [binary, "--permission-mode", "auto", "-p"]
    else:
        return write_fail(f"unsupported backend {backend}")
    if not binary:
        return write_fail(f"{backend} not found")
    prompt = ("Read-only final code review. Review the diff " + base + ".." + head +
              " against every feature brief's §4 Done-when and §3, and repository AGENTS.md checks. "
              "Do not edit, commit, push, merge, or invoke forge writes. End with exactly:\n"
              "FINAL REVIEW\nverdict: PASS|FAIL\nhead: " + head.lower() + "\nbase: " + base.lower() +
              "\nblockers: none|<one line>\nEND FINAL REVIEW")
    if backend == "hermes":
        cmd.append(prompt)
    elif backend == "claude":
        cmd.append(prompt)
    else:
        cmd.append(prompt)
    try:
        completed = subprocess.run(["timeout", "-k", "10", timeout_s, *cmd], cwd=repo,
                                   text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   check=False)
    except OSError as exc:
        return write_fail(f"backend prerequisite: {exc}")
    if completed.returncode == 124 or completed.returncode == 137:
        return write_fail(f"timeout after {timeout_s} s")
    if completed.returncode:
        return write_fail(f"backend exited {completed.returncode}")
    matches = list(BLOCK.finditer(completed.stdout))
    if len(matches) != 1:
        return write_fail("expected exactly one FINAL REVIEW block")
    m = matches[0]
    verdict, got_head, got_base, blockers = m.groups()
    actual = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False).stdout.strip()
    if actual.lower() != head.lower():
        return write_fail("repo HEAD moved during review")
    if got_head.lower() != head.lower():
        return write_fail("review head mismatch")
    if got_base.lower() != base.lower():
        return write_fail("review base mismatch")
    if verdict != "PASS" or blockers != "none":
        return write_fail("review verdict FAIL" if verdict != "PASS" else "review blockers present")
    record.update(verdict="PASS", blockers="none")
    record.pop("reason", None)
    atomic_json(evidence, record)
    print(f"FINAL REVIEW PASS {head[:7]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
