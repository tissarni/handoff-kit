#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub case-h.md draft)"
NAME="$(basename "$BRIEF" .md)"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"

python3 - "$SANDBOX/state/calls.log" <<'PY'
import json, re, sys
calls = [json.loads(l) for l in open(sys.argv[1], encoding='utf-8')]
by_stage = {}
for c in calls:
    by_stage.setdefault(c['stage'], c)
for stage in ('review', 'revise', 'run', 'close', 'debrief'):
    assert stage in by_stage, f"no call logged for stage {stage}"
    argv = by_stage[stage]['argv']
    assert '--session-id' in argv, f"{stage}: no --session-id in argv: {argv}"
    i = argv.index('--session-id')
    assert '--' in argv and argv.index('--') > i, f"{stage}: --session-id not before --: {argv}"
    v = argv[i + 1]
    assert re.match(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', v), f"{stage}: bad session id {v}"
vals = [by_stage[s]['argv'][by_stage[s]['argv'].index('--session-id') + 1] for s in ('review', 'revise', 'run', 'close', 'debrief')]
assert len(set(vals)) == 5, f"session ids are not all distinct: {vals}"
print("ok")
PY
[ $? -eq 0 ] || fail "session-id check failed"

USAGE_LOG="${BRIEF%.md}.usage.log"
assert_file "$USAGE_LOG"
python3 - "$USAGE_LOG" "$NAME" <<'PY'
import sys
path, name = sys.argv[1:3]
lines = [l for l in open(path, encoding='utf-8').read().splitlines() if l.strip()]
expected = [f"USAGE {name} {s} turns=1 in=3 cw=100 cr=200 out=20 cost=0.0007" for s in
            ("review", "revise", "run", "close", "debrief")]
assert lines == expected, f"expected {expected}, got {lines}"
PY
[ $? -eq 0 ] || fail "usage.log content check failed"

echo ok
