#!/usr/bin/env bash
#
# lib/mirror-lock.sh — who holds `$mirror.lock` (scripts/state-sync.sh's
# `mirror_lock`) right now, for how long, and a way to bound a step that
# might wedge while holding it.
#
# agent-ops#1679: on 2026-09-18 a `state-sync.sh push` on ockham-2 wedged for
# almost seven hours inside the redaction loop, holding the mirror lock the
# whole time. "another state-sync holds the mirror — nothing to do" is
# documented as self-clearing (an ordinary slow fetch), so nothing in the
# logs or in `--status` distinguished that wedge from a slow one, and on a
# standby node — whose only publication is its liveness — a wedged push made
# it indistinguishable from a dead node for the whole seven hours.
#
# Two independent things follow from that:
#
#   the holder's age    the losing side of the contention (do_fetch, or a
#                        concurrent push) needs to say how long the current
#                        hold has run, not just that one exists, and
#                        `--status` needs the same figure so a human does not
#                        have to read cron.log to tell a wedge from a slow
#                        fetch. That is what this file answers.
#
#   a deadline           a step that might wedge while holding the lock
#                        (do_push's own redaction loop) needs a bound, so a
#                        wedge releases the lock on its own inside one push
#                        interval rather than however long it takes a human
#                        to notice and kill it by hand. `mirror_run_with_deadline`
#                        below is that bound, generic over what it runs.
#
# The lock file itself ($mirror.lock) cannot answer "how long has the
# current holder been running": `exec 9>"$mirror.lock"` (mirror_lock)
# truncates it on *every* attempt, winner and loser alike, so its mtime is
# reset by the very call that is asking. The holder marker below
# ($mirror.lock.holder) is written only by the process that actually wins
# the flock, and removed when it releases — so it carries a stamped start
# time for exactly as long as a real hold is in force, and nothing else
# touches it.
#
# Sourced by scripts/state-sync.sh (the winning/losing sides of the lock
# itself) and by agent-cycle.sh (lib/manage.sh's `--status`, a read-only
# caller that never takes the lock and so needs its own live probe).

# mirror_lock_holder_marker MIRROR
# The marker's path, one function so every reader and writer names it
# identically.
mirror_lock_holder_marker() {
  printf '%s.lock.holder\n' "$1"
}

# mirror_lock_mark_started MIRROR MODE
# Called by the process that has just won the flock (scripts/state-sync.sh's
# `mirror_lock`), before it does anything the lock protects. Atomic (temp +
# rename) so a reader never sees a half-written marker. Never fails: a marker
# that cannot be written leaves a future loser unable to report an age, the
# same "no evidence is not evidence" degradation as an unread doctor pass.
mirror_lock_mark_started() {
  local mirror="$1" mode="$2" marker tmp
  marker="$(mirror_lock_holder_marker "$mirror")"
  tmp="$marker.tmp.$$"
  jq -nc --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg mode "$mode" --argjson pid "$$" \
    '{started: $started, mode: $mode, pid: $pid}' > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$marker" 2>/dev/null
  return 0
}

# mirror_lock_clear_started MIRROR
# Called on release (a trap in scripts/state-sync.sh's `mirror_lock`), so a
# finished run leaves no marker for the next loser to misread as a live
# hold.
mirror_lock_clear_started() {
  rm -f "$(mirror_lock_holder_marker "$1")" 2>/dev/null
  return 0
}

# mirror_lock_holder_age_s MIRROR
# Seconds since the current holder started, per its own marker — empty if
# there is no marker to read (a lock taken by a version of this script that
# predates this file, or already released between the flock failing and this
# read). Never fails.
mirror_lock_holder_age_s() {
  local marker started started_s now_s
  marker="$(mirror_lock_holder_marker "$1")"
  [[ -s "$marker" ]] || return 0
  started="$(jq -r '.started // empty' "$marker" 2>/dev/null)" || return 0
  [[ -n "$started" ]] || return 0
  started_s="$(date -u -d "$started" +%s 2>/dev/null)" || return 0
  [[ -n "$started_s" ]] || return 0
  now_s="$(date -u +%s)"
  (( now_s >= started_s )) || return 0
  printf '%s\n' "$(( now_s - started_s ))"
}

