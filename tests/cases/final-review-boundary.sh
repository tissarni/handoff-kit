#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

count_final() {
  python3 - "$SANDBOX/state/calls.log" <<'PY'
import json, os, sys
p = sys.argv[1]
rows = [json.loads(line) for line in open(p, encoding='utf-8')] if os.path.exists(p) else []
print(sum(row.get('stage') == 'final-review' for row in rows))
PY
}

NOFLAG="$(make_brief testsub no-feature.md draft)"
OUT="$(launch loop "$NOFLAG" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "ordinary loop failed ($RC): $OUT"
[ "$(count_final)" -eq 0 ] || fail "loop without --feature-complete invoked final review"

PASS_BRIEF="$(make_brief testsub feature-pass.md draft)"
OUT="$(launch loop "$PASS_BRIEF" --gate auto --backend claude --feature-complete 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "feature-complete loop failed ($RC): $OUT"
[ "$(state_of "$PASS_BRIEF")" = closed ] || fail "PASS review changed closed brief state"
[ "$(count_final)" -eq 1 ] || fail "feature-complete loop did not invoke one final review"
assert_file "${PASS_BRIEF%.md}.final-review.json"

FAIL_BRIEF="$(make_brief testsub feature-fail.md draft)"
FAKE_CLAUDE=final-review=FAIL
OUT="$(launch loop "$FAIL_BRIEF" --gate auto --backend claude --feature-complete 2>&1)"; RC=$?
[ "$RC" -eq 1 ] || fail "FAIL review should return 1, got $RC: $OUT"
[ "$(state_of "$FAIL_BRIEF")" = closed ] || fail "FAIL review reopened the closed brief"
[ "$(count_final)" -eq 2 ] || fail "FAIL review did not add exactly one invocation"
printf '%s\n' "$OUT" | /usr/bin/grep -qF 'FINAL REVIEW FAIL' || fail "FAIL result missing from output: $OUT"
unset FAKE_CLAUDE

# Orchestrated auto policy reviews the whole plan only at its last-phase boundary,
# after both phase briefs have closed. Manual policy preserves the old no-review path.
ORCH_A="$(make_brief testsub orch-a.md draft)"
ORCH_B="$(make_brief testsub orch-b.md draft)"
PLAN="$(dirname "$ORCH_A")/orch-plan.md"
make_plan "$PLAN" "$ORCH_A" "$ORCH_B"
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$SANDBOX/repo_under.test" true >/dev/null
EVENTS="${PLAN%.md}.events.log"
orch start "$PLAN" --backend claude >/dev/null 2>&1
is_done() { /usr/bin/grep -q '^orchestration: done' "$PLAN" 2>/dev/null; }
wait_for 90 is_done || fail "auto-policy plan did not complete: $(head -1 "${PLAN%.md}.status.md" 2>/dev/null)"
[ "$(state_of "$ORCH_A")" = closed ] && [ "$(state_of "$ORCH_B")" = closed ] || fail "auto-policy plan did not close both briefs"
[ "$(count_final)" -eq 3 ] || fail "auto policy did not invoke one final reviewer"
pass_line="$(/usr/bin/grep -n 'FINAL REVIEW PASS' "$EVENTS" | cut -d: -f1)"
closed_lines="$(/usr/bin/grep -n 'BRIEF CLOSED' "$EVENTS" | cut -d: -f1 | tail -2)"
[ -n "$pass_line" ] && [ "$(printf '%s\n' "$closed_lines" | wc -l)" -eq 2 ] || fail "missing close/review events"
last_closed="$(printf '%s\n' "$closed_lines" | tail -1)"
[ "$pass_line" -gt "$last_closed" ] || fail "final review was logged before both BRIEF CLOSED events"
assert_file "${PLAN%.md}.final-review.json"

MANUAL_BRIEF="$(make_brief testsub manual-brief.md draft)"
MANUAL_PLAN="$(dirname "$ORCH_A")/manual-plan.md"
make_plan "$MANUAL_PLAN" "$MANUAL_BRIEF"
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$SANDBOX/repo_under.test" false >/dev/null
orch start "$MANUAL_PLAN" --backend claude >/dev/null 2>&1
manual_done() { /usr/bin/grep -q '^orchestration: done' "$MANUAL_PLAN" 2>/dev/null; }
wait_for 90 manual_done || fail "manual-policy plan did not complete"
[ "$(count_final)" -eq 3 ] || fail "manual policy invoked final reviewer"
assert_no_file "${MANUAL_PLAN%.md}.final-review.json"

echo ok
