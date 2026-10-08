#!/usr/bin/env bash
# A plan on the kit's own checkout is refused before git; a worktree runs; a stage started
# by name (no .sh) is seen by the scan.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

R="$SANDBOX/repo_under.test"
gitr() { env -i HOME="$SANDBOX/home" PATH=/usr/bin:/bin git -C "$R" "$@"; }

# 1. refused, before git
KG="$(make_brief subk kg-brief.md draft)"
PLAN="$(dirname "$KG")/kg-plan.md"
make_plan "$PLAN" "$KG"
STATUS="${PLAN%.md}.status.md"
is_done() { [ -f "$STATUS" ] && head -1 "$STATUS" | /usr/bin/grep -q '^DONE'; }
cp -R "$SANDBOX/kit" "$R/handoff-kit"
_sbx_env
OUT="$(env -i "${SBX_ENV[@]}" bash "$R/handoff-kit/handoff-orchestrate.sh" start "$PLAN" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 2 ] || fail "step 1: expected exit 2, got $RC: $OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF 'preflight:kit — ' || fail "step 1: no preflight:kit: $OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF "worktree add --detach $SANDBOX/repo_under.test-testsub origin/main" || fail "step 1: no worktree line: $OUT"
OUT="$(env -i "${SBX_ENV[@]}" HANDOFF_ORCH_ALLOW_CONCURRENT=1 bash "$R/handoff-kit/handoff-orchestrate.sh" start "$PLAN" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 2 ] || fail "step 1 concurrent: expected exit 2, got $RC: $OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF 'preflight:kit — ' || fail "step 1 concurrent: no preflight:kit: $OUT"
[ "$(gitr branch --show-current)" = main ] || fail "step 1: repo branch moved"
assert_no_file "$R/.git/handoff-plan.lock"
/usr/bin/grep -q '^orchestration: planned' "$PLAN" || fail "step 1: plan no longer planned"
assert_no_file "${PLAN%.md}.lock"
assert_no_file "${PLAN%.md}.baseline"

# 2. a worktree runs it
gitr worktree add -q --detach "$R-testsub" origin/main || fail "step 2: worktree add failed"
sed -i "s#^repo: .*#repo: $R-testsub#" "$KG"
FAKE_CLAUDE="run=commit"
_sbx_env
OUT="$(env -i "${SBX_ENV[@]}" bash "$R/handoff-kit/handoff-orchestrate.sh" start "$PLAN" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "step 2: expected exit 0, got $RC: $OUT"
wait_for 120 is_done || fail "step 2: never reached DONE: $(head -3 "$STATUS" 2>/dev/null)"
wait_for 30 test ! -f "${PLAN%.md}.lock" || fail "step 2: driver kept its lock"
rm -rf "$R/handoff-kit"

# 3. a stage started by name is seen
Q1="$(make_brief subr q1-brief.md draft)"
PB="$(make_brief subq pb-brief.md draft)"
PQ="$(dirname "$PB")/q-plan.md"
make_plan "$PQ" "$PB"
mkdir -p "$SANDBOX/tmp/byname"
printf '%s\n' 'while :; do sleep 1; done' >"$SANDBOX/tmp/byname/handoff-launch"
bash "$SANDBOX/tmp/byname/handoff-launch" loop "$Q1" --backend claude & SPID=$!
wait_for 10 pgrep -f "$SANDBOX/tmp/byname/handoff-launch loop " || fail "step 3: stand-in never visible to pgrep"
OUT="$(orch start "$PQ" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 2 ] || fail "step 3: expected exit 2, got $RC: $OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF 'preflight:launcher — ' || fail "step 3: no preflight:launcher: $OUT"
assert_no_file "$R/.git/handoff-plan.lock"
[ "$(gitr branch --show-current)" = main ] || fail "step 3: repo branch moved"
kill "$SPID"; wait "$SPID" 2>/dev/null

echo ok
