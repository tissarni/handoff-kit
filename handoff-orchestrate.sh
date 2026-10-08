#!/usr/bin/env bash
# Drive a phase of handoff briefs end-to-end with no human between gates.
#
#   handoff-orchestrate start  <plan> [--backend <b>] [--model <m>]
#       Pre-flight, record the repo baseline, take the lock, launch a detached driver
#       that runs `handoff-launch.sh loop <brief> --gate auto --backend <b>` for every
#       brief of the current phase, in order. The driver reads the loop's exit code and
#       the brief's handoff: field, applies the break and retry policy, writes every
#       transition to <plan>.status.md and <plan>.events.log, and
#       at the end of the phase writes the phase summary and notifies. Nothing runs in
#       parallel: brief k+1's review starts only after brief k is closed.
#   handoff-orchestrate tick   <plan>
#       Watchdog pass (systemd timer, 30 min; armed by start/resume, retired when the
#       last phase is done). Deterministic bash, never advances state: driver alive? current stage's
#       heartbeat and budget? kill the stalled stage (the driver then retries or breaks);
#       refresh the status header. A tick with nothing to report touches <plan>.tick and
#       exits 0.
#   handoff-orchestrate status <plan>
#       Print the first line of <plan>.status.md (RUNNING / NEEDS YOU / PAUSED / DONE).
#   handoff-orchestrate stop   <plan>
#       Kill the driver and the current stage, mark orchestration: paused, leave the
#       briefs as the launcher left them. Idempotent.
#   handoff-orchestrate resume <plan> [--backend <b>] [--model <m>]
#       Re-derive everything from disk, record a fresh baseline (the repo after the hand
#       fix), continue from the first brief not closed, from its current handoff: state.
#       Exactly one command after a fix at a break. A broken or paused phase whose
#       briefs are all closed has nothing left to run: resume ends it the way the driver
#       does (PHASE DONE, orchestration done|phase-done, the DONE status and its phase
#       summary) and launches nothing.
#
# Everything except the mode comes from the plan file's own frontmatter (schema:
# the vault's plan template), the same way handoff-launch.sh reads a brief. State
# lives on disk and nowhere else: each brief's handoff: field, the plan's orchestration:
# and phases[].status, and beside the plan:
#   <plan>.status.md    first line is the verdict a machine reads; the rest is for a human
#   <plan>.events.log   one line per transition, kill, retry, pause, break
#   <plan>.lock         "pid <driver pid> started <epoch> <date>" — a driver owns the repo
#   <checkout git dir>/handoff-plan.lock  "<plan path>" — the plan holding the checkout while running, paused or broken
#   <plan>.baseline     branch, head and dirty paths recorded at start/resume
#   <plan>.stage        "<brief> <loop pid> <epoch>" while a loop is live — what the tick watches
#   <plan>.driver.log   the driver's own stdout/stderr
#   <plan>.tick         touched by every tick
#   <plan>.lock.tick    the tick's flock file (removed with the lock)
#   <brief>.failed-<ts>.log · <brief>.killed-<ts>.log   a loop's output when it failed or was killed
#
# Branch flow: the plan branch is a feature branch cut from `base:` (plan field;
# default dev when origin has it, else main). The run stage pushes every commit as it lands
# and opens the draft PR; after each closed brief the driver pushes whatever the run left
# unpushed and opens the PR if none is open. start/resume put the repo on the plan branch
# themselves, cutting it from origin/<base> and pushing it when it does not exist yet — no
# human creates branches or PRs. The driver never merges and never pushes to a shared
# branch — a plan whose branch IS one is refused at parse time.
#
# Exit codes (read by the skill and by the timer unit):
#   0  ok / quiet tick / phase done / broke and said so
#   1  usage or state error (plan locked by a live driver, unknown command, ...)
#   2  start/resume pre-flight failed — nothing launched, the check named on stderr; a
#      refusal comes before any fetch or checkout, so the branch never moves first
#
# Roots (required): the vault, its defaults file and its projects directory.
#   VAULT                           the notes repo; a relative plan path is relative to it
#   HANDOFF_DEFAULTS                the defaults file, relative to VAULT
#   HANDOFF_PROJECTS                the projects directory; its next path segment is a
#                                   brief's main
#   Each comes from the environment, else from ~/.config/handoff/config.env; the script
#   stops when one is missing.
#
# Environment (optional):
#   HANDOFF_KIT                     the kit directory instead of this script's own (the
#                                   driver gets it, because its snapshot runs from
#                                   <plan>.driver/)
#   HANDOFF_LIMIT_WAIT              seconds to pause on a usage-limit message (default 1800)
#   HANDOFF_ORCH_ALLOW_CONCURRENT=1 skip the launcher stage scan only (same-checkout
#                                   detection is on by default: different repos or
#                                   worktrees are separate working trees and may run
#                                   in parallel; only a second launcher on the SAME
#                                   checkout is refused). The checkout lock still
#                                   applies: a plan never takes a checkout another
#                                   running, paused or broken plan holds.

set -euo pipefail

KIT="${HANDOFF_KIT:-$(cd "$(dirname "$(readlink -f "$0")")" && pwd)}"
# HANDOFF_LAUNCHER names a snapshot launcher (launch_driver): the driver
# runs a copy of both scripts so an edit mid-phase never reaches the currently running
# one. Read once, then unset — otherwise it would reach every claude stage session the
# driver starts, and a stage that runs `handoff-orchestrate.sh start` on another plan
# would pick up THIS plan's snapshot launcher.
LAUNCHER="${HANDOFF_LAUNCHER:-$KIT/handoff-launch.sh}"
unset HANDOFF_LAUNCHER

die()  { printf 'handoff-orchestrate.sh: %s\n' "$*" >&2; exit 1; }
die2() { printf 'handoff-orchestrate.sh: %s\n' "$*" >&2; exit 2; }

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

