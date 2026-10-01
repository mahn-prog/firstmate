#!/usr/bin/env bash
# fm-worker-park.sh: automatic parking of idle ship and scout workers.
#
# These tests drive the real park executable against a temp home. The two
# collaborators it delegates to are stubbed through their seams: the current
# state reader (FM_CREW_STATE_BIN) and the lifecycle owner
# (FM_WORKER_PARK_CONTROL_BIN), so the park policy is pinned without an agent.
# fm-control's own --idle-only guard is pinned in tests/fm-control.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PARK="$ROOT/bin/fm-worker-park.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-park)

# new_home <name> -> echoes a home with one idle ship task t1 and the stubs.
# The stubbed crew state is read from stub/crew-<id>; the stubbed control plane
# appends its argv to stub/control.log and exits with stub/control-rc.
new_home() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/data/t1" "$dir/config" "$dir/stub/bin" "$dir/wt-t1"
  printf '# brief\n' > "$dir/data/t1/brief.md"
  cat > "$dir/stub/bin/crew-state" <<'SH'
#!/usr/bin/env bash
cat "$FM_TEST_STUB/crew-$1" 2>/dev/null || echo "state: unknown · source: none · no stub"
SH
  cat > "$dir/stub/bin/control" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_STUB/control.log"
if [ "$2" = relaunch ]; then
  # A relaunch republishes the record with a new incarnation, as fm-spawn does.
  sed -i.bak "s/^spawn_gen=.*/spawn_gen=s-relaunched/" "$FM_HOME/state/$1.meta"
fi
cat "$FM_TEST_STUB/control-out" 2>/dev/null
exit "$(cat "$FM_TEST_STUB/control-rc" 2>/dev/null || echo 0)"
SH
  chmod +x "$dir/stub/bin/crew-state" "$dir/stub/bin/control"
  add_task "$dir" t1
  printf '%s\n' "$dir"
}

add_task() {  # <home> <id> [kind] [extra meta lines...]
  local dir=$1 id=$2 kind=${3:-ship}
  shift 3 2>/dev/null || shift $#
  mkdir -p "$dir/wt-$id" "$dir/data/$id"
  fm_write_meta "$dir/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" "worktree=$dir/wt-$id" \
    "harness=claude" "kind=$kind" "mode=direct-PR" "spawn_gen=s-$id" "$@"
}

crew() {  # <home> <id> <crew-state line>
  printf '%s\n' "$3" > "$1/stub/crew-$2"
}

status() {  # <home> <id> <status line>
  printf '%s\n' "$3" >> "$1/state/$2.status"
}

run_park() {  # <home> <args...>
  local dir=$1
  shift
  env FM_HOME="$dir" FM_TEST_STUB="$dir/stub" \
    FM_CREW_STATE_BIN="$dir/stub/bin/crew-state" \
    FM_WORKER_PARK_CONTROL_BIN="$dir/stub/bin/control" \
    FM_WORKER_PARK_GRACE_SECS="${GRACE:-0}" \
    "$PARK" "$@" 2>&1
}

control_log() {
  cat "$1/stub/control.log" 2>/dev/null || true
}

# --- park -------------------------------------------------------------------

test_done_worker_is_parked_after_grace() {
  local dir out
  dir=$(new_home finished)
  status "$dir" t1 "done [at=1]: PR https://github.com/o/r/pull/7"
  crew "$dir" t1 "state: done · source: status-log · PR https://github.com/o/r/pull/7"
  out=$(run_park "$dir" scan)
  assert_equals "" "$(control_log "$dir")" "the first sighting only starts the grace clock"$'\n'"$out"
  out=$(run_park "$dir" scan)
  assert_equals "t1 exit --idle-only" "$(control_log "$dir")" "a done worker past its grace is stopped idle-only"$'\n'"$out"
  assert_present "$dir/state/t1.worker-park" "the park writes its marker"
  assert_contains "$(cat "$dir/state/worker-park.log")" "t1 parked" "the park is logged"
  pass "a done worker is parked through the idle-only exit once its grace elapses"
}

