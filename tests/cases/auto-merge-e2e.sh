#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

repo="$SANDBOX/repo_under.test"
origin="$SANDBOX/origin.git"
brief="$(make_brief testsub first.md draft)"
brief_two="$(make_brief testsub second.md draft)"
plan="$(dirname "$brief")/e2e-plan.md"
make_plan "$plan" "$brief" "$brief_two"
python3 - "$plan" "$brief_two" <<'PY'
import sys
p, second = sys.argv[1:]
s = open(p).read().replace('updated: 2026-01-01', 'updated: 2026-01-01\nrevision: r1', 1)
s = s.replace('base: main', 'base: dev', 1)
s = s.replace('branch: feat/test', 'branch: feat/e2e', 1)
open(p, 'w').write(s)
PY

mkdir -p "$SANDBOX/home/.config/handoff"
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" \
  python3 "$SANDBOX/kit/handoff-merge.py" default-get | /usr/bin/grep -qx false \
  || fail "installation default was not false"
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" \
  python3 "$SANDBOX/kit/handoff-merge.py" default-set false >/dev/null
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" \
  python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$repo" true >/dev/null
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" \
  python3 "$SANDBOX/kit/handoff-merge.py" assess --repo "$repo" --task "$plan" \
    --revision r1 --risk ordinary --reason "e2e assessment" >/dev/null
policy="$SANDBOX/home/.config/handoff/project-policy.json"
cp "$policy" "$SANDBOX/state/policy.expected.json"

main_sha="$(git -C "$repo" rev-parse origin/main)"
git -C "$repo" remote set-url origin https://github.com/test/repo
git -C "$repo" config url."$origin".insteadOf https://github.com/test/repo
cat >"$SANDBOX/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ['FAKE_STATE_DIR'])
state_path, log_path = root/'forge.json', root/'gh.log'
d = json.loads(state_path.read_text())
a = sys.argv[1:]
method = a[a.index('-X')+1] if '-X' in a else 'GET'
ep = 'graphql' if 'graphql' in a else next((x for x in a if x.startswith('repos/')), '')
log_path.open('a').write(method+' '+ep+'\n')
repo = d['repo']
if ep == 'repos/test/repo':
    print(json.dumps({'full_name':'test/repo'}))
elif ep.endswith('/git/ref/heads/main'):
    print(json.dumps({'object':{'sha':d['main']}}))
elif ep.endswith('/git/ref/heads/dev'):
    if not d.get('dev'):
        print('HTTP 404', file=sys.stderr); sys.exit(1)
    print(json.dumps({'object':{'sha':d['dev']}}))
elif ep.endswith('/git/refs') and method == 'POST':
    if d.get('dev'):
        print('HTTP 422', file=sys.stderr); sys.exit(1)
    d['dev'] = d['main']
    state_path.write_text(json.dumps(d))
    subprocess.run(['git','--git-dir',str(repo),'update-ref','refs/heads/dev',d['dev']],check=True)
    print(json.dumps({'ref':'refs/heads/dev'}))
elif ep.startswith('repos/test/repo/pulls?state=all&head=test:feat/e2e'):
    head = subprocess.check_output(['git','-C',d['checkout'],'rev-parse','refs/heads/feat/e2e'],text=True).strip()
    d['head'] = head; state_path.write_text(json.dumps(d))
    print(json.dumps([{'number':7,'state':'open','merged_at':None,'merge_commit_sha':None,
      'head':{'ref':'feat/e2e','sha':head,'repo':{'full_name':'test/repo'}},
      'base':{'ref':'dev','sha':d['main'],'repo':{'full_name':'test/repo'}}}]))
