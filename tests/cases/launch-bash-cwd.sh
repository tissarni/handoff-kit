#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub case-bashcwd.md draft)"
CALLS="$SANDBOX/state/calls.log"

unset CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"

python3 - "$CALLS" "case-bashcwd" <<'PY' || fail "CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR assertions failed"
import json, sys
path, brief = sys.argv[1], sys.argv[2]
recs = [json.loads(l) for l in open(path, encoding="utf-8") if json.loads(l)["brief"] == brief]
stages = {r["stage"] for r in recs}
missing = {"review", "revise", "run", "close", "debrief"} - stages
assert not missing, f"stages never called: {sorted(missing)}"
for r in recs:
    got = r.get("env", {}).get("CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR")
    assert got == "1", f"{r['stage']}: CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR = {got!r}"
print("ok")
PY

echo ok
