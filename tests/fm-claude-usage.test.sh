#!/usr/bin/env bash
# tests/fm-claude-usage.test.sh - bin/fm-claude-usage.sh counts only
# Firstmate-launched Claude sessions, tells a worker from a secondmate by the
# brief it read, deduplicates the per-block transcript lines of one request,
# sums subagent requests into the session only, and reads compactions and the
# session cost. The transcripts are synthetic, in Claude Code's own line shape.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

USAGE="$ROOT/bin/fm-claude-usage.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-usage)
PROJECTS="$TMP_ROOT/projects"

# usage_line <id> <input> <cache_creation> <cache_read> <output> [model]
usage_line() {
  printf '{"type":"assistant","timestamp":"2026-10-21T10:00:01Z","message":{"id":"%s","model":"%s","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' \
    "$1" "${6:-claude-opus-5-5}" "$2" "$3" "$4" "$5"
}

user_line() {  # <timestamp> <text>
  jq -cn --arg ts "$1" --arg t "$2" '{type:"user",timestamp:$ts,message:{role:"user",content:$t}}'
}

tool_result_line() {  # <text>
  jq -cn --arg t "$1" '{type:"user",timestamp:"2026-10-21T10:00:02Z",message:{role:"user",content:[{type:"tool_result",tool_use_id:"t1",content:$t}]}}'
}

# A doorbell-launched ship worker: it reads its brief through a tool, one
# request spans two transcript lines, it compacts once, and runs one subagent.
# A Pi bridge's msg_syn_ record and an all-zero record are not real requests.
make_worker() {
  local dir="$PROJECTS/-wt-ship" s=worker-1
  mkdir -p "$dir/$s/subagents"
  {
    user_line 2026-10-21T10:00:00Z "Firstmate operational input waiting: read '/home/state/operational-inbox/1.msg' and handle its contents as Firstmate operational input."
    usage_line msg_syn_1 5 9000 0 3 'claude-sonnet-5-5[1m]'
    usage_line zero 0 0 0 0
    usage_line m1 2 30000 1000 50
    usage_line m1 2 30000 1000 80
    tool_result_line "FIRSTMATE_OP: v1 launch-brief: # Current worker role contract
You are a crewmate: an autonomous worker agent managed by firstmate."
    usage_line m2 1 2000 31000 40
    printf '%s\n' '{"type":"system","subtype":"compact_boundary","timestamp":"2026-10-21T10:30:00Z","compactMetadata":{"trigger":"auto","preTokens":170000,"postTokens":5000}}'
    usage_line m3 1 9000 0 20
    usage_line synthetic 0 0 0 0 '<synthetic>'
    printf '%s\n' '{"type":"cost-state","totalCostUSD":1.25}'
  } > "$dir/$s.jsonl"
  usage_line sub1 5 500 4500 10 > "$dir/$s/subagents/agent-a.jsonl"
}

# A secondmate launched with its brief inline, on an earlier day.
make_secondmate() {
  local dir="$PROJECTS/-home-sm"
  mkdir -p "$dir"
  {
    user_line 2026-10-10T09:00:00Z "FIRSTMATE_OP: v1 launch-brief: # Charter for the second mate"
    usage_line s1 3 20000 0 10
  } > "$dir/sm-1.jsonl"
}

# Sessions the reader must skip: the captain's own chat, and a doorbell session
# that never read a brief.
make_unrelated() {
  mkdir -p "$PROJECTS/-other"
  { user_line 2026-10-21T08:00:00Z "hello"; usage_line u1 1 1000 0 5; } > "$PROJECTS/-other/chat.jsonl"
  { user_line 2026-10-21T08:00:00Z "Firstmate operational input waiting: read '/x.msg'"; usage_line u2 1 1000 0 5; } \
    > "$PROJECTS/-other/doorbell-only.jsonl"
}

make_worker
make_secondmate
make_unrelated

