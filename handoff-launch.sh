#!/usr/bin/env bash
# Launch a handoff session from a brief.
#
#   handoff-launch review <brief>        read-only review, headless. Writes the block to
#                                        <brief>.review.md and sets handoff: reviewed.
#                                        Headless read-only stages (review, close) run
#                                        bypassPermissions so they can execute the checks
#                                        they judge; writes are denied by tool, not prompt
#                                        It first runs brief-check.sh on the brief and
#                                        keeps the report in <brief>.check.md. A FAIL line
#                                        exits 12 before any session starts; a crash, a
#                                        timeout or a missing script only warns.
#   handoff-launch run    <brief>        the implementation run, interactive. Sets
#                                        handoff: running. With --delegate the report
#                                        is written to <brief>.report.md and the brief
#                                        moves to handoff: reported
#   handoff-launch revise <brief>        headless VAULT session: /handoff-revise reads
#                                        <brief>.review.md unattended, sets handoff: ready
#   handoff-launch debrief <brief>       headless VAULT session: /debrief reads
#                                        <brief>.report.md unattended, sets handoff: closed
#   handoff-launch close  <brief>        headless read-only REPO session: audits
#                                        <brief>.report.md into <brief>.close.md, handoff
#                                        unchanged. Before the session it re-runs every §4
#                                        command brief-check.sh --done-when can read, in
#                                        the repo, into <brief>.done-when.md; the prompt
#                                        carries those results beside the brief's §4
#   handoff-launch loop   <brief>        chain the stages above from the brief's current
#                                        handoff: state, one fresh session each, serially:
#                                          draft    -> review -> revise -> GATE
#                                          ready    -> run --delegate -> close -> debrief -> closed
#                                        A close FAIL classed fixable, every failing
#                                        finding on a §4 item, gets ONE fix-up before the
#                                        debrief (claude only): the run's own session is
#                                        resumed with just those findings, written to
#                                        <brief>.fixup.md, and close runs again. A second
#                                        FAIL breaks as before. The first attempt stays in
#                                        <brief>.report-1.md, .close-1.md, .done-when-1.md.
#                                        A failing §4 item the close marks `pre-existing?`
#                                        gets that second close too, with or without a
#                                        fix-up and on any backend: it first re-runs the
#                                        item on a clean checkout of origin/<base>
#                                        (--prove), and only the same exit code with
#                                        byte-identical output proves it. The proof is
#                                        <brief>.preexisting.md.
#                                        Every claude stage appends `<UTC time> <mode>
#                                        <session id>` to <brief>.sessions.log.
#                                        The gate is deliberate: a revised brief is read
#                                        before it is run. --gate human (default) stops
#                                        there; re-running loop is the approval.
#   ...            --gate auto|human     loop only. `auto` crosses the gate unattended when
#                                        the revise stage's own verdict allows it: the
#                                        latest "## Revise outcome" in <brief>.review.md
#                                        ends with the literal line `gate: clean` AND the
#                                        brief says handoff: ready (checked separately).
#                                        A missing or `held` token stops. After debrief it
#                                        also checks the run: NOT DONE none, close VERDICT
#                                        PASS, handoff: closed, outcome COMPLETE or PARTIAL
#                                        (BLOCKED fails). PARTIAL and audit: counts above 0
#                                        only print a WARNING: line — they are the run's
#                                        self-check; the close stage is the verdict, on §4
#                                        results the launcher re-ran. Nothing here is interpreted —
#                                        literal tokens only; absence stops.
#                                        Loop exit codes are a contract, read by
#                                        handoff-orchestrate.sh:
#                                          0   closed (and, with auto, the run passed)
#                                          10  gate held — one line `GATE: <reason>` on stdout
#                                              (a brief-check FAIL before the review is
#                                              `GATE: brief-check — <result> · first: <line>`)
#                                          20  run failed the check — `RUN: <reason>` on stdout
#                                          30  launcher error (a stage died, a state the
#                                              loop does not know, a missing file)
#   handoff-launch lesson <brief> --note <file>
#                                        route one pain point from a finished run into a
#                                        hook, a test case or an AGENTS.md trap. Headless.
#   handoff-launch resume <brief> --session <id> --note <file>
#                                        answer a paused run's question and let it carry
#                                        on with its context intact. The note is read from
#                                        a FILE, never an argument, for the same reason the
#                                        brief is. The loop's fix-up is a resume too. Its
#                                        ledger line counts only the turns after it starts.
#
#   HANDOFF_ALLOW_FREE_RUN=1             let a run/resume stage launch on a free-tier model
#                                        (name ending `:free`). Refused otherwise: a run
#                                        leaves commits and is never relaunched blind, and
#                                        free models died mid-run three times in the first
#                                        real plan (2026-09-21/22).
#   HANDOFF_DONE_WHEN_TIMEOUT=<s>        close only: the timeout of each re-run §4 command
#                                        (default 600, the run's own Bash timeout)
#   HANDOFF_BASE=<branch>                close --prove only: the proof checks out
#                                        origin/<branch>. The orchestrator passes the
#                                        plan's base; unset, it is dev when origin has it,
#                                        else main
#   ...            --dry-run             resolve and report, launch nothing
#   ...            --delegate            run mode: headless and unattended, instead of
#                                        interactive. Nobody can interject and an
#                                        unanswerable permission prompt is auto-denied
#   ...            --stream              review only: emit JSONL events as they happen,
#                                        so a backgrounded run shows live progress
#                                        instead of nothing until it finishes
#   ...            --prove N[,N…]        close only, passed by the loop: before the session,
#                                        re-run those §4 items on a clean checkout of the
#                                        base and carry the proof in the prompt
#   ...            --backend claude|hermes|devin
#                                        which agent runs the session. Default: hermes
#                                        when HERMES_BACKEND=1 or claude is absent,
#                                        else claude. Loop forwards it to every stage.
#                                        devin = the Devin CLI (a local coding agent, the
#                                        same shape as claude: cwd is the repo, the prompt
#                                        arrives from a file, the block is captured from
#                                        stdout). Stage config is TRANSLATED from the
#                                        brief's Claude-vocabulary <mode>-session block —
#                                        see "devin stage config" below. Explicit only:
#                                        it is never auto-detected.
#   ...            --model <name>        overrides the model. Claude: replaces the brief's
#                                        <mode>-session model. Hermes: passed as -m, on
#                                        top of the profile (whose own model is the
#                                        default). Devin: passed verbatim, no effort
#                                        suffix, so it must name a model the account can
#                                        see (`devin models list`). Loop forwards it to
#                                        every stage.
#
# Invoke it locally:
#   handoff-launch <mode> <brief>      (a relative brief is relative to the vault)
#   bash <kit>/handoff-launch.sh <mode> <brief> runs the same script.
#
# Roots. The kit is this script's directory (or HANDOFF_KIT); it holds brief-check.sh,
# handoff-usage.py, hooks/ and guards/. VAULT, HANDOFF_DEFAULTS (relative to VAULT) and
# HANDOFF_PROJECTS come from the environment, else from ~/.config/handoff/config.env, and
# the script stops when one is missing.
#
# Why a script and not a command line. `$(cat <brief>)` inside a quoted
# `bash -lc '...'` string does NOT survive: the brief's text reaches bash as
# script and is executed. That happened once — a formatter reformatted 82 files and
# `git add` staged them before it was caught. Inside a file, nothing has to survive
# anything. This is also why the brief is never passed as an argument to this script.
#
# Everything except the mode comes from the brief's own frontmatter, so a brief always
# launches the way it records, and there is one place to look when it does not.

set -euo pipefail

# A loop exits 30 on any launcher error so a caller reading exit codes can tell it from a
# held gate (10) or a failed run (20). Every other mode keeps 1.
DIE_RC=1
die() { printf 'handoff-launch.sh: %s\n' "$*" >&2; exit "$DIE_RC"; }

# Tools nobody watching a headless claude -p session can use safely: Monitor and
# ScheduleWakeup wait on a notification that session never receives, and CronCreate
# schedules work with nobody there to see it run. Merged into --disallowedTools on
# every review|close|DELEGATE claude -p call — see the "argv" section.
HEADLESS_DENY="Monitor,ScheduleWakeup,CronCreate"
# Background tasks off for every headless claude stage. The variable removes
# run_in_background from the Bash and Agent tools and makes a command that overruns its
# timeout get killed instead of moved to the background, where a -p session would wait
# on a notification that never comes. The 900000 max stays under the orchestrator's
# 20-min transcript-stall limit: a Bash call writes nothing until it returns.
HEADLESS_ENV=(CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 BASH_DEFAULT_TIMEOUT_MS=600000 BASH_MAX_TIMEOUT_MS=900000)
merge_csv() {   # $1 = existing list (may be empty), $2 = items to add, comma-joined
  python3 - "$1" "$2" <<'PY'
import sys
existing, add = sys.argv[1], sys.argv[2]
items = [i for i in existing.split(',') if i]
for a in add.split(','):
    if a and a not in items:
        items.append(a)
print(','.join(items))
PY
}

# One cleanup for every temp path a run makes, installed before the first one exists.
# A later `trap … EXIT` silently REPLACES an earlier one rather than adding to it, so
# every temp file this script can create is removed from here, each guarded by
# ${VAR:-} since most modes never set most of them.
CAPTURE=""; SETTINGS_FILE=""; PROOF_TMP=""
cleanup() {
  [ -n "$CAPTURE" ] && rm -f "$CAPTURE"
  [ -n "$SETTINGS_FILE" ] && rm -f "$SETTINGS_FILE"
  [ -n "${DV_TMP:-}" ] && rm -rf "$DV_TMP"
  if [ -n "$PROOF_TMP" ]; then   # the pre-existing proof's checkout of the base
    git -C "$BRIEF_REPO" worktree remove --force "$PROOF_TMP/base" >/dev/null 2>&1 || true
    rm -rf "$PROOF_TMP"
    git -C "$BRIEF_REPO" worktree prune >/dev/null 2>&1 || true
  fi
  true
}
trap cleanup EXIT

KIT="${HANDOFF_KIT:-$(cd "$(dirname "$(readlink -f "$0")")" && pwd)}"

# Find claude without depending on the caller's PATH. `bash <script>` is neither a login
# nor an interactive shell, so ~/.profile never runs and ~/.local/bin is absent — which
# is exactly how a delegated run died with "claude: command not found" (exit 127) while
# every earlier `bash -lc` invocation worked. Resolve it here so the script behaves
# the same however it is invoked.
# Launch one session at a time. Two started simultaneously on 2026-08-25 both died
# instantly with a usage-limit message, while the same two run serially both succeeded --
# so treat a limit message from a parallel launch as a burst condition to retry serially,
# not as a wall.

# Find claude without depending on the caller's PATH. `bash <script>` is neither a login
# nor an interactive shell, so ~/.profile never runs and ~/.local/bin is absent — which
# is exactly how a delegated run died with "claude: command not found" (exit 127) while
# every earlier `bash -lc` invocation worked. Resolve it here so the script behaves the
# same however it is invoked.
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
if [ -z "$CLAUDE_BIN" ]; then
  for c in "$HOME/.local/bin/claude" "$HOME/bin/claude" /usr/local/bin/claude /usr/bin/claude; do
    [ -x "$c" ] && { CLAUDE_BIN="$c"; break; }
  done
fi
# The Claude desktop app (Code tab) installs no `claude` on PATH but ships the full CLI
# under ~/.claude/remote/ccd-cli/<version>, one ELF per version. Newest wins. Found only
# here, on purpose: auto-detection above uses PATH, so a host with only the desktop app
# still defaults to hermes — `--backend claude` is how you ask for this one.
if [ -z "$CLAUDE_BIN" ]; then
  CLAUDE_BIN="$(ls -1 "$HOME"/.claude/remote/ccd-cli/* 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "$CLAUDE_BIN" ] && [ ! -x "$CLAUDE_BIN" ] && CLAUDE_BIN=""
fi

# Devin CLI — the third backend, and the same resolution problem as claude: `bash
# <script>` is neither a login nor an interactive shell, so ~/.profile never runs.
# Installed by `curl -fsSL https://cli.devin.ai/install.sh | bash` as a symlink
# ~/.local/bin/devin -> ~/.local/share/devin/cli/_versions/current/bin/devin, which is also
# where the updater keeps its versions, so both are checked.
DEVIN_BIN="${DEVIN_BIN:-$(command -v devin 2>/dev/null || true)}"
if [ -z "$DEVIN_BIN" ]; then
  for d in "$HOME/.local/bin/devin" "$HOME/bin/devin" /usr/local/bin/devin \
           "$HOME/.local/share/devin/cli/_versions/current/bin/devin"; do
    [ -x "$d" ] && { DEVIN_BIN="$d"; break; }
  done
fi

# ---------------------------------------------------------------- args
MODE="${1:-}"
BRIEF_ARG="${2:-}"
DRY=0
STREAM=0
DELEGATE=0
SESSION=""
SESSION_ID=""
NOTE_FILE=""
BACKEND_ARG=""
MODEL_ARG=""
GATE="human"     # loop only: human = stop at ready (today's behaviour), auto = read the token
GATE_ARG=""
PROVE=""         # close only: §4 items to re-run on the base first (the loop passes it)
PASS=()          # flags the loop forwards to every stage it spawns (--gate is NOT one: it is the loop's own)
[ "$MODE" = "loop" ] && DIE_RC=30
_next=""
for a in "${@:3}"; do
  case "$_next" in
    session) SESSION="$a"; _next=""; continue ;;
    note)    NOTE_FILE="$a"; _next=""; continue ;;
    backend) BACKEND_ARG="$a"; PASS+=(--backend "$a"); _next=""; continue ;;
    model)   MODEL_ARG="$a";   PASS+=(--model "$a");   _next=""; continue ;;
    gate)    GATE_ARG="$a"; _next=""; continue ;;
    prove)   PROVE="$a"; _next=""; continue ;;
  esac
  case "$a" in
    --dry-run)  DRY=1 ;;
    --stream)   STREAM=1 ;;
    --delegate) DELEGATE=1 ;;
    --session)  _next=session ;;
    --note)     _next=note ;;
    --backend)  _next=backend ;;
    --model)    _next=model ;;
    --gate)     _next=gate ;;
    --prove)    _next=prove ;;
    --backend=*) BACKEND_ARG="${a#--backend=}"; PASS+=(--backend "$BACKEND_ARG") ;;
    --model=*)   MODEL_ARG="${a#--model=}";     PASS+=(--model "$MODEL_ARG") ;;
    --gate=*)    GATE_ARG="${a#--gate=}" ;;
    --prove=*)   PROVE="${a#--prove=}" ;;
    *) die "unknown flag: $a" ;;
  esac
done
[ -z "$_next" ] || die "--$_next needs a value"
if [ -n "$GATE_ARG" ]; then
  [ "$MODE" = "loop" ] || die "--gate only applies to loop (got mode $MODE)"
  case "$GATE_ARG" in
    auto|human) GATE="$GATE_ARG" ;;
    *) die "--gate must be auto or human, got: $GATE_ARG" ;;
  esac
