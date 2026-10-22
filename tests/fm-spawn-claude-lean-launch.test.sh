#!/usr/bin/env bash
# tests/fm-spawn-claude-lean-launch.test.sh - every Claude agent this fleet
# launches starts lean: claude.ai connectors off unless the task opted in,
# Chrome and two user plugins off, a smaller skill listing, the unused built-in
# tools removed, a per-launch auto-compact window, and - for ship and scout
# workers only - the captain's personal ~/.claude/CLAUDE.md excluded with its
# two load-bearing rules carried in the worker system-prompt append, plus, in a
# firstmate-repo worktree only, that worktree's AGENTS.md and CLAUDE.md
# excluded with the two worker-binding rules they alone carried. A ship or
# scout worker also carries the FM_TASK_WORKER=claude marker and starts with
# Claude auto memory off unless its project is listed in config/claude-auto-memory.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then EXECUTE the launch
# command the pane actually received, under a synthetic pane environment, with
# the claude binary replaced by a probe that prints the connector switch it was
# started with and each argument it received. What the probe prints is what a
# real agent would have received.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-lean)

# A synthetic pane value the default launch must override rather than inherit.
CONTRARY=true

# The 19 built-in tools no Firstmate-launched Claude agent uses, from the
# lean-worker measurement this launch implements.
EXPECTED_DISALLOWED='Artifact,ArtifactComments,ArtifactData,Workflow,DesignSync,PushNotification,RemoteTrigger,CronCreate,CronDelete,CronList,ScheduleWakeup,EnterWorktree,ExitWorktree,EnterPlanMode,ExitPlanMode,AskUserQuestion,ReportFindings,EndConversation,NotebookEdit'

# The per-launch auto-compact window, chosen by replaying the fleet's Claude
# transcripts: it overrides any larger saved user window for every agent
# this fleet launches.
EXPECTED_AUTOCOMPACT=200000

# make_case <name> <id>...
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 case_dir home proj wt fakebin launchlog panelog id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$panelog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# The spawn runs with HOME=<home>/user-home (fm_test_run_spawn), so this is the
# personal instructions file a ship or scout launch must exclude.
personal_claude_md() { printf '%s/user-home/.claude/CLAUDE.md' "$1"; }

install_claude_probe() {  # <fakebin>
  cat > "$1/claude" <<'SH'
#!/bin/sh
printf 'CONNECTORS=%s\n' "${ENABLE_CLAUDEAI_MCP_SERVERS-unset}"
printf 'WORKER=%s\n' "${FM_TASK_WORKER-unset}"
printf 'AUTOMEMORY=%s\n' "${CLAUDE_CODE_DISABLE_AUTO_MEMORY-unset}"
for a in "$@"; do printf 'ARG=%s\n' "$a"; done
SH
  chmod +x "$1/claude"
}

# Execute the emitted launch in a synthetic pane shell, replaying the pane's
# pre-launch exports first. <ambient> is the connector switch the pane holds.
#   emitted_launch_probe <fakebin> <launch-log> <pane-log> <ambient|unset>
emitted_launch_probe() {
  local fakebin=$1 launchlog=$2 panelog=$3 ambient=$4 launch preamble
  launch=$(cat "$launchlog")
  preamble=$(grep '^export ' "$panelog")
  install_claude_probe "$fakebin"
  if [ "$ambient" = unset ]; then
    env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm TMUX=synthetic-pane \
      /bin/sh -c "$preamble
$launch"
  else
    env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm TMUX=synthetic-pane \
      ENABLE_CLAUDEAI_MCP_SERVERS="$ambient" /bin/sh -c "$preamble
$launch"
  fi
}

probe_value_after() {  # <probe-output> <flag>: the argument that follows <flag>
  printf '%s\n' "$1" | awk -v flag="ARG=$2" 'found { sub(/^ARG=/, ""); print; exit } $0 == flag { found = 1 }'
}

probe_line() {  # <probe-output> <KEY>: the probe's KEY=value line
  printf '%s\n' "$1" | grep "^$2=" | head -1
}

# A ship or scout worker carries the task worker marker and, unless its
# project opted out, starts with auto memory off.
#   assert_task_worker_env <probe-output> <on|off> <label>
assert_task_worker_env() {
  local seen=$1 memory=$2 label=$3 expected=AUTOMEMORY=1
  [ "$memory" = off ] || expected=AUTOMEMORY=unset
  assert_equals WORKER=claude "$(probe_line "$seen" WORKER)" "$label: a task worker must carry FM_TASK_WORKER=claude"
  assert_equals "$expected" "$(probe_line "$seen" AUTOMEMORY)" "$label: auto memory must be $memory"
}

