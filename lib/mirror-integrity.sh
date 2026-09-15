#!/usr/bin/env bash
#
# lib/mirror-integrity.sh — whether scripts/state-sync.sh's own mirror
# checkout is trustworthy before either push or fetch reads or writes it.
#
# The mirror (STATE_SYNC_MIRROR, default `workspace_root/.agent-ops-state`)
# is a git checkout that survives across cron ticks and container restarts,
# so a host whose disk quietly damages a loose object — an unclean shutdown
# mid-write, as happened on ockham-container from 2026-08-08 and ockham-2 on
# 2026-08-24 — hands the next tick a `.git` directory that opens fine but
# cannot answer for what it holds. `mirror_init` (scripts/state-sync.sh) used
# to trust that a directory existing was the whole check, so a corrupt
# mirror kept being read from and pushed to for four days straight, with
# `git gc` itself failing at repair the entire time and nothing in the
# automation logs saying so — the only visible symptom was an unbounded
# branch.
#
# The mirror is wholly derived, which is what makes discarding it — rather
# than repairing it — both cheap and correct: this node's own branch is
# rsync'd back out of state_dir on the very next push, and every peer branch
# is re-fetched at --depth 1 by the very next fetch. Nothing in the mirror is
# the only copy of anything, and repair (`git gc`) is exactly what was
# already failing throughout the incident above, so the answer is never
# "try to fix it" — it is "throw it away and rebuild from source".
#
# `git fsck --connectivity-only` is the check: it walks every object
# reachable from a ref and confirms it exists and parses, without reading
# every object's full content the way a plain `git fsck` does. That bound is
# the right one here — the incident's own damage sat on a *peer's*
# remote-tracking ref, which is reachable — and it is cheap. Measured against
# a synthetic mirror of 220k reachable objects: 0.2s with those objects
# packed, 1.8s with every one of them loose. The loose figure is the one that
# governs, because a mirror whose `git gc` is failing is precisely a mirror
# whose objects stop being packed, so unpacked is the shape damage actually
# arrives in. Either figure is three orders of magnitude inside the 5-minute
# push / 7-minute fetch interval this runs on (requirement 2.5), so no
# stamp-file gate is needed to keep it off the common path.
#
# A non-empty `.git/gc.log` fails the check too, ahead of the fsck (#604's
# own second clause, unimplemented until 2026-09-15). The file is git's
# record that its last `gc --auto` failed, and its instruction to itself not
# to try again: every later auto-gc is declined and the old error is merely
# reprinted, so the condition it records is permanent until someone removes
# the file — which on 2026-09-14/15 was the state of both workstation
# mirrors, each carrying a `pack-objects died of signal 9` from a gc the
# kernel had OOM-killed, with 24,000–27,000 loose objects and 1.4–1.7 GiB
# behind it and `fsck` clean throughout, because every object was valid and
# the store was merely never packed. A mirror that cannot garbage-collect is
# not a trustworthy mirror, whatever fsck says, and the answer is the same
# rebuild.
#
# The store is also *configured* so that its gc cannot be the thing that
# fails (mirror_configure_store below, applied by mirror_init on every push
# and fetch). The mirror's shape is one rolling commit per node, amended and
# force-pushed every few minutes; with a default reflog every amended-away
# snapshot stays reachable for thirty days, so the loose pile grows by a
# month of superseded snapshots before any of it is prunable, and when
# `gc --auto` finally fires (6,700 loose objects) it packs all of that with
# one `pack-objects` thread per CPU inside a scheduler whose `memory.max` is
# 1536m and which is usually running a stage. That is the gc the kernel
# killed. So:
#
#   core.logAllRefUpdates false   no reflog — an amended-away snapshot is
#                                 garbage at once. The existing `.git/logs`
#                                 is removed too: with the setting false git
#                                 still appends to a reflog file that already
#                                 exists, which is why `git reflog expire`
#                                 alone did not stop the pile regrowing on
#                                 2026-09-15.
#   gc.pruneExpire now            unreachable objects are pruned by the gc
#                                 that finds them, not two weeks later. Safe
#                                 here and only here: every git process that
#                                 touches the mirror runs under `$mirror.lock`
#                                 (mirror_lock, scripts/state-sync.sh), so
#                                 there is no concurrent writer whose
#                                 not-yet-referenced objects a prune could
#                                 take.
#   gc.autoDetach false           the auto-gc runs in the foreground of the
#                                 `git commit` or `git fetch` that triggered
#                                 it, so it completes inside that lock — a
#                                 detached gc pruning at `now` would outlive
#                                 the lock and race the very next state-sync
#                                 fetch for the objects it had written but
#                                 not yet referenced. A foreground auto-gc
#                                 also never writes `gc.log` (only a detached
#                                 one does), so a failure is retried at the
#                                 next trigger instead of declining every gc
#                                 for ever; the check above still guards a
#                                 mirror that predates this and any gc run by
#                                 hand.
#   gc.auto 1000                  the loose-object trigger, down from 6,700,
#                                 so the pile between gcs stays around a
#                                 thousand objects (about 40 MB of them at
#                                 the fleet's push rate) rather than a few
#                                 hundred megabytes; the same total work,
#                                 spread thinner.
#   gc.autoPackLimit 1            the gc the loose trigger runs is an
#                                 *incremental* repack, and at that moment the
#                                 mirror's remote-tracking ref for its own
#                                 branch (updated by the depth-1 fetch that
#                                 starts every push) still names the snapshot
#                                 the amend has just superseded — so that one
#                                 snapshot is packed, and becomes garbage only
#                                 when the push moves the ref. Packed garbage
#                                 survives every incremental repack; git
#                                 consolidates with `repack -a -d` (which,
#                                 under `pruneExpire now`, drops it) only
#                                 when the pack count exceeds this limit,
#                                 whose default is 50. At 1, the push after
#                                 every incremental gc consolidates, and the
#                                 store settles at one pack holding the
#                                 current snapshot and at most the one before
#                                 it.
#   pack.threads 1                a single-threaded, window-bounded repack:
#   pack.windowMemory 64m         the memory a repack of the reachable set
#                                 alone needs is small (measured at 140–280
#                                 MiB peak across the four Poetic nodes on
#                                 2026-09-15, 11–14 s each, against a pack of
#                                 about 12.5 MiB), and the ceiling is what
#                                 killed the last one.
#
# A rebuild has to be recorded somewhere that outlives the rebuild itself —
# the mirror it happened to is exactly what gets discarded — so the record
# lives under state_dir as a small local cache file
# (mirror_rebuild_state_file below), the same class of node-local
# memoisation as .image-drift-cache.json: not fleet data, so it does not
# replicate (scripts/state-sync.sh's own EXCLUDES), but read back into the
# heartbeat's `mirror` field on every push — the same channel that already
# carries the compose/image/switch verdicts (lib/compose-drift.sh,
# lib/image-drift.sh, lib/toggle.sh) — so a rebuild is as visible to a human
# or a peer as any other node fact, and a *second* rebuild is visibly a
# repeat rather than one more indistinguishable line.
#
# Sourced by scripts/state-sync.sh only: the mirror belongs to state-sync,
# unlike compose/image/switch, which other scripts (publish-dashboard.sh,
# doctor.sh) also read for this node's own status.

