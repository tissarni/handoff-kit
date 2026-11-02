#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

# A two-state forge fixture: pending CI can resolve after a chosen number of finalize reads.
cat >"$SANDBOX/bin/gh" <<'GH'
#!/usr/bin/env python3
import json, os, pathlib, sys
root=pathlib.Path(os.environ['HOME']).parent/'state'; state_path=root/'forge.json'; log=root/'gh.log'
d=json.loads(state_path.read_text()); a=sys.argv[1:]
endpoint=next((x for x in a if x.startswith('repos/')), '')
method=a[a.index('-X')+1] if '-X' in a else 'GET'
log.open('a').write(method+' '+endpoint+'\n')
head=d['head']; base=d['base']
if endpoint.startswith('repos/test/repo/pulls?state=all&head=test:feat/test'):
 merged=bool(d.get('merged'))
 print(json.dumps([{'number':7,'state':'closed' if merged else 'open','merged_at':'2026-01-01T00:00:00Z' if merged else None,'merge_commit_sha':'c'*40 if merged else None,'head':{'ref':'feat/test','sha':head,'repo':{'full_name':'test/repo'}},'base':{'ref':'dev','sha':base,'repo':{'full_name':'test/repo'}}}]))
elif endpoint.endswith('/pulls/7/merge') and method=='PUT':
 d['merged']=True; state_path.write_text(json.dumps(d)); print('{"merged":true}')
elif endpoint.endswith('/pulls/7') and method=='PATCH':
 d['body']=next(x[5:] for x in a if x.startswith('body=')); state_path.write_text(json.dumps(d)); print('{}')
elif endpoint.endswith('/pulls/7'):
 merged=bool(d.get('merged'))
 print(json.dumps({'number':7,'node_id':'PR_node','body':d.get('body','Free-form PR description.'),'state':'closed' if merged else 'open','draft':False,'merged':merged,'merge_commit_sha':'c'*40 if merged else None,'mergeable_state':'clean','base':{'ref':'dev','sha':base,'repo':{'full_name':'test/repo'}},'head':{'ref':'feat/test','sha':head,'repo':{'full_name':'test/repo'}}}))
elif endpoint.endswith('/protection/required_status_checks'): print('{"contexts":["ci"],"checks":[]}')
elif endpoint.endswith('/commits/'+head+'/status'): print('{"state":"success","total_count":0,"statuses":[]}')
elif '/actions/runs?head_sha='+head in endpoint:
 pending=d.get('runs_seen',0)<d['pending_before']; d['runs_seen']=d.get('runs_seen',0)+1; d['last_pending']=pending; state_path.write_text(json.dumps(d))
 run={'id':1,'workflow_id':1,'name':'ci','event':'push','head_sha':head,'status':'in_progress' if pending else 'completed','conclusion':None if pending else 'success','created_at':'2026-01-01T00:00:00Z'}
 print(json.dumps([{'total_count':1,'workflow_runs':[run]}]))
elif '/actions/runs/1/jobs' in endpoint:
 pending=bool(d.get('last_pending')); status='in_progress' if pending else 'completed'; conclusion=None if pending else 'success'
 print(json.dumps([{'total_count':1,'jobs':[{'name':'ci','status':status,'conclusion':conclusion,'started_at':'2026-01-01T00:00:00Z','id':11}]}]))
elif 'check-runs' in endpoint:
 print('HTTP 404 check-runs must never be requested',file=sys.stderr); sys.exit(8)
elif endpoint.endswith('/git/ref/heads/feat/test'): print(json.dumps({'object':{'sha':head}}))
elif '/git/refs/heads/feat/test' in endpoint and method=='DELETE': d['deleted']=True; state_path.write_text(json.dumps(d)); sys.exit(0)
elif endpoint.endswith('/git/ref/heads/dev'): print(json.dumps({'object':{'sha':'c'*40}}))
elif '/compare/' in endpoint: print('{"status":"identical"}')
else: print('unexpected '+method+' '+endpoint,file=sys.stderr); sys.exit(8)
GH
chmod +x "$SANDBOX/bin/gh"
git -C "$SANDBOX/repo_under.test" remote set-url origin https://github.com/test/repo
git -C "$SANDBOX/repo_under.test" update-ref refs/remotes/origin/dev main
git -C "$SANDBOX/repo_under.test" checkout -q -b feat/test
HEAD_SHA="$(git -C "$SANDBOX/repo_under.test" rev-parse HEAD)"
BASE_SHA="$HEAD_SHA"

