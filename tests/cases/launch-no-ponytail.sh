#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub case-lite-mode.md draft)"
/usr/bin/sed -i 's/ponytail-mode: full/ponytail-mode: lite/' "$BRIEF"
CALLS="$SANDBOX/state/calls.log"

OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"

python3 - "$CALLS" <<'PY' || fail "no call may carry PONYTAIL_DEFAULT_MODE"
import json, sys
for l in open(sys.argv[1], encoding="utf-8"):
    r = json.loads(l)
    if "PONYTAIL_DEFAULT_MODE" in r.get("env", {}):
        sys.exit(1)
PY

DRY="$(launch review "$BRIEF" --dry-run --backend claude 2>&1)"
printf '%s\n' "$DRY" | grep -qi 'ponytail' && fail "expected no 'ponytail' (case-insensitive) in --dry-run output:
$DRY"

echo ok
