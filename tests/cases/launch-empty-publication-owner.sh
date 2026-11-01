#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub empty-owner.md ready)"
for kind in equals separate trailing-equals trailing-separate; do
  case "$kind" in
    equals) args=(--publication-owner=) ;;
    separate) args=(--publication-owner '') ;;
    trailing-equals) args=(--publication-owner supervisor --publication-owner=) ;;
    trailing-separate) args=(--publication-owner supervisor --publication-owner '') ;;
  esac
  if OUT="$(launch run "$BRIEF" "${args[@]}" --backend claude 2>&1)"; then
    fail "launcher accepted explicit empty owner selection ($kind)"
  fi
  [ ! -f "$SANDBOX/state/calls.log" ] || fail "empty owner selection launched a stage ($kind)"
  [ "$(git -C "$SANDBOX/repo_under.test" branch --show-current)" = main ] || fail "empty owner selection moved the branch ($kind)"
  if git --git-dir="$SANDBOX/origin.git" show-ref --verify --quiet refs/heads/feat/test; then
    fail "empty owner selection published a branch ($kind)"
  fi
  [ ! -f "$SANDBOX/state/gh.log" ] || fail "empty owner selection wrote through gh ($kind)"
done

echo ok
