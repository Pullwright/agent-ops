#!/usr/bin/env bash
#
# test/disk-space-wiring.test.sh — regression test for requirement 2.0c's
# free-disk-space check in agent-cycle.sh (agent-ops#756; both directories,
# agent-ops#992): not whether disk_space_verdict classifies a shortfall
# correctly (test/disk-space.test.sh covers that in isolation) but whether the
# cycle actually acts on it — standing down with the right cause, path and
# reason, before the clone (and everything after it, the Co-Ordinator most of
# all) ever runs.
#
# The incident this guards: a node ran short of disk mid-clone / mid-push,
# leaving zero-length git objects in both nodes' state_dir mirrors,
# permanently disabling `git gc` (#604) — the state_dir half — and leaving
# 4.2 GB of orphaned clones behind it (#605) — the workspace_root half.
# `scripts/doctor.sh` had already read and warned about both directories;
# nothing acted on either warning until this check, and until agent-ops#992
# the check itself only ever acted on workspace_root's half.
#
# The block is lifted verbatim out of agent-cycle.sh, the way
# test/auth-failure-wiring.test.sh and test/backpressure-wiring.test.sh lift
# their own, so the assertions are about the shipped code rather than a copy
# of its logic.
#
# No network, no real disk read: lib/disk-space.sh is deliberately not
# sourced here. `disk_space_free_kb`, `disk_space_verdict`,
# `disk_space_describe` and `disk_space_same_filesystem` are all supplied as
# stubs below, so the free-KiB figures and the same-filesystem verdict the
# block sees are injected outright and no assertion depends on this host's
# real free space or real filesystem layout. What the real helpers compute is
# test/disk-space.test.sh's subject; this file's subject is only whether the
# shipped block acts on their verdicts, for both directories.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/disk-space-wiring.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_CYCLE="$SCRIPT_DIR/lib/standdown.sh"

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

extract_block() {
  local start_re="$1" end_re="$2" file="$3"
  BLOCK_START_RE="$start_re" BLOCK_END_RE="$end_re" awk '
    $0 ~ ENVIRON["BLOCK_START_RE"] { on = 1 }
    on                             { print }
    on && $0 ~ ENVIRON["BLOCK_END_RE"] { exit }
  ' "$file"
}

# Ends at 2.0f's own heading, not 2.1's: requirement 2.0f's free-memory gate
# (test/memory-wiring.test.sh) sits between them, and extracting through it
# would eval that block here too — where its helpers are not stubbed, so the
# fall-through cases below would abort under `set -e` and read as a false
# "never fell through".
disk_block="$(extract_block '^# 2\.0c Free disk space' '^# 2\.0f Free host memory' "$AGENT_CYCLE")"
if [[ -z "$disk_block" ]]; then
  echo "FAIL - could not extract the free-disk-space check block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
if ! grep -q 'disk_space_verdict' <<<"$disk_block"; then
  echo "FAIL - extracted block does not call disk_space_verdict — the anchors matched the wrong text" >&2
  exit 1
fi

FAKE_STATE_DIR="/fake/state"
FAKE_WORKSPACE_ROOT="/fake/workspace"

