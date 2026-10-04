#!/usr/bin/env bash
# fm-host-switch.sh - move the whole fleet onto one host (claude or codex) in
# one step, from a saved host profile.
#
# Usage: fm-host-switch.sh <host> [--dry-run]
#        fm-host-switch.sh save <host>
#        fm-host-switch.sh check [--session-host <host>]
#        fm-host-switch.sh verify
#
# Why: a fleet runs on one host at a time - the secondmates, the workers and the
# no-mistakes reviewer all follow the host the captain opened the session on.
# Switching used to be five hand edits plus a relaunch of every agent, and a
# validation run keeps the pipeline agent it started with, so a run started
# before a switch was stranded unless someone continued it on the new host.
#
# Host profile: config/host-profiles/<host>/ (FM_HOST_PROFILES_DIR overrides
# the directory), one file per setting:
#   secondmate-harness  the secondmate pin line ("<harness> [<model>] [<effort>]")
#   crew-harness        the crew harness (a bare adapter name, equal to <host>)
#   crew-dispatch.json  the dispatch profiles
#   no-mistakes-agent   the reviewer's `agent:` value
#   no-mistakes-args    optional; that agent's agent_args_override list, one
#                       argument per line
#   worker-tiers        optional; "<strong|standard|light> <harness> <model> <effort>"
#                       lines that keep a worker's reasoning class across hosts
# config/host-profile names the fleet host last applied. It and
# config/host-worker-tiers (every profile's host on a line of its own, then its
# tiers prefixed by host) are inherited by secondmate homes; the profile
# directory is primary-only.
#
# <host> [--dry-run]
#   Primary home (fleet scope), in this order:
#   1. Validate the profile; refuse before any change when it is incomplete or
#      the reviewer config's structure is not recognized.
#   2. Inventory every ship and scout task in this home whose harness is
#      another host (a saved profile's name; a worker a dispatch rule sent to
#      some other harness is left alone): endpoint state, park state and its
#      validation run (`no-mistakes axi status` in its worktree).
#   3. Write the profile into config/ and the reviewer config
#      (${NM_HOME:-~/.no-mistakes}/config.yaml): only the top-level `agent:`
#      line and the `agent_args_override.<agent>` list change. A failed config
#      write restores the config files it already replaced and stops before
#      relaunching anything.
#   4. Push inherited config to live secondmate homes (fm-config-push.sh).
#   5. Relaunch each local secondmate not yet on the new pin (fm-control.sh
#      relaunch) and, once it is on the pin, steer it to run this command in
#      its own home; every run steers again, so a steer that failed is retried
#      by rerunning the switch. A remote secondmate is listed for manual
#      follow-up.
#   6. Relaunch each worker on the same tier of the new host. An alive worker
#      goes through fm-control.sh relaunch, a parked one through
#      fm-worker-park.sh unpark, a stopped unparked one is only reported, and
#      one already on the host is left alone.
#   A secondmate home (home scope) runs only step 2 and step 6 for its own
#   workers, and only for the fleet host its inherited config/host-profile
#   names; the fleet settings belong to the primary.
#   Validation runs are never aborted, forced or rewritten. Firstmate does not
#   write to project worktrees, so each worker's relaunch note carries its own
#   continuation: an active run stays on the agent it started with and the
#   worker keeps driving it; a failed or cancelled run is continued on the new
#   host by running the exact branch_sync.next_action command `axi status`
#   names (a sync or custody recovery), if any, and then `no-mistakes rerun`.
#   A command that carries --keep-local would discard commits, so the note
#   tells the worker to raise a decision and stop instead. A run whose status
#   cannot be classified is reported as unreadable for the worker to check.
#   --dry-run prints the same plan and changes nothing.
#   Each applied switch writes state/host-switch/<stamp>/ with plan.txt,
#   actions.log and the previous config and reviewer config.
#   One switch runs at a time per home (state/.host-switch.lock).
#   Exit 0 when every action succeeded, 1 when any action failed (the rest
#   still ran), 2 on a usage error or a refusal before any change.
#
# save <host>
#   Capture this primary home's live config into the <host> profile. Refuses
#   unless the live crew harness and secondmate pin both name <host>. An
#   existing worker-tiers file is kept.
#
# check [--session-host <host>]
#   Read-only session-start notice, printed by bin/fm-bootstrap.sh. The fleet
#   host is config/host-profile, or before any switch in a home with a saved
#   profile the crew harness when it names a concrete adapter. Prints
#   HOST_PROFILE lines when this session's host (bin/fm-harness.sh unless
#   given) differs from the fleet host, or when recorded workers in this home
#   still run on another host; prints nothing otherwise, in a home with
#   neither a saved profile nor an applied switch, or when no fleet host is
#   known. It never switches anything.
#
# verify
#   Read-only: list secondmates, workers, the reviewer config and validation
#   runs still on another host. Exit 1 when anything is.
#
# Environment (tests stub the collaborators):
#   FM_HOME                        this home
#   FM_HOST_PROFILES_DIR           profile directory (default config/host-profiles)
#   NM_HOME                        no-mistakes home (default ~/.no-mistakes)
#   FM_HOST_SWITCH_CONTROL_BIN     lifecycle owner (bin/fm-control.sh)
#   FM_HOST_SWITCH_PARK_BIN        parked-worker owner (bin/fm-worker-park.sh)
#   FM_HOST_SWITCH_SEND_BIN        steer owner (bin/fm-send.sh)
#   FM_HOST_SWITCH_PUSH_BIN        inherited-config push (bin/fm-config-push.sh)
#   FM_HOST_SWITCH_HARNESS_BIN     session-host detection (bin/fm-harness.sh)
#   FM_HOST_SWITCH_AGENT_STATE_BIN endpoint classifier, called as `<bin> <id>`
#                                  (default: bin/fm-backend.sh's recovery-grade read)
#   FM_HOST_SWITCH_NM_TIMEOUT      seconds per `axi status` read (20)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROFILES="${FM_HOST_PROFILES_DIR:-$CONFIG/host-profiles}"
NM_CONFIG="${NM_HOME:-$HOME/.no-mistakes}/config.yaml"
CONTROL=${FM_HOST_SWITCH_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}
PARK=${FM_HOST_SWITCH_PARK_BIN:-$SCRIPT_DIR/fm-worker-park.sh}
SEND=${FM_HOST_SWITCH_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}
PUSH=${FM_HOST_SWITCH_PUSH_BIN:-$SCRIPT_DIR/fm-config-push.sh}
HARNESS=${FM_HOST_SWITCH_HARNESS_BIN:-$SCRIPT_DIR/fm-harness.sh}
AGENT_STATE_BIN=${FM_HOST_SWITCH_AGENT_STATE_BIN:-}
NM_TIMEOUT=${FM_HOST_SWITCH_NM_TIMEOUT:-20}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=20 ;; esac

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-worker-park-lib.sh
. "$SCRIPT_DIR/fm-worker-park-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

