#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF1="$(make_brief testsub e-brief1.md draft)"
BRIEF2="$(make_brief testsub e-brief2.md draft)"
PLAN="$(dirname "$BRIEF1")/e-plan.md"
make_plan "$PLAN" "$BRIEF1" "$BRIEF2"
STATUS="${PLAN%.md}.status.md"
EVENTS="${PLAN%.md}.events.log"

FAKE_CLAUDE="run=commit"
orch start "$PLAN" --backend claude >/dev/null 2>&1

is_done() { [ -f "$STATUS" ] && head -1 "$STATUS" | grep -q '^DONE'; }
wait_for 120 is_done || fail "phase did not finish within 120s (status: $(head -1 "$STATUS" 2>/dev/null))"

head -1 "$STATUS" | grep -qF 'DONE · phase 1/1' || fail "expected 'DONE · phase 1/1', got: $(head -1 "$STATUS")"
[ "$(grep -c 'BRIEF CLOSED' "$EVENTS")" -eq 2 ] || fail "expected 2 BRIEF CLOSED events, got $(grep -c 'BRIEF CLOSED' "$EVENTS")"
grep -q 'PHASE DONE 1' "$EVENTS" || fail "expected 'PHASE DONE 1' in events log"
[ "$(grep -c '^pr create' "$SANDBOX/state/gh.log" 2>/dev/null || echo 0)" -eq 1 ] \
  || fail "expected exactly one 'pr create' in gh.log, got: $(cat "$SANDBOX/state/gh.log" 2>/dev/null)"

REPO_HEAD="$(git -C "$SANDBOX/repo_under.test" rev-parse HEAD)"
ORIGIN_HEAD="$(git -C "$SANDBOX/origin.git" rev-parse feat/test)"
[ "$REPO_HEAD" = "$ORIGIN_HEAD" ] || fail "origin/feat/test ($ORIGIN_HEAD) != repo HEAD ($REPO_HEAD)"

grep -q '^orchestration: done' "$PLAN" || fail "expected 'orchestration: done' in plan frontmatter"
assert_no_file "${PLAN%.md}.lock"

echo ok
