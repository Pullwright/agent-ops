#!/usr/bin/env bash
#
# test/constraint.test.sh — self-contained regression test for
# lib/constraint.sh's `constraint_classify` (docs/ROADMAP.md D21's "state
# the constraint" bullet, issue #609).
#
# What matters here:
#
#   three empty       no time-account data at all, an account present but
#   states            too thin a window to trust (below the minimum
#                      sample), and an account with a sufficient window but
#                      no candidate clearing the minimum share — all three
#                      read "insufficient-evidence" but for different,
#                      distinguishable reasons, never collapsed into one.
#   grow and shrink    a back-pressure-dominated account recommends raising
#   on equal footing   the cap; an idle-without-demand-dominated one
#                      recommends shrinking the fleet — both are ordinary
#                      "ok" verdicts, neither privileged over the other.
#   never the          a fixture whose largest bucket is `overhead` or
#   largest bucket     `coordinator-declined` idleness — neither a ranked
#                      candidate — must not be named the constraint merely
#                      for being the biggest number on the page.
#   two candidates      the human merge gate and the pipeline's own defect
#   permanently         rate report `not_evaluable_reason`/`depends_on` on
#   not evaluable       every single call, never flipping to evaluable.
#   pure function       no event reading, no network, no lock: every
#                        assertion here drives `constraint_classify` on a
#                        canned account object, never a log fixture.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/constraint.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/constraint.sh
. "$SCRIPT_DIR/lib/constraint.sh"

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

classify_of() {  # <account-json> [min_share [min_sample_seconds [cadence_bound_minutes]]]
  constraint_classify "$1" "${2:-0.3}" "${3:-14400}" "${4:-null}"
}

account_json() {  # window_from window_to expected_total idle_json eb_json totals_extra_json
  local from="$1" to="$2" total="$3" idle="$4" eb="$5" totals_extra="${6:-}"
  [[ -n "$totals_extra" ]] || totals_extra='{}'
  jq -nc --arg from "$from" --arg to "$to" --argjson total "$total" \
    --argjson idle "$idle" --argjson eb "$eb" --argjson extra "$totals_extra" \
    '{
      window: {from: $from, to: $to, seconds: 604800},
      nodes: ["n1","n2","n3"],
      expected_total_seconds: $total,
      totals: ({"idle-without-demand": 0} + $extra),
      idle_with_demand_by_cause: $idle,
      externally_blocked_by_cause: $eb
    }'
}

# --- Empty state 1: no time-account data at all -----------------------------

no_account='{"window":{"from":null,"to":null,"seconds":0},"nodes":[],"expected_total_seconds":0,"totals":{},"idle_with_demand_by_cause":{},"externally_blocked_by_cause":{}}'
out_none="$(classify_of "$no_account")"
assert_eq "no account: status is insufficient-evidence" \
  "insufficient-evidence" "$(jq -r '.status' <<<"$out_none")"
assert_eq "  ... reason is no-time-account-data" \
  "no-time-account-data" "$(jq -r '.insufficient_reason' <<<"$out_none")"
assert_eq "  ... names no leading candidate" \
  "null" "$(jq -c '.leading_candidate' <<<"$out_none")"
assert_eq "  ... the sentence itself says so, naming the missing record" \
  "true" "$(jq -r '.sentence | test("Insufficient evidence") and test("#597")' <<<"$out_none")"

# --- Empty state 2: account present, window too thin to trust ---------------

thin="$(account_json "2026-09-01T00:00:00Z" "2026-09-01T00:05:00Z" 300 \
  '{"awaiting-tick":300}' '{}')"
out_thin="$(classify_of "$thin" 0.3 14400)"
assert_eq "thin window: status is insufficient-evidence" \
  "insufficient-evidence" "$(jq -r '.status' <<<"$out_thin")"
assert_eq "  ... reason is window-below-minimum-sample" \
  "window-below-minimum-sample" "$(jq -r '.insufficient_reason' <<<"$out_thin")"
assert_eq "  ... names no leading candidate, however dominant awaiting-tick was" \
  "null" "$(jq -c '.leading_candidate' <<<"$out_thin")"
assert_eq "  ... the sentence states the observed sample against the minimum" \
  "true" "$(jq -r '.sentence | test("300") and test("14400")' <<<"$out_thin")"

# --- Empty state 3: sufficient window, but no candidate clears min share ----

