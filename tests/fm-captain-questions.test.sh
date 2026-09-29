#!/usr/bin/env bash
# Behavior tests for bin/fm-captain-questions.sh, the read-only count of captain
# calls behind the open-question cap in captain-hold-lifecycle.
# Covers the open (live + aged) and parked (dated + blocked) split taken from the
# canonical fleet snapshot, the optional home cap and its refusal of malformed
# values, text/JSON parity, captain holds published by a secondmate home, and
# the lower-bound disclosure for a truncated or unreadable secondmate summary
# or an unstructured current main-home row.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COUNTER="$ROOT/bin/fm-captain-questions.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-questions)
# Keep disposable homes outside the snapshot's code-root boundary even when
# TMPDIR is inside an isolated source worktree.
FIXTURE_ROOT="$TMP_ROOT/fixture-root"
mkdir -p "$FIXTURE_ROOT"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

# Three open calls (two live, one aged), two parked (one dated, one blocked),
# and rows that are not open captain calls at all.
write_main_backlog() {  # <home>
  cat > "$1/data/backlog.md" <<'EOF'
## In flight
- [ ] gated-work - Work waiting on the captain (repo: firstmate) (kind: ship) (since 2026-07-10) (hold: pick A or B) (hold-kind: captain)
  Captain hold set: 2026-07-10T12:00:00Z

## Queued
- [ ] live-call - Choose the route (repo: firstmate) (kind: captain) (since 2026-07-10) (hold: route A or B) (hold-kind: captain)
  Captain hold set: 2026-07-10T12:00:00Z
- [ ] aged-call - Old unanswered call (repo: firstmate) (kind: captain) (since 2026-06-01) (hold: still open) (hold-kind: captain)
  Captain hold set: 2026-06-01T12:00:00Z
- [ ] dated-call - Deferred by the captain (repo: firstmate) (kind: captain) (since 2026-07-01) (hold: later) (hold-kind: captain) (hold-until: 2026-08-01)
  Captain hold set: 2026-07-01T12:00:00Z
- [ ] blocked-call - Waits on other work blocked-by: other-work (repo: firstmate) (kind: captain) (since 2026-07-10) (hold: after other work) (hold-kind: captain)
  Captain hold set: 2026-07-10T12:00:00Z
- [ ] other-work - Ordinary queued work (repo: firstmate) (kind: ship)
- [ ] external-wait - Waiting on a vendor (repo: firstmate) (kind: ship) (hold: vendor reply) (hold-kind: external)

## Done
- [x] answered-call - Settled call (repo: firstmate) (kind: captain) (hold-kind: captain) (done 2026-07-09)
EOF
}

# A local secondmate home publishing its structured summary: one live and one
# aged captain hold (open) and one dated (parked). <omitted-json> lets a test
# declare a truncated captain-hold inventory.
write_mate() {  # <parent-home> <mate-id> <omitted-json>
  local parent=$1 id=$2 omitted=$3 mate
  mate="$TMP_ROOT/$id-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  mate=$(cd "$mate" && pwd -P)
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  printf -- '- %s - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-07-11)\n' \
    "$id" "$mate" >> "$parent/data/secondmates.md"
  jq -n --arg home "$mate" --argjson omitted "$omitted" '{
    schema:"fm-secondmate-home-summary.v1",
    hold_classifier_schema:"fm-captain-hold-buckets.v1",
    generated:"2026-07-11T17:55:00Z",generated_epoch:1783792500,home:$home,
    valid:true,reason:null,invalidity:{kind:null,ids:[]},state:"captain_decision",
    active_children:[],
    decisions_open:[
      {id:"mate-live",key:"mate-live",verb:"captain-hold",summary:"Mate live call",reason:"pick one",hold_until:null,hold_bucket:"live",hold_age_days:1,source:"backlog"},
      {id:"mate-task",key:"race",verb:"needs-decision",summary:"child asks firstmate",reason:null,source:"status"}
    ],holds:[],
    queued:[
      {id:"mate-aged",title:"Mate aged call",blocked_by:null,blocked_by_ids:[],unresolved_blocker_ids:[],blocked_reason:null,hold_reason:"still open",hold_kind:"captain",hold_until:null,hold_bucket:"aged",hold_age_days:40,captain_actionable:false,repo:"firstmate",kind:"captain",since:"2026-06-01"},
      {id:"mate-dated",title:"Mate dated call",blocked_by:null,blocked_by_ids:[],unresolved_blocker_ids:[],blocked_reason:null,hold_reason:"later",hold_kind:"captain",hold_until:"2026-08-01",hold_bucket:"dated",hold_age_days:10,captain_actionable:false,repo:"firstmate",kind:"captain",since:"2026-07-01"},
      {id:"mate-live",title:"Mate live call",blocked_by:null,blocked_by_ids:[],unresolved_blocker_ids:[],blocked_reason:null,hold_reason:"pick one",hold_kind:"captain",hold_until:null,hold_bucket:"live",hold_age_days:1,captain_actionable:true,repo:"firstmate",kind:"captain",since:"2026-07-10"},
      {id:"mate-queued",title:"Mate ordinary work",blocked_by:null,blocked_by_ids:[],unresolved_blocker_ids:[],blocked_reason:null,hold_reason:null,hold_kind:null,hold_until:null,hold_bucket:null,hold_age_days:null,captain_actionable:false,repo:"firstmate",kind:"ship",since:"2026-07-10"}
    ],landed:[],endpoints:[],
    counts:{active_children:0,decisions_open:2,holds:0,queued:4,landed:0,endpoints:0},omitted:$omitted
  }' > "$mate/state/home-summary.json"
}

