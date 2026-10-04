#!/usr/bin/env bash
# Process facts: the one owner of "does this pid exist, and what is it?".
#
# Inside Codex's macOS seatbelt sandbox, which runs every command a Codex
# primary, secondmate, or crewmate executes, /bin/ps cannot execute (it is
# setuid root) and `kill -0` on any process outside the current command fails
# with EPERM, so a live process looks dead. The kernel process record stays
# readable there: Codex's own sandbox policy allows the sysctl name
# kern.proc.pid.<pid> for any pid, and Linux exposes /proc/<pid>/stat. This
# library reads that record where ps cannot run, so an unsandboxed session
# keeps exactly the ps and kill -0 path it always had for liveness and process
# fields. Pid identity is the one exception: on macOS it is the kernel record in
# every context, so an identity recorded inside the sandbox matches the one
# computed outside it.
# docs/verification/runtime-backends.md records the sandbox facts this rests on.
#
# The kernel record carries the parent pid, command name (at most 16 bytes),
# and start time. It does not carry argv or the executable path, so a field
# that needs them reads as absent without ps.
#
# This file is sourced and has no side effects on source beyond defining
# functions and resolving the platform name once.

# Resolved once at source time: fm_pid_identity runs inside 0.2s confirm and
# 0.5s attach polls, and forking uname per call is a measurable cost on the
# platform (Git Bash/MSYS) that already pays the highest fork price.
_FM_UNAME=${_FM_UNAME:-$(uname 2>/dev/null || echo unknown)}

# Read one kernel process record through sysctl {CTL_KERN, KERN_PROC,
# KERN_PROC_PID, pid} (syscall 202 is __sysctl on 64-bit Darwin) and print
# "ppid start_sec start_usec comm". Offsets are those of the 648-byte 64-bit
# struct kinfo_proc: p_starttime at 0, p_pid at 40, p_comm at 243, and e_ppid
# at 560. Exit 1 when no such process exists, 2
# when the record cannot be read or does not have the expected shape.
# shellcheck disable=SC2016 # Perl source: its $ variables are Perl's, not the shell's.
_FM_PROC_KINFO_PL='
my $pid = shift;
my $mib = pack("i4", 1, 14, 1, $pid);
my $buf = "\0" x 1024;
my $len = pack("Q", length $buf);
syscall(202, $mib, 4, $buf, $len, 0, 0) == 0 or exit 2;
my $n = unpack("Q", $len);
exit 1 if $n == 0;
exit 2 unless $n == 648 && unpack("i", substr($buf, 40, 4)) == $pid;
my ($sec, $usec) = unpack("q q", substr($buf, 0, 16));
my $comm = unpack("Z17", substr($buf, 243, 17));
my $ppid = unpack("i", substr($buf, 560, 4));
printf("%d %d %06d %s\n", $ppid, $sec, $usec, $comm);
'

# fm_proc_read <pid>
# Read pid's kernel process record without ps or signals. Returns 0 and sets
# FM_PROC_PPID, FM_PROC_START (seconds.microseconds
# on Darwin, clock ticks since boot on /proc) and FM_PROC_COMM; returns 1 when
# the process provably does not exist; returns 2 when the record cannot be read.
FM_PROC_PPID='' FM_PROC_START='' FM_PROC_COMM=''
fm_proc_read() {
  local pid=$1 proc_root line rest comm
  local -a fields
  FM_PROC_PPID='' FM_PROC_START='' FM_PROC_COMM=''
  case "$pid" in ''|*[!0-9]*|0) return 2 ;; esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/self/stat" ] || [ -r "$proc_root/$pid/stat" ]; then
    [ -e "$proc_root/$pid" ] || return 1
    line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    rest=${line##*)}
    comm=${line#*(}
    comm=${comm%)*}
    read -r -a fields <<< "$rest"
    [ "${#fields[@]}" -ge 20 ] || return 2
    FM_PROC_PPID=${fields[1]}
    FM_PROC_START=${fields[19]}
    FM_PROC_COMM=$comm
    return 0
  fi
  [ "$_FM_UNAME" = Darwin ] || return 2
  command -v perl >/dev/null 2>&1 || return 2
  local rc=0 ppid sec usec
  line=$(perl -e "$_FM_PROC_KINFO_PL" "$pid" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  read -r ppid sec usec comm <<< "$line"
  case "$ppid" in ''|*[!0-9]*) return 2 ;; esac
  case "$sec$usec" in ''|*[!0-9]*) return 2 ;; esac
  FM_PROC_PPID=$ppid
  FM_PROC_START="$sec.$usec"
  FM_PROC_COMM=$comm
  return 0
}

# fm_proc_ps_runs
# True when ps can run in this process. ps that cannot execute at all exits 126
# (the sandbox refuses the exec) or 127 (absent); any other outcome, including
# a nonzero status for a missing pid, means ps runs. Probed once against this
# shell's own pid and cached for the life of the shell; fm_proc_field records
# the same verdict when one of its own ps calls cannot execute.
FM_PROC_PS_RUNS=
fm_proc_ps_runs() {
  local rc=0
  if [ -z "$FM_PROC_PS_RUNS" ]; then
    ps -o pid= -p "$$" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      126|127) FM_PROC_PS_RUNS=0 ;;
      *) FM_PROC_PS_RUNS=1 ;;
    esac
  fi
  [ "$FM_PROC_PS_RUNS" = 1 ]
}