die() {  # <message>
  echo "error: $1" >&2
  exit 2
}

# First non-empty, non-comment line of <file>, trimmed; empty when absent.
first_line() {  # <file>
  local line
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in ''|'#'*) continue ;; esac
    printf '%s' "$line"
    return 0
  done < "$1"
}

word() {  # <n> <words...>
  local n=$1 w
  shift
  read -r -a w <<< "$*"
  printf '%s' "${w[$((n - 1))]:-}"
}

valid_host_name() {
  case "$1" in ''|*[!a-z0-9-]*) return 1 ;; esac
}

is_secondmate_home() {
  fm_root_is_secondmate_home "$FM_HOME"
}

# --- reviewer config --------------------------------------------------------

nm_agent() {  # <config-file>
  [ -f "$1" ] || return 0
  sed -n 's/^agent:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$1" | head -1
}

# The agent_args_override.<agent> list, one argument per line.
nm_args() {  # <config-file> <agent>
  [ -f "$1" ] || return 0
  awk -v agent="$2" '
    function indent(s) { match(s, /[^ ]/); return RSTART - 1 }
    /^[^[:space:]#]/ { in_block = ($0 ~ /^agent_args_override:[[:space:]]*$/); in_key = 0; next }
    !in_block { next }
    in_key && $0 ~ /^[ ]+- / && indent($0) > key_ind { s = $0; sub(/^[ ]+- /, "", s); print s; next }
    { in_key = 0 }
    $0 ~ ("^[ ]+" agent ":[[:space:]]*$") { in_key = 1; key_ind = indent($0) }
  ' "$1"
}

# Print <config-file> with the top-level agent set to <agent> and, when
# <args-file> is non-empty, that agent's agent_args_override list replaced.
# Exit 3 when the structure is not the one this edit understands.
nm_render() {  # <config-file> <agent> <args-file>
  awk -v agent="$2" -v argsfile="$3" '
    function indent(s) { match(s, /[^ ]/); return RSTART - 1 }
    function emit_args(ind,   i, pad) {
      pad = sprintf("%" ind "s", "")
      for (i = 1; i <= n; i++) print pad "- " args[i]
    }
    BEGIN {
      n = 0
      if (argsfile != "") while ((getline l < argsfile) > 0) if (l != "") args[++n] = l
    }
    /^[^[:space:]#]/ {
      if (in_block && n > 0 && !key_done) { print "  " agent ":"; emit_args(4); key_done = 1 }
      in_block = 0; in_key = 0
      if ($0 ~ /^agent:/) { print "agent: " agent; agent_lines++; next }
      if ($0 ~ /^agent_args_override:/) {
        if ($0 !~ /^agent_args_override:[[:space:]]*$/) bad = 1
        in_block = 1; block_seen = 1; print; next
      }
      print; next
    }
    in_block {
      if (in_key) {
        if ($0 ~ /^[ ]+- / && indent($0) > key_ind) next
        in_key = 0
      }
      if ($0 ~ ("^[ ]+" agent ":[[:space:]]*[^[:space:]#]")) bad = 1
      if (n > 0 && $0 ~ ("^[ ]+" agent ":[[:space:]]*$")) {
        print; key_ind = indent($0); emit_args(key_ind + 2); key_done = 1; in_key = 1; next
      }
    }
    { print }
    END {
      if (in_block && n > 0 && !key_done) { print "  " agent ":"; emit_args(4); key_done = 1 }
      if (!block_seen && n > 0) { print "agent_args_override:"; print "  " agent ":"; emit_args(4) }
      if (agent_lines != 1 || bad) exit 3
    }
  ' "$1"
}

# --- tiers ------------------------------------------------------------------

# Every saved profile's host as "<host>", then its tiers as
# "<host> <tier> <harness> <model> <effort>".
profile_tier_lines() {
  local d host
  for d in "$PROFILES"/*/; do
    [ -d "$d" ] || continue
    host=$(basename "$d")
    printf '%s\n' "$host"
    [ -f "$d/worker-tiers" ] || continue
    grep -v '^[[:space:]]*\(#\|$\)' "$d/worker-tiers" | sed "s/^[[:space:]]*/$host /"
  done
  return 0
}

# Every known tier: the saved profiles' in fleet scope, the inherited copy in
# home scope.
tier_lines() {
  if [ "$SCOPE" = fleet ]; then
    profile_tier_lines
  elif [ -f "$CONFIG/host-worker-tiers" ]; then
    grep -v '^[[:space:]]*\(#\|$\)' "$CONFIG/host-worker-tiers" || true
  fi
}

# 0 when <harness> names a host this home knows: a saved profile (primary) or
# the fleet host or a host the inherited host-worker-tiers names (secondmate
# home).
is_host() {  # <harness>
  [ -n "$1" ] || return 1
  if is_secondmate_home; then
    [ "$1" = "$(first_line "$CONFIG/host-profile")" ] && return 0
    [ -f "$CONFIG/host-worker-tiers" ] && awk -v h="$1" '$1 == h { f = 1 } END { exit !f }' "$CONFIG/host-worker-tiers"
  else
    [ -d "$PROFILES/$1" ]
  fi
}

tier_of() {  # <harness> <model> <effort>
  local t
  t=$(tier_lines | awk -v h="$1" -v m="$2" -v e="$3" '$3 == h && $4 == m && $5 == e { print $2; exit }')
  printf '%s' "${t:-standard}"
}

# "<harness> <model> <effort>" a worker of <tier> runs on <host>.
tier_target() {  # <tier> <host> <dispatch-json> <crew-harness>
  local t d
  t=$(tier_lines | awk -v host="$2" -v tier="$1" '$1 == host && $2 == tier { print $3, $4, $5; exit }')
  if [ -z "$t" ] && [ -f "$3" ] && command -v jq >/dev/null 2>&1; then
    d=$(jq -r '.default // empty | if type == "array" then .[0] else . end
      | "\(.harness // "") \(.model // "") \(.effort // "")"' "$3" 2>/dev/null || true)
    [ "$(word 1 "$d")" = "$4" ] && t=$d
  fi
  printf '%s' "${t:-$4}"
}

# --- inventory --------------------------------------------------------------

agent_state() {  # <id> <meta>
  if [ -n "$AGENT_STATE_BIN" ]; then
    "$AGENT_STATE_BIN" "$1" 2>/dev/null || printf 'unreadable'
    return 0
  fi
  local backend target
  backend=$(fm_backend_of_meta "$2")
  target=$(fm_backend_target_of_meta "$2")
  fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable'
}

# Sets RUN_CLASS (none|active|success|stopped|unreadable), RUN_ID, RUN_STATUS,
# RUN_NEXT, RUN_CMD and RUN_AGENT for the worktree's current-branch run.
inventory_run() {  # <worktree> <branch>
  local out rc=0
  RUN_CLASS=none RUN_ID='' RUN_STATUS='' RUN_NEXT='' RUN_CMD='' RUN_AGENT=''
  if [ ! -d "$1" ]; then RUN_CLASS=unreadable; return 0; fi
  out=$(fm_nm_run_bounded "$1" "$NM_TIMEOUT" axi status 2>/dev/null) || rc=$?
  RUN_ID=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  if [ -z "$RUN_ID" ]; then
    [ "$rc" -eq 0 ] || RUN_CLASS=unreadable
    return 0
  fi
  if [ -n "$2" ] && [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")" != "$2" ]; then
    RUN_ID=''
    return 0
  fi
  RUN_STATUS=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
  RUN_NEXT=$(fm_nm_branch_sync_nested "$out" next_action code)
  RUN_CMD=$(fm_nm_branch_sync_nested "$out" next_action command)
  RUN_AGENT=$(printf '%s\n' "$out" | sed -nE 's/.*[[:space:]"]([a-z][a-z0-9-]*) (producing output|started pid).*/\1/p' | head -1)
  if fm_nm_run_is_active "$out"; then
    RUN_CLASS=active
    fm_nm_run_is_parked "$out" && RUN_STATUS="$RUN_STATUS, parked at a gate"
  else
    case "$RUN_STATUS" in
      completed) RUN_CLASS=success ;;
      failed|cancelled) RUN_CLASS=stopped ;;
      *) RUN_CLASS=unreadable ;;
    esac
  fi
}

