#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

FX="$REPO_ROOT/tests/fixtures/brief-check"
_sbx_env
env -i "${SBX_ENV[@]}" bash "$FX/make-repo.sh" "$SANDBOX/tmp/fx" || fail "make-repo.sh failed"
R="$SANDBOX/tmp/fx/repo"
C1="$(git -C "$R" rev-parse 'v1.0.0^{commit}')"
F2="$(git -C "$R" rev-parse feat/x)"

(
  cd "$R"
  export HOME="$SANDBOX/home"
  export GIT_AUTHOR_DATE="2026-01-09T12:00:00+00:00" GIT_COMMITTER_DATE="2026-01-09T12:00:00+00:00"
  git checkout -q -b tmp/old "$C1"
  git commit -q --allow-empty -m m1
) || fail "tmp/old setup failed"

(
  cd "$R"
  export HOME="$SANDBOX/home"
  export GIT_AUTHOR_DATE="2026-01-20T12:00:00+00:00" GIT_COMMITTER_DATE="2026-01-20T12:00:00+00:00"
  git checkout -q feat/x
  git merge -q --no-ff --no-edit tmp/old
  git commit -q --allow-empty -m f3
  git push -q origin feat/x
  git checkout -q -b feat/late main
  git tag -a v1.2.0 -m v1.2.0 main
) || fail "merge/F3 setup failed"

F3="$(git -C "$R" rev-parse feat/x)"
[ "$(git -C "$R" rev-parse feat/x~2)" = "$F2" ] || fail "expected feat/x~2 == original F2"

BRIEF="$SANDBOX/tmp/at-brief.md"
cat >"$BRIEF" <<EOF
---
repo: $R
branch: feat/x
---

# At fixture

## §0 Session preamble

- First step: \`git checkout -b feat/late origin/dev\`.

## §2 State

- \`feat/x\` @ \`$F2\`.
- The latest tag is \`v1.1.0\`.
EOF

OUT="$(env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/brief-check.sh" "$BRIEF")"; RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"

F3SHORT="${F3:0:7}"
LINE1="$(printf '%s\n' "$OUT" | head -1)"
case "$LINE1" in
  *"@ feat/x $F3SHORT") ;;
  *) fail "expected line1 to end '@ feat/x $F3SHORT', got '$LINE1'";;
esac

NLINES="$(printf '%s\n' "$OUT" | /usr/bin/grep -c .)"
[ "$NLINES" -eq 5 ] || fail "expected 5 lines, got $NLINES. Output:
$OUT"

N0="$(/usr/bin/grep -nF 'feat/late origin/dev' "$BRIEF" | head -1 | cut -d: -f1)"
NF2="$(/usr/bin/grep -nF "feat/x\` @ \`$F2\`" "$BRIEF" | head -1 | cut -d: -f1)"
NTAG="$(/usr/bin/grep -nF 'The latest tag is' "$BRIEF" | head -1 | cut -d: -f1)"

printf '%s\n' "$OUT" | /usr/bin/grep -qF "WARN git §0 $N0 " || fail "expected WARN git §0 $N0. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF "WARN git §2 $NF2 " || fail "expected WARN git §2 $NF2. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF "WARN git §2 $NTAG " || fail "expected WARN git §2 $NTAG. Output:
$OUT"

LASTLINE="$(printf '%s\n' "$OUT" | tail -1)"
[ "$LASTLINE" = "RESULT 0 FAIL · 3 WARN" ] || fail "expected RESULT 0 FAIL · 3 WARN, got '$LASTLINE'. Output:
$OUT"

OUT2="$(env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/brief-check.sh" "$BRIEF" --at 2026-01-10T00:00:00+00:00)"; RC2=$?
[ "$RC2" -eq 0 ] || fail "expected exit 0 with --at, got $RC2. Output:
$OUT2"

F2SHORT="${F2:0:7}"
EXPECT2="brief-check $BRIEF · repo $R @ feat/x $F2SHORT (as of 2026-01-10T00:00:00+00:00)
RESULT 0 FAIL · 0 WARN"
[ "$OUT2" = "$EXPECT2" ] || fail "expected:
$EXPECT2
got:
$OUT2"

echo ok
