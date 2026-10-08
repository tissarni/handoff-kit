#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

# The prompt the last review session was given (the fake logs its argv; the prompt is last).
last_prompt() {
  python3 - "$SANDBOX/state/calls.log" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding='utf-8') if l.strip()]
print([r for r in recs if r['stage'] == 'review'][-1]['argv'][-1])
PY
}
# Assert each literal line appears in the prompt, in this order.
in_order() {
  python3 - "$1" "${@:2}" <<'PY'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
at = 0
for want in sys.argv[2:]:
    try:
        at = lines.index(want, at) + 1
    except ValueError:
        sys.exit(f'missing, or out of order: {want!r}')
PY
}
P="$SANDBOX/tmp/prompt.txt"

# 1. No claim table: the report block carries this launch's brief-check output.
B1="$(make_brief testsub wr-none.md draft)"
printf '## §2 State\n\n- The helper is `lib/nowhere.py`.\n' >>"$B1"
launch review "$B1" --backend claude >/dev/null 2>&1 || fail "review 1 failed"
last_prompt >"$P"
W="$(/usr/bin/grep -m1 '^WARN ' "${B1%.md}.check.md")"
[ -n "$W" ] || fail "no WARN line in ${B1%.md}.check.md"
in_order "$P" '=== BRIEF-CHECK REPORT ===' "$W" 'RESULT 0 FAIL · 1 WARN' '=== CLAIM TABLE ===' 'none' '=== BRIEF UNDER REVIEW ===' 'revision: r1' \
  || fail "review 1 prompt: $(head -c 600 "$P")"

# 2. A claim table for this revision is inlined whole, with no STALE line.
B2="$(make_brief testsub wr-fresh.md draft)"
cat >"${B2%.md}.claims.md" <<'T'
# Claim check — wr-fresh.md — revision r1 — 2026-01-01

1. HOLDS — the harness has a fake claude — `tests/fakes/claude:1` "#!/usr/bin/env bash"
RESULT 1 claims · 1 hold · 0 do not hold · 0 cannot tell
T
launch review "$B2" --backend claude >/dev/null 2>&1 || fail "review 2 failed"
last_prompt >"$P"
in_order "$P" '=== BRIEF-CHECK REPORT ===' 'RESULT 0 FAIL · 0 WARN' '=== CLAIM TABLE ===' '# Claim check — wr-fresh.md — revision r1 — 2026-01-01' \
  'RESULT 1 claims · 1 hold · 0 do not hold · 0 cannot tell' '=== BRIEF UNDER REVIEW ===' || fail "review 2 prompt: $(head -c 600 "$P")"
! /usr/bin/grep -q '^STALE: ' "$P" || fail "review 2: a fresh table was marked STALE"

# 3. A table written for another revision is marked STALE and still shown.
B3="$(make_brief testsub wr-stale.md draft)"
sed 's/revision r1/revision r0/; s/wr-fresh/wr-stale/' "${B2%.md}.claims.md" >"${B3%.md}.claims.md"
launch review "$B3" --backend claude >/dev/null 2>&1 || fail "review 3 failed"
last_prompt >"$P"
in_order "$P" '=== CLAIM TABLE ===' 'STALE: revision r0, brief is r1' '# Claim check — wr-stale.md — revision r0 — 2026-01-01' '=== BRIEF UNDER REVIEW ===' \
  || fail "review 3 prompt: $(head -c 600 "$P")"

# 4. Past the argv size limit the reports are left out and the review still runs.
B4="$(make_brief testsub wr-big.md draft)"
python3 - "$B4" "${B4%.md}.claims.md" <<'PY2'
import sys
brief, claims = sys.argv[1], sys.argv[2]
with open(brief, 'a', encoding='utf-8') as f:
    f.write('## §9 Known traps\n\n')
    i = 0
    while f.tell() < 122000:
        f.write('Filler line %05d for the prompt size guard, plain prose and nothing else.\n' % i); i += 1
with open(claims, 'w', encoding='utf-8') as f:
    f.write('# Claim check — wr-big.md — revision r1 — 2026-01-01\n\n')
    for n in range(1, 61):
        f.write('%d. HOLDS — filler claim %d, long enough to count against the size limit of one argv string — `a:1` "x"\n' % (n, n))
    f.write('RESULT 60 claims · 60 hold · 0 do not hold · 0 cannot tell\n')
PY2
OUT="$(launch review "$B4" --backend claude 2>&1)" || fail "review 4 failed. Output:
$OUT"
printf '%s\n' "$OUT" | /usr/bin/grep -qxF 'WARNING: brief and reports pass 126000 bytes — the review gets the brief alone' \
  || fail "review 4: no size WARNING. Output: $(printf '%s\n' "$OUT" | tail -n 5)"
last_prompt >"$P"
in_order "$P" '=== BRIEF-CHECK REPORT ===' 'omitted: the prompt would pass the 128 KiB argument limit' '=== CLAIM TABLE ===' \
  'omitted: the prompt would pass the 128 KiB argument limit' '=== BRIEF UNDER REVIEW ===' || fail "review 4 prompt: $(head -c 600 "$P")"
! /usr/bin/grep -q '^# Claim check' "$P" || fail "review 4: the claim table was sent past the limit"
[ "$(state_of "$B4")" = reviewed ] || fail "expected big brief reviewed, got '$(state_of "$B4")'"

echo ok
