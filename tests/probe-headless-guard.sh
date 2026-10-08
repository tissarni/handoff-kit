#!/usr/bin/env bash
# Live probe: proves the background-wait guard, the tool denial and the timeout kill
# actually work against the real claude CLI, on haiku, for about $0.10 (two sessions:
# the guard, then an overrun under CLAUDE_CODE_DISABLE_BACKGROUND_TASKS). tests/run.sh
# does not run it — it uses your own environment (the real login), not the sandbox's
# fakes.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
GUARD="$REPO_ROOT/guards/no-background-wait.py"
LAUNCHER="$REPO_ROOT/handoff-launch.sh"

[ -f "$GUARD" ] || { echo "probe: no guard at $GUARD"; exit 1; }

HEADLESS_DENY="$(/usr/bin/sed -n 's/^HEADLESS_DENY="\(.*\)"$/\1/p' "$LAUNCHER" | head -1)"
[ -n "$HEADLESS_DENY" ] || { echo "probe: could not read HEADLESS_DENY from $LAUNCHER"; exit 1; }

CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
[ -n "$CLAUDE_BIN" ] || { echo "probe: claude not found on PATH"; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

SETTINGS_FILE="$WORKDIR/settings.json"
python3 - "$SETTINGS_FILE" "$GUARD" <<'PY'
import json, shlex, sys
out, guard = sys.argv[1], sys.argv[2]
cmd = "python3 " + shlex.quote(guard)
config = {"hooks": {"PreToolUse": [{"matcher": "Bash",
                                     "hooks": [{"type": "command", "command": cmd}]}]}}
with open(out, "w", encoding="utf-8") as f:
    json.dump(config, f)
PY

OUT1="$WORKDIR/stream1.jsonl"
OUT2="$WORKDIR/stream2.jsonl"

# One headless haiku session. stdin must be /dev/null, or -p waits 3 s and warns.
# $1 = output file, $2 = prompt, the rest = `env` arguments for the session.
run_session() {
  local out="$1" prompt="$2"; shift 2
  ( cd "$WORKDIR" && timeout 240 env "$@" "$CLAUDE_BIN" -p \
      --model haiku \
      --permission-mode bypassPermissions \
      --max-turns 4 \
      --output-format stream-json \
      --verbose \
      --settings "$SETTINGS_FILE" \
      --disallowedTools "$HEADLESS_DENY" \
      -- "$prompt" </dev/null >"$out" 2>&1 )
}

# Session 1: the guard. With the variable set, run_in_background leaves the schema and
# the guard can never be reached, so the variable is unset here.
run_session "$OUT1" \
  "Run the Bash tool with command \"sleep 1\" and run_in_background set to true. Then reply with exactly: DONE" \
  -u CLAUDE_CODE_DISABLE_BACKGROUND_TASKS
# Session 2: a command that overruns its timeout must be killed, not moved to the background.
run_session "$OUT2" \
  "Call the Bash tool exactly once, with command 'sleep 12; echo done' and no timeout parameter. Then reply with exactly: DONE" \
  CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 BASH_DEFAULT_TIMEOUT_MS=4000 BASH_MAX_TIMEOUT_MS=4000

python3 - "$OUT1" "$OUT2" "$HEADLESS_DENY" <<'PY'
import json, sys

out1, out2, deny_csv = sys.argv[1], sys.argv[2], sys.argv[3]
deny = [d for d in deny_csv.split(',') if d]


def parse(path):
    r = {'tools': None, 'denial': False, 'ok': False, 'cost': 0.0,
         'killed': False, 'moved': False}
    for line in open(path, encoding='utf-8', errors='replace'):
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get('type') == 'system' and ev.get('subtype') == 'init':
            r['tools'] = ev.get('tools') or []
        if ev.get('type') == 'user':
            for block in (ev.get('message') or {}).get('content') or []:
                if not isinstance(block, dict) or block.get('type') != 'tool_result':
                    continue
                c = block.get('content')
                text = c if isinstance(c, str) else str(c or '')
                if block.get('is_error') and 'headless stage:' in text:
                    r['denial'] = True
                if 'Command timed out' in text:
                    r['killed'] = True
                if 'moved to the background' in text:
                    r['moved'] = True
        if ev.get('type') == 'result':
            r['ok'] = not ev.get('is_error', True)
            r['cost'] = ev.get('total_cost_usd') or 0.0
    return r


a, b = parse(out1), parse(out2)
tools = a['tools']
present = [t for t in deny if tools is not None and t in tools]
if tools is None:
    print("tools: no init event seen")
elif present:
    print(f"tools: present: {' '.join(present)}")
else:
    print(f"tools: {' '.join(deny)} absent")

print(f"denial: {'seen' if a['denial'] else 'not seen'}")
overrun = 'killed' if b['killed'] else 'moved to the background' if b['moved'] else 'not seen'
print(f"overrun: {overrun}")
print(f"cost: {round(a['cost'] + b['cost'], 4)}")

ok = tools is not None and not present and a['ok'] and b['ok'] and overrun == 'killed'
sys.exit(0 if ok else 1)
PY
