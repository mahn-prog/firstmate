#!/usr/bin/env bash
# fm-worker-park-lib.sh - the worker-park record contract (one owner).
#
# A PARKED WORKER is an ordinary ship or scout task whose agent process was
# stopped by the control plane while the task waits, with its endpoint, local
# copy, branch, inbox, and instructions preserved. bin/fm-worker-park.sh owns
# when a worker is parked and unparked; this library owns only the durable
# records every other reader consults, so none of them restates the format:
#
#   state/<id>.worker-park          the park marker (key=value lines):
#     schema=fm-worker-park.v1
#     spawn_gen=<the task record's spawn_gen when parked>
#     parked_at=<epoch>
#     state=<fm-crew-state.sh state word when parked>
#     until=<epoch>                 optional: the declared wait's own time
#     pr=<url>                      optional: the task's PR when parked
#     crew=<the full fm-crew-state.sh line when parked>
#   state/<id>.worker-park-watch    "<first-seen-epoch>\t<signature>" grace clock
#   state/<id>.worker-park-refused  "<action>\t<epoch>\t<refusal text>"
#   state/<id>.worker-park-pr       "<red> <changes> <conflict> <activity>" baseline
#   state/worker-park.log           append-only "<UTC> <id> <event>: <detail>"
#
# A marker is VALID only while its spawn_gen equals the task record's current
# spawn_gen, so any relaunch - through the unpark path or by hand - retires it
# without a write. "Parked" here never means a no-mistakes run parked at a gate;
# fm-crew-state.sh keeps that meaning for its `state: parked`.
#
# Readers: bin/fm-watch.sh (stale, wedge, turn-end, and steering-inbox paths
# skip a parked task), bin/fm-send.sh (a steer to a parked task starts the
# unpark), bin/fm-crew-state.sh (a parked task reads its declared state, not
# unknown), bin/fm-session-start.sh (prints `endpoint: parked`), and
# bin/fm-teardown.sh (removes every record above except the shared log).
#
# Config (docs/configuration.md "Worker parking" owns the user contract):
# config/worker-park absent means on with the default grace; a first line
# `off` disables parking; a first line of digits sets the grace in seconds.
# FM_WORKER_PARK_GRACE_SECS overrides the grace. Anything else reads invalid,
# which disables parking and is reported by the scan.
#
# Dependency-free and side-effect free on source; set -u safe.

FM_WORKER_PARK_DEFAULT_GRACE_SECS=600

fm_worker_park_marker() {  # <state-dir> <id>
  printf '%s/%s.worker-park' "$1" "$2"
}

# The last value of <key>= in <file>, or empty.
fm_worker_park_kv() {  # <file> <key>
  local file=$1 key=$2 line value=''
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) value=${line#*=} ;;
    esac
  done < "$file" 2>/dev/null || true
  printf '%s' "$value"
}

fm_worker_park_field() {  # <state-dir> <id> <key>
  fm_worker_park_kv "$(fm_worker_park_marker "$1" "$2")" "$3"
}

# 0 when <id> has a park marker bound to its current task record.
fm_worker_park_valid() {  # <state-dir> <id>
  local marker meta
  marker=$(fm_worker_park_marker "$1" "$2")
  meta="$1/$2.meta"
  [ -f "$marker" ] && [ -f "$meta" ] || return 1
  [ "$(fm_worker_park_kv "$marker" schema)" = fm-worker-park.v1 ] || return 1
  [ "$(fm_worker_park_kv "$marker" spawn_gen)" = "$(fm_worker_park_kv "$meta" spawn_gen)" ]
}

# 0 when the last recorded refusal for <id> was an unpark, so its unread steer
# must go back to the ordinary escalation path instead of waiting on unpark.
fm_worker_park_unpark_refused() {  # <state-dir> <id>
  local f="$1/$2.worker-park-refused" action
  [ -f "$f" ] || return 1
  IFS=$'\t' read -r action _ < "$f" 2>/dev/null || return 1
  [ "$action" = unpark ]
}

# Prints "on <grace-secs>", "off", or "invalid <first-line>".
fm_worker_park_config() {  # <config-dir>
  local file="$1/worker-park" first='' grace
  if [ -f "$file" ]; then
    IFS= read -r first < "$file" 2>/dev/null || true
    first=${first%%#*}
    first=$(printf '%s' "$first" | tr -d '[:space:]')
  fi
  case "$first" in
    off) printf 'off\n'; return 0 ;;
    '') grace=$FM_WORKER_PARK_DEFAULT_GRACE_SECS ;;
    *[!0-9]*) printf 'invalid %s\n' "$first"; return 0 ;;
    *) grace=$first ;;
  esac
  case "${FM_WORKER_PARK_GRACE_SECS:-}" in
    '') ;;
    *[!0-9]*) printf 'invalid FM_WORKER_PARK_GRACE_SECS=%s\n' "$FM_WORKER_PARK_GRACE_SECS"; return 0 ;;
    *) grace=$FM_WORKER_PARK_GRACE_SECS ;;
  esac
  printf 'on %s\n' "$grace"
}

# Human line for readers that report a parked task.
fm_worker_park_describe() {  # <state-dir> <id>
  local at when
  at=$(fm_worker_park_field "$1" "$2" parked_at)
  when=$(date -u -r "$at" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$at" +%Y-%m-%dT%H:%MZ 2>/dev/null || printf '%s' "$at")
  printf 'worker parked since %s (agent stopped while idle; relaunched on a steer, PR activity, or its declared wait time)' "$when"
}