# ---------------------------------------------------------------- args
CMD="${1:-}"
[ -n "$CMD" ] || die "usage: handoff-orchestrate start|tick|stop|resume|status <plan> [--backend <b>] [--model <m>]"
PLAN_ARG="${2:-}"
[ -n "$PLAN_ARG" ] || die "no plan given"
case "$PLAN_ARG" in
  /*) PLAN="$PLAN_ARG" ;;
   *) PLAN="$VAULT/$PLAN_ARG" ;;
esac
[ -f "$PLAN" ] || die "plan not found: $PLAN"
BASE="${PLAN%.md}"
STATUS="$BASE.status.md"; EVENTS="$BASE.events.log"; LOCK="$BASE.lock"
BASELINE="$BASE.baseline"; STAGE_FILE="$BASE.stage"; DRIVER_LOG="$BASE.driver.log"
TICK_FILE="$BASE.tick"

BACKEND_ARG=""; MODEL_ARG=""; _next=""
for a in "${@:3}"; do
  case "$_next" in
    backend) BACKEND_ARG="$a"; _next=""; continue ;;
    model)   MODEL_ARG="$a";   _next=""; continue ;;
  esac
  case "$a" in
    --backend)   _next=backend ;;
    --model)     _next=model ;;
    --backend=*) BACKEND_ARG="${a#--backend=}" ;;
    --model=*)   MODEL_ARG="${a#--model=}" ;;
    *) die "unknown flag: $a" ;;
  esac
done
[ -z "$_next" ] || die "--$_next needs a value"

# ---------------------------------------------------------------- helpers
now_s() { date +%s; }
ts()    { date -d "@$1" '+%F %T'; }
log_event() { printf '%s %s\n' "$(ts "$(now_s)")" "$1" >>"$EVENTS"; }
fm_scalar() {  # $1 = file with frontmatter, $2 = key -> value or empty
  python3 - "$1" "$2" <<'PY'
import sys
path, key = sys.argv[1], sys.argv[2]
for l in open(path, encoding='utf-8').read().splitlines()[1:]:
    if l.strip() == '---': break
    if l.startswith(key + ':'):
        print(l.split(':', 1)[1].strip().strip('"\'')); break
PY
}
read_brief_state() { fm_scalar "$1" handoff; }
brief_repo()       { fm_scalar "$1" repo; }

# ---------------------------------------------------------------- plan read
# Minimal YAML frontmatter (flat keys, one nesting level, a list of maps for phases:),
# same parser philosophy as handoff-launch.sh. Emits shell-assignable lines.
plan_vars="$(python3 - "$PLAN" <<'PY'
import os, sys, shlex
path = sys.argv[1]
def parse(lines):
    root = {}; stack = [(-1, root)]; n = len(lines); i = 0
    while i < n:
        raw = lines[i]; i += 1
        if not raw.strip() or raw.lstrip().startswith('#'):
            continue
        ind = len(raw) - len(raw.lstrip()); line = raw.strip()
        if '#' in line and not line.startswith('#'):
            # strip a trailing comment (outside quotes; values here never contain '#')
            line = line.split(' #', 1)[0].rstrip()
        is_item = line.startswith('- ')
        if is_item: line = line[2:].strip()
        key, _, val = line.partition(':')
        key, val = key.strip(), val.strip().strip('"\'')
        while len(stack) > 1 and stack[-1][0] >= ind: stack.pop()
        parent = stack[-1][1]
        if is_item:
            child = {}; parent.append(child)
            if val == '':
                child[key] = {}; stack.append((ind, child[key]))
            else:
                child[key] = val; stack.append((ind, child))
        elif val == '':
            j = i; is_list = False
            while j < n:
                nxt = lines[j]
                if not nxt.strip() or nxt.lstrip().startswith('#'): j += 1; continue
                if len(nxt) - len(nxt.lstrip()) <= ind: break
                is_list = nxt.lstrip().startswith('- '); break
            child = [] if is_list else {}; parent[key] = child; stack.append((ind, child))
        else:
            parent[key] = val
    return root
lines = open(path, encoding='utf-8').read().splitlines()
if not lines or lines[0].strip() != '---': sys.exit('plan has no frontmatter')
end = next((i for i, l in enumerate(lines[1:], 1) if l.strip() == '---'), None)
if end is None: sys.exit('plan frontmatter is unterminated')
fm = parse(lines[1:end])
scalar = lambda k: fm.get(k, '') if isinstance(fm.get(k, ''), str) else ''
phase_s = scalar('phase')
try: phase_idx = int(phase_s) - 1 if phase_s else 0
except ValueError: phase_idx = 0
phases = fm.get('phases') if isinstance(fm.get('phases'), list) else []
phase = phases[phase_idx] if 0 <= phase_idx < len(phases) and isinstance(phases[phase_idx], dict) else {}
briefs_raw = phase.get('briefs', [])
if isinstance(briefs_raw, str):
    briefs_raw = [b for b in briefs_raw.replace('[', '').replace(']', '').split(',') if b.strip()]
briefs = []
for b in briefs_raw:
    b = str(b).strip().strip('"\'')
    if b: briefs.append(b if b.startswith('/') else os.path.join(os.path.dirname(path), b))
budgets = fm.get('budgets') if isinstance(fm.get('budgets'), dict) else {}
bget = lambda k: budgets.get(k, '') if isinstance(budgets.get(k, ''), str) and budgets.get(k, '').isdigit() else ''
out = {
  'PLAN_ORCH': scalar('orchestration'), 'PLAN_PHASE_IDX': str(phase_idx), 'PLAN_PHASE_COUNT': str(len(phases)),
  'PLAN_PHASE_NAME': phase.get('name') if isinstance(phase.get('name'), str) else f'phase {phase_s or 1}',
  'PLAN_PHASE_BRANCH': phase.get('branch') if isinstance(phase.get('branch'), str) else '',
  'PLAN_BACKEND': scalar('backend'), 'PLAN_MODEL': scalar('model'),
  'PLAN_BRANCH': scalar('branch'), 'PLAN_NOTIFY': scalar('notify'), 'PLAN_BASE': scalar('base'),
  'PLAN_PROJECT': scalar('project'), 'PLAN_SETUP': scalar('setup'),
  'B_REVIEW': bget('review'), 'B_REVISE': bget('revise'), 'B_RUN': bget('run'),
  'B_CLOSE': bget('close'), 'B_DEBRIEF': bget('debrief'), 'B_PHASE': bget('phase'), 'B_HEART': bget('heartbeat'),
}
for k, v in out.items(): print(f'{k}={shlex.quote(v)}')
print(f'PLAN_BRIEF_COUNT={len(briefs)}')
for i, b in enumerate(briefs): print(f'PLAN_BRIEF_{i}={shlex.quote(b)}')
PY
)" || die "could not parse plan frontmatter"
eval "$plan_vars"
PLAN_BRIEFS=()
for i in $(seq 0 $((PLAN_BRIEF_COUNT-1))); do eval "PLAN_BRIEFS+=(\"\$PLAN_BRIEF_$i\")"; done
[ "$PLAN_BRIEF_COUNT" -gt 0 ] || die "phase $((PLAN_PHASE_IDX+1)) of the plan lists no briefs"

# The plan's backend is the default, --backend overrides. Never auto-detected.
# A model is passed to the loop only when set: the loop forwards it to EVERY stage.
if [ -n "$BACKEND_ARG" ]; then BACKEND="$BACKEND_ARG"; else BACKEND="$PLAN_BACKEND"; fi
[ -n "$BACKEND" ] || die "plan has no backend: and none given with --backend"
case "$BACKEND" in claude|hermes|devin) ;; *) die "bad backend: $BACKEND (claude|hermes|devin)" ;; esac
[ -n "$MODEL_ARG" ] || MODEL_ARG="$PLAN_MODEL"
MODEL_FLAGS=(); [ -n "$MODEL_ARG" ] && MODEL_FLAGS=(--model "$MODEL_ARG")
WANT_BRANCH="${PLAN_PHASE_BRANCH:-$PLAN_BRANCH}"

# The phase's repo: every brief of a phase works in one repo (one branch per plan).
REPO=""
for b in "${PLAN_BRIEFS[@]}"; do
  [ -f "$b" ] || die "brief listed in the plan is missing: $b"
  r="$(brief_repo "$b")"; [ -n "$r" ] && { REPO="$r"; break; }
done
[ -n "$REPO" ] || die "no brief of the phase carries a repo: field"

# PR target and the one hard rule of branch flow: the plan works on a feature branch, never
# on a shared one. `base:` from the plan, else dev when origin has it, else main.
PROTECTED_RE='^(dev|main|master|staging|production)$'
if [ -n "$PLAN_BASE" ]; then BASE_BRANCH="$PLAN_BASE"
elif git -C "$REPO" rev-parse --verify -q origin/dev >/dev/null 2>&1; then BASE_BRANCH=dev
else BASE_BRANCH=main; fi
printf '%s' "$WANT_BRANCH" | /usr/bin/grep -qE "$PROTECTED_RE" \
  && die "plan branch '$WANT_BRANCH' is a shared branch — a plan runs on a feature branch cut from $BASE_BRANCH; only a human merges there"

# ---------------------------------------------------------------- plan writes
set_plan_orch() {  # $1 = orchestration value; also stamps updated:
  python3 - "$PLAN" "$1" "$(date +%F)" <<'PY'
import io, sys
path, orch, today = sys.argv[1:4]
lines = io.open(path, encoding='utf-8').read().split('\n')
end = next(i for i, l in enumerate(lines[1:], 1) if l.strip() == '---')
seen = False
for i in range(1, end):
    if lines[i].startswith('orchestration:'):
        rest = lines[i].split('#', 1)
        lines[i] = f'orchestration: {orch}' + (('          #' + rest[1]) if len(rest) > 1 else ''); seen = True
    elif lines[i].startswith('updated:'):
        lines[i] = f'updated: {today}'
if not seen: lines.insert(end, f'orchestration: {orch}')
io.open(path, 'w', encoding='utf-8', newline='').write('\n'.join(lines))
PY
  log_event "plan orchestration -> $1"
}
set_phase_status() {  # $1 = pending|running|done|broken, on phases[PLAN_PHASE_IDX]
  python3 - "$PLAN" "$PLAN_PHASE_IDX" "$1" <<'PY'
import io, re, sys
path, idx, status = sys.argv[1], int(sys.argv[2]), sys.argv[3]
lines = io.open(path, encoding='utf-8').read().split('\n')
end = next(i for i, l in enumerate(lines[1:], 1) if l.strip() == '---')
starts = [i for i in range(1, end) if re.match(r'^\s+- name:', lines[i])]
if idx < len(starts):
    lo = starts[idx]; hi = starts[idx + 1] if idx + 1 < len(starts) else end
    for i in range(lo, hi):
        m = re.match(r'^(\s+)status:\s*\S*(.*)$', lines[i])
        if m:
            lines[i] = f'{m.group(1)}status: {status}{m.group(2)}'; break
    else:
        lines.insert(lo + 1, f'    status: {status}')
io.open(path, 'w', encoding='utf-8', newline='').write('\n'.join(lines))
PY
}

# ---------------------------------------------------------------- lock
lock_pid()   { awk 'NR==1{print $2}' "$LOCK" 2>/dev/null || true; }
lock_alive() { local p; p="$(lock_pid)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
write_lock() { printf 'pid %s started %s %s\n' "$1" "$(now_s)" "$(ts "$(now_s)")" >"$LOCK"; }
release_lock() { rm -f "$LOCK" "$STAGE_FILE" "$LOCK.tick"; }

# The checkout lock lives in the checkout's own git dir (per worktree, never tracked, never
# in `git status`). It holds one line: the real path of the plan that owns the checkout.
checkout_lock_path() {
  local d; d="$(git -C "$REPO" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s/handoff-plan.lock' "$d"
}
# The remedy both refusals print: a sibling worktree of REPO for this plan, then where to
# point repo:. The sibling is PLAN_PROJECT without its repo prefix (the plan's sub directory
# name when PLAN_PROJECT is empty).
checkout_remedy() {
  local sib short repo_lc cmd
  repo_lc="$(basename "$REPO")"; repo_lc="${repo_lc,,}"
  short="$PLAN_PROJECT"; [ -n "$short" ] || short="$(basename "$(dirname "$(dirname "$PLAN")")")"
  case "$short" in "$repo_lc"-*) short="${short#"$repo_lc"-}" ;; esac
  sib="$(dirname "$REPO")/$(basename "$REPO")-$short"
  if [ -e "$sib" ]; then
    cmd="  $sib already exists: if it is free, point repo: at it"
  else
    cmd="  git -C $REPO fetch -q origin && git -C $REPO worktree add --detach $sib origin/$BASE_BRANCH"
    [ -z "$PLAN_SETUP" ] || cmd="$cmd"$'\n'"  (builtin cd $sib && $PLAN_SETUP)"
  fi
  printf '%s\nthen point repo: at %s in this phase'"'"'s briefs, and run this command again.\n' "$cmd" "$sib"
}
# A checkout is held while another plan's orchestration: is running, paused or broken —
# decided by that plan's state, never by a pid. Any other state, or a plan file gone, is
# a stale lock. Prints the refusal and returns 1 when held.
checkout_held_by_other() {  # $1 = lock file
  local holder st self
  [ -f "$1" ] || return 0
  holder="$(head -1 "$1")"; self="$(readlink -f "$PLAN")"
  [ -n "$holder" ] && [ "$holder" != "$self" ] && [ -f "$holder" ] || return 0
  st="$(fm_scalar "$holder" orchestration)"; st="${st%% *}"
  case "$st" in running|paused|broken) ;; *) return 0 ;; esac
  printf 'preflight:checkout — %s is held by %s (orchestration: %s). Give this plan its own checkout:\n' "$REPO" "$holder" "$st"
  checkout_remedy
  printf "(or change the holder's orchestration: in its plan file if it is finished)"
  return 1
}
# A plan whose checkout is the one this kit runs from is refused: its run would edit the
# engine that the driver, its stages and every other plan's stages are running. A kit
# outside any git checkout passes.
kit_check() {
  local kit_top repo_top
  kit_top="$(git -C "$KIT" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$kit_top" ] || return 0
  repo_top="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$repo_top" ] || return 0
  [ "$(cd "$kit_top" && pwd -P)" = "$(cd "$repo_top" && pwd -P)" ] || return 0
  printf 'preflight:kit — %s is the checkout the kit runs from (%s), and a run there would rewrite the engine under every stage. Give this plan its own checkout:\n' "$REPO" "$KIT"
  checkout_remedy
  return 1
}
# The watchdog timer is armed per plan by start/resume (arm_watchdog) and is only
# needed while a phase can still run. When the LAST phase completes the driver retires it
# itself — the first real plan (2026-09-22) left its timer ticking on a finished plan and
# handed the operator a systemd-escape puzzle. Intermediate phases keep it: the next phase's
# start reuses it. Silent when systemd or the unit is absent.
retire_watchdog() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local unit; unit="handoff-watchdog@$(systemd-escape "$PLAN_ARG").timer"
  systemctl --user is-enabled "$unit" >/dev/null 2>&1 || systemctl --user is-active "$unit" >/dev/null 2>&1 || return 0
  if systemctl --user disable --now "$unit" >/dev/null 2>&1; then
    log_event "WATCHDOG retired $unit — last phase done"
    echo "watchdog timer retired: $unit"
  else
    log_event "WATCHDOG could not retire $unit — disable it by hand: systemctl --user disable --now '$unit'"
  fi
}

# start/resume arm the plan's watchdog themselves: a start run straight from the printed
# command (2026-09-23) otherwise left two drivers with no timer watching them. The two
# template units are the kit's systemd/ files, written by its install.sh and never here;
# without them, or without systemd, this prints a note and the fallback, never a failure.
arm_watchdog() {
  local dir="$HOME/.config/systemd/user" unit
  if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "NOTE: no systemd user session — no watchdog timer; fallback: /loop 30m handoff-orchestrate tick $PLAN_ARG"
    return 0
  fi
  if [ ! -f "$dir/handoff-watchdog@.service" ] || [ ! -f "$dir/handoff-watchdog@.timer" ]; then
    echo "NOTE: no watchdog units in $dir — run $KIT/install.sh; fallback: /loop 30m handoff-orchestrate tick $PLAN_ARG"
    return 0
  fi
  unit="handoff-watchdog@$(systemd-escape "$PLAN_ARG").timer"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  if systemctl --user is-active "$unit" >/dev/null 2>&1; then
    echo "watchdog timer: $unit (already active)"
  elif systemctl --user enable --now "$unit" >/dev/null 2>&1; then
    log_event "WATCHDOG armed $unit"
    echo "watchdog timer: $unit (armed)"
  else
    log_event "WATCHDOG could not arm $unit — enable it by hand: systemctl --user enable --now '$unit'"
    echo "WARNING: could not arm $unit — systemctl --user enable --now '$unit'"
  fi
}

# ---------------------------------------------------------------- baseline
# Recorded at start/resume, checked before every launch and after every run: same
# branch, dirty set a SUBSET of the baseline's, origin/<branch> an ancestor of HEAD.
record_baseline() {
  {
    printf 'branch %s\n' "$(git -C "$REPO" branch --show-current 2>/dev/null || true)"
    printf 'head %s\n' "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"
    git -C "$REPO" status --porcelain 2>/dev/null | cut -c4- | sed 's/^/dirty /'
  } >"$BASELINE"
}
baseline_head() { awk '$1=="head"{print $2}' "$BASELINE" 2>/dev/null || true; }

# Tree check. Prints nothing and returns 0 when the repo is where the plan says; else
# prints "preflight:<branch|tree|origin> — <detail>" and returns 1.
tree_check() {
  local cur dirty_now extra head remote
  cur="$(git -C "$REPO" branch --show-current 2>/dev/null || true)"
  if [ "$cur" != "$WANT_BRANCH" ]; then
    printf 'preflight:branch — repo on %s, plan wants %s\n' "${cur:-<detached>}" "$WANT_BRANCH"; return 1
  fi
  extra="$(python3 - "$BASELINE" "$(git -C "$REPO" status --porcelain 2>/dev/null | cut -c4-)" <<'PY'
import sys
base = {l.split(' ', 1)[1] for l in open(sys.argv[1], encoding='utf-8').read().splitlines() if l.startswith('dirty ')}
now = [l for l in sys.argv[2].splitlines() if l.strip()]
print(' '.join(p for p in now if p not in base))
PY
)"
  if [ -n "$extra" ]; then
    printf 'preflight:tree — paths dirty that were not in the baseline: %s\n' "$extra"; return 1
  fi
  # Origin rule: the branch is pushed at phase ends and its PR stays open across
  # phases, so HEAD is normally AHEAD of origin while a phase runs. What must never
  # happen is origin holding commits HEAD lacks (someone pushed from elsewhere, or a
  # force-push): origin/<branch> must be an ancestor of HEAD. No remote branch yet is fine.
  head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"
  remote="$(git -C "$REPO" rev-parse --verify -q "origin/$WANT_BRANCH" 2>/dev/null || true)"
  if [ -n "$remote" ] && ! git -C "$REPO" merge-base --is-ancestor "$remote" "$head" 2>/dev/null; then
    printf 'preflight:origin — origin/%s (%s) has commits HEAD (%s) lacks; pull or rebase by hand\n' "$WANT_BRANCH" "${remote:0:7}" "${head:0:7}"; return 1
  fi
  return 0
}

# ---------------------------------------------------------------- pre-flight
# Before EVERY launch. Prints "preflight:<check> — <detail>" and returns 1 on failure;
# the caller decides between die2 (start/resume) and break_phase (driver).
disk_min_gb() { awk -F: '/^\s*disk-min-free-gb:/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$DEFAULTS" 2>/dev/null || true; }
backend_bin() {
  case "$BACKEND" in
    claude) printf '%s' "${CLAUDE_BIN:-$(command -v claude 2>/dev/null || ls "$HOME/.local/bin/claude" 2>/dev/null || true)}" ;;
    hermes) printf '%s' "${HERMES_BIN:-$(command -v hermes 2>/dev/null || ls "$HOME/.local/bin/hermes" 2>/dev/null || true)}" ;;
    devin)  printf '%s' "${DEVIN_BIN:-$(command -v devin 2>/dev/null || ls "$HOME/.local/bin/devin" 2>/dev/null || true)}" ;;
  esac
}
# No other launcher stage alive ON THE SAME CHECKOUT: two loops on one working tree
# collide on files and burst limits. Different repos, or a worktree of the same repo, are
# separate working trees and may run side by side. Prints the refusal and returns 1 on a hit.
stage_scan() {
  local pid rest other_brief other_repo root r self_real other_real
  while read -r pid rest; do
    [ -z "$pid" ] && continue; [ "$pid" = "$BASHPID" ] && continue
    other_brief="$(printf '%s\n' "$rest" | /usr/bin/grep -oE 'handoff-launch(\.sh)? (loop|review|run|close|revise|debrief|resume|lesson) [^ ]+\.md' | /usr/bin/awk '{print $3}')"
    [ -n "$other_brief" ] || continue
    # Resolve the other brief's repo: line. An absolute path reads directly
    # (worktree-launched runs carry the full worktree path); a relative path
    # is vault-relative — try the main vault and any vault worktree root.
    other_repo=""
    case "$other_brief" in
      /*) other_repo="$(/usr/bin/sed -nE 's/^repo:[[:space:]]*(.*)$/\1/p' "$other_brief" 2>/dev/null | head -1)" ;;
      *)
        for root in "$VAULT" "${VAULT}/.claude/worktrees/"*; do
          r="$(/usr/bin/sed -nE 's/^repo:[[:space:]]*(.*)$/\1/p' "$root/$other_brief" 2>/dev/null | head -1)"
          [ -n "$r" ] && { other_repo="$r"; break; }
        done ;;
    esac
    # Compare canonical real paths: a worktree and its main resolve to
    # distinct paths, so only a genuinely shared checkout matches.
    self_real="$(cd "$REPO" 2>/dev/null && pwd -P)"
    other_real="$(cd "${other_repo:-/nonexistent}" 2>/dev/null && pwd -P)"
    if [ -n "$other_real" ] && [ "$other_real" = "$self_real" ]; then
      printf 'preflight:launcher — a handoff-launch.sh stage is already running on this checkout: %s\n' "$rest"; return 1
    fi
  done < <(pgrep -af "handoff-launch(\.sh)? (loop|review|run|close|revise|debrief|resume|lesson) " 2>/dev/null || true)
  return 0
}

preflight() {  # $1 = brief
  local brief="$1" st bin min_gb free_gb reason
  [ -f "$brief" ] || { printf 'preflight:brief — not found: %s\n' "$brief"; return 1; }
  [ -d "$REPO" ]  || { printf 'preflight:repo — not a directory: %s\n' "$REPO"; return 1; }
  # 1. no other launcher stage alive on the same checkout (stage_scan). Env override
  #    HANDOFF_ORCH_ALLOW_CONCURRENT=1 skips the scan only.
  if [ "${HANDOFF_ORCH_ALLOW_CONCURRENT:-0}" != "1" ]; then
    stage_scan || return 1
  fi
  # 2. disk (a root shared with docker fills up; ENOSPC looks like a silent stall)
  min_gb="$(disk_min_gb)"; min_gb="${min_gb:-5}"
  free_gb="$(python3 -c 'import shutil,sys; print(shutil.disk_usage(sys.argv[1]).free // 2**30)' "$VAULT")"
  [ "$free_gb" -ge "$min_gb" ] || { printf 'preflight:disk — %s GB free, threshold %s GB\n' "$free_gb" "$min_gb"; return 1; }
  # 3. backend present, authenticated, profiled
  bin="$(backend_bin)"
  [ -n "$bin" ] && [ -x "$bin" ] || { printf 'preflight:backend — %s binary not found\n' "$BACKEND"; return 1; }
  case "$BACKEND" in
    devin)  "$bin" auth status >/dev/null 2>&1 || { printf 'preflight:backend — devin not logged in (devin auth status)\n'; return 1; } ;;
    hermes) for p in review run close; do [ -d "$HOME/.hermes/profiles/$p" ] || { printf 'preflight:backend — hermes profile %s missing\n' "$p"; return 1; }; done ;;
  esac
  # 4. branch / tree ⊆ baseline / level with origin
  reason="$(tree_check)" || { printf '%s\n' "$reason"; return 1; }
  # 5. the launcher resolves this brief (intact argv, a known first stage)
  if ! bash "$LAUNCHER" loop "$brief" --gate auto --backend "$BACKEND" "${MODEL_FLAGS[@]}" --dry-run >/dev/null 2>&1; then
    printf 'preflight:dry-run — handoff-launch.sh loop --dry-run failed for %s\n' "$(basename "$brief")"; return 1
  fi
  # 6. a state the loop can start from
  st="$(read_brief_state "$brief")"
  case "$st" in
    draft|reviewed|ready|reported) ;;
    running) printf 'preflight:state — %s is handoff: running (a live or dead run; /debrief reconstructs a dead one)\n' "$(basename "$brief")"; return 1 ;;
    *)       printf 'preflight:state — %s has handoff: %s\n' "$(basename "$brief")" "${st:-<none>}"; return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------- status file
stage_of_state() {  # the launcher's next stage for a brief state
  case "$1" in
    draft) echo review ;; reviewed) echo revise ;; ready|running) echo run ;;
    reported) echo close ;; closed) echo debrief ;; *) echo "?" ;;
  esac
}
brief_pos() {  # 1-based index of $1 in the phase
  local i=0 b; for b in "${PLAN_BRIEFS[@]}"; do i=$((i+1)); [ "$b" = "$1" ] && { echo "$i"; return; }; done; echo "?"
}
# RUNNING header from the stage file (what is live) — used by the driver and the tick.
running_line() {
  local brief pid started st stage el hb hbtxt
  if [ -f "$STAGE_FILE" ]; then
    read -r brief pid started <"$STAGE_FILE"
    st="$(read_brief_state "$brief")"; stage="$(stage_of_state "$st")"
    el=$(( ( $(now_s) - $(stage_started "$brief" "$started") ) / 60 ))
    hb="$(heartbeat_age "$stage")"; if [ "$hb" -lt 0 ]; then hbtxt="heartbeat unknown"; else hbtxt="heartbeat $((hb/60)) min ago"; fi
    printf 'RUNNING · phase %s/%s · brief %s/%s %s · stage %s · %s min · %s\n' \
      "$((PLAN_PHASE_IDX+1))" "$PLAN_PHASE_COUNT" "$(brief_pos "$brief")" "$PLAN_BRIEF_COUNT" "$(basename "$brief" .md)" "$stage" "$el" "$hbtxt"
  else
    printf 'RUNNING · phase %s/%s · between briefs\n' "$((PLAN_PHASE_IDX+1))" "$PLAN_PHASE_COUNT"
  fi
}
write_status() {  # $1 = verdict line, $2 = optional extra markdown appended after the table
  local b st
  # Built beside the file, then renamed over it: written in place, line 1 (the verdict)
  # lands first, and a reader polling it sees DONE before the summary under it exists.
  {
    printf '%s\n' "$1"
    printf '\n> plan: `%s` · backend `%s`%s · lock: %s\n' "$PLAN_ARG" "$BACKEND" "${MODEL_ARG:+ · model \`$MODEL_ARG\`}" "$([ -f "$LOCK" ] && cat "$LOCK" || echo none)"
    printf '\n## Phase %s/%s — %s\n\n' "$((PLAN_PHASE_IDX+1))" "$PLAN_PHASE_COUNT" "$PLAN_PHASE_NAME"
    printf '| # | brief | handoff | next stage | review verdict | close verdict |\n|---|---|---|---|---|---|\n'
    local i=0
    for b in "${PLAN_BRIEFS[@]}"; do
      i=$((i+1)); st="$(read_brief_state "$b" 2>/dev/null || echo '?')"
      printf '| %s | %s | %s | %s | %s | %s |\n' "$i" "$(basename "$b" .md)" "$st" \
        "$([ "$st" = closed ] && echo '—' || stage_of_state "$st")" \
        "$(/usr/bin/grep -m1 -oE '^verdict:\s*\S+' "${b%.md}.review.md" 2>/dev/null | awk '{print $2}' || true)" \
        "$(/usr/bin/grep -m1 -oE '^VERDICT:\s*\S+' "${b%.md}.close.md" 2>/dev/null | awk '{print $2}' || true)"
    done
    [ -n "${2:-}" ] && printf '\n%s\n' "$2"
    printf '\n## Events (last 20)\n\n```\n'
    [ -f "$EVENTS" ] && tail -20 "$EVENTS"
    printf '```\n\n`written %s`\n' "$(ts "$(now_s)")"
  } >"$STATUS.tmp.$$" && mv -f "$STATUS.tmp.$$" "$STATUS"
}
verdict() { sed -n '1p' "$STATUS" 2>/dev/null || echo "NO STATUS — plan has not been started"; }

# ---------------------------------------------------------------- notify
notify() {  # $1 = message. Loud for NEEDS YOU / PAUSED, silent otherwise.
  [ -n "$PLAN_NOTIFY" ] || return 0
  local env="$HOME/.config/handoff/notify.env" token chat dn=true
  [ -f "$env" ] || { echo "notify: $env missing (plan says notify: $PLAN_NOTIFY)" >&2; return 0; }
  token="$(/usr/bin/grep -E '^TELEGRAM_BOT_TOKEN=' "$env" | cut -d= -f2- | tr -d '"'"'")"
  chat="$(/usr/bin/grep -E '^TELEGRAM_CHAT_ID=' "$env" | cut -d= -f2- | tr -d '"'"'")"
  [ -n "$token" ] && [ -n "$chat" ] || { echo "notify: TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID missing in $env" >&2; return 0; }
  case "$1" in NEEDS\ YOU*|PAUSED*) dn=false ;; esac
  curl -fsS -m 20 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    --data-urlencode "chat_id=$chat" --data-urlencode "text=$1
$PLAN_ARG" --data-urlencode "disable_notification=$dn" >/dev/null 2>&1 \
    && log_event "NOTIFY sent — ${1%% ·*}" \
    || { log_event "NOTIFY failed (curl) — ${1%% ·*}"; echo "notify: send failed — the status file remains the source of truth" >&2; }
}
notify_check() {  # pre-flight: the channel must be able to send
  [ -n "$PLAN_NOTIFY" ] || return 0
  local env="$HOME/.config/handoff/notify.env" token chat
  [ -f "$env" ] || { printf 'preflight:notify — %s missing\n' "$env"; return 1; }
  token="$(/usr/bin/grep -E '^TELEGRAM_BOT_TOKEN=' "$env" | cut -d= -f2- | tr -d '"'"'")"
  chat="$(/usr/bin/grep -E '^TELEGRAM_CHAT_ID=' "$env" | cut -d= -f2- | tr -d '"'"'")"
  [ -n "$token" ] && [ -n "$chat" ] || { printf 'preflight:notify — TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID missing\n'; return 1; }
  curl -fsS -m 20 "https://api.telegram.org/bot${token}/getMe" >/dev/null 2>&1 || { printf 'preflight:notify — Telegram getMe failed (network or token)\n'; return 1; }
  return 0
}

# ---------------------------------------------------------------- stage file + heartbeat
# The driver writes "<brief> <loop pid> <epoch>" while a loop is live; the loop is started
# in its own process group (setsid) so the pid is also the pgid the tick kills.
write_stage() { printf '%s %s %s\n' "$1" "$2" "$(now_s)" >"$STAGE_FILE"; }
clear_stage() { rm -f "$STAGE_FILE"; }
# A stage's start: the launcher rewrites the brief's frontmatter at every state change,
# so the brief's mtime is when the current stage began — except for the first stage of
# the loop, which changes nothing before it starts; then it is the loop's start.
stage_started() {  # $1 = brief, $2 = loop start epoch
  local m; m="$(stat -c %Y "$1" 2>/dev/null || echo 0)"
  [ "$m" -gt "$2" ] && echo "$m" || echo "$2"
}
# Seconds since the newest transcript line for this backend; -1 when no source is known.
# File size is NOT a heartbeat (a delegated `claude -p` writes 0 bytes until it exits).
# Vault stages (revise, debrief) are claude sessions in the vault whatever the backend.
heartbeat_age() {  # $1 = stage (review|revise|run|close|debrief). Seconds since the stage's
  # session last moved, or -1 when unknown. Scoped to the ONE place that stage writes:
  # a repo stage's transcript dir or hermes profile, a vault stage's vault transcript dir.
  # Never a union — an interactive vault session (or the gateway) would keep a dead
  # stage looking alive (seen 2026-09-22: 24 s "heartbeat" from this very session).
  local stage="${1:-run}" now newest="" c="" d="" profile=""
  now="$(now_s)"
  case "$BACKEND" in
    claude)
      case "$stage" in revise|debrief) d="$VAULT" ;; *) d="$REPO" ;; esac
      d="$HOME/.claude/projects/$(printf '%s' "$d" | sed 's/[^A-Za-z0-9]/-/g')"
      [ -d "$d" ] && c="$(find "$d" -maxdepth 1 -name '*.jsonl' -newermt "@$(( now - 86400 ))" -printf '%T@\n' 2>/dev/null | sort -rn | head -1)"
      [ -n "$c" ] && newest="${c%.*}" ;;
    hermes)
      # Repo stages run under profiles/<review|run|close>; every message lands in that
      # profile's state.db. File mtimes are no heartbeat (the gateway's maintenance
      # stamps every profile's state.db and -wal at once a few times a day), so ask the
      # database: max(sessions.last_activity_at), which only a live session advances.
      # Revise/debrief run under the default profile the gateway shares: unknown (-1),
      # the budget alone bounds them.
      case "$stage" in review|run|close) profile="$stage" ;; *) profile="" ;; esac
      [ -n "$profile" ] && [ -f "$HOME/.hermes/profiles/$profile/state.db" ] && c="$(python3 - "$HOME/.hermes/profiles/$profile/state.db" <<'PY' 2>/dev/null
import sqlite3, sys
try:
    v = sqlite3.connect(f'file:{sys.argv[1]}?mode=ro', uri=True).execute('select max(last_activity_at) from sessions').fetchone()[0]
    print(int(float(v)) if v else '')
except Exception:
    print('')
PY
)"
      [ -n "$c" ] && newest="$c" ;;
    devin)
      if command -v devin >/dev/null 2>&1; then
        c="$(cd "$REPO" && devin list --format json 2>/dev/null | python3 -c '
import json, sys, time, calendar
try: data = json.load(sys.stdin)
except Exception: data = []
best = 0
for s in data if isinstance(data, list) else []:
    la = s.get("last_activity_at", "")
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S"):
        try: best = max(best, calendar.timegm(time.strptime(la, fmt))); break
        except ValueError: pass
print(best or "")' 2>/dev/null || true)"
        [ -n "$c" ] && newest="$c"
      fi ;;
  esac
  [ -n "$newest" ] && echo $(( now - newest )) || echo -1
}
stage_budget_s() {  # $1 = stage -> seconds or empty
  local m=""
  case "$1" in
    review) m="$B_REVIEW" ;; revise) m="$B_REVISE" ;; run) m="$B_RUN" ;;
    close)  m=$(( ${B_CLOSE:-0} + ${B_DEBRIEF:-0} )); [ "$m" = 0 ] && m="" ;;   # reported → close then debrief, one state
    debrief) m="$B_DEBRIEF" ;;
  esac
  [ -n "$m" ] && echo $(( m * 60 )) || true
}
# SIGTERM the loop's process group, 60 s, then SIGKILL. The launcher's capture is a
# mktemp file the launcher removes on exit; what survives is the driver's own capture of
# the loop's output, which the driver renames <brief>.killed-<ts>.log.
kill_group() {  # $1 = pgid
  kill -TERM -- "-$1" 2>/dev/null || kill -TERM "$1" 2>/dev/null || return 0
  local w=0; while kill -0 "$1" 2>/dev/null && [ "$w" -lt 60 ]; do sleep 1; w=$((w+1)); done
  kill -KILL -- "-$1" 2>/dev/null || kill -KILL "$1" 2>/dev/null || true
}

# Usage-limit signatures, per backend wording; extend as hermes and devin show theirs.
# An unknown wording is a `failed`, the safe side. Claude, 2026-09-29: "You've
# hit your session limit · resets 12:30pm (UTC)" — neither "usage" nor "resets at".
LIMIT_RE="You've hit your (usage |session )?limit|usage limit reached|You have reached your (usage|rate) limit|limit will reset at|resets (at )?[0-9]|rate_limit_error|Upgrade to Pro to access this model"
is_usage_limit() { printf '%s' "$1" | /usr/bin/grep -qiE "$LIMIT_RE"; }

# ---------------------------------------------------------------- what failed
# Prints "class: <class>\n- <line>\n..." (1-5 lines) for a gate hold, a failed run or a
# dead run — the three kinds that cover every break on file. Prints nothing for any other
# reason (its own diagnosis is already in the text). $3 is the kept loop log from
# run_loop's LOOP_LOG — a path, never the output itself: the heredoc below reads its
# program from stdin, so data has to come in as arguments, and a dead run's output can
# pass the 128 KiB limit on one argument or environment string.
what_failed() {  # $1 = reason "kind:field — detail", $2 = brief, $3 = kept loop log path (may be empty)
  python3 - "$1" "$2" "${3:-}" <<'PY'
import os, re, sys

reason, brief, kept_log = sys.argv[1], sys.argv[2], sys.argv[3]
name = os.path.basename(brief)[:-3] if brief.endswith('.md') else os.path.basename(brief)

def norm(line):
    s = ' '.join(line.split())
    if s.startswith('- '):
        s = s[2:]
    return s[:200]

FIND_RE = re.compile(r'^\s*(?:-\s*)?\[(BLOCKER|WRONG)\]')
FINDINGS_RE = re.compile(r'—\s*\**(refuted|unconfirmed)\**\s*—', re.I)

def read(p):
    if not p:
        return None
    try:
        return open(p, encoding='utf-8', errors='replace').read()
    except OSError:
        return None

def emit(cls, lines):
    print(f'class: {cls}')
    for l in lines[:5]:
        print(f'- {norm(l)}')

def not_done_items(report_text):
    blk = re.search(r'=== COMPLETION REPORT ===(.*?)(?:=== END COMPLETION REPORT ===|\Z)', report_text, re.S)
    body_text = blk.group(1) if blk else ''
    nd = re.search(r'(?m)^--- NOT DONE ---[ \t]*\n(.*?)(?=^--- |\Z)', body_text, re.S)
    body = nd.group(1) if nd else ''
    items = re.findall(r'(?m)^-[ \t].*(?:\n[ \t]+.*)*', body)
    if not items and body.strip():
        items = [body.strip()]
    return [i for i in items if not re.match(r'^-?\s*none\b', i.strip(), re.I)]

if reason.startswith('gate:brief-check'):
    check_path = brief[:-3] + '.check.md' if brief.endswith('.md') else brief + '.check.md'
    lines = [l for l in (read(check_path) or '').splitlines() if l.startswith('FAIL ')]
    emit('fixable', lines or [reason[len('gate:'):]])

elif reason.startswith('gate:'):
    field = reason[len('gate:'):]
    review_path = brief[:-3] + '.review.md' if brief.endswith('.md') else brief + '.review.md'
    text = read(review_path) or ''
    parts = re.split(r'(?m)^## Revise outcome\b.*$', text)
    above = parts[0]
    last = parts[-1] if len(parts) > 1 else ''

    def outcome_line(key):
        m = re.search(r'(?m)^' + re.escape(key) + r'\s*(.*)$', last)
        if not m:
            return None
        val = m.group(1).strip()
        if re.match(r'^none\b', val, re.I):
            return None
        return f'{key} {val}'

    lines = []
    if field.startswith('missing — '):
        cls = 'fixable'
        lines = [field[len('missing — '):]]
    else:
        cls = 'decision'
        if field.startswith('held — revise left the brief at handoff: '):
            lines.append(field[len('held — '):])
        d = outcome_line('decisions surfaced, not applied:')
        if d: lines.append(d)
        s = outcome_line('skipped:')
        if s: lines.append(s)
        blocker = next((l for l in above.splitlines() if (m := FIND_RE.match(l)) and m.group(1) == 'BLOCKER'), None)
        wrong = next((l for l in above.splitlines() if (m := FIND_RE.match(l)) and m.group(1) == 'WRONG'), None)
        if blocker: lines.append(blocker)
        if wrong: lines.append(wrong)
    if not lines:
        lines = [f'no BLOCKER or WRONG finding and no surfaced decision in {name}.review.md']
    emit(cls, lines)

elif reason.startswith('run:failed'):
    close_path = brief[:-3] + '.close.md' if brief.endswith('.md') else brief + '.close.md'
    report_path = brief[:-3] + '.report.md' if brief.endswith('.md') else brief + '.report.md'
    close_text = read(close_path) or ''
    report_text = read(report_path) or ''
    cm = re.search(r'^CLASS:\s*(fixable|accept\??|decision)(?=\s|$)', close_text, re.M)
    cls = cm.group(1) if cm else 'fixable'
    if cls == 'accept':
        cls = 'accept?'

    field = re.sub(r'^\s*[—-]\s*', '', reason[len('run:failed'):])
    lines = []
    if field == 'close audit VERDICT: FAIL':
        lines = [l for l in close_text.splitlines() if FINDINGS_RE.search(l)]
    elif field.startswith('NOT DONE lists'):
        lines = not_done_items(report_text)
    elif field.startswith('audit:'):
        lines = [l for l in report_text.splitlines() if FINDINGS_RE.search(l)]
        if not lines:
            lines = [field]
    else:
        lines = [field]
    if not lines:
        lines = [f'no NOT DONE item and no refuted or unconfirmed finding in {name}.report.md or {name}.close.md']
    emit(cls, lines)

elif reason.startswith('run:dead'):
    lines = []
    text = read(kept_log)
    if text is not None:
        nb = [l for l in text.splitlines() if l.strip()]
        lines = nb[-5:]
    if not lines:
        lines = ['the loop printed nothing']
    emit('fixable', lines)

# every other reason already carries its own diagnosis — print nothing
PY
}

# ---------------------------------------------------------------- break
break_phase() {  # $1 = reason "kind:field — detail"; $2 = brief
  local reason="$1" brief="${2:-}" where wf section
  where="$( [ -n "$brief" ] && basename "$brief" .md || echo "phase $((PLAN_PHASE_IDX+1))")"
  log_event "BREAK $where — $reason"
  wf="$(what_failed "$reason" "$brief" "${LOOP_LOG:-}" 2>/dev/null)" || wf=""
  set_plan_orch broken; set_phase_status broken
  release_lock
  section=""
  [ -n "$wf" ] && section="### What failed · ${wf%%$'\n'*}"$'\n\n'"$(printf '%s\n' "$wf" | tail -n +2)"$'\n\n'
  write_status "NEEDS YOU · broken at $where · $reason" "$(printf '## Break\n\n%s\n\n%sBrief: `%s` (handoff: %s). Fix by hand, then exactly one command:\n\n```bash\nhandoff-orchestrate resume %s --backend %s%s\n```' \
    "$reason" "$section" "${brief:-—}" "$([ -n "$brief" ] && read_brief_state "$brief" || echo —)" "$PLAN_ARG" "$BACKEND" "${MODEL_ARG:+ --model $MODEL_ARG}")"
  notify "NEEDS YOU · $PLAN_PHASE_NAME · broken at $where · $reason$([ -n "$wf" ] && printf '\n%s' "$wf")"
  printf 'BREAK: %s\n' "$reason" >&2
  exit 0
}

# ---------------------------------------------------------------- phase summary
# The input to the next /handoff-plan: what closed, every DIVERGED / BRIEF WAS WRONG /
# PAIN POINTS line, ADR drafts the debriefs wrote, human checks carried, the branch head.
# ---------------------------------------------------------------- branch flow
# The run stage is told to push every commit and open the PR itself. These are the
# backstop after a closed brief: whatever it left unpushed goes up, and a plan branch with
# no open PR gets its draft. A failed push breaks the phase — the branch flow is part of
# the contract, and the next brief's §2 assumes origin has the commits. A failed PR
# creation only logs: it is a watching aid, and the human can open it in one command.
push_branch() {  # $1 = brief
  local head remote out
  head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"
  remote="$(git -C "$REPO" rev-parse --verify -q "origin/$WANT_BRANCH" 2>/dev/null || true)"
  [ -n "$head" ] && [ "$head" != "$remote" ] || return 0
  printf '%s' "$WANT_BRANCH" | /usr/bin/grep -qE "$PROTECTED_RE" && break_phase "run:push — refusing to push shared branch $WANT_BRANCH" "$1"
  if out="$(git -C "$REPO" push -q -u origin "$WANT_BRANCH" 2>&1)"; then
    log_event "PUSH $WANT_BRANCH ${remote:+${remote:0:7}..}${head:0:7} -> origin — backstop, the run left commits unpushed"
  else
    break_phase "run:push — git push origin $WANT_BRANCH failed: $(printf '%s' "$out" | tail -1 | cut -c1-160)" "$1"
  fi
}
# The forge comes from origin's URL. On a GitLab origin `gh` cannot reach the remote at
# all ("none of the git remotes configured for this repository point to a known GitHub
# host"), so a phase on a GitLab repo (2026-10-05) opened no PR and its last
# run stopped PARTIAL on the PR step. GitLab gets `glab`; everything else keeps `gh`.
repo_forge() {  # gitlab | github
  case "$(git -C "$REPO" remote get-url origin 2>/dev/null)" in
    *gitlab*) echo gitlab ;;
    *) echo github ;;
  esac
}
forge_cli() { [ "$(repo_forge)" = gitlab ] && echo glab || echo gh; }
pr_url() {  # open PR (GitLab: merge request) for the plan branch, or empty
  local cli; cli="$(forge_cli)"
  command -v "$cli" >/dev/null 2>&1 || return 0
  if [ "$cli" = glab ]; then
    # `glab mr list` has no JSON output before glab 1.3x; the REST call works on every version.
    (cd "$REPO" && glab api "projects/:id/merge_requests?state=opened&source_branch=$WANT_BRANCH" 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["web_url"] if d else "")' 2>/dev/null) || true
  else
    (cd "$REPO" && gh pr list --head "$WANT_BRANCH" --state open --json url --jq '.[0].url' 2>/dev/null) || true
  fi
}
ensure_pr() {  # $1 = brief
  local cli; cli="$(forge_cli)"
  command -v "$cli" >/dev/null 2>&1 || { log_event "PR skipped — $cli not installed on this machine"; return 0; }
  [ -z "$(pr_url)" ] || return 0
  local title url slug body by_hand; slug="$(basename "$PLAN" .md)"
  title="$(sed -n 's/^# Plan — *//p' "$PLAN" | head -1)"; title="${title:-$slug}"
  body="$(printf 'Feature branch of a phased plan (%s), driven by handoff-orchestrate.\n\nEvery phase stacks on this branch and pushes here; nothing is merged between phases. When the last phase is done, a human validates the whole feature and squash-merges this PR into %s. No agent session merges it.' "$slug" "$BASE_BRANCH")"
  local -a cmd
  if [ "$cli" = glab ]; then
    by_hand="glab mr create --draft --target-branch $BASE_BRANCH --source-branch $WANT_BRANCH --fill --yes"
    cmd=(glab mr create --draft --target-branch "$BASE_BRANCH" --source-branch "$WANT_BRANCH"
         --title "$title" --description "$body" --yes)
  else
    by_hand="gh pr create --draft --base $BASE_BRANCH --head $WANT_BRANCH"
    cmd=(gh pr create --draft --base "$BASE_BRANCH" --head "$WANT_BRANCH" --title "$title" --body "$body")
  fi
  if url="$(cd "$REPO" && "${cmd[@]}" 2>&1)"; then
    # glab prints a summary block with the URL on its last line, indented; gh prints only the URL.
    url="$(printf '%s' "$url" | /usr/bin/grep -oE 'https?://[^[:space:]]+' | tail -1)" || true
    log_event "PR opened (draft) $WANT_BRANCH -> $BASE_BRANCH: $url"
    notify "PR opened (draft) · $WANT_BRANCH -> $BASE_BRANCH · $url"
  else
    log_event "PR not opened — ${by_hand%% --*} failed: $(printf '%s' "$url" | tail -1 | cut -c1-160) — by hand: cd $REPO && $by_hand"
  fi
}