# scan twice, so an unchanged waiting signature can clear a zero grace.
scan2() {  # <home>
  run_park "$1" scan >/dev/null
  run_park "$1" scan
}

test_each_waiting_state_is_parked() {
  local dir case_ status_line crew_line
  while IFS='|' read -r case_ status_line crew_line; do
    dir=$(new_home "wait-$case_")
    status "$dir" t1 "$status_line"
    crew "$dir" t1 "$crew_line"
    scan2 "$dir" >/dev/null
    assert_equals "t1 exit --idle-only" "$(control_log "$dir")" "a $case_ worker should be parked"
    assert_present "$dir/state/t1.worker-park" "a $case_ park writes its marker"
  done <<'EOF'
scout-done|done [at=1]: report at data/t1/report.md|state: done · source: status-log · report at data/t1/report.md
paused|paused [at=1]: waiting on vendor until 2099-01-01T00:00Z|state: paused · source: status-log · waiting on vendor
needs-decision|needs-decision [at=1]: pick A or B|state: parked · source: status-log · pick A or B
blocked|blocked [at=1]: need a credential|state: blocked · source: status-log · need a credential
captain-held|captain-held [at=1]: held for the captain|state: unknown · source: none · no current-state source available
EOF
  pass "done, paused, needs-decision, blocked, and captain-held workers are each parked"
}

test_active_workers_are_never_parked() {
  local dir case_ status_line crew_line
  while IFS='|' read -r case_ status_line crew_line; do
    dir=$(new_home "active-$case_")
    status "$dir" t1 "$status_line"
    crew "$dir" t1 "$crew_line"
    scan2 "$dir" >/dev/null
    assert_equals "" "$(control_log "$dir")" "a $case_ worker must not be stopped"
    assert_absent "$dir/state/t1.worker-park" "a $case_ worker gets no park marker"
  done <<'EOF'
working|working [at=1]: building|state: working · source: pane · harness busy (hook)
busy-after-done|done [at=1]: PR https://github.com/o/r/pull/7|state: working · source: pane · harness busy (hook)
validating|done [at=1]: PR https://github.com/o/r/pull/7|state: working · source: run-step · ci step running
gate|needs-decision [at=1]: gate finding|state: parked · source: run-step · awaiting_approval
failed|failed [at=1]: broke|state: failed · source: status-log · broke
EOF
  pass "working, busy, validating, gated, and failed workers are never parked"
}

test_unread_inbox_blocks_parking() {
  local dir
  dir=$(new_home inbox)
  status "$dir" t1 "done [at=1]: PR https://github.com/o/r/pull/7"
  crew "$dir" t1 "state: done · source: status-log · PR"
  mkdir -p "$dir/state/t1.inbox"
  printf 'schema=fm-task-inbox.v1\n--\nfix it\n' > "$dir/state/t1.inbox/001.msg"
  scan2 "$dir" >/dev/null
  assert_equals "" "$(control_log "$dir")" "a worker with an unread steer must not be parked"
  pass "an unread steering-inbox record keeps a waiting worker running"
}

test_grace_must_elapse() {
  local dir
  dir=$(new_home grace)
  status "$dir" t1 "done [at=1]: PR https://github.com/o/r/pull/7"
  crew "$dir" t1 "state: done · source: status-log · PR"
  GRACE=600 scan2 "$dir" >/dev/null
  assert_equals "" "$(control_log "$dir")" "a worker inside its grace must not be parked"
  pass "a waiting worker is not parked before its grace elapses"
}

test_changed_signature_restarts_the_grace_clock() {
  local dir
  dir=$(new_home resig)
  status "$dir" t1 "done [at=1]: PR https://github.com/o/r/pull/7"
  crew "$dir" t1 "state: done · source: status-log · PR"
  run_park "$dir" scan >/dev/null
  status "$dir" t1 "done [at=2]: PR https://github.com/o/r/pull/7 again"
  run_park "$dir" scan >/dev/null
  assert_equals "" "$(control_log "$dir")" "a new status line restarts the clock"
  run_park "$dir" scan >/dev/null
  assert_equals "t1 exit --idle-only" "$(control_log "$dir")" "an unchanged signature then parks"
  pass "any change to the waiting signature restarts the grace clock"
}

