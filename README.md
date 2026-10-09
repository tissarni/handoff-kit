# The handoff kit

The kit runs agent sessions from written briefs: a review, a revise, the run itself, a close
and a debrief, each in a fresh session. A driver runs a plan's phase of briefs one after
another, unattended, and a watchdog timer keeps an eye on it.

It works with a **vault**: the notes repo that holds your briefs and plans. "Vault" is the
kit's own word for that repo.

## What it needs

- Linux, with bash, git and python3 (standard library only).
- GNU coreutils (`readlink -f`, `timeout`, `mktemp`, `date -d`, `stat -c`), util-linux
  (`flock`, `setsid`), procps (`pgrep`), awk and sed.
- An agent CLI: `claude` by default, or `hermes` or `devin`.
- `gh` for a GitHub origin, or `glab` for a GitLab one.
- Optionally, for the watchdog, a systemd user session (`systemctl`, `systemd-escape`) on
  Linux, or a GUI login session (`launchctl`) on macOS; and `curl` with `notify.env` for
  messages.

## The vault it works with

- **A defaults file**, named by `HANDOFF_DEFAULTS` (a path relative to the vault).
  - For a brief with no `vault-session:` or `close-session:` block, the launcher reads
    `defaults:` `vault:` or `close:`, with `per-main: <main>: <key>:` laid over.
  - `defaults:` `review:` and `run:` hold what your brief-writing tool stamps into a brief's
    own blocks.
  - The orchestrator reads only `orchestration:` `disk-min-free-gb:`.
  - `tests/fixtures/handoff-defaults.yml` is a full example.
- **A projects directory**, named by `HANDOFF_PROJECTS`.
  - A brief's main is the path segment after the one equal to `HANDOFF_PROJECTS`; its sub is
    the directory two levels above the brief file, so a brief sits at
    `<projects>/<main>/.../<sub>/specs/<brief>.md`.
  - `HANDOFF_PROJECTS` must be a single directory name. A multi-segment value such as `a/b`
    never matches, so a brief's main comes out empty and the per-main defaults are skipped.
- **A brief's frontmatter:**
  - `handoff:`, the brief's state: draft, reviewed, ready, running, reported or closed;
  - `revision:` and `repo:`, both required;
  - `branch:`;
  - the stage blocks `review-session:` and `run-session:` (model, effort, permission-mode,
    disallowed-tools);
  - its §4 "Done when" items, which `brief-check --done-when` lists and the close stage
    re-runs.
