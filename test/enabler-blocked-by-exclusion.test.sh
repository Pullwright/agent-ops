#!/usr/bin/env bash
#
# test/enabler-blocked-by-exclusion.test.sh — regression test for issue
# #2593: a blocked candidate whose own GitHub thread still names an open
# `Blocked-by: #N` reference is excluded from `compute_enabler_eligible_set`'s
# own eligible set (`lib/eligibility.sh`), so an Enabler engagement is never
# spent re-deriving the same `still-blocked` verdict requirement 34j's
# `dependency_clearances` (lib/candidate-gather.sh) already tracks and will
# clear by itself the moment the reference closes.
#
# The filter under test is not a standalone function — like the stale-ref
# filter test/pr-claim-exclusion.test.sh already covers, it runs inline,
# between `enabler_eligible_items` and the point past which the exit trap may
# engage the Enabler, inside `compute_enabler_eligible_set`. Same technique,
# same reason: lifted out by its own start/end markers and `eval`'d against a
# fixture, so a change to the real block is what this suite exercises, not a
# second copy of it.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/enabler-blocked-by-exclusion.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/dependency-gate.sh
. "$SCRIPT_DIR/lib/dependency-gate.sh"
# shellcheck source=lib/candidate-select.sh
. "$SCRIPT_DIR/lib/candidate-select.sh"
# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/eligibility.sh
. "$SCRIPT_DIR/lib/eligibility.sh"

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

extract_open_blocked_by_block() {
  awk '
    /^open_blocked_by_json='"'"'\[\]'"'"'$/ { on = 1 }
    on                                      { print }
    on && /^fi$/                            { exit }
  ' "$SCRIPT_DIR/lib/eligibility.sh"
}
open_blocked_by_block_src="$(extract_open_blocked_by_block)"
if [[ "$open_blocked_by_block_src" != *"open_blocked_by_json"* ]]; then
  printf 'FAIL - could not extract the open-Blocked-by block from lib/eligibility.sh (moved or reworded?)\n'
  exit 1
fi

run_open_blocked_by_block() {  # <ordered-repos-json> <enabler-eligible-json> <open-issues-json> [aliases-json] [blocked-json]
  (
    # ordered_repos_json/blocked_json/etc. are consumed by the real
    # compute_band_eligibility call (for its dependency_threads_json
    # snapshot) and the eval'd filter below — neither is visible to the
    # static analysis below.
    # shellcheck disable=SC2034
    ordered_repos_json="$1" enabler_eligible_json="$2" open_issues_json="$3" \
      repo_slug_aliases_json="${4:-{\}}" blocked_json="${5:-[]}" void_json='[]' \
      union_log='/dev/null' logged="" logged_fields=""
    # shellcheck disable=SC2317
    guard_warn() { :; }
    # shellcheck disable=SC2317
    log_event() { logged="$logged$1 $2\n"; logged_fields="$2"; }
    compute_band_eligibility
    eval "$open_blocked_by_block_src"
    jq -c -n --argjson e "$enabler_eligible_json" --arg l "$logged" --arg f "$logged_fields" \
      '{eligible: $e, logged: $l, fields: $f}'
  )
}

# --- issue #2581's own reproduction shape: a tech-debt-sourced candidate ---
# --- whose thread still carries an open Blocked-by: reference -------------
ordered='[{"slug": "Pullwright/agent-ops",
           "tech_debt": [{"ref": "2581", "number": 2581,
                           "body": "ci_trigger_ensure pushes a nudge commit…",
                           "comments": [{"body": "Blocked-by: #2565"}]}]}]'
eligible='[{"repo": "Pullwright/agent-ops", "item": "2581", "reason": "threshold"}]'
open_2565='{"Pullwright/agent-ops": [2565, 9001]}'
result="$(run_open_blocked_by_block "$ordered" "$eligible" "$open_2565")"
assert_eq "a candidate whose thread names a still-open Blocked-by reference is excluded (issue #2581's own shape)" "0" \
  "$(jq '[.eligible[] | select(.item == "2581")] | length' <<<"$result")"
assert_eq "the drop is logged, not silent" "true" \
  "$(jq -r '.logged | test("enabler-open-blocked-by-skipped")' <<<"$result")"
assert_eq "  ... naming the excluded item" "2581" \
  "$(jq -r '.fields | fromjson | .skipped[0].item' <<<"$result")"

# --- the plain `issues` band gets the identical treatment -----------------
issues_ordered='[{"slug": "o/r",
                   "issues": [{"number": 42, "body": "see dependency",
                                "comments": [{"body": "- Blocked-by: #99"}]}]}]'
issues_eligible='[{"repo": "o/r", "item": "42", "reason": "threshold"}]'
open_99='{"o/r": [99]}'
issues_result="$(run_open_blocked_by_block "$issues_ordered" "$issues_eligible" "$open_99")"
assert_eq "an issues-sourced candidate with an open Blocked-by is excluded too" "0" \
  "$(jq '[.eligible[] | select(.item == "42")] | length' <<<"$issues_result")"

