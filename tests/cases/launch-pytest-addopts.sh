#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF1="$(make_brief testsub case-pytest1.md draft)"
BRIEF2="$(make_brief testsub case-pytest2.md draft)"
CALLS="$SANDBOX/state/calls.log"

unset PYTEST_ADDOPTS
OUT1="$(launch loop "$BRIEF1" --gate auto --backend claude 2>&1)"; RC1=$?
[ "$RC1" -eq 0 ] || fail "expected exit 0 for first loop, got $RC1. Output:
$OUT1"

python3 - "$CALLS" "case-pytest1" <<'PY' || fail "first loop PYTEST_ADDOPTS assertions failed"
import json, sys
path, brief = sys.argv[1], sys.argv[2]
recs = [json.loads(l) for l in open(path, encoding="utf-8") if json.loads(l)["brief"] == brief]
for r in recs:
    env = r.get("env", {})
    if r["stage"] in ("review", "run", "close"):
        assert env.get("PYTEST_ADDOPTS") == "-q --tb=short", \
            f"{r['stage']}: PYTEST_ADDOPTS = {env.get('PYTEST_ADDOPTS')!r}"
    elif r["stage"] in ("revise", "debrief"):
        assert "PYTEST_ADDOPTS" not in env, f"{r['stage']}: unexpected PYTEST_ADDOPTS = {env.get('PYTEST_ADDOPTS')!r}"
print("ok")
PY

export PYTEST_ADDOPTS=-x
OUT2="$(launch loop "$BRIEF2" --gate auto --backend claude 2>&1)"; RC2=$?
[ "$RC2" -eq 0 ] || fail "expected exit 0 for second loop, got $RC2. Output:
$OUT2"
unset PYTEST_ADDOPTS

python3 - "$CALLS" "case-pytest2" <<'PY' || fail "second loop PYTEST_ADDOPTS assertion failed"
import json, sys
path, brief = sys.argv[1], sys.argv[2]
recs = [json.loads(l) for l in open(path, encoding="utf-8") if json.loads(l)["brief"] == brief]
run = next(r for r in recs if r["stage"] == "run")
got = run.get("env", {}).get("PYTEST_ADDOPTS")
assert got == "-x -q --tb=short", f"run PYTEST_ADDOPTS = {got!r}"
print("ok")
PY

echo ok
