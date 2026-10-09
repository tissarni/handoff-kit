# AGENTS.md — the handoff kit

This directory is the handoff kit: `handoff-launch.sh`, `handoff-orchestrate.sh` and
`brief-check.sh`, their hooks, guard, repo-side skills, watchdog units, the launchd template, `install.sh` and
tests. It runs agent sessions from written briefs and plans. It works with a vault: the
notes repo that holds those briefs and plans, named by `~/.config/handoff/config.env`.
"Vault" is the kit's own word for that repo, and `README.md` says what the kit needs from it.

## Checks

- `bash tests/run.sh 2>&1 | tail -n 40` runs every case in a sandbox (its own `HOME` and
  `PATH`, fake `claude`, `gh`, `glab`, `curl`, `systemctl` and `launchctl`). It takes about four minutes
  and ends `N passed, 0 failed`. `bash tests/run.sh <case>…` runs some of them.
- `bash -n` on every script you touch.
- A change of behaviour comes with a case that fails without it. Show that it does: copy
  the old scripts into a directory and run the case with `HANDOFF_SCRIPTS_DIR` set to it.

## Never

- Never run `tests/probe-headless-guard.sh`: it starts real, paid agent sessions.
- Never run `install.sh`, a `systemctl --user` command that changes anything, or a
  `launchctl` command, against your real `HOME`. The cases run both inside the sandbox.
- Never read `~/.config/handoff/notify.env`: it holds a live bot token. Never source it or
  `config.env`; the scripts read them one key at a time.
- Never read `~/.hermes/.env` or a profile's `.env` or `auth.json`: they hold live keys.

## Rules, and why

- **The scripts stay mode 100755.** `install.sh` links them into `~/.local/bin`, and the
  kernel runs a link's target, so a target without the bit fails with `Permission denied`.
- **`systemd/` holds the only definition of the watchdog units, and `install.sh` is their
  only writer.** Two writers drift apart: one that writes a unit only when it is missing
  never updates it. Keep the unit names and the instance string: the timers already
  enabled on a host are named by them.
- **`launchd/` holds the only definition of the watchdog agent.** launchd has no template
  units, so the orchestrator fills the template in per plan when it arms one; nothing else
  writes a plist. Keep the label recipe (`handoff-watchdog.` and the checksum of the plan's
  real path): the agents already loaded on a host are named by it.
- **Every case runs with the fake `launchctl` and `systemctl` first on `PATH`.** On macOS
  the sandbox `PATH` reaches the real `/bin/launchctl`, and a case that reached it would
  load an agent into the developer's own session.
- **No path outside this directory**, except the vault that `config.env` names. The kit
  must work from a plain copy of this directory.
- **No names of people, hosts, clients or other projects, no decision-record numbers and no
  note paths**, in code, comments or docs. A reader of the kit has none of them. A comment
  states the rule and its reason in its own words.
- **The repository is public, so the names rule covers what is written on GitHub too.** PR
  titles and descriptions, review and issue comments, and commit messages follow the names
  rule above. No hook reads a text typed on GitHub, and an edited text keeps its earlier
  version in its edit history.
- **Call `/usr/bin/grep`, never bare `grep`, and write POSIX patterns in grep, sed and
  awk** (a class such as `[:space:]` in a bracket expression, never `\s`, `\S` or `\w`). On
  some hosts `grep` resolves to another tool or dialect, and a pattern that works in one
  fails in the other: macOS's `/usr/bin/grep` is BSD grep whatever `PATH` holds, and mawk
  reads `\s` as `s`. The scripts and hooks have no bare `grep` left; some older test lines
  still do.
- **The five entry points carry the same preamble directly above their first `set` line.**
  It puts Homebrew's GNU tools first on `PATH` and runs the script under Homebrew's bash on
  macOS. A new entry point copies it, and `tests/cases/portable-preamble.sh` fails when
  copies differ.
- **The hooks stay bash 3.2 and POSIX, with no preamble.** git runs them under whatever
  `bash` its `PATH` holds, on every commit and push of a stage: no `mapfile`, case
  conversion or `sed -i`, and only `/usr/bin/grep`, since macOS's `/usr/bin/grep` and `sed`
  are BSD tools.
- **Compare a count from `wc` as a number (`-eq`, `-gt`), never as a string (`=`).** BSD `wc`
  pads its number with spaces, so on macOS `[ "$(wc -l <file)" = 2 ]` is false where `-eq 2`
  holds. The hooks, `tests/run.sh` and the cases that do not source `tests/lib.sh` run without
  a preamble of their own, so on macOS they may get BSD `wc`.
- **A text change to `skills/` goes in a change of its own.** `install.sh` copies those
  skills to user level, so every repo session on the host runs the new text right after
  the next install.
- **The review SOUL carries the review skill's output block byte for byte.** A change to
  the block changes `skills/handoff-review/SKILL.md` and `hermes/profiles/review/SOUL.md`
  in one commit (an exception to the rule above: the SOUL's copy counts as part of that
  skills change), and `tests/cases/install-hermes-profiles.sh` compares them. A hermes
  review gets the bare brief, so that SOUL is the only place the block's format reaches
  the session, and the next stage parses the block.
- **Keep every Claude stage isolated from the operator's connectors and user-scope plugins.**
  Unattended stages run with no one approving a write, so a connected service or a plugin
  the operator set up for their own work must not be reachable from them, and their
  descriptions cost tokens on every turn. The launcher turns them off for each stage.