fi
if [ -n "$PROVE" ]; then
  [ "$MODE" = "close" ] || die "--prove only applies to close (got mode $MODE)"
  [[ "$PROVE" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "--prove takes §4 item numbers, e.g. 2,5 — got: $PROVE"
fi

# ---------------------------------------------------------------- backend
# Three backends: claude, hermes and devin, all local on this host. claude is the
# default. Resolution, first hit wins:
# --backend on the command line, then HERMES_BACKEND=1, then auto (hermes when claude
# is absent). The flag exists so a copy-pasted loop command SHOWS which agent it
# launches instead of depending on what is installed where it is run.
case "$BACKEND_ARG" in
  "")            if [ -n "${HERMES_BACKEND:-}" ] || ! command -v claude >/dev/null 2>&1; then BACKEND=hermes; else BACKEND=claude; fi ;;
  claude|hermes|devin) BACKEND="$BACKEND_ARG" ;;
  *)             die "--backend must be claude, hermes or devin, got: $BACKEND_ARG" ;;
esac
if [ "$BACKEND" = "devin" ]; then
  [ -n "$DEVIN_BIN" ] || die "devin not found. Checked PATH, ~/.local/bin, /usr/local/bin and ~/.local/share/devin/cli/_versions/current/bin. Install it (curl -fsSL https://cli.devin.ai/install.sh | bash) or set DEVIN_BIN."
  # Fail before anything costs anything: a headless stage on an unauthenticated CLI
  # returns prose nobody can parse, and the brief then keeps a state it never earned.
  if ! "$DEVIN_BIN" auth status 2>&1 | grep -qi 'logged in'; then
    die "devin is not authenticated. Run 'devin auth login' (on a headless/SSH box add --force-manual-token-flow)."
  fi
fi
if [ "$BACKEND" = "hermes" ]; then
  HERMES_BIN="${HERMES_BIN:-$(command -v hermes 2>/dev/null || true)}"
  if [ -z "$HERMES_BIN" ]; then
    for h in "$HOME/.local/bin/hermes" "$HOME/bin/hermes" /usr/local/bin/hermes /usr/bin/hermes; do
      [ -x "$h" ] && { HERMES_BIN="$h"; break; }
    done
  fi
  [ -n "$HERMES_BIN" ] || die "hermes not found. Checked PATH and the usual install locations. Set HERMES_BIN."
fi

case "$MODE" in
  review|run|close|loop) ;;
  revise|debrief) DELEGATE=1 ;;
  lesson)
    [ -n "$NOTE_FILE" ] || die "lesson needs --note <file>"
    [ -f "$NOTE_FILE" ] || die "note file not found: $NOTE_FILE"
    DELEGATE=1
    ;;
  resume)
    [ -n "$SESSION" ]   || die "resume needs --session <id>"
    [ -n "$NOTE_FILE" ] || die "resume needs --note <file>"
    [ -f "$NOTE_FILE" ] || die "note file not found: $NOTE_FILE"
    DELEGATE=1
    ;;
  *) die "usage: handoff-launch review|run|close|revise|debrief|loop|resume|lesson <brief> [...]" ;;
esac
[ -n "$BRIEF_ARG" ] || die "no brief given"

# Roots: the vault, its defaults file (relative to the vault) and its projects directory.
# Each comes from the environment, else from the per-user config file, which is read line
# by line like notify.env and never sourced. No fallback: a missing root stops here.
HANDOFF_CONFIG="$HOME/.config/handoff/config.env"
cfg_get() {   # $1 = key -> its value in $HANDOFF_CONFIG ('' when absent); the last line wins
  [ -f "$HANDOFF_CONFIG" ] && /usr/bin/grep -E "^$1=" "$HANDOFF_CONFIG" | tail -n 1 | cut -d= -f2- | tr -d "\"'" || true
}
VAULT="${VAULT:-$(cfg_get VAULT)}"
HANDOFF_DEFAULTS="${HANDOFF_DEFAULTS:-$(cfg_get HANDOFF_DEFAULTS)}"
HANDOFF_PROJECTS="${HANDOFF_PROJECTS:-$(cfg_get HANDOFF_PROJECTS)}"
for k in VAULT HANDOFF_DEFAULTS HANDOFF_PROJECTS; do
  [ -n "${!k}" ] || die "$k is not set: add a $k= line to $HANDOFF_CONFIG, or set $k in the environment"
done
DEFAULTS="$VAULT/$HANDOFF_DEFAULTS"

case "$BRIEF_ARG" in
  /*) BRIEF="$BRIEF_ARG" ;;
   *) BRIEF="$VAULT/$BRIEF_ARG" ;;
esac
[ -f "$BRIEF" ] || die "brief not found: $BRIEF"

# ---------------------------------------------------------------- frontmatter
# Flat keys plus one level of nesting is the whole schema; parsed without PyYAML so
# this has no dependency the toolkit does not already require.
eval_lines="$(python3 - "$BRIEF" "$MODE" "$DEFAULTS" "$HANDOFF_PROJECTS" <<'PY'
import os, sys, shlex
path, mode, dpath, projects = sys.argv[1:5]

def parse(lines):
    """Minimal YAML: scalars and nested maps by indentation. No lists, no multi-line."""
    root = {}
    stack = [(-1, root)]
    for raw in lines:
        if not raw.strip() or raw.lstrip().startswith('#'):
            continue
        ind = len(raw) - len(raw.lstrip())
        key, _, val = raw.strip().partition(':')
        key, val = key.strip(), val.strip().strip('"\'')
        while len(stack) > 1 and stack[-1][0] >= ind:
            stack.pop()
        parent = stack[-1][1]
        if val == '':
            child = {}
            parent[key] = child
            stack.append((ind, child))
        else:
            parent[key] = val
    return root

lines = open(path, encoding='utf-8').read().splitlines()
if not lines or lines[0].strip() != '---':
    sys.exit("brief has no frontmatter")
end = next((i for i, l in enumerate(lines[1:], 1) if l.strip() == '---'), None)
if end is None:
    sys.exit("brief frontmatter is unterminated")
fm = parse(lines[1:end])
scalar = lambda k: fm.get(k, '') if isinstance(fm.get(k, ''), str) else ''

if mode in ("resume", "lesson"):
    want = "run-session"
elif mode in ("revise", "debrief"):
    want = "vault-session"
else:
    want = f"{mode}-session"
sess = fm.get(want, {})
if not isinstance(sess, dict):
    sess = {}

# A vault stage is not stamped into the brief by /handoff (the brief describes repo
# sessions), and no brief on file carries a close-session block either (/handoff never
# stamped one). Both fall back to the defaults file, per-main override first.
if want in ("vault-session", "close-session") and not sess:
    dkey = "vault" if want == "vault-session" else "close"
    if os.path.isfile(dpath):
        d = parse(open(dpath, encoding='utf-8').read().splitlines())
        parts = os.path.normpath(path).split(os.sep)
        main = parts[parts.index(projects) + 1] if projects in parts else ''
        sess = dict(d.get('defaults', {}).get(dkey, {}) or {})
        sess.update(d.get('per-main', {}).get(main, {}).get(dkey, {}) or {})

out = {
    'BRIEF_REPO':     scalar('repo'),
    'BRIEF_BRANCH':   scalar('branch'),
    'BRIEF_REVISION': scalar('revision'),
    'BRIEF_HANDOFF':  scalar('handoff'),
    'SESS_KEY':       want,
    'CFG_MODEL':      sess.get('model', ''),
    'CFG_EFFORT':     sess.get('effort', ''),
    'CFG_PERM':       sess.get('permission-mode', ''),
    'CFG_DISALLOWED': sess.get('disallowed-tools', ''),
}
for k, v in out.items():
    print(f"{k}={shlex.quote(v)}")
PY
)" || die "could not parse brief frontmatter"
eval "$eval_lines"

# --model beats the brief. The brief still records what /handoff resolved; the launch
# banner and the dry-run print what was actually used.
if [ -n "$MODEL_ARG" ]; then
  [ -n "$CFG_MODEL" ] && printf 'NOTE: --model %s overrides the brief %s model %s.\n' "$MODEL_ARG" "$SESS_KEY" "$CFG_MODEL" >&2
  CFG_MODEL="$MODEL_ARG"
fi

[ -n "$BRIEF_REPO" ] || die "brief frontmatter has no repo:"
[ -d "$BRIEF_REPO" ] || die "repo not found: $BRIEF_REPO"
[ -n "$BRIEF_REVISION" ] || die "brief has no revision: — refusing to launch a brief that cannot be identified later"
if [ "$BACKEND" = "claude" ]; then
  [ -n "$CLAUDE_BIN" ] || die "claude not found. Checked PATH and the usual install locations. Set CLAUDE_BIN or invoke through a login shell."
fi

# ---------------------------------------------------------------- return channel
# A stage's output goes to a FILE next to the brief, never only to stdout. The brief is
# the channel into a repo session and these two files are the channel back:
# the next stage reads them from disk, so no human copies a block between sessions and
# no vault session has to stay open waiting for one.
SUB="$(basename "$(dirname "$(dirname "$BRIEF")")")"
BRIEF_REL="${BRIEF#"$VAULT"/}"
OUT_REVIEW="${BRIEF%.md}.review.md"
OUT_REPORT="${BRIEF%.md}.report.md"
OUT_CLOSE="${BRIEF%.md}.close.md"
OUT_DONE_WHEN="${BRIEF%.md}.done-when.md"   # close only: the §4 commands the launcher re-ran
OUT_SESSIONS="${BRIEF%.md}.sessions.log"    # claude: one `<UTC time> <mode> <session id>` line per stage
OUT_FIXUP="${BRIEF%.md}.fixup.md"           # loop only: the one fix-up's note to the run session
OUT_PREEXISTING="${BRIEF%.md}.preexisting.md"   # close --prove only: those §4 items re-run on the base
OUT_CHECK="${BRIEF%.md}.check.md"
RC_CHECK=12      # review only: brief-check found a FAIL, no session was launched

# ---------------------------------------------------------------- devin stage config
# The Devin CLI is a local coding agent, not a profile system, so its analogue of
# claude's --disallowedTools and of hermes's per-role profile has to be built from what it
# does have. The brief's <mode>-session block is Claude vocabulary, so the launcher
# TRANSLATES it instead of rewriting every brief on disk:
#
#   model   a Claude alias is also a Devin alias (opus, sonnet/claude, swe, gpt, codex,
#           gemini, haiku), and Devin carries the thinking level IN the model id
#           (claude-opus-5-medium). So <model>+<effort> resolves to <family-slug>-<effort>
#           against the account's live model list, and every other case falls back to the
#           brief's token verbatim. Fail-open on purpose: an id the account cannot see is a
#           launch failure, while the bare alias always resolves.
#   effort  no flag of its own — it IS the thinking level inside that model id.
#   perm    acceptEdits -> accept-edits, bypassPermissions -> dangerous, else auto; and
#           every headless stage is forced to dangerous, see the argv section.
#   deny    the read-only stages (review, close) get a real, harness-level write denial:
#           `permissions.deny: ["edit"]` in a generated --config, which is checked before
#           the permission decision and outranks the mode, so the edit tools are refused
#           while `exec` still runs. See the config block below for the merge rule.
DV_MODEL=""; DV_MODEL_NOTE=""; DV_PERM=""; DV_TMP=""; PROMPT_FILE=""
dv_perm() {   # claude's permission vocabulary -> devin's
  python3 - "${1:-}" <<'PY'
import sys
print({"acceptedits": "accept-edits", "accept-edits": "accept-edits",
       "bypasspermissions": "dangerous", "dangerous": "dangerous", "yolo": "dangerous",
       "manual": "auto", "normal": "auto", "auto": "auto"}.get(sys.argv[1].strip().lower(), "auto"))
PY
}
if [ "$BACKEND" = "devin" ]; then
  DV_TMP="$(mktemp -d)"
  # The account's tier decides which models exist at all — on Devin Free every named model
  # answers "Upgrade to Pro to access this model", and the ONLY thing that runs is the CLI's
  # own default. So the tier is read once here rather than discovered by a failed launch,
  # and the brief's model is only translated when the account can actually reach it.
  DV_TIER="$("$DEVIN_BIN" auth status 2>/dev/null | awk -F: '/Tier:/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
  DV_FREE=0
  case "$DV_TIER" in *[Ff]ree*) DV_FREE=1 ;; esac
  # A read-only stage gets its write denial HERE, at the harness level: `deny` is checked
  # before the permission decision and outranks the mode, so `edit` is refused outright
  # while `exec` still runs — which is what lets the review check claims with git instead
  # of only reading them. The skill it runs repeats the rule, but a rule is not a guarantee.
  #
  # --config REPLACES the user's ~/.config/devin/config.json, so our file is built by
  # merging theirs rather than by writing a bare one: silently dropping a user's own
  # permission rules to add ours would be a poor trade. An unparseable config (JSON with
  # comments) is the one case that cannot be merged, and it says so.
  DV_CONFIG=""; DV_CONFIG_NOTE=""
  case "$MODE" in
    review|close)
      DV_CONFIG="$DV_TMP/readonly-config.json"
      DV_CONFIG_NOTE="$(python3 - "$DV_CONFIG" "$HOME/.config/devin/config.json" <<'PY'
import json, sys
out, user = sys.argv[1], sys.argv[2]
try:
    base = json.load(open(user, encoding="utf-8"))
    if not isinstance(base, dict):
        raise ValueError
    note = "merged into the user config"
except FileNotFoundError:
    base, note = {}, "no user config to merge (created one)"
except Exception:
    base, note = {}, "user config is not plain JSON — NOT merged, only the deny rule applies"
perms = base.get("permissions") if isinstance(base.get("permissions"), dict) else {}
deny = list(perms.get("deny") or [])
if "edit" not in deny:
    deny.append("edit")
base["permissions"] = {**perms, "deny": deny}
base["read_config_from"] = {**{"cursor": True, "windsurf": True, "claude": True},
                            **(base.get("read_config_from") or {})}
json.dump(base, open(out, "w", encoding="utf-8"), indent=2)
print(note)
PY
)"
      ;;
  esac
  "$DEVIN_BIN" models list --format json >"$DV_TMP/models.json" 2>/dev/null || : >"$DV_TMP/models.json"
  if [ -n "$MODEL_ARG" ]; then
    DV_MODEL="$MODEL_ARG"; DV_MODEL_NOTE="from --model"
  elif [ "$DV_FREE" = "1" ]; then
    DV_MODEL=""
    DV_MODEL_NOTE="tier ${DV_TIER:-?}: only the CLI default runs, brief said ${CFG_MODEL:-<none>}"
  elif [ -n "$CFG_MODEL" ]; then
    DV_OUT="$(python3 - "$DV_TMP/models.json" "$CFG_MODEL" "$CFG_EFFORT" <<'PY'
import json, sys
path, token, effort = sys.argv[1], sys.argv[2].strip(), sys.argv[3].strip()

def norm(s):
    # hermes-stamped briefs carry portal ids ("z-ai/glm-5.3", "deepseek/deepseek-v4-flash"):
    # drop the vendor prefix. Devin spells family slugs with dashes where the upstream
    # model uses dots (glm-5.3 -> glm-5-3), so both sides are normalised before comparing.
    return s.rsplit("/", 1)[-1].lower().replace(".", "-")

try:
    fams = json.load(open(path, encoding="utf-8"))["families"]
except Exception:
    fams = []
want = norm(token)
fam = next((f for f in fams
            if norm(f.get("slug", "")) == want
            or want in [norm(str(a)) for a in (f.get("aliases") or [])]), None)
if fam is None:
    print(token); print("not a family alias here — passed verbatim")
else:
    # Devin carries the thinking level in the model id, and the suffix does not always
    # follow the slug verbatim, so the variant is found by matching the trailing effort
    # segment against the family's real ids rather than by building an id and hoping.
    pick = None
    if effort:
        for v in fam.get("variants") or []:
            uid = str(v.get("model_uid") or "")
            head, _, tail = uid.rpartition("-")
            if tail.lower() == effort.lower() and norm(head) == norm(fam.get("slug", "")):
                pick = uid
                break
    if pick:
        print(pick); print(f"{fam.get('family_label', fam['slug'])} {effort}")
    elif effort:
        print(token); print(f"{token} (no '{effort}' variant in that family)")
    else:
        # No thinking level recorded, so the family itself is the answer — an alias is
        # what devin's docs promise resolves, the slug is what its own list prints. The
        # raw token is only right when it is already one of those: a hermes-stamped brief
        # says "z-ai/glm-5.3", which is a portal id devin has never heard of.
        alias = (fam.get("aliases") or [None])[0]
        print(alias or fam.get("slug") or token)
        print(f"{fam.get('family_label', fam['slug'])}{' (alias)' if alias else ' (slug)'}")
PY
)" || DV_OUT="$CFG_MODEL"
    DV_MODEL="$(printf '%s\n' "$DV_OUT" | sed -n 1p)"
    DV_MODEL_NOTE="$(printf '%s\n' "$DV_OUT" | sed -n 2p)"
  else
    DV_MODEL_NOTE="no <mode>-session model in the brief — the CLI's own default"
  fi
fi

# The brief's handoff: field is the loop's state machine, and the launcher is the one
# process that knows when a stage actually started or finished, so it owns the moves
# draft->reviewed, ready->running, running->reported. The vault skills own
# reviewed->ready (revise) and reported->closed (debrief).
read_state() {
  python3 - "$BRIEF" <<'PY'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
for l in lines[1:]:
    if l.strip() == '---': break
    if l.startswith('handoff:'): print(l.split(':', 1)[1].strip().strip('"\'')); break
PY
}
set_state() {
  python3 - "$BRIEF" "$1" "$(date +%F)" <<'PY'
import io, sys
path, state, today = sys.argv[1:4]
text = io.open(path, encoding='utf-8').read()
lines = text.split('\n')
end = next(i for i, l in enumerate(lines[1:], 1) if l.strip() == '---')
seen = False
for i in range(1, end):
    if lines[i].startswith('handoff:'):
        lines[i] = f'handoff: {state}'; seen = True
    elif lines[i].startswith('updated:'):
        lines[i] = f'updated: {today}'
if not seen:
    lines.insert(end, f'handoff: {state}')
io.open(path, 'w', encoding='utf-8', newline='').write('\n'.join(lines))
PY
  printf 'handoff: %s -> %s  (%s)\n' "$BRIEF_HANDOFF" "$1" "$(basename "$BRIEF")" >&2
  BRIEF_HANDOFF="$1"
}

# One line of cost per claude stage (§3.6), on stderr and appended to <brief>.usage.log
# (tracked, like events.log). Never changes the stage's exit status or its stdout: every
# command here is guarded, so a ledger error becomes an "unavailable" line, not a failure
# the loop or the operator mistakes for the stage's own result.
usage_ledger() {
  [ "$BACKEND" = "claude" ] || return 0
  local id="$SESSION_ID" since=() brief_base transcript line
  # A resume appends to the transcript of the session it continues, whose earlier turns
  # are already in the ledger: count only the turns since this launch started.
  if [ "$MODE" = "resume" ]; then id="$SESSION"; since=(--since "$STARTED_EXACT"); fi
  [ -n "$id" ] || return 0
  brief_base="$(basename "$BRIEF" .md)"
  transcript="$(find "$HOME/.claude/projects" -maxdepth 2 -name "$id.jsonl" -print -quit 2>/dev/null)" || transcript=""
  [ -n "$transcript" ] || transcript="$HOME/.claude/projects/*/$id.jsonl"
  line="$(python3 "$KIT/handoff-usage.py" "$transcript" "$brief_base" "$MODE" "${since[@]}" 2>&1 | /usr/bin/grep -v '^[[:space:]]*$' | tail -1)" || line=""
  [ -n "$line" ] || line="ledger produced no output"
  case "$line" in
    "USAGE "*) ;;
    *) line="USAGE $brief_base $MODE unavailable — ledger error: ${line:0:160}" ;;
  esac
  printf '%s\n' "$line" >&2
  printf '%s\n' "$line" >>"${BRIEF%.md}.usage.log" 2>/dev/null || true
  return 0
}

