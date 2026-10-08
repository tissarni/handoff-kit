#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub g2-brief1.md draft)"
PLAN="$(dirname "$BRIEF")/g2-plan.md"
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

FAKE_CLAUDE="run=no-report"
orch start "$PLAN" --backend claude >/dev/null 2>&1

notified() { /usr/bin/grep -qE 'NOTIFY sent — NEEDS YOU|driver exiting' "$EVENTS" 2>/dev/null; }
wait_for 60 notified || fail "no NOTIFY/driver-exiting event within 60s. Events:
$(cat "$EVENTS" 2>/dev/null)"

FIRST="$(head -1 "$STATUS")"
NAME="$(basename "$BRIEF" .md)"
case "$FIRST" in
  "NEEDS YOU · broken at $NAME · run:dead — "*) ;;
  *) fail "expected status line 1 'NEEDS YOU · broken at $NAME · run:dead — ...', got: $FIRST" ;;
esac

LOG="$(ls "${BRIEF%.md}".failed-*.log 2>/dev/null | head -1)"
[ -n "$LOG" ] || fail "expected a ${BRIEF%.md}.failed-*.log"

assert_contains "$STATUS" '### What failed · class: fixable'
assert_contains "$SANDBOX/state/curl.log" 'class: fixable'

while IFS= read -r L; do
  assert_contains "$STATUS" "- $L"
done < <(python3 -c "
lines = [l for l in open('$LOG', encoding='utf-8').read().splitlines() if l.strip()]
for l in lines[-5:]:
    s = ' '.join(l.split())
    if s.startswith('- '): s = s[2:]
    print(s[:200])
")

echo ok