# The relaunch note for a worker whose run inventory is in RUN_*.
# shellcheck disable=SC2016 # backticks are literal command quotes in the note
continuation_note() {  # <host>
  local host=$1 base step
  base="Firstmate moved the whole fleet to the $host host and relaunched you on it; nothing in your local copy changed. Read your inbox and any handoff you keep, then continue the task from its current state."
  case "$RUN_CLASS" in
    none|success)
      printf '%s' "$base"
      ;;
    active)
      printf '%s Your validation run %s was %s at the switch and keeps the pipeline agent it started with; that is expected. Keep driving it with `no-mistakes axi status` and `no-mistakes axi respond`, and never abort it. If it later ends failed or cancelled, continue it on %s: follow branch_sync.next_action from `no-mistakes axi status` (`no-mistakes axi sync`, or the exact recovery command it names; if that command contains --keep-local, append needs-decision instead of running it), then run `no-mistakes rerun` and drive the new run.' \
        "$base" "$RUN_ID" "$RUN_STATUS" "$host"
      ;;
    stopped)
      case "$RUN_CMD" in
        *--keep-local*)
          printf '%s Your validation run %s ended %s before the switch, and its next step (`%s`) would discard commits. Do NOT run it and do not rerun: append needs-decision naming run %s and that command, and stop. Never abort, force, reset or discard anything.' \
            "$base" "$RUN_ID" "$RUN_STATUS" "$RUN_CMD" "$RUN_ID"
          return 0
          ;;
        '') step='it names no sync step' ;;
        *) step="run exactly \`$RUN_CMD\`" ;;
      esac
      printf '%s Your validation run %s ended %s before the switch. Continue it on %s now: run `no-mistakes axi status`; %s; then run `no-mistakes rerun` from the preserved branch head and drive the new run with `no-mistakes axi status` and `no-mistakes axi respond`. Never abort, force, reset or discard anything.' \
        "$base" "$RUN_ID" "$RUN_STATUS" "$host" "$step"
      ;;
    *)
      printf '%s Firstmate could not read your validation run at the switch: check `no-mistakes axi status`, and if a run ended failed or cancelled, continue it on %s by following branch_sync.next_action and then running `no-mistakes rerun`.' \
        "$base" "$host"
      ;;
  esac
}

