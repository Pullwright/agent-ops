#!/usr/bin/env bash
#
# test/enabler-blocked-by-exclusion.test.sh — regression test for issue
# #2593 (and its own follow-up fix, agent-ops#2603): a blocked candidate
# whose own GitHub thread named a still-open `Blocked-by: #N` reference is
# excluded from `compute_enabler_eligible_set`'s own eligible set
# (`lib/eligibility.sh`), so an Enabler engagement is never spent
# re-deriving the same `still-blocked` verdict requirement 34j's
# `dependency_clearances` (lib/candidate-gather.sh) already tracks and will
# clear by itself the moment the reference closes.
#
# The first version of this filter (issue #2593) read each eligible
# candidate's own thread out of `ordered_repos_json`'s `issues`/`tech_debt`
# bands and re-parsed it for a `Blocked-by:` line — but
# scripts/gather-issues.sh and scripts/gather-tech-debt.sh already drop a
# candidate naming a still-open `Blocked-by:` reference *before* it ever
# reaches either band (the live check happens at gather time), so that
# version could never fire on its own target class. This version instead
# reads `issues_excluded`/`tech_debt_excluded` — the sidecar arrays both
# gathers already report their own drops and reasons into, which the
# blocked/void subtraction never touches — so the fixtures below are built
# the way the real gathers actually produce them, not a shape production
# never reaches.
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
    /^still_blocked_by_json='"'"'\[\]'"'"'$/ { on = 1 }
    on                                      { print }
    on && /^fi$/                            { exit }
  ' "$SCRIPT_DIR/lib/eligibility.sh"
}
open_blocked_by_block_src="$(extract_open_blocked_by_block)"
if [[ "$open_blocked_by_block_src" != *"open_blocked_by_json"* ]]; then
  printf 'FAIL - could not extract the open-Blocked-by block from lib/eligibility.sh (moved or reworded?)\n'
  exit 1
fi

run_open_blocked_by_block() {  # <ordered-repos-json> <enabler-eligible-json> [aliases-json]
  (
    # ordered_repos_json/etc. are consumed by the eval'd filter below — not
    # visible to the static analysis here.
    # shellcheck disable=SC2034
    ordered_repos_json="$1" enabler_eligible_json="$2" \
      repo_slug_aliases_json="${3:-{\}}" union_log='/dev/null' logged="" logged_fields=""
    # shellcheck disable=SC2317
    guard_warn() { :; }
    # shellcheck disable=SC2317
    log_event() { logged="$logged$1 $2\n"; logged_fields="$2"; }
    eval "$open_blocked_by_block_src"
    jq -c -n --argjson e "$enabler_eligible_json" --arg l "$logged" --arg f "$logged_fields" \
      '{eligible: $e, logged: $l, fields: $f}'
  )
}

# --- issue #2581's own reproduction shape: a tech-debt-sourced candidate ---
# --- scripts/gather-tech-debt.sh already dropped for naming a still-open --
# --- Blocked-by: reference, reported into tech_debt_excluded --------------
ordered='[{"slug": "Pullwright/agent-ops",
           "tech_debt_excluded": [{"number": 2581, "reason": "blocked-by: #2565"}]}]'
eligible='[{"repo": "Pullwright/agent-ops", "item": "2581", "reason": "threshold"}]'
result="$(run_open_blocked_by_block "$ordered" "$eligible")"
assert_eq "a candidate scripts/gather-tech-debt.sh excluded for a still-open Blocked-by reference is dropped (issue #2581's own shape)" "0" \
  "$(jq '[.eligible[] | select(.item == "2581")] | length' <<<"$result")"
assert_eq "the drop is logged, not silent" "true" \
  "$(jq -r '.logged | test("enabler-open-blocked-by-skipped")' <<<"$result")"
assert_eq "  ... naming the excluded item" "2581" \
  "$(jq -r '.fields | fromjson | .skipped[0].item' <<<"$result")"

