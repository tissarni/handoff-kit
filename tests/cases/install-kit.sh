#!/usr/bin/env bash
# install.sh writes config, links, skills and units; the commands then run by name.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub ik-brief.md draft)"
REL="${BRIEF#"$SANDBOX/vault/"}"
PLAN="$(dirname "$BRIEF")/ik-plan.md"
make_plan "$PLAN" "$BRIEF"
PREL="${PLAN#"$SANDBOX/vault/"}"
CFG="$SANDBOX/home/.config/handoff/config.env"
DEF=02-projects/_templates/handoff-defaults.yml

inst() { _sbx_env; env -i "${SBX_ENV[@]}" bash "$1/install.sh" "${@:2}"; }
byname() {
  _sbx_env
  local e=() v
  for v in "${SBX_ENV[@]}"; do
    case "$v" in
      VAULT=*|HANDOFF_DEFAULTS=*|HANDOFF_PROJECTS=*) ;;
      PATH=*) e+=("PATH=$SANDBOX/home/.local/bin:${v#PATH=}") ;;
      *) e+=("$v") ;;
    esac
  done
  env -i "${e[@]}" "$@"
}
has() { printf '%s\n' "$OUT" | /usr/bin/grep -qF -- "$1" || fail "$2: output lacks '$1':
$OUT"; }

# 1. no flags, no config: refused, nothing written
OUT="$(inst "$SANDBOX/kit" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] || fail "step 1: expected exit 1, got $RC: $OUT"
has '--vault' "step 1"
for p in "$CFG" "$SANDBOX/home/.local/bin" "$SANDBOX/home/.config/systemd"; do
  [ ! -e "$p" ] || fail "step 1: $p was written"
done

# 2. a full install over stale files
mkdir -p "$SANDBOX/home/.claude/skills/handoff-review" "$SANDBOX/home/.claude/skills/other" \
         "$SANDBOX/home/.config/systemd/user"
echo stale >"$SANDBOX/home/.claude/skills/handoff-review/SKILL.md"
echo x >"$SANDBOX/home/.claude/skills/handoff-review/extra.md"
echo keep >"$SANDBOX/home/.claude/skills/other/SKILL.md"
echo stale >"$SANDBOX/home/.config/systemd/user/handoff-watchdog@.service"
OUT="$(inst "$SANDBOX/kit" --vault "$SANDBOX/vault" --defaults "$DEF" --projects 02-projects 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "step 2: expected exit 0, got $RC: $OUT"
[ "$(cat "$CFG")" = "VAULT=$SANDBOX/vault
HANDOFF_DEFAULTS=$DEF
HANDOFF_PROJECTS=02-projects" ] || fail "step 2: config.env is not the three lines: $(cat "$CFG")"
for n in handoff-launch handoff-orchestrate brief-check; do
  [ "$(readlink -f "$SANDBOX/home/.local/bin/$n")" = "$SANDBOX/kit/$n.sh" ] || fail "step 2: link $n wrong"
done
for d in "$SANDBOX/kit"/skills/*/; do
  n="$(basename "$d")"
  [ -z "$(diff -r "$d" "$SANDBOX/home/.claude/skills/$n" 2>&1)" ] || fail "step 2: skill $n differs"
done
[ -f "$SANDBOX/home/.claude/skills/other/SKILL.md" ] || fail "step 2: other skill removed"
for u in handoff-watchdog@.service handoff-watchdog@.timer; do
  cmp -s "$SANDBOX/kit/systemd/$u" "$SANDBOX/home/.config/systemd/user/$u" || fail "step 2: unit $u differs"
done
has 'NOTE: no systemd user session' "step 2"
has 'is not on PATH' "step 2"

# 3. by name
OUT="$(byname handoff-orchestrate status "$PREL" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "step 3 status: exit $RC: $OUT"
has 'NO STATUS — plan has not been started' "step 3 status"
OUT="$(byname handoff-launch close "$REL" --dry-run --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "step 3 close: exit $RC: $OUT"
has "  brief:       $SANDBOX/vault/$REL" "step 3 close"
has "a delegated run writes it: handoff-launch run $REL --delegate" "step 3 close"
OUT="$(byname brief-check 2>&1)"; RC=$?
[ "$RC" -eq 2 ] || fail "step 3 brief-check: exit $RC: $OUT"
has 'usage: brief-check <brief.md>' "step 3 brief-check"
OUT="$(byname handoff-orchestrate 2>&1)"; RC=$?
[ "$RC" -eq 1 ] || fail "step 3 orchestrate usage: exit $RC: $OUT"
has 'usage: handoff-orchestrate start|tick|stop|resume|status' "step 3 orchestrate usage"
OUT="$(byname handoff-launch 2>&1)"; RC=$?
[ "$RC" -eq 1 ] || fail "step 3 launch usage: exit $RC: $OUT"
has 'usage: handoff-launch review|run|close|revise|debrief|loop|resume|lesson' "step 3 launch usage"

# 4. a re-install from another kit keeps the file
echo EXTRA=kept >>"$CFG"
cp -R "$SANDBOX/kit" "$SANDBOX/kit2"
OUT="$(inst "$SANDBOX/kit2" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "step 4: exit $RC: $OUT"
for n in handoff-launch handoff-orchestrate brief-check; do
  [ "$(readlink -f "$SANDBOX/home/.local/bin/$n")" = "$SANDBOX/kit2/$n.sh" ] || fail "step 4: link $n not in kit2"
done
[ "$(cat "$CFG")" = "EXTRA=kept
VAULT=$SANDBOX/vault
HANDOFF_DEFAULTS=$DEF
HANDOFF_PROJECTS=02-projects" ] || fail "step 4: config.env wrong: $(cat "$CFG")"

# 5. one flag changes one key
cp "$CFG" "$SANDBOX/cfg4"
cp "$SANDBOX/vault/$DEF" "$SANDBOX/vault/02-projects/_templates/alt.yml"
OUT="$(inst "$SANDBOX/kit" --defaults 02-projects/_templates/alt.yml 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "step 5: exit $RC: $OUT"
/usr/bin/grep -qx 'HANDOFF_DEFAULTS=02-projects/_templates/alt.yml' "$CFG" || fail "step 5: defaults not changed"
[ "$(/usr/bin/grep -v '^HANDOFF_DEFAULTS=' "$CFG")" = "$(/usr/bin/grep -v '^HANDOFF_DEFAULTS=' "$SANDBOX/cfg4")" ] \
  || fail "step 5: another key changed"

# 6. a refusal changes nothing
cp "$CFG" "$SANDBOX/cfg5"
OUT="$(inst "$SANDBOX/kit" --vault "$SANDBOX/nowhere" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] || fail "step 6: exit $RC: $OUT"
has 'vault not found' "step 6"
cmp -s "$CFG" "$SANDBOX/cfg5" || fail "step 6: config.env changed"
OUT="$(inst "$SANDBOX/kit" --bogus 2>&1)"; RC=$?
[ "$RC" -eq 2 ] || fail "step 6 bogus: exit $RC: $OUT"

echo ok
