#!/usr/bin/env bash
# brief-check.sh --done-when: the §4 commands the launcher re-runs before the close, one
# JSON line per numbered item; placeholders, writes and file-less greps are skipped.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

B="$SANDBOX/dw-fixture.md"
cat >"$B" <<'EOF'
---
handoff: draft
revision: r1
---

## §3 Settled

1. `test -f nothing-here` exits 0 — outside §4, never listed.

## §4 Goal, and Done when

1. `set -o pipefail; bash tests/run.sh 2>&1 | tail -n 40` prints `3 passed, 0 failed` (5 s).
2. The bite holds:

   ```bash
   d=$(mktemp -d) && git -C "$d" init -q && echo "rc=$?"
   ```

   prints `rc=0`.
3. `git log --oneline -1 <branch>` shows the commit.
4. `git push origin feat/x` succeeds.
5. In `README.md`, `/usr/bin/grep -c foo` prints `0`.
6. The PR description reads well.
7. `test -f README.md` and `test -d tests` both exit 0.

## §5 Step 0

1. `test -f later` exits 0 — after §4, never listed.
EOF

OUT="$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 bash "$SANDBOX/kit/brief-check.sh" --done-when "$B" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "--done-when exit $RC. Output:
$OUT"
printf '%s\n' "$OUT" >"$SANDBOX/dw.jsonl"
python3 - "$SANDBOX/dw.jsonl" <<'PY' || fail "unexpected --done-when output:
$OUT"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding='utf-8') if l.strip()]
def cmds(n):
    return [(c['kind'], c['cmd']) for c in rows[n - 1]['commands']]
def why(n):
    return [s['why'] for s in rows[n - 1]['skipped']]
checks = [
    ([r['item'] for r in rows], [1, 2, 3, 4, 5, 6, 7]),
    (rows[0]['line'], 12),
    (cmds(1), [('span', 'set -o pipefail; bash tests/run.sh 2>&1 | tail -n 40')]),
    (cmds(2), [('fence', 'd=$(mktemp -d) && git -C "$d" init -q && echo "rc=$?"')]),
    ((cmds(3), why(3)), ([], ['placeholder'])),
    ((cmds(4), why(4)), ([], ['denied'])),
    ((cmds(5), why(5)), ([], ['no-file'])),
    ((cmds(6), why(6)), ([], [])),
    (cmds(7), [('span', 'test -f README.md'), ('span', 'test -d tests')]),
]
bad = [(got, want) for got, want in checks if got != want]
for got, want in bad:
    print('got  %r\nwant %r' % (got, want))
sys.exit(1 if bad else 0)
PY

# a brief with no §4 prints nothing; a missing argument is a usage error
NO4="$SANDBOX/no-section.md"
printf -- '---\nhandoff: draft\n---\n\n## §3 Settled\n\n1. `test -f x` exits 0.\n' >"$NO4"
OUT="$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 bash "$SANDBOX/kit/brief-check.sh" --done-when "$NO4" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "no-§4 brief: exit $RC, output: $OUT"
env -i PATH=/usr/bin:/bin LANG=C.UTF-8 bash "$SANDBOX/kit/brief-check.sh" --done-when >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "missing brief: expected exit 2, got $RC"

echo ok
