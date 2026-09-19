#!/usr/bin/env bash
#
# test/state-sync.test.sh — regression test for scripts/state-sync.sh under
# the multi-active fleet model (per-node branches, no lease).
#
# Eight things here are worth a test rather than a careful reading:
#
#   what replicates   the exclude list is the difference between a fleet that
#                     shares its memory and one that shares its locks.
#   where it goes     each node writes its own `nodes/<NODE_NAME>` branch and
#                     never anyone else's — the property that made a lease
#                     unnecessary for state.
#   what is kept      the push bounds the node's own cycles/ and reviews/ to
#                     state_local_cycles_retained — the local record must stay
#                     longer than the mirror's, and the newest must survive.
#   what comes back   a fetch materialises every peer, whole, and prunes a
#                     peer whose branch is gone — half a peer or a ghost peer
#                     both poison the union readers.
#   what is trusted   a mirror whose object store has quietly corrupted, or
#                     whose own gc has failed and given up (a `gc.log`), is
#                     discarded and rebuilt rather than kept and published
#                     from — the property that makes an unclean shutdown a
#                     one-tick blip instead of a four-day silent outage
#                     (#604) — and the store is configured so that the
#                     snapshots every amend orphans are pruned at once
#                     instead of piling up for a month behind a reflog
#                     until a gc the scheduler's memory ceiling kills.
#   what unblocks it  an `index.lock` a dead git left in the mirror is cleared
#                     once it is older than a push interval and no git is
#                     alive in there, a live one never is, and a push that
#                     fails names its step and git's line in log.jsonl
#                     rather than exiting in silence (#1377).
#   what never leaves  everything replicated is redacted first (lib/redact.sh,
#   raw                agent-ops#966) — a token or a home path that reaches a
#                     published file must not survive the commit this push
#                     makes to a repository that is never rotated.
#   what unwedges it   a redaction that fails on one file warns and moves on
#                     rather than abandoning the loop mid-stream (the shape
#                     that deadlocked a whole push against `find`'s own
#                     process substitution for almost seven hours, holding
#                     the mirror lock throughout), a step that still runs
#                     long past a push interval is killed and the lock
#                     released regardless of cause, and the losing side of a
#                     lock contention says how long the current hold has run
#                     rather than reporting every wait as equally ordinary
#                     (agent-ops#1679).
#
# No network and no GitHub: the remote is a local bare repository
# (STATE_SYNC_REMOTE). No test framework is used (none exists elsewhere in
# this repo). Run directly:
#
#   ./test/state-sync.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$SCRIPT_DIR/scripts/state-sync.sh"

# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/mirror-integrity.sh
. "$SCRIPT_DIR/lib/mirror-integrity.sh"
# shellcheck source=lib/mirror-lock.sh
. "$SCRIPT_DIR/lib/mirror-lock.sh"

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
    printf 'FAIL - %s\n     expected NOT to contain: %s\n' "$desc" "$needle"
    failures=$(( failures + 1 ))
  fi
}

# --- The stand-in remote ------------------------------------------------------
remote="$tmp_dir/remote.git"
git init --quiet --bare --initial-branch=main "$remote"

# --- A node ------------------------------------------------------------------
# Each node is a HOME: config.json's state_dir and workspace_root are
# ~-relative, so a throwaway home is a throwaway node.
# cycles_retained (requirement 1d) is no longer a literal in config.json — it
# derives from schedule.cycle_interval_minutes — so the effective value this
# test asserts against has to be resolved the same way scripts/state-sync.sh
# itself resolves it, not read off the raw file.
cycles_retained="$(config_defaults "$SCRIPT_DIR/config.json" "$SCRIPT_DIR/config.schema.json" | jq -r '.cycles_retained')"

new_node() {  # new_node <name> -> prints its HOME
  local home="$tmp_dir/$1"
  mkdir -p "$home/.local/state/poetic-agents/cycles" \
           "$home/.local/state/poetic-agents/reviews" \
           "$home/.cache/poetic-agents/workspaces"
  printf '%s' "$home"
}

sync_as() {  # sync_as <home> <role> <mode> [env assignments…]
  local home="$1" role="$2" mode="$3"; shift 3
  env HOME="$home" AGENT_OPS_ROLE="$role" NODE_NAME="$(basename "$home")" \
    STATE_SYNC_REMOTE="$remote" "$@" \
    "$SYNC" "$mode" 2>&1
}

# ==============================================================================
# push — each node its own branch
# ==============================================================================
active_home="$(new_node active-node)"
state="$active_home/.local/state/poetic-agents"

printf '{"ts":"2026-07-20T00:00:00Z","event":"cycle-start"}\n' > "$state/log.jsonl"
printf '{"ts":"2026-07-20T00:00:00Z","event":"review-start"}\n' > "$state/review-log.jsonl"
printf '{"ts":"2026-08-21T02:00:00Z","node":"active-node","event":"revert-rate","repo":"o/r"}\n' > "$state/revert-rate.jsonl"
printf '{"reason":"testing"}\n' > "$state/disabled.json"
# A token and a home path planted here and in the transcript below, for the
# redaction check (agent-ops#966): state-sync.sh commits both, unrotated, to
# the private state-mirror repository, so a token that reaches either from a
# verbose git/curl error or a stray `set -x` must not survive the push.
printf 'cron says hello, token ghp_1234567890abcdefXYZ1234 in /home/fixturenode/secret\n' \
  > "$state/cron.log"
mkdir -p "$state/cycles/20260720T010000Z-1" "$state/reviews/20260720T020000Z-1"
printf '{"result":"token ghp_1234567890abcdefXYZ1234 in /home/fixturenode/secret"}\n' \
  > "$state/cycles/20260720T010000Z-1/coordinator.out"
# The stage event stream beside it (requirement 4d). It is the one thing in a
# cycle directory that must not replicate: `.out` is one JSON object, a stream
# is every message and every tool result, and the branch is a rolling commit
# holding `cycles_retained` of them.
printf '{"type":"system"}\n' > "$state/cycles/20260720T010000Z-1/coordinator.stream.jsonl"
printf '{"type":"system"}\n' > "$state/reviews/20260720T020000Z-1/reviewer.stream.jsonl"
# The fleet-log snapshot beside them (agent-ops#763). Same class and a sharper
# case of it: the union of every node's log.jsonl as this cycle saw it, so
# publishing it would send a peer a derivative of the logs it is already being
# sent — one copy per retained cycle, each the whole fleet's history to that
# point.
printf '{"type":"union"}\n' > "$state/cycles/20260720T010000Z-1/.fleet-log.jsonl"
printf '{"type":"union"}\n' > "$state/reviews/20260720T020000Z-1/.fleet-log.jsonl"
# Every directory here carries a file, because git stores no empty ones: a
# cycle that stood down before its first stage leaves an empty directory, and
# that directory does not replicate. Its log.jsonl entry does, which is what
# the union readers actually consume.
printf 'review\n' > "$state/reviews/20260720T020000Z-1/review.out"

# The things that must stay behind, one per reason in the exclude list.
printf '{"pid":999}\n' > "$state/lock.json"
printf '{"pid":998}\n' > "$state/review-lock.json"
# This node's own instruction to its own watchtower hook (agent-ops#1096): a
# copy on a peer would tell that peer's hook to allow a roll nothing about
# that peer actually earned, on the same reasoning as the locks above.
printf '{"until":"2026-08-30T10:00:00Z"}\n' > "$state/roll-pending.json"
printf 'server noise\n' > "$state/dashboard.log"
printf '{}\n' > "$state/.dashboard-github.json"
printf '{"ok":false}\n' > "$state/.image-drift-cache.json"
# This node's own read-back of what the shared state holds for its own branch
# (agent-ops#602) — local to this node on the identical reasoning as the
# image-drift cache above; no peer ever needs this node's own answer to "am I
# fresh".
printf '{"ts":"2026-07-20T00:00:00Z"}\n' > "$state/.state-sync-published.json"
# The expensive-gather cache (lib/expensive-gather-cache.sh, requirement 48,
# agent-ops#1086): local to this node, like the caches above —
# expensive_gather_pick_repo keys on cache-file mtime, and a copy restored
# from the fleet state branch would carry a checkout-fresh mtime.
mkdir -p "$state/expensive-gather"
printf '{"findings":[]}\n' > "$state/expensive-gather/o_r.json"
# The wake-poll cache (scripts/wake-poll.sh, requirement 54, issue #613):
# this node's own stored ETags, local on the same reasoning as
# expensive-gather/ above — no peer reads another node's copy.
mkdir -p "$state/wake-poll/o_r"
printf 'W/"deadbeef"\n' > "$state/wake-poll/o_r/issues.etag"
# The hourly unattended doctor pass's own artefacts (agent-ops#543): local to
# this node, like the caches above, so neither file should replicate. Its
# *verdict* is folded into the heartbeat (agent-ops#1278) and, as of
# agent-ops#1397, so are its failing checks — bounded. This fixture therefore
# carries more fails than that bound and one longer than the truncation, which
# is what the heartbeat assertions further down read.
printf 'doctor noise\n' > "$state/doctor.log"
jq -nc --arg long "$(printf 'x%.0s' $(seq 1 260))" '
  {timestamp: "2026-07-20T00:05:00Z",
   verdict: "fail",
   fails: ["first failing check", $long, "third failing check", "fourth failing check"],
   warns: ["a warning no peer reads"],
   skips: 2,
   token_expiry: "2026-12-01"}' > "$state/.doctor-status.json"
# The per-stage health snapshot (lib/stage-health.sh, agent-ops#662): local to
# this node as a raw file, on the same reasoning as the doctor status cache
# above — but unlike it, its content is meant to reach peers, folded into the
# heartbeat below rather than replicated verbatim.
printf '{"computed_at":"2026-07-20T00:00:00Z","threshold":3,"idle_after_hours":48,"stages":{"coordinator":{"verdict":"failing","consecutive_failures":5,"last_success":null,"last_detail":"boom"}}}\n' \
  > "$state/.stage-health.json"
# The compose reconciler's own verdict (lib/compose-reconcile.sh, requirement
# 2.5a): written by a *different container* into this shared volume, and
# local to this node as a raw file for the same reason .stage-health.json
# above is — it answers for one host's deployment file. Its content reaches
# peers folded into the heartbeat below.
printf '{"status":"refused","at":"2026-07-20T00:00:00Z","reason":"the merged compose.yaml requires NODE_NAME"}\n' \
  > "$state/.compose-reconcile.json"
# The daily revert-rate publishing pass's own text output (agent-ops#579):
# local to this node, like doctor.log above — its structured sibling,
# revert-rate.jsonl (set up above, beside log.jsonl), is fleet-wide data and
# must replicate instead.
printf 'revert-rate noise\n' > "$state/revert-rate.log"
# The cumulative-since-baseline pass's own settled-aggregate cache
# (TD-PPagop-26082204): this node's memoisation of what it has already
# mined, not a fact about the fleet, so it stays local like
# .doctor-status.json above.
printf '{"o/r":{"settled_aggregate":{"count":1,"post_merge":{"reverts":0,"follow_up_fixes":0}},"settled_until":"2026-08-21T00:00:00Z","baseline_since":"2026-08-15T00:00:00Z"}}\n' \
  > "$state/revert-rate-cumulative-state.json"
# The daily tech-debt archive publishing pass's own text output (agent-
# ops#878): local to this node, like doctor.log above — unlike revert-
# rate.log it has no structured sibling at all, since what it publishes
# lands in the state repository's own tech-debt-archive/ tree directly.
printf 'tech-debt-archive noise\n' > "$state/tech-debt-archive.log"
# The wake poller's own text output (scripts/wake-poll.sh, requirement 54,
# issue #613): local to this node, like the publish logs above, and the
# fastest-growing of them — a line every schedule.wake_poll_minutes. Its one
# structured record, the wake-poll-triggered event, goes to log.jsonl, which
# does replicate.
printf 'wake-poll: nothing changed — no wake\n' > "$state/wake-poll.log"
# The gh transport shim's own state (lib/gh-shim.sh, requirement 2.0e,
# agent-ops#1084): the stored response bodies are this node's own cache, on
# the same reasoning as the caches above, and the largest and fastest-churning
# thing under state_dir. The ledger and budget.json beside them are fleet-wide
# telemetry and must replicate.
mkdir -p "$state/gh-shim/http-cache"
printf '{"identity":"abc","path":"repos/o/r","etag":"e","fetched_at":1,"body":"{}"}\n' \
  > "$state/gh-shim/http-cache/deadbeef.json"
printf '{"ts":"2026-07-20T01:00:00Z","method":"GET","path":"repos/o/r","status":200,"cache":"miss","resource":"core","used":7}\n' \
  > "$state/gh-shim/ledger.ndjson"
printf '{"abc":{"core":{"limit":5000,"used":7,"remaining":4993,"reset":1893456000}}}\n' \
  > "$state/gh-shim/budget.json"
