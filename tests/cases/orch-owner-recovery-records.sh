#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

valid_resume_record() {
  printf '2026-01-01 00:00:00 RESUME backend=claude model=<stage defaults> publication-owner=%s from previous (handoff: ready) · baseline abcdef0 on feat/test, 0 dirty paths\n' "$1"
}
invalid_record() {
  case "$1" in
    spaced) printf '%s\n' '2026-01-02 00:00:00 RESUME backend=claude model=<stage defaults> publication-owner=super visor from malformed (handoff: ready) · baseline abcdef0 on feat/test, 0 dirty paths' ;;
    truncated) printf '%s\n' '2026-01-02 00:00:00 RESUME backend=claude model=<stage defaults> publication-owner=supervisor' ;;
  esac
}
hash_file() { python3 - "$1" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())
PY
}

for bad in spaced truncated; do
  for older in none runner supervisor; do
    suffix="$bad-$older"
    BRIEF="$(make_brief testsub "record-$suffix.md" ready)"
    PLAN="$(dirname "$BRIEF")/plan-$suffix.md"
    make_plan "$PLAN" "$BRIEF"
    BASE="${PLAN%.md}"
    EVENTS="$BASE.events.log"
    case "$older" in
      none) invalid_record "$bad" >"$EVENTS" ;;
      runner) valid_resume_record runner >"$EVENTS"; invalid_record "$bad" >>"$EVENTS" ;;
      supervisor) valid_resume_record supervisor >"$EVENTS"; invalid_record "$bad" >>"$EVENTS" ;;
    esac
    plan_hash="$(hash_file "$PLAN")"
    events_hash="$(hash_file "$EVENTS")"
    if OUT="$(orch resume "$PLAN" --backend claude 2>&1)"; then
      fail "accepted malformed owner-bearing record ($suffix): $OUT"
    fi
    printf '%s\n' "$OUT" | /usr/bin/grep -qF 'invalid recorded publication owner' || fail "malformed owner record was not explicitly refused ($suffix): $OUT"
    [ "$(hash_file "$PLAN")" = "$plan_hash" ] || fail "malformed owner record modified the plan ($suffix)"
    [ "$(hash_file "$EVENTS")" = "$events_hash" ] || fail "malformed owner record modified its event history ($suffix)"
    [ ! -e "$BASE.status.md" ] || fail "malformed owner record wrote status ($suffix)"
    [ ! -e "$BASE.baseline" ] || fail "malformed owner record wrote a baseline ($suffix)"
    [ ! -e "$BASE.lock" ] || fail "malformed owner record wrote a lock ($suffix)"
    [ ! -e "$BASE.stage" ] || fail "malformed owner record wrote a stage marker ($suffix)"
    [ ! -e "$BASE.driver.log" ] || fail "malformed owner record wrote a driver log ($suffix)"
    [ ! -e "$BASE.driver" ] || fail "malformed owner record created a driver snapshot ($suffix)"
    [ ! -f "$SANDBOX/state/calls.log" ] || fail "malformed owner record launched a stage ($suffix)"
    [ ! -f "$SANDBOX/state/gh.log" ] || fail "malformed owner record wrote through gh ($suffix)"
    [ "$(git -C "$SANDBOX/repo_under.test" branch --show-current)" = main ] || fail "malformed owner record moved the branch ($suffix)"
    if git --git-dir="$SANDBOX/origin.git" show-ref --verify --quiet refs/heads/feat/test; then
      fail "malformed owner record published a branch ($suffix)"
    fi
  done
done

# A genuinely legacy START/RESUME event has no owner key and retains runner defaults.
BRIEF="$(make_brief testsub legacy-record.md ready)"
PLAN="$(dirname "$BRIEF")/legacy-plan.md"
make_plan "$PLAN" "$BRIEF"
BASE="${PLAN%.md}"
printf '%s\n' '2026-01-01 00:00:00 RESUME backend=claude model=<stage defaults> from previous (handoff: ready) · baseline abcdef0 on feat/test, 0 dirty paths' >"$BASE.events.log"
printf 'pid 999999999 started 0 never\n' >"$BASE.lock"
OUT="$(orch stop "$PLAN" 2>&1)" || fail "legacy owner-absent recovery failed: $OUT"
assert_contains "${PLAN%.md}.status.md" "handoff-orchestrate resume $PLAN --backend claude --publication-owner runner"
printf '%s\n' "$OUT" | /usr/bin/grep -qF -- "--publication-owner runner" || fail "legacy recovery did not retain runner default: $OUT"

echo ok
