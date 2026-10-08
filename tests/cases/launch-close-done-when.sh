#!/usr/bin/env bash
# Before the close session, the launcher re-runs the brief's §4 commands in the repo and
# the close prompt carries §4 and their results; a dry run lists them and runs nothing.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

CALLS="$SANDBOX/state/calls.log"
B="$(make_brief testsub cdw.md reported)"
cat >>"$B" <<'EOF'

## §4 Goal, and Done when

1. `test -f README.md` exits 0.
2. `/usr/bin/grep -c 'not there' README.md` prints `1`.
3. The prose reads well.

## §5 Step 0

Nothing.
EOF
REPORT="${B%.md}.report.md"
printf '=== COMPLETION REPORT ===\nbrief-revision: r1\noutcome: COMPLETE\naudit: 1 checked, 0 refuted, 0 unconfirmed\n--- NOT DONE ---\n- none\n=== END COMPLETION REPORT ===\n' >"$REPORT"
DW="${B%.md}.done-when.md"
HEAD="$(git -C "$SANDBOX/repo_under.test" rev-parse --short HEAD)"

# 1. dry run: lists the commands, runs nothing, writes nothing
OUT="$(launch close "$B" --dry-run --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "dry-run exit $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF "  done-when:   2 commands from 3 §4 items would run in $SANDBOX/repo_under.test before the session, 600 s each; 1 items judged; results -> $DW" || fail "missing dry-run done-when line. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF '  §4.1 $ test -f README.md' || fail "dry run does not list §4.1. Output:
$OUT"
assert_no_file "$DW"

# 2. a close: the results file, then the prompt carries §4 and the results
OUT="$(launch close "$B" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "close exit $RC. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF "done-when: 2 commands run in 0 s · 1 exited non-zero · 1 of 3 §4 items judged -> $DW" || fail "missing done-when summary. Output:
$OUT"
head -1 "$DW" | /usr/bin/grep -qE "^# done-when · cdw\.md · revision r1 · [0-9T:Z-]+ · head $HEAD\$" || fail "bad results header: $(head -1 "$DW")"
python3 - "$DW" <<'PY' || fail "unexpected results file:
$(cat "$DW")"
import re, sys
lines = open(sys.argv[1], encoding='utf-8').read().split('\n')
want = [
    r'2 commands run in 0 s · 1 exited non-zero · 1 of 3 §4 items judged',
    r'§4\.1 · line 27 · exit 0 · 0s · sha256 e3b0c44298fc1c14',
    r'  \$ test -f README\.md',
    r'  \(no output\)',
    r'§4\.2 · line 28 · exit 1 · 0s · sha256 [0-9a-f]{16}',
    r"  \$ /usr/bin/grep -c 'not there' README\.md",
    r'  \| 0',
    r'§4\.3 · line 29 · judged — no command the launcher can run: check it yourself',
    r'',
]
got = lines[1:]
bad = len(got) != len(want) or any(not re.fullmatch(w, g) for w, g in zip(want, got))
if bad:
    print('\n'.join(got))
sys.exit(1 if bad else 0)
PY
python3 - "$CALLS" <<'PY' || fail "close prompt lacks §4 or the results. calls.log:
$(tail -c 3000 "$CALLS")"
import json, sys
rec = [json.loads(l) for l in open(sys.argv[1], encoding='utf-8') if l.strip()][-1]
p = rec['argv'][-1]
need = ['=== COMPLETION REPORT ===\n=== COMPLETION REPORT ===\nbrief-revision: r1',
        '=== BRIEF §4 ===\n## §4 Goal, and Done when\n\n1. `test -f README.md` exits 0.',
        '3. The prose reads well.\n=== DONE-WHEN RESULTS ===\n# done-when · cdw.md',
        '§4.2 · line 28 · exit 1', 'Every §4 item gets one finding']
missing = [n for n in need if n not in p]
print('missing:', missing) if missing else None
sys.exit(1 if missing or rec['stage'] != 'close' or '## §5' in p else 0)
PY

# 3. a command past its timeout is killed with its whole pipeline, and marked
T="$(make_brief testsub cdw-slow.md reported)"
printf '\n## §4 Goal, and Done when\n\n1. `bash -c "sleep 30 | cat"` exits 0.\n' >>"$T"
cp "$REPORT" "${T%.md}.report.md"
_sbx_env
s=$(date +%s)
OUT="$(env -i "${SBX_ENV[@]}" HANDOFF_DONE_WHEN_TIMEOUT=1 bash "$SANDBOX/kit/handoff-launch.sh" close "$T" --backend claude 2>&1)"; RC=$?
e=$(date +%s)
[ "$RC" -eq 0 ] || fail "slow close exit $RC. Output:
$OUT"
[ $((e - s)) -lt 20 ] || fail "the timed-out command was not killed: $((e - s)) s"
/usr/bin/grep -qE '^§4\.1 · line [0-9]+ · exit 124 · [0-9]+s · timed out after 1 s · sha256 ' "${T%.md}.done-when.md" || fail "no timed-out line:
$(cat "${T%.md}.done-when.md")"

# 4. a parser that crashes fails open: the close still runs and judges every item
printf '#!/usr/bin/env bash\necho "Traceback (most recent call last):" >&2\nexit 1\n' >"$SANDBOX/kit/brief-check.sh"
OUT="$(launch close "$B" --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "crash close exit $RC. Output:
$OUT"
assert_contains "$DW" 'none: brief-check.sh --done-when exited 1: Traceback (most recent call last): — every §4 item is a judged item: check each one yourself'
assert_contains "$CALLS" 'none: brief-check.sh --done-when exited 1'

echo ok
