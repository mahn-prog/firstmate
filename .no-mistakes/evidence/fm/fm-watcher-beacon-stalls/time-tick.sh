#!/usr/bin/env bash
# time-tick.sh <code-root> <state-dir>
. "$1/bin/fm-marker-lib.sh"; . "$1/bin/fm-pending-reply-lib.sh"
s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
fm_pending_reply_tick "$2"
e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
printf 'records=%s tick_seconds=%.2f\n' "$(ls "$2/pending-replies" | wc -l | tr -d ' ')" "$(echo "$e - $s" | bc)"
