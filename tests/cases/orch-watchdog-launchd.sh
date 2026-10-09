#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub i-brief1.md draft)"
PLAN="$(dirname "$BRIEF")/i-plan.md"
make_plan "$PLAN" "$BRIEF"
STATUS="${PLAN%.md}.status.md"
EVENTS="${PLAN%.md}.events.log"
LOG="$SANDBOX/state/launchctl.log"

_sbx_env
RESOLVED="$(env -i "${SBX_ENV[@]}" bash -c 'command -v launchctl')"
assert_eq "$RESOLVED" "$SANDBOX/bin/launchctl" "launchctl must resolve to the fake"

touch "$SANDBOX/state/launchctl.on"
N="$(printf '%s' "$(readlink -f "$PLAN")" | cksum | cut -d' ' -f1)"
LABEL="handoff-watchdog.$N"
PLIST="$SANDBOX/home/Library/LaunchAgents/$LABEL.plist"
LOADED="$SANDBOX/state/launchctl.loaded.$LABEL"

FAKE_CLAUDE="run=wait"
OUT="$(orch start "$PLAN" --backend claude 2>&1)"
printf '%s\n' "$OUT" | /usr/bin/grep -qF "watchdog agent: $LABEL (armed)" || fail "expected armed line, got:
$OUT"
assert_contains "$EVENTS" "WATCHDOG armed"
assert_file "$PLIST"
assert_file "$LOADED"

python3 - "$PLIST" "$LABEL" "$SANDBOX/home" "$PLAN" <<'PY' || fail "plist content wrong"
import plistlib, sys
plist, label, home, plan = sys.argv[1:5]
d = plistlib.load(open(plist, "rb"))
assert d["Label"] == label, d["Label"]
want = ["/usr/bin/env", "bash", home + "/.local/bin/handoff-orchestrate", "tick", plan]
assert d["ProgramArguments"] == want, d["ProgramArguments"]
assert d["StartInterval"] == 1800
assert d["EnvironmentVariables"]["PATH"].startswith("/opt/homebrew/bin:")
PY
cp "$PLIST" "$SANDBOX/state/plist.saved"

wait_for 60 test -f "$SANDBOX/state/run-started" || fail "run stage never started"
touch "$SANDBOX/state/run-release"

has_plist_line() { /usr/bin/grep -q '^plist=' "$LOG"; }
wait_for 60 has_plist_line || fail "driver never retired the agent"
assert_no_file "$PLIST"
assert_no_file "$LOADED"
assert_contains "$EVENTS" "WATCHDOG retired"
/usr/bin/grep -q '^plist=absent$' "$LOG" || fail "expected plist=absent in $LOG"

# The tick's backstop: put the agent back and let a tick retire it.
cp "$SANDBOX/state/plist.saved" "$PLIST"
touch "$LOADED"
TICKOUT="$(orch tick "$PLAN" 2>&1)"
printf '%s\n' "$TICKOUT" | /usr/bin/grep -qF "watchdog agent retired: $LABEL" || fail "expected retired line, got:
$TICKOUT"
assert_no_file "$PLIST"
assert_no_file "$LOADED"
[ "$(/usr/bin/grep -c '^plist=absent$' "$LOG")" = 2 ] || fail "expected a second plist=absent in $LOG"

echo ok
