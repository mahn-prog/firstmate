#!/usr/bin/env bash
# fm-host-switch.sh: one-step fleet host switch between saved host profiles.
#
# These tests drive the real executable against a temp home. Its collaborators
# are stubbed through their seams so the switch is pinned without an agent:
# the lifecycle owner (FM_HOST_SWITCH_CONTROL_BIN), the parked-worker owner
# (FM_HOST_SWITCH_PARK_BIN), the steer owner (FM_HOST_SWITCH_SEND_BIN), the
# inherited-config push (FM_HOST_SWITCH_PUSH_BIN), the endpoint classifier
# (FM_HOST_SWITCH_AGENT_STATE_BIN), and a PATH `no-mistakes` stub whose
# `axi status` answer is read per worktree. NM_HOME points the reviewer config
# at the temp home, so the real ~/.no-mistakes is never read or written.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWITCH="$ROOT/bin/fm-host-switch.sh"
TMP_ROOT=$(fm_test_tmproot fm-host-switch)

# The reviewer config as it looks on a Claude-hosted fleet.
nm_config_claude() {
  cat <<'EOF'
# reviewer follows the host
agent: claude
session_reuse: false
agent_args_override:
  codex:
    - --sandbox
    - workspace-write
  claude:
    - --permission-mode
    - bypassPermissions

agent_timeout: "90m"
EOF
}

# write_profile <home> <host> <secondmate line> <nm agent> [arg...]
write_profile() {
  local dir=$1/config/host-profiles/$2 host=$2 sm=$3 nm=$4
  shift 4
  mkdir -p "$dir"
  printf '%s\n' "$sm" > "$dir/secondmate-harness"
  printf '%s\n' "$host" > "$dir/crew-harness"
  printf '{"rules":[],"default":{"harness":"%s","model":"%s-default","effort":"low"}}\n' "$host" "$host" > "$dir/crew-dispatch.json"
  printf '%s\n' "$nm" > "$dir/no-mistakes-agent"
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@" > "$dir/no-mistakes-args"; fi
}

write_tiers() {  # <home> <host> <lines...>
  local dir=$1/config/host-profiles/$2
  shift 2
  printf '%s\n' "$@" > "$dir/worker-tiers"
}

