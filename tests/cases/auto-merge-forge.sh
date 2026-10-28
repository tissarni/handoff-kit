#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init
helper="$SANDBOX/kit/handoff-merge.py"
[ -x "$helper" ] || fail "sandbox omitted handoff helper"
repo="$SANDBOX/repo_under.test"
HOME="$SANDBOX/home" python3 "$helper" policy-set --repo "$repo" true >/dev/null
mkdir -p "$SANDBOX/fakebin"
cat >"$SANDBOX/fakebin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state = Path(os.environ['FAKE_STATE_DIR']) / 'forge.json'
log = Path(os.environ['FAKE_STATE_DIR']) / 'forge.log'
data = json.loads(state.read_text()) if state.exists() else {'dev': None, 'merged': False}
args = sys.argv[1:]
log.open('a').write(' '.join(args) + '\n')
endpoint = next((x for x in args if x.startswith('repos/')), '')
method = 'GET'
if '-X' in args: method = args[args.index('-X') + 1]
if endpoint == 'repos/acme/widget': result = {'full_name': 'acme/widget'}
elif endpoint.endswith('/git/ref/heads/main'): result = {'object': {'sha': 'mainsha'}}
elif endpoint.endswith('/git/ref/heads/dev'):
    if data['dev'] is None:
        print('gh: Not Found (HTTP 404)', file=sys.stderr); sys.exit(1)
    result = {'object': {'sha': 'wrongsha' if os.environ.get('FORGE_WRONG_DEV_READBACK') == '1' else data['dev']}}
elif endpoint.endswith('/git/refs') and method == 'POST':
    data['dev'] = 'mainsha'; result = {'ref': 'refs/heads/dev'}
elif endpoint.endswith('/pulls/7'):
    result = {'state': 'open', 'draft': os.environ.get('FORGE_DRAFT') == '1',
      'merged': data['merged'], 'merge_commit_sha': 'mergecommit' if data['merged'] else None,
      'base': {'ref': os.environ.get('FORGE_BASE', 'dev'), 'sha': 'basesha', 'repo': {'full_name': 'acme/widget'}},
      'mergeable_state': 'clean',
      'head': {'ref': 'feature/x', 'sha': os.environ.get('FORGE_HEAD', 'headsha'),
        'repo': {'full_name': 'acme/widget'}}}
elif endpoint.endswith('/commits/headsha/status'): result = {'state': os.environ.get('FORGE_STATUS', 'success')}
elif endpoint.endswith('/commits/headsha/check-runs'): result = {'check_runs': [{'status': 'completed', 'conclusion': 'success'}]}
elif endpoint.endswith('/pulls/7/merge') and method == 'PUT':
    if 'sha=headsha' not in args or 'merge_method=squash' not in args: sys.exit(3)
    data['merged'] = True; result = {'merged': True}
elif endpoint.endswith('/git/ref/heads/feature/x'): result = {'object': {'sha': 'headsha'}}
elif endpoint.endswith('/git/refs/heads/feature/x') and method == 'DELETE':
    print('', end='')
    sys.exit(0)
else: sys.exit(4)
state.write_text(json.dumps(data))
print(json.dumps(result))
PY
chmod +x "$SANDBOX/fakebin/gh"
forge_env=("PATH=$SANDBOX/fakebin:$PATH" "HOME=$SANDBOX/home" "GH_TOKEN=fake" "GH_HOST=github.com" "FAKE_STATE_DIR=$SANDBOX/state")
# Creation uses a fresh verified main SHA; existing dev must remain untouched.
env "${forge_env[@]}" python3 "$helper" dev-bootstrap --repository acme/widget >/dev/null
assert_contains "$SANDBOX/state/forge.log" 'refs/heads/dev'
python3 - "$SANDBOX/state/forge.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['dev']=='mainsha'
PY
python3 - "$SANDBOX/state/forge.log" <<'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
post = next(i for i, line in enumerate(lines) if '-X POST repos/acme/widget/git/refs' in line)
assert any('repos/acme/widget/git/ref/heads/dev' in line for line in lines[post + 1:])
PY
python3 - "$SANDBOX/state/forge.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['dev']='dev-owned'; open(p,'w').write(json.dumps(d))
PY
env "${forge_env[@]}" python3 "$helper" dev-bootstrap --repository acme/widget >/dev/null
python3 - "$SANDBOX/state/forge.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['dev']=='dev-owned'
PY
# Unsafe readiness states must make zero merge or delete calls.
: >"$SANDBOX/state/forge.log"
if env "${forge_env[@]}" FORGE_DRAFT=1 python3 "$helper" finalize --repository acme/widget --pr 7 --head headsha --base basesha --branch feature/x --policy-repo "$repo" --task task-1 --revision rev-1 --risk ordinary >/dev/null 2>&1; then fail "draft PR finalized"; fi
if /usr/bin/grep -E 'PUT .*pulls/7/merge|DELETE .*feature/x' "$SANDBOX/state/forge.log" >/dev/null; then fail "draft PR caused forbidden mutation"; fi
if env "${forge_env[@]}" FORGE_HEAD=other python3 "$helper" finalize --repository acme/widget --pr 7 --head headsha --base basesha --branch feature/x --policy-repo "$repo" --task task-1 --revision rev-1 --risk ordinary >/dev/null 2>&1; then fail "wrong PR head finalized"; fi
if /usr/bin/grep -E 'PUT .*pulls/7/merge|DELETE .*feature/x' "$SANDBOX/state/forge.log" >/dev/null; then fail "wrong head caused forbidden mutation"; fi
# Positive exact-head path: one squash mutation, read-back, then owned-head cleanup.
env "${forge_env[@]}" python3 "$helper" finalize --repository acme/widget --pr 7 --head headsha --base basesha --branch feature/x --policy-repo "$repo" --task task-1 --revision rev-1 --risk ordinary
[ "$(/usr/bin/grep -c 'PUT .*pulls/7/merge' "$SANDBOX/state/forge.log")" -eq 1 ] || fail "expected one squash merge call"
assert_contains "$SANDBOX/state/forge.log" 'DELETE repos/acme/widget/git/refs/heads/feature/x'
printf '%s\n' 'GitHub dev bootstrap and exact-head finalization passed'
