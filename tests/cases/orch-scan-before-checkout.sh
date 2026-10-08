#!/usr/bin/env bash
# The stage scan sees a hand-launched resume or lesson, and refuses before the branch moves.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

REPO_UT="$SANDBOX/repo_under.test"
P1="$(make_brief subp p1.md draft)"
PLAN="$(dirname "$P1")/plan.md"
make_plan "$PLAN" "$P1"
Q1="$(make_brief subq q1.md draft)"

mkdir -p "$SANDBOX/tmp/stage"
printf '%s\n' 'while :; do sleep 1; done' >"$SANDBOX/tmp/stage/handoff-launch.sh"

for mode in resume lesson; do
  bash "$SANDBOX/tmp/stage/handoff-launch.sh" "$mode" "$Q1" &
  STAND=$!
  wait_for 10 pgrep -f "handoff-launch.sh $mode " || fail "$mode: stand-in never visible to pgrep"

  OUT="$(orch start "$PLAN" --backend claude 2>&1)"; RC=$?
  [ "$RC" -eq 2 ] || fail "$mode: expected exit 2, got $RC. Output:
$OUT"
  printf '%s\n' "$OUT" | /usr/bin/grep -qF 'preflight:launcher — ' || fail "$mode: expected preflight:launcher in output:
$OUT"

  CUR="$(env -i HOME="$SANDBOX/home" PATH=/usr/bin:/bin git -C "$REPO_UT" branch --show-current)"
  assert_eq "$CUR" main "$mode: repo branch moved"
  assert_no_file "$REPO_UT/.git/handoff-plan.lock"
  /usr/bin/grep -q '^orchestration: planned$' "$PLAN" || fail "$mode: plan no longer planned"

  kill "$STAND" 2>/dev/null; wait "$STAND" 2>/dev/null
  pkill -f "$SANDBOX/tmp/stage/handoff-launch.sh $mode " 2>/dev/null || true
done

echo ok
