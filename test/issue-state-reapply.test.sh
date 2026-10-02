#!/usr/bin/env bash
#
# test/issue-state-reapply.test.sh — regression test for agent-ops#1095:
# requirement 16.4's assigned/blocked-label drops (requirement 3j's
# deterministic half), re-applied to a replayed `issues` band (requirement
# 48) from this cycle's own `gather_source_state` sample rather than left as
# stale as the band itself.
#
# Two things are under test, each lifted whole out of the shipped source so a
# change to the real code is what this suite exercises, not a reimplementation
# of it:
#
#   1. `issue_state_reapply` (lib/candidate-select.sh) — the pure jq
#      transform: given an `issues` band, a `gather_source_state` issues
#      sample and a prior `issues_excluded_raw`, it drops every candidate the
#      sample now reports assigned or `blocked`-labelled, folding each fresh
#      drop into the prior exclusion set.
#   2. The cached-branch issues-source block in `gather_ordered_repos`
#      (lib/candidate-gather.sh) — the wiring that calls it only when this
#      cycle's own source-state sample succeeded (`state.ok == true`),
#      leaving a replayed band untouched otherwise.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/issue-state-reapply.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/candidate-select.sh
. "$SCRIPT_DIR/lib/candidate-select.sh"

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

# =============================================================================
# Part 1: issue_state_reapply itself
# =============================================================================

candidates='[{"number":1,"ref":"1"},{"number":2,"ref":"2"},{"number":3,"ref":"3"}]'
state_issues='[{"n":1,"u":"","l":[],"a":"warwickallen"},{"n":2,"u":"","l":["Blocked"],"a":""},{"n":3,"u":"","l":[],"a":""}]'

