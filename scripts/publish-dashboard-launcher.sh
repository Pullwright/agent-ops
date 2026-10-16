#!/usr/bin/bash
#
# publish-dashboard-launcher.sh — sub-minute dashboard heartbeat.
#
# cron can't fire more than once a minute, so cron launches this once every
# 5 minutes and it self-loops for ~295s (leaving a ~5s gap so consecutive cron
# runs don't overlap). Each tick regenerates the dashboard; a full
# GitHub-hitting refresh runs only when the last one has aged out — five
# minutes, or `duty_divisor` times what the last one cost when that is longer,
# up to `pace_cap_s` — with the cheap local-only --no-github refresh in
# between, so the page stays near-live without hammering the GitHub API.
#
# A tick lands on a 5-second boundary as before, but the loop also measures
# what each tick costs and idles a multiple of that before the next one; a
# backoff that outlasts the window is persisted for the window after it, which
# idles through what is left of it or exits without a tick. So the Publisher
# can never take more than a fixed share of wall-clock — across windows, not
# merely within one — whatever a publish grows to cost. See `duty_divisor`
# below.

set -uo pipefail

startat=$EPOCHSECONDS
# LAUNCHER_WINDOW exists for the test suite, which cannot wait five minutes;
# cron always runs the default.
endat=$(( startat + ${LAUNCHER_WINDOW:-295} ))
# A tick started in the window's final seconds finishes after it, and the
# overrun collides with the next cron-fired launcher. This is the *floor* on
# that reserve; the loop raises it to whatever the last tick actually cost,
# because the ten seconds here were sized against a five-second budget that
# nothing enforced and every node now misses — see `duty_divisor` below.
tick_margin=10

# How long the loop must idle after a tick, as a multiple of what that tick
# cost. 9 holds the Publisher to a tenth of wall-clock: of the window, while
# the backoff fits inside it, and of the windows after it when it does not,
# because the backoff is persisted (`next_tick_at`, below) and the next window
# honours it before it runs anything.
#
# The loop used to sleep to the next 5-second boundary and no more, whatever a
# tick had just cost, on the assumption a tick fits in five seconds (the
# `tick_margin` note above, and this file's header). Nothing measured a tick,
# so nothing noticed when that stopped being true: by 2026-08-25 a publish cost
# 20-22s on every node, and the window ran rebuilds back to back — ~11 per
# window, roughly 78% of a core, measured at 4 rebuilds per 120s on `poetic-1`
# (#799). The page it produced was byte-identical each time on an idle node.
#
# Pacing off the measured cost rather than a constant is what makes this
# self-correcting: a cheap tick earns a cheap backoff and the page stays as
# live as it ever was (a 0.4s no-op tick still lands on the next 5-second
# boundary), while an expensive one pays for itself. It needs no per-node
# tuning and cannot be invalidated by the state growing, which a hard-coded
# budget — or a hand-set LAUNCHER_WINDOW — can and did.
#
# For as long as the backoff lived only in this process, that share held only
# inside a window: cron starts a fresh launcher every five minutes, a window
# always runs its first tick (the floor on the tail reserve in the loop, which
# is about fit, not pacing), and nothing told the new launcher what the old one
# still owed. Invisible while a tick cost 20s, because 180s of backoff fits a
# 295s window. By 2026-10-16 a GitHub refresh cost 500–1,100s and a local tick
# 45–270s on every node, so no backoff fitted, every window's first tick ran
# at once, and the Publisher was busy about two thirds of every hour — two of
# them per host, with every host at a load of 4 to 6 while the pipeline was
# idle (#2429). The refresh was also due again 285s after it finished whatever
# it had cost, which is the same defect from the other side; see `gh_due_s` in
# the loop.
duty_divisor="${LAUNCHER_DUTY_DIVISOR:-9}"

