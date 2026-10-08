#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub case-close-defaults.md draft)"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"

CALLS="$SANDBOX/state/calls.log"
assert_file "$CALLS"

python3 - "$CALLS" <<'PY' || fail "python assertions failed"
import json, sys

def argval(argv, flag):
    return argv[argv.index(flag) + 1] if flag in argv else None

recs = {r["stage"]: r for r in (json.loads(l) for l in open(sys.argv[1], encoding="utf-8"))}

close = recs["close"]["argv"]
assert argval(close, "--model") == "sonnet", f"close --model = {argval(close, '--model')!r}"
assert argval(close, "--effort") == "medium", f"close --effort = {argval(close, '--effort')!r}"
assert argval(close, "--permission-mode") == "bypassPermissions", f"close --permission-mode = {argval(close, '--permission-mode')!r}"
deny = argval(close, "--disallowedTools") or ""
assert "Edit,Write,NotebookEdit" in deny, f"close --disallowedTools = {deny!r}"

for stage in ("revise", "debrief"):
    argv = recs[stage]["argv"]
    assert argval(argv, "--effort") == "medium", f"{stage} --effort = {argval(argv, '--effort')!r}"

print("ok")
PY

echo ok