# --- the plain `issues` band gets the identical treatment, via -----------
# --- issues_excluded -------------------------------------------------------
issues_ordered='[{"slug": "o/r",
                   "issues_excluded": [{"number": 42, "reason": "blocked-by: #99"}]}]'
issues_eligible='[{"repo": "o/r", "item": "42", "reason": "threshold"}]'
issues_result="$(run_open_blocked_by_block "$issues_ordered" "$issues_eligible")"
assert_eq "an issues-sourced candidate excluded for an open Blocked-by is dropped too" "0" \
  "$(jq '[.eligible[] | select(.item == "42")] | length' <<<"$issues_result")"

# --- the reference has since closed: dependency_clearances' own job, not --
# --- this filter's — scripts/gather-issues.sh no longer reports the item --
# --- excluded at all, and the candidate must survive -----------------------
closed_ordered='[{"slug": "o/r", "issues_excluded": [], "issues": [{"number": 42}]}]'
closed_result="$(run_open_blocked_by_block "$closed_ordered" "$issues_eligible")"
assert_eq "a candidate no longer reported excluded survives" "1" \
  "$(jq '[.eligible[] | select(.item == "42")] | length' <<<"$closed_result")"
assert_eq "  ... and nothing is logged on that path" "false" \
  "$(jq -r '.logged | test("enabler-open-blocked-by-skipped")' <<<"$closed_result")"

# --- a candidate reported excluded for an unrelated reason is unaffected ---
# --- (only the structured blocked-by reason this filter owns matters here) -
other_reason_ordered='[{"slug": "o/r", "issues_excluded": [{"number": 7, "reason": "assigned"}]}]'
other_reason_eligible='[{"repo": "o/r", "item": "7", "reason": "threshold"}]'
other_reason_result="$(run_open_blocked_by_block "$other_reason_ordered" "$other_reason_eligible")"
assert_eq "a candidate excluded for a non-Blocked-by reason is unaffected" "1" \
  "$(jq '[.eligible[] | select(.item == "7")] | length' <<<"$other_reason_result")"

# --- a candidate this cycle's bands do not carry at all decides nothing ----
# --- ("unknown is never gone", the same rule dependency_clearances itself -
# --- observes) --------------------------------------------------------------
unseen_ordered='[{"slug": "o/r"}]'
unseen_eligible='[{"repo": "o/r", "item": "7", "reason": "threshold"}]'
unseen_result="$(run_open_blocked_by_block "$unseen_ordered" "$unseen_eligible")"
assert_eq "a candidate absent from this cycle's own gathered bands is left eligible" "1" \
  "$(jq '[.eligible[] | select(.item == "7")] | length' <<<"$unseen_result")"

# --- a repo this cycle's own gather did not walk fresh at all (neither ----
# --- _excluded array present) also decides nothing, the identical reading -
no_repo_result="$(run_open_blocked_by_block '[]' "$issues_eligible")"
assert_eq "a repo absent from ordered_repos_json entirely is left eligible" "1" \
  "$(jq '[.eligible[] | select(.item == "42")] | length' <<<"$no_repo_result")"

# --- a repo-slug rename is resolved through repo_slug_aliases_json before --
# --- the lookup, exactly as enabler_eligible_items' own same_item does ----
renamed_ordered='[{"slug": "new/repo",
                    "issues_excluded": [{"number": 10, "reason": "blocked-by: #3"}]}]'
renamed_eligible='[{"repo": "old/repo", "item": "10", "reason": "threshold"}]'
renamed_aliases='{"old/repo": "new/repo"}'
renamed_result="$(run_open_blocked_by_block "$renamed_ordered" "$renamed_eligible" "$renamed_aliases")"
assert_eq "a block recorded under a renamed repo slug still resolves through the alias map" "0" \
  "$(jq '[.eligible[] | select(.item == "10")] | length' <<<"$renamed_result")"