phase_summary() {
  python3 - "$REPO" "$(baseline_head)" "$WANT_BRANCH" "$BASE_BRANCH" "$(pr_url)" "${PLAN_BRIEFS[@]}" <<'PY'
import os, re, subprocess, sys
repo, base_head, branch, base_branch, pr_url, briefs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6:]
def read(p):
    try: return open(p, encoding='utf-8').read()
    except OSError: return ''
def section(text, name):
    m = re.search(r'^--- ' + re.escape(name) + r' ---\s*\n(.*?)(?=^--- [A-Z ]+ ---|^=== END|\Z)', text, re.S | re.M)
    body = (m.group(1) if m else '').strip()
    items = [l.rstrip() for l in body.splitlines() if l.strip()]
    if not items or (len(items) == 1 and re.match(r'^-?\s*none\b', items[0], re.I)): return []
    return items
out = ['## Phase summary', '']
divg, wrong, pain, notdone, drafts, human, prs, verdicts = [], [], [], [], [], [], [], []
for b in briefs:
    name = os.path.basename(b)[:-3]
    rep = read(b[:-3] + '.report.md'); rev = read(b[:-3] + '.review.md'); clo = read(b[:-3] + '.close.md')
    fm = read(b).split('\n---', 2)[0] if read(b).startswith('---') else ''
    st = re.search(r'^handoff:\s*(\S+)', read(b), re.M); st = st.group(1) if st else '?'
    outc = re.search(r'^outcome:\s*(\S+)', rep, re.M); outc = outc.group(1) if outc else '?'
    aud = re.search(r'^audit:\s*(.+)$', rep, re.M); aud = aud.group(1).strip() if aud else '—'
    vs = re.findall(r'^verdict:\s*(\S+)', rev, re.M); cv = re.search(r'^VERDICT:\s*(\S+)', clo, re.M)
    fx = ' · fix-up' if os.path.isfile(b[:-3] + '.fixup.md') else ''
    verdicts.append(f'- `{name}` — handoff {st} · report {outc} · audit {aud} · review {"/".join(vs) or "—"} · close {cv.group(1) if cv else "—"}{fx}')
    for tag, dest in (('DIVERGED', divg), ('BRIEF WAS WRONG', wrong), ('PAIN POINTS', pain), ('NOT DONE', notdone)):
        for it in section(rep, tag): dest.append(f'- ({name}) {it.lstrip("- ").strip()}')
    # a §4 check the launcher proved fails byte-identically on the base: the brief assumed it could pass
    for l in read(b[:-3] + '.preexisting.md').splitlines():
        if re.match(r'§4\.\d+ · proven\b', l): wrong.append(f'- ({name}) {l}')
    # a report debriefed twice carries two outcome blocks: same line, once
    for m in re.finditer(r'^drafts awaiting a human:\s*(.+)$', rep, re.M):
        line = f'- ({name}) {m.group(1).strip()}'
        if not re.match(r'^\s*"?none\b', m.group(1), re.I) and line not in drafts: drafts.append(line)
    for m in re.finditer(r'^human checks carried into current.md:\s*(.+)$', rep, re.M):
        line = f'- ({name}) {m.group(1).strip()}'
        if not re.match(r'^\s*"?none\b', m.group(1), re.I) and line not in human: human.append(line)
    for m in re.finditer(r'(?:PR|pull request) #(\d+)', rep): prs.append(m.group(1))
