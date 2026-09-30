#!/usr/bin/env bash
# fm-worker-park.sh - park idle ship and scout workers, and unpark them when
# their next step needs them.
#
# Usage: fm-worker-park.sh scan
#        fm-worker-park.sh unpark <task-id> --reason <text>
#        fm-worker-park.sh status <task-id>
#
# Why: an idle worker agent still holds memory. A worker that has finished
# (scout report written, PR ready and only awaiting merge), declared a
# `paused:` wait, or is waiting on a decision (needs-decision, blocked, or a
# captain-held transfer) needs no running agent until something changes.
# Parking stops that agent through the control plane and keeps everything else;
# unparking relaunches it from its instructions and inbox.
# bin/fm-worker-park-lib.sh owns the durable records; this script owns policy.
#
# scan (the watcher starts it detached on its own cadence; safe to run by hand)
#   For each ordinary ship or scout task in THIS home - never a secondmate,
#   never a remote placement, only the tmux and herdr backends whose control
#   plane can prove a stop, never a task under a supervision lease:
#   - A parked worker is unparked when its steering inbox holds an unread
#     record, when the `until <UTC>` time of the wait it was parked on has
#     passed, or when its GitHub PR (read at most every FM_WORKER_PARK_PR_SECS)
#     newly shows a failed check, a changes-requested review, a merge
#     conflict, or more reviews and comments than at its first read after
#     parking. A merged or closed PR leaves it parked for cleanup.
#   - Any other worker is parked when parking is on, its inbox is empty, and
#     fm-crew-state.sh has reported it waiting with an unchanged signature
#     (state, source, status-log size, unread count) for the grace period.
#     Waiting is: done; paused; blocked or needs-decision from the status log
#     (never a no-mistakes run parked at a gate, which the worker must attend);
#     or an idle captain-held transfer. Only tasks whose status declaration is
#     already one of those verbs are read at all, forge reads are skipped, and
#     each scan does at most FM_WORKER_PARK_MAX_READS state or PR reads and
#     FM_WORKER_PARK_MAX_ACTIONS park or unpark actions, resuming from a
#     rotating cursor so no task starves.
#   Parking writes the marker first, then runs `fm-control.sh <id> exit
#   --idle-only`, which refuses rather than interrupt a worker that turned busy;
#   a refusal removes the marker again.
#
# unpark: relaunches a parked worker through `fm-control.sh <id> relaunch
#   --note <why>`, then retires the park records. A task that is not parked is
#   a successful no-op. bin/fm-send.sh starts this detached for a steer to a
#   parked worker; scan is the backstop.
#
# Refusals: any control-plane refusal leaves the worker as it was, is logged
#   once to state/worker-park.log, and the same action is not retried by scan
#   for FM_WORKER_PARK_RETRY_SECS. An explicit unpark always tries. A refused
#   unpark hands the unread steer back to the watcher's ordinary escalation.
#
# Teardown and discard are never done here. Exit 0 on success or a no-op;
# 1 on a refused unpark or an unusable home; 2 on a usage error.
#
# Environment (seconds unless noted):
#   FM_WORKER_PARK_GRACE_SECS     grace override (config/worker-park, default 600)
#   FM_WORKER_PARK_MAX_READS      state and PR reads per scan (6)
#   FM_WORKER_PARK_MAX_ACTIONS    park and unpark actions per scan (2)
#   FM_WORKER_PARK_PR_SECS        per-task PR read spacing while parked (300)
#   FM_WORKER_PARK_RETRY_SECS     backoff after a refusal (1800)
#   FM_WORKER_PARK_CONTROL_BIN    lifecycle owner (bin/fm-control.sh; tests stub)
#   FM_CREW_STATE_BIN             current-state reader (bin/fm-crew-state.sh)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  scan|unpark|status) ;;
  *) usage >&2; exit 2 ;;
esac

