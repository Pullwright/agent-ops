#!/usr/bin/env bash
#
# test/enabler-void-refusal-exclusion.test.sh — regression test for
# requirement 34p (issue #2789): once a repo+item's void-refusal run has
# reached its own escalation threshold (`void_refusal_escalation_candidates`,
# lib/cycle-state.sh), the Enabler's own eligible set
# (`compute_enabler_eligible_set`, lib/eligibility.sh) must drop it too — not
# just the Co-Ordinator's bands — so the more expensive stage does not pay
# for the identical wasted re-examination the circuit breaker exists to stop
# the cheaper one paying for.
#
# The filter under test is not a standalone function — like
# test/enabler-blocked-by-exclusion.test.sh and
# test/pr-claim-exclusion.test.sh already cover their own neighbouring
# filters, it runs inline inside `compute_enabler_eligible_set`. Same
# technique, same reason: lifted out by its own start/end markers and
# `eval`'d against a fixture, so a change to the real block is what this
# suite exercises, not a second copy of it.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/enabler-void-refusal-exclusion.test.sh
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

extract_void_refusal_block() {
  awk '
    /^void_refusal_escalated_n="\$\(jq .length./ { on = 1 }
    on && /^stale_gather_candidates_json=.\[\].$/ { exit }
    on                                            { print }
  ' "$SCRIPT_DIR/lib/eligibility.sh"
}
void_refusal_block_src="$(extract_void_refusal_block)"
if [[ "$void_refusal_block_src" != *"void_refusal_escalated_json"* ]]; then
  printf 'FAIL - could not extract the void-refusal-escalated block from lib/eligibility.sh (moved or reworded?)\n'
  exit 1
fi
if [[ "$void_refusal_block_src" != *"enabler-void-refusal-escalated-skipped"* ]]; then
  printf 'FAIL - extracted span does not reach its own log_event call (moved, reworded, or the end marker drifted?)\n'
  exit 1
fi

run_void_refusal_block() {  # <enabler-eligible-json> <escalated-json>
  (
    # Consumed by the eval'd filter below — not visible to the static
    # analysis here.
    # shellcheck disable=SC2034
    enabler_eligible_json="$1" void_refusal_escalated_json="$2" logged=""
    # shellcheck disable=SC2317,SC2329
    log_event() { logged="$logged$1 $2\n"; }
    eval "$void_refusal_block_src"
    printf '%s\x1e%s' "$enabler_eligible_json" "$logged"
  )
}

eligible='[{"repo":"org/a","item":"297","reason":"threshold"},{"repo":"org/a","item":"298","reason":"threshold"},{"repo":"org/b","item":"297","reason":"threshold"}]'
escalated='[{"repo":"org/a","item":"297","count":2}]'

IFS=$'\x1e' read -r out logged <<<"$(run_void_refusal_block "$eligible" "$escalated")"
assert_eq "an escalated repo+item is dropped from the Enabler's own eligible set" \
  '["298"]' "$(jq -c '[.[] | select(.repo == "org/a") | .item]' <<<"$out")"
assert_eq "...but a different repo's identically-numbered item survives" \
  '["297"]' "$(jq -c '[.[] | select(.repo == "org/b") | .item]' <<<"$out")"
assert_eq "...and the skip is logged" \
  "1" "$(grep -c "enabler-void-refusal-escalated-skipped" <<<"$logged")"

IFS=$'\x1e' read -r out logged <<<"$(run_void_refusal_block "$eligible" '[]')"
assert_eq "an empty escalated set changes nothing" "3" "$(jq 'length' <<<"$out")"
assert_eq "...and logs nothing" "0" "$(grep -c "enabler-void-refusal-escalated-skipped" <<<"$logged")"

IFS=$'\x1e' read -r out logged <<<"$(run_void_refusal_block "$eligible" 'not json')"
assert_eq "malformed escalated JSON degrades to changing nothing" "3" "$(jq 'length' <<<"$out")"

IFS=$'\x1e' read -r out logged <<<"$(run_void_refusal_block "$eligible" "")"
assert_eq "an unset escalated variable (void_refusal_escalated_json never computed) changes nothing" \
  "3" "$(jq 'length' <<<"$out")"

echo
echo "----------------------------------------"
if (( failures > 0 )); then
  echo "$failures assertion(s) failed."
  exit 1
else
  echo "All assertions passed."
fi