run_summary() {
  case "$RUN_CLASS" in
    none) printf 'no run' ;;
    active) printf 'run %s active (%s) - stays on its start agent%s, never aborted' "$RUN_ID" "$RUN_STATUS" "${RUN_AGENT:+ ($RUN_AGENT)}" ;;
    success) printf 'run %s completed' "$RUN_ID" ;;
    stopped)
      case "$RUN_CMD" in
        *--keep-local*) printf 'run %s %s - its next step would discard commits; worker raises a decision' "$RUN_ID" "$RUN_STATUS" ;;
        '') printf 'run %s %s - worker continues: rerun' "$RUN_ID" "$RUN_STATUS" ;;
        *) printf 'run %s %s - worker continues: %s, then rerun' "$RUN_ID" "$RUN_STATUS" "$RUN_NEXT" ;;
      esac
      ;;
    *) printf 'run unreadable - worker checks it after relaunch' ;;
  esac
}

# --- plan -------------------------------------------------------------------

PLAN=()     # printed plan lines
ACTIONS=()  # "<kind>\t<id>\t<desc>" executed in order
NOTES=()    # relaunch note per action (empty when none)
ARGS=()     # extra relaunch arguments per action, space-separated

plan() { PLAN+=("$1"); }
action() {  # <kind> <id> <desc> [note] [args]
  ACTIONS+=("$1"$'\t'"$2"$'\t'"$3")
  NOTES+=("${4:-}")
  ARGS+=("${5:-}")
}

metas_of_kind() {  # <kind>...
  local meta kind k
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(fm_meta_get "$meta" kind)
    for k in "$@"; do
      [ "$kind" = "$k" ] && printf '%s\n' "$meta"
    done
  done
}

config_change() {  # <label> <old> <new>
  if [ "$2" = "$3" ]; then plan "$1: $3 (unchanged)"; else plan "$1: ${2:-(absent)} -> $3"; fi
}

