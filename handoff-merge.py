#!/usr/bin/env python3
"""Repository-scoped merge policy and task-approval interface.

This is operator convenience, not a hostile-process security boundary: another process
running as this user can edit these local files. Agent-produced brief content is never read.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import subprocess
from typing import Any

CONFIG = Path.home() / ".config" / "handoff" / "config.env"
POLICIES = Path.home() / ".config" / "handoff" / "project-policy.json"
VALID_RISKS = {"ordinary", "breaking-api", "destructive-migration", "auth-permissions-secrets",
               "deployment-infrastructure", "merge-policy", "uncertain"}


class Refusal(Exception):
    pass


class MissingRef(Refusal):
    pass


def _atomic_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    except BaseException:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass
        raise


def _config() -> list[str]:
    try:
        return CONFIG.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return []


def _default() -> bool:
    values = [line.partition("=")[2] for line in _config()
              if line.startswith("HANDOFF_AUTO_MERGE=")]
    if not values:
        return False
    if values[-1] not in ("true", "false"):
        raise Refusal("invalid HANDOFF_AUTO_MERGE value; refusing auto mode")
    return values[-1] == "true"


def _repo(path: str) -> str:
    candidate = Path(path).expanduser()
    if not candidate.is_dir():
        raise Refusal(f"repository directory does not exist: {path}")
    resolved = candidate.resolve()
    if not (resolved / ".git").exists():
        raise Refusal(f"not a Git repository: {path}")
    return str(resolved)


def _load() -> dict:
    try:
        data = json.loads(POLICIES.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"version": 1, "repositories": {}}
    except (OSError, json.JSONDecodeError) as exc:
        raise Refusal(f"cannot read policy store: {exc}") from exc
    if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("repositories"), dict):
        raise Refusal("invalid policy store; refusing auto mode")
    try:
        for entry in data["repositories"].values():
            _validate_entry(entry)
    except (TypeError, ValueError, KeyError) as exc:
        raise Refusal("invalid policy store; refusing auto mode") from exc
    return data


def _save(data: dict) -> None:
    _atomic_text(POLICIES, json.dumps(data, sort_keys=True, indent=2) + "\n")


def _valid_task(task: Any) -> bool:
    return isinstance(task, str) and task.startswith("/")


def _validate_entry(entry: Any) -> None:
    if (not isinstance(entry, dict) or
            (entry.get("enabled") is not None and not isinstance(entry.get("enabled"), bool))):
        raise ValueError("invalid repository policy")
    overrides = entry.get("overrides", [])
    if not isinstance(overrides, list):
        raise ValueError("invalid overrides")
    for approval in overrides:
        if (not isinstance(approval, dict) or not _valid_task(approval.get("task"))
                or not isinstance(approval.get("revision"), str) or not approval["revision"]
                or approval.get("risk") not in VALID_RISKS):
            raise ValueError("invalid override")
    assessments = entry.get("assessments", [])
    if not isinstance(assessments, list):
        raise ValueError("invalid assessments")
    seen_assessments = set()
    for assessment in assessments:
        if (not isinstance(assessment, dict) or not _valid_task(assessment.get("task"))
                or not isinstance(assessment.get("revision"), str) or not assessment["revision"]
                or assessment.get("risk") not in VALID_RISKS
                or not isinstance(assessment.get("reason"), str) or not assessment["reason"]):
            raise ValueError("invalid assessment")
        identity = assessment["task"], assessment["revision"]
        if identity in seen_assessments:
            raise ValueError("duplicate assessment")
        seen_assessments.add(identity)
    if "hold" in entry and not isinstance(entry["hold"], bool):
        raise ValueError("invalid hold")
    task_holds = entry.get("task_holds", [])
    if not isinstance(task_holds, list) or any(not _valid_task(task) for task in task_holds):
        raise ValueError("invalid task holds")
    if len(task_holds) != len(set(task_holds)):
        raise ValueError("duplicate task hold")


def _entry(data: dict, repo: str) -> dict:
    entry = data["repositories"].get(repo, {"enabled": None, "overrides": []})
    _validate_entry(entry)
    entry.setdefault("assessments", [])
    entry.setdefault("hold", False)
    entry.setdefault("task_holds", [])
    return entry


def _task_arg(task: str) -> None:
    if not _valid_task(task):
        raise Refusal("task identity must be an absolute path")


def _bool(value: str) -> bool:
    if value not in ("true", "false"):
        raise Refusal("policy must be exactly true or false")
    return value == "true"


def _gh(method: str, endpoint: str, fields: dict[str, str] | None = None,
        *, allow_list: bool = False, paginate: bool = False) -> Any:
    """Call one fixed GitHub REST endpoint and decode its JSON response."""
    if not os.environ.get("GH_TOKEN") or os.environ.get("GH_HOST") != "github.com":
        raise Refusal("GitHub credentials/host are not configured")
    argv = ["gh", "api"]
    if paginate:
        argv += ["--paginate", "--slurp"]
    argv += ["-X", method]
    argv.append(endpoint)
    for key, value in (fields or {}).items():
        argv += ["-f", f"{key}={value}"]
    try:
        result = subprocess.run(argv, check=True, text=True, capture_output=True,
                                env={**os.environ, "GH_HOST": "github.com", "GIT_TERMINAL_PROMPT": "0"})
        if not result.stdout.strip() and method == "DELETE":
            # GitHub returns HTTP 204 for ref deletion; an empty body is success.
            return {}
        data = json.loads(result.stdout)
    except subprocess.CalledProcessError as exc:
        if "HTTP 404" in (exc.stderr or ""):
            raise MissingRef(f"GitHub resource not found: {endpoint}") from exc
        raise Refusal(f"GitHub {method} {endpoint} failed") from exc
    except json.JSONDecodeError as exc:
        raise Refusal(f"GitHub {method} {endpoint} failed") from exc
    if not isinstance(data, dict) and not (allow_list and isinstance(data, list)):
        raise Refusal("GitHub returned an invalid response")
    if paginate and isinstance(data, list) and data and all(isinstance(page, list) for page in data):
        data = [item for page in data for item in page]
    return data


def _repo_slug(value: str) -> str:
    parts = value.split("/")
    if len(parts) != 2 or any(not p or p in (".", "..") or not p.replace("-", "").replace("_", "").isalnum() for p in parts):
        raise Refusal("repository must be owner/name")
    return value


def _merge_state(slug: str, branch: str, base: str) -> None:
    """Report the state of matching first-party pull requests without writing."""
    owner = slug.split("/", 1)[0]
    rows = _gh("GET", f"repos/{slug}/pulls?state=all&head={owner}:{branch}&base={base}",
               allow_list=True, paginate=True)
    if not isinstance(rows, list):
        raise Refusal("GitHub returned an invalid pull request list")
    matches = []
    for pr in rows:
        if not isinstance(pr, dict):
            continue
        head, target = pr.get("head"), pr.get("base")
        if not isinstance(head, dict) or not isinstance(target, dict):
            continue
        head_repo, base_repo = head.get("repo"), target.get("repo")
        if (isinstance(head_repo, dict) and isinstance(base_repo, dict)
                and isinstance(head_repo.get("full_name"), str)
                and isinstance(base_repo.get("full_name"), str)
                and head_repo["full_name"].lower() == slug.lower()
                and base_repo["full_name"].lower() == slug.lower()
                and head.get("ref") == branch and target.get("ref") == base):
            matches.append(pr)
    opened = [pr for pr in matches if pr.get("state") == "open"]
    if len(opened) > 1:
        raise Refusal("ambiguous: more than one matching open pull request")
    if opened:
        pr = opened[0]
        sha = pr.get("head", {}).get("sha")
        number = pr.get("number")
        if (not isinstance(number, int) or isinstance(number, bool)
                or not isinstance(sha, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", sha)):
            raise Refusal("matching open pull request is invalid")
        print(f"open {number} {sha}")
        return
    merged = [pr for pr in matches if pr.get("state") == "closed" and pr.get("merged_at") is not None]
    merged.sort(key=lambda pr: str(pr.get("merged_at") or ""), reverse=True)
    if merged:
        pr = merged[0]
        number = pr.get("number")
        listed_sha = pr.get("head", {}).get("sha")
        if (not isinstance(number, int) or isinstance(number, bool)
                or not isinstance(listed_sha, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", listed_sha)):
            raise Refusal("matching merged pull request is invalid")
        verified = _gh("GET", f"repos/{slug}/pulls/{number}")
        sha = verified.get("head", {}).get("sha")
        merge_sha = verified.get("merge_commit_sha")
        if (verified.get("merged") is not True or sha != listed_sha
                or not isinstance(sha, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", sha)
                or not isinstance(merge_sha, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", merge_sha)):
            raise Refusal("matching merged pull request could not be verified")
        print(f"merged {merge_sha} {sha}")
        return
    print("absent")


def _bootstrap(slug: str) -> None:
    repo = _gh("GET", f"repos/{slug}")
    if repo.get("full_name", "").lower() != slug.lower():
        raise Refusal("GitHub repository identity did not match")
    main = _gh("GET", f"repos/{slug}/git/ref/heads/main")
    sha = main.get("object", {}).get("sha")
    if not isinstance(sha, str) or not sha:
        raise Refusal("verified main revision is unavailable")
    try:
        existing = _gh("GET", f"repos/{slug}/git/ref/heads/dev")
    except MissingRef:
        try:
            _gh("POST", f"repos/{slug}/git/refs", {"ref": "refs/heads/dev", "sha": sha})
            created = _gh("GET", f"repos/{slug}/git/ref/heads/dev")
            if created.get("object", {}).get("sha") != sha:
                raise Refusal("created dev ref did not read back at verified main")
            print(f"created dev at {sha}")
            return
        except Refusal:
            # Another actor may have created dev between the read and create.
            existing = _gh("GET", f"repos/{slug}/git/ref/heads/dev")
    if not existing.get("object", {}).get("sha"):
        raise Refusal("existing dev revision is unverifiable")
    print("dev exists; preserved")


def _finalize(slug: str, number: int, head: str, base: str, branch: str, policy_repo: str,
              task: str, revision: str, risk: str) -> None:
    if Path(slug).is_dir():
        raise Refusal("use owner/name as --repository; local paths are not forge identities")
    policy_path = _repo(policy_repo)
    data = _load()
    # Keep forge identity independent from the operator's local checkout path.
    entry = _entry(data, policy_path)
    enabled = entry["enabled"] is True
    approval = {"task": task, "revision": revision, "risk": risk}
    if not enabled or (risk != "ordinary" and approval not in entry.get("overrides", [])):
        raise Refusal("effective task policy is manual")
    if os.environ.get("HANDOFF_MERGE_HOLD") == "1":
        raise Refusal("a merge hold is active")
    if not head or not base or not branch or branch in ("main", "dev"):
        raise Refusal("expected feature branch, head and base revision are required")
    pr = _gh("GET", f"repos/{slug}/pulls/{number}")
    if (pr.get("state") != "open" or pr.get("draft") is not False or
            pr.get("base", {}).get("ref") != "dev" or
            pr.get("base", {}).get("sha") != base or
            pr.get("base", {}).get("repo", {}).get("full_name", "").lower() != slug.lower() or
            pr.get("head", {}).get("ref") != branch or
            pr.get("head", {}).get("sha") != head or
            pr.get("mergeable_state") != "clean" or
            pr.get("head", {}).get("repo", {}).get("full_name", "").lower() != slug.lower()):
        raise Refusal("PR is not open, non-draft, exact-head and targeted to dev")
    status = _gh("GET", f"repos/{slug}/commits/{head}/status")
    if status.get("state") != "success":
        raise Refusal("commit status is not successful")
    checks = _gh("GET", f"repos/{slug}/commits/{head}/check-runs")
    runs = checks.get("check_runs")
    if not isinstance(runs, list) or not runs or any(r.get("status") != "completed" or r.get("conclusion") != "success" for r in runs):
        raise Refusal("required check runs are absent or unsuccessful")
    # Re-read policy and PR immediately before the one expected-head squash mutation.
    entry = _entry(_load(), policy_path)
    if entry["enabled"] is not True or (risk != "ordinary" and approval not in entry.get("overrides", [])) or os.environ.get("HANDOFF_MERGE_HOLD") == "1":
        raise Refusal("task policy or hold changed before merge")
    latest = _gh("GET", f"repos/{slug}/pulls/{number}")
    if (latest.get("head", {}).get("sha") != head or latest.get("base", {}).get("sha") != base or
            latest.get("base", {}).get("ref") != "dev" or latest.get("mergeable_state") != "clean" or
            latest.get("state") != "open"):
        raise Refusal("PR changed after readiness checks")
    try:
        _gh("PUT", f"repos/{slug}/pulls/{number}/merge", {"sha": head, "merge_method": "squash"})
    except Refusal:
        # Lost/ambiguous write response: reconcile read-only; never repeat the write.
        merged = _gh("GET", f"repos/{slug}/pulls/{number}")
        if merged.get("merged") is not True or merged.get("head", {}).get("sha") != head:
            raise Refusal("merge response was ambiguous and read-back did not verify merge")
    merged = _gh("GET", f"repos/{slug}/pulls/{number}")
    if merged.get("merged") is not True or merged.get("head", {}).get("sha") != head or not merged.get("merge_commit_sha"):
        raise Refusal("squash merge could not be verified")
    ref = _gh("GET", f"repos/{slug}/git/ref/heads/{branch}")
    if ref.get("object", {}).get("sha") == head:
        try:
            _gh("DELETE", f"repos/{slug}/git/refs/heads/{branch}")
        except Refusal as exc:
            raise Refusal("merge verified but owned feature branch cleanup failed") from exc
        print("merged and verified; owned feature branch deleted")
    else:
        print("merged and verified; feature branch changed, preserved")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("default-get", help="print installation default: true or false")
    p = sub.add_parser("default-set", help="set the installation default")
    p.add_argument("value")
    p = sub.add_parser("policy-get", help="print exact repository policy: auto or manual")
    p.add_argument("--repo", required=True)
    p = sub.add_parser("policy-set", help="set exact repository policy")
    p.add_argument("--repo", required=True)
    p.add_argument("value")
    p = sub.add_parser("policy-init", help="persist the choice confirmed by a project initializer")
    p.add_argument("--repo", required=True)
    p.add_argument("--choice", required=True, choices=("true", "false"))
    p = sub.add_parser("effective", help="display effective task policy")
    p.add_argument("--repo", required=True)
    p.add_argument("--task", required=True)
    p.add_argument("--revision", required=True)
    p.add_argument("--risk", choices=sorted(VALID_RISKS))
    p = sub.add_parser("assess", help="record operator risk assessment for a task revision")
    p.add_argument("--repo", required=True)
    p.add_argument("--task", required=True)
    p.add_argument("--revision", required=True)
    p.add_argument("--risk", required=True, choices=sorted(VALID_RISKS))
    p.add_argument("--reason", required=True)
    for name in ("hold", "release"):
        p = sub.add_parser(name, help="set or clear a repository or task merge hold")
        p.add_argument("--repo", required=True)
        p.add_argument("--task")
    p = sub.add_parser("override", help="record explicit task-scoped operator approval")
    p.add_argument("--repo", required=True)
    p.add_argument("--task", required=True)
    p.add_argument("--revision", required=True)
    p.add_argument("--risk", required=True, choices=sorted(VALID_RISKS))
    p.add_argument("--approve", action="store_true", required=True)
    p = sub.add_parser("dev-bootstrap", help="create missing GitHub dev from verified main")
    p.add_argument("--repository", required=True)
    p = sub.add_parser("finalize", help="readiness-check and squash one exact feature head")
    p.add_argument("--repository", required=True)
    p.add_argument("--pr", required=True, type=int)
    p.add_argument("--head", required=True)
    p.add_argument("--base", required=True)
    p.add_argument("--branch", required=True)
    p.add_argument("--policy-repo", required=True)
    p.add_argument("--task", required=True)
    p.add_argument("--revision", required=True)
    p.add_argument("--risk", required=True, choices=sorted(VALID_RISKS))
    p = sub.add_parser("merge-state", help="read-only status of a matching pull request")
    p.add_argument("--repository", required=True)
    p.add_argument("--branch", required=True)
    p.add_argument("--base", required=True)
    args = parser.parse_args()
    try:
        if args.command == "dev-bootstrap":
            _bootstrap(_repo_slug(args.repository))
            return 0
        if args.command == "finalize":
            _finalize(_repo_slug(args.repository), args.pr, args.head, args.base, args.branch,
                      args.policy_repo, args.task, args.revision, args.risk)
            return 0
        if args.command == "merge-state":
            _merge_state(_repo_slug(args.repository), args.branch, args.base)
            return 0
        if args.command == "default-get":
            print(str(_default()).lower())
            return 0
        if args.command == "default-set":
            value = _bool(args.value)
            lines = [line for line in _config() if not line.startswith("HANDOFF_AUTO_MERGE=")]
            lines.append(f"HANDOFF_AUTO_MERGE={str(value).lower()}")
            _atomic_text(CONFIG, "\n".join(lines) + "\n")
            print(str(value).lower())
            return 0
        repo = _repo(args.repo)
        if args.command == "effective":
            try:
                data = _load()
            except Refusal:
                print("manual — invalid policy store")
                return 0
        else:
            data = _load()
        if args.command in ("effective", "assess", "override", "hold", "release") and getattr(args, "task", None) is not None:
            _task_arg(args.task)
        if args.command in ("effective", "assess", "override") and not args.revision:
            raise Refusal("revision must be non-empty")
        entry = _entry(data, repo)
        if args.command == "policy-get":
            enabled = entry["enabled"]
            print("auto" if enabled is True else "manual")
            return 0
        if args.command in ("policy-set", "policy-init"):
            choice = args.value if args.command == "policy-set" else args.choice
            entry["enabled"] = _bool(choice)
            data["repositories"][repo] = entry
            _save(data)
            print("auto" if entry["enabled"] else "manual")
            return 0
        if args.command == "assess":
            if not args.revision or not args.reason:
                raise Refusal("assessment revision and reason must be non-empty")
            entry["assessments"] = [a for a in entry["assessments"]
                                    if (a["task"], a["revision"]) != (args.task, args.revision)]
            entry["assessments"].append({"task": args.task, "revision": args.revision,
                                         "risk": args.risk, "reason": args.reason})
            data["repositories"][repo] = entry
            _save(data)
            print("assessed")
            return 0
        if args.command in ("hold", "release"):
            held = args.command == "hold"
            if args.task is None:
                entry["hold"] = held
            elif held and args.task not in entry["task_holds"]:
                entry["task_holds"].append(args.task)
            elif not held:
                entry["task_holds"] = [task for task in entry["task_holds"] if task != args.task]
            data["repositories"][repo] = entry
            _save(data)
            print("held" if held else "released")
            return 0
        if args.command == "override":
            if entry["enabled"] is not True:
                raise Refusal("task approval cannot elevate a manual repository policy")
            approvals = entry.setdefault("overrides", [])
            approval = {"task": args.task, "revision": args.revision, "risk": args.risk}
            if approval not in approvals:
                approvals.append(approval)
            data["repositories"][repo] = entry
            _save(data)
            print("approved")
            return 0
        if args.command == "effective":
            if entry["enabled"] is not True:
                decision = "manual — repository policy manual"
            else:
                assessment = next((a for a in entry["assessments"]
                                   if a["task"] == args.task and a["revision"] == args.revision), None)
                if assessment is None:
                    decision = "manual — no risk assessment"
                elif (entry["hold"] or args.task in entry["task_holds"]
                      or os.environ.get("HANDOFF_MERGE_HOLD") == "1"):
                    decision = "manual — hold"
                elif (assessment["risk"] != "ordinary" and
                      {"task": args.task, "revision": args.revision, "risk": assessment["risk"]}
                      not in entry["overrides"]):
                    decision = f"manual — risk {assessment['risk']}"
                else:
                    decision = "auto"
            print(decision)
            return 0
        raise Refusal("unsupported operation")
    except Refusal as exc:
        print(f"handoff-merge: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
