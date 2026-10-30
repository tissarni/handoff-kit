#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

brief="$(make_brief testsub disclosure.md draft)"
plan="$(dirname "$brief")/disclosure-plan.md"
make_plan "$plan" "$brief"
python3 - "$plan" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('updated: 2026-01-01', 'updated: 2026-01-01\nrevision: r1', 1)
open(p,'w').write(s)
PY
repo="$SANDBOX/repo_under.test"
git -C "$repo" remote set-url origin https://github.com/acme/widget.git
mkdir -p "$SANDBOX/home/.config/handoff"
policy="$SANDBOX/home/.config/handoff/project-policy.json"
HOME="$SANDBOX/home" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$repo" true >/dev/null
python3 - "$policy" "$plan" "$repo" <<'PY'
import json,pathlib,sys
p,plan,repo=sys.argv[1:]
d=json.load(open(p)); d['repositories'][repo]['assessments']=[{'task':str(pathlib.Path(plan).resolve()),'revision':'r1','risk':'ordinary','reason':'reviewed'}]
open(p,'w').write(json.dumps(d))
PY
before="$(sha256sum "$policy" | cut -d' ' -f1)"
OUT="$(orch start "$plan" --backend claude --publication-owner supervisor 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "START failed: $OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -q 'MERGE POLICY' || fail "START omitted disclosure: $OUT"
assert_contains "${plan%.md}.events.log" 'MERGE POLICY'
assert_contains "${plan%.md}.events.log" 'effective=manual — auto-merge only targets dev (base main)'
assert_contains "${plan%.md}.events.log" 'repository-policy=auto forge=github risk=ordinary reason=reviewed override=no effective=manual — auto-merge only targets dev (base main)'
assert_contains "${plan%.md}.events.log" "consequence=manual: the plan ends at its PR; this repository's sequence waits for your merge"
assert_eq "$(sha256sum "$policy" | cut -d' ' -f1)" "$before" "disclosure changed policy bytes"

# A matching override can lift a risky assessment; an override for another
# revision cannot. Each START is stopped before the next matrix row.
stop_driver() {
  wait_for 10 test -f "${plan%.md}.lock" || true
  orch stop "$plan" >/dev/null 2>&1 || true
  wait_for 10 test '!' -f "${plan%.md}.lock" || true
}
stop_driver
# Keep the existing policy matrix focused on policy rather than base guarding.
python3 - "$plan" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('base: main', 'base: dev', 1); open(p,'w').write(s)
PY
set_policy_case() {
  local risk="$1" rev="$2" override_rev="$3"
  python3 - "$policy" "$plan" "$repo" "$risk" "$rev" "$override_rev" <<'PY'
import json,pathlib,sys
p,plan,repo,risk,rev,override_rev=sys.argv[1:]
d=json.load(open(p)); e=d['repositories'][repo]
task=str(pathlib.Path(plan).resolve())
e['assessments']=[{'task':task,'revision':rev,'risk':risk,'reason':'matrix reason'}]
e['overrides']=([{'task':task,'revision':override_rev,'risk':risk}] if override_rev else [])
open(p,'w').write(json.dumps(d))
PY
}
run_policy_case() {
  local expected="$1" before_case
  before_case="$(sha256sum "$policy" | cut -d' ' -f1)"
  OUT="$(orch start "$plan" --backend claude --publication-owner supervisor 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] || fail "matrix START failed: $OUT"
  printf '%s\n' "$OUT" | /usr/bin/grep -qF "$expected" || fail "missing '$expected': $OUT"
  assert_contains "${plan%.md}.events.log" "$expected"
  assert_eq "$(sha256sum "$policy" | cut -d' ' -f1)" "$before_case" "disclosure changed policy bytes"
  stop_driver
}
set_policy_case breaking-api r1 ''
run_policy_case 'effective=manual — risk breaking-api'
set_policy_case breaking-api r1 r1
run_policy_case 'effective=auto'
set_policy_case breaking-api r1 other-revision
run_policy_case 'effective=manual — risk breaking-api'

# No assessment has the actionable assess hint.
python3 - "$policy" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['repositories'][next(iter(d['repositories']))]['assessments']=[]; d['repositories'][next(iter(d['repositories']))]['overrides']=[]
open(p,'w').write(json.dumps(d))
PY
run_policy_case 'manual — no risk assessment'
assert_contains "${plan%.md}.events.log" 'assess with handoff-policy assess --repo'

# Repository manual and non-GitHub origins retain the manual consequence.
HOME="$SANDBOX/home" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$repo" false >/dev/null
run_policy_case 'manual: unchanged behaviour'
HOME="$SANDBOX/home" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$repo" true >/dev/null
git -C "$repo" remote set-url origin https://gitlab.example/acme/widget.git
set_policy_case ordinary r1 ''
run_policy_case 'forge=gitlab risk=ordinary reason=matrix reason override=no effective=auto consequence=manual: unchanged behaviour'
git -C "$repo" remote set-url origin https://github.com/acme/widget.git

# A revisionless plan must disclose a read-only manual reason and still start.
python3 - "$plan" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('revision: r1\n','',1); open(p,'w').write(s)
PY
run_policy_case 'manual — no plan revision'
before_resume="$(sha256sum "$policy" | cut -d' ' -f1)"
OUT="$(orch resume "$plan" --backend claude --publication-owner supervisor 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "RESUME failed: $OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -q 'MERGE POLICY' && fail "RESUME printed disclosure: $OUT"
assert_eq "$(sha256sum "$policy" | cut -d' ' -f1)" "$before_resume" "RESUME changed policy bytes"
echo ok