build_plan() {
  local host=$1 old_host meta id h m e tier target th tm te state parked sm_line sm_h remote note
  old_host=$(first_line "$CONFIG/host-profile")
  plan "host switch: ${old_host:-(none recorded)} -> $host (scope: $SCOPE, home: $FM_HOME)"
  if [ "$SCOPE" = fleet ]; then
    config_change crew-harness "$(first_line "$CONFIG/crew-harness")" "$(first_line "$P/crew-harness")"
    config_change secondmate-harness "$(first_line "$CONFIG/secondmate-harness")" "$(first_line "$P/secondmate-harness")"
    if cmp -s "$CONFIG/crew-dispatch.json" "$P/crew-dispatch.json"; then
      plan "crew-dispatch.json: unchanged"
    else
      plan "crew-dispatch.json: replaced by the $host profile's"
    fi
    config_change host-profile "$old_host" "$host"
    NM_OLD_AGENT=$(nm_agent "$NM_CONFIG")
    if [ "$NM_OLD_AGENT" = "$NM_NEW_AGENT" ] && { [ ! -f "$P/no-mistakes-args" ] \
      || [ "$(nm_args "$NM_CONFIG" "$NM_NEW_AGENT")" = "$(grep -v '^$' "$P/no-mistakes-args")" ]; }; then
      NM_CHANGED=0
      plan "no-mistakes agent: $NM_NEW_AGENT (unchanged) in $NM_CONFIG"
    else
      NM_CHANGED=1
      plan "no-mistakes agent: ${NM_OLD_AGENT:-(absent)} -> $NM_NEW_AGENT in $NM_CONFIG"
      [ -f "$P/no-mistakes-args" ] && plan "no-mistakes $NM_NEW_AGENT args: $(tr '\n' ' ' < "$P/no-mistakes-args" | sed 's/ *$//')"
    fi
    SM_METAS=$(metas_of_kind secondmate)
    if [ -n "$SM_METAS" ]; then
      plan "push: inherited config to live secondmate homes"
      action push - "push inherited config to secondmate homes"
    fi
    sm_line=$(first_line "$P/secondmate-harness")
    sm_h=$(word 1 "$sm_line")
    note="The fleet host is now $host. Run \`bin/fm-host-switch.sh $host --dry-run\` and then \`bin/fm-host-switch.sh $host\` in this home to move your own workers onto it, then report the result through your status."
    while IFS= read -r meta; do
      [ -n "$meta" ] || continue
      id=$(basename "$meta" .meta)
      remote=$(fm_meta_get "$meta" remote_host)
      h=$(fm_meta_get "$meta" harness)
      if [ -n "$remote" ]; then
        plan "secondmate $id: remote on $remote; switch it by hand there"
      elif [ "$h" = "$sm_h" ]; then
        plan "secondmate $id: already on $sm_h; steer it to run bin/fm-host-switch.sh $host in its home"
        action steer "$id" "steer secondmate $id to switch its own workers" "$note"
      else
        plan "secondmate $id: relaunch on $sm_line, then steer it to run bin/fm-host-switch.sh $host in its home"
        action secondmate "$id" "relaunch secondmate $id on $sm_line"
        action steer "$id" "steer secondmate $id to switch its own workers" "$note"
      fi
    done <<< "$SM_METAS"
  fi
  while IFS= read -r meta; do
    [ -n "$meta" ] || continue
    id=$(basename "$meta" .meta)
    h=$(fm_meta_get "$meta" harness)
    m=$(fm_meta_get "$meta" model)
    e=$(fm_meta_get "$meta" effort)
    if [ "$h" = "$CREW" ]; then
      plan "worker $id: already on $CREW; unchanged"
      continue
    fi
    if ! is_host "$h"; then
      plan "worker $id: on $h, not a host profile; unchanged"
      continue
    fi
    tier=$(tier_of "$h" "$m" "$e")
    target=$(tier_target "$tier" "$host" "$DISPATCH" "$CREW")
    th=$(word 1 "$target"); tm=$(word 2 "$target"); te=$(word 3 "$target")
    state=$(agent_state "$id" "$meta")
    parked=0
    fm_worker_park_valid "$STATE" "$id" && parked=1
    inventory_run "$(fm_meta_get "$meta" worktree)" "$(fm_meta_get "$meta" branch)"
    note=$(continuation_note "$host")
    local args="--harness $th${tm:+ --model $tm}${te:+ --effort $te}" from="$h/${m:-default}/${e:-default}" to="$th/${tm:-default}/${te:-default}"
    if [ "$parked" = 1 ]; then
      plan "worker $id: unpark (parked) $from -> $to ($tier); $(run_summary)"
      action unpark "$id" "unpark worker $id on $to" "$note" "$args"
    elif [ "$state" = alive ]; then
      plan "worker $id: relaunch $from -> $to ($tier); $(run_summary)"
      action worker "$id" "relaunch worker $id on $to" "$note" "$args"
    else
      plan "worker $id: stopped ($state), not relaunched; $(run_summary); relaunch it later with: bin/fm-control.sh $id relaunch $args --note <why>"
    fi
  done <<< "$(metas_of_kind ship scout)"
}

# --- apply ------------------------------------------------------------------

RECORD=''
FAILED=0

log_action() {  # <ok|FAILED> <desc> [detail]
  local line="$1 $2${3:+: $3}"
  printf '%s\n' "$line"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >> "$RECORD/actions.log"
  [ "$1" = ok ] || FAILED=1
}

one_line() { printf '%s' "$1" | tr '\n\t' '  ' | cut -c1-300; }

