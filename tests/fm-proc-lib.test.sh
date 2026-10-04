#!/usr/bin/env bash
# tests/fm-proc-lib.test.sh - process facts without ps (bin/fm-proc-lib.sh).
#
# Inside Codex's macOS seatbelt sandbox /bin/ps cannot execute (it is setuid)
# and `kill -0` on any process outside the current command fails with EPERM, so
# a live process reads as dead. These cases reproduce that environment with a
# PATH-shadowed ps that fails exactly as the sandbox makes it fail and a kill
# stub that refuses every signal, then assert the verdicts come from the kernel
# process record instead. Every sandbox case is paired with the same question
# asked with a working ps, which must keep today's verdict unchanged.
# shellcheck disable=SC2016 # single quotes are deliberate: these scripts run inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-proc-lib)
PROC_LIB="$ROOT/bin/fm-proc-lib.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"

# A ps that cannot run, as inside the Codex sandbox.
SANDBOX_BIN=$(fm_fakebin "$TMP_ROOT/sandbox")
cat > "$SANDBOX_BIN/ps" <<'SH'
#!/bin/sh
echo "/bin/ps: Operation not permitted" >&2
exit 126
SH
chmod +x "$SANDBOX_BIN/ps"

LIVE_PIDS=()
cleanup_live() {
  local pid
  for pid in ${LIVE_PIDS[@]+"${LIVE_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_live EXIT

LIVE_PID=
start_live() {  # sets LIVE_PID to a live background process
  sleep 120 &
  LIVE_PID=$!
  LIVE_PIDS+=("$LIVE_PID")
}

dead_pid() {  # prints the pid of a process that has already exited
  local pid
  sh -c 'exit 0' &
  pid=$!
  wait "$pid" 2>/dev/null || true
  printf '%s\n' "$pid"
}

# Evaluate <expr> with the process-facts library loaded. <mode> sandbox shadows
# ps with the failing one and makes every kill -0 refuse, as EPERM does in the
# sandbox; <mode> host leaves ps and kill alone. <lib> defaults to the
# process-facts library.
proc_eval() {  # <mode> <expr> [<lib>]
  local mode=$1 expr=$2 lib=${3:-$PROC_LIB} path=$PATH stub=''
  if [ "$mode" = sandbox ]; then
    path="$SANDBOX_BIN:$PATH"
    stub='kill() { return 1; }'
  fi
  PATH="$path" FM_STATE_OVERRIDE="$TMP_ROOT/state" bash -c "
    . \"\$0\"
    $stub
    $expr
  " "$lib"
}

test_live_process_in_another_command_reads_alive_in_the_sandbox() {
  local live dead
  start_live
  live=$LIVE_PID
  dead=$(dead_pid)
  proc_eval sandbox "fm_pid_alive $live" \
    || fail "sandbox: a live pid refused by kill -0 read as dead"
  if proc_eval sandbox "fm_pid_alive $dead"; then
    fail "sandbox: an exited pid read as alive"
  fi
  proc_eval host "fm_pid_alive $live" || fail "host: a live pid read as dead"
  if proc_eval host "fm_pid_alive $dead"; then
    fail "host: an exited pid read as alive"
  fi
  pass "proc: liveness without ps reads live as alive and exited as dead"
}

test_refused_signal_with_working_ps_keeps_the_dead_verdict() {
  local live
  start_live
  live=$LIVE_PID
  # With ps runnable the session is not sandboxed, so a refused signal keeps
  # exactly today's verdict.
  if proc_eval host "kill() { return 1; }; fm_pid_alive $live"; then
    fail "host: a refused signal with a working ps changed the dead verdict"
  fi
  pass "proc: an unsandboxed refused signal keeps today's verdict"
}

test_live_lock_holder_is_not_stolen_in_the_sandbox() {
  local live dead lock
  start_live
  live=$LIVE_PID
  dead=$(dead_pid)
  lock="$TMP_ROOT/held.lock"
  mkdir -p "$lock"
  printf '%s\n' "$live" > "$lock/pid"
  if proc_eval sandbox "fm_lock_try_acquire '$lock'" "$WAKE_LIB"; then
    fail "sandbox: a mkdir lock held by a live process in another command was stolen"
  fi
  [ "$(cat "$lock/pid")" = "$live" ] || fail "sandbox: the live holder's pid was overwritten"
  printf '%s\n' "$dead" > "$lock/pid"
  proc_eval sandbox "fm_lock_try_acquire '$lock'" "$WAKE_LIB" \
    || fail "sandbox: a mkdir lock whose holder exited was not reclaimed"
  pass "proc: shared locks keep a live holder and reclaim an exited one without ps"
}

# A watcher records its identity inside the sandbox and an unsandboxed Stop hook
# verifies it with ps available, so both contexts must compute the same value.
test_identity_is_the_same_inside_and_outside_the_sandbox() {
  local live other inside outside other_id
  start_live
  live=$LIVE_PID
  start_live
  other=$LIVE_PID
  inside=$(proc_eval sandbox "fm_pid_identity $live") \
    || fail "sandbox: no identity for a live process"
  [ -n "$inside" ] || fail "sandbox: an empty identity for a live process"
  outside=$(proc_eval host "fm_pid_identity $live") || fail "host: no identity for a live process"
  assert_equals "$outside" "$inside" "identity differs inside and outside the sandbox"
  other_id=$(proc_eval sandbox "fm_pid_identity $other") || fail "sandbox: no identity for a second process"
  assert_not_equals "$inside" "$other_id" "two live processes share one identity"
  if proc_eval sandbox "fm_pid_identity $(dead_pid)" >/dev/null; then
    fail "sandbox: an exited pid still has an identity"
  fi
  pass "proc: identity is non-empty, per-process, and equal inside and outside the sandbox"
}

# A harness-named process: a real executable whose kernel command name is
# codex, so ancestry walks see a codex-shaped process without Codex installed.
# Neither a symlink to bash nor a script works (the kernel names both bash),
# and macOS kills a copied system bash. `codex -c <script> [<arg>...]` runs the
# script in a child bash and waits for it; `codex --wait` just stays alive.
# Without a C compiler the cases that need it report a skip.
CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
cat > "$TMP_ROOT/fake-codex.c" <<'C'
#include <errno.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
  int status;
  pid_t child;
  if (argc == 2 && strcmp(argv[1], "--wait") == 0) {
    for (;;) pause();
  }
  if (argc < 3 || strcmp(argv[1], "-c") != 0) return 64;
  child = fork();
  if (child < 0) return 70;
  if (child == 0) {
    argv[0] = "bash";
    argv[1] = "-c";
    execv("/bin/bash", argv);
    _exit(127);
  }
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) return 71;
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 72;
}
C
HARNESS=
if [ -n "$CC_BIN" ]; then
  mkdir -p "$TMP_ROOT/harness"
  HARNESS="$TMP_ROOT/harness/codex"
  "$CC_BIN" -o "$HARNESS" "$TMP_ROOT/fake-codex.c" || fail "could not build the fake codex process"
