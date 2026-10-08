#!/usr/bin/env bash
# A brief for the kit's own repo may say "vault": it is the kit's word for the notes repo it
# works with. Any other repo's brief may not, and a note path fails in every repo.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

FX="$REPO_ROOT/tests/fixtures/brief-check"
_sbx_env
env -i "${SBX_ENV[@]}" bash "$FX/make-repo.sh" "$SANDBOX/tmp/fx" || fail "make-repo.sh failed"
R="$SANDBOX/tmp/fx/repo"

# The kit's shape: the three engine scripts at the top, on feat/x only.
for f in handoff-launch.sh handoff-orchestrate.sh brief-check.sh; do
  printf '#!/usr/bin/env bash\n' >"$R/$f"
done
(
  cd "$R"
  export HOME="$SANDBOX/home"
  export GIT_AUTHOR_DATE="2026-01-08T12:00:00+00:00" GIT_COMMITTER_DATE="2026-01-08T12:00:00+00:00"
  git add handoff-launch.sh handoff-orchestrate.sh brief-check.sh
  git commit -q -m "add the engine scripts"
  git push -q origin feat/x
) || fail "kit fixture commit/push failed"

BRIEF="$SANDBOX/tmp/kit-brief.md"
cat >"$BRIEF" <<EOF
---
repo: $R
branch: feat/x
---

# Kit fixture

## §1 Why this exists

The vault holds the briefs that this kit runs.
EOF

# 1. The kit's repo: the word passes.
OUT="$(env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/brief-check.sh" "$BRIEF" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "kit repo: expected exit 0, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF -- 'RESULT 0 FAIL · 0 WARN' || fail "kit repo: expected a clean result. Output:
$OUT"

# 2. main lacks the three scripts, so there the word is a pointer again.
OUT="$(env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/brief-check.sh" "$BRIEF" --branch main 2>&1)"; RC=$?
[ "$RC" -eq 1 ] || fail "other repo: expected exit 1, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF -- "FAIL sweep §1 10 — matched 'vault'" || fail "other repo: expected the vault FAIL. Output:
$OUT"

# 3. In the kit's repo a note path still fails, and the word still passes.
printf 'Its notes sit under `02-projects/`.\n' >>"$BRIEF"
OUT="$(env -i "${SBX_ENV[@]}" bash "$SANDBOX/kit/brief-check.sh" "$BRIEF" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] || fail "note path: expected exit 1, got $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qF -- "FAIL sweep §1 11 — matched '02-projects/'" || fail "note path: expected the note-path FAIL. Output:
$OUT"
if printf '%s\n' "$OUT" | /usr/bin/grep -qF -- "matched 'vault'"; then
  fail "note path: the word failed in the kit's repo. Output:
$OUT"
fi

echo ok
