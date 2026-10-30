#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub auto-merge.md draft)"
BRIEF_TWO="$(make_brief testsub second-brief.md draft)"
PLAN="$(dirname "$BRIEF")/auto-merge-plan.md"
make_plan "$PLAN" "$BRIEF" "$BRIEF_TWO"
python3 - "$PLAN" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('updated: 2026-01-01', 'updated: 2026-01-01\nrevision: r1', 1)
open(p,'w').write(s)
PY
mkdir -p "$SANDBOX/home/.config/handoff"
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" \
  python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$SANDBOX/repo_under.test" true >/dev/null
python3 - "$SANDBOX/home/.config/handoff/project-policy.json" "$PLAN" "$SANDBOX/repo_under.test" <<'PY'
import json,sys,pathlib
p,plan,repo=sys.argv[1:]
d=json.load(open(p)); entry=d['repositories'][repo]
entry['assessments']=[{'task':str(pathlib.Path(plan).resolve()),'revision':'r1','risk':'ordinary','reason':'test'}]
open(p,'w').write(json.dumps(d))
PY

# The shared forge fake records calls and returns verified merge and base state.
cat >"$SANDBOX/bin/gh" <<'GH'
#!/usr/bin/env python3
import json, os, pathlib, sys
root=pathlib.Path(os.environ['HOME']).parent/'state'; state=root/'forge.json'; log=root/'gh.log'
d=json.loads(state.read_text()) if state.exists() else {}
a=sys.argv[1:]; endpoint=next((x for x in a if x.startswith('repos/')), '')
method=a[a.index('-X')+1] if '-X' in a else 'GET'
log.open('a').write(method+' '+endpoint+'\n')
head=d['head']; base=d['base']
if endpoint.startswith('repos/test/repo/pulls?state=all&head=test:feat/test'):
 merged=bool(d.get('merged'))
 print(json.dumps([{'number':7,'state':'closed' if merged else 'open','merged_at':'2026-01-01T00:00:00Z' if merged else None,'merge_commit_sha':'c'*40 if merged else None,'head':{'ref':'feat/test','sha':head,'repo':{'full_name':'test/repo'}},'base':{'ref':'main','sha':base,'repo':{'full_name':'test/repo'}}}]))
elif endpoint.endswith('/pulls/7/merge') and method=='PUT':
 d['puts']=d.get('puts',0)+1; d['merged']=not bool(d.get('put_error')); state.write_text(json.dumps(d))
 if d.get('put_error'): print('HTTP 500',file=sys.stderr); sys.exit(1)
 print('{"merged":true}')
elif endpoint.endswith('/pulls/7'):
 print(json.dumps({'number':7,'node_id':'PR_node','body':'## Feature\nfeature\n## Acceptance\naccept\n## Final review\n'+head+'\n## CI\nci\n## Limitations\nnone','state':'closed' if d.get('merged') else 'open','draft':False,'merged':bool(d.get('merged')),'merge_commit_sha':'c'*40 if d.get('merged') else None,'mergeable_state':'clean','base':{'ref':'main','sha':base,'repo':{'full_name':'test/repo'}},'head':{'ref':'feat/test','sha':head,'repo':{'full_name':'test/repo'}}}))
elif endpoint.endswith('/protection/required_status_checks'): print('{"contexts":["ci"],"checks":[]}')
elif endpoint.endswith('/commits/'+head+'/status'): print('{"state":"success","statuses":[]}')
elif '/check-runs' in endpoint:
 conclusion='failure' if d.get('fail_check') else 'success'
 print(json.dumps({'total_count':1,'check_runs':[{'name':'ci','status':'completed','conclusion':conclusion,'started_at':'2026-01-01T00:00:00Z','id':1}]}))
elif endpoint.endswith('/git/ref/heads/feat/test'):
 if d.get('deleted'): print('HTTP 404',file=sys.stderr); sys.exit(1)
 print(json.dumps({'object':{'sha':head}}))
