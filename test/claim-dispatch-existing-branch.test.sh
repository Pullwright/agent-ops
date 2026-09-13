#!/usr/bin/env bash
#
# test/claim-dispatch-existing-branch.test.sh — regression test for the
# branch-vs-file claim dispatch in agent-cycle.sh (requirement 53, issue
# #979).
#
# A source whose pull request and branch predate the claim must take a *file*
# claim keyed on the item ref, never a branch claim: the branch-claim arm
# creates a fresh branch off the default branch and then overwrites the
# candidate's own `branch` field with it, which hands the Implementer a branch
# no pull request tracks and skips the PR-keyed `pr-<n>` exclusion claim
# (issue #238) entirely. `landing-refusals` was gathered, selected and
# preflighted as such a source while missing from this dispatch, so its
# Implementer would have pushed to a new branch off `main` and the refused
# pull request would never have received the
# `<!-- agent-ops:reconciles comment=<id> -->` line that clears gate 4.
#
# The dispatch condition is lifted verbatim out of agent-cycle.sh — the same
# extraction technique test/pr-claim-hold-through-review.test.sh uses for
# release_claim — so a regression in the real condition is what this catches,
# not a restatement of it. The second half asserts the condition agrees with
# `PREFLIGHT_EXISTING_BRANCH_SOURCES` (lib/preflight.sh), the other place the
# same set is written down: the two disagreeing is precisely the defect.
#
# No network and no GitHub. Run directly:
#
#   ./test/claim-dispatch-existing-branch.test.sh
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

# --- Lift the dispatch condition verbatim out of agent-cycle.sh -------------
# The `if [[ … ]]; then` whose body opens with the "No new branch to create"
# comment. Line continuations are folded so the condition can be eval'd as one
# expression.
condition="$(awk '
  /^  if \[\[ "\$c_source" == "review-feedback"/ { collecting = 1 }
  collecting {
    line = $0
    sub(/^[[:space:]]+/, "", line)
    sub(/[[:space:]]*\\$/, "", line)
    sub(/^if /, "", line)
    sub(/; then$/, "", line)
    printf "%s ", line
    if ($0 ~ /; then$/) { exit }
  }
' "$SCRIPT_DIR/agent-cycle.sh")"

# The lift must produce a complete, parseable `[[ … ]]` command, or every
# assertion below would silently read "branch" off an eval that merely failed
# to parse — the one way this file could pass while proving nothing.
if [[ -z "$condition" ]]; then
  printf 'FAIL - could not lift the claim dispatch condition out of agent-cycle.sh\n'
  exit 1
fi
if ! bash -n <<<"c_source=x; c_takeover=x; $condition"; then
  printf 'FAIL - the lifted condition does not parse: %s\n' "$condition"
  exit 1
fi
printf 'ok   - lifted the dispatch condition: %s\n' "$condition"

# takes_file_claim <source> [takeover] — "file" when the lifted condition
# selects the pre-existing-branch arm, "branch" otherwise.
takes_file_claim() {
  # shellcheck disable=SC2034  # Both are read by $condition, inside the eval
  # below — the point of lifting the real condition rather than restating it is
  # that shellcheck cannot see through the string, and neither can a reader
  # grepping for the names. They are the same two variable names agent-cycle.sh
  # itself tests, deliberately, so the lifted text needs no rewriting.
  local c_source="$1" c_takeover="${2:-false}"
  if eval "$condition"; then
    printf 'file'
  else
    printf 'branch'
  fi
}

# --- The five sources whose branch and PR predate the claim ----------------
for src in review-feedback abandoned-drafts dequeued landing-refusals; do
  assert_eq "$src takes a file claim on the existing branch" \
    "file" "$(takes_file_claim "$src")"
done
assert_eq "merge-conflicts takes a file claim on our own conflicted PR" \
  "file" "$(takes_file_claim merge-conflicts false)"

# --- The takeover carve-out and the ordinary fresh-branch sources ----------
# A `merge-conflicts` takeover (requirement 3s, issue #250) names Dependabot's
# PR, not ours: a genuinely new branch, so the ordinary branch-claim path.
assert_eq "a merge-conflicts takeover still takes a branch claim" \
  "branch" "$(takes_file_claim merge-conflicts true)"
for src in tech-debt issues security code-quality register-hygiene \
           human-visibility project-review failed-runs implementation-plan; do
  assert_eq "$src takes a branch claim (nothing exists to claim yet)" \
    "branch" "$(takes_file_claim "$src")"
done

# --- The dispatch and PREFLIGHT_EXISTING_BRANCH_SOURCES must agree ---------
# lib/preflight.sh writes the same set down a second time, for the merged-
# branch ancestry gate. The two disagreeing is the defect this file exists
# for: preflight believing a branch predates the claim while the dispatch
# mints a fresh one for it.
# shellcheck source=lib/preflight.sh
. "$SCRIPT_DIR/lib/preflight.sh"

for src in $PREFLIGHT_EXISTING_BRANCH_SOURCES; do
  assert_eq "$src is in PREFLIGHT_EXISTING_BRANCH_SOURCES, so it must take a file claim" \
    "file" "$(takes_file_claim "$src")"
done

# …and nothing outside that set (bar the takeover carve-out, asserted above)
# may take one.
for src in tech-debt issues security code-quality register-hygiene \
           human-visibility project-review failed-runs implementation-plan; do
  assert_eq "$src is absent from PREFLIGHT_EXISTING_BRANCH_SOURCES" \
    "1" "$(preflight_existing_branch_source "$src"; echo $?)"
done

# ---------------------------------------------------------------------------------
if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
