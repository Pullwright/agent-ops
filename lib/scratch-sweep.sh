#!/usr/bin/env bash
#
# lib/scratch-sweep.sh — reclaim the per-process scratch directories a dead
# process left in the container's writable layer.
#
# Two things write a directory of their own under $TMPDIR and cannot always
# remove it: scripts/publish-dashboard.sh's working set
# (`publish-dashboard.<pid>.XXXXXX`, 300 MB and more on a fleet with a month
# of log, and since agent-ops#1827 the home of every other file a publish
# spools) and lib/toggle.sh's flag memos (`agent-ops-fleet-flag-memo.<pid>`,
# small). Each carries its owner's pid in its name for this reason: whether
# that pid is still alive is a local, instant test, and the only one that
# cannot mistake a slow live publish for an orphan — an age threshold would,
# and a publish on a loaded node has run for hours (agent-ops#1620). The
# writable layer shares the host's disk with the state volumes, so an orphan
# there is disk the pressure valve of requirement 2.5 cannot reclaim: that
# valve can shed only its own derived files (agent-ops#1827).
#
# The test is "does the pid exist", never "may this process signal it":
# `kill -0` answers EPERM for another user's live process, which must read as
# alive, so `/proc/<pid>` is consulted first and `kill -0` only confirms.
# PIDs are recycled, so a name whose pid is alive again may in fact be an
# orphan adopted by an unrelated process; it stays, and the sweep after that
# process exits takes it. The other direction — removing a live process's
# directory — is the one this must never take, and a pid that exists is never
# read as dead.
#
#   scratch_sweep_dead_owners [DIR]
#       Remove every orphan under DIR (default ${TMPDIR:-/tmp}). Prints the
#       number removed. Exits 0 always: a sweep that cannot run must never
#       fail the cycle that called it.

# _scratch_pid_alive PID
_scratch_pid_alive() {
  [[ -e "/proc/$1" ]] || kill -0 "$1" 2>/dev/null
}

# shellcheck disable=SC2120  # DIR is optional; agent-cycle.sh passes none, the tests do
scratch_sweep_dead_owners() {
  local dir="${1:-${TMPDIR:-/tmp}}" d name pid removed=0
  [[ -d "$dir" ]] || { printf '0\n'; return 0; }
  for d in "$dir"/publish-dashboard.* "$dir"/agent-ops-fleet-flag-memo.*; do
    [[ -d "$d" ]] || continue
    name="${d##*/}"
    case "$name" in
      publish-dashboard.*)
        pid="${name#publish-dashboard.}"
        pid="${pid%%.*}" ;;
      agent-ops-fleet-flag-memo.*)
        pid="${name#agent-ops-fleet-flag-memo.}" ;;
      *) continue ;;
    esac
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    _scratch_pid_alive "$pid" && continue
    if rm -rf -- "$d" 2>/dev/null; then
      removed=$(( removed + 1 ))
    fi
  done
  printf '%s\n' "$removed"
  return 0
}