fi

have_harness() {  # <case name>: true, or reports the case skipped
  [ -n "$HARNESS" ] && return 0
  pass "$1 skipped: no C compiler to build the fake codex process"
  return 1
}

# Run <script> inside a codex-shaped harness process, whose pid the script sees
# as $PPID. <mode> sandbox shadows ps with the failing one and makes kill -0
# refuse in every bash below the harness, as the sandbox's EPERM does; host
# leaves both alone. Extra arguments reach the script as $1...
in_harness() {  # <mode> <script> [<arg>...]
  local mode=$1 script=$2 path=$PATH prelude=''
  shift 2
  if [ "$mode" = sandbox ]; then
    path="$SANDBOX_BIN:$PATH"
    prelude='kill() { if [ "${1:-}" = -0 ]; then return 1; fi; builtin kill "$@"; }; export -f kill;'
  fi
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CODEX_THREAD_ID \
    PATH="$path" ROOT="$ROOT" "$HARNESS" -c "$prelude $script" in-harness "$@"
}

start_live_harness() {  # sets LIVE_PID to a live codex-shaped process
  "$HARNESS" --wait &
  LIVE_PID=$!
  LIVE_PIDS+=("$LIVE_PID")
}

test_field_reads_without_ps() {
  have_harness "proc: kernel-record fields" || return 0
  local live parent comm args
  start_live_harness
  live=$LIVE_PID
  comm=$(proc_eval sandbox "fm_proc_field comm $live") || fail "sandbox: no command name for a live process"
  [ "$(basename -- "$comm")" = codex ] || fail "sandbox: command name '$comm', expected codex"
  parent=$(proc_eval sandbox "fm_proc_field ppid $live") || fail "sandbox: no parent for a live process"
  assert_equals "$$" "$(printf '%s' "$parent" | tr -d ' ')" "sandbox: parent pid of the test's own child"
  args=$(proc_eval sandbox "fm_proc_field args $live") || fail "sandbox: args read failed for a live process"
  assert_equals "" "$args" "sandbox: args are absent from the kernel record"
  if proc_eval sandbox "fm_proc_field comm $(dead_pid)" >/dev/null; then
    fail "sandbox: an exited pid still has a command name"
  fi
  comm=$(proc_eval host "fm_proc_field comm $live") || fail "host: no command name for a live process"
  assert_equals "$(ps -o comm= -p "$live")" "$comm" "host: command name differs from ps"
  args=$(proc_eval host "fm_proc_field args $live") || fail "host: no args for a live process"
  assert_equals "$(ps -o args= -p "$live")" "$args" "host: args differ from ps"
  pass "proc: fields come from ps where it runs and from the kernel record where it cannot"
}

