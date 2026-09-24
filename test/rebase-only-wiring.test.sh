#!/usr/bin/env bash
#
# test/rebase-only-wiring.test.sh — regression test for the two blocks
# agent-cycle.sh adds for requirement 31e (agent-ops#1806): a `merge-conflicts`
# item's rebase-only push must skip the Reviewer/Approver stages for this
# cycle, carrying the pull request's standing verdicts forward instead of
# re-running either.
#
#   - **The pre-capture block** (step 6b, just ahead of "--- 7. Implementer
#     stage ---"): `premerge_rebase_only_capture` records the pull request's
#     pre-push head and base SHAs — but only for a `merge-conflicts` work
#     order that is not a Dependabot takeover, and only once the work order's
#     own `base` resolves to a real ref.
#   - **The stage-start advisory block** (just inside "--- 8. Reviewer stage
#     ---", right after the existing #916 merge-state check): compares the
#     pre-push diff against the post-push one by patch-id and, when they
#     match, logs the carry-forward event and ends the cycle at zero further
#     stage cost — exactly as the existing merge-state block already does for
#     a confirmed merge, immediately above it.
#
# Both blocks are lifted verbatim out of agent-cycle.sh, the same technique
# test/reviewer-merge-observed-wiring.test.sh already uses: the assertions are
# about the shipped code, not a copy of its logic. `rebase_only_push` and
# `log_event` are stubbed as recorders — `rebase_only_push` itself is
# unit-tested on its own terms in test/rebase-only.test.sh — so this file owns
# only the thinner question: given each shape those can return, does
# agent-cycle.sh's own dispatch do the right thing with it?
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/rebase-only-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.
#
# shellcheck disable=SC2016
# This file's whole business is assembling scripts whose `$`-expressions must
# reach the assembled file unexpanded; the single-quoted patterns and printf
# templates below are deliberate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/agent-cycle.sh"

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

# extract_block START_PATTERN MARKER_PATTERN FILE
# Turns on at START_PATTERN, prints every line while on, and stops at the
# first bare "fi" line seen *after* MARKER_PATTERN.
extract_block() {
  local start="$1" marker="$2" file="$3"
  awk -v start="$start" -v marker="$marker" '
    $0 ~ start { on = 1 }
    on { print }
    on && seen && /^fi$/ { exit }
    on && $0 ~ marker { seen = 1 }
  ' "$file"
}

# extract_to_call START_PATTERN CALL_PATTERN FILE
# Turns on at START_PATTERN, prints every line while on, and stops right
# after the first line matching CALL_PATTERN — for a flat function-definition
# plus one-line call, which carries no closing "fi" of its own to stop at.
extract_to_call() {
  local start="$1" call="$2" file="$3"
  awk -v start="$start" -v call="$call" '
    $0 ~ start { on = 1 }
    on { print }
    on && $0 ~ call { exit }
  ' "$file"
}

capture_block="$(extract_to_call \
  '^premerge_old_head=""; premerge_old_base=""; premerge_base_name=""$' \
  '^premerge_rebase_only_capture$' \
  "$CYCLE")"

advisory_block="$(extract_block \
  '^rebase_only_new_head=""; rebase_only_new_base=""$' \
  'reviewer-approver-carried-forward' \
  "$CYCLE")"

for pair in "capture:$capture_block" "advisory:$advisory_block"; do
  if [[ -z "${pair#*:}" ]]; then
    echo "FAIL - could not extract the ${pair%%:*} block from agent-cycle.sh — has it moved?" >&2
    exit 1
  fi
done

# --- The pre-capture block: stub git, run against each work-order shape ------

run_capture() {  # SELECTED_SOURCE TAKEOVER BASE_FIELD [ls-remote output style]
  local selected_source="$1" takeover="$2" base_field="$3"
  cat >"$tmp_dir/capture-harness.sh" <<HARNESS
set -uo pipefail
selected_source="$selected_source"
selected_branch="agent/td-42"
clone_dir="/no/such/clone"
work_order_json='$(jq -nc --arg t "$takeover" --arg b "$base_field" \
  '{takeover: ($t == "true"), base: (if $b == "" then null else $b end)}')'
git() {
  if [[ "\$1" == "-C" && "\$3" == "ls-remote" ]]; then
    case "\$5" in
      *"agent/td-42") printf 'oldheadsha\trefs/heads/agent/td-42\n' ;;
      *"main") printf 'oldbasesha\trefs/heads/main\n' ;;
      *) return 1 ;;
    esac
    return 0
  fi
  return 1
}
$capture_block
printf 'head=%s\tbase=%s\tbase_name=%s\n' "\$premerge_old_head" "\$premerge_old_base" "\$premerge_base_name"
HARNESS
  bash "$tmp_dir/capture-harness.sh"
}

