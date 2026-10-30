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
# The extracted span now also covers the stale-expensive-gather-cache live
# re-check (issue #2709): a second, later exclusion pass over the same
# `enabler_eligible_json`, which can issue real `gh api` reads for the narrow
# set of candidates a stale cache cannot speak to. Those reads are mocked
# below via a `gh` function the extracted block's own `eval` picks up from
# this process, exactly as `log_event`/`guard_warn` already are.
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
# shellcheck source=lib/issue-prefetch.sh
. "$SCRIPT_DIR/lib/issue-prefetch.sh"
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
    on && /^# Past this line the exit trap/   { exit }
    on                                        { print }
  ' "$SCRIPT_DIR/lib/eligibility.sh"
}
open_blocked_by_block_src="$(extract_open_blocked_by_block)"
if [[ "$open_blocked_by_block_src" != *"open_blocked_by_json"* ]]; then
  printf 'FAIL - could not extract the open-Blocked-by block from lib/eligibility.sh (moved or reworded?)\n'
  exit 1
fi
if [[ "$open_blocked_by_block_src" != *"stale_gather_live_checked_json"* ]]; then
  printf 'FAIL - extracted span does not reach the stale-expensive-gather-cache live re-check (moved, reworded, or the end marker drifted?)\n'
  exit 1
fi

run_open_blocked_by_block() {  # <ordered-repos-json> <enabler-eligible-json> [aliases-json]
                                # [degraded-issues-excluded-json] [latest-issues-excluded-json]
                                # [gh-live-json]
  (
    # ordered_repos_json/etc. are consumed by the eval'd filter below — not
    # visible to the static analysis here.
    # shellcheck disable=SC2034
    ordered_repos_json="$1" enabler_eligible_json="$2" \
      repo_slug_aliases_json="${3:-{\}}" \
      degraded_issues_excluded_json="${4:-[]}" latest_issues_excluded_json="${5:-{\}}" \
      gh_live_json="${6:-{\}}" \
      union_log='/dev/null' logged="" logged_fields=""
    # shellcheck disable=SC2317,SC2329
    guard_warn() { :; }
    # shellcheck disable=SC2317,SC2329
    log_event() { logged="$logged$1 $2\n"; logged_fields="$2"; }
    # Mocks the `gh api` reads the stale-expensive-gather-cache live
    # re-check (issue #2709, re-keyed onto `updated_at` by issue #2720) can
    # issue: `repos/<r>/issues/<n>` with a `--jq '.updated_at // ""'` filter
    # returns that candidate's own `updated_at` (from `$gh_live_json`'s
    # `"<r>#<n>".updated_at`) -- the cheap per-candidate read the live
    # re-check does before paying for the heavier reads below -- a `--jq
    # '.body // ""'` filter returns that candidate's own body (`.body`), the
    # same shape with `--jq '[.[].body // ""] | join("\n")'` (the
    # `/comments` path) returns its comments (`.comments`), and `--jq
    # '.state'` — `issue_blocked_by_ref`'s own check of a *referenced*
    # issue's live state — returns `.ref_state` (empty, i.e. fail-open to
    # "still-open", when absent). Dispatched on the `--jq` filter text, not
    # the path, since the candidate's own updated_at/body/comments reads and
    # a referenced issue's state read share the identical
    # `repos/<r>/issues/<n>` path shape.
    #
    # The comments read also models REST's own paging, so the suite can pin
    # the direction of truncation rather than assuming the whole thread
    # arrives: where `.comments` is an *array* of bodies (rather than one
    # pre-joined string, as the simpler cases below give it), the mock
    # returns every element only under `--paginate`, and otherwise just the
    # first `per_page` of them — defaulting, exactly as the real endpoint
    # does, to the *oldest* 30. A `Blocked-by:` line in element 31 is
    # therefore invisible to any call that does not page, which is what the
    # 31-comment case further down asserts against.
    #
    # Argument scanning, not positional indexing: `--paginate` sits between
    # the path and `--jq` on the comments read, so `$4` is not reliably the
    # filter, and the path may now carry a `?per_page=` query string.
    # shellcheck disable=SC2317,SC2329
    gh() {
      local cmd="$1" path filter="" paginate=0 per_page=0 query="" repo item key
      [[ "$cmd" == "api" ]] || return 1
      shift; path="$1"; shift
      while (( $# )); do
        case "$1" in
          --paginate) paginate=1 ;;
          --jq) filter="${2:-}"; shift ;;
        esac
        shift
      done
      query="${path#*\?}"; [[ "$query" != "$path" ]] || query=""
      path="${path%%\?*}"
      [[ "$query" =~ per_page=([0-9]+) ]] && per_page="${BASH_REMATCH[1]}"
      [[ "$path" =~ ^repos/(.+)/issues/([0-9]+)(/comments)?$ ]] || return 1
      repo="${BASH_REMATCH[1]}"; item="${BASH_REMATCH[2]}"; key="$repo#$item"
      case "$filter" in
        *updated_at*) jq -r --arg k "$key" '(.[$k].updated_at // "")' <<<"$gh_live_json" ;;
        *state*) jq -r --arg k "$key" '(.[$k].ref_state // "")' <<<"$gh_live_json" ;;
        *join*)  jq -r --arg k "$key" --argjson pag "$paginate" --argjson pp "$per_page" '
                   (.[$k].comments // "") as $c
                   | if ($c | type) == "array"
                     then (if $pag == 1 then $c
                           else $c[0:(if $pp > 0 then $pp else 30 end)] end
                           | join("\n"))
                     else $c end' <<<"$gh_live_json" ;;
        *)       jq -r --arg k "$key" '(.[$k].body // "")' <<<"$gh_live_json" ;;
      esac
    }
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