# bin/fm-lock.sh is the session lock a Codex primary or secondmate takes at
# session start: it must take a lock whose recorded owner is dead, refuse one a
# live session owns, and confirm its own on a later call, inside the sandbox as
# it does outside it.
test_session_lock_inside_the_sandbox() {
  have_harness "session-lock: sandbox lock" || return 0
  local mode state out live
  for mode in sandbox host; do
    state="$TMP_ROOT/lock-$mode/state"
    mkdir -p "$state"
    dead_pid > "$state/.lock"
    out=$(in_harness "$mode" 'export FM_STATE_OVERRIDE="$1"; bash "$ROOT/bin/fm-lock.sh" && bash "$ROOT/bin/fm-lock.sh" && echo "harness=$PPID"' "$state" 2>&1) \
      || fail "$mode: a dead owner's lock was not taken and confirmed: $out"
    case "$out" in *harness=*) ;; *) fail "$mode: lock run printed no harness pid: $out" ;; esac
    assert_equals "${out##*harness=}" "$(head -n 1 "$state/.lock")" "$mode: lock line 1 is not the harness pid"
    start_live_harness
    live=$LIVE_PID
    printf '%s\n' "$live" > "$state/.lock"
    if out=$(in_harness "$mode" 'FM_STATE_OVERRIDE="$1" bash "$ROOT/bin/fm-lock.sh"' "$state" 2>&1); then
      fail "$mode: a lock owned by a live session was taken: $out"
    fi
    case "$out" in
      *"another live firstmate session holds the lock (pid $live)"*) ;;
      *) fail "$mode: the live-owner refusal did not name the owner: $out" ;;
    esac
    assert_equals "$live" "$(head -n 1 "$state/.lock")" "$mode: the live owner's lock was rewritten"
    out=$(in_harness "$mode" 'FM_STATE_OVERRIDE="$1" bash "$ROOT/bin/fm-lock.sh" status' "$state" 2>&1)
    assert_equals "lock: held by live harness pid $live" "$out" "$mode: status of a live-held lock"
  done
  pass "session-lock: dead owner taken, live owner refused, own lock confirmed, inside and outside the sandbox"
}

test_harness_detection_inside_the_sandbox() {
  have_harness "harness: sandbox ancestry" || return 0
  local mode out
  for mode in sandbox host; do
    out=$(in_harness "$mode" 'bash "$ROOT/bin/fm-harness.sh" ancestry') \
      || fail "$mode: harness ancestry failed"
    assert_equals "comm codex" "$out" "$mode: harness ancestry verdict"
  done
  pass "harness: ancestry resolves codex inside and outside the sandbox"
}

# The Codex watcher records its identity inside the sandbox; the Stop-hook
# turn-end guard checks it outside, with ps. Both directions must agree.
test_watcher_identity_crosses_the_sandbox() {
  local live state recorder checker watch_path=/fm/bin/fm-watch.sh home=/fm/home
  start_live
  live=$LIVE_PID
  for recorder in sandbox host; do
    for checker in sandbox host; do
      state="$TMP_ROOT/watch-$recorder-$checker"
      mkdir -p "$state/.watch.lock"
      printf '%s\n' "$live" > "$state/.watch.lock/pid"
      printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
      printf '%s\n' "$watch_path" > "$state/.watch.lock/watcher-path"
      proc_eval "$recorder" "fm_pid_identity $live" > "$state/.watch.lock/pid-identity" \
        || fail "$recorder: no watcher identity recorded"
      : > "$state/.last-watcher-beat"
      proc_eval "$checker" "fm_watcher_healthy '$state' '$watch_path' 300 '$home'" "$WAKE_LIB" \
        || fail "a watcher recorded in the $recorder context failed the $checker health check"
    done
  done
  printf '%s\n' "$(dead_pid)" > "$state/.watch.lock/pid"
  if proc_eval sandbox "fm_watcher_healthy '$state' '$watch_path' 300 '$home'" "$WAKE_LIB"; then
    fail "sandbox: an exited watcher read as healthy"
  fi
  pass "watcher: identity recorded on either side of the sandbox passes the health check on the other"
}