out += ['### Briefs', ''] + verdicts + ['']
STAGES = ['review', 'revise', 'run', 'close', 'debrief']
phase_sums = {s: 0.0 for s in STAGES + ['other']}
phase_has = {s: False for s in STAGES + ['other']}
total_unpriced = 0
total_unavailable = 0
cost_rows = []
for b in briefs:
    name = os.path.basename(b)[:-3]
    sums = {s: 0.0 for s in STAGES + ['other']}
    has = {s: False for s in STAGES + ['other']}
    for line in read(b[:-3] + '.usage.log').splitlines():
        if not line.startswith('USAGE '):
            continue
        parts = line.split()
        if len(parts) < 3:
            continue
        col = parts[2] if parts[2] in STAGES else 'other'
        if 'unavailable' in line:
            total_unavailable += 1
            continue
        m = re.search(r'cost=(\d+\.\d+)', line)
        if m:
            sums[col] += float(m.group(1))
            has[col] = True
        um = re.search(r'unpriced=(\d+)', line)
        if um: total_unpriced += int(um.group(1))
    cells, row_total, row_has = [], 0.0, False
    for col in STAGES + ['other']:
        if has[col]:
            cells.append(f'{sums[col]:.4f}'); row_total += sums[col]; row_has = True
            phase_sums[col] += sums[col]; phase_has[col] = True
        else:
            cells.append('—')
    cost_rows.append(f'| `{name}` | ' + ' | '.join(cells) + ' | ' + (f'{row_total:.4f}' if row_has else '—') + ' |')
