#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

repo="$SANDBOX/repo_under.test"
brief="$(make_brief testsub version.md draft)"
plan="$(dirname "$brief")/version-plan.md"
make_plan "$plan" "$brief"
python3 - "$plan" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('base: main', 'base: dev', 1).replace('updated: 2026-01-01', 'updated: 2026-01-01\nrevision: r1', 1)
open(p,'w').write(s)
PY
mkdir -p "$SANDBOX/home/.config/handoff"
git -C "$repo" remote set-url origin https://github.com/test/repo
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$repo" true >/dev/null
python3 - "$SANDBOX/home/.config/handoff/project-policy.json" "$plan" "$repo" <<'PY'
import json,pathlib,sys
p,plan,repo=sys.argv[1:]; d=json.load(open(p)); d['repositories'][repo]['assessments']=[{'task':str(pathlib.Path(plan).resolve()),'revision':'r1','risk':'ordinary','reason':'test'}]; open(p,'w').write(json.dumps(d))
PY

run_start() {
  local version="$1" path="${2:-$SANDBOX/bin:/usr/bin:/bin}" out rc
  _sbx_env; local e=(); local v
  for v in "${SBX_ENV[@]}"; do case "$v" in PATH=*) e+=("PATH=$path");; FAKE_GH_VERSION=*) e+=("FAKE_GH_VERSION=$version");; *) e+=("$v");; esac; done
  out="$(env -i "${e[@]}" GH_TOKEN=fake GH_HOST=github.com bash "$SANDBOX/kit/handoff-orchestrate.sh" start "$plan" --backend claude --publication-owner supervisor 2>&1)"; rc=$?
  printf '%s\n' "$rc" >"$SANDBOX/state/start.rc"
  printf '%s\n' "$out" >"$SANDBOX/state/start.out"
}

run_start 2.23.0
[ "$(cat "$SANDBOX/state/start.rc")" -eq 2 ] || fail "old gh start did not exit 2: $(cat "$SANDBOX/state/start.out")"
assert_contains "$SANDBOX/state/start.out" 'preflight:gh — gh >= 2.48 required, found 2.23.0'
/usr/bin/grep -q '^orchestration: planned' "$plan" || fail "old gh changed plan state"
assert_no_file "${plan%.md}.driver.log"

for version in 2.48.0 2.103.3; do
  rm -f "$(git -C "$repo" rev-parse --absolute-git-dir)/handoff-plan.lock"
  run_start "$version"
  [ "$(cat "$SANDBOX/state/start.rc")" -eq 0 ] || fail "gh $version did not proceed: $(cat "$SANDBOX/state/start.out")"
  if /usr/bin/grep -q 'preflight:gh' "$SANDBOX/state/start.out"; then fail "gh $version was refused"; fi
  /usr/bin/grep -q 'driver launched:' "$SANDBOX/state/start.out" || fail "gh $version did not pass preflight"
  orch stop "$plan" >/dev/null 2>&1 || true
  wait_for 10 test '!' -f "${plan%.md}.lock" || fail "driver lock remained after stop"
  python3 - "$plan" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('orchestration: paused', 'orchestration: planned', 1); open(p,'w').write(s)
PY
  rm -f "$(git -C "$repo" rev-parse --absolute-git-dir)/handoff-plan.lock"
done

# Manual policy is not gated.
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$repo" false >/dev/null
run_start 2.23.0
if /usr/bin/grep -q 'preflight:gh' "$SANDBOX/state/start.out"; then fail "manual policy was refused by gh version"; fi

# Missing gh is diagnosed only for auto policy.
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$repo" true >/dev/null
run_start 2.23.0 "$SANDBOX/no-gh:/usr/bin:/bin"
assert_contains "$SANDBOX/state/start.out" 'preflight:gh — gh >= 2.48 required, found none'

# Retry must gate before merge-state, even if the PR could already be merged.
retry_plan="$(dirname "$plan")/retry-version-plan.md"
make_plan "$retry_plan" "$brief"
python3 - "$retry_plan" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('base: main', 'base: dev', 1).replace('orchestration: planned', 'orchestration: awaiting-merge', 1).replace('updated: 2026-01-01', 'updated: 2026-01-01\nrevision: r1\nfinal-reviewed-head: '+'a'*40, 1); open(p,'w').write(s)
PY
: >"$SANDBOX/state/gh.log"
_sbx_env; env -i "${SBX_ENV[@]}" FAKE_GH_VERSION=2.23.0 GH_TOKEN=fake GH_HOST=github.com bash "$SANDBOX/kit/handoff-orchestrate.sh" resume "$retry_plan" --retry-merge --backend claude --publication-owner supervisor >"$SANDBOX/state/retry.out" 2>&1 && fail "old gh retry unexpectedly succeeded"
assert_contains "$SANDBOX/state/retry.out" 'preflight:gh — gh >= 2.48 required, found 2.23.0'
/usr/bin/grep -q '^orchestration: awaiting-merge' "$retry_plan" || fail "retry refusal changed plan state"
if /usr/bin/grep -q 'api' "$SANDBOX/state/gh.log"; then fail "retry called gh api before version refusal"; fi

echo ok
