#!/usr/bin/env bash
#
# test/memory-throttle-wiring.test.sh — regression test for requirement
# 2.0i's parent-cgroup memory-throttle check (agent-ops#2469): not whether
# lib/memory.sh's own rate/headroom arithmetic is correct (test/memory.test.sh
# covers that in isolation) but whether `lib/standdown.sh`'s own
# `memory_throttle_check` actually acts on it — standing down with the right
# cause and reason, escalating after enough consecutive firings, and retiring
# that escalation once a cycle reads clean.
#
# The gap this closes: requirement 2.0f reads the *host's* own MemAvailable,
# which cannot see a node whose *parent* cgroup is throttling it under
# memory.high while the host itself has memory free — `doctor.sh` has warned
# on this for a long time and nothing ever stood a cycle down on it.
#
# Unlike test/memory-wiring.test.sh's extract-and-eval technique (the check it
# covers is an inline block), `memory_throttle_check` and its own
# `_memory_throttle_escalate` helper are defined at file scope in
# lib/standdown.sh precisely so they can be called from two places — sourcing
# the whole file only defines them (no top-level code runs), so this test
# sources the shipped file directly and then calls the real function, with
# every dependency it reaches for (`memory_cgroup_*`, `log_event`,
# `set_node_state_terminal`, `create_escalation_issue`,
# `memory_throttle_retire_resolved`) stubbed below — the same division of
# labour test/memory-wiring.test.sh already draws between "what the real
# helpers compute" and "whether the shipped block acts on their verdict".
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/memory-throttle-wiring.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STANDDOWN="$SCRIPT_DIR/lib/standdown.sh"

failures=0
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

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
    printf 'FAIL - %s (%q not found in %q)\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

if ! grep -q '^memory_throttle_check()' "$STANDDOWN"; then
  echo "FAIL - memory_throttle_check is no longer defined in lib/standdown.sh — has it moved?" >&2
  exit 1
fi

# run_check THROTTLE_VERDICT HEADROOM_VERDICT ESCALATE_AFTER PREV_CONSECUTIVE [DRY_RUN] [RETIRE_RC]
# Sources the real lib/standdown.sh (which only defines functions; nothing in
# it executes at source time) into a fresh subshell, stubs every dependency
# memory_throttle_check and _memory_throttle_escalate reach for, seeds the
# globals agent-cycle.sh's own spine would already have set — including a
# gate-owned state file pre-seeded with PREV_CONSECUTIVE when it is positive,
# standing in for a previous cycle's own reading — and calls the real
# function once. Every stubbed call lands in $calls_file (one line per call,
# tab-separated), followed by "FELL THROUGH" iff the function returned rather
# than exiting the process — the same contract test/memory-wiring.test.sh's
# own run_block already uses. Prints the function's own exit status.
#
# RETIRE_RC is the exit status the stubbed `memory_throttle_retire_resolved`
# returns — `0` (the default) for a close that landed, non-zero for one of
# the three windows the real function returns non-zero for and logs "will
# retry next cycle" against. The gate-owned state file this call leaves
# behind is readable at $mt_state_path afterwards, which is what the
# retry-reachability assertions below read: the count persisted there is the
# only thing that ever brings a later cycle back to a forfeited close.
calls_file="$tmp_dir/calls"
mt_state_path="$tmp_dir/state/.memory-cgroup-throttle-state"
run_check() {
  local throttle_verdict="$1" headroom_verdict="$2" escalate_after="$3" \
    prev_consecutive="$4" dry_run="${5:-0}" retire_rc="${6:-0}"
  local state_dir="$tmp_dir/state"
  rm -rf "$state_dir"; mkdir -p "$state_dir"
  : > "$calls_file"
  if (( prev_consecutive > 0 )); then
    printf '1000\t500\t%s\n' "$prev_consecutive" > "$state_dir/.memory-cgroup-throttle-state"
  fi
  (
    set -euo pipefail
    export THROTTLE_VERDICT="$throttle_verdict" HEADROOM_VERDICT="$headroom_verdict" \
      CALLS_FILE="$calls_file" RETIRE_RC="$retire_rc"
    # shellcheck disable=SC1090
    . "$STANDDOWN"

    # shellcheck disable=SC2034  # consumed by memory_throttle_check below, invisible to a static reader
    max_cgroup_throttle_per_minute=10000
    # Non-zero so the real function always calls the stubbed
    # memory_cgroup_headroom_verdict below (which ignores the threshold and
    # returns $HEADROOM_VERDICT regardless) — the actual value never matters
    # here since lib/memory.sh's own real arithmetic is test/memory.test.sh's
    # subject, not this file's.
    # shellcheck disable=SC2034
    min_cgroup_headroom_bytes=1
    # shellcheck disable=SC2034
    memory_throttle_escalate_after="$escalate_after"
    # shellcheck disable=SC2034
    node_name="node-x"
    # shellcheck disable=SC2034
    cycle_id="cycle-1"
    # shellcheck disable=SC2034
    cycle_dir="$tmp_dir"
    # shellcheck disable=SC2034
    crash_loop_repo="Poetic-Poems/poetic"
    # shellcheck disable=SC2034
    enabler_assignee="warwickallen"
    # shellcheck disable=SC2034
    enabler_escalation_label="enabler"
    # shellcheck disable=SC2034
    DRY_RUN="$dry_run"

    # shellcheck disable=SC2317  # called from the real memory_throttle_check, invisible to a static reader
    memory_cgroup_parent_events_high() { printf '600'; }
    # shellcheck disable=SC2317
    memory_cgroup_field() { printf '100'; }
    # shellcheck disable=SC2317
    memory_cgroup_parent_high() { printf '200'; }
    # shellcheck disable=SC2317
    memory_cgroup_throttle_rate_per_min() { printf '42'; }
    # shellcheck disable=SC2317
    memory_cgroup_throttle_verdict() { printf '%s' "$THROTTLE_VERDICT"; }
    # shellcheck disable=SC2317
    memory_cgroup_throttle_describe() { printf 'the rate is too high'; }
    # shellcheck disable=SC2317
    memory_cgroup_headroom_verdict() { printf '%s' "$HEADROOM_VERDICT"; }
    # shellcheck disable=SC2317
    memory_cgroup_headroom_describe() { printf 'too close to the ceiling'; }

    # shellcheck disable=SC2317
    log_event() { printf 'log_event\t%s\t%s\n' "$1" "${2:-{\}}" >> "$CALLS_FILE"; }
    # shellcheck disable=SC2317
    set_node_state_terminal() { printf 'set_node_state_terminal\t%s\t%s\n' "$1" "$2" >> "$CALLS_FILE"; }
    # shellcheck disable=SC2317
    create_escalation_issue() {
      printf 'create_escalation_issue\t%s\t%s\n' "$1" "$2" >> "$CALLS_FILE"
      printf '42\thttps://github.com/x/y/issues/42'
    }
    # shellcheck disable=SC2317
    memory_throttle_retire_resolved() {
      printf 'memory_throttle_retire_resolved\t%s\t%s\n' "$1" "$2" >> "$CALLS_FILE"
      return "$RETIRE_RC"
    }

    memory_throttle_check
    printf 'FELL THROUGH\n' >> "$CALLS_FILE"
  )
  printf '%s' "$?"
}

