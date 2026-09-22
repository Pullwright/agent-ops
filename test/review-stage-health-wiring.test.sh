#!/usr/bin/env bash
#
# test/review-stage-health-wiring.test.sh — regression test for the
# review-cycle.sh half of agent-ops#996: the repository-review pipeline's own
# stage-health verdict, symmetric with the implementation pipeline's (issue
# #662). Not whether `stage_health_verdicts`/`stage_health_write_status`
# compute correctly (test/stage-health.test.sh covers that in full) but
# whether review-cycle.sh feeds them the right events and calls them with the
# right arguments — the wiring, the same division every other
# `*-wiring.test.sh` in this directory draws.
#
# Three things this guards, each silently reopening the gap #996 exists to
# close if lost:
#
#   review-stage-end/review-attempt-failed carry `stage`   lib/stage-health.sh
#     filters on `.stage`; an event missing it reads as belonging to no
#     stage at all, and `project-reviewer` would sit `idle` forever however
#     many runs actually happened.
#   the `cycle` field is per (review id, repo), not the bare review id
#     a single review-cycle.sh run can review several repos under one
#     `review_id` (the while-loop in review-cycle.sh) — sharing the bare id
#     would let lib/stage-health.sh's own cycle-keyed exit-0-but-failed join
#     (TD-PPagop-26082504) attach one repo's genuine failure detail to
#     another repo's success.
#   review-attempt-failed carries `stage_failure: true`   without it, the
#     exit-0-but-failed join (a `review-stage-end` with `exit_code: 0` but a
#     "reviewer returned no usable completion" verdict) never counts as a
#     failure at all — issue #1511's implementation-pipeline lesson, applied
#     here for the first time.
#
# The two log_event call sites are lifted whole out of review-cycle.sh (the
# same `awk` extraction test/review-repo-labels-wiring.test.sh and
# test/stage-health.test.sh's own `stage_health_status_report` check use), so
# these assertions are about the shipped code rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/review-stage-health-wiring.test.sh
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

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual: %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- Lift the review-stage-end log_event call whole out of review_one -------
stage_end_block="$(awk '
  /^  log_event "review-stage-end"/ { on = 1 }
  on                                { print }
  on && /\+ \$m.\)"$/               { exit }
' "$REVIEW_CYCLE")"
if [[ -z "$stage_end_block" || "$stage_end_block" != *'stage: "project-reviewer"'* ]]; then
  echo "FAIL - could not extract the review-stage-end log_event call from review-cycle.sh (moved or reworded?)" >&2
  exit 1
fi

# --- Lift the review-attempt-failed (reviewer-stage) log_event call --------
attempt_failed_block="$(awk '
  /^    log_event "review-attempt-failed" "\$\(jq -nc --arg r "\$slug" --arg d "\$detail"/ { on = 1 }
  on                                 { print }
  on && /stage_failure: true\}.\)"$/ { exit }
' "$REVIEW_CYCLE")"
if [[ -z "$attempt_failed_block" || "$attempt_failed_block" != *'stage_failure: true'* ]]; then
  echo "FAIL - could not extract the reviewer-stage review-attempt-failed log_event call from review-cycle.sh (moved or reworded?)" >&2
  exit 1
fi

# --- Stub log_event and metering_fields, eval each block in isolation ------
call_log="$(mktemp)"
trap 'rm -f "$call_log"' EXIT
# shellcheck disable=SC2317  # invoked only by the eval'd blocks
log_event() { printf '%s\t%s\n' "$1" "$2" >> "$call_log"; }
# shellcheck disable=SC2317  # invoked only by the eval'd stage_end_block
metering_fields() { printf '{"model":"%s"}' "$1"; }

: > "$call_log"
( review_id="20260922T170650Z-n1-42" slug="o/r" rc=1 stage_kill_reason="" \
    model="claude-sonnet-5" out_file="/dev/null" stage_gaps_json="null" \
  eval "$stage_end_block" )
