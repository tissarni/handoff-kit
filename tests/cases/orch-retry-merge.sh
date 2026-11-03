#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub retry.md draft)"
PLAN="$(dirname "$BRIEF")/retry-plan.md"
make_plan "$PLAN" "$BRIEF"
python3 - "$PLAN" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('base: main', 'base: dev', 1).replace('updated: 2026-01-01', 'updated: 2026-01-01\nrevision: r1', 1); open(p,'w').write(s)
PY
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$SANDBOX/repo_under.test" true >/dev/null
python3 - "$SANDBOX/home/.config/handoff/project-policy.json" "$PLAN" "$SANDBOX/repo_under.test" <<'PY'
import json,sys,pathlib
p,plan,repo=sys.argv[1:]; d=json.load(open(p)); d['repositories'][repo]['assessments']=[{'task':str(pathlib.Path(plan).resolve()),'revision':'r1','risk':'ordinary','reason':'test'}]; open(p,'w').write(json.dumps(d))
PY

cat >"$SANDBOX/bin/gh" <<'GH'
#!/usr/bin/env python3
import json,os,pathlib,sys
if sys.argv[1:] == ['--version']: print('gh version 2.103.3 (2026-01-01)'); raise SystemExit(0)
root=pathlib.Path(os.environ['HOME']).parent/'state'; f=root/'forge.json'; d=json.loads(f.read_text()); a=sys.argv[1:]; ep=next((x for x in a if x.startswith('repos/')), ''); method=a[a.index('-X')+1] if '-X' in a else 'GET'; (root/'gh.log').open('a').write(method+' '+ep+'\n'); head=d['head']; base=d['base']
if ep.startswith('repos/test/repo/pulls?state=all&head=test:feat/test'):
 m=bool(d.get('merged')); print(json.dumps([{'number':7,'state':'closed' if m else 'open','merged_at':'2026-01-01T00:00:00Z' if m else None,'merge_commit_sha':'c'*40 if m else None,'head':{'ref':'feat/test','sha':head,'repo':{'full_name':'test/repo'}},'base':{'ref':'dev','sha':base,'repo':{'full_name':'test/repo'}}}]))
elif ep.endswith('/pulls/7/merge') and method=='PUT':
 d['puts']=d.get('puts',0)+1; d['merged']=True; f.write_text(json.dumps(d)); print('{"merged":true}')
elif ep.endswith('/pulls/7') and method=='PATCH':
 d['body']=next(x[5:] for x in a if x.startswith('body=')); d['body_writes']=d.get('body_writes',0)+1; f.write_text(json.dumps(d)); print('{}')
elif ep.endswith('/pulls/7'):
 m=bool(d.get('merged')); print(json.dumps({'number':7,'node_id':'PR_node','body':d.get('body','Free-form PR description.'),'state':'closed' if m else 'open','draft':False,'merged':m,'merge_commit_sha':'c'*40 if m else None,'mergeable_state':'clean','base':{'ref':'dev','sha':base,'repo':{'full_name':'test/repo'}},'head':{'ref':'feat/test','sha':head,'repo':{'full_name':'test/repo'}}}))
