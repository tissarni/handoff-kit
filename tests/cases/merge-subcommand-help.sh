#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

python3 - "$SANDBOX/kit/handoff-merge.py" <<'PY' || fail "merge subcommand help or invalid finalize assertions failed"
import re, subprocess, sys
script = sys.argv[1]
top = subprocess.run([sys.executable, script, "--help"], text=True, capture_output=True)
assert top.returncode == 0, (top.returncode, top.stdout, top.stderr)
match = re.search(r"(?m)^\s+\{([^}]+)\}\s*$", top.stdout)
assert match, top.stdout
commands = match.group(1).split(",")
assert commands, commands
for command in commands:
    result = subprocess.run([sys.executable, script, command, "--help"], text=True, capture_output=True)
    assert result.returncode == 0, (command, result.returncode, result.stdout, result.stderr)
    assert "usage:" in result.stdout, (command, result.stdout)
for args in (["finalize"], ["finalize", "--invalid"]):
    result = subprocess.run([sys.executable, script, *args], text=True, capture_output=True)
    assert result.returncode == 1, (args, result.returncode, result.stdout, result.stderr)
    assert "handoff-merge: invalid finalize arguments" in result.stderr, (args, result.stderr)
print("help exits 0 for %d subcommands; invalid finalize arguments exit 1" % len(commands))
PY

echo ok
