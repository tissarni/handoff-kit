#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

run_install() {
  local version="$1" path="${2:-$SANDBOX/bin:/usr/bin:/bin}" out rc
  _sbx_env; local e=() v
  local found=0
  for v in "${SBX_ENV[@]}"; do case "$v" in PATH=*) e+=("PATH=$path");; FAKE_GH_VERSION=*) e+=("FAKE_GH_VERSION=$version"); found=1;; *) e+=("$v");; esac; done
  [ "$found" -eq 1 ] || e+=("FAKE_GH_VERSION=$version")
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
mkdir -p "$SANDBOX/no-gh"
make_path_without_gh "$SANDBOX/no-gh"
if env PATH="$SANDBOX/no-gh" bash -c 'command -v gh' >/dev/null 2>&1; then fail "gh resolved in gh-less PATH"; fi
for name in systemctl launchctl curl; do
  resolved="$(env PATH="$SANDBOX/no-gh" bash -c 'command -v "$1"' bash "$name")"
  [ -n "$resolved" ] || fail "$name missing from gh-less PATH"
  target="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$resolved")"
  expected="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SANDBOX/bin/$name")"
  [ "$target" = "$expected" ] || fail "$name did not resolve to sandbox fake: $target"
done
bash_path="$(env PATH="$SANDBOX/no-gh" bash -c 'command -v bash')"
[ -n "$bash_path" ] && [ -x "$bash_path" ] || fail "bash missing or not executable in gh-less PATH"
case "${OSTYPE:-}" in darwin*)
  bash_major="$(env PATH="$SANDBOX/no-gh" bash -c 'printf "%s" "${BASH_VERSINFO[0]}"')"
  [ "$bash_major" -ge 4 ] || fail "gh-less PATH selected bash $bash_major; need bash 4 or newer" ;;
esac
run_install 2.23.0 "$SANDBOX/no-gh"
if /usr/bin/grep -q 'gh >= 2.48 required' "$SANDBOX/state/install.out"; then fail "missing gh emitted a warning"; fi
[ "$(cat "$SANDBOX/state/install.rc")" -eq 0 ] || fail "missing-gh install changed exit status"
echo ok