elif ep.endswith('/pulls/7'):
    merged = bool(d.get('merged'))
    body = '## Feature\nfeature\n## Acceptance\naccept\n## Final review\n'+d['head']+'\n## CI\nci\n## Limitations\nnone'
    print(json.dumps({'number':7,'node_id':'PR_node','body':body,'state':'closed' if merged else 'open',
      'draft':True,'merged':merged,'merge_commit_sha':d.get('merge_sha'), 'mergeable_state':'clean',
      'base':{'ref':'dev','sha':d['main'],'repo':{'full_name':'test/repo'}},
      'head':{'ref':'feat/e2e','sha':d['head'],'repo':{'full_name':'test/repo'}}}))
elif ep.endswith('/protection/required_status_checks'):
    print('{"contexts":["ci"],"checks":[]}')
elif '/check-runs' in ep:
    print('{"total_count":1,"check_runs":[{"name":"ci","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","id":1}]}')
elif ep.endswith('/commits/'+d['head']+'/status'):
    print('{"state":"success","statuses":[]}')
elif ep == 'graphql' and method == 'POST':
    d['ready'] = True; state_path.write_text(json.dumps(d)); print('{}')
elif ep.endswith('/pulls/7/merge') and method == 'PUT':
    if not d.get('ready') or not any('sha='+d['head'] in x for x in a) or not any('merge_method=squash' in x for x in a):
        print('invalid merge request', file=sys.stderr); sys.exit(1)
    subprocess.run(['git','--git-dir',str(repo),'fetch',str(d['checkout']),'refs/heads/feat/e2e'],
                   check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    tree = subprocess.check_output(['git','--git-dir',str(repo),'rev-parse',d['head']+'^{tree}'],text=True).strip()
    merge = subprocess.check_output(['git','--git-dir',str(repo),'commit-tree',tree,'-p',d['main']],text=True,
      input='verified squash result\n').strip()
    subprocess.run(['git','--git-dir',str(repo),'update-ref','refs/heads/dev',merge],check=True)
    d.update(merged=True,merge_sha=merge,dev=merge); state_path.write_text(json.dumps(d))
    print('{"merged":true}')
elif ep.endswith('/git/ref/heads/dev'):
    print(json.dumps({'object':{'sha':d['dev']}}))
elif ep.endswith('/git/ref/heads/feat/e2e'):
    print(json.dumps({'object':{'sha':d['head']}}))
elif '/git/refs/heads/feat/e2e' in ep and method == 'DELETE':
    d['deleted'] = True; state_path.write_text(json.dumps(d))
elif '/compare/' in ep:
    print('{"status":"identical"}')
else:
    print('unexpected '+method+' '+ep, file=sys.stderr); sys.exit(8)
PY
chmod +x "$SANDBOX/bin/gh"
python3 - "$SANDBOX/state/forge.json" "$origin" "$main_sha" "$repo" <<'PY'
import json,sys
open(sys.argv[1],'w').write(json.dumps({'repo':sys.argv[2],'checkout':sys.argv[4],
  'main':sys.argv[3],'dev':None,'head':None}))
PY
export FAKE_CLAUDE=run=commit,run@second=wait
_sbx_env
env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com \
  bash "$SANDBOX/kit/handoff-orchestrate.sh" start "$plan" --backend claude \
  --publication-owner supervisor >/dev/null 2>&1
wait_for 120 test -f "$SANDBOX/state/run-started" || fail "second brief did not reach its wait barrier"
EVENTS="${plan%.md}.events.log"
assert_contains "$EVENTS" 'BRIEF CLOSED first'
assert_contains "$EVENTS" 'effective=auto'
assert_eq "$(/usr/bin/grep -c 'BRIEF CLOSED' "$EVENTS")" 1 "closed briefs at barrier"
mutations="$(/usr/bin/grep -E '^(POST |PUT |DELETE )' "$SANDBOX/state/gh.log")"
assert_eq "$mutations" 'POST repos/test/repo/git/refs' "forge mutations before release"
printf '%s\n' "$main_sha" >"$SANDBOX/state/original-base"
touch "$SANDBOX/state/run-release"
plan_done() { /usr/bin/grep -q '^orchestration: done' "$plan" 2>/dev/null; }
wait_for 120 plan_done || fail "auto-merge plan did not finish"

python3 - "$plan" "$EVENTS" "$policy" "$SANDBOX/state/policy.expected.json" "$SANDBOX/state/forge.json" "$SANDBOX/state/gh.log" "$SANDBOX/state/original-base" "$origin" <<'PY'
import json, pathlib, re, subprocess, sys
plan, events, policy, expected, state, log, original, origin = map(pathlib.Path, sys.argv[1:])
text = plan.read_text()
assert re.search(r'^orchestration: done$', text, re.M), 'plan frontmatter not done'
rows = events.read_text().splitlines()
for item in ('BRIEF CLOSED first','BRIEF CLOSED second','FINAL REVIEW PASS','MERGED '):
    assert any(item in row for row in rows), f'missing event {item}'
positions = [next(i for i,row in enumerate(rows) if label in row) for label in
             ('BRIEF CLOSED first','BRIEF CLOSED second','FINAL REVIEW PASS','MERGED ')]
assert positions == sorted(positions), f'event order wrong: {positions}'
review = json.loads(pathlib.Path(str(plan).replace('.md','.final-review.json')).read_text())
assert {'feature','repo','head','base','verdict','blockers','risk','backend','created'} <= review.keys(), review
assert review['head'] and review['base'] and review['verdict'] == 'PASS'
d = json.loads(state.read_text())
assert d['ready'] and d['merged'] and d['deleted'], d
assert d['head'] == review['head'], 'merge was not bound to reviewed head'
assert d['merge_sha'] and len(d['merge_sha']) == 40
mutations = [line for line in log.read_text().splitlines() if line.startswith(('POST ','PUT ','DELETE '))]
assert mutations == ['POST repos/test/repo/git/refs','POST graphql',
                     'PUT repos/test/repo/pulls/7/merge','DELETE repos/test/repo/git/refs/heads/feat/e2e'], mutations
assert json.loads(policy.read_text()) == json.loads(expected.read_text()), 'policy store changed after assessment'
assert subprocess.check_output(['git','--git-dir',str(origin),'rev-parse','refs/heads/dev'],text=True).strip() == d['merge_sha']
assert subprocess.run(['git','--git-dir',str(origin),'cat-file','-e',d['merge_sha']+'^{commit}']).returncode == 0
assert d['merge_sha'] != original.read_text().strip(), 'squash result did not advance dev'
PY

second="$(make_brief testsub second-plan.md draft)"
second_plan="$(dirname "$second")/fresh-branch-plan.md"
make_plan "$second_plan" "$second"
python3 - "$second_plan" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('base: main','base: dev',1).replace('branch: feat/test','branch: feat/fresh',1); open(p,'w').write(s)
PY
if git -C "$repo" show-ref --verify --quiet refs/heads/feat/fresh; then
  fail "fresh branch existed before second plan"
fi
git -C "$repo" fetch -q origin || fail "could not refresh origin/dev after merge"
new_dev="$(git -C "$repo" rev-parse origin/dev)"
export FAKE_CLAUDE=run=wait
_sbx_env
env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com \
  bash "$SANDBOX/kit/handoff-orchestrate.sh" start "$second_plan" --backend claude \
  --publication-owner supervisor >/dev/null 2>&1
wait_for 90 test -f "$SANDBOX/state/run-started" || fail "second plan did not start"
fresh_head="$(git -C "$repo" rev-parse feat/fresh)"
assert_eq "$fresh_head" "$new_dev" "fresh branch did not start at updated origin/dev"
assert_eq "$(git -C "$repo" show-ref --verify --quiet refs/heads/feat/fresh; echo $?)" 0 "fresh branch missing"
[ "$fresh_head" != "$main_sha" ] || fail "fresh branch still points at original base"
echo ok
