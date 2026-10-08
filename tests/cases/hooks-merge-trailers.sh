#!/usr/bin/env bash
# The handoff commit hooks under an agent session: a plain non-fast-forward `git merge`
# commits and carries the Harness:/Model: trailers (in a checkout and in a linked
# worktree), a normal commit does too, and commit-msg still refuses a message with
# Co-Authored-By or without the trailers. Self-contained: runs under tests/run.sh or
# alone with `bash tests/cases/hooks-merge-trailers.sh`.
set -uo pipefail
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 HANDOFF_HARNESS HANDOFF_MODEL GIT_DIR GIT_INDEX_FILE

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }

SANDBOX="$(mktemp -d)"
echo "SANDBOX=$SANDBOX"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME"
printf '[user]\n\tname = Test User\n\temail = test@example.com\n[init]\n\tdefaultBranch = main\n' >"$HOME/.gitconfig"

# The session hook dir, built by the launcher's own install_git_hooks.
HOOKS_DIR="$SANDBOX/git-hooks"
KIT="$REPO_ROOT"
die() { fail "install_git_hooks: $*"; }
eval "$(sed -n '/^install_git_hooks() {/,/^}/p' "$REPO_ROOT/handoff-launch.sh")"
[ "$HOOKS_DIR" = "$SANDBOX/git-hooks" ] || fail "HOOKS_DIR left the sandbox"

R="$SANDBOX/repo"
git init -q "$R"
G() { git -C "$R" "$@"; }
echo base >"$R/a"; G add a; G commit -q -m base
G branch dev
G checkout -q -b feat; echo feat >"$R/f"; G add f; G commit -q -m "feat: one"
G checkout -q dev; echo dev >"$R/d"; G add d; G commit -q -m "dev: moved"
G checkout -q feat
G worktree add -q -b feat-wt "$SANDBOX/wt" feat
install_git_hooks "$R"

export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS_DIR"
export HANDOFF_HARNESS=claude-code HANDOFF_MODEL=sonnet GIT_EDITOR=true

trailers_of() { git -C "$1" log -1 --format=%B | git interpret-trailers --parse; }
expect_trailers() {   # $1 = repo dir, $2 = what
  local t; t="$(trailers_of "$1")"
  printf '%s\n' "$t" | /usr/bin/grep -qx 'Harness: claude-code' || fail "$2: no Harness trailer in: $(git -C "$1" log -1 --format=%B)"
  printf '%s\n' "$t" | /usr/bin/grep -qx 'Model: sonnet' || fail "$2: no Model trailer"
}

for d in "$R" "$SANDBOX/wt"; do
  out="$(git -C "$d" merge dev 2>&1)" || fail "merge in $d did not commit: $out"
  [ "$(git -C "$d" rev-list --parents -1 HEAD | wc -w)" = 3 ] || fail "HEAD in $d is not a merge commit"
  [ "$(git -C "$d" log -1 --format=%s)" = "Merge branch 'dev' into $(git -C "$d" branch --show-current)" ] || fail "merge subject changed in $d"
  expect_trailers "$d" "merge in $d"
done

echo more >>"$R/f"; G add f
G commit -q -m "feat: two" -m "Co-Authored-By: Someone <s@example.com>" || fail "normal commit refused"
expect_trailers "$R" "normal commit"
G log -1 --format=%B | /usr/bin/grep -qi 'Co-Authored-By' && fail "Co-Authored-By survived prepare-commit-msg"

# commit-msg alone: what it sees when prepare-commit-msg was bypassed.
(cd "$R" && printf 'subject\n\nbody\n' >"$SANDBOX/m1" && ! "$HOOKS_DIR/commit-msg" "$SANDBOX/m1" 2>/dev/null) \
  || fail "commit-msg accepted a message without trailers"
(cd "$R" && printf 'subject\n\nHarness: claude-code\nModel: sonnet\nCo-Authored-By: X <x@example.com>\n' >"$SANDBOX/m2" \
  && ! "$HOOKS_DIR/commit-msg" "$SANDBOX/m2" 2>/dev/null) || fail "commit-msg accepted Co-Authored-By"
echo "ok"
