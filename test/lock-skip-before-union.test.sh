#!/usr/bin/env bash
#
# test/lock-skip-before-union.test.sh — regression test for *where* in
# agent-cycle.sh the lock-held fast path sits relative to the fleet-log union
# (agent-ops#2312).
#
# Before this fix, every cycle attempt built the whole-fleet union — on
# 2026-10-10 that union reached 111 MB — and only afterwards checked whether
# this node's own lock was already held. 16 of 23 `cycle-start`s on one node
# that day paid for the build only to then find the lock held and exit
# (`cycle-skipped`), which is the specific cost this test pins against
# reappearing: `skip_cycle_if_lock_fresh` (the common-case "already held, not
# stale" check) must run, and its own `exit 0` must be reachable, before
# `fleet_logs` ever materialises `$union_log`, and before the two readers
# that then have to make sense of it (`stage_budget_observations`, and the
# full `acquire_lock` that re-derives the precise stale threshold from it).
#
# This is a textual/structural check, the same approach
# test/label-marker-horizon-wiring.test.sh already uses for an analogous
# ordering question in this same file: there is no way to observe "the union
# was never built" from inside a stubbed partial run of this script without
# reimplementing most of its own setup, so the fact asserted here is a fact
# about the shipped script's line order, not about a captured runtime trace.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/lock-skip-before-union.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/agent-cycle.sh"

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

first_line_matching() { grep -n -m1 -- "$1" "$CYCLE" | cut -d: -f1; }

fast_check_def_line="$(first_line_matching '^skip_cycle_if_lock_fresh() {')"
fast_check_call_line="$(first_line_matching '^skip_cycle_if_lock_fresh$')"
# shellcheck disable=SC2016  # grep pattern: agent-cycle.sh's own literal `$union_log`.
union_snapshot_line="$(first_line_matching 'fleet_logs .* > "\$union_log"')"
# shellcheck disable=SC2016  # ditto.
stage_budget_read_line="$(first_line_matching 'stage_budget_observations < "\$union_log"')"
acquire_lock_call_line="$(first_line_matching '^acquire_lock$')"

assert_eq "the lock-held fast-path function is still defined" \
  "yes" "$([[ -n "$fast_check_def_line" ]] && echo yes || echo no)"
assert_eq "  ... and still called" \
  "yes" "$([[ -n "$fast_check_call_line" ]] && echo yes || echo no)"
assert_eq "the union snapshot is still where this test expects to find it" \
  "yes" "$([[ -n "$union_snapshot_line" ]] && echo yes || echo no)"
assert_eq "the stage-budget union read is still where this test expects to find it" \
  "yes" "$([[ -n "$stage_budget_read_line" ]] && echo yes || echo no)"
assert_eq "the full acquire_lock call is still where this test expects to find it" \
  "yes" "$([[ -n "$acquire_lock_call_line" ]] && echo yes || echo no)"

if [[ -z "$fast_check_def_line" || -z "$fast_check_call_line" \
      || -z "$union_snapshot_line" || -z "$stage_budget_read_line" \
      || -z "$acquire_lock_call_line" ]]; then
  printf '\n%d assertion(s) failed\n' "$(( failures + 1 ))" >&2
  echo "FAIL - could not locate the lock/union wiring in agent-cycle.sh — has it moved?" >&2
  exit 1
fi

assert_eq "the fast-path function is defined before it is called" \
  "yes" "$([[ "$fast_check_def_line" -lt "$fast_check_call_line" ]] && echo yes || echo no)"
assert_eq "the fast-path call precedes the union snapshot — no union read for an already-held lock" \
  "yes" "$([[ "$fast_check_call_line" -lt "$union_snapshot_line" ]] && echo yes || echo no)"
assert_eq "the fast-path call precedes the stage-budget union read too" \
  "yes" "$([[ "$fast_check_call_line" -lt "$stage_budget_read_line" ]] && echo yes || echo no)"
assert_eq "the fast-path call precedes the full acquire_lock call" \
  "yes" "$([[ "$fast_check_call_line" -lt "$acquire_lock_call_line" ]] && echo yes || echo no)"
assert_eq "the union snapshot precedes the stage-budget read that consumes it" \
  "yes" "$([[ "$union_snapshot_line" -lt "$stage_budget_read_line" ]] && echo yes || echo no)"

if (( failures )); then
  printf '\n%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall assertions passed\n'