# run_block SAME_FS STATE_FREE_KB WORKSPACE_FREE_KB MIN_BYTES EVENT_FILE
# SAME_FS is "true"/"false", fed straight to the stubbed
# disk_space_same_filesystem. STATE_FREE_KB/WORKSPACE_FREE_KB are what the
# stubbed disk_space_free_kb reports for state_dir/workspace_root
# respectively — switched on the path argument the block itself passes, so a
# same-filesystem run that never reads state_dir's figure proves it by simply
# never being given the chance to use it. MIN_BYTES seeds
# min_free_workspace_bytes exactly as agent-cycle.sh's own cfg read would.
# Writes every log_event call, plus one "free_kb_call <path>" line per
# disk_space_free_kb call, to EVENT_FILE, and prints the block's own exit
# status followed by "FELL THROUGH" iff it ran off the end rather than
# exiting.
run_block() {
  local same_fs="$1" state_free_kb="$2" workspace_free_kb="$3" min_bytes="$4" event_file="$5"
  : > "$event_file"
  (
    # `-e`, matching agent-cycle.sh's own top-of-file flags exactly (not this
    # test file's own, looser `set -uo pipefail`): a stubbed helper that
    # returns non-zero for a benign reason would abort the block silently
    # under `-e` and read here as a false "FELL THROUGH never happened", the
    # same way it would abort a real cycle.
    set -euo pipefail
    # shellcheck disable=SC2034  # consumed by $disk_block below, invisible to a static reader
    state_dir="$FAKE_STATE_DIR"
    # shellcheck disable=SC2034  # consumed by $disk_block below, invisible to a static reader
    workspace_root="$FAKE_WORKSPACE_ROOT"
    # shellcheck disable=SC2034  # consumed by $disk_block below, invisible to a static reader
    min_free_workspace_bytes="$min_bytes"

    export EVENT_FILE="$event_file"
    export SAME_FS="$same_fs"
    export STATE_FREE_KB="$state_free_kb"
    export WORKSPACE_FREE_KB="$workspace_free_kb"
    export FAKE_STATE_DIR WORKSPACE_ROOT_PATH="$FAKE_WORKSPACE_ROOT"

    # shellcheck disable=SC2317  # called from $disk_block via eval, invisible to a static reader
    disk_space_same_filesystem() { [[ "$SAME_FS" == "true" ]]; }
    # shellcheck disable=SC2317  # called from $disk_block via eval, invisible to a static reader
    disk_space_free_kb() {
      printf 'free_kb_call\t%s\n' "$1" >> "$EVENT_FILE"
      case "$1" in
        "$FAKE_STATE_DIR") printf '%s' "$STATE_FREE_KB" ;;
        "$WORKSPACE_ROOT_PATH") printf '%s' "$WORKSPACE_FREE_KB" ;;
        *) printf '' ;;
      esac
    }
    # shellcheck disable=SC2317  # called from $disk_block via eval, invisible to a static reader
    disk_space_verdict() {
      local free="$1" min="$2"
      [[ "$min" =~ ^[0-9]+$ ]] || min=0
      (( min > 0 )) || { printf 'ok'; return 0; }
      [[ "$free" =~ ^[0-9]+$ ]] || { printf 'ok'; return 0; }
      if (( free < min / 1024 )); then printf 'low'; else printf 'ok'; fi
    }
    # shellcheck disable=SC2317  # called from $disk_block via eval, invisible to a static reader
    disk_space_describe() { printf '%s has only %s KiB free, below the %s bytes this cycle needs' "$1" "$2" "$3"; }

    # shellcheck disable=SC2317  # called from $disk_block via eval, invisible to a static reader
    log_event() {
      printf '%s\t%s\n' "$1" "${2:-{\}}" >> "$EVENT_FILE"
    }
    # docs/FLOW-SCHEMA.md, requirement 50, issue #597: the disk-space
    # stand-down also calls lib/node-time-state.sh's set_node_state_terminal.
    # Stubbed to a no-op — this file's own subject is the stand-down's cause
    # and reason, not the node-state record test/node-time-state.test.sh
    # covers directly.
    # shellcheck disable=SC2317  # called from $disk_block via eval, invisible to a static reader
    set_node_state_terminal() { :; }

    eval "$disk_block"
    printf 'FELL THROUGH\n' >> "$EVENT_FILE"
  )
  printf '%s' "$?"
}

free_kb_call_count() { grep -c '^free_kb_call' "$1" || true; }

# === Same filesystem: state_dir and workspace_root collapse to one reading ==

# --- below the floor, nonzero free space: cause is disk-low, one reading ---

