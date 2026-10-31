#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init

PLAN_BRIEF="$(make_brief testsub merge-brief.md draft)"
PLAN="$(dirname "$PLAN_BRIEF")/merge-plan.md"
make_plan "$PLAN" "$PLAN_BRIEF"
python3 - "$PLAN" <<'PY'
import sys
p=sys.argv[1]
s=open(p, encoding='utf-8').read().replace("notify: ''", "notify: telegram")
open(p, 'w', encoding='utf-8').write(s)
PY
mkdir -p "$SANDBOX/home/.config/handoff"
printf 'TELEGRAM_BOT_TOKEN=fake\nTELEGRAM_CHAT_ID=fake\n' >"$SANDBOX/home/.config/handoff/notify.env"
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$SANDBOX/repo_under.test" true >/dev/null

# The fake API returns controlled pull-request rows and rejects any request that
# could implicitly mutate a resource.
cat >"$SANDBOX/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_STATE_DIR/gh.log"
if [ "${1:-}" = api ]; then
  shift
  args="$*"
  case " $args " in *' -f '*|*' --field '*)
    case " $args " in *' -X GET '*) ;; *) echo 'unsafe request: fields without GET' >&2; exit 9 ;; esac ;;
  esac
  [ "${FAKE_GH_FAIL:-0}" = 1 ] && { echo failure >&2; exit 1; }
  case "$args" in
    *'head='*/*:*) echo 'invalid head filter' >&2; exit 8 ;;
  esac
  case "$args" in
    *'/pulls/'[0-9]*) printf '%s\n' "$FAKE_GH_PR_RESPONSE"; exit 0 ;;
  esac
  printf '%s\n' "${FAKE_GH_RESPONSE:-[]}"
  exit 0
fi
case "${1:-}:${2:-}" in pr:list) printf '%s\n' 'https://github.com/test/repo/pull/9' ;; esac
exit 0
GH
chmod +x "$SANDBOX/bin/gh"
cat >"$SANDBOX/bin/git" <<'GIT'
#!/usr/bin/env bash
for arg in "$@"; do [ "$arg" = fetch ] && exit 0; done
exec /usr/bin/git "$@"
GIT
chmod +x "$SANDBOX/bin/git"
git -C "$SANDBOX/repo_under.test" remote set-url origin https://github.com/test/repo
cat >"$SANDBOX/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_STATE_DIR/curl.log"
CURL
chmod +x "$SANDBOX/bin/curl"
touch "$SANDBOX/state/launchctl.on"
export FAKE_GH_RESPONSE='[]'
merge_state() {
  env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" \
    FAKE_STATE_DIR="$SANDBOX/state" FAKE_GH_RESPONSE="$1" FAKE_GH_FAIL="${2:-0}" \
    FAKE_GH_PR_RESPONSE="${3-}" \
    GH_TOKEN=fake GH_HOST=github.com python3 "$SANDBOX/kit/handoff-merge.py" merge-state \
      --repository test/repo --branch feat/test --base main
}
foreign='[{"number":2,"state":"closed","merged_at":"2026-01-01T00:00:00Z","merge_commit_sha":"foreign-merge","head":{"sha":"foreign-head","ref":"feat/test","repo":{"full_name":"fork/repo"}},"base":{"ref":"main","repo":{"full_name":"test/repo"}}}]'
[ "$(merge_state "$foreign")" = absent ] || fail "foreign fork PR was not ignored"
opened='[{"number":3,"state":"open","merged_at":null,"merge_commit_sha":null,"head":{"sha":"1111111111111111111111111111111111111111","ref":"feat/test","repo":{"full_name":"test/repo"}},"base":{"ref":"main","repo":{"full_name":"test/repo"}}}]'
[ "$(merge_state "$opened")" = 'open 3 1111111111111111111111111111111111111111' ] || fail "open PR response form was wrong"
merged='[{"number":4,"state":"closed","merged_at":"2026-01-01T00:00:00Z","merge_commit_sha":"2222222222222222222222222222222222222222","head":{"sha":"3333333333333333333333333333333333333333","ref":"feat/test","repo":{"full_name":"test/repo"}},"base":{"ref":"main","repo":{"full_name":"test/repo"}}}]'
pr_get='{"number":4,"state":"closed","merged":true,"mergeable_state":"unknown","body":"","merge_commit_sha":"2222222222222222222222222222222222222222","head":{"sha":"3333333333333333333333333333333333333333","ref":"feat/test","repo":{"full_name":"test/repo"}},"base":{"ref":"main","repo":{"full_name":"test/repo"}}}'
before_get="$(wc -l <"$SANDBOX/state/gh.log")"
merged_result="$(merge_state "$merged" 0 "$pr_get" 2>&1)" || fail "merged PR verification failed: $merged_result"
[ "$merged_result" = 'merged 2222222222222222222222222222222222222222 3333333333333333333333333333333333333333' ] || fail "merged PR response form was wrong: $merged_result"
[ "$(wc -l <"$SANDBOX/state/gh.log")" -eq "$((before_get + 2))" ] || fail "merged list item was not verified by one single-PR GET"
/usr/bin/grep -q 'head=test:feat/test' "$SANDBOX/state/gh.log" || fail "list head filter did not use owner login"
older_and_newer="$(python3 - "$merged" <<'PY'
import json, sys
old=json.loads(sys.argv[1])[0]
new=json.loads(json.dumps(old)); new['number']=6; new['merged_at']='2026-02-01T00:00:00Z'
new['merge_commit_sha']='5555555555555555555555555555555555555555'
new['head']['sha']='6666666666666666666666666666666666666666'
print(json.dumps([new, old]))
PY
)"
new_get="${pr_get/2222222222222222222222222222222222222222/5555555555555555555555555555555555555555}"
new_get="${new_get/3333333333333333333333333333333333333333/6666666666666666666666666666666666666666}"
[ "$(merge_state "$older_and_newer" 0 "$new_get")" = 'merged 5555555555555555555555555555555555555555 6666666666666666666666666666666666666666' ] || fail "most recently merged matching PR was not selected"
prefer_open="$(python3 - "$opened" "$merged" <<'PY'
import json, sys
print(json.dumps(json.loads(sys.argv[1]) + json.loads(sys.argv[2])))
PY
)"
[ "$(merge_state "$prefer_open")" = 'open 3 1111111111111111111111111111111111111111' ] || fail "open PR did not take precedence over merged PR"
ambiguous="$(python3 - "$opened" <<'PY'
import json, sys
row=json.loads(sys.argv[1])[0]
other=json.loads(json.dumps(row)); other['number']=5
print(json.dumps([row, other]))
PY
)"
OUT="$(merge_state "$ambiguous" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | /usr/bin/grep -q ambiguous || fail "multiple open PRs were not rejected: $OUT"
OUT="$(merge_state '[]' 1 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || fail "merge-state API failure returned success"
/usr/bin/grep -q -- '-X GET ' "$SANDBOX/state/gh.log" || fail "merge-state did not use explicit GET requests"
if /usr/bin/grep -E 'api -X (POST|PUT|DELETE)' "$SANDBOX/state/gh.log" >/dev/null; then fail "merge-state used a mutating HTTP method"; fi
merge_orch() {
  _sbx_env
  env -i "${SBX_ENV[@]}" GH_TOKEN=fake GH_HOST=github.com \
    FAKE_GH_RESPONSE="${FAKE_GH_RESPONSE:-[]}" FAKE_GH_FAIL="${FAKE_GH_FAIL:-0}" \
    FAKE_GH_PR_RESPONSE="${FAKE_GH_PR_RESPONSE-}" \
    bash "$SANDBOX/kit/handoff-orchestrate.sh" resume "$PLAN" --backend claude --publication-owner supervisor
}

orch start "$PLAN" --backend claude --publication-owner supervisor >/dev/null 2>&1
wait_merge() {
  /usr/bin/grep -q '^orchestration: awaiting-merge' "$PLAN" 2>/dev/null \
    && /usr/bin/grep -q 'AWAITING MERGE' "${PLAN%.md}.events.log" 2>/dev/null
}
wait_for 90 wait_merge || fail "plan did not enter awaiting-merge: $(head -1 "${PLAN%.md}.status.md" 2>/dev/null)"
EVENTS="${PLAN%.md}.events.log"
assert_contains "$EVENTS" 'BRIEF CLOSED'
assert_contains "$EVENTS" 'AWAITING MERGE'
closed_line="$(/usr/bin/grep -n 'BRIEF CLOSED' "$EVENTS" | tail -1 | cut -d: -f1)"
awaiting_line="$(/usr/bin/grep -n 'AWAITING MERGE' "$EVENTS" | tail -1 | cut -d: -f1)"
[ "$awaiting_line" -gt "$closed_line" ] || fail "AWAITING MERGE event preceded BRIEF CLOSED"
reviewed_before="$(/usr/bin/grep -m1 '^final-reviewed-head:' "$PLAN" | cut -d: -f2- | tr -d ' ')"
[ "$reviewed_before" = "$(git -C "$SANDBOX/repo_under.test" rev-parse HEAD)" ] || fail "plan did not persist exact reviewed head"
status_line="$(head -1 "${PLAN%.md}.status.md")"
case "$status_line" in AWAITING\ MERGE*) ;; *) fail "status did not start with AWAITING MERGE: $status_line" ;; esac
assert_contains "${PLAN%.md}.status.md" 'PR: https://github.com/test/repo/pull/9'
[ -f "$(git -C "$SANDBOX/repo_under.test" rev-parse --absolute-git-dir)/handoff-plan.lock" ] || fail "checkout lock was released"
assert_no_file "${PLAN%.md}.lock"
[ "$(/usr/bin/grep -c 'disable_notification=false' "$SANDBOX/state/curl.log" 2>/dev/null || true)" -gt 0 ] || fail "awaiting-merge notification was not loud"
if /usr/bin/grep -q 'disable --now' "$SANDBOX/state/systemctl.log" 2>/dev/null || /usr/bin/grep -q 'bootout' "$SANDBOX/state/launchctl.log" 2>/dev/null; then fail "watchdog retired while awaiting merge"; fi

OTHER_BRIEF="$(make_brief testsub other.md draft)"
OTHER_PLAN="$(dirname "$OTHER_BRIEF")/other-plan.md"
make_plan "$OTHER_PLAN" "$OTHER_BRIEF"
OUT="$(orch start "$OTHER_PLAN" --backend claude --publication-owner supervisor 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || fail "second plan started on held checkout"
case "$OUT" in *'held by'*) ;; *) fail "checkout refusal did not name holder: $OUT" ;; esac
OUT="$(orch start "$PLAN" --backend claude --publication-owner supervisor 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | /usr/bin/grep -qi resume || fail "start did not direct user to resume: $OUT"
claude_before="$(wc -l <"$SANDBOX/state/calls.log")"
OUT="$(orch tick "$PLAN" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "driverless awaiting-merge tick failed: $OUT"
[ "$(wc -l <"$SANDBOX/state/calls.log")" -eq "$claude_before" ] || fail "tick invoked another stage"

run_state() {
  local response="$1" expected_rc="$2" expected="$3" before after output rc
  export FAKE_GH_RESPONSE="$response"
  before="$(wc -l <"$SANDBOX/state/calls.log")"
  output="$(merge_orch 2>&1)"; rc=$?
  [ "$rc" -eq "$expected_rc" ] || fail "resume rc $rc, wanted $expected_rc: $output"
  after="$(wc -l <"$SANDBOX/state/calls.log")"
  [ "$before" -eq "$after" ] || fail "resume launched a stage"
  [ "$(/usr/bin/grep -m1 '^orchestration:' "$PLAN")" = 'orchestration: awaiting-merge' ] || [ "$expected" = done ] || fail "resume changed state: $expected"
  case "$expected" in
    open) case "$output" in *'still awaiting merge'*) ;; *) fail "open response not explained: $output" ;; esac ;;
    absent) case "$output" in *'still awaiting merge'*) ;; *) fail "absent response not explained: $output" ;; esac ;;
    stale)
      case "$output" in *'reviewed head'*'deadbee'*) ;; *) fail "stale merge mismatch did not name both heads: $output" ;; esac
      assert_contains "$EVENTS" 'AWAITING MERGE'
      ! /usr/bin/grep -q 'MERGE VERIFIED' "$EVENTS" || fail "stale merge was verified"
      ;;
    fail) case "$output" in *'failed'*) ;; *) fail "API failure not named: $output" ;; esac ;;
  esac
}
run_state '[{"number":7,"state":"open","merged_at":null,"merge_commit_sha":null,"head":{"sha":"reviewed-head","ref":"feat/test","repo":{"full_name":"test/repo"}},"base":{"ref":"main","repo":{"full_name":"test/repo"}}}]' 1 open
plan_before="$(sha256sum "$PLAN" | cut -d' ' -f1)"
run_state '[]' 1 absent
[ "$(sha256sum "$PLAN" | cut -d' ' -f1)" = "$plan_before" ] || fail "absent response changed plan file"
FAKE_GH_PR_RESPONSE='{"number":8,"state":"closed","merged":true,"merge_commit_sha":"4444444444444444444444444444444444444444","head":{"sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","ref":"feat/test","repo":{"full_name":"test/repo"}},"base":{"ref":"main","repo":{"full_name":"test/repo"}}}'
run_state '[{"number":8,"state":"closed","merged_at":"2026-01-01T00:00:00Z","merge_commit_sha":"4444444444444444444444444444444444444444","head":{"sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","ref":"feat/test","repo":{"full_name":"test/repo"}},"base":{"ref":"main","repo":{"full_name":"test/repo"}}}]' 1 stale
export FAKE_GH_FAIL=1
run_state '[]' 1 fail
unset FAKE_GH_FAIL

# The reviewed head is the plan's final reviewed head, exposed by the final-review evidence.
reviewed="$(git -C "$SANDBOX/repo_under.test" rev-parse HEAD)"
python3 - "$PLAN" "$reviewed" <<'PY'
import sys
p, sha = sys.argv[1:]
s=open(p, encoding='utf-8').read()
if 'final-reviewed-head:' not in s:
    s=s.replace('orchestration: awaiting-merge', 'orchestration: awaiting-merge\nfinal-reviewed-head: '+sha)
else:
    import re
    s=re.sub(r'^final-reviewed-head:.*$', 'final-reviewed-head: '+sha, s, flags=re.M)
open(p, 'w', encoding='utf-8').write(s)
PY
export FAKE_GH_RESPONSE="[{\"number\":9,\"state\":\"closed\",\"merged_at\":\"2026-01-01T00:00:00Z\",\"merge_commit_sha\":\"4444444444444444444444444444444444444444\",\"head\":{\"sha\":\"$reviewed\",\"ref\":\"feat/test\",\"repo\":{\"full_name\":\"test/repo\"}},\"base\":{\"ref\":\"main\",\"repo\":{\"full_name\":\"test/repo\"}}}]"
export FAKE_GH_PR_RESPONSE="{\"number\":9,\"state\":\"closed\",\"merged\":true,\"merge_commit_sha\":\"4444444444444444444444444444444444444444\",\"head\":{\"sha\":\"$reviewed\",\"ref\":\"feat/test\",\"repo\":{\"full_name\":\"test/repo\"}},\"base\":{\"ref\":\"main\",\"repo\":{\"full_name\":\"test/repo\"}}}"
before="$(wc -l <"$SANDBOX/state/calls.log")"
OUT="$(merge_orch 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "verified merge resume failed: $OUT"
[ "$(/usr/bin/grep -m1 '^orchestration:' "$PLAN")" = 'orchestration: done' ] || fail "verified merge did not finish plan"
assert_contains "$EVENTS" 'MERGE VERIFIED'
[ ! -f "$(git -C "$SANDBOX/repo_under.test" rev-parse --absolute-git-dir)/handoff-plan.lock" ] || fail "checkout lock not released"
/usr/bin/grep -q 'disable --now' "$SANDBOX/state/systemctl.log" 2>/dev/null || /usr/bin/grep -q 'bootout' "$SANDBOX/state/launchctl.log" 2>/dev/null || fail "watchdog not retired after merge"
[ "$(wc -l <"$SANDBOX/state/calls.log")" -eq "$before" ] || fail "verified merge launched a stage"

count_final() {
  python3 - "$SANDBOX/state/calls.log" <<'PY'
import json, os, sys
p=sys.argv[1]
rows=[json.loads(line) for line in open(p, encoding='utf-8')] if os.path.exists(p) else []
print(sum(row.get('stage') == 'final-review' for row in rows))
PY
}
final_count="$(count_final)"
MANUAL_BRIEF="$(make_brief testsub manual-merge.md draft)"
MANUAL_PLAN="$(dirname "$MANUAL_BRIEF")/manual-merge-plan.md"
make_plan "$MANUAL_PLAN" "$MANUAL_BRIEF"
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$SANDBOX/repo_under.test" false >/dev/null
orch start "$MANUAL_PLAN" --backend claude --publication-owner supervisor >/dev/null 2>&1
manual_done() { /usr/bin/grep -q '^orchestration: done' "$MANUAL_PLAN" 2>/dev/null; }
wait_for 90 manual_done || fail "manual policy did not remain on the done path"
[ "$(count_final)" -eq "$final_count" ] || fail "manual policy invoked final review"
/usr/bin/grep -q 'AWAITING MERGE' "${MANUAL_PLAN%.md}.events.log" 2>/dev/null && fail "manual policy logged awaiting-merge"

GITLAB_BRIEF="$(make_brief testsub gitlab-merge.md draft)"
GITLAB_PLAN="$(dirname "$GITLAB_BRIEF")/gitlab-merge-plan.md"
make_plan "$GITLAB_PLAN" "$GITLAB_BRIEF"
git -C "$SANDBOX/repo_under.test" remote set-url origin https://gitlab.com/test/repo
env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" python3 "$SANDBOX/kit/handoff-merge.py" policy-set --repo "$SANDBOX/repo_under.test" true >/dev/null
orch start "$GITLAB_PLAN" --backend claude --publication-owner supervisor >/dev/null 2>&1
gitlab_done() { /usr/bin/grep -q '^orchestration: done' "$GITLAB_PLAN" 2>/dev/null; }
wait_for 90 gitlab_done || fail "GitLab auto policy did not use the done path"
[ "$(count_final)" -eq "$final_count" ] || fail "GitLab auto policy invoked final review"
/usr/bin/grep -q 'AWAITING MERGE' "${GITLAB_PLAN%.md}.events.log" 2>/dev/null && fail "GitLab auto policy logged awaiting-merge"

FAIL_BRIEF="$(make_brief testsub failed-review.md draft)"
FAIL_PLAN="$(dirname "$FAIL_BRIEF")/failed-review-plan.md"
make_plan "$FAIL_PLAN" "$FAIL_BRIEF"
git -C "$SANDBOX/repo_under.test" remote set-url origin https://github.com/test/repo
FAKE_CLAUDE=final-review=blockers
orch start "$FAIL_PLAN" --backend claude --publication-owner supervisor >/dev/null 2>&1
failed_review() { /usr/bin/grep -q '^orchestration: broken' "$FAIL_PLAN" 2>/dev/null; }
wait_for 90 failed_review || fail "final-review FAIL did not break the plan"
/usr/bin/grep -q 'final-review' "${FAIL_PLAN%.md}.events.log" || fail "broken state reason omitted final-review"
/usr/bin/grep -q 'AWAITING MERGE' "${FAIL_PLAN%.md}.events.log" 2>/dev/null && fail "failed review entered awaiting-merge"

echo ok