# new_home <name> -> echoes a primary home on the claude host with both
# profiles saved, and every stub in place.
new_home() {
  local dir="$TMP_ROOT/$1" bin
  mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/stub/bin" "$dir/nm" "$dir/fakebin"
  bin=$dir/stub/bin
  printf 'claude opus\n' > "$dir/config/secondmate-harness"
  printf 'claude\n' > "$dir/config/crew-harness"
  printf '{"rules":[],"default":{"harness":"claude","model":"opus","effort":"high"}}\n' > "$dir/config/crew-dispatch.json"
  printf 'claude\n' > "$dir/config/host-profile"
  nm_config_claude > "$dir/nm/config.yaml"
  write_profile "$dir" claude "claude opus" claude --permission-mode bypassPermissions
  write_profile "$dir" codex "codex gpt-sol low" codex --sandbox workspace-write --model gpt-sol
  write_tiers "$dir" claude "strong claude opus xhigh" "standard claude opus high" "light claude sonnet medium"
  write_tiers "$dir" codex "strong codex gpt-astra high" "standard codex gpt-sol medium" "light codex gpt-luna low"
  for tool in control park send push; do
    cat > "$bin/$tool" <<SH
#!/usr/bin/env bash
{ printf '%s' "$tool"; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "\$FM_TEST_STUB/calls.log"
exit "\$(cat "\$FM_TEST_STUB/$tool-rc" 2>/dev/null || echo 0)"
SH
  done
  cat > "$bin/agent-state" <<'SH'
#!/usr/bin/env bash
cat "$FM_TEST_STUB/state-$1" 2>/dev/null || echo alive
SH
  # The no-mistakes stub answers `axi status` from the worktree's own stub file.
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_STUB/nm.log"
if [ "$1 $2" = "axi status" ] && [ -f .nm-status ]; then cat .nm-status; exit 0; fi
echo "no runs yet"
SH
  chmod +x "$bin"/* "$dir/fakebin/no-mistakes"
  printf '%s\n' "$dir"
}

add_worker() {  # <home> <id> <harness> <model> <effort> [extra meta lines...]
  local dir=$1 id=$2 h=$3 m=$4 e=$5
  shift 5
  mkdir -p "$dir/wt-$id" "$dir/data/$id"
  fm_write_meta "$dir/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" "worktree=$dir/wt-$id" \
    "harness=$h" "model=$m" "effort=$e" "kind=ship" "mode=direct-PR" \
    "branch=fm/$id" "spawn_gen=s-$id" "backend=herdr" "$@"
}

add_secondmate() {  # <home> <id> [extra meta lines...]
  local dir=$1 id=$2
  shift 2
  mkdir -p "$dir/sm-$id"
  fm_write_meta "$dir/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" "worktree=$dir/sm-$id" \
    "harness=claude" "model=opus" "kind=secondmate" "mode=secondmate" \
    "home=$dir/sm-$id" "spawn_gen=s-$id" "backend=herdr" "$@"
}

run_status() {  # <home> <id> <axi status TOON>
  printf '%s\n' "$3" > "$1/wt-$2/.nm-status"
}

run_switch() {  # <home> <args...>
  local dir=$1
  shift
  env FM_HOME="$dir" FM_TEST_STUB="$dir/stub" NM_HOME="$dir/nm" \
    PATH="$dir/fakebin:$PATH" \
    FM_HOST_SWITCH_CONTROL_BIN="$dir/stub/bin/control" \
    FM_HOST_SWITCH_PARK_BIN="$dir/stub/bin/park" \
    FM_HOST_SWITCH_SEND_BIN="$dir/stub/bin/send" \
    FM_HOST_SWITCH_PUSH_BIN="$dir/stub/bin/push" \
    FM_HOST_SWITCH_AGENT_STATE_BIN="$dir/stub/bin/agent-state" \
    "$SWITCH" "$@" 2>&1
}

calls() {
  cat "$1/stub/calls.log" 2>/dev/null || true
}

# snapshot <home>: every config byte, the reviewer config, and the state tree.
snapshot() {
  (cd "$1" && find config nm state -type f -print0 | sort -z | xargs -0 shasum) 2>/dev/null
}

# --- dry run ----------------------------------------------------------------

test_dry_run_prints_the_plan_and_touches_nothing() {
  local dir out before
  dir=$(new_home dry)
  add_worker "$dir" w1 claude opus high
  add_secondmate "$dir" sm1
  before=$(snapshot "$dir")
  out=$(run_switch "$dir" codex --dry-run)
  expect_code 0 $? "dry run"
  assert_equals "$before" "$(snapshot "$dir")" "a dry run must change no file"$'\n'"$out"
  assert_equals "" "$(calls "$dir")" "a dry run must call no lifecycle, steer or push owner"
  assert_contains "$out" "claude -> codex" "the plan names the switch"
  assert_contains "$out" "crew-harness: claude -> codex" "the plan shows the crew harness change"
  assert_contains "$out" "secondmate-harness: claude opus -> codex gpt-sol low" "the plan shows the secondmate pin change"
  assert_contains "$out" "no-mistakes agent: claude -> codex" "the plan shows the reviewer agent change"
  assert_contains "$out" "secondmate sm1: relaunch on codex gpt-sol low" "the plan relaunches the secondmate"
  assert_contains "$out" "worker w1: relaunch claude/opus/high -> codex/gpt-sol/medium (standard)" "the plan keeps the worker's tier"
  assert_contains "$out" "dry run: nothing changed" "the dry run says so"
  pass "a dry run prints the exact plan and changes nothing"
}

# --- apply ------------------------------------------------------------------

test_apply_switches_config_reviewer_secondmates_and_workers() {
  local dir out rc=0 record expected
  dir=$(new_home apply)
  add_worker "$dir" w1 claude opus xhigh
  add_secondmate "$dir" sm1
  out=$(run_switch "$dir" codex) || rc=$?
  expect_code 0 "$rc" "apply"$'\n'"$out"
  assert_equals "codex" "$(cat "$dir/config/crew-harness")" "crew harness follows the profile"
  assert_equals "codex gpt-sol low" "$(cat "$dir/config/secondmate-harness")" "secondmate pin follows the profile"
  assert_equals "codex" "$(cat "$dir/config/host-profile")" "the fleet host is recorded"
  assert_grep '"harness":"codex"' "$dir/config/crew-dispatch.json" "dispatch follows the profile"
  assert_grep "codex standard codex gpt-sol medium" "$dir/config/host-worker-tiers" "every profile's tiers are published for secondmate homes"
  expected=$(cat <<'EOF'
# reviewer follows the host
agent: codex
session_reuse: false
agent_args_override:
  codex:
    - --sandbox
    - workspace-write
    - --model
    - gpt-sol
  claude:
    - --permission-mode
    - bypassPermissions

agent_timeout: "90m"
EOF
)
  assert_equals "$expected" "$(cat "$dir/nm/config.yaml")" "only the agent line and that agent's args change"
  record=$(printf '%s\n' "$out" | sed -n 's/^record: //p')
  assert_present "$record/no-mistakes-config.before.yaml" "the previous reviewer config is kept"
  assert_equals "claude" "$(cat "$record/config-before/crew-harness")" "the previous config is kept"
  assert_present "$record/plan.txt" "the plan is recorded"
  assert_contains "$(cat "$record/actions.log")" "ok relaunch worker w1" "each action is logged"
  expected="push
control [sm1] [relaunch]
send [sm1] [The fleet host is now codex. Run \`bin/fm-host-switch.sh codex --dry-run\` and then \`bin/fm-host-switch.sh codex\` in this home to move your own workers onto it, then report the result through your status.]"
  assert_equals "$expected" "$(calls "$dir" | sed -n '1,3p')" "push, then secondmate relaunch on its pin, then the steer"
  assert_contains "$(calls "$dir" | sed -n 4p)" "control [w1] [relaunch] [--harness] [codex] [--model] [gpt-astra] [--effort] [high] [--note]" "a strong worker stays strong on the new host"
  pass "apply writes the profile, edits only the reviewer agent, and relaunches in order"
}

test_second_apply_is_a_no_op() {
  local dir out
  dir=$(new_home idem)
  add_worker "$dir" w1 claude opus high
  run_switch "$dir" codex >/dev/null
  # The stub control plane does not republish records; do what fm-spawn would.
  sed -i.bak 's/^harness=.*/harness=codex/' "$dir/state/w1.meta"
  : > "$dir/stub/calls.log"
  out=$(run_switch "$dir" codex)
  expect_code 0 $? "second apply"
  assert_equals "" "$(calls "$dir")" "nothing is relaunched twice"$'\n'"$out"
  assert_contains "$out" "worker w1: already on codex; unchanged" "the worker is reported as already switched"
  assert_contains "$out" "no-mistakes agent: codex (unchanged)" "the reviewer is reported unchanged"
  pass "running the switch again changes nothing"
}

test_incomplete_profile_refuses_before_any_change() {
  local dir out rc=0 before
  dir=$(new_home incomplete)
  add_worker "$dir" w1 claude opus high
  rm "$dir/config/host-profiles/codex/no-mistakes-agent"
  before=$(snapshot "$dir")
  out=$(run_switch "$dir" codex) || rc=$?
  expect_code 2 "$rc" "incomplete profile"
  assert_contains "$out" "no-mistakes-agent is missing or empty" "the refusal names the missing setting"
  assert_equals "$before" "$(snapshot "$dir")" "nothing changes on a refusal"
  assert_equals "" "$(calls "$dir")" "nothing is relaunched on a refusal"
  out=$(run_switch "$dir" pi) || rc=$?
  assert_contains "$out" "no saved profile for 'pi'" "an unknown host names the save command"
  pass "an incomplete or unknown profile refuses before any change"
}

test_unrecognized_reviewer_config_refuses() {
  local dir out rc=0
  dir=$(new_home nmflow)
  printf 'agent: claude\nagent_args_override: {}\n' > "$dir/nm/config.yaml"
  out=$(run_switch "$dir" codex) || rc=$?
  expect_code 2 "$rc" "flow-style reviewer config"
  assert_contains "$out" "structure this switch does not edit" "the refusal says why"
  assert_equals "claude" "$(cat "$dir/config/crew-harness")" "config is untouched"
  printf 'session_reuse: false\n' > "$dir/nm/config.yaml"
  out=$(run_switch "$dir" codex) || rc=$?
  assert_contains "$out" "structure this switch does not edit" "a config with no agent line refuses too"
  pass "a reviewer config this edit cannot understand is refused, not rewritten"
}

test_failed_relaunch_is_reported_and_the_rest_continue() {
  local dir out rc=0
  dir=$(new_home failing)
  add_worker "$dir" w1 claude opus high
  add_worker "$dir" w2 claude sonnet medium
  echo 1 > "$dir/stub/control-rc"
  out=$(run_switch "$dir" codex) || rc=$?
  expect_code 1 "$rc" "a failed relaunch"
  assert_contains "$out" "FAILED relaunch worker w1" "the failure is reported"
  assert_contains "$out" "FAILED relaunch worker w2" "the next worker was still attempted"
  assert_contains "$(calls "$dir")" "control [w2] [relaunch] [--harness] [codex] [--model] [gpt-luna] [--effort] [low]" "a light worker stays light"
  pass "a failed relaunch is reported per agent and the rest still run"
}

# --- validation runs ----------------------------------------------------------

# toon <id> <status> <next-code> <next-command> [extra run lines]
toon() {
  cat <<EOF
run:
  id: "$1"
  branch: fm/w1
  status: $2
${5:-}
branch_sync:
  state: x
  next_action:
    code: $3
    command: $4
EOF
}

note_of() {  # <home> <id>: the --note argument of the worker's relaunch call
  calls "$1" | grep "^control \[$2\] \[relaunch\]" | sed 's/.*\[--note\] \[\(.*\)\]$/\1/'
}

test_active_run_stays_on_its_agent_and_is_never_aborted() {
  local dir out note
  dir=$(new_home active-run)
  add_worker "$dir" w1 claude opus high
  run_status "$dir" w1 "$(toon R1 running continue_active_run "no-mistakes axi status" '  active_steps[1]{step,status,active_for,round_active_for,last_activity,agent_pid,round}:
    review,fixing,1m,1m,"5s ago: claude producing output","42",fix 1')"
  out=$(run_switch "$dir" codex)
  assert_contains "$out" "run R1 active (running) - stays on its start agent (claude), never aborted" "the plan says the run keeps its agent"
  note=$(note_of "$dir" w1)
  assert_contains "$note" "keeps the pipeline agent it started with" "the worker is told the run keeps its agent"
  assert_contains "$note" "never abort it" "the worker is told never to abort"
  assert_contains "$note" "no-mistakes rerun" "the worker knows how to continue after it ends"
  assert_no_grep "abort" "$dir/stub/nm.log" "the switch never aborts a run"
  assert_equals "axi status" "$(sort -u "$dir/stub/nm.log")" "the switch only reads run status"
  pass "an active run stays on its start agent, is never aborted, and its worker keeps driving it"
}

test_failed_run_gets_the_supported_continuation() {
  local dir note
  dir=$(new_home failed-run)
  add_worker "$dir" w1 claude opus high
  run_status "$dir" w1 "$(toon R2 failed sync "no-mistakes axi sync")"
  run_switch "$dir" codex >/dev/null
  note=$(note_of "$dir" w1)
  assert_contains "$note" "Your validation run R2 ended failed before the switch. Continue it on codex now" "the worker is told its run ended"
  # shellcheck disable=SC2016 # literal backticks in the expected note
  assert_contains "$note" 'run `no-mistakes axi sync`; then run `no-mistakes rerun` from the preserved branch head' "sync, then rerun"
  assert_contains "$note" "Never abort, force, reset or discard anything." "the note forbids destructive moves"
  pass "a failed run's worker is told to sync and rerun on the new host"
}

test_custody_recovery_is_passed_through_exactly() {
  local dir note
  dir=$(new_home recover-run)
  add_worker "$dir" w1 claude opus high
  run_status "$dir" w1 "$(toon R3 cancelled recover_custody "no-mistakes axi sync --recover")"
  run_switch "$dir" codex >/dev/null
  note=$(note_of "$dir" w1)
  # shellcheck disable=SC2016 # literal backticks in the expected note
  assert_contains "$note" 'run exactly `no-mistakes axi sync --recover`; then run `no-mistakes rerun`' "the exact recovery command is passed on"
  pass "a stranded run's custody recovery is passed to the worker exactly"
}

test_keep_local_recovery_becomes_a_decision() {
  local dir out note
  dir=$(new_home keep-local)
  add_worker "$dir" w1 claude opus high
  run_status "$dir" w1 "$(toon R4 failed recover_custody "no-mistakes axi sync --recover --keep-local")"
  out=$(run_switch "$dir" codex)
  assert_contains "$out" "run R4 failed - recovery would discard commits; worker raises a decision" "the plan flags the discard"
  note=$(note_of "$dir" w1)
  assert_contains "$note" "do NOT run its recovery command" "the worker must not run a discarding recovery"
  assert_contains "$note" "append needs-decision naming run R4" "the worker raises a decision instead"
  pass "a recovery that would discard commits is escalated, never run"
}

test_run_on_another_branch_is_not_this_workers() {
  local dir out
  dir=$(new_home other-branch)
  add_worker "$dir" w1 claude opus high
  run_status "$dir" w1 "$(toon R5 failed sync "no-mistakes axi sync" | sed 's#branch: fm/w1#branch: fm/other#')"
  out=$(run_switch "$dir" codex --dry-run)
  assert_contains "$out" "worker w1: relaunch claude/opus/high -> codex/gpt-sol/medium (standard); no run" "another branch's run is not attributed"
  pass "a run on another branch is never attributed to the worker"
}

# --- parked, stopped, remote, and home scope ---------------------------------

test_parked_worker_is_unparked_onto_the_new_host() {
  local dir out
  dir=$(new_home parked)
  add_worker "$dir" w1 claude sonnet medium
  printf 'schema=fm-worker-park.v1\nspawn_gen=s-w1\nstate=done\nparked_at=1\n' > "$dir/state/w1.worker-park"
  echo dead > "$dir/stub/state-w1"
  out=$(run_switch "$dir" codex)
  assert_contains "$out" "worker w1: unpark (parked) claude/sonnet/medium -> codex/gpt-luna/low (light)" "the plan unparks the worker"
  assert_contains "$(calls "$dir")" "park [unpark] [w1] [--reason] [the fleet moved to the codex host] [--harness] [codex] [--model] [gpt-luna] [--effort] [low] [--note-extra]" "unpark carries the new profile"
  assert_not_contains "$(calls "$dir")" "control [w1]" "a parked worker is not relaunched around its park records"
  pass "a parked worker is unparked onto the new host so its park records retire"
}

test_stopped_worker_is_reported_not_relaunched() {
  local dir out
  dir=$(new_home stopped)
  add_worker "$dir" w1 claude opus high
  echo missing > "$dir/stub/state-w1"
  out=$(run_switch "$dir" codex)
  assert_contains "$out" "worker w1: stopped (missing), not relaunched" "the stopped worker is reported"
  assert_contains "$out" "bin/fm-control.sh w1 relaunch --harness codex --model gpt-sol --effort medium --note <why>" "the report names the relaunch command"
  assert_not_contains "$(calls "$dir")" "[w1]" "nothing is sent to a stopped worker"
  pass "a stopped, unparked worker is reported with its relaunch command, not relaunched"
}

test_remote_and_current_secondmates_are_not_relaunched() {
  local dir out
  dir=$(new_home remote)
  add_secondmate "$dir" far "remote_host=box.example"
  add_secondmate "$dir" near
  sed -i.bak 's/^harness=.*/harness=codex/' "$dir/state/near.meta"
  out=$(run_switch "$dir" codex)
  assert_contains "$out" "secondmate far: remote on box.example; switch it by hand there" "a remote secondmate is listed"
  assert_contains "$out" "secondmate near: already on codex; unchanged" "a current secondmate is left alone"
  assert_equals "push" "$(calls "$dir")" "only the config push runs"
  pass "remote secondmates are listed and current ones left alone"
}

test_secondmate_home_switches_only_its_own_workers() {
  local dir out nm_before
  dir=$(new_home sm-home)
  rm -rf "$dir/config/host-profiles"
  printf 'sm-home\n' > "$dir/.fm-secondmate-home"
  printf 'codex\n' > "$dir/config/host-profile"
  printf 'codex\n' > "$dir/config/crew-harness"
  printf 'claude standard claude opus high\ncodex standard codex gpt-sol medium\n' > "$dir/config/host-worker-tiers"
  add_worker "$dir" w1 claude opus high
  nm_before=$(cat "$dir/nm/config.yaml")
  out=$(run_switch "$dir" codex)
  expect_code 0 $? "home-scope switch"$'\n'"$out"
  assert_contains "$out" "scope: home" "the plan says home scope"
  assert_equals "$nm_before" "$(cat "$dir/nm/config.yaml")" "a secondmate home never edits the reviewer config"
  assert_equals "claude opus" "$(cat "$dir/config/secondmate-harness")" "a secondmate home never writes a secondmate pin"
  assert_contains "$(calls "$dir")" "control [w1] [relaunch] [--harness] [codex] [--model] [gpt-sol] [--effort] [medium]" "its own worker moves on the inherited tiers"
  assert_not_contains "$(calls "$dir")" "push" "a secondmate home pushes nothing"
  out=$(run_switch "$dir" claude) && fail "a secondmate home must refuse a host the fleet is not on"
  assert_contains "$out" "the primary firstmate owns the fleet switch" "the refusal names the owner"
  pass "a secondmate home moves only its own workers, onto the fleet host it inherited"
}

# --- check (session-start notice) and save -----------------------------------

run_check() {  # <home> <session host> [args...]
  local dir=$1 host=$2
  shift 2
  printf '#!/usr/bin/env bash\necho %s\n' "$host" > "$dir/stub/bin/harness"
  chmod +x "$dir/stub/bin/harness"
  env FM_HOME="$dir" NM_HOME="$dir/nm" FM_HOST_SWITCH_HARNESS_BIN="$dir/stub/bin/harness" \
    "$SWITCH" check "$@" 2>&1
}

test_check_names_the_one_command_on_a_host_mismatch() {
  local dir out before
  dir=$(new_home check)
  add_worker "$dir" w1 claude opus high
  before=$(snapshot "$dir")
  out=$(run_check "$dir" codex)
  expect_code 0 $? "check"
  assert_equals "HOST_PROFILE: this session runs on codex but the fleet host is claude; to move the whole fleet to codex run: bin/fm-host-switch.sh codex (preview with --dry-run)" "$out" "the notice names the one command"
  assert_equals "$before" "$(snapshot "$dir")" "check changes nothing"
  assert_equals "" "$(calls "$dir")" "check never switches anything"
  assert_equals "" "$(run_check "$dir" claude)" "a matching session host prints nothing"
  assert_equals "" "$(run_check "$dir" unknown)" "an undetectable session host prints nothing"
  rm -rf "$dir/config/host-profiles/codex"
  assert_contains "$(run_check "$dir" codex)" "no codex profile is saved; save one while the fleet runs on codex (bin/fm-host-switch.sh save codex)" "a missing profile names the save step"
  rm "$dir/config/host-profile"
  assert_equals "" "$(run_check "$dir" codex)" "a home with no recorded fleet host prints nothing"
  pass "check prints a notice naming the one command on a host mismatch, and nothing otherwise"
}

test_check_flags_workers_left_on_another_host() {
  local dir out
  dir=$(new_home check-stale)
  add_worker "$dir" w1 codex gpt-sol medium
  add_worker "$dir" w2 claude opus high
  out=$(run_check "$dir" claude)
  assert_equals "HOST_PROFILE: 1 worker(s) in this home still run on another host than claude: w1 (codex); run: bin/fm-host-switch.sh claude (preview with --dry-run)" "$out" "a worker left behind is named"
  pass "check names workers still running on another host than the fleet's"
}

test_check_in_a_secondmate_home_points_at_the_primary() {
  local dir
  dir=$(new_home check-sm)
  printf 'sm-home\n' > "$dir/.fm-secondmate-home"
  assert_contains "$(run_check "$dir" codex)" "the primary firstmate owns the fleet switch" "a secondmate never switches the fleet"
  pass "check in a secondmate home points at the primary"
}

test_save_captures_the_live_config_into_a_profile() {
  local dir out rc=0
  dir=$(new_home save)
  rm -rf "$dir/config/host-profiles/claude"
  out=$(run_switch "$dir" save claude) || rc=$?
  expect_code 0 "$rc" "save"$'\n'"$out"
  assert_equals "claude opus" "$(cat "$dir/config/host-profiles/claude/secondmate-harness")" "the secondmate pin is saved"
  assert_equals "claude" "$(cat "$dir/config/host-profiles/claude/no-mistakes-agent")" "the reviewer agent is saved"
  assert_equals $'--permission-mode\nbypassPermissions' "$(cat "$dir/config/host-profiles/claude/no-mistakes-args")" "that agent's args are saved"
  assert_equals "$(cat "$dir/config/crew-dispatch.json")" "$(cat "$dir/config/host-profiles/claude/crew-dispatch.json")" "dispatch is saved"
  assert_contains "$out" "no worker-tiers" "a missing tier file is pointed out"
  out=$(run_switch "$dir" save codex) || rc=$?
  expect_code 2 "$rc" "saving a host the fleet is not on"
  assert_contains "$out" "save a profile only while the fleet runs on it" "the refusal says why"
  pass "save captures the live config and refuses a host the fleet is not on"
}

test_dry_run_prints_the_plan_and_touches_nothing
test_apply_switches_config_reviewer_secondmates_and_workers
test_second_apply_is_a_no_op
test_incomplete_profile_refuses_before_any_change
test_unrecognized_reviewer_config_refuses
test_failed_relaunch_is_reported_and_the_rest_continue
test_active_run_stays_on_its_agent_and_is_never_aborted
test_failed_run_gets_the_supported_continuation
test_custody_recovery_is_passed_through_exactly
test_keep_local_recovery_becomes_a_decision
test_run_on_another_branch_is_not_this_workers
test_parked_worker_is_unparked_onto_the_new_host
test_stopped_worker_is_reported_not_relaunched
test_remote_and_current_secondmates_are_not_relaunched
test_secondmate_home_switches_only_its_own_workers
test_check_names_the_one_command_on_a_host_mismatch
test_check_flags_workers_left_on_another_host
test_check_in_a_secondmate_home_points_at_the_primary
test_save_captures_the_live_config_into_a_profile