scenario_plan() {
  local name="$1" ci_budget="$2" pending_before="$3" brief plan
  brief="$(make_brief testsub "$name.md" draft)"
  plan="$(dirname "$brief")/$name-plan.md"
  make_plan "$plan" "$brief"
  python3 - "$plan" "$ci_budget" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('base: main', 'base: dev', 1).replace('updated: 2026-01-01', 'updated: 2026-01-01\nrevision: r1', 1).replace('  heartbeat: 20', '  heartbeat: 20\n  ci: '+sys.argv[2], 1); open(p,'w').write(s)
PY
  env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" \
    python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$SANDBOX/repo_under.test" true >/dev/null
  python3 - "$SANDBOX/home/.config/handoff/project-policy.json" "$plan" "$SANDBOX/repo_under.test" <<'PY'
import json,sys,pathlib
p,plan,repo=sys.argv[1:]; d=json.load(open(p)); d['repositories'][repo]['assessments']=[{'task':str(pathlib.Path(plan).resolve()),'revision':'r1','risk':'ordinary','reason':'test'}]; open(p,'w').write(json.dumps(d))
PY
  python3 - "$SANDBOX/state/forge.json" "$HEAD_SHA" "$BASE_SHA" "$pending_before" <<'PY'
import json,sys
open(sys.argv[1],'w').write(json.dumps({'head':sys.argv[2],'base':sys.argv[3],'pending_before':int(sys.argv[4]),'runs_seen':0,'last_pending':False,'body':'Free-form PR description.'}))
PY
  : >"$SANDBOX/state/gh.log"
  export HANDOFF_CI_POLL_S=0
  _sbx_env
  env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com \
    bash "$SANDBOX/kit/handoff-orchestrate.sh" start "$plan" --backend claude --publication-owner supervisor >/dev/null 2>&1
  printf '%s' "$plan"
}

WAIT_PLAN="$(scenario_plan wait-success 1 2)"
wait_done() { /usr/bin/grep -q '^orchestration: done' "$WAIT_PLAN" 2>/dev/null; }
wait_for 120 wait_done || fail "pending CI did not resolve to done: $(head -1 "$WAIT_PLAN" 2>/dev/null)"
WAIT_EVENTS="${WAIT_PLAN%.md}.events.log"
assert_eq "$(/usr/bin/grep -c 'CI PENDING' "$WAIT_EVENTS")" 1 "distinct pending CI event count"
assert_contains "$WAIT_EVENTS" 'MERGED ccccccc into dev — verified'
assert_eq "$(/usr/bin/grep -c 'CI PENDING' "$WAIT_EVENTS")" 1 "one CI PENDING event despite repeated pending answers"
assert_eq "$(/usr/bin/grep -c '^PUT repos/' "$SANDBOX/state/gh.log")" 1 "successful scenario merge calls"

TIMEOUT_PLAN="$(scenario_plan wait-timeout 0 10)"
timeout_held() { /usr/bin/grep -q '^orchestration: awaiting-merge' "$TIMEOUT_PLAN" 2>/dev/null; }
wait_for 120 timeout_held || fail "zero-budget pending CI did not await merge: $(head -1 "$TIMEOUT_PLAN" 2>/dev/null)"
TIMEOUT_EVENTS="${TIMEOUT_PLAN%.md}.events.log"
assert_contains "$TIMEOUT_EVENTS" 'CI still pending after 0 min'
assert_eq "$(/usr/bin/grep -c '^PUT repos/' "$SANDBOX/state/gh.log")" 0 "zero-budget merge PUT count"
assert_eq "$(/usr/bin/grep -c 'CI PENDING' "$TIMEOUT_EVENTS")" 1 "zero-budget CI pending event count"
echo ok
