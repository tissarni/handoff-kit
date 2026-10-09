#!/usr/bin/env bash
# The driver hands the plan's base to the loop, so a pre-existing failure is proven against
# it, and the phase summary lists the proven item under BRIEF WAS WRONG.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

REPO="$SANDBOX/repo_under.test"
# origin/release reads differently from origin/main: only a proof against release can hold
( builtin cd "$REPO" && export HOME="$SANDBOX/home" && git checkout -q -b release && echo release >README.md \
  && git commit -qam "test: release" && git push -q origin release && git checkout -q main )
B="$(make_brief testsub o-pe.md draft)"
printf '\n## §4 Goal, and Done when\n\n1. `cat README.md` prints `fixed`.\n' >>"$B"
PLAN="$(dirname "$B")/o-plan.md"
make_plan "$PLAN" "$B"
sed -i 's/^base: main$/base: release/' "$PLAN"
STATUS="${PLAN%.md}.status.md"

FAKE_CLAUDE="run=commit,close=FAIL-preexisting-once"
orch start "$PLAN" --backend claude >/dev/null 2>&1
settled() { [ -f "$STATUS" ] && head -1 "$STATUS" | /usr/bin/grep -qE '^(DONE|NEEDS YOU)'; }
wait_for 120 settled || fail "phase did not settle within 120s (status: $(head -1 "$STATUS" 2>/dev/null))"
head -1 "$STATUS" | /usr/bin/grep -q '^DONE' || fail "phase did not finish: $(head -1 "$STATUS")"

/usr/bin/grep -qxF -e '- (o-pe) §4.1 · proven — every command exits and prints byte-identically on origin/release' "$STATUS" \
  || fail "no proven line under BRIEF WAS WRONG:
$(sed -n '/BRIEF WAS WRONG/,/^### NOT DONE/p' "$STATUS")"

echo ok
