#!/usr/bin/env bash
#
# test/rebase-only-wiring.test.sh — regression test for the three blocks
# agent-cycle.sh adds for requirement 31e (agent-ops#1806): a `merge-conflicts`
# item's rebase-only push must skip the Reviewer *engagement* for this cycle —
# and only the engagement, since the Approver round and the arming step below
# it still have to run, GitHub having dismissed the standing approval on the
# push whatever the patch-id said.
#
#   - **The pre-capture block** (step 6b, just ahead of "--- 7. Implementer
#     stage ---"): `premerge_rebase_only_capture` records the pull request's
#     pre-push head and base SHAs — but only for a `merge-conflicts` work
#     order that is not a Dependabot takeover, and only once the work order's
#     own `base` resolves to a real ref.
#   - **The stage-start advisory block** (just inside "--- 8. Reviewer stage
#     ---", right after the existing #916 merge-state check): compares the
#     pre-push diff against the post-push one by patch-id, reading both heads
#     from `origin` so the question stays "did the push change the diff",
#     and settles `$rebase_only`.
#   - **The engagement block**: acts on `$rebase_only` — skipping
#     `stage_budget_apply`/`run_claude_stage` and synthesising a `ready`
#     verdict for the handoff path below, or running the engagement for real.
#
# All three blocks are lifted verbatim out of agent-cycle.sh, the same technique
# test/reviewer-merge-observed-wiring.test.sh already uses: the assertions are
# about the shipped code, not a copy of its logic. `rebase_only_push` and
# `log_event` are stubbed as recorders — `rebase_only_push` itself is
# unit-tested on its own terms in test/rebase-only.test.sh — so this file owns
# only the thinner question: given each shape those can return, does
# agent-cycle.sh's own dispatch do the right thing with it?
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/rebase-only-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.
#
# shellcheck disable=SC2016
# This file's whole business is assembling scripts whose `$`-expressions must
# reach the assembled file unexpanded; the single-quoted patterns and printf
# templates below are deliberate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/agent-cycle.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:             %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# extract_block START_PATTERN MARKER_PATTERN FILE
# Turns on at START_PATTERN, prints every line while on, and stops at the
# first bare "fi" line seen *after* MARKER_PATTERN.
extract_block() {
  local start="$1" marker="$2" file="$3"
  awk -v start="$start" -v marker="$marker" '
    $0 ~ start { on = 1 }
    on { print }
    on && seen && /^fi$/ { exit }
    on && $0 ~ marker { seen = 1 }
  ' "$file"
}

# extract_to_call START_PATTERN CALL_PATTERN FILE
# Turns on at START_PATTERN, prints every line while on, and stops right
# after the first line matching CALL_PATTERN — for a flat function-definition
# plus one-line call, which carries no closing "fi" of its own to stop at.
extract_to_call() {
  local start="$1" call="$2" file="$3"
  awk -v start="$start" -v call="$call" '
    $0 ~ start { on = 1 }
    on { print }
    on && $0 ~ call { exit }
  ' "$file"
}

capture_block="$(extract_to_call \
  '^premerge_old_head=""; premerge_old_base=""; premerge_base_name=""$' \
  '^premerge_rebase_only_capture$' \
  "$CYCLE")"

advisory_block="$(extract_to_call \
  '^rebase_only_new_head=""; rebase_only_new_base=""$' \
  '^rebase_only_advisory_check && rebase_only=' \
  "$CYCLE")"

engagement_block="$(extract_block \
  '^# Requirement 31e: the engagement itself is what a confirmed rebase-only push$' \
  'reviewer-carried-forward' \
  "$CYCLE")"

for pair in "capture:$capture_block" "advisory:$advisory_block" "engagement:$engagement_block"; do
  if [[ -z "${pair#*:}" ]]; then
    echo "FAIL - could not extract the ${pair%%:*} block from agent-cycle.sh — has it moved?" >&2
    exit 1
  fi
done

# --- The pre-capture block: stub git, run against each work-order shape ------

