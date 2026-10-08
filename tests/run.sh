#!/usr/bin/env bash
# Run every tests/cases/*.sh (or only the ones named on the command line), each in its
# own fresh sandbox. Prints PASS/FAIL per case, then "N passed, M failed". Exits 0 iff
# nothing failed.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASES_DIR="$DIR/cases"

if [ "$#" -gt 0 ]; then
  files=()
  for c in "$@"; do files+=("$CASES_DIR/$c.sh"); done
else
  files=("$CASES_DIR"/*.sh)
fi

pass=0
fail=0
for f in "${files[@]}"; do
  [ -f "$f" ] || { echo "FAIL $(basename "${f%.sh}") — no such case"; fail=$((fail+1)); continue; }
  name="$(basename "$f" .sh)"
  out="$(mktemp)"
  if HANDOFF_SCRIPTS_DIR="${HANDOFF_SCRIPTS_DIR:-}" bash "$f" >"$out" 2>&1; then
    echo "PASS $name"
    pass=$((pass+1))
  else
    reason="$(/usr/bin/grep -m1 '^FAIL:' "$out" || true)"
    [ -n "$reason" ] || reason="$(tail -1 "$out")"
    echo "FAIL $name — ${reason#FAIL: }"
    fail=$((fail+1))
    sbox="$(/usr/bin/grep -m1 '^SANDBOX=' "$out" | cut -d= -f2-)"
    if [ -n "$sbox" ] && [ -d "$sbox" ]; then
      dlog="$(find "$sbox" -name '*.driver.log' 2>/dev/null | head -1)"
      if [ -n "$dlog" ] && [ -f "$dlog" ]; then
        echo "  --- driver log (tail) ---"
        tail -20 "$dlog" | sed 's/^/  /'
      fi
      clog="$sbox/state/calls.log"
      if [ -f "$clog" ]; then
        echo "  --- calls.log (tail) ---"
        tail -20 "$clog" | sed 's/^/  /'
      fi
    fi
  fi
  rm -f "$out"
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
