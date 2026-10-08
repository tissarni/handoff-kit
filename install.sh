#!/usr/bin/env bash
# Install the handoff kit for this user. Run it again after every pull or merge of the kit.
#
#   install.sh [--vault <dir>] [--defaults <path relative to the vault>] [--projects <dir>]
#
# Writes, all under $HOME:
#   ~/.config/handoff/config.env   VAULT, HANDOFF_DEFAULTS and HANDOFF_PROJECTS; other lines kept
#   ~/.local/bin/handoff-launch, handoff-orchestrate, brief-check   symlinks into this kit
#   ~/.claude/skills/<name>/        each skill under skills/, replaced whole
#   ~/.config/systemd/user/handoff-watchdog@.service and .timer   copied from systemd/
# A flag left out keeps the value config.env already has. The environment's VAULT,
# HANDOFF_DEFAULTS and HANDOFF_PROJECTS are ignored here: the file must not take a value
# that one shell happened to export. Nothing is enabled: start/resume arm each plan's timer.
set -euo pipefail
KIT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
USAGE="usage: install.sh [--vault <dir>] [--defaults <path relative to the vault>] [--projects <dir>]"
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
usage() { printf '%s\n' "$USAGE" >&2; exit 2; }
[ -n "${HOME:-}" ] || die "HOME is not set"
CFG="$HOME/.config/handoff/config.env"
cfg_get() { [ -f "$CFG" ] && /usr/bin/grep -E "^$1=" "$CFG" | tail -n 1 | cut -d= -f2- | tr -d "\"'" || true; }
vault="" defaults="" projects=""
while [ $# -gt 0 ]; do
  case "$1" in
    --vault|--defaults|--projects)
      [ $# -ge 2 ] || usage
      case "$1" in --vault) vault="$2" ;; --defaults) defaults="$2" ;; --projects) projects="$2" ;; esac
      shift 2 ;;
    *) usage ;;
  esac
done
vault="${vault:-$(cfg_get VAULT)}"; defaults="${defaults:-$(cfg_get HANDOFF_DEFAULTS)}"; projects="${projects:-$(cfg_get HANDOFF_PROJECTS)}"
# Check everything before writing anything: a refused install changes no file.
[ -n "$vault" ] || die "no vault: pass --vault <dir> (config.env has no VAULT= line yet)"
[ -n "$defaults" ] || die "no defaults file: pass --defaults <path relative to the vault>"
[ -n "$projects" ] || die "no projects directory: pass --projects <dir>"
real="$(cd "$vault" 2>/dev/null && pwd -P)" || die "vault not found: $vault"; vault="$real"
[ -f "$vault/$defaults" ] || die "defaults file not found: $vault/$defaults"
[ -d "$vault/$projects" ] || die "projects directory not found: $vault/$projects"
for n in handoff-launch handoff-orchestrate brief-check; do [ -x "$KIT/$n.sh" ] || die "$KIT/$n.sh is missing or not executable"; done
for u in handoff-watchdog@.service handoff-watchdog@.timer; do [ -f "$KIT/systemd/$u" ] || die "$KIT/systemd/$u is missing"; done
mkdir -p "$(dirname "$CFG")"; tmp="$CFG.tmp.$$"
{ [ -f "$CFG" ] && /usr/bin/grep -vE '^(VAULT|HANDOFF_DEFAULTS|HANDOFF_PROJECTS)=' "$CFG" || true
  printf 'VAULT=%s\nHANDOFF_DEFAULTS=%s\nHANDOFF_PROJECTS=%s\n' "$vault" "$defaults" "$projects"; } >"$tmp"
mv -f "$tmp" "$CFG"; echo "config: $CFG"
mkdir -p "$HOME/.local/bin"
for n in handoff-launch handoff-orchestrate brief-check; do ln -sfn "$KIT/$n.sh" "$HOME/.local/bin/$n"; echo "linked $HOME/.local/bin/$n -> $KIT/$n.sh"; done
mkdir -p "$HOME/.claude/skills"
for d in "$KIT"/skills/*/; do [ -d "$d" ] || continue; name="$(basename "$d")"; rm -rf "$HOME/.claude/skills/$name"; cp -R "$d" "$HOME/.claude/skills/$name"; echo "installed skill $name"; done
units="$HOME/.config/systemd/user"; mkdir -p "$units"
cp "$KIT/systemd/handoff-watchdog@.service" "$KIT/systemd/handoff-watchdog@.timer" "$units/"
if command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload >/dev/null 2>&1; then echo "watchdog units: $units (reloaded)"
else echo "NOTE: no systemd user session — units written to $units, not reloaded"; fi
case ":${PATH:-}:" in *":$HOME/.local/bin:"*) ;; *) echo "NOTE: $HOME/.local/bin is not on PATH — add it, or the commands are not found by name" ;; esac
