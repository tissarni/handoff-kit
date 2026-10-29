#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$SANDBOX/vault/02-projects/sample/one.md"
mkdir -p "$(dirname "$BRIEF")"
printf '%s\n' '---' "repo: $SANDBOX/repo_under.test" '---' 'brief' >"$BRIEF"
HEAD_SHA="$(git -C "$SANDBOX/repo_under.test" rev-parse HEAD)"
BASE_SHA="$HEAD_SHA"
EVIDENCE="${BRIEF%.md}.final-review.json"

cat >"$SANDBOX/bin/claude" <<'EOF'
#!/usr/bin/env python3
import os, re, sys, time
with open(os.environ['FAKE_STATE_DIR'] + '/final-review.calls', 'a') as f:
    f.write('called\n')
text = ' '.join(sys.argv)
open(os.environ['FAKE_STATE_DIR'] + '/final-review.prompt', 'w').write(text)
mode = os.environ.get('FAKE_REVIEW_MODE', '')
if mode == 'SLEEP':
    time.sleep(5)
h = re.search(r'head: ([0-9a-f]{40})', text)
b = re.search(r'base: ([0-9a-f]{40})', text)
if not h or not b:
    sys.exit(4)
print('FINAL REVIEW\nverdict: PASS\nhead: %s\nbase: %s\nblockers: none\nEND FINAL REVIEW' % (h.group(1), b.group(1)))
if mode == 'PASS_EXIT':
    sys.exit(7)
EOF
chmod +x "$SANDBOX/bin/claude"

OUT="$(launch final-review "$BRIEF" --head "$HEAD_SHA" --base "$BASE_SHA" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "valid review failed ($RC): $OUT"
python3 - "$EVIDENCE" "$BRIEF" "$SANDBOX/repo_under.test" "$HEAD_SHA" "$BASE_SHA" <<'PY' || fail "evidence fields are incorrect"
import json, sys
path, feature, repo, head, base = sys.argv[1:]
d = json.load(open(path, encoding='utf-8'))
assert d['feature'] == feature
assert d['repo'] == repo
assert d['head'] == head and d['base'] == base
assert d['verdict'] == 'PASS' and d['blockers'] == 'none'
assert d['backend'] == 'claude' and isinstance(d['created'], int)
PY
[ "$(wc -l <"$SANDBOX/state/final-review.calls")" -eq 1 ] || fail "review call count is not one"
python3 - "$SANDBOX/state/final-review.prompt" "$BRIEF" "$HEAD_SHA" "$BASE_SHA" <<'PY' || fail "review prompt omitted brief/identifiers/output block or read-only flags"
import sys
s=open(sys.argv[1]).read()
assert all(x in s for x in sys.argv[2:])
assert 'FINAL REVIEW' in s and 'verdict: PASS|FAIL' in s and 'blockers: none|<one line>' in s
assert '--disallowedTools' in s and 'Edit,Write,NotebookEdit' in s
PY

# Matching durable evidence makes the next invocation reuse the verdict.
OUT="$(launch final-review "$BRIEF" --head "$HEAD_SHA" --base "$BASE_SHA" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "evidence reuse failed ($RC): $OUT"
[ "$(wc -l <"$SANDBOX/state/final-review.calls")" -eq 1 ] || fail "matching evidence launched another reviewer"

# A record from a different repository must not be reused, even if its other keys match.
python3 - "$EVIDENCE" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p,encoding='utf-8')); d['repo']='/different/repository'
json.dump(d,open(p,'w',encoding='utf-8'))
PY
OUT="$(launch final-review "$BRIEF" --head "$HEAD_SHA" --base "$BASE_SHA" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "different-repository evidence was not replaced ($RC): $OUT"
[ "$(wc -l <"$SANDBOX/state/final-review.calls")" -eq 2 ] || fail "different-repository evidence was reused"

# A passing block cannot override a failing backend exit status.
rm -f "$EVIDENCE"
OUT="$(FAKE_REVIEW_MODE=PASS_EXIT launch final-review "$BRIEF" --head "$HEAD_SHA" --base "$BASE_SHA" --backend claude 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || fail "non-zero backend with PASS block unexpectedly passed"
python3 - "$EVIDENCE" <<'PY' || fail "non-zero backend exit was not persisted as FAIL"
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
assert d['verdict']=='FAIL' and d['reason']=='backend exited 7'
PY

# Timeout uses the launcher process timeout, not timeout(1), and persists the budget.
rm -f "$EVIDENCE"
OUT="$(HANDOFF_FINAL_REVIEW_TIMEOUT=1 FAKE_REVIEW_MODE=SLEEP launch final-review "$BRIEF" --head "$HEAD_SHA" --base "$BASE_SHA" --backend claude 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || fail "sleeping reviewer exceeded budget but passed"
python3 - "$EVIDENCE" <<'PY' || fail "timeout was not persisted"
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
assert d['verdict']=='FAIL' and d['reason']=='timeout after 1 s'
PY
unset FAKE_REVIEW_MODE

# The Hermes profile prerequisite is checked only after identity is resolved, so its
# failure is durable evidence and it never falls through to another profile.
rm -f "$EVIDENCE"
OUT="$(launch final-review "$BRIEF" --head "$HEAD_SHA" --base "$BASE_SHA" --backend hermes 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || fail "missing Hermes profile unexpectedly passed"
python3 - "$EVIDENCE" <<'PY' || fail "missing Hermes profile did not write FAIL evidence"
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
assert d['verdict'] == 'FAIL'
assert d['reason'] == 'hermes profile final-review missing'
PY
[ "$(wc -l <"$SANDBOX/state/final-review.calls")" -eq 4 ] || fail "Hermes prerequisite invoked a backend"

# A canonical plan resolves briefs across all phases and refuses inconsistent repos
# before creating evidence or starting a backend.
OTHER_REPO="$SANDBOX/other-repo"
mkdir -p "$OTHER_REPO"
git -C "$OTHER_REPO" init -q -b main
printf 'other\n' >"$OTHER_REPO/README.md"
git -C "$OTHER_REPO" add README.md
git -C "$OTHER_REPO" -c user.name=test -c user.email=test@example.invalid commit -q -m init
SECOND="$SANDBOX/vault/02-projects/sample/two.md"
printf '%s\n' '---' "repo: $OTHER_REPO" '---' 'brief' >"$SECOND"
PLAN="$SANDBOX/vault/02-projects/sample/plan.md"
cat >"$PLAN" <<'EOF'
---
phases:
  - name: first
    briefs:
      - one.md
  - name: second
    briefs:
      - two.md
---
EOF
OUT="$(launch final-review "$PLAN" --head "$HEAD_SHA" --base "$BASE_SHA" --backend claude 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || fail "plan with mixed repositories unexpectedly launched"
assert_no_file "${PLAN%.md}.final-review.json"
[ "$(wc -l <"$SANDBOX/state/final-review.calls")" -eq 4 ] || fail "invalid plan invoked a reviewer"

echo ok
