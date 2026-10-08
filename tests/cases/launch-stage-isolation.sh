#!/usr/bin/env bash
# Every claude stage starts with the claude.ai connectors off, and with each user-scope
# plugin off unless the stage's own project enables it (repo for run/close/review, vault for
# revise/debrief). A watched run passes its settings inline, so no temp file outlives it.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

REPO="$SANDBOX/repo_under.test"
mkdir -p "$SANDBOX/home/.claude" "$REPO/.claude" "$SANDBOX/vault/.claude"
cat >"$SANDBOX/home/.claude/settings.json" <<'JSON'
{"enabledPlugins": {"alpha@market": true, "beta@market": true, "gamma@market": false}}
JSON
echo '{"enabledPlugins": {"beta@market": true}}' >"$REPO/.claude/settings.json"
( builtin cd "$REPO" && git add .claude/settings.json && HOME="$SANDBOX/home" git commit -qm "test: project plugins" )
echo '{"enabledPlugins": {"alpha@market": true}}' >"$SANDBOX/vault/.claude/settings.json"

BRIEF="$(make_brief testsub case-iso.md draft)"
OUT="$(launch loop "$BRIEF" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"

RUNBRIEF="$(make_brief testsub case-iso-run.md ready)"
OUT="$(launch run "$RUNBRIEF" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "watched run: expected exit 0, got $RC. Output:
$OUT"

CALLS="$SANDBOX/state/calls.log"
assert_file "$CALLS"

python3 - "$CALLS" <<'PY' || fail "python assertions failed: ENABLE_CLAUDEAI_MCP_SERVERS / enabledPlugins"
import json, os, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
loop, watched = recs[:-1], recs[-1]
assert [r["stage"] for r in loop] == ["review", "revise", "run", "close", "debrief"], [r["stage"] for r in loop]
for r in recs:
    assert r["env"].get("ENABLE_CLAUDEAI_MCP_SERVERS") == "false", f"{r['stage']}: ENABLE_CLAUDEAI_MCP_SERVERS not false"
want = {"review": "alpha@market", "run": "alpha@market", "close": "alpha@market",
        "revise": "beta@market", "debrief": "beta@market"}
for r in loop:
    s = r.get("settings") or {}
    assert s.get("enabledPlugins") == {want[r["stage"]]: False}, f"{r['stage']}: enabledPlugins {s.get('enabledPlugins')!r}"
    assert len(s.get("hooks", {}).get("PreToolUse", [])) == 1, f"{r['stage']}: guard hook missing"
    assert r.get("settings_path"), f"{r['stage']}: no settings file"
    assert not os.path.exists(r["settings_path"]), f"{r['stage']}: settings file left behind"
assert watched["stage"] == "run"
assert "settings_path" not in watched, "watched run used a settings file"
assert (watched.get("settings") or {}).get("enabledPlugins") == {"alpha@market": False}, "watched run: enabledPlugins"
assert "hooks" not in watched["settings"], "watched run carries a hook"
assert watched["argv"].index("--settings") < watched["argv"].index("--"), "--settings after --"
PY

OUT="$(launch run "$RUNBRIEF" --dry-run --backend claude 2>&1)"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF '  plugins off: alpha@market' || fail "dry-run lacks plugins off line. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF '  settings:    inline' || fail "dry-run lacks inline settings. Output:
$OUT"
echo ok