# Without ps the kernel record has no argv or executable path, so a live holder
# whose command name is not harness-shaped could still be a harness that only
# argv identifies (a version-named Claude Code binary, a script under node).
# Inside the sandbox such a lock is refused rather than taken; outside it, ps
# proves the holder is no harness and the lock is stale, exactly as before.
test_unrecognizable_live_holder_is_refused_in_the_sandbox() {
  have_harness "session-lock: unrecognizable holder" || return 0
  local mode state out rc
  start_live
  for mode in sandbox host; do
    state="$TMP_ROOT/unknown-holder-$mode/state"
    mkdir -p "$state"
    printf '%s\n' "$LIVE_PID" > "$state/.lock"
    out=$(in_harness "$mode" 'FM_STATE_OVERRIDE="$1" bash "$ROOT/bin/fm-lock.sh"' "$state" 2>&1) && rc=0 || rc=$?
    case "$mode:$rc" in
      sandbox:0) fail "sandbox: a live holder it could not identify lost its lock: $out" ;;
      host:0) ;;
      host:*) fail "host: a live non-harness holder's stale lock was not taken: $out" ;;
    esac
  done
  pass "session-lock: an unidentifiable live holder is refused inside the sandbox and stale outside it"
}

# A live pid that is no recognizable harness keeps its lock inside the sandbox
# only while it could be the process that wrote the lock: one that started in a
# later second than the lock file was last written is a reused pid, and the
# lock is taken. One that started in the same second still refuses.
test_holder_started_after_the_lock_was_written_is_stale_in_the_sandbox() {
  have_harness "session-lock: holder started after the lock" || return 0
  local state out start
  start_live
  state="$TMP_ROOT/reused-holder/state"
  mkdir -p "$state"
  start=$(proc_eval sandbox "fm_proc_start_epoch $LIVE_PID") \
    || fail "sandbox: no start time for a live process"
  printf '%s\n' "$LIVE_PID" > "$state/.lock"
  perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1] or exit 1' "$start" "$state/.lock" \
    || fail "could not set the lock's mtime"
  if out=$(in_harness sandbox 'FM_STATE_OVERRIDE="$1" bash "$ROOT/bin/fm-lock.sh"' "$state" 2>&1); then
    fail "sandbox: a holder that started in the lock's own second lost its lock: $out"
  fi
  assert_equals "$LIVE_PID" "$(head -n 1 "$state/.lock")" "sandbox: a same-second holder's lock was rewritten"
  perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1] or exit 1' "$((start - 1))" "$state/.lock" \
    || fail "could not set the lock's mtime"
  out=$(in_harness sandbox 'FM_STATE_OVERRIDE="$1" bash "$ROOT/bin/fm-lock.sh" && echo "harness=$PPID"' "$state" 2>&1) \
    || fail "sandbox: a holder that started after the lock was written kept it: $out"
  assert_equals "${out##*harness=}" "$(head -n 1 "$state/.lock")" "sandbox: the reused pid's lock was not taken"
  pass "session-lock: a holder that started after the lock was written is stale inside the sandbox"
}

# Inside the sandbox a watcher started by an earlier command cannot be
# signalled, so --stop must say the sandbox refused the signal instead of
# waiting it out and reporting a generic failure. Outside it, the watcher stops.
test_watcher_stop_reports_a_refused_signal() {
  local mode home state out rc
  for mode in sandbox host; do
    start_live
    home="$TMP_ROOT/watch-stop-$mode"
    state="$home/state"
    mkdir -p "$state/.watch.lock"
    printf '%s\n' "$LIVE_PID" > "$state/.watch.lock/pid"
    printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
    printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$state/.watch.lock/watcher-path"
    proc_eval "$mode" "fm_pid_identity $LIVE_PID" > "$state/.watch.lock/pid-identity" \
      || fail "$mode: no watcher identity recorded"
    out=$(proc_eval "$mode" "export -f kill 2>/dev/null; unset FM_STATE_OVERRIDE; FM_HOME='$home' bash '$ROOT/bin/fm-watch-arm.sh' --stop" 2>&1) && rc=0 || rc=$?
    case "$mode:$rc:$out" in
      sandbox:1:*"watcher: FAILED - pid=$LIVE_PID did not stop: the sandbox refused the stop signal"*) ;;
      host:0:*"watcher: stopped pid=$LIVE_PID"*) ;;
      *) fail "$mode: unexpected --stop result (exit $rc): $out" ;;
    esac
  done
  pass "watcher: --stop names the sandbox's refused signal and stops the watcher outside it"
}

test_live_process_in_another_command_reads_alive_in_the_sandbox
test_identity_is_the_same_inside_and_outside_the_sandbox
test_live_lock_holder_is_not_stolen_in_the_sandbox
test_refused_signal_with_working_ps_keeps_the_dead_verdict
test_field_reads_without_ps
test_session_lock_inside_the_sandbox
test_harness_detection_inside_the_sandbox
test_watcher_identity_crosses_the_sandbox
test_unrecognizable_live_holder_is_refused_in_the_sandbox
test_holder_started_after_the_lock_was_written_is_stale_in_the_sandbox
test_watcher_stop_reports_a_refused_signal