probe_has_arg() {  # <probe-output> <arg>
  printf '%s\n' "$1" | grep -qxF "ARG=$2"
}

assert_lean_common() {  # <probe-output> <label>
  local seen=$1 label=$2 settings
  probe_has_arg "$seen" --no-chrome || fail "$label: launch does not pass --no-chrome"$'\n'"$seen"
  assert_equals "$EXPECTED_AUTOCOMPACT" "$(probe_value_after "$seen" --autocompact)" \
    "$label: launch must cap the auto-compact window per launch"
  assert_equals "$EXPECTED_DISALLOWED" "$(probe_value_after "$seen" --disallowedTools)" \
    "$label: launch must remove exactly the 19 unused built-in tools"
  settings=$(probe_value_after "$seen" --settings)
  printf '%s' "$settings" | jq -e '
      .feedbackDrafts == "off"
      and .attribution == {"commit":"","pr":"","sessionUrl":false}
      and .skillListingBudgetFraction == 0.004
      and .enabledPlugins == {"vercel@claude-plugins-official":false,"atlassian@claude-plugins-official":false}' >/dev/null \
    || fail "$label: launch settings JSON is missing a lean key or lost an existing one: $settings"
}

assert_worker_excludes_personal_file() {  # <probe-output> <home> <label>
  local seen=$1 home=$2 label=$3 settings prompt expected
  expected=$(personal_claude_md "$home")
  settings=$(probe_value_after "$seen" --settings)
  printf '%s' "$settings" | jq -e --arg p "$expected" '.claudeMdExcludes[0] == $p' >/dev/null \
    || fail "$label: settings must exclude the personal CLAUDE.md at $expected: $settings"
  prompt=$(probe_value_after "$seen" --append-system-prompt)
  assert_contains "$prompt" "You are a task worker launched by Firstmate" \
    "$label: the task control-channel statement must stay in the append"
  assert_contains "$prompt" "Never wrap a shell command in base64, hex, or any other encoding" \
    "$label: the append must carry the no-encoded-commands rule"
  assert_contains "$prompt" "heredoc" "$label: the append must name the readable alternative"
  local g
  for g in "Think before coding" "Simplicity first" "Surgical changes" "Goal-driven"; do
    assert_contains "$prompt" "$g" "$label: the append must carry the behavioural guideline '$g'"
  done
}