out="$(run_capture "merge-conflicts" "false" "main")"
assert_eq "a merge-conflicts, non-takeover item with a resolvable base captures both SHAs" \
  "head=oldheadsha	base=oldbasesha	base_name=main" "$out"

out="$(run_capture "merge-conflicts" "true" "main")"
assert_eq "a Dependabot takeover captures nothing — it is ordinary fresh work" \
  "head=	base=	base_name=" "$out"

out="$(run_capture "issues" "false" "main")"
assert_eq "a non-merge-conflicts source captures nothing" \
  "head=	base=	base_name=" "$out"

out="$(run_capture "merge-conflicts" "false" "")"
assert_eq "a merge-conflicts item with no base field captures nothing" \
  "head=	base=	base_name=" "$out"

# --- The stage-start advisory block: stub rebase_only_push and log_event ----

run_advisory() {  # OLD_HEAD OLD_BASE IMPL_PR_URL PUSH_RESULT(true|false|unavailable)
  local old_head="$1" old_base="$2" pr_url="$3" push_result="$4"
  cat >"$tmp_dir/advisory-harness.sh" <<HARNESS
set -uo pipefail
premerge_old_head="$old_head"
premerge_old_base="$old_base"
premerge_base_name="main"
impl_pr_url="$pr_url"
selected_repo="acme/widgets"
selected_item="42"
clone_dir="/no/such/clone"
git() {
  if [[ "\$1" == "-C" && "\$3" == "rev-parse" ]]; then
    printf 'newheadsha\n'; return 0
  fi
  if [[ "\$1" == "-C" && "\$3" == "ls-remote" ]]; then
    printf 'newbasesha\trefs/heads/main\n'; return 0
  fi
  if [[ "\$1" == "-C" && "\$3" == "fetch" ]]; then
    return 0
  fi
  return 1
}
rebase_only_push() {
  case "$push_result" in
    true) return 0 ;;
    false) return 1 ;;
    unavailable) return 1 ;;
  esac
}
log_event() { printf '%s\t%s\n' "\$1" "\$2" >>"$tmp_dir/events"; }
$advisory_block
echo "fell through past the advisory block"
HARNESS
  bash "$tmp_dir/advisory-harness.sh"
}

: >"$tmp_dir/events"
out="$(run_advisory "oldheadsha" "oldbasesha" "https://github.com/acme/widgets/pull/42" "true")"
assert_eq "a confirmed rebase-only push echoes the PR url and ends the cycle there" \
  "https://github.com/acme/widgets/pull/42" "$out"
assert_contains "  ... never falling through to the reviewer tier" \
  "https://github.com/acme/widgets/pull/42" "$out"
if [[ "$out" == *"fell through"* ]]; then
  assert_eq "  ... (never falls through)" "no fall-through" "fell through"
else
  assert_eq "  ... (never falls through)" "no fall-through" "no fall-through"
fi
assert_contains "  ... and logs reviewer-approver-carried-forward" \
  "reviewer-approver-carried-forward" "$(cat "$tmp_dir/events")"
assert_contains "  ... naming rebase_only: true" '"rebase_only":true' "$(cat "$tmp_dir/events")"
assert_contains "  ... the pull request's own url" '"pr_url":"https://github.com/acme/widgets/pull/42"' \
  "$(cat "$tmp_dir/events")"

: >"$tmp_dir/events"
out="$(run_advisory "oldheadsha" "oldbasesha" "https://github.com/acme/widgets/pull/42" "false")"
assert_eq "a push whose diff genuinely changed falls through to the reviewer tier" \
  "fell through past the advisory block" "$out"
assert_eq "  ... and logs nothing" "" "$(cat "$tmp_dir/events")"

: >"$tmp_dir/events"
out="$(run_advisory "" "" "https://github.com/acme/widgets/pull/42" "true")"
assert_eq "no pre-capture (not a merge-conflicts item) falls through without even asking" \
  "fell through past the advisory block" "$out"
assert_eq "  ... and logs nothing" "" "$(cat "$tmp_dir/events")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
