#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub case-d.md ready)"
FAKE_CLAUDE="run=transcript-only"
OUT="$(launch run "$BRIEF" --delegate --backend claude 2>&1)"; RC=$?

[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"
[ "$(state_of "$BRIEF")" = reported ] || fail "expected brief reported, got '$(state_of "$BRIEF")'"
REPORT="${BRIEF%.md}.report.md"
assert_file "$REPORT"
head -1 "$REPORT" | grep -qF 'source: transcript' \
  || fail "expected first line of $REPORT to mention source: transcript, got: $(head -1 "$REPORT")"

echo ok
