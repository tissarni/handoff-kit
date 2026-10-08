#!/usr/bin/env python3
"""PreToolUse guard: refuse a Bash call that backgrounds itself.

Wired to Bash tool calls in a headless claude -p session (review, close, or any
DELEGATE stage). A backgrounded task there never delivers its notification — the
turn ends "waiting" and the session dies with no report.

Exit 0 = allow, silently. Exit 2 = block; stderr is returned to the model as the
reason. Any other exit is a non-blocking error and the call goes ahead, so this
fails open: it only blocks a well-formed run_in_background: true, never input it
cannot parse.
"""
import json
import sys


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        return
    try:
        data = json.loads(raw)
    except ValueError:
        return
    if not isinstance(data, dict):
        return
    if (data.get("tool_input") or {}).get("run_in_background") is True:
        sys.stderr.write(
            "headless stage: run it in the foreground with timeout <= 900000 — "
            "a background task never notifies a -p session, so the turn would "
            "end waiting for it\n"
        )
        sys.exit(2)


if __name__ == "__main__":
    main()