# --- issue #2678: a repo whose issues gather degraded this cycle folds to --
# --- the identical issues_excluded: [] a clean, nothing-excluded gather ----
# --- gets (requirement 33) — but `degraded_issues_excluded_json` names the --
# --- repo as degraded, so the filter falls back to the prior reading -------
# --- `latest_issues_excluded_json` carries for it, rather than treating the
# --- standing Blocked-by: reference as unknown and leaving it eligible -----
degraded_ordered='[{"slug": "o/r", "issues_excluded": []}]'
degraded_eligible='[{"repo": "o/r", "item": "2616", "reason": "threshold"}]'
degraded_list='["o/r"]'
degraded_latest='{"o/r": [{"number": 2616, "reason": "blocked-by: #2437"}]}'
degraded_result="$(run_open_blocked_by_block "$degraded_ordered" "$degraded_eligible" '{}' \
  "$degraded_list" "$degraded_latest")"
assert_eq "a degraded-gather repo's candidate falls back to the prior reading and is dropped (issue #2678)" "0" \
  "$(jq '[.eligible[] | select(.item == "2616")] | length' <<<"$degraded_result")"
assert_eq "  ... and the drop is logged, not silent" "true" \
  "$(jq -r '.logged | test("enabler-open-blocked-by-skipped")' <<<"$degraded_result")"

# ... the same repo, same empty issues_excluded, but NOT named in
# degraded_issues_excluded_json: this cycle's own gather really was clean, so
# the stale prior reading must not override it.
clean_result="$(run_open_blocked_by_block "$degraded_ordered" "$degraded_eligible" '{}' \
  '[]' "$degraded_latest")"
assert_eq "a repo not reported degraded uses this cycle's own (genuinely empty) exclusion set, not the stale prior one" "1" \
  "$(jq '[.eligible[] | select(.item == "2616")] | length' <<<"$clean_result")"

# ... a degraded repo with no prior reading at all still decides nothing —
# "unknown is never gone" survives the fallback.
no_prior_result="$(run_open_blocked_by_block "$degraded_ordered" "$degraded_eligible" '{}' \
  "$degraded_list" '{}')"
