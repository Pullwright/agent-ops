#!/usr/bin/env bash
#
# test/implementer-merge-observed-wiring.test.sh — regression test for the
# step 6c dispatch block lib/coordinator-phase.sh adds for agent-ops#1062
# (requirement 31f): a finishing source's pre-existing subject pull request
# that has already merged must never reach an Implementer engagement.
#
#   - **The five finishing sources with a pre-existing subject** —
#     `preflight_existing_branch_source`'s own set (review-feedback,
#     merge-conflicts, dequeued, landing-refusals, abandoned-drafts), less a
#     `merge-conflicts` work order carrying `"takeover": true` (that `pr_url`
#     names Dependabot's own pull request, not a subject this stage can
#     retire) — have `pr_merge_state` read against the work order's own
#     `pr_url` just ahead of the Implementer engagement (step 7). A `merged`
#     result reaches `reviewer_merge_observed` (stage
#     `"implementer-stage-start"`, an empty verdict — no stage ran to have
#     found anything) and releases both the item-keyed and the PR-keyed
#     claim, ending the cycle there.
#   - Every other source, and a `merge-conflicts` takeover, never call
#     `pr_merge_state` at all: there is no pre-existing subject for either
#     to be stale about.
#   - An `open` or unreadable (`failed`) result is advisory only and falls
#     through to the ordinary Implementer engagement.
#
# The block is lifted verbatim out of lib/coordinator-phase.sh, the same
# technique test/reviewer-merge-observed-wiring.test.sh already uses: the
# assertions are about the shipped code, not a copy of its logic.
# `pr_merge_state`, `reviewer_merge_observed` and `release_claim` are stubbed
# as recorders — each is unit-tested on its own terms elsewhere
# (test/merge-observed.test.sh, test/pr-merge-state.test.sh) — so this file
# owns only the thinner question: given each shape those three (plus the
# real `preflight_existing_branch_source`, sourced rather than stubbed,
# since it is pure and this is exactly the gate the block depends on) can
# return, does lib/coordinator-phase.sh's own dispatch do the right thing
# with it?
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/implementer-merge-observed-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.
#
# shellcheck disable=SC2016
# This file's whole business is assembling scripts whose `$`-expressions must
# reach the assembled file unexpanded; the single-quoted patterns and printf
# templates below are deliberate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/lib/coordinator-phase.sh"
PREFLIGHT="$SCRIPT_DIR/lib/preflight.sh"

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:             %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

assert_lacks() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:                 %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- Extraction ---------------------------------------------------------------
extract_block() {
  local start="$1" marker="$2" file="$3"
  awk -v start="$start" -v marker="$marker" '
    $0 ~ start { on = 1 }
    on { print }
    on && seen && /^fi$/ { exit }
    on && $0 ~ marker { seen = 1 }
  ' "$file"
}

stage_start_block="$(extract_block \
  '^pre_implementer_merge_state=""; pre_implementer_merge_sha=""$' \
  'implementer-stage-start' \
  "$CYCLE")"

if [[ -z "$stage_start_block" ]]; then
  echo "FAIL - could not extract the stage_start block from lib/coordinator-phase.sh — has it moved?" >&2
  exit 1
fi

# --- Assembly -------------------------------------------------------------
# run_block BLOCK SOURCE TAKEOVER PR_URL
# Runs BLOCK under the same `set -euo pipefail` the real file runs under,
# with `selected_source`/`work_order_json` seeded and every stub/global
# applied first. `pr_merge_state`, `reviewer_merge_observed` and
# `release_claim` all record their calls as one line each in $tmp_dir/calls;
# a real `echo`/`exit 0` inside BLOCK ends the harness itself, which
# run_block treats as an ordinary (successful) exit. The real
# `preflight_existing_branch_source` (lib/preflight.sh) is sourced, not
# stubbed — it is pure and is exactly the gate under test.
run_block() {
  local block="$1" source="$2" takeover="$3" pr_url="$4" harness="$tmp_dir/harness.sh"
  {
    printf '%s\n' 'set -euo pipefail'
    printf 'selected_source=%q\n' "$source"
    printf 'work_order_json=%q\n' "$(jq -nc --arg t "$takeover" --arg u "$pr_url" \
      '{takeover: ($t == "true"), pr_url: $u}')"
    printf '%s\n' "$(cat "$PREFLIGHT")"
    printf '%s\n' 'pr_merge_state() { printf "%s\t%s\n" "pr_merge_state" "$*" >>'"$(printf '%q' "$tmp_dir/calls")"'; printf "%s" "$PR_MERGE_STATE_RESULT"; }'
    printf '%s\n' 'reviewer_merge_observed() { printf "%s\t%s\n" "reviewer_merge_observed" "$*" >>'"$(printf '%q' "$tmp_dir/calls")"'; }'
    printf '%s\n' 'release_claim() { printf "%s\t%s\n" "release_claim" "$*" >>'"$(printf '%q' "$tmp_dir/calls")"'; }'
    printf '%s\n' "$block"
    printf '%s\n' 'echo "__fell_through__"'
  } > "$harness"
  : > "$tmp_dir/calls"
  bash "$harness" 2>"$tmp_dir/stderr"
}