# The most a persisted backoff, or the GitHub refresh's due age, may come to.
# Both scale with a measured cost, and nothing upstream bounds what wedges a
# tick: #1305 measured a 4,511,835 ms tick on a node livelocked under its
# memory cgroup's throttling, which at 1:9 is 11.3 hours of idling. A page an
# hour behind is an outage the operator can read; an eleven-hour one is not.
# The in-window clamp (`max_next_tick_ms`, in the loop) bounds the sleep a
# single window takes; this bounds what crosses windows. LAUNCHER_PACE_CAP
# exists for the test suite, like the other LAUNCHER_* variables; cron always
# runs the default.
pace_cap_s="${LAUNCHER_PACE_CAP:-3600}"

scriptdir="$(cd "$(dirname "$0")" && pwd)"
appdir="$(dirname "$scriptdir")"
# shellcheck source=lib/fleet.sh
. "$appdir/lib/fleet.sh"
# shellcheck source=lib/scratch.sh
. "$appdir/lib/scratch.sh"
# LAUNCHER_PUBLISH_CMD exists for the test suite, which must be able to watch
# which mode each tick chose without a network call; cron always runs the
# Publisher itself.
cmd="${LAUNCHER_PUBLISH_CMD:-$scriptdir/publish-dashboard.sh}"

# Same convention as agent-cycle.sh/review-cycle.sh: stamps the JSON repair
# records fleet_repair_log below writes for the JSONL logs, so a reader can
# tell which node's launcher found and fixed the hole.
node_name="${NODE_NAME:-$(hostname 2>/dev/null || echo node)}"
node_name="${node_name//[^A-Za-z0-9._-]/-}"

# Derive the state dir from config.json (same source publish-dashboard.sh
# uses) so the lock and log always land where the dashboard is written.
expand_home() { local p="$1"; [[ "$p" == "~"* ]] && p="$HOME${p:1}"; printf '%s\n' "$p"; }
logdir="$(expand_home "$(jq -r '.state_dir' "$appdir/config.json")")"
log="${1:-$logdir/dashboard.log}"
lck="$logdir/dashboard.lck"

# Which ticks talk to GitHub, decided by the age of the last real fetch rather
# than by the wall clock. publish-dashboard.sh stamps this file on every fetch
# it *attempts* — success or failure alike — so the gate is both self-healing
# and self-limiting: a missed cron window, a publish that overran its 5-second
# budget, or a GitHub outage all resolve to "the next tick is the one that
# fetches", and none of them can turn into a retry storm.
#
# It replaces `(( EPOCHSECONDS % 300 < 5 ))`, which could not fire. The sleep
# below always lands a tick on an exact multiple of 5, so that test meant
# `% 300 == 0`; a window opened by a `*/5` cron entry starts on a 300-second
# boundary and runs from offset +5 to +285, so the one instant it needed was
# the one instant the loop never reached. In practice the GitHub panels
# refreshed only when cron's sub-second jitter happened to put the first tick
# on the boundary — every half hour or worse, not every five minutes, and
# with nothing anywhere saying so.
#
# 285 rather than 300: the stamp is written when a fetch *finishes*, so the
# gap between fetches is this plus however long one takes (~20s on a two-repo
# node). Ageing out slightly early keeps the observed cadence at five minutes
# instead of drifting past it.
#
# This is the *floor* on the due age, not the due age itself: a refresh that
# costs more than a ninth of it is due `duty_divisor` times its own cost after
# it finished instead, so that it keeps to the same share of wall-clock as any
# other tick (`gh_due_s`, computed in the loop because the cost it follows
# changes inside a window). A fixed 285s let a 700s refresh fall due again
# 285s after it finished, which is what made every window's first tick a
# refresh on every node (#2429).
gh_cache="$logdir/.dashboard-github.json"
gh_max_age="${LAUNCHER_GITHUB_MAX_AGE:-285}"

