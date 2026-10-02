#!/usr/bin/env bash
#
# lib/chain.sh — finish-then-continue (requirement 39): whether a cycle that
# just won a claim should chain another selection cycle immediately, instead
# of waiting for the next cron firing.
#
# Sourced by agent-cycle.sh only; split out so the "is it worth chaining"
# question is a pure function of what the cycle already gathered, the same
# way lib/noop-skip.sh keeps "is it worth asking the Co-Ordinator again" pure
# and separately testable. Neither function predicts what a chained cycle
# will actually find — its own Co-Ordinator, its own fresh gather and its own
# no-op fingerprint answer that — this only decides whether asking again is
# cheap enough to be worth it.
#
# A second, related question lives here too (agent-ops#1096): whether this
# cycle should yield a chain it would otherwise take because the image has
# moved on. A node running long or chained cycles never presents watchtower's
# deploy/docker/watchtower-pre-update.sh a gap to poll into, so a healthy,
# merely-busy node could stay behind indefinitely even though nothing about
# it is wedged. `chain_image_behind` reads the same `image_drift_status`
# verdict the heartbeat already publishes (no second signal), and
# `chain_write_roll_pending` records the decision not to chain so the hook can
# honour it — see agent-cycle.sh's cleanup(), which is the only caller of
# either.
#
# A third question, added once the first two shipped (agent-ops#1102): a
# marker `chain_write_roll_pending` wrote is honoured on a fixed clock, not
# "until the next cycle would have started" the way #1096's own spec
# describes, so a cycle that reacquires the lock before the marker's `until`
# passes runs its own stages underneath it. `chain_clear_landed_roll_pending`
# is how the next cycle sheds a marker that has already done its job — see
# agent-cycle.sh's `acquire_lock` call site, its only caller.
#
# A fourth question, for the one case the third leaves deliberately open
# (agent-ops#1102's own option 2): `chain_clear_landed_roll_pending` declines
# to clear a marker whose verdict still reads "behind", so that cycle runs
# its own stages underneath a marker that still authorises overriding
# `lock.json`. `chain_roll_pending_live` and `chain_updater_should_standdown`
# are the two guards agent-cycle.sh combines to decide whether that cycle
# should idle instead of running — only when the marker has not yet expired
# and watchtower is actually polling and being turned away (otherwise idling
# fixes nothing, since nothing is waiting to take the gap). `chain_roll_
# standdown_available`/`chain_roll_standdown_record` are the one-stand-down-
# per-pending-roll cap that bounds it even against a wrong verdict from those
# two guards, cleared by `chain_clear_landed_roll_pending` alongside the
# marker itself once the roll has actually landed.

# chain_sources_remain ORDERED_REPOS_JSON
# Print the total count of configured, non-excluded sources across every
# repo in the cycle's already-gathered `ordered_repos_json` (requirement
# 2.2a's back-pressure narrowing already applied). Zero means nothing is
# left for even a fresh Co-Ordinator to look at — back-pressure emptied
# every repo's `.sources`, the one shape that can happen this late, since a
# cycle reaching a won claim already passed every earlier stand-down.
#
# Deliberately not a prediction of *how much* work remains: `.sources` is a
# list of enabled categories, not a list of items, and staying that coarse is
# what keeps this cheap — the sources were already gathered this cycle, nothing
# further is fetched to answer this question.
chain_sources_remain() {
  local repos_json="$1" n
  n="$(jq '[.[].sources | length] | add // 0' <<<"$repos_json" 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%d' "$n"
}

# chain_should_continue CHAIN_COUNT MAX_CHAINED_CYCLES ORDERED_REPOS_JSON
# Exit 0 (chain another cycle) iff this cycle's own place in its lineage
# (CHAIN_COUNT, 1 for the cron-fired original) is still under
# MAX_CHAINED_CYCLES *and* chain_sources_remain is non-zero. Exit 1
# otherwise — including on a non-numeric CHAIN_COUNT/MAX_CHAINED_CYCLES,
# which fails closed rather than chaining on a value that could not be
# trusted.
chain_should_continue() {
  local chain_count="$1" max="$2" repos_json="$3"
  [[ "$chain_count" =~ ^[0-9]+$ ]] || return 1
  [[ "$max" =~ ^[0-9]+$ ]] || return 1
  (( chain_count < max )) || return 1
  (( $(chain_sources_remain "$repos_json") > 0 ))
}