printf '' > "$state/gh-shim/ledger.ndjson.lock"
mkdir -p "$state/dashboard"
printf '<html>\n' > "$state/dashboard/index.html"
# scripts/node-health.sh's own caches (requirements 57/58a, issue #608):
# local to this node on the same reasoning as .image-drift-cache.json and
# labels-ensured/ above — neither answers for anything a peer would read.
printf '{"ok":true}\n' > "$state/.node-health-ratelimit-cache.json"
printf '' > "$state/.node-alive"

out="$(sync_as "$active_home" active push)"
assert_eq "push exits 0" "0" "$?"
assert_contains "push names the node's branch" "nodes/active-node" "$out"

pushed="$tmp_dir/pushed"
git clone --quiet --branch nodes/active-node "$remote" "$pushed"
assert_eq "the log replicates" "1" "$(test -f "$pushed/log.jsonl" && echo 1 || echo 0)"
assert_eq "the review log replicates" "1" "$(test -f "$pushed/review-log.jsonl" && echo 1 || echo 0)"
assert_eq "the revert-rate log replicates" "1" "$(test -f "$pushed/revert-rate.jsonl" && echo 1 || echo 0)"
assert_eq "the switch replicates" "1" "$(test -f "$pushed/disabled.json" && echo 1 || echo 0)"
assert_eq "cycle transcripts replicate" "1" \
  "$(test -f "$pushed/cycles/20260720T010000Z-1/coordinator.out" && echo 1 || echo 0)"
assert_eq "reviews replicate" "1" "$(test -d "$pushed/reviews/20260720T020000Z-1" && echo 1 || echo 0)"
assert_eq "the cron log replicates" "1" "$(test -f "$pushed/cron.log" && echo 1 || echo 0)"

assert_eq "the lock does not replicate" "0" "$(test -e "$pushed/lock.json" && echo 1 || echo 0)"
assert_eq "the review lock does not replicate" "0" "$(test -e "$pushed/review-lock.json" && echo 1 || echo 0)"
assert_eq "the roll-pending marker does not replicate" "0" "$(test -e "$pushed/roll-pending.json" && echo 1 || echo 0)"
assert_eq "the dashboard log does not replicate" "0" "$(test -e "$pushed/dashboard.log" && echo 1 || echo 0)"
assert_eq "the GitHub cache does not replicate" "0" "$(test -e "$pushed/.dashboard-github.json" && echo 1 || echo 0)"
assert_eq "the image-drift cache does not replicate" "0" "$(test -e "$pushed/.image-drift-cache.json" && echo 1 || echo 0)"
assert_eq "the publication cache does not replicate" "0" "$(test -e "$pushed/.state-sync-published.json" && echo 1 || echo 0)"
assert_eq "the expensive-gather cache does not replicate" "0" "$(test -e "$pushed/expensive-gather" && echo 1 || echo 0)"
assert_eq "the wake-poll cache does not replicate" "0" "$(test -e "$pushed/wake-poll" && echo 1 || echo 0)"
assert_eq "the doctor log does not replicate" "0" "$(test -e "$pushed/doctor.log" && echo 1 || echo 0)"
assert_eq "the doctor status cache does not replicate" "0" "$(test -e "$pushed/.doctor-status.json" && echo 1 || echo 0)"
assert_eq "the stage-health cache does not replicate as a raw file" "0" "$(test -e "$pushed/.stage-health.json" && echo 1 || echo 0)"
assert_eq "the compose-reconcile verdict does not replicate as a raw file" "0" "$(test -e "$pushed/.compose-reconcile.json" && echo 1 || echo 0)"
assert_eq "the revert-rate publish log does not replicate" "0" "$(test -e "$pushed/revert-rate.log" && echo 1 || echo 0)"
assert_eq "the revert-rate cumulative-state cache does not replicate" "0" \
  "$(test -e "$pushed/revert-rate-cumulative-state.json" && echo 1 || echo 0)"
assert_eq "the tech-debt archive publish log does not replicate" "0" "$(test -e "$pushed/tech-debt-archive.log" && echo 1 || echo 0)"
assert_eq "the node-health rate-limit cache does not replicate" "0" "$(test -e "$pushed/.node-health-ratelimit-cache.json" && echo 1 || echo 0)"
assert_eq "the node-health liveness marker does not replicate" "0" "$(test -e "$pushed/.node-alive" && echo 1 || echo 0)"
assert_eq "the wake-poll log does not replicate" "0" "$(test -e "$pushed/wake-poll.log" && echo 1 || echo 0)"
assert_eq "the generated dashboard does not replicate" "0" "$(test -e "$pushed/dashboard" && echo 1 || echo 0)"
assert_eq "the gh shim's HTTP cache does not replicate" "0" \
  "$(test -e "$pushed/gh-shim/http-cache" && echo 1 || echo 0)"
assert_eq "…nor its lock files" "0" \
  "$(test -e "$pushed/gh-shim/ledger.ndjson.lock" && echo 1 || echo 0)"
assert_eq "…but its ledger does, being fleet-wide telemetry" "1" \
  "$(test -f "$pushed/gh-shim/ledger.ndjson" && echo 1 || echo 0)"
assert_eq "…and so does its budget reading of the shared bucket" "1" \
  "$(test -f "$pushed/gh-shim/budget.json" && echo 1 || echo 0)"
# Both transfers are covered: the cycle directories go through their own rsync
# with its own filter, so an exclusion that held only for the general transfer
# would let every cycle's stream through anyway.
assert_eq "a cycle's stage stream does not replicate" "0" \
  "$(test -e "$pushed/cycles/20260720T010000Z-1/coordinator.stream.jsonl" && echo 1 || echo 0)"
assert_eq "nor does a review's" "0" \
  "$(test -e "$pushed/reviews/20260720T020000Z-1/reviewer.stream.jsonl" && echo 1 || echo 0)"
assert_eq "a cycle's fleet-log snapshot does not replicate" "0" \
  "$(test -e "$pushed/cycles/20260720T010000Z-1/.fleet-log.jsonl" && echo 1 || echo 0)"
assert_eq "nor does a review's" "0" \
  "$(test -e "$pushed/reviews/20260720T020000Z-1/.fleet-log.jsonl" && echo 1 || echo 0)"
# The record itself is untouched by either exclusion — what a peer reads of a
# cycle is still there.
assert_eq "the record survives both exclusions" "1" \
  "$(test -f "$pushed/cycles/20260720T010000Z-1/coordinator.out" && echo 1 || echo 0)"

# Redaction (agent-ops#966): the token and home path planted in cron.log and
# the cycle transcript above must not reach the commit this push makes to
# the state-mirror repository — the same defence-in-depth pass
# publish-dashboard.sh already applies to its own (lower-risk) payload.
pushed_cron="$(cat "$pushed/cron.log")"
assert_contains "the cron log's token is redacted" "[REDACTED-TOKEN]" "$pushed_cron"
assert_lacks "no raw token survives in the cron log" "ghp_1234567890abcdefXYZ1234" "$pushed_cron"
assert_lacks "no home path survives in the cron log" "/home/fixturenode" "$pushed_cron"
pushed_transcript="$(cat "$pushed/cycles/20260720T010000Z-1/coordinator.out")"
assert_contains "a cycle transcript's token is redacted too" "[REDACTED-TOKEN]" "$pushed_transcript"
assert_lacks "no raw token survives in the transcript" "ghp_1234567890abcdefXYZ1234" "$pushed_transcript"
assert_eq "the redacted transcript is still valid JSON" "0" \
  "$(jq -e . >/dev/null 2>&1 <<<"$pushed_transcript"; echo $?)"

assert_contains "the commit names the node" "state: active-node" \
  "$(git -C "$pushed" log -1 --format=%s)"

hb="$(cat "$pushed/heartbeat.json" 2>/dev/null || echo '{}')"
assert_eq "the heartbeat names the node" "active-node" "$(jq -r '.node' <<<"$hb")"
assert_eq "the heartbeat records the role" "active" "$(jq -r '.role' <<<"$hb")"
assert_eq "the heartbeat records the newest cycle" "20260720T010000Z-1" "$(jq -r '.last_cycle' <<<"$hb")"

# --- The heartbeat carries the node-scoped switch (issue #379) ---------------
# The node's own state_dir/disabled.json above ({"reason":"testing"}, no
# other fields) is exactly the switch this node's cycles gate on, so the same
# read (lib/toggle.sh's toggle_switch_summary) that feeds `--status` and the
# dashboard's page-top banner feeds the heartbeat's `switch` field too — one
# implementation, so a peer's card cannot disagree with what that node itself
# would report (requirement 34a).
assert_eq "the heartbeat reports the node's own switch as disabled" "true" \
  "$(jq -r '.switch.disabled' <<<"$hb")"
assert_eq "carrying the reason from disabled.json" "testing" \
  "$(jq -r '.switch.reason' <<<"$hb")"

# --- The heartbeat carries an image-drift verdict slot (#155) -----------------
# lib/image-drift.sh's own suite (test/image-drift.test.sh) covers what the
# verdict says; what belongs here is only that state-sync.sh asks for one at
# all. This suite runs from a plain checkout (source "checkout", not "image"
# — SCRIPT_DIR names this repository's own working tree, which ships no
# build-info.json), so the verdict is null by lib/image-drift.sh's own rule
# for a node not running a CI-stamped image — the key existing, not its
# value, is the wiring this asserts.
assert_eq "the heartbeat carries an image-drift slot" "true" "$(jq 'has("image")' <<<"$hb")"

# --- The heartbeat carries the per-stage health verdict (agent-ops#662) -------
# Unlike image/compose above, this is a verbatim read of `.stage-health.json`
# — lib/stage-health.sh's own suite covers what the verdict says, so what
# belongs here is only that the fixture written above (the file excluded from
# raw replication two assertions up) reaches the heartbeat unchanged.
assert_eq "the heartbeat carries the stage-health verdict computed this cycle" "failing" \
  "$(jq -r '.stage_health.stages.coordinator.verdict' <<<"$hb")"
assert_eq "with its consecutive-failure count intact" "5" \
  "$(jq -r '.stage_health.stages.coordinator.consecutive_failures' <<<"$hb")"

# --- The heartbeat carries the doctor verdict (agent-ops#1278) and, bounded,
#     the checks that failed (agent-ops#1397) --------------------------------
# The verdict alone is what lib/pager.sh's `verdict-unanimous` invariant fires
# on; with nothing but the verdict it could say only that every node was
# unhappy, which cost a hand search of four nodes' `.doctor-status.json` to
# learn they were all failing the same check (#1398). The checks now travel
# with it — bounded, which is the whole reason the array stayed local before:
# the whole fleet re-fetches this file every schedule.state_sync_fetch_minutes,
# and unbounded diagnostic prose there is a cost with no ceiling.
assert_eq "the heartbeat carries the doctor verdict" "fail" \
  "$(jq -r '.doctor.verdict' <<<"$hb")"
assert_eq "and the time the pass was computed" "2026-07-20T00:05:00Z" \
  "$(jq -r '.doctor.timestamp' <<<"$hb")"
assert_eq "and names the check that failed, not merely that one did" "first failing check" \
  "$(jq -r '.doctor.fails[0]' <<<"$hb")"
assert_eq "at most three of them, however many the node reported" "3" \
  "$(jq -r '.doctor.fails | length' <<<"$hb")"
assert_eq "  ... so the fourth does not travel" "0" \
  "$(jq -r '[.doctor.fails[] | select(. == "fourth failing check")] | length' <<<"$hb")"
assert_eq "each truncated, so one node's prose cannot grow the shared file without bound" "200" \
  "$(jq -r '.doctor.fails[1] | length' <<<"$hb")"
assert_eq "warns stay local — no reader off this node" "false" \
  "$(jq -r '.doctor | has("warns")' <<<"$hb")"
assert_eq "and so does token_expiry, which only the node holding the credential can act on" "false" \
  "$(jq -r '.doctor | has("token_expiry")' <<<"$hb")"

# --- The heartbeat carries a mirror-rebuild verdict slot (#604) ---------------
# lib/mirror-integrity.sh's own behaviour (a corrupted mirror is discarded
# and rebuilt) is covered by its dedicated section below; what belongs here
# is only that a mirror which has never had to rebuild reports `null`, not
# that the key is simply missing.
assert_eq "the heartbeat carries a mirror-rebuild slot" "true" "$(jq 'has("mirror")' <<<"$hb")"
assert_eq "unset until this node has actually rebuilt its mirror" "null" "$(jq -c '.mirror' <<<"$hb")"

