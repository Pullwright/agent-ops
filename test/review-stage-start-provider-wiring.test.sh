#!/usr/bin/env bash
#
# test/review-stage-start-provider-wiring.test.sh — regression test for
# `review-stage-start` naming the provider beside the model (issue #2136):
# not whether `MODEL_PROVIDER` resolution itself is correct
# (test/model-id.test.sh covers that) but whether review_one's own
# `review-stage-start` log_event call reads it and includes `provider`
# alongside `model`, the way `review-stage-end` already does through
# `lib/metering.sh`'s `metering_fields` (issue #2133).
#
# The block is lifted verbatim out of review_one in review-cycle.sh, the way
# test/review-repo-labels-wiring.test.sh lifts its own, so the assertions are
# about the shipped code rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/review-stage-start-provider-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVIEW_CYCLE="$SCRIPT_DIR/review-cycle.sh"

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

# --- Lift the review-stage-start block whole out of review_one --------------
start_block="$(awk '
  /^  local review_budget_overrides review_budget review_backstop_min review_inactivity_min$/ { on = 1 }
  on                        { print }
  on && /review_context_sources: \$rcs\}.*\)"$/ { exit }
' "$REVIEW_CYCLE")"
# shellcheck disable=SC2016  # matching a literal jq fragment, not expanding one
if [[ "$start_block" != *'log_event "review-stage-start"'* || "$start_block" != *'provider: $p'* ]]; then
  echo "FAIL - could not extract the review-one review-stage-start block from review-cycle.sh (moved or reworded?)" >&2
  exit 1
fi

# --- Stub: log_event, and the helpers the block calls to build the event ----
call_log="$(mktemp)"
trap 'rm -f "$call_log"' EXIT
# shellcheck disable=SC2317  # invoked only by the eval'd start_block
log_event() { printf 'EVENT %s %s\n' "$1" "$2" >> "$call_log"; }
# shellcheck disable=SC2317  # invoked only by the eval'd start_block
stage_budget_resolve() { printf '{"backstop_min": 150, "inactivity_min": 10}\n'; }
# shellcheck disable=SC2317  # invoked only by the eval'd start_block
metering_intended_lane() { printf 'default\n'; }

run_block() {  # <slug> <model> <provider>
  (
    declare -gA MODEL_PROVIDER=()
    # Consumed only by the eval'd start_block, invisible to shellcheck.
    # shellcheck disable=SC2034
    [[ -n "$3" ]] && MODEL_PROVIDER["$2"]="$3"
    # Every one of these is consumed only by the eval'd start_block, invisible
    # to shellcheck.
    # shellcheck disable=SC2034
    entry='{"timeout_review": null, "inactivity_review": null}' \
      slug="$1" model="$2" review_context_sources='[]' \
      stage_budget_json='{}' STAGE_BUDGET_PRIORS='{"project-reviewer": {"backstop": 150, "inactivity": 10}}' \
      STAGE_MODEL_SET_EXTRA_JSON='{}'
    eval "$start_block"
  )
}

: > "$call_log"
run_block "o/r" "grok-build-0.1" "xai"
event_line="$(grep '^EVENT review-stage-start' "$call_log")"
assert_eq "exactly one review-stage-start event is logged" "1" \
  "$(grep -c '^EVENT review-stage-start' "$call_log")"
assert_eq "it names the configured xAI model" "1" \
  "$(grep -c '"model":"grok-build-0.1"' <<<"$event_line")"
assert_eq "  ... and the provider that model resolved to, beside it" "1" \
  "$(grep -c '"provider":"xai"' <<<"$event_line")"

: > "$call_log"
run_block "o/other" "claude-sonnet-5" ""
event_line="$(grep '^EVENT review-stage-start' "$call_log")"
assert_eq "a model MODEL_PROVIDER never recorded (e.g. a bare Claude id) still logs" "1" \
  "$(grep -c '"model":"claude-sonnet-5"' <<<"$event_line")"
assert_eq "  ... falling back to anthropic rather than an empty provider" "1" \
  "$(grep -c '"provider":"anthropic"' <<<"$event_line")"

echo
if (( failures == 0 )); then
  echo "All review-stage-start-provider-wiring assertions passed."
  exit 0
else
  echo "$failures review-stage-start-provider-wiring assertion(s) FAILED."
  exit 1
fi
