#!/usr/bin/env bash
# shellcheck disable=SC2034
# impl_pr_url/repo_slug/pr_label are read only by the extracted block below,
# `eval`-defined rather than sourced, so shellcheck cannot see the use — the
# same false positive test/pr-raised-join-key.test.sh's own header disables
# for the same reason.
#
# test/pr-label-ensure-wiring.test.sh — regression test for the block in
# lib/coordinator-phase.sh that calls `pr_label_ensure` immediately after
# `pr-raised` (requirement 17a, agent-ops#2074/#2403) and turns its verdict
# into a `warning` event, or none. `pr_label_ensure` itself is stubbed — it
# has its own test (test/pr-label-ensure.test.sh) — so this file is only
# about the wiring: which repo/number/label it is called with, and which of
# its three possible answers (`added`/`present`/`failed`) logs what.
#
# Lifted verbatim, the same technique test/pr-raised-join-key.test.sh uses,
# so the assertions are about the shipped code rather than a copy of its
# logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/pr-label-ensure-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/lib/coordinator-phase.sh"

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

block="$(awk '
  /^  pr_label_result="\$\(pr_label_ensure / { on = 1 }
  on { print }
  on && /^  esac$/ { exit }
' "$CYCLE")"
if [[ -z "$block" || "$block" != *"pr_label_ensure"* ]]; then
  echo "FAIL - could not extract the pr_label_ensure wiring block from lib/coordinator-phase.sh — has it moved?" >&2
  exit 1
fi

calls_file="$(mktemp)"
events_file="$(mktemp)"
trap 'rm -f "$calls_file" "$events_file"' EXIT

stub_result=""
pr_label_ensure() { printf '%s\n' "$*" >> "$calls_file"; printf '%s' "$stub_result"; }
log_event() { printf '%s\t%s\n' "$1" "$2" >> "$events_file"; }

run_it() {  # <impl_pr_url> <repo_slug> <pr_label> <ensure-result>
  : > "$calls_file"
  : > "$events_file"
  ( impl_pr_url="$1" repo_slug="$2" pr_label="$3" stub_result="$4"
    eval "$block" )
}
event_of() { grep -m1 "^$1"$'\t' "$events_file" | cut -f2- || true; }

run_it "https://github.com/acme/widgets/pull/42" "acme/widgets" "autonomous-agent" "added"
assert_eq "called with repo, PR number parsed from the URL, and pr_label" \
  "acme/widgets 42 autonomous-agent" "$(cat "$calls_file")"
assert_eq "an 'added' verdict logs a warning naming the PR and the label" \
  "1" "$(grep -c '^warning' "$events_file")"
assert_eq "  ... mentioning the PR URL" "true" \
  "$(jq -r '.detail | contains("https://github.com/acme/widgets/pull/42")' <<<"$(event_of warning)")"
assert_eq "  ... carrying pr_url too" '"https://github.com/acme/widgets/pull/42"' \
  "$(jq -c '.pr_url' <<<"$(event_of warning)")"

run_it "https://github.com/acme/widgets/pull/43" "acme/widgets" "autonomous-agent" "present"
assert_eq "a 'present' verdict logs nothing" "0" "$(wc -l < "$events_file")"

run_it "https://github.com/acme/widgets/pull/44" "acme/widgets" "autonomous-agent" "failed"
assert_eq "a 'failed' verdict logs a warning too, not a hard failure" \
  "1" "$(grep -c '^warning' "$events_file")"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
