# AGENTS.md — the handoff kit

This directory is the handoff kit: `handoff-launch.sh`, `handoff-orchestrate.sh` and
`brief-check.sh`, their hooks, guard, repo-side skills, watchdog units, `install.sh` and
tests. It runs agent sessions from written briefs and plans. It works with a vault: the
notes repo that holds those briefs and plans, named by `~/.config/handoff/config.env`.
"Vault" is the kit's own word for that repo, and `README.md` says what the kit needs from it.

## Checks

- `bash tests/run.sh 2>&1 | tail -n 40` runs every case in a sandbox (its own `HOME` and
  `PATH`, fake `claude`, `gh`, `glab`, `curl` and `systemctl`). It takes about four minutes
  and ends `N passed, 0 failed`. `bash tests/run.sh <case>…` runs some of them.
- `bash -n` on every script you touch.
- A change of behaviour comes with a case that fails without it. Show that it does: copy
  the old scripts into a directory and run the case with `HANDOFF_SCRIPTS_DIR` set to it.

## Never

- Never run `tests/probe-headless-guard.sh`: it starts real, paid agent sessions.
- Never run `install.sh`, or a `systemctl --user` command that changes anything, against
  your real `HOME`. The cases run both inside the sandbox.
- Never read `~/.config/handoff/notify.env`: it holds a live bot token. Never source it or
  `config.env`; the scripts read them one key at a time.

## Rules, and why

- **The scripts stay mode 100755.** `install.sh` links them into `~/.local/bin`, and the
  kernel runs a link's target, so a target without the bit fails with `Permission denied`.
- **`systemd/` holds the only definition of the watchdog units, and `install.sh` is their
  only writer.** Two writers drift apart: one that writes a unit only when it is missing
  never updates it. Keep the unit names and the instance string: the timers already
  enabled on a host are named by them.
- **No path outside this directory**, except the vault that `config.env` names. The kit
  must work from a plain copy of this directory.
- **No names of people, hosts, clients or other projects, no decision-record numbers and no
  note paths**, in code, comments or docs. A reader of the kit has none of them. A comment
  states the rule and its reason in its own words.
- **Call `/usr/bin/grep`, never bare `grep`.** On some hosts `grep` resolves to another tool
  or dialect, and a pattern that works in one fails in the other. Some older lines still use
  the bare name.
- **A text change to `skills/` goes in a change of its own.** `install.sh` copies those
  skills to user level, so every repo session on the host runs the new text right after
  the next install.
- **Keep every Claude stage isolated from the operator's connectors and user-scope plugins.**
  Unattended stages run with no one approving a write, so a connected service or a plugin
  the operator set up for their own work must not be reachable from them, and their
  descriptions cost tokens on every turn. The launcher turns them off for each stage.