phase_cells, phase_total, phase_row_has = [], 0.0, False
for col in STAGES + ['other']:
    if phase_has[col]:
        phase_cells.append(f'{phase_sums[col]:.4f}'); phase_total += phase_sums[col]; phase_row_has = True
    else:
        phase_cells.append('—')
cost_rows.append('| **phase** | ' + ' | '.join(phase_cells) + ' | ' + (f'{phase_total:.4f}' if phase_row_has else '—') + ' |')
out += ['### Cost — claude stages, USD at list price', '',
        '| brief | review | revise | run | close | debrief | other | total |',
        '|---|---|---|---|---|---|---|---|'] + cost_rows + [
        '', f'Unpriced turns: {total_unpriced} · stages with no usage: {total_unavailable}', '']
for title, items in (('DIVERGED — choices made against the brief (read before the next plan)', divg),
                     ('BRIEF WAS WRONG — the vault was wrong about the repo', wrong),
                     ('NOT DONE', notdone), ('ADR drafts the debriefs wrote, not applied', drafts),
                     ('Human checks carried into current.md', human), ('PAIN POINTS — for /capture-lesson', pain)):
    out += [f'### {title}', ''] + (items or ['- none']) + ['']
out += [f'### Branch `{branch}` -> `{base_branch}`', '', f'Open PR: {pr_url or "none"} · PRs named by the reports: {", ".join("#" + p for p in sorted(set(prs))) or "none"}', '', '```']
try:
    rng = f'{base_head}..HEAD' if base_head else '-12'
    out.append(subprocess.run(['git', '-C', repo, 'log', '--format=%h %s  [%(trailers:key=Harness,valueonly,separator=%x2C) / %(trailers:key=Model,valueonly,separator=%x2C)]', rng],
                              capture_output=True, text=True).stdout.rstrip() or '(no new commits since the baseline)')
    out.append(subprocess.run(['git', '-C', repo, 'status', '-sb'], capture_output=True, text=True).stdout.rstrip())
