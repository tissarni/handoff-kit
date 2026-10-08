#!/usr/bin/env bash
# A §4 failure the close marks pre-existing? gets a second close that first re-runs the
# item on a clean checkout of origin/<base>. Byte-identical there proves it, and no fix-up
# is spent. A different output proves nothing, and the run breaks. HANDOFF_BASE picks the
# base. A mixed FAIL fixes the rest and proves the pre-existing item in the same close.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

REPO="$SANDBOX/repo_under.test"
CALLS="$SANDBOX/state/calls.log"
add_dw() {   # $1 = brief. §4.1 reads README.md, which the fake run never changes.
  cat >>"$1" <<'EOF'

## §4 Goal, and Done when

1. `cat README.md` prints `fixed`.
2. `test -f README.md` exits 0.

## §5 Step 0

Nothing.
EOF
}
stages() { python3 -c 'import json, sys; print(" ".join(json.loads(l)["stage"] for l in open(sys.argv[1]) if json.loads(l)["brief"] == sys.argv[2]))' "$CALLS" "$1"; }
fresh() { rm -f "$SANDBOX/state/fail-once-close"; }

# 1. proven: README.md reads the same on origin/main, so §4.1 prints byte-identically there.
# The repo's own post-checkout hook must not run in the throwaway checkout.
printf '#!/bin/sh\ntouch "%s/state/post-checkout-ran"\n' "$SANDBOX" >"$REPO/.git/hooks/post-checkout"
chmod +x "$REPO/.git/hooks/post-checkout"
B="$(make_brief testsub pe.md draft)"; add_dw "$B"
FAKE_CLAUDE="close=FAIL-preexisting-once"
OUT="$(launch loop "$B" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "proven: expected exit 0, got $RC. Output:
$OUT"
[ "$(state_of "$B")" = closed ] || fail "proven: expected closed, got '$(state_of "$B")'"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF 'pre-existing: the close FAILed only on §4.1, marked pre-existing? — closing again after a re-run on a clean checkout of the base' \
  || fail "proven: no pre-existing line. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF "pre-existing: 1 of 1 items proven on origin/main -> ${B%.md}.preexisting.md" \
  || fail "proven: no proof summary. Output:
$OUT"
[ "$(stages pe)" = "review revise run close close debrief" ] || fail "proven: stages $(stages pe)"
assert_no_file "${B%.md}.fixup.md"
/usr/bin/grep -qxF '§4.1 · proven — every command exits and prints byte-identically on origin/main' "${B%.md}.preexisting.md" \
  || fail "proven: bad proof file:
$(cat "${B%.md}.preexisting.md" 2>&1)"
head -1 "${B%.md}.preexisting.md" | /usr/bin/grep -qE '^# pre-existing proof · pe\.md · revision r1 · [0-9T:Z-]+ · head [0-9a-f]+ · origin/main [0-9a-f]+$' \
  || fail "proven: bad proof header: $(head -1 "${B%.md}.preexisting.md")"
python3 - "$CALLS" <<'PY' || fail "proven: the proof is not in the second close's prompt only"
import json, sys
closes = [r for r in map(json.loads, open(sys.argv[1], encoding='utf-8')) if r['stage'] == 'close' and r['brief'] == 'pe']
p1, p2 = closes[0]['argv'][-1], closes[1]['argv'][-1]
sys.exit(0 if '=== PRE-EXISTING PROOF ===' not in p1 and 'pre-existing?' in p1
         and '=== PRE-EXISTING PROOF ===\n# pre-existing proof · pe.md' in p2 else 1)
PY
[ "$(git -C "$REPO" worktree list | wc -l)" -eq 1 ] || fail "proven: the base checkout was left behind: $(git -C "$REPO" worktree list)"
assert_no_file "$SANDBOX/state/post-checkout-ran"
rm -f "$REPO/.git/hooks/post-checkout"

# 2. not proven: a local commit changes README.md, so the output differs from origin/main
( builtin cd "$REPO" && echo changed >README.md && HOME="$SANDBOX/home" git commit -qam "test: change README" )
fresh
B="$(make_brief testsub pe2.md draft)"; add_dw "$B"
OUT="$(launch loop "$B" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 20 ] || fail "not proven: expected exit 20, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF 'RUN: failed — close audit VERDICT: FAIL' || fail "not proven: no RUN line. Output:
$OUT"
/usr/bin/grep -qE '^§4\.1 · not proven — line [0-9]+: exit 0 · sha256 [0-9a-f]{16} here, exit 0 · sha256 [0-9a-f]{16} on origin/main$' "${B%.md}.preexisting.md" \
  || fail "not proven: bad proof file:
$(cat "${B%.md}.preexisting.md" 2>&1)"

# 3. HANDOFF_BASE: origin/release carries the changed README.md, so the proof there holds
git -C "$REPO" push -q origin HEAD:refs/heads/release
fresh
B="$(make_brief testsub pe3.md draft)"; add_dw "$B"
_sbx_env
OUT="$(env -i "${SBX_ENV[@]}" HANDOFF_BASE=release bash "$SANDBOX/kit/handoff-launch.sh" loop "$B" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "HANDOFF_BASE: expected exit 0, got $RC. Output:
$OUT"
assert_contains "${B%.md}.preexisting.md" '§4.1 · proven — every command exits and prints byte-identically on origin/release'

# 4. mixed: §4.1 is fixed by the fix-up, §4.2 is proven by the same second close
fresh
B="$(make_brief testsub pe4.md draft)"; add_dw "$B"
FAKE_CLAUDE="close=FAIL-fixable-pre-once"
OUT="$(launch loop "$B" --gate auto --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "mixed: expected exit 0, got $RC. Output:
$OUT"
[ "$(stages pe4)" = "review revise run close resume close debrief" ] || fail "mixed: stages $(stages pe4)"
assert_contains "${B%.md}.fixup.md" '- §4.1 fake criterion — refuted — fake evidence: exit 1'
assert_contains "${B%.md}.fixup.md" 'The close also marked §4.2 pre-existing?'
/usr/bin/grep -qF '§4.2 fake suite' "${B%.md}.fixup.md" && fail "mixed: the pre-existing finding went into the fix-up note"
assert_contains "${B%.md}.preexisting.md" '§4.2 · proven — every command exits and prints byte-identically on origin/main'

# 5. a dry run names the proof and runs nothing; --prove belongs to close alone
OUT="$(launch close "$B" --prove 1,2 --dry-run --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "dry run exit $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF "  prove:       §4.1, §4.2 would be re-run on a clean checkout of origin/main before the session; proof -> ${B%.md}.preexisting.md" \
  || fail "dry run: no prove line. Output:
$OUT"
OUT="$(launch review "$B" --prove 1 --dry-run --backend claude 2>&1)" && fail "review --prove was accepted"
printf '%s\n' "$OUT" | /usr/bin/grep -qF -- '--prove only applies to close (got mode review)' || fail "no --prove refusal. Output:
$OUT"

echo ok