assert_eq "a degraded repo with no prior latest_issues_excluded reading is left eligible" "1" \
  "$(jq '[.eligible[] | select(.item == "2616")] | length' <<<"$no_prior_result")"

# --- issue #2709: the stale-expensive-gather-cache live re-check ----------
# A `Blocked-by:` line posted after a repo's expensive-gather cache was
# written is invisible to the cached-sidecar filter above for the whole
# gather rotation. These four cases are its own four acceptance criteria.
#
# The gate under test keys on the candidate's own live `updated_at`
# (issue #2720), not its `blocked_ts`: every fixture below that is meant to
# reach the live re-check now carries its own `updated_at` in `*_gh_live`,
# and every `blocked_ts` left on an `*_eligible` fixture is now inert —
# kept only because it is the shape the real gathers actually produce.

# 1. A fresh-gather candidate is unaffected, even though the mocked `gh`
#    reads would exclude it if the live re-check ran against it anyway —
#    proving `expensive_gather.fresh == true` skips the re-check outright.
fresh_ordered='[{"slug": "o/r", "expensive_gather": {"fresh": true, "gathered_at": "2026-10-27T10:53:38Z"}}]'
fresh_eligible='[{"repo": "o/r", "item": "42", "reason": "threshold"}]'
fresh_gh_live='{"o/r#42": {"updated_at": "2026-10-27T11:00:00Z", "body": "Blocked-by: #99"}, "o/r#99": {"ref_state": "open"}}'
fresh_result="$(run_open_blocked_by_block "$fresh_ordered" "$fresh_eligible" '{}' '[]' '{}' "$fresh_gh_live")"
assert_eq "a fresh-gather candidate is unaffected by the live re-check (issue #2709 AC 1)" "1" \
  "$(jq '[.eligible[] | select(.item == "42")] | length' <<<"$fresh_result")"

# 2. A stale-gather candidate whose thread has NOT moved since the cache was
#    written is unaffected — even though it is now selected into the
#    repo-stale set (fresh == false), the cheap `updated_at` read holds it
#    back from the heavier thread read the would-exclude mocked reads sit
#    behind, proving the `updated_at <= gathered_at` guard, not the fresh
#    flag, is what holds it back from the live re-check (issue #2720 keeps
#    this scenario, issue #2709's own AC 2, true under the new gate).
before_ordered='[{"slug": "o/r", "expensive_gather": {"fresh": false, "gathered_at": "2026-10-27T11:00:00Z"}}]'
before_eligible='[{"repo": "o/r", "item": "43", "reason": "threshold"}]'
before_gh_live='{"o/r#43": {"updated_at": "2026-10-27T10:00:00Z", "body": "Blocked-by: #99"}, "o/r#99": {"ref_state": "open"}}'
before_result="$(run_open_blocked_by_block "$before_ordered" "$before_eligible" '{}' '[]' '{}' "$before_gh_live")"
assert_eq "a stale-gather candidate whose thread has not moved since the cache was written is unaffected (issue #2709 AC 2, re-pinned for issue #2720)" "1" \
  "$(jq '[.eligible[] | select(.item == "43")] | length' <<<"$before_result")"

# 2b. issue #2720's own residual window: a candidate blocked *before* the
#    cache was written (so the old `blocked_ts > gathered_at` gate would
#    have missed it, as case 2 above still pins) whose thread's own
#    `updated_at` moved *after* the cache — e.g. a human adding a
#    `Blocked-by:` line to an already-blocked item, or a later stage
#    noticing the dependency on a recheck round — is now selected for the
#    live re-check, and excluded on the still-open reference its thread
#    names.
residual_ordered='[{"slug": "o/r", "expensive_gather": {"fresh": false, "gathered_at": "2026-10-27T11:00:00Z"}}]'
residual_eligible='[{"repo": "o/r", "item": "46", "reason": "threshold", "blocked_ts": "2026-10-27T10:00:00Z"}]'
residual_gh_live='{"o/r#46": {"updated_at": "2026-10-27T12:00:00Z", "body": "Blocked-by: #99"}, "o/r#99": {"ref_state": "open"}}'
residual_result="$(run_open_blocked_by_block "$residual_ordered" "$residual_eligible" '{}' '[]' '{}' "$residual_gh_live")"
assert_eq "a candidate blocked before the cache but whose thread updated after it is now selected and excluded (issue #2720's own residual window)" "0" \
  "$(jq '[.eligible[] | select(.item == "46")] | length' <<<"$residual_result")"