# Commit attribution. Every commit an agent makes in a repo stage carries two trailers,
# `Harness:` and `Model:`, and never a Co-Authored-By line. The guarantee is a git hook,
# not a setting or a prose rule: hermes reproduced Claude's Co-Authored-By trailer by
# copying it from git history, so any agent that reads the log keeps doing it until a
# hook refuses. core.hooksPath is overridden through git's environment config for this
# process tree only — a human shell never sees it, so manual commits are untouched — and
# every other hook name gets a wrapper that hands over to the repo's own hook (a
# pre-commit framework lives there; an unchained override would disable it silently).
HOOKS_DIR="$HOME/.config/handoff/git-hooks"
install_git_hooks() {   # $1 = repo. Regenerates the session hook dir: ours + one chain wrapper per hook name.
  local src="$KIT/hooks" common names n
  [ -f "$src/prepare-commit-msg" ] && [ -f "$src/commit-msg" ] && [ -f "$src/pre-push" ] && [ -f "$src/chain" ] || die "hook templates missing under $src"
  mkdir -p "$HOOKS_DIR"
  common="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null || true)"
  case "$common" in /*) ;; *) common="$1/$common" ;; esac
  # Hook names come from git's own template list plus whatever this repo actually has —
  # never a typed list, because a name missing here is a repo hook silently skipped.
  names="$( { ls /usr/share/git-core/templates/hooks/ 2>/dev/null | sed -n 's/\.sample$//p'
              ls "$common/hooks" 2>/dev/null | sed -n '/\.sample$/!p'; } | sort -u )"
  for n in $names; do
    case "$n" in prepare-commit-msg|commit-msg|pre-push) continue ;; esac
    install -m 755 "$src/chain" "$HOOKS_DIR/$n"
  done
  install -m 755 "$src/prepare-commit-msg" "$HOOKS_DIR/prepare-commit-msg"
  install -m 755 "$src/commit-msg" "$HOOKS_DIR/commit-msg"
  install -m 755 "$src/pre-push" "$HOOKS_DIR/pre-push"     # no agent push onto dev/main
}

# ---------------------------------------------------------------- loop
# Serial by construction: each stage is this script again, and the next one starts only
# after the previous exited and the brief's state says it succeeded. Two sessions at
# once hit the usage limit as a burst (see above), so there is no parallel form.
if [ "$MODE" = "loop" ]; then
  RC_GATE=10; RC_RUN=20
  stage() {   # returns the stage's exit code; the caller decides what a failure means
    printf '\n==> loop: %s %s\n' "$1" "$(basename "$BRIEF")" >&2
    local rc=0
    bash "$0" "$@" "${PASS[@]}" || rc=$?
    return "$rc"
  }
  expect() {   # $1 = state the last stage must have produced
    local now; now="$(read_state)"
    [ "$now" = "$1" ] || die "stage left the brief at handoff: ${now:-<none>}, expected $1. Stopping here."
    BRIEF_HANDOFF="$now"
  }

  # The revise gate: the judgment lives in /handoff-revise,
  # which ends its unattended "## Revise outcome" block with ONE literal line, `gate: clean`
  # or `gate: held — <first failing check>`. This reads the LAST such block in the review
  # file and prints `clean`, `held — <reason>` or `missing — <where>`. Nothing else is parsed:
  # the first real outcome files carried `skipped:` and `decisions surfaced:` as free prose
  # with drifting arrows, and a predicate over those would be guessing. Absence fails closed.
  gate_read() {
    python3 - "$OUT_REVIEW" <<'PY'
import os, re, sys
path = sys.argv[1]
if not os.path.isfile(path):
    print(f"missing — no review file at {path}"); sys.exit()
text = open(path, encoding='utf-8', errors='replace').read()
parts = re.split(r'(?m)^## Revise outcome\b.*$', text)
if len(parts) < 2:
    print("missing — the review file has no '## Revise outcome' section"); sys.exit()
last = None
for last in re.finditer(r'(?m)^gate:[ \t]*(.*?)[ \t]*$', parts[-1]):
    pass
if last is None:
    print("missing — the latest Revise outcome has no 'gate:' line (fail closed)"); sys.exit()
v = last.group(1)
if v == 'clean':
    print('clean'); sys.exit()
m = re.match(r'held\b\s*[—–:-]*\s*(.*)$', v)
if m:
    print('held — ' + (m.group(1).strip() or '(no reason given)')); sys.exit()
print(f"missing — unrecognised gate token {v!r}, expected 'clean' or 'held — <reason>' (fail closed)")
PY
  }

  # The post-run check: every input is a fixed-format block the
  # launcher itself wrote — the COMPLETION REPORT in <brief>.report.md, the CLOSE AUDIT in
  # <brief>.close.md — plus the brief's own state. Prints `ok` or `failed — <first failing
  # check>`. `- none` (with or without a trailing explanation) is the written form of an
  # empty NOT DONE section in every real report so far, so it counts as empty; any other
  # item does not, whatever its prose says. The tree condition is the orchestrator's
  # (from git), not read from the report's `tree:` field.
  # outcome: PARTIAL and non-zero audit: counts are the run's self-check, written just
  # before the report, and /handoff-close turns any refuted or unconfirmed claim into
  # PARTIAL. Twice on 2026-09-29, every task done, that failed a run the close audit passed:
  # the run refuted its own over-broad wording of a claim, then left one unconfirmed for a
  # diff it never read. So neither fails the check alone: with NOT DONE none and the close
  # audit at PASS they print a WARNING: line on stderr. BLOCKED, or any other outcome, fails.
  run_check() {
    python3 - "$OUT_REPORT" "$OUT_CLOSE" "$(read_state)" <<'PY'
import os, re, sys
report, close, state = sys.argv[1:4]
def fail(why):
    print("failed — " + why); sys.exit()
if state != 'closed':
    fail(f"handoff: {state or '<none>'}, not closed")
if not os.path.isfile(report):
    fail(f"no completion report at {report}")
text = open(report, encoding='utf-8', errors='replace').read()
# Bounded by the END marker when the session printed one; 7 of the first 30 real reports
# did not, so the block otherwise runs to the end of the file. That opens nothing: every
# field below must still be literally present, and the debrief's appended section carries
# none of them.
blk = re.search(r'=== COMPLETION REPORT ===(.*?)(?:=== END COMPLETION REPORT ===|\Z)', text, re.S)
if not blk:
    fail("the report file has no COMPLETION REPORT block")
blk = blk.group(1)
warn = []
o = re.search(r'(?m)^outcome:\s*(\S+)', blk)
if not o:
    fail("the report has no outcome: line")
if o.group(1) == 'PARTIAL':
    warn.append("outcome: PARTIAL")
elif o.group(1) != 'COMPLETE':
    fail(f"outcome: {o.group(1)}")
a = re.search(r'(?m)^audit:.*?(\d+)\s+refuted,\s*(\d+)\s+unconfirmed', blk)
if not a:
    fail("the report has no parseable audit: line")
if a.group(1) != '0' or a.group(2) != '0':
    warn.append(f"audit: {a.group(1)} refuted, {a.group(2)} unconfirmed")
nd = re.search(r'(?m)^--- NOT DONE ---[ \t]*\n(.*?)(?=^--- |\Z)', blk, re.S)
if not nd:
    fail("the report has no --- NOT DONE --- section")
body = nd.group(1)
items = re.findall(r'(?m)^-[ \t].*(?:\n[ \t]+.*)*', body)
if not items and body.strip():
    items = [body.strip()]
real = [i for i in items if not re.match(r'^-?\s*none\b', i.strip(), re.I)]
if real:
    first = ' '.join(real[0].split())
    fail(f"NOT DONE lists {len(real)} item(s): {first[:100]}")
if not os.path.isfile(close):
    fail(f"no close audit at {close}")
c = open(close, encoding='utf-8', errors='replace').read()
v = re.search(r'(?m)^VERDICT:\s*(\S+)', c)
if not v:
    fail("the close audit has no VERDICT: line")
if v.group(1) != 'PASS':
    fail(f"close audit VERDICT: {v.group(1)}")
if warn:
    print("WARNING: run check passes on close audit VERDICT: PASS with NOT DONE none, although the report says "
          + " · ".join(warn), file=sys.stderr)
print("ok")
PY
  }
  gate_stop() {   # $1 = reason. One line on stdout for a machine, the rest on stderr for a human.
    printf 'GATE: %s\n' "$1"
    printf 'loop stopped at the gate (exit %s). Brief: %s\n  revise outcome: %s\n' "$RC_GATE" "$BRIEF" "$OUT_REVIEW" >&2
    exit "$RC_GATE"
  }
  # One fix-up per run, before the debrief. A close FAIL classed fixable whose every
  # failing finding names a §4 item (`§4.<n>`, the label the done-when results print) is
  # the run's own miss on its own criteria, and the run's session is the cheapest place to
  # clear it: it still holds the brief and the work. A finding marked `pre-existing?`
  # claims the check fails on the base too. No fix-up is spent on it: the next close
  # re-runs it on the base (--prove), and only a byte-identical result proves it. Prints
  # `pass` when the close did not FAIL; `fixup <run session id> <items to prove, or ->`
  # and then the lines to fix; `prove - <items>` when every failing finding is
  # pre-existing?; or `no — <why>`. A failing finding with no §4 label (the report's
  # honesty, its scope, a premise of the brief), a decision FAIL, or lines to fix under
  # any CLASS but fixable go on to the debrief and the run check, as before. The session
  # id is the latest `run` line of <brief>.sessions.log; a `resume` line after it means
  # this run has had its fix-up.
  fixup_read() {
    python3 - "$OUT_CLOSE" "$OUT_SESSIONS" "$BACKEND" <<'PY'
import re, sys
close, sessions, backend = sys.argv[1:4]
def no(why):
    print('no — ' + why); sys.exit()
try:
    c = open(close, encoding='utf-8', errors='replace').read()
except OSError:
    no('no close audit at ' + close)
v = re.search(r'(?m)^VERDICT:\s*(\S+)', c)
if not v or v.group(1) != 'FAIL':
    print('pass'); sys.exit()
k = re.search(r'(?m)^CLASS:\s*(\S+)', c)
klass = k.group(1) if k else 'nowhere'
if klass == 'decision':
    no('the close FAIL is classed decision')
f = re.search(r'(?ms)^FINDINGS:[ \t]*\n(.*?)(?=^=== END CLOSE AUDIT ===|\Z)', c)
PRE = re.compile(r'\u2014\s*\**pre-existing\?\**\s*\u2014', re.I)
lines = [l.strip() for l in (f.group(1) if f else '').splitlines()
         if re.search(r'\b(?:refuted|unconfirmed)\b', l, re.I) or PRE.search(l)]
if not lines:
    no('the close FAIL names no refuted, unconfirmed or pre-existing? finding')
off = [l for l in lines if not re.match(r'^(?:-\s*)?\**§4\.\d+(?!\d)', l)]
if off:
    no('a failing finding is not on a §4 item: ' + ' '.join(off[0].split())[:120])
pre = [l for l in lines if PRE.search(l)]
fix = [l for l in lines if l not in pre]
prove = ','.join(str(n) for n in sorted({int(re.match(r'^(?:-\s*)?\**§4\.(\d+)', l).group(1)) for l in pre})) or '-'
if not fix:
    print('prove - ' + prove); sys.exit()
if klass != 'fixable':
    no('the close FAIL is classed %s, not fixable' % klass)
if backend != 'claude':
    no("a fix-up resumes the run's own session, which only the claude backend saves")
try:
    rows = [l.split() for l in open(sessions, encoding='utf-8', errors='replace')]
except OSError:
    no('no session ids recorded at ' + sessions)
runs = [i for i, r in enumerate(rows) if len(r) >= 3 and r[1] == 'run']
if not runs:
    no('no run session recorded in ' + sessions)
if any(len(r) >= 3 and r[1] == 'resume' for r in rows[runs[-1] + 1:]):
    no('this run has had its one fix-up')
print('fixup %s %s' % (rows[runs[-1]][2], prove))
print('\n'.join(fix))
PY
  }
  fixup_note() {   # $1 = the findings to fix, $2 = the items to prove or -. The whole prompt of the resumed run session.
    local proving=""
    [ "$2" = "-" ] || proving="

The close also marked §4.${2//,/, §4.} pre-existing?: the launcher re-runs those on a clean checkout of the base before the next close, and only a byte-identical result there proves them. Leave them alone."
    cat >"$OUT_FIXUP" <<EOF
The close audit of this run FAILed, classed fixable. Each line below is a §4 Done-when item it refuted or could not confirm. The launcher re-ran every §4 command after your report, so an exit code or an output line quoted here is a fact, not an opinion.

$1$proving

Fix only these. Touch nothing else and do not redo work that passed. If an item cannot be met as the brief states it, do not bend its check to pass: say so under NOT DONE. Then re-run every §4 command, one per Bash call; commit and push the fix by explicit refspec; and finish with /handoff-close, which re-emits the whole COMPLETION REPORT, for the brief and this fix together. This is the one fix-up: a second FAIL stops the loop for a human.
EOF
  }
  run_stop() {    # $1 = reason
    printf 'RUN: %s\n' "$1"
    printf 'loop finished but the run failed the check (exit %s). Report: %s\n  close audit: %s\n' "$RC_RUN" "$OUT_REPORT" "$OUT_CLOSE" >&2
    exit "$RC_RUN"
  }

  if [ "$DRY" = "1" ]; then
    if [ "$GATE" = "auto" ]; then gate_word="gate(auto: reads the token)"; else gate_word="STOP for approval"; fi
    tail_word="close -> (a pre-existing? §4 FAIL: close --prove, once) -> debrief"
    [ "$BACKEND" = "claude" ] && tail_word="close -> (a fixable §4 FAIL: resume -> close, once; a pre-existing? item: --prove) -> debrief"
    case "$BRIEF_HANDOFF" in
      draft)    plan="review -> revise -> $gate_word -> run --delegate -> $tail_word"; first=review ;;
      reviewed) plan="revise -> $gate_word -> run --delegate -> $tail_word";           first=revise ;;
      ready)    plan="run --delegate -> $tail_word";    first=run ;;
      reported) plan="$tail_word";                      first=close ;;
      running)  plan="nothing: a run is recorded live";       first="" ;;
      closed)   plan="nothing: closed";                       first="" ;;
      *)        plan="nothing: state '${BRIEF_HANDOFF:-<none>}' is not in the loop"; first="" ;;
    esac
    [ "$GATE" = "human" ] && case "$BRIEF_HANDOFF" in draft|reviewed) plan="${plan%% -> run *}" ;; esac
    printf 'DRY RUN loop — from handoff: %s the plan is: %s\n' "${BRIEF_HANDOFF:-<none>}" "$plan"
    printf '  backend: %s   model: %s   gate: %s\n' "$BACKEND" "${MODEL_ARG:-<per stage: brief / hermes profile>}" "$GATE"
    printf '  review  -> %s\n  report  -> %s\n  close   -> %s\n' "$OUT_REVIEW" "$OUT_REPORT" "$OUT_CLOSE"
    printf '  exit codes: 0 closed · 10 gate held (GATE: …) · 20 run failed (RUN: …) · 30 launcher error\n'
    case "$BRIEF_HANDOFF" in
      reviewed|ready) printf '  gate token now: %s\n' "$(gate_read)" ;;
      reported|closed) printf '  run check now:  %s\n' "$(run_check)" ;;
    esac
    if [ -n "$first" ]; then
      printf '\nfirst stage resolves as:\n'
      if [ "$first" = "run" ]; then bash "$0" run "$BRIEF" --delegate --dry-run "${PASS[@]}"; else bash "$0" "$first" "$BRIEF" --dry-run "${PASS[@]}"; fi
    fi
    exit 0
  fi

  while :; do
    case "$BRIEF_HANDOFF" in
      draft)
        rc=0; stage review "$BRIEF" || rc=$?
        if [ "$rc" -eq "$RC_CHECK" ]; then
          res="$(/usr/bin/grep -m1 '^RESULT ' "$OUT_CHECK" 2>/dev/null || true)"
          ff="$(/usr/bin/grep -m1 '^FAIL ' "$OUT_CHECK" 2>/dev/null || true)"
          gate_stop "brief-check — ${res#RESULT } · first: ${ff#FAIL }"
        fi
        [ "$rc" -eq 0 ] || die "review stage exited $rc — see its output above"
        expect reviewed ;;
      reviewed)
        # The revise stage's exit code is not the verdict: the state and the token are.
        # A non-zero exit that still moved the brief to ready is a session that died
        # after its work; one that left it at reviewed is a held gate, named by the token.
        stage revise "$BRIEF" || printf 'NOTE: revise stage exited %s; reading the brief state and the gate token anyway.\n' "$?" >&2
        now="$(read_state)"
        if [ "$now" != "ready" ]; then
          token="$(gate_read)"
          case "$token" in
            held*) gate_stop "$token" ;;
            *)     gate_stop "held — revise left the brief at handoff: ${now:-<none>} (a REWRITE verdict or a revision mismatch stops here on purpose); token: $token" ;;
          esac
        fi
        BRIEF_HANDOFF="$now"
        if [ "$GATE" = "human" ]; then
          printf '\nLOOP PAUSED — revised brief is ready for your approval:\n  %s\n' "$BRIEF"
          printf 'What the revise stage did and did not apply: %s (section "Revise outcome").\n' "$OUT_REVIEW"
          printf 'Revise stage verdict (informational under --gate human): %s\n' "$(gate_read)"
          printf 'Read the brief. To run it, launch the loop again — it resumes from handoff: ready.\n'
          gate_stop "human — read the revised brief, then re-run loop to approve it"
        fi ;;
      ready)
        if [ "$GATE" = "auto" ]; then
          # Two independent reads, both required: the token from the review file,
          # the state from the brief. Either one missing or wrong holds the gate.
          token="$(gate_read)"
          [ "$token" = "clean" ] || gate_stop "$token"
          [ "$(read_state)" = "ready" ] || gate_stop "held — token is clean but the brief says handoff: $(read_state)"
          printf 'gate: clean — continuing past ready unattended (--gate auto)\n' >&2
        fi
        stage run "$BRIEF" --delegate || die "run stage exited $? — see its output above"
        expect reported ;;
      reported)
        stage close "$BRIEF" || die "close stage exited $? — see its output above"   # audit; stays reported, then debrief closes it
        next="$(fixup_read)" || next="no — the fix-up check crashed"
        case "$next" in
          pass) ;;
          fixup\ *|prove\ *)
            read -r kind sid items <<<"$(printf '%s\n' "$next" | head -1)"
            fails="$(printf '%s\n' "$next" | tail -n +2)"
            for f in "$OUT_REPORT" "$OUT_CLOSE" "$OUT_DONE_WHEN"; do
              if [ -f "$f" ]; then cp "$f" "${f%.md}-1.md"; fi
            done
            prove=()
            [ "$items" = "-" ] || prove=(--prove "$items")
            if [ "$kind" = "fixup" ]; then
              fixup_note "$fails" "$items"
              printf 'fix-up: the close FAILed on %s §4 finding(s), classed fixable — resuming run session %s once with %s\n' \
                "$(printf '%s\n' "$fails" | wc -l)" "$sid" "$OUT_FIXUP" >&2
              # A fix-up is a run: if it dies, the brief is left where a dead run leaves it.
              set_state running
              stage resume "$BRIEF" --session "$sid" --note "$OUT_FIXUP" \
                || die "fix-up resume exited $? — brief left at handoff: $(read_state); the first attempt is kept in $(basename "${OUT_REPORT%.md}")-1.md and $(basename "${OUT_CLOSE%.md}")-1.md; set handoff: reported to close the first attempt again"
              expect reported
            else
              printf 'pre-existing: the close FAILed only on §4.%s, marked pre-existing? — closing again after a re-run on a clean checkout of the base\n' "${items//,/, §4.}" >&2
            fi
            stage close "$BRIEF" "${prove[@]}" || die "the second close stage exited $? — see its output above" ;;
          *) printf 'fix-up: %s\n' "$next" >&2 ;;
        esac
        stage debrief "$BRIEF" || printf 'NOTE: debrief stage exited %s; reading the brief state anyway.\n' "$?" >&2
        expect closed ;;
      closed)
        verdict="$(run_check)"
        if [ "$GATE" = "auto" ]; then
          [ "$verdict" = "ok" ] || run_stop "$verdict"
          printf '\nLOOP COMPLETE — %s is closed and the run passed the check. Report and debrief outcome: %s\n' "$(basename "$BRIEF")" "$OUT_REPORT"
        else
          printf '\nLOOP COMPLETE — %s is closed. Report and debrief outcome: %s\n' "$(basename "$BRIEF")" "$OUT_REPORT"
          printf 'Run check (informational under --gate human): %s\n' "$verdict"
        fi
        exit 0 ;;
      running)
        die "brief is handoff: running. If a run is live, wait for it (claude agents --json). If it died without a report, /debrief $SUB with no report reconstructs from git and closes it." ;;
      *)
        die "handoff: '${BRIEF_HANDOFF:-<none>}' is not a loop state (draft|reviewed|ready|running|reported|closed)." ;;
    esac
  done
fi

# A vault stage needs its input file, which a previous stage should have written.
need_input() {   # $1 = file, $2 = how to produce it
  [ -f "$1" ] && return 0
  [ "$DRY" = "1" ] && { printf 'WARNING: input file missing: %s — %s\n' "$1" "$2" >&2; return 0; }
  die "input file missing: $1 — $2"
}
[ "$MODE" = "revise" ]  && need_input "$OUT_REVIEW" "a review writes it: handoff-launch review $BRIEF_REL"
[ "$MODE" = "debrief" ] && need_input "$OUT_REPORT" "a delegated run writes it. For a watched run, paste the block into a vault session: /debrief $SUB"
[ "$MODE" = "close" ]   && need_input "$OUT_REPORT" "a delegated run writes it: handoff-launch run $BRIEF_REL --delegate"

# A review must be unable to write. This is a hard denial, not a preference: the
# session reports "No such tool available: Write ... in subagents as well as here", so
# the fan-out cannot route around it either. The close audit is read-only for the same
# reason and gets the same denial — it used to get none.
if { [ "$MODE" = "review" ] || [ "$MODE" = "close" ]; } && [ -z "$CFG_DISALLOWED" ]; then
  CFG_DISALLOWED="Edit,Write,NotebookEdit"
fi

# --delegate means nobody is there to answer a prompt, so a permission mode that asks
# questions turns the run into an expensive no-op. Proven: the first delegated run stopped
# on its very first substantive step because `git ls-remote` needed approval, having done
# nothing at all.
#
# This is safe for the reason the toolkit exists: permission mode governs Claude Code's
# own prompts, NOT the repo's PreToolUse hooks. guard-universal, guard-prod and guard-paths
# still fire and still exit 2 — dangerous commands, `make release`, pushes to protected
# branches and writes escaping the repo root remain refused, unapprovably. Bypassing the
# prompts leaves the actual guard layer intact.
#
# Watched runs keep whatever the brief records: there, the prompts are useful.
if [ "$DELEGATE" = "1" ] && [ "$CFG_PERM" != "bypassPermissions" ]; then
  printf 'NOTE: --delegate overrides permission-mode %s -> bypassPermissions.\n' "${CFG_PERM:-<unset>}" >&2
  printf '      Unattended cannot answer prompts. The repo hooks still apply.\n' >&2
  CFG_PERM="bypassPermissions"
fi

# The read-only stages are headless too, and a headless session auto-denies every prompt
# it cannot show. Under the brief's acceptEdits (review) or no mode at all (close — briefs
# carry no close-session block) the audit could run only what the repo's settings allowlist
# named, so `npx vitest`, `pytest` and `gh pr view` were refused and 11 of the first 12
# FAIL verdicts read "unconfirmed — this command requires approval" (2026-09-21).
# Same rule the devin branch below already applies: every unattended stage
# bypasses prompts; review and close are held by the tool denial above and by the repo
# hooks, which fire regardless of mode — not by prompts nobody is there to answer.
if [ "$BACKEND" = "claude" ] && { [ "$MODE" = "review" ] || [ "$MODE" = "close" ]; } && [ "$CFG_PERM" != "bypassPermissions" ]; then
  printf 'NOTE: %s is headless — permission-mode %s -> bypassPermissions so the audit can execute what it checks.\n' "$MODE" "${CFG_PERM:-<unset>}" >&2
  printf '      Writes stay denied: --disallowedTools %s, plus the repo hooks.\n' "$CFG_DISALLOWED" >&2
  CFG_PERM="bypassPermissions"
fi

# A brief written by /handoff carries a resolved <mode>-session block. A missing one is
# not fatal, but it means the session silently inherits the machine's own defaults, and
# the brief then does NOT record what its run was actually given — which is the one
# property the whole scheme rests on. Say so rather than quietly substituting values.
if [ -z "$CFG_MODEL$CFG_EFFORT$CFG_PERM" ]; then
  printf 'WARNING: no %s block in the brief (or handoff-defaults.yml). Model, effort and permission mode will\n' "$SESS_KEY" >&2
  printf '         come from this machine settings, and the brief will not record them.\n' >&2
fi

# The PR rule depends on the repo's forge. On a GitLab origin `gh` cannot reach the remote
# ("none of the git remotes ... point to a known GitHub host"): a run on a GitLab repo
# (2026-10-05) stopped PARTIAL on that one step. Read from origin's URL here,
# spliced into RUN_RULES below.
case "$(git -C "$BRIEF_REPO" remote get-url origin 2>/dev/null)" in
  *gitlab*) PR_RULE='- Right after the first push, if no merge request is open for the branch (`glab mr list --source-branch <branch>`), open one draft merge request against the base the brief names: `glab mr create --draft --target-branch <base> --source-branch <branch> --fill --yes`. This repo is on GitLab: `gh` cannot reach it, so every PR step the brief names (view, create, update the description) is done with `glab mr` (`glab mr update <number> --description "$(cat <file>)"`). Never open a second one, never merge, never push to dev or main.' ;;
  *) PR_RULE='- Right after the first push, if no PR is open for the branch, open one draft PR against the base the brief names: `gh pr create --draft --base <base>`. Never open a second one, never merge, never push to dev or main.' ;;
esac

# Standing rules for every run prompt, whatever the backend. Defined once here, inline,
# rather than read from a file in the kit: the driver runs a snapshot of this script for
# a whole phase, and a rules file read live from the vault would change under it. A
# QUOTED heredoc, on purpose — the block below contains backticked command examples
# that a double-quoted string would execute as command substitution.
RUN_RULES="$(cat <<'EOF'
Standing rules for every handoff run. They hold whatever the brief below says.
- Commit as you go and push every commit by explicit refspec: `git push origin <branch>` (add `-u` the first time). Never a bare `git push`.
@PR_RULE@
- Commit messages carry the Harness: and Model: trailers the session adds for you. Never add a Co-Authored-By line.
- Write no planning or report .md file into the repo.
- Never end a turn waiting on a background task: a -p session never receives its notification, so the run would end there. Run long commands in the foreground with a timeout of up to 900000 ms. A command that overruns its timeout is killed, not backgrounded: give a long check a longer timeout, or split it.
- Keep command output short: run checks as `set -o pipefail; <command> 2>&1 | tail -n 40`, which keeps the exit code and the last 40 lines. Run vitest with `--reporter=dot`. pytest already gets `-q --tb=short` from the environment.
- Read each file once. To look at part of it again, use `grep -n` or `sed -n '<from>,<to>p'`.
- Finish by running /handoff-close. Do not substitute another completion, verification or plan-execution skill.
EOF
)"
RUN_RULES="${RUN_RULES/@PR_RULE@/"$PR_RULE"}"

# ---------------------------------------------------------------- brief-check (review only)
# The deterministic pre-check. It runs before any review session is spent; only its FAIL
# checks stop the stage (the self-containment sweep), WARN lines are leads for the review.
# The report is kept beside the brief. A crash, a timeout or a missing script fails open
# with a WARNING: the review still runs every lens.
CHECK_OUT=""; CHECK_RC=0; CHECK_RESULT=""
if [ "$MODE" = "review" ]; then
  if [ -f "$KIT/brief-check.sh" ]; then
    CHECK_OUT="$(timeout 300 bash "$KIT/brief-check.sh" "$BRIEF" 2>&1)" || CHECK_RC=$?
  else
    CHECK_OUT="brief-check.sh not found at $KIT/brief-check.sh"; CHECK_RC=127
  fi
  CHECK_RESULT="$(printf '%s\n' "$CHECK_OUT" | /usr/bin/grep -m1 '^RESULT ' || true)"
  if [ "$DRY" != "1" ]; then
    { printf '# brief-check · %s · revision %s · %s · exit %s\n\n' "$(basename "$BRIEF")" "$BRIEF_REVISION" "$(date -u +%FT%TZ)" "$CHECK_RC"
      printf '%s\n' "$CHECK_OUT"; } >"$OUT_CHECK"
    # Exit 1 is a FAIL only with a RESULT line: a Python crash also exits 1, and fails open.
    if [ "$CHECK_RC" -eq 1 ] && [ -n "$CHECK_RESULT" ]; then
      first_fail="$(printf '%s\n' "$CHECK_OUT" | /usr/bin/grep -m1 '^FAIL ' || true)"
      printf 'BRIEF-CHECK: %s · first: %s\n' "${CHECK_RESULT#RESULT }" "${first_fail#FAIL }"
      printf 'review not launched: brief-check found a FAIL. Fix the brief and launch again. Report: %s\n' "$OUT_CHECK" >&2
      exit "$RC_CHECK"
    elif [ "$CHECK_RC" -ne 0 ]; then
      printf 'WARNING: brief-check exited %s — reviewing anyway. Report: %s\n' "$CHECK_RC" "$OUT_CHECK" >&2
    fi
  fi
fi

# ---------------------------------------------------------------- review blocks
# The two write-time reports a claude or devin review is given, so it verifies their
# findings instead of rediscovering them: the brief-check output of this launch, and the
# claim table written beside the brief. A table whose header names another revision is
# still shown, marked STALE, as leads only.
review_blocks() {
  local claims="${BRIEF%.md}.claims.md" rev
  printf '=== BRIEF-CHECK REPORT ===\n%s\n' "${CHECK_OUT:-none}"
  printf '=== CLAIM TABLE ===\n'
  if [ -f "$claims" ]; then
    rev="$(/usr/bin/grep -m1 '^# Claim check — ' "$claims" | sed -n 's/^# Claim check — .* — revision \([^ ]*\) — .*$/\1/p')"
    [ "$rev" = "$BRIEF_REVISION" ] || printf 'STALE: revision %s, brief is %s\n' "${rev:-unknown}" "$BRIEF_REVISION"
    cat "$claims"
  else
    printf 'none\n'
  fi
}
# The prompt travels as one argv string and the kernel refuses one over 128 KiB
# (MAX_ARG_STRLEN), so a large brief plus both reports would kill the stage. Past
# REVIEW_PROMPT_MAX bytes the reports are left out, with a WARNING, and the review runs.
REVIEW_PROMPT_MAX=126000
review_prompt() {   # $1 = wrapper text
  local p
  p="$1
$(review_blocks)
=== BRIEF UNDER REVIEW ===
$(cat "$BRIEF")"
  if [ "$(printf '%s' "$p" | wc -c)" -gt "$REVIEW_PROMPT_MAX" ]; then
    printf 'WARNING: brief and reports pass %s bytes — the review gets the brief alone\n' "$REVIEW_PROMPT_MAX" >&2
    p="$1
=== BRIEF-CHECK REPORT ===
omitted: the prompt would pass the 128 KiB argument limit
=== CLAIM TABLE ===
omitted: the prompt would pass the 128 KiB argument limit
=== BRIEF UNDER REVIEW ===
$(cat "$BRIEF")"
  fi
  printf '%s' "$p"
}

# ---------------------------------------------------------------- done-when (close only)
# The close stage judges §4; it does not choose what to run. Left to choose, two sonnet
# closes (2026-09-29, 2026-10-01) never opened the brief and FAILed on unchecked claims. So
# before the close session starts, every §4 command `brief-check.sh --done-when` can read
# is re-run HERE, in the run's worktree, with no model involved: one at a time, stdin
# closed, each under HANDOFF_DONE_WHEN_TIMEOUT seconds (600). Its exit code, its seconds,
# a sha256 of its whole output and the last 40 lines of it go to <brief>.done-when.md,
# which the close prompt carries beside the brief's §4. An item with no command the parser
# can read is a judged item: the close checks it itself. A parser that is missing, crashes
# or times out fails open with a NOTE, and every item is then judged.
DW_TIMEOUT="${HANDOFF_DONE_WHEN_TIMEOUT:-600}"
DW_SUMMARY=""
done_when_run() {   # $1 = dir the commands run in, $2 = results file, $3 = 1: list, run nothing, $4 = only these items (2,5)
  python3 - "$KIT/brief-check.sh" "$BRIEF" "$1" "$2" "$DW_TIMEOUT" "$3" "$BRIEF_REVISION" "${4:-}" <<'PY'
import hashlib, json, os, subprocess, sys, time
from datetime import datetime, timezone

checker, brief, repo, out, timeout_s, list_only, revision, only = sys.argv[1:9]
only = {int(n) for n in only.split(',')} if only else None
timeout_s = int(timeout_s)
KEEP, WIDE = 40, 500        # lines kept per command, characters kept per line
NOT_RUN = {'placeholder': 'it holds a placeholder', 'denied': 'it writes to git or the network',
           'no-file': 'its grep names no file'}


def parse():
    if not os.path.isfile(checker):
        return None, 'brief-check.sh not found at %s' % checker
    try:
        p = subprocess.run(['bash', checker, '--done-when', brief], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    except subprocess.TimeoutExpired:
        return None, 'brief-check.sh --done-when timed out after 120 s'
    if p.returncode != 0:
        err = p.stderr.decode('utf-8', 'replace').strip().splitlines()
        return None, 'brief-check.sh --done-when exited %d: %s' % (p.returncode, err[-1] if err else 'no output')
    try:
        return [json.loads(l) for l in p.stdout.decode('utf-8', 'replace').splitlines() if l.strip()], ''
    except ValueError:
        return None, 'brief-check.sh --done-when printed a line that is not JSON'


def run(cmd, env):
    t0 = time.monotonic()
    try:
        # timeout(1) kills the command's whole process group; the outer timeout only
        # stops a child that keeps the pipe open after that.
        p = subprocess.run(['timeout', '-k', '10', str(timeout_s), 'bash', '-c', cmd], cwd=repo, env=env,
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout_s + 30)
        rc, data = p.returncode, p.stdout
    except subprocess.TimeoutExpired as e:
        rc, data = 124, e.stdout or b''
    return rc, round(time.monotonic() - t0), data


def head():
    p = subprocess.run(['git', '-C', repo, 'rev-parse', '--short', 'HEAD'],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p.stdout.decode().strip() or 'unknown'


items, why = parse()
if list_only == '1':
    if items is None:
        print('parser failed (%s) — the close would judge every §4 item' % why)
        sys.exit(0)
    cmds = [(it['item'], c) for it in items for c in it['commands']]
    print('%d commands from %d §4 items would run in %s before the session, %d s each; %d items judged; results -> %s'
          % (len(cmds), len(items), repo, timeout_s, sum(1 for it in items if not it['commands']), out))
    for n, c in cmds:
        print('  §4.%d $ %s' % (n, c['cmd'].split('\n')[0][:100]))
    sys.exit(0)

env = dict(os.environ)
env['PYTEST_ADDOPTS'] = ((env.get('PYTEST_ADDOPTS') or '') + ' -q --tb=short').strip()
body, ran, nonzero, judged, total = [], 0, 0, 0, 0
if items is None:
    body.append('none: %s — every §4 item is a judged item: check each one yourself' % why)
elif not items:
    body.append('none: the brief has no numbered §4 items — judge the report as before')
for it in items or []:
    if only is not None and it['item'] not in only:
        continue
    label = '§4.%d' % it['item']
    for c in it['commands']:
        rc, secs, data = run(c['cmd'], env)
        ran += 1
        total += secs
        nonzero += rc != 0
        late = ' · timed out after %d s' % timeout_s if rc in (124, 137) and secs >= timeout_s else ''
        body.append('%s · line %d · exit %d · %ds%s · sha256 %s'
                    % (label, c['line'], rc, secs, late, hashlib.sha256(data).hexdigest()[:16]))
        for k, l in enumerate(c['cmd'].split('\n')):
            body.append(('  $ ' if k == 0 else '  > ') + l)
        lines = data.decode('utf-8', 'replace').split('\n')
        if lines and lines[-1] == '':
            lines.pop()
        if not lines:
            body.append('  (no output)')
        for l in lines[-KEEP:]:
            body.append('  | ' + (l if len(l) <= WIDE else l[:WIDE] + '…[+%d chars]' % (len(l) - WIDE)))
    for s in it['skipped']:
        body.append('%s · line %d · not run: %s — judge it yourself' % (label, s['line'], NOT_RUN.get(s['why'], s['why'])))
        body.append('  $ ' + s['cmd'].split('\n')[0])
    if not it['commands']:
        judged += 1
        if not it['skipped']:
            body.append('%s · line %d · judged — no command the launcher can run: check it yourself' % (label, it['line']))
if items is None:
    count = 'parser failed — every §4 item is judged'
else:
    count = '%d commands run in %d s · %d exited non-zero · %d of %d §4 items judged' % (ran, total, nonzero, judged, len(items))
stamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
text = '# done-when · %s · revision %s · %s · head %s\n%s\n%s\n' % (
    os.path.basename(brief), revision, stamp, head(), count, '\n'.join(body))
with open(out + '.tmp', 'w', encoding='utf-8') as f:
    f.write(text)
os.replace(out + '.tmp', out)
print('%s -> %s' % (count, out))
PY
}
if [ "$MODE" = "close" ]; then
  if [ "$DRY" = "1" ]; then
    DW_SUMMARY="$(done_when_run "$BRIEF_REPO" "$OUT_DONE_WHEN" 1)" || DW_SUMMARY="the parser could not be listed"
  elif [ -f "$OUT_REPORT" ]; then
    rm -f "$OUT_DONE_WHEN"
    if ! DW_SUMMARY="$(done_when_run "$BRIEF_REPO" "$OUT_DONE_WHEN" 0)"; then
      DW_SUMMARY="the runner crashed — every §4 item is a judged item: check each one yourself"
      printf '# done-when · %s · revision %s · %s\nnone: %s\n' "$(basename "$BRIEF")" "$BRIEF_REVISION" "$(date -u +%FT%TZ)" "$DW_SUMMARY" >"$OUT_DONE_WHEN"
      printf 'NOTE: done-when %s\n' "$DW_SUMMARY" >&2
    else
      printf 'done-when: %s\n' "$DW_SUMMARY" >&2
    fi
  fi
fi
# ---------------------------------------------------------------- pre-existing proof (close --prove only)
# A failing §4 item the close marked `pre-existing?` (the report or the output says its
# check fails on the base too) is a model's claim, and a claim never passes on its own:
# the test a run called a pre-existing flake on 2026-09-28 failed 6 of 8 runs. With
# --prove (the loop's second close), those items' commands are re-run here, before the
# session, on a clean detached checkout of origin/<base> with no hooks, by the same
# runner. An item is proven only when every one of its commands exits with the same code
# and prints byte-identical output (the same sha256) there and in this close's results.
# A judged or not-run part, a timeout, or a command naming this checkout's path or $HOME
# never proves. The base is HANDOFF_BASE (the orchestrator passes the plan's), else dev
# when origin has it, else main. The proof goes to <brief>.preexisting.md and into the
# prompt; the phase summary lists each proven item under BRIEF WAS WRONG.
PROOF_SUMMARY=""
proof_base() {
  local b="${HANDOFF_BASE:-}"
  if [ -z "$b" ]; then
    if git -C "$BRIEF_REPO" rev-parse --verify -q origin/dev >/dev/null 2>&1; then b=dev; else b=main; fi
  fi
  printf 'origin/%s' "$b"
}
proof_none() {   # $1 = why nothing is proven: the proof file and its summary line
  printf '# pre-existing proof · %s · revision %s · %s\nnone: %s — nothing is proven\n' \
    "$(basename "$BRIEF")" "$BRIEF_REVISION" "$(date -u +%FT%TZ)" "$1" >"$OUT_PREEXISTING"
  printf 'nothing proven: %s -> %s' "$1" "$OUT_PREEXISTING"
}
proof_run() {   # PROOF_TMP is the caller's, so the EXIT cleanup sees it. Prints the summary line.
  local ref sha out
  ref="$(proof_base)"
  sha="$(git -C "$BRIEF_REPO" rev-parse --verify -q "$ref^{commit}" 2>/dev/null)" || { proof_none "$ref does not exist in $BRIEF_REPO"; return 0; }
  # No hooks: the checkout is a throwaway, and no post-checkout hook may run in it.
  out="$(git -C "$BRIEF_REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$PROOF_TMP/base" "$sha" 2>&1)" \
    || { proof_none "could not check out $ref: $(printf '%s' "$out" | tail -1)"; return 0; }
  done_when_run "$PROOF_TMP/base" "$PROOF_TMP/base.done-when.md" 0 "$PROVE" >/dev/null || true
  git -C "$BRIEF_REPO" worktree remove --force "$PROOF_TMP/base" >/dev/null 2>&1 || true
  python3 - "$OUT_DONE_WHEN" "$PROOF_TMP/base.done-when.md" "$PROVE" "$ref" "$BRIEF_REPO" "$HOME" "$OUT_PREEXISTING" "$(basename "$BRIEF")" "$BRIEF_REVISION" <<'PY'
import os, re, sys
from datetime import datetime, timezone

here_p, base_p, want, ref, repo, home, out, brief, revision = sys.argv[1:10]
want = sorted({int(n) for n in want.split(',')})
ROW = re.compile(r'^§4\.(\d+) · line (\d+) · (?:exit (\d+) · \d+s( · timed out after \d+ s)? · sha256 ([0-9a-f]+)$|(not run|judged)\b)')


def load(p):
    # {item: [row]} and the head the results were taken on; None when there is no file
    try:
        lines = open(p, encoding='utf-8', errors='replace').read().split('\n')
    except OSError:
        return None, '?'
    m = re.search(r' · head (\S+)$', lines[0])
    rows, cur = {}, None
    for l in lines[1:]:
        m2 = ROW.match(l)
        if m2:
            cur = {'line': int(m2.group(2)), 'rc': m2.group(3), 'late': bool(m2.group(4)),
                   'sha': m2.group(5), 'other': m2.group(6), 'cmd': []}
            rows.setdefault(int(m2.group(1)), []).append(cur)
        elif cur is not None and l[:4] in ('  $ ', '  > '):
            cur['cmd'].append(l[4:])
    return rows, (m.group(1) if m else '?')


here, head_sha = load(here_p)
there, base_sha = load(base_p)
outside = {p for p in (repo, os.path.realpath(repo), home) if p and p != '/'}
HOME_RE = re.compile(r'(?<![\w/.-])~(?=/|\s|$)|\$\{?HOME\b')
body, proven = [], 0
for n in want:
    rows = (here or {}).get(n, [])
    base = {r['line']: r for r in (there or {}).get(n, [])}
    why = None
    if here is None:
        why = 'this close has no done-when results to compare with'
    elif not rows:
        why = 'the done-when results have no line for it'
    elif any(r['other'] for r in rows):
        why = 'part of it is judged or not run, and no byte comparison covers that part'
    for r in rows if why is None else []:
        cmd, o = '\n'.join(r['cmd']), base.get(r['line'])
        if any(p in cmd for p in outside) or HOME_RE.search(cmd):
            why = 'line %d names a path outside the checkout, so both runs read the same files' % r['line']
        elif r['late'] or (o and o['late']):
            why = 'line %d timed out' % r['line']
        elif o is None or o['rc'] is None:
            why = 'line %d did not run on %s' % (r['line'], ref)
        elif (o['rc'], o['sha']) != (r['rc'], r['sha']):
            why = 'line %d: exit %s · sha256 %s here, exit %s · sha256 %s on %s' % (r['line'], r['rc'], r['sha'], o['rc'], o['sha'], ref)
        if why:
            break
    if why:
        body.append('§4.%d · not proven — %s' % (n, why))
    else:
        proven += 1
        body.append('§4.%d · proven — every command exits and prints byte-identically on %s' % (n, ref))
    for r in rows:
        if r['rc'] is not None:
            body.append('  line %d · exit %s · sha256 %s here' % (r['line'], r['rc'], r['sha']))
            body.append('  $ ' + (r['cmd'][0] if r['cmd'] else ''))
count = '%d of %d items proven on %s' % (proven, len(want), ref)
stamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
with open(out + '.tmp', 'w', encoding='utf-8') as f:
    f.write('# pre-existing proof · %s · revision %s · %s · head %s · %s %s\n%s\n%s\n'
            % (brief, revision, stamp, head_sha, ref, base_sha, count, '\n'.join(body)))
os.replace(out + '.tmp', out)
print('%s -> %s' % (count, out))
PY
}
if [ "$MODE" = "close" ]; then
  if [ "$DRY" = "1" ]; then
    [ -z "$PROVE" ] || PROOF_SUMMARY="§4.${PROVE//,/, §4.} would be re-run on a clean checkout of $(proof_base) before the session; proof -> $OUT_PREEXISTING"
  elif [ -z "$PROVE" ]; then
    rm -f "$OUT_PREEXISTING"     # a proof belongs to the close it was run for
  elif [ -f "$OUT_REPORT" ]; then
    PROOF_TMP="$(mktemp -d)"
    PROOF_SUMMARY="$(proof_run)" || PROOF_SUMMARY="$(proof_none "the proof crashed")"
    printf 'pre-existing: %s\n' "$PROOF_SUMMARY" >&2
  fi
fi
# The brief's §4, heading to the next § heading, for the close prompt.
dw_section() {
  awk '/^## §4([^0-9]|$)/ { p = 1; print; next } p && /^## §[0-9]/ { exit } p' "$BRIEF"
}
# Same 128 KiB argument limit as the review: past REVIEW_PROMPT_MAX bytes the results are
# left out and named by path instead — the close session runs on this host and can read it.
close_prompt() {   # $1 = wrapper text, ending at the COMPLETION REPORT marker
  local p results proof=""
  results="$(cat "$OUT_DONE_WHEN" 2>/dev/null || printf 'none: not run (%s)' "${DW_SUMMARY:-dry run}")"
  [ -z "$PROVE" ] || proof="
=== PRE-EXISTING PROOF ===
$(cat "$OUT_PREEXISTING" 2>/dev/null || printf 'none: %s' "${PROOF_SUMMARY:-dry run}")"
  p="$1
$(cat "$OUT_REPORT" 2>/dev/null || true)
=== BRIEF §4 ===
$(dw_section)
=== DONE-WHEN RESULTS ===
$results$proof"
  if [ "$(printf '%s' "$p" | wc -c)" -gt "$REVIEW_PROMPT_MAX" ]; then
    printf 'WARNING: report, §4 and results pass %s bytes — the close is pointed at %s instead\n' "$REVIEW_PROMPT_MAX" "$OUT_DONE_WHEN" >&2
    p="$1
$(cat "$OUT_REPORT" 2>/dev/null || true)
=== BRIEF §4 ===
$(dw_section)
=== DONE-WHEN RESULTS ===
omitted: the prompt would pass the 128 KiB argument limit. Read them with one call: cat '$OUT_DONE_WHEN'$proof"
  fi
  printf '%s' "$p"
}

# ---------------------------------------------------------------- prompt
if [ "$MODE" = "lesson" ]; then
  # A lesson note is a POSTMORTEM, not an instruction - it says what happened and what
  # it cost, and deliberately does not prescribe a fix. Sent raw it reads as background
  # context, and the session answers with "what would you like me to do". Verified
  # 2026-09-01: a lesson launched unwrapped made no changes and asked for a task.
  # So lesson mode needs its own imperative wrapper, exactly as review mode does.
  #
  # The wrapper NAMES /capture-lesson rather than improvising the task. That skill
  # owns the routing ladder - hook rule with both-direction tests,
  # then verify-local.sh, then an AGENTS.md trap, then a skill, then "none of these".
  # A wrapper that says "find the cheapest lever yourself" skips the ladder: on
  # 2026-09-01 that produced a straight config edit that never considered a guard or a
  # test case. Same shape as review mode naming /handoff-review.
  WRAPPER="This is a task, not background reading. Below the marker is a postmortem of a friction point that has cost real time in this repo. Run the /capture-lesson skill against it, and no other skill before it - that skill owns the decision of where a lesson belongs. If /capture-lesson is not available here, say so plainly in your report and then do the equivalent yourself. Before changing anything, investigate how the thing actually works today and test the mechanism the note claims rather than trusting it - the note is one person reading of a failure and has been wrong before. Constraints. Write no planning or report .md file into this repo. Make one focused commit on the current branch. Do not merge and do not push to dev or main. Report what you changed, what you verified, and what you deliberately left alone. === LESSON ==="
  PROMPT="$WRAPPER
$(cat "$NOTE_FILE")"
elif [ "$MODE" = "resume" ]; then
  PROMPT="$(cat "$NOTE_FILE")"
elif [ "$MODE" = "revise" ]; then
  # The vault session can resolve vault paths, so the file is passed by path, not
  # inlined. `unattended` is the skill's own flag: no questions, outcome written to the
  # review file, state moved only when the review said RUN or REVISE.
  PROMPT="/handoff-revise $SUB ${OUT_REVIEW#"$VAULT"/} unattended"
elif [ "$MODE" = "debrief" ]; then
  PROMPT="/debrief $SUB ${OUT_REPORT#"$VAULT"/} unattended"
elif [ "$MODE" = "review" ] && [ "$BACKEND" = "devin" ]; then
  # Same discipline as the claude wrapper, plus the one thing devin adds: its skills are
  # global (~/.agents/skills, ~/.config/devin/skills) or project (.devin/skills,
  # .agents/skills), so /handoff-review can be absent on a host that was never set up for
  # it. Naming the fallback keeps a missing skill from turning into a silently different
  # review with an unparseable block.
  WRAPPER="DO NOT IMPLEMENT ANYTHING. The text below the BRIEF UNDER REVIEW marker is a DRAFT brief, for review only. Run the /handoff-review skill against it, and no other skill before it. If /handoff-review is not available in this session, say so plainly in one line and then produce the same review block yourself. You have no write access in this session: do not attempt edits, commits or branch changes. Batch your read commands into one exec call per turn — never a lone cd or ls. The two blocks before the brief are checks already run on it: verify their findings, do not rediscover them."
  PROMPT="$(review_prompt "$WRAPPER")"
elif [ "$MODE" = "review" ]; then
  if [ "$BACKEND" = "hermes" ]; then
    # The hermes `review` profile is self-contained: no /handoff-review skill exists
    # there (it is a bare read-only lens whose SOUL defines the block format). A wrapper
    # that names /handoff-review would make the bare profile misbehave, so on hermes the
    # brief goes raw — the SOUL supplies the discipline.
    PROMPT="$(cat "$BRIEF")"
  else
    WRAPPER="DO NOT IMPLEMENT ANYTHING. The text below the BRIEF UNDER REVIEW marker is a DRAFT brief, for review only. Run the /handoff-review skill against it, and no other skill before it. Make no edits, no commits, no branch changes, no installs. Batch your read commands into ONE Bash call per turn — never a lone cd or ls. The two blocks before the brief are checks already run on it: verify their findings, do not rediscover them."
    PROMPT="$(review_prompt "$WRAPPER")"
  fi
elif [ "$MODE" = "close" ] && [ "$BACKEND" = "devin" ]; then
  # The close STAGE is an audit of a finished run — not the run's own last act, which is
  # /handoff-close and emits a COMPLETION REPORT. Devin has no profile SOUL to carry that
  # distinction, so the block format is inlined here rather than pointed at. It must not
  # write, and it must not re-run the work: it checks the report against the repo.
  WRAPPER="Below the markers are the COMPLETION REPORT of a handoff run, the brief's §4 Done-when, and the DONE-WHEN RESULTS: every §4 command the launcher could read, re-run in this repo after the run reported, each with its exit code and the last 40 lines of its output. Audit the run against the repo you are rooted in. Judge each result against the criterion its §4 item states, and do not re-run a command that has a result. Check every §4 item the results mark judged or not run yourself, one command per exec call. Then verify the report's other claims (diff, commits, scope) rather than taking them on faith, and confirm a coherent leaving state. You have NO write access in this session: make no edits, no commits, no branch changes. Do not re-run the implementation. Finish with exactly this machine-readable block, and nothing after it.

=== CLOSE AUDIT ===
VERDICT: PASS | FAIL
CLASS: none | fixable | accept? | decision
REPORT_REVISION: <the brief-revision echoed in the completion report being audited>
FINDINGS:
- <§4.n, for a §4 item> <claim checked> — <confirmed | refuted | unconfirmed | pre-existing? | out-of-scope> — <evidence: a result's exit code and output line, a command you ran and its output, or path:line>
=== END CLOSE AUDIT ===

Every §4 item gets one finding, which starts with its label exactly as the results print it: §4.<n>, the n-th numbered item of §4. A finding about anything else carries no label. A result whose exit code or output contradicts its criterion is refuted, and so is a command that timed out. A result that does not show what its criterion names is unconfirmed: say what is missing. A claim you could not check is 'unconfirmed', never 'confirmed'. The one exception is a claim about something outside this repo and this host, such as remote devices, other machines or people: mark it 'out-of-scope', with the reason as evidence. A command that was denied, failed or was not run is never out-of-scope, unless a PRE-EXISTING PROOF after the results marks its item proven: then it is out-of-scope, with the proof line as evidence, and an item the proof marks not proven is refuted. Mark a §4 finding pre-existing? instead of refuted only when the report or the output says its check fails on the base branch too, and the brief's tasks do not change what it checks, as with a test suite, a linter or a type check. Never for a check of something the brief asks the run to build: the base lacks that work by design. pre-existing? is a claim, not a pass: the launcher re-runs that item on a clean checkout of the base before the next close. Anything refuted, left unconfirmed or pre-existing? means FAIL. out-of-scope findings do not. CLASS is none on a PASS. On a FAIL it names what the failure needs: fixable when redoing part of the brief's own tasks would clear it, accept? when the work may stand as it is and a human should judge the failing claim, decision when clearing it needs a choice the brief does not make. CLASS leaves pre-existing? findings out: when they are the only failing ones, it is accept?. === COMPLETION REPORT ==="
  PROMPT="$(close_prompt "$WRAPPER")"
elif [ "$MODE" = "close" ]; then
  # The close STAGE is an audit of a finished run — not the run's own last act, which is
  # /handoff-close and emits a COMPLETION REPORT. Claude has no per-profile SOUL the way
  # hermes does (close/SOUL.md), so a prompt that only said "emit the CLOSE AUDIT block
  # your role defines" had no role to point at: the session matched the /handoff-close
  # skill on the wording instead (it explicitly refuses to be substituted) and re-emitted
  # a second COMPLETION REPORT, which the parser below never finds. Inlined here instead,
  # same as the devin branch above.
  WRAPPER="Below the markers are the COMPLETION REPORT of a handoff run, the brief's §4 Done-when, and the DONE-WHEN RESULTS: every §4 command the launcher could read, re-run in this repo after the run reported, each with its exit code and the last 40 lines of its output. Audit the run against the repo you are rooted in. Judge each result against the criterion its §4 item states, and do not re-run a command that has a result. Check every §4 item the results mark judged or not run yourself, one command per Bash call. Then verify the report's other claims (diff, commits, scope) rather than taking them on faith, and confirm a coherent leaving state. Make no edits, no commits, no branch changes. Do not re-run the implementation. Do not invoke /handoff-close or any other completion-report skill — this is an audit of one, not another one. Finish with exactly this machine-readable block, and nothing after it.

=== CLOSE AUDIT ===
VERDICT: PASS | FAIL
CLASS: none | fixable | accept? | decision
REPORT_REVISION: <the brief-revision echoed in the completion report being audited>
FINDINGS:
- <§4.n, for a §4 item> <claim checked> — <confirmed | refuted | unconfirmed | pre-existing? | out-of-scope> — <evidence: a result's exit code and output line, a command you ran and its output, or path:line>
=== END CLOSE AUDIT ===

Every §4 item gets one finding, which starts with its label exactly as the results print it: §4.<n>, the n-th numbered item of §4. A finding about anything else carries no label. A result whose exit code or output contradicts its criterion is refuted, and so is a command that timed out. A result that does not show what its criterion names is unconfirmed: say what is missing. A claim you could not check is 'unconfirmed', never 'confirmed'. The one exception is a claim about something outside this repo and this host, such as remote devices, other machines or people: mark it 'out-of-scope', with the reason as evidence. A command that was denied, failed or was not run is never out-of-scope, unless a PRE-EXISTING PROOF after the results marks its item proven: then it is out-of-scope, with the proof line as evidence, and an item the proof marks not proven is refuted. Mark a §4 finding pre-existing? instead of refuted only when the report or the output says its check fails on the base branch too, and the brief's tasks do not change what it checks, as with a test suite, a linter or a type check. Never for a check of something the brief asks the run to build: the base lacks that work by design. pre-existing? is a claim, not a pass: the launcher re-runs that item on a clean checkout of the base before the next close. Anything refuted, left unconfirmed or pre-existing? means FAIL. out-of-scope findings do not. CLASS is none on a PASS. On a FAIL it names what the failure needs: fixable when redoing part of the brief's own tasks would clear it, accept? when the work may stand as it is and a human should judge the failing claim, decision when clearing it needs a choice the brief does not make. CLASS leaves pre-existing? findings out: when they are the only failing ones, it is accept?. === COMPLETION REPORT ==="
  PROMPT="$(close_prompt "$WRAPPER")"
elif [ "$MODE" = "run" ] && [ "$BACKEND" = "hermes" ]; then
  # The hermes run profile's SOUL ends with "run /handoff-close", but no such skill exists
  # in that profile (the repos carry it for claude only). The first two real hermes runs
  # (2026-09-22) therefore printed the marker, a code fence and free prose: no outcome:,
  # audit: or NOT DONE lines, so the post-run check failed on work that had in fact landed.
  # The block is inlined here, the way the close wrapper inlines the audit block.
  WRAPPER="Below the marker is your brief. Do the work it describes, then END with the completion report below — printed as plain text, not inside a code fence, with every field present, nothing after the END marker. If /handoff-close is not available in this session, say so in one line before the block and write the block yourself.

=== COMPLETION REPORT ===
brief-revision: <the revision: from the brief's frontmatter>
repo: <repo dir name>   branch: <branch>   tree: clean | dirty
audit: <n> checked, <n> refuted, <n> unconfirmed
outcome: COMPLETE | PARTIAL | BLOCKED
--- DONE ---
- <task> — <commit sha> — evidence: <command and its output>
--- DIVERGED ---
- <where you departed from the brief and why> | - none
--- BRIEF WAS WRONG ---
- <a claim in the brief the repo contradicted> | - none
--- NOT DONE ---
- <task asked of the run, not done, and why> | - none
--- STATE AT STOP ---
<branch, commits ahead, tree state, PR state>
--- VERIFICATION RUN ---
<each test/build/lint command re-run at the end, with exit code and its last line>
--- PAIN POINTS ---
- <friction worth a lesson> | - none
=== END COMPLETION REPORT ===

The audit: line counts claims you re-checked yourself just before writing the report; a claim you did not re-check is unconfirmed. outcome: COMPLETE only when every Done-when in the brief holds and NOT DONE is '- none'. === BRIEF ==="
  PROMPT="$RUN_RULES

$WRAPPER
$(cat "$BRIEF")"
else
  PROMPT="$RUN_RULES

=== BRIEF ===
$(cat "$BRIEF")"
fi

# ---------------------------------------------------------------- argv
# Order is load-bearing: every flag, then `--`, then the prompt LAST. Two separate
# failures forced this, and `--` is the one thing that fixes both.
#
#   1. A brief begins with YAML frontmatter, so the prompt's first characters are `---`.
#      Passed as a bare positional, the parser reads that as an option and dies with
#      `error: unknown option '---`. The review escaped it only because its wrapper text
#      sits in front of the frontmatter.
#   2. `--disallowedTools` and `--allowedTools` are variadic. Put them before a bare
#      positional prompt and they swallow it word by word as tool names.
#
# `--` ends option parsing outright, so a variadic flag cannot reach past it and a
# leading `---` is just text. Verified both ways against 2.1.245.
ARGS=()
AGENT_BIN=""
if [ "$BACKEND" = "hermes" ]; then
  # Hermes backend. The brief's review-session/run-session blocks
  # record Claude-isms (model/effort/permission-mode/disallowed-tools); Hermes has no
  # per-stage effort knob or per-tool write denial — model and posture are pinned per
  # profile instead. So none of CFG_* is passed
  # through; the profile is the unit of configuration.
  case "$MODE" in
    run|resume)  PROFILE="run" ;;
    review)      PROFILE="review" ;;
    close)       PROFILE="close" ;;
    *)           PROFILE="default" ;;   # revise/debrief/lesson are vault stages
  esac
  if [ -n "$CFG_EFFORT$CFG_PERM$CFG_DISALLOWED" ]; then
    printf 'NOTE: hermes backend ignores brief session config (effort/perm/disallowed) — profile %s pins it.\n' "$PROFILE" >&2
  fi
  AGENT_BIN="$HERMES_BIN"
  # The profile's own model is the default. A --model on the command line is passed as
  # hermes -m and wins; the brief's model (a Claude name like opus) is never passed.
  if [ "$PROFILE" = "default" ]; then _hcfg="$HOME/.hermes/config.yaml"; else _hcfg="$HOME/.hermes/profiles/$PROFILE/config.yaml"; fi
  PROFILE_MODEL="$(awk '/^model:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^  default:/{sub(/^  default:[ ]*/,"");print;exit}' "$_hcfg" 2>/dev/null || true)"
  if [ -n "$MODEL_ARG" ]; then EFFECTIVE_MODEL="$MODEL_ARG"; else EFFECTIVE_MODEL="${PROFILE_MODEL:-<profile default>}"; fi
  # A run leaves commits, so it is the one stage that cannot be retried blind,
  # and free-tier models are the ones that give up mid-task: the first plan's two
  # `meituan/longcat-2.0:free` runs died `agent_close` with no report and a third wrote no
  # report fields (2026-09-21/22). Refused unless the human says so per launch.
  case "$MODE:$EFFECTIVE_MODEL" in
    run:*:free|resume:*:free)
      [ "${HANDOFF_ALLOW_FREE_RUN:-0}" = "1" ] || die "run stage on a free-tier model ($EFFECTIVE_MODEL) — pass --model <paid model> or HANDOFF_ALLOW_FREE_RUN=1 to insist" ;;
    *:*:free) printf 'NOTE: %s stage on a free-tier model (%s) — stateless, retried once if it dies.\n' "$MODE" "$EFFECTIVE_MODEL" >&2 ;;
  esac
  # Hermes selects the profile with -p, not --profile, and takes the prompt as a
  # -z VALUE. So there is no `--` ordering game and no per-tool write flag: the
  # profile is the whole unit of configuration.
  # -p must come before -z (both are top-level flags, argparse is order-strict here).
  ARGS+=(-p "$PROFILE")
  [ -n "$MODEL_ARG" ] && ARGS+=(-m "$MODEL_ARG")
  # Hermes restores the profile's last recorded working directory on start, so a close
  # profile whose previous session sat in the vault audits the vault: the first two real
  # hermes close audits (2026-09-22) refuted every claim against the vault's git log
  # while the commits sat in the repo. --in pins the directory and skips that restore.
  if [ "$MODE" = "revise" ] || [ "$MODE" = "debrief" ]; then ARGS+=(--in "$VAULT"); else ARGS+=(--in "$BRIEF_REPO"); fi
  ARGS+=(-z "$PROMPT")
  [ "$MODE" = "resume" ] && ARGS+=(--resume "$SESSION")
