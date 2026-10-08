#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

FX="$REPO_ROOT/tests/fixtures/brief-check"
_sbx_env
env -i "${SBX_ENV[@]}" bash "$FX/make-repo.sh" "$SANDBOX/tmp/fx" || fail "make-repo.sh failed"
R="$SANDBOX/tmp/fx/repo"
printf 'build-out/\n' >>"$R/.git/info/exclude"

H="$SANDBOX/tmp/fx/helperlib"
env -i "${SBX_ENV[@]}" bash -c '
  set -e
  git init -q -b main "$1"
  git -C "$1" config user.name "Test User"
  git -C "$1" config user.email test@example.com
  mkdir -p "$1/lib"
  printf "x = 1\n" >"$1/lib/other_only.py"
  git -C "$1" add -A
  GIT_AUTHOR_DATE=2026-01-01T12:00:00+00:00 GIT_COMMITTER_DATE=2026-01-01T12:00:00+00:00 \
    git -C "$1" commit -q -m o1
  git -C "$1" branch feat/other-only
' _ "$H" || fail "helperlib setup failed"
O1="$(git -C "$H" rev-parse HEAD)" || fail "no helperlib commit"

BRIEF="$SANDBOX/tmp/false-alarms-brief.md"
python3 - "$FX/false-alarms-brief.md.in" "$BRIEF" "$R" "$H" "${O1:0:7}" <<'PY'
import sys
src, dst, repo, other, o1 = sys.argv[1:6]
t = open(src, encoding='utf-8').read()
pairs = '[' * 2 + 'lon, lat], [lon, lat]]'
t = (t.replace('@REPO@', repo).replace('@OTHER@', other).replace('@O1@', o1)
      .replace('@PAIRS@', pairs))
open(dst, 'w', encoding='utf-8').write(t)
PY

OUT="$(env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/brief-check.sh" "$BRIEF")"; RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"

LASTLINE="$(printf '%s\n' "$OUT" | tail -1)"
[ "$LASTLINE" = "RESULT 0 FAIL · 6 WARN" ] || fail "expected RESULT line, got '$LASTLINE'. Output:
$OUT"

EXP_ROWS="$(
  while IFS=$'\t' read -r level check section string; do
    n="$(/usr/bin/grep -nF -- "$string" "$BRIEF" | head -1 | cut -d: -f1)"
    [ -n "$n" ] || fail "fixture string not found in brief: $string"
    printf '%s %s %s %s\n' "$n" "$level" "$check" "$section"
  done <"$FX/false-alarms-expected.tsv" | sort -n -k1,1
)"
EXP_ROWS="$(printf '%s\n' "$EXP_ROWS" | awk '{print $2, $3, $4, $1}')"
GOT_ROWS="$(printf '%s\n' "$OUT" | /usr/bin/grep -E '^(FAIL|WARN) ' | awk '{print $1, $2, $3, $4}')"

[ "$GOT_ROWS" = "$EXP_ROWS" ] || fail "findings mismatch.
expected:
$EXP_ROWS
got:
$GOT_ROWS"

echo ok