install_file() {  # <src> <dest>
  local tmp
  tmp="$2.host-switch.$$"
  cp "$1" "$tmp" && mv -f "$tmp" "$2" && return 0
  rm -f "${tmp:?}"
  return 1
}

CONFIG_ITEMS="secondmate-harness crew-harness crew-dispatch.json host-worker-tiers host-profile"

# Put back every config item as it was before this switch.
restore_config() {
  local item
  for item in $CONFIG_ITEMS; do
    if [ -f "$RECORD/config-before/$item" ]; then
      cp -p "$RECORD/config-before/$item" "${CONFIG:?}/${item:?}"
    else
      rm -f "${CONFIG:?}/${item:?}"
    fi
  done
}

apply_config() {
  local item stage tmp
  mkdir -p "$RECORD/config-before" "$RECORD/config-after" || { log_action FAILED "create the switch record"; return 1; }
  for item in $CONFIG_ITEMS; do
    if [ -f "$CONFIG/$item" ] && ! cp -p "$CONFIG/$item" "$RECORD/config-before/$item"; then
      log_action FAILED "back up config/$item"
      return 1
    fi
  done
  if [ "$NM_CHANGED" = 1 ] && ! cp -p "$NM_CONFIG" "$RECORD/no-mistakes-config.before.yaml"; then
    log_action FAILED "back up the no-mistakes config" "$NM_CONFIG"
    return 1
  fi
  stage=$RECORD/config-after
  if ! { cp "$P/secondmate-harness" "$P/crew-harness" "$P/crew-dispatch.json" "$stage/" \
    && profile_tier_lines > "$stage/host-worker-tiers" \
    && printf '%s\n' "$TARGET" > "$stage/host-profile"; }; then
    log_action FAILED "stage the $TARGET profile"
    return 1
  fi
  for item in $CONFIG_ITEMS; do
    if ! install_file "$stage/$item" "$CONFIG/$item"; then
      restore_config
      log_action FAILED "write config/$item; restored the previous config"
      return 1
    fi
  done
  log_action ok "config switched to the $TARGET profile"
  if [ "$NM_CHANGED" = 1 ]; then
    tmp="$NM_CONFIG.host-switch.$$"
    # Copy first so the replacement keeps the original's mode.
    if cp -p "$NM_CONFIG" "$tmp" && nm_render "$NM_CONFIG" "$NM_NEW_AGENT" "$NM_ARGS_FILE" > "$tmp" && mv -f "$tmp" "$NM_CONFIG"; then
      log_action ok "no-mistakes agent set to $NM_NEW_AGENT (new runs only; active runs keep their agent)"
    else
      rm -f "${tmp:?}"
      restore_config
      log_action FAILED "no-mistakes config not changed; restored the previous config" "$NM_CONFIG"
      return 1
    fi
  fi
}

run_actions() {
  local i kind id desc note out rc relaunch_failed=''
  for i in "${!ACTIONS[@]}"; do
    IFS=$'\t' read -r kind id desc <<< "${ACTIONS[$i]}"
    note=${NOTES[$i]}
    rc=0
    if [ "$kind" = steer ] && [ "$relaunch_failed" = "$id" ]; then
      log_action FAILED "$desc" "skipped because its relaunch failed"
      continue
    fi
    case "$kind" in
      push) out=$(FM_HOME="$FM_HOME" "$PUSH" 2>&1) || rc=$? ;;
      secondmate) out=$(FM_HOME="$FM_HOME" "$CONTROL" "$id" relaunch 2>&1) || rc=$? ;;
      steer) out=$(FM_HOME="$FM_HOME" "$SEND" "$id" "$note" 2>&1) || rc=$? ;;
      worker)
        # shellcheck disable=SC2086 # ARGS holds space-separated flag/value pairs without spaces in values
        out=$(FM_HOME="$FM_HOME" "$CONTROL" "$id" relaunch ${ARGS[$i]} --note "$note" 2>&1) || rc=$?
        ;;
      unpark)
        # shellcheck disable=SC2086 # same as above
        out=$(FM_HOME="$FM_HOME" "$PARK" unpark "$id" --reason "the fleet moved to the $TARGET host" ${ARGS[$i]} --note-extra "$note" 2>&1) || rc=$?
        ;;
    esac
    if [ "$rc" -eq 0 ]; then
      log_action ok "$desc"
    else
      log_action FAILED "$desc" "$(one_line "$out")"
      [ "$kind" = secondmate ] && relaunch_failed=$id
    fi
  done
}

# --- verbs ------------------------------------------------------------------

