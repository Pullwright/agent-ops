#!/usr/bin/env bash
#
# test/dependency-clearances-tech-debt-wiring.test.sh — regression test for
# agent-ops#2604: requirement 34j's release reshape in lib/candidate-gather.sh
# consumed `ordered_repos_json`'s `.issues` band only, so a union-log-blocked
# tech-debt item (a GitHub issue carrying `pw::type:tech-debt`,
# gather-tech-debt.sh's own band — excluded from `.issues` by design) could
# never be cleared mechanically by `dependency_clearances`: it would only ever
# reappear in `.tech_debt`, which this reshape never read, leaving the Enabler
# as the sole unblocker for the whole tech-debt band.
#
# The fix merges `(.tech_debt // [])` alongside `(.issues // [])` before
# keying by `(.number // .ref) | tostring` — the two bands partition a
# repo's open issues by the `pw::type:tech-debt` label (gather-issues.sh
# excludes it, gather-tech-debt.sh keeps only it), so a number can never
# legitimately collide between them.
#
# The reshape is lifted verbatim out of lib/candidate-gather.sh, the way
# test/coordinator-input-wiring.test.sh and test/void-retire-wiring.test.sh
# lift theirs, so the assertions are about the shipped code rather than a
# copy of its logic. `dependency_clearances` itself (lib/dependency-gate.sh)
# is exercised unmodified — test/dependency-gate.test.sh already covers its
# own logic in full; this file's job is only the map it is handed.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/dependency-clearances-tech-debt-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/dependency-gate.sh
. "$SCRIPT_DIR/lib/dependency-gate.sh"

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

extract_block() {
  local start_re="$1" end_re="$2" file="$3"
  BLOCK_START_RE="$start_re" BLOCK_END_RE="$end_re" awk '
    $0 ~ ENVIRON["BLOCK_START_RE"] { on = 1 }
    on                             { print }
    on && $0 ~ ENVIRON["BLOCK_END_RE"] { exit }
  ' "$file"
}

# shellcheck disable=SC2016  # The anchors are awk regexes matching lib/candidate-gather.sh's own text, not expansions for this shell.
reshape_block="$(extract_block '^issues_by_repo_json="\$\(jq -c' \
  '^\[\[ -n "\$issues_by_repo_json" \]\] \|\| issues_by_repo_json='"'"'\{\}'"'"'$' \
  "$SCRIPT_DIR/lib/candidate-gather.sh")"
if [[ -z "$reshape_block" || "$reshape_block" != *'tech_debt'* ]]; then
  echo "FAIL - could not extract requirement 34j's release reshape from lib/candidate-gather.sh — has it moved, or dropped tech_debt?" >&2
  exit 1
fi

run_reshape() {
  local ordered_repos_json="$1" tmp_dir harness out
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN
  harness="$tmp_dir/reshape-harness.sh"
  {
    printf 'set -uo pipefail\n'
    printf 'ordered_repos_json=%q\n' "$ordered_repos_json"
    printf '%s\n' "$reshape_block"
    # shellcheck disable=SC2016  # The harness's own $issues_by_repo_json, written out literally for the assembled script to expand, not this shell.
    printf 'printf '"'"'%%s'"'"' "$issues_by_repo_json"\n'
  } > "$harness"
  out="$(bash "$harness")"
  printf '%s' "$out"
}

# --- Half one: a tech-debt-band item's thread is now reachable --------------

repos_both_bands='[
  {"slug": "o/r",
   "issues": [{"number": 100, "body": "An ordinary issue.\n\nBlocked-by: #1", "comments": []}],
   "tech_debt": [{"number": 200, "ref": "200",
                  "body": "Noticed while working #1.\n\nBlocked-by: #1", "comments": []}]}
]'
reshaped="$(run_reshape "$repos_both_bands")"
assert_eq "an issues-band item's thread is reachable, keyed by number" \
  "true" "$(jq -r '(.["o/r"]["100"].body // "") | test("Blocked-by: #1")' <<<"$reshaped")"
