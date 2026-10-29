#!/usr/bin/env python3
"""Prepare inputs for, and record the result of, a final review stage."""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HEX = re.compile(r"^[0-9a-fA-F]{40}$")
BLOCK = re.compile(
    r"(?m)^FINAL REVIEW\nverdict: (PASS|FAIL)\nhead: ([0-9a-fA-F]{40})\n"
    r"base: ([0-9a-fA-F]{40})\nblockers: ([^\r\n]+)\nEND FINAL REVIEW$"
)


def fail(message):
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
    result, in_phases, in_briefs = [], False, False
    for line in lines:
        indent = len(line) - len(line.lstrip())
        text = line.strip()
        if text == "phases:":
            in_phases, in_briefs = True, False
            continue
        if in_phases and indent == 0 and text and not text.startswith("#"):
            in_phases, in_briefs = False, False
        if not in_phases:
            continue
        if indent <= 2 and re.match(r"^-\s+", text):
            in_briefs = False
        if re.match(r"briefs:\s*", text):
            in_briefs = True
            value = text.partition(":")[2].strip()
            if value.startswith("["):
                result.extend(x.strip().strip("\"'") for x in value.strip("[]").split(",") if x.strip())
            elif value:
                result.append(value.strip("\"'"))
        elif in_briefs and indent >= 4 and text.startswith("-"):
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


def git_head(repo):
    return subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False).stdout.strip().lower()


def resolve(feature_arg, head, base, check_head=True):
    if not HEX.fullmatch(head) or not HEX.fullmatch(base):
        raise ValueError("--head and --base must each be 40 hexadecimal characters")
    feature = Path(feature_arg)
    if not feature.is_absolute():
        feature = Path(os.environ.get("VAULT", ".")) / feature
    feature = feature.resolve(strict=True)
    lines, _ = scalar_frontmatter(feature)
    briefs = plan_briefs(lines, feature) if feature.name.endswith(".md") and "phases:" in "\n".join(lines) else [feature]
    repos = []
    for brief in briefs:
        if not brief.is_file():
            raise ValueError(f"plan brief is missing: {brief}")
        _, meta = scalar_frontmatter(brief)
        if not meta.get("repo"):
            raise ValueError(f"brief has no repo: field: {brief}")
        repo = Path(meta["repo"])
        if not repo.is_absolute():
            repo = brief.parent / repo
        repos.append(repo.resolve(strict=True))
    if len(set(repos)) != 1:
        raise ValueError("briefs resolve to different repositories: " + ", ".join(map(str, briefs)))
    repo = repos[0]
    if not repo.is_dir() or subprocess.run(["git", "-C", str(repo), "rev-parse", "--git-dir"],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        raise ValueError(f"repo is not a git checkout: {repo}")
    if check_head and git_head(repo) != head.lower():
        raise ValueError("repo HEAD does not match requested head")
    evidence = feature.with_name(feature.name[:-3] + ".final-review.json" if feature.name.endswith(".md") else feature.name + ".final-review.json")
    return feature, briefs, repo, evidence


def prepare(argv):
    if len(argv) != 7 or argv[3] != "--head" or argv[5] != "--base":
        return fail("usage: handoff-final-review.py prepare <feature> --head <sha> --base <sha>")
    feature_arg, head, base = argv[2], argv[4], argv[6]
    try:
        feature, briefs, repo, evidence = resolve(feature_arg, head, base)
    except (OSError, ValueError, IndexError) as exc:
        return fail(str(exc))
    if evidence.is_file():
        try:
            old = json.loads(evidence.read_text(encoding="utf-8"))
            if all(old.get(k) == v for k, v in (("feature", str(feature)), ("repo", str(repo)),
                                                 ("head", head.lower()), ("base", base.lower()))):
                print(json.dumps({"reuse": True, "record": old}))
                return 0
        except (OSError, ValueError):
            pass
    print(json.dumps({"reuse": False, "repo": str(repo), "briefs": [str(p) for p in briefs],
                      "evidence": str(evidence)}))
    return 0


def record(argv):
    if len(argv) < 11:
        return fail("usage: handoff-final-review.py record <feature> --head <sha> --base <sha> --backend <backend> --output <file> [--status <status>]")
    feature_arg, head, base, backend, output = argv[2], "", "", "", ""
    status = ""
    it = iter(argv[3:])
    try:
        for key in it:
            value = next(it)
            if key == "--head": head = value
            elif key == "--base": base = value
            elif key == "--backend": backend = value
            elif key == "--output": output = value
            elif key == "--status": status = value
            else: return fail(f"unknown record option {key}")
    except StopIteration:
        return fail("record option requires a value")
    try:
        feature, _, repo, evidence = resolve(feature_arg, head, base, check_head=False)
    except (OSError, ValueError, IndexError) as exc:
        # The evidence target may still be resolvable from the feature path.
        return fail(str(exc))
    record = {"feature": str(feature), "repo": str(repo), "head": head.lower(), "base": base.lower(),
              "verdict": "FAIL", "blockers": "", "backend": backend, "created": int(time.time())}
    reason = ""
    if status:
        if status.startswith("timeout:"):
            reason = "timeout after " + status.partition(":")[2] + " s"
        elif status.startswith("exit:"):
            reason = "backend exited " + status.partition(":")[2]
        else:
            reason = status
    else:
        try:
            output_text = Path(output).read_text(encoding="utf-8")
        except OSError as exc:
            output_text = ""
            reason = f"cannot read stage output: {exc}"
        matches = list(BLOCK.finditer(output_text))
        if not reason and len(matches) != 1:
            reason = "expected exactly one FINAL REVIEW block"
        if not reason:
            verdict, got_head, got_base, blockers = matches[0].groups()
            if git_head(repo) != head.lower(): reason = "repo HEAD moved during review"
            elif got_head.lower() != head.lower(): reason = "review head mismatch"
            elif got_base.lower() != base.lower(): reason = "review base mismatch"
            elif verdict != "PASS": reason = "review verdict FAIL"
            elif blockers != "none": reason = "review blockers present"
            else: record.update(verdict="PASS", blockers="none")
    if reason:
        record["reason"] = reason
    atomic_json(evidence, record)
    verdict = record["verdict"]
    print(f"FINAL REVIEW {verdict} {head[:7]}" + (f" — {reason}" if reason else ""))
    return 0 if verdict == "PASS" else 1


def main(argv):
    if len(argv) < 2:
        return fail("expected prepare or record subcommand")
    if argv[1] == "prepare": return prepare(argv)
    if argv[1] == "record": return record(argv)
    return fail("expected prepare or record subcommand")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
