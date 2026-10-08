#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF1="$(make_brief testsub i-brief1.md draft)"
BRIEF2="$(make_brief testsub i-brief2.md draft)"
PLAN="$(dirname "$BRIEF1")/i-plan.md"
make_plan "$PLAN" "$BRIEF1" "$BRIEF2"
STATUS="${PLAN%.md}.status.md"
EVENTS="${PLAN%.md}.events.log"

FAKE_CLAUDE="run=commit"
orch start "$PLAN" --backend claude >/dev/null 2>&1

is_done() { [ -f "$STATUS" ] && head -1 "$STATUS" | grep -q '^DONE'; }
wait_for 120 is_done || fail "phase did not finish within 120s (status: $(head -1 "$STATUS" 2>/dev/null))"

for n in i-brief1 i-brief2; do
  cnt="$(/usr/bin/grep -c "COST $n 0.0035 USD over 5 stages\$" "$EVENTS")"
  [ "$cnt" -eq 1 ] || fail "expected exactly one COST line for $n, got $cnt. Events:
$(cat "$EVENTS")"
done

head -1 "$STATUS" | grep -q '^DONE · ' || fail "expected status line 1 to start 'DONE · ', got: $(head -1 "$STATUS")"

assert_contains "$STATUS" '### Cost — claude stages, USD at list price'
assert_contains "$STATUS" '| `i-brief1` | 0.0007 | 0.0007 | 0.0007 | 0.0007 | 0.0007 | — | 0.0035 |'
assert_contains "$STATUS" '| `i-brief2` | 0.0007 | 0.0007 | 0.0007 | 0.0007 | 0.0007 | — | 0.0035 |'
assert_contains "$STATUS" '| **phase** | 0.0014 | 0.0014 | 0.0014 | 0.0014 | 0.0014 | — | 0.0070 |'
assert_contains "$STATUS" 'Unpriced turns: 0 · stages with no usage: 0'

echo ok