assert_eq "a tech-debt-band item's thread is reachable too, keyed the same way" \
  "true" "$(jq -r '(.["o/r"]["200"].body // "") | test("Blocked-by: #1")' <<<"$reshaped")"

# --- Half two: dependency_clearances now clears a tech-debt-band block ------
#
# The exact #196-199-shaped scenario test/dependency-gate.test.sh already
# proves for an issues-band item, restated for a tech-debt one: a
# union-log-blocked item whose `Blocked-by:` reference has resolved, present
# this cycle only because gather-tech-debt.sh's own live check
# (issue_blocked_by_ref) already found every reference closed.
blocked_td_200='[{"repo":"o/r","item":"200","ts":"2026-08-01T00:00:00Z"}]'
cleared="$(dependency_clearances "$blocked_td_200" "$reshaped")"
assert_eq "a union-log-blocked tech-debt item present in the reshaped map clears" \
  '1' "$(jq 'length' <<<"$cleared")"
assert_eq "the clearance names the right repo and item" \
  '{"repo":"o/r","item":"200"}' "$(jq -c '.[0] | {repo, item}' <<<"$cleared")"
assert_eq "the reason names the resolved reference" \
  "true" "$(jq -r '.[0].reason | test("#1")' <<<"$cleared")"

# A tech-debt item absent from this cycle's reshaped map (its own dependency
# still open, so gather-tech-debt.sh held it out) decides nothing — the same
# "unknown is never gone" rule the issues-band release already observes.
repos_td_held='[
  {"slug": "o/r", "issues": [],
   "tech_debt": []}
]'
reshaped_held="$(run_reshape "$repos_td_held")"
assert_eq "a tech-debt item this cycle never gathered clears nothing" \
  '0' "$(jq 'length' <<<"$(dependency_clearances "$blocked_td_200" "$reshaped_held")")"

# --- No regression: a repo number colliding across bands never drops either -
#
# Not a case gather-issues.sh/gather-tech-debt.sh's own label partition
# expects to hit in practice (noted in the reshape's own comment), but the
# merge must still behave predictably rather than erroring out.
repos_collision='[
  {"slug": "o/r",
   "issues": [{"number": 300, "body": "Blocked-by: #1 (issues copy)", "comments": []}],
   "tech_debt": [{"number": 300, "ref": "300", "body": "Blocked-by: #1 (tech-debt copy)", "comments": []}]}
]'
reshaped_collision="$(run_reshape "$repos_collision")"
assert_eq "a colliding number resolves to exactly one entry, the tech-debt one (concatenated last)" \
  "true" "$(jq -r '(.["o/r"]["300"].body // "") | test("tech-debt copy")' <<<"$reshaped_collision")"
assert_eq "and only one entry exists for that key, not two" \
  '1' "$(jq '.["o/r"] | length' <<<"$reshaped_collision")"

# --- Narrowing by expensive_gather freshness still applies to both bands ----
#
# Requirement 48: a repo replayed from the node's expensive-gather cache
# carries proof from whenever its last turn was, not this cycle — narrowed
# out of the map before the reshape, for `tech_debt` exactly as for `issues`.
repos_stale='[
  {"slug": "o/r", "expensive_gather": {"fresh": false},
   "issues": [{"number": 100, "body": "Blocked-by: #1", "comments": []}],
   "tech_debt": [{"number": 200, "ref": "200", "body": "Blocked-by: #1", "comments": []}]}
]'
reshaped_stale="$(run_reshape "$repos_stale")"
assert_eq "a non-fresh repo's tech-debt band is narrowed out of the map" \
  '{}' "$(jq -c '. ["o/r"] // {}' <<<"$reshaped_stale")"

echo
if (( failures == 0 )); then
  echo "All dependency-clearances-tech-debt-wiring assertions passed."
  exit 0
else
  echo "$failures dependency-clearances-tech-debt-wiring assertion(s) FAILED."
  exit 1
fi