load_target() {  # <host>
  TARGET=$1
  valid_host_name "$TARGET" || die "'$TARGET' is not a host name"
  if is_secondmate_home; then
    SCOPE=home
    local fleet
    fleet=$(first_line "$CONFIG/host-profile")
    [ "$fleet" = "$TARGET" ] || die "this secondmate home's fleet host is '${fleet:-unset}', not '$TARGET'; the primary firstmate owns the fleet switch"
    CREW=$(first_line "$CONFIG/crew-harness")
    [ "$CREW" = "$TARGET" ] || die "this secondmate home's inherited crew harness is '${CREW:-unset}', not '$TARGET'; wait for the primary's config push"
    DISPATCH=$CONFIG/crew-dispatch.json
    return 0
  fi
  SCOPE=fleet
  P=$PROFILES/$TARGET
  [ -d "$P" ] || die "no saved profile for '$TARGET' in $PROFILES; save one with: bin/fm-host-switch.sh save $TARGET (while the fleet runs on $TARGET)"
  local f
  for f in secondmate-harness crew-harness crew-dispatch.json no-mistakes-agent; do
    [ -n "$(first_line "$P/$f")" ] || die "profile '$TARGET' is incomplete: $P/$f is missing or empty"
  done
  [ "$(first_line "$P/crew-harness")" = "$TARGET" ] || die "profile '$TARGET' crew-harness names '$(first_line "$P/crew-harness")', not '$TARGET'"
  [ "$(word 1 "$(first_line "$P/secondmate-harness")")" = "$TARGET" ] || die "profile '$TARGET' secondmate-harness does not start with '$TARGET'"
  if command -v jq >/dev/null 2>&1; then
    jq -e 'type == "object"' "$P/crew-dispatch.json" >/dev/null 2>&1 || die "profile '$TARGET' crew-dispatch.json is not a JSON object"
  fi
  NM_NEW_AGENT=$(first_line "$P/no-mistakes-agent")
  NM_ARGS_FILE=''
  [ -f "$P/no-mistakes-args" ] && NM_ARGS_FILE=$P/no-mistakes-args
  [ -f "$NM_CONFIG" ] || die "no-mistakes config $NM_CONFIG is missing"
  nm_render "$NM_CONFIG" "$NM_NEW_AGENT" "$NM_ARGS_FILE" > /dev/null \
    || die "no-mistakes config $NM_CONFIG has a structure this switch does not edit (it needs exactly one top-level agent: line and a block-style agent_args_override); change it by hand"
  CREW=$TARGET
  DISPATCH=$P/crew-dispatch.json
}

cmd_switch() {
  local dry=0 i
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  load_target "$1"
  shift
  case "${1:-}" in
    --dry-run) dry=1 ;;
    '') ;;
    *) usage >&2; exit 2 ;;
  esac
  [ -d "$STATE" ] || die "state dir '$STATE' is missing"
  if [ "$dry" = 0 ]; then
    LOCK=$STATE/.host-switch.lock
    fm_lock_try_acquire "$LOCK" || die "another host switch is running in this home ($LOCK)"
    trap 'fm_lock_release "$LOCK" >/dev/null 2>&1 || true' EXIT
  fi
  NM_CHANGED=0
  build_plan "$TARGET"
  for i in "${PLAN[@]}"; do printf '%s\n' "$i"; done
  if [ "$dry" = 1 ]; then
    echo "dry run: nothing changed"
    return 0
  fi
  RECORD="$STATE/host-switch/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$RECORD" || die "cannot create the switch record $RECORD"
  printf '%s\n' "${PLAN[@]}" > "$RECORD/plan.txt"
  : > "$RECORD/actions.log"
  if [ "$SCOPE" = fleet ]; then
    apply_config || { echo "record: $RECORD"; echo "switch stopped before relaunching anything" >&2; exit 1; }
  fi
  run_actions
  echo "record: $RECORD"
  [ "$FAILED" = 0 ] || exit 1
}

cmd_save() {
  local host=${1:-} dir sm crew agent
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  valid_host_name "$host" || die "'$host' is not a host name"
  is_secondmate_home && die "host profiles are saved in the primary home"
  sm=$(first_line "$CONFIG/secondmate-harness")
  crew=$(first_line "$CONFIG/crew-harness")
  [ "$crew" = "$host" ] || die "live config/crew-harness is '${crew:-unset}', not '$host'; save a profile only while the fleet runs on it"
  [ "$(word 1 "$sm")" = "$host" ] || die "live config/secondmate-harness is '${sm:-unset}', not '$host ...'"
  [ -f "$CONFIG/crew-dispatch.json" ] || die "live config/crew-dispatch.json is missing"
  agent=$(nm_agent "$NM_CONFIG")
  [ -n "$agent" ] || die "no top-level agent: line in $NM_CONFIG"
  dir=$PROFILES/$host
  mkdir -p "$dir" || die "cannot create $dir"
  printf '%s\n' "$sm" > "$dir/secondmate-harness"
  printf '%s\n' "$crew" > "$dir/crew-harness"
  cp "$CONFIG/crew-dispatch.json" "$dir/crew-dispatch.json"
  printf '%s\n' "$agent" > "$dir/no-mistakes-agent"
  nm_args "$NM_CONFIG" "$agent" > "$dir/no-mistakes-args"
  [ -s "$dir/no-mistakes-args" ] || rm -f "$dir/no-mistakes-args"
  echo "saved profile '$host' in $dir"
  [ -f "$dir/worker-tiers" ] || echo "note: no worker-tiers in $dir; relaunched workers take the dispatch default until you add '<strong|standard|light> <harness> <model> <effort>' lines"
}

