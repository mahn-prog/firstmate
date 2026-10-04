#!/usr/bin/env bash
# Live guard: the session lock and process liveness inside the real Codex
# sandbox.
#
# On macOS every command a Codex primary, secondmate, or crewmate runs executes
# in Codex's seatbelt sandbox, where /bin/ps cannot execute and `kill -0` on a
# process outside the current command is refused. The session lock, liveness,
# and watcher identity therefore read the kernel process record there
# (bin/fm-proc-lib.sh). A stub can only confirm that assumption, so this guard
# runs the real scripts under the installed `codex sandbox` with the
# workspace-write profile, in a throwaway home, and checks: a dead owner's lock
# is taken, a live Codex session's lock is refused, a session confirms its own
# lock, session start takes the lock writable, and a process's liveness and
# identity read the same inside as outside. `codex sandbox` has no approval
# path, so every step passing is also the proof that none needed escalation.
#
# It spends no model tokens (`codex sandbox` runs commands only), so it runs by
# default wherever codex is installed on macOS.
# shellcheck disable=SC2016 # single quotes are deliberate: these scripts run inside the sandboxed child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CODEX_SANDBOX_PROC_LIVE codex

if [ "$(uname)" != Darwin ]; then
  printf 'skip: live: the codex sandbox process restriction is macOS seatbelt only\n'
  exit 0
fi

CODEX_VERSION=$(codex --version 2>&1)
TMP_ROOT=$(fm_test_tmproot fm-codex-sandbox-proc-live)
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"
LIVE_PIDS=()
cleanup_live() {
  local pid
  for pid in ${LIVE_PIDS[@]+"${LIVE_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_live EXIT

# Run a command inside the Codex sandbox with this home's workspace-write mode.
# The bare `codex sandbox` resolves to read-only, so the mode is passed
# explicitly. The scratch home lives under TMPDIR, which that mode can write.
sbx() {  # <home> <command...>
  local home=$1
  shift
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    codex sandbox -c 'sandbox_mode="workspace-write"' -- \
    /usr/bin/env FM_HOME="$home" ROOT="$ROOT" "$@"
}

new_home() {  # <name>: prints a scratch home whose lock names an exited pid
  local home="$TMP_ROOT/$1" pid
  mkdir -p "$home/state"
  sh -c 'exit 0' &
  pid=$!
  wait "$pid" 2>/dev/null || true
  printf '%s\n' "$pid" > "$home/state/.lock"
  printf '%s\n' "$home"
}

test_sandbox_still_forbids_ps_and_foreign_signals() {
  local home out
  home=$(new_home probe)
  sleep 120 &
  LIVE_PIDS+=("$!")
  out=$(sbx "$home" /bin/bash -c 'ps -o pid= -p $$ >/dev/null 2>&1; echo "ps=$?"; kill -0 "$1" 2>/dev/null; echo "kill=$?"' probe "$!" 2>&1) \
    || fail "codex $CODEX_VERSION: the sandbox probe itself failed: $out"
  case "$out" in
    *ps=126*kill=1*) ;;
    *) fail "codex $CODEX_VERSION: ps or foreign kill -0 now runs inside the sandbox, so this guard no longer exercises the no-ps path; update it: $out" ;;
  esac
  pass "codex $CODEX_VERSION: the sandbox still refuses ps and foreign kill -0"
}

test_lock_dead_owner_taken_and_own_confirmed() {
  local home out
  home=$(new_home dead-owner)
  out=$(sbx "$home" /bin/bash -c 'bash "$ROOT/bin/fm-lock.sh" && bash "$ROOT/bin/fm-lock.sh" && bash "$ROOT/bin/fm-lock.sh" status' 2>&1) \
    || fail "codex $CODEX_VERSION: the sandbox did not take a dead owner's lock and confirm it: $out"
  case "$out" in
    *"lock acquired: harness pid "*"lock acquired: harness pid "*"lock: held by live harness pid "*) ;;
    *) fail "codex $CODEX_VERSION: unexpected lock output: $out" ;;
  esac
  pass "codex $CODEX_VERSION: a dead owner's lock is taken and confirmed inside the sandbox"
}

