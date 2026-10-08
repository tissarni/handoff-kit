#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub case-b.md draft)"
FAKE_CLAUDE="revise=held"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?

[ "$RC" -eq 10 ] || fail "expected exit 10, got $RC. Output:
$OUT"
FIRSTGATE="$(printf '%s\n' "$OUT" | grep -m1 '^GATE: ' || true)"
case "$FIRSTGATE" in
  "GATE: held — "*) ;;
  *) fail "expected first GATE: line to start 'GATE: held — ', got: $FIRSTGATE" ;;
esac
[ "$(state_of "$BRIEF")" = reviewed ] || fail "expected brief reviewed, got '$(state_of "$BRIEF")'"

echo ok