# 3. A stale-gather candidate whose thread moved *after* the cache was
#    written and whose live thread names a still-open Blocked-by reference
#    is excluded, and the exclusion is logged under the shared
#    `enabler-stale-refs-skipped` event (issue #2709's own "Logging"
#    instruction).
after_open_ordered='[{"slug": "o/r", "expensive_gather": {"fresh": false, "gathered_at": "2026-10-27T10:53:38Z"}}]'
after_eligible='[{"repo": "o/r", "item": "2693", "reason": "threshold"}]'
after_open_gh_live='{"o/r#2693": {"updated_at": "2026-10-27T11:00:00Z", "body": "Blocked-by: #2684"}, "o/r#2684": {"ref_state": "open"}}'
after_open_result="$(run_open_blocked_by_block "$after_open_ordered" "$after_eligible" '{}' '[]' '{}' "$after_open_gh_live")"
assert_eq "a stale-gather candidate updated after the cache was written, still open live, is excluded (issue #2709 AC 3, item 2693's own reproduction)" "0" \
  "$(jq '[.eligible[] | select(.item == "2693")] | length' <<<"$after_open_result")"
assert_eq "  ... and the exclusion is logged under the shared enabler-stale-refs-skipped event" "true" \
  "$(jq -r '.logged | test("enabler-stale-refs-skipped")' <<<"$after_open_result")"

# 4. Same as 3, but the referenced issue is now closed: not excluded.
after_closed_gh_live='{"o/r#2693": {"updated_at": "2026-10-27T11:00:00Z", "body": "Blocked-by: #2684"}, "o/r#2684": {"ref_state": "closed"}}'
after_closed_result="$(run_open_blocked_by_block "$after_open_ordered" "$after_eligible" '{}' '[]' '{}' "$after_closed_gh_live")"
assert_eq "  ... but survives once the referenced issue is closed live (issue #2709 AC 4)" "1" \
  "$(jq '[.eligible[] | select(.item == "2693")] | length' <<<"$after_closed_result")"

# --- a candidate whose repo carries no expensive_gather stamp at all is ---
# --- read as fresh, the same convention issues_by_repo_json already -------
# --- observes, and so is left alone by the live re-check too --------------
no_stamp_ordered='[{"slug": "o/r"}]'
no_stamp_eligible='[{"repo": "o/r", "item": "44", "reason": "threshold"}]'
no_stamp_gh_live='{"o/r#44": {"updated_at": "2026-10-27T11:00:00Z", "body": "Blocked-by: #99"}, "o/r#99": {"ref_state": "open"}}'
no_stamp_result="$(run_open_blocked_by_block "$no_stamp_ordered" "$no_stamp_eligible" '{}' '[]' '{}' "$no_stamp_gh_live")"
assert_eq "a candidate whose repo carries no expensive_gather stamp is left eligible (no stamp reads as fresh)" "1" \
  "$(jq '[.eligible[] | select(.item == "44")] | length' <<<"$no_stamp_result")"

