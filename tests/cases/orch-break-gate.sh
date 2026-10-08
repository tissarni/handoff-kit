#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub f-brief1.md draft)"
PLAN="$(dirname "$BRIEF")/f-plan.md"
make_plan "$PLAN" "$BRIEF"
STATUS="${PLAN%.md}.status.md"

FAKE_CLAUDE="review=REWRITE,revise=held"
orch start "$PLAN" --backend claude >/dev/null 2>&1

is_broken() { [ -f "$STATUS" ] && head -1 "$STATUS" | grep -q '^NEEDS YOU'; }
wait_for 60 is_broken || fail "phase did not break within 60s (status: $(head -1 "$STATUS" 2>/dev/null))"

FIRST="$(head -1 "$STATUS")"
case "$FIRST" in
  "NEEDS YOU · broken at "*) ;;
  *) fail "expected status to start 'NEEDS YOU · broken at ', got: $FIRST" ;;
esac
printf '%s' "$FIRST" | grep -qF 'gate:held — ' || fail "expected 'gate:held — ' in status: $FIRST"
grep -q '^orchestration: broken' "$PLAN" || fail "expected 'orchestration: broken' in plan frontmatter"

echo ok
