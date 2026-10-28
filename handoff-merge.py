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

CONFIG = Path.home() / ".config" / "handoff" / "config.env"
POLICIES = Path.home() / ".config" / "handoff" / "project-policy.json"
VALID_RISKS = {"ordinary", "breaking-api", "destructive-migration", "auth-permissions-secrets",
               "deployment-infrastructure", "merge-policy", "uncertain"}


class Refusal(Exception):
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
    args = parser.parse_args()
    try:
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
