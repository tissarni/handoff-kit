#!/usr/bin/env bash
# Builds <dir>/repo and its bare origin <dir>/origin.git, both with `git init -b main`.
# Every write runs with GIT_AUTHOR_DATE/GIT_COMMITTER_DATE pinned to its step's day, so
# every SHA is the same on every run given the sandbox's fixed name and email.
set -euo pipefail

DIR="$1"
REPO="$DIR/repo"
ORIGIN="$DIR/origin.git"

at() {   # $1 = YYYY-MM-DD, then the git command
  local day="$1"; shift
  GIT_AUTHOR_DATE="${day}T12:00:00+00:00" GIT_COMMITTER_DATE="${day}T12:00:00+00:00" "$@"
}

mkdir -p "$REPO"
git init -q -b main "$REPO"
git -C "$REPO" config user.name "Test User"
git -C "$REPO" config user.email test@example.com

mkdir -p "$REPO/src/web" "$REPO/tests"
printf '# Fixture repo\n' >"$REPO/README.md"
printf '# Agents\n\n- Never push to main.\n' >"$REPO/AGENTS.md"

{
  for n in $(seq 1 40); do
    if [ "$n" -eq 10 ]; then
      echo 'def make_thing():'
    elif [ "$n" -eq 20 ]; then
      echo 'class WidgetPanel:'
    else
      echo "# line $n"
    fi
  done
} >"$REPO/src/app.py"

{
  for n in $(seq 1 20); do
    if [ "$n" -eq 5 ]; then
      echo 'export function computeTotal(items) {'
    else
      echo "// line $n"
    fi
  done
} >"$REPO/src/web/helpers.js"

printf 'def test_nothing():\n    assert True\n' >"$REPO/tests/test_app.py"

git -C "$REPO" add -A
at 2026-01-01 git -C "$REPO" commit -q -m c1
at 2026-01-01 git -C "$REPO" tag -a v1.0.0 -m v1.0.0

at 2026-01-02 git -C "$REPO" commit -q --allow-empty -m c2
at 2026-01-02 git -C "$REPO" tag -a v1.1.0 -m v1.1.0

at 2026-01-03 git -C "$REPO" checkout -q -b dev
at 2026-01-03 git -C "$REPO" commit -q --allow-empty -m d1

at 2026-01-04 git -C "$REPO" checkout -q -b feat/x
at 2026-01-04 git -C "$REPO" commit -q --allow-empty -m f1

at 2026-01-05 git -C "$REPO" checkout -q dev
at 2026-01-05 git -C "$REPO" commit -q --allow-empty -m d2

at 2026-01-06 git -C "$REPO" checkout -q feat/x
at 2026-01-06 git -C "$REPO" commit -q --allow-empty -m f2

git init -q --bare "$ORIGIN"
git -C "$REPO" remote add origin "$ORIGIN"
at 2026-01-06 git -C "$REPO" push -q origin main
at 2026-01-06 git -C "$REPO" push -q origin dev
at 2026-01-06 git -C "$REPO" push -q -u origin feat/x

at 2026-01-07 git -C "$REPO" checkout -q -b feat/local-only main

git -C "$REPO" checkout -q feat/x
