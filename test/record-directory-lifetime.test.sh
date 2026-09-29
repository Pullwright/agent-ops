#!/usr/bin/env bash
#
# test/record-directory-lifetime.test.sh — what a review run leaves behind in
# `state_dir/reviews/` (agent-ops#1826; docs/REVIEW-PIPELINE-SPEC.md R2 and
# R2c, docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 2.5).
#
#   a tick that did nothing   a run that finds the review lock held by a live
#   leaves no directory       peer, or stands down because agent-cycle.sh
#                             holds the node, removes the record directory it
#                             made: its only content is the fleet-log
#                             snapshot, and it would otherwise take one of
#                             `state_local_streams_retained`'s slots from a
#                             run that did something.
#   a run that did something  keeps its record, but not the snapshot: the
#   leaves no snapshot        run's own cleanup removes `.fleet-log.jsonl`,
#                             which nothing reads after the run.
#
# Against the real review-cycle.sh, offline, on the shim
# test/node-time-state.test.sh already uses: `repos: []` and `state_repo: ""`
# keep every ending short of the network. agent-cycle.sh carries the same
# three changes at the same sites (its lock-held skip and its cleanup); it
# has no offline path to the lock, so it is covered by review here and by
# the state-sync tests of the prune that these directories feed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

shim_node() {  # shim_node <name> -> prints its directory
  local name="$1"
  local dir="$tmp_dir/$name"
  local item
  mkdir -p "$dir" "$dir/home/.local/state/poetic-agents" "$dir/scripts"
  for item in lib prompts .claude review-cycle.sh agent-cycle.sh config.schema.json; do
    [[ -e "$SCRIPT_DIR/$item" ]] && ln -s "$SCRIPT_DIR/$item" "$dir/$item"
  done
  # `scripts/` is linked file by file so that the dashboard publisher can be
  # left out: cleanup runs it only when it is executable, it spends its whole
  # 120-second budget on GitHub in an offline container, and nothing here
  # asserts on it. The state-sync push stays and exits at its `state_repo`
  # guard.
  for item in "$SCRIPT_DIR"/scripts/*; do
    [[ "$(basename "$item")" == publish-dashboard.sh ]] && continue
    ln -s "$item" "$dir/scripts/$(basename "$item")"
  done
  # No `not_before`: every ending exercised here lies past the lock, and
  # the dated stand-downs run before it.
  jq '.repository_review.repos = [] | .state_repo = ""
      | del(.repository_review.defaults.not_before)' \
    "$SCRIPT_DIR/config.json" > "$dir/config.json"
  printf '%s' "$dir"
}

run_shim_review() {  # run_shim_review <dir>
  env HOME="$1/home" AGENT_OPS_ROLE=active timeout 60 "$1/review-cycle.sh" --once >/dev/null 2>&1
}

review_dirs_of() {  # review_dirs_of <dir> -> how many record directories exist
  find "$1/home/.local/state/poetic-agents/reviews" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

events_of() {  # events_of <dir> -> "event/cause-or-detail" per line
  jq -r 'select(.event == "review-skipped" or .event == "review-stand-down" or .event == "review-end")
         | "\(.event)/\(.cause // .detail // "")"' \
    "$1/home/.local/state/poetic-agents/review-log.jsonl" 2>/dev/null || true
}

# A lock's holder must be alive *and* young, or R2 takes the lock over and
# ends the holder's whole process group — which, for a `sleep` started here,
# is this test. `started_at` is therefore now, not a fixed date.
lock_json() {  # lock_json <pid> -> a live, young lock record
  jq -nc --argjson p "$1" --arg h "${HOSTNAME:-}" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{pid: $p, started_at: $at, host: $h}'
}

# --- The review lock held by a live peer: no directory ------------------------
sleep 120 &
live_pid=$!
d="$(shim_node held-review-lock)"
lock_json "$live_pid" > "$d/home/.local/state/poetic-agents/review-lock.json"
run_shim_review "$d"
assert_eq "a run that finds the review lock held by a live peer logs review-skipped" \
  "1" "$(events_of "$d" | grep -c '^review-skipped/review lock held by pid')"
assert_eq "  ... and leaves no record directory behind" "0" "$(review_dirs_of "$d")"
assert_eq "  ... while still recording its ending" \
  "1" "$(events_of "$d" | grep -c '^review-end/')"
kill "$live_pid" 2>/dev/null
wait "$live_pid" 2>/dev/null

# --- agent-cycle.sh holding the node: no directory ----------------------------
sleep 120 &
live_pid=$!
d="$(shim_node busy-implementation-peer)"
lock_json "$live_pid" > "$d/home/.local/state/poetic-agents/lock.json"
run_shim_review "$d"
assert_eq "a run that stands down because agent-cycle.sh holds the node says so" \
  "1" "$(events_of "$d" | grep -c '^review-stand-down/peer-pipeline-busy$')"
assert_eq "  ... and leaves no record directory behind either" "0" "$(review_dirs_of "$d")"
kill "$live_pid" 2>/dev/null
wait "$live_pid" 2>/dev/null

# --- A run that took its snapshot and ended through cleanup: no snapshot ------
# The usage-limit cooldown (R2c's own reader of the snapshot) is the first
# ending past the snapshot that needs no network: a `limit-hit` whose
# `resume_at` is in the future, in this node's own log.jsonl, stands the run
# down after the union has been read.
d="$(shim_node cooldown-after-snapshot)"
jq -nc --arg r "$(date -u -d '+3 hours' +%Y-%m-%dT%H:%M:%SZ)" \
  '{event: "limit-hit", ts: "2000-01-01T00:00:00Z", resume_at: $r, class: "other"}' \
  > "$d/home/.local/state/poetic-agents/log.jsonl"
run_shim_review "$d"
assert_eq "a run that reads its snapshot and stands down for the cooldown records that ending" \
  "1" "$(events_of "$d" | grep -c '^review-stand-down/usage-limit$')"
assert_eq "  ... keeps its record directory" "1" "$(review_dirs_of "$d")"
assert_eq "  ... but not the fleet-log snapshot inside it" "0" \
  "$(find "$d/home/.local/state/poetic-agents/reviews" -name '.fleet-log.jsonl' 2>/dev/null | wc -l | tr -d ' ')"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