elif '/git/refs/heads/feat/test' in endpoint and method=='DELETE':
 d['deletes']=d.get('deletes',0)+1
 if d.get('delete_error'): print('HTTP 500',file=sys.stderr); sys.exit(1)
 d['deleted']=True; state.write_text(json.dumps(d)); sys.exit(0)
elif endpoint.endswith('/git/ref/heads/main'): print(json.dumps({'object':{'sha':'c'*40}}))
elif '/compare/' in endpoint: print('{"status":"identical"}')
else: print('unexpected '+method+' '+endpoint,file=sys.stderr); sys.exit(8)
GH
chmod +x "$SANDBOX/bin/gh"
git -C "$SANDBOX/repo_under.test" remote set-url origin https://github.com/test/repo
git -C "$SANDBOX/repo_under.test" checkout -q -b feat/test
FAKE_HEAD="$(git -C "$SANDBOX/repo_under.test" rev-parse HEAD)"
FAKE_BASE="$(git -C "$SANDBOX/repo_under.test" rev-parse HEAD)"
python3 - "$SANDBOX/state/forge.json" "$FAKE_HEAD" "$FAKE_BASE" <<'PY'
import json,sys
open(sys.argv[1],'w').write(json.dumps({'head':sys.argv[2],'base':sys.argv[3]}))
PY

_sbx_env
# The finalize path requires the same explicit host credentials as direct callers.
env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com \
  bash "$SANDBOX/kit/handoff-orchestrate.sh" start "$PLAN" --backend claude --publication-owner supervisor >/dev/null 2>&1
is_done() { /usr/bin/grep -q '^orchestration: done' "$PLAN" 2>/dev/null; }
wait_for 120 is_done || fail "auto merge did not finish: $(head -1 "${PLAN%.md}.status.md" 2>/dev/null)"
EVENTS="${PLAN%.md}.events.log"
assert_contains "$EVENTS" "MERGED ccccccc into main — verified"
assert_contains "$EVENTS" 'branch cleaned'
assert_eq "$(/usr/bin/grep -c 'BRIEF CLOSED' "$EVENTS")" 2 "closed brief count"
close_lines="$(/usr/bin/grep -n 'BRIEF CLOSED' "$EVENTS" | cut -d: -f1 | tr '\n' ' ')"
review_line="$(/usr/bin/grep -n 'FINAL REVIEW PASS' "$EVENTS" | cut -d: -f1)"
merge_line="$(/usr/bin/grep -n 'MERGED ccccccc into main — verified' "$EVENTS" | cut -d: -f1)"
set -- $close_lines
[ "$1" -lt "$2" ] && [ "$2" -lt "$review_line" ] && [ "$review_line" -lt "$merge_line" ] || fail "event order was wrong: $close_lines $review_line $merge_line"
assert_eq "$(/usr/bin/grep -c '^PUT repos/' "$SANDBOX/state/gh.log")" 1 "merge PUT count"
[ ! -f "$(git -C "$SANDBOX/repo_under.test" rev-parse --absolute-git-dir)/handoff-plan.lock" ] || fail "checkout lock was not released"

SECOND_BRIEF="$(make_brief testsub second-plan.md draft)"
SECOND_PLAN="$(dirname "$SECOND_BRIEF")/second-auto-plan.md"
make_plan "$SECOND_PLAN" "$SECOND_BRIEF"
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" \
  python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$SANDBOX/repo_under.test" false >/dev/null
orch start "$SECOND_PLAN" --backend claude --publication-owner supervisor >/dev/null 2>&1
second_done() { /usr/bin/grep -q '^orchestration: done' "$SECOND_PLAN" 2>/dev/null; }
wait_for 90 second_done || fail "second plan could not start after checkout lock release"

