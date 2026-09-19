#!/usr/bin/env bash
#
# test/manage-status.test.sh — the two `--status` lines lib/manage.sh added
# for agent-ops#1377: this node's own publication freshness (`published:`)
# and the scheduled doctor's last verdict (`doctor:`).
#
# Why these two are worth a test: from 2026-09-12 to -15 poetic-2 published
# nothing for three days while `--status` read every stage `ok`; the doctor
# failed its publication check hourly the whole time, into a file nothing
# surfaced to the terminal a maintainer actually reads. `check-nodes.sh`
# (external) prints `--status` per node, so these lines are where that fact
# now lands. Both must degrade to a plain sentence, never an error, on a node
# that has nothing to report yet.
#
# No network, no GitHub. Run directly: ./test/manage-status.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/mirror-lock.sh
. "$SCRIPT_DIR/lib/mirror-lock.sh"
# shellcheck source=lib/manage.sh
. "$SCRIPT_DIR/lib/manage.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
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
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}
assert_lacks() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# The globals lib/manage.sh reads from agent-cycle.sh's own process, and the
# one config accessor it calls (node_stale_after_minutes → 30, the shipped
# default, as `cfg` would resolve it).
state_dir="$tmp_dir/state"
workspace_root="$tmp_dir/workspace"
mkdir -p "$state_dir" "$workspace_root"
state_repo="Poetic-Poems/agent-ops-state"
cfg() { case "$1" in *node_stale_after_minutes*) echo 1800 ;; *) echo "" ;; esac; }

# --- manage_age_phrase ---------------------------------------------------------
assert_eq "seconds under a minute" "42s" "$(manage_age_phrase 42)"
assert_eq "minutes under an hour" "7m" "$(manage_age_phrase 450)"
assert_eq "hours under a day" "3h" "$(manage_age_phrase 12000)"
assert_eq "days beyond" "2d" "$(manage_age_phrase 200000)"
assert_eq "garbage reads as zero, never an arithmetic error" "0s" "$(manage_age_phrase abc)"

# --- publication_status_report -------------------------------------------------
assert_eq "no publication read back yet is a plain unknown" \
  "published: unknown — no fetch has read this node's own branch back yet" \
  "$(publication_status_report)"

jq -nc --arg ts "$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" '{ts: $ts}' \
  > "$state_dir/.state-sync-published.json"
out="$(publication_status_report)"
assert_contains "a publication two minutes old is fresh" "published: fresh — last confirmed publication 2m ago" "$out"
assert_contains "…against the node_stale_after_minutes threshold" "under the 30m threshold" "$out"

# poetic-2's own shape on 2026-09-15: a read-back nearly three days old.
jq -nc --arg ts "$(date -u -d '68 hours ago' +%Y-%m-%dT%H:%M:%SZ)" '{ts: $ts}' \
  > "$state_dir/.state-sync-published.json"
out="$(publication_status_report)"
assert_contains "a publication days old is STALE, in capitals" "published: STALE — last confirmed publication 2d ago" "$out"
assert_contains "…and says what that usually means" "state-sync.sh push has likely stopped working" "$out"
assert_contains "…citing the issue that explains the read-back" "agent-ops#602" "$out"

state_repo=""
assert_eq "a node with no state_repo says so rather than reading a file that cannot exist" \
  "published: not configured (no state_repo)" "$(publication_status_report)"
state_repo="Poetic-Poems/agent-ops-state"

# --- the mirror lock's own current holder (agent-ops#1679) ---------------------
# "another state-sync holds the mirror" is self-clearing only for an ordinary
# slow fetch — a push wedged holding it for hours looks identical from
# outside otherwise, so this line names the current hold's age once it has
# outrun one push interval (300s here: the stub `cfg` above answers nothing
# for `schedule.state_sync_push_minutes`, so `publication_status_report`
# falls back to its own default the same way a real unconfigured key would).
mirror="$workspace_root/.agent-ops-state"
jq -nc --arg ts "$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" '{ts: $ts}' \
  > "$state_dir/.state-sync-published.json"