# mirror_rebuild_state_file STATE_DIR
# The path of the durable local record, one function so state-sync.sh's
# EXCLUDES list and the read/write sites below cannot name it differently.
mirror_rebuild_state_file() {
  printf '%s/.mirror-rebuild-state.json\n' "$1"
}

# mirror_integrity_ok MIRROR
# True (exit 0) iff MIRROR carries no non-empty `.git/gc.log` and every
# object `git fsck --connectivity-only` can reach exists and parses. False on
# a `gc.log` — git's own record of a gc that failed and will not be retried
# — or on any nonzero fsck exit: an empty loose object exits 2, other
# corruption 3, and no third outcome is worth telling apart from a caller
# that is about to discard and rebuild either way. The `gc.log` test runs
# first because it is free, and because it is the one that fires when fsck
# would not (see the header: an unpacked store is a valid store).
mirror_integrity_ok() {
  local mirror="$1"
  [[ -s "$mirror/.git/gc.log" ]] && return 1
  git -C "$mirror" fsck --connectivity-only --no-progress >/dev/null 2>&1
}

# mirror_store_config
# The mirror's own git configuration, one `key value` pair per line — held in
# one place so mirror_configure_store below and the test that asserts it
# cannot name the set differently. The reasoning for each key is in the
# header above; the values are the ones measured on 2026-09-15.
mirror_store_config() {
  cat <<'EOF'
core.logAllRefUpdates false
gc.pruneExpire now
gc.autoDetach false
gc.auto 1000
gc.autoPackLimit 1
pack.threads 1
pack.windowMemory 64m
EOF
}