# --- a cross-repo Blocked-by reference is simply whatever reason string ---
# --- scripts/gather-issues.sh already resolved it to (no local re-parse, --
# --- no local alias resolution of the *reference's* own repo — the live ---
# --- check at gather time already settled that) ----------------------------
cross_ordered='[{"slug": "o/r",
                  "issues_excluded": [{"number": 55, "reason": "blocked-by: other/repo#8"}]}]'
cross_eligible='[{"repo": "o/r", "item": "55", "reason": "threshold"}]'
cross_result="$(run_open_blocked_by_block "$cross_ordered" "$cross_eligible")"
assert_eq "a cross-repo Blocked-by reference still open excludes the candidate" "0" \
  "$(jq '[.eligible[] | select(.item == "55")] | length' <<<"$cross_result")"
cross_closed_ordered='[{"slug": "o/r", "issues_excluded": [], "issues": [{"number": 55}]}]'
cross_closed_result="$(run_open_blocked_by_block "$cross_closed_ordered" "$cross_eligible")"
assert_eq "  ... and survives once that same reference is no longer reported excluded" "1" \
  "$(jq '[.eligible[] | select(.item == "55")] | length' <<<"$cross_closed_result")"

# --- an unrelated eligible item in the same cycle is untouched -------------
mixed_eligible='[
  {"repo": "o/r", "item": "42", "reason": "threshold"},
  {"repo": "o/r", "item": "7", "reason": "threshold"}
]'
mixed_ordered='[{"slug": "o/r",
                  "issues_excluded": [{"number": 42, "reason": "blocked-by: #99"}]}]'
mixed_result="$(run_open_blocked_by_block "$mixed_ordered" "$mixed_eligible")"
assert_eq "the still-blocked candidate is dropped" "0" \
  "$(jq '[.eligible[] | select(.item == "42")] | length' <<<"$mixed_result")"
assert_eq "  ... while the unrelated eligible candidate in the same cycle survives" "1" \
  "$(jq '[.eligible[] | select(.item == "7")] | length' <<<"$mixed_result")"

# --- issue #2607: a candidate reported excluded under BOTH its own ---------
# --- deterministic reason (assigned/blocked-label/pager) AND a co-occurring
# --- "blocked-by: " entry — the shape scripts/gather-issues.sh and ---------
# --- scripts/gather-tech-debt.sh now produce for exactly this case — is ----
# --- still dropped, because this filter only ever looks for an entry whose
# --- own `reason` starts "blocked-by: ", regardless of what else that ------
# --- candidate's own number is also reported under in the same array. ------
co_occur_ordered='[{"slug": "o/r",
  "issues_excluded": [{"number": 50, "reason": "assigned"},
                       {"number": 50, "reason": "blocked-by: #51"}]}]'
co_occur_eligible='[{"repo": "o/r", "item": "50", "reason": "threshold"}]'
co_occur_result="$(run_open_blocked_by_block "$co_occur_ordered" "$co_occur_eligible")"
assert_eq "a candidate carrying both its deterministic reason and a blocked-by one is still dropped (issue #2607)" "0" \
  "$(jq '[.eligible[] | select(.item == "50")] | length' <<<"$co_occur_result")"

# --- issues_excluded and tech_debt_excluded are both consulted, for the ---
# --- same repo, in the same cycle ------------------------------------------
both_ordered='[{"slug": "o/r",
                 "issues_excluded": [{"number": 42, "reason": "blocked-by: #99"}],
                 "tech_debt_excluded": [{"number": 2581, "reason": "blocked-by: #2565"}]}]'
both_eligible='[
  {"repo": "o/r", "item": "42", "reason": "threshold"},
  {"repo": "o/r", "item": "2581", "reason": "threshold"}
]'
both_result="$(run_open_blocked_by_block "$both_ordered" "$both_eligible")"
assert_eq "the issues-band drop excludes its own candidate" "0" \
  "$(jq '[.eligible[] | select(.item == "42")] | length' <<<"$both_result")"
assert_eq "  ... and the tech-debt-band drop excludes its own candidate, same cycle" "0" \
  "$(jq '[.eligible[] | select(.item == "2581")] | length' <<<"$both_result")"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
