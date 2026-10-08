#!/usr/bin/env bash
# A repo whose origin is on GitLab gets its draft MR from glab, never gh: gh cannot reach
# a GitLab remote, and a phase on one (2026-10-05) opened no PR because of it.
# The run prompt carries the glab rule too.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

# Same bare repo, reached through a path that reads as a GitLab URL.
mkdir -p "$SANDBOX/gitlab.example.com"
mv "$SANDBOX/origin.git" "$SANDBOX/gitlab.example.com/origin.git"
git -C "$SANDBOX/repo_under.test" remote set-url origin "$SANDBOX/gitlab.example.com/origin.git"

BRIEF1="$(make_brief testsub g-brief1.md draft)"
BRIEF2="$(make_brief testsub g-brief2.md draft)"
PLAN="$(dirname "$BRIEF1")/g-plan.md"
make_plan "$PLAN" "$BRIEF1" "$BRIEF2"
STATUS="${PLAN%.md}.status.md"
EVENTS="${PLAN%.md}.events.log"

FAKE_CLAUDE="run=commit"
orch start "$PLAN" --backend claude >/dev/null 2>&1

is_done() { [ -f "$STATUS" ] && head -1 "$STATUS" | grep -q '^DONE'; }
wait_for 120 is_done || fail "phase did not finish within 120s (status: $(head -1 "$STATUS" 2>/dev/null))"

[ "$(grep -c '^mr create' "$SANDBOX/state/glab.log" 2>/dev/null || echo 0)" -eq 1 ] \
  || fail "expected exactly one 'mr create' in glab.log, got: $(cat "$SANDBOX/state/glab.log" 2>/dev/null)"
grep -q -- '--target-branch main --source-branch feat/test' "$SANDBOX/state/glab.log" \
  || fail "mr create did not target main from feat/test: $(grep '^mr create' "$SANDBOX/state/glab.log")"
[ ! -s "$SANDBOX/state/gh.log" ] || fail "gh was called on a GitLab origin: $(cat "$SANDBOX/state/gh.log")"
grep -qF 'PR opened (draft) feat/test -> main: https://gitlab.com/test/repo/-/merge_requests/1' "$EVENTS" \
  || fail "no PR-opened event with the bare MR URL: $(grep 'PR ' "$EVENTS")"

python3 - "$SANDBOX/state/calls.log" <<'PY' || fail "run prompt does not carry the glab rule"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
runs = [r for r in recs if r["stage"] == "run"]
assert runs, "no run call"
argv = runs[0]["argv"]
prompt = argv[argv.index("--") + 1]
assert "glab mr create --draft --target-branch <base>" in prompt, "no glab rule"
assert "gh pr create" not in prompt, "gh rule still present"
assert "@PR_RULE@" not in prompt, "placeholder not replaced"
PY

echo ok
