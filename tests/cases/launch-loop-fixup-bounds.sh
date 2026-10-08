#!/usr/bin/env bash
# The fix-up's bounds: a second fixable FAIL breaks (one fix-up per run), a failing
# finding with no §4 label never gets one, and a resume that ends without a report
# leaves the brief at running, where a dead run leaves it — the run's own older report
# in the same transcript is not taken for the resume's. A bullet that says refuted or
# unconfirmed anywhere counts as failing, so an unlabelled one blocks the fix-up.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

CALLS="$SANDBOX/state/calls.log"
resumes() { python3 -c 'import json, sys; print(sum(1 for l in open(sys.argv[1]) if json.loads(l)["stage"] == "resume" and json.loads(l)["brief"] == sys.argv[2]))' "$CALLS" "$1"; }

# 1. fixable twice: one resume, the second close goes to the debrief, the run check fails
BRIEF="$(make_brief testsub fx2.md draft)"
FAKE_CLAUDE="close=FAIL-fixable"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 20 ] || fail "twice: expected exit 20, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF 'RUN: failed — close audit VERDICT: FAIL' || fail "twice: no RUN line. Output:
$OUT"
[ "$(resumes fx2)" = 1 ] || fail "twice: expected 1 resume, got $(resumes fx2)"
# relaunched from reported (a retried close, a human resume): the run has had its fix-up
/usr/bin/sed -i 's/^handoff: .*/handoff: reported/' "$BRIEF"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 20 ] || fail "relaunch: expected exit 20, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF 'fix-up: no — this run has had its one fix-up' || fail "relaunch: no guard line. Output:
$OUT"
[ "$(resumes fx2)" = 1 ] || fail "relaunch: expected still 1 resume, got $(resumes fx2)"

# 2. a failing finding with no §4 label: no fix-up at all
BRIEF="$(make_brief testsub fx3.md draft)"
FAKE_CLAUDE="close=FAIL-unprefixed"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 20 ] || fail "unprefixed: expected exit 20, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF 'fix-up: no — a failing finding is not on a §4 item: - the PR description — refuted — fake evidence' \
  || fail "unprefixed: no reason line. Output:
$OUT"
[ "$(resumes fx3)" = 0 ] || fail "unprefixed: expected no resume, got $(resumes fx3)"
assert_no_file "${BRIEF%.md}.fixup.md"

# 3. the resume ends without a report: launcher error, brief left at running
BRIEF="$(make_brief testsub fx4.md draft)"
FAKE_CLAUDE="close=FAIL-fixable,resume=no-report"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 30 ] || fail "dead: expected exit 30, got $RC. Output:
$OUT"
[ "$(state_of "$BRIEF")" = running ] || fail "dead: expected running, got '$(state_of "$BRIEF")'"
printf '%s\n' "$OUT" | /usr/bin/grep -qF 'WARNING: no === COMPLETION REPORT === block found in stdout or in the transcript.' \
  || fail "dead: the run's older report was taken for the resume's. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF 'fix-up resume exited 1 — brief left at handoff: running; the first attempt is kept in fx4.report-1.md and fx4.close-1.md' \
  || fail "dead: no die line. Output:
$OUT"
cmp -s "${BRIEF%.md}.report.md" "${BRIEF%.md}.report-1.md" || fail "dead: the report changed"

# 4. a labelled refutation beside an unlabelled, single-dash one: still no fix-up
BRIEF="$(make_brief testsub fx5.md draft)"
FAKE_CLAUDE="close=FAIL-mixed"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 20 ] || fail "mixed: expected exit 20, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF 'fix-up: no — a failing finding is not on a §4 item: - the report — refuted. fake evidence' \
  || fail "mixed: no reason line. Output:
$OUT"
[ "$(resumes fx5)" = 0 ] || fail "mixed: expected no resume, got $(resumes fx5)"
assert_no_file "${BRIEF%.md}.fixup.md"

echo ok