elif [ "$BACKEND" = "claude" ]; then
  [ "$MODE" = "resume" ] && ARGS+=(--resume "$SESSION")
  SETTINGS_NOTE="none"
  ENV_NOTE=""
  GUARD_PATH=""
  HEADLESS=0
  if [ "$MODE" = "review" ] || [ "$MODE" = "close" ] || [ "$DELEGATE" = "1" ]; then
    HEADLESS=1
    ARGS+=(-p)
    export "${HEADLESS_ENV[@]}"
    ENV_NOTE="${HEADLESS_ENV[*]}"
    # Default `-p` output is text, buffered and printed only at the end — a backgrounded
    # session therefore shows an empty file for its whole run, which reads exactly like a
    # stall. stream-json emits events as they arrive, at the cost of JSONL the caller must
    # unpack.
    [ "$STREAM" = "1" ] && ARGS+=(--output-format stream-json --verbose --include-partial-messages)
    # No -p session watches a background wait notification — the guard (§3.3) refuses
    # one at the tool level. Read live from the kit, not the driver's snapshot: a kit
    # without guards/ skips the hook rather than blocking every headless Bash call.
    GUARD_PATH="$KIT/guards/no-background-wait.py"
    if [ -f "$GUARD_PATH" ]; then
      CFG_DISALLOWED="$(merge_csv "$CFG_DISALLOWED" "$HEADLESS_DENY")"
    else
      printf 'NOTE: no background-wait guard at %s — headless Bash calls are not protected against a background wait.\n' "$GUARD_PATH" >&2
      GUARD_PATH=""
    fi
  fi
  # Stage isolation: the operator's claude.ai connectors and user-scope plugins are set up
  # for their own interactive work, and an unattended stage must not reach a shared
  # service through them (nor pay their tool and skill descriptions on every turn). The
  # connectors go off by environment; the plugins go off by a --settings map that leaves
  # out what the stage's own project enables, since --settings outranks project settings.
  export ENABLE_CLAUDEAI_MCP_SERVERS=false
  ENV_NOTE="${ENV_NOTE:+$ENV_NOTE }ENABLE_CLAUDEAI_MCP_SERVERS=false"
  if [ "$MODE" = "revise" ] || [ "$MODE" = "debrief" ]; then STAGE_DIR="$VAULT"; else STAGE_DIR="$BRIEF_REPO"; fi
  # Line 1: the stage's one settings JSON, empty when there is nothing to put in it.
  # Line 2: the plugin keys it turns off, comma-joined.
  STAGE_CFG="$(python3 - "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" "$STAGE_DIR/.claude/settings.json" "$STAGE_DIR/.claude/settings.local.json" "$GUARD_PATH" <<'PY'