# --- throttling: stands the cycle down ---

rc="$(run_check throttling ok 0 0)"
assert_eq "a 'throttling' rate verdict stands the cycle down (exit 0)" "0" "$rc"
assert_eq "…and never falls through to the rest of the cycle" \
  "no" "$(if grep -q 'FELL THROUGH' "$calls_file"; then echo yes; else echo no; fi)"
standdown_line="$(grep '^log_event	stand-down' "$calls_file" || true)"
assert_eq "a stand-down event was logged" \
  "yes" "$(if [[ -n "$standdown_line" ]]; then echo yes; else echo no; fi)"
assert_eq "…with cause memory-throttled" \
  "yes" "$(if [[ "$standdown_line" == *'"cause":"memory-throttled"'* ]]; then echo yes; else echo no; fi)"
assert_eq "…and the terminal node state carries the same cause" \
  "yes" "$(if grep -q '^set_node_state_terminal	externally-blocked	memory-throttled' "$calls_file"; then echo yes; else echo no; fi)"

# --- near-ceiling (headroom) alone also trips it ---

rc="$(run_check ok near-ceiling 0 0)"
assert_eq "a 'near-ceiling' headroom verdict also stands the cycle down" "0" "$rc"
assert_eq "…with cause memory-throttled too" \
  "yes" "$(if grep -q '"cause":"memory-throttled"' "$calls_file"; then echo yes; else echo no; fi)"

# --- ok: falls through, standing nothing down ---

rc="$(run_check ok ok 0 0)"
assert_eq "both verdicts ok falls through to the rest of the cycle" \
  "yes" "$(if grep -q 'FELL THROUGH' "$calls_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q 'stand-down' "$calls_file"; then echo yes; else echo no; fi)"

# --- empty (no evidence): falls through, never standing down on a guess ---

rc="$(run_check "" "" 0 0)"
assert_eq "no evidence (empty verdicts) falls through rather than standing down on a guess" \
  "yes" "$(if grep -q 'FELL THROUGH' "$calls_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q 'stand-down' "$calls_file"; then echo yes; else echo no; fi)"

# --- escalation: files once the consecutive count reaches the threshold ---