test_ship_and_scout_launch_lean_in_both_allowlist_postures() {
  local setting rec out status seen kind id
  for setting in absent enabled; do
    for kind in ship scout; do
      id="$kind-$setting-a1"
      rec=$(make_case "$kind-$setting" "$id")
      read_case "$rec"
      [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      if [ "$kind" = ship ]; then
        out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
      else
        out=$(run_case_spawn "$id" "$PROJ_DIR" --scout)
      fi
      status=$?
      expect_code 0 "$status" "$kind spawn with allowlist=$setting should succeed: $out"
      seen=$(emitted_launch_probe "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "$CONTRARY") \
        || fail "$kind, allowlist $setting: the emitted launch failed to run"
      assert_equals "CONNECTORS=false" "$(printf '%s\n' "$seen" | head -1)" \
        "$kind, allowlist $setting: claude.ai connectors must be off, overriding a contrary pane value"
      assert_lean_common "$seen" "$kind, allowlist $setting"
      assert_worker_excludes_personal_file "$seen" "$HOME_DIR" "$kind, allowlist $setting"
      assert_project_memory_kept "$seen" "$HOME_DIR" "$kind, allowlist $setting"
      assert_task_worker_env "$seen" off "$kind, allowlist $setting"
    done
  done
  pass "ship and scout Claude launches start lean and exclude the personal CLAUDE.md under both allowlist postures"
}

# A worker in any project other than firstmate keeps that project's own
# AGENTS.md and CLAUDE.md, and gets none of the firstmate-repo rules.
assert_project_memory_kept() {  # <probe-output> <home> <label>
  local seen=$1 home=$2 label=$3 settings prompt
  settings=$(probe_value_after "$seen" --settings)
  printf '%s' "$settings" | jq -e --arg p "$(personal_claude_md "$home")" '.claudeMdExcludes == [$p]' >/dev/null \
    || fail "$label: a non-firstmate worktree must exclude only the personal CLAUDE.md: $settings"
  prompt=$(probe_value_after "$seen" --append-system-prompt)
  assert_not_contains "$prompt" "$FM_REPO_ADDRESS_RULE" "$label: a non-firstmate worker must not get the firstmate-repo rules"
  assert_not_contains "$prompt" "$FM_REPO_WATCHER_RULE" "$label: a non-firstmate worker must not get the firstmate-repo rules"
}

# make_firstmate_shaped <dir>: give a worktree or home the two files that
# identify the firstmate repository, plus the memory files a Claude agent
# would otherwise load there.
make_firstmate_shaped() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/.agents/skills/firstmate-coding-guidelines"
  printf '#!/usr/bin/env bash\n' > "$dir/bin/fm-spawn.sh"
  printf -- '---\nname: firstmate-coding-guidelines\n---\n' > "$dir/.agents/skills/firstmate-coding-guidelines/SKILL.md"
  printf '# Firstmate\n' > "$dir/AGENTS.md"
  printf '@AGENTS.md\n' > "$dir/CLAUDE.md"
}

# Rules from the firstmate supervisor contract that bind a worker and live
# nowhere else a firstmate-repo worker still loads; the launch append carries
# them once that contract is excluded.
FM_REPO_ADDRESS_RULE='Never put "captain" or any other direct address into a non-chat artifact'
FM_REPO_WATCHER_RULE='Never broadly kill Firstmate processes such as watchers'

test_firstmate_repo_worker_skips_the_supervisor_contract() {
  local rec out status seen kind id settings prompt personal
  for kind in ship scout; do
    id="$kind-fmrepo-a1"
    rec=$(make_case "$kind-fmrepo" "$id")
    read_case "$rec"
    make_firstmate_shaped "$WT_DIR"
    # A pooled worktree must be clean and the spawn resets it to origin's
    # default branch, so the identity files are committed and pushed there.
    if ! { git -C "$WT_DIR" add -A && git -C "$WT_DIR" -c user.name=t -c user.email=t@t commit -qm firstmate-shaped \
      && git -C "$WT_DIR" push -q origin HEAD:main; }; then
      fail "$kind: could not commit the firstmate-shaped worktree"
    fi
    if [ "$kind" = ship ]; then
      out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
    else
      out=$(run_case_spawn "$id" "$PROJ_DIR" --scout)
    fi
    status=$?
    expect_code 0 "$status" "$kind spawn in a firstmate-repo worktree should succeed: $out"
    seen=$(emitted_launch_probe "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" unset) \
      || fail "$kind in a firstmate-repo worktree: the emitted launch failed to run"
    assert_lean_common "$seen" "$kind in a firstmate-repo worktree"
    assert_worker_excludes_personal_file "$seen" "$HOME_DIR" "$kind in a firstmate-repo worktree"
    personal=$(personal_claude_md "$HOME_DIR")
    settings=$(probe_value_after "$seen" --settings)
    printf '%s' "$settings" | jq -e --arg p "$personal" --arg a "$WT_DIR/AGENTS.md" --arg c "$WT_DIR/CLAUDE.md" \
        '.claudeMdExcludes == [$p, $a, $c]' >/dev/null \
      || fail "$kind in a firstmate-repo worktree: settings must also exclude the worktree's AGENTS.md and CLAUDE.md: $settings"
    prompt=$(probe_value_after "$seen" --append-system-prompt)
    assert_contains "$prompt" "$FM_REPO_ADDRESS_RULE" "$kind in a firstmate-repo worktree: the append must carry the no-direct-address rule"
    assert_contains "$prompt" "$FM_REPO_WATCHER_RULE" "$kind in a firstmate-repo worktree: the append must carry the watcher rule"
    assert_contains "$prompt" "Never wrap a shell command in base64" "$kind in a firstmate-repo worktree: the append must keep its other rules"
  done
  pass "a ship or scout worker in a firstmate-repo worktree skips its AGENTS.md and CLAUDE.md and carries the two binding rules"
}

make_secondmate_home() {  # <dir> <id>
  local sm=$1 id=$2
  mkdir -p "$sm/bin" "$sm/data"
  make_firstmate_shaped "$sm"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main
}

test_secondmate_launch_lean_but_keeps_personal_file() {
  local setting rec sm out status seen settings
  for setting in absent enabled; do
    rec=$(make_case "secondmate-$setting" "sm-$setting")
    read_case "$rec"
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    sm="$CASE_DIR/secondmate-home"
    make_secondmate_home "$sm" "sm-$setting"
    out=$(run_case_spawn "sm-$setting" "$sm" --secondmate)
    status=$?
    expect_code 0 "$status" "secondmate spawn with allowlist=$setting should succeed: $out"
    seen=$(emitted_launch_probe "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "$CONTRARY") \
      || fail "secondmate, allowlist $setting: the emitted launch failed to run"
    assert_equals "CONNECTORS=false" "$(printf '%s\n' "$seen" | head -1)" \
      "secondmate, allowlist $setting: claude.ai connectors must be off"
    assert_lean_common "$seen" "secondmate, allowlist $setting"
    settings=$(probe_value_after "$seen" --settings)
    printf '%s' "$settings" | jq -e 'has("claudeMdExcludes") | not' >/dev/null \
      || fail "secondmate, allowlist $setting: a second mate must keep loading the personal CLAUDE.md and its home's AGENTS.md: $settings"
    probe_has_arg "$seen" --append-system-prompt \
      && fail "secondmate, allowlist $setting: a second mate must not receive the task-worker append"
    assert_equals WORKER=unset "$(probe_line "$seen" WORKER)" "secondmate, allowlist $setting: a second mate is not a task worker"
    assert_equals AUTOMEMORY=unset "$(probe_line "$seen" AUTOMEMORY)" "secondmate, allowlist $setting: a second mate keeps auto memory"
  done
  pass "a secondmate Claude launch starts lean and keeps the personal CLAUDE.md"
}

# config/claude-auto-memory lists the projects whose workers keep Claude auto
# memory, by project directory name; every other project's workers start
# without it.
test_auto_memory_opt_out_keeps_memory_for_listed_projects() {
  local rec out status seen kind id
  for kind in ship scout; do
    id="$kind-automemory-a1"
    rec=$(make_case "$kind-automemory" "$id")
    read_case "$rec"
    # Surrounding whitespace, including a CRLF line end, is ignored.
    printf 'other-project\n  %s \r\n' "$(basename "$PROJ_DIR")" > "$HOME_DIR/config/claude-auto-memory"
    if [ "$kind" = ship ]; then
      out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
    else
      out=$(run_case_spawn "$id" "$PROJ_DIR" --scout)
    fi
    status=$?
    expect_code 0 "$status" "$kind spawn with an auto-memory opt-out should succeed: $out"
    seen=$(emitted_launch_probe "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" unset) \
      || fail "$kind with an auto-memory opt-out: the emitted launch failed to run"
    assert_task_worker_env "$seen" on "$kind in a listed project"
    assert_lean_common "$seen" "$kind in a listed project"
  done
  id=ship-unlisted-a1
  rec=$(make_case ship-unlisted "$id")
  read_case "$rec"
  printf 'other-project\n' > "$HOME_DIR/config/claude-auto-memory"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn in a project the opt-out list omits should succeed: $out"
  seen=$(emitted_launch_probe "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" unset) \
    || fail "ship in an unlisted project: the emitted launch failed to run"
  assert_task_worker_env "$seen" off "ship in an unlisted project"
  pass "a project listed in config/claude-auto-memory keeps auto memory for its workers, and only it"
}

test_unreadable_auto_memory_list_refuses_the_spawn() {
  local rec out status id=ship-automemory-unreadable
  rec=$(make_case ship-automemory-unreadable "$id")
  read_case "$rec"
  ln -s "$CASE_DIR/missing-auto-memory-list" "$HOME_DIR/config/claude-auto-memory"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a ship spawn with an unreadable config/claude-auto-memory should refuse: $out"
  assert_contains "$out" "config/claude-auto-memory" "the refusal should name the file: $out"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn must not launch anything"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not write a task record"
  pass "an unreadable config/claude-auto-memory refuses a Claude task worker spawn before launching"
}

test_connector_opt_in_leaves_connectors_on() {
  local rec out status seen kind id
  for kind in ship scout; do
    id="$kind-connectors-a1"
    rec=$(make_case "$kind-connectors" "$id")
    read_case "$rec"
    if [ "$kind" = ship ]; then
      out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --claude-connectors)
    else
      out=$(run_case_spawn "$id" "$PROJ_DIR" --scout --claude-connectors)
    fi
    status=$?
    expect_code 0 "$status" "$kind spawn with --claude-connectors should succeed: $out"
    seen=$(emitted_launch_probe "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" unset) \
      || fail "$kind with connectors: the emitted launch failed to run"
    assert_equals "CONNECTORS=unset" "$(printf '%s\n' "$seen" | head -1)" \
      "$kind with --claude-connectors: the launch must not switch claude.ai connectors off"
    assert_lean_common "$seen" "$kind with connectors"
  done
  pass "--claude-connectors keeps claude.ai connectors while every other lean lever still applies"
}

# A secondmate is respawned by its own owner path rather than by relaunch, so
# the opt-in is a task-worker choice and a secondmate spawn refuses it before
# any endpoint or record exists.
test_secondmate_refuses_connector_opt_in() {
  local rec sm out status
  rec=$(make_case secondmate-connectors sm-connectors)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_secondmate_home "$sm" sm-connectors
  out=$(run_case_spawn sm-connectors "$sm" --secondmate --claude-connectors)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn with --claude-connectors should refuse: $out"
  assert_contains "$out" "--claude-connectors" "the refusal should name the flag: $out"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused secondmate spawn must not launch anything"
  [ ! -e "$HOME_DIR/state/sm-connectors.meta" ] || fail "a refused secondmate spawn must not write a task record"
  pass "a secondmate spawn refuses --claude-connectors before launching"
}

# --- relaunch ---------------------------------------------------------------
#
# bin/fm-control.sh relaunch stops the agent and rebuilds the launch through
# bin/fm-spawn.sh --relaunch. The stub models just enough pane lifecycle: the
# exit command leaves a bare shell behind, and the launch literal starts claude.
make_relaunch_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *' claude '*) printf 'claude' > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