evt_file="$tmp_dir/same-low-events"
block_rc="$(run_block true 9999999 1000 2147483648 "$evt_file")"
assert_eq "same-filesystem: free space below the floor stands the cycle down (exit 0, never falls through)" \
  "0" "$block_rc"
assert_eq "…and the block never runs off its own end into the rest of the cycle" \
  "no" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…taking exactly one disk_space_free_kb reading" \
  "1" "$(free_kb_call_count "$evt_file")"
standdown_line="$(grep '^stand-down' "$evt_file" || true)"
assert_eq "a stand-down event was logged" \
  "yes" "$(if [[ -n "$standdown_line" ]]; then echo yes; else echo no; fi)"
assert_eq "…with cause disk-low for a nonzero shortfall" \
  "yes" "$(if [[ "$standdown_line" == *'"cause":"disk-low"'* ]]; then echo yes; else echo no; fi)"
assert_eq "…naming workspace_root in the reason (byte-for-byte what a single-directory reading always produced)" \
  "yes" "$(if [[ "$standdown_line" == *"$FAKE_WORKSPACE_ROOT"* ]]; then echo yes; else echo no; fi)"

# --- exactly zero free space: cause is disk-full ---

evt_file="$tmp_dir/same-full-events"
block_rc="$(run_block true 9999999 0 2147483648 "$evt_file")"
assert_eq "same-filesystem: zero free space also stands the cycle down" "0" "$block_rc"
standdown_line="$(grep '^stand-down' "$evt_file" || true)"
assert_eq "…with cause disk-full at exactly zero" \
  "yes" "$(if [[ "$standdown_line" == *'"cause":"disk-full"'* ]]; then echo yes; else echo no; fi)"

# --- at or above the floor: falls through untouched, one reading ---

evt_file="$tmp_dir/same-ok-events"
block_rc="$(run_block true 9999999 9999999 2147483648 "$evt_file")"
assert_eq "same-filesystem: free space above the floor falls through to the rest of the cycle" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…still taking exactly one reading" \
  "1" "$(free_kb_call_count "$evt_file")"

# --- an unreadable df (empty free_kb): falls through, not standing down on a guess ---

evt_file="$tmp_dir/same-unknown-events"
block_rc="$(run_block true 9999999 '' 2147483648 "$evt_file")"
assert_eq "same-filesystem: an unreadable free-space read falls through rather than standing down on a guess" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"

# --- min_free_workspace_bytes: 0 turns the check off entirely, however low free space is ---

evt_file="$tmp_dir/same-disabled-events"
block_rc="$(run_block true 0 0 0 "$evt_file")"
assert_eq "a 0 floor turns the check off even at zero free space on both directories" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"

# === Different filesystems: each directory judged, and read, on its own ====

# --- state_dir alone below the floor: stands down naming state_dir ---

evt_file="$tmp_dir/split-state-low-events"
block_rc="$(run_block false 1000 9999999 2147483648 "$evt_file")"
assert_eq "split filesystems: state_dir alone below the floor stands the cycle down" \
  "0" "$block_rc"
assert_eq "…taking two readings (state_dir and workspace_root, on separate filesystems)" \
  "2" "$(free_kb_call_count "$evt_file")"
standdown_line="$(grep '^stand-down' "$evt_file" || true)"
assert_eq "…naming state_dir, not workspace_root" \
  "yes" "$(if [[ "$standdown_line" == *"\"path\":\"$FAKE_STATE_DIR\""* ]]; then echo yes; else echo no; fi)"
assert_eq "…with cause disk-low for a nonzero shortfall" \
  "yes" "$(if [[ "$standdown_line" == *'"cause":"disk-low"'* ]]; then echo yes; else echo no; fi)"

# --- state_dir alone at exactly zero: cause disk-full ---

evt_file="$tmp_dir/split-state-full-events"
block_rc="$(run_block false 0 9999999 2147483648 "$evt_file")"
standdown_line="$(grep '^stand-down' "$evt_file" || true)"
assert_eq "split filesystems: state_dir alone at exactly zero free space stands down as disk-full" \
  "yes" "$(if [[ "$standdown_line" == *'"cause":"disk-full"'* ]]; then echo yes; else echo no; fi)"