# fm_proc_field <comm|args|ppid> <pid>
# Print one field for pid exactly as `ps -o <field>= -p <pid>` prints it, with
# ps's exit status, wherever ps runs. Where ps cannot execute the kernel record
# answers instead: comm is the kernel command name (at most 16 bytes) and ppid
# is a bare number. args, which the kernel record does not carry, prints
# nothing and is not looked up. Returns 1 when the process does not exist or
# its record cannot be read. A caller that walks many pids through command
# substitutions calls fm_proc_ps_runs first, so each subshell inherits the
# verdict instead of probing ps again.
fm_proc_field() {  # <field> <pid>
  local field=$1 pid=$2 out rc=0
  if [ "$FM_PROC_PS_RUNS" != 0 ]; then
    out=$(ps -o "$field=" -p "$pid" 2>/dev/null) || rc=$?
    case "$rc" in
      126|127) FM_PROC_PS_RUNS=0 ;;
      *)
        [ -z "$out" ] || printf '%s\n' "$out"
        return "$rc"
        ;;
    esac
  fi
  [ "$field" != args ] || return 0
  fm_proc_read "$pid" || return 1
  case "$field" in
    comm) printf '%s\n' "$FM_PROC_COMM" ;;
    ppid) printf '%s\n' "$FM_PROC_PPID" ;;
    *) return 1 ;;
  esac
}

# fm_proc_start_epoch <pid>
# Print the whole second, in epoch time, at which pid started, from its kernel
# record. On /proc the start is boot time plus clock ticks, both rounded down,
# so the printed second is never later than the true start. Returns 1 when the
# record or the boot time cannot be read.
fm_proc_start_epoch() {
  local pid=$1 proc_root btime hz
  fm_proc_read "$pid" || return 1
  case "$FM_PROC_START" in
    *.*)
      printf '%s\n' "${FM_PROC_START%%.*}"
      return 0
      ;;
  esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  btime=$(sed -n 's/^btime //p' "$proc_root/stat" 2>/dev/null)
  hz=$(getconf CLK_TCK 2>/dev/null)
  case "$btime" in ''|*[!0-9]*) return 1 ;; esac
  case "$hz" in ''|*[!0-9]*|0) return 1 ;; esac
  case "$FM_PROC_START" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((btime + FM_PROC_START / hz))"
}

# fm_pid_alive <pid>
# True when pid names an existing process. A successful kill -0 is alive and,
# where ps runs, a refused one is dead, exactly as before this library existed.
# Where ps cannot run, a refused signal is the sandbox's EPERM rather than proof
# of death, so the kernel record decides; an unreadable record stays dead.
fm_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null && return 0
  fm_proc_ps_runs && return 1
  fm_proc_read "$pid"
}

# fm_pid_identity <pid>
# Print a stable identity for a live pid that changes when the pid is reused:
# start time plus command. Returns 1 when the pid has no identity to read.
fm_pid_identity() {
  local pid=$1 out proc_root stat_line starttime cmdline_hex identity_key rc=0
  local -a stat_fields
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  # Prefer a Linux-compatible /proc when present: stat field 22 (starttime, clock ticks since boot) is
  # immune to the wall-clock steps that re-render the ps lstart fallback's date
  # (observed as WSL2 btime drift) and would evict a live watcher; combining the
  # full NUL-separated cmdline keeps PID reuse a mismatch even on a tick collision.
  # Git Bash/MSYS exposes these compatible files but its Cygwin ps rejects the
  # portable fallback's -o fields, so capability detection must not key on uname.
  if [ -r "$proc_root/$pid/stat" ] && [ -r "$proc_root/$pid/cmdline" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    # After the final comm delimiter, array index 19 is proc stat field 22.
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in
      ''|*[!0-9]*) return 1 ;;
    esac
    cmdline_hex=$(od -An -v -tx1 "$proc_root/$pid/cmdline" 2>/dev/null | tr -d '[:space:]') || return 1
    [ -n "$cmdline_hex" ] || return 1
    identity_key=proc-starttime
    [ "$_FM_UNAME" != Linux ] || identity_key=linux-starttime
    printf '%s=%s cmdline-hex=%s\n' "$identity_key" "$starttime" "$cmdline_hex"
    return 0
  fi
  # Darwin has no /proc. The kernel record's microsecond start time plus its
  # command name is readable both inside the Codex sandbox, where ps cannot
  # run, and outside it, so an identity a sandboxed watcher records matches the
  # one an unsandboxed hook computes for the same process.
  if [ "$_FM_UNAME" = Darwin ]; then
    fm_proc_read "$pid" || rc=$?
    case "$rc" in
      0)
        printf 'darwin-kinfo-start=%s comm-hex=%s\n' "$FM_PROC_START" \
          "$(printf '%s' "$FM_PROC_COMM" | od -An -v -tx1 | tr -d '[:space:]')"
        return 0
        ;;
      1) return 1 ;;
    esac
  fi
  # Elsewhere, or when the kernel record is unreadable, ps answers.
  # Pin LC_ALL=C so lstart's date format is locale-invariant: the identity is
  # written under one locale but re-read under the machine's ambient locale, which
  # would otherwise mismatch on a non-C locale (e.g. ko_KR) and reject a live watcher.
  # Pin COLUMNS wide so the command column is never cut to the ambient terminal
  # width: the identity is written from a wide shell but re-read inside a
  # narrow-COLUMNS hook, where a truncated command would likewise reject a live
  # watcher (issue #799). This mirrors fm_pending_reply_pid_identity, which pins the
  # same width for the same reason.
  out=$(COLUMNS=10000 LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}
