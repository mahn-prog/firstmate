#!/usr/bin/env bash
# run-watcher.sh <code-root> <lab> <logfile>
cd "$1" && exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$2" FM_POLL=5 FM_WATCH_HANDLING_SUCCESSOR=1 bash "$1/bin/fm-watch.sh" > "$3" 2>&1
