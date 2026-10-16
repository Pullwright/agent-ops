#!/usr/bin/env bash
#
# test/publish-union-once.test.sh — regression test for how many times
# scripts/publish-dashboard.sh builds the fleet-log union in one tick, and
# where (agent-ops#2429).
#
# On 2026-10-16 the four nodes' `log.jsonl` union was 124 MB and one `jq`
# pass over it cost 5 to 13 s. The Publisher built that union four times a
# tick — once for the transient-refusal verdict, ahead of the no-op
# short-circuit, so even a tick that then skipped had paid for it; once for
# the snapshot every reader shares; once more, fresh, for the payload's
# `pager` array — and twice for `review-log.jsonl`, and the pager's state
# reads parsed the whole fresh re-union twice per registered key. A GitHub
# tick cost 700 s against a 295 s launcher window. What this test pins
# against reappearing: `log.jsonl` goes through `fleet_logs` exactly once a
# tick, at the snapshot, after the no-op short-circuit's own `exit 0`;
# `review-log.jsonl` goes through it exactly once, ahead of the full-build
# block, so that every consumer, the pager included, shares the one build;
# and `crash_loop_verdict` is called after the snapshot it reads.
#
# This is a textual/structural check, on test/lock-skip-before-union.test.sh's
# own precedent for the analogous question in agent-cycle.sh: "the union was
# built only once" is not observable from inside a stubbed run of the
# Publisher without reimplementing most of its setup, so the fact asserted
# here is a fact about the shipped script's line order, not about a captured
# runtime trace. Comment lines are blanked before every count, since the
# script's own comments quote the calls they describe.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/publish-union-once.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISH="$SCRIPT_DIR/scripts/publish-dashboard.sh"

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

# code_lines — the script with every comment line blanked, line numbers kept,
# so a count or a position below never sees a comment that quotes a call.
code_lines() { sed -E 's/^[[:space:]]*#.*$//' "$PUBLISH"; }
count_matching() { code_lines | grep -c -- "$1"; }
first_line_matching() { code_lines | grep -n -m1 -- "$1" | cut -d: -f1; }

# shellcheck disable=SC2016  # grep patterns: the publisher's own literal `$state_dir`/`$peers_dir`.
log_union_pattern='fleet_logs "\$state_dir" "\$peers_dir" log\.jsonl'
# shellcheck disable=SC2016  # ditto.
review_union_pattern='fleet_logs "\$state_dir" "\$peers_dir" review-log\.jsonl'
# shellcheck disable=SC2016  # ditto.
verdict_pattern='crash_loop_verdict "\$crash_loop_after_dashboard"'

log_union_count="$(count_matching "$log_union_pattern")"
log_union_line="$(first_line_matching "$log_union_pattern")"
review_union_count="$(count_matching "$review_union_pattern")"
review_union_line="$(first_line_matching "$review_union_pattern")"
verdict_line="$(first_line_matching "$verdict_pattern")"
full_block_line="$(first_line_matching '^if (( FULL )); then$')"
# The no-op short-circuit: the fingerprint comparison, then the first `exit 0`
# after it.
fingerprint_line="$(first_line_matching 'local_state_fingerprint)" == ')"
short_circuit_exit_line=""
if [[ -n "$fingerprint_line" ]]; then
  short_circuit_exit_line="$(code_lines \
    | awk -v from="$fingerprint_line" 'NR > from && /^[[:space:]]*exit 0[[:space:]]*$/ { print NR; exit }')"
fi

assert_eq "the no-op short-circuit is still where this test expects to find it" \
  "yes" "$([[ -n "$fingerprint_line" && -n "$short_circuit_exit_line" ]] && echo yes || echo no)"
assert_eq "the log.jsonl union snapshot is still where this test expects to find it" \
  "yes" "$([[ -n "$log_union_line" ]] && echo yes || echo no)"
assert_eq "the review-log.jsonl union is still where this test expects to find it" \
  "yes" "$([[ -n "$review_union_line" ]] && echo yes || echo no)"
assert_eq "the transient-refusal verdict's call is still where this test expects to find it" \
  "yes" "$([[ -n "$verdict_line" ]] && echo yes || echo no)"
assert_eq "the full-build block is still where this test expects to find it" \
  "yes" "$([[ -n "$full_block_line" ]] && echo yes || echo no)"

if [[ -z "$fingerprint_line" || -z "$short_circuit_exit_line" || -z "$log_union_line" \
      || -z "$review_union_line" || -z "$verdict_line" || -z "$full_block_line" ]]; then
  printf '\n%d assertion(s) failed\n' "$(( failures + 1 ))" >&2
  echo "FAIL - could not locate the union wiring in publish-dashboard.sh — has it moved?" >&2
  exit 1
fi

assert_eq "log.jsonl goes through fleet_logs exactly once a tick" "1" "$log_union_count"
assert_eq "  ... and that read is after the no-op short-circuit's exit 0 — a skipped tick builds no union" \
  "yes" "$([[ "$short_circuit_exit_line" -lt "$log_union_line" ]] && echo yes || echo no)"
assert_eq "review-log.jsonl goes through fleet_logs exactly once a tick" "1" "$review_union_count"
assert_eq "  ... ahead of the full-build block, so the pager shares the one build" \
  "yes" "$([[ "$review_union_line" -lt "$full_block_line" ]] && echo yes || echo no)"
assert_eq "crash_loop_verdict is called after the snapshot it reads" \
  "yes" "$([[ "$log_union_line" -lt "$verdict_line" ]] && echo yes || echo no)"

if (( failures )); then
  printf '\n%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall assertions passed\n'