elif ep.endswith('/protection/required_status_checks'): print('{"contexts":["ci"],"checks":[]}')
elif ep.endswith('/commits/'+head+'/status'): print('{"state":"success","statuses":[]}')
elif '/actions/runs/1/jobs' in ep: print(json.dumps([{'total_count':1,'jobs':[{'name':'ci','status':'completed','conclusion':'failure' if d.get('fail_check') else 'success','started_at':'2026-01-01T00:00:00Z','id':11}]}]))
elif '/actions/runs?head_sha='+head in ep: print(json.dumps([{'total_count':1,'workflow_runs':[{'id':1,'workflow_id':1,'name':'wf','event':'push','head_sha':head,'status':'completed','conclusion':'failure' if d.get('fail_check') else 'success','created_at':'2026-01-01T00:00:00Z'}]}]))
elif 'check-runs' in ep: print('HTTP 404',file=sys.stderr); sys.exit(8)
elif ep.endswith('/git/ref/heads/feat/test'): print(json.dumps({'object':{'sha':head}}))
elif '/git/refs/heads/feat/test' in ep and method=='DELETE': d['deleted']=True; f.write_text(json.dumps(d)); sys.exit(0)
elif ep.endswith('/git/ref/heads/dev'): print(json.dumps({'object':{'sha':'c'*40}}))
elif '/compare/' in ep: print('{"status":"identical"}')
else: print('unexpected '+method+' '+ep,file=sys.stderr); sys.exit(8)
GH
chmod +x "$SANDBOX/bin/gh"
git -C "$SANDBOX/repo_under.test" remote set-url origin https://github.com/test/repo
git -C "$SANDBOX/repo_under.test" update-ref refs/remotes/origin/dev main
git -C "$SANDBOX/repo_under.test" checkout -q -b feat/test
HEAD_SHA="$(git -C "$SANDBOX/repo_under.test" rev-parse HEAD)"
python3 - "$SANDBOX/state/forge.json" "$HEAD_SHA" <<'PY'
import json,sys
open(sys.argv[1],'w').write(json.dumps({'head':sys.argv[2],'base':sys.argv[2],'fail_check':True}))
PY
run_orch() { _sbx_env; env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com bash "$SANDBOX/kit/handoff-orchestrate.sh" "$@"; }

# The initial finalize refusal creates reviewed awaiting-merge state.
run_orch start "$PLAN" --backend claude --publication-owner supervisor >/dev/null 2>&1
awaiting() { /usr/bin/grep -q '^orchestration: awaiting-merge' "$PLAN" 2>/dev/null; }
wait_for 120 awaiting || fail "initial transient finalize refusal did not await merge"
EVENTS="${PLAN%.md}.events.log"
final_reviews() { /usr/bin/grep -c '"stage": "final-review"' "$SANDBOX/state/calls.log" || true; }
FINAL_COUNT="$(final_reviews)"
PLAN_SUM="$(sha256sum "$PLAN" | cut -d' ' -f1)"
python3 - "$SANDBOX/state/forge.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['fail_check']=False; open(p,'w').write(json.dumps(d))
PY
: >"$SANDBOX/state/gh.log"
run_orch resume "$PLAN" --retry-merge --backend claude --publication-owner supervisor >/dev/null 2>&1
/usr/bin/grep -q '^orchestration: done' "$PLAN" || fail "retry did not mark plan done"
assert_contains "$EVENTS" 'RETRY MERGE'
assert_contains "$EVENTS" 'MERGED ccccccc into dev — verified'
assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("puts",0))' "$SANDBOX/state/forge.json")" 1 "retry merge PUT count"
assert_eq "$(final_reviews)" "$FINAL_COUNT" "final-review count changed on retry"
[ ! -f "$(git -C "$SANDBOX/repo_under.test" rev-parse --absolute-git-dir)/handoff-plan.lock" ] || fail "checkout lock remained after retry merge"

