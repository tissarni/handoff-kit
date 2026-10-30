# The handoff kit

The kit runs agent sessions from written briefs: a review, a revise, the run itself, a close
and a debrief, each in a fresh session. A driver runs a plan's phase of briefs one after
another, unattended, and a watchdog timer keeps an eye on it.

It works with a **vault**: the notes repo that holds your briefs and plans. "Vault" is the
kit's own word for that repo.

## What it needs

- Linux, or macOS with Homebrew and `brew install bash coreutils findutils gnu-sed grep`:
  each script puts the GNU tools first on its own `PATH` and runs under Homebrew's bash.
- bash 4 or newer, git and python3 (standard library only).
- GNU coreutils, findutils, sed and grep (`readlink -f`, `timeout`, `mktemp`, `date -d`,
  `stat -c`), awk and `ps`; util-linux's `flock` and `setsid` where present, python3
  standing in otherwise.
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
On an interactive first install, the installer asks whether to enable repository
auto-merge by default; unattended first installs choose false. `--auto-merge true|false`
sets it explicitly. Reruns preserve the saved choice unless that flag is supplied.

It writes, all under `$HOME`:

- `~/.config/handoff/config.env`: `VAULT`, `HANDOFF_DEFAULTS`, `HANDOFF_PROJECTS` and
  `HANDOFF_AUTO_MERGE`; other
  lines are kept;
- `~/.local/bin/handoff-launch`, `handoff-orchestrate`, `brief-check` and `handoff-policy`: symlinks into
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

## Repository merge policy

Automatic merge is supported for GitHub only. A feature is one plan, one feature branch and
one pull request. Automatic merges target `dev` only; `finalize` refuses any other base, and
an auto-policy plan based on another branch ends in `awaiting-merge` for a human merge.
Nothing automatically merges `dev` into `main`. GitLab and repositories with manual or
unconfigured policy keep their previous completion behavior.

### Configuration and operator commands

The shipped installation default is false. On an interactive first install, `install.sh`
asks whether to enable it; unattended first installs choose false. Pass
`--auto-merge true|false` to set it explicitly. A rerun keeps the saved choice unless that
flag is supplied. The setting is only a proposed value for project initialization: changing
it does not change any repository's saved choice, and an unconfigured repository is manual.
A project initializer can call `handoff-policy default-get`, ask the user to confirm the
proposed value, then persist that choice with
`handoff-policy policy-init --repo <git-repository> --choice true|false`.

The `handoff-policy` interface (the installed name for `handoff-merge.py`) is an operator
interface. Paths passed to `--repo` are local Git repositories; forge commands take
`owner/name` where shown. Commands and their normal stdout are:

- `handoff-policy default-get` — prints `true` or `false`.
- `handoff-policy default-set true|false` — saves and prints the installation default.
- `handoff-policy policy-get --repo <path>` — prints `auto` or `manual`; a repository with
  no saved choice is `manual`.
- `handoff-policy policy-set --repo <path> true|false` — saves and prints `auto` or `manual`.
- `handoff-policy policy-init --repo <path> --choice true|false` — persists the project
  initializer's confirmed choice and prints `auto` or `manual`.
- `handoff-policy effective --repo <path> --task <id> --revision <revision>
  [--risk <category>]` — prints `auto` or `manual — <reason>`. `--risk` is accepted for
  compatibility/display; the recorded assessment determines the decision.
- `handoff-policy assess --repo <path> --task <id> --revision <revision> --risk
  <category> --reason <text>` — records the operator's risk assessment and prints
  `assessed`.
- `handoff-policy override --repo <path> --task <id> --revision <revision> --risk
  <category> --approve` — records a task/revision/risk-scoped approval and prints
  `approved`; it cannot elevate a manual repository.
- `handoff-policy hold --repo <path> [--task <id>]` and
  `handoff-policy release --repo <path> [--task <id>]` — set or clear a repository-wide
  hold, or a task hold, and print `held` or `released`.
- `handoff-policy merge-state --repository <owner/name> --branch <branch> --base <branch>`
  — read-only matching-PR state (`merged`, `open` or `absent`, with identifiers).
- `handoff-policy dev-bootstrap --repository <owner/name>` — creates a missing GitHub `dev`
  from verified `main`, preserving an existing `dev`.
- `handoff-policy finalize --repository <owner/name> --plan <plan> --branch <branch>
  [--base dev]` — checks readiness and merges one reviewed feature head. Exit 0 means
  verified completion; exit 1 means refusal; exit 3 means an ambiguous merge outcome that
  needs human verification; exit 4 means the merge was verified but branch cleanup failed.

### Risk and final review

Assess risk before launching a feature. Categories requiring manual handling by default are
`breaking-api`, `destructive-migration`, `auth-permissions-secrets`,
`deployment-infrastructure`, `merge-policy`, and `uncertain`; unknown or unassessed risk is
manual. An operator can record an explicit exception with `override` on an opted-in
repository, but it applies only to that task, revision and assessed risk. Brief or PR prose
cannot create an assessment or approval. Turning repository policy off prevents an override
from enabling it. A hold can block all tasks or one task. The final reviewer can identify
late risk: a non-ordinary review risk that does not match the assessment is refused and
returns the task to manual handling.