import json, shlex, sys
user, proj, local, guard = sys.argv[1:5]

def plugins(path, report):
    try:
        with open(path, encoding="utf-8") as f:
            m = json.load(f).get("enabledPlugins", {})
        if not isinstance(m, dict):
            raise ValueError("enabledPlugins is not a map")
        return m
    except FileNotFoundError:
        return {}
    except Exception as e:
        if report:
            print("NOTE: cannot read %s (%s) - user plugins stay as they are." % (path, e), file=sys.stderr)
        return {}

enabled = {k for k, v in plugins(user, True).items() if v is True}
stage = plugins(proj, False)
stage.update(plugins(local, False))
off = sorted(k for k in enabled if stage.get(k) is not True)
cfg = {}
if guard:
    cfg["hooks"] = {"PreToolUse": [{"matcher": "Bash",
                                    "hooks": [{"type": "command", "command": "python3 " + shlex.quote(guard)}]}]}
if off:
    cfg["enabledPlugins"] = {k: False for k in off}
print(json.dumps(cfg) if cfg else "")
print(",".join(off))
PY
)" || STAGE_CFG=""
  STAGE_JSON="$(printf '%s\n' "$STAGE_CFG" | sed -n '1p')"
  PLUGINS_OFF="$(printf '%s\n' "$STAGE_CFG" | sed -n '2p')"
  if [ -n "$STAGE_JSON" ]; then
    if [ "$HEADLESS" = "1" ]; then
      SETTINGS_FILE="$(mktemp)"
      printf '%s' "$STAGE_JSON" >"$SETTINGS_FILE"
      ARGS+=(--settings "$SETTINGS_FILE")
      SETTINGS_NOTE="$SETTINGS_FILE"
    else
      # A watched run exec()s claude, so no EXIT trap would remove a temp file: inline JSON.
      ARGS+=(--settings "$STAGE_JSON")
      SETTINGS_NOTE="inline"
    fi
  fi
  [ -n "$CFG_MODEL" ]      && ARGS+=(--model "$CFG_MODEL")
  [ -n "$CFG_EFFORT" ]     && ARGS+=(--effort "$CFG_EFFORT")
  [ -n "$CFG_PERM" ]       && ARGS+=(--permission-mode "$CFG_PERM")
  [ -n "$CFG_DISALLOWED" ] && ARGS+=(--disallowedTools "$CFG_DISALLOWED")
  ARGS+=(--name "$MODE $(basename "$BRIEF" .md) $BRIEF_REVISION")
  # A session id of its own for every claude stage but resume (§3.5): resume continues
  # the earlier session (--resume), and the CLI only takes a new id alongside --resume
  # with --fork-session, which would start a new session instead of continuing the old
  # one and would double-count the earlier stage's transcript.
  if [ "$MODE" != "resume" ]; then
    SESSION_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    ARGS+=(--session-id "$SESSION_ID")
  fi
  ARGS+=(-- "$PROMPT")
  AGENT_BIN="$CLAUDE_BIN"
  EFFECTIVE_MODEL="${CFG_MODEL:-<machine default>}"
