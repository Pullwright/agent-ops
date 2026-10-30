#!/usr/bin/env bash
#
# test/selection-fingerprint-model-set.test.sh — regression test for issue
# #2660: lib/gather-phase.sh's `selection_config_json`, `enabler_config_json`
# and `refiner_config_json` — the Co-Ordinator's own no-op fingerprint
# inputs (requirement 35b) — each embed a fingerprinted model key's already-
# resolved variable directly. For a key configured as a weighted set (issue
# #2247, PR #2647), that variable holds only the set's own handle — the
# config key's own name, a constant — so editing the set's membership or
# weights left the fingerprint, and the fleet-wide forced recheck a model
# change is meant to trigger, unmoved.
#
# The fix routes each of the three blocks' model fields through
# `model_key_fingerprint_json` (lib/model-id.sh), which embeds
# `MODEL_SET_JSON[key]`'s own normalized member array for a set-configured
# key instead of its bare handle, leaving an ordinary (non-set) key
# unchanged.
#
# The three blocks are lifted verbatim out of lib/gather-phase.sh, the way
# test/coordinator-input-wiring.test.sh already lifts its own fit/prompt
# blocks out of the same file, so these assertions are about the shipped
# code rather than a copy of its logic. No network and no `claude`: the
# lifted blocks read only the config-shaped variables this test sets below.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/selection-fingerprint-model-set.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATHER_PHASE_LIB="$SCRIPT_DIR/lib/gather-phase.sh"

