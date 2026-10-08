#!/usr/bin/env bash
#
# test/standdown-limit-probe.test.sh — regression test for the usage-limit
# probe's own stage-end (issue #2239, D30, lib/standdown.sh). The probe is
# deliberately not a stage — it logs no paired stage-start, and requirement
# 33's own exception list says so — but it still spends real tokens on a
# real `run_model_stage` launch, and until this event existed that spend
# reached the dashboard's cost scan but never log.jsonl's own per-stage
# ledger. This lifts the probe's own stage-end block verbatim out of
# lib/standdown.sh and asserts it carries `stage: "limit-probe"`, the real
# exit code, and the same metering record every other stage-end carries —
# `lane`, `cost_usd` and `tokens` included — exactly as `lib/metering.sh`'s
# `metering_fields` derives it (docs/METERING-SCHEMA.md).
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/standdown-limit-probe.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STANDDOWN="$SCRIPT_DIR/lib/standdown.sh"

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

# Lifted verbatim — from the probe's own run_model_stage launch through its
# stage-end's closing jq literal — so this test is about the shipped code,
# not a copy of its logic (the same technique test/stage-budget-apply-join-
# key.test.sh and its siblings use for their own extracted snippets).
probe_block="$(awk '
  index($0, "probe_out=\"$cycle_dir/limit-probe.out\"") { on = 1 }
  on { print }
  on && index($0, "stage: \"limit-probe\", exit_code: $rc") { exit }
' "$STANDDOWN")"
if [[ -z "$probe_block" || "$probe_block" != *'metering_fields'* ]]; then
  echo "FAIL - could not extract the limit-probe stage-end block from lib/standdown.sh — has it moved?" >&2
  exit 1
fi

# shellcheck source=lib/metering.sh
. "$SCRIPT_DIR/lib/metering.sh"

call_log="$(mktemp)"
trap 'rm -f "$call_log"' EXIT
log_event() { printf '%s\t%s\n' "$1" "$2" >> "$call_log"; }

# The stub stands in for a real run_model_stage launch: it writes a stage
# envelope and sets the two caller-visible globals a real run leaves (gaps,
# lane), exactly as lib/stage-run.sh's own run_model_stage does — this test
# is about what lib/standdown.sh does with those outputs, not about
# run_model_stage itself (test/stage-run.test.sh covers that seam directly).
run_model_stage() {
  local out_file="$5"
  jq -nc '{total_cost_usd: 0.002, duration_ms: 900, num_turns: 1, is_error: false,
           modelUsage: {"claude-haiku-4-5": {inputTokens: 20, outputTokens: 5,
             cacheCreationInputTokens: 0, cacheReadInputTokens: 0, costUSD: 0.002}}}' \
    > "$out_file"
  # shellcheck disable=SC2034  # read by the extracted probe_block, not visible here
  stage_gaps_json='{"n":1,"p50":2,"p95":2,"p99":2,"max":2}'
  # shellcheck disable=SC2034
  stage_lane_json='"api"'
  return "${STUB_RUN_RC:-0}"
}

run_probe() {  # run_probe <cycle_dir>
  ( cycle_dir="$1" implementer_model_trivial="claude-haiku-4-5" \
      stage_kill_reason="" \
    eval "$probe_block" )
}

cycle_dir="$(mktemp -d)"
trap 'rm -rf "$cycle_dir"; rm -f "$call_log"' EXIT

: > "$call_log"
STUB_RUN_RC=0 run_probe "$cycle_dir"
event="$(grep -m1 '^stage-end'$'\t' "$call_log" | cut -f2-)"

assert_eq "the probe logs exactly one stage-end" \
  "1" "$(grep -c '^stage-end'$'\t' "$call_log")"
assert_eq "...naming stage: limit-probe" \
  '"limit-probe"' "$(jq -c '.stage' <<<"$event")"
assert_eq "...with the real invocation's own exit_code" \
  "0" "$(jq -r '.exit_code' <<<"$event")"
assert_eq "...carrying the lane the stub run observed" \
  '"api"' "$(jq -c '.lane' <<<"$event")"
assert_eq "...carrying the stub envelope's own cost_usd" \
  "0.002" "$(jq -r '.cost_usd' <<<"$event")"
assert_eq "...carrying the stub envelope's own tokens" \
  '{"input":20,"output":5,"cache_creation":0,"cache_read":0}' \
  "$(jq -c '.tokens' <<<"$event")"
assert_eq "...and no kill_reason, since the stub run was not killed" \
  "false" "$(jq -c 'has("kill_reason")' <<<"$event")"

: > "$call_log"
STUB_RUN_RC=124 run_probe "$cycle_dir"
event="$(grep -m1 '^stage-end'$'\t' "$call_log" | cut -f2-)"
assert_eq "a killed probe's stage-end still carries the real (non-zero) exit_code" \
  "124" "$(jq -r '.exit_code' <<<"$event")"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