scenario_plan() {
  local name="$1" mode="${2:-}" brief plan
  brief="$(make_brief testsub "$name.md" draft)"
  plan="$(dirname "$brief")/$name-plan.md"
  make_plan "$plan" "$brief"
  python3 - "$plan" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('updated: 2026-01-01', 'updated: 2026-01-01\nrevision: r1', 1); open(p,'w').write(s)
PY
  env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$SANDBOX/repo_under.test" true >/dev/null
  python3 - "$SANDBOX/home/.config/handoff/project-policy.json" "$plan" "$SANDBOX/repo_under.test" <<'PY'
import json,sys,pathlib
p,plan,repo=sys.argv[1:]; d=json.load(open(p)); d['repositories'][repo]['assessments']=[{'task':str(pathlib.Path(plan).resolve()),'revision':'r1','risk':'ordinary','reason':'test'}]; open(p,'w').write(json.dumps(d))
PY
  python3 - "$SANDBOX/state/forge.json" "$FAKE_HEAD" "$FAKE_BASE" "$mode" <<'PY'
import json,sys
state={'head':sys.argv[2],'base':sys.argv[3]}
if sys.argv[4]=='already': state.update(merged=True,deleted=True)
elif sys.argv[4]=='failing-check': state['fail_check']=True
elif sys.argv[4]=='ambiguous': state['put_error']=True
elif sys.argv[4]=='cleanup-failure': state['delete_error']=True
open(sys.argv[1],'w').write(json.dumps(state))
PY
  if [ "$mode" = failing-check ] || [ "$mode" = ambiguous ] || [ "$mode" = cleanup-failure ]; then
    python3 - "$SANDBOX/state/forge.json" "$mode" <<'PY' || { echo "FAIL: scenario state was not ready before orchestration started"; return 1; }
import json,sys
key={'failing-check':'fail_check','ambiguous':'put_error','cleanup-failure':'delete_error'}[sys.argv[2]]
assert json.load(open(sys.argv[1])).get(key) is True
PY
  fi
  if [ "$mode" = malformed ]; then
    cp "$SANDBOX/kit/handoff-merge.py" "$SANDBOX/kit/handoff-merge-real.py"
    cat >"$SANDBOX/kit/handoff-merge.py" <<'PY'
#!/usr/bin/env python3
import pathlib,runpy,sys
if len(sys.argv)>1 and sys.argv[1]=='policy-get': print('auto'); raise SystemExit(0)
if len(sys.argv)>1 and sys.argv[1]=='finalize':
 print('merged and verified')
 print('branch-cleanup: deleted')
 raise SystemExit(0)
sys.argv[0]=str(pathlib.Path(__file__).with_name('handoff-merge-real.py'))
runpy.run_path(sys.argv[0],run_name='__main__')
PY
    chmod +x "$SANDBOX/kit/handoff-merge.py"
  fi
  : >"$SANDBOX/state/gh.log"
  _sbx_env
  env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com bash "$SANDBOX/kit/handoff-orchestrate.sh" start "$plan" --backend claude --publication-owner supervisor >/dev/null 2>&1
  printf '%s' "$plan"
}
event_seen() { /usr/bin/grep -qF -- "$2" "$1" 2>/dev/null; }

FAIL_CHECK_PLAN="$(scenario_plan failing-check failing-check)" || fail "failing-check scenario state was not ready before orchestration started"
check_held() { /usr/bin/grep -q '^orchestration: awaiting-merge' "$FAIL_CHECK_PLAN" 2>/dev/null; }
wait_for 90 check_held || fail "failing required check did not hold for merge"
wait_for 10 event_seen "${FAIL_CHECK_PLAN%.md}.events.log" 'auto-merge refused' || fail "failing-check event was not recorded"
assert_contains "${FAIL_CHECK_PLAN%.md}.events.log" 'auto-merge refused'
if /usr/bin/grep -E '^(POST graphql|PUT |DELETE )' "$SANDBOX/state/gh.log" >/dev/null; then fail "failing required check caused a forge mutation"; fi
python3 - "$SANDBOX/state/forge.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['merged']=True; open(p,'w').write(json.dumps(d))
PY
_sbx_env
env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com bash "$SANDBOX/kit/handoff-orchestrate.sh" resume "$FAIL_CHECK_PLAN" --backend claude --publication-owner supervisor >/dev/null 2>&1
/usr/bin/grep -q '^orchestration: done' "$FAIL_CHECK_PLAN" || fail "human merge did not resume to done"
assert_contains "${FAIL_CHECK_PLAN%.md}.events.log" 'MERGE VERIFIED'
if /usr/bin/grep -E '^PUT ' "$SANDBOX/state/gh.log" >/dev/null; then fail "resume retried the merge PUT"; fi