- **A plan's frontmatter:**
  - `project`;
  - `orchestration`: planned, running, paused, broken, phase-done or done;
  - `backend`, `model`, `phase`, `branch`, `base`, `budgets`, `notify` and `setup`;
  - `phases:` entries, each with `name`, `briefs: [...]` (a flow list; a relative brief
    resolves against the plan's directory), `status`, an optional `branch` and
    `why-cut-here`.
- **Skills the stages call.** `/handoff-review` and `/handoff-close` ship in `skills/`.
  `/handoff-revise` and `/debrief` run in the vault stages, so the vault provides them.
  `/capture-lesson` (the lesson stage) must come from elsewhere.

## Install

Clone the kit, then run:

```
bash install.sh --vault <dir> --defaults <path relative to the vault> --projects <dir>
```

for example `--vault ~/notes --defaults templates/handoff-defaults.yml --projects projects`.
Add `--hermes-profiles` to also seed the hermes stage profiles (see `## Hermes profiles`).

It writes, all under `$HOME`:

- `~/.config/handoff/config.env`: `VAULT`, `HANDOFF_DEFAULTS` and `HANDOFF_PROJECTS`; other
  lines are kept;
- `~/.local/bin/handoff-launch`, `handoff-orchestrate` and `brief-check`: symlinks into
  this kit;
- `~/.claude/skills/<name>/`: each skill under `skills/`, replaced whole;
- `~/.config/systemd/user/handoff-watchdog@.service` and `.timer`, copied from `systemd/`;
- `~/.hermes/profiles/review`, `run` and `close`: only with `--hermes-profiles`, each one
  only when it does not exist yet.

A flag left out keeps the value `config.env` already has. The environment's `VAULT`,
`HANDOFF_DEFAULTS` and `HANDOFF_PROJECTS` are ignored by the installer. Run it again after
every pull of the kit. `~/.local/bin` must be on your `PATH`. Nothing is enabled: `start`
and `resume` arm each plan's timer. It exits 1 on a refusal and 2 on a bad flag.

## Config

- `~/.config/handoff/config.env` holds `VAULT`, `HANDOFF_DEFAULTS` and `HANDOFF_PROJECTS`.
  The environment wins, key by key. A missing key stops the script, naming the key.
- Neither config file is ever sourced. Each line is one `KEY=value`; the last line for a key
  wins and quotes are stripped.
- `~/.config/handoff/notify.env` holds `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`, used by
  a plan with `notify: telegram`.

## Hermes profiles

The launcher can run a stage on hermes (`--backend hermes`). Hermes keeps one profile per
role, a directory under `~/.hermes/profiles/` with a `SOUL.md` (standing instructions) and
a `config.yaml` (which names the model). The stage-to-profile map:

- `run` and `resume` use the `run` profile, `review` uses `review`, `close` uses `close`;
- every other stage (revise, debrief, lesson) uses `default`, your own hermes setup, which
  must provide the skills those stages call.

A stage's model is the profile's `model.default`, unless `--model` is passed. A run or
resume on a model ending `:free` is refused, unless `HANDOFF_ALLOW_FREE_RUN=1`.

The kit ships a generic `SOUL.md` for each of the three profiles, under
`hermes/profiles/`. The review one holds the whole review: a hermes review gets the bare
brief, with no wrapper and no skill, so the procedure and the output block that the next
stage parses reach the session only through that SOUL. The run one defers to the report
format in the run prompt. `bash install.sh --hermes-profiles` creates each missing profile
from them, with the `model:` block of `~/.hermes/config.yaml` copied into its `config.yaml`
(mode 600). A profile that already exists, whatever it holds, is kept and never written to.
Without the flag, nothing under `~/.hermes` is read or written.

The flag never writes credentials: give each new profile the `.env` or `auth.json` its
provider needs. Hermes has no read-only mode, so the review and close profiles are
read-only by their SOUL alone.

## Commands

### `handoff-launch <mode> <brief>`

A relative brief is relative to the vault.

Every Claude stage starts with `ENABLE_CLAUDEAI_MCP_SERVERS=false` and with user-scope plugins off unless the stage's own project enables them, so an unattended stage cannot reach the operator's connected services and does not pay their tool and skill descriptions on every turn.

- **Modes:**
  - `review`: read-only and headless; writes `<brief>.review.md`. A brief-check FAIL stops it
    with exit 12 before any session starts;
  - `run`: the implementation, interactive; with `--delegate`, headless and unattended, the
    report written to `<brief>.report.md`;
  - `revise` and `debrief`: each a headless vault session;
  - `close`: a read-only repo session that audits the report into `<brief>.close.md`;
  - `loop`: chains the stages from the brief's current `handoff:` state;
  - `lesson <brief> --note <file>` and `resume <brief> --session <id> --note <file>`.
- **Flags:** `--gate auto|human` (loop), `--dry-run`, `--delegate`, `--stream` (review),
  `--prove N[,N…]` (close; the loop passes it), `--backend claude|hermes|devin` and
  `--model`.
- **Loop exits:** 0 closed; 10 gate held, with `GATE: …`; 20 the run failed the check, with
  `RUN: …`; 30 launcher error.
- **Environment:** `HANDOFF_ALLOW_FREE_RUN=1`, `HANDOFF_DONE_WHEN_TIMEOUT=<s>` (600 by
  default), `HANDOFF_BASE=<branch>` and `HANDOFF_KIT`.

### `handoff-orchestrate start|tick|status|stop|resume <plan> [--backend <b>] [--model <m>]`

- `start` runs the pre-flight, records the repo baseline, takes the lock and launches a
  detached driver. `tick` is the watchdog pass, `status` prints the first line of
  `<plan>.status.md`, `stop` kills the driver and marks the plan paused, `resume` continues
  from the first brief not closed. The header of the script lists the files kept beside a
  plan.
- **Exits:** 0 ok, or broke and said so; 1 usage or state error; 2 a pre-flight check failed
  and nothing launched.
- **Environment:** `HANDOFF_LIMIT_WAIT` (1800 s by default), `HANDOFF_ORCH_ALLOW_CONCURRENT=1`
  and `HANDOFF_KIT`.
- A plan whose checkout is the one the kit runs from is refused.

### `brief-check`

- `brief-check <brief.md> [--at <ISO time>] [--repo <dir>] [--branch <name>]`
- `brief-check --facts <repo> <branch>`
- `brief-check --done-when <brief.md>`
- `brief-check --backtest <labels.tsv> [--vault <dir>] [--fail <checks>]`
- `brief-check --help`

Exit 1 when a FAIL line prints, 2 on a usage error, 0 otherwise.

The sweep fails a brief's lines that point at something the run cannot follow: wiki links,
note paths, decision numbers, the word "vault", pointers to other notes, and brief and plan
file names. Its rule for "vault":

- a brief whose repo has the kit's three scripts at its top level may say "vault";
- a brief whose repo is a vault may also name note paths;
- brief-check knows a vault by a fixed top-level directory name, hard-coded in `run_sweep`.

`--backtest` without `--vault` takes the git top level of the kit's own directory. That is
the vault only while the kit sits inside it.

## Watchdog

On Linux the timer fires 5 minutes after boot, then every 30 minutes, and runs
`handoff-orchestrate tick <plan>`. `start` and `resume` arm a plan's timer, and the driver
disables it after the last phase.

On macOS, with no systemd and a GUI login session, `start` and `resume` fill
`launchd/handoff-watchdog.plist` in for the plan, write it to
`~/Library/LaunchAgents/<label>.plist` and load it with `launchctl bootstrap`. The label is
`handoff-watchdog.<n>`, `<n>` being the checksum (`cksum`) of the plan's real path; the log
is `~/Library/Logs/<label>.log`. The driver retires the agent after the last phase, and a
tick retires it too when it finds the plan finished. The agent is inert until the
orchestrator itself runs on macOS.

Without either, run `/loop 30m handoff-orchestrate tick <plan>` in an agent session instead.

## Tests

- `bash tests/run.sh [case…]` runs every case, or the cases named.
- Each case has its own sandbox, with its own `HOME` and `PATH` and fake `claude`, `gh`,
  `glab`, `curl`, `systemctl` and `launchctl`.
- `HANDOFF_SCRIPTS_DIR=<dir>` runs the cases against the scripts in `<dir>`: the launcher,
  the orchestrator, `brief-check.sh`, `handoff-usage.py` and `install.sh`.
- CI runs the suite on every push and pull request, on `ubuntu-latest` (required) and on
  `macos-latest` (advisory: that job may fail without failing the run).
- Never run `tests/probe-headless-guard.sh`: it starts real, paid sessions.

## Layout

- `handoff-launch.sh`: the launcher, one session per stage.
- `handoff-orchestrate.sh`: the driver and the watchdog pass.
- `brief-check.sh`: checks a brief's claims against its repo.
- `handoff-usage.py`: prices a Claude Code session transcript from its usage rows.
- `install.sh`: installs the kit for the current user.
- `launchd/`: the macOS watchdog agent's plist template.
- `hooks/`: the git hooks the launcher sets for a stage session.
- `guards/`: a guard that refuses background waits in headless stages.
- `skills/`: the repo-side skills `handoff-review` and `handoff-close`.
- `hermes/`: the generic hermes profile seeds, `profiles/<name>/SOUL.md`.
- `systemd/`: the watchdog service and timer units.
- `tests/`: the suite, its fakes and fixtures.
- `.github/workflows/tests.yml`: the CI workflow that runs the suite.
- `AGENTS.md`, `CLAUDE.md`: rules for an agent working on the kit.
- `.gitattributes`, `.gitignore`: LF line endings and ignored caches.