GIT_DIR="$(git -C "$SANDBOX/repo_under.test" rev-parse --absolute-git-dir)"
CHECKOUT_LOCK="$GIT_DIR/handoff-plan.lock"
PLAN_LOCK="${PLAN%.md}.lock"
set_awaiting() {
  local reviewed="$1"
  python3 - "$PLAN" "$reviewed" <<'PY'
import re,sys
p,head=sys.argv[1:]; s=open(p).read(); s=re.sub(r'^orchestration:.*$', 'orchestration: awaiting-merge', s, count=1, flags=re.M)
if re.search(r'^final-reviewed-head:', s, re.M): s=re.sub(r'^final-reviewed-head:.*$', 'final-reviewed-head: '+head, s, count=1, flags=re.M)
else: s=s.replace('orchestration: awaiting-merge', 'orchestration: awaiting-merge\\nfinal-reviewed-head: '+head, 1)
open(p,'w').write(s)
PY
  printf '%s\n' "$(readlink -f "$PLAN")" >"$CHECKOUT_LOCK"
}
reset_forge() {
  python3 - "$SANDBOX/state/forge.json" "$HEAD_SHA" "$1" <<'PY'
import json,sys
data={'head':sys.argv[2], 'base':sys.argv[2], 'fail_check':sys.argv[3]=='fail'}
open(sys.argv[1],'w').write(json.dumps(data))
PY
  : >"$SANDBOX/state/gh.log"
}
assert_no_forge_writes() {
  local writes
  writes="$(/usr/bin/grep -E '^(PUT|PATCH|DELETE)[[:space:]]' "$SANDBOX/state/gh.log" || true)"
  [ -z "$writes" ] || fail "retry precondition caused a forge mutation: $writes"
}
assert_checkout_held() {
  [ -f "$CHECKOUT_LOCK" ] || fail "checkout lock was not retained after refusal"
  [ "$(head -1 "$CHECKOUT_LOCK")" = "$(readlink -f "$PLAN")" ] || fail "checkout lock owner changed"
}

# A moved local head requires a new final review and must not touch the forge.
set_awaiting "$HEAD_SHA"; reset_forge ok
printf 'head moved\n' >"$SANDBOX/repo_under.test/moved.txt"
git -C "$SANDBOX/repo_under.test" add moved.txt
git -C "$SANDBOX/repo_under.test" -c user.name='Test User' -c user.email=test@example.com commit -q -m 'test moved head'
[ "$(git -C "$SANDBOX/repo_under.test" rev-parse HEAD)" != "$HEAD_SHA" ] || fail "moved-head setup did not move HEAD"
: >"$SANDBOX/state/gh.log"
if OUT="$(run_orch resume "$PLAN" --retry-merge --backend claude --publication-owner supervisor 2>&1)"; then fail "moved head retry unexpectedly succeeded"; fi
case "$OUT" in *'head moved since the final review'*) ;; *) fail "moved head refusal was unclear: $OUT" ;; esac
assert_checkout_held; assert_no_forge_writes
/usr/bin/grep -q '^orchestration: awaiting-merge' "$PLAN" || fail "moved-head refusal changed plan state"
git -C "$SANDBOX/repo_under.test" reset -q --hard "$HEAD_SHA"
rm -f "$SANDBOX/repo_under.test/moved.txt"

# Repository manual policy and an effective task hold both refuse before writes.
set_awaiting "$HEAD_SHA"; reset_forge ok
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$SANDBOX/repo_under.test" false >/dev/null
: >"$SANDBOX/state/gh.log"
if OUT="$(run_orch resume "$PLAN" --retry-merge --backend claude --publication-owner supervisor 2>&1)"; then fail "manual policy retry unexpectedly succeeded"; fi
case "$OUT" in *'repository policy is not auto'*) ;; *) fail "manual repository policy refusal was unclear: $OUT" ;; esac
assert_checkout_held; assert_no_forge_writes
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$SANDBOX/repo_under.test" true >/dev/null
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" hold --repo "$SANDBOX/repo_under.test" --task "$(readlink -f "$PLAN")" >/dev/null
PLAN_BEFORE="$(sha256sum "$PLAN" | cut -d' ' -f1)"
: >"$SANDBOX/state/gh.log"
if OUT="$(run_orch resume "$PLAN" --retry-merge --backend claude --publication-owner supervisor 2>&1)"; then fail "task hold retry unexpectedly succeeded"; fi
case "$OUT" in *'effective task policy is manual — hold'*) ;; *) fail "task hold refusal was unclear: $OUT" ;; esac
[ "$(sha256sum "$PLAN" | cut -d' ' -f1)" = "$PLAN_BEFORE" ] || fail "task-policy refusal edited plan"
assert_checkout_held; assert_no_forge_writes
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" release --repo "$SANDBOX/repo_under.test" --task "$(readlink -f "$PLAN")" >/dev/null