fields_json="$(cut -f2 "$call_log")"
assert_eq "review-stage-end names the shared event" \
  "review-stage-end" "$(cut -f1 "$call_log")"
assert_eq "  ... and carries stage: project-reviewer, for lib/stage-health.sh's stage filter" \
  "project-reviewer" "$(jq -r '.stage' <<<"$fields_json")"
assert_eq "  ... and a cycle keyed by (review id, repo), not the bare review id" \
  "20260922T170650Z-n1-42:o/r" "$(jq -r '.cycle' <<<"$fields_json")"
assert_eq "  ... and the repo and exit_code review-log.jsonl's other consumers already read" \
  "o/r 1" "$(jq -r '.repo, .exit_code' <<<"$fields_json" | tr '\n' ' ' | sed 's/ $//')"

: > "$call_log"
( review_id="20260922T170650Z-n1-42" slug="o/r" detail="reviewer returned no usable completion" \
  eval "$attempt_failed_block" )
fields_json="$(cut -f2 "$call_log")"
assert_eq "review-attempt-failed (reviewer stage) names the shared event" \
  "review-attempt-failed" "$(cut -f1 "$call_log")"
assert_eq "  ... and carries stage: project-reviewer, matching review-stage-end's own" \
  "project-reviewer" "$(jq -r '.stage' <<<"$fields_json")"
assert_eq "  ... and the same (review id, repo) cycle as its matching review-stage-end" \
  "20260922T170650Z-n1-42:o/r" "$(jq -r '.cycle' <<<"$fields_json")"
assert_eq "  ... and stage_failure: true — this call only ever fires on a genuine attempt failure" \
  "true" "$(jq -r '.stage_failure' <<<"$fields_json")"

# --- The cleanup() trap computes and writes the verdict, not the implementation
#     pipeline's own .stage-health.json ---------------------------------------
cleanup_block="$(awk '
  /^cleanup\(\) \{$/ { on = 1 }
  on                 { print }
  on && /^\}$/       { exit }
' "$REVIEW_CYCLE")"
if [[ -z "$cleanup_block" || "$cleanup_block" != *'stage_health_write_status'* ]]; then
  echo "FAIL - could not extract cleanup() from review-cycle.sh (moved or reworded?)" >&2
  exit 1
fi
# shellcheck disable=SC2016  # matching review-cycle.sh's own literal source text, not expanding it
assert_contains "cleanup() computes the verdict from this run's own review_log_file" \
  "$cleanup_block" 'stage_health_write_status "$state_dir" "$review_log_file"'
assert_contains "  ... narrowed to this pipeline's one stage" \
  "$cleanup_block" '["project-reviewer"]'
assert_contains "  ... over this stream's own event names, not the shared stage-end/attempt-failed" \
  "$cleanup_block" 'review-stage-end review-attempt-failed'
assert_contains "  ... into its own status file, never the implementation pipeline's .stage-health.json" \
  "$cleanup_block" '.review-stage-health.json'
# Ordering matters (see the call's own comment): the verdict must be computed
# and written before the state-sync push reads it into the heartbeat.
# shellcheck disable=SC2016  # matching review-cycle.sh's own literal source text, not expanding it
verdict_line="$(grep -n 'stage_health_write_status "\$state_dir" "\$review_log_file"' "$REVIEW_CYCLE" | head -n1 | cut -d: -f1)"
push_line="$(grep -n 'scripts/state-sync.sh" push' "$REVIEW_CYCLE" | head -n1 | cut -d: -f1)"
assert_eq "the verdict is written before the state-sync push, not after" "1" \
  "$(( verdict_line < push_line ? 1 : 0 ))"

# --- lib/stage-health.sh is actually sourced, or all of the above is inert -
assert_contains "review-cycle.sh sources lib/stage-health.sh" \
  "$(grep -c 'source=lib/stage-health.sh' "$REVIEW_CYCLE")" "1"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