# --- The heartbeat carries the compose-drift verdict (#131) and the updater
# --- verdict (agent-ops#603), from a single push ------------------------------
# Two independent heartbeat fields, assembled by do_push from unrelated
# inputs (compose-drift's forced fixture paths, the updater ledger keyed by
# $HOSTNAME) with no interaction between them — so both fixtures are staged
# before one push, and one clone answers for both, rather than paying for a
# second real push-and-clone that would only be exercising the first push's
# own amend-not-accumulate behaviour a second time (already covered below).
#
# Compose: end to end, a node whose compose.yaml has drifted publishes that
# fact with its next push. The check's paths are forced to fixtures, because
# this suite runs both on developer hosts and inside the CI image, and the
# defaults would answer for whichever environment it happens to be in.
#
# Updater: lib/updater-health.sh's own suite (test/updater-health.test.sh)
# covers what the verdict says; what belongs here is that a ledger
# deploy/docker/watchtower-pre-update.sh wrote reaches the heartbeat, keyed by
# the container's own $HOSTNAME rather than NODE_NAME — the two need not
# match — and that the raw ledger itself does not replicate. Two entries, not
# one (agent-ops#1071): `updater_status` now reads liveness first, off the
# ledger's own newest entry, so a single entry old enough to prove "stuck" is
# also old enough to read null outright — the fixture needs a poll recent
# enough to stay live *and* a first allow old enough to be stuck, the same
# shape a container watchtower is still polling actually writes. Both entries
# also carry `started` (agent-ops#1072), matching this test process's own
# reading of PID 1's start time (field 22 of /proc/1/stat, the same field the
# hook stamps) — `updater_status` inside the pushed subshell reads the same
# value back (no sixth argument passed here, exactly as state-sync.sh's own
# call site never passes one), so the fixture is read as genuinely this
# container's own unbroken run, never a foreign generation's.
drift_image="$tmp_dir/drift-image.yaml"
drift_host="$tmp_dir/drift-host.yaml"
printf 'services:\n  scheduler:\n    image: ghcr.io/example/agent-ops:latest\n' > "$drift_image"
printf 'services:\n  scheduler:\n    image: ghcr.io/example/agent-ops:pinned\n' > "$drift_host"
own_started="$(awk '{ sub(/^.*\) /, ""); print $20 }' /proc/1/stat)"
mkdir -p "$state/updater-ledger"
{
  printf '{"ts":"%s","verdict":"allow","started":%s}\n' \
    "$(date -u -d '40 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" "$own_started"
  printf '{"ts":"%s","verdict":"allow","started":%s}\n' \
    "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" "$own_started"
} > "$state/updater-ledger/updater-host.jsonl"
sync_as "$active_home" active push \
  COMPOSE_DRIFT_HOST="$drift_host" COMPOSE_DRIFT_IMAGE="$drift_image" \
  HOSTNAME=updater-host >/dev/null
assert_eq "the drift- and updater-carrying push exits 0" "0" "$?"
drift_pushed="$tmp_dir/pushed-drift"
git clone --quiet --branch nodes/active-node "$remote" "$drift_pushed"
assert_eq "a drifted compose.yaml is published in the heartbeat" "drifted" \
  "$(jq -r '.compose.status' "$drift_pushed/heartbeat.json" 2>/dev/null)"
assert_eq "with the count of differing lines" "2" \
  "$(jq -r '.compose.diff_lines' "$drift_pushed/heartbeat.json" 2>/dev/null)"

# --- The heartbeat carries the reconciler's verdict beside it (2.5a) ---------
# Verbatim, like `.stage-health.json` above and for a stronger version of the
# same reason: the file is another *container's* finished verdict, and
# state-sync.sh holds neither the Docker socket nor the project directory it
# was reached through, so it could not re-derive it even if it wanted to.
# lib/compose-reconcile.sh's own suite covers what the verdict says.
assert_eq "the reconciler's verdict travels beside the drift verdict it acts on" "refused" \
  "$(jq -r '.compose_reconcile.status' "$drift_pushed/heartbeat.json" 2>/dev/null)"
assert_eq "with the reason it recorded intact" "the merged compose.yaml requires NODE_NAME" \
  "$(jq -r '.compose_reconcile.reason' "$drift_pushed/heartbeat.json" 2>/dev/null)"

assert_eq "a container that never rolled after an allow is published as stuck" "stuck" \
  "$(jq -r '.updater.status' "$drift_pushed/heartbeat.json" 2>/dev/null)"
assert_eq "the raw ledger does not replicate" "0" \
  "$(test -e "$drift_pushed/updater-ledger" && echo 1 || echo 0)"

# --- A second push amends rather than accumulating history ---
printf '{"ts":"2026-07-20T01:00:00Z","event":"cycle-end"}\n' >> "$state/log.jsonl"
sync_as "$active_home" active push >/dev/null
assert_eq "the amending push exits 0" "0" "$?"
assert_eq "history stays a single rolling commit" "1" \
  "$(git -C "$remote" rev-list --count nodes/active-node)"

# --- A standby pushes too (its heartbeat is the point) ---
standby_home="$(new_node standby-node)"
sb_state="$standby_home/.local/state/poetic-agents"
printf '{"ts":"2026-07-21T00:00:00Z","event":"cycle-start"}\n' > "$sb_state/log.jsonl"
out="$(sync_as "$standby_home" standby push)"
assert_eq "a standby push exits 0" "0" "$?"
assert_eq "a standby publishes its own branch" "1" \
  "$(git -C "$remote" rev-parse --verify --quiet refs/heads/nodes/standby-node >/dev/null && echo 1 || echo 0)"
assert_eq "…and never touches a peer's" "1" \
  "$(git -C "$remote" rev-list --count nodes/active-node)"
sb_pushed="$tmp_dir/pushed-standby"
git clone --quiet --branch nodes/standby-node "$remote" "$sb_pushed"
assert_eq "a node with no .stage-health.json yet publishes a null stage_health, not a guess" "null" \
  "$(jq -c '.stage_health' "$sb_pushed/heartbeat.json")"
assert_eq "a node with no reconciler publishes a null compose_reconcile, not a guess" "null" \
  "$(jq -c '.compose_reconcile' "$sb_pushed/heartbeat.json")"
assert_eq "a node with no updater-ledger/ yet publishes a null updater, not a guess" "null" \
  "$(jq -c '.updater' "$sb_pushed/heartbeat.json")"

# --- Mirror retention ---
# One more cycle directory than the configured retention, so the oldest must
# fall out of the mirror while staying on the node that made it.
i=0
while (( i < cycles_retained + 1 )); do
  d="$(printf '%s/cycles/20260101T%06dZ-%d' "$state" "$i" "$i")"
  mkdir -p "$d"
  printf 'filler\n' > "$d/coordinator.out"
  i=$(( i + 1 ))
done
sync_as "$active_home" active push >/dev/null
assert_eq "the retention push exits 0" "0" "$?"
rm -rf "$pushed"; git clone --quiet --branch nodes/active-node "$remote" "$pushed"
assert_eq "the mirror keeps cycles_retained cycles" "$cycles_retained" \
  "$(find "$pushed/cycles" -mindepth 1 -maxdepth 1 -type d | wc -l)"
assert_eq "the oldest cycle is pruned from the mirror" "0" \
  "$(test -e "$pushed/cycles/20260101T000000Z-0" && echo 1 || echo 0)"
assert_eq "the newest cycle survives the prune" "1" \
  "$(test -e "$pushed/cycles/20260720T010000Z-1" && echo 1 || echo 0)"
assert_eq "the node keeps its own history" "1" \
  "$(test -e "$state/cycles/20260101T000000Z-0" && echo 1 || echo 0)"

# --- Local retention ---
# The push also bounds the node's own state_dir (state_local_cycles_retained,
# overridden small here): newest kept, oldest deleted, reviews included — and
# the prune runs before any mirroring, so it happens on every push.
lr_home="$(new_node local-retention-node)"
lr_state="$lr_home/.local/state/poetic-agents"
printf 'log\n' > "$lr_state/log.jsonl"
i=0
while (( i < 5 )); do
  d="$(printf '%s/cycles/20260201T%06dZ-%d' "$lr_state" "$i" "$i")"
  mkdir -p "$d"; printf 'filler\n' > "$d/coordinator.out"
  r="$(printf '%s/reviews/20260201T%06dZ-%d' "$lr_state" "$i" "$i")"
  mkdir -p "$r"; printf 'filler\n' > "$r/review.out"
  i=$(( i + 1 ))
done
out="$(sync_as "$lr_home" active push STATE_SYNC_LOCAL_RETAINED=3)"
assert_eq "the local-retention push exits 0" "0" "$?"
assert_contains "a push reports the local prune" "pruned 2 cycles record(s)" "$out"
assert_eq "local cycles are pruned to the cap" "3" \
  "$(find "$lr_state/cycles" -mindepth 1 -maxdepth 1 -type d | wc -l)"
assert_eq "the oldest local cycle is deleted" "0" \
  "$(test -e "$lr_state/cycles/20260201T000000Z-0" && echo 1 || echo 0)"
assert_eq "the newest local cycle survives" "1" \
  "$(test -e "$lr_state/cycles/20260201T000004Z-4" && echo 1 || echo 0)"
assert_eq "local reviews are pruned to the cap" "3" \
  "$(find "$lr_state/reviews" -mindepth 1 -maxdepth 1 -type d | wc -l)"
# The analytics retention policy (requirement 2.6d): a push that prunes
# cycles/ and reviews/ never reaches log.jsonl, which this fixture seeded
# with content of its own above.
assert_eq "log.jsonl is untouched by the local prune" "log" \
  "$(cat "$lr_state/log.jsonl")"

# A stale directory reappearing below the retention cut is pruned by the next
# push.
mkdir -p "$lr_state/cycles/20250101T000000Z-9"
printf 'stale\n' > "$lr_state/cycles/20250101T000000Z-9/coordinator.out"
out="$(sync_as "$lr_home" active push STATE_SYNC_LOCAL_RETAINED=3)"
assert_eq "the reappearing-stale-dir push exits 0" "0" "$?"
assert_contains "a later push prunes a reappearing stale dir" "pruned 1 cycles record(s)" "$out"
assert_eq "the stale directory is gone" "0" \
  "$(test -e "$lr_state/cycles/20250101T000000Z-9" && echo 1 || echo 0)"

# --- Local retention of the derived files -------------------------------------
# A second, much tighter bound (state_local_streams_retained), on the derived
# files alone: they are megabytes where the records holding them are kilobytes,
# so they go early and the records stay. What this asserts is precisely that
# separation — the record survives them.
#
# Both files in the class are exercised, not just the stream: `.fleet-log.jsonl`
# was absent from this prune until agent-ops#763 and so fell through to the
# record retention, a thousand deep, which is the whole of the bug.
sr_home="$(new_node stream-retention-node)"
sr_state="$sr_home/.local/state/poetic-agents"
# A real event rather than filler: this node's branch survives to the union
# read below, and a line with no `ts` would sort ahead of every dated one.
printf '{"ts":"2026-07-22T00:00:00Z","event":"cycle-start"}\n' > "$sr_state/log.jsonl"
i=0
while (( i < 4 )); do
  d="$(printf '%s/cycles/20260301T%06dZ-%d' "$sr_state" "$i" "$i")"
  mkdir -p "$d"
  printf 'filler\n' > "$d/coordinator.out"
  printf '{"type":"system"}\n' > "$d/coordinator.stream.jsonl"
  printf '{"type":"union"}\n' > "$d/.fleet-log.jsonl"
  r="$(printf '%s/reviews/20260301T%06dZ-%d' "$sr_state" "$i" "$i")"
  mkdir -p "$r"
  printf 'filler\n' > "$r/review.out"
  printf '{"type":"system"}\n' > "$r/reviewer.stream.jsonl"
  printf '{"type":"union"}\n' > "$r/.fleet-log.jsonl"
  i=$(( i + 1 ))
done
out="$(sync_as "$sr_home" active push STATE_SYNC_LOCAL_RETAINED=10 STATE_SYNC_STREAMS_RETAINED=2)"
assert_eq "the derived-retention push exits 0" "0" "$?"
# Four files across the two doomed cycle directories: a stream and a snapshot
# each. The count is the assertion that the snapshot is in the class at all.
assert_contains "a push reports the derived prune" "pruned 4 derived file(s) from cycles" "$out"
assert_eq "the oldest cycle's stream is deleted" "0" \
  "$(test -e "$sr_state/cycles/20260301T000000Z-0/coordinator.stream.jsonl" && echo 1 || echo 0)"
assert_eq "…and its fleet-log snapshot with it" "0" \
  "$(test -e "$sr_state/cycles/20260301T000000Z-0/.fleet-log.jsonl" && echo 1 || echo 0)"
assert_eq "…while the record it belonged to is untouched" "1" \
  "$(test -f "$sr_state/cycles/20260301T000000Z-0/coordinator.out" && echo 1 || echo 0)"
assert_eq "the newest cycles keep their streams" "1" \
  "$(test -f "$sr_state/cycles/20260301T000003Z-3/coordinator.stream.jsonl" && echo 1 || echo 0)"
assert_eq "…and their snapshots — the running cycle still reads its own" "1" \
  "$(test -f "$sr_state/cycles/20260301T000003Z-3/.fleet-log.jsonl" && echo 1 || echo 0)"