except Exception as e:
    out.append(f'(git unavailable: {e})')
out.append('```')
print('\n'.join(out))
PY
}

# ---------------------------------------------------------------- driver
launch_driver() {
  # The driver runs a SNAPSHOT of both scripts: the operator edits these files
  # between phases while other plans are live, and this plan's later briefs edit them
  # too. Bash reads a script while it executes it, so an in-place overwrite while the
  # driver sits in handoff-orchestrate.sh's own final case…esac corrupts it mid-read.
  # Only the two bash scripts are snapshotted — the hooks, the guard, brief-check and
  # the usage reader resolve live from $KIT, and the defaults file from $VAULT; tick/stop/status/the systemd unit keep running the live
  # files, since they are short-lived and must pick up fixes.
  local driver_dir="$BASE.driver"
  rm -rf "$driver_dir"
  mkdir -p "$driver_dir"
  cp "$KIT/handoff-launch.sh" "$driver_dir/handoff-launch.sh"
  cp "$KIT/handoff-orchestrate.sh" "$driver_dir/handoff-orchestrate.sh"
  setsid env VAULT="$VAULT" HANDOFF_KIT="$KIT" HANDOFF_DEFAULTS="$HANDOFF_DEFAULTS" HANDOFF_PROJECTS="$HANDOFF_PROJECTS" HANDOFF_LAUNCHER="$driver_dir/handoff-launch.sh" \
    bash "$driver_dir/handoff-orchestrate.sh" __driver "$PLAN_ARG" --backend "$BACKEND" "${MODEL_FLAGS[@]}" \
    >"$DRIVER_LOG" 2>&1 </dev/null &
  local dpid=$!
  write_lock "$dpid"   # the driver's pid, not this shell's: the tick watches the driver
  set_plan_orch running; set_phase_status running
  write_status "RUNNING · phase $((PLAN_PHASE_IDX+1))/$PLAN_PHASE_COUNT · driver $dpid starting"
  printf 'driver launched: pid %s\n  log:    %s\n  status: handoff-orchestrate status %s\n  stop:   handoff-orchestrate stop %s\n' "$dpid" "$DRIVER_LOG" "$PLAN_ARG" "$PLAN_ARG"
}

