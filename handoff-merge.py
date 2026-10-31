#!/usr/bin/env python3
"""Repository-scoped merge policy and task-approval interface.

This is operator convenience, not a hostile-process security boundary: another process
running as this user can edit these local files. Agent-produced brief content is never read.
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import subprocess
from typing import Any, NoReturn

CONFIG = Path.home() / ".config" / "handoff" / "config.env"
POLICIES = Path.home() / ".config" / "handoff" / "project-policy.json"
VALID_RISKS = {"ordinary", "breaking-api", "destructive-migration", "auth-permissions-secrets",
               "deployment-infrastructure", "merge-policy", "uncertain"}
PR_BODY_SECTIONS = ("Feature", "Acceptance", "Final review", "CI", "Limitations")


class Refusal(Exception):
    pass


class MissingRef(Refusal):
    pass


class FinalizeFailure(Refusal):
    def __init__(self, message: str, exit_code: int):
        super().__init__(message)
        self.exit_code = exit_code


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
        detail = (exc.stderr or "").strip()
        raise Refusal(f"GitHub {method} {endpoint} failed" + (f": {detail}" if detail else "")) from exc
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


def _review_evidence(plan: str) -> tuple[str, str, str, str, str, str]:
    feature = Path(plan).expanduser().resolve()
    evidence = feature.with_name(feature.name[:-3] + ".final-review.json" if feature.name.endswith(".md")
                                else feature.name + ".final-review.json")
    try:
        record = json.loads(evidence.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise Refusal("invalid final-review evidence: file") from exc
    if not isinstance(record, dict):
        raise Refusal("invalid final-review evidence: object")
    required = ("feature", "repo", "head", "base", "verdict", "blockers", "risk")
    for key in required:
        if key not in record or not isinstance(record[key], str):
            raise Refusal(f"invalid final-review evidence: {key}")
    if record["feature"] != str(feature):
        raise Refusal("invalid final-review evidence: feature")
    if record["verdict"] != "PASS":
        raise Refusal("invalid final-review evidence: verdict")
    if record["blockers"] != "none":
        raise Refusal("invalid final-review evidence: blockers")
    if record["risk"] not in VALID_RISKS:
        raise Refusal("invalid final-review evidence: risk")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", record["head"]):
        raise Refusal("invalid final-review evidence: head")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", record["base"]):
        raise Refusal("invalid final-review evidence: base")
    try:
        repo_path = Path(record["repo"]).expanduser().resolve(strict=True)
        if not repo_path.is_dir():
            raise OSError("not a directory")
        local_head = subprocess.run(["git", "-C", str(repo_path), "rev-parse", "HEAD"], check=True,
                                    text=True, capture_output=True).stdout.strip()
        repo = str(repo_path)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise Refusal("invalid final-review evidence: repo") from exc
    revision = ""
    try:
        lines = feature.read_text(encoding="utf-8").splitlines()
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
        for line in lines[1:end]:
            match = re.match(r"^revision:\s*(.*?)\s*$", line)
            if match:
                revision = match.group(1).strip("\"'")
                break
    except (OSError, UnicodeError, StopIteration):
        pass
    if not revision:
        raise Refusal("plan revision is missing")
    if local_head.lower() != record["head"].lower():
        raise Refusal("final-review evidence head does not match local HEAD")
    return repo, str(feature), revision, record["risk"], record["head"].lower(), record["base"].lower()


def _finalize_decision(slug: str, plan: str, branch: str, base: str) -> tuple[str, str, str, int, str, str, bool]:
    if base != "dev":
        raise Refusal("automatic merges only target dev")
    if Path(slug).is_dir():
        raise Refusal("use owner/name as --repository; local paths are not forge identities")
    policy_path, task, revision, risk, head, evidence_base = _review_evidence(plan)
    data = _load()
    entry = _entry(data, policy_path)
    if entry["enabled"] is not True:
        raise Refusal("effective task policy is manual — repository policy manual")
    assessment = next((a for a in entry["assessments"]
                       if a["task"] == task and a["revision"] == revision), None)
    if assessment is None:
        raise Refusal("effective task policy is manual — no risk assessment")
    if entry["hold"] or task in entry["task_holds"] or os.environ.get("HANDOFF_MERGE_HOLD") == "1":
        raise Refusal("effective task policy is manual — hold")
    assessed = assessment["risk"]
    approval = {"task": task, "revision": revision, "risk": assessed}
    if assessed != "ordinary" and approval not in entry["overrides"]:
        raise Refusal(f"effective task policy is manual — risk {assessed}")
    if risk != "ordinary" and risk != assessed:
        raise Refusal(f"late risk {risk}")
    if not branch or branch in ("main", "dev"):
        raise Refusal("expected feature branch")
    owner = slug.split("/", 1)[0]
    rows = _gh("GET", f"repos/{slug}/pulls?state=all&head={owner}:{branch}", allow_list=True, paginate=True)
    if not isinstance(rows, list):
        raise Refusal("GitHub returned an invalid pull request list")
    candidates = []
    base_mismatches = []
    for candidate in rows:
        if not isinstance(candidate, dict):
            continue
        candidate_head = candidate.get("head")
        candidate_base = candidate.get("base")
        candidate_repo = candidate_head.get("repo") if isinstance(candidate_head, dict) else None
        target_repo = candidate_base.get("repo") if isinstance(candidate_base, dict) else None
        if (isinstance(candidate_head, dict) and isinstance(candidate_base, dict)
                and isinstance(candidate_repo, dict) and isinstance(target_repo, dict)
                and str(candidate_repo.get("full_name", "")).lower() == slug.lower()
                and str(target_repo.get("full_name", "")).lower() == slug.lower()
                and candidate_head.get("ref") == branch and candidate_head.get("sha") == head):
            if candidate_base.get("ref") == base:
                candidates.append(candidate)
            else:
                base_mismatches.append(candidate)
    opened = [pr for pr in candidates if pr.get("state") == "open"]
    merged_candidates = [pr for pr in candidates
                         if pr.get("state") == "closed" and pr.get("merged_at") is not None]
    if len(opened) == 1 and not merged_candidates:
        pr, already_merged = opened[0], False
    elif not opened and len(merged_candidates) == 1:
        pr, already_merged = merged_candidates[0], True
    else:
        numbers = [str(pr.get("number", "unknown")) for pr in candidates]
        if not candidates and base_mismatches:
            stale_numbers = ", ".join(str(pr.get("number", "unknown")) for pr in base_mismatches)
            raise Refusal(f"base changed; pull request candidates: {stale_numbers}")
        raise Refusal("ambiguous pull request candidates: " + (", ".join(numbers) or "none"))
    number = pr.get("number")
    if not isinstance(number, int) or isinstance(number, bool):
        raise Refusal("matching open pull request is invalid")
    pr = _gh("GET", f"repos/{slug}/pulls/{number}")
    head_info, base_info = pr.get("head"), pr.get("base")
    if not isinstance(head_info, dict) or not isinstance(base_info, dict):
        raise Refusal("pull request identity changed")
    head_repo, base_repo = head_info.get("repo"), base_info.get("repo")
    if not isinstance(head_repo, dict) or not isinstance(base_repo, dict):
        raise Refusal("pull request identity changed")
    if (pr.get("state") != ("closed" if already_merged else "open") or base_info.get("ref") != base or
            (not already_merged and base_info.get("sha") != evidence_base) or
            str(base_repo.get("full_name", "")).lower() != slug.lower() or
            str(head_repo.get("full_name", "")).lower() != slug.lower() or
            head_info.get("ref") != branch or head_info.get("sha") != head or
            (not already_merged and pr.get("mergeable_state") != "clean") or
            (already_merged and (pr.get("merged") is not True or not isinstance(pr.get("merge_commit_sha"), str)
                                 or not re.fullmatch(r"[0-9a-fA-F]{40}", pr["merge_commit_sha"])) )):
        if base_info.get("ref") != base or base_info.get("sha") != evidence_base:
            raise Refusal("base changed since final review")
        if head_info.get("sha") != head:
            raise Refusal("pull request head does not match final review")
        if pr.get("mergeable_state") != "clean":
            raise Refusal("pull request is not clean")
        raise Refusal("pull request identity changed")
    return policy_path, task, revision, number, head, evidence_base, already_merged


def _finalize(slug: str, plan: str, branch: str, base: str) -> None:
    _, _, _, number, head, expected_base, already_merged = _finalize_decision(slug, plan, branch, base)
    if already_merged:
        print("already merged")
        _verify_merge_and_cleanup(slug, number, head, branch, base)
        return
    pr = _gh("GET", f"repos/{slug}/pulls/{number}")
    body = pr.get("body")
    sections: dict[str, list[str]] = {}
    current = None
    if isinstance(body, str):
        for line in body.splitlines():
            if line.startswith("## "):
                current = line[3:].strip()
                sections[current] = []
            elif current is not None:
                sections[current].append(line)
    for section in PR_BODY_SECTIONS:
        content = "\n".join(sections.get(section, [])).strip()
        if not content or (section == "Final review" and head not in content):
            raise Refusal(f"incomplete PR body: {section}")

    ready_marked = False

    def refuse(reason: str) -> NoReturn:
        if ready_marked:
            raise Refusal(f"refused after marking ready: {reason}")
        raise Refusal(reason)

    try:
        protection = _gh("GET", f"repos/{slug}/branches/{base}/protection/required_status_checks")
        if not isinstance(protection, dict):
            refuse("malformed required status checks response")
        contexts, check_defs = protection.get("contexts", []), protection.get("checks", [])
        if not isinstance(contexts, list) or not isinstance(check_defs, list):
            refuse("malformed required status checks response")
        required: set[str] = set()
        for context in contexts:
            if not isinstance(context, str):
                refuse("malformed required status checks response")
            required.add(context)
        for check in check_defs:
            if not isinstance(check, dict) or not isinstance(check.get("context"), str):
                refuse("malformed required status checks response")
            required.add(check["context"])
        fallback = not required
    except MissingRef:
        fallback, required = True, set()
    except Refusal as exc:
        if "HTTP 403" in str(exc) or "HTTP 404" in str(exc):
            fallback, required = True, set()
        else:
            refuse(str(exc))

    try:
        runs = []
        page = 1
        total_count = None
        while total_count is None or len(runs) < total_count:
            checks = _gh("GET", f"repos/{slug}/commits/{head}/check-runs?per_page=100&page={page}")
            batch = checks.get("check_runs") if isinstance(checks, dict) else None
            if not isinstance(batch, list):
                refuse("invalid check-runs response")
            runs.extend(batch)
            total_count = checks.get("total_count", len(runs))
            if not isinstance(total_count, int) or total_count < len(runs) or not batch:
                if total_count > len(runs) and batch:
                    refuse("invalid check-runs pagination response")
                break
            page += 1
        status = _gh("GET", f"repos/{slug}/commits/{head}/status")
        statuses = status.get("statuses") if isinstance(status, dict) else None
        if not isinstance(runs, list) or not isinstance(statuses, list):
            refuse("invalid check results response")
        if fallback:
            if any(not isinstance(run, dict) or run.get("status") != "completed" or
                   run.get("conclusion") not in ("success", "neutral", "skipped") for run in runs):
                refuse("required checks are absent or unsuccessful")
            if not any(run.get("conclusion") == "success" for run in runs) and not (
                    status.get("state") == "success" and not statuses):
                refuse("required checks are absent or unsuccessful")
        else:
            def latest(items: list, name_key: str, time_key: str, name: str) -> dict | None:
                matching = [item for item in items if isinstance(item, dict) and item.get(name_key) == name]
                if not matching:
                    return None
                return max(matching, key=lambda item: (str(item.get(time_key, "")),
                                                       int(item.get("id", 0)) if str(item.get("id", 0)).isdigit() else 0))
            for name in required:
                run = latest(runs, "name", "started_at", name)
                legacy = latest(statuses, "context", "created_at", name)
                if run is None and legacy is None:
                    refuse(f"required check missing: {name}")
                if run is not None and (run.get("status") != "completed" or run.get("conclusion") != "success"):
                    refuse(f"required check unsuccessful: {name}")
                if legacy is not None and legacy.get("state") != "success":
                    refuse(f"required check unsuccessful: {name}")
    except Refusal as exc:
        refuse(str(exc))

    if pr.get("draft") is True:
        node_id = pr.get("node_id")
        if not isinstance(node_id, str) or not node_id:
            refuse("pull request identity changed")
        query = "mutation($pullRequestId: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $pullRequestId}) { pullRequest { id } } }"
        _gh("POST", "graphql", {"query": query, "pullRequestId": node_id})
        ready_marked = True

    try:
        _, _, _, latest_number, latest_head, latest_base, latest_merged = _finalize_decision(slug, plan, branch, base)
    except Refusal as exc:
        refuse(str(exc))
    if (latest_number, latest_head, latest_base, latest_merged) != (number, head, expected_base, False):
        refuse("pull request identity changed before merge")
    reconciled = None
    try:
        _gh("PUT", f"repos/{slug}/pulls/{number}/merge", {"sha": head, "merge_method": "squash"})
    except Refusal:
        try:
            reconciled = _gh("GET", f"repos/{slug}/pulls/{number}")
        except Refusal as exc:
            raise FinalizeFailure("ambiguous: merge read-back failed", 3) from exc
        if reconciled.get("merged") is not True or reconciled.get("head", {}).get("sha") != head:
            raise FinalizeFailure("ambiguous: merge response was not verified", 3)
    _verify_merge_and_cleanup(slug, number, head, branch, base, reconciled)


def _verify_merge_and_cleanup(slug: str, number: int, head: str, branch: str, base: str,
                              merged: dict | None = None) -> None:
    try:
        if merged is None:
            merged = _gh("GET", f"repos/{slug}/pulls/{number}")
        assert merged is not None
        merge_sha = merged.get("merge_commit_sha")
        if (merged.get("merged") is not True or merged.get("head", {}).get("sha") != head
                or not isinstance(merge_sha, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", merge_sha)):
            raise FinalizeFailure("ambiguous: squash merge could not be verified", 3)
        base_ref = _gh("GET", f"repos/{slug}/git/ref/heads/{base}")
        base_sha = base_ref.get("object", {}).get("sha")
        if not isinstance(base_sha, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", base_sha):
            raise FinalizeFailure("ambiguous: base ref could not be verified", 3)
        if base_sha != merge_sha:
            comparison = _gh("GET", f"repos/{slug}/compare/{merge_sha}...{base_sha}")
            # compare BASE...HEAD describes HEAD relative to BASE: base containing the merge is "ahead".
            if comparison.get("status") not in ("identical", "ahead"):
                raise FinalizeFailure("ambiguous: merge commit is not contained in base", 3)
    except FinalizeFailure:
        raise
    except Refusal as exc:
        raise FinalizeFailure("ambiguous: merge/base read-back failed", 3) from exc
    try:
        ref = _gh("GET", f"repos/{slug}/git/ref/heads/{branch}")
    except MissingRef:
        print("branch already deleted")
        print(f"merge-sha: {merge_sha}")
        print("branch-cleanup: already-deleted")
        return
    except Refusal as exc:
        print(f"merge-sha: {merge_sha}")
        print("branch-cleanup: failed")
        raise FinalizeFailure("merged, cleanup failed: branch ref could not be read", 4) from exc
    if ref.get("object", {}).get("sha") != head:
        print("branch preserved")
        print(f"merge-sha: {merge_sha}")
        print("branch-cleanup: preserved")
        return
    try:
        _gh("DELETE", f"repos/{slug}/git/refs/heads/{branch}")
    except Refusal as exc:
        print(f"merge-sha: {merge_sha}")
        print("branch-cleanup: failed")
        raise FinalizeFailure("merged, cleanup failed: branch deletion failed", 4) from exc
    print("merged and verified; owned feature branch deleted")
    print(f"merge-sha: {merge_sha}")
    print("branch-cleanup: deleted")


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
    p = sub.add_parser("finalize", help="readiness-check and squash one reviewed feature head")
    p.add_argument("--repository", required=True)
    p.add_argument("--plan", required=True)
    p.add_argument("--branch", required=True)
    p.add_argument("--base", default="dev")
    p = sub.add_parser("merge-state", help="read-only status of a matching pull request")
    p.add_argument("--repository", required=True)
    p.add_argument("--branch", required=True)
    p.add_argument("--base", required=True)
    argv = sys.argv[1:]
    try:
        if argv and argv[0] == "finalize":
            with contextlib.redirect_stderr(io.StringIO()):
                args = parser.parse_args(argv)
        else:
            args = parser.parse_args(argv)
    except SystemExit as exc:
        if argv and argv[0] == "finalize":
            if exc.code == 0:
                return 0
            print("handoff-merge: invalid finalize arguments", file=sys.stderr)
            return 1
        raise exc
    try:
        if args.command == "dev-bootstrap":
            _bootstrap(_repo_slug(args.repository))
            return 0
        if args.command == "finalize":
            _finalize(_repo_slug(args.repository), args.plan, args.branch, args.base)
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
        return exc.exit_code if isinstance(exc, FinalizeFailure) else 1


if __name__ == "__main__":
    raise SystemExit(main())
