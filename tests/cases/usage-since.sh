#!/usr/bin/env bash
# A resumed session appends to the transcript it continues: --since counts only the rows
# stamped at or after it, subagents included, and a row with no timestamp not at all.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

T="$SANDBOX/tmp/22222222-2222-4222-8222-222222222222.jsonl"
mkdir -p "${T%.jsonl}/subagents"
python3 - "$T" "${T%.jsonl}/subagents/agent-a.jsonl" <<'PY'
import json, sys
main, sub = sys.argv[1:3]
def row(mid, ts, out):
    r = {"type": "assistant", "message": {"id": mid, "model": "claude-sonnet-5",
         "usage": {"input_tokens": 1, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": out}}}
    if ts:
        r["timestamp"] = ts
    return json.dumps(r) + "\n"
open(main, 'w').write(row('m1', '2026-10-01T10:00:00.000Z', 10) + row('m2', '2026-10-01T10:05:00.250Z', 20) + row('m3', None, 30))
open(sub, 'w').write(row('s1', '2026-10-01T10:01:00.000Z', 40) + row('s2', '2026-10-01T10:06:00.000Z', 50))
PY
U() { env -i PATH=/usr/bin:/bin python3 "$SANDBOX/kit/handoff-usage.py" "$@"; }
SINCE="$(date -u -d 2026-10-01T10:05:00Z +%s)"

OUT="$(U "$T" b1 resume --since "$SINCE")"; RC=$?
[ "$RC" -eq 0 ] || fail "since: exit $RC. Output: $OUT"
assert_eq "$OUT" 'USAGE b1 resume turns=2 in=2 cw=0 cr=0 out=70 cost=0.0011' "since"

OUT="$(U "$T" b1 run)"; RC=$?
[ "$RC" -eq 0 ] || fail "all: exit $RC. Output: $OUT"
assert_eq "$OUT" 'USAGE b1 run turns=5 in=5 cw=0 cr=0 out=150 cost=0.0023' "no --since"

U "$T" b1 resume --since soon >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "a bad --since value: expected exit 2, got $RC"

echo ok