# --- a stale stamp carrying no gathered_at at all is left alone too ------
# The node had no cache for that repo to load, so `lib/candidate-gather.sh`
# stamped `gathered_at: null`. There is no timestamp to compare a live
# `updated_at` against, so there is no narrow set left to take — and the
# `gathered_at != ""` guard is what holds the line: jq's own `"…" > null` is
# *true*, so without it every eligible candidate in such a repo would be
# live-re-checked, which is precisely the per-candidate check issue #2603
# removed for cost. The mocked `gh` reads would exclude this candidate if the
# re-check ran, so the surviving entry is what pins the guard.
null_at_ordered='[{"slug": "o/r", "expensive_gather": {"fresh": false, "gathered_at": null}}]'
null_at_eligible='[{"repo": "o/r", "item": "45", "reason": "threshold"}]'
null_at_gh_live='{"o/r#45": {"updated_at": "2026-10-27T11:00:00Z", "body": "Blocked-by: #99"}, "o/r#99": {"ref_state": "open"}}'
null_at_result="$(run_open_blocked_by_block "$null_at_ordered" "$null_at_eligible" '{}' '[]' '{}' "$null_at_gh_live")"
assert_eq "a stale stamp with no gathered_at is left eligible, never live-re-checked" "1" \
  "$(jq '[.eligible[] | select(.item == "45")] | length' <<<"$null_at_result")"
assert_eq "  ... and nothing is logged for it" "" \
  "$(jq -r '.logged' <<<"$null_at_result")"

# --- the live re-check reads the *whole* comment thread, not REST's own ---
# --- first page: the `Blocked-by:` line sits at the end of a thread ------
# A 31-comment thread whose `Blocked-by:` line is the newest comment. REST's
# own default is the oldest 30 ascending, so a read that does not page cannot
# see element 31 at all — and the pipeline posts the line at the moment it
# records the block, which is exactly what the `updated_at > gathered_at` gate
# above selects for, so this is the common shape rather than a corner. The
# mocked `gh` models that truncation (see its own comment), which is what lets
# this assertion fail against a non-paging read.
long_thread_comments="$(jq -nc '[range(0; 30) | "a routine pipeline comment, number \(.)"]
  + ["Blocked-by: #2684"]')"
long_thread_gh_live="$(jq -nc --argjson c "$long_thread_comments" \
  '{"o/r#2693": {updated_at: "2026-10-27T11:00:00Z", body: "no dependency named in the body", comments: $c},
    "o/r#2684": {ref_state: "open"}}')"
long_thread_result="$(run_open_blocked_by_block "$after_open_ordered" "$after_eligible" '{}' '[]' '{}' "$long_thread_gh_live")"
assert_eq "a Blocked-by line in the 31st comment is still seen (the whole thread is read, not REST's oldest-30 default)" "0" \
  "$(jq '[.eligible[] | select(.item == "2693")] | length' <<<"$long_thread_result")"

# --- only a bare issue number is re-checked live -------------------------
# `.item` is an issue number for the `issues` and `tech_debt` bands alone —
# the only two either `_excluded` sidecar ever reports on. A surviving
# `pr-<n>-conflict-<sha>` claim (requirement 35e's own stale-ref pass keeps a
# *live* one) is not a path `repos/<slug>/issues/<item>` can resolve, so
# re-checking it would spend two unconditional 404s on a question with no
# answer. The mocked `gh` refuses the non-numeric path exactly as the real
# endpoint 404s it, so the candidate survives either way — what this pins is
# that it is never put to the question at all.
pr_ref_eligible='[{"repo": "o/r", "item": "pr-2700-conflict-a1b2c3d", "reason": "threshold"}]'
pr_ref_result="$(run_open_blocked_by_block "$after_open_ordered" "$pr_ref_eligible" '{}' '[]' '{}' '{}')"
assert_eq "a non-issue-numbered item is left eligible and never live-re-checked" "1" \
  "$(jq '[.eligible[] | select(.item == "pr-2700-conflict-a1b2c3d")] | length' <<<"$pr_ref_result")"
assert_eq "  ... and nothing is logged for it" "" \
  "$(jq -r '.logged' <<<"$pr_ref_result")"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
