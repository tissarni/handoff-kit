#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub h-brief1.md draft)"
PLAN="$(dirname "$BRIEF")/h-plan.md"
make_plan "$PLAN" "$BRIEF"
STATUS="${PLAN%.md}.status.md"
EVENTS="${PLAN%.md}.events.log"

FAKE_CLAUDE="review=limit-once"
orch start "$PLAN" --backend claude >/dev/null 2>&1

is_done() { [ -f "$STATUS" ] && head -1 "$STATUS" | grep -q '^DONE'; }
wait_for 60 is_done || fail "phase did not finish within 60s (status: $(head -1 "$STATUS" 2>/dev/null))"

grep -q 'PAUSE usage limit #1 at ' "$EVENTS" || fail "expected 'PAUSE usage limit #1 at ' in events log:
$(cat "$EVENTS" 2>/dev/null)"
head -1 "$STATUS" | grep -qF 'DONE · phase 1/1' || fail "expected 'DONE · phase 1/1', got: $(head -1 "$STATUS")"

echo ok