assert_eq "reviews are bounded the same way" "0" \
  "$(test -e "$sr_state/reviews/20260301T000000Z-0/reviewer.stream.jsonl" && echo 1 || echo 0)"
assert_eq "…snapshots included" "0" \
  "$(test -e "$sr_state/reviews/20260301T000000Z-0/.fleet-log.jsonl" && echo 1 || echo 0)"
assert_eq "…and keep their own records too" "1" \
  "$(test -f "$sr_state/reviews/20260301T000000Z-0/review.out" && echo 1 || echo 0)"
assert_eq "no cycle directory is removed by the derived prune" "4" \
  "$(find "$sr_state/cycles" -mindepth 1 -maxdepth 1 -type d | wc -l)"

# A derived file already in the mirror from before its exclusion existed is
# deleted from it, not merely left behind: `--delete-excluded` is what makes
# the rules retroactive, and without it every node's branch would keep whatever
# it had published up to the day this landed. For `.fleet-log.jsonl` that is
# not a hypothetical tail: at agent-ops#763 every copy on every branch predated
# the rule, so the retroactive half is the entire reclamation.
git clone --quiet --branch nodes/active-node "$remote" "$tmp_dir/legacy"
mkdir -p "$tmp_dir/legacy/cycles/20260720T010000Z-1"
printf '{"type":"system"}\n' > "$tmp_dir/legacy/cycles/20260720T010000Z-1/legacy.stream.jsonl"
printf '{"type":"union"}\n' > "$tmp_dir/legacy/cycles/20260720T010000Z-1/.fleet-log.jsonl"
git -C "$tmp_dir/legacy" add -A >/dev/null 2>&1
git -C "$tmp_dir/legacy" commit --quiet -m "state: derived files published before the exclusions" >/dev/null 2>&1
git -C "$tmp_dir/legacy" push --quiet origin HEAD:nodes/active-node >/dev/null 2>&1
sync_as "$active_home" active push >/dev/null
assert_eq "the legacy-derived push exits 0" "0" "$?"
rm -rf "$tmp_dir/pushed-again"
git clone --quiet --branch nodes/active-node "$remote" "$tmp_dir/pushed-again"
assert_eq "a stream already in the mirror is deleted from it" "0" \
  "$(test -e "$tmp_dir/pushed-again/cycles/20260720T010000Z-1/legacy.stream.jsonl" && echo 1 || echo 0)"
assert_eq "a snapshot already in the mirror is deleted from it" "0" \
  "$(test -e "$tmp_dir/pushed-again/cycles/20260720T010000Z-1/.fleet-log.jsonl" && echo 1 || echo 0)"

# ==============================================================================
# mirror integrity — a corrupted mirror is discarded and rebuilt, never
# repaired or silently trusted (#604)
# ==============================================================================
# The fault this reproduces: an unclean shutdown leaves a loose object
# truncated to zero bytes (the field evidence behind #604 — ockham-container
# from 2026-08-08, ockham-2 on 2026-08-24, four empty objects each time), and
# `mirror_init` used to treat `.git/` existing as the whole check.
mi_home="$(new_node mirror-integrity-node)"
mi_state="$mi_home/.local/state/poetic-agents"
mi_mirror="$mi_home/.cache/poetic-agents/workspaces/.agent-ops-state"
printf '{"ts":"2026-08-25T00:00:00Z","event":"cycle-start"}\n' > "$mi_state/log.jsonl"

find_head_object() {  # find_head_object <mirror-dir> -> path of the loose
  # object holding the mirror's own HEAD commit — always reachable, unlike
  # an arbitrary loose object, some of which are amend-orphaned history that
  # `git fsck --connectivity-only` never walks.
  local mirror="$1" sha
  sha="$(git -C "$mirror" rev-parse HEAD 2>/dev/null)" || return 1
  printf '%s/.git/objects/%s/%s\n' "$mirror" "${sha:0:2}" "${sha:2}"
}

truncate_object() {  # truncate_object <path> — git writes loose objects
  # read-only, so the write needs its own permission first.
  chmod u+w "$1" && : > "$1"
}

# A brand-new mirror's first-ever init has nothing to have failed, so it must
# never be reported as a rebuild — otherwise every node's first-ever push
# would report self-healing that never happened.
out="$(sync_as "$mi_home" active push)"
assert_eq "the first-ever push on a fresh mirror exits 0" "0" "$?"
mi_pushed_1="$tmp_dir/mi-pushed-1"
git clone --quiet --branch nodes/mirror-integrity-node "$remote" "$mi_pushed_1"
assert_eq "a fresh mirror's first push reports no rebuild" "null" \
  "$(jq -c '.mirror' "$mi_pushed_1/heartbeat.json" 2>/dev/null)"

# Truncate a loose object the way the unclean shutdown did.
corrupt_1="$(find_head_object "$mi_mirror")"
assert_eq "the HEAD commit is a loose object to corrupt" "1" "$([[ -f "$corrupt_1" ]] && echo 1 || echo 0)"
truncate_object "$corrupt_1"
assert_eq "the mirror now fails its own connectivity check" "1" \
  "$(git -C "$mi_mirror" fsck --connectivity-only >/dev/null 2>&1 && echo 0 || echo 1)"

# New content, so the next push has to actually reach the remote with the
# right content — not merely that the check fired.
printf '{"ts":"2026-08-25T00:05:00Z","event":"cycle-end"}\n' >> "$mi_state/log.jsonl"
out="$(sync_as "$mi_home" active push)"
assert_eq "the push over a corrupted mirror still exits 0" "0" "$?"
assert_contains "it reports discarding and rebuilding the mirror" \
  "failed its integrity check" "$out"

mi_pushed_2="$tmp_dir/mi-pushed-2"
git clone --quiet --branch nodes/mirror-integrity-node "$remote" "$mi_pushed_2"
assert_eq "the rebuilt push publishes the node's current log content" "1" \
  "$(grep -c 'cycle-end' "$mi_pushed_2/log.jsonl")"
assert_eq "the heartbeat records the rebuild" "rebuilt" \
  "$(jq -r '.mirror.status' "$mi_pushed_2/heartbeat.json" 2>/dev/null)"
assert_eq "as the first rebuild this node has ever needed" "1" \
  "$(jq -r '.mirror.count' "$mi_pushed_2/heartbeat.json" 2>/dev/null)"
assert_eq "the branch is still a single rolling commit after the rebuild" "1" \
  "$(git -C "$mi_pushed_2" rev-list --count nodes/mirror-integrity-node)"

# A second, independent corruption is a *repeat* rebuild, and the record
# under state_dir — which outlives the mirror it describes — is what makes
# that a visible fact rather than one more indistinguishable line.
corrupt_2="$(find_head_object "$mi_mirror")"
assert_eq "the HEAD commit is a loose object a second time" "1" "$([[ -f "$corrupt_2" ]] && echo 1 || echo 0)"
truncate_object "$corrupt_2"
out="$(sync_as "$mi_home" active push)"
assert_eq "the second corrupted push exits 0" "0" "$?"
mi_pushed_3="$tmp_dir/mi-pushed-3"
git clone --quiet --branch nodes/mirror-integrity-node "$remote" "$mi_pushed_3"
assert_eq "a repeat rebuild bumps the count rather than reading like the first" "2" \
  "$(jq -r '.mirror.count' "$mi_pushed_3/heartbeat.json" 2>/dev/null)"

# `mirror_init` sits ahead of both do_push and do_fetch (requirement 2.5), so
# a fetch hitting the same corrupted mirror must rebuild it too — proven here
# by a third corruption discovered through `fetch` instead of `push`, with
# the following push (which is what actually reads the durable record) then
# showing the count has moved again.
corrupt_3="$(find_head_object "$mi_mirror")"
assert_eq "the HEAD commit is a loose object a third time" "1" "$([[ -f "$corrupt_3" ]] && echo 1 || echo 0)"
truncate_object "$corrupt_3"
out="$(sync_as "$mi_home" active fetch)"
assert_eq "a fetch over a corrupted mirror still exits 0" "0" "$?"
assert_contains "the fetch itself reports discarding and rebuilding the mirror" \
  "failed its integrity check" "$out"
out="$(sync_as "$mi_home" active push)"
assert_eq "the push after the fetch-triggered rebuild exits 0" "0" "$?"
mi_pushed_4="$tmp_dir/mi-pushed-4"
git clone --quiet --branch nodes/mirror-integrity-node "$remote" "$mi_pushed_4"
assert_eq "a rebuild triggered by fetch counts the same as one triggered by push" "3" \
  "$(jq -r '.mirror.count' "$mi_pushed_4/heartbeat.json" 2>/dev/null)"

# A non-empty gc.log is a failed check in its own right — #604's second
# clause. It is git's record that its last gc failed and will not be retried,
# and on 2026-09-14/15 both workstation mirrors carried one (a `pack-objects`
# the kernel had OOM-killed) over a store fsck called clean: 24,000–27,000
# valid loose objects that nothing would ever pack again.
printf 'error: pack-objects died of signal 9\nfatal: failed to run repack\n' \
  > "$mi_mirror/.git/gc.log"
assert_eq "the mirror with a gc.log still passes fsck (the objects are valid)" "0" \
  "$(git -C "$mi_mirror" fsck --connectivity-only >/dev/null 2>&1 && echo 0 || echo 1)"
out="$(sync_as "$mi_home" active push)"
assert_eq "a push over a mirror carrying a gc.log exits 0" "0" "$?"
assert_contains "a non-empty gc.log fails the integrity check on its own" \
  "failed its integrity check" "$out"
assert_eq "the rebuilt mirror carries no gc.log" "0" \
  "$(test -e "$mi_mirror/.git/gc.log" && echo 1 || echo 0)"
mi_pushed_5="$tmp_dir/mi-pushed-5"
git clone --quiet --branch nodes/mirror-integrity-node "$remote" "$mi_pushed_5"
assert_eq "a gc.log rebuild is recorded like a corruption rebuild" "4" \
  "$(jq -r '.mirror.count' "$mi_pushed_5/heartbeat.json" 2>/dev/null)"

# ==============================================================================
# mirror object store — bounded by configuration, so the mirror's own gc is
# never again the thing that fails (2026-09-15; lib/mirror-integrity.sh's
# header has the mechanism)
# ==============================================================================
# Every push amends one rolling commit and force-pushes it, orphaning the
# previous snapshot. Left to git's defaults the reflog kept every orphan for
# thirty days and `gc --auto` then handed the month's pile to a `pack-objects`
# with one thread per CPU, inside a 1536m scheduler — which the kernel killed,
# leaving a gc.log that stopped every later gc. The remedy is configuration
# `mirror_init` applies on every run, so the assertions here are on the
# mirror the section above has been pushing through.
while read -r key value; do
  [[ -n "$key" ]] || continue
  assert_eq "mirror_init sets $key" "$value" \
    "$(git -C "$mi_mirror" config --local --get "$key" 2>/dev/null)"
done < <(mirror_store_config)
assert_eq "the mirror keeps no reflog files" "0" \
  "$(test -e "$mi_mirror/.git/logs" && echo 1 || echo 0)"

# A mirror that predates the configuration carries reflog files, and with
# core.logAllRefUpdates=false git still appends to any that exist — which is
# exactly how a hand compaction on 2026-09-15 left the pile regrowing. So
# the files themselves must go, not merely be expired.
mkdir -p "$mi_mirror/.git/logs/refs/heads"
printf '0000000000000000000000000000000000000000 %s x <x> 0 +0000\tstale\n' \
  "$(git -C "$mi_mirror" rev-parse HEAD)" > "$mi_mirror/.git/logs/HEAD"
out="$(sync_as "$mi_home" active push)"
assert_eq "a push over a mirror with old reflog files exits 0" "0" "$?"
assert_eq "…and removes them" "0" \
  "$(test -e "$mi_mirror/.git/logs" && echo 1 || echo 0)"

