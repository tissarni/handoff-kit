#!/usr/bin/env bash
# Install the handoff kit for this user. Run it again after every pull or merge of the kit.
#
#   install.sh [--vault <dir>] [--defaults <path relative to the vault>] [--projects <dir>] [--hermes-profiles]
#
# Writes, all under $HOME:
#   ~/.config/handoff/config.env   VAULT, HANDOFF_DEFAULTS and HANDOFF_PROJECTS; other lines kept
#   ~/.local/bin/handoff-launch, handoff-orchestrate, brief-check   symlinks into this kit
#   ~/.claude/skills/<name>/        each skill under skills/, replaced whole
#   ~/.config/systemd/user/handoff-watchdog@.service and .timer   copied from systemd/
#   ~/.hermes/profiles/{review,run,close}   only with --hermes-profiles: each missing profile
#                                  is built from hermes/profiles/, an existing one is never touched
# A flag left out keeps the value config.env already has. The environment's VAULT,
# HANDOFF_DEFAULTS and HANDOFF_PROJECTS are ignored here: the file must not take a value
# that one shell happened to export. Nothing is enabled: start/resume arm each plan's timer.
set -euo pipefail
KIT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
USAGE="usage: install.sh [--vault <dir>] [--defaults <path relative to the vault>] [--projects <dir>] [--hermes-profiles]"
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
usage() { printf '%s\n' "$USAGE" >&2; exit 2; }
[ -n "${HOME:-}" ] || die "HOME is not set"
CFG="$HOME/.config/handoff/config.env"
cfg_get() { [ -f "$CFG" ] && /usr/bin/grep -E "^$1=" "$CFG" | tail -n 1 | cut -d= -f2- | tr -d "\"'" || true; }
vault="" defaults="" projects="" hermes=0
while [ $# -gt 0 ]; do
  case "$1" in
    --vault|--defaults|--projects)
      [ $# -ge 2 ] || usage
      case "$1" in --vault) vault="$2" ;; --defaults) defaults="$2" ;; --projects) projects="$2" ;; esac
      shift 2 ;;
    --hermes-profiles) hermes=1; shift ;;
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
if [ "$hermes" = 1 ]; then
  for n in review run close; do [ -f "$KIT/hermes/profiles/$n/SOUL.md" ] || die "$KIT/hermes/profiles/$n/SOUL.md is missing"; done
  [ -d "$HOME/.hermes" ] || die "no $HOME/.hermes: install hermes first, or leave out --hermes-profiles"
fi
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
if [ "$hermes" = 1 ]; then
  hp="$HOME/.hermes/profiles"; made=0
  for n in review run close; do
    d="$hp/$n"
    if [ -e "$d" ] || [ -L "$d" ]; then echo "kept hermes profile $n: $d exists"; continue; fi
    mkdir -p "$hp"; t="$hp/.$n.tmp.$$"; rm -rf "$t"; mkdir "$t"
    cp "$KIT/hermes/profiles/$n/SOUL.md" "$t/SOUL.md"
    # The model: block only (it can hold a provider URL or a key): never printed, mode 600.
    if /usr/bin/grep -q '^model:' "$HOME/.hermes/config.yaml" 2>/dev/null; then
      ( umask 077; awk '/^model:/{f=1;print;next} f&&/^[^ ]/{f=0} f{print}' "$HOME/.hermes/config.yaml" >"$t/config.yaml" )
      chmod 600 "$t/config.yaml"; nocfg=0
    else nocfg=1; fi
    # Re-test right before the rename: a plain mv would move the temp dir into a directory that appeared meanwhile.
    if [ -e "$d" ] || [ -L "$d" ]; then rm -rf "$t"; echo "kept hermes profile $n: $d exists"; continue; fi
    mv "$t" "$d"; made=1; echo "installed hermes profile $n"
    [ "$nocfg" = 0 ] || echo "NOTE: hermes profile $n has no config.yaml: ~/.hermes/config.yaml has no model: block"
  done
  [ "$made" = 0 ] || echo "NOTE: new hermes profiles have no credentials: give each the .env or auth.json its provider needs"
fi
case ":${PATH:-}:" in *":$HOME/.local/bin:"*) ;; *) echo "NOTE: $HOME/.local/bin is not on PATH — add it, or the commands are not found by name" ;; esac
