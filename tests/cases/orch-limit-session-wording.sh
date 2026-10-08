#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub s-brief1.md draft)"
PLAN="$(dirname "$BRIEF")/s-plan.md"
make_plan "$PLAN" "$BRIEF"
STATUS="${PLAN%.md}.status.md"
EVENTS="${PLAN%.md}.events.log"

# Claude's wording of 2026-09-29, verbatim. The review hits it once and pauses; the run
# hits it and breaks as a limit, where it used to read as run:dead.
printf '%s\n' "You've hit your session limit · resets 12:30pm (UTC)" >"$SANDBOX/state/limit-text"
FAKE_CLAUDE="review=limit-once,run=limit"
orch start "$PLAN" --backend claude >/dev/null 2>&1

exited() { /usr/bin/grep -q 'driver exiting' "$EVENTS" 2>/dev/null; }
wait_for 60 exited || fail "driver did not exit within 60s (status: $(head -1 "$STATUS" 2>/dev/null))"

/usr/bin/grep -q 'PAUSE usage limit #1 at s-brief1 (handoff: draft)' "$EVENTS" \
  || fail "expected the review to pause on the limit. Events:
$(cat "$EVENTS")"
FIRST="$(head -1 "$STATUS")"
case "$FIRST" in
  "NEEDS YOU · broken at s-brief1 · limit — run stage hit a usage limit;"*) ;;
  *) fail "expected the run to break as a usage limit, got: $FIRST" ;;
esac

echo ok