# The bound itself. `gc --auto`'s loose-object trigger estimates the count
# from the `objects/17/` bucket alone (one object there stands for 256), so
# it is forced here by planting two blobs whose ids begin with `17` — the
# contents below were found by search and are asserted before use — with the
# threshold lowered to 1 through git's environment-config channel, which
# reaches every git process state-sync.sh runs without touching the mirror's
# own config. The estimate needs *more than* threshold/256 objects in the
# bucket, hence two. The shape this pins is the one lib/mirror-integrity.sh's
# header describes: the gc a loose trigger runs is incremental and, because
# the mirror's remote-tracking ref still names the snapshot the amend has
# just superseded, packs that one snapshot; the push after it consolidates
# (gc.autoPackLimit 1) and drops what the push before made garbage. So the
# store settles at one pack holding the current snapshot and at most the one
# before it — never a reflog's month of them.
gc_home="$(new_node gc-bound-node)"
gc_state="$gc_home/.local/state/poetic-agents"
gc_mirror="$gc_home/.cache/poetic-agents/workspaces/.agent-ops-state"
gc_env=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=1)
gc_loose()       { git -C "$gc_mirror" count-objects -v | awk '/^count:/{print $2}'; }
gc_packs()       { git -C "$gc_mirror" count-objects -v | awk '/^packs:/{print $2}'; }
gc_in_pack()     { git -C "$gc_mirror" count-objects -v | awk '/^in-pack:/{print $2}'; }
gc_unreachable() { git -C "$gc_mirror" fsck --unreachable --no-progress 2>/dev/null | grep -c '^unreachable' || true; }
# Two pushes with changing content first, each amend orphaning the snapshot
# before it, and no gc yet — nothing has landed in the sampled bucket.
printf '{"ts":"2026-09-15T00:00:00Z","event":"cycle-start"}\n' > "$gc_state/log.jsonl"
out="$(sync_as "$gc_home" active push "${gc_env[@]}")"
assert_eq "the first push on the gc-bound node exits 0" "0" "$?"
gc_first="$(git -C "$gc_mirror" rev-parse HEAD)"
printf '{"ts":"2026-09-15T00:05:00Z","event":"cycle-end"}\n' >> "$gc_state/log.jsonl"
out="$(sync_as "$gc_home" active push "${gc_env[@]}")"
assert_eq "the second push exits 0" "0" "$?"
assert_eq "before any gc the orphaned snapshot's objects are still loose" "1" "$(( $(gc_loose) > 0 ))"
assert_eq "…and no reflog holds them reachable" "1" "$(( $(gc_unreachable) > 0 ))"
# The third push plants the bucket, so the commit that amends in this
# content triggers the gc — over a store now holding two orphaned snapshots.
printf 'seed-553' > "$gc_state/bucket-a"
printf 'seed-1537' > "$gc_state/bucket-b"
assert_eq "the two planted blobs hash into git's sampled bucket" "17 17" \
  "$(for f in bucket-a bucket-b; do git hash-object "$gc_state/$f" | cut -c1-2; done | tr '\n' ' ' | sed 's/ $//')"
printf '{"ts":"2026-09-15T00:10:00Z","event":"cycle-start"}\n' >> "$gc_state/log.jsonl"
gc_before_third="$(git -C "$gc_mirror" rev-parse HEAD)"
out="$(sync_as "$gc_home" active push "${gc_env[@]}")"
assert_eq "the third push exits 0" "0" "$?"
assert_eq "the gc it triggered ran in the foreground: no loose object is left" "0" "$(gc_loose)"
assert_eq "…into one pack" "1" "$(gc_packs)"
assert_eq "…the first snapshot, orphaned two pushes ago, pruned outright rather than kept for two weeks" "1" \
  "$(git -C "$gc_mirror" cat-file -e "$gc_first" 2>/dev/null && echo 0 || echo 1)"
assert_eq "…and only the snapshot this very push superseded still packed" "" \
  "$(comm -23 <(git -C "$gc_mirror" fsck --unreachable --no-progress 2>/dev/null | awk '{print $3}' | sort) \
              <(git -C "$gc_mirror" rev-list --objects "$gc_before_third" | awk '{print $1}' | sort))"
assert_eq "…with no gc.log written, so the next auto-gc is not declined" "0" \
  "$(test -e "$gc_mirror/.git/gc.log" && echo 1 || echo 0)"
# A fourth push with new content, no trigger: its predecessor becomes garbage
# in the pack. A fifth forces another incremental gc (a second pack); the
# sixth is what consolidates — the depth-1 fetch that opens it runs its own
# auto-maintenance, finds the pack count over the limit and repacks with
# `-a`, before the amend writes the sixth snapshot — and what remains is one
# pack of the fifth snapshot and the ones it reaches, the sixth snapshot
# loose until the next incremental gc, and no garbage older than the fifth.
printf '{"ts":"2026-09-15T00:15:00Z","event":"cycle-end"}\n' >> "$gc_state/log.jsonl"
out="$(sync_as "$gc_home" active push "${gc_env[@]}")"
assert_eq "the fourth push exits 0" "0" "$?"
printf 'seed-1691' > "$gc_state/bucket-c"
printf 'seed-2166' > "$gc_state/bucket-d"
assert_eq "the second planted pair hashes into the bucket too" "17 17" \
  "$(for f in bucket-c bucket-d; do git hash-object "$gc_state/$f" | cut -c1-2; done | tr '\n' ' ' | sed 's/ $//')"
printf '{"ts":"2026-09-15T00:20:00Z","event":"cycle-start"}\n' >> "$gc_state/log.jsonl"
out="$(sync_as "$gc_home" active push "${gc_env[@]}")"
assert_eq "the fifth push exits 0" "0" "$?"
assert_eq "the second incremental gc leaves a second pack" "2" "$(gc_packs)"
printf '{"ts":"2026-09-15T00:25:00Z","event":"cycle-end"}\n' >> "$gc_state/log.jsonl"
gc_before_sixth="$(git -C "$gc_mirror" rev-parse HEAD)"
out="$(sync_as "$gc_home" active push "${gc_env[@]}")"
assert_eq "the sixth push exits 0" "0" "$?"
assert_eq "the push after an incremental gc consolidates to one pack" "1" "$(gc_packs)"
assert_eq "…every loose object being the current snapshot's own, none of it garbage" "" \
  "$(comm -23 <(find "$gc_mirror/.git/objects" -type f -path '*/??/*' | sed -E 's#.*/objects/(..)/(.*)#\1\2#' | sort) \
              <(git -C "$gc_mirror" rev-list --objects HEAD | awk '{print $1}' | sort))"
assert_eq "…holding the current snapshot and at most the one before it" "1" \
  "$(( $(gc_in_pack) <= $(git -C "$gc_mirror" rev-list --objects --all | wc -l) \
                        + $(git -C "$gc_mirror" rev-list --objects "$gc_before_sixth" | wc -l) ))"
assert_eq "…every unreachable object belonging to that one superseded snapshot" "" \
  "$(comm -23 <(git -C "$gc_mirror" fsck --unreachable --no-progress 2>/dev/null | awk '{print $3}' | sort) \
              <(git -C "$gc_mirror" rev-list --objects "$gc_before_sixth" | awk '{print $1}' | sort))"
assert_eq "…and still no gc.log" "0" "$(test -e "$gc_mirror/.git/gc.log" && echo 1 || echo 0)"
gc_pushed="$tmp_dir/gc-pushed"
git clone --quiet --branch nodes/gc-bound-node "$remote" "$gc_pushed"
assert_eq "the branch is still one rolling commit" "1" \
  "$(git -C "$gc_pushed" rev-list --count nodes/gc-bound-node)"
assert_eq "…carrying the node's current log content" "6" \
  "$(grep -c . "$gc_pushed/log.jsonl")"
assert_eq "…and nothing reported a rebuild — this was a gc, not a discard" "null" \
  "$(jq -c '.mirror' "$gc_pushed/heartbeat.json" 2>/dev/null)"

# ==============================================================================
# the mirror's own index.lock — an orphan is cleared, a live one is not, and
# a push that fails says so (agent-ops#1377)
# ==============================================================================
# The fault this reproduces: a git that died mid-write left `.git/index.lock`
# behind, and every later push failed at the first index write while its own
# progress lines kept printing — 27 hours on poetic-1 (2026-09-09 to -11),
# three days on poetic-2 (2026-09-13 to -15), and nothing on either node
# named it.
il_home="$(new_node index-lock-node)"
il_state="$il_home/.local/state/poetic-agents"
il_mirror="$il_home/.cache/poetic-agents/workspaces/.agent-ops-state"
il_push_s="$(config_defaults "$SCRIPT_DIR/config.json" "$SCRIPT_DIR/config.schema.json" \
  | jq -r '.schedule.state_sync_push_minutes * 60 | floor')"
printf '{"ts":"2026-09-13T01:40:00Z","event":"cycle-start"}\n' > "$il_state/log.jsonl"
out="$(sync_as "$il_home" active push)"
assert_eq "the index-lock node's first push exits 0" "0" "$?"

# A fresh lock — younger than one push interval — may belong to a live git,
# and is left alone. The push then fails at the write that needs it, and
# that failure is now a named event rather than a silent non-zero exit.
: > "$il_mirror/.git/index.lock"
printf '{"ts":"2026-09-13T01:45:00Z","event":"cycle-end"}\n' >> "$il_state/log.jsonl"
out="$(sync_as "$il_home" active push)"
assert_eq "a push over a fresh index.lock exits non-zero" "1" "$?"
assert_contains "…and says it left the young lock alone" \
  "within one push interval — leaving it" "$out"
assert_contains "…and names the step and git's own fatal line" \
  "push failed at reset — fatal:" "$out"
assert_eq "…and logs a state-sync-push-failed event with that line" "1" \
  "$(jq -c 'select(.event == "state-sync-push-failed" and .step == "reset" and (.detail | startswith("fatal:")))' \
       "$il_state/log.jsonl" | wc -l)"
assert_eq "the fresh lock is still there" "1" "$(test -e "$il_mirror/.git/index.lock" && echo 1 || echo 0)"

# An old lock with a git process working in the mirror is a live lock,
# whatever its age: never removed. The process here is a sleeper wearing
# git's name with the mirror as its working directory — the two facts
# `mirror_git_busy` reads — since a real git cannot be made to hold the
# index lock for the length of a test.
touch -d "@$(( $(date +%s) - il_push_s * 3 ))" "$il_mirror/.git/index.lock"
( cd "$il_mirror" && exec -a git sleep 60 ) &
il_sleeper=$!
sleep 0.2
out="$(sync_as "$il_home" active push)"
assert_eq "a push over an old lock with a git process in the mirror exits non-zero" "1" "$?"
assert_contains "…and says why the lock was left" \
  "a git process is working in the mirror — leaving it" "$out"
assert_eq "the lock a live process may hold is never removed" "1" \
  "$(test -e "$il_mirror/.git/index.lock" && echo 1 || echo 0)"
kill "$il_sleeper" 2>/dev/null; wait "$il_sleeper" 2>/dev/null

# The same old lock with no git process alive is the orphan: cleared, logged
# with its age, and the push completes with the node's current content.
out="$(sync_as "$il_home" active push)"
assert_eq "a push over an orphaned index.lock exits 0" "0" "$?"
assert_contains "…and reports clearing it" "cleared an orphaned index.lock" "$out"
assert_eq "…the lock is gone" "0" "$(test -e "$il_mirror/.git/index.lock" && echo 1 || echo 0)"
assert_eq "…a state-sync-lock-cleared event carries an age past one push interval" "1" \
  "$(jq -c --argjson p "$il_push_s" 'select(.event == "state-sync-lock-cleared" and .age_s > $p)' \
       "$il_state/log.jsonl" | wc -l)"
assert_eq "…the event names the node" "index-lock-node" \
  "$(jq -r 'select(.event == "state-sync-lock-cleared") | .node' "$il_state/log.jsonl" | tail -1)"
assert_eq "…with a null cycle, since no cycle wrote it" "null" \
  "$(jq -c 'select(.event == "state-sync-lock-cleared") | .cycle' "$il_state/log.jsonl" | tail -1)"
il_pushed="$tmp_dir/il-pushed"
git clone --quiet --branch nodes/index-lock-node "$remote" "$il_pushed"
assert_eq "…and the branch carries the content the failed pushes could not publish" "1" \
  "$(grep -c 'cycle-end' "$il_pushed/log.jsonl")"
assert_eq "…including both events, which replicate like any other" "2" \
  "$(jq -r 'select(.event == "state-sync-push-failed" or .event == "state-sync-lock-cleared") | .event' \
       "$il_pushed/log.jsonl" | sort -u | wc -l)"

# ==============================================================================
# fetch — peers materialised whole, pruned when gone
# ==============================================================================
out="$(sync_as "$standby_home" standby fetch)"
assert_eq "fetch exits 0" "0" "$?"
sb_peers="$(fleet_peers_dir "$standby_home/.cache/poetic-agents/workspaces")"
assert_eq "a fetch materialises the peer's log" "1" \
  "$(test -f "$sb_peers/active-node/log.jsonl" && echo 1 || echo 0)"
assert_eq "…and the peer's heartbeat" "active-node" \
  "$(jq -r '.node' "$sb_peers/active-node/heartbeat.json" 2>/dev/null)"
assert_eq "a fetch does not include the node itself" "0" \
  "$(test -e "$sb_peers/standby-node" && echo 1 || echo 0)"
assert_eq "a fetch leaves the node's own state alone" "1" \
  "$(grep -c '2026-07-21' "$sb_state/log.jsonl")"
assert_eq "peers do not carry locks" "0" \
  "$(test -e "$sb_peers/active-node/lock.json" && echo 1 || echo 0)"

# The other direction: the active node holds the standby.
sync_as "$active_home" active fetch >/dev/null
assert_eq "the active node's fetch exits 0" "0" "$?"
a_peers="$(fleet_peers_dir "$active_home/.cache/poetic-agents/workspaces")"
assert_eq "the active node holds its peers too" "1" \
  "$(test -f "$a_peers/standby-node/log.jsonl" && echo 1 || echo 0)"

