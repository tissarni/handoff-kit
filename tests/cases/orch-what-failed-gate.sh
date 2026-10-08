#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub d-brief1.md draft)"
PLAN="$(dirname "$BRIEF")/d-plan.md"
make_plan "$PLAN" "$BRIEF"
python3 -c "
import sys
p = sys.argv[1]
t = open(p, encoding='utf-8').read()
t = t.replace(\"notify: ''\", 'notify: telegram')
open(p, 'w', encoding='utf-8').write(t)
" "$PLAN"
STATUS="${PLAN%.md}.status.md"
EVENTS="${PLAN%.md}.events.log"

mkdir -p "$SANDBOX/home/.config/handoff"
cat >"$SANDBOX/home/.config/handoff/notify.env" <<'EOF'
TELEGRAM_BOT_TOKEN=test-token
TELEGRAM_CHAT_ID=1
EOF

FAKE_CLAUDE="review=REWRITE,revise=held"
orch start "$PLAN" --backend claude >/dev/null 2>&1

notified() { /usr/bin/grep -qE 'NOTIFY sent — NEEDS YOU|driver exiting' "$EVENTS" 2>/dev/null; }
wait_for 60 notified || fail "no NOTIFY/driver-exiting event within 60s. Events:
$(cat "$EVENTS" 2>/dev/null)"

FIRST="$(head -1 "$STATUS")"
NAME="$(basename "$BRIEF" .md)"
case "$FIRST" in
  "NEEDS YOU · broken at $NAME · gate:held — "*) ;;
  *) fail "expected status line 1 'NEEDS YOU · broken at $NAME · gate:held — ...', got: $FIRST" ;;
esac

W="$(python3 -c "
import re
text = open('${BRIEF%.md}.review.md', encoding='utf-8').read()
line = next(l for l in text.splitlines() if '[WRONG]' in l)
s = ' '.join(line.split())
if s.startswith('- '): s = s[2:]
print(s[:200])
")"

assert_contains "$STATUS" '### What failed · class: decision'
assert_contains "$STATUS" "- $W"
assert_contains "$SANDBOX/state/curl.log" 'class: decision'
assert_contains "$SANDBOX/state/curl.log" "- $W"

echo ok
