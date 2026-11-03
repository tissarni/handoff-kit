#!/usr/bin/env bash
# Verify installation adds only the required Hermes client environment allowlist.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init
H="$SANDBOX/home/.hermes"
mkdir -p "$H"
KIT="$SANDBOX/kit"
ARGS=(--vault "$SANDBOX/vault" --defaults 02-projects/_templates/handoff-defaults.yml --projects 02-projects)
inst() { _sbx_env; env -i "${SBX_ENV[@]}" bash "$KIT/install.sh" "${ARGS[@]}" --hermes-profiles; }

OUT="$(inst 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "fresh install failed: $OUT"
for n in run close; do
  /usr/bin/grep -q 'client_env_passthrough' "$H/profiles/$n/config.yaml" || fail "$n profile lacks client_env_passthrough"
  for v in HANDOFF_HARNESS HANDOFF_MODEL GIT_CONFIG_PARAMETERS; do
    /usr/bin/grep -q -- "$v" "$H/profiles/$n/config.yaml" || fail "$n profile lacks $v"
  done
done

# Existing run config is extended without changing unrelated lines.
printf 'model:\n  default: custom/model\nother:\n  keep: exactly\n' >"$H/profiles/run/config.yaml"
cp "$H/profiles/run/config.yaml" "$SANDBOX/run.before"
OUT="$(inst 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "existing profile upgrade failed: $OUT"
python3 - "$SANDBOX/run.before" "$H/profiles/run/config.yaml" <<'PY' || fail 'existing profile content changed outside allowlist'
import sys
before=open(sys.argv[1]).read().splitlines()
after=open(sys.argv[2]).read().splitlines()
assert after[:len(before)] == before, (before, after)
assert all(any(x in line for line in after) for x in ['HANDOFF_HARNESS', 'HANDOFF_MODEL', 'GIT_CONFIG_PARAMETERS'])
PY
cp "$H/profiles/run/config.yaml" "$SANDBOX/run.after"
OUT="$(inst 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "second install failed: $OUT"
cmp -s "$SANDBOX/run.after" "$H/profiles/run/config.yaml" || fail 'second install was not idempotent'
echo ok