elif [ "$BACKEND" = "devin" ]; then
  # Headless means nobody can answer a prompt, and devin auto-denies rather than hanging —
  # so `accept-edits` (the brief's default) would approve edits and leave every `exec`
  # denied, which is a review that cannot run `git status` to check the claims it judges.
  # Every stage the launcher drives unattended is therefore `dangerous`, with the read-only
  # stages held back by their skill's own tool access instead. A *watched* run keeps the
  # brief's posture, mapped into devin's vocabulary, because there the prompts are the point.
  case "$MODE" in
    run) if [ "$DELEGATE" = "1" ]; then DV_HEADLESS=1; else DV_HEADLESS=0; fi ;;
    *)   DV_HEADLESS=1 ;;
  esac
  if [ "$DV_HEADLESS" = "1" ]; then
    DV_PERM=dangerous
  else
    DV_PERM="$(dv_perm "$CFG_PERM")"
  fi
  [ -n "$DV_MODEL" ] && ARGS+=(--model "$DV_MODEL")
  [ -n "$DV_CONFIG" ] && ARGS+=(--config "$DV_CONFIG")
  ARGS+=(--permission-mode "$DV_PERM")
  [ "$MODE" = "resume" ] && ARGS+=(-r "$SESSION")
  if [ "$DV_HEADLESS" = "1" ]; then
    # Non-interactive mode cannot show the workspace-trust prompt and fails closed in a
    # directory it has not been trusted in, so a script must skip the check — same
    # trade-off as the permission mode above, and the same note applies: this is a
    # first-run-through-a-pipe question, not a security boundary.
    ARGS+=(--respect-workspace-trust false)
    ARGS+=(-p)
    # The prompt goes through a FILE. --print's inline value is optional, and the brief
    # opens with `---` frontmatter, so a positional prompt would need `--` in front of it
    # and would still be the whole brief on the command line. --prompt-file has neither
    # problem and no size limit.
    PROMPT_FILE="$DV_TMP/prompt-$MODE.txt"
    printf '%s' "$PROMPT" >"$PROMPT_FILE"
    ARGS+=(--prompt-file "$PROMPT_FILE")
  else
    # The REPL takes its opening message positionally, after `--` so that a leading `---`
    # is text and not an option — the same fix, for the same reason, as the claude branch.
    ARGS+=(-- "$PROMPT")
  fi
  AGENT_BIN="$DEVIN_BIN"
  EFFECTIVE_MODEL="${DV_MODEL:-<devin default>}"
