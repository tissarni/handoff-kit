#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init
brief="$(make_brief testsub bootstrap.md draft)"
plan="$(dirname "$brief")/bootstrap-plan.md"
make_plan "$plan" "$brief"
python3 - "$plan" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('base: main', 'base: dev', 1)
open(p,'w').write(s)
PY
repo="$SANDBOX/repo_under.test"
git -C "$repo" remote set-url origin https://github.com/acme/widget.git
git -C "$repo" config url."$SANDBOX/origin.git".insteadOf https://github.com/acme/widget.git
main_sha="$(git -C "$repo" rev-parse origin/main)"
cat >"$SANDBOX/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
root=pathlib.Path(os.environ['FAKE_STATE_DIR'])
state=json.loads((root/'bootstrap.json').read_text())
a=sys.argv[1:]; endpoint=next((x for x in a if x.startswith('repos/')), '')
method=a[a.index('-X')+1] if '-X' in a else 'GET'
with (root/'forge.log').open('a') as f: f.write(method+' '+endpoint+'\n')
if endpoint == 'repos/acme/widget': print(json.dumps({'full_name':'acme/widget'}))
elif endpoint.endswith('/git/ref/heads/main'):
    if not state.get('main'): print('HTTP 404',file=sys.stderr); sys.exit(1)
    print(json.dumps({'object':{'sha':state['main']}}))
elif endpoint.endswith('/git/ref/heads/dev'):
    if not state.get('dev'): print('HTTP 404',file=sys.stderr); sys.exit(1)
    print(json.dumps({'object':{'sha':state['dev']}}))
elif endpoint.endswith('/git/refs') and method == 'POST':
    if state.get('deny_post'): print('HTTP 403',file=sys.stderr); sys.exit(1)
    state['dev']=state['main']; (root/'bootstrap.json').write_text(json.dumps(state))
    subprocess.run(['git','--git-dir',state['origin'],'update-ref','refs/heads/dev',state['main']],check=True)
    print(json.dumps({'ref':'refs/heads/dev'}))
else: print('unexpected '+method+' '+endpoint,file=sys.stderr); sys.exit(8)
PY
chmod +x "$SANDBOX/bin/gh"
python3 - "$SANDBOX/state/bootstrap.json" "$main_sha" "$SANDBOX/origin.git" <<'PY'
import json,sys
open(sys.argv[1],'w').write(json.dumps({'main':sys.argv[2],'dev':None,'origin':sys.argv[3]}))
PY
mkdir -p "$SANDBOX/home/.config/handoff"
HOME="$SANDBOX/home" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$repo" true >/dev/null
# START must bootstrap only through the fake forge, and the result must derive from main.
_sbx_env
OUT="$(env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com bash "$SANDBOX/kit/handoff-orchestrate.sh" start "$plan" --backend claude --publication-owner supervisor 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "START failed: $OUT"
assert_contains "$SANDBOX/state/forge.log" 'repos/acme/widget/git/refs'
git -C "$repo" show-ref --verify --quiet refs/remotes/origin/dev || fail "origin/dev was not fetched"
assert_eq "$(git -C "$repo" rev-parse origin/dev)" "$(git -C "$repo" rev-parse origin/main)" "dev did not start at main"
orch stop "$plan" >/dev/null 2>&1 || true
wait_for 10 test '!' -f "${plan%.md}.lock" || fail "bootstrap driver kept its lock"

# An existing dev branch needs no API write.
: >"$SANDBOX/state/forge.log"
OUT="$(env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com bash "$SANDBOX/kit/handoff-orchestrate.sh" start "$plan" --backend claude --publication-owner supervisor 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "existing-dev START failed: $OUT"
if /usr/bin/grep -q 'POST repos/acme/widget/git/refs' "$SANDBOX/state/forge.log"; then fail "existing dev caused bootstrap POST"; fi
orch stop "$plan" >/dev/null 2>&1 || true
wait_for 10 test '!' -f "${plan%.md}.lock" || fail "existing-dev driver kept its lock"
rm -f "$(git -C "$repo" rev-parse --absolute-git-dir)/handoff-plan.lock"

# Manual policy leaves a missing dev unbootstrapped and fails before cutting a branch.
manual_plan="$(dirname "$plan")/manual-bootstrap-plan.md"
make_plan "$manual_plan" "$brief"
python3 - "$manual_plan" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('base: main', 'base: dev', 1).replace('branch: feat/test', 'branch: feat/manual-bootstrap', 1); open(p,'w').write(s)
PY
git -C "$repo" checkout -q main
git -C "$repo" branch -D feat/test >/dev/null 2>&1 || true
git -C "$repo" update-ref -d refs/remotes/origin/dev
git -C "$SANDBOX/origin.git" update-ref -d refs/heads/dev
python3 - "$SANDBOX/state/bootstrap.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['dev']=None; open(p,'w').write(json.dumps(d))
PY
HOME="$SANDBOX/home" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$repo" false >/dev/null
: >"$SANDBOX/state/forge.log"
OUT="$(env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com bash "$SANDBOX/kit/handoff-orchestrate.sh" start "$manual_plan" --backend claude --publication-owner supervisor 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || fail "manual missing-dev START unexpectedly passed: $OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -q 'origin/dev.*missing' || fail "manual missing-dev refusal unclear: $OUT"
if /usr/bin/grep -q 'POST repos/acme/widget/git/refs' "$SANDBOX/state/forge.log"; then fail "manual policy called dev-bootstrap"; fi
git -C "$repo" show-ref --verify --quiet refs/heads/feat/test && fail "manual missing-dev cut a feature branch"

# Automatic bootstrap refuses a missing main ref and a denied create without
# falling back to main or cutting the requested feature branch.
auto_plan="$(dirname "$plan")/failed-bootstrap-plan.md"
make_plan "$auto_plan" "$brief"
python3 - "$auto_plan" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('base: main', 'base: dev', 1).replace('branch: feat/test', 'branch: feat/bootstrap-failure', 1); open(p,'w').write(s)
PY
HOME="$SANDBOX/home" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$repo" true >/dev/null
python3 - "$SANDBOX/state/bootstrap.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['main']=None; d['dev']=None; d.pop('deny_post',None); open(p,'w').write(json.dumps(d))
PY
OUT="$(env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com bash "$SANDBOX/kit/handoff-orchestrate.sh" start "$auto_plan" --backend claude --publication-owner supervisor 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || fail "missing-main bootstrap unexpectedly passed: $OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -q 'preflight:dev-bootstrap' || fail "missing-main refusal unclear: $OUT"
git -C "$repo" show-ref --verify --quiet refs/heads/feat/bootstrap-failure && fail "missing-main fallback cut a feature branch"
python3 - "$SANDBOX/state/bootstrap.json" "$main_sha" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['main']=d['main'] or sys.argv[2]; d['dev']=None; d['deny_post']=True; open(p,'w').write(json.dumps(d))
PY
OUT="$(env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com bash "$SANDBOX/kit/handoff-orchestrate.sh" start "$auto_plan" --backend claude --publication-owner supervisor 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || fail "denied bootstrap unexpectedly passed: $OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -q 'preflight:dev-bootstrap' || fail "denied-bootstrap refusal unclear: $OUT"
git -C "$repo" show-ref --verify --quiet refs/heads/feat/bootstrap-failure && fail "denied bootstrap cut a feature branch"
echo ok
