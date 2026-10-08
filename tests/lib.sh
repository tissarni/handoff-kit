#!/usr/bin/env bash
# Shared harness for tests/cases/*.sh. Sourced by each case. One `mktemp -d` sandbox
# per case, outside the repo; every command against it runs under `env -i` so nothing
# in this session's own environment (HANDOFF_HARNESS, GIT_CONFIG_*, CLAUDE*) leaks in
# and commits through the real hooks or writes to the real HOME.
set -uo pipefail

# This session may itself be a handoff repo stage, carrying GIT_CONFIG_* (pointing at
# the REAL ~/.config/handoff/git-hooks) and HANDOFF_HARNESS/HANDOFF_MODEL in its own
# ambient environment. launch()/orch() already run under `env -i` and are immune, but a
# plain `git` command run directly by a case (e.g. sandbox_init's own setup push) is
# not — it would hit the real pre-push hook and refuse. Strip them here, once, for the
# whole harness process.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 HANDOFF_HARNESS HANDOFF_MODEL

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKES_DIR="$REPO_ROOT/tests/fakes"

fail() { echo "FAIL: $*"; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1'${3:+ — $3}"; }
assert_contains() {   # $1 = file, $2 = literal substring
  [ -f "$1" ] || fail "expected file to exist: $1"
  grep -qF -- "$2" "$1" 2>/dev/null || fail "expected $1 to contain: $2"
}
assert_file() { [ -f "$1" ] || fail "expected file to exist: $1"; }
assert_no_file() { [ ! -f "$1" ] || fail "expected file NOT to exist: $1"; }

wait_for() {   # wait_for <seconds> <command...> — polls once a second
  local secs="$1"; shift
  local i=0
  while [ "$i" -lt "$secs" ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
    i=$((i+1))
  done
  return 1
}

state_of() {   # $1 = brief path
  /usr/bin/grep -m1 '^handoff:' "$1" 2>/dev/null | cut -d: -f2- | /usr/bin/sed -e 's/^[[:space:]]*//' -e "s/[\"']//g"
}

sandbox_cleanup() {
  [ -n "${SANDBOX:-}" ] || return 0
  pkill -f "$SANDBOX" >/dev/null 2>&1 || true
  sleep 1
  pkill -9 -f "$SANDBOX" >/dev/null 2>&1 || true
  rm -rf "$SANDBOX"
}

write_fakes() {
  mkdir -p "$SANDBOX/bin"
  for f in claude systemctl curl gh glab; do
    cp "$FAKES_DIR/$f" "$SANDBOX/bin/$f"
    chmod +x "$SANDBOX/bin/$f"
  done
}

sandbox_init() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  echo "SANDBOX=$SANDBOX"
  trap 'sandbox_cleanup' EXIT

  mkdir -p "$SANDBOX/home" "$SANDBOX/vault/02-projects/_templates" \
           "$SANDBOX/state" "$SANDBOX/bin" "$SANDBOX/tmp"

  cat >"$SANDBOX/home/.gitconfig" <<'EOF'
[user]
	name = Test User
	email = test@example.com
[init]
	defaultBranch = main
EOF

  git init -q -b main --bare "$SANDBOX/origin.git"

  mkdir -p "$SANDBOX/repo_under.test"
  (
    cd "$SANDBOX/repo_under.test"
    export HOME="$SANDBOX/home"
    git init -q -b main
    echo "test repo" >README.md
    git add README.md
    git commit -q -m init
    git remote add origin "$SANDBOX/origin.git"
    git push -q origin main
  )

  local src="${HANDOFF_SCRIPTS_DIR:-$REPO_ROOT}"
  mkdir -p "$SANDBOX/kit"
  cp "$src/handoff-launch.sh" "$SANDBOX/kit/handoff-launch.sh"
  cp "$src/handoff-orchestrate.sh" "$SANDBOX/kit/handoff-orchestrate.sh"
  local usage_src="$src"
  [ -f "$usage_src/handoff-usage.py" ] || usage_src="$REPO_ROOT"
  [ -f "$usage_src/handoff-usage.py" ] && cp "$usage_src/handoff-usage.py" "$SANDBOX/kit/handoff-usage.py"
  cp -r "$REPO_ROOT/hooks" "$SANDBOX/kit/hooks"
  [ -d "$REPO_ROOT/guards" ] && cp -r "$REPO_ROOT/guards" "$SANDBOX/kit/guards"
  cp -r "$REPO_ROOT/skills" "$SANDBOX/kit/skills"
  cp -r "$REPO_ROOT/systemd" "$SANDBOX/kit/systemd"
  cp "$REPO_ROOT/install.sh" "$SANDBOX/kit/install.sh"
  cp "$REPO_ROOT/tests/fixtures/handoff-defaults.yml" \
     "$SANDBOX/vault/02-projects/_templates/handoff-defaults.yml"
  python3 - "$SANDBOX/vault/02-projects/_templates/handoff-defaults.yml" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p, encoding='utf-8').read()
t = re.sub(r'disk-min-free-gb:\s*\d+', 'disk-min-free-gb: 0', t)
open(p, 'w', encoding='utf-8').write(t)
PY

  [ -f "$src/brief-check.sh" ] && cp "$src/brief-check.sh" "$SANDBOX/kit/"
  chmod +x "$SANDBOX/kit/"*.sh

  write_fakes
}

