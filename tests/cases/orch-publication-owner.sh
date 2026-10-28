#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub supervisor-brief.md draft)"
PLAN="$(dirname "$BRIEF")/supervisor-plan.md"
make_plan "$PLAN" "$BRIEF"
STATUS="${PLAN%.md}.status.md"
EVENTS="${PLAN%.md}.events.log"

FAKE_CLAUDE="review=RUN,run=complete"
for kind in equals separate trailing-equals trailing-separate forged; do
  case "$kind" in
    equals) args=(--publication-owner=) ;;
    separate) args=(--publication-owner '') ;;
    trailing-equals) args=(--publication-owner supervisor --publication-owner=) ;;
    trailing-separate) args=(--publication-owner supervisor --publication-owner '') ;;
    forged) args=(--publication-owner forged) ;;
  esac
  if OUT="$(orch start "$PLAN" --backend claude "${args[@]}" 2>&1)"; then
    fail "orchestrator accepted invalid publication owner ($kind)"
  fi
  [ ! -f "$STATUS" ] || fail "invalid publication owner wrote plan status ($kind)"
  [ ! -f "$EVENTS" ] || fail "invalid publication owner wrote plan events ($kind)"
  [ ! -f "$SANDBOX/state/calls.log" ] || fail "invalid publication owner launched a stage ($kind)"
  [ "$(git -C "$SANDBOX/repo_under.test" branch --show-current)" = main ] || fail "invalid publication owner moved the branch ($kind)"
  if git --git-dir="$SANDBOX/origin.git" show-ref --verify --quiet refs/heads/feat/test; then
    fail "invalid publication owner published a branch ($kind)"
  fi
  [ ! -f "$SANDBOX/state/gh.log" ] || fail "invalid publication owner wrote through gh ($kind)"
done
_sbx_env
OUT="$(env -i "${SBX_ENV[@]}" FAKE_CLAUDE="$FAKE_CLAUDE" bash "$SANDBOX/kit/handoff-launch.sh" loop "$BRIEF" --gate auto --backend claude --publication-owner supervisor --dry-run 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "owner loop dry-run failed: $OUT"
OUT="$(orch start "$PLAN" --backend claude --publication-owner supervisor 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "orchestrator start failed: $OUT"
is_done() { [ -f "$STATUS" ] && /usr/bin/grep -q '^DONE' "$STATUS"; }
wait_for 120 is_done || fail "supervisor-owned phase did not finish: $(head -1 "$STATUS" 2>/dev/null)"
assert_contains "$EVENTS" 'publication-owner=supervisor'
assert_contains "$EVENTS" 'PUBLICATION held for supervisor'
if git --git-dir="$SANDBOX/origin.git" show-ref --verify --quiet refs/heads/feat/test; then
  fail "supervisor-owned orchestration published its feature branch"
fi
if [ -f "$SANDBOX/state/gh.log" ] && /usr/bin/grep -qE 'pr create|api .*pulls' "$SANDBOX/state/gh.log"; then
  fail "supervisor-owned orchestration performed a forge PR write"
fi
python3 - "$SANDBOX/state/calls.log" <<'PY' || fail "orchestrated run prompt omitted local-only ownership"
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8') if line.strip()]
runs = [r for r in rows if r['stage'] == 'run']
assert len(runs) == 1, 'expected exactly one run stage'
prompt = runs[0]['argv'][-1]
assert 'Publication owner: supervisor' in prompt
assert 'LOCAL-ONLY' in prompt
assert 'git push origin <branch>' not in prompt
PY

# Recovery commands derive owner only from trusted orchestrator START/RESUME events.
# Exercise stop and a dead-driver watchdog tick without touching real watchdog services.
PLAN_BASE="${PLAN%.md}"
printf 'pid 999999999 started 0 never\n' >"$PLAN_BASE.lock"
OUT="$(orch stop "$PLAN" 2>&1)" || fail "supervisor stop failed: $OUT"
assert_contains "$STATUS" "handoff-orchestrate resume $PLAN --backend claude --publication-owner supervisor"
printf 'pid 999999999 started 0 never\n' >"$PLAN_BASE.lock"
OUT="$(orch tick "$PLAN" 2>&1)" || fail "supervisor watchdog tick failed: $OUT"
assert_contains "$STATUS" "handoff-orchestrate resume $PLAN --backend claude --publication-owner supervisor"

# A supervisor-owned phase failure must print the same explicit local-only recovery.
BRIEF2="$(make_brief testsub supervisor-failure.md draft)"
PLAN2="$(dirname "$BRIEF2")/supervisor-failure-plan.md"
make_plan "$PLAN2" "$BRIEF2"
STATUS2="${PLAN2%.md}.status.md"
FAKE_CLAUDE="review=RUN,run=complete,close=FAIL,resume=complete"
OUT="$(orch start "$PLAN2" --backend claude --publication-owner supervisor 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "supervisor failure plan did not start: $OUT"
broken() { [ -f "$STATUS2" ] && /usr/bin/grep -q '^NEEDS YOU · broken at supervisor-failure · run:failed' "$STATUS2"; }
wait_for 120 broken || fail "supervisor failure did not reach broken recovery status: $(head -1 "$STATUS2" 2>/dev/null)"
assert_contains "$STATUS2" "handoff-orchestrate resume $PLAN2 --backend claude --publication-owner supervisor"
if git --git-dir="$SANDBOX/origin.git" show-ref --verify --quiet refs/heads/feat/test; then
  fail "supervisor-owned failure published its feature branch"
fi

echo ok
# End of case.