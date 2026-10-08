#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub r-brief1.md draft)"
PLAN="$(dirname "$BRIEF")/r-plan.md"
make_plan "$PLAN" "$BRIEF"
STATUS="${PLAN%.md}.status.md"
EVENTS="${PLAN%.md}.events.log"

# The phase's last brief closes but its loop exits 20: broken, every brief closed.
FAKE_CLAUDE="close=FAIL"
orch start "$PLAN" --backend claude >/dev/null 2>&1
exited() { /usr/bin/grep -q 'driver exiting' "$EVENTS" 2>/dev/null; }
wait_for 60 exited || fail "driver did not exit within 60s (status: $(head -1 "$STATUS" 2>/dev/null))"
head -1 "$STATUS" | /usr/bin/grep -q '^NEEDS YOU' || fail "expected a NEEDS YOU status, got: $(head -1 "$STATUS")"
/usr/bin/grep -q '^orchestration: broken' "$PLAN" || fail "expected 'orchestration: broken' in plan frontmatter"
[ "$(state_of "$BRIEF")" = closed ] || fail "expected brief closed, got '$(state_of "$BRIEF")'"
CALLS="$(wc -l <"$SANDBOX/state/calls.log")"

# start is not resume: it still refuses the phase.
OUT="$(orch start "$PLAN" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 1 ] || fail "start: expected exit 1, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF 'every brief of phase 1 is already closed' \
  || fail "start: expected 'every brief of phase 1 is already closed' in output:
$OUT"

# resume ends the phase the way the driver does, and launches nothing.
OUT="$(orch resume "$PLAN" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "resume: expected exit 0, got $RC. Output:
$OUT"
head -1 "$STATUS" | /usr/bin/grep -qF 'DONE · phase 1/1' || fail "expected 'DONE · phase 1/1', got: $(head -1 "$STATUS")"
assert_contains "$STATUS" '## Phase summary'
assert_contains "$STATUS" '### Branch `feat/test` -> `main`'
assert_contains "$STATUS" 'Open PR: '
/usr/bin/grep -q 'PHASE DONE 1' "$EVENTS" || fail "expected 'PHASE DONE 1' in events log"
/usr/bin/grep -q '^orchestration: done' "$PLAN" || fail "expected 'orchestration: done' in plan frontmatter"
/usr/bin/grep -q '^    status: done' "$PLAN" || fail "expected the phase at 'status: done' in plan frontmatter"
assert_no_file "${PLAN%.md}.lock"
sleep 2
[ "$(wc -l <"$SANDBOX/state/calls.log")" -eq "$CALLS" ] || fail "resume launched a stage: $(tail -1 "$SANDBOX/state/calls.log")"

# No other state reaches it: planned still refuses, paused ends the phase.
PLAN2="$(dirname "$BRIEF")/r2-plan.md"
make_plan "$PLAN2" "$BRIEF"
OUT="$(orch resume "$PLAN2" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 1 ] || fail "planned: expected exit 1, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF 'every brief of phase 1 is already closed' \
  || fail "planned: expected 'every brief of phase 1 is already closed' in output:
$OUT"
assert_no_file "${PLAN2%.md}.status.md"
/usr/bin/sed -i 's/^orchestration: planned$/orchestration: paused/' "$PLAN2"
OUT="$(orch resume "$PLAN2" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "paused: expected exit 0, got $RC. Output:
$OUT"
head -1 "${PLAN2%.md}.status.md" | /usr/bin/grep -qF 'DONE · phase 1/1' \
  || fail "paused: expected 'DONE · phase 1/1', got: $(head -1 "${PLAN2%.md}.status.md")"

echo ok
