#!/usr/bin/env bash
#
# test/scratch.test.sh — regression test for lib/scratch.sh: the per-process
# scratch directory every entry point enters, and the sweep of the ones dead
# processes leave (docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 2.5,
# agent-ops#1827).
#
# The property under test is the direction of every possible mistake: a
# directory under a dead pid goes, and one under a live pid — or one this
# sweep was never told about, or one whose liveness cannot be established —
# stays, however old it is. Everything runs against a private directory, so
# nothing here depends on this host's /tmp.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/scratch.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/scratch.sh
. "$SCRIPT_DIR/lib/scratch.sh"

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (expected %q, got %q)\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# "yes" if DIR exists as a directory, else "no".
present() { if [[ -d "$1" ]]; then printf 'yes'; else printf 'no'; fi; }

# A pid nothing holds, in this namespace (the same search
# test/publish-dashboard.test.sh uses for its lock-liveness cases).
dead_pid() {
  local p
  for (( p = $(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 32768) - 1; p > 300; p-- )); do
    kill -0 "$p" 2>/dev/null || { printf '%s' "$p"; return 0; }
  done
  printf '4194303'
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
dead="$(dead_pid)"

# --- Entering and releasing a scratch directory ----------------------------------------
# Run in a child so that the TMPDIR it exports and the traps it arms are its
# own; what it prints is what the parent asserts on.
base="$tmp/base"; mkdir -p "$base"
enter_out="$(TMPDIR="$base" bash -c '
  . "$1/lib/scratch.sh"
  SCRATCH_DIR=""
  trap scratch_release EXIT
  scratch_enter unit-test || { echo "enter failed"; exit 1; }
  printf "dir=%s\n" "$SCRATCH_DIR"
  printf "base=%s\n" "$SCRATCH_BASE"
  printf "tmpdir-inside=%s\n" "$TMPDIR"
  printf "mktemp-lands-inside=%s\n" "$(mktemp)"
  scratch_release
  printf "tmpdir-after=%s\n" "$TMPDIR"
  printf "dir-after=%s\n" "$([[ -d "$SCRATCH_DIR" || -n "$SCRATCH_DIR" ]] && echo present || echo gone)"
' _ "$SCRIPT_DIR")"
entered_dir="$(sed -n 's/^dir=//p' <<<"$enter_out")"
assert_eq "scratch_enter makes agent-ops.<name>.<pid>.XXXXXX under the prior TMPDIR" \
  "yes" "$([[ "$entered_dir" =~ ^"$base"/agent-ops\.unit-test\.[0-9]+\.[A-Za-z0-9]{6}$ ]] && echo yes || echo "no: $entered_dir")"
assert_eq "…records the directory it was made in as SCRATCH_BASE" "$base" "$(sed -n 's/^base=//p' <<<"$enter_out")"
assert_eq "…and exports TMPDIR pointing inside it" "$entered_dir" "$(sed -n 's/^tmpdir-inside=//p' <<<"$enter_out")"
assert_eq "…so a plain mktemp from then on lands inside it" \
  "yes" "$([[ "$(sed -n 's/^mktemp-lands-inside=//p' <<<"$enter_out")" == "$entered_dir"/* ]] && echo yes || echo no)"
assert_eq "scratch_release puts TMPDIR back" "$base" "$(sed -n 's/^tmpdir-after=//p' <<<"$enter_out")"
assert_eq "…clears SCRATCH_DIR" "gone" "$(sed -n 's/^dir-after=//p' <<<"$enter_out")"
assert_eq "…and the directory is gone from the base" "no" "$(present "$entered_dir")"
assert_eq "…leaving the base empty" "" "$(ls -A "$base")"

# TMPDIR unset beforehand: released as unset, not as an empty string.
# shellcheck disable=SC2016  # the child expands these, as in the block above
unset_out="$(env -u TMPDIR bash -c '
  . "$1/lib/scratch.sh"
  SCRATCH_DIR=""; trap scratch_release EXIT
  scratch_enter unit-test || exit 1
  printf "%s\n" "${TMPDIR:-unset}"
  scratch_release
  printf "%s\n" "${TMPDIR-unset}"
' _ "$SCRIPT_DIR")"
assert_eq "with TMPDIR unset beforehand the directory is made under /tmp" \
  "yes" "$([[ "$(sed -n 1p <<<"$unset_out")" == /tmp/agent-ops.unit-test.* ]] && echo yes || echo no)"
assert_eq "…and TMPDIR is unset again after the release, not set to an empty string" \
  "unset" "$(sed -n 2p <<<"$unset_out")"

# An unwritable base: the call fails, says so, and leaves TMPDIR alone.
ro="$tmp/read-only"; mkdir -p "$ro"; chmod 0555 "$ro"
if [[ "$(id -u)" -eq 0 ]]; then
  printf 'skip - an unwritable base cannot be arranged as root; the failure path is not exercised here\n'
else
  fail_out="$(TMPDIR="$ro" bash -c '
    . "$1/lib/scratch.sh"
    SCRATCH_DIR=""; trap scratch_release EXIT
    if scratch_enter unit-test 2>"$2/enter.err"; then echo "entered"; else echo "refused rc=$?"; fi
    printf "%s\n" "$TMPDIR"
  ' _ "$SCRIPT_DIR" "$tmp")"
  assert_eq "a base that cannot be written into refuses the call with exit 1" "refused rc=1" "$(sed -n 1p <<<"$fail_out")"
  assert_eq "…says so on stderr, naming the caller and the base" \
    "unit-test: cannot make a scratch directory in $ro" "$(cat "$tmp/enter.err")"
  assert_eq "…and leaves TMPDIR as it was" "$ro" "$(sed -n 2p <<<"$fail_out")"
fi
chmod 0755 "$ro"

# --- One sweep over the lot ---------------------------------------------------------
dir="$tmp/scratch"
mkdir -p "$dir/agent-ops.publish-dashboard.$dead.AbC123" \
         "$dir/agent-ops.agent-cycle.$dead.DeF456" \
         "$dir/agent-ops-fleet-flag-memo.$dead" \
         "$dir/.agent-ops-sweep.$dead.agent-ops.review-cycle.$dead.GhI789" \
         "$dir/agent-ops.publish-dashboard.$$.LiVe01" \
         "$dir/agent-ops-fleet-flag-memo.$$" \
         "$dir/.agent-ops-sweep.$$.agent-ops.doctor.$dead.JkL012" \
         "$dir/tmp.SomethingElse" \
         "$dir/agent-ops.publish-dashboard.notapid.X"
: > "$dir/agent-ops.publish-dashboard.$dead.AbC123/events.jsonl"
: > "$dir/agent-ops.publish-dashboard.$dead.plainfile"

out="$(scratch_sweep_dead_owners "$dir")"
assert_eq "the sweep counts the four directories it removed" "4" "$out"
assert_eq "a publisher working set under a dead pid is removed" \
  "no" "$(present "$dir/agent-ops.publish-dashboard.$dead.AbC123")"
assert_eq "a cycle's scratch directory under a dead pid is removed" \
  "no" "$(present "$dir/agent-ops.agent-cycle.$dead.DeF456")"
assert_eq "a toggle memo root under a dead pid is removed" \
  "no" "$(present "$dir/agent-ops-fleet-flag-memo.$dead")"
assert_eq "a tombstone a dead sweep left is removed" \
  "no" "$(present "$dir/.agent-ops-sweep.$dead.agent-ops.review-cycle.$dead.GhI789")"
assert_eq "a publisher working set under a live pid is kept" \
  "yes" "$(present "$dir/agent-ops.publish-dashboard.$$.LiVe01")"
assert_eq "a toggle memo root under a live pid is kept" \
  "yes" "$(present "$dir/agent-ops-fleet-flag-memo.$$")"
assert_eq "a tombstone of a sweep still running is kept" \
  "yes" "$(present "$dir/.agent-ops-sweep.$$.agent-ops.doctor.$dead.JkL012")"
assert_eq "a directory of another name is never touched" \
  "yes" "$(present "$dir/tmp.SomethingElse")"
assert_eq "a name whose pid field is not a number is kept" \
  "yes" "$(present "$dir/agent-ops.publish-dashboard.notapid.X")"
assert_eq "a plain file under a dead pid is not a scratch directory, and is kept" \
  "yes" "$([[ -f "$dir/agent-ops.publish-dashboard.$dead.plainfile" ]] && echo yes || echo no)"
own_tombs=""
for t in "$dir"/.agent-ops-sweep."$$".*; do [[ -d "$t" && "$t" != *JkL012 ]] && own_tombs+="${t##*/} "; done
assert_eq "no tombstone of this sweep's own is left behind" "" "$own_tombs"

# --- Idempotent, and the default location ----------------------------------------------
out="$(scratch_sweep_dead_owners "$dir")"
assert_eq "a second sweep finds nothing further to remove" "0" "$out"
mkdir -p "$dir/agent-ops-fleet-flag-memo.$dead"
out="$(TMPDIR="$dir" scratch_sweep_dead_owners)"
assert_eq "without an argument, in a process that entered no scratch directory, the sweep reads \$TMPDIR" "1" "$out"
mkdir -p "$dir/agent-ops-fleet-flag-memo.$dead"
out="$(TMPDIR="$dir" bash -c '
  . "$1/lib/scratch.sh"
  SCRATCH_DIR=""; trap scratch_release EXIT
  scratch_enter unit-test || exit 1
  scratch_sweep_dead_owners      # TMPDIR now points inside this process'"'"'s own directory
' _ "$SCRIPT_DIR")"
assert_eq "…and in a process that did, it reads the base that directory was made in, not the directory itself" "1" "$out"
unit_dirs=""
for t in "$dir"/agent-ops.unit-test.*; do [[ -e "$t" ]] && unit_dirs+="${t##*/} "; done
assert_eq "…which the process's own live directory survives (released on its exit)" "" "$unit_dirs"

# --- A pid this process may not signal is alive, however /proc answers -----------------
# `kill -0` on another user's process fails with EPERM, and under a /proc
# mounted with hidepid the /proc entry is hidden too. A `kill` function
# shadows the builtin for the library's call, answering EPERM for the dead
# pid, whose /proc entry is genuinely absent: the directory must stay.
mkdir -p "$dir/agent-ops.publish-dashboard.$dead.EpErM1"
kill() { if [[ "${1:-}" == -0 && "${2:-}" == "$dead" ]]; then echo "kill: ($2) - Operation not permitted" >&2; return 1; fi; builtin kill "$@"; }
out="$(scratch_sweep_dead_owners "$dir")"
unset -f kill
assert_eq "a pid whose kill -0 answers EPERM is read as alive and its directory is kept" \
  "yes" "$(present "$dir/agent-ops.publish-dashboard.$dead.EpErM1")"
assert_eq "…and counted as nothing removed" "0" "$out"
rm -rf "$dir/agent-ops.publish-dashboard.$dead.EpErM1"

# --- A missing directory is not a failure ----------------------------------------------
out="$(scratch_sweep_dead_owners "$tmp/does-not-exist")"
rc=$?
assert_eq "a missing directory yields a count of zero" "0" "$out"
assert_eq "…and exit 0" "0" "$rc"

# ---------------------------------------------------------------------------------
if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