# hold_mirror_lock -> sets $holder_parent/$holder_child, the two pids
# actually holding the open file description the flock sits on. `flock file
# cmd` forks: the parent keeps the lock open across the fork, so `cmd` (here,
# `sleep`) inherits the same fd and keeps the lock held even after the parent
# alone is killed — both have to be killed to release it below. Backgrounded
# directly, never through a `$(...)` command substitution: bash kills a
# command substitution's own still-running background jobs the moment that
# subshell exits, which would free the lock before this function's caller
# ever got to use it.
hold_mirror_lock() {
  flock "$mirror.lock" sleep 5 &
  holder_parent=$!
  sleep 0.2
  holder_child="$(pgrep -P "$holder_parent" | head -1)"
}

# A live holder younger than one push interval is an ordinary contention —
# no different from any other push in progress — so no wedge note.
jq -nc --arg started "$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)" \
  '{started: $started, mode: "push", pid: 1}' > "$mirror.lock.holder"
hold_mirror_lock
out="$(publication_status_report)"
assert_lacks "a lock held for under one push interval is not called a wedge" \
  "agent-ops#1679" "$out"
kill "$holder_parent" "$holder_child" 2>/dev/null; wait "$holder_parent" 2>/dev/null

# A live holder older than one push interval is named as a possible wedge —
# the fact `--status` exists to surface without reading cron.log.
jq -nc --arg started "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  '{started: $started, mode: "push", pid: 1}' > "$mirror.lock.holder"
hold_mirror_lock
out="$(publication_status_report)"
assert_contains "a lock held past one push interval is named as a possible wedge" \
  "holding the mirror lock for 1h, longer than one push interval" "$out"
assert_contains "…citing the issue that explains it" "agent-ops#1679" "$out"
kill "$holder_parent" "$holder_child" 2>/dev/null; wait "$holder_parent" 2>/dev/null

# Once nothing holds the lock, the note is gone regardless of what the stale
# marker still says — the marker only means anything while a live flock backs
# it.
out="$(publication_status_report)"
assert_lacks "no live holder means no wedge note, however old the marker" \
  "agent-ops#1679" "$out"
rm -f "$mirror.lock" "$mirror.lock.holder"

# --- doctor_status_report ------------------------------------------------------
assert_eq "no unattended pass yet is a plain sentence" \
  "doctor:   no unattended pass recorded yet" "$(doctor_status_report)"

jq -nc --arg ts "$(date -u -d '50 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  '{timestamp: $ts, verdict: "ok", fails: [], warns: [], skips: []}' > "$state_dir/.doctor-status.json"
assert_eq "an ok verdict carries only its age" "doctor:   ok (50m ago)" "$(doctor_status_report)"

# The verdict poetic-2's doctor wrote hourly for three days, verbatim but
# for the timestamp.
jq -nc --arg ts "$(date -u -d '50 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  '{timestamp: $ts, verdict: "fail", warns: ["something minor"],
    fails: ["this node'"'"'s last confirmed publication into Poetic-Poems/agent-ops-state is 205644s old, over the 1800s node_stale_after_minutes threshold — state-sync.sh push has likely stopped working even if local cycles are still running (agent-ops#602)",
            "a second failing check"]}' > "$state_dir/.doctor-status.json"
out="$(doctor_status_report)"
assert_contains "a failing verdict counts its failures" "doctor:   fail (50m ago) — 2 failing, first: " "$out"
assert_contains "…and names the first one" "last confirmed publication into Poetic-Poems/agent-ops-state is 205644s old" "$out"
assert_eq "…on one line" "1" "$(printf '%s\n' "$out" | wc -l)"

printf 'not json\n' > "$state_dir/.doctor-status.json"
assert_eq "an unreadable status file is reported, not an error" \
  "doctor:   unreadable .doctor-status.json" "$(doctor_status_report)"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