# mirror_configure_store MIRROR
# Apply mirror_store_config to MIRROR's own `.git/config` and remove its
# reflog files. Idempotent and cheap — each key is written only when it does
# not already hold the value, so a settled mirror costs seven `git config
# --get` reads per state-sync run — and safe on a mirror that has not been
# configured before: an existing pile of reflog-kept snapshots becomes
# unreachable the moment `.git/logs` goes, and the next auto-gc prunes it
# under the same bounds a fresh mirror runs under (a pile of 43,000 reflog
# entries and 48–50 packs on the two VM nodes went that way by hand on
# 2026-09-15, in 11–12 s each). Never returns non-zero:
# the caller is about to push or fetch, and neither is worth aborting over a
# configuration write.
mirror_configure_store() {
  local mirror="$1" key value
  while read -r key value; do
    [[ -n "$key" ]] || continue
    [[ "$(git -C "$mirror" config --local --get "$key" 2>/dev/null)" == "$value" ]] \
      || git -C "$mirror" config --local "$key" "$value" 2>/dev/null || true
  done < <(mirror_store_config)
  # With core.logAllRefUpdates false git still appends to any reflog file that
  # already exists, so the files themselves have to go — once; git creates no
  # new ones while the setting holds.
  rm -rf "${mirror:?}/.git/logs"
  return 0
}

# mirror_record_rebuild STATE_DIR
# Bump the durable rebuild counter and stamp the time. Called only when a
# rebuild actually happens — never for the ordinary first-run init, which
# must stay silent (a fresh `git init` has nothing to have failed).
mirror_record_rebuild() {
  local f prev=0
  f="$(mirror_rebuild_state_file "$1")"
  if [[ -f "$f" ]]; then
    prev="$(jq -r '.count // 0' "$f" 2>/dev/null || echo 0)"
    [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
  fi
  mkdir -p "$(dirname "$f")"
  jq -nc --argjson count "$(( prev + 1 ))" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{count: $count, last_rebuilt_at: $ts}' > "$f"
}

# mirror_rebuild_verdict STATE_DIR
# The heartbeat's `mirror` field: the JSON literal `null` if this node has
# never rebuilt its mirror, else {status:"rebuilt", count, last_rebuilt_at} —
# the same shape family as compose_drift_status/image_drift_status/
# toggle_switch_summary, read back fresh on every push so a repeat rebuild
# bumps `count` rather than reading identically to the first. Never returns
# non-zero: this runs under `set -e` inside a node's heartbeat push, and no
# verdict is worth aborting one.
mirror_rebuild_verdict() {
  local f
  f="$(mirror_rebuild_state_file "$1")"
  [[ -f "$f" ]] || { printf 'null'; return 0; }
  jq -c '{status: "rebuilt", count: (.count // 1), last_rebuilt_at: (.last_rebuilt_at // "")}' "$f" 2>/dev/null \
    || printf 'null'
  return 0
}