run_capture() {  # SELECTED_SOURCE TAKEOVER BASE_FIELD [ls-remote output style]
  local selected_source="$1" takeover="$2" base_field="$3"
  cat >"$tmp_dir/capture-harness.sh" <<HARNESS
set -uo pipefail
selected_source="$selected_source"
selected_branch="agent/td-42"
clone_dir="/no/such/clone"
work_order_json='$(jq -nc --arg t "$takeover" --arg b "$base_field" \
  '{takeover: ($t == "true"), base: (if $b == "" then null else $b end)}')'
git() {
  if [[ "\$1" == "-C" && "\$3" == "ls-remote" ]]; then
    case "\$5" in
      *"agent/td-42") printf 'oldheadsha\trefs/heads/agent/td-42\n' ;;
      *"main") printf 'oldbasesha\trefs/heads/main\n' ;;
      *) return 1 ;;
    esac
    return 0
  fi
  return 1
}
$capture_block
printf 'head=%s\tbase=%s\tbase_name=%s\n' "\$premerge_old_head" "\$premerge_old_base" "\$premerge_base_name"
HARNESS
  bash "$tmp_dir/capture-harness.sh"
}

out="$(run_capture "merge-conflicts" "false" "main")"
assert_eq "a merge-conflicts, non-takeover item with a resolvable base captures both SHAs" \
  "head=oldheadsha	base=oldbasesha	base_name=main" "$out"

out="$(run_capture "merge-conflicts" "true" "main")"
assert_eq "a Dependabot takeover captures nothing — it is ordinary fresh work" \
  "head=	base=	base_name=" "$out"

out="$(run_capture "issues" "false" "main")"
assert_eq "a non-merge-conflicts source captures nothing" \
  "head=	base=	base_name=" "$out"

out="$(run_capture "merge-conflicts" "false" "")"
assert_eq "a merge-conflicts item with no base field captures nothing" \
  "head=	base=	base_name=" "$out"

# --- The stage-start advisory block: stub rebase_only_push, record its args --

run_advisory() {  # OLD_HEAD OLD_BASE IMPL_PR_URL PUSH_RESULT(true|false) NEW_HEAD
  local old_head="$1" old_base="$2" pr_url="$3" push_result="$4" new_head="${5:-newheadsha}"
  cat >"$tmp_dir/advisory-harness.sh" <<HARNESS
set -uo pipefail
premerge_old_head="$old_head"
premerge_old_base="$old_base"
premerge_base_name="main"
selected_branch="agent/td-42"
impl_pr_url="$pr_url"
selected_repo="acme/widgets"
selected_item="42"
clone_dir="/no/such/clone"
git() {
  if [[ "\$1" == "-C" && "\$3" == "rev-parse" ]]; then
    printf 'worktreeheadsha\n' >>"$tmp_dir/rev-parse-calls"; printf 'worktreeheadsha\n'; return 0
  fi
  if [[ "\$1" == "-C" && "\$3" == "ls-remote" ]]; then
    case "\$5" in
      *"agent/td-42") printf '$new_head\trefs/heads/agent/td-42\n' ;;
      *"main") printf 'newbasesha\trefs/heads/main\n' ;;
      *) return 1 ;;
    esac
    return 0
  fi
  if [[ "\$1" == "-C" && "\$3" == "fetch" ]]; then
    return 0
  fi
  return 1
}
rebase_only_push() {
  printf '%s\n' "\$*" >>"$tmp_dir/push-calls"
  case "$push_result" in
    true) return 0 ;;
    *) return 1 ;;
  esac
}
$advisory_block
printf 'rebase_only=%s\n' "\$rebase_only"
HARNESS
  bash "$tmp_dir/advisory-harness.sh"
}

: >"$tmp_dir/push-calls"; : >"$tmp_dir/rev-parse-calls"
out="$(run_advisory "oldheadsha" "oldbasesha" "https://github.com/acme/widgets/pull/42" "true")"
assert_eq "a confirmed rebase-only push settles rebase_only=true" "rebase_only=true" "$out"
assert_contains "  ... comparing the pre-push pair against the post-push pair" \
  "oldbasesha oldheadsha newbasesha newheadsha" "$(cat "$tmp_dir/push-calls")"
assert_eq "  ... reading the post-push head from origin, never the clone's own HEAD" \
  "" "$(cat "$tmp_dir/rev-parse-calls")"

: >"$tmp_dir/push-calls"
out="$(run_advisory "oldheadsha" "oldbasesha" "https://github.com/acme/widgets/pull/42" "false")"
assert_eq "a push whose diff genuinely changed settles rebase_only=false" "rebase_only=false" "$out"

