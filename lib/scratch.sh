#!/usr/bin/env bash
#
# lib/scratch.sh — one scratch directory per process, and the sweep that
# reclaims the ones dead processes leave.
#
# Every scheduled entry point (agent-cycle.sh, review-cycle.sh,
# monitor-cycle.sh, scripts/doctor.sh, scripts/state-sync.sh) and the
# dashboard Publisher (scripts/publish-dashboard.sh) starts by calling
# `scratch_enter NAME`, which makes `agent-ops.NAME.<pid>.XXXXXX` under
# $TMPDIR and points TMPDIR at it for the rest of the process. From then on
# everything the process or any library it calls spools through `mktemp` —
# lib/item-lifecycle.sh's and lib/node-time-state.sh's union files,
# lib/gh-shim.sh's per-call directories, lib/issue-priority.sh's cache,
# lib/toggle.sh's flag memos, `sort`'s spill files — lands inside that one
# directory, and `scratch_release`, called from the process's EXIT trap,
# removes the lot with one `rm -rf`. bash runs the EXIT trap on `exit`, on a
# failing command under `set -e` and on an untrapped fatal signal alike, so a
# process ended by the TERM a `timeout` sends still releases its directory.
# What no trap sees — a KILL from the OOM killer, a container stopped past
# its grace, a peer's stale-lock takeover reaching its KILL — leaves the
# directory behind, in the container's writable layer, on the same disk as
# the state volumes and out of reach of the disk-pressure valve of
# requirement 2.5, which can shed only its own derived files
# (agent-ops#1827). That is what the sweep is for.
#
# The directory carries its owner's pid in its name so that an orphan can be
# told from a live process's directory by a local, instant test — whether
# that pid still exists — and not by age: a publish on a loaded node has run
# for hours (agent-ops#1620), and an age threshold would take its working set
# from under it.
#
#   scratch_enter NAME
#       Make this process's scratch directory under ${TMPDIR:-/tmp}, remember
#       what TMPDIR was, and export TMPDIR pointing inside it. Sets
#       SCRATCH_DIR, and SCRATCH_BASE to the directory it was made in.
#       Returns 1, with a line on stderr and TMPDIR untouched, when the
#       directory cannot be made — a full or unwritable TMPDIR — so the caller
#       can stop rather than aim every later write at the filesystem root.
#       The caller sets SCRATCH_DIR="" and arms the EXIT trap that calls
#       scratch_release *before* calling this: a signal landing between the
#       mktemp and the assignment then finds an empty SCRATCH_DIR and releases
#       nothing, and the sweep takes the directory later, under a dead pid.
#
#   scratch_release
#       Remove SCRATCH_DIR, if set, and put TMPDIR back as it was, so that a
#       process this one starts from its own cleanup — agent-cycle.sh's
#       chained cycle — inherits a TMPDIR that exists. Safe to call twice, or
#       before scratch_enter.
#
#   scratch_sweep_dead_owners [DIR]
#       Remove every scratch directory at the top of DIR whose owning pid no
#       longer exists — `agent-ops.<name>.<pid>.XXXXXX`, lib/toggle.sh's
#       `agent-ops-fleet-flag-memo.<pid>`, and a `.agent-ops-sweep.<pid>.…`
#       tombstone an earlier sweep left — and print the number removed. DIR
#       defaults to SCRATCH_BASE, the directory scratch_enter made this
#       process's own directory in, or to ${TMPDIR:-/tmp} in a process that
#       never entered one. Exits 0 always: a sweep that cannot run must never
#       fail its caller.
#
# The liveness test is "does the pid exist", never "may this process signal
# it". /proc/<pid> answers first; where it cannot — /proc mounted with
# hidepid, so another user's processes are invisible — `kill -0` is asked,
# and only ESRCH ("No such process") reads as dead: EPERM is another user's
# live process, and anything else is not evidence. PIDs are recycled, so a
# name whose pid is alive again may in fact be an orphan adopted by an
# unrelated process; it stays, and the sweep after that process exits takes
# it. Between the liveness test and the removal a new process could start
# under the very pid just found dead, so the directory is renamed to a
# tombstone first and the pid tested again before anything is removed; a pid
# found alive at that second test has its directory renamed back. What
# remains is the rename itself, and a process that new cannot have written
# into a directory it has only just been handed.

