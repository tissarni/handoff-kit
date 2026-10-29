#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init
[ -x "$SANDBOX/kit/handoff-merge.py" ] || fail "sandbox omitted handoff-merge.py"

# Empty settings resolve manually; repository choices are exact and independent.
helper="$SANDBOX/kit/handoff-merge.py"
repo_a="$SANDBOX/repo_under.test"
repo_b="$SANDBOX/vault/02-projects/other"
mkdir -p "$repo_b"
git -C "$repo_b" init -q -b main
OUT="$(HOME="$SANDBOX/home" python3 "$helper" policy-get --repo "$repo_a" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "policy-get failed: $OUT"
assert_eq "$OUT" manual
HOME="$SANDBOX/home" python3 "$helper" default-set true
HOME="$SANDBOX/home" python3 "$helper" default-get | /usr/bin/grep -qx true
cp "$SANDBOX/home/.config/handoff/config.env" "$SANDBOX/default.good"
if OUT="$(HOME="$SANDBOX/home" python3 "$helper" default-set yes 2>&1)"; then RC=0; else RC=$?; fi
[ "$RC" -ne 0 ] || fail "invalid installation default was accepted"
cmp -s "$SANDBOX/default.good" "$SANDBOX/home/.config/handoff/config.env" || fail "invalid default partially changed config"
HOME="$SANDBOX/home" python3 "$helper" policy-get --repo "$repo_a" | /usr/bin/grep -qx 'manual'
HOME="$SANDBOX/home" python3 "$helper" policy-init --repo "$repo_a" --choice true
HOME="$SANDBOX/home" python3 "$helper" policy-set --repo "$repo_b" false
if HOME="$SANDBOX/home" python3 "$helper" override --repo "$repo_b" --task /plans/task-b.md --revision rev-1 --risk ordinary --approve 2>&1; then
  fail "task approval elevated a manual repository policy"
fi
HOME="$SANDBOX/home" python3 "$helper" assess --repo "$repo_a" --task /plans/task-a.md --revision rev-1 --risk ordinary --reason routine
HOME="$SANDBOX/home" python3 "$helper" effective --repo "$repo_a" --task /plans/task-a.md --revision rev-1 | /usr/bin/grep -qx 'auto'
HOME="$SANDBOX/home" python3 "$helper" effective --repo "$repo_b" --task /plans/task-b.md --revision rev-1 | /usr/bin/grep -qx 'manual — repository policy manual'
HOME="$SANDBOX/home" python3 "$helper" policy-set --repo "$repo_b" true
HOME="$SANDBOX/home" python3 "$helper" assess --repo "$repo_b" --task /plans/task-b.md --revision rev-1 --risk uncertain --reason risk-review
HOME="$SANDBOX/home" python3 "$helper" override --repo "$repo_b" --task /plans/task-b.md --revision rev-1 --risk uncertain --approve
HOME="$SANDBOX/home" python3 "$helper" effective --repo "$repo_b" --task /plans/task-b.md --revision rev-1 | /usr/bin/grep -qx 'auto'
HOME="$SANDBOX/home" python3 "$helper" effective --repo "$repo_b" --task /plans/task-c.md --revision rev-1 | /usr/bin/grep -qx 'manual — no risk assessment'
HOME="$SANDBOX/home" python3 "$helper" assess --repo "$repo_b" --task /plans/task-b.md --revision rev-1 --risk breaking-api --reason updated-risk
HOME="$SANDBOX/home" python3 "$helper" effective --repo "$repo_b" --task /plans/task-b.md --revision rev-1 --risk ordinary | /usr/bin/grep -qx 'manual — risk breaking-api'
HOME="$SANDBOX/home" python3 "$helper" override --repo "$repo_b" --task /plans/task-b.md --revision rev-1 --risk breaking-api --approve
HOME="$SANDBOX/home" python3 "$helper" effective --repo "$repo_b" --task /plans/task-b.md --revision rev-1 --risk ordinary | /usr/bin/grep -qx 'auto'
HOME="$SANDBOX/home" python3 "$helper" effective --repo "$repo_b" --task /plans/task-b.md --revision rev-2 | /usr/bin/grep -qx 'manual — no risk assessment'
printf '%s\n' 'auto-merge policy isolation and scoped override passed'
