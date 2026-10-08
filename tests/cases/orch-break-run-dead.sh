#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub g-brief1.md draft)"
PLAN="$(dirname "$BRIEF")/g-plan.md"
make_plan "$PLAN" "$BRIEF"
STATUS="${PLAN%.md}.status.md"

FAKE_CLAUDE="run=no-report"
orch start "$PLAN" --backend claude >/dev/null 2>&1

is_broken() { [ -f "$STATUS" ] && head -1 "$STATUS" | grep -q '^NEEDS YOU'; }
wait_for 60 is_broken || fail "phase did not break within 60s (status: $(head -1 "$STATUS" 2>/dev/null))"

FIRST="$(head -1 "$STATUS")"
printf '%s' "$FIRST" | grep -qF 'run:dead — run stage failed (exit 30), no commit landed' \
  || fail "expected run:dead text in status: $FIRST"
[ "$(state_of "$BRIEF")" = running ] || fail "expected brief handoff: running, got '$(state_of "$BRIEF")'"
ls "${BRIEF%.md}".failed-*.log >/dev/null 2>&1 || fail "expected a ${BRIEF%.md}.failed-*.log"

echo ok
