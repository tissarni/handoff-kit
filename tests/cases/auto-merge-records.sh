#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init
helper="$SANDBOX/kit/handoff-merge.py"
repo="$SANDBOX/repo_under.test"
other="$SANDBOX/other-repo"
mkdir -p "$other"
git -C "$other" init -q -b main
home="$SANDBOX/home"
run() { HOME="$home" python3 "$helper" "$@"; }
expect() { expected="${!#}"; set -- "${@:1:$#-1}"; actual="$(run "$@")" || fail "command failed: $*"; [ "$actual" = "$expected" ] || fail "got '$actual', expected '$expected'"; }
task=/plans/task-a.md

run policy-set --repo "$repo" true >/dev/null
expect effective --repo "$repo" --task "$task" --revision r1 'manual — no risk assessment'
run assess --repo "$repo" --task "$task" --revision r1 --risk ordinary --reason routine >/dev/null
expect effective --repo "$repo" --task "$task" --revision r1 auto
run override --repo "$repo" --task "$task" --revision r1 --risk ordinary --approve >/dev/null
run assess --repo "$repo" --task "$task" --revision r1 --risk breaking-api --reason reviewed >/dev/null
expect effective --repo "$repo" --task "$task" --revision r1 'manual — risk breaking-api'
expect effective --repo "$repo" --task "$task" --revision r1 --risk ordinary 'manual — risk breaking-api'
run override --repo "$repo" --task "$task" --revision r1 --risk breaking-api --approve >/dev/null
expect effective --repo "$repo" --task "$task" --revision r1 auto
run override --repo "$repo" --task /plans/foreign.md --revision r1 --risk breaking-api --approve >/dev/null
expect effective --repo "$repo" --task /plans/foreign.md --revision r1 'manual — no risk assessment'
expect effective --repo "$repo" --task "$task" --revision r2 'manual — no risk assessment'
run override --repo "$repo" --task "$task" --revision r2 --risk breaking-api --approve >/dev/null
expect effective --repo "$repo" --task "$task" --revision r1 auto
run hold --repo "$repo" >/dev/null
expect effective --repo "$repo" --task "$task" --revision r1 'manual — hold'
run release --repo "$repo" >/dev/null
run hold --repo "$repo" --task "$task" >/dev/null
expect effective --repo "$repo" --task "$task" --revision r1 'manual — hold'
run assess --repo "$repo" --task /plans/other.md --revision r1 --risk ordinary --reason independent >/dev/null
expect effective --repo "$repo" --task /plans/other.md --revision r1 auto
run release --repo "$repo" --task /plans/other.md >/dev/null
expect effective --repo "$repo" --task "$task" --revision r1 'manual — hold'
run release --repo "$repo" --task "$task" >/dev/null
expect effective --repo "$repo" --task "$task" --revision r1 auto
HANDOFF_MERGE_HOLD=1 expect effective --repo "$repo" --task "$task" --revision r1 'manual — hold'

# Legacy version-1 entries retain their defaults for all newly added records.
python3 - "$home/.config/handoff/project-policy.json" "$repo" <<'PY'
import json, sys
p, repo = sys.argv[1:]
with open(p, encoding='utf-8') as f: d=json.load(f)
d['repositories'][repo]={'enabled': True, 'overrides': []}
with open(p, 'w', encoding='utf-8') as f: json.dump(d, f)
PY
expect effective --repo "$repo" --task "$task" --revision r1 'manual — no risk assessment'

# Every record command rejects relative task identities without changing the store.
for command in assess override hold release effective; do
  cp "$home/.config/handoff/project-policy.json" "$SANDBOX/before"
  case "$command" in
    assess) args=(--repo "$repo" --task task-a --revision r1 --risk ordinary --reason test) ;;
    override) args=(--repo "$repo" --task task-a --revision r1 --risk ordinary --approve) ;;
    hold|release) args=(--repo "$repo" --task task-a) ;;
    effective) args=(--repo "$repo" --task task-a --revision r1) ;;
  esac
  if run "$command" "${args[@]}" >/dev/null 2>&1; then fail "$command accepted relative task identity"; fi
  cmp -s "$SANDBOX/before" "$home/.config/handoff/project-policy.json" || fail "$command changed store after relative task rejection"
done

# Validation spans repositories and refusals never rewrite invalid input.
python3 - "$home/.config/handoff/project-policy.json" "$repo" "$other" <<'PY'
import json, sys
p, repo, other = sys.argv[1:]
with open(p, encoding='utf-8') as f: d=json.load(f)
d['repositories'][repo]={'enabled': True, 'overrides': [], 'assessments': [], 'hold': False, 'task_holds': []}
d['repositories'][other]={'enabled': False, 'overrides': [], 'hold': 'false'}
with open(p, 'w', encoding='utf-8') as f: json.dump(d, f)
PY
cp "$home/.config/handoff/project-policy.json" "$SANDBOX/invalid"
expect effective --repo "$repo" --task "$task" --revision r1 'manual — invalid policy store'
if run assess --repo "$repo" --task "$task" --revision r2 --risk ordinary --reason test >/dev/null 2>&1; then fail "write accepted malformed other-repository entry"; fi
cmp -s "$SANDBOX/invalid" "$home/.config/handoff/project-policy.json" || fail "invalid write partially changed store"

for duplicate in assessment task_hold; do
  python3 - "$home/.config/handoff/project-policy.json" "$repo" "$duplicate" <<'PY'
import json, sys
p, repo, kind = sys.argv[1:]
with open(p, encoding='utf-8') as f: d=json.load(f)
e=d['repositories'][repo]
e['hold']=False
if kind == 'assessment':
 a={'task':'/plans/a.md','revision':'r1','risk':'ordinary','reason':'x'}
 e['assessments']=[a,a]
else:
 e['assessments']=[]; e['task_holds']=['/plans/a.md','/plans/a.md']
with open(p, 'w', encoding='utf-8') as f: json.dump(d, f)
PY
  cp "$home/.config/handoff/project-policy.json" "$SANDBOX/duplicate"
  expect effective --repo "$repo" --task "$task" --revision r1 'manual — invalid policy store'
  if run policy-set --repo "$repo" false >/dev/null 2>&1; then fail "write accepted duplicate $duplicate"; fi
  cmp -s "$SANDBOX/duplicate" "$home/.config/handoff/project-policy.json" || fail "duplicate $duplicate write changed store"
done
printf '%s\n' 'auto-merge record validation and effective decisions passed'