out="$(issue_state_reapply "$candidates" "$state_issues" "null")"
assert_eq "an assigned issue is dropped from candidates" \
  "false" "$(jq -e '.candidates | any(.number == 1)' <<<"$out" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "a Blocked-labelled issue (case-insensitive) is dropped from candidates" \
  "false" "$(jq -e '.candidates | any(.number == 2)' <<<"$out" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "an untouched issue stays a candidate" \
  '[{"number":3,"ref":"3"}]' "$(jq -c '.candidates' <<<"$out")"
assert_eq "the assigned drop is reported with reason assigned" \
  "assigned" "$(jq -r '.excluded[] | select(.number == 1) | .reason' <<<"$out")"
assert_eq "the blocked-label drop is reported with reason blocked-label" \
  "blocked-label" "$(jq -r '.excluded[] | select(.number == 2) | .reason' <<<"$out")"
assert_eq "exactly two drops are reported" \
  "2" "$(jq '.excluded | length' <<<"$out")"

# --- Precedence: assigned wins when an issue is both assigned and blocked ---
both='[{"n":4,"u":"","l":["blocked"],"a":"alice"}]'
out_both="$(issue_state_reapply '[{"number":4,"ref":"4"}]' "$both" "null")"
assert_eq "an issue both assigned and blocked-labelled reports reason assigned" \
  "assigned" "$(jq -r '.excluded[0].reason' <<<"$out_both")"

# --- A candidate the sample no longer names is left exactly as it arrived --
out_unsampled="$(issue_state_reapply '[{"number":99,"ref":"99"}]' '[]' "null")"
assert_eq "an unsampled candidate stays, untouched" \
  '[{"number":99,"ref":"99"}]' "$(jq -c '.candidates' <<<"$out_unsampled")"
assert_eq "an unsampled candidate adds no exclusion" \
  "null" "$(jq -c '.excluded' <<<"$out_unsampled")"

# --- null prior with no fresh drop stays null, not a false empty -----------
out_nodrop="$(issue_state_reapply '[{"number":7,"ref":"7"}]' '[{"n":7,"u":"","l":[],"a":""}]' "null")"
assert_eq "no fresh drop against a null prior stays null, never a false []" \
  "null" "$(jq -c '.excluded' <<<"$out_nodrop")"

# --- A fresh drop merges with, de-dupes against, and overrides a stale prior
prior='[{"number":9,"reason":"blocked-label"}]'
out_merge="$(issue_state_reapply '[{"number":9,"ref":"9"},{"number":10,"ref":"10"}]' \
  '[{"n":9,"u":"","l":[],"a":"alice"},{"n":10,"u":"","l":[],"a":""}]' "$prior")"
assert_eq "a fresh drop's own reason wins over a stale cached one for the same number" \
  '[{"number":9,"reason":"assigned"}]' "$(jq -c '.excluded' <<<"$out_merge")"
assert_eq "the fresh drop still removes the candidate" \
  '[{"number":10,"ref":"10"}]' "$(jq -c '.candidates' <<<"$out_merge")"

# --- A prior exclusion for a number no longer a candidate at all is kept ---
# (e.g. closed since, or past the sample's own page bound) — the merge never
# drops a prior entry just because this cycle's candidates array moved on.
out_keep_prior="$(issue_state_reapply '[]' '[]' '[{"number":55,"reason":"assigned"}]')"
assert_eq "a prior exclusion survives when its own issue is no longer a candidate" \
  '[{"number":55,"reason":"assigned"}]' "$(jq -c '.excluded' <<<"$out_keep_prior")"

# =============================================================================
# Part 2: the cached-branch issues-source block in lib/candidate-gather.sh
# =============================================================================

issues_block_src="$(awk '
  index($0, "  issues=\"[]\"; issues_excluded=\"[]\"") == 1 { on = 1 }
  on { print }
  on && index($0, "  fi") == 1 { exit }
' "$SCRIPT_DIR/lib/candidate-gather.sh")"
if [[ "$issues_block_src" != *'issue_state_reapply'* \
   || "$issues_block_src" != *'exclude_claimed_items'* ]]; then
  printf 'FAIL - could not extract the cached-branch issues-source block from lib/candidate-gather.sh (moved or reworded?)\n'
  exit 1
fi

run_cached_issues_block() {  # <sources-json> <issues_raw> <issues_excluded_raw> <state-json>
  (
    # Consumed only by the eval'd block below, invisible to static analysis.
    # shellcheck disable=SC2034
    sources="$1" issues_raw="$2" issues_excluded_raw="$3" state="$4" \
      claimed_item_refs_json='[]'
    eval "$issues_block_src"
    # issues/issues_excluded: assigned only by the eval'd block above,
    # invisible to static analysis.
    # shellcheck disable=SC2154
    jq -nc --argjson i "$issues" --argjson e "$issues_excluded" '{issues: $i, issues_excluded: $e}'
  )
}

state_ok='{"ok":true,"issues":[{"n":1,"u":"","l":[],"a":"warwickallen"},{"n":2,"u":"","l":["blocked"],"a":""},{"n":3,"u":"","l":[],"a":""}]}'
band='[{"number":1,"ref":"1"},{"number":2,"ref":"2"},{"number":3,"ref":"3"}]'

out="$(run_cached_issues_block '["issues:high"]' "$band" 'null' "$state_ok")"
assert_eq "wiring: a successful state sample drops the now-assigned issue from the replayed band" \
  '[{"number":3,"ref":"3"}]' "$(jq -c '.issues' <<<"$out")"
assert_eq "wiring: the drop is reported in issues_excluded with its reason" \
  "true" "$(jq -e '.issues_excluded | any(.number == 1 and .reason == "assigned")' <<<"$out" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "wiring: the blocked-label drop is reported too" \
  "true" "$(jq -e '.issues_excluded | any(.number == 2 and .reason == "blocked-label")' <<<"$out" >/dev/null 2>&1 && echo true || echo false)"

# --- state.ok == false: fail open, leave the replayed band exactly as it was
state_bad='{"ok":false}'
out_bad="$(run_cached_issues_block '["issues:high"]' "$band" 'null' "$state_bad")"
assert_eq "wiring: a failed state sample leaves the replayed band unfiltered" \
  "$band" "$(jq -c '.issues' <<<"$out_bad")"
assert_eq "wiring: a failed state sample reports no new exclusion" \
  "[]" "$(jq -c '.issues_excluded' <<<"$out_bad")"

# --- sources not including "issues": the block's own outer guard is untouched
out_nosource="$(run_cached_issues_block '["tech-debt"]' "$band" 'null' "$state_ok")"
assert_eq "wiring: a repo not configured for issues gets the empty band, same as today" \
  "[]" "$(jq -c '.issues' <<<"$out_nosource")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