# chain_image_behind IMAGE_STATUS_JSON
# Exit 0 iff lib/image-drift.sh's own `image_drift_status` verdict — the same
# one the heartbeat publishes as `image` (requirement 2.5) — is "behind"
# (agent-ops#1096). "current", "unverified" and the JSON literal `null` (a
# developer checkout, which is not running a CI-stamped image at all) all
# read false: none of them is a case a cycle boundary can do anything about,
# and this must fail closed on a verdict it cannot read rather than yield a
# chain the fleet actually needed.
chain_image_behind() {
  local status_json="${1:-null}" status=""
  status="$(jq -r '.status // empty' <<<"$status_json" 2>/dev/null || true)"
  [[ "$status" == "behind" ]]
}

# chain_write_roll_pending STATE_DIR MINUTES
# Write STATE_DIR/roll-pending.json — {"until": <ISO8601, MINUTES from now>}
# — recording that this cycle yielded a pending image roll instead of
# chaining (requirement 39, agent-ops#1096).
# deploy/docker/watchtower-pre-update.sh reads this back and honours it as an
# unconditional allow until `until`, which is what actually gets the roll to
# the node: with nothing chaining, the next cron firing is still MINUTES
# away (the caller passes `schedule.cycle_interval_minutes`), and watchtower's
# own five-minute poll would otherwise have to land inside that gap by luck
# alone — the very failure #1096 was filed over.
#
# A non-numeric MINUTES falls back to the schema's own default (15) rather
# than failing outright: a misread config value must not turn "yield to the
# roll" into "yield and then never actually say so". Best-effort like every
# other write under state_dir this pipeline makes from its own cleanup path
# (record_verdict in the hook itself is the model): a failure to write here
# must not turn a real "do not chain" decision into a fatal error.
chain_write_roll_pending() {
  local state_dir="$1" minutes="${2:-15}" until_ts=""
  [[ "$minutes" =~ ^[0-9]+$ ]] || minutes=15
  until_ts="$(date -u -d "+${minutes} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || return 0
  [[ -n "$until_ts" ]] || return 0
  mkdir -p "$state_dir" 2>/dev/null || return 0
  local tmp="$state_dir/roll-pending.json.tmp.$$"
  jq -nc --arg u "$until_ts" '{until: $u}' > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  mv "$tmp" "$state_dir/roll-pending.json" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

# chain_clear_landed_roll_pending STATE_DIR IMAGE_STATUS_JSON
# Remove STATE_DIR/roll-pending.json unless IMAGE_STATUS_JSON still reads
# "behind" (agent-ops#1102). `chain_write_roll_pending` names a fixed-width
# window because it cannot know exactly when the next cycle will start; this
# is the other half, called back at the top of the cycle that actually does
# start, once it holds the lock the marker was written to be overridden
# against. Re-acquiring that lock is itself the proof the "no cycle running"
# gap the marker describes has ended — so once the image is no longer
# "behind", the marker has either already done its job (the roll landed in
# the gap) or was never earned by this node's own current image, and leaving
# it live either way would let it authorise watchtower to destroy *this*
# cycle's own container for whatever publishes next, on the strength of a
# decision made about a roll that is no longer the one in question. A
# "behind" verdict — the roll genuinely has not landed yet — leaves the
# marker untouched: narrowing the window in that case is #1102's own
# documented larger design change, not this fix. Always succeeds, the same
# as `chain_write_roll_pending`: no marker to clear, and a failed removal,
# both leave nothing for the caller to react to.
chain_clear_landed_roll_pending() {
  local state_dir="$1" status_json="${2:-null}"
  chain_image_behind "$status_json" && return 0
  rm -f "$state_dir/roll-pending.json" "$state_dir/roll-standdown.json" 2>/dev/null || true
}

# chain_roll_pending_live STATE_DIR
# Exit 0 iff STATE_DIR/roll-pending.json exists and names an `until` that has
# not yet passed (agent-ops#1102 option 2) — the identical parse deploy/docker/
# watchtower-pre-update.sh's own `roll_pending_allow` uses (an unparseable
# `until`, or none at all, reads as epoch 0, i.e. not live), so the two never
# disagree about whether the marker is still in force. A marker that has
# merely expired is left for `chain_clear_landed_roll_pending`'s own clock-
# driven caller to deal with rather than deleted here — this function only
# answers the question, it never writes.
chain_roll_pending_live() {
  # Separate statements on purpose: `local a=… b="$a"` expands every argument
  # before assigning any, so `f` would read an unset `state_dir` under `set -u`.
  local state_dir="$1"
  local f="$state_dir/roll-pending.json" until_ts="" until_epoch=0 now_epoch=0
  [[ -f "$f" ]] || return 1
  until_ts="$(jq -r '.until // empty' "$f" 2>/dev/null || true)"
  [[ -n "$until_ts" ]] || return 1
  until_epoch="$(date -d "$until_ts" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  (( until_epoch > now_epoch ))
}

# chain_updater_should_standdown UPDATER_STATUS_JSON
# Exit 0 iff lib/updater-health.sh's own `updater_status` verdict means
# watchtower is actually invoking the pre-update hook and being turned away
# right now (agent-ops#1102 option 2's Guard A) — the only condition idling a
# cycle can do anything about. "deferring" (our own invocation streak is
# currently being refused) and "stuck" with `reason:"defer"` (the same streak,
# grown stuck) both qualify; every other verdict — `null` (no live ledger
# evidence: watchtower is not running, or not polling this container yet),
# "rolled", and "stuck" with `reason:"allow"` (the roll itself is failing for
# reasons of its own, #1099's `Conflict` observation) — does not, since idling
# fixes none of them.
chain_updater_should_standdown() {
  local status_json="${1:-null}" status="" reason=""
  status="$(jq -r '.status // "null"' <<<"$status_json" 2>/dev/null || echo null)"
  case "$status" in
    deferring) return 0 ;;
    stuck)
      reason="$(jq -r '.reason // empty' <<<"$status_json" 2>/dev/null || true)"
      [[ "$reason" == "defer" ]]
      ;;
    *) return 1 ;;
  esac
}