has_profile() {
  local d
  for d in "$PROFILES"/*/; do
    [ -d "$d" ] && return 0
  done
  return 1
}

cmd_check() {
  local session='' fleet meta id h stale='' n=0 crew
  case "${1:-}" in
    --session-host) session=${2:-}; [ -n "$session" ] || { usage >&2; exit 2; } ;;
    '') ;;
    *) usage >&2; exit 2 ;;
  esac
  fleet=$(first_line "$CONFIG/host-profile")
  if [ -z "$fleet" ]; then
    has_profile || return 0
    fleet=$(first_line "$CONFIG/crew-harness")
  fi
  case "$fleet" in ''|default) return 0 ;; esac
  [ -n "$session" ] || session=$("$HARNESS" 2>/dev/null || true)
  if [ -n "$session" ] && [ "$session" != unknown ] && [ "$session" != "$fleet" ]; then
    if is_secondmate_home; then
      echo "HOST_PROFILE: this secondmate session runs on $session but the fleet host is $fleet; the primary firstmate owns the fleet switch"
    elif [ -d "$PROFILES/$session" ]; then
      echo "HOST_PROFILE: this session runs on $session but the fleet host is $fleet; to move the whole fleet to $session run: bin/fm-host-switch.sh $session (preview with --dry-run)"
    else
      echo "HOST_PROFILE: this session runs on $session but the fleet host is $fleet, and no $session profile is saved; save one while the fleet runs on $session (bin/fm-host-switch.sh save $session) before switching"
    fi
    return 0
  fi
  crew=$(first_line "$CONFIG/crew-harness")
  [ -n "$crew" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    case "$(fm_meta_get "$meta" kind)" in ship|scout) ;; *) continue ;; esac
    h=$(fm_meta_get "$meta" harness)
    [ "$h" = "$crew" ] && continue
    is_host "$h" || continue
    id=$(basename "$meta" .meta)
    n=$((n + 1))
    [ "$n" -le 5 ] && stale="$stale${stale:+, }$id ($h)"
  done
  [ "$n" -eq 0 ] && return 0
  [ "$n" -gt 5 ] && stale="$stale, and $((n - 5)) more"
  echo "HOST_PROFILE: $n worker(s) in this home still run on another host than $fleet: $stale; run: bin/fm-host-switch.sh $fleet (preview with --dry-run)"
}

cmd_verify() {
  local fleet crew sm_h meta id h kind bad=0 line
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  fleet=$(first_line "$CONFIG/host-profile")
  [ -n "$fleet" ] || die "no fleet host recorded in config/host-profile"
  echo "fleet host: $fleet"
  crew=$(first_line "$CONFIG/crew-harness")
  [ "$crew" = "$fleet" ] || { echo "OLD crew-harness: $crew"; bad=1; }
  if ! is_secondmate_home; then
    sm_h=$(word 1 "$(first_line "$CONFIG/secondmate-harness")")
    [ "$sm_h" = "$fleet" ] || { echo "OLD secondmate-harness: $sm_h"; bad=1; }
    if [ -d "$PROFILES/$fleet" ]; then
      line=$(nm_agent "$NM_CONFIG")
      [ "$line" = "$(first_line "$PROFILES/$fleet/no-mistakes-agent")" ] || { echo "OLD no-mistakes agent: $line"; bad=1; }
    fi
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(fm_meta_get "$meta" kind)
    h=$(fm_meta_get "$meta" harness)
    case "$kind" in
      secondmate)
        [ -n "$(fm_meta_get "$meta" remote_host)" ] && { echo "CHECK secondmate $id: remote; verify it on its host"; continue; }
        if [ "$h" = "$sm_h" ]; then echo "ok secondmate $id: $h"; else echo "OLD secondmate $id: $h"; bad=1; fi
        ;;
      ship|scout)
        if [ "$h" = "$crew" ]; then
          echo "ok worker $id: $h"
        elif is_host "$h"; then
          echo "OLD worker $id: $h"
          bad=1
        else
          echo "ok worker $id: $h (not a host profile)"
        fi
        inventory_run "$(fm_meta_get "$meta" worktree)" "$(fm_meta_get "$meta" branch)"
        if [ "$RUN_CLASS" = active ] && [ -n "$RUN_AGENT" ] && [ "$RUN_AGENT" != "$fleet" ]; then
          echo "OLD run $RUN_ID of $id: active on $RUN_AGENT; the worker reruns it on $fleet after it ends"
          bad=1
        elif [ "$RUN_CLASS" = stopped ]; then
          echo "CHECK run $RUN_ID of $id: ended $RUN_STATUS; continue it with no-mistakes rerun"
        fi
        ;;
    esac
  done
  [ "$bad" = 0 ]
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
  save) shift; cmd_save "$@" ;;
  check) shift; cmd_check "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  -*) usage >&2; exit 2 ;;
  *) cmd_switch "$@" ;;
esac
