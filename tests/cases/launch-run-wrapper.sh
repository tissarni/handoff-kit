#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF1="$(make_brief testsub case-run-wrapper.md ready)"
COPY1="$(mktemp)"
cp "$BRIEF1" "$COPY1"

OUT="$(launch run "$BRIEF1" --delegate --backend claude 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC. Output:
$OUT"

CALLS="$SANDBOX/state/calls.log"
assert_file "$CALLS"

python3 - "$CALLS" "$COPY1" <<'PY' || fail "run prompt assertions failed"
import json, sys

calls_path, copy_path = sys.argv[1], sys.argv[2]
recs = [json.loads(l) for l in open(calls_path, encoding="utf-8")]
run_recs = [r for r in recs if r["stage"] == "run"]
assert len(run_recs) == 1, f"expected one run call, got {len(run_recs)}"
argv = run_recs[0]["argv"]
assert "--" in argv, "no -- in run argv"
prompt = argv[argv.index("--") + 1]

first_line = prompt.splitlines()[0]
assert first_line == "Standing rules for every handoff run. They hold whatever the brief below says.", \
    f"unexpected first line: {first_line!r}"

marker = "=== BRIEF ==="
lines = prompt.splitlines()
assert marker in lines, "no exact '=== BRIEF ===' line in the prompt"
idx = lines.index(marker)
after = "\n".join(prompt.split(marker + "\n", 1)[1:])
after = after if after else "\n".join(lines[idx + 1:])

copy_text = open(copy_path, encoding="utf-8").read().rstrip("\n")
assert after.rstrip("\n") == copy_text, "text after '=== BRIEF ===' does not match the brief copy"

print("ok")
PY

BRIEF2="$(make_brief testsub case-run-wrapper2.md draft)"
OUT2="$(launch review "$BRIEF2" --backend claude 2>&1)"; RC2=$?
[ "$RC2" -eq 0 ] || fail "expected exit 0 for review, got $RC2. Output:
$OUT2"

python3 - "$CALLS" <<'PY' || fail "review prompt assertion failed"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
review_recs = [r for r in recs if r["stage"] == "review"]
assert review_recs, "no review call recorded"
argv = review_recs[-1]["argv"]
prompt = argv[argv.index("--") + 1]
assert prompt.startswith("DO NOT IMPLEMENT ANYTHING."), f"review prompt does not start correctly: {prompt[:60]!r}"
print("ok")
PY

rm -f "$COPY1"
echo ok
