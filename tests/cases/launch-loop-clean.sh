#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub case-a.md draft)"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?

[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"
[ "$(state_of "$BRIEF")" = closed ] || fail "expected brief closed, got '$(state_of "$BRIEF")'"
assert_file "${BRIEF%.md}.review.md"
assert_file "${BRIEF%.md}.report.md"
assert_file "${BRIEF%.md}.close.md"
printf '%s\n' "$OUT" | grep -qF 'LOOP COMPLETE' || fail "expected LOOP COMPLETE in output:
$OUT"

echo ok