# What a tick of each kind last cost, in whole seconds, rounded up, and the
# instant the last tick's backoff ends when that is past its own window:
# "<gh_cost_s> <local_cost_s> <next_tick_at>", the third in epoch seconds, or
# 0 for a backoff that ended inside its window. The tail reserve below needs
# the costs on the *first* tick of a window, the pacing check needs the
# backoff *before* that tick, and cron starts a fresh launcher every window —
# so learning either in-process would reset it exactly when it is wanted, and
# the fix would ship inert. That is the shape #793 shipped with for a day and
# a half, so it is worth a file.
#
# Seconds rather than milliseconds because `endat` and `EPOCHSECONDS` are
# seconds and the reserve and the pacing check are the only consumers; rounded
# up because under-reserving, and under-idling, is what this exists to
# prevent.
cost_cache="$logdir/.dashboard-tick-cost"
gh_cost_s=0
local_cost_s=0
next_tick_at=0
if [[ -r "$cost_cache" ]]; then
  read -r gh_cost_s local_cost_s next_tick_at _ < "$cost_cache" 2>/dev/null || true
fi
# A truncated or hand-edited cache must not become an arithmetic error in the
# loop; an unreadable value simply means "not measured yet" — or, for the
# third field, "nothing owed", which is also what a cache with two fields
# reads as.
[[ "$gh_cost_s"    =~ ^[0-9]+$ ]] || gh_cost_s=0
[[ "$local_cost_s" =~ ^[0-9]+$ ]] || local_cost_s=0
[[ "$next_tick_at" =~ ^[0-9]+$ ]] || next_tick_at=0
cost_stamp="$gh_cost_s $local_cost_s $next_tick_at"

# The very first thing we touch is the lock/log in $logdir, before
# publish-dashboard.sh gets a chance to create it — make sure it exists.
mkdir -p "$logdir"