test_secondmates_and_unsupported_tasks_are_skipped() {
  local dir
  dir=$(new_home skip)
  rm -f "$dir/state/t1.meta"
  add_task "$dir" sm secondmate
  add_task "$dir" rm ship "remote_host=box"
  add_task "$dir" zj ship "backend=zellij"
  add_task "$dir" ls ship
  : > "$dir/state/.lease-ls"
  for id in sm rm zj ls; do
    status "$dir" "$id" "done [at=1]: finished"
    crew "$dir" "$id" "state: done · source: status-log · finished"
  done
  scan2 "$dir" >/dev/null
  assert_equals "" "$(control_log "$dir")" "secondmates, remote, unverified-backend, and leased tasks are never parked"
  pass "secondmates, remote placements, unverified backends, and leased tasks are skipped"
}

test_config_off_disables_parking() {
  local dir
  dir=$(new_home off)
  printf 'off\n' > "$dir/config/worker-park"
  status "$dir" t1 "done [at=1]: PR https://github.com/o/r/pull/7"
  crew "$dir" t1 "state: done · source: status-log · PR"
  scan2 "$dir" >/dev/null
  assert_equals "" "$(control_log "$dir")" "config off must park nothing"
  printf 'soon\n' > "$dir/config/worker-park"
  scan2 "$dir" >/dev/null
  assert_equals "" "$(control_log "$dir")" "an invalid config parks nothing"
  assert_equals 1 "$(grep -c config-invalid "$dir/state/worker-park.log")" "an invalid config is logged once"
  pass "config/worker-park off (or invalid) disables parking"
}

test_refused_park_is_logged_once_and_backed_off() {
  local dir
  dir=$(new_home refused)
  status "$dir" t1 "done [at=1]: PR https://github.com/o/r/pull/7"
  crew "$dir" t1 "state: done · source: status-log · PR"
  printf 'error: task t1 is busy; --idle-only refuses\n' > "$dir/stub/control-out"
  printf '1\n' > "$dir/stub/control-rc"
  scan2 "$dir" >/dev/null
  run_park "$dir" scan >/dev/null
  run_park "$dir" scan >/dev/null
  assert_equals "t1 exit --idle-only" "$(control_log "$dir")" "a refused park is not retried inside its backoff"
  assert_absent "$dir/state/t1.worker-park" "a refused park leaves no marker"
  assert_equals 1 "$(grep -c 'park-refused' "$dir/state/worker-park.log")" "the refusal is logged once"
  FM_WORKER_PARK_RETRY_SECS=0 run_park "$dir" scan >/dev/null
  assert_equals 2 "$(control_log "$dir" | wc -l | tr -d ' ')" "after the backoff the park is tried again"
  assert_equals 1 "$(grep -c 'park-refused' "$dir/state/worker-park.log")" "an identical refusal is not logged again"
  pass "a refused park leaves the worker alone, logs once, and backs off"
}

# --- unpark ------------------------------------------------------------------

parked_home() {  # <name> -> a home whose t1 is already parked
  local dir
  dir=$(new_home "$1")
  status "$dir" t1 "done [at=1]: PR https://github.com/o/r/pull/7"
  crew "$dir" t1 "state: done · source: status-log · PR"
  scan2 "$dir" >/dev/null
  : > "$dir/stub/control.log"
  printf '%s\n' "$dir"
}

test_steer_unparks_the_worker() {
  local dir out
  dir=$(parked_home steer)
  mkdir -p "$dir/state/t1.inbox"
  printf 'schema=fm-task-inbox.v1\n--\nfix it\n' > "$dir/state/t1.inbox/001.msg"
  out=$(run_park "$dir" scan)
  assert_contains "$(control_log "$dir")" "t1 relaunch --note" "an unread steer relaunches the parked worker"$'\n'"$out"
  assert_contains "$(control_log "$dir")" "inbox" "the relaunch note says why"
  assert_absent "$dir/state/t1.worker-park" "an unpark retires the marker"
  pass "an unread steer relaunches a parked worker and retires its marker"
}