# --- the reference has since closed: dependency_clearances' own job, not --
# --- this filter's — the candidate must survive ---------------------------
closed_open='{"o/r": [100]}'
closed_result="$(run_open_blocked_by_block "$issues_ordered" "$issues_eligible" "$closed_open")"
assert_eq "a candidate whose named reference is no longer in the open-issues digest survives" "1" \
  "$(jq '[.eligible[] | select(.item == "42")] | length' <<<"$closed_result")"
assert_eq "  ... and nothing is logged on that path" "false" \
  "$(jq -r '.logged | test("enabler-open-blocked-by-skipped")' <<<"$closed_result")"

# --- a candidate with no Blocked-by line at all is unaffected --------------
plain_ordered='[{"slug": "o/r", "issues": [{"number": 7, "body": "ordinary issue", "comments": []}]}]'
plain_eligible='[{"repo": "o/r", "item": "7", "reason": "threshold"}]'
plain_result="$(run_open_blocked_by_block "$plain_ordered" "$plain_eligible" '{}')"
assert_eq "a candidate with no Blocked-by line is unaffected" "1" \
  "$(jq '[.eligible[] | select(.item == "7")] | length' <<<"$plain_result")"

# --- a candidate this cycle's bands do not carry at all decides nothing ----
# --- ("unknown is never gone", the same rule dependency_clearances itself -
# --- observes) --------------------------------------------------------------
unseen_ordered='[{"slug": "o/r", "issues": []}]'
unseen_eligible='[{"repo": "o/r", "item": "7", "reason": "threshold"}]'
unseen_result="$(run_open_blocked_by_block "$unseen_ordered" "$unseen_eligible" '{}')"
assert_eq "a candidate absent from this cycle's own gathered bands is left eligible" "1" \
  "$(jq '[.eligible[] | select(.item == "7")] | length' <<<"$unseen_result")"

# --- a reference whose own repo this cycle could not read cleanly counts ---
# --- as still-open — the same fail-safe direction issue_blocked_by_ref -----
# --- already takes for the identical convention ----------------------------
unknown_result="$(run_open_blocked_by_block "$issues_ordered" "$issues_eligible" '{}')"
assert_eq "a reference whose repo is absent from the open-issues digest fails safe toward still-open" "0" \
  "$(jq '[.eligible[] | select(.item == "42")] | length' <<<"$unknown_result")"

# --- a cross-repo reference is resolved against its own named repo's -------
# --- open-issues digest, not the candidate's own repo -----------------------
cross_ordered='[{"slug": "o/r",
                  "issues": [{"number": 55, "body": "Blocked-by: other/repo#8", "comments": []}]}]'
cross_eligible='[{"repo": "o/r", "item": "55", "reason": "threshold"}]'
cross_open_still='{"o/r": [], "other/repo": [8]}'
cross_result_open="$(run_open_blocked_by_block "$cross_ordered" "$cross_eligible" "$cross_open_still")"
assert_eq "a cross-repo Blocked-by reference still open in its own repo excludes the candidate" "0" \
  "$(jq '[.eligible[] | select(.item == "55")] | length' <<<"$cross_result_open")"
cross_open_closed='{"o/r": [], "other/repo": [9]}'
cross_result_closed="$(run_open_blocked_by_block "$cross_ordered" "$cross_eligible" "$cross_open_closed")"
assert_eq "  ... and survives once that same reference is no longer open" "1" \
  "$(jq '[.eligible[] | select(.item == "55")] | length' <<<"$cross_result_closed")"

# --- a repo-slug rename is resolved through repo_slug_aliases_json before --
# --- either lookup, exactly as enabler_eligible_items' own same_item does --
renamed_ordered='[{"slug": "new/repo",
                    "issues": [{"number": 10, "body": "Blocked-by: #3", "comments": []}]}]'
renamed_eligible='[{"repo": "old/repo", "item": "10", "reason": "threshold"}]'
renamed_open='{"new/repo": [3]}'
renamed_aliases='{"old/repo": "new/repo"}'
renamed_result="$(run_open_blocked_by_block "$renamed_ordered" "$renamed_eligible" "$renamed_open" "$renamed_aliases")"
assert_eq "a block recorded under a renamed repo slug still resolves through the alias map" "0" \
  "$(jq '[.eligible[] | select(.item == "10")] | length' <<<"$renamed_result")"

# --- an unrelated eligible item in the same cycle is untouched -------------
mixed_eligible='[
  {"repo": "o/r", "item": "42", "reason": "threshold"},
  {"repo": "o/r", "item": "7", "reason": "threshold"}
]'
mixed_ordered='[{"slug": "o/r",
                  "issues": [
                    {"number": 42, "body": "see dependency", "comments": [{"body": "- Blocked-by: #99"}]},
                    {"number": 7, "body": "ordinary issue", "comments": []}
                  ]}]'
mixed_result="$(run_open_blocked_by_block "$mixed_ordered" "$mixed_eligible" "$open_99")"
assert_eq "the still-blocked candidate is dropped" "0" \
  "$(jq '[.eligible[] | select(.item == "42")] | length' <<<"$mixed_result")"
assert_eq "  ... while the unrelated eligible candidate in the same cycle survives" "1" \
  "$(jq '[.eligible[] | select(.item == "7")] | length' <<<"$mixed_result")"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