# A human merge is reconciled without a second merge PUT.
set_awaiting "$HEAD_SHA"
python3 - "$SANDBOX/state/forge.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['merged']=True; open(p,'w').write(json.dumps(d))
PY
: >"$SANDBOX/state/gh.log"
run_orch resume "$PLAN" --retry-merge --backend claude --publication-owner supervisor >/dev/null 2>&1
/usr/bin/grep -q '^orchestration: done' "$PLAN" || fail "already-merged retry did not complete"
assert_contains "$EVENTS" 'MERGE VERIFIED'
! /usr/bin/grep -q '^PUT ' "$SANDBOX/state/gh.log" || fail "already-merged retry sent another merge PUT"
[ ! -f "$CHECKOUT_LOCK" ] || fail "checkout lock remained after verified human merge"

# Retry-time finalize refusal must release only the plan lock and keep checkout ownership.
set_awaiting "$HEAD_SHA"; reset_forge fail
FINAL_COUNT="$(final_reviews)"
: >"$SANDBOX/state/gh.log"
run_orch resume "$PLAN" --retry-merge --backend claude --publication-owner supervisor >/dev/null 2>&1
/usr/bin/grep -q '^orchestration: awaiting-merge' "$PLAN" || fail "retry finalize refusal did not remain awaiting-merge"
[ ! -f "$PLAN_LOCK" ] || fail "retry finalize refusal left a plan lock"
assert_checkout_held
assert_eq "$(final_reviews)" "$FINAL_COUNT" "retry finalize refusal invoked final review"
assert_eq "$(/usr/bin/grep -c '^PATCH ' "$SANDBOX/state/gh.log")" 1 "retry PR-body PATCH before finalize refusal"
! /usr/bin/grep -q '^PUT ' "$SANDBOX/state/gh.log" || fail "refused retry attempted merge PUT"

# The flag is rejected before plan or forge writes outside its supported state/command.
PLAN_BEFORE="$(sha256sum "$PLAN" | cut -d' ' -f1)"
if OUT="$(run_orch start "$PLAN" --retry-merge --backend claude --publication-owner supervisor 2>&1)"; then fail "start --retry-merge unexpectedly succeeded"; fi
[ "$(sha256sum "$PLAN" | cut -d' ' -f1)" = "$PLAN_BEFORE" ] || fail "start --retry-merge edited plan"
python3 - "$PLAN" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read(); s=re.sub(r'^orchestration:.*$', 'orchestration: broken', s, count=1, flags=re.M); open(p,'w').write(s)
PY
PLAN_BEFORE="$(sha256sum "$PLAN" | cut -d' ' -f1)"
: >"$SANDBOX/state/gh.log"
if OUT="$(run_orch start "$PLAN" --retry-merge --backend claude --publication-owner supervisor 2>&1)"; then fail "start --retry-merge on broken plan unexpectedly succeeded"; fi
case "$OUT" in *'--retry-merge only applies to resume'*) ;; *) fail "start --retry-merge refusal was unclear: $OUT" ;; esac
[ "$(sha256sum "$PLAN" | cut -d' ' -f1)" = "$PLAN_BEFORE" ] || fail "start --retry-merge on broken plan edited plan"
assert_no_forge_writes
if OUT="$(run_orch resume "$PLAN" --retry-merge --backend claude --publication-owner supervisor 2>&1)"; then fail "broken plan retry unexpectedly succeeded"; fi
case "$OUT" in *'requires a plan in awaiting-merge state'*) ;; *) fail "broken-plan refusal was unclear: $OUT" ;; esac
[ "$(sha256sum "$PLAN" | cut -d' ' -f1)" = "$PLAN_BEFORE" ] || fail "broken-plan retry edited plan"
assert_no_forge_writes
echo ok