rc="$(run_check throttling ok 3 2)"
assert_eq "the third consecutive firing (threshold 3) stands down" "0" "$rc"
assert_eq "…and escalates, naming this node's own item ref" \
  "yes" "$(if grep -q '^create_escalation_issue' "$calls_file"; then echo yes; else echo no; fi)"
escalate_call="$(grep '^create_escalation_issue' "$calls_file" || true)"
assert_contains "…the escalation names memory-throttled:<node>" "memory-throttled:node-x" "$escalate_call"

# --- escalation: not yet at the threshold, no escalation filed ---

rc="$(run_check throttling ok 3 0)"
assert_eq "the first consecutive firing (threshold 3) still stands down" "0" "$rc"
assert_eq "…but does not escalate yet" \
  "no" "$(if grep -q '^create_escalation_issue' "$calls_file"; then echo yes; else echo no; fi)"

# --- escalation: disabled (0) never files regardless of the count ---

rc="$(run_check throttling ok 0 10)"
assert_eq "memory_throttle_escalate_after: 0 never escalates" \
  "no" "$(if grep -q '^create_escalation_issue' "$calls_file"; then echo yes; else echo no; fi)"

# --- escalation: suppressed under --dry-run ---

rc="$(run_check throttling ok 3 5 1)"
assert_eq "--dry-run still stands the cycle down" "0" "$rc"
assert_eq "…but never files an escalation" \
  "no" "$(if grep -q '^create_escalation_issue' "$calls_file"; then echo yes; else echo no; fi)"

# --- retirement: a clean reading after reaching the threshold retires ---

rc="$(run_check ok ok 3 3)"
assert_eq "a clean reading after reaching the threshold falls through" \
  "yes" "$(if grep -q 'FELL THROUGH' "$calls_file"; then echo yes; else echo no; fi)"
assert_eq "…and calls the retirement function" \
  "yes" "$(if grep -q '^memory_throttle_retire_resolved' "$calls_file"; then echo yes; else echo no; fi)"

# --- retirement: a clean reading that never reached the threshold does not
#     bother looking for anything to retire ---

rc="$(run_check ok ok 3 1)"
assert_eq "a clean reading below the threshold never calls the retirement function" \
  "no" "$(if grep -q '^memory_throttle_retire_resolved' "$calls_file"; then echo yes; else echo no; fi)"

# --- retirement: suppressed under --dry-run ---

rc="$(run_check ok ok 3 3 1)"
assert_eq "--dry-run suppresses the retirement lookup too" \
  "no" "$(if grep -q '^memory_throttle_retire_resolved' "$calls_file"; then echo yes; else echo no; fi)"

# --- retirement: never on an empty verdict ------------------------------
#
# An unreadable parent window is the very condition an open escalation here
# is about, not evidence that it has cleared. Retiring on silence would
# close a live escalation on a node that is still throttling — and is
# exactly what the consecutive count's own "silence must never retire an
# alarm" rule already refuses to do for the count itself.
rc="$(run_check "" "" 3 3)"
assert_eq "an empty verdict above the threshold never retires the escalation" \
  "no" "$(if grep -q '^memory_throttle_retire_resolved' "$calls_file"; then echo yes; else echo no; fi)"
assert_eq "…and leaves the consecutive count exactly where it was" \
  "3" "$(cut -f3 "$mt_state_path")"

# --- retirement: a failed close stays reachable next cycle --------------
#
# The regression agent-ops#2511 fixed for 0h, in 0i's own shape: the
# `mt_prev_consecutive >= memory_throttle_escalate_after` test is the only
# thing that ever brings this node back to the close, so a count persisted
# as `0` alongside a close that failed would forfeit the escalation for the
# container's whole remaining lifetime — while
# `memory_throttle_retire_resolved` logs "will retry next cycle" against it.
rc="$(run_check ok ok 3 3 0 0)"
assert_eq "a clean reading whose close succeeded clears the consecutive count" \
  "0" "$(cut -f3 "$mt_state_path")"

rc="$(run_check ok ok 3 3 0 1)"
assert_eq "a clean reading whose close failed still attempted it" \
  "yes" "$(if grep -q '^memory_throttle_retire_resolved' "$calls_file"; then echo yes; else echo no; fi)"
assert_eq "…and keeps the consecutive count, so the next cycle reaches the close again" \
  "3" "$(cut -f3 "$mt_state_path")"

rc="$(run_check ok ok 3 3 1)"
assert_eq "--dry-run, which never attempts the close, keeps the count for a real cycle to retire" \
  "3" "$(cut -f3 "$mt_state_path")"

echo
if (( failures == 0 )); then
  echo "All memory-throttle-wiring assertions passed."
  exit 0
else
  echo "$failures memory-throttle-wiring assertion(s) FAILED."
  exit 1
fi
