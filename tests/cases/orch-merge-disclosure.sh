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
assert_contains "${plan%.md}.events.log" 'effective=auto'
assert_eq "$(sha256sum "$policy" | cut -d' ' -f1)" "$before" "disclosure changed policy bytes"
echo ok
