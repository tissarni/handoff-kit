#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

GUARD="$REPO_ROOT/guards/no-background-wait.py"
[ -f "$GUARD" ] || fail "guard not found: $GUARD"

RC=0
STDERR="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"sleep 1","run_in_background":true}}' | python3 "$GUARD" 2>&1 1>/dev/null)" || RC=$?
[ "$RC" -eq 2 ] || fail "expected exit 2 on run_in_background:true, got $RC"
printf '%s' "$STDERR" | grep -qF 'headless stage: run it in the foreground' \
  || fail "expected stderr to contain 'headless stage: run it in the foreground', got: $STDERR"

check_allows() {   # $1 = input
  local rc=0 err
  err="$(printf '%s' "$1" | python3 "$GUARD" 2>&1 1>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0 for input $1, got $rc (stderr: $err)"
  [ -z "$err" ] || fail "expected empty stderr for input $1, got: $err"
}
check_allows '{"tool_input":{"command":"ls"}}'
check_allows '{"tool_input":{"run_in_background":false}}'
check_allows 'not json'
check_allows ''

echo ok