run_counter() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$FIXTURE_ROOT" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z FM_SNAPSHOT_NOW_EPOCH=1783792800 \
    "$COUNTER" "$@"
}

test_counts_open_and_parked_calls_in_the_main_home() {
  local home out
  home=$(make_home main-only)
  write_main_backlog "$home"
  out=$(run_counter "$home") || fail "counter failed on a plain home: $out"
  printf '%s\n' "$out" | grep -Fx 'captain_questions: open=3 parked=2 cap=none at_cap=no exact=yes' >/dev/null \
    || fail "wrong summary line for live, aged, dated and blocked holds: $out"
  printf '%s\n' "$out" | grep -Fx 'home main: open=3 parked=2 exact=yes' >/dev/null \
    || fail "main home line missing or wrong: $out"
  for call in 'main/gated-work live' 'main/live-call live' 'main/aged-call aged' \
    'main/dated-call dated' 'main/blocked-call blocked'; do
    printf '%s\n' "$out" | grep -F "call $call:" >/dev/null || fail "call '$call' not listed: $out"
  done
  for id in other-work external-wait answered-call; do
    printf '%s\n' "$out" | grep -F "/$id " >/dev/null && fail "$id is not an open captain call but was listed: $out"
  done
  pass "fm-captain-questions: live and aged holds are open, dated and blocked are parked, other rows are ignored"
}

test_json_is_the_same_model() {
  local home json
  home=$(make_home json-home)
  write_main_backlog "$home"
  json=$(run_counter "$home" --json) || fail "counter --json failed: $json"
  printf '%s\n' "$json" | jq -e '
    .schema == "fm-captain-questions.v1"
    and .open == 3 and .parked == 2 and .cap == null and .at_cap == false and .exact == true
    and (.homes == [{id:"main",open:3,parked:2,exact:true}])
    and (.unmeasured == [])
    and ([.calls[] | select(.home == "main") | .id] | sort
         == ["aged-call","blocked-call","dated-call","gated-work","live-call"])
    and ([.calls[] | select(.id == "live-call") | .title][0] == "Choose the route")
  ' >/dev/null || fail "JSON model disagrees with the text count: $json"
  pass "fm-captain-questions: --json carries the same count as the text output"
}

test_home_cap_is_reported() {
  local home out
  home=$(make_home cap-home)
  write_main_backlog "$home"
  printf '3\n' > "$home/config/captain-question-cap"
  out=$(run_counter "$home") || fail "counter failed with a cap: $out"
  printf '%s\n' "$out" | grep -Fx 'captain_questions: open=3 parked=2 cap=3 at_cap=yes exact=yes' >/dev/null \
    || fail "an open count equal to the cap must read at_cap=yes: $out"
  printf '2\n' > "$home/config/captain-question-cap"
  out=$(run_counter "$home") || fail "counter failed with a cap: $out"
  printf '%s\n' "$out" | grep -F 'cap=2 at_cap=yes' >/dev/null || fail "an open count over the cap must read at_cap=yes: $out"
  printf '16\n' > "$home/config/captain-question-cap"
  out=$(run_counter "$home" --json) || fail "counter --json failed with a cap: $out"
  printf '%s\n' "$out" | jq -e '.cap == 16 and .at_cap == false' >/dev/null \
    || fail "an open count under the cap must read at_cap=false: $out"
  pass "fm-captain-questions: the home cap is read and at_cap compares the open count against it"
}

test_malformed_cap_is_refused() {
  local home value out rc
  home=$(make_home bad-cap-home)
  write_main_backlog "$home"
  for value in '0' 'abc' '3 4' '' '-2'; do
    printf '%s\n' "$value" > "$home/config/captain-question-cap"
    out=$(run_counter "$home" 2>&1); rc=$?
    expect_code 2 "$rc" "malformed cap '$value' must be refused (got: $out)"
    printf '%s\n' "$out" | grep -F 'captain-question-cap' >/dev/null \
      || fail "refusal for cap '$value' did not name the file: $out"
    printf '%s\n' "$out" | grep -F 'captain_questions:' >/dev/null \
      && fail "a malformed cap must not print a count: $out"
  done
  pass "fm-captain-questions: a malformed cap is refused rather than defaulted"
}