# mirror_lock_probe MIRROR
# For a read-only caller that never calls `mirror_lock` itself
# (lib/manage.sh's `--status`): `{"held":false}` when nobody currently holds
# `$MIRROR.lock`, else `{"held":true,"age_s":N}` (age_s omitted if the marker
# cannot be read). Takes and instantly releases the same lock
# scripts/state-sync.sh contends for, via `flock`(1) against the lock file
# directly rather than a bash-builtin fd — this call owns no fd of its own
# to test with, only the path — which is exactly the "is anyone holding this
# right now" a non-blocking probe answers. Never fails: a lock file that does
# not exist yet (single-node install, or before the first push) reads as not
# held, same as a genuinely free one.
mirror_lock_probe() {
  local mirror="$1" lock age
  lock="$mirror.lock"
  [[ -e "$lock" ]] || { printf '{"held":false}\n'; return 0; }
  if flock -n "$lock" -c true >/dev/null 2>&1; then
    printf '{"held":false}\n'
    return 0
  fi
  age="$(mirror_lock_holder_age_s "$mirror")"
  if [[ -n "$age" ]]; then
    jq -nc --argjson age "$age" '{held:true, age_s:$age}'
  else
    printf '{"held":true}\n'
  fi
  return 0
}

# mirror_kill_tree PID
# Terminate PID and every descendant it has forked, reading /proc for the
# parent/child edges the same way scripts/state-sync.sh's own
# `mirror_git_busy` already reads it to find a live git in the mirror —
# generalised here to any process tree rather than one named `git`. SIGTERM
# first, then, after a short grace period, SIGKILL for whatever is still
# alive: a step wedged in blocking I/O (the redaction loop's own process
# substitution, agent-ops#1679) will not always exit on SIGTERM alone if it
# is inside a shell whose child is itself blocked, so the escalation is what
# actually bounds this. Never fails: killing a tree that has already exited
# is a no-op, not an error.
mirror_kill_tree() {
  local root="$1" pids=("$1") frontier=("$1") next p ppid stat_line rest i frontier_pid
  [[ -d /proc/self ]] || { kill -TERM "$root" 2>/dev/null; return 0; }
  # Breadth-first over /proc's own ppid field, bounded by the number of
  # processes on the box: a wedge is one shell and, at most, the handful of
  # external commands (find, sed) the redaction loop spawns, never a fleet's
  # worth. `stat`'s own comm field (the second, parenthesised one) can itself
  # contain spaces or parentheses, so the ppid is read after the *last* `)`
  # in the line rather than by naive field-splitting the whole thing.
  while (( ${#frontier[@]} > 0 )); do
    next=()
    for p in /proc/[0-9]*; do
      p="${p#/proc/}"
      stat_line="$(cat "/proc/$p/stat" 2>/dev/null)" || continue
      rest="${stat_line##*) }"
      ppid="$(awk '{print $2}' <<<"$rest")"
      for frontier_pid in "${frontier[@]}"; do
        [[ "$ppid" == "$frontier_pid" ]] || continue
        pids+=("$p")
        next+=("$p")
        break
      done
    done
    frontier=(${next[@]+"${next[@]}"})
  done
  for (( i = ${#pids[@]} - 1; i >= 0; i-- )); do
    kill -TERM "${pids[$i]}" 2>/dev/null
  done
  sleep 1
  for (( i = ${#pids[@]} - 1; i >= 0; i-- )); do
    kill -KILL "${pids[$i]}" 2>/dev/null
  done
  return 0
}

# mirror_run_with_deadline SECONDS CMD [ARGS...]
# Run CMD as a background job of the *current* shell (so it inherits every
# function and variable already in scope — no re-exec, no need to pass
# state across a process boundary) and give it SECONDS to finish. Past that,
# kill its whole process tree (mirror_kill_tree above) and return 124 — the
# same exit code GNU `timeout`(1) uses for its own deadline, so a caller
# already handling that convention elsewhere in this codebase reads this one
# identically. Polls once a second, the same granularity every age in this
# file is measured at.
mirror_run_with_deadline() {
  local deadline="$1"; shift
  "$@" &
  local job_pid=$! waited=0
  while kill -0 "$job_pid" 2>/dev/null; do
    if (( waited >= deadline )); then
      mirror_kill_tree "$job_pid"
      wait "$job_pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  wait "$job_pid"
}