# A container killed mid-append can leave the log's size recorded while the
# data blocks behind the last few writes never reach disk: they read back as
# NUL bytes. `ockham-container` carries one such hole — 652 bytes, four whole
# lines, between two intact ones, left by a watchtower roll back when a roll
# could still land mid-cycle. Rolls now defer to a running cycle
# (deploy/docker/watchtower-pre-update.sh), but every other unclean stop still
# does this: a manual `up -d` or `down`, a host reboot, an OOM kill.
#
# The lost lines are lost. What matters is what the hole does to every *later*
# read: one NUL anywhere makes the whole file binary, and grep then stops
# printing matches for all 8 MB of plain text around it. GNU grep at least says
# "binary file matches"; ugrep, which is what `grep` resolves to on the node
# owner's own shell, prints nothing and exits 1 — indistinguishable from "the
# heartbeat has never logged a refresh". That is precisely the wrong failure
# for the one file you open when something is wrong, and it persists for the
# life of the log.
#
# So strip the NULs once per window and record what was dropped, rather than
# closing the gap silently — the loss is a fact about the node worth keeping
# (`fleet_repair_log`, lib/fleet.sh). It hits the same hazard in `log.jsonl`,
# `review-log.jsonl` and `revert-rate.jsonl` too, so repair those the same way
# each window, alongside `dashboard.log`.
#
# Except `log.jsonl` while the implementation cycle holds its lock. A running
# cycle copies its own new events into its union snapshot by line number —
# `tail -n "+$(( log_lines_before + 1 ))"`, with `log_lines_before` taken from
# `wc -l` (lib/candidate-gather.sh, lib/standdown.sh) — and a repair that
# drops K damaged lines and appends one record of its own moves every later
# line up by K-1, so the snapshot would silently lose that many of the cycle's
# events. The size check in `fleet_repair_swap` does not catch it, because no
# append needs to overlap the repair. The lock is live by `acquire_lock`'s own
# test (agent-cycle.sh): a pid that `kill -0` finds, in a lock that names this
# container or names none. The launcher and the cycle share a container, so a
# lock naming another one is a dead container's, which the next cycle takes
# over. Nothing takes line offsets into the other files, and the repair is
# retried every window, so one skipped while a cycle runs costs nothing.
cycle_lock_live() {  # <lock-file>
  local f="$1" pid host
  [[ -f "$f" ]] || return 1
  pid="$(jq -r '.pid // empty' "$f" 2>/dev/null || true)"
  host="$(jq -r '.host // empty' "$f" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ -z "$host" || "$host" == "${HOSTNAME:-}" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}
fleet_repair_log "$log" "$node_name"
for f in "$logdir/log.jsonl" "$logdir/review-log.jsonl" "$logdir/revert-rate.jsonl"; do
  if [[ "$f" == "$logdir/log.jsonl" ]] && cycle_lock_live "$logdir/lock.json"; then
    continue
  fi
  fleet_repair_log "$f" "$node_name"
done

# What a dead process left in $TMPDIR — a Publisher's working set from a
# publish the OOM killer or a container stop ended, a cycle's scratch
# directory from a stale-lock takeover's KILL (lib/scratch.sh,
# implementation-pipeline-spec requirement 2.5). Once a window, here, because
# this launcher runs on every node every five minutes whatever the node's
# role, which no cycle does: a standby node's agent-cycle.sh exits at its
# role guard, and its Publisher runs from this loop alone. Logged only when
# something was removed, so an idle node's log stays quiet.
# shellcheck disable=SC2119  # the default, ${TMPDIR:-/tmp}, is the one wanted here
swept="$(scratch_sweep_dead_owners)"
if [[ "$swept" =~ ^[0-9]+$ ]] && (( swept > 0 )); then
  printf '%(%Y-%m-%dT%H:%M:%S%z)T swept: removed %s scratch director(ies) left by dead processes in %s\n' \
    -1 "$swept" "${TMPDIR:-/tmp}" >>"$log"
fi

# What the last window's final tick still owes. Its backoff was computed in
# that process and persisted (the third field above) because it ran past that
# window; this one either idles through what is left of it, or has no room
# for a tick past it and ends without one. Across windows that is the same 1:9
# the sleep in the loop keeps within one: a 75s local tick is followed by 675s
# of idle whichever cron firings those seconds fall in, where a fresh launcher
# that knew nothing of the debt ran its first tick at once (#2429). It is
# pacing, not fit: the floor in the loop that always runs a window's first
# tick is about a tick the window cannot fit, and does not apply here.
#
# After the repair and the sweep rather than before them: both are the
# launcher's own per-window housekeeping, cheap, and wanted on every node
# every five minutes whatever the Publisher is owed — a hole in a log is worth
# closing before the next read of it rather than an hour later, and a dead
# Publisher's working set is reclaimed the window it is found. The pacing is
# about the Publisher's share of the machine, which neither of them touches.
#
# `endat - tick_margin` rather than `endat`: the loop admits no tick in the
# window's final `tick_margin` seconds, so a backoff ending there leaves this
# window nothing to wait for. Whole seconds, because `next_tick_at` is whole
# seconds and the loop's own 5-second alignment follows regardless.
if (( EPOCHSECONDS < next_tick_at )); then
  if (( next_tick_at <= endat - tick_margin )); then
    printf '%(%Y-%m-%dT%H:%M:%S%z)T pacing: idle until %(%Y-%m-%dT%H:%M:%S%z)T — the last tick'\''s backoff reaches into this window\n' \
      -1 "$next_tick_at" >>"$log"
    sleep $(( next_tick_at - EPOCHSECONDS ))
  else
    printf '%(%Y-%m-%dT%H:%M:%S%z)T pacing: window idle — the last tick'\''s backoff runs to %(%Y-%m-%dT%H:%M:%S%z)T\n' \
      -1 "$next_tick_at" >>"$log"
    exit 0
  fi
fi

# EPOCHSECONDS is too coarse to pace with: it rounds a 0.4s no-op tick to 0 and
# a 0.6s one to 1, and the backoff below multiplies whatever it is given, so
# that rounding would be multiplied too. EPOCHREALTIME carries microseconds.
now_ms() {
  local t="${EPOCHREALTIME/,/.}"   # a comma-decimal locale renders it that way
  printf '%s' "$(( ${t%%.*} * 1000 + 10#${t#*.} / 1000 ))"
}

sleep_ms() {
  local ms="$1"
  (( ms > 0 )) || return 0
  sleep "$(( ms / 1000 )).$(printf '%03d' "$(( ms % 1000 ))")"
}

# What the last tick cost, and therefore the earliest the next may start. Zero
# until a tick has been measured, so the first tick of a window is never
# delayed and a window that runs one tick behaves exactly as it did before.
last_cost_ms=0
next_tick_ms=0
# Ticks actually started in this window, for the first-tick floor on the
# reserve below.
ticks_run=0

while (( EPOCHSECONDS < endat - tick_margin )); do
  # Wait out the backoff the previous tick earned. One that would run past the
  # end of the window ends the window instead: cron opens the next one on
  # schedule, that one reads what this tick persisted and idles the rest of
  # the backoff itself, and sleeping through the remainder here would only
  # delay it.
  backoff_ms=$(( next_tick_ms - $(now_ms) ))
  if (( backoff_ms > 0 )); then
    (( EPOCHSECONDS + backoff_ms / 1000 < endat - tick_margin )) || break
    sleep_ms "$backoff_ms"
  fi

  # --fast with it: a local tick carries the history roll-ups forward from the
  # last full payload instead of rebuilding them, which is what lets the page
  # follow a running cycle at 1:9 pacing (#798). The GitHub tick below is the
  # full build, so nothing carried forward is ever more than one fetch old.
  github=(--no-github --fast); kind=local
  sleep $(( 5 - EPOCHSECONDS % 5 ))
  gh_at="$(stat -c %Y "$gh_cache" 2>/dev/null)" || gh_at=0
  # The refresh is due when the stamp is older than the larger of `gh_max_age`
  # and `duty_divisor` times what the last refresh cost, capped at
  # `pace_cap_s`: the 1:9 every tick keeps, applied to the one kind a fixed
  # age let run back to back (#2429). Computed here rather than once at the
  # top, because every refresh this window runs re-measures `gh_cost_s`.
  gh_due_s=$(( gh_cost_s * duty_divisor ))
  (( gh_due_s <= pace_cap_s )) || gh_due_s=$pace_cap_s
  (( gh_due_s >= gh_max_age )) || gh_due_s=$gh_max_age
  if (( EPOCHSECONDS - ${gh_at:-0} >= gh_due_s )); then
    github=(); kind=github
  fi

  # Reserve the window's tail for a tick of the kind about to run, or for
  # `tick_margin`, whichever is longer.
  #
  # This used to reserve `tick_margin` *plus* `last_cost_ms` — whatever the
  # previous tick cost, of either kind — one line above, before the kind was
  # even decided. That was a sound proxy only while every tick was expensive.
  # #804 made the no-op path actually fire, so the previous tick became a
  # sub-second skip, the reserve collapsed to the bare `tick_margin`, and a 45s
  # GitHub tick starting in the last half-minute ran past the end of the
  # window. supercronic does not run overlapping instances of a job, so it
  # dropped the *whole* next window — `not starting: job is still running` —
  # and the page went ten minutes without an update (#807). The old reserve was
  # correct precisely for as long as the bug it depended on was still there.
  #
  # A GitHub tick costs 42-47s against a local tick's 17-20s on both laptop
  # nodes, so the two kinds cannot share an estimate in either direction: the
  # local figure under-reserves a GitHub tick, and the GitHub figure would cost
  # an idle window most of the cheap ticks it has room for.
  #
  # Larger-of-the-two rather than the sum: `tick_margin` is the floor on this
  # reserve, not a separate cushion to add to it. Summing them made a 1s tick
  # in a 30s window reserve 11s of it, which is how the original guard read —
  # and it means a cheap tick's tail behaves exactly as it always has, because
  # for anything under 10s this is still just `tick_margin`.
  if [[ "$kind" == github ]]; then reserve_s=$gh_cost_s; else reserve_s=$local_cost_s; fi
  (( reserve_s > tick_margin )) || reserve_s=$tick_margin
  # A window always runs its first tick, whatever the reserve says. Without
  # this floor a tick that grew past the window would stop the dashboard
  # altogether, silently and permanently — every window deferring its only
  # tick, no page update, and nothing in the log but one deferral every five
  # minutes. That trades a bounded overrun for an unbounded outage, which is
  # the wrong way round; and the tick that overran in #807 was never a
  # window's first, since a GitHub tick starting at t<=5s of a 295s window
  # cannot overrun it. So the floor costs the fix nothing.
  if (( ticks_run > 0 && EPOCHSECONDS > endat - reserve_s )); then
    # In practice only the expensive kind reaches this, so it is at most one
    # line per window and usually far fewer. It is also the only place the tail
    # rule becomes visible: without it a deferred fetch is indistinguishable
    # from a quiet system, which is the failure mode the pacing line above was
    # added for.
    printf '%(%Y-%m-%dT%H:%M:%S%z)T deferred: a %s tick needs %ss, window has %ss left\n' \
      -1 "$kind" "$reserve_s" "$(( endat - EPOCHSECONDS ))" >>"$log"
    break
  fi

  if [[ "$kind" == github ]]; then
    # One line every five minutes, and the only record anywhere of when the
    # GitHub-sourced panels were last actually refreshed — the symptom this
    # gate's predecessor produced was a page that looked healthy while its PR
    # list quietly aged, with nothing in the log to say so.
    #
    # The due age it was gated on goes with it: once that age follows the
    # cost, a reader cannot tell from the stamp alone whether a fifty-minute
    # gap was a slow refresh paying for itself or a gate that failed to fire.
    if (( gh_at > 0 )); then age="$(( EPOCHSECONDS - gh_at ))s ago"; else age="never"; fi
    printf '%(%Y-%m-%dT%H:%M:%S%z)T github: refreshing (last fetch %s, due after %ss)\n' \
      -1 "$age" "$gh_due_s" >>"$log"
  fi
  # -E 111: distinguish "another publish holds the lock" (skip, don't stack
  # up) from a genuine publish failure, and leave a trace so a stuck lock
  # doesn't look like a quiet system.
  tick_start_ms="$(now_ms)"
  ticks_run=$(( ticks_run + 1 ))
  flock -n -E 111 "$lck" "$cmd" "${github[@]}" >>"$log" 2>&1
  rc=$?
  tick_end_ms="$(now_ms)"
  last_cost_ms=$(( tick_end_ms - tick_start_ms ))
  # The backoff this tick earns, capped at `pace_cap_s` (see there): a backoff
  # scales with `last_cost_ms`, which scales with whatever wedged the tick, and
  # nothing upstream bounds that. agent-ops#1305 measured a 4,511,835 ms tick
  # — a node livelocked under a memory cgroup's throttling, not a publish
  # merely running long — which this loop turned into a computed "next tick
  # in 40606s" (11.3 hours).
  raw_backoff_ms=$(( last_cost_ms * duty_divisor ))
  (( raw_backoff_ms <= pace_cap_s * 1000 )) || raw_backoff_ms=$(( pace_cap_s * 1000 ))
  next_tick_ms=$(( tick_end_ms + raw_backoff_ms ))
  # A backoff that ends past this window's reserve line is the next window's
  # to honour, so the instant it ends is persisted below, with the costs, in
  # whole seconds rounded up. Zero when it ends inside the window, which the
  # next window reads as nothing owed; and zero for a tick that earned no
  # backoff at all, even one ending past the line, since an instant already
  # past by the time any window could read it is a write for nothing.
  max_next_tick_ms=$(( (endat - tick_margin) * 1000 ))
  if (( raw_backoff_ms > 0 && next_tick_ms > max_next_tick_ms )); then
    next_tick_at=$(( (next_tick_ms + 999) / 1000 ))
  else
    next_tick_at=0
  fi
  # Within the window the sleep is clamped to the window's own remaining time:
  # cron opens the next window on schedule and that window reads what is owed,
  # so sleeping past `endat` here would only delay it — and the raw figure is
  # what a later `pacing:` line would otherwise log as this tick's backoff,
  # which is how #1305's 40606s reached the log. Never below `tick_end_ms`: a
  # window already past its reserve owes no backoff, not a negative one.
  (( max_next_tick_ms < tick_end_ms )) && max_next_tick_ms=$tick_end_ms
  (( next_tick_ms > max_next_tick_ms )) && next_tick_ms=$max_next_tick_ms
  backoff_ms=$(( next_tick_ms - tick_end_ms ))

  # A backoff worth naming. The defect behind this loop was invisible for as
  # long as it was deployed because nothing anywhere recorded what a tick cost
  # — it took `top` on the host to find it. One line per expensive tick, and
  # only for an expensive one, keeps that visible without burying the GitHub
  # and repair lines this log exists for. A lock collision (rc 111) costs
  # nothing and earns nothing, so it never lands here and still retries on the
  # next boundary.
  #
  # The threshold is on the backoff rather than the tick because the backoff is
  # what an operator is looking for: it says the heartbeat is deliberately
  # idling and for how long, which is the question `top` was needed to answer.
  # Logged as the clamped figure, never the raw `last_cost_ms * duty_divisor`:
  # the whole point of the clamp above is that the backoff actually applied is
  # never longer than the window has left, so the log must not claim otherwise.
  if (( backoff_ms >= 5000 )); then
    printf '%(%Y-%m-%dT%H:%M:%S%z)T pacing: tick cost %sms — next tick in %ss (duty cycle 1:%s)\n' \
      -1 "$last_cost_ms" "$(( backoff_ms / 1000 ))" "$duty_divisor" >>"$log"
  fi
  # Remember what this kind of tick costs, for the tail reserve at the top of
  # the loop — and, with what its backoff still owes past this window, for the
  # next window, which is a different process.
  #
  # A lock collision is excluded: it returns in milliseconds without publishing
  # anything, and recording that as the cost of a GitHub tick would under-
  # reserve the next window's tail by forty seconds — the exact defect this is
  # here to fix, reintroduced through its own bookkeeping.
  if (( rc != 111 )); then
    if [[ "$kind" == github ]]; then
      gh_cost_s=$(( (last_cost_ms + 999) / 1000 ))
    else
      local_cost_s=$(( (last_cost_ms + 999) / 1000 ))
    fi
    # Written only when a whole second moved, or the owed instant changed —
    # which it does on the one tick a window can have whose backoff crosses
    # the window's end, and on the first tick after it, so at most twice a
    # window. The
    # cache lives in `state_dir`, which the Publisher fingerprints, and a
    # rewrite on every 5-second no-op tick would be pure churn for that
    # fingerprint to step around — the same self-invalidation that made #802
    # and #804 necessary. It is pruned there explicitly, but not writing it is
    # cheaper than excluding it well.
    if [[ "$gh_cost_s $local_cost_s $next_tick_at" != "$cost_stamp" ]]; then
      cost_stamp="$gh_cost_s $local_cost_s $next_tick_at"
      # Rename into place: a launcher killed mid-write must not leave the next
      # window reading half a number and reserving nothing.
      if printf '%s\n' "$cost_stamp" > "$cost_cache.$$" 2>/dev/null; then
        mv -f "$cost_cache.$$" "$cost_cache" 2>/dev/null || rm -f "$cost_cache.$$" 2>/dev/null
      else
        rm -f "$cost_cache.$$" 2>/dev/null || true
      fi
    fi
  fi

  if (( rc == 111 )); then
    # Not our turn and no fetch happened, so the stamp is deliberately left
    # alone: the next tick inherits the attempt rather than losing the window.
    printf '%(%Y-%m-%dT%H:%M:%S%z)T skipped: publish already running\n' -1 >>"$log"
  elif [[ "$kind" == github ]]; then
    # A GitHub tick ran. The Publisher stamps the file itself at the end of
    # any fetch it reaches, but one that dies before then — a missing binary,
    # a killed process — would leave the stamp untouched and put every
    # following tick back into GitHub mode, five seconds apart. Stamping the
    # attempt here bounds that to one try per window, whatever happened.
    touch "$gh_cache" 2>/dev/null || true
  fi
done

# A healthy window must end 0. Without this, the script's status is that of
# the last loop-body command — the `(( rc == 111 ))` bookkeeping above, which
# is 1 (false) after every *successful* publish — and supercronic reports the
# whole window as failed every five minutes, drowning real failures in noise.
exit 0
