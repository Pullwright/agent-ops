#!/usr/bin/env bash
#
# test/stage-lane-frozen-fallthrough.test.sh — regression test for #2242's
# own first acceptance criterion: "with a frozen anthropic/subscription
# record, a stage on anthropic runs on api". That behaviour lives entirely
# in `stage_lane_frozen` and the two lines it adds to `stage_lane_draw`
# (lib/stage-run.sh) — real code, called through its real entry points,
# never lifted or stubbed — and until now nothing exercised it: every other
# suite that calls `stage_lane_draw` sources lib/stage-run.sh without
# lib/limit-detect.sh, so `stage_lane_frozen` ran as its own permissive
# fallback the whole time and the exclusion was invisible to CI.
#
# lib/stage-run.sh is sourced *before* lib/limit-detect.sh here, the
# opposite of every production entry point (agent-cycle.sh, review-cycle.sh,
# monitor-cycle.sh) — deliberately, to prove `stage_lane_frozen`'s
# source-order independence: the `declare -F limit_governing_record_for`
# check that chooses its real behaviour over the permissive fallback lives
# inside the function body (evaluated on every call), not in a one-time
# choice between two definitions made at source time, so which of the two
# files is sourced first makes no difference to what it does.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/stage-lane-frozen-fallthrough.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

declare -gA PROVIDER_SUBSTRATE=()
declare -gA PROVIDER_LANES=()

# shellcheck source=lib/stage-run.sh
. "$SCRIPT_DIR/lib/stage-run.sh"
# shellcheck source=lib/limit-detect.sh
. "$SCRIPT_DIR/lib/limit-detect.sh"

# No fleet flag in force for any of this file's scenarios — the union log
# alone carries the governing record. Never sourced from lib/toggle.sh, so
# this stays a two-file test.
# shellcheck disable=SC2317,SC2329  # called by limit_governing_record_for, invisible to a static reader
fleet_flag_fetch() { :; }

PROVIDER_SUBSTRATE[anthropic]=claude-code
# Both lanes present and open: `stage_lane_draw`'s own fallback-to-the-other-
# lane only means something when both were open before this issue's freeze
# exclusion narrows one of them away.
export ANTHROPIC_API_KEY="sk-ant-test-placeholder"
sub_present_dir="$(mktemp -d)"
printf '{}' > "$sub_present_dir/.credentials.json"
export CLAUDE_CONFIG_DIR="$sub_present_dir"
PROVIDER_LANES[anthropic]='{"api":{"weight":1,"enabled":true},"subscription":{"weight":1,"enabled":true}}'

cycle_dir="$(mktemp -d)"
union_log="$cycle_dir/union.jsonl"
state_repo="test-repo"
state_dir=""
trap 'rm -rf "$cycle_dir" "$sub_present_dir"' EXIT

write_union() {  # write_union <lane> <resume_at>
  local lane="$1" resume_at="$2"
  jq -nc --arg l "$lane" --arg r "$resume_at" \
    '{ts:"2026-11-22T00:00:00Z", event:"limit-hit", provider:"anthropic",
       lane:$l, resume_at:$r, kind:"auto", reset_known:false}' > "$union_log"
}

: > "$union_log"
assert_eq "with no limit in force, neither lane reads frozen" \
  "1 1" "$(stage_lane_frozen anthropic api; echo -n "$? "; stage_lane_frozen anthropic subscription; echo -n "$?")"

write_union subscription "2099-01-01T00:00:00Z"
for i in 1 2 3 4 5; do
  assert_eq "a frozen anthropic/subscription record sends seed $i to api" \
    "api" "$(stage_lane_draw anthropic claude-code "fallthrough-seed-$i")"
done
assert_eq "...and stage_lane_frozen itself agrees: subscription is frozen" \
  "0" "$(stage_lane_frozen anthropic subscription; echo -n "$?")"
assert_eq "...while api is not" \
  "1" "$(stage_lane_frozen anthropic api; echo -n "$?")"

write_union api "2099-01-01T00:00:00Z"
for i in 1 2 3; do
  assert_eq "a frozen anthropic/api record sends seed $i to subscription" \
    "subscription" "$(stage_lane_draw anthropic claude-code "fallthrough-seed-$i")"
done

write_union subscription "2000-01-01T00:00:00Z"
assert_eq "a lapsed resume_at in the past does not exclude the lane" \
  "1" "$(stage_lane_frozen anthropic subscription; echo -n "$?")"

if (( failures > 0 )); then
  printf '\n%s assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nAll assertions passed\n'