# shellcheck source=lib/model-id.sh
. "$SCRIPT_DIR/lib/model-id.sh"

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
assert_ne() {
  local desc="$1" before="$2" after="$3"
  if [[ "$before" != "$after" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     before and after were both: %s\n' "$desc" "$before"
    failures=$(( failures + 1 ))
  fi
}

# --- Extraction: each block, by its own unique start/end lines ---------------

block_between() {
  local start_fixed="$1" end_fixed="$2" file="$3" start_line end_line
  start_line="$(grep -Fn -- "$start_fixed" "$file" | head -1 | cut -d: -f1)"
  end_line="$(grep -Fn -- "$end_fixed" "$file" | head -1 | cut -d: -f1)"
  [[ -n "$start_line" && -n "$end_line" ]] || return 1
  sed -n "${start_line},${end_line}p" "$file"
}

# shellcheck disable=SC2016,SC1003  # The fixed strings are lib/gather-phase.sh's own literal text, matched with grep -F, not expansions for this shell.
selection_block="$(block_between \
  'selection_config_json="$(jq -nc \' \
  '   + $nice'"'"')"' \
  "$GATHER_PHASE_LIB")"
if [[ -z "$selection_block" || "$selection_block" != *'model_key_fingerprint_json'* ]]; then
  echo "FAIL - could not extract selection_config_json's block from lib/gather-phase.sh — has it moved?" >&2
  exit 1
fi

# shellcheck disable=SC2016,SC1003  # Same as above: lib/gather-phase.sh's own literal text, including its embedded single quote.
enabler_block="$(block_between \
  'enabler_config_json="$(jq -nc \' \
  '    recheck_hours: $rh, escalation_label: $lbl, refinement_max_per_engagement: $rmax}'"'"')"' \
  "$GATHER_PHASE_LIB")"
if [[ -z "$enabler_block" || "$enabler_block" != *'model_key_fingerprint_json'* ]]; then
  echo "FAIL - could not extract enabler_config_json's block from lib/gather-phase.sh — has it moved?" >&2
  exit 1
fi

# shellcheck disable=SC2016,SC1003  # Same as above: lib/gather-phase.sh's own literal text, including its embedded single quotes.
refiner_block="$(block_between \
  'refiner_config_json="$(jq -nc \' \
  '  '"'"'{refiner_model: $m, refined_label: $lbl, refiner_max_per_engagement: $rmax, refinement_policy: $policy}'"'"')"' \
  "$GATHER_PHASE_LIB")"
if [[ -z "$refiner_block" || "$refiner_block" != *'model_key_fingerprint_json'* ]]; then
  echo "FAIL - could not extract refiner_config_json's block from lib/gather-phase.sh — has it moved?" >&2
  exit 1
fi

# --- Fixture: one ordinary key, one weighted set (issue #2247) ---------------

# shellcheck disable=SC2034  # Read by the lifted selection_config_json block, eval'd below.
coordinator_model="claude-sonnet-5"
model_key_load_into implementer_model_default implementer_model_default \
  '{"models": [{"id": "claude-sonnet-5", "weight": 2}, {"id": "claude-opus-5", "weight": 1}]}'
# shellcheck disable=SC2034
implementer_model_trivial="claude-haiku-4-5-20251001"
# shellcheck disable=SC2034
candidates_max=5
# shellcheck disable=SC2034
repo_nice_json="{}"

# shellcheck disable=SC2034  # Read by the lifted enabler_config_json block, eval'd below.
enabler_model="claude-sonnet-5"
# shellcheck disable=SC2034
enabler_after_coordinator_cycles=3
# shellcheck disable=SC2034
refinement_after_coordinator_cycles=6
# shellcheck disable=SC2034
enabler_recheck_hours=24
# shellcheck disable=SC2034
enabler_escalation_label="open-question"
# shellcheck disable=SC2034  # Read by both the lifted enabler_config_json and refiner_config_json blocks.
refinement_max_per_engagement=2

# shellcheck disable=SC2034  # Read by the lifted refiner_config_json block, eval'd below.
refiner_model="claude-sonnet-5"
# shellcheck disable=SC2034
refined_label="refined"
# shellcheck disable=SC2034
refiner_max_per_engagement=2
# shellcheck disable=SC2034
refinement_policy_json="{}"

eval "$selection_block"
eval "$enabler_block"
eval "$refiner_block"

# shellcheck disable=SC2154  # Assigned by the lifted selection_config_json block just eval'd above.
assert_eq "selection_config_json: an ordinary (non-set) coordinator_model passes through as before" \
  '"claude-sonnet-5"' "$(jq -c '.coordinator_model' <<<"$selection_config_json")"
# shellcheck disable=SC2154
assert_eq "selection_config_json: a set-configured implementer_model_default embeds its member array, not the bare handle" \
  '[{"id":"anthropic/claude-sonnet-5","weight":2},{"id":"anthropic/claude-opus-5","weight":1}]' \
  "$(jq -c '.models.default' <<<"$selection_config_json")"
# shellcheck disable=SC2154
assert_eq "selection_config_json: an ordinary implementer_model_trivial is unaffected" \
  '"claude-haiku-4-5-20251001"' "$(jq -c '.models.trivial' <<<"$selection_config_json")"
# shellcheck disable=SC2154  # Assigned by the lifted enabler_config_json block just eval'd above.
assert_eq "enabler_config_json: an ordinary enabler_model is unaffected" \
  '"claude-sonnet-5"' "$(jq -c '.enabler_model' <<<"$enabler_config_json")"
# shellcheck disable=SC2154  # Assigned by the lifted refiner_config_json block just eval'd above.
assert_eq "refiner_config_json: an ordinary refiner_model is unaffected" \
  '"claude-sonnet-5"' "$(jq -c '.refiner_model' <<<"$refiner_config_json")"

# --- Editing the set's weights must change the fingerprint (issue #2660) -----

# shellcheck disable=SC2154  # Assigned by the lifted selection_config_json block eval'd above.
before_selection="$selection_config_json"
model_key_load_into implementer_model_default implementer_model_default \
  '{"models": [{"id": "claude-sonnet-5", "weight": 9}, {"id": "claude-opus-5", "weight": 1}]}'
eval "$selection_block"
assert_ne "editing a weighted set's weight changes selection_config_json's value for that key" \
  "$before_selection" "$selection_config_json"

# And membership, not just weight: dropping a member must move it too.
before_selection="$selection_config_json"
model_key_load_into implementer_model_default implementer_model_default \
  '{"models": [{"id": "claude-sonnet-5", "weight": 9}]}'
eval "$selection_block"
assert_ne "editing a weighted set's membership changes selection_config_json's value for that key" \
  "$before_selection" "$selection_config_json"

echo
if (( failures == 0 )); then
  echo "PASS"
  exit 0
else
  echo "FAIL ($failures assertion(s) failed)"
  exit 1
fi
