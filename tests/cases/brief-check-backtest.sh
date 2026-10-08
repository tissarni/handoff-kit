#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

FX="$REPO_ROOT/tests/fixtures/brief-check"
_sbx_env
env -i "${SBX_ENV[@]}" bash "$FX/make-repo.sh" "$SANDBOX/tmp/fx" || fail "make-repo.sh failed"
R="$SANDBOX/tmp/fx/repo"

V="$SANDBOX/tmp/bt-vault"
D="2026-01-10T12:00:00+00:00"
mkdir -p "$V/specs"
cat >"$V/specs/demo.md" <<'BRIEF'
---
repo: /nonexistent/repo
branch: feat/nope
---

# Demo

## §0 Session preamble

- You are on `feat/x`.

## §2 State

- Commit `abc1234` holds the parser.
- `src/web/missing.js` renders the header.

## §4 Goal, and Done when

Goal: the parser accepts the new header.

1. `python3 -m pytest -q` exits 0.
2. The header looks right in the browser.

## §7 Tasks

1. Add the parser.
BRIEF
env -i "${SBX_ENV[@]}" GIT_AUTHOR_DATE="$D" GIT_COMMITTER_DATE="$D" bash -c '
  set -e
  git init -q -b main "$1"
  git -C "$1" config user.name "Test User"
  git -C "$1" config user.email test@example.com
  git -C "$1" add specs/demo.md
  git -C "$1" commit -q -m s' _ "$V" || fail "vault setup failed"
S="$(git -C "$V" rev-parse HEAD)"

TSV="$SANDBOX/tmp/labels.tsv"
T="2026-02-01T00:00:00+00:00"
{
  printf 'review_file\treview_ts\tbrief_sha\trepo\tbranch\ttag\tcategory\tsection\tfinding\n'
  printf 'specs/other.review.md\t%s\tNA\tNA\tNA\tWRONG\tjudgment\t§3\tx\n' "$T"
  row() { printf 'specs/demo.review.md\t%s\t%s\t%s\tfeat/x\t%s\t%s\t%s\t%s\n' "$T" "$S" "$R" "$1" "$2" "$3" "$4"; }
  row WRONG git '§2' one
  row WRONG git '§2' two
  row BLOCKER dw-static '§4.2' three
  row WRONG judgment '§3' four
  row WRONG symbol '§2' five
} >"$TSV"

OUT="$(env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/brief-check.sh" --backtest "$TSV" --vault "$V")"; RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"

EXPECT='backtest 1 briefs · 5 labels · skipped 1
CAT git labels=2 fail=0 (0%) fail+warn=1 (50%) approximate
CAT path labels=0
CAT line labels=0
CAT symbol labels=1 fail=0 (0%) fail+warn=0 (0%)
CAT dw-static labels=1 fail=0 (0%) fail+warn=1 (100%)
CAT boundary labels=0
CAT dw-run labels=0 no check
CAT judgment labels=1 no check
ALL checkable labels=4 fail=0 (0%) fail+warn=2 (50%)
ALL labelled labels=5 fail=0 (0%) fail+warn=2 (40%)
UNMATCHED FAIL per brief max=0 mean=0.0
UNMATCHED WARN per brief max=1 mean=1.0
UNMATCHED by check sweep=0/0 git=0/0 path=0/1 line=0/0 symbol=0/0 size=0/0 boundary=0/0 done-when=0/0
BRIEF specs/demo.review.md labels=5 matched=2 unmatched-fail=0 unmatched-warn=1'
[ "$OUT" = "$EXPECT" ] || fail "expected:
$EXPECT
got:
$OUT"

OUT4="$(env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/brief-check.sh" --backtest "$TSV" --vault "$V" --fail sweep,git,path,line)"; RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0 with --fail, got $RC. Output:
$OUT4"
EXPECT4='backtest 1 briefs · 5 labels · skipped 1
CAT git labels=2 fail=1 (50%) fail+warn=1 (50%) approximate
CAT path labels=0
CAT line labels=0
CAT symbol labels=1 fail=0 (0%) fail+warn=0 (0%)
CAT dw-static labels=1 fail=0 (0%) fail+warn=1 (100%)
CAT boundary labels=0
CAT dw-run labels=0 no check
CAT judgment labels=1 no check
ALL checkable labels=4 fail=1 (25%) fail+warn=2 (50%)
ALL labelled labels=5 fail=1 (20%) fail+warn=2 (40%)
UNMATCHED FAIL per brief max=1 mean=1.0
UNMATCHED WARN per brief max=0 mean=0.0
UNMATCHED by check sweep=0/0 git=0/0 path=1/0 line=0/0 symbol=0/0 size=0/0 boundary=0/0 done-when=0/0
BRIEF specs/demo.review.md labels=5 matched=2 unmatched-fail=1 unmatched-warn=0'
[ "$OUT4" = "$EXPECT4" ] || fail "expected:
$EXPECT4
got:
$OUT4"

env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/brief-check.sh" --backtest "$TSV" --vault "$V" --fail nosuch >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "expected exit 2 for --fail nosuch, got $RC"

echo ok
