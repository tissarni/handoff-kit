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
if OUT="$(orch start "$PLAN" --backend claude --publication-owner forged 2>&1)"; then
  fail "orchestrator accepted an invalid publication owner"
fi
[ ! -f "$STATUS" ] || fail "invalid publication owner wrote plan status"
[ ! -f "$SANDBOX/state/calls.log" ] || fail "invalid publication owner launched a stage"
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

echo ok