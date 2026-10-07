#!/usr/bin/env bash
# seed-pending-replies.sh <code-root> <lab-home> <n-settled>
# Seeds a lab home's state/pending-replies with records shaped like the live
# home's: one settled record made through the real lib (create -> delivered ->
# correlated report -> try_resolve), cloned N times under fresh corr ids, plus
# 1) a resolved record whose escalation is still open (tick must close it),
# 2) an open awaiting_report record whose correlated report is already in the
#    parent status file (tick must resolve it), and
# 3) a resolved record with an escalation that was already closed (settled).
set -u
ROOT=$1 HOME_DIR=$2 N=$3
STATE="$HOME_DIR/state"
. "$ROOT/bin/fm-marker-lib.sh"
. "$ROOT/bin/fm-pending-reply-lib.sh"
export FM_PENDING_REPLY_GRACE_SECS=0
tmpl=$(fm_pending_reply_create "$HOME_DIR" "$STATE" hibit "seed request")
fm_pending_reply_mark_delivered "$STATE" "$tmpl"
printf 'done [corr=%s]: seed complete\n' "$tmpl" >> "$STATE/hibit.status"
fm_pending_reply_try_resolve "$STATE" "$tmpl" || { echo "template did not resolve" >&2; exit 1; }
dir=$(fm_pending_reply_dir "$STATE")
for ((i = 1; i < N; i++)); do
  c=$(printf '%016x' "$((0x1000000000 + i))")
  sed "s/^corr_id=.*/corr_id=$c/" "$dir/$tmpl" > "$dir/$c"
  chmod 600 "$dir/$c"
done
openesc=$(fm_pending_reply_create "$HOME_DIR" "$STATE" hibit "open escalation request")
fm_pending_reply_mark_delivered "$STATE" "$openesc"
rec=$(fm_pending_reply_path "$STATE" "$openesc")
fm_pending_reply_set "$rec" escalated_epoch "$(( $(date +%s) - 600 ))"
fm_pending_reply_set "$rec" phase resolved
closedesc=$(fm_pending_reply_create "$HOME_DIR" "$STATE" hibit "closed escalation request")
fm_pending_reply_mark_delivered "$STATE" "$closedesc"
rec=$(fm_pending_reply_path "$STATE" "$closedesc")
fm_pending_reply_set "$rec" escalated_epoch "$(( $(date +%s) - 900 ))"
fm_pending_reply_set "$rec" escalation_closed_epoch "$(( $(date +%s) - 800 ))"
fm_pending_reply_set "$rec" phase resolved
awaiting=$(fm_pending_reply_create "$HOME_DIR" "$STATE" hibit "awaiting request")
fm_pending_reply_mark_delivered "$STATE" "$awaiting"
printf 'done [corr=%s]: awaiting report landed\n' "$awaiting" >> "$STATE/hibit.status"
printf 'settled_template=%s\nopen_escalation=%s\nclosed_escalation=%s\nawaiting=%s\n' \
  "$tmpl" "$openesc" "$closedesc" "$awaiting"
