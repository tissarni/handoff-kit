#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub auto-merge.md draft)"
PLAN="$(dirname "$BRIEF")/auto-merge-plan.md"
make_plan "$PLAN" "$BRIEF"
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
if endpoint.endswith('/pulls?state=all&head=test:feat/test'):
 print(json.dumps([{'number':7,'state':'open','merged_at':None,'merge_commit_sha':None,'head':{'ref':'feat/test','sha':head,'repo':{'full_name':'test/repo'}},'base':{'ref':'main','sha':base,'repo':{'full_name':'test/repo'}}}]))
elif endpoint.endswith('/pulls/7/merge') and method=='PUT':
 d['puts']=d.get('puts',0)+1; d['merged']=not bool(os.environ.get('FAKE_AMBIGUOUS')); state.write_text(json.dumps(d))
 if os.environ.get('FAKE_AMBIGUOUS'): print('HTTP 500',file=sys.stderr); sys.exit(1)
 print('{"merged":true}')
elif endpoint.endswith('/pulls/7'):
 print(json.dumps({'number':7,'node_id':'PR_node','body':'## Feature\nfeature\n## Acceptance\naccept\n## Final review\n'+head+'\n## CI\nci\n## Limitations\nnone','state':'closed' if d.get('merged') else 'open','draft':False,'merged':bool(d.get('merged')),'merge_commit_sha':'c'*40 if d.get('merged') else None,'mergeable_state':'clean','base':{'ref':'main','sha':base,'repo':{'full_name':'test/repo'}},'head':{'ref':'feat/test','sha':head,'repo':{'full_name':'test/repo'}}}))
elif endpoint.endswith('/protection/required_status_checks'): print('{"contexts":["ci"],"checks":[]}')
elif endpoint.endswith('/commits/'+head+'/status'): print('{"state":"success","statuses":[]}')
elif '/check-runs' in endpoint: print('{"total_count":1,"check_runs":[{"name":"ci","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","id":1}]}')
elif endpoint.endswith('/git/ref/heads/feat/test'):
 if d.get('deleted'): print('HTTP 404',file=sys.stderr); sys.exit(1)
 print(json.dumps({'object':{'sha':head}}))
elif '/git/refs/heads/feat/test' in endpoint and method=='DELETE':
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
assert_eq "$(/usr/bin/grep -c '^PUT repos/' "$SANDBOX/state/gh.log")" 1 "merge PUT count"
[ ! -f "$(git -C "$SANDBOX/repo_under.test" rev-parse --absolute-git-dir)/handoff-plan.lock" ] || fail "checkout lock was not released"

echo ok
