#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

FX="$REPO_ROOT/tests/fixtures/brief-check"
_sbx_env
env -i "${SBX_ENV[@]}" bash "$FX/make-repo.sh" "$SANDBOX/tmp/fx" || fail "make-repo.sh failed"

R="$SANDBOX/tmp/fx/repo"
C1="$(git -C "$R" rev-parse 'v1.0.0^{commit}')" || fail "no v1.0.0"
D1="$(git -C "$R" rev-parse dev~1)" || fail "no dev~1"
D2="$(git -C "$R" rev-parse dev)" || fail "no dev"
F2="$(git -C "$R" rev-parse feat/x)" || fail "no feat/x"

BRIEF="$SANDBOX/tmp/rules-brief.md"
python3 - "$FX/rules-brief.md.in" "$BRIEF" "$R" "$C1" "$D1" "$D2" "$F2" <<'PY'
import sys
src, dst, repo, c1, d1, d2, f2 = sys.argv[1:8]
t = open(src, encoding='utf-8').read()
t = (t.replace('@REPO@', repo).replace('@C1@', c1).replace('@D1@', d1)
      .replace('@D2@', d2).replace('@F2@', f2).replace('@LINK@', '[[design-note]]'))
open(dst, 'w', encoding='utf-8').write(t)
PY

OUT="$(env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/brief-check.sh" "$BRIEF")"; RC=$?
[ "$RC" -eq 1 ] || fail "expected exit 1, got $RC. Output:
$OUT"

F2SHORT="${F2:0:7}"
LINE1="$(printf '%s\n' "$OUT" | head -1)"
EXPECT1="brief-check $BRIEF · repo $R @ feat/x $F2SHORT"
[ "$LINE1" = "$EXPECT1" ] || fail "expected line1 '$EXPECT1', got '$LINE1'"

LASTLINE="$(printf '%s\n' "$OUT" | tail -1)"
[ "$LASTLINE" = "RESULT 1 FAIL · 27 WARN" ] || fail "expected RESULT line, got '$LASTLINE'. Output:
$OUT"

COUNT="$(printf '%s\n' "$OUT" | /usr/bin/grep -cE '^(FAIL|WARN) ')"
[ "$COUNT" -eq 28 ] || fail "expected 28 findings, got $COUNT. Output:
$OUT"

EXP_ROWS="$(
  while IFS=$'\t' read -r level check section string; do
    n="$(/usr/bin/grep -nF -- "$string" "$BRIEF" | head -1 | cut -d: -f1)"
    [ -n "$n" ] || fail "fixture string not found in brief: $string"
    printf '%s %s %s %s\n' "$n" "$level" "$check" "$section"
  done <"$FX/rules-expected.tsv" | sort -n -k1,1
)"
EXP_ROWS="$(printf '%s\n' "$EXP_ROWS" | awk '{print $2, $3, $4, $1}')"

GOT_ROWS="$(printf '%s\n' "$OUT" | /usr/bin/grep -E '^(FAIL|WARN) ' | awk '{print $1, $2, $3, $4}')"

[ "$GOT_ROWS" = "$EXP_ROWS" ] || fail "findings mismatch.
expected:
$EXP_ROWS
got:
$GOT_ROWS"

NOTE_NUM="$(printf '%s\n' "$OUT" | /usr/bin/grep -nF 'NOTE boundary AGENTS.md:3 — Never push to main.' | head -1 | cut -d: -f1)"
[ -n "$NOTE_NUM" ] || fail "expected NOTE boundary line. Output:
$OUT"
LAST_FINDING_NUM="$(printf '%s\n' "$OUT" | /usr/bin/grep -nE '^(FAIL|WARN) ' | tail -1 | cut -d: -f1)"
RESULT_NUM="$(printf '%s\n' "$OUT" | /usr/bin/grep -n '^RESULT ' | head -1 | cut -d: -f1)"
[ "$NOTE_NUM" -gt "$LAST_FINDING_NUM" ] || fail "NOTE not after last finding"
[ "$NOTE_NUM" -lt "$RESULT_NUM" ] || fail "NOTE not before RESULT"

env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/brief-check.sh" >/dev/null 2>&1
[ "$?" -eq 2 ] || fail "expected exit 2 with no args"

env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/brief-check.sh" "$SANDBOX/tmp/does-not-exist.md" >/dev/null 2>&1
[ "$?" -eq 2 ] || fail "expected exit 2 for missing brief"

echo ok