AMBIGUOUS_PLAN="$(scenario_plan ambiguous-merge ambiguous)" || fail "ambiguous-merge scenario state was not ready before orchestration started"
ambiguous_held() { /usr/bin/grep -q '^orchestration: awaiting-merge' "$AMBIGUOUS_PLAN" 2>/dev/null; }
wait_for 90 ambiguous_held || fail "ambiguous merge did not hold for verification"
wait_for 10 event_seen "${AMBIGUOUS_PLAN%.md}.events.log" 'merge outcome ambiguous — verify before resuming' || fail "ambiguous-merge event was not recorded"
assert_contains "${AMBIGUOUS_PLAN%.md}.events.log" 'merge outcome ambiguous — verify before resuming'
assert_eq "$(/usr/bin/grep -c '^PUT ' "$SANDBOX/state/gh.log")" 1 "ambiguous merge PUT count"
_sbx_env
OUT="$(env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com bash "$SANDBOX/kit/handoff-orchestrate.sh" resume "$AMBIGUOUS_PLAN" --backend claude --publication-owner supervisor 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || fail "unmerged ambiguous result was not held on resume"
assert_eq "$(/usr/bin/grep -c '^PUT ' "$SANDBOX/state/gh.log")" 1 "resume merge PUT count"
python3 - "$SANDBOX/state/forge.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['merged']=True; open(p,'w').write(json.dumps(d))
PY
_sbx_env
env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com bash "$SANDBOX/kit/handoff-orchestrate.sh" resume "$AMBIGUOUS_PLAN" --backend claude --publication-owner supervisor >/dev/null 2>&1

CLEANUP_PLAN="$(scenario_plan cleanup-failure cleanup-failure)" || fail "cleanup-failure scenario state was not ready before orchestration started"
cleanup_done() { /usr/bin/grep -q '^orchestration: done' "$CLEANUP_PLAN" 2>/dev/null; }
wait_for 90 cleanup_done || fail "cleanup failure did not complete merged plan"
wait_for 10 event_seen "${CLEANUP_PLAN%.md}.events.log" 'cleanup failed' || fail "cleanup-failure event was not recorded"
assert_contains "${CLEANUP_PLAN%.md}.events.log" 'MERGED ccccccc into main — verified'
assert_contains "${CLEANUP_PLAN%.md}.events.log" 'cleanup failed'
assert_contains "${CLEANUP_PLAN%.md}.events.log" 'feat/test'

ALREADY_PLAN="$(scenario_plan already-absent already)"
already_done() { /usr/bin/grep -q '^orchestration: done' "$ALREADY_PLAN" 2>/dev/null; }
wait_for 90 already_done || fail "already-merged plan did not complete"
assert_contains "${ALREADY_PLAN%.md}.events.log" 'branch cleaned (already deleted)'
if /usr/bin/grep -E '^(PUT |DELETE )' "$SANDBOX/state/gh.log" >/dev/null; then fail "already-merged reconciliation sent a merge or delete call"; fi

FAKE_CLAUDE=final-review=blockers
export FAKE_CLAUDE
FAILED_REVIEW_PLAN="$(scenario_plan failed-review)"
failed_review_broken() { /usr/bin/grep -q '^orchestration: broken' "$FAILED_REVIEW_PLAN" 2>/dev/null; }
wait_for 90 failed_review_broken || fail "failed final review did not break the phase"
if /usr/bin/grep -E '^(POST graphql|PUT |DELETE )' "$SANDBOX/state/gh.log" >/dev/null; then fail "failed final review caused a forge mutation"; fi
rm -f "$(git -C "$SANDBOX/repo_under.test" rev-parse --absolute-git-dir)/handoff-plan.lock"
unset FAKE_CLAUDE