# chain_roll_standdown_available STATE_DIR
# Exit 0 iff STATE_DIR/roll-standdown.json is absent, or its `count` reads
# exactly 0 — the one-stand-down-per-pending-roll cap (agent-ops#1102 option
# 2): even a wrong verdict from chain_updater_should_standdown must not idle a
# node indefinitely. An unreadable file or a non-numeric `count` fails closed
# toward running the cycle (exit 1, "already stood down"), never toward
# idling it a second time on a value that could not be trusted.
chain_roll_standdown_available() {
  # Separate statements on purpose (see chain_roll_pending_live's own note).
  local state_dir="$1"
  local f="$state_dir/roll-standdown.json" count=""
  [[ -f "$f" ]] || return 0
  count="$(jq -r '.count // 0' "$f" 2>/dev/null)" || return 1
  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  (( count == 0 ))
}

# chain_roll_standdown_record STATE_DIR
# Increment STATE_DIR/roll-standdown.json's `count` — creating it at 1 with
# `since` the current time if absent, preserving the original `since` on a
# second write — recording that this cycle idled rather than running its
# stages under a live roll-pending marker (agent-ops#1102 option 2). Best-
# effort like `chain_write_roll_pending`: a failure to write here must not
# turn a real stand-down into a fatal error, and this cap existing to fail
# safe is pointless if writing it can itself abort the cycle.
chain_roll_standdown_record() {
  # Separate statements on purpose (see chain_roll_pending_live's own note).
  local state_dir="$1"
  local f="$state_dir/roll-standdown.json" count=0 since=""
  if [[ -f "$f" ]]; then
    count="$(jq -r '.count // 0' "$f" 2>/dev/null)" || count=0
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    since="$(jq -r '.since // empty' "$f" 2>/dev/null || true)"
  fi
  [[ -n "$since" ]] || since="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || return 0
  mkdir -p "$state_dir" 2>/dev/null || return 0
  local tmp="$f.tmp.$$"
  jq -nc --argjson c "$(( count + 1 ))" --arg s "$since" '{count: $c, since: $s}' > "$tmp" 2>/dev/null \
    || { rm -f "$tmp" 2>/dev/null; return 0; }
  mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}