test_explicit_unpark_and_idempotence() {
  local dir out rc
  dir=$(parked_home explicit)
  out=$(run_park "$dir" unpark t1 --reason "firstmate steer"); rc=$?
  expect_code 0 "$rc" "explicit unpark"$'\n'"$out"
  assert_contains "$(control_log "$dir")" "firstmate steer" "the reason reaches the relaunch note"
  out=$(run_park "$dir" unpark t1 --reason again); rc=$?
  expect_code 0 "$rc" "unparking an unparked worker is a no-op"
  assert_equals 1 "$(control_log "$dir" | wc -l | tr -d ' ')" "a no-op unpark sends nothing"
  pass "explicit unpark relaunches once and is idempotent"
}

test_refused_unpark_is_recorded_for_escalation() {
  local dir out rc
  dir=$(parked_home unpark-refused)
  printf 'error: another lifecycle action is already running\n' > "$dir/stub/control-out"
  printf '1\n' > "$dir/stub/control-rc"
  out=$(run_park "$dir" unpark t1 --reason steer); rc=$?
  expect_code 1 "$rc" "a refused unpark fails"
  assert_present "$dir/state/t1.worker-park" "a refused unpark keeps the worker parked"
  assert_contains "$(cat "$dir/state/t1.worker-park-refused")" "unpark" "the refusal is recorded for the watcher"
  pass "a refused unpark keeps the marker and records the refusal"
}

test_declared_wait_time_unparks() {
  local dir
  dir=$(new_home until)
  status "$dir" t1 "paused [at=1]: waiting on vendor until 2099-01-01T00:00Z"
  crew "$dir" t1 "state: paused · source: status-log · waiting on vendor"
  scan2 "$dir" >/dev/null
  assert_equals "t1 exit --idle-only" "$(control_log "$dir")" "the paused worker parks"
  run_park "$dir" scan >/dev/null
  assert_equals "t1 exit --idle-only" "$(control_log "$dir")" "before its wait time it stays parked"
  FM_WORKER_PARK_NOW=4102444800 run_park "$dir" scan >/dev/null
  assert_contains "$(control_log "$dir")" "t1 relaunch" "a passed declared wait time relaunches it"
  pass "a parked worker is relaunched once its declared wait time passes"
}

test_past_wait_time_does_not_cycle() {
  local dir
  dir=$(new_home until-past)
  status "$dir" t1 "paused [at=1]: waiting on vendor until 2001-01-01T00:00Z"
  crew "$dir" t1 "state: paused · source: status-log · waiting on vendor"
  scan2 "$dir" >/dev/null
  run_park "$dir" scan >/dev/null
  assert_equals "t1 exit --idle-only" "$(control_log "$dir")" "a wait time already past must not relaunch the worker it just parked"
  pass "a declared wait time already past when parking is not a relaunch cue"
}

test_validation_gate_unparks() {
  local dir case_ crew_line want
  while IFS='|' read -r case_ crew_line want; do
    dir=$(parked_home "run-$case_")
    crew "$dir" t1 "$crew_line"
    run_park "$dir" scan >/dev/null
    if [ -n "$want" ]; then
      assert_contains "$(control_log "$dir")" "$want" "$case_ relaunches the parked worker"
    else
      assert_equals "" "$(control_log "$dir")" "$case_ leaves the worker parked"
    fi
  done <<'EOF'
gate|state: parked · source: run-step · awaiting_approval|waiting at a gate
failed|state: failed · source: run-step · run failed|validation run failed
fixing|state: working · source: run-step · run active (fixing)|
EOF
  pass "a parked worker's validation run at a gate or failed relaunches it; a fixing run does not"
}

