#!/usr/bin/env bash
# fm-captain-questions.sh - count the captain calls open across the fleet.
#
# Read-only report behind the open-question cap that
# .agents/skills/captain-hold-lifecycle/SKILL.md owns: how many calls wait on
# the captain now, how many are parked, and whether the open count has reached
# this home's cap. It classifies nothing itself. Every captain hold's bucket
# comes from bin/fm-fleet-snapshot.sh, the single owner of hold_bucket, so this
# count agrees with Bearings' Captain's Call and Charted Next.
#   open    live + aged captain holds: waiting on the captain now, or overdue.
#           Aged holds stay open so that aging out of Captain's Call never
#           frees a cap slot.
#   parked  dated + blocked captain holds: deferred to a date, or waiting on
#           other work.
# The main home's holds come from the snapshot's backlog records; a current
# row the backlog parser could not structure marks the main home inexact. Each
# registered secondmate contributes the captain holds in its published home
# summary (its queued inventory plus captain-hold decisions, each hold counted
# once); a child's needs-decision is that secondmate's to handle and is not a
# captain call. A summary whose captain-hold inventory was truncated or only
# partly trusted marks that home inexact, and a secondmate with no readable
# summary is listed as unmeasured; either makes the fleet total a lower bound
# (exact=no). Every registered secondmate is sampled. This command writes
# nothing; the snapshot may refresh its own observational remote-summary cache.
#
# The cap is the optional home config file config/captain-question-cap
# (FM_CONFIG_OVERRIDE, else $FM_HOME/config): one positive base-10 integer on
# one line in a regular file. Absent means no cap, and the command only
# reports. A present but malformed file is refused rather than defaulted.
# at_cap is yes when the open count is at or above the cap.
#
# Hard limits the count and the cap never change: a per-operation approval the
# organization's policy reserves (toll-free and Mindbody filings, Salesforce
# record writes, carrier appeals, number assignment and replacement, first
# arming of a lane) is never accepted by silence and never a two-way door, and
# the cap never delays holding one; product decisions and client-facing wording
# stay with the captain; nothing here changes organization policy, the Security
# Guardrails, or any review gate.
#
# Usage: fm-captain-questions.sh [--json]
#   (default)  one summary line, then one line per home, unmeasured home, and call:
#                captain_questions: open=<n> parked=<n> cap=<n|none> at_cap=<yes|no> exact=<yes|no>
#                home <id>: open=<n> parked=<n> exact=<yes|no>
#                unmeasured <id>: <reason>
#                call <home>/<task-id> <bucket>: <title>
#   --json     the same model: {schema:"fm-captain-questions.v1", open, parked,
#              cap (null when absent), at_cap, exact, homes[], unmeasured[], calls[]}
#   -h|--help  this text
# Exit: 0 when counted; 1 when the fleet snapshot fails; 2 on a usage error or
# a malformed cap file.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

FORMAT=text
case "$#:${1:-}" in
  0:) ;;
  1:--json) FORMAT=json ;;
  1:-h|1:--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-captain-questions: jq not found" >&2; exit 1; }

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CAP_FILE="$CONFIG/captain-question-cap"

CAP=null
if [ -e "$CAP_FILE" ] || [ -L "$CAP_FILE" ]; then
  cap_value=
  if [ -f "$CAP_FILE" ] && [ ! -L "$CAP_FILE" ]; then
    cap_value=$(cat "$CAP_FILE" 2>/dev/null) || cap_value=
  fi
  case "$cap_value" in
    ''|*[!0-9]*|0*)
      echo "fm-captain-questions: $CAP_FILE must be one positive integer on one line in a regular file" >&2
      exit 2 ;;
  esac
  CAP=$cap_value
fi

SNAPSHOT=$(FM_SNAPSHOT_SECONDMATES=0 "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || {
  echo "fm-captain-questions: fleet snapshot failed" >&2
  exit 1
}

MODEL=$(printf '%s\n' "$SNAPSHOT" | jq --argjson cap "$CAP" '
  def is_open: .bucket == "live" or .bucket == "aged";
  def tally($calls):
    {open:([$calls[] | select(is_open)] | length),
     parked:([$calls[] | select(is_open | not)] | length)};
  ([.backlog.records[]? | select(.structured == true and .hold_bucket != null)
    | {home:"main",id,bucket:.hold_bucket,title:(.title // .id)}]) as $main
  | ([.secondmate_current.records[]? | select(.provenance.selected == "structured-home")]) as $measured
  | ([.secondmate_current.records[]? | select(.provenance.selected != "structured-home")
      | {id,reason:(.current.reason // "structured home summary unavailable")}]) as $unmeasured
  | ([$measured[] as $m
      | [($m.queued // [])[]
          | select(.hold_kind == "captain" and .hold_bucket != null)
          | {id,bucket:.hold_bucket,title:(.title // .id)}]
        + [($m.decisions_open // [])[]
          | select(.source == "backlog" and .verb == "captain-hold" and .hold_bucket != null)
          | {id,bucket:.hold_bucket,title:(.summary // .id)}]
      | unique_by(.id)[]
      | {home:$m.id} + .]) as $mate_calls
  | ([{id:"main",exact:((.main_inventory.unstructured_current_count // 0) == 0)} + tally($main)]
     + [$measured[] as $m
        | {id:$m.id,
           exact:(($m.provenance.trust // "complete") == "complete"
                  and ([$m.omitted[]? | select(.surface == "queued" or .surface == "decisions_open")] | length) == 0)}
          + tally([$mate_calls[] | select(.home == $m.id)])]) as $homes
  | ($main + $mate_calls) as $calls
  | tally($calls) as $total
  | {schema:"fm-captain-questions.v1",
     open:$total.open,parked:$total.parked,cap:$cap,
     at_cap:($cap != null and $total.open >= $cap),
     exact:(all($homes[]; .exact) and ($unmeasured | length) == 0
            and ((.secondmate_current.truncated // 0) == 0)),
     homes:[$homes[] | {id,open,parked,exact}],
     unmeasured:$unmeasured,
     calls:$calls}
') || { echo "fm-captain-questions: could not read the fleet snapshot" >&2; exit 1; }

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$MODEL"
  exit 0
fi

printf '%s\n' "$MODEL" | jq -r '
  def yn: if . then "yes" else "no" end;
  "captain_questions: open=\(.open) parked=\(.parked) cap=\(.cap // "none") at_cap=\(.at_cap | yn) exact=\(.exact | yn)",
  (.homes[] | "home \(.id): open=\(.open) parked=\(.parked) exact=\(.exact | yn)"),
  (.unmeasured[] | "unmeasured \(.id): \(.reason)"),
  (.calls[] | "call \(.home)/\(.id) \(.bucket): \(.title)")
'
