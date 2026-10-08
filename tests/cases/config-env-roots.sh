#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub cr-brief.md draft)"
REL="${BRIEF#"$SANDBOX/vault/"}"
PLAN="$(dirname "$BRIEF")/cr-plan.md"
make_plan "$PLAN" "$BRIEF"
PREL="${PLAN#"$SANDBOX/vault/"}"
CFG="$SANDBOX/home/.config/handoff/config.env"
mkdir -p "$(dirname "$CFG")"

cat >"$SANDBOX/vault/02-projects/_templates/alt-defaults.yml" <<'YML'
defaults:
  close:
    model: opus
    effort: low
    permission-mode: bypassPermissions
    disallowed-tools: Edit,Write,NotebookEdit
per-main:
  testmain:
    close:
      model: haiku
orchestration:
  disk-min-free-gb: 0
YML

noroots() {
  _sbx_env
  local e=() v
  for v in "${SBX_ENV[@]}"; do
    case "$v" in VAULT=*|HANDOFF_DEFAULTS=*|HANDOFF_PROJECTS=*) ;; *) e+=("$v") ;; esac
  done
  env -i "${e[@]}" "$@"
}
L=(bash "$SANDBOX/kit/handoff-launch.sh" close "$REL" --dry-run --backend claude)
O=(bash "$SANDBOX/kit/handoff-orchestrate.sh" status "$PREL")

has() { printf '%s\n' "$OUT" | /usr/bin/grep -qF -- "$1" || fail "output lacks '$1'. Output:
$OUT"; }

# 1. no config, no environment
OUT="$(noroots "${L[@]}" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] || fail "launcher without roots: expected exit 1, got $RC"
has 'config.env'
OUT="$(noroots "${O[@]}" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] || fail "orchestrator without roots: expected exit 1, got $RC"
has 'config.env'

# 2. the file alone
printf '%s\n' "VAULT=$SANDBOX/vault" \
  'HANDOFF_DEFAULTS=02-projects/_templates/alt-defaults.yml' \
  'HANDOFF_PROJECTS=02-projects' >"$CFG"
OUT="$(noroots "${L[@]}" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "file alone: launcher expected exit 0, got $RC. Output:
$OUT"
has "  brief:       $SANDBOX/vault/$REL"
has 'model:       haiku   effort: low'
OUT="$(noroots "${O[@]}" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "file alone: orchestrator expected exit 0, got $RC. Output:
$OUT"

# 3. the environment wins, key by key
printf '%s\n' "VAULT=$SANDBOX/nowhere" \
  'HANDOFF_DEFAULTS=02-projects/_templates/alt-defaults.yml' \
  'HANDOFF_PROJECTS=02-projects' >"$CFG"
OUT="$(noroots env "VAULT=$SANDBOX/vault" "${L[@]}" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "env over file: expected exit 0, got $RC. Output:
$OUT"
has 'model:       haiku   effort: low'

# 4. the projects directory decides the main
printf '%s\n' "VAULT=$SANDBOX/vault" \
  'HANDOFF_DEFAULTS=02-projects/_templates/alt-defaults.yml' \
  'HANDOFF_PROJECTS=elsewhere' >"$CFG"
OUT="$(noroots "${L[@]}" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "other projects dir: expected exit 0, got $RC. Output:
$OUT"
has 'model:       opus   effort: low'

# 5. the last line wins, and its quotes go
printf '%s\n' 'HANDOFF_PROJECTS="02-projects"' >>"$CFG"
OUT="$(noroots "${L[@]}" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "last line: expected exit 0, got $RC. Output:
$OUT"
has 'model:       haiku   effort: low'

echo ok
