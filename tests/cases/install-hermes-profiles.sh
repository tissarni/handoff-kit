#!/usr/bin/env bash
# install.sh --hermes-profiles seeds the three hermes profiles, keeps existing ones, and
# without the flag leaves ~/.hermes alone.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

H="$SANDBOX/home/.hermes"
CFG="$SANDBOX/home/.config/handoff/config.env"
DEF=02-projects/_templates/handoff-defaults.yml
KIT="$SANDBOX/kit"
SENT=sentinel-model-9
ARGS=(--vault "$SANDBOX/vault" --defaults "$DEF" --projects 02-projects)

inst() { _sbx_env; env -i "${SBX_ENV[@]}" bash "$KIT/install.sh" "$@"; }
has() { printf '%s\n' "$OUT" | /usr/bin/grep -qF -- "$1" || fail "$2: output lacks '$1':
$OUT"; }
hasnt() { ! printf '%s\n' "$OUT" | /usr/bin/grep -qF -- "$1" || fail "$2: output has '$1':
$OUT"; }
block() { sed -n '/^=== HANDOFF REVIEW ===$/,/^=== END HANDOFF REVIEW ===$/p' "$1"; }

# 1. the review SOUL carries the skill's block byte for byte
block "$KIT/skills/handoff-review/SKILL.md" >"$SANDBOX/b1"
block "$KIT/hermes/profiles/review/SOUL.md" >"$SANDBOX/b2"
cmp -s "$SANDBOX/b1" "$SANDBOX/b2" || fail "step 1: review blocks differ"
[ "$(wc -l <"$SANDBOX/b2")" -eq 17 ] || fail "step 1: block is not 17 lines"

# 2. flag, no ~/.hermes: refused, nothing written
OUT="$(inst "${ARGS[@]}" --hermes-profiles 2>&1)"; RC=$?
[ "$RC" -eq 1 ] || fail "step 2: expected exit 1, got $RC: $OUT"
has 'install hermes first' "step 2"
for p in "$CFG" "$SANDBOX/home/.local/bin" "$H"; do [ ! -e "$p" ] || fail "step 2: $p was written"; done

# 3. no flag: ~/.hermes untouched
mkdir -p "$H"
printf 'model:\n  default: %s\n  provider: custom\nother: 1\n' "$SENT" >"$H/config.yaml"
find "$H" | sort >"$SANDBOX/before"; cp "$H/config.yaml" "$SANDBOX/cfg.before"
OUT="$(inst "${ARGS[@]}" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "step 3: exit $RC: $OUT"
find "$H" | sort | cmp -s - "$SANDBOX/before" || fail "step 3: ~/.hermes changed"
cmp -s "$H/config.yaml" "$SANDBOX/cfg.before" || fail "step 3: config.yaml changed"

# 4. flag: three profiles
OUT="$(inst "${ARGS[@]}" --hermes-profiles 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "step 4: exit $RC: $OUT"
printf 'model:\n  default: %s\n  provider: custom\n' "$SENT" >"$SANDBOX/model.expected"
for n in review run close; do
  d="$H/profiles/$n"
  cmp -s "$KIT/hermes/profiles/$n/SOUL.md" "$d/SOUL.md" || fail "step 4: $n SOUL differs"
  cmp -s "$SANDBOX/model.expected" "$d/config.yaml" || fail "step 4: $n config.yaml is not the model block"
  [ -n "$(find "$d/config.yaml" -perm 600)" ] || fail "step 4: $n config.yaml is not mode 600"
  has "installed hermes profile $n" "step 4"
done
[ -z "$(find "$H" \( -name .env -o -name auth.json \))" ] || fail "step 4: credentials written"
[ -z "$(find "$H/profiles" -mindepth 1 -maxdepth 1 -name '.*')" ] || fail "step 4: leftover dot directory"
has 'NOTE: new hermes profiles have no credentials' "step 4"
hasnt "$SENT" "step 4"
cmp -s "$H/config.yaml" "$SANDBOX/cfg.before" || fail "step 4: ~/.hermes/config.yaml changed"

# 5. second run keeps edits
echo edited >>"$H/profiles/review/SOUL.md"
echo 'edited: 1' >>"$H/profiles/run/config.yaml"
OUT="$(inst "${ARGS[@]}" --hermes-profiles 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "step 5: exit $RC: $OUT"
for n in review run close; do has "kept hermes profile $n" "step 5"; done
hasnt 'installed hermes profile' "step 5"
[ "$(tail -n 1 "$H/profiles/review/SOUL.md")" = edited ] || fail "step 5: review SOUL edit lost"
[ "$(tail -n 1 "$H/profiles/run/config.yaml")" = 'edited: 1' ] || fail "step 5: run config edit lost"

# 6. a profile recreated with no model: block to copy
rm -rf "$H/profiles/close"
printf 'other: 1\n' >"$H/config.yaml"
OUT="$(inst "${ARGS[@]}" --hermes-profiles 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "step 6: exit $RC: $OUT"
cmp -s "$KIT/hermes/profiles/close/SOUL.md" "$H/profiles/close/SOUL.md" || fail "step 6: close SOUL differs"
[ ! -e "$H/profiles/close/config.yaml" ] || fail "step 6: close has a config.yaml"
has 'NOTE: hermes profile close has no config.yaml' "step 6"

echo ok