fi

# One line, every launch, dry or not: which agent and which model this stage gets.
# The reason --backend/--model exist is that this used to be invisible until a
# process listing was read.
if [ "$BACKEND" = "hermes" ]; then
  printf 'LAUNCH %s: backend=hermes profile=%s model=%s%s\n' "$MODE" "$PROFILE" "$EFFECTIVE_MODEL" "${MODEL_ARG:+ (from --model)}" >&2
elif [ "$BACKEND" = "devin" ]; then
  printf 'LAUNCH %s: backend=devin model=%s%s%s perm=%s\n' "$MODE" "$EFFECTIVE_MODEL" "${MODEL_ARG:+ (from --model)}" "${DV_MODEL_NOTE:+ [$DV_MODEL_NOTE]}" "$DV_PERM" >&2
else
  printf 'LAUNCH %s: backend=claude model=%s%s effort=%s\n' "$MODE" "$EFFECTIVE_MODEL" "${MODEL_ARG:+ (from --model)}" "${CFG_EFFORT:-<default>}" >&2
fi

# Every Bash call restarts in the dir cd'd to below: a persisted bare `cd` let "prints nothing" greps pass vacuously.
[ "$BACKEND" = "claude" ] && export CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR=1

if [ "$MODE" = "revise" ] || [ "$MODE" = "debrief" ]; then
  cd "$VAULT"      # a vault skill is only visible to a session rooted in the vault
