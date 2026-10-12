#!/usr/bin/env bash
# A plan rewrite goes through a temp file and a rename, so a driver that reads the plan
# mid-write never sees it empty. A rename changes the inode; an in-place write does not.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF1="$(make_brief testsub oa-brief1.md draft)"
PLAN="$(dirname "$BRIEF1")/oa-plan.md"
make_plan "$PLAN" "$BRIEF1"
STATUS="${PLAN%.md}.status.md"
chmod 0640 "$PLAN"

ino_mode() { python3 -c 'import os, sys; s = os.stat(sys.argv[1]); print(s.st_ino, oct(s.st_mode & 0o7777))' "$1"; }
BEFORE="$(ino_mode "$PLAN")"
# Hold the original inode with a link outside the specs dir: later rewrites free and reuse inodes,
# and a reused one would pass an in-place write's check by luck.
ln "$PLAN" "$SANDBOX/tmp/original" || fail "could not link the original"

FAKE_CLAUDE="run=commit"
orch start "$PLAN" --backend claude >/dev/null 2>&1

is_done() { [ -f "$STATUS" ] && head -1 "$STATUS" | /usr/bin/grep -q '^DONE'; }
wait_for 120 is_done || fail "phase did not finish within 120s (status: $(head -1 "$STATUS" 2>/dev/null))"

AFTER="$(ino_mode "$PLAN")"
[ "${BEFORE%% *}" != "${AFTER%% *}" ] || fail "the plan was rewritten in place"
[ "${BEFORE#* }" = "${AFTER#* }" ] || fail "the plan's mode changed from ${BEFORE#* } to ${AFTER#* }"
LEFT="$(find "$(dirname "$PLAN")" -name "$(basename "$PLAN").tmp.*" | head -1)"
[ -z "$LEFT" ] || fail "a temp file is left beside the plan: $LEFT"

SRC="${HANDOFF_SCRIPTS_DIR:-$REPO_ROOT}"
HITS="$(/usr/bin/grep -n -F -e '>"$LOCK"' -e '>"$STAGE_FILE"' -e "io.open(path, 'w'" "$SRC/handoff-orchestrate.sh" "$SRC/handoff-launch.sh")"
[ -z "$HITS" ] || fail "an in-place state write is left:
$HITS"

echo ok