# ==============================================================================
# fetch — the outbound answer for self (agent-ops#602)
# ==============================================================================
# The fetch above already brought this node's own branch down alongside every
# peer's (`+refs/heads/nodes/*`), so reading it back costs no extra network
# round trip: a node's own freshness must be read from what the shared state
# holds for it, never from its own clock — the read that went missing on
# 2026-08-08.
published_file="$active_home/.local/state/poetic-agents/.state-sync-published.json"
assert_eq "a fetch writes this node's own publication cache" "1" \
  "$(test -f "$published_file" && echo 1 || echo 0)"
remote_hb_ts="$(git -C "$remote" show nodes/active-node:heartbeat.json 2>/dev/null | jq -r '.ts')"
assert_eq "…carrying the ts the remote branch's own heartbeat holds" "$remote_hb_ts" \
  "$(jq -r '.ts' "$published_file" 2>/dev/null)"

# A branch with no heartbeat.json at all (unreachable in practice — every push
# writes one, but the read-back must not crash on it) falls back to the ref's
# own committer date rather than leaving the cache empty. A dedicated remote
# and mirror, never the shared one above: this fixture's own log.jsonl is not
# valid JSON, and letting it leak into the shared remote would poison the
# union read further down in this file for every peer of it.
no_hb_remote="$tmp_dir/no-heartbeat-remote.git"
git init --quiet --bare --initial-branch=main "$no_hb_remote"
worktree="$tmp_dir/no-hb-worktree"
git init --quiet "$worktree"
printf 'no heartbeat here\n' > "$worktree/log.jsonl"
git -C "$worktree" add -A
git -C "$worktree" -c user.name=test -c user.email=test@test \
  commit --quiet -m "state: no-heartbeat-node (no heartbeat.json)"
git -C "$worktree" push --quiet "$no_hb_remote" "HEAD:refs/heads/nodes/no-heartbeat-node"
committer_epoch="$(git -C "$worktree" log -1 --format=%ct)"
no_hb_home="$(new_node no-heartbeat-node)"
env HOME="$no_hb_home" AGENT_OPS_ROLE=standby NODE_NAME=no-heartbeat-node \
  STATE_SYNC_REMOTE="$no_hb_remote" "$SYNC" fetch >/dev/null
assert_eq "the no-heartbeat fetch exits 0" "0" "$?"
no_hb_published="$no_hb_home/.local/state/poetic-agents/.state-sync-published.json"
assert_eq "a branch with no heartbeat.json still writes a publication cache" "1" \
  "$(test -f "$no_hb_published" && echo 1 || echo 0)"
assert_eq "…falling back to the ref's own committer date" "$committer_epoch" \
  "$(date -u -d "$(jq -r '.ts' "$no_hb_published" 2>/dev/null)" +%s 2>/dev/null)"

# A deleted branch is a decommissioned node: its peer copy goes on the next
# fetch.
git -C "$remote" update-ref -d refs/heads/nodes/local-retention-node
sync_as "$standby_home" standby fetch >/dev/null
assert_eq "the branch-pruning fetch exits 0" "0" "$?"
assert_eq "a vanished branch prunes its peer copy" "0" \
  "$(test -e "$sb_peers/local-retention-node" && echo 1 || echo 0)"

# ==============================================================================
# fetch — a real failure is distinguished from the bootstrap no-op (#693)
# ==============================================================================
# A successful fetch marks the peers directory fresh.
marker="$sb_peers/.last-fetch.json"
assert_eq "a successful fetch marks the peers fresh" "true" \
  "$(jq -r '.ok' "$marker" 2>/dev/null)"
# Written whole and renamed into place, so a reader never catches it empty —
# and the write-side temporary is not left behind for one to find.
assert_eq "the marker leaves no half-written temporary behind" "0" \
  "$(test -e "$marker.tmp" && echo 1 || echo 0)"

# The genuine bootstrap case: a state repository with no node branches at all
# (a fresh bare repo, never pushed to) stays a silent no-op — exit 0, no
# marker written, because no fetch has ever actually run against real peer
# data.
bootstrap_remote="$tmp_dir/bootstrap-remote.git"
git init --quiet --bare --initial-branch=main "$bootstrap_remote"
bootstrap_home="$(new_node bootstrap-node)"
bootstrap_peers="$(fleet_peers_dir "$bootstrap_home/.cache/poetic-agents/workspaces")"
out="$(env HOME="$bootstrap_home" AGENT_OPS_ROLE=standby NODE_NAME=bootstrap-node \
  STATE_SYNC_REMOTE="$bootstrap_remote" "$SYNC" fetch 2>&1)"
assert_eq "the bootstrap fetch exits 0" "0" "$?"
assert_contains "the bootstrap fetch names itself as such" \
  "no node branches yet" "$out"
assert_eq "the bootstrap fetch writes no marker" "0" \
  "$(test -e "$bootstrap_peers/.last-fetch.json" && echo 1 || echo 0)"

# A real failure — modelled here as an unreachable remote, standing in for
# dead credentials or a network outage — is not the bootstrap case: it logs
# git's stderr, exits non-zero so the scheduler surfaces it, and marks the
# peers directory stale rather than leaving it silently looking fresh.
unreachable_home="$(new_node unreachable-node)"
unreachable_peers="$(fleet_peers_dir "$unreachable_home/.cache/poetic-agents/workspaces")"
out="$(env HOME="$unreachable_home" AGENT_OPS_ROLE=standby NODE_NAME=unreachable-node \
  STATE_SYNC_REMOTE="$tmp_dir/does-not-exist.git" "$SYNC" fetch 2>&1)"
status=$?
assert_eq "a real fetch failure exits non-zero" "1" "$status"
assert_contains "a real fetch failure is logged, not swallowed" \
  "could not reach the state repository" "$out"
assert_eq "a real fetch failure marks the peers stale" "false" \
  "$(jq -r '.ok' "$unreachable_peers/.last-fetch.json" 2>/dev/null)"

# A peer directory that was fresh and then starts failing is marked stale in
# place — a reader must see the flip, not a directory that still looks fresh
# from the last successful fetch.
was_fresh_home="$active_home"
was_fresh_peers="$a_peers"
sync_as "$was_fresh_home" active fetch >/dev/null
assert_eq "was fresh before the failure" "true" \
  "$(jq -r '.ok' "$was_fresh_peers/.last-fetch.json" 2>/dev/null)"
env HOME="$was_fresh_home" AGENT_OPS_ROLE=active NODE_NAME="$(basename "$was_fresh_home")" \
  STATE_SYNC_REMOTE="$tmp_dir/does-not-exist.git" "$SYNC" fetch >/dev/null 2>&1
assert_eq "a previously fresh peers directory flips to stale on failure" "false" \
  "$(jq -r '.ok' "$was_fresh_peers/.last-fetch.json" 2>/dev/null)"

# ==============================================================================
# the union read (lib/fleet.sh)
# ==============================================================================
union="$(fleet_logs "$sb_state" "$sb_peers" log.jsonl)"
assert_contains "the union carries the node's own events" '2026-07-21' "$union"
assert_contains "the union carries the peer's events" '2026-07-20' "$union"
assert_eq "the union is time-ordered" "1" \
  "$([[ "$(printf '%s\n' "$union" | head -1)" == *2026-07-20T00:00:00Z* ]] && echo 1 || echo 0)"

# ==============================================================================
# fleet_logs_healthy — the gate requirement 38b's live reconciliation reads
# before drawing a negative from the union (agent-ops#816 review)
# ==============================================================================
union_log_file="$tmp_dir/union-healthy.jsonl"
printf '%s\n' "$union" > "$union_log_file"
empty_union_log_file="$tmp_dir/union-empty.jsonl"
: > "$empty_union_log_file"

assert_eq "a populated union with a fresh (ok:true) peers marker reads healthy" "0" \
  "$(fleet_logs_healthy "$sb_state" "$sb_peers" "$union_log_file" >/dev/null 2>&1; echo $?)"
assert_eq "an empty union reads unhealthy regardless of the peers marker" "1" \
  "$(fleet_logs_healthy "$sb_state" "$sb_peers" "$empty_union_log_file" >/dev/null 2>&1; echo $?)"
assert_eq "a populated union behind a stale (ok:false) peers marker reads unhealthy" "1" \
  "$(fleet_logs_healthy "$sb_state" "$unreachable_peers" "$union_log_file" >/dev/null 2>&1; echo $?)"
no_marker_peers="$tmp_dir/no-marker-peers"
mkdir -p "$no_marker_peers"
assert_eq "a populated union with a peers directory never fetched (no marker at all) reads healthy" "0" \
  "$(fleet_logs_healthy "$sb_state" "$no_marker_peers" "$union_log_file" >/dev/null 2>&1; echo $?)"

# ==============================================================================
# fleet_mark_peers — the marker schema and its transition rule (#990, owner
# decision at escalation #1065): a last-successful-fetch time a failure
# carries forward rather than overwrites, and a marker that stops moving once
# an outage sets in.
# ==============================================================================
mark_dir="$tmp_dir/mark-peers"
mkdir -p "$mark_dir"
marker_file="$mark_dir/.last-fetch.json"

fleet_mark_peers "$mark_dir" true
assert_eq "a success writes ok:true" "true" "$(jq -r '.ok' "$marker_file")"
assert_eq "  ... with ts and last_ok_ts equal" "1" \
  "$([[ "$(jq -r '.ts' "$marker_file")" == "$(jq -r '.last_ok_ts' "$marker_file")" ]] && echo 1 || echo 0)"

first_success_ts="$(jq -r '.ts' "$marker_file")"
sleep 1
fleet_mark_peers "$mark_dir" false
assert_eq "the first failure after a success writes ok:false" "false" "$(jq -r '.ok' "$marker_file")"
assert_eq "  ... carrying last_ok_ts forward unchanged from the previous marker" "$first_success_ts" \
  "$(jq -r '.last_ok_ts' "$marker_file")"
assert_eq "  ... with a new ts" "1" \
  "$([[ "$(jq -r '.ts' "$marker_file")" != "$first_success_ts" ]] && echo 1 || echo 0)"

before_mtime="$(stat -c %Y "$marker_file")"
before_bytes="$(cat "$marker_file")"
sleep 1
fleet_mark_peers "$mark_dir" false
after_mtime="$(stat -c %Y "$marker_file")"
after_bytes="$(cat "$marker_file")"
assert_eq "a second consecutive failure leaves the marker file byte-identical" "1" \
  "$([[ "$before_bytes" == "$after_bytes" ]] && echo 1 || echo 0)"
assert_eq "  ... and mtime-unchanged — its mtime feeds local_state_fingerprint, so a needless move here would rebuild the dashboard once per failed fetch attempt" "1" \
  "$([[ "$before_mtime" == "$after_mtime" ]] && echo 1 || echo 0)"

sleep 1
fleet_mark_peers "$mark_dir" true
assert_eq "a success after a run of failures restores ok:true" "true" "$(jq -r '.ok' "$marker_file")"
assert_eq "  ... with ts = last_ok_ts = now" "1" \
  "$([[ "$(jq -r '.ts' "$marker_file")" == "$(jq -r '.last_ok_ts' "$marker_file")" ]] && echo 1 || echo 0)"

mark_no_marker_dir="$tmp_dir/mark-no-marker"
mkdir -p "$mark_no_marker_dir"
fleet_mark_peers "$mark_no_marker_dir" false
assert_eq "a failure with no marker present writes ok:false" "false" \
  "$(jq -r '.ok' "$mark_no_marker_dir/.last-fetch.json")"
assert_eq "  ... and last_ok_ts:null, since there is no prior success to carry forward" "null" \
  "$(jq -r '.last_ok_ts' "$mark_no_marker_dir/.last-fetch.json")"

mark_legacy_dir="$tmp_dir/mark-legacy"
mkdir -p "$mark_legacy_dir"
legacy_ts="2026-01-01T00:00:00Z"
printf '{"ok":true,"ts":"%s"}' "$legacy_ts" > "$mark_legacy_dir/.last-fetch.json"
fleet_mark_peers "$mark_legacy_dir" false
assert_eq "a legacy {ok:true,ts} marker with no last_ok_ts field yields last_ok_ts = that marker's own ts on failure" \
  "$legacy_ts" "$(jq -r '.last_ok_ts' "$mark_legacy_dir/.last-fetch.json")"

# ==============================================================================
# fleet_peers_stale — the one staleness predicate (#990), shared by
# fleet_logs_healthy below and the dashboard's fleet-strip badge
# ==============================================================================
stale_dir_false="$tmp_dir/stale-ok-false"
mkdir -p "$stale_dir_false"
printf '{"ok":false,"ts":"%s","last_ok_ts":null}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$stale_dir_false/.last-fetch.json"
assert_eq "ok:false reads stale regardless of ts" "0" \
  "$(fleet_peers_stale "$stale_dir_false" >/dev/null 2>&1; echo $?)"