run_loop() {  # $1 = brief. Runs one loop in its own process group; sets LOOP_RC, LOOP_OUT and LOOP_LOG.
  local cap pid
  cap="$(mktemp)"
  set +e
  # HANDOFF_BASE: a pre-existing failure is proven against the plan's base, not a guess
  HANDOFF_BASE="$BASE_BRANCH" setsid bash "$LAUNCHER" loop "$1" --gate auto --backend "$BACKEND" "${MODEL_FLAGS[@]}" >"$cap" 2>&1 </dev/null &
  pid=$!
  write_stage "$1" "$pid"
  wait "$pid"; LOOP_RC=$?
  set -e
  clear_stage
  LOOP_OUT="$(cat "$cap")"
  LOOP_LOG=""
  # Keep the loop's output whenever it did not close the brief: it is the only trace of
  # a stage that died without its block (2026-09-21: two hermes runs died with exit 30
  # and the capture had been deleted — nothing said why).
  case "$LOOP_RC" in
    0) rm -f "$cap" ;;
    137|143) LOOP_LOG="${1%.md}.killed-$(date +%Y%m%d-%H%M%S).log"; mv "$cap" "$LOOP_LOG" ;;
    *) LOOP_LOG="${1%.md}.failed-$(date +%Y%m%d-%H%M%S).log"; mv "$cap" "$LOOP_LOG" ;;
  esac
}

log_cost() {  # $1 = brief. Sums LOOP_OUT's "USAGE " lines into one COST event. Guarded like what_failed.
  local name out
  name="$(basename "$1" .md)"
  out="$(printf '%s\n' "$LOOP_OUT" | python3 -c '
import re, sys
name = sys.argv[1]
total = 0.0
n = 0
u = 0
for line in sys.stdin:
    if not line.startswith("USAGE "):
        continue
    m = re.search(r"cost=(\d+\.\d+)", line)
    if not m:
        continue
    total += float(m.group(1))
    n += 1
    um = re.search(r"unpriced=(\d+)", line)
    if um:
        u += int(um.group(1))
if n:
    msg = f"COST {name} {total:.4f} USD over {n} stages"
    if u:
        msg += f" + {u} unpriced turns"
    print(msg)
' "$name" 2>/dev/null)" || out=""
  [ -n "$out" ] && log_event "$out"
  return 0
}

driver() {
  local brief st phase_start phase_retries=0 pauses=0 tried="" kind reason verdict_line brief_head
  local limit_wait="${HANDOFF_LIMIT_WAIT:-1800}"
  phase_start="$(awk 'NR==1{print $4}' "$LOCK" 2>/dev/null || true)"; phase_start="${phase_start:-$(now_s)}"
  trap 'log_event "driver exiting (pid $$)"' EXIT

  for brief in "${PLAN_BRIEFS[@]}"; do
    st="$(read_brief_state "$brief")"
    [ "$st" = "closed" ] && continue           # already done (resume)
    # HEAD when this brief starts: the run:dead break text says whether the dead run
    # committed anything, measured from here, not from the phase baseline.
    brief_head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"
    log_event "BRIEF START $(basename "$brief" .md) from handoff: $st"
    notify "▶ START · phase $((PLAN_PHASE_IDX+1))/$PLAN_PHASE_COUNT · $(basename "$brief" .md) · from handoff: $st"
    while :; do
      # phase wall-clock budget
      if [ -n "$B_PHASE" ] && [ $(( $(now_s) - phase_start )) -gt $(( B_PHASE * 60 )) ]; then
        break_phase "watchdog:phase-budget — $B_PHASE min exceeded" "$brief"
      fi
      # pre-flight right before this launch: baseline must still hold
      reason="$(preflight "$brief")" || break_phase "$reason" "$brief"
      write_status "RUNNING · phase $((PLAN_PHASE_IDX+1))/$PLAN_PHASE_COUNT · brief $(brief_pos "$brief")/$PLAN_BRIEF_COUNT $(basename "$brief" .md) · stage $(stage_of_state "$(read_brief_state "$brief")") · starting"
      run_loop "$brief"
      log_cost "$brief"
      st="$(read_brief_state "$brief")"
      verdict_line="$(printf '%s\n' "$LOOP_OUT" | /usr/bin/grep -m1 -E '^(GATE|RUN): ' || true)"

      if [ "$LOOP_RC" -eq 0 ]; then
        # the post-run tree check is the orchestrator's, from git
        reason="$(tree_check)" || break_phase "run:tree — ${reason#preflight:tree — }" "$brief"
        push_branch "$brief"; ensure_pr "$brief"     # backstop
        log_event "BRIEF CLOSED $(basename "$brief" .md)"
        write_status "RUNNING · phase $((PLAN_PHASE_IDX+1))/$PLAN_PHASE_COUNT · brief $(brief_pos "$brief")/$PLAN_BRIEF_COUNT $(basename "$brief" .md) · closed"
        notify "phase $((PLAN_PHASE_IDX+1)) · $(basename "$brief" .md) closed ($(brief_pos "$brief")/$PLAN_BRIEF_COUNT)"
        break
      fi
      case "$LOOP_RC" in
        10) break_phase "gate:${verdict_line#GATE: }" "$brief" ;;
        20) break_phase "run:${verdict_line#RUN: }" "$brief" ;;
      esac
      # 30 (launcher error / stage died), 137/143 (killed by the tick), anything else.
      if is_usage_limit "$LOOP_OUT"; then
        # A run that hit the limit left commits and a tree behind: never relaunched alone.
        # The human decides between waiting and resuming on another
        # backend/model — resume takes both flags. Stateless stages pause and retry.
        [ "$st" = "running" ] && break_phase "limit — run stage hit a usage limit; its commits stay on the branch. Sort the tree, set the brief to ready, then resume (optionally --backend/--model)" "$brief"
        pauses=$((pauses+1))
        [ "$pauses" -le 10 ] || break_phase "limit — eleventh usage-limit pause in this phase" "$brief"
        log_event "PAUSE usage limit #$pauses at $(basename "$brief" .md) (handoff: $st) — retrying at $(ts $(( $(now_s) + limit_wait )))"
        set_plan_orch paused
        write_status "PAUSED · usage limit · retrying at $(date -d "@$(( $(now_s) + limit_wait ))" '+%H:%M') · pause $pauses/10"
        notify "PAUSED · usage limit · retrying at $(date -d "@$(( $(now_s) + limit_wait ))" '+%H:%M')"
        sleep "$limit_wait"
        set_plan_orch running
        continue
      fi
      if [ "$LOOP_RC" -eq 137 ] || [ "$LOOP_RC" -eq 143 ]; then kind="killed"; else kind="failed (exit $LOOP_RC${verdict_line:+, $verdict_line})"; fi
      # A dead run always breaks: the driver cannot tell "rerun fixes it" from
      # "a human must look", and a relaunch would spend the same budget on the same model.
      # The break text says whether the run committed anything since the brief started,
      # so the human knows if `handoff: ready` + resume is the whole fix.
      if [ "$st" = "running" ]; then
        if [ "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)" = "$brief_head" ]; then
          break_phase "run:dead — run stage $kind, no commit landed since the brief started, brief left at handoff: running. Check the tree, set the brief to ready, resume" "$brief"
        else
          break_phase "run:dead — run stage $kind, HEAD moved since the brief started (partial commits on the branch), brief left at handoff: running. Sort the tree, set the brief to ready (re-run) or closed (/debrief reconstructs), resume" "$brief"
        fi
      fi
      # Retry classes: review/close/revise/debrief once each from their unchanged state; phase cap 3.
      case " $tried " in *" $brief@$st "*) break_phase "watchdog:retries — $(stage_of_state "$st") $kind twice from handoff: $st" "$brief" ;; esac
      [ "$phase_retries" -lt 3 ] || break_phase "watchdog:retries — fourth retry in this phase ($(stage_of_state "$st") $kind)" "$brief"
      tried="$tried $brief@$st"; phase_retries=$((phase_retries+1))
      log_event "RETRY #$phase_retries $(basename "$brief" .md) $(stage_of_state "$st") $kind, relaunching from handoff: $st"
    done
  done

  phase_done
}

# Every brief of the phase is closed. The driver's own end, and resume's when a broken or
# paused phase has no brief left to run (begin).
phase_done() {
  log_event "PHASE DONE $((PLAN_PHASE_IDX+1)) — $PLAN_PHASE_NAME"
  # the last phase closes the plan: `done`, not `phase-done` (the status skill's
  # "review and merge the PR" step keys on it)
  if [ $((PLAN_PHASE_IDX+1)) -ge "$PLAN_PHASE_COUNT" ]; then set_plan_orch done; else set_plan_orch phase-done; fi
  set_phase_status done
  release_lock
  # the plan is finished with its checkout: drop the checkout lock, only if it is ours
  local clf; clf="$(checkout_lock_path 2>/dev/null)" || clf=""
  if [ -n "$clf" ] && [ -f "$clf" ] && [ "$(head -1 "$clf")" = "$(readlink -f "$PLAN")" ]; then rm -f "$clf"; fi
  write_status "DONE · phase $((PLAN_PHASE_IDX+1))/$PLAN_PHASE_COUNT · $PLAN_PHASE_NAME · $PLAN_BRIEF_COUNT briefs closed · $(ts "$(now_s)")" "$(phase_summary)"
  [ $((PLAN_PHASE_IDX+1)) -ge "$PLAN_PHASE_COUNT" ] && retire_watchdog
  notify "DONE · phase $((PLAN_PHASE_IDX+1))/$PLAN_PHASE_COUNT · $PLAN_PHASE_NAME · $PLAN_BRIEF_COUNT briefs closed"
  echo "phase $((PLAN_PHASE_IDX+1)) complete"
}

