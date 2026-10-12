#!/usr/bin/env bash
# tests/run.sh prints a failed case's driver log, then removes that case's sandbox; a passing
# case's sandbox is removed by the case itself. Runs a scratch copy of the runner on two
# synthetic cases, each in its own sandbox outside this one.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

SCRATCH="$SANDBOX/scratch"
PATHS="$SANDBOX/paths"
mkdir -p "$SCRATCH/tests/cases" "$PATHS"
cp "$REPO_ROOT/tests/run.sh" "$REPO_ROOT/tests/lib.sh" "$SCRATCH/tests/"
cp -r "$REPO_ROOT/tests/fakes" "$SCRATCH/tests/fakes"

cat >"$SCRATCH/tests/cases/synth-fail.sh" <<'SYN'
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init >/dev/null 2>&1
echo "SANDBOX=$SANDBOX"
printf '%s\n' "$SANDBOX" >"$RKFS_PATHS/fail"
echo "synthetic driver line 7731" >"$SANDBOX/x.driver.log"
fail "synthetic failure"
SYN
cat >"$SCRATCH/tests/cases/synth-pass.sh" <<'SYN'
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init >/dev/null 2>&1
echo "SANDBOX=$SANDBOX"
printf '%s\n' "$SANDBOX" >"$RKFS_PATHS/pass"
echo ok
SYN
chmod +x "$SCRATCH/tests/cases/"*.sh

OUT="$(HANDOFF_SCRIPTS_DIR="$REPO_ROOT" RKFS_PATHS="$PATHS" bash "$SCRATCH/tests/run.sh" synth-fail synth-pass 2>&1)"

printf '%s\n' "$OUT" | /usr/bin/grep -qF -e '--- driver log (tail) ---' \
  && printf '%s\n' "$OUT" | /usr/bin/grep -qF 'synthetic driver line 7731' \
  || { printf 'runner output:\n%s\n' "$OUT"; fail "run.sh printed no driver log for a failed case"; }

[ -s "$PATHS/fail" ] && [ -s "$PATHS/pass" ] || fail "a synthetic case did not record its sandbox. Output:
$OUT"
FAILBOX="$(cat "$PATHS/fail")"; PASSBOX="$(cat "$PATHS/pass")"
[ ! -e "$FAILBOX" ] || fail "run.sh left the failed case's sandbox behind: $FAILBOX"
[ ! -e "$PASSBOX" ] || fail "the passing case's sandbox is still there: $PASSBOX"
printf '%s\n' "$OUT" | /usr/bin/grep -qx '1 passed, 1 failed' || fail "unexpected summary. Output:
$OUT"

echo ok