diffuse="$(account_json "2026-09-01T00:00:00Z" "2026-09-08T00:00:00Z" 1814400 \
  '{"awaiting-tick":40000,"back-pressure":30000,"peer-claimed":20000,"coordinator-declined":10000}' \
  '{"usage-limit":10000}' '{"idle-without-demand":50000}')"
out_diffuse="$(classify_of "$diffuse" 0.3 14400)"
assert_eq "diffuse: status is insufficient-evidence" \
  "insufficient-evidence" "$(jq -r '.status' <<<"$out_diffuse")"
assert_eq "  ... reason is no-candidate-above-minimum-share" \
  "no-candidate-above-minimum-share" "$(jq -r '.insufficient_reason' <<<"$out_diffuse")"
assert_eq "  ... names no leading candidate" \
  "null" "$(jq -c '.leading_candidate' <<<"$out_diffuse")"
assert_eq "  ... the sentence names the largest observed candidate anyway, as context" \
  "true" "$(jq -r '.sentence | test("Node count")' <<<"$out_diffuse")"

# --- Grow case: back-pressure dominant --------------------------------------

grow="$(account_json "2026-09-01T00:00:00Z" "2026-09-08T00:00:00Z" 1814400 \
  '{"awaiting-tick":50000,"back-pressure":800000,"peer-claimed":30000,"coordinator-declined":20000}' \
  '{"usage-limit":5000}' '{"idle-without-demand":10000}')"
out_grow="$(classify_of "$grow" 0.3 14400)"
assert_eq "grow: status is ok" "ok" "$(jq -r '.status' <<<"$out_grow")"
assert_eq "  ... leading candidate is back-pressure" \
  "back-pressure" "$(jq -r '.leading_candidate' <<<"$out_grow")"
assert_eq "  ... its own share is 800000/1814400, rounded to 3 places" \
  "0.441" "$(jq -r '.candidates[] | select(.key=="back-pressure") | .share' <<<"$out_grow")"
assert_eq "  ... direction is grow" \
  "grow" "$(jq -r '.candidates[] | select(.key=="back-pressure") | .direction' <<<"$out_grow")"
assert_eq "  ... the sentence names it, its percentage and the recommendation" \
  "true" "$(jq -r '.sentence | test("back-pressure"; "i") and test("44%") and test("max_open_agent_prs")' <<<"$out_grow")"
assert_eq "  ... the effect is stated in node-seconds, labelled an upper bound" \
  "true" "$(jq -r '.sentence | test("800000s recoverable") and test("upper bound")' <<<"$out_grow")"

# --- Shrink case: idle-without-demand dominant, on equal footing with grow --

shrink="$(account_json "2026-09-01T00:00:00Z" "2026-09-08T00:00:00Z" 1814400 \
  '{"awaiting-tick":20000,"back-pressure":10000,"peer-claimed":15000,"coordinator-declined":5000}' \
  '{"usage-limit":1000}' '{"idle-without-demand":1200000}')"
out_shrink="$(classify_of "$shrink" 0.3 14400)"
assert_eq "shrink: status is ok" "ok" "$(jq -r '.status' <<<"$out_shrink")"
assert_eq "  ... leading candidate is node-count" \
  "node-count" "$(jq -r '.leading_candidate' <<<"$out_shrink")"
assert_eq "  ... direction is shrink" \
  "shrink" "$(jq -r '.candidates[] | select(.key=="node-count") | .direction' <<<"$out_shrink")"
assert_eq "  ... the sentence recommends running fewer nodes, in as many words" \
  "true" "$(jq -r '.sentence | test("fewer nodes")' <<<"$out_shrink")"
assert_eq "  ... never phrased as a resource being exhausted (idle-without-demand is the healthy zero)" \
  "true" "$(jq -r '.sentence | (test("exhaust"; "i") or test("out of"; "i")) | not' <<<"$out_shrink")"

# --- node-count folds BOTH peer-claimed contention and idle-without-demand --

peer_claimed_only="$(account_json "2026-09-01T00:00:00Z" "2026-09-08T00:00:00Z" 1814400 \
  '{"awaiting-tick":10000,"back-pressure":10000,"peer-claimed":900000,"coordinator-declined":5000}' \
  '{"usage-limit":1000}' '{"idle-without-demand":0}')"
