#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

FIXTURE="$REPO_ROOT/tests/fixtures/usage/11111111-1111-4111-8111-111111111111.jsonl"

OUT="$(env -i PATH=/usr/bin:/bin python3 "$SANDBOX/kit/handoff-usage.py" "$FIXTURE" b1 run)"; RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output: $OUT"
EXPECT='USAGE b1 run turns=3 in=17 cw=1800 cr=3000 out=450 cost=0.0243'
[ "$OUT" = "$EXPECT" ] || fail "expected '$EXPECT', got '$OUT'"

NONE="$SANDBOX/tmp/none.jsonl"
OUT2="$(env -i PATH=/usr/bin:/bin python3 "$SANDBOX/kit/handoff-usage.py" "$NONE" b1 run)"; RC2=$?
[ "$RC2" -eq 0 ] || fail "no-transcript: expected exit 0, got $RC2. Output: $OUT2"
EXPECT2="USAGE b1 run unavailable — no transcript at $NONE"
[ "$OUT2" = "$EXPECT2" ] || fail "no-transcript: expected '$EXPECT2', got '$OUT2'"

echo ok
