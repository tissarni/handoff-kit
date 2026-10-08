#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub case-c.md draft)"
FAKE_CLAUDE="close=FAIL"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?

[ "$RC" -eq 20 ] || fail "expected exit 20, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | grep -qF 'RUN: failed — close audit VERDICT: FAIL' \
  || fail "expected 'RUN: failed — close audit VERDICT: FAIL' in output:
$OUT"
[ "$(state_of "$BRIEF")" = closed ] || fail "expected brief closed, got '$(state_of "$BRIEF")'"

echo ok
