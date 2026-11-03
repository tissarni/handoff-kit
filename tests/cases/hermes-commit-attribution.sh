#!/usr/bin/env bash
# Verify hermes commit attribution forwarding, refusal, resume, and isolation.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INHERITED_GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS:-}"
source "$DIR/../lib.sh"
if [[ "$INHERITED_GIT_CONFIG_PARAMETERS" == *'/sentinel/real-hooks'* ]]; then
  [ -z "${GIT_CONFIG_PARAMETERS:-}" ] || fail 'tests/lib.sh did not clear inherited GIT_CONFIG_PARAMETERS'
fi
sandbox_init
cp "$FAKES_DIR/hermes" "$SANDBOX/bin/hermes"
chmod +x "$SANDBOX/bin/hermes"
mkdir -p "$SANDBOX/home/.hermes/profiles/run"
cat >"$SANDBOX/home/.hermes/profiles/run/config.yaml" <<'EOF'
terminal:
  client_env_passthrough:
    - HANDOFF_HARNESS
    - HANDOFF_MODEL
    - GIT_CONFIG_PARAMETERS
EOF
BRIEF="$(make_brief 'sub' 'attribution.md' ready)"
NOTE="$SANDBOX/note.txt"
printf 'continue\n' >"$NOTE"
_sbxx() { _sbx_env; SBX_ENV+=("FAKE_HERMES_COMMIT=1"); }
run_launch() { _sbxx; env -i "${SBX_ENV[@]}" "VAULT=$SANDBOX/vault" "HERMES_BIN=$SANDBOX/bin/hermes" bash "$SANDBOX/kit/handoff-launch.sh" "$@"; }

OUT="$(run_launch run "$BRIEF" --delegate --backend hermes 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "hermes run failed: $OUT"
REPO="$SANDBOX/repo_under.test"
TRAILERS="$(git -C "$REPO" log -1 --format=%B | git interpret-trailers --parse)"
assert_contains <(printf '%s\n' "$TRAILERS") 'Harness: hermes'
assert_contains <(printf '%s\n' "$TRAILERS") 'Model: profile/run-model'
[ -z "$(git -C "$REPO" config --local --get core.hooksPath || true)" ] || fail 'core.hooksPath persisted in repo config'

# Missing one forwarded variable must refuse before Hermes is called.
printf 'terminal:\n  client_env_passthrough: [HANDOFF_HARNESS, GIT_CONFIG_PARAMETERS]\n' >"$SANDBOX/home/.hermes/profiles/run/config.yaml"
before="$(wc -l <"$SANDBOX/state/hermes.jsonl")"
OUT="$(run_launch run "$BRIEF" --delegate --backend hermes 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || fail 'run accepted incomplete profile'
[[ "$OUT" == *HANDOFF_MODEL* && "$OUT" == *'install.sh --hermes-profiles'* ]] || fail "preflight did not explain missing name/fix: $OUT"
assert_eq "$(wc -l <"$SANDBOX/state/hermes.jsonl")" "$before"

# Resume uses the run profile and refuses the same missing-name case.
python3 - "$BRIEF" <<'PY'
import pathlib, re, sys
p=pathlib.Path(sys.argv[1]); p.write_text(re.sub(r'^handoff: .*$', 'handoff: running', p.read_text(), flags=re.M))
PY
OUT="$(run_launch resume "$BRIEF" --session s --note "$NOTE" --backend hermes 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || fail 'resume accepted incomplete profile'
[[ "$OUT" == *HANDOFF_MODEL* ]] || fail "resume preflight omitted missing name: $OUT"
assert_eq "$(wc -l <"$SANDBOX/state/hermes.jsonl")" "$before"

# Complete profile permits resume and forwards the hook config to the opt-in fake.
cat >"$SANDBOX/home/.hermes/profiles/run/config.yaml" <<'EOF'
terminal:
  client_env_passthrough: [HANDOFF_HARNESS, HANDOFF_MODEL, GIT_CONFIG_PARAMETERS]
EOF
OUT="$(run_launch resume "$BRIEF" --session s --note "$NOTE" --backend hermes 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "hermes resume failed: $OUT"
assert_eq "$(git -C "$REPO" log -1 --format=%B | git interpret-trailers --parse | /usr/bin/grep -c '^Harness: hermes$')" 1

# Claude keeps the existing environment config path and does not receive the new variable.
# The fake records its environment snapshot when asked, while the launcher still uses its original config.
printf 'model: profile/run-model\n' >"$SANDBOX/home/.hermes/profiles/run/config.yaml"
OUT="$(run_launch run "$BRIEF" --delegate --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 1 ] || fail "claude fake should stop without report, got $RC: $OUT"
[[ "$OUT" == *'HANDOFF_HARNESS=claude-code'* ]] || fail "claude attribution environment changed: $OUT"
[[ "$OUT" != *'GIT_CONFIG_PARAMETERS'* ]] || fail "kit added GIT_CONFIG_PARAMETERS for claude: $OUT"
echo ok
