#!/usr/bin/env bash
# Exercise actual argv dispatch, not only dry-run wording. The fake never edits notes.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init
cp "$FAKES_DIR/hermes" "$SANDBOX/bin/hermes"
chmod +x "$SANDBOX/bin/hermes"
mkdir -p "$SANDBOX/home/.hermes"
printf 'model:\n  default: profile/model\n' >"$SANDBOX/home/.hermes/config.yaml"
BRIEF="$(make_brief 'sub with spaces' 'brief with spaces.md' reviewed)"
printf 'review fixture\n' >"${BRIEF%.md}.review.md"
printf 'report fixture\n' >"${BRIEF%.md}.report.md"
mv "$SANDBOX/vault" "$SANDBOX/notes with spaces"
NOTES="$SANDBOX/notes with spaces"
BRIEF="$NOTES/${BRIEF#"$SANDBOX/vault/"}"
for skill in handoff-revise debrief; do
  mkdir -p "$NOTES/.agents/skills/$skill"
  printf 'Authoritative fixture instructions.\n' >"$NOTES/.agents/skills/$skill/SKILL.md"
done
notes_launch() {
  _sbx_env
  env -i "${SBX_ENV[@]}" "VAULT=$NOTES" "HERMES_BIN=$SANDBOX/bin/hermes" \
    bash "$SANDBOX/kit/handoff-launch.sh" "$@"
}
errors=0
for stage in revise debrief; do
  initial=reviewed; [ "$stage" = debrief ] && initial=reported
  python3 - "$BRIEF" "$initial" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
path.write_text(re.sub(r'^handoff: .*$', 'handoff: ' + sys.argv[2], path.read_text(), flags=re.M))
PY
  for override in no yes; do
    args=()
    [ "$override" = yes ] && args=(--model 'explicit/model with spaces')
    OUT="$(notes_launch "$stage" "$BRIEF" --backend hermes "${args[@]}" 2>&1)"; RC=$?
    if [ "$RC" -ne 0 ]; then
      printf 'REGRESSION %s (%s): exit %s\n%s\n' "$stage" "$override" "$RC" "$OUT"
      errors=$((errors+1))
    else
      expected='profile/model'
      [ "$override" = yes ] && expected='explicit/model with spaces'
      [[ "$OUT" == *"profile=default model=$expected"* ]] || fail "wrong selected profile/model: $OUT"
    fi
    assert_eq "$(state_of "$BRIEF")" "$initial" 'fake must not invent a transition'
  done
done
[ "$errors" -eq 0 ] || fail "$errors notes-stage invocations rejected"
python3 - "$SANDBOX/state/hermes.jsonl" "$NOTES" "$BRIEF" <<'PY' || fail 'notes task/argv assertions'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1])]
root, brief = sys.argv[2:]
assert len(records) == 4
for record, stage, override in zip(records, ['revise']*2 + ['debrief']*2, [False, True]*2):
    argv = record['argv']
    skill = 'handoff-revise' if stage == 'revise' else 'debrief'
    assert argv[:2] == ['-p', 'default'], argv
    assert record['cwd'] == root
    assert argv[argv.index('--in')+1] == root
    prompt = argv[argv.index('-z')+1]
    assert not prompt.lstrip().startswith('/')
    assert 'Read the authoritative local skill instructions' in prompt
    assert 'Do not ask questions' in prompt
    assert 'Do not substitute' in prompt
    task = json.loads(prompt.split('=== NOTES TASK ===\n', 1)[1])
    artifact = brief[:-3] + ('.review.md' if stage == 'revise' else '.report.md')
    assert task == {'notes_root': root, 'skill': skill,
                    'skill_file': root + '/.agents/skills/' + skill + '/SKILL.md',
                    'arguments': ['sub with spaces', artifact[len(root)+1:], 'unattended']}, task
    assert argv[-2:] == ['-z', prompt]
    assert ('-m' in argv) == override
    if override:
        assert argv[argv.index('-m')+1] == 'explicit/model with spaces'
    assert '--effort' not in argv and '--yolo' not in argv
PY
# Acceptance of a prompt is not a gate verdict. No token/state -> held as before.
python3 - "$BRIEF" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace('handoff: reported', 'handoff: reviewed'))
PY
OUT="$(notes_launch loop "$BRIEF" --backend hermes --gate auto 2>&1)"; RC=$?
assert_eq "$RC" 10
assert_eq "$(state_of "$BRIEF")" reviewed
# A missing authoritative file must fail before dispatch, never improvise a skill.
for skill in handoff-revise debrief; do
  rm "$NOTES/.agents/skills/$skill/SKILL.md"
  stage=revise; [ "$skill" = debrief ] && stage=debrief
  before="$(wc -l <"$SANDBOX/state/hermes.jsonl")"
  OUT="$(notes_launch "$stage" "$BRIEF" --backend hermes 2>&1)"; RC=$?
  [ "$RC" -ne 0 ] || fail 'missing skill accepted'
  assert_eq "$(wc -l <"$SANDBOX/state/hermes.jsonl")" "$before"
  assert_eq "$(state_of "$BRIEF")" reviewed
done
echo ok
