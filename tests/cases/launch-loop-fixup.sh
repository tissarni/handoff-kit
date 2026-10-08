#!/usr/bin/env bash
# A close FAIL classed fixable, on a §4 item only: the loop resumes the run's own session
# once with just that finding, closes again, and the second close passes. The first
# attempt is kept, every stage's session id is logged, and the resume's ledger line
# counts only its own turn.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub fx.md draft)"
B="${BRIEF%.md}"
FAKE_CLAUDE="close=FAIL-fixable-once"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"
[ "$(state_of "$BRIEF")" = closed ] || fail "expected closed, got '$(state_of "$BRIEF")'"
printf '%s\n' "$OUT" | /usr/bin/grep -qF "fix-up: the close FAILed on 1 §4 finding(s), classed fixable — resuming run session " \
  || fail "no fix-up line. Output:
$OUT"

/usr/bin/grep -qxF 'VERDICT: FAIL' "$B.close-1.md" || fail "close-1 is not the FAIL: $(cat "$B.close-1.md" 2>&1)"
/usr/bin/grep -qxF 'VERDICT: PASS' "$B.close.md" || fail "close is not the PASS: $(cat "$B.close.md" 2>&1)"
assert_file "$B.report-1.md"
assert_file "$B.done-when-1.md"
assert_contains "$B.fixup.md" '- §4.1 fake criterion — refuted — fake evidence: exit 1'

python3 - "$SANDBOX/state/calls.log" "$B.sessions.log" "$B.usage.log" "$B.fixup.md" <<'PY' || fail "see above"
import json, sys
calls_p, sessions_p, usage_p, fixup_p = sys.argv[1:5]
calls = [json.loads(l) for l in open(calls_p, encoding='utf-8')]
stages = [c['stage'] for c in calls]
want = ['review', 'revise', 'run', 'close', 'resume', 'close', 'debrief']
if stages != want:
    sys.exit(f'stages {stages}, want {want}')
run, resume = calls[2]['argv'], calls[4]['argv']
sid = run[run.index('--session-id') + 1]
if resume[resume.index('--resume') + 1] != sid or '--session-id' in resume:
    sys.exit(f'the resume does not continue the run session {sid}: {resume}')
if resume[-1] != open(fixup_p, encoding='utf-8').read().rstrip('\n'):
    sys.exit('the resume prompt is not the fix-up note')
rows = [l.split() for l in open(sessions_p, encoding='utf-8')]
if [r[1] for r in rows] != want:
    sys.exit(f'sessions.log modes {[r[1] for r in rows]}, want {want}')
if rows[2][2] != sid or rows[4][2] != sid or len({r[2] for r in rows}) != 6:
    sys.exit(f'sessions.log ids wrong: {rows}')
usage = [l for l in open(usage_p, encoding='utf-8').read().splitlines() if ' resume ' in l]
if usage != ['USAGE fx resume turns=1 in=3 cw=100 cr=200 out=20 cost=0.0007']:
    sys.exit(f'resume ledger line: {usage}')
PY

echo ok