# --- workspace_root alone below the floor: stands down naming workspace_root ---

evt_file="$tmp_dir/split-workspace-low-events"
block_rc="$(run_block false 9999999 1000 2147483648 "$evt_file")"
assert_eq "split filesystems: workspace_root alone below the floor stands the cycle down" \
  "0" "$block_rc"
standdown_line="$(grep '^stand-down' "$evt_file" || true)"
assert_eq "…naming workspace_root, not state_dir" \
  "yes" "$(if [[ "$standdown_line" == *"\"path\":\"$FAKE_WORKSPACE_ROOT\""* ]]; then echo yes; else echo no; fi)"

# --- both short: the event names whichever has less free space (state_dir shorter) ---

evt_file="$tmp_dir/split-both-state-shorter-events"
run_block false 500 1500 2147483648 "$evt_file" > /dev/null
standdown_line="$(grep '^stand-down' "$evt_file" || true)"
assert_eq "split filesystems: both short, state_dir has less free space — event names state_dir" \
  "yes" "$(if [[ "$standdown_line" == *"\"path\":\"$FAKE_STATE_DIR\""* && "$standdown_line" == *'"free_kb":"500"'* ]]; then echo yes; else echo no; fi)"

# --- both short: the event names whichever has less free space (workspace_root shorter) ---

evt_file="$tmp_dir/split-both-workspace-shorter-events"
run_block false 1500 500 2147483648 "$evt_file" > /dev/null
standdown_line="$(grep '^stand-down' "$evt_file" || true)"
assert_eq "split filesystems: both short, workspace_root has less free space — event names workspace_root" \
  "yes" "$(if [[ "$standdown_line" == *"\"path\":\"$FAKE_WORKSPACE_ROOT\""* && "$standdown_line" == *'"free_kb":"500"'* ]]; then echo yes; else echo no; fi)"

# --- both at or above the floor: falls through untouched ---

evt_file="$tmp_dir/split-ok-events"
block_rc="$(run_block false 9999999 9999999 2147483648 "$evt_file")"
assert_eq "split filesystems: both directories at or above the floor fall through" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and stand nothing down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"

# --- state_dir unreadable, workspace_root ok: falls through — no evidence, no stand-down ---

evt_file="$tmp_dir/split-state-unreadable-events"
block_rc="$(run_block false '' 9999999 2147483648 "$evt_file")"
assert_eq "split filesystems: an unreadable state_dir reading (workspace_root ok) falls through" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"

# --- state_dir unreadable, workspace_root low: stands down on workspace_root's own evidence ---

evt_file="$tmp_dir/split-state-unreadable-workspace-low-events"
block_rc="$(run_block false '' 1000 2147483648 "$evt_file")"
standdown_line="$(grep '^stand-down' "$evt_file" || true)"
assert_eq "split filesystems: state_dir unreadable but workspace_root low still stands the cycle down" \
  "yes" "$(if [[ -n "$standdown_line" ]]; then echo yes; else echo no; fi)"
assert_eq "…naming workspace_root, the one directory with real evidence" \
  "yes" "$(if [[ "$standdown_line" == *"\"path\":\"$FAKE_WORKSPACE_ROOT\""* ]]; then echo yes; else echo no; fi)"

# --- min_free_workspace_bytes: 0 turns the check off even on split filesystems ---

evt_file="$tmp_dir/split-disabled-events"
block_rc="$(run_block false 0 0 0 "$evt_file")"
assert_eq "a 0 floor turns the check off on split filesystems too, however low free space is" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"

echo
if (( failures == 0 )); then
  echo "All disk-space-wiring assertions passed."
  exit 0
else
  echo "$failures disk-space-wiring assertion(s) FAILED."
  exit 1
fi
