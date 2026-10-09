#!/usr/bin/env bash
# The orchestrator without setsid, flock and pgrep on PATH: python3 stands in for the first
# two, ps for the third, and the disk threshold is read under mawk.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

# A PATH holding every system tool except the three.
python3 - "$SANDBOX/sysbin" <<'PY'
import os, sys
dst = sys.argv[1]
os.makedirs(dst)
skip = {'setsid', 'flock', 'pgrep'}
seen = set()
for d in ('/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin'):
    if not os.path.isdir(d):
        continue
    for n in os.listdir(d):
        if n in skip or n in seen:
            continue
        seen.add(n)
        os.symlink(os.path.join(d, n), os.path.join(dst, n))
PY
SBX_PATH="$SANDBOX/bin:$SANDBOX/sysbin"
for t in setsid flock pgrep; do
  ! env -i PATH="$SBX_PATH" bash -c "command -v $t" >/dev/null 2>&1 || fail "$t is still on the sandbox PATH"
done

REPO_UT="$SANDBOX/repo_under.test"
P1="$(make_brief subp p1.md draft)"
PLAN="$(dirname "$P1")/plan.md"
make_plan "$PLAN" "$P1"
Q1="$(make_brief subq q1.md draft)"
DEFS="$SANDBOX/vault/02-projects/_templates/handoff-defaults.yml"

# (a) the disk threshold is read from the indented key
sed -i 's/disk-min-free-gb: 0/disk-min-free-gb: 999999/' "$DEFS"
OUT="$(orch start "$PLAN" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 2 ] || fail "disk: expected exit 2, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF 'preflight:disk — ' || fail "disk: no preflight:disk in:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF 'threshold 999999 GB' || fail "disk: threshold not read in:
$OUT"
sed -i 's/disk-min-free-gb: 999999/disk-min-free-gb: 0/' "$DEFS"

# (b) the stage scan finds a running stage without pgrep
mkdir -p "$SANDBOX/tmp/stage"
printf '%s\n' 'while :; do sleep 1; done' >"$SANDBOX/tmp/stage/handoff-launch.sh"
bash "$SANDBOX/tmp/stage/handoff-launch.sh" resume "$Q1" &
STAND=$!
wait_for 10 pgrep -f "$SANDBOX/tmp/stage/handoff-launch.sh resume " || fail "stand-in never visible to pgrep"
OUT="$(orch start "$PLAN" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 2 ] || fail "scan: expected exit 2, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF 'preflight:launcher — ' || fail "scan: no preflight:launcher in:
$OUT"
kill "$STAND" 2>/dev/null; wait "$STAND" 2>/dev/null

# (c) a driver and a loop that lead their own sessions
FAKE_CLAUDE="run=wait"
OUT="$(orch start "$PLAN" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "start: expected exit 0, got $RC. Output:
$OUT"
wait_for 60 test -f "$SANDBOX/state/run-started" || fail "run stage never started"
pgid_of() { ps -o pgid= -p "$1" | tr -d '[:space:]'; }
DPID="$(awk '/^pid /{print $2; exit}' "${PLAN%.md}.lock")"
[ -n "$DPID" ] || DPID="$(cut -d' ' -f2 "${PLAN%.md}.lock")"
LPID="$(cut -d' ' -f2 "${PLAN%.md}.stage")"
assert_eq "$(pgid_of "$DPID")" "$DPID" "driver is not its own group leader"
assert_eq "$(pgid_of "$LPID")" "$LPID" "loop is not its own group leader"

# (d) the tick lock, held by python3 here and by python3 in the script
READY="$SANDBOX/tick-ready"; REL="$SANDBOX/tick-release"
python3 - "${PLAN%.md}.lock.tick" "$READY" "$REL" <<'PY' &
import fcntl, os, sys, time
f = open(sys.argv[1], 'a')
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[2], 'w').close()
while not os.path.exists(sys.argv[3]):
    time.sleep(0.2)
PY
HOLD=$!
wait_for 10 test -f "$READY" || fail "lock holder never ready"
OUT="$(orch tick "$PLAN" 2>&1)"
assert_eq "$OUT" "tick: another tick holds the lock"
touch "$REL"; wait "$HOLD"
OUT="$(orch tick "$PLAN" 2>&1)"
printf '%s\n' "$OUT" | /usr/bin/grep -q '^tick: ok' || fail "expected 'tick: ok', got:
$OUT"

# (e) the phase finishes
touch "$SANDBOX/state/run-release"
STATUS="${PLAN%.md}.status.md"
is_done() { [ -f "$STATUS" ] && head -1 "$STATUS" | /usr/bin/grep -q '^DONE'; }
wait_for 60 is_done || fail "phase did not finish (status: $(head -1 "$STATUS" 2>/dev/null))"

echo ok
