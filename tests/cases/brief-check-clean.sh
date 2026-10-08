#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

FX="$REPO_ROOT/tests/fixtures/brief-check"
_sbx_env
env -i "${SBX_ENV[@]}" bash "$FX/make-repo.sh" "$SANDBOX/tmp/fx" || fail "make-repo.sh failed"
R="$SANDBOX/tmp/fx/repo"

mkdir -p "$R/02-projects/demo"
printf '# Demo\n' >"$R/02-projects/demo/context.md"
(
  cd "$R"
  export HOME="$SANDBOX/home"
  export GIT_AUTHOR_DATE="2026-01-08T12:00:00+00:00" GIT_COMMITTER_DATE="2026-01-08T12:00:00+00:00"
  git add 02-projects/demo/context.md
  git commit -q -m "add demo context"
  git push -q origin feat/x
) || fail "clean fixture commit/push failed"

HSHA="$(git -C "$R" rev-parse feat/x)"

BRIEF="$SANDBOX/tmp/clean-brief.md"
cat >"$BRIEF" <<EOF
---
repo: $R
branch: feat/x
---

# Clean fixture

## §0 Session preamble

- You are on \`feat/x\`, in sync with origin at \`$HSHA\`.

## §1 Why this exists

The vault keeps its notes under \`02-projects/\`.

## §2 State

- \`feat/x\` @ \`$HSHA\`, 3 commits ahead of \`dev\`, 1 behind.
- \`02-projects/demo/context.md\` holds the sub's context.
- \`src/app.py:10\` defines \`make_thing\`.

## §4 Goal, and Done when

Goal: the parser accepts the new header.

1. \`python3 -m pytest -q tests\` exits 0.
2. \`git status --porcelain\` prints nothing.

## §6 Constraints

- Never edit \`src/app.py\` by hand.

## §7 Tasks

1. Write the parser.
2. Add the tests.
3. Sync, push, update the PR.
EOF

OUT="$(env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/brief-check.sh" "$BRIEF")"; RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"

HSHORT="${HSHA:0:7}"
EXPECT="brief-check $BRIEF · repo $R @ feat/x $HSHORT
RESULT 0 FAIL · 0 WARN"
[ "$OUT" = "$EXPECT" ] || fail "expected:
$EXPECT
got:
$OUT"

echo ok
