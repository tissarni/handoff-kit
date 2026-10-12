#!/usr/bin/env bash
# A brief's state change goes through a temp file and a rename, so a reader of the
# frontmatter never sees the brief empty. A rename changes the inode; an in-place write does not.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub la-brief.md draft)"
chmod 0640 "$BRIEF"

ino_mode() { python3 -c 'import os, sys; s = os.stat(sys.argv[1]); print(s.st_ino, oct(s.st_mode & 0o7777))' "$1"; }
BEFORE="$(ino_mode "$BRIEF")"
# Hold the original inode with a link outside the specs dir: later rewrites free and reuse inodes,
# and a reused one would pass an in-place write's check by luck.
ln "$BRIEF" "$SANDBOX/tmp/original" || fail "could not link the original"

OUT="$(launch review "$BRIEF" --backend claude --model opus 2>&1)" || fail "launch review failed. Output:
$OUT"
[ "$(state_of "$BRIEF")" = reviewed ] || fail "expected brief reviewed, got '$(state_of "$BRIEF")'"

AFTER="$(ino_mode "$BRIEF")"
[ "${BEFORE%% *}" != "${AFTER%% *}" ] || fail "the brief was rewritten in place"
[ "${BEFORE#* }" = "${AFTER#* }" ] || fail "the brief's mode changed from ${BEFORE#* } to ${AFTER#* }"
LEFT="$(find "$(dirname "$BRIEF")" -name "$(basename "$BRIEF").tmp.*" | head -1)"
[ -z "$LEFT" ] || fail "a temp file is left beside the brief: $LEFT"

SRC="${HANDOFF_SCRIPTS_DIR:-$REPO_ROOT}"
HITS="$(/usr/bin/grep -n -F -e '>"$LOCK"' -e '>"$STAGE_FILE"' -e "io.open(path, 'w'" "$SRC/handoff-orchestrate.sh" "$SRC/handoff-launch.sh")"
[ -z "$HITS" ] || fail "an in-place state write is left:
$HITS"

echo ok
