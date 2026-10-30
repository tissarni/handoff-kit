#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

REPO="$SANDBOX/repo_under.test"
BRIEF="$(make_brief testsub variants.md draft)"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
BASE_SHA="$HEAD_SHA"
EVIDENCE="${BRIEF%.md}.final-review.json"
CALLS="$SANDBOX/state/calls.log"

mkdir -p "$SANDBOX/home/.claude" "$SANDBOX/home/.hermes/profiles/final-review"
printf '%s\n' '{"enabledPlugins":{"test-plugin@market":true}}' >"$SANDBOX/home/.claude/settings.json"

OUT="$(launch final-review "$BRIEF" --head "$HEAD_SHA" --base "$BASE_SHA" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "candidate final review failed ($RC): $OUT"
printf 'CANDIDATE OUTPUT: rc=%s\n%s\n' "$RC" "$OUT"
python3 - "$CALLS" <<'PY' || fail "claude final-review argv/settings assertion failed"
import json, sys
r=[json.loads(line) for line in open(sys.argv[1], encoding='utf-8') if json.loads(line).get('stage') == 'final-review'][-1]
a=r['argv']
assert a[a.index('--permission-mode')+1] == 'bypassPermissions', a
assert a[a.index('--disallowedTools')+1].find('Edit') >= 0
assert all(x in a[a.index('--disallowedTools')+1] for x in ('Edit','Write','NotebookEdit'))
s=r.get('settings')
assert isinstance(s, dict), s
assert len(s.get('hooks', {}).get('PreToolUse', [])) == 1, s
assert s.get('enabledPlugins') == {'test-plugin@market': False}, s
assert r.get('settings_path'), r
PY

cat >"$SANDBOX/bin/backend-capture" <<'PY'
#!/usr/bin/env python3
import json, os, re, sys
with open(os.environ['FAKE_STATE_DIR'] + '/' + os.environ['BACKEND_LOG'], 'w', encoding='utf-8') as f:
    json.dump(sys.argv[1:], f)
text=' '.join(sys.argv[1:])
h=re.search(r'head: ([0-9a-f]{40})', text)
b=re.search(r'base: ([0-9a-f]{40})', text)
if not h or not b: sys.exit(4)
print('''FINAL REVIEW
verdict: PASS
head: %s
base: %s
blockers: none
risk: ordinary
END FINAL REVIEW''' % (h.group(1), b.group(1)))
PY
chmod +x "$SANDBOX/bin/backend-capture"
cp "$SANDBOX/bin/backend-capture" "$SANDBOX/bin/hermes"
cp "$SANDBOX/bin/backend-capture" "$SANDBOX/bin/devin"
_sbx_env
SBX_ENV+=("HERMES_BIN=$SANDBOX/bin/hermes" "DEVIN_BIN=$SANDBOX/bin/devin" "BACKEND_LOG=hermes.argv")
rm -f "$EVIDENCE"
env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/handoff-launch.sh" final-review "$BRIEF" --head "$HEAD_SHA" --base "$BASE_SHA" --backend hermes >/dev/null 2>&1 || fail "Hermes final-review invocation failed"
python3 - "$SANDBOX/state/hermes.argv" "$REPO" <<'PY' || fail "Hermes final-review argv assertion failed"
import json, sys
a=json.load(open(sys.argv[1], encoding='utf-8'))
assert a[a.index('-p')+1] == 'final-review', a
assert a[a.index('--in')+1] == sys.argv[2], a
PY

_sbx_env
SBX_ENV+=("HERMES_BIN=$SANDBOX/bin/hermes" "DEVIN_BIN=$SANDBOX/bin/devin" "BACKEND_LOG=devin.argv")
rm -f "$EVIDENCE"
env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/handoff-launch.sh" final-review "$BRIEF" --head "$HEAD_SHA" --base "$BASE_SHA" --backend devin >/dev/null 2>&1 || fail "Devin final-review invocation failed"
python3 - "$SANDBOX/state/devin.argv" <<'PY' || fail "Devin final-review argv assertion failed"
import json, sys
a=json.load(open(sys.argv[1], encoding='utf-8'))
assert a[a.index('--permission-mode')+1] == 'dangerous', a
assert a[a.index('--respect-workspace-trust')+1] == 'false', a
PY

# Each malformed or stale review response is rejected with a durable non-empty reason.
for variant in no-block two-block wrong-head wrong-base blockers fail-ordinary move-head; do
  rm -f "$EVIDENCE"
  OUT="$(FAKE_CLAUDE="final-review=$variant" launch final-review "$BRIEF" --head "$HEAD_SHA" --base "$BASE_SHA" --backend claude 2>&1)"; RC=$?
  [ "$RC" -ne 0 ] || fail "$variant unexpectedly passed: $OUT"
  printf '%s\n' "$OUT" | /usr/bin/grep -qF 'FINAL REVIEW FAIL' || fail "$variant omitted FAIL verdict: $OUT"

  ! printf '%s\n' "$OUT" | /usr/bin/grep -qF 'FINAL REVIEW PASS' || fail "$variant printed PASS: $OUT"
  python3 - "$EVIDENCE" <<'PY'
import json, sys
r=json.load(open(sys.argv[1], encoding='utf-8'))
assert r.get('verdict') == 'FAIL', r
assert isinstance(r.get('reason'), str) and r['reason'].strip(), r
PY
  [ "$?" -eq 0 ] || fail "$variant did not persist a non-empty FAIL reason: $(cat "$EVIDENCE" 2>/dev/null)"
done

echo ok
