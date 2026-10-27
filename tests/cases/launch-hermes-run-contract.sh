#!/usr/bin/env bash
# Validate real argv, while missing output must still fail closed.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init
cp "$FAKES_DIR/hermes-run-contract" "$SANDBOX/bin/hermes"
chmod +x "$SANDBOX/bin/hermes"
mkdir -p "$SANDBOX/home/.hermes/profiles/run"
printf 'model:\n  default: profile/run-model\nagent:\n  reasoning_effort: high\n' >"$SANDBOX/home/.hermes/profiles/run/config.yaml"
BRIEF="$(make_brief 'sub with spaces' 'brief with spaces.md' ready)"
cp "$BRIEF" "$SANDBOX/brief-original"
NOTE="$SANDBOX/continuation with spaces.txt"
printf 'Continue only the remaining task; preserve prior verified work.\n' >"$NOTE"
mv "$SANDBOX/repo_under.test" "$SANDBOX/repo with spaces"
python3 - "$BRIEF" "$SANDBOX" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('repo_under.test', 'repo with spaces'))
PY
cp "$BRIEF" "$SANDBOX/brief-original"
errors=0
for stage in run resume; do
  for override in no yes; do
    python3 - "$BRIEF" "$stage" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
p.write_text(re.sub(r'^handoff: .*$', 'handoff: ' + ('ready' if sys.argv[2] == 'run' else 'running'), p.read_text(), flags=re.M))
PY
    args=()
    [ "$stage" = resume ] && args=(--session 'session with spaces' --note "$NOTE")
    [ "$override" = yes ] && args+=(--model 'explicit/model with spaces')
    OUT="$(launch "$stage" "$BRIEF" --delegate --backend hermes "${args[@]}" 2>&1)"; RC=$?
    if [[ "$OUT" != *'Offline run contract accepted;'* ]]; then
      printf 'REGRESSION %s (%s): exit %s\n%s\n' "$stage" "$override" "$RC" "$OUT"
      errors=$((errors+1))
    fi
    # A validated prompt is not evidence of completed implementation.
    assert_eq "$RC" 1
    assert_eq "$(state_of "$BRIEF")" running
    assert_no_file "${BRIEF%.md}.report.md"
    expected='profile/run-model'
    [ "$override" = yes ] && expected='explicit/model with spaces'
    [[ "$OUT" == *"profile=run model=$expected"* ]] || fail "wrong profile/model: $OUT"
  done
done
[ "$errors" -eq 0 ] || fail "$errors run/resume prompt contracts rejected"
python3 - "$SANDBOX/state/hermes.jsonl" "$SANDBOX" "$NOTE" <<'PY' || fail 'run/resume argv assertions'
import json, pathlib, re, sys
root, note = sys.argv[2:]
rows = [json.loads(line) for line in open(sys.argv[1])]
assert len(rows) == 4
for row, stage, override in zip(rows, ['run']*2 + ['resume']*2, [False, True]*2):
    argv = row['argv']
    assert not row['errors'], row['errors']
    assert argv[:2] == ['-p', 'run']
    assert argv[argv.index('--in')+1] == root + '/repo with spaces'
    assert row['cwd'] == root + '/repo with spaces'
    assert ('-m' in argv) == override
    if override:
        assert argv[argv.index('-m')+1] == 'explicit/model with spaces'
    assert ('--resume' in argv) == (stage == 'resume')
    if stage == 'resume':
        assert argv[-2:] == ['--resume', 'session with spaces']
    assert '--effort' not in argv and '--yolo' not in argv
    prompt = argv[argv.index('-z')+1]
    assert prompt.startswith('Standing rules for every handoff run.')
    assert 'git push origin <branch>' in prompt
    assert 'Never a bare `git push`' in prompt
    assert 'Write no planning or report .md file into the repo.' in prompt
    marker = '=== BRIEF ===' if stage == 'run' else '=== CONTINUATION NOTE ==='
    payload = prompt.split(marker + '\n', 1)[1]
    expected = pathlib.Path(root + '/brief-original' if stage == 'run' else note).read_text().rstrip('\n')
    if stage == 'run':
        # The launcher refreshes only the frontmatter date before dispatch.
        payload = re.sub(r'^updated: .*$', 'updated: DATE', payload, flags=re.M)
        expected = re.sub(r'^updated: .*$', 'updated: DATE', expected, flags=re.M)
    assert payload == expected, (stage, payload)
    # The exact report template must be present, unchanged, for both stages.
    assert prompt.count('\n=== COMPLETION REPORT ===\n') == 1
    assert prompt.count('\n=== END COMPLETION REPORT ===\n') == 1
print('4 executable Hermes run/resume contracts accepted; no artifacts fabricated')
PY
echo ok
