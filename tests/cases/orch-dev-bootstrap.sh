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
elif endpoint.endswith('/git/ref/heads/main'): print(json.dumps({'object':{'sha':state['main']}}))
elif endpoint.endswith('/git/ref/heads/dev'):
    if not state.get('dev'): print('HTTP 404',file=sys.stderr); sys.exit(1)
    print(json.dumps({'object':{'sha':state['dev']}}))
elif endpoint.endswith('/git/refs') and method == 'POST':
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
echo ok
