#!/usr/bin/env bash
#
# test/enabler-refiner-refusal-fields.test.sh — the Enabler's and the
# Refiner's own best-effort `stage-end`/`warning` events now carry
# `api_refusal`/`api_message`/`api_refusal_class` (agent-ops#2308), the same
# three fields `handle_stage_failure` (lib/stage-attempt.sh) already attaches
# for the Co-Ordinator, Implementer and Reviewer. Neither the Enabler nor the
# Refiner routes through that function — both span repositories by
# construction, so neither ever pins a repo/item — which is why this needed
# its own wiring rather than being covered by test/coordinator-input-wiring.test.sh.
#
# Each block is lifted verbatim out of its own file (the same technique
# test/auth-failure-wiring.test.sh and test/standdown-credential-preflight.test.sh
# use), from the comment introducing the refusal read through the closing
# `stage-end` `log_event` call, so the assertions are about the shipped code.
# `stage_api_refusal`/`_class`/`_message` are the real functions from
# lib/stage-attempt.sh; `run_model_stage`/`log_event`/`metering_fields` are
# stubbed.
#
# Run directly: ./test/enabler-refiner-refusal-fields.test.sh — exit 0 iff
# all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

extract_block() {
  local start_re="$1" end_re="$2" file="$3"
  BLOCK_START_RE="$start_re" BLOCK_END_RE="$end_re" awk '
    $0 ~ ENVIRON["BLOCK_START_RE"] { on = 1 }
    on                             { print }
    on && $0 ~ ENVIRON["BLOCK_END_RE"] { exit }
  ' "$file"
}

# shellcheck source=lib/stage-attempt.sh
. "$SCRIPT_DIR/lib/stage-attempt.sh"
metering_fields() { printf '{}'; }

enabler_block="$(extract_block '^  # The Enabler never pins a repo/item,' \
  "^     \\+ \\\$metered')\"\$" "$SCRIPT_DIR/lib/enabler.sh")"
if [[ -z "$enabler_block" ]] || ! grep -q 'stage: "enabler"' <<<"$enabler_block"; then
  echo "FAIL - could not extract the Enabler's refusal-read block from lib/enabler.sh — has it moved?" >&2
  exit 1
fi

refiner_block="$(extract_block '^  # Same gap as the Enabler'"'"'s own' \
  "^     \\+ \\\$metered')\"\$" "$SCRIPT_DIR/lib/refinement.sh")"
if [[ -z "$refiner_block" ]] || ! grep -q 'stage: "refiner"' <<<"$refiner_block"; then
  echo "FAIL - could not extract the Refiner's refusal-read block from lib/refinement.sh — has it moved?" >&2
  exit 1
fi

# run_either BLOCK OUT_FILE_CONTENT EVENT_FILE — evaluates BLOCK against a
# fixture .out file, with rc=1 (an ordinary non-zero exit, same as a refused
# credential would leave) and stage_kill_reason empty, recording every
# log_event call to EVENT_FILE.
run_either() {
  local block="$1" out_content="$2" event_file="$3"
  local out_file="$tmp_dir/stage.out"
  printf '%s' "$out_content" > "$out_file"
  : > "$event_file"
  (
    set -euo pipefail
    # shellcheck disable=SC2034  # consumed by $block below, invisible to a static reader
    out="$out_file"
    # shellcheck disable=SC2034
    rc=1
    # shellcheck disable=SC2034
    stage_kill_reason=""
    # shellcheck disable=SC2034
    enabler_model="claude-haiku-4-5-20251001"
    # shellcheck disable=SC2034
    refiner_model="claude-haiku-4-5-20251001"
    # shellcheck disable=SC2034
    stage_gaps_json="null"
    # shellcheck disable=SC2317  # called from $block via eval
    log_event() { printf '%s\t%s\n' "$1" "${2:-{\}}" >> "$EVENT_FILE"; }
    export EVENT_FILE="$event_file"
    eval "$block"
  )
}

# --- A refused credential: the stage-end event names it ---

refused_out='{"is_error":true,"terminal_reason":"api_error","api_error_status":400,"result":"This API key is not scoped to a workspace, so this request must include the anthropic-workspace-id header."}'

evt_file="$tmp_dir/enabler-events"
run_either "$enabler_block" "$refused_out" "$evt_file"
stage_end_line="$(grep '^stage-end' "$evt_file" || true)"
assert_eq "the Enabler's stage-end names the refusal token" \
  "yes" "$(if [[ "$stage_end_line" == *'"api_refusal":"workspace_scope_refused"'* ]]; then echo yes; else echo no; fi)"
assert_eq "…carries the refusal class" \
  "yes" "$(if [[ "$stage_end_line" == *'"api_refusal_class":"refused"'* ]]; then echo yes; else echo no; fi)"
assert_eq "…and the API's own message" \
  "yes" "$(if [[ "$stage_end_line" == *"not scoped to a workspace"* ]]; then echo yes; else echo no; fi)"

evt_file2="$tmp_dir/refiner-events"
run_either "$refiner_block" "$refused_out" "$evt_file2"
stage_end_line2="$(grep '^stage-end' "$evt_file2" || true)"
assert_eq "the Refiner's stage-end names the refusal token too" \
  "yes" "$(if [[ "$stage_end_line2" == *'"api_refusal":"workspace_scope_refused"'* ]]; then echo yes; else echo no; fi)"
assert_eq "…carries the refusal class too" \
  "yes" "$(if [[ "$stage_end_line2" == *'"api_refusal_class":"refused"'* ]]; then echo yes; else echo no; fi)"

# --- An ordinary non-refusal failure: no refusal fields at all ---

ordinary_out='{"is_error":true,"terminal_reason":"error_during_execution","result":"the tool crashed"}'

run_either "$enabler_block" "$ordinary_out" "$evt_file"
stage_end_line="$(grep '^stage-end' "$evt_file" || true)"
assert_eq "an ordinary failure's stage-end carries no api_refusal field" \
  "no" "$(if [[ "$stage_end_line" == *'api_refusal'* ]]; then echo yes; else echo no; fi)"

run_either "$refiner_block" "$ordinary_out" "$evt_file2"
stage_end_line2="$(grep '^stage-end' "$evt_file2" || true)"
assert_eq "…and neither does the Refiner's" \
  "no" "$(if [[ "$stage_end_line2" == *'api_refusal'* ]]; then echo yes; else echo no; fi)"

if (( failures > 0 )); then
  printf '\n%d assertion(s) failed.\n' "$failures"
  exit 1
fi
printf '\nAll assertions passed.\n'