if [ -z "${FM_HOME:-}" ] || [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME must name this firstmate home explicitly" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 1; }

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-worker-park-lib.sh
. "$SCRIPT_DIR/fm-worker-park-lib.sh"

CONTROL=${FM_WORKER_PARK_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}
CREW_STATE=${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}
LOG="$STATE/worker-park.log"

num() {  # <value> <default>
  case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
MAX_READS=$(num "${FM_WORKER_PARK_MAX_READS:-}" 6)
MAX_ACTIONS=$(num "${FM_WORKER_PARK_MAX_ACTIONS:-}" 2)
PR_SECS=$(num "${FM_WORKER_PARK_PR_SECS:-}" 300)
RETRY_SECS=$(num "${FM_WORKER_PARK_RETRY_SECS:-}" 1800)
NOW=$(date +%s)
SEP=' · '

log() {  # <id> <event> <detail>
  printf '%s %s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$LOG" 2>/dev/null || true
}

one_line() {  # <text> -> the text on one bounded line
  printf '%s' "$1" | tr '\n\t' '  ' | cut -c1-300
}

meta() {  # <id> <key>
  fm_worker_park_kv "$STATE/$1.meta" "$2"
}

unread_count() {  # <id>
  local n=0 f
  for f in "$STATE/$1.inbox"/*.msg; do
    [ -e "$f" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# 0 when this home may park or unpark <id> at all.
parkable_task() {  # <id>
  local id=$1 kind backend
  kind=$(meta "$id" kind)
  case "${kind:-ship}" in ship|scout) ;; *) return 1 ;; esac
  [ -z "$(meta "$id" remote_host)" ] || return 1
  backend=$(meta "$id" backend)
  case "${backend:-tmux}" in tmux|herdr) ;; *) return 1 ;; esac
  [ -d "$(meta "$id" worktree)" ] || return 1
  [ ! -e "$STATE/.lease-$id" ]
}

# 0 when a refusal of <action> for <id> is still inside its backoff.
refusal_backing_off() {  # <id> <action>
  local f="$STATE/$1.worker-park-refused" action at
  [ -f "$f" ] || return 1
  IFS=$'\t' read -r action at _ < "$f" 2>/dev/null || return 1
  [ "$action" = "$2" ] || return 1
  [ $((NOW - $(num "$at" 0))) -lt "$RETRY_SECS" ]
}

# Record a refusal, logging it only when it differs from the recorded one.
record_refusal() {  # <id> <action> <text>
  local f="$STATE/$1.worker-park-refused" text prev_action prev_text
  text=$(one_line "$3")
  if [ -f "$f" ]; then
    IFS=$'\t' read -r prev_action _ prev_text < "$f" 2>/dev/null || true
    [ "$prev_action" = "$2" ] && [ "$prev_text" = "$text" ] \
      || log "$1" "$2-refused" "$text"
  else
    log "$1" "$2-refused" "$text"
  fi
  printf '%s\t%s\t%s\n' "$2" "$NOW" "$text" > "$f"
}

retire_records() {  # <id>
  rm -f "$(fm_worker_park_marker "$STATE" "$1")" "$STATE/$1.worker-park-watch" \
    "$STATE/$1.worker-park-refused" "$STATE/$1.worker-park-pr"
}

# The PR a parked worker is waiting on: the record's pr=, else the first PR URL
# in its status log.
task_pr() {  # <id>
  local pr
  pr=$(meta "$1" pr)
  [ -n "$pr" ] || pr=$(grep -Eo 'https://[^[:space:])"]+/pull/[0-9]+' "$STATE/$1.status" 2>/dev/null | head -1)
  printf '%s' "$pr"
}

# --- waiting-state classification -------------------------------------------

# Prints the crew-state line when <id> is waiting, else fails. Counts one read.
waiting_crew_line() {  # <id> <resolved-status-line>
  local id=$1 line=$2 crew state source
  crew=$(FM_HOME="$FM_HOME" FM_CREW_STATE_NO_FORGE=1 "$CREW_STATE" "$id" 2>/dev/null) || return 1
  crew=$(printf '%s\n' "$crew" | tail -1)
  state=${crew#state: }
  state=${state%%"$SEP"*}
  source=${crew#*"$SEP"source: }
  source=${source%%"$SEP"*}
  case "$state:$source" in
    done:*|paused:*|blocked:status-log|parked:status-log) ;;
    unknown:none)
      # A captain-held transfer has no crew-state word of its own: it reads
      # unknown only after the pane was proven idle and no run was attributed.
      status_is_captain_held "$line" || return 1
      case "$crew" in *"no current-state source available"*) ;; *) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  printf '%s' "$crew"
}

# --- park and unpark --------------------------------------------------------

park() {  # <id> <crew-line> <resolved-status-line>
  local id=$1 crew=$2 line=$3 marker state until out rc
  marker=$(fm_worker_park_marker "$STATE" "$id")
  state=${crew#state: }
  state=${state%%"$SEP"*}
  until=$(status_paused_until "$line" 2>/dev/null || true)
  {
    echo "schema=fm-worker-park.v1"
    echo "spawn_gen=$(meta "$id" spawn_gen)"
    echo "parked_at=$NOW"
    echo "state=$state"
    [ -z "$until" ] || echo "until=$until"
    echo "pr=$(task_pr "$id")"
    echo "crew=$(one_line "$crew")"
  } > "$marker.tmp" || { rm -f "$marker.tmp"; return 1; }
  mv -f "$marker.tmp" "$marker" || { rm -f "$marker.tmp"; return 1; }
  rc=0
  out=$(FM_HOME="$FM_HOME" "$CONTROL" "$id" exit --idle-only 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$marker"
    record_refusal "$id" park "$out"
    return 1
  fi
  rm -f "$STATE/$id.worker-park-watch" "$STATE/$id.worker-park-refused" "$STATE/$id.worker-park-pr"
  log "$id" parked "$state ($(one_line "$out"))"
}

unpark() {  # <id> <reason>
  local id=$1 reason=$2 lock note out rc state at
  fm_worker_park_valid "$STATE" "$id" || return 0
  lock="$STATE/.worker-park-$id.lock"
  fm_lock_try_acquire "$lock" || { echo "unpark of $id already in progress"; return 0; }
  if ! fm_worker_park_valid "$STATE" "$id"; then
    fm_lock_release "$lock" || true
    return 0
  fi
  state=$(fm_worker_park_field "$STATE" "$id" state)
  at=$(fm_worker_park_field "$STATE" "$id" parked_at)
  note="Firstmate parked this worker (stopped its agent while the task waited in state '$state') at $(date -u -r "$at" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$at" +%Y-%m-%dT%H:%MZ 2>/dev/null || printf 'epoch %s' "$at") and relaunched it because: $reason. Nothing in the local copy changed while it was parked. Read your inbox as instructed above and any handoff you keep, then continue the task from its current state."
  rc=0
  out=$(FM_HOME="$FM_HOME" "$CONTROL" "$id" relaunch --note "$note" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    record_refusal "$id" unpark "$out"
    fm_lock_release "$lock" || true
    echo "unpark of $id refused: $(one_line "$out")" >&2
    return 1
  fi
  retire_records "$id"
  log "$id" unparked "$reason"
  fm_lock_release "$lock" || true
  echo "unparked $id: $reason"
}

# --- PR trigger -------------------------------------------------------------

# Prints the unpark reason when the parked worker's PR newly needs it. Counts one
# read when a read is due.
pr_reason() {  # <id>
  local id=$1 url f json now_flags red changes conflict activity open
  local b_red b_changes b_conflict b_activity
  url=$(fm_worker_park_field "$STATE" "$id" pr)
  case "$url" in https://github.com/*/pull/[0-9]*) ;; *) return 1 ;; esac
  f="$STATE/$id.worker-park-pr"
  if [ -f "$f" ]; then
    [ $((NOW - $(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0))) -ge "$PR_SECS" ] || return 1
  fi
  READS=$((READS + 1))
  json=$(fm_run_timed 20 gh pr view "$url" --json state,mergeable,reviewDecision,statusCheckRollup,reviews,comments 2>/dev/null) || return 1
  now_flags=$(printf '%s' "$json" | jq -r '
    [ (if .state == "OPEN" then 1 else 0 end),
      (if ([.statusCheckRollup[]? | (.conclusion // "") , (.state // "")]
           | any(. == "FAILURE" or . == "TIMED_OUT" or . == "CANCELLED" or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE" or . == "ERROR")) then 1 else 0 end),
      (if .reviewDecision == "CHANGES_REQUESTED" then 1 else 0 end),
      (if .mergeable == "CONFLICTING" then 1 else 0 end),
      ((.reviews | length) + (.comments | length)) ] | @tsv' 2>/dev/null) || return 1
  IFS=$'\t' read -r open red changes conflict activity <<< "$now_flags"
  [ -n "${activity:-}" ] || return 1
  if [ ! -f "$f" ]; then
    printf '%s %s %s %s\n' "$red" "$changes" "$conflict" "$activity" > "$f"
    return 1
  fi
  read -r b_red b_changes b_conflict b_activity < "$f" || true
  printf '%s %s %s %s\n' "$red" "$changes" "$conflict" "$activity" > "$f"
  [ "$open" = 1 ] || return 1
  if [ "$red" = 1 ] && [ "${b_red:-0}" != 1 ]; then printf 'its PR %s has a failed check' "$url"; return 0; fi
  if [ "$changes" = 1 ] && [ "${b_changes:-0}" != 1 ]; then printf 'its PR %s has a changes-requested review' "$url"; return 0; fi
  if [ "$conflict" = 1 ] && [ "${b_conflict:-0}" != 1 ]; then printf 'its PR %s has a merge conflict' "$url"; return 0; fi
  if [ "$activity" -gt "$(num "${b_activity:-}" 0)" ]; then printf 'its PR %s has new reviews or comments' "$url"; return 0; fi
  return 1
}

# --- scan -------------------------------------------------------------------

READS=0
ACTIONS=0

scan_parked() {  # <id>
  local id=$1 reason='' until
  if [ "$(unread_count "$id")" -gt 0 ]; then
    reason="a firstmate instruction is waiting in its inbox"
  else
    until=$(fm_worker_park_field "$STATE" "$id" until)
    if [ -n "$until" ] && [ "$NOW" -ge "$(num "$until" 0)" ]; then
      reason="the time its declared wait named has passed"
    elif [ "$READS" -lt "$MAX_READS" ]; then
      reason=$(pr_reason "$id") || reason=
    fi
  fi
  [ -n "$reason" ] || return 0
  refusal_backing_off "$id" unpark && return 0
  [ "$ACTIONS" -lt "$MAX_ACTIONS" ] || return 0
  ACTIONS=$((ACTIONS + 1))
  unpark "$id" "$reason" >/dev/null 2>&1 || true
}

scan_idle() {  # <id> <grace>
  local id=$1 grace=$2 line verb crew sig size first prev
  if [ "$(unread_count "$id")" -gt 0 ]; then
    rm -f "$STATE/$id.worker-park-watch"
    return 0
  fi
  line=$(status_current_line "$STATE/$id.status" "$(meta "$id" kind)" 2>/dev/null)
  verb=$(status_line_verb "$line")
  if ! status_is_paused_or_captain_held "$line"; then
    case "$verb" in
      done|needs-decision|blocked) ;;
      *) rm -f "$STATE/$id.worker-park-watch"; return 0 ;;
    esac
  fi
  [ "$READS" -lt "$MAX_READS" ] || return 2
  READS=$((READS + 1))
  if ! crew=$(waiting_crew_line "$id" "$line"); then
    rm -f "$STATE/$id.worker-park-watch"
    return 0
  fi
  size=$(wc -c < "$STATE/$id.status" 2>/dev/null | tr -d ' ')
  sig="${crew%%"$SEP"source*}|${crew#*"$SEP"source: }|$size"
  sig=$(one_line "$sig")
  first=
  if [ -f "$STATE/$id.worker-park-watch" ]; then
    IFS=$'\t' read -r first prev < "$STATE/$id.worker-park-watch" || true
  fi
  if [ -z "$first" ] || [ "${prev:-}" != "$sig" ]; then
    printf '%s\t%s\n' "$NOW" "$sig" > "$STATE/$id.worker-park-watch"
    return 0
  fi
  [ $((NOW - $(num "$first" "$NOW"))) -ge "$grace" ] || return 0
  refusal_backing_off "$id" park && return 0
  [ "$ACTIONS" -lt "$MAX_ACTIONS" ] || return 2
  # Re-read the inbox immediately before acting: a steer may have just landed.
  [ "$(unread_count "$id")" -eq 0 ] || return 0
  ACTIONS=$((ACTIONS + 1))
  park "$id" "$crew" "$line" || true
}

scan() {
  local cfg enabled=0 grace=0 lock ids=() id meta start=0 i n cursor rc
  cfg=$(fm_worker_park_config "$CONFIG")
  case "$cfg" in
    on\ *) enabled=1; grace=${cfg#on } ;;
    invalid\ *)
      if [ "$(cat "$STATE/.worker-park-config-invalid" 2>/dev/null)" != "$cfg" ]; then
        printf '%s\n' "$cfg" > "$STATE/.worker-park-config-invalid"
        log home config-invalid "${cfg#invalid } (parking is off until config/worker-park reads off, a number of seconds, or is removed)"
        echo "warning: config/worker-park is not 'off' or a number of seconds; parking is off" >&2
      fi
      ;;
  esac
  lock="$STATE/.worker-park-scan.lock"
  fm_lock_try_acquire "$lock" || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    ids+=("$(basename "$meta" .meta)")
  done
  n=${#ids[@]}
  cursor=$(cat "$STATE/.worker-park-cursor" 2>/dev/null || true)
  for ((i = 0; i < n; i++)); do
    if [ "${ids[i]}" = "$cursor" ]; then start=$(((i + 1) % n)); break; fi
  done
  for ((i = 0; i < n; i++)); do
    id=${ids[(start + i) % n]}
    parkable_task "$id" || continue
    rc=0
    if fm_worker_park_valid "$STATE" "$id"; then
      scan_parked "$id"
    else
      [ ! -e "$(fm_worker_park_marker "$STATE" "$id")" ] || retire_records "$id"
      [ "$enabled" = 1 ] || { rm -f "$STATE/$id.worker-park-watch"; continue; }
      scan_idle "$id" "$grace" || rc=$?
    fi
    printf '%s\n' "$id" > "$STATE/.worker-park-cursor"
    # A spent budget ends the scan; the cursor resumes after the last task seen.
    [ "$rc" -ne 2 ] || break
  done
  fm_lock_release "$lock" || true
}

case "$1" in
  scan)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    scan
    ;;
  unpark)
    [ "$#" -eq 4 ] && [ "$3" = --reason ] && [ -n "$4" ] || { usage >&2; exit 2; }
    [ -f "$STATE/$2.meta" ] || { echo "error: no task '$2' in $STATE" >&2; exit 1; }
    unpark "$2" "$4"
    ;;
  status)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    if fm_worker_park_valid "$STATE" "$2"; then
      echo "parked: $(fm_worker_park_describe "$STATE" "$2")"
    else
      echo "not parked"
    fi
    ;;
esac
