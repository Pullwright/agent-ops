#!/usr/bin/env bash
#
# test/scratch-sweep.test.sh — regression test for lib/scratch-sweep.sh: the
# cycle-start sweep of per-process scratch directories whose owner is dead
# (docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 2.5, agent-ops#1827).
#
# The property under test is the direction of every possible mistake: a
# directory under a dead pid goes, and one under a live pid — or one this
# sweep was never told about — stays, however old it is. Everything runs
# against a private directory, so nothing here depends on this host's /tmp.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/scratch-sweep.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/scratch-sweep.sh
. "$SCRIPT_DIR/lib/scratch-sweep.sh"

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
dir="$tmp/scratch"
mkdir -p "$dir/publish-dashboard.$dead.AbC123" \
         "$dir/agent-ops-fleet-flag-memo.$dead" \
         "$dir/publish-dashboard.$$.LiVe01" \
         "$dir/agent-ops-fleet-flag-memo.$$" \
         "$dir/tmp.SomethingElse" \
         "$dir/publish-dashboard.notapid.X"
: > "$dir/publish-dashboard.$dead.AbC123/events.jsonl"
: > "$dir/publish-dashboard.$dead.plainfile"

# --- One sweep over the lot ---------------------------------------------------------
out="$(scratch_sweep_dead_owners "$dir")"
assert_eq "the sweep counts the two directories it removed" "2" "$out"
assert_eq "a publisher working set under a dead pid is removed" \
  "no" "$(present "$dir/publish-dashboard.$dead.AbC123")"
assert_eq "a toggle memo root under a dead pid is removed" \
  "no" "$(present "$dir/agent-ops-fleet-flag-memo.$dead")"
assert_eq "a publisher working set under a live pid is kept" \
  "yes" "$(present "$dir/publish-dashboard.$$.LiVe01")"
assert_eq "a toggle memo root under a live pid is kept" \
  "yes" "$(present "$dir/agent-ops-fleet-flag-memo.$$")"
assert_eq "a directory of another name is never touched" \
  "yes" "$(present "$dir/tmp.SomethingElse")"
assert_eq "a name whose pid field is not a number is kept" \
  "yes" "$(present "$dir/publish-dashboard.notapid.X")"
assert_eq "a plain file under a dead pid is not a scratch directory, and is kept" \
  "yes" "$([[ -f "$dir/publish-dashboard.$dead.plainfile" ]] && echo yes || echo no)"

# --- Idempotent, and the default location is $TMPDIR -----------------------------------
out="$(scratch_sweep_dead_owners "$dir")"
assert_eq "a second sweep finds nothing further to remove" "0" "$out"
mkdir -p "$dir/agent-ops-fleet-flag-memo.$dead"
out="$(TMPDIR="$dir" scratch_sweep_dead_owners)"
assert_eq "without an argument the sweep reads \$TMPDIR" "1" "$out"

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
