#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

BRIEF="$(make_brief testsub g-brief1.md draft)"
printf 'Notes live in the vault.\n' >>"$BRIEF"
PLAN="$(dirname "$BRIEF")/g-plan.md"
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
cat >"$SANDBOX/home/.config/handoff/notify.env" <<'EOT'
TELEGRAM_BOT_TOKEN=test-token
TELEGRAM_CHAT_ID=1
EOT

orch start "$PLAN" --backend claude >/dev/null 2>&1

notified() { /usr/bin/grep -qE 'NOTIFY sent — NEEDS YOU|driver exiting' "$EVENTS" 2>/dev/null; }
wait_for 60 notified || fail "no NOTIFY/driver-exiting event within 60s. Events:
$(cat "$EVENTS" 2>/dev/null)"

FIRST="$(head -1 "$STATUS")"
EXPFIRST="NEEDS YOU · broken at g-brief1 · gate:brief-check — 1 FAIL · 0 WARN · first: sweep §- 24 — matched 'vault'"
[ "$FIRST" = "$EXPFIRST" ] || fail "expected status line 1 '$EXPFIRST', got: $FIRST"

assert_contains "$STATUS" '### What failed · class: fixable'
assert_contains "$STATUS" "- FAIL sweep §- 24 — matched 'vault'"
assert_contains "$SANDBOX/state/curl.log" 'class: fixable'
assert_contains "$SANDBOX/state/curl.log" "- FAIL sweep §- 24 — matched 'vault'"
[ ! -s "$SANDBOX/state/calls.log" ] || fail "a session was launched. calls.log:
$(cat "$SANDBOX/state/calls.log")"

echo ok
