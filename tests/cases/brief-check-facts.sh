#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

FX="$REPO_ROOT/tests/fixtures/brief-check"
_sbx_env
env -i "${SBX_ENV[@]}" bash "$FX/make-repo.sh" "$SANDBOX/tmp/fx" || fail "make-repo.sh failed"
R="$SANDBOX/tmp/fx/repo"
D1="$(git -C "$R" rev-parse dev~1)"
D2="$(git -C "$R" rev-parse dev)"
C2="$(git -C "$R" rev-parse main)"

(
  cd "$R"
  export HOME="$SANDBOX/home"
  export GIT_AUTHOR_DATE="2026-01-08T12:00:00+00:00" GIT_COMMITTER_DATE="2026-01-08T12:00:00+00:00"
  git commit -q --allow-empty -m f3
  git fetch -q origin
  touch -d '2026-01-25 12:00:00 UTC' .git/FETCH_HEAD
  echo scratch >scratch.txt
) || fail "facts fixture setup failed"

F3="$(git -C "$R" rev-parse feat/x)"

D1SHORT="${D1:0:7}"; D2SHORT="${D2:0:7}"; C2SHORT="${C2:0:7}"; F3SHORT="${F3:0:7}"

OUT="$(env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/brief-check.sh" --facts "$R" feat/x)"; RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"

EXPECT="repo $R
head feat/x $F3SHORT
branch feat/x local $F3SHORT
upstream origin/feat/x
upstream-delta 1 ahead 0 behind
base origin/dev $D2SHORT d2
base-delta 3 ahead 1 behind merge-base $D1SHORT
latest-tag v1.1.0 $C2SHORT
tree 1 changed
fetched 2026-01-25T12:00:00+00:00"
[ "$OUT" = "$EXPECT" ] || fail "expected:
$EXPECT
got:
$OUT"

OUT2="$(env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/brief-check.sh" --facts "$R" feat/nope)"; RC2=$?
[ "$RC2" -eq 0 ] || fail "expected exit 0, got $RC2. Output:
$OUT2"

EXPECT2="repo $R
head feat/x $F3SHORT
branch feat/nope missing
upstream none
upstream-delta -
base origin/dev $D2SHORT d2
base-delta -
latest-tag v1.1.0 $C2SHORT
tree 1 changed
fetched 2026-01-25T12:00:00+00:00"
[ "$OUT2" = "$EXPECT2" ] || fail "expected:
$EXPECT2
got:
$OUT2"

echo ok