test_secondmate_captain_holds_are_counted() {
  local home out
  home=$(make_home fleet-home)
  write_main_backlog "$home"
  write_mate "$home" mate-a '[]'
  out=$(run_counter "$home") || fail "counter failed with a secondmate: $out"
  printf '%s\n' "$out" | grep -Fx 'captain_questions: open=5 parked=3 cap=none at_cap=no exact=yes' >/dev/null \
    || fail "secondmate captain holds were not added to the fleet count: $out"
  printf '%s\n' "$out" | grep -Fx 'home mate-a: open=2 parked=1 exact=yes' >/dev/null \
    || fail "secondmate home line missing or wrong: $out"
  printf '%s\n' "$out" | grep -F 'call mate-a/mate-live live:' >/dev/null \
    || fail "secondmate live call not listed once from its summary: $out"
  [ "$(printf '%s\n' "$out" | grep -c 'call mate-a/mate-live ')" -eq 1 ] \
    || fail "a hold listed in both summary surfaces must count once: $out"
  printf '%s\n' "$out" | grep -F 'mate-task' >/dev/null \
    && fail "a child's needs-decision is the secondmate's to handle, not a captain call: $out"
  pass "fm-captain-questions: a secondmate's published captain holds count once each"
}

test_partial_secondmate_counts_are_lower_bounds() {
  local home out
  home=$(make_home partial-home)
  write_main_backlog "$home"
  write_mate "$home" mate-cut '[{"surface":"queued","count":7}]'
  out=$(run_counter "$home") || fail "counter failed with a truncated secondmate: $out"
  printf '%s\n' "$out" | grep -F 'exact=no' >/dev/null || fail "a truncated summary must make the count a lower bound: $out"
  printf '%s\n' "$out" | grep -Fx 'home mate-cut: open=2 parked=1 exact=no' >/dev/null \
    || fail "the truncated home must be marked inexact: $out"

  home=$(make_home unreadable-home)
  write_main_backlog "$home"
  write_mate "$home" mate-gone '[]'
  rm -f "$TMP_ROOT/mate-gone-home/state/home-summary.json"
  out=$(run_counter "$home") || fail "counter failed with an unreadable secondmate: $out"
  printf '%s\n' "$out" | grep -Fx 'captain_questions: open=3 parked=2 cap=none at_cap=no exact=no' >/dev/null \
    || fail "an unreadable secondmate must leave the main count and mark it inexact: $out"
  printf '%s\n' "$out" | grep -F 'unmeasured mate-gone:' >/dev/null \
    || fail "an unreadable secondmate must be named as unmeasured: $out"
  pass "fm-captain-questions: truncated or unreadable secondmate summaries are disclosed as lower bounds"
}

test_unstructured_main_rows_make_the_count_a_lower_bound() {
  local home out
  home=$(make_home unstructured-home)
  write_main_backlog "$home"
  # A current row the backlog parser cannot structure may be a captain call
  # nobody can classify, so the main home's count is only a lower bound.
  awk '/^## Done$/ { print "- [ ] a free-form queued note nobody structured"; print "" } { print }' \
    "$home/data/backlog.md" > "$home/data/backlog.md.new" && mv "$home/data/backlog.md.new" "$home/data/backlog.md"
  out=$(run_counter "$home") || fail "counter failed with an unstructured main row: $out"
  printf '%s\n' "$out" | grep -Fx 'home main: open=3 parked=2 exact=no' >/dev/null \
    || fail "an unstructured current main row must mark the main home inexact: $out"
  printf '%s\n' "$out" | grep -F 'exact=no' | grep -F 'captain_questions:' >/dev/null \
    || fail "an unstructured current main row must make the fleet total a lower bound: $out"
  pass "fm-captain-questions: unstructured current main rows make the count a lower bound"
}

test_help_and_usage() {
  local out rc
  out=$("$COUNTER" --help) || fail "--help failed"
  printf '%s\n' "$out" | grep -F 'captain-question-cap' >/dev/null || fail "--help did not name the cap file: $out"
  printf '%s\n' "$out" | grep -F 'never accepted by silence' >/dev/null || fail "--help did not state the hard limits: $out"
  out=$("$COUNTER" --bogus 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown option must be a usage error (got: $out)"
  pass "fm-captain-questions: help names the cap and the hard limits; unknown options are refused"
}

test_counts_open_and_parked_calls_in_the_main_home
test_json_is_the_same_model
test_home_cap_is_reported
test_malformed_cap_is_refused
test_secondmate_captain_holds_are_counted
test_partial_secondmate_counts_are_lower_bounds
test_unstructured_main_rows_make_the_count_a_lower_bound
test_help_and_usage
