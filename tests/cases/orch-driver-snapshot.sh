#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub j-brief1.md draft)"
PLAN="$(dirname "$BRIEF")/j-plan.md"
make_plan "$PLAN" "$BRIEF"
STATUS="${PLAN%.md}.status.md"
LOCK="${PLAN%.md}.lock"

FAKE_CLAUDE="run=wait"
# VAULT deliberately unset: the orchestrator must read it from config.env.
mkdir -p "$SANDBOX/home/.config/handoff"
printf 'VAULT=%s\n' "$SANDBOX/vault" >"$SANDBOX/home/.config/handoff/config.env"
orch_novault start "$PLAN" --backend claude >/dev/null 2>&1

wait_for 60 test -f "$SANDBOX/state/run-started" || fail "run stage never started"

# Sabotage mid-phase: overwrite the live launcher in place, and append a canary line to
# the live orchestrator. Neither must reach the running driver if it is running a
# snapshot, as opposed to the live files.
printf '#!/usr/bin/env bash\nexit 99\n' >"$SANDBOX/kit/handoff-launch.sh"
printf '\ntouch "$FAKE_STATE_DIR/appended-line-ran"\n' >>"$SANDBOX/kit/handoff-orchestrate.sh"

touch "$SANDBOX/state/run-release"

# From here on, poll only files — never call orch/tick/status, which would run the
# live orchestrator's own final case...esac again (and thus the appended line).
done_seen=0
i=0
while [ "$i" -lt 60 ]; do
  if [ -f "$STATUS" ] && sed -n '1p' "$STATUS" | grep -q '^DONE'; then done_seen=1; break; fi
  sleep 1
  i=$((i+1))
done
[ "$done_seen" -eq 1 ] || fail "phase did not reach DONE within 60s (status: $(sed -n '1p' "$STATUS" 2>/dev/null))"
[ ! -f "$LOCK" ] || fail "expected lock file to be gone"
assert_no_file "$SANDBOX/state/appended-line-ran"
assert_file "${PLAN%.md}.driver/handoff-launch.sh"
assert_file "${PLAN%.md}.driver/handoff-orchestrate.sh"

echo ok
