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
is_awaiting_merge() { /usr/bin/grep -q '^orchestration: awaiting-merge' "$PLAN" 2>/dev/null; }
wait_for 90 is_awaiting_merge || fail "auto-policy plan did not await merge: $(head -1 "${PLAN%.md}.status.md" 2>/dev/null)"
[ "$(state_of "$ORCH_A")" = closed ] && [ "$(state_of "$ORCH_B")" = closed ] || fail "auto-policy plan did not close both briefs"
[ "$(count_final)" -eq 3 ] || fail "auto policy did not invoke one final reviewer"
pass_line="$(/usr/bin/grep -n 'FINAL REVIEW PASS' "$EVENTS" | cut -d: -f1)"
closed_lines="$(/usr/bin/grep -n 'BRIEF CLOSED' "$EVENTS" | cut -d: -f1 | tail -2)"
[ -n "$pass_line" ] && [ "$(printf '%s\n' "$closed_lines" | wc -l)" -eq 2 ] || fail "missing close/review events"
last_closed="$(printf '%s\n' "$closed_lines" | tail -1)"
[ "$pass_line" -gt "$last_closed" ] || fail "final review was logged before both BRIEF CLOSED events"
assert_file "${PLAN%.md}.final-review.json"

# Complete the held checkout through the read-only merge verification before the
# partial-phase scenario reuses this sandbox repository.
git -C "$SANDBOX/repo_under.test" remote set-url origin https://github.com/test/repo
cat >"$SANDBOX/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = api ]; then
  printf '[{"number":1,"state":"closed","merged":true,"merge_commit_sha":"4444444444444444444444444444444444444444","head":{"sha":"%s","ref":"feat/test","repo":{"full_name":"test/repo"}},"base":{"ref":"main","repo":{"full_name":"test/repo"}}}]\n' "$FAKE_MERGE_SHA"
  exit 0
fi
exit 0
GH
chmod +x "$SANDBOX/bin/gh"
merge_orch() {
  _sbx_env
  local reviewed
  reviewed="$(/usr/bin/grep -m1 '^final-reviewed-head:' "$PLAN" | cut -d: -f2- | tr -d ' ')"
  env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com FAKE_MERGE_SHA="$reviewed" \
    bash "$SANDBOX/kit/handoff-orchestrate.sh" resume "$PLAN" --backend claude --publication-owner supervisor
}
OUT="$(merge_orch 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "final-review plan did not complete via merge verification: $OUT"
/usr/bin/grep -q '^orchestration: done' "$PLAN" || fail "verified merge did not release final-review plan"

# An auto-policy plan cannot review after only its first phase has completed.
PARTIAL_A="$(make_brief testsub partial-a.md draft)"
PARTIAL_B="$(make_brief testsub partial-b.md draft)"
PARTIAL_PLAN="$(dirname "$PARTIAL_A")/partial-plan.md"
make_plan "$PARTIAL_PLAN" "$PARTIAL_A" "$PARTIAL_B"
python3 - "$PARTIAL_PLAN" <<'PY'
import sys
p=sys.argv[1]
s=open(p, encoding='utf-8').read().replace('  - name: phase one\n    briefs: [partial-a.md, partial-b.md]\n    status: pending', '  - name: phase one\n    briefs: [partial-a.md]\n    status: pending\n  - name: phase two\n    briefs: [partial-b.md]\n    status: pending')
s=s.replace('| 1 | test | partial-a.md, partial-b.md | last phase |', '| 1 | test | partial-a.md | next phase |\n| 2 | test | partial-b.md | last phase |')
open(p, 'w', encoding='utf-8').write(s)
PY
FAKE_CLAUDE="run=complete"
orch start "$PARTIAL_PLAN" --backend claude >/dev/null 2>&1
partial_wait() { /usr/bin/grep -q '^orchestration: phase-done' "$PARTIAL_PLAN" 2>/dev/null; }
wait_for 90 partial_wait || fail "phase one did not finish in two-phase plan"
[ "$(state_of "$PARTIAL_A")" = closed ] || fail "phase one did not complete"
[ "$(count_final)" -eq 3 ] || fail "final review ran after phase one but before phase two completed"

MANUAL_BRIEF="$(make_brief testsub manual-brief.md draft)"
MANUAL_PLAN="$(dirname "$ORCH_A")/manual-plan.md"
make_plan "$MANUAL_PLAN" "$MANUAL_BRIEF"
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$SANDBOX/repo_under.test" false >/dev/null
orch start "$MANUAL_PLAN" --backend claude >/dev/null 2>&1
manual_done() { /usr/bin/grep -q '^orchestration: done' "$MANUAL_PLAN" 2>/dev/null; }
wait_for 90 manual_done || fail "manual-policy plan did not complete"
[ "$(count_final)" -eq 3 ] || fail "manual policy invoked final reviewer"
assert_no_file "${MANUAL_PLAN%.md}.final-review.json"

# A failed second brief run is not a completed phase and must not be reviewed.
FAILED_A="$(make_brief testsub failed-a.md draft)"
FAILED_B="$(make_brief testsub failed-b.md draft)"
FAILED_PLAN="$(dirname "$FAILED_A")/failed-plan.md"
make_plan "$FAILED_PLAN" "$FAILED_A" "$FAILED_B"
FAKE_CLAUDE="run=complete,run@failed-b=no-report"
orch start "$FAILED_PLAN" --backend claude >/dev/null 2>&1
failed_phase_wait() { /usr/bin/grep -q '^NEEDS YOU · broken at failed-b · run:' "${FAILED_PLAN%.md}.status.md" 2>/dev/null; }
wait_for 90 failed_phase_wait || fail "first brief did not close before second brief run failed"
[ "$(state_of "$FAILED_A")" = closed ] && [ "$(state_of "$FAILED_B")" = running ] || fail "second brief did not fail after the first closed"
[ "$(count_final)" -eq 3 ] || fail "final review ran after failed second-phase run"
unset FAKE_CLAUDE

echo ok
