#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

# The run's audit of itself (outcome PARTIAL, refuted/unconfirmed counts) only warns
# when the close audit says PASS and NOT DONE is none.
BRIEF="$(make_brief testsub case-p.md draft)"
FAKE_CLAUDE="run=partial"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?

[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF 'LOOP COMPLETE' || fail "expected LOOP COMPLETE in output:
$OUT"
WARN='WARNING: run check passes on close audit VERDICT: PASS with NOT DONE none, although the report says outcome: PARTIAL · audit: 1 refuted, 1 unconfirmed'
printf '%s\n' "$OUT" | /usr/bin/grep -qxF "$WARN" || fail "expected the line '$WARN' in output:
$OUT"
[ "$(state_of "$BRIEF")" = closed ] || fail "expected brief closed, got '$(state_of "$BRIEF")'"

# A close audit FAIL, a NOT DONE item or BLOCKED still fails the check.
expect_run_failed() {  # $1 = brief file, $2 = FAKE_CLAUDE, $3 = the RUN: line expected
  local b out rc
  b="$(make_brief testsub "$1" draft)"
  FAKE_CLAUDE="$2"
  out="$(launch loop "$b" --gate auto --backend claude 2>&1)"; rc=$?
  [ "$rc" -eq 20 ] || fail "$2: expected exit 20, got $rc. Output:
$out"
  printf '%s\n' "$out" | /usr/bin/grep -qxF "$3" || fail "$2: expected the line '$3' in output:
$out"
}
expect_run_failed case-p2.md 'run=partial,close=FAIL' 'RUN: failed — close audit VERDICT: FAIL'
expect_run_failed case-p3.md 'run=not-done' 'RUN: failed — NOT DONE lists 1 item(s): - task 2 left for a later brief'
expect_run_failed case-p4.md 'run=blocked' 'RUN: failed — outcome: BLOCKED'

echo ok
