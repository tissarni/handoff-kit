#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

B="$(make_brief testsub publication.md ready)"
cat >>"$B" <<'EOF'

## Current task

Current HEAD: synthetic-head-1
Publication owner: supervisor

Tasks:
1. Implement the single synthetic task.
EOF

# The actual generated run prompt must retain the normalized current brief and owner.
OUT="$(launch run "$B" --publication-owner supervisor --backend claude 2>&1)" || fail "supervisor run failed: $OUT"
EVIDENCE_DIR="${HANDOFF_EVIDENCE_DIR:-${TMPDIR:-/tmp}/handoff-bootstrap-evidence}"
mkdir -p "$EVIDENCE_DIR"
python3 - "$SANDBOX/state/calls.log" "$EVIDENCE_DIR/supervisor-run-prompt.txt" <<'PY' || fail "supervisor prompt contract failed"
import json, sys
rec = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8') if line.strip()][-1]
prompt = rec['argv'][-1]
need = ['Publication owner: supervisor', 'Current HEAD: synthetic-head-1', '1. Implement the single synthetic task.']
missing = [s for s in need if s not in prompt]
assert not missing, 'missing normalized brief text: %r' % missing
assert 'git push origin <branch>' not in prompt, 'supervisor prompt mandates runner publication'
assert 'gh pr create --draft' not in prompt and 'glab mr create --draft' not in prompt, 'supervisor prompt mandates PR creation'
assert prompt.count('synthetic-head-1') == 1, 'historical/current HEAD override leaked into prompt'
assert rec['stage'] == 'run'
open(sys.argv[2], 'w', encoding='utf-8').write(prompt)
PY

# The default owner preserves existing runner publication requirements.
B2="$(make_brief testsub runner-publication.md ready)"
launch run "$B2" --backend claude >/dev/null 2>&1 || fail "default-owner run failed"
python3 - "$SANDBOX/state/calls.log" <<'PY' || fail "default runner publication prompt contract failed"
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8') if line.strip()]
prompt = rows[-1]['argv'][-1]
assert 'git push origin <branch>' in prompt
assert 'gh pr create --draft --base <base>' in prompt
assert 'Trusted launcher publication owner: runner' in prompt
PY

# The selected owner survives the loop's one fix-up/resume, too.
B4="$(make_brief testsub supervisor-fixup.md ready)"
printf '## Revise outcome\n\ngate: clean\n' >"${B4%.md}.review.md"
FAKE_CLAUDE="run=complete,close=FAIL-fixable-once"
OUT="$(launch loop "$B4" --gate auto --publication-owner supervisor --backend claude 2>&1)" || fail "supervisor fix-up loop failed: $OUT"
python3 - "$SANDBOX/state/calls.log" <<'PY' || fail "supervisor ownership did not survive fix-up resume"
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8') if line.strip()]
run = next(r for r in rows if r['stage'] == 'run' and r['brief'] == 'supervisor-fixup')
resume = next(r for r in rows if r['stage'] == 'resume' and r['brief'] == 'supervisor-fixup')
assert 'Trusted launcher publication owner: supervisor' in run['argv'][-1]
note = resume['argv'][-1]
assert 'commit any fix locally and do not publish it' in note
assert 'git push origin' not in note and 'PR create' not in note
PY

# Reject unsupported ownership before any agent stage is launched.
B3="$(make_brief testsub invalid-owner.md ready)"
CALL_COUNT="$(python3 -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if l.strip()))' "$SANDBOX/state/calls.log")"
if OUT="$(launch run "$B3" --publication-owner forged --backend claude 2>&1)"; then
  fail "invalid publication owner was accepted"
fi
python3 - "$SANDBOX/state/calls.log" "$CALL_COUNT" <<'PY' || fail "invalid owner launched an agent stage"
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8') if line.strip()]
assert len(rows) == int(sys.argv[2]), 'unexpected stage launch after invalid owner'
PY

echo ok