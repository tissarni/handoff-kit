#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init
CALLS="$SANDBOX/state/calls.log"
resumes() { python3 -c 'import json,sys; print(sum(json.loads(l)["stage"] == "resume" for l in open(sys.argv[1]) if l.strip()))' "$CALLS"; }

# Correctly separated claims permit only the unresolved criterion into the one fix-up.
BRIEF="$(make_brief testsub findings-split.md draft)"
FAKE_CLAUDE="close=FAIL-split-once"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)" || fail "split findings loop failed: $OUT"
[ "$(resumes)" -eq 1 ] || fail "split findings should run exactly one fix-up"
FIXUP="${BRIEF%.md}.fixup.md"
assert_contains "$FIXUP" '§4.2 timing claim — unconfirmed'
if /usr/bin/grep -q '§4.1 branch observation' "$FIXUP"; then fail "confirmed independent finding leaked into fix-up"; fi
python3 - "$CALLS" <<'PY' || fail "close producer prompt omitted the one-claim/one-verdict protocol"
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8') if line.strip()]
prompt = next(r['argv'][-1] for r in rows if r['stage'] == 'close')
assert 'Each finding states exactly one criterion or claim and exactly one verdict' in prompt
assert 'never combine a confirmed observation with an unconfirmed claim' in prompt
PY

# A finding that combines conflicting verdicts is ambiguous and cannot authorize fix-up.
BRIEF="$(make_brief testsub findings-ambiguous.md draft)"
FAKE_CLAUDE="close=FAIL-mixed-verdict"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 20 ] || fail "mixed-verdict finding expected run failure, got $RC: $OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF 'a failing finding must contain exactly one verdict' || fail "no conservative ambiguous-finding refusal: $OUT"
[ "$(resumes)" -eq 1 ] || fail "ambiguous finding triggered a fix-up"
assert_no_file "${BRIEF%.md}.fixup.md"

# Preserve the archived mixed observation/claim refusal: one free-text finding may not
# turn an unconfirmed timing claim into a fixable §4 item by borrowing a confirmed label.
BRIEF="$(make_brief testsub findings-archived-mix.md draft)"
FAKE_CLAUDE="close=FAIL-archived-mix"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 20 ] || fail "combined finding expected run failure, got $RC: $OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF 'a failing finding is not on a §4 item' || fail "combined finding was not conservatively refused: $OUT"
[ "$(resumes)" -eq 1 ] || fail "combined finding triggered a fix-up"
assert_no_file "${BRIEF%.md}.fixup.md"

# Preserve refusal for an unmapped honesty/security failure; narrowing the parser must not erase it.
BRIEF="$(make_brief testsub findings-unmapped.md draft)"
FAKE_CLAUDE="close=FAIL-unmapped"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 20 ] || fail "unmapped finding expected run failure, got $RC: $OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF 'a failing finding is not on a §4 item' || fail "unmapped failure was not refused: $OUT"
[ "$(resumes)" -eq 1 ] || fail "unmapped finding triggered a fix-up"
assert_no_file "${BRIEF%.md}.fixup.md"

echo ok