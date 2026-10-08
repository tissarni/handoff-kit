#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BAD="$(make_brief testsub rbc-bad.md draft)"
printf 'Notes live in the vault.\n' >>"$BAD"
CHECK="${BAD%.md}.check.md"
EXP="1 FAIL · 0 WARN · first: sweep §- 24 — matched 'vault'"
CALLS="$SANDBOX/state/calls.log"

# 1. single-stage review: a sweep FAIL exits 12 before any session
OUT="$(launch review "$BAD" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 12 ] || fail "expected exit 12, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF "BRIEF-CHECK: $EXP" || fail "missing 'BRIEF-CHECK: $EXP'. Output:
$OUT"
head -1 "$CHECK" | /usr/bin/grep -qE '^# brief-check · rbc-bad.md · revision r1 · .* · exit 1$' || fail "bad report header: $(head -1 "$CHECK")"
assert_contains "$CHECK" 'RESULT 1 FAIL · 0 WARN'

# 2. loop: the stop is a gate hold, the brief stays draft, nothing is spent
OUT="$(launch loop "$BAD" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 10 ] || fail "expected loop exit 10, got $RC. Output:
$OUT"
FIRSTGATE="$(printf '%s\n' "$OUT" | /usr/bin/grep -m1 '^GATE: ' || true)"
[ "$FIRSTGATE" = "GATE: brief-check — $EXP" ] || fail "unexpected GATE line: $FIRSTGATE"
[ "$(state_of "$BAD")" = draft ] || fail "expected brief draft, got '$(state_of "$BAD")'"
[ ! -e "${BAD%.md}.review.md" ] || fail "a review file exists after a brief-check stop"
[ ! -s "$CALLS" ] || fail "a session was launched. calls.log:
$(cat "$CALLS")"

# 3. dry-run: runs the check, writes no report, stops nothing
OUT="$(launch review "$BAD" --dry-run --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "expected dry-run exit 0, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF "  brief-check: RESULT 1 FAIL · 0 WARN (exit 1) — a FAIL stops the review before its session; report -> $CHECK" || fail "missing dry-run brief-check line. Output:
$OUT"
DRY="$(make_brief testsub rbc-dry.md draft)"
OUT="$(launch review "$DRY" --dry-run --backend claude 2>&1)" || fail "dry-run of rbc-dry failed. Output:
$OUT"
[ ! -e "${DRY%.md}.check.md" ] || fail "dry-run wrote a .check.md"

# 4. clean brief: reviewed, report says 0 FAIL
[ ! -s "$CALLS" ] || fail "calls.log not empty before step 4"
GOOD="$(make_brief testsub rbc-good.md draft)"
OUT="$(launch review "$GOOD" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "clean review exit $RC. Output:
$OUT"
assert_contains "${GOOD%.md}.check.md" 'RESULT 0 FAIL · 0 WARN'
[ "$(state_of "$GOOD")" = reviewed ] || fail "expected rbc-good reviewed, got '$(state_of "$GOOD")'"

# 5. a crash fails open
printf '#!/usr/bin/env bash\necho "Traceback (most recent call last):" >&2\nexit 1\n' >"$SANDBOX/kit/brief-check.sh"
CRASH="$(make_brief testsub rbc-crash.md draft)"
OUT="$(launch review "$CRASH" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "crash review exit $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF "WARNING: brief-check exited 1 — reviewing anyway. Report: ${CRASH%.md}.check.md" || fail "missing crash WARNING. Output:
$OUT"
[ "$(state_of "$CRASH")" = reviewed ] || fail "expected rbc-crash reviewed"

# 6. a missing script fails open
rm -f "$SANDBOX/kit/brief-check.sh"
OPEN="$(make_brief testsub rbc-open.md draft)"
OUT="$(launch review "$OPEN" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "missing-script review exit $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF "WARNING: brief-check exited 127 — reviewing anyway. Report: ${OPEN%.md}.check.md" || fail "missing 127 WARNING. Output:
$OUT"
[ "$(state_of "$OPEN")" = reviewed ] || fail "expected rbc-open reviewed"

echo ok
