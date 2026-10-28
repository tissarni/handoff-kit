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
import sys
import tempfile
import subprocess

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
    return data


def _save(data: dict) -> None:
    _atomic_text(POLICIES, json.dumps(data, sort_keys=True, indent=2) + "\n")


def _entry(data: dict, repo: str) -> dict:
    entry = data["repositories"].get(repo, {"enabled": None, "overrides": []})
    if not isinstance(entry, dict) or entry.get("enabled") not in (None, True, False):
        raise Refusal("invalid repository policy; refusing auto mode")
    if not isinstance(entry.get("overrides", []), list):
        raise Refusal("invalid task override store; refusing auto mode")
    return entry


def _bool(value: str) -> bool:
    if value not in ("true", "false"):
        raise Refusal("policy must be exactly true or false")
    return value == "true"


def _gh(method: str, endpoint: str, fields: dict[str, str] | None = None) -> dict:
    """Call one fixed GitHub REST endpoint and decode its JSON response."""
    if not os.environ.get("GH_TOKEN") or os.environ.get("GH_HOST") != "github.com":
        raise Refusal("GitHub credentials/host are not configured")
    argv = ["gh", "api"]
    if method != "GET":
        argv += ["-X", method]
    argv.append(endpoint)
    for key, value in (fields or {}).items():
        argv += ["-f", f"{key}={value}"]
    try:
        result = subprocess.run(argv, check=True, text=True, capture_output=True,
                                env={**os.environ, "GH_HOST": "github.com", "GIT_TERMINAL_PROMPT": "0"})
        data = json.loads(result.stdout)
    except subprocess.CalledProcessError as exc:
        if "HTTP 404" in (exc.stderr or ""):
            raise MissingRef(f"GitHub resource not found: {endpoint}") from exc
        raise Refusal(f"GitHub {method} {endpoint} failed") from exc
    except json.JSONDecodeError as exc:
        raise Refusal(f"GitHub {method} {endpoint} failed") from exc
    if not isinstance(data, dict):
        raise Refusal("GitHub returned an invalid response")
    return data


def _repo_slug(value: str) -> str:
    parts = value.split("/")
    if len(parts) != 2 or any(not p or p in (".", "..") or not p.replace("-", "").replace("_", "").isalnum() for p in parts):
        raise Refusal("repository must be owner/name")
    return value


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
            print(f"created dev at {sha}")
            return
        except Refusal:
            # Another actor may have created dev between the read and create.
            existing = _gh("GET", f"repos/{slug}/git/ref/heads/dev")
    if not existing.get("object", {}).get("sha"):
        raise Refusal("existing dev revision is unverifiable")
    print("dev exists; preserved")


def _finalize(slug: str, number: int, head: str, branch: str, policy_repo: str,
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
    if not head or not branch or branch in ("main", "dev"):
        raise Refusal("expected feature branch and head are required")
    pr = _gh("GET", f"repos/{slug}/pulls/{number}")
    if (pr.get("state") != "open" or pr.get("draft") is not False or
            pr.get("base", {}).get("ref") != "dev" or
            pr.get("head", {}).get("ref") != branch or
            pr.get("head", {}).get("sha") != head or
            pr.get("base", {}).get("sha") is None or
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
    if latest.get("head", {}).get("sha") != head or latest.get("base", {}).get("ref") != "dev" or latest.get("state") != "open":
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
    p.add_argument("--risk", required=True, choices=sorted(VALID_RISKS))
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
    p.add_argument("--branch", required=True)
    p.add_argument("--policy-repo", required=True)
    p.add_argument("--task", required=True)
    p.add_argument("--revision", required=True)
    p.add_argument("--risk", required=True, choices=sorted(VALID_RISKS))
    args = parser.parse_args()
    try:
        if args.command == "dev-bootstrap":
            _bootstrap(_repo_slug(args.repository))
            return 0
        if args.command == "finalize":
            _finalize(_repo_slug(args.repository), args.pr, args.head, args.branch,
                      args.policy_repo, args.task, args.revision, args.risk)
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
        data = _load()
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
            enabled = entry["enabled"]
            if enabled is None:
                enabled = False  # Unconfigured repositories remain manual.
            approval = {"task": args.task, "revision": args.revision, "risk": args.risk}
            approved = approval in entry.get("overrides", [])
            if args.risk != "ordinary" and not approved:
                print("manual")
                return 0
            print("auto" if enabled else "manual")
            return 0
        raise Refusal("unsupported operation")
    except Refusal as exc:
        print(f"handoff-merge: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