# ---------------------------------------------------------------- start / resume
# The plan branch is the orchestrator's to set up, not the human's (2026-09-24: the operator was
# being asked to create it before every plan). At start/resume: already on it → nothing;
# exists locally → check it out; exists only on origin → track it; nowhere → cut it from
# origin/<base> and push it so origin has the branch from minute one. The PR
# needs a commit that base lacks, so it opens after the first one — the run's job, the
# driver's backstop; never a human step. A checkout that git refuses (a dirty tree in the
# way) is the one real failure here, reported as such.
ensure_branch() {
  local cur out
  cur="$(git -C "$REPO" branch --show-current 2>/dev/null || true)"
  [ "$cur" = "$WANT_BRANCH" ] && return 0
  git -C "$REPO" fetch -q origin 2>/dev/null || true
  if git -C "$REPO" rev-parse --verify -q "refs/heads/$WANT_BRANCH" >/dev/null 2>&1; then
    out="$(git -C "$REPO" checkout -q "$WANT_BRANCH" 2>&1)" || die2 "preflight:branch — repo on ${cur:-<detached>}, could not check out $WANT_BRANCH: $(printf '%s' "$out" | tail -1)"
    log_event "BRANCH checked out $WANT_BRANCH (repo was on ${cur:-<detached>})"
  elif git -C "$REPO" rev-parse --verify -q "origin/$WANT_BRANCH" >/dev/null 2>&1; then
    out="$(git -C "$REPO" checkout -q --track "origin/$WANT_BRANCH" 2>&1)" || die2 "preflight:branch — could not track origin/$WANT_BRANCH: $(printf '%s' "$out" | tail -1)"
    log_event "BRANCH tracking origin/$WANT_BRANCH (repo was on ${cur:-<detached>})"
  else
    git -C "$REPO" rev-parse --verify -q "origin/$BASE_BRANCH" >/dev/null 2>&1 || die2 "preflight:branch — $WANT_BRANCH exists nowhere and origin/$BASE_BRANCH (the base to cut it from) is missing"
    out="$(git -C "$REPO" checkout -q -b "$WANT_BRANCH" "origin/$BASE_BRANCH" 2>&1)" || die2 "preflight:branch — could not create $WANT_BRANCH from origin/$BASE_BRANCH: $(printf '%s' "$out" | tail -1)"
    if out="$(git -C "$REPO" push -q -u origin "$WANT_BRANCH" 2>&1)"; then
      log_event "BRANCH created $WANT_BRANCH from origin/$BASE_BRANCH and pushed (repo was on ${cur:-<detached>})"
    else
      log_event "BRANCH created $WANT_BRANCH from origin/$BASE_BRANCH; push failed, the backstop after brief 1 retries: $(printf '%s' "$out" | tail -1 | cut -c1-120)"
    fi
  fi
}

begin() {  # $1 = START|RESUME
  case "$PLAN_ORCH" in
    running) lock_alive && die "plan is running: $(cat "$LOCK")"; ;;   # stale `running` with no live driver: fall through
    phase-done|done) die "phase $((PLAN_PHASE_IDX+1)) is $PLAN_ORCH — /handoff-plan writes the next phase and resets orchestration: planned" ;;
    planned|paused|broken) ;;
    *) die "unknown orchestration: '$PLAN_ORCH'" ;;
  esac
  lock_alive && die "plan already has a live driver: $(cat "$LOCK")"
  local first="" b
  for b in "${PLAN_BRIEFS[@]}"; do [ "$(read_brief_state "$b")" = "closed" ] || { first="$b"; break; }; done
  if [ -z "$first" ]; then
    # The last brief closed but its loop still broke (a failed run check, 2026-09-29), or
    # a stop came after it: only the driver's end is missing. No other command or state
    # gets it.
    case "$1:$PLAN_ORCH" in
      RESUME:broken|RESUME:paused)
        log_event "RESUME — every brief of phase $((PLAN_PHASE_IDX+1)) is closed, finishing the phase"
        phase_done; return 0 ;;
    esac
    die "every brief of phase $((PLAN_PHASE_IDX+1)) is already closed"
  fi
  # The kit's own checkout is refused before the lock and before any git write; unlike the
  # stage scan, HANDOFF_ORCH_ALLOW_CONCURRENT does not skip it.
  local reason clf
  reason="$(kit_check)" || die2 "$reason"
  # Lock the checkout before anything moves it: a refusal here leaves the branch, the
  # baseline and the plan untouched.
  clf="$(checkout_lock_path)" || die2 "preflight:repo — not a git checkout: $REPO"
  reason="$(checkout_held_by_other "$clf")" || die2 "$reason"
  if [ "${HANDOFF_ORCH_ALLOW_CONCURRENT:-0}" != "1" ]; then
    reason="$(stage_scan)" || die2 "$reason"
  fi
  readlink -f "$PLAN" >"$clf" 2>/dev/null || die2 "preflight:checkout — could not write $clf"
  ensure_branch
  record_baseline
  reason="$(notify_check)" || { rm -f "$BASELINE"; die2 "$reason"; }
  reason="$(preflight "$first")" || { rm -f "$BASELINE"; die2 "$reason"; }
  if git -C "$REPO" rev-parse --verify -q "origin/$BASE_BRANCH" >/dev/null 2>&1 \
     && ! git -C "$REPO" merge-base --is-ancestor "origin/$BASE_BRANCH" HEAD 2>/dev/null; then
    log_event "NOTE base — origin/$BASE_BRANCH has commits $WANT_BRANCH lacks; the run's sync step merges $BASE_BRANCH in before its PR update"
  fi
  log_event "$1 backend=$BACKEND model=${MODEL_ARG:-<stage defaults>} from $(basename "$first" .md) (handoff: $(read_brief_state "$first")) · baseline $(awk '$1=="head"{print substr($2,1,7)}' "$BASELINE") on $WANT_BRANCH, $(/usr/bin/grep -c '^dirty ' "$BASELINE" || true) dirty paths"
  launch_driver
  arm_watchdog
}

stop() {
  local pid; pid="$(lock_pid)"
  if [ -z "$pid" ]; then echo "nothing running: no lock for $PLAN_ARG (orchestration: $PLAN_ORCH)"; exit 0; fi
  # Driver first, so it cannot read the dying stage as a failure and record a break of
  # its own; then the stage, orphaned by now, by process group.
  kill_group "$pid"
  log_event "STOP driver $pid by hand"
  local sb="" sp ss
  if [ -f "$STAGE_FILE" ]; then
    read -r sb sp ss <"$STAGE_FILE"
    log_event "STOP killing stage pgid $sp ($(basename "$sb" .md))"; kill_group "$sp"; clear_stage
  fi
  set_plan_orch paused
  release_lock
  write_status "PAUSED · stopped by hand at $(ts "$(now_s)") · resume: handoff-orchestrate resume $PLAN_ARG --backend $BACKEND"
  echo "stopped driver $pid; orchestration: paused. Briefs are as the launcher left them."
  if [ -n "$sb" ] && [ "$(read_brief_state "$sb")" = "running" ]; then
    echo "NOTE: $(basename "$sb") is handoff: running — a run was killed mid-way. resume will refuse it until a human"
    echo "      sorts the repo out and sets the brief to ready (re-run) or closed (/debrief reconstructs a dead run)."
  fi
  echo "resume: handoff-orchestrate resume $PLAN_ARG --backend $BACKEND${MODEL_ARG:+ --model $MODEL_ARG}"
}

# ---------------------------------------------------------------- tick
tick() {
  touch "$TICK_FILE"
  if [ ! -f "$LOCK" ]; then
    # A finished plan's timer retires itself on the first tick after the last phase — the
    # backstop for a driver that completed before retire_watchdog existed or failed to run it.
    case "$PLAN_ORCH" in phase-done|done) [ $((PLAN_PHASE_IDX+1)) -ge "$PLAN_PHASE_COUNT" ] && retire_watchdog ;; esac
    echo "tick: no driver for $PLAN_ARG (orchestration: $PLAN_ORCH) — $(verdict)"; exit 0
  fi
  exec 9>"$LOCK.tick"
  flock -n 9 || { echo "tick: another tick holds the lock"; exit 0; }
  local pid; pid="$(lock_pid)"
  if ! kill -0 "$pid" 2>/dev/null; then
    # A driver that exited on its own path (break, done, stop) released the lock. A lock
    # with a dead pid is a driver that died — a break the driver could not write itself.
    log_event "TICK driver $pid dead with the lock held — watchdog:driver"
    set_plan_orch broken; set_phase_status broken
    release_lock
    write_status "NEEDS YOU · watchdog:driver — driver $pid died mid-phase" "$(printf '## Break\n\nThe driver process is gone but the phase is not done. Read `%s`, then:\n\n```bash\nhandoff-orchestrate resume %s --backend %s\n```' "$DRIVER_LOG" "$PLAN_ARG" "$BACKEND")"
    notify "NEEDS YOU · watchdog:driver — driver $pid died mid-phase"
    exit 0
  fi
  [ -f "$STAGE_FILE" ] || { echo "tick: driver $pid alive, between stages — $(verdict)"; exit 0; }
  local sb sp ss st stage started el hb hb_limit budget reason=""
  read -r sb sp ss <"$STAGE_FILE"
  st="$(read_brief_state "$sb")"; stage="$(stage_of_state "$st")"
  started="$(stage_started "$sb" "$ss")"; el=$(( $(now_s) - started ))
  hb="$(heartbeat_age "$stage")"; hb_limit=$(( ${B_HEART:-20} * 60 )); budget="$(stage_budget_s "$stage")"
  if [ "$hb" -ge 0 ] && [ "$hb" -gt "$hb_limit" ] && [ "$hb" -lt "$el" ]; then
    reason="stalled — no transcript movement for $((hb/60)) min (limit ${B_HEART:-20})"
  elif [ -n "$budget" ] && [ "$el" -gt "$budget" ]; then
    reason="over budget — $stage at $((el/60)) min (budget $((budget/60)))"
  fi
  if [ -n "$reason" ]; then
    log_event "KILL $(basename "$sb" .md) $stage pgid $sp — $reason — heartbeat $([ "$hb" -ge 0 ] && echo "${hb}s ago" || echo unknown)"
    # Status BEFORE the kill: the driver's wait() returns right after it and writes the
    # next header (retry or break) — writing ours afterwards would overwrite that.
    write_status "RUNNING · phase $((PLAN_PHASE_IDX+1))/$PLAN_PHASE_COUNT · killing $stage of $(basename "$sb" .md) — $reason · driver decides retry or break"
    kill_group "$sp"    # the driver's wait() returns 143/137 and applies the retry classes
    echo "tick: killed $stage of $(basename "$sb" .md) — $reason"
    exit 0
  fi
  write_status "$(running_line)"
  echo "tick: ok — $(verdict)"
}

# ---------------------------------------------------------------- commands
case "$CMD" in
  status)   verdict ;;
  start)    begin START ;;
  resume)   begin RESUME ;;
  stop)     stop ;;
  tick)     tick ;;
  __driver) driver ;;
  *) die "unknown command: $CMD (start|tick|stop|resume|status)" ;;
esac