test_budget_rotation_reaches_every_task() {
  local dir i
  dir=$(new_home rotate)
  add_task "$dir" t2
  for id in t1 t2; do
    status "$dir" "$id" "done [at=1]: report at data/$id/report.md"
    crew "$dir" "$id" "state: done · source: status-log · report"
  done
  for i in 1 2 3 4 5 6; do
    FM_WORKER_PARK_MAX_READS=1 run_park "$dir" scan >/dev/null
  done
  assert_present "$dir/state/t1.worker-park" "t1 is parked"
  assert_present "$dir/state/t2.worker-park" "a task past a spent read budget is not starved"
  pass "the per-scan read budget rotates so every waiting task is reached"
}

test_relaunch_by_hand_invalidates_the_marker() {
  local dir
  dir=$(parked_home stale-marker)
  sed -i.bak 's/^spawn_gen=.*/spawn_gen=s-manual/' "$dir/state/t1.meta"
  mkdir -p "$dir/state/t1.inbox"
  printf 'schema=fm-task-inbox.v1\n--\nfix it\n' > "$dir/state/t1.inbox/001.msg"
  run_park "$dir" scan >/dev/null
  assert_equals "" "$(control_log "$dir")" "a new incarnation is not relaunched as a parked worker"
  assert_absent "$dir/state/t1.worker-park" "the earlier incarnation's marker is retired"
  pass "a marker from an earlier incarnation is not honored"
}

# A gh stub that answers every GraphQL PR read with stub/pr.json.
gh_stub() {  # <fakebin>
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "api graphql" ] || exit 1
cat "$FM_TEST_STUB/pr.json"
SH
  chmod +x "$1/gh"
}

# pr_json <home> <state> <mergeable> <review-decision> <check-nodes> <review-nodes> <comment-nodes>
# writes the GitHub GraphQL answer the gh stub serves.
pr_json() {
  printf '{"data":{"repository":{"pullRequest":{"state":"%s","mergeable":"%s","reviewDecision":%s,"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":%s}}}}]},"reviews":{"nodes":%s},"comments":{"nodes":%s}}}}}' \
    "$2" "$3" "$4" "$5" "$6" "$7" > "$1/stub/pr.json"
}

test_pr_activity_unparks() {
  local dir fb
  dir=$(parked_home pr)
  fb="$dir/stub/fakebin"
  mkdir -p "$fb"
  gh_stub "$fb"
  pr_json "$dir" OPEN MERGEABLE null '[{"conclusion":"SUCCESS"}]' '[]' '[]'
  PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 run_park "$dir" scan >/dev/null
  assert_equals "" "$(control_log "$dir")" "a green quiet PR leaves the worker parked"
  PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 run_park "$dir" scan >/dev/null
  assert_equals "" "$(control_log "$dir")" "an unchanged PR leaves the worker parked"
  pr_json "$dir" OPEN MERGEABLE null '[{"conclusion":"SUCCESS"},{"state":"FAILURE"}]' '[]' '[]'
  PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 run_park "$dir" scan >/dev/null
  assert_contains "$(control_log "$dir")" "failed check" "a newly red PR relaunches the worker"
  pass "a parked worker's PR going red relaunches it"
}

test_pr_review_and_conflict_unpark() {
  local dir fb case_ mergeable decision reviews comments want
  while IFS='|' read -r case_ mergeable decision reviews comments want; do
    dir=$(parked_home "pr-$case_")
    fb="$dir/stub/fakebin"
    mkdir -p "$fb"
    gh_stub "$fb"
    pr_json "$dir" OPEN MERGEABLE null '[]' '[]' '[]'
    PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 run_park "$dir" scan >/dev/null
    pr_json "$dir" OPEN "$mergeable" "$decision" '[]' "$reviews" "$comments"
    PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 run_park "$dir" scan >/dev/null
    assert_contains "$(control_log "$dir")" "$want" "$case_ relaunches the parked worker"
  done <<'EOF'
changes|MERGEABLE|"CHANGES_REQUESTED"|[{"state":"CHANGES_REQUESTED","createdAt":"2026-09-29T10:00:00Z","author":{"__typename":"User"}}]|[]|changes-requested
conflict|CONFLICTING|null|[]|[]|merge conflict
comment|MERGEABLE|null|[]|[{"createdAt":"2026-09-29T10:00:00Z","author":{"__typename":"User"}}]|new reviews or comments
review|MERGEABLE|null|[{"state":"COMMENTED","createdAt":"2026-09-29T10:00:00Z","author":{"__typename":"User"}}]|[]|new reviews or comments
EOF
  pass "review findings, a merge conflict, and new human reviews or comments each relaunch a parked worker"
}