# _scratch_pid_dead PID
_scratch_pid_dead() {
  local err
  [[ -e "/proc/$1" ]] && return 1
  err="$(LC_ALL=C kill -0 "$1" 2>&1)" && return 1
  [[ "$err" == *"No such process"* ]]
}

# _scratch_owner_pid NAME
# The pid a scratch directory's name carries; returns 1 for a name that is
# not one of the three shapes, or whose pid field is not a number.
_scratch_owner_pid() {
  local pid
  case "$1" in
    agent-ops.*.*.*)
      pid="${1#agent-ops.}"; pid="${pid#*.}"; pid="${pid%%.*}" ;;
    agent-ops-fleet-flag-memo.*)
      pid="${1#agent-ops-fleet-flag-memo.}" ;;
    .agent-ops-sweep.*.*)
      pid="${1#.agent-ops-sweep.}"; pid="${pid%%.*}" ;;
    *) return 1 ;;
  esac
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$pid"
}

scratch_enter() {
  local name="$1" base="${TMPDIR:-/tmp}" dir
  dir="$(mktemp -d "$base/agent-ops.$name.$$.XXXXXX" 2>/dev/null)" || {
    printf '%s: cannot make a scratch directory in %s\n' "$name" "$base" >&2
    return 1
  }
  SCRATCH_OUTER_TMPDIR="${TMPDIR-}"
  SCRATCH_OUTER_TMPDIR_SET="${TMPDIR+set}"
  SCRATCH_BASE="$base"
  SCRATCH_DIR="$dir"
  export TMPDIR="$dir"
  return 0
}

scratch_release() {
  if [[ -n "${SCRATCH_DIR:-}" ]]; then
    rm -rf -- "$SCRATCH_DIR" 2>/dev/null || true
    SCRATCH_DIR=""
    if [[ -n "${SCRATCH_OUTER_TMPDIR_SET:-}" ]]; then
      export TMPDIR="${SCRATCH_OUTER_TMPDIR-}"
    else
      unset TMPDIR
    fi
  fi
  return 0
}

# shellcheck disable=SC2120  # DIR is optional; the launcher and agent-cycle.sh pass none, the tests do
scratch_sweep_dead_owners() {
  local dir="${1:-${SCRATCH_BASE:-${TMPDIR:-/tmp}}}" d name pid tomb removed=0
  [[ -d "$dir" ]] || { printf '0\n'; return 0; }
  for d in "$dir"/agent-ops.* "$dir"/agent-ops-fleet-flag-memo.* "$dir"/.agent-ops-sweep.*; do
    [[ -d "$d" ]] || continue
    name="${d##*/}"
    pid="$(_scratch_owner_pid "$name")" || continue
    _scratch_pid_dead "$pid" || continue
    case "$name" in
      .agent-ops-sweep.*)
        # A tombstone: the sweep that made it died before removing it, and
        # nothing can own a tombstone, so it goes as it is.
        ;;
      *)
        tomb="$dir/.agent-ops-sweep.$$.$name"
        mv -T -- "$d" "$tomb" 2>/dev/null || continue
        if ! _scratch_pid_dead "$pid"; then
          mv -T -- "$tomb" "$d" 2>/dev/null || rm -rf -- "$tomb" 2>/dev/null
          continue
        fi
        d="$tomb" ;;
    esac
    if rm -rf -- "$d" 2>/dev/null; then
      removed=$(( removed + 1 ))
    fi
  done
  printf '%s\n' "$removed"
  return 0
}