test_json_rows_count_firstmate_sessions_only() {
  local out worker sm
  out=$("$USAGE" --projects "$PROJECTS" --json) || fail "the --json read failed: $out"
  assert_equals 2 "$(printf '%s\n' "$out" | grep -c .)" "only the worker and the secondmate are Firstmate-launched"
  worker=$(printf '%s\n' "$out" | jq -c 'select(.session == "worker-1")')
  sm=$(printf '%s\n' "$out" | jq -c 'select(.session == "sm-1")')
  assert_equals worker "$(jq -r .role <<<"$worker")" "a brief carrying the worker role contract marks a worker"
  assert_equals secondmate "$(jq -r .role <<<"$sm")" "an inline brief without it marks a secondmate"
  assert_equals 3 "$(jq -r .requests <<<"$worker")" "two lines of one request count once and synthetic or all-zero ones not at all"
  assert_equals 31002 "$(jq -r .first_request <<<"$worker")" "a request's context is input plus cache creation plus cache read"
  assert_equals 33001 "$(jq -r .peak_request <<<"$worker")" "peak is the largest request"
  assert_equals 73004 "$(jq -r .main_context_total <<<"$worker")" "main context sums every request"
  assert_equals 140 "$(jq -r .output_total <<<"$worker")" "a request keeps its last line's output tokens"
  assert_equals 5005 "$(jq -r .subagent_context_total <<<"$worker")" "subagent requests are read from the session's subagents directory"
  assert_equals 78009 "$(jq -r .session_context_total <<<"$worker")" "the session total adds the subagent requests"
  assert_equals '[{"post":5000,"pre":170000,"trigger":"auto"}]' "$(jq -c .compactions <<<"$worker")" "compactions come from compact_boundary records"
  assert_equals 1.25 "$(jq -r .cost_usd <<<"$worker")" "cost is the session's cost-state total"
  assert_equals claude-opus-5-5 "$(jq -r .model <<<"$worker")" "model is the first real assistant model"
  pass "--json reports exactly the Firstmate-launched sessions with deduplicated request totals"
}

test_filters_select_by_start_day_and_role() {
  local out
  out=$("$USAGE" --projects "$PROJECTS" --json --since 2026-10-14) || fail "the --since read failed: $out"
  assert_equals worker-1 "$(printf '%s\n' "$out" | jq -r .session)" "--since keeps only sessions started on or after that day"
  out=$("$USAGE" --projects "$PROJECTS" --json --until 2026-10-13) || fail "the --until read failed: $out"
  assert_equals sm-1 "$(printf '%s\n' "$out" | jq -r .session)" "--until keeps only sessions started on or before that day"
  out=$("$USAGE" --projects "$PROJECTS" --json --role secondmate) || fail "the --role read failed: $out"
  assert_equals sm-1 "$(printf '%s\n' "$out" | jq -r .session)" "--role keeps only that role"
  pass "--since, --until and --role select sessions"
}

test_summary_and_session_tables() {
  local out row
  out=$("$USAGE" --projects "$PROJECTS" --role worker) || fail "the summary read failed: $out"
  row=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "worker"')
  assert_equals "worker	1	3	24.3k	31.0k	33.0k	31.0k	33.0k	78.0k	78.0k	78.0k	1	1	1.25" "$row" \
    "the summary row aggregates requests and sessions"
  out=$("$USAGE" --projects "$PROJECTS" --sessions) || fail "the --sessions read failed: $out"
  assert_equals 3 "$(printf '%s\n' "$out" | grep -c .)" "--sessions prints a header and one row per session"
  assert_contains "$out" "-wt-ship/worker-1" "--sessions names the transcript"
  pass "the summary and per-session tables report the same sessions"
}

test_missing_root_and_bad_date_refuse() {
  local out status
  out=$("$USAGE" --projects "$TMP_ROOT/absent" 2>&1)
  status=$?
  expect_code 1 "$status" "a missing transcript root must refuse: $out"
  out=$("$USAGE" --projects "$PROJECTS" --since 21-10-2026 2>&1)
  status=$?
  expect_code 2 "$status" "a malformed date must refuse: $out"
  pass "a missing transcript root or malformed date refuses"
}

test_json_rows_count_firstmate_sessions_only
test_filters_select_by_start_day_and_role
test_summary_and_session_tables
test_missing_root_and_bad_date_refuse