test_live_session_lock_refused_then_reclaimed_after_exit() {
  local home holder out session waited=0
  home=$(new_home live-owner)
  # A first Codex session takes the lock and stays alive until told to stop.
  sbx "$home" /bin/bash -c 'bash "$ROOT/bin/fm-lock.sh" >/dev/null 2>&1 || exit 1; : > "$FM_HOME/ready"; while [ ! -e "$FM_HOME/stop" ]; do sleep 0.2; done' &
  session=$!
  LIVE_PIDS+=("$session")
  while [ ! -e "$home/ready" ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 150 ] || fail "codex $CODEX_VERSION: the first sandbox session never took the lock"
    sleep 0.2
  done
  holder=$(head -n 1 "$home/state/.lock")
  if out=$(sbx "$home" /bin/bash -c 'bash "$ROOT/bin/fm-lock.sh"' 2>&1); then
    fail "codex $CODEX_VERSION: a second sandbox session took a live session's lock: $out"
  fi
  case "$out" in
    *"another live firstmate session holds the lock (pid $holder)"*) ;;
    *) fail "codex $CODEX_VERSION: the live-owner refusal did not name pid $holder: $out" ;;
  esac
  assert_equals "$holder" "$(head -n 1 "$home/state/.lock")" "codex $CODEX_VERSION: the live owner's lock was rewritten"
  : > "$home/stop"
  wait "$session" 2>/dev/null || true
  out=$(sbx "$home" /bin/bash -c 'bash "$ROOT/bin/fm-lock.sh"' 2>&1) \
    || fail "codex $CODEX_VERSION: the exited session's lock was not reclaimed: $out"
  pass "codex $CODEX_VERSION: a live session's lock is refused and reclaimed once that session exits"
}

test_session_start_takes_the_lock_writable() {
  local home digest
  home=$(new_home session-start)
  digest="$home/digest.txt"
  sbx "$home" /bin/bash -c 'bash "$ROOT/bin/fm-session-start.sh" > "$FM_HOME/digest.txt" 2>&1' \
    || fail "codex $CODEX_VERSION: session start failed inside the sandbox: $(head -n 40 "$digest" 2>/dev/null)"
  grep -q '^lock acquired: harness pid ' "$digest" \
    || fail "codex $CODEX_VERSION: session start did not take the lock: $(sed -n '1,12p' "$digest")"
  if grep -q 'operate read-only' "$digest"; then
    fail "codex $CODEX_VERSION: session start came up read-only: $(grep 'operate read-only' "$digest")"
  fi
  pass "codex $CODEX_VERSION: session start takes the lock writable inside the sandbox"
}

# The Codex watcher records its identity inside the sandbox and the Stop-hook
# turn-end guard checks it outside, so both must read one process the same way.
test_liveness_and_identity_match_across_the_sandbox() {
  local home live dead inside outside state watch_path=/fm/bin/fm-watch.sh
  home=$(new_home identity)
  sleep 120 &
  live=$!
  LIVE_PIDS+=("$live")
  dead=$(head -n 1 "$home/state/.lock")
  inside=$(sbx "$home" /bin/bash -c '. "$ROOT/bin/fm-wake-lib.sh"; fm_pid_alive "$1" || exit 3; if fm_pid_alive "$2"; then exit 4; fi; fm_pid_identity "$1"' identity "$live" "$dead" 2>&1) \
    || fail "codex $CODEX_VERSION: liveness or identity inside the sandbox failed: $inside"
  outside=$(FM_HOME="$home" bash -c '. "$1"; fm_pid_identity "$2"' identity "$WAKE_LIB" "$live") \
    || fail "codex $CODEX_VERSION: identity outside the sandbox failed"
  [ -n "$inside" ] || fail "codex $CODEX_VERSION: an empty identity inside the sandbox"
  assert_equals "$outside" "$inside" "codex $CODEX_VERSION: identity differs inside and outside the sandbox"
  state="$home/state"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$watch_path" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$inside" > "$state/.watch.lock/pid-identity"
  : > "$state/.last-watcher-beat"
  FM_HOME="$home" bash -c '. "$1"; fm_watcher_healthy "$2" "$3" 300 "$4"' health "$WAKE_LIB" "$state" "$watch_path" "$home" \
    || fail "codex $CODEX_VERSION: a watcher identity recorded inside the sandbox failed the health check outside"
  pass "codex $CODEX_VERSION: liveness and identity read the same inside and outside the sandbox"
}

test_sandbox_still_forbids_ps_and_foreign_signals
test_lock_dead_owner_taken_and_own_confirmed
test_live_session_lock_refused_then_reclaimed_after_exit
test_session_start_takes_the_lock_writable
test_liveness_and_identity_match_across_the_sandbox
