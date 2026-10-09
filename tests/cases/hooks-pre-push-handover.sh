#!/usr/bin/env bash
# The handoff pre-push hook under an agent session: it refuses a push onto a shared
# branch before the repo's own pre-push runs, and otherwise hands over to that hook with
# git's ref lines replayed on its stdin and its arguments intact, keeping its exit status.
# Self-contained: runs under tests/run.sh or alone with `bash tests/cases/hooks-pre-push-handover.sh`.
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

# The session hook dir, built by the launcher's own install_git_hooks, from the kit under test.
HOOKS_DIR="$SANDBOX/git-hooks"
KIT="${HANDOFF_SCRIPTS_DIR:-$REPO_ROOT}"
die() { fail "install_git_hooks: $*"; }
eval "$(sed -n '/^install_git_hooks() {/,/^}/p' "$KIT/handoff-launch.sh")"
[ "$HOOKS_DIR" = "$SANDBOX/git-hooks" ] || fail "HOOKS_DIR left the sandbox"

git init -q --bare "$SANDBOX/origin.git"
R="$SANDBOX/repo"
git init -q "$R"
G() { git -C "$R" "$@"; }
echo base >"$R/a"; G add a; G commit -q -m base
G remote add origin "$SANDBOX/origin.git"
G branch b1; G branch b2
install_git_hooks "$R"

OWN="$R/.git/hooks/pre-push"
CAP="$SANDBOX/cap"
install_own() {   # $1 = exit status of the own hook
  mkdir -p "$CAP"; rm -f "$CAP"/*
  printf '#!/usr/bin/env bash\ncat >"%s/stdin"\nprintf "%%s\\n" "$@" >"%s/args"\ntouch "%s/ran"\nexit %s\n' "$CAP" "$CAP" "$CAP" "$1" >"$OWN"
  chmod +x "$OWN"
}

export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS_DIR"
ZEROS="0000000000000000000000000000000000000000"

# One branch: the own hook gets git's single ref line and the two arguments.
install_own 0
out="$(G push origin b1 2>&1)" || fail "push of b1 failed: $out"
sha="$(G rev-parse b1)"
[ "$(cat "$CAP/stdin"; printf x)" = "refs/heads/b1 $sha refs/heads/b1 $ZEROS"$'\n'x ] || fail "own hook stdin for one branch: $(cat "$CAP/stdin")"
[ "$(cat "$CAP/args")" = "origin"$'\n'"$SANDBOX/origin.git" ] || fail "own hook args: $(cat "$CAP/args")"

# Two branches in one push: both lines, in git's order.
install_own 0
G branch feat2
out="$(G push origin b2 feat2 2>&1)" || fail "push of two branches failed: $out"
want="$(printf 'refs/heads/b2 %s refs/heads/b2 %s\nrefs/heads/feat2 %s refs/heads/feat2 %s\n' "$(G rev-parse b2)" "$ZEROS" "$(G rev-parse feat2)" "$ZEROS" | sort)"
[ "$(wc -l <"$CAP/stdin")" = 2 ] || fail "own hook did not get two lines: $(cat "$CAP/stdin")"
[ "$(sort "$CAP/stdin")" = "$want" ] || fail "own hook stdin for two branches: $(cat "$CAP/stdin")"

# A shared branch: refused, named, and the own hook never runs.
install_own 0
out="$(G push origin b1:main 2>&1)" && fail "push to main succeeded"
printf '%s' "$out" | /usr/bin/grep -q 'refs/heads/main is a shared branch' || fail "refusal does not name the shared branch: $out"
[ ! -e "$CAP/ran" ] || fail "own hook ran on a refused push"

# The own hook's status is the push's.
install_own 1
G push origin b1:b3 >/dev/null 2>&1 && fail "push succeeded though the own hook exited 1"
[ -e "$CAP/ran" ] || fail "own hook did not run"

# No own hook: the push goes through.
rm -f "$OWN"
out="$(G push origin b1:b4 2>&1)" || fail "push without an own hook failed: $out"
echo "ok"
