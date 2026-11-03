#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

STATUS=""
EVENTS=""
BRIEF=""
PLAN=""

prepare_closed_phase() {  # $1 = name, $2 = publication owner
  local name="$1" owner="$2" out rc
  BRIEF="$(make_brief testsub "$name-brief.md" draft)"
  PLAN="$(dirname "$BRIEF")/$name-plan.md"
  make_plan "$PLAN" "$BRIEF"
  STATUS="${PLAN%.md}.status.md"
  EVENTS="${PLAN%.md}.events.log"
  FAKE_CLAUDE="close=FAIL"
  out="$(orch start "$PLAN" --backend claude --publication-owner "$owner" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || fail "$name: start failed ($rc): $out"
  is_broken() { [ -f "$STATUS" ] && /usr/bin/grep -q '^NEEDS YOU' "$STATUS"; }
  wait_for 120 is_broken || fail "$name: phase did not break: $(head -1 "$STATUS" 2>/dev/null)"
  [ "$(state_of "$BRIEF")" = closed ] || fail "$name: expected closed brief, got $(state_of "$BRIEF")"
  rm -f "$SANDBOX/state/gh-pr-url" "$SANDBOX/state/gh.log"
}

add_unpushed_commit() {
  local repo="$SANDBOX/repo_under.test"
  printf '%s\n' "$1" >"$repo/$1.txt"
  git -C "$repo" add "$1.txt"
  git -C "$repo" -c user.name='Test User' -c user.email=test@example.com commit -q -m "$1"
}

# Runner recovery publishes the already-closed phase before marking it done.
prepare_closed_phase runner runner
add_unpushed_commit runner-unpushed
EXPECTED_HEAD="$(git -C "$SANDBOX/repo_under.test" rev-parse HEAD)"
OUT="$(orch resume "$PLAN" --backend claude --publication-owner runner 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "runner resume: expected exit 0, got $RC: $OUT"
ORIGIN_HEAD="$(git --git-dir="$SANDBOX/origin.git" rev-parse refs/heads/feat/test 2>/dev/null || true)"
[ "$ORIGIN_HEAD" = "$EXPECTED_HEAD" ] || fail "runner resume: origin has $ORIGIN_HEAD, expected $EXPECTED_HEAD"
python3 - "$EVENTS" <<'PY' || fail "runner resume: publication events must precede PHASE DONE"
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
push = next((i for i, line in enumerate(lines) if ' PUSH ' in f' {line}'), None)
pr = next((i for i, line in enumerate(lines) if ' PR opened (draft) ' in f' {line}'), None)
done = next((i for i, line in enumerate(lines) if ' PHASE DONE 1 ' in f' {line}'), None)
assert push is not None and pr is not None and done is not None, (push, pr, done)
assert push < done and pr < done, (push, pr, done)
PY
assert_contains "$SANDBOX/state/gh.log" 'pr create --draft'
head -1 "$STATUS" | /usr/bin/grep -q '^DONE · phase 1/1' || fail "runner resume: expected DONE, got $(head -1 "$STATUS")"

# Supervisor recovery leaves the unpushed commit local and never creates a PR.
prepare_closed_phase supervisor supervisor
add_unpushed_commit supervisor-unpushed
EXPECTED_HEAD="$(git --git-dir="$SANDBOX/origin.git" rev-parse refs/heads/feat/test)"
LOCAL_HEAD="$(git -C "$SANDBOX/repo_under.test" rev-parse HEAD)"
[ "$LOCAL_HEAD" != "$EXPECTED_HEAD" ] || fail "supervisor setup: expected a local-only commit"
OUT="$(orch resume "$PLAN" --backend claude --publication-owner supervisor 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "supervisor resume: expected exit 0, got $RC: $OUT"
[ "$(git --git-dir="$SANDBOX/origin.git" rev-parse refs/heads/feat/test)" = "$EXPECTED_HEAD" ] \
  || fail "supervisor resume changed origin"
if [ -f "$SANDBOX/state/gh.log" ] && /usr/bin/grep -q 'pr create' "$SANDBOX/state/gh.log"; then
  fail "supervisor resume created a PR"
fi
assert_contains "$EVENTS" 'PUBLICATION held for supervisor at phase end'

# A rejected runner push breaks the phase before PHASE DONE or PR creation.
prepare_closed_phase rejected runner
add_unpushed_commit rejected-unpushed
cat >"$SANDBOX/origin.git/hooks/pre-receive" <<'HOOK'
#!/bin/sh
exit 1
HOOK
chmod +x "$SANDBOX/origin.git/hooks/pre-receive"
OUT="$(orch resume "$PLAN" --backend claude --publication-owner runner 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "rejected resume: break_phase should return 0, got $RC: $OUT"
head -1 "$STATUS" | /usr/bin/grep -q '^NEEDS YOU · broken .*run:push' \
  || fail "rejected resume: expected broken run:push status, got $(head -1 "$STATUS")"
assert_contains "$STATUS" 'run:push'
if /usr/bin/grep -q 'PHASE DONE' "$EVENTS"; then fail "rejected resume recorded PHASE DONE"; fi
if [ -f "$SANDBOX/state/gh.log" ] && /usr/bin/grep -q 'pr create' "$SANDBOX/state/gh.log"; then
  fail "rejected resume attempted PR creation"
fi

echo ok