test_merged_pr_stays_parked() {
  local dir fb
  dir=$(parked_home pr-merged)
  fb="$dir/stub/fakebin"
  mkdir -p "$fb"
  gh_stub "$fb"
  pr_json "$dir" OPEN MERGEABLE null '[]' '[]' '[]'
  PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 run_park "$dir" scan >/dev/null
  pr_json "$dir" MERGED UNKNOWN null '[]' '[{"state":"COMMENTED","createdAt":"2026-09-29T10:00:00Z","author":{"__typename":"User"}}]' '[{"createdAt":"2026-09-29T10:00:00Z","author":{"__typename":"User"}}]'
  PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 run_park "$dir" scan >/dev/null
  assert_equals "" "$(control_log "$dir")" "a merged PR leaves the worker parked for cleanup"
  pass "a merged PR leaves a parked worker parked"
}

# GitHub App logins carry no "[bot]" suffix (github-actions, coderabbitai); only
# the author type marks them, on comments and reviews alike.
test_approval_and_bot_activity_do_not_unpark() {
  local dir fb bot_reviews bot_comments
  dir=$(parked_home pr-quiet)
  fb="$dir/stub/fakebin"
  mkdir -p "$fb"
  gh_stub "$fb"
  pr_json "$dir" OPEN MERGEABLE null '[]' '[]' '[]'
  PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 run_park "$dir" scan >/dev/null
  bot_reviews='{"state":"APPROVED","createdAt":"2026-09-29T10:00:00Z","author":{"__typename":"User","login":"reviewer"}},{"state":"COMMENTED","createdAt":"2026-09-29T10:01:00Z","author":{"__typename":"Bot","login":"coderabbitai"}}'
  bot_comments='{"createdAt":"2026-09-29T10:02:00Z","author":{"__typename":"Bot","login":"github-actions"}},{"createdAt":"2026-09-29T10:03:00Z","author":{"__typename":"Bot","login":"vercel"}}'
  pr_json "$dir" OPEN MERGEABLE '"APPROVED"' '[]' "[$bot_reviews]" "[$bot_comments]"
  PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 run_park "$dir" scan >/dev/null
  assert_equals "" "$(control_log "$dir")" "an approval and bot reviews and comments leave the worker parked"
  pr_json "$dir" OPEN MERGEABLE '"APPROVED"' '[]' "[$bot_reviews]" "[$bot_comments,{\"createdAt\":\"2026-09-29T10:04:00Z\",\"author\":{\"__typename\":\"User\",\"login\":\"captain\"}}]"
  PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 run_park "$dir" scan >/dev/null
  assert_contains "$(control_log "$dir")" "new reviews or comments" "a human comment after bot activity still relaunches the worker"
  pass "an approving review or bot activity does not relaunch a parked worker; a human comment does"
}