test_relaunch_keeps_the_connector_choice() {
  local choice dir home proj wt id out status seen launch preamble expected
  for choice in default opted-in; do
    id="relaunch-$choice-a1"
    dir="$TMP_ROOT/relaunch-$choice"
    home="$dir/home"
    proj="$dir/proj"
    wt="$dir/wt"
    mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake" "$dir/user-home"
    touch "$home/state/.last-watcher-beat"
    make_relaunch_stub "$dir"
    fm_git_worktree "$proj" "$wt" "wt-relaunch-$choice"
    fm_test_spawn_brief "$home" "$id"
    : > "$dir/fake/literal"
    : > "$dir/fake/keys"
    printf 'claude' > "$dir/fake/command"
    printf '%s\n' "fm-$id" > "$dir/fake/windows"
    printf '%s' "$wt" > "$dir/fake/cwd"
    {
      echo "window=fmses:fm-$id"
      echo "endpoint_task_id=$id"
      echo "worktree=$wt"
      echo "project=$proj"
      echo "harness=claude"
      echo "kind=ship"
      echo "mode=no-mistakes"
      echo "yolo=off"
      echo "tasktmp=$dir/tasktmp"
      echo "model=default"
      echo "effort=default"
      [ "$choice" = default ] || echo "claude_connectors=on"
    } > "$home/state/$id.meta"

    out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
      HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
      "$CONTROL" "$id" relaunch --note 'replacement continues the same task' 2>&1)
    status=$?
    expect_code 0 "$status" "relaunch with connectors $choice should succeed: $out"
    launch=$(grep ' claude ' "$dir/fake/literal" | tail -1)
    [ -n "$launch" ] || fail "relaunch with connectors $choice sent no replacement launch command"
    install_claude_probe "$dir/fakebin"
    preamble=$(grep '^export ' "$dir/fake/keys")
    seen=$(env -i HOME="$dir/user-home" PATH="$dir/fakebin:$PATH" TERM=xterm TMUX=synthetic-pane \
      /bin/sh -c "$preamble
$launch") || fail "relaunch with connectors $choice: the replacement launch failed to run"
    expected=CONNECTORS=false
    [ "$choice" = default ] || expected=CONNECTORS=unset
    assert_equals "$expected" "$(printf '%s\n' "$seen" | head -1)" \
      "a relaunched worker must keep the connector choice its task was spawned with ($choice)"
    assert_lean_common "$seen" "relaunch, connectors $choice"
    assert_task_worker_env "$seen" off "relaunch, connectors $choice"
    grep -c '^claude_connectors=on$' "$home/state/$id.meta" | grep -qx "$([ "$choice" = default ] && echo 0 || echo 1)" \
      || fail "relaunch with connectors $choice: the task record must keep exactly its connector choice"
  done
  pass "relaunch rebuilds the lean launch and keeps the task's connector choice"
}

test_ship_and_scout_launch_lean_in_both_allowlist_postures
test_firstmate_repo_worker_skips_the_supervisor_contract
test_secondmate_launch_lean_but_keeps_personal_file
test_auto_memory_opt_out_keeps_memory_for_listed_projects
test_unreadable_auto_memory_list_refuses_the_spawn
test_connector_opt_in_leaves_connectors_on
test_secondmate_refuses_connector_opt_in
test_relaunch_keeps_the_connector_choice
