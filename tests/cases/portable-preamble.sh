#!/usr/bin/env bash
# The portable preamble is the same in the five entry points, sits right above each one's
# first `set` line, and the hooks stay bash 3.2 and POSIX.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"

SRC="${HANDOFF_SCRIPTS_DIR:-$REPO_ROOT}"
FILES=("$SRC/handoff-launch.sh" "$SRC/handoff-orchestrate.sh" "$SRC/brief-check.sh" "$SRC/install.sh" "$REPO_ROOT/tests/lib.sh")

ref=""
for f in "${FILES[@]}"; do
  [ "$(/usr/bin/grep -c -x '# >>> portable preamble' "$f")" = 1 ] || fail "$f: not exactly one opening marker"
  [ "$(/usr/bin/grep -c -x '# <<< portable preamble' "$f")" = 1 ] || fail "$f: not exactly one closing marker"
  end="$(/usr/bin/grep -n -x '# <<< portable preamble' "$f" | cut -d: -f1)"
  start="$(/usr/bin/grep -n -x '# >>> portable preamble' "$f" | cut -d: -f1)"
  first_set="$(/usr/bin/grep -n '^set ' "$f" | head -1 | cut -d: -f1)"
  [ "$first_set" = "$((end+1))" ] || fail "$f: the first set line is not right after the preamble"
  block="$(sed -n "${start},${end}p" "$f")"
  [ "$(printf '%s\n' "$block" | wc -l)" -gt 2 ] || fail "$f: the preamble holds only its markers"
  if [ -z "$ref" ]; then ref="$block"; else [ "$block" = "$ref" ] || fail "$f: preamble differs from the others"; fi
done

for h in "$REPO_ROOT"/hooks/*; do
  [ -f "$h" ] || continue
  for w in mapfile readarray 'declare -A' 'local -A' ',,}' '^^}' 'sed -i'; do
    ! /usr/bin/grep -qF -e "$w" "$h" || fail "$h holds '$w'"
  done
  ! /usr/bin/grep -q -E '(^|[[:space:]|(!])grep -' "$h" || fail "$h calls a bare grep"
done

echo ok
