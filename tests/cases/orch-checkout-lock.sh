#!/usr/bin/env bash
# One plan per checkout: start locks the checkout in its git dir before the branch moves,
# refuses a second plan with the worktree command, and only phase_done releases the lock.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

REPO_UT="$SANDBOX/repo_under.test"
LK="$REPO_UT/.git/handoff-plan.lock"
GIT_ENV=(env -i "HOME=$SANDBOX/home" "PATH=/usr/bin:/bin")

new_plan() {   # $1 = sub -> sets BRIEF and PLAN
  BRIEF="$(make_brief "$1" "$1-brief.md" draft)"
  PLAN="$(dirname "$BRIEF")/plan.md"
  make_plan "$PLAN" "$BRIEF"
}
plan_state() { /usr/bin/grep -m1 '^orchestration:' "$1" | awk '{print $2}'; }
done_status() { head -1 "${1%.md}.status.md" 2>/dev/null | /usr/bin/grep -q '^DONE'; }
driver_exited() { /usr/bin/grep -q 'driver exiting' "${1%.md}.events.log" 2>/dev/null; }

# 1. Held by a broken plan.
new_plan suba; BRIEF_A="$BRIEF"; PLAN_A="$PLAN"
/usr/bin/sed -i 's/^orchestration: planned$/orchestration: planned          # planned -> running/' "$PLAN_A"
FAKE_CLAUDE="close=FAIL"
orch start "$PLAN_A" --backend claude >/dev/null 2>&1
wait_for 60 driver_exited "$PLAN_A" || fail "A: driver did not exit within 60s"
[ "$(plan_state "$PLAN_A")" = broken ] || fail "A: expected broken, got '$(plan_state "$PLAN_A")'"
[ "$(state_of "$BRIEF_A")" = closed ] || fail "A: expected brief closed"
[ -f "$LK" ] || fail "A: expected $LK"
assert_eq "$(cat "$LK")" "$(readlink -f "$PLAN_A")" "lock content"

# 2. A second plan is refused before git moves anything.
new_plan subb; BRIEF_B="$BRIEF"; PLAN_B="$PLAN"
/usr/bin/sed -i -e 's/^branch: feat\/test$/branch: feat\/other/' -e 's/^project: testsub$/project: subb\nsetup: make deps/' "$PLAN_B"
OUT="$(orch start "$PLAN_B" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 2 ] || fail "B: expected exit 2, got $RC. Output:
$OUT"
for want in 'preflight:checkout — ' '(orchestration: broken)' \
            "worktree add --detach $REPO_UT-subb origin/main" '&& make deps)'; do
  printf '%s\n' "$OUT" | /usr/bin/grep -qF -- "$want" || fail "B: expected '$want' in output:
$OUT"
done
assert_eq "$("${GIT_ENV[@]}" git -C "$REPO_UT" branch --show-current)" feat/test "repo branch moved"
[ "$(plan_state "$PLAN_B")" = planned ] || fail "B: expected planned"
assert_no_file "${PLAN_B%.md}.lock"
assert_no_file "${PLAN_B%.md}.baseline"
assert_eq "$(cat "$LK")" "$(readlink -f "$PLAN_A")" "lock changed by the refusal"

# 3. The worktree runs it.
"${GIT_ENV[@]}" git -C "$REPO_UT" worktree add -q --detach "$REPO_UT-subb" origin/main \
  || fail "worktree add failed"
/usr/bin/sed -i "s|^repo: .*|repo: $REPO_UT-subb|" "$BRIEF_B"
WT_GIT="$("${GIT_ENV[@]}" git -C "$REPO_UT-subb" rev-parse --absolute-git-dir)"
FAKE_CLAUDE="run=commit"
OUT="$(orch start "$PLAN_B" --backend claude 2>&1)" || fail "B in worktree: start failed:
$OUT"
wait_for 120 done_status "$PLAN_B" || fail "B: no DONE status within 120s: $(head -1 "${PLAN_B%.md}.status.md")"
assert_no_file "$WT_GIT/handoff-plan.lock"
assert_eq "$(cat "$LK")" "$(readlink -f "$PLAN_A")" "A's lock after B finished"

# 4. Done releases it.
OUT="$(orch resume "$PLAN_A" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "A resume: expected exit 0, got $RC. Output:
$OUT"
[ "$(plan_state "$PLAN_A")" = done ] || fail "A: expected done"
assert_no_file "$LK"

# 5. A stale lock is taken; a running plan holds.
readlink -f "$PLAN_A" >"$LK"
new_plan subc; PLAN_C="$PLAN"
FAKE_CLAUDE="run=wait"
OUT="$(orch start "$PLAN_C" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "C: expected exit 0, got $RC. Output:
$OUT"
assert_eq "$(cat "$LK")" "$(readlink -f "$PLAN_C")" "C's lock"
wait_for 60 test -f "$SANDBOX/state/run-started" || fail "C: run stage never started"

new_plan subd; PLAN_D="$PLAN"
OUT="$(orch start "$PLAN_D" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 2 ] || fail "D: expected exit 2, got $RC. Output:
$OUT"
for want in 'preflight:checkout — ' '(orchestration: running)'; do
  printf '%s\n' "$OUT" | /usr/bin/grep -qF -- "$want" || fail "D: expected '$want' in output:
$OUT"
done
_sbx_env
OUT="$(env -i "${SBX_ENV[@]}" HANDOFF_ORCH_ALLOW_CONCURRENT=1 bash "$SANDBOX/kit/handoff-orchestrate.sh" start "$PLAN_D" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 2 ] || fail "D concurrent: expected exit 2, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF 'preflight:checkout — ' || fail "D concurrent: expected the same refusal:
$OUT"

touch "$SANDBOX/state/run-release"
wait_for 120 done_status "$PLAN_C" || fail "C: no DONE status within 120s"
assert_no_file "$LK"

echo ok