calls_named() { grep $'^'"$1"$'\t' "$tmp_dir/calls" | cut -f2-; }

URL="https://github.com/Poetic-Poems/agent-ops/pull/1062"

# === The five finishing sources, no takeover ===================================

for src in review-feedback dequeued landing-refusals abandoned-drafts; do
  # --- Merged: reviewer_merge_observed fires, both claims released, no engagement
  out="$(PR_MERGE_STATE_RESULT=$'merged\tb48eebf' run_block "$stage_start_block" "$src" "false" "$URL")"
  assert_contains "$src: a merged subject calls reviewer_merge_observed" \
    "$URL b48eebf {} implementer-stage-start" "$(calls_named reviewer_merge_observed)"
  assert_eq "  ... and releases the claim as no-pr" "no-pr" "$(calls_named release_claim)"
  assert_lacks "  ... and the block itself ends the cycle (no fall-through)" "__fell_through__" "$out"

  # --- Open: falls through, nothing fires -------------------------------------
  out="$(PR_MERGE_STATE_RESULT=$'open\t' run_block "$stage_start_block" "$src" "false" "$URL")"
  assert_eq "$src: an open subject calls reviewer_merge_observed not at all" \
    "" "$(calls_named reviewer_merge_observed)"
  assert_eq "  ... and release_claim not at all" "" "$(calls_named release_claim)"
  assert_contains "  ... and falls through to the Implementer engagement" \
    "__fell_through__" "$out"

  # --- Unreadable: advisory, falls through ------------------------------------
  out="$(PR_MERGE_STATE_RESULT=$'failed\t' run_block "$stage_start_block" "$src" "false" "$URL")"
  assert_eq "$src: an unreadable state also falls through (advisory only)" \
    "" "$(calls_named reviewer_merge_observed)"
  assert_contains "  ... running the stage rather than blocking on it" \
    "__fell_through__" "$out"
done

# --- merge-conflicts, no takeover: behaves like the other four ---------------
out="$(PR_MERGE_STATE_RESULT=$'merged\tb48eebf' run_block "$stage_start_block" "merge-conflicts" "false" "$URL")"
assert_contains "merge-conflicts (no takeover): a merged subject completes" \
  "$URL b48eebf {} implementer-stage-start" "$(calls_named reviewer_merge_observed)"

# === Excluded shapes: pr_merge_state is never even asked =======================

# --- merge-conflicts with takeover: Dependabot's own PR, not our subject -----
out="$(PR_MERGE_STATE_RESULT=$'merged\tb48eebf' run_block "$stage_start_block" "merge-conflicts" "true" "$URL")"
assert_eq "merge-conflicts takeover: pr_merge_state is never called" \
  "" "$(calls_named pr_merge_state)"
assert_contains "  ... and falls through to the Implementer engagement" \
  "__fell_through__" "$out"

# --- A source outside the five finishing ones: no pre-existing subject -------
for src in issues tech-debt project-review failed-runs; do
  out="$(PR_MERGE_STATE_RESULT=$'merged\tb48eebf' run_block "$stage_start_block" "$src" "false" "$URL")"
  assert_eq "$src: pr_merge_state is never called" "" "$(calls_named pr_merge_state)"
  assert_contains "  ... and falls through to the Implementer engagement" \
    "__fell_through__" "$out"
done

# --- A finishing source with no pr_url at all: the read is skipped -----------
out="$(PR_MERGE_STATE_RESULT=$'merged\tb48eebf' run_block "$stage_start_block" "review-feedback" "false" "")"
assert_eq "review-feedback with an empty pr_url skips the read entirely" \
  "" "$(calls_named pr_merge_state)"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
