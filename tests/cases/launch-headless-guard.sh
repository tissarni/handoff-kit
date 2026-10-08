#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub case-guard.md draft)"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"

CALLS="$SANDBOX/state/calls.log"
assert_file "$CALLS"

[ "$(wc -l <"$CALLS")" -eq 5 ] || fail "expected exactly 5 calls.log lines, got $(wc -l <"$CALLS")"

python3 - "$CALLS" "$SANDBOX/kit" <<'PY' || fail "python assertions failed"
import json, shlex, sys, os

path, kit = sys.argv[1], sys.argv[2]
guard = os.path.join(kit, "guards", "no-background-wait.py")
recs = [json.loads(l) for l in open(path, encoding="utf-8")]

stages = [r["stage"] for r in recs]
assert stages == ["review", "revise", "run", "close", "debrief"], f"expected review,revise,run,close,debrief order, got {stages}"

for r in recs:
    sp = r.get("settings_path")
    assert sp, f"{r['stage']}: no --settings path recorded"
    settings = r.get("settings")
    assert settings, f"{r['stage']}: settings JSON missing or unparseable"
    hooks = settings.get("hooks", {}).get("PreToolUse", [])
    assert len(hooks) == 1, f"{r['stage']}: expected one PreToolUse entry, got {len(hooks)}"
    entry = hooks[0]
    assert entry.get("matcher") == "Bash", f"{r['stage']}: matcher is {entry.get('matcher')!r}, expected Bash"
    cmds = entry.get("hooks", [])
    assert len(cmds) == 1, f"{r['stage']}: expected one hook command, got {len(cmds)}"
    command = cmds[0].get("command", "")
    parts = shlex.split(command)
    assert parts == ["python3", guard], f"{r['stage']}: command {parts!r} != ['python3', {guard!r}]"
    assert os.path.isfile(guard), f"guard file does not exist: {guard}"

    argv = r["argv"]
    assert "--disallowedTools" in argv, f"{r['stage']}: no --disallowedTools in argv"
    deny = argv[argv.index("--disallowedTools") + 1]
    for tool in ("Monitor", "ScheduleWakeup", "CronCreate"):
        assert tool in deny, f"{r['stage']}: --disallowedTools {deny!r} missing {tool}"

print("ok")
PY

python3 - "$CALLS" <<'PY' || fail "a recorded settings_path file still exists after the loop"
import json, os, sys
path = sys.argv[1]
for l in open(path, encoding="utf-8"):
    r = json.loads(l)
    sp = r.get("settings_path")
    if sp and os.path.exists(sp):
        sys.exit(1)
PY

echo ok
