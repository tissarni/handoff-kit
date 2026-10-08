#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub case-hlenv.md draft)"
RUNBRIEF="$(make_brief testsub case-hlenv-run.md ready)"
CALLS="$SANDBOX/state/calls.log"

unset CLAUDE_CODE_DISABLE_BACKGROUND_TASKS BASH_DEFAULT_TIMEOUT_MS BASH_MAX_TIMEOUT_MS
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"

# Dry-runs first: the interactive run moves its brief to running.
WANT='  env:         CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 BASH_DEFAULT_TIMEOUT_MS=600000 BASH_MAX_TIMEOUT_MS=900000 ENABLE_CLAUDEAI_MCP_SERVERS=false'
OUT="$(launch run "$RUNBRIEF" --delegate --dry-run --backend claude 2>&1)"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF "$WANT" || fail "delegate dry-run lacks env line. Output:
$OUT"
OUT="$(launch run "$RUNBRIEF" --dry-run --backend claude 2>&1)"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF '  env:         ENABLE_CLAUDEAI_MCP_SERVERS=false' || fail "interactive dry-run lacks the connectors-off env line. Output:
$OUT"

OUT="$(launch run "$RUNBRIEF" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "interactive run: expected exit 0, got $RC. Output:
$OUT"

python3 - "$CALLS" <<'PY' || fail "headless env assertions failed"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
loop = [r for r in recs if r["brief"] == "case-hlenv"]
stages = [r["stage"] for r in loop]
assert stages == ["review", "revise", "run", "close", "debrief"], f"stages: {stages}"
want = {"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
        "BASH_DEFAULT_TIMEOUT_MS": "600000", "BASH_MAX_TIMEOUT_MS": "900000"}
names = set(want)
for r in loop:
    got = {k: v for k, v in r["env"].items() if k in names}
    assert got == want, f"{r['stage']}: env {got!r}"
inter = [r for r in recs if r["brief"] == "case-hlenv-run"]
assert len(inter) == 1, f"interactive records: {len(inter)}"
r = inter[0]
assert "-p" not in r["argv"], "interactive run has -p"
leak = names & set(r["env"])
assert not leak, f"interactive env has {sorted(leak)}"
print("ok")
PY

echo ok