# comment_nodes <first-minute> <count> <kind>... writes comma-joined comment
# nodes, one per minute from 10:<first-minute>, cycling through the author kinds.
comment_nodes() {
  local first=$1 count=$2 i out='' kind
  shift 2
  local kinds=("$@")
  for ((i = 0; i < count; i++)); do
    kind=${kinds[$((i % ${#kinds[@]}))]}
    out+="${out:+,}{\"createdAt\":\"2026-09-29T$(printf '%02d:%02d' $(((first + i) / 60 + 10)) $(((first + i) % 60))):00Z\",\"author\":{\"__typename\":\"$kind\"}}"
  done
  printf '%s' "$out"
}

# The PR read sees only the last 100 comments; a new human comment must wake the
# worker even when bot comments push older human comments out of that window.
test_full_comment_window_still_sees_new_human_comment() {
  local dir fb
  dir=$(parked_home pr-window)
  fb="$dir/stub/fakebin"
  mkdir -p "$fb"
  gh_stub "$fb"
  pr_json "$dir" OPEN MERGEABLE null '[]' '[]' "[$(comment_nodes 0 60 User),$(comment_nodes 60 40 Bot)]"
  PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 run_park "$dir" scan >/dev/null
  pr_json "$dir" OPEN MERGEABLE null '[]' '[]' "[$(comment_nodes 6 54 User),$(comment_nodes 60 40 Bot),$(comment_nodes 100 5 Bot),$(comment_nodes 105 1 User)]"
  PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 run_park "$dir" scan >/dev/null
  assert_contains "$(control_log "$dir")" "new reviews or comments" "a new human comment in a full window relaunches the worker"
  pass "a new human comment wakes a parked worker even as older comments leave the last-100 window"
}

# A review's createdAt is when its author started it; a review started before
# the baseline but submitted after it is new activity.
test_late_submitted_review_unparks() {
  local dir fb
  dir=$(parked_home pr-late-review)
  fb="$dir/stub/fakebin"
  mkdir -p "$fb"
  gh_stub "$fb"
  pr_json "$dir" OPEN MERGEABLE null '[]' '[]' '[{"createdAt":"2026-09-29T10:15:00Z","author":{"__typename":"User"}}]'
  PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 run_park "$dir" scan >/dev/null
  pr_json "$dir" OPEN MERGEABLE null '[]' '[{"state":"COMMENTED","createdAt":"2026-09-29T10:00:00Z","submittedAt":"2026-09-29T10:30:00Z","author":{"__typename":"User"}}]' '[{"createdAt":"2026-09-29T10:15:00Z","author":{"__typename":"User"}}]'
  PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 run_park "$dir" scan >/dev/null
  assert_contains "$(control_log "$dir")" "new reviews or comments" "a review submitted after the baseline relaunches the worker"
  pass "a review started before the baseline but submitted after it wakes a parked worker"
}

# A PR reason the scan cannot act on (its action budget is spent) must not move
# the baseline, or the next read would find nothing new and drop it for good.
test_deferred_pr_reason_is_retried() {
  local dir fb
  dir=$(parked_home pr-deferred)
  fb="$dir/stub/fakebin"
  mkdir -p "$fb"
  gh_stub "$fb"
  pr_json "$dir" OPEN MERGEABLE null '[]' '[]' '[]'
  PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 run_park "$dir" scan >/dev/null
  pr_json "$dir" OPEN MERGEABLE '"CHANGES_REQUESTED"' '[]' '[{"state":"CHANGES_REQUESTED","createdAt":"2026-09-29T10:00:00Z","author":{"__typename":"User"}}]' '[]'
  PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 FM_WORKER_PARK_MAX_ACTIONS=0 run_park "$dir" scan >/dev/null
  assert_equals "" "$(control_log "$dir")" "a spent action budget defers the unpark"
  PATH="$fb:$PATH" FM_WORKER_PARK_PR_SECS=0 run_park "$dir" scan >/dev/null
  assert_contains "$(control_log "$dir")" "changes-requested" "the deferred PR reason relaunches the worker once the budget allows"
  pass "a PR reason deferred by a spent action budget unparks the worker on a later scan"
}

# --- fm-send and the watcher's readers -------------------------------------

# A tmux stub whose only pane holds a shell: the parked worker's agent is gone.
shell_pane_tmux() {  # <dir> -> echoes fakebin
  local fb="$1/stub/tmuxbin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys) printf '%s\n' "$*" >> "$FM_TEST_STUB/typed"; exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) printf 'zsh\n'; exit 0 ;;
        *pane_current_path*) printf '/tmp\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '$ \n'; exit 0 ;;
  list-windows) printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

test_fm_send_to_a_parked_worker_starts_the_unpark() {
  local dir fb out rc i
  dir=$(parked_home send)
  fb=$(shell_pane_tmux "$dir")
  out=$(env PATH="$fb:$PATH" FM_HOME="$dir" FM_TEST_STUB="$dir/stub" \
    FM_WORKER_PARK_CONTROL_BIN="$dir/stub/bin/control" \
    "$ROOT/bin/fm-send.sh" t1 "please address the review" 2>&1); rc=$?
  expect_code 0 "$rc" "the steer is durably sent"$'\n'"$out"
  assert_contains "$out" "was parked" "fm-send says the parked worker is being relaunched"
  assert_present "$dir/state/t1.inbox/001.msg" "the steer is recorded"
  for i in $(seq 1 50); do
    grep -q relaunch "$dir/stub/control.log" 2>/dev/null && break
    sleep 0.1
  done
  assert_contains "$(control_log "$dir")" "t1 relaunch --note" "the unpark relaunches the worker"
  [ ! -s "$dir/stub/typed" ] || fail "nothing is typed into a parked worker's shell: $(cat "$dir/stub/typed")"
  pass "fm-send to a parked worker records the steer and starts its relaunch, typing nothing"
}

test_fm_send_refuses_a_typed_command_to_a_parked_worker() {
  local dir fb out rc
  dir=$(parked_home send-typed)
  fb=$(shell_pane_tmux "$dir")
  out=$(env PATH="$fb:$PATH" FM_HOME="$dir" FM_TEST_STUB="$dir/stub" \
    FM_WORKER_PARK_CONTROL_BIN="$dir/stub/bin/control" \
    "$ROOT/bin/fm-send.sh" t1 "/compact" 2>&1); rc=$?
  expect_code 1 "$rc" "a typed command to a parked worker is refused"$'\n'"$out"
  assert_contains "$out" "parked" "the refusal says the worker is parked"
  [ ! -s "$dir/stub/typed" ] || fail "nothing is typed into a parked worker's shell: $(cat "$dir/stub/typed")"
  pass "fm-send refuses a typed command to a parked worker instead of typing it into a shell"
}

test_crew_state_reports_a_parked_worker_as_waiting() {
  local dir fb out
  dir=$(parked_home crew-state)
  fb=$(shell_pane_tmux "$dir")
  # The ship-done gate needs a real pushed head, so pin a declared wait here.
  status "$dir" t1 "paused [at=2]: waiting on the vendor"
  out=$(env PATH="$fb:$PATH" FM_HOME="$dir" FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" t1)
  assert_contains "$out" "state: paused · source: status-log · waiting on the vendor" "a parked worker reads its declaration"
  assert_contains "$out" "worker parked since" "the parked worker is named as parked"
  assert_not_contains "$out" "gone" "a parked worker is not reported gone"
  pass "fm-crew-state reports a parked worker's waiting state, not a dead endpoint"
}

test_done_worker_is_parked_after_grace
test_each_waiting_state_is_parked
test_active_workers_are_never_parked
test_unread_inbox_blocks_parking
test_grace_must_elapse
test_changed_signature_restarts_the_grace_clock
test_secondmates_and_unsupported_tasks_are_skipped
test_config_off_disables_parking
test_refused_park_is_logged_once_and_backed_off
test_steer_unparks_the_worker
test_explicit_unpark_and_idempotence
test_refused_unpark_is_recorded_for_escalation
test_declared_wait_time_unparks
test_past_wait_time_does_not_cycle
test_validation_gate_unparks
test_budget_rotation_reaches_every_task
test_relaunch_by_hand_invalidates_the_marker
test_pr_activity_unparks
test_pr_review_and_conflict_unpark
test_merged_pr_stays_parked
test_approval_and_bot_activity_do_not_unpark
test_full_comment_window_still_sees_new_human_comment
test_late_submitted_review_unparks
test_deferred_pr_reason_is_retried
test_fm_send_to_a_parked_worker_starts_the_unpark
test_crew_state_reports_a_parked_worker_as_waiting
test_fm_send_refuses_a_typed_command_to_a_parked_worker
