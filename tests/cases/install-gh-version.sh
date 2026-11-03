#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

run_install() {
  local version="$1" path="${2:-$SANDBOX/bin:/usr/bin:/bin}" out rc
  _sbx_env; local e=() v
  for v in "${SBX_ENV[@]}"; do case "$v" in PATH=*) e+=("PATH=$path");; FAKE_GH_VERSION=*) e+=("FAKE_GH_VERSION=$version");; *) e+=("$v");; esac; done
  out="$(env -i "${e[@]}" bash "$SANDBOX/kit/install.sh" --vault "$SANDBOX/vault" --defaults 02-projects/_templates/handoff-defaults.yml --projects 02-projects 2>&1)"; rc=$?
  printf '%s\n' "$rc" >"$SANDBOX/state/install.rc"
  printf '%s\n' "$out" >"$SANDBOX/state/install.out"
}
warning='install.sh: warning: gh >= 2.48 required for auto-merge, found 2.23.0'
run_install 2.23.0
[ "$(cat "$SANDBOX/state/install.rc")" -eq 0 ] || fail "old-gh install changed exit status: $(cat "$SANDBOX/state/install.out")"
assert_contains "$SANDBOX/state/install.out" "$warning"
run_install garbage
[ "$(cat "$SANDBOX/state/install.rc")" -eq 0 ] || fail "unknown-version install changed exit status"
assert_contains "$SANDBOX/state/install.out" 'install.sh: warning: gh >= 2.48 required for auto-merge, found unknown'
[ "$(/usr/bin/grep -c 'install.sh: warning: gh >= 2.48 required' "$SANDBOX/state/install.out")" -eq 1 ] || fail "unknown-version warning was not exactly one line"
run_install 2.103.3
if /usr/bin/grep -q 'gh >= 2.48 required' "$SANDBOX/state/install.out"; then fail "new gh emitted a warning"; fi
run_install 2.23.0 "$SANDBOX/no-gh:/usr/bin:/bin"
if /usr/bin/grep -q 'gh >= 2.48 required' "$SANDBOX/state/install.out"; then fail "missing gh emitted a warning"; fi
[ "$(cat "$SANDBOX/state/install.rc")" -eq 0 ] || fail "missing-gh install changed exit status"
echo ok