out_pc="$(classify_of "$peer_claimed_only" 0.3 14400)"
assert_eq "peer-claimed contention alone also leads to node-count/shrink" \
  "node-count" "$(jq -r '.leading_candidate' <<<"$out_pc")"
assert_eq "  ... its seconds are peer-claimed's alone here (no idle-without-demand)" \
  "900000" "$(jq -r '.candidates[] | select(.key=="node-count") | .seconds' <<<"$out_pc")"

# --- coordinator-declined idleness never becomes a candidate on its own,
#     however large — it names no lever in the ranked six --------------------

declined_dominant="$(account_json "2026-09-01T00:00:00Z" "2026-09-08T00:00:00Z" 1814400 \
  '{"awaiting-tick":10000,"back-pressure":10000,"peer-claimed":10000,"coordinator-declined":1200000}' \
  '{"usage-limit":1000}' '{"idle-without-demand":0}')"
out_declined="$(classify_of "$declined_dominant" 0.3 14400)"
assert_eq "coordinator-declined dominance still abstains: no candidate captures it" \
  "insufficient-evidence" "$(jq -r '.status' <<<"$out_declined")"
assert_eq "  ... the largest ranked candidate share is thin (peer-claimed 10000/1814400)" \
  "no-candidate-above-minimum-share" "$(jq -r '.insufficient_reason' <<<"$out_declined")"

# --- model-capacity: usage-limit isolated from other externally-blocked
#     causes (github-budget must not inflate it) -----------------------------

model_cap="$(account_json "2026-09-01T00:00:00Z" "2026-09-08T00:00:00Z" 1814400 \
  '{"awaiting-tick":10000,"back-pressure":10000,"peer-claimed":10000,"coordinator-declined":5000}' \
  '{"usage-limit":700000,"github-budget":600000}' '{"idle-without-demand":0}')"
out_mc="$(classify_of "$model_cap" 0.3 14400)"
assert_eq "model-capacity: leading candidate is model-capacity" \
  "model-capacity" "$(jq -r '.leading_candidate' <<<"$out_mc")"
assert_eq "  ... its seconds are usage-limit's alone, github-budget excluded" \
  "700000" "$(jq -r '.candidates[] | select(.key=="model-capacity") | .seconds' <<<"$out_mc")"

# --- The two structurally-unevaluable candidates report so on every call ----

for fixture_name in none thin diffuse grow shrink pc declined mc; do
  out_var="out_$fixture_name"
  out="${!out_var}"
  assert_eq "$fixture_name: human-merge-gate is never evaluable" \
    "false #574" "$(jq -r '.candidates[] | select(.key=="human-merge-gate") | [(.evaluable|tostring), .depends_on] | join(" ")' <<<"$out")"
  assert_eq "$fixture_name: pipeline-defect-rate is never evaluable" \
    "false #596" "$(jq -r '.candidates[] | select(.key=="pipeline-defect-rate") | [(.evaluable|tostring), .depends_on] | join(" ")' <<<"$out")"
  assert_eq "$fixture_name: both non-evaluable candidates carry a not_evaluable_reason" \
    "2" "$(jq -r '[.candidates[] | select(.evaluable == false) | select(.not_evaluable_reason != null)] | length' <<<"$out")"
  assert_eq "$fixture_name: candidates always lists exactly six, fixed order" \
    '["cron-latency","back-pressure","node-count","model-capacity","human-merge-gate","pipeline-defect-rate"]' \
    "$(jq -c '[.candidates[].key]' <<<"$out")"
done

# --- cadence_bound_minutes is echoed back verbatim, purely informational ----

out_cadence="$(classify_of "$grow" 0.3 14400 15)"
assert_eq "cadence_bound_minutes is echoed back when given" \
  "15" "$(jq -r '.cadence_bound_minutes' <<<"$out_cadence")"
out_no_cadence="$(classify_of "$grow" 0.3 14400)"
assert_eq "cadence_bound_minutes is null when not given" \
  "null" "$(jq -c '.cadence_bound_minutes' <<<"$out_no_cadence")"

# --- min_share/min_sample_seconds are echoed back, so a reader can see what
#     gated the verdict without a second lookup ------------------------------

assert_eq "min_share is echoed back" "0.3" "$(jq -r '.min_share' <<<"$out_grow")"
assert_eq "min_sample_seconds is echoed back" "14400" "$(jq -r '.min_sample_seconds' <<<"$out_grow")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
