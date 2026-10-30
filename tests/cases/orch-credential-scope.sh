#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

TOKENS=(GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN)
VALUES=(sentinel-gh sentinel-github sentinel-enterprise-gh sentinel-enterprise-github)

# Capture process arguments and the stage environment before delegating to the sandbox fakes.
cat >"$SANDBOX/bin/setsid" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" >>"$FAKE_STATE_DIR/setsid.argv"
# macOS has no setsid binary: fall back the way the orchestrator itself does.
if [ -x /usr/bin/setsid ]; then exec /usr/bin/setsid "$@"; fi
exec python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"
SH
cat >"$SANDBOX/bin/env" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in HANDOFF_LAUNCHER=*) printf '%s\0' "$@" >>"$FAKE_STATE_DIR/env.argv"; break ;; esac
done
exec /usr/bin/env "$@"
SH
cat >"$SANDBOX/bin/claude" <<'SH'
#!/usr/bin/env bash
stage=""
name=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = --name ]; then name="${args[$((i+1))]}"; fi
done
stage="${name%% *}"
python3 - "$FAKE_STATE_DIR/stages.jsonl" "$stage" <<'PY'
import json, os, sys
with open(sys.argv[1], 'a', encoding='utf-8') as f:
    f.write(json.dumps({'stage':sys.argv[2], 'env':{k:os.environ.get(k) for k in
        ('GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN','GITHUB_ENTERPRISE_TOKEN')}})+'\n')
PY
exec "$FAKE_STATE_DIR/real-claude" "$@"
SH
cp "$FAKES_DIR/claude" "$SANDBOX/state/real-claude"
chmod +x "$SANDBOX/bin/setsid" "$SANDBOX/bin/env" "$SANDBOX/bin/claude" "$SANDBOX/state/real-claude"

# The fake forge records that finalization retained its token, but does not perform a write.
cat >"$SANDBOX/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${GH_TOKEN-unset}" >>"$FAKE_STATE_DIR/gh-token.log"
printf '[]\n'
SH
chmod +x "$SANDBOX/bin/gh"

seed_tokens() {
  local i
  for i in "${!TOKENS[@]}"; do SBX_ENV+=("${TOKENS[$i]}=${VALUES[$i]}"); done
}

# A runner-owned run retains all token values.
BRIEF_RUN="$(make_brief testsub credential-run.md ready)"
_sbx_env; seed_tokens
OUT="$(env -i "${SBX_ENV[@]}" FAKE_CLAUDE=run=complete bash "$SANDBOX/kit/handoff-launch.sh" run "$BRIEF_RUN" --delegate --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "runner-owned run failed ($RC): $OUT"
python3 - "$SANDBOX/state/stages.jsonl" "${VALUES[*]}" <<'PY' || fail "runner-owned run did not retain all credentials"
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1],encoding='utf-8')]
r=[x for x in rows if x['stage']=='run'][-1]
assert list(r['env'].values()) == sys.argv[2].split(), r
PY

# A directly launched supervisor-owned run also loses credentials before backend execution.
BRIEF_DIRECT="$(make_brief testsub direct-supervisor-run.md ready)"
_sbx_env; seed_tokens
OUT="$(env -i "${SBX_ENV[@]}" FAKE_CLAUDE=run=complete bash "$SANDBOX/kit/handoff-launch.sh" run "$BRIEF_DIRECT" --delegate --backend claude --publication-owner supervisor 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "direct supervisor-owned run failed ($RC): $OUT"

# The supervisor-owned loop traverses review, revise, run, close, debrief and final-review.
BRIEF="$(make_brief testsub credential-scope.md draft)"
_sbx_env; seed_tokens
OUT="$(env -i "${SBX_ENV[@]}" FAKE_CLAUDE=review=RUN,run=complete bash "$SANDBOX/kit/handoff-launch.sh" loop "$BRIEF" --gate auto --backend claude --publication-owner supervisor --feature-complete 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "supervisor-owned loop failed ($RC): $OUT"
python3 - "$SANDBOX/state/stages.jsonl" <<'PY' || fail "a supervisor-owned stage retained a token or missed a stage"
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1],encoding='utf-8')]
need={'review','revise','run','close','debrief','final-review'}
runner=[r for r in rows if r['stage']=='run']
assert len(runner) >= 2, runner
assert all(v is None for v in runner[-1]['env'].values()), runner[-1]
supervisor=[r for r in rows if r['stage'] in need and r is not runner[0]]
seen={r['stage'] for r in supervisor}
assert need <= seen, (need-seen, seen)
for r in supervisor:
    assert all(v is None for v in r['env'].values()), r
PY

# Orchestration's driver keeps credentials for finalize; no token value belongs in argv.
BRIEF2="$(make_brief testsub credential-driver.md draft)"
PLAN="$(dirname "$BRIEF2")/credential-plan.md"
make_plan "$PLAN" "$BRIEF2"
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$SANDBOX/repo_under.test" true >/dev/null
_sbx_env; seed_tokens
OUT="$(env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/handoff-orchestrate.sh" start "$PLAN" --backend claude --publication-owner supervisor 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "supervisor-owned plan did not start ($RC): $OUT"
awaiting() { /usr/bin/grep -q '^orchestration: awaiting-merge' "$PLAN" 2>/dev/null; }
wait_for 120 awaiting || fail "plan did not reach finalization state"
python3 - "$SANDBOX/state/setsid.argv" "$SANDBOX/state/env.argv" "${VALUES[*]}" <<'PY' 2>"$SANDBOX/state/argv-check.err" || fail "a launch argv exposed a credential sentinel: $(tail -1 "$SANDBOX/state/argv-check.err")"
import os,sys
missing=[p for p in sys.argv[1:3] if not os.path.exists(p)]
assert not missing, f"argv spy files missing: {missing}"
for p in sys.argv[1:3]:
    raw=open(p,'rb').read().decode('utf-8','replace').replace(chr(0),' ')
    for x in sys.argv[3].split():
        i=raw.find(x)
        assert i < 0, f"{os.path.basename(p)}: {x} in ...{raw[max(0,i-200):i+60]!r}"
PY
[ -f "$SANDBOX/state/gh-token.log" ] || fail "finalize did not invoke fake gh"
/usr/bin/grep -q '^sentinel-gh$' "$SANDBOX/state/gh-token.log" || fail "finalize did not retain GH_TOKEN"
echo ok