else
  cd "$BRIEF_REPO"
  # Repo stage: arm the commit-attribution hooks (see install_git_hooks). Vault stages
  # (revise/debrief) are excluded on purpose — the vault's own auto-commits stay plain.
  case "$BACKEND" in claude) HANDOFF_HARNESS=claude-code ;; *) HANDOFF_HARNESS="$BACKEND" ;; esac
  HANDOFF_MODEL="$EFFECTIVE_MODEL"
  export HANDOFF_HARNESS HANDOFF_MODEL
  # Quiet pytest everywhere but the vault stages (§3.7): -q keeps the summary line,
  # --tb=short drops the locals that carried a password in one repo's long traceback.
  export PYTEST_ADDOPTS="${PYTEST_ADDOPTS:+$PYTEST_ADDOPTS }-q --tb=short"
  install_git_hooks "$BRIEF_REPO"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS_DIR"
  if [ "$BACKEND" = "claude" ] && ! grep -q '"includeCoAuthoredBy": *false' "$HOME/.claude/settings.json" 2>/dev/null; then
    printf 'NOTE: ~/.claude/settings.json lacks "includeCoAuthoredBy": false — the hook strips the line anyway, but set it so claude stops offering it.\n' >&2
  fi
fi

if [ "$DRY" = "1" ]; then
  printf 'DRY RUN — nothing launched\n'
  printf '  mode:        %s\n' "$MODE"
  printf '  brief:       %s\n' "$BRIEF"
  printf '  revision:    %s\n' "$BRIEF_REVISION"
  printf '  handoff:     %s\n' "$BRIEF_HANDOFF"
  printf '  repo:        %s\n' "$BRIEF_REPO"
  printf '  cwd:         %s\n' "$(pwd)"
  printf '  branch now:  %s  (brief expects %s)\n' "$(git branch --show-current 2>/dev/null)" "$BRIEF_BRANCH"
  printf '  tree:        %s changed\n' "$(git status --short 2>/dev/null | wc -l)"
  printf '  model:       %s   effort: %s   perm: %s\n' "$EFFECTIVE_MODEL" "$CFG_EFFORT" "$CFG_PERM"
  printf '  disallowed:  %s\n' "${CFG_DISALLOWED:-<none>}"
  [ "$BACKEND" = "claude" ] && printf '  settings:    %s\n' "${SETTINGS_NOTE:-none}"
  [ "$BACKEND" = "claude" ] && printf '  env:         %s\n' "${ENV_NOTE:-none}"
  [ "$BACKEND" = "claude" ] && printf '  plugins off: %s\n' "${PLUGINS_OFF:-none}"
  printf '  backend:     %s\n' "$BACKEND"
  if [ -n "${HANDOFF_HARNESS:-}" ]; then
    printf '  trailers:    Harness: %s   Model: %s   (hooks: %s, chaining the repo'"'"'s own)\n' "$HANDOFF_HARNESS" "$HANDOFF_MODEL" "$HOOKS_DIR"
  fi
  if [ "$BACKEND" = "hermes" ]; then
    printf '  hermes:      %s   profile: %s (profile model: %s)\n' "$HERMES_BIN" "${PROFILE:-<none>}" "${PROFILE_MODEL:-?}"
  elif [ "$BACKEND" = "devin" ]; then
    printf '  devin:       %s\n' "$DEVIN_BIN"
    printf '  devin model: %s   %s\n' "${DV_MODEL:-<CLI default>}" "${DV_MODEL_NOTE:-}"
    printf '  devin perm:  %s   headless: %s (trust check skipped when headless)\n' "${DV_PERM:-?}" "${DV_HEADLESS:-?}"
    [ -n "$DV_CONFIG" ] && printf '  devin config:%s (%s)\n' "$DV_CONFIG" "$DV_CONFIG_NOTE"
    if [ "${DV_HEADLESS:-0}" = "1" ]; then
      printf '  devin argv:  %s\n' "${ARGS[*]}"
      printf '  prompt file: %s  (%s bytes, removed on exit)\n' "$PROMPT_FILE" "${#PROMPT}"
    fi
  else
    printf '  claude:      %s\n' "$CLAUDE_BIN"
  fi
  printf '  prompt:      %s bytes\n' "${#PROMPT}"
  if [ "$MODE" = "run" ]; then
    if [ "$DELEGATE" = "1" ]; then
      printf '  session:     HEADLESS — unattended, prompts auto-denied, no interjection\n'
      printf '  writes:      %s, then handoff: running -> reported\n' "$OUT_REPORT"
    else
      printf '  session:     interactive — needs a TTY: run it in a terminal\n'
      printf '  writes:      handoff: -> running. The report comes back by paste (/debrief %s)\n' "$SUB"
    fi
  fi
  [ "$MODE" = "review" ]  && printf '  writes:      %s, then handoff: -> reviewed\n' "$OUT_REVIEW"
  [ "$MODE" = "review" ]  && printf '  brief-check: %s (exit %s) — a FAIL stops the review before its session; report -> %s\n' "${CHECK_RESULT:-<no RESULT line>}" "$CHECK_RC" "$OUT_CHECK"
  [ "$MODE" = "close" ]   && printf '  session:     HEADLESS repo session, cwd %s\n  reads:       %s (inlined into the prompt)\n  writes:      %s, handoff unchanged (close audits; debrief closes)\n' "$BRIEF_REPO" "$OUT_REPORT" "$OUT_CLOSE"
  [ "$MODE" = "close" ]   && printf '  done-when:   %s\n' "$DW_SUMMARY"
  [ -n "$PROVE" ]         && printf '  prove:       %s\n' "$PROOF_SUMMARY"
  [ "$MODE" = "revise" ]  && printf '  session:     HEADLESS vault session, cwd %s\n  reads:       %s\n  writes:      the brief (bumped), Revise outcome appended to the review file, handoff: -> ready\n' "$VAULT" "$OUT_REVIEW"
  [ "$MODE" = "debrief" ] && printf '  session:     HEADLESS vault session, cwd %s\n  reads:       %s\n  writes:      current.md, context.md frontmatter, Debrief outcome appended to the report file, handoff: -> closed\n' "$VAULT" "$OUT_REPORT"
  if [ "$MODE" = "review" ] || [ "$DELEGATE" = "1" ]; then
    if [ "$STREAM" = "1" ]; then
      printf '  output:      stream-json — fills live, readable while it runs\n'
    else
      printf '  output:      text — buffered, the file stays empty until it exits\n'
    fi
  fi
  # The proof that matters: intact means ONE argv element. Word-split means hundreds,
  # which is the failure that once executed a brief as shell script.
  printf '  argc:        %s  (prompt is the final arg, after --, whole)\n' "${#ARGS[@]}"
  exit 0
fi

# Every claude stage's session id, where the loop can read it: the fix-up resumes the
# run's own session by this id. One line per launch, `<UTC time> <mode> <session id>`;
# resume logs the id it continues. hermes and devin pick their own ids, so they log
# nothing here and never get a fix-up.
if [ "$BACKEND" = "claude" ]; then
  printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$MODE" "${SESSION_ID:-$SESSION}" >>"$OUT_SESSIONS" 2>/dev/null || true
fi

# An interactive run owns the terminal — hand the process over and stop here. The state
# moves first: the launcher is the one process that knows a run actually started, and
# `/handoff-status` reads exactly this field to tell "waiting on you" from "waiting on
# an agent".
if [ "$MODE" = "run" ] && [ "$DELEGATE" != "1" ]; then
  set_state running
  exec "$AGENT_BIN" "${ARGS[@]}"
fi

if [ "$MODE" = "lesson" ]; then
  # A lesson produces a repo change, not a parseable block, so there is nothing to
  # recover and stdout is the whole answer. Read the DIFF it left, not this summary:
  # both lessons run on 2026-08-25 described their own changes accurately, but a
  # summary is the session's account of itself either way.
  set +e
  "$AGENT_BIN" "${ARGS[@]}"
  RC=$?
  set -e
  usage_ledger
  exit "$RC"
fi

if [ "$MODE" = "revise" ] || [ "$MODE" = "debrief" ]; then
  # The vault skill writes its own outcome into the review/report file and moves the
  # state itself, so stdout is only its closing summary. Report whether the state moved:
  # that, not the prose, is what the loop checks next.
  set +e
  "$AGENT_BIN" "${ARGS[@]}"
  RC=$?
  set -e
  usage_ledger
  AFTER="$(read_state)"
  if [ "$MODE" = "revise" ]; then OUT_FILE="$OUT_REVIEW"; else OUT_FILE="$OUT_REPORT"; fi
  if [ "$AFTER" = "$BRIEF_HANDOFF" ]; then
    printf '\n[%s] %s: handoff still %s — the stage did not move it. Read the outcome section in %s for why.\n' "$MODE" "$(basename "$BRIEF")" "${AFTER:-<none>}" "$OUT_FILE" >&2
  else
    printf '\n[%s] %s: handoff %s -> %s. Outcome appended to %s\n' "$MODE" "$(basename "$BRIEF")" "$BRIEF_HANDOFF" "$AFTER" "$OUT_FILE" >&2
  fi
  exit "$RC"
fi

# ---------------------------------------------------------------- headless capture
# `claude -p` prints only the session's LAST assistant message. A fan-out review emits
# its block and then, as the parallel agents' wait timers expire, one or more trailing
# notes — so stdout ends up holding "Leftover timer. Nothing further." and the 17 KB
# review looks lost. It is not lost: it is in the session transcript. Observed on the
# first real run, and it will recur on every fan-out, so stdout is not trusted here.
# A delegated run has the same exposure: its report can be followed by trailing notes too.
if [ "$MODE" = "review" ]; then
  MARKER='=== HANDOFF REVIEW ==='
  OUT_FILE="$OUT_REVIEW"
  NEXT_STATE=reviewed
elif [ "$MODE" = "close" ]; then
  MARKER='=== CLOSE AUDIT ==='
  OUT_FILE="$OUT_CLOSE"
  NEXT_STATE=reported     # close audits; debrief owns reported -> closed
else
  MARKER='=== COMPLETION REPORT ==='
  OUT_FILE="$OUT_REPORT"
  NEXT_STATE=reported
  [ "$MODE" = "run" ] && set_state running
fi
STARTED_EXACT="$(date +%s.%N)"   # turns stamped before this are an earlier stage's
STARTED_AT="${STARTED_EXACT%.*}"
CAPTURE="$(mktemp)"

set +e
"$AGENT_BIN" "${ARGS[@]}" >"$CAPTURE" 2>&1
RC=$?
set -e
usage_ledger

# The one failure that looks like success: a stage rejected before it ran anything. Devin
# answers a model the account cannot reach with "Upgrade to Pro" and still exits 0, so this
# is named here rather than left to the no-marker warning below.
if grep -qF 'Upgrade to Pro to access this model' "$CAPTURE"; then
  printf 'NOTE: devin refused the model — this account tier does not include it. Launch without --model, or upgrade the plan.\n' >&2
fi

SOURCE=""
if grep -qF "$MARKER" "$CAPTURE"; then
  SOURCE=stdout
else
  # Claude Code names a project's transcript directory after its cwd with / -> -
  PROJ="$HOME/.claude/projects/$(printf '%s' "$BRIEF_REPO" | sed 's/[^A-Za-z0-9]/-/g')"
  RECOVERED="$(
    python3 - "$PROJ" "$STARTED_AT" "$MARKER" "$STARTED_EXACT" <<'PY'
import json, os, sys
from datetime import datetime
proj, started, marker, since = sys.argv[1], int(sys.argv[2]), sys.argv[3], float(sys.argv[4])
def stamp(ts):
    try:
        return datetime.fromisoformat(ts.replace('Z', '+00:00')).timestamp()
    except (AttributeError, ValueError):
        return None
if not os.path.isdir(proj):
    sys.exit(0)
cands = [os.path.join(proj, f) for f in os.listdir(proj) if f.endswith('.jsonl')]
cands = [p for p in cands if os.path.getmtime(p) >= started - 5]
best = None
for path in sorted(cands, key=os.path.getmtime, reverse=True):
    for line in open(path, encoding='utf-8'):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get('type') != 'assistant':
            continue
        # A resume appends to the transcript it continues: a report already in that file
        # is the earlier stage's, never this one's.
        t = stamp(row.get('timestamp'))
        if t is not None and t < since:
            continue
        for block in (row.get('message') or {}).get('content') or []:
            if isinstance(block, dict) and block.get('type') == 'text' \
               and marker in (block.get('text') or ''):
                best = block['text']          # keep the LAST match in the session
    if best:
        break
if best:
    print(best)
PY
  )"
  if [ -n "$RECOVERED" ]; then
    printf '%s\n' "$RECOVERED" >"$CAPTURE"
    SOURCE=transcript
    printf '(recovered from the session transcript — stdout held only the trailing message)\n' >&2
  fi
fi

if [ -z "$SOURCE" ]; then
  printf 'WARNING: no %s block found in stdout or in the transcript. Raw output follows.\n' "$MARKER" >&2
  printf '         handoff: left at %s. Nothing written to %s.\n' "$(read_state)" "$OUT_FILE" >&2
  cat "$CAPTURE"
  exit 1
fi

# Write from the marker line on, under one header that ties the file to its brief.
python3 - "$CAPTURE" "$OUT_FILE" "$MARKER" "$MODE" "$(basename "$BRIEF")" "$BRIEF_REVISION" "$SOURCE" "$(date +%F)" <<'PY'
import io, sys
cap, out, marker, mode, brief, rev, source, today = sys.argv[1:9]
text = io.open(cap, encoding='utf-8', errors='replace').read()
lines = text.splitlines()
i = next((n for n, l in enumerate(lines) if marker in l), 0)
head = f"<!-- handoff-launch.sh {mode} · brief: {brief} · revision: {rev} · {today} · source: {source} -->"
io.open(out, 'w', encoding='utf-8', newline='\n').write(head + '\n\n' + '\n'.join(lines[i:]).rstrip() + '\n')
PY
set_state "$NEXT_STATE"

# One line for the terminal — the block itself is on disk now, and printing 17 KB into
# whatever session launched this is the cost this file exists to avoid.
HEADLINE="$(grep -m1 -iE '^(verdict|result|outcome|status):' "$OUT_FILE" || true)"
printf 'WROTE %s (%s lines, from %s)%s\n' "$OUT_FILE" "$(wc -l <"$OUT_FILE")" "$SOURCE" "${HEADLINE:+ — $HEADLINE}"
exit "$RC"