stale_dir_fresh="$tmp_dir/stale-ok-true-fresh"
mkdir -p "$stale_dir_fresh"
fresh_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ok":true,"ts":"%s","last_ok_ts":"%s"}' "$fresh_ts" "$fresh_ts" > "$stale_dir_fresh/.last-fetch.json"
assert_eq "ok:true with a fresh ts reads not stale" "1" \
  "$(fleet_peers_stale "$stale_dir_fresh" >/dev/null 2>&1; echo $?)"

stale_dir_old="$tmp_dir/stale-ok-true-old"
mkdir -p "$stale_dir_old"
old_ts="$(date -u -d '-30 minutes' +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ok":true,"ts":"%s","last_ok_ts":"%s"}' "$old_ts" "$old_ts" > "$stale_dir_old/.last-fetch.json"
assert_eq "ok:true with a ts older than 3 fetch intervals reads stale — a dead fetch cron that never logged a failure" "0" \
  "$(fleet_peers_stale "$stale_dir_old" >/dev/null 2>&1; echo $?)"

stale_dir_none="$tmp_dir/stale-no-marker"
mkdir -p "$stale_dir_none"
assert_eq "no marker at all reads not stale — the bootstrap case, caught by the union's own emptiness instead" "1" \
  "$(fleet_peers_stale "$stale_dir_none" >/dev/null 2>&1; echo $?)"

stale_dir_cap="$tmp_dir/stale-cap"
mkdir -p "$stale_dir_cap"
# 35 minutes (2100s) sits between the 1800s LABEL_OWN_GRACE_SECONDS cap and
# the 3600s an uncapped 3*20 fetch-minute threshold would otherwise allow —
# stale only because the cap applies.
cap_ts="$(date -u -d '-35 minutes' +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ok":true,"ts":"%s","last_ok_ts":"%s"}' "$cap_ts" "$cap_ts" > "$stale_dir_cap/.last-fetch.json"
assert_eq "the threshold is capped at LABEL_OWN_GRACE_SECONDS even for a longer configured fetch interval (#1053)" "0" \
  "$(fleet_peers_stale "$stale_dir_cap" 20 >/dev/null 2>&1; echo $?)"

sleep 2
assert_eq "FLEET_PEERS_STALE_SECONDS overrides the computed threshold downward" "0" \
  "$(FLEET_PEERS_STALE_SECONDS=1 fleet_peers_stale "$stale_dir_fresh" >/dev/null 2>&1; echo $?)"
assert_eq "  ... and upward" "1" \
  "$(FLEET_PEERS_STALE_SECONDS=3600 fleet_peers_stale "$stale_dir_old" >/dev/null 2>&1; echo $?)"

assert_eq "a populated union behind an ok:true marker whose ts has gone stale reads unhealthy too (#990)" "1" \
  "$(fleet_logs_healthy "$sb_state" "$stale_dir_old" "$union_log_file" >/dev/null 2>&1; echo $?)"
assert_eq "  ... and fleet_logs_healthy's own optional fetch_minutes argument narrows the threshold the same way" "1" \
  "$(fleet_logs_healthy "$sb_state" "$stale_dir_cap" "$union_log_file" 20 >/dev/null 2>&1; echo $?)"

# ==============================================================================
# fleet_repair_log — NUL-run repair for the JSONL logs and dashboard.log alike
# (agent-ops#794): a container killed mid-append leaves NUL bytes where the
# last writes should be, which makes the whole file binary to grep/jq. The
# repair clears them — for a `.jsonl` target, along with whatever record the
# run left too truncated to parse, since the bytes alone gone still leaves a
# join no reader can read — and records what was dropped, in a shape each
# target format can actually still read: a JSON line for `.jsonl`, so no
# `fromjson? // empty` reader silently swallows the record of its own repair,
# and a plain-text line otherwise (the pre-existing dashboard.log behaviour).
# ==============================================================================
repair_text="$tmp_dir/repair-plain.log"
{ printf 'before the hole\n'; printf '\0\0\0\0\0\0\0\0'; printf 'after the hole\n'; } > "$repair_text"
fleet_repair_log "$repair_text" "repair-node"
repaired_text="$(cat "$repair_text")"
assert_eq "plain-text target: the hole is gone" "0" \
  "$(tr -cd '\0' < "$repair_text" | wc -c)"
assert_contains "plain-text target: the lines around it survive (before)" \
  "before the hole" "$repaired_text"
assert_contains "plain-text target: and after" "after the hole" "$repaired_text"
assert_contains "plain-text target: the loss is recorded as a sentence, not JSON" \
  "repaired: dropped 8 NUL byte(s)" "$repaired_text"

repair_jsonl="$tmp_dir/repair-log.jsonl"
{ printf '{"ts":"2026-08-08T16:36:00Z","event":"before"}\n'; printf '\0\0\0\0\0'; \
  printf '{"ts":"2026-08-08T16:37:00Z","event":"after"}\n'; } > "$repair_jsonl"
fleet_repair_log "$repair_jsonl" "repair-node"
assert_eq "jsonl target: the hole is gone" "0" \
  "$(tr -cd '\0' < "$repair_jsonl" | wc -c)"
assert_eq "jsonl target: every line, including the repair record, is valid JSON" \
  "3" "$(jq -s 'length' < "$repair_jsonl" 2>/dev/null)"
repair_record="$(tail -n1 "$repair_jsonl")"
assert_eq "jsonl target: the repair record itself parses as JSON" "1" \
  "$(if jq -e . >/dev/null 2>&1 <<<"$repair_record"; then echo 1; else echo 0; fi)"
assert_eq "jsonl target: the repair record names the event" "log-repaired" \
  "$(jq -r '.event' <<<"$repair_record")"
assert_eq "jsonl target: the repair record counts the dropped bytes" "5" \
  "$(jq -r '.dropped_nul_bytes' <<<"$repair_record")"
assert_eq "jsonl target: the repair record names the node" "repair-node" \
  "$(jq -r '.node' <<<"$repair_record")"
assert_eq "jsonl target: the repair record carries a ts" "true" \
  "$(jq -r '(.ts | length) > 0' <<<"$repair_record")"
assert_contains "jsonl target: the lines around the hole survive" \
  '"event":"before"' "$(cat "$repair_jsonl")"
assert_contains "jsonl target: and after" '"event":"after"' "$(cat "$repair_jsonl")"
assert_eq "jsonl target: a hole that cost no whole record counts none dropped" "0" \
  "$(jq -r '.dropped_lines' <<<"$repair_record")"

# The shape agent-ops#794 was actually opened on: the run falls *inside* a
# record, taking the newline that ended it with it. Removing the NUL bytes
# alone would splice the truncated head onto the whole of the next record, on
# one line — `jq -s` refuses that join exactly as it refused the NULs, which is
# the abort the issue's own acceptance criterion names. The stump is
# unrecoverable, so it goes and is counted; the intact record it ran into is
# not, so it stays.
mid_record="$tmp_dir/repair-mid-record.jsonl"
{ printf '{"ts":"2026-08-08T16:00:00Z","cycle":"20260808T160000Z-node-a","event":"cycle-start"'
  printf '\0%.0s' $(seq 60)
  printf '{"ts":"2026-08-08T16:36:00Z","event":"cycle-end"}\n'
  printf '{"ts":"2026-08-08T17:00:00Z","event":"later"}\n'; } > "$mid_record"
assert_eq "jsonl target, run mid-record: jq -s refuses the file before repair" "refused" \
  "$(if jq -s 'length' < "$mid_record" >/dev/null 2>&1; then echo read; else echo refused; fi)"
fleet_repair_log "$mid_record" "repair-node"
assert_eq "  ... and reads it whole afterwards" "3" \
  "$(jq -s 'length' < "$mid_record" 2>/dev/null)"
assert_eq "  ... the truncated head of the damaged record is gone" "0" \
  "$(grep -c 'cycle-start' "$mid_record")"
assert_eq "  ... the intact record the run ran into is kept, not dropped with it" "1" \
  "$(jq -s '[.[] | select(.event == "cycle-end")] | length' < "$mid_record")"
assert_eq "  ... and the record after it" "1" \
  "$(jq -s '[.[] | select(.event == "later")] | length' < "$mid_record")"
assert_eq "  ... the repair record counts the line that went" "1" \
  "$(jq -r '.dropped_lines' <<<"$(tail -n1 "$mid_record")")"
assert_eq "  ... alongside the bytes" "60" \
  "$(jq -r '.dropped_nul_bytes' <<<"$(tail -n1 "$mid_record")")"

# The commonest shape of all: the writes still in flight were the file's own
# tail, so what survives ends mid-record with no closing newline. The repair
# record has to start a line of its own — appended to the stump instead, the
# one line whose job is to say something was lost would itself be the line no
# reader can parse.
tail_lost="$tmp_dir/repair-tail-lost.jsonl"
{ printf '{"ts":"2026-08-08T16:36:00Z","event":"intact"}\n'
  printf '{"ts":"2026-08-08T16:37:00Z","event":"tru'
  printf '\0%.0s' $(seq 40); } > "$tail_lost"
fleet_repair_log "$tail_lost" "repair-node"
assert_eq "jsonl target, tail lost: jq -s reads the repaired file whole" "2" \
  "$(jq -s 'length' < "$tail_lost" 2>/dev/null)"
assert_eq "  ... the repair record is a line of its own, not appended to the stump" \
  "log-repaired" "$(jq -r '.event' <<<"$(tail -n1 "$tail_lost")")"
assert_eq "  ... and the intact record before it survives" "1" \
  "$(jq -s '[.[] | select(.event == "intact")] | length' < "$tail_lost")"

# An intact target of either format is left exactly as it is: no rewrite, no
# repair record — repairing what was never holed would be its own false
# report.
intact_text="$tmp_dir/intact.log"
printf 'nothing wrong here\n' > "$intact_text"
fleet_repair_log "$intact_text" "repair-node"
assert_eq "an intact plain-text target gets no repair marker" "0" \
  "$(grep -c 'repaired: dropped' "$intact_text")"
intact_jsonl="$tmp_dir/intact.jsonl"
printf '{"ts":"2026-08-08T16:36:00Z","event":"fine"}\n' > "$intact_jsonl"
fleet_repair_log "$intact_jsonl" "repair-node"
assert_eq "an intact jsonl target gets no repair record" "1" \
  "$(jq -s 'length' < "$intact_jsonl")"
assert_eq "and no log-repaired event appears" "0" \
  "$(jq -s '[.[] | select(.event == "log-repaired")] | length' < "$intact_jsonl")"

# ==============================================================================
# node identity in pipeline events (requirement 33, offline path)
# ==============================================================================
# The management switch logs through the same log_event as every pipeline
# event, with no model call and no GitHub write — the cheapest offline proof
# that events carry the node's name.
# TOGGLE_GH is pinned to /bin/false so the fleet-flag writes that --disable
# and --enable now attempt (requirement 2.3a) go to a stub that fails like an
# unreachable state repo — never to the real one — and the local switch keeps
# working regardless, which is exactly the degraded mode being asserted here.
# DASHBOARD_GH_CMD is pinned the same way: both actions end in
# lib/manage.sh's refresh_dashboard, which shells out to the real
# publish-dashboard.sh — unstubbed, that script reads this repository's own
# (real) config.json and makes real `gh` calls against every configured repo,
# which is no part of what this section asserts and, unlike the fleet-flag
# stub above, was costing minutes rather than milliseconds. Stubbed, its `gh`
# calls fail immediately like the offline path they are standing in for, and
# refresh_dashboard already swallows the failure (`|| true`) exactly as it
# does for a real node with no network.
cycle_home="$(new_node cycle-node)"
env HOME="$cycle_home" AGENT_OPS_ROLE=standby NODE_NAME=cycle-node \
  STATE_SYNC_REMOTE="$remote" TOGGLE_GH=/bin/false DASHBOARD_GH_CMD=/bin/false \
  "$SCRIPT_DIR/agent-cycle.sh" --disable "state-sync test" >/dev/null 2>&1
assert_contains "switch events carry the node's name" '"node":"cycle-node"' \
  "$(cat "$cycle_home/.local/state/poetic-agents/log.jsonl" 2>/dev/null)"
env HOME="$cycle_home" AGENT_OPS_ROLE=standby NODE_NAME=cycle-node \
  STATE_SYNC_REMOTE="$remote" TOGGLE_GH=/bin/false DASHBOARD_GH_CMD=/bin/false \
  "$SCRIPT_DIR/agent-cycle.sh" --enable >/dev/null 2>&1
assert_contains "the enable is logged too" '"event":"enabled"' \
  "$(cat "$cycle_home/.local/state/poetic-agents/log.jsonl" 2>/dev/null)"