: >"$tmp_dir/push-calls"
out="$(run_advisory "oldheadsha" "oldbasesha" "https://github.com/acme/widgets/pull/42" "true" "oldheadsha")"
assert_eq "an unmoved head is no push at all, never a rebase-only one" "rebase_only=false" "$out"
assert_eq "  ... and is not even asked about" "" "$(cat "$tmp_dir/push-calls")"

: >"$tmp_dir/push-calls"
out="$(run_advisory "" "" "https://github.com/acme/widgets/pull/42" "true")"
assert_eq "no pre-capture (not a merge-conflicts item) settles false without even asking" \
  "rebase_only=false" "$out"
assert_eq "  ... and is not even asked about" "" "$(cat "$tmp_dir/push-calls")"

# --- The engagement block: does $rebase_only actually skip the model call? ---

run_engagement() {  # REBASE_ONLY(true|false)
  local rebase_only="$1"
  : >"$tmp_dir/events"; : >"$tmp_dir/calls"
  cat >"$tmp_dir/engagement-harness.sh" <<HARNESS
set -uo pipefail
rebase_only="$rebase_only"
selected_repo="acme/widgets"
selected_item="42"
impl_pr_url="https://github.com/acme/widgets/pull/42"
premerge_old_head="oldheadsha"
rebase_only_new_head="newheadsha"
rev_complexity="medium"
rev_model="a-model"
reviewer_prompt="the reviewer prompt"
rev_out="$tmp_dir/reviewer.out"
clone_dir="/no/such/clone"
stage_backstop_min=90
stage_inactivity_min=15
stage_kill_reason=""
stage_gaps_json='{}'
ONCE=0
log_event() { printf '%s\t%s\n' "\$1" "\$2" >>"$tmp_dir/events"; }
stage_budget_apply() { printf 'stage_budget_apply\n' >>"$tmp_dir/calls"; }
run_claude_stage() { printf 'run_claude_stage\n' >>"$tmp_dir/calls"; return 0; }
metering_fields() { printf '{}'; }
rework_stage_rerun_maybe() { :; }
log_node_state_transition() { :; }
stage_watchdog_warning() { printf ''; }
dump_stage_output() { :; }
extract_json_result() { printf '{"status":"ready","ci":"from a real engagement"}'; }
stage_salvage_result() { printf ''; }
$engagement_block
printf 'rc=%s json=%s\n' "\$rev_rc" "\$rev_status_json"
HARNESS
  bash "$tmp_dir/engagement-harness.sh"
}

out="$(run_engagement "true")"
assert_eq "a rebase-only push never runs the Reviewer engagement" "" "$(cat "$tmp_dir/calls")"
assert_contains "  ... logging reviewer-carried-forward instead" \
  "reviewer-carried-forward" "$(cat "$tmp_dir/events")"
assert_contains "  ... naming rebase_only: true" '"rebase_only":true' "$(cat "$tmp_dir/events")"
assert_contains "  ... the pull request's own url" '"pr_url":"https://github.com/acme/widgets/pull/42"' \
  "$(cat "$tmp_dir/events")"
assert_eq "  ... and no stage-end event, since no stage ran" \
  "" "$(grep -c 'stage-end' "$tmp_dir/events" | sed 's/^0$//')"
assert_contains "  ... synthesising a ready verdict for the handoff path below" \
  '"status":"ready"' "$out"
assert_contains "  ... whose ci field names the requirement it came from" \
  "requirement 31e" "$out"
assert_contains "  ... at exit code 0, so handle_stage_failure never fires" "rc=0" "$out"

out="$(run_engagement "false")"
assert_contains "a push whose diff changed runs the engagement for real" \
  "run_claude_stage" "$(cat "$tmp_dir/calls")"
assert_contains "  ... charging the stage budget for it" \
  "stage_budget_apply" "$(cat "$tmp_dir/calls")"
assert_contains "  ... logging stage-end" "stage-end" "$(cat "$tmp_dir/events")"
assert_eq "  ... and never logging reviewer-carried-forward" \
  "" "$(grep -c 'reviewer-carried-forward' "$tmp_dir/events" | sed 's/^0$//')"
assert_contains "  ... taking its verdict from the stage's own output" \
  "from a real engagement" "$out"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