FAKE_CLAUDE=run=no-report
export FAKE_CLAUDE
FAILED_BRIEF_PLAN="$(scenario_plan failed-brief)"
failed_brief_broken() { /usr/bin/grep -q '^orchestration: broken' "$FAILED_BRIEF_PLAN" 2>/dev/null; }
wait_for 90 failed_brief_broken || fail "failed brief did not break the phase"
if /usr/bin/grep -E '^(POST graphql|PUT |DELETE )' "$SANDBOX/state/gh.log" >/dev/null; then fail "failed brief caused a forge mutation"; fi
rm -f "$(git -C "$SANDBOX/repo_under.test" rev-parse --absolute-git-dir)/handoff-plan.lock"
unset FAKE_CLAUDE

PHASE_ONE="$(make_brief testsub phase-one.md draft)"
PHASE_TWO="$(make_brief testsub phase-two.md draft)"
PHASE_PLAN="$(dirname "$PHASE_ONE")/intermediate-phase-plan.md"
make_plan "$PHASE_PLAN" "$PHASE_ONE" "$PHASE_TWO"
python3 - "$PHASE_PLAN" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('updated: 2026-01-01', 'updated: 2026-01-01\nrevision: r1', 1)
s=s.replace('  - name: phase one\n    briefs: [phase-one.md, phase-two.md]\n    status: pending', '  - name: phase one\n    briefs: [phase-one.md]\n    status: pending\n  - name: phase two\n    briefs: [phase-two.md]\n    status: pending')
open(p,'w').write(s)
PY
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$SANDBOX/repo_under.test" true >/dev/null
python3 - "$SANDBOX/home/.config/handoff/project-policy.json" "$PHASE_PLAN" "$SANDBOX/repo_under.test" <<'PY'
import json,sys,pathlib
p,plan,repo=sys.argv[1:]; d=json.load(open(p)); d['repositories'][repo]['assessments']=[{'task':str(pathlib.Path(plan).resolve()),'revision':'r1','risk':'ordinary','reason':'test'}]; open(p,'w').write(json.dumps(d))
PY
python3 - "$SANDBOX/state/forge.json" "$FAKE_HEAD" "$FAKE_BASE" <<'PY'
import json,sys
open(sys.argv[1],'w').write(json.dumps({'head':sys.argv[2],'base':sys.argv[3]}))
PY
FAKE_CLAUDE=run@phase-two=wait
export FAKE_CLAUDE
_sbx_env
env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com bash "$SANDBOX/kit/handoff-orchestrate.sh" start "$PHASE_PLAN" --backend claude --publication-owner supervisor >/dev/null 2>&1
phase_one_done() { /usr/bin/grep -q 'PHASE DONE 1' "${PHASE_PLAN%.md}.events.log" 2>/dev/null; }
wait_for 120 phase_one_done || fail "intermediate phase did not finish"
if /usr/bin/grep -E '^(POST graphql|PUT |DELETE )' "$SANDBOX/state/gh.log" >/dev/null; then fail "intermediate phase attempted a merge"; fi
unset FAKE_CLAUDE

MALFORMED_PLAN="$(scenario_plan malformed-report malformed)"
malformed_held() { /usr/bin/grep -q '^orchestration: awaiting-merge' "$MALFORMED_PLAN" 2>/dev/null; }
wait_for 90 malformed_held || fail "missing verified SHA did not hold for manual verification"
assert_contains "${MALFORMED_PLAN%.md}.events.log" 'merge outcome ambiguous — verify before resuming'
if /usr/bin/grep '^PUT ' "$SANDBOX/state/gh.log" >/dev/null; then fail "missing SHA output logged or sent a merge"; fi

echo ok