# ==============================================================================
# push — a large cycles/ directory does not kill the push (#806)
# ==============================================================================
# `do_push` took the newest cycle id with `find … | sort -r | head -n 1`.
# `head` closes the pipe the moment it has its one line; `sort`, which cannot
# emit anything until it has read every name, is still writing, takes SIGPIPE
# and exits 141. In a command substitution in the current shell, under
# `set -euo pipefail`, that becomes the push's own status and `-e` aborts it —
# after the mirror lock and the fetch, before the commit, and without one line
# in state-sync.log to say so.
#
# It is a race against the pipe buffer: when sort's whole output fits before
# head exits, nothing is signalled. On the live nodes (1000 cycles, ~32-40 KB
# of names) it fired in 16-17 of every 30 runs — which is exactly why it went
# a month unattributed. So this test does not reproduce the race, it removes
# it: enough names to put sort's output well past any pipe buffer, so the old
# code fails every time and the assertion means something.
big_home="$(new_node big-cycles-node)"
big_state="$big_home/.local/state/poetic-agents"
printf '{"ts":"2026-07-20T00:00:00Z","event":"cycle-start"}\n' > "$big_state/log.jsonl"
# ~600 names of ~250 bytes is ~150 KB, more than twice a default 64 KB pipe
# buffer. The directories are deliberately left empty: git stores no empty
# directory, so none of this reaches the commit and the test stays quick — what
# matters is the length of the name list `sort` must write, not any payload.
big_pad="$(printf 'x%.0s' $(seq 1 230))"
for i in $(seq -w 1 600); do
  mkdir -p "$big_state/cycles/20260720T0100${i}Z-$big_pad"
done
big_out="$(sync_as "$big_home" active push STATE_SYNC_LOCAL_RETAINED=600)"
big_rc=$?
assert_eq "a push over a large cycles/ survives the newest-cycle scan" "0" "$big_rc"
assert_contains "and reports what it pushed, rather than dying silently" \
  "state-sync(push): pushed" "$big_out"

# ==============================================================================
# a wedged step is killed and the lock it holds is released (agent-ops#1679)
# ==============================================================================
# The fault this reproduces: on 2026-09-18 a push on ockham-2 wedged inside
# the redaction loop for almost seven hours, holding `mirror_lock` the whole
# time. "another state-sync holds the mirror" is documented as self-clearing
# (an ordinary slow fetch), so nothing distinguished the wedge from a slow
# push, and the node read as dead for the whole seven hours.

# --- mirror_run_with_deadline / mirror_kill_tree, in isolation -----------------
# A step that would run to completion well inside the deadline is untouched:
# its own exit status passes through, and it is not made to wait for the
# deadline to elapse.
dl_start="$(date +%s)"
mirror_run_with_deadline 5 bash -c 'exit 3'
dl_rc=$?
dl_elapsed=$(( $(date +%s) - dl_start ))
assert_eq "a step that finishes well inside the deadline keeps its own exit code" "3" "$dl_rc"
assert_eq "…and returns immediately, not after waiting out the deadline" "1" \
  "$(( dl_elapsed < 3 ? 1 : 0 ))"

# The simulated wedge: a step that would otherwise run far longer than the
# deadline is killed, and the deadline itself — not the step's own runtime —
# is what bounds how long the caller waits.
dl_start="$(date +%s)"
mirror_run_with_deadline 1 sleep 30
dl_rc=$?
dl_elapsed=$(( $(date +%s) - dl_start ))
assert_eq "a step wedged past its deadline is reported as 124, the same code timeout(1) uses" \
  "124" "$dl_rc"
assert_eq "…and the caller is freed at the deadline, not after the full 30s" "1" \
  "$(( dl_elapsed < 10 ? 1 : 0 ))"
sleep 0.3
assert_eq "…and the wedged process itself is actually gone, not merely abandoned" \
  "0" "$(pgrep -f 'sleep 30' | wc -l)"

# A step that forks its own children (the redaction loop's own shape: a shell
# with `find` as a live child) has all of them killed, not just the shell —
# the same /proc walk scripts/state-sync.sh's own `mirror_git_busy` already
# reads, generalised here to any process tree.
dl_start="$(date +%s)"
mirror_run_with_deadline 1 bash -c 'sleep 30 & wait'
dl_rc=$?
dl_elapsed=$(( $(date +%s) - dl_start ))
assert_eq "a wedged shell with its own child is also reported as 124" "124" "$dl_rc"
assert_eq "…freed at the deadline" "1" "$(( dl_elapsed < 10 ? 1 : 0 ))"
sleep 0.3
assert_eq "…and the grandchild sleep is gone too, not left as an orphan" \
  "0" "$(pgrep -f 'sleep 30' | wc -l)"

# --- the lock holder marker, in isolation ---------------------------------------
ml_dir="$tmp_dir/mirror-lock-unit"
mkdir -p "$ml_dir"
ml_mirror="$ml_dir/.agent-ops-state"
assert_eq "no marker yet reads as no age to report" "" "$(mirror_lock_holder_age_s "$ml_mirror")"
mirror_lock_mark_started "$ml_mirror" push
assert_eq "a marker just written reads back as this process' own pid" \
  "$$" "$(jq -r '.pid' "$(mirror_lock_holder_marker "$ml_mirror")")"
assert_eq "…and an age of (about) zero" "0" "$(mirror_lock_holder_age_s "$ml_mirror")"
mirror_lock_clear_started "$ml_mirror"
assert_eq "clearing it removes the marker" "0" \
  "$(test -e "$(mirror_lock_holder_marker "$ml_mirror")" && echo 1 || echo 0)"
assert_eq "…so age reads back to nothing again" "" "$(mirror_lock_holder_age_s "$ml_mirror")"

# mirror_lock_probe, the read-only side lib/manage.sh's --status calls: no
# lock file at all reads as free, same as a genuinely uncontended one.
assert_eq "a mirror with no lock file yet probes as not held" \
  '{"held":false}' "$(mirror_lock_probe "$ml_mirror")"

# --- the losing side of a real contention names the holder's own age -----------
# `il_sleeper`'s own trick (above) fakes a live process; here the lock itself
# has to be genuinely held, so a real `flock` does it — backgrounded directly
# at the top level, never through a `$(...)` command substitution, which bash
# would tear the job down along with once that subshell exits.
wl_home="$(new_node wedge-loser-node)"
wl_state="$wl_home/.local/state/poetic-agents"
wl_mirror="$wl_home/.cache/poetic-agents/workspaces/.agent-ops-state"
printf '{"ts":"2026-09-18T14:00:00Z","event":"cycle-start"}\n' > "$wl_state/log.jsonl"
out="$(sync_as "$wl_home" active push)"
assert_eq "the wedge-loser node's first push exits 0" "0" "$?"

wl_push_s="$(config_defaults "$SCRIPT_DIR/config.json" "$SCRIPT_DIR/config.schema.json" \
  | jq -r '.schedule.state_sync_push_minutes * 60 | floor')"
jq -nc --arg started "$(date -u -d "@$(( $(date +%s) - wl_push_s * 3 ))" +%Y-%m-%dT%H:%M:%SZ)" \
  '{started: $started, mode: "push", pid: 1}' > "$wl_mirror.lock.holder"
flock "$wl_mirror.lock" sleep 5 &
wl_holder_parent=$!
sleep 0.2
wl_holder_child="$(pgrep -P "$wl_holder_parent" | head -1)"

out="$(sync_as "$wl_home" active fetch)"
assert_eq "a fetch against a genuinely held lock still exits 0 — this stays self-clearing" "0" "$?"
assert_contains "…but now names the holder's own age" \
  "another state-sync holds the mirror — holding for" "$out"
assert_contains "…past one push interval, said explicitly" \
  "longer than one push interval — may be wedged" "$out"

kill "$wl_holder_parent" "$wl_holder_child" 2>/dev/null; wait "$wl_holder_parent" 2>/dev/null

# A young hold, by contrast, is reported as an age but never called a wedge —
# an ordinary push in progress is not the fault this line exists to name.
jq -nc --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{started: $started, mode: "push", pid: 1}' > "$wl_mirror.lock.holder"
flock "$wl_mirror.lock" sleep 5 &
wl_holder_parent=$!
sleep 0.2
wl_holder_child="$(pgrep -P "$wl_holder_parent" | head -1)"
out="$(sync_as "$wl_home" active fetch)"
assert_contains "a young hold still reports its age" \
  "another state-sync holds the mirror — holding for" "$out"
assert_lacks "…but is never called a wedge" "may be wedged" "$out"
kill "$wl_holder_parent" "$wl_holder_child" 2>/dev/null; wait "$wl_holder_parent" 2>/dev/null

# --- a single file's redaction failing does not wedge the whole push -----------
# The root cause #1679 traced the incident to: a file `redact_file` cannot
# rewrite used to abort the whole loop under `set -e`, abandoning `find`'s
# process substitution before EOF and deadlocking the run against its own
# unread pipe. A failed redaction is now a warning and a skip.
rc_home="$(new_node redact-failure-node)"
rc_state="$rc_home/.local/state/poetic-agents"
printf '{"ts":"2026-07-20T00:00:00Z","event":"cycle-start"}\n' > "$rc_state/log.jsonl"
printf 'a token ghp_1234567890abcdefXYZ1234 that must still be redacted\n' \
  > "$rc_state/cron.log"
# `sed -i` rewrites a file by creating a new temp file beside it and renaming
# over the original, so it is the *directory's* write permission that has to
# be denied, not the file's own — the file still has to be plainly readable
# for rsync to mirror it there in the first place.
mkdir -p "$rc_state/protected"
printf 'this one cannot be rewritten\n' > "$rc_state/protected/unwritable.log"
chmod 555 "$rc_state/protected"
rc_out="$(sync_as "$rc_home" active push)"
rc_rc=$?
chmod 755 "$rc_state/protected"
assert_eq "a push with one unredactable file still succeeds overall" "0" "$rc_rc"
assert_contains "…warning about the one file it could not redact" \
  "WARNING: could not redact" "$rc_out"
assert_contains "…committing it unredacted" "committing it unredacted" "$rc_out"
rc_pushed="$tmp_dir/rc-pushed"
git clone --quiet --branch nodes/redact-failure-node "$remote" "$rc_pushed"
assert_eq "…and every other file still got redacted normally" "1" \
  "$(grep -c 'REDACTED-TOKEN' "$rc_pushed/cron.log")"
# rsync's -a carried the source directory's own 555 into the mirror too; put
# back so the whole-tmp_dir cleanup trap at the bottom of this file can
# actually remove it.
chmod -R u+w "$rc_home"

# --- the deadline itself: a step that runs long is killed and the lock freed ---
# Not a reproduction of the exact race above (which needed a real file
# `redact_file` cannot rewrite, above) — a generically slow redaction pass,
# thousands of trivial files, each costing its own `sed -i` process spawn, is
# a real, deterministic way to make the same loop legitimately take longer
# than a short deadline, which is exactly the safety net regardless of cause
# this deadline exists to be.
dd_home="$(new_node deadline-node)"
dd_state="$dd_home/.local/state/poetic-agents"
dd_mirror="$dd_home/.cache/poetic-agents/workspaces/.agent-ops-state"
printf '{"ts":"2026-07-20T00:00:00Z","event":"cycle-start"}\n' > "$dd_state/log.jsonl"
mkdir -p "$dd_state/wedge"
touch "$dd_state"/wedge/file_{00001..08000}
dd_start="$(date +%s)"
dd_out="$(sync_as "$dd_home" active push STATE_SYNC_PUSH_DEADLINE_SECONDS=2)"
dd_rc=$?
dd_elapsed=$(( $(date +%s) - dd_start ))
assert_eq "a push whose redaction pass runs long exits non-zero" "1" "$dd_rc"
assert_eq "…well inside the deadline it was killed at, not after the full pass" "1" \
  "$(( dd_elapsed < 15 ? 1 : 0 ))"
assert_contains "…naming the deadline as the step that failed" \
  "push failed at redaction-loop-deadline" "$dd_out"
assert_eq "…logged as a state-sync-push-failed event naming the same step" "1" \
  "$(jq -c 'select(.event == "state-sync-push-failed" and .step == "redaction-loop-deadline")' \
       "$dd_state/log.jsonl" | wc -l)"
assert_eq "…and the mirror lock's own holder marker is gone, not left behind" "0" \
  "$(test -e "$dd_mirror.lock.holder" && echo 1 || echo 0)"
# The killed push's own rsync had already staged the 8000 files into the
# mirror before the redaction pass wedged; removing the source directory lets
# the next push's `rsync --delete` clear them out again rather than redacting
# the same slow pile a second time — what this asserts is that the lock is
# free, not that a second giant redaction also finishes in 2s.
rm -rf "$dd_state/wedge"
dd_out2="$(sync_as "$dd_home" active push STATE_SYNC_PUSH_DEADLINE_SECONDS=2)"
assert_eq "…so the very next push is not still shut out by the dead one's lock" "0" "$?"
assert_contains "…and actually completes" "state-sync(push): pushed" "$dd_out2"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
