#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub i-brief1.md draft)"
PLAN="$(dirname "$BRIEF")/i-plan.md"
make_plan "$PLAN" "$BRIEF"
STATUS="${PLAN%.md}.status.md"

FAKE_CLAUDE="run=wait"
orch start "$PLAN" --backend claude >/dev/null 2>&1

wait_for 60 test -f "$SANDBOX/state/run-started" || fail "run stage never started"

TICKOUT="$(orch tick "$PLAN" 2>&1)"
printf '%s\n' "$TICKOUT" | grep -q '^tick: ok' || fail "expected 'tick: ok' line, got:
$TICKOUT"

FIRST="$(head -1 "$STATUS")"
printf '%s' "$FIRST" | grep -qF 'stage run' || fail "expected 'stage run' in status: $FIRST"
printf '%s' "$FIRST" | grep -qF 'heartbeat 0 min ago' || fail "expected 'heartbeat 0 min ago' in status: $FIRST"

touch "$SANDBOX/state/run-release"

is_done() { [ -f "$STATUS" ] && head -1 "$STATUS" | grep -q '^DONE'; }
wait_for 60 is_done || fail "phase did not finish within 60s after release (status: $(head -1 "$STATUS" 2>/dev/null))"

echo ok