# The env every sandbox command runs under. VAULT and the two other roots are included;
# use orch_novault for the one case that must read VAULT from config.env.
_sbx_env() {
  SBX_ENV=(
    "PATH=$SANDBOX/bin:/usr/local/bin:/usr/bin:/bin"
    "HOME=$SANDBOX/home"
    "VAULT=$SANDBOX/vault"
    "HANDOFF_DEFAULTS=02-projects/_templates/handoff-defaults.yml"
    "HANDOFF_PROJECTS=02-projects"
    "FAKE_VAULT=$SANDBOX/vault"
    "FAKE_STATE_DIR=$SANDBOX/state"
    "FAKE_CLAUDE=${FAKE_CLAUDE:-}"
    "CLAUDE_BIN=$SANDBOX/bin/claude"
    "TMPDIR=$SANDBOX/tmp"
    "LANG=C.UTF-8"
    "HANDOFF_LIMIT_WAIT=1"
  )
  [ -n "${PYTEST_ADDOPTS+x}" ] && SBX_ENV+=("PYTEST_ADDOPTS=$PYTEST_ADDOPTS")
}

launch() {
  _sbx_env
  env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/handoff-launch.sh" "$@"
}

orch() {
  _sbx_env
  env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/handoff-orchestrate.sh" "$@"
}

orch_novault() {   # same as orch, but VAULT unset: the script must read it from config.env
  _sbx_env
  local e=() v
  for v in "${SBX_ENV[@]}"; do
    case "$v" in VAULT=*) ;; *) e+=("$v") ;; esac
  done
  env -i "${e[@]}" bash "$SANDBOX/kit/handoff-orchestrate.sh" "$@"
}

make_brief() {   # $1 = sub, $2 = filename, $3 = state (default draft)
  local sub="$1" file="$2" state="${3:-draft}"
  local dir="$SANDBOX/vault/02-projects/testmain/subprojects/$sub/specs"
  mkdir -p "$dir"
  local path="$dir/$file"
  local base="${file%.md}"
  cat >"$path" <<EOF
---
updated: 2026-01-01
tags: [spec, brief]
handoff: $state
revision: r1
repo: $SANDBOX/repo_under.test
branch: feat/test
review-session:
  model: opus
  effort: medium
  permission-mode: acceptEdits
  ponytail-mode: full
  disallowed-tools: Edit,Write,NotebookEdit
run-session:
  model: sonnet
  effort: medium
  permission-mode: acceptEdits
  ponytail-mode: full
---

# Brief — $base

Fake brief for the test harness.
EOF
  printf '%s' "$path"
}

make_plan() {   # $1 = plan path, $2.. = brief paths (same dir as plan)
  local plan="$1"; shift
  local names=() n
  for b in "$@"; do names+=("$(basename "$b")"); done
  local list=""
  for n in "${names[@]}"; do
    if [ -z "$list" ]; then list="$n"; else list="$list, $n"; fi
  done
  cat >"$plan" <<EOF
---
updated: 2026-01-01
tags: [spec, plan]
project: testsub
orchestration: planned
backend: claude
model: ''
phase: 1
branch: feat/test
base: main
budgets:
  review: 45
  revise: 30
  run: 240
  close: 30
  debrief: 30
  phase: 1440
  heartbeat: 20
notify: ''
phases:
  - name: phase one
    briefs: [$list]
    status: pending
---

# Plan — test

## Phases

| # | Delivers | Briefs | Boundary after it |
|---|---|---|---|
| 1 | test | $list | last phase |

## Run

\`\`\`bash
handoff-orchestrate start $(basename "$plan") --backend claude
\`\`\`

## Log

- test plan
EOF
}