A final code review runs only at a whole-feature boundary: use `handoff-launch loop
<brief> --feature-complete` for a standalone feature, or it runs after the last phase of an
orchestrated plan under auto policy on GitHub. It reviews the exact base-to-head changes
against the briefs' acceptance criteria, design and repository `AGENTS.md` checks; it
verifies relevant checks and does not treat PR prose, prior reports or CI alone as proof.
The read-only reviewer never merges. It writes `<feature>.final-review.json` evidence,
bound to the feature, repository, exact head and base, verdict, blockers and risk. Reuse
requires matching feature/repository/head/base and a valid risk; changed inputs require a
new review. The deterministic `finalize` helper consumes that evidence and performs the
merge checks.

The Hermes `final-review` profile is created by `install.sh --hermes-profiles` without a
`SOUL.md`; its config inherits the model block. If the profile is absent, the launcher fails
closed. Claude final review uses the review stage settings and tool denials. Devin final
review uses the review stage's edit-denying config. Local policies are convenience files,
not a sandbox against other processes running as the same user; there is no cryptographic
isolation.

### Pull requests, recovery and CI

The PR body must have non-empty `## Feature`, `## Acceptance`, `## Final review`, `## CI` and
`## Limitations` sections. The `Final review` section must contain the reviewed head SHA.
`finalize` enforces those sections and the SHA, but PR prose never grants authority.

Feature PRs stay drafts during implementation. Only after every merge check has passed
(policy, evidence, identity, PR body and required CI on the exact head) does `finalize`
mark a draft PR ready for review, its single write before the merge. It then re-reads the
PR and refuses if anything changed; a PR refused at that point stays ready and is not
merged. Every refusal before that point makes no write.

A successful plan reaches `done`. If a non-`dev` base or an operator refusal needs human
handling, the plan becomes `awaiting-merge` and keeps its checkout; `resume` verifies a
matching human merge against the recorded reviewed head before completing. A final-review
FAIL makes the plan `broken`. An ambiguous merge result (exit 3) is not retried
automatically: verify the PR and target branch first, then resume only when its state is
known. Exit 4 means merge succeeded but branch cleanup failed; the plan completes with a
warning and the leftover branch can be cleaned up separately. To retry a refused finalize
by hand after correcting the cause, use the `finalize` command above; it requires the plan's
valid final-review evidence and current readiness checks. Use `hold`/`release` to pause or
resume eligibility at repository or task scope.

This kit's CI workflow runs the test suite on every push and pull request; it has no
deployment job. Merging into `dev` may trigger workflows configured by the repository—check
those triggers before enabling auto-merge. The kit does not change repository protections or
workflows. Finalize requires `GH_TOKEN` and `GH_HOST` in the orchestrator environment, with
the GitHub host set to `github.com`. The companion project-initializer integration is
outside this repository.

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
  `--model`, and `--publication-owner runner|supervisor` (run, loop and resume; defaults
  to `runner`). `runner` preserves the existing forge-specific push and draft-PR workflow.
  `supervisor` keeps the run local-only; the run and orchestrator do not publish a branch
  or create/update a PR, and the trusted supervisor owns later publication. Brief or Issue
  prose cannot grant publication credentials or merge authority.
- **Loop exits:** 0 closed; 10 gate held, with `GATE: …`; 20 the run failed the check, with
  `RUN: …`; 30 launcher error.
- **Environment:** `HANDOFF_ALLOW_FREE_RUN=1`, `HANDOFF_DONE_WHEN_TIMEOUT=<s>` (600 by
  default), `HANDOFF_BASE=<branch>` and `HANDOFF_KIT`.

### `handoff-orchestrate start|tick|status|stop|resume <plan> [--backend <b>] [--model <m>] [--publication-owner runner|supervisor]`

- `start` runs the pre-flight, records the repo baseline, takes the lock and launches a
  detached driver. `tick` is the watchdog pass, `status` prints the first line of
  `<plan>.status.md`, `stop` kills the driver and marks the plan paused, `resume` continues
  from the first brief not closed. The header of the script lists the files kept beside a
  plan.
- `--publication-owner` is accepted on `start` and `resume`, defaults to `runner`, and is
  forwarded to each run. In `supervisor` mode the driver also leaves branch and PR
  publication to the supervisor. Recovery commands carry the selected owner; `tick` and
  `stop` recover it from the plan's trusted START/RESUME event, not brief or Issue prose.
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
tick retires it too when it finds the plan finished.

Without either, run `/loop 30m handoff-orchestrate tick <plan>` in an agent session instead.

## Tests

- `bash tests/run.sh [case…]` runs every case, or the cases named.
- Each case has its own sandbox, with its own `HOME` and `PATH` and fake `claude`, `gh`,
  `glab`, `curl`, `systemctl` and `launchctl`.
- `HANDOFF_SCRIPTS_DIR=<dir>` runs the cases against the scripts in `<dir>`: the launcher,
  the orchestrator, `brief-check.sh`, `handoff-usage.py` and `install.sh`.
- CI runs the suite on every push and pull request, on `ubuntu-latest` and on
  `macos-latest`; a failure in either job fails the run. The macOS job installs bash and the
  GNU tools first.
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
