#!/usr/bin/env bash
#
# lib/compose-reconcile.sh — apply this node's own merged compose.yaml, the
# way watchtower applies a merged image.
#
# lib/compose-drift.sh answers "has this node's compose.yaml fallen behind the
# copy its image shipped". It has been answering "yes" on nodes for days at a
# time, because the only thing that could act on the answer was a human
# running `docker compose up -d` on that host: an image roll recreates a
# container from the *old* container's Config, so labels, service environment,
# mounts and whole new services merged to `main` sit inert on every node until
# someone visits it. Two escalations in one week (agent-ops#1266's
# `memory.high` parent, agent-ops#1339's collector change) existed only to ask
# the owner to perform that visit.
#
# This library is the deterministic actor the badge never had. No model is in
# this path and none can be: the file it installs is the one that arrived
# through the image, byte for byte, and the only decision taken here is
# whether now is a safe moment to install it.
#
# What it will do, and nothing else:
#
#   1. compare the node's own compose.yaml against the image's copy, through
#      lib/compose-drift.sh — the same comparison the heartbeat badge makes,
#      so the actor and the alarm can never disagree about what drift is;
#   2. check every `${VAR}` the *new* file requires against the keys in the
#      node's `.env`, and refuse outright if one is missing;
#   3. honour the two cycle locks exactly as
#      deploy/docker/watchtower-pre-update.sh honours them, so a compose
#      recreate can no more kill a running cycle than an image roll can, and
#      stand back while a `roll-pending` marker says a watchtower roll is due
#      on this node, so the two updaters never recreate the same container at
#      once — for `lock_stale_after` at the outside, the same bound a cycle
#      lock gets;
#   4. copy the image's copy over the node's, and run
#      `docker compose up -d --remove-orphans` for that project — from a
#      transient sibling container, never from this one.
#
# It never touches `.env`. That file holds the node's identity and its live
# credentials, it is the one file that legitimately differs between two nodes,
# and it is the owner's. The env check reads *key names only* — the
# `sed` below discards everything after the `=` before anything is printed —
# so no value is read into a variable, logged, or compared; the same idea the
# workstation's own `env-key-hash.sh` uses to compare a node's `.env` against
# its running containers without ever handling what is in it.
#
# **The copy is written in place, not renamed.** A bind mount of a *file*
# pins the inode it was created against, so `mv`-ing a new file over
# compose.yaml would leave every already-running container's
# `/host/compose.yaml` showing the old content — and `compose up -d` recreates
# only the services whose own config changed, so a node that took a merged
# change adding one new service would go on reporting `compose drifted` from
# every container the change did not touch, for ever, with nothing left to
# reconcile. Truncating the existing inode instead makes the new content
# visible through every existing mount the moment it lands. The write is
# staged beside the target and verified byte-for-byte first, so the
# non-atomic step is a single local copy of an already-checked file.
#
# **The recreate runs in a sibling container, not in this one.** `reconciler`
# is a service of the very project an apply recreates, and on a real apply it
# is always one of the services that changed: the compose change that drifted
# arrives on the same image roll that carries it. Both Compose versions in
# play recreate a container by creating its replacement, stopping the old one,
# removing it and renaming the new one, and only then starting everything in
# dependency order — so an `up -d` run from inside this container reaches its
# own service, stops the process running it, and dies there, leaving the
# project stopped or created-but-never-started. `restart: unless-stopped` does
# not help: an explicit stop cancels the restart, and a container that was
# never started has no restart to resume. That is not a theoretical ordering.
# It took `ockham-container`'s whole stack down on 2026-09-28, on the first
# real apply anywhere on the fleet (agent-ops#1913).
#
# So the `up` is handed to a `docker run --rm` of this very image, with the
# socket and the project directory mounted and `docker` as its command, under
# a cleared environment (see `_compose_reconcile_apply` for why that matters)
# — the shape watchtower already uses to update itself. Nothing that `up` stops
# is then the process running it. This container is still stopped and
# recreated, and is meant to be; what changes is that the apply finishes
# without it. The sibling is run *attached*, so on the ordinary tick that does
# not recreate this service its exit status is read here directly, and on the
# one that does, the client dies with this container while the sibling — a
# container of its own, carrying no compose labels and so invisible to
# `--remove-orphans` — runs to completion.
#
# **`applying` is recorded before the file is installed, and stands for as
# long as the sibling runs.** A verdict written only once `up` returns is one
# a tick that dies mid-apply never writes, which leaves the verdict of the
# tick before it standing: a peer reading the heartbeat sees a node merely
# waiting rather than one stopped half-way through recreating itself. The
# marker goes first instead, carrying `pending_apply`, so the state is visible
# for as long as it lasts and the next tick — ordinarily in the container the
# apply itself replaced — retries the recreate and settles it.
#
# Before the *install*, because the gap between installing the file and
# recording the intention is the one moment in which drift reads in-sync and
# nothing is left asking for a recreate: a tick killed in it leaves every
# container running a compose.yaml it was not created from, with the marker
# saying the node is idle. A tick killed the other side of that record simply
# installs on the next one.
#
# And for as long as the sibling runs, because the marker is what
# deploy/docker/watchtower-pre-update.sh reads to keep a roll off a project
# mid-recreate. Every tick that finds the sibling alive rewrites `applying`
# with a fresh timestamp and settles on that — ahead of the locks, the roll
# marker and the drift check alike, so none of their verdicts can displace the
# guard in the middle of the recreate it exists to protect. The marker
# therefore tracks the apply's real duration, and the hook's own freshness
# bound is a backstop against a reconciler that never came back rather than
# the mechanism itself.
#
# What the sibling printed outlives it in `$state_dir/compose-apply.log`,
# written from inside the sibling through the state volume it inherits. On the
# apply that matters there is nowhere else for it to go: the client capturing
# it dies with this container, and `--rm` takes the sibling's own daemon-side
# log with the container. The file holds the most recent apply alone, header
# line and all — it is local diagnostics on a node whose disk this library has
# no business filling, the event log already records *that* an apply failed,
# and the failing run's last line rides in the verdict's `detail`.
#
# Verdicts, one compact JSON object, written to `$state_dir/.compose-
# reconcile.json` and carried to every dashboard in this node's heartbeat
# (IMPLEMENTATION-PIPELINE-SPEC requirement 2.5a):
#
#   {status:"in-sync", at, since}           nothing to do
#   {status:"applying", at, since,          an apply is in flight: the file is
#    from, to, pending_apply:true}          being or has been installed and a
#                                           sibling container recreates this
#                                           project; whichever generation of
#                                           this container ticks next finishes
#                                           the verdict
#   {status:"reconciled", at, since,        the file was replaced and the
#    from, to}                              project recreated; `from`/`to` are
#                                           the SHA-256 of the old and new file
#   {status:"deferred", at, since, reason}  a cycle is in flight, a roll is
#                                           due, or the recreate itself failed
#                                           — retried on the next tick in every
#                                           case
#   {status:"refused", at, since, reason}   the node is not configured for
#                                           reconciliation, or the new file
#                                           needs a `${VAR}` its `.env` does
#                                           not define. Nothing was applied.
#
# `at` is when the verdict was last written, which is every tick; `since` is
# when the node entered it — the `at` of the last tick whose `status` or
# `reason` differed from the tick before. "How long has this node been
# deferring" needs the second, and the tick deciding how much longer to stand
# back for a watchtower roll reads its own.
#
# A failed `docker compose up -d` is `deferred` rather than `refused` because
# it is retried: the file has already been replaced by then, so drift alone
# would never ask again — `pending_apply` on the marker is what makes the next
# tick retry the recreate it could not finish, and it is the one piece of
# state this library keeps across ticks. Once set it is carried onto every
# later verdict until a recreate actually succeeds, deferrals and refusals
# included: a lock taken, or a roll falling due, between the install and the
# retry must postpone that retry, never discard it.
#
# Events reach `$state_dir/log.jsonl` through lib/log-event.sh's envelope, and
# only on a *transition*: this runs every few minutes, and a node that defers
# through a 40-minute cycle must leave one record of the deferral, not eight.
#
# Every path override exists for the tests, which must control all of them and
# must never reach a real Docker socket: COMPOSE_RECONCILE_PROJECT_DIR,
# _IMAGE_FILE, _STATE_DIR, _CONFIG, _DOCKER (the `docker` command itself,
# stubbed), _DOCKER_SOCKET (this container's own socket path, whose group the
# sibling is added to and which its `DOCKER_HOST` names) and _NOW.

# The two reasons a later tick has to recognise by value rather than by
# reading, written once here instead of at each site. `reason` is the key the
# transition test compares one tick against the next, so neither may carry
# anything that varies while the state does not: a roll marker's `until` moves
# forward at every cycle boundary, and rides in `detail` for that reason.
COMPOSE_RECONCILE_APPLYING_REASON='an apply of the merged compose.yaml is in flight — a sibling container performs the recreate'
COMPOSE_RECONCILE_ROLL_REASON='a watchtower roll is due on this node — the recreate waits until it has landed'

# shellcheck source=lib/compose-drift.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compose-drift.sh"
# shellcheck source=lib/log-event.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log-event.sh"

# The SHA-256 of a file, or the empty string. Identifies *which* compose file
# was installed in a way a line count cannot, and both digests ride the
# `compose-reconciled` event so a later reader can tell one reconciliation
# from another without the files themselves.
compose_reconcile_sha() {
  [[ -f "$1" ]] || return 0
  sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

# The `${VAR}` references a compose file needs the environment to supply,
# sorted and de-duplicated: the braced forms only, and only those with no
# default or alternate — `${VAR}` and `${VAR:?…}`/`${VAR?…}`, never
# `${VAR:-…}`, `${VAR-…}`, `${VAR:+…}` or `${VAR+…}`, all of which compose
# resolves on its own when the variable is unset.
#
# Whole-line comments go first, through the identical filter
# lib/compose-drift.sh applies — partly so the two agree about what is
# material, and partly because this file's comments are full of prose that
# looks like shell (`$pid`, `$(sed …)`), none of which compose ever sees: it
# parses YAML before it interpolates, so a comment is gone before
# interpolation begins. `$$` is compose's own escape for a literal `$`, so it
# is stripped before the scan and `$${VAR}` correctly matches nothing.
#
# Braced forms only, deliberately. A bare `$VAR` is legal compose and is not
# looked for: this file does not use it, and a scan loose enough to catch it
# is loose enough to read the shell fragments in a comment that survived the
# filter as node configuration — a false refusal, which here means a node that
# stops reconciling itself and says a merged change is missing a variable that
# does not exist.
compose_reconcile_required_vars() {
  local file="$1"
  [[ -r "$file" ]] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$file" 2>/dev/null \
    | sed 's/\$\$//g' \
    | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*(\}|:?[-+?][^}]*\})' \
    | sed -E 's/^\$\{([A-Za-z_][A-Za-z0-9_]*)(\}|:?([-+?])[^}]*\})$/\1 \3/' \
    | awk '$2 == "" || $2 == "?" { print $1 }' \
    | sort -u
}

# The key names an `.env` file defines, sorted and de-duplicated. Names only:
# the substitution keeps capture group 2 and discards the whole of the rest of
# the line, so no value ever reaches stdout, a variable, or a comparison. A
# missing or unreadable file is an empty set rather than an error — the caller
# decides what that means.
compose_reconcile_env_keys() {
  local file="$1"
  [[ -r "$file" ]] || return 0
  sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*$/\2/p' \
    "$file" 2>/dev/null | sort -u
}

# The set difference: what the new compose file requires and the node's `.env`
# does not define, one name per line. Empty output is the passing case.
compose_reconcile_missing_env() {  # <compose-file> <env-file>
  comm -23 \
    <(compose_reconcile_required_vars "$1") \
    <(compose_reconcile_env_keys "$2") 2>/dev/null || true
}

# A one-line description of a lock this container must respect, or nothing.
#
# The judgement is deploy/docker/watchtower-pre-update.sh's, and this is
# deliberately only its *foreign* branch: that script runs inside the
# container it is about to destroy and so can meaningfully ask whether its own
# pid is alive, while this one runs in a container that writes neither lock
# and shares no PID namespace with whatever did. A pid is meaningful only
# inside the namespace that minted it (agent-ops#130), so every lock is
# honoured here without a liveness check, until it is released or until it
# passes the same `lock_stale_after` the next cycle would take it over at. The
# asymmetry is priced exactly as the hook prices it: honouring a dead lock
# costs one tick's delay, and the next tick is five minutes away.
compose_reconcile_lock_held() {  # <lock-file> <stale-after-hours>
  local f="$1" stale_after_hours="$2" pid started_at host started_epoch now_epoch
  [[ -f "$f" ]] || return 0
  pid="$(jq -r '.pid // empty' "$f" 2>/dev/null || true)"
  started_at="$(jq -r '.started_at // empty' "$f" 2>/dev/null || true)"
  host="$(jq -r '.host // empty' "$f" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  # An unparseable `started_at` reads as epoch 0 and so as impossibly old —
  # the hook's own convention, and `acquire_lock`'s: a lock whose age cannot
  # be established is one the next cycle would take over, and nothing here
  # should protect what the pipeline itself would not.
  started_epoch="$(date -d "$started_at" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  (( now_epoch - started_epoch < stale_after_hours * 3600 )) || return 0
  # The description deliberately carries no age. It is the key the transition
  # check compares one tick against the next (`_compose_reconcile_settle`), and
  # a live age makes every tick a transition: a node deferring through a
  # 40-minute cycle would log eight identical deferrals into a log replicated
  # to every peer. What is stable while a lock is held — which lock, whose
  # container, since when — is exactly what a reader needs, and the age is
  # arithmetic on the timestamp already in it.
  printf '%s held by container %s since %s' \
    "$(basename "$f")" "${host:-unknown}" "${started_at:-unknown}"
}

# Print the `until` and succeed iff `$state_dir/roll-pending.json` names one
# that has not passed — agent-ops#1096's marker, read from the same file the
# pre-update hook reads and meaning the same thing: this node's last cycle
# boundary found its image behind and yielded, so watchtower is licensed to
# roll this stack at any moment until `until`.
#
# **Read here as a deferral, not as the override it is there.** The hook's
# question is "may this roll destroy a container", and the marker answers yes;
# the question here is "may this tick recreate the whole project", and the
# same marker answers no. Both updaters recreate the same containers, and on
# `ockham-container` on 2026-09-28 they were racing to recreate the same five
# within one second, with nothing surviving to say which stop was whose
# (agent-ops#1913). So the reconciler stands back while a roll is due and
# applies on the first tick after it has landed. The scope question the hook
# has to answer — `lock.json` yes, `review-lock.json` no — does not arise
# here: this defers for either lock anyway, so the marker overrides nothing
# and only ever adds a reason to wait.
#
# The `until` is printed rather than a sentence built around it, because the
# caller puts it in `detail` and not in `reason`. It moves forward every time
# the marker is re-armed, and a `reason` that moved with it would make each
# cycle boundary a fresh transition in a log replicated to every peer, and
# would reset the very timestamp `_compose_reconcile_waited_out` measures the
# wait against.
#
# An unparseable `until` reads as epoch 0, so a corrupt marker never holds a
# reconciliation back on a window it cannot prove.
compose_reconcile_roll_pending() {  # <state-dir>
  local f="$1/roll-pending.json" until_ts until_epoch now_epoch
  [[ -f "$f" ]] || return 1
  until_ts="$(jq -r '.until // empty' "$f" 2>/dev/null || true)"
  [[ -n "$until_ts" ]] || return 1
  until_epoch="$(date -d "$until_ts" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  (( until_epoch > now_epoch )) || return 1
  printf '%s' "$until_ts"
}

# Succeed iff this node has already stood back for a roll for longer than a
# cycle lock would be honoured — `lock_stale_after` hours, measured from the
# `since` on the verdict this tick opened with.
#
# **The marker alone cannot bound the wait, and that is why this exists.**
# `chain_write_roll_pending` re-arms it at every cycle boundary whose image
# still reads `behind` (agent-ops#1096), and
# `chain_clear_landed_roll_pending` leaves it alone while that is true
# (agent-ops#1102), so a node whose roll cannot land — watchtower
# crash-looping, a registry it cannot reach — carries a live marker for as
# long as the condition lasts. A deferral that followed the marker and nothing
# else would leave that node running a compose.yaml none of its containers
# came from for exactly as long, up to and including the merged file that
# would fix it. So the deferral is bounded by this node's own patience
# instead, at the same figure and for the same reason a cycle lock is: a
# signal the pipeline would no longer honour about its own cycles is not one
# to honour about a roll. Past it the apply goes ahead, and the sibling's name
# is what keeps two recreates apart if the roll does land in the middle.
#
# A `since` that will not parse reads as epoch 0 and so as long past the
# bound, the same convention `compose_reconcile_lock_held` keeps: a wait whose
# age cannot be established is not one to go on serving.
_compose_reconcile_waited_out() {  # <now> <stale-after-hours>
  local now="$1" hours="$2" since_epoch now_epoch
  [[ "${compose_reconcile_tick_status:-}" == "deferred" ]] || return 1
  [[ "${compose_reconcile_tick_reason:-}" == "$COMPOSE_RECONCILE_ROLL_REASON" ]] || return 1
  [[ -n "${compose_reconcile_tick_since:-}" ]] || return 1
  since_epoch="$(date -d "$compose_reconcile_tick_since" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date -d "$now" +%s 2>/dev/null || date +%s)"
  (( now_epoch - since_epoch >= hours * 3600 ))
}

# The path as Compose cleans it before labelling a container with it.
# `filepath.Abs` collapses `//`, `/./` and `..` and drops a trailing slash, so
# a node whose `.env` reads `AGENT_OPS_PROJECT_DIR=/srv/agent-ops/` runs
# perfectly well — every bind mount resolves — while its containers carry
# `com.docker.compose.project.working_dir=/srv/agent-ops`. Matched raw, that
# node would defer on every tick with "cannot identify itself", pointing an
# operator at the daemon rather than at the spelling of one line of `.env`.
# `realpath -m -s` is the same cleaning and only that: `-m` so no component
# need exist, `-s` so a symlinked project directory is left as written, which
# is what Compose itself records.
_compose_reconcile_clean_path() {  # <path>
  local p="$1" cleaned=""
  [[ -n "$p" ]] || return 0
  cleaned="$(realpath -m -s -- "$p" 2>/dev/null || true)"
  if [[ -z "$cleaned" ]]; then
    cleaned="$p"
    while [[ "$cleaned" == */ && "$cleaned" != / ]]; do cleaned="${cleaned%/}"; done
  fi
  printf '%s' "$cleaned"
}

# The verdict file itself — `$state_dir/.compose-reconcile.json` — is read
# rather than recomputed by everything that reports it (scripts/state-sync.sh
# for the heartbeat, scripts/publish-dashboard.sh for this node's own row),
# with the one-line `jq -c '.' … || echo null` those scripts already use for
# `.stage-health.json` and `.doctor-status.json`. Same reason: the reconciler
# runs on its own schedule in its own container, and a second computation
# elsewhere would be free to disagree with what that container actually did.
# It is local to this node and excluded from replication, like every other
# file of its kind; only the verdict travels, folded into the heartbeat.

# --- The run itself -----------------------------------------------------------

# compose_reconcile_run — one tick. Prints the verdict object and returns 0 on
# every path: this runs from cron in a container whose only job it is, and no
# verdict is worth a non-zero exit that nothing reads.
compose_reconcile_run() {
  local project_dir image_file state_dir config_file docker_cmd docker_socket now
  project_dir="$(_compose_reconcile_clean_path \
    "${COMPOSE_RECONCILE_PROJECT_DIR:-${AGENT_OPS_PROJECT_DIR:-}}")"
  image_file="${COMPOSE_RECONCILE_IMAGE_FILE:-}"
  [[ -n "$image_file" ]] \
    || image_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy/docker/compose.yaml"
  state_dir="${COMPOSE_RECONCILE_STATE_DIR:-}"
  config_file="${COMPOSE_RECONCILE_CONFIG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.json}"
  docker_cmd="${COMPOSE_RECONCILE_DOCKER:-docker}"
  docker_socket="${COMPOSE_RECONCILE_DOCKER_SOCKET:-/var/run/docker.sock}"
  now="${COMPOSE_RECONCILE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

  local host_file="$project_dir/compose.yaml" env_file="$project_dir/.env"

  _compose_reconcile_begin_tick "$state_dir"
  # Carried onto every verdict below. It is the one piece of state this
  # library keeps across ticks, and the one a tick must never drop: once the
  # file is installed, drift reads in-sync from that moment on, so a verdict
  # written without it is a recreate nothing will ever ask for again.
  local pending_apply="$compose_reconcile_tick_pending"

  # --- An apply already in flight ---------------------------------------------
  # Ahead of every other question, because while the sibling is alive the
  # marker has to go on saying `applying`: that is what
  # deploy/docker/watchtower-pre-update.sh reads to keep a roll off a project
  # mid-recreate. Any other verdict written here — the `name is already in use`
  # a second `docker run` would earn, a lock taken meanwhile, a roll falling
  # due — would clear that guard in the middle of the recreate it exists to
  # protect, and the next poll would roll the stack over the top of it. So the
  # tick settles on a fresh `applying` instead and does nothing else; the
  # recreate the sibling is already running is the one that finishes.
  if [[ "$pending_apply" == "true" ]] && _compose_reconcile_sibling_alive "$docker_cmd"; then
    _compose_reconcile_settle "$state_dir" "$now" applying \
      "$COMPOSE_RECONCILE_APPLYING_REASON" true \
      "$compose_reconcile_tick_from" "$compose_reconcile_tick_to"
    return 0
  fi

  # --- Is this node configured for reconciliation at all? ---------------------
  # The project directory is bind-mounted at the *same absolute path* it has
  # on the host (deploy/docker/compose.yaml's `reconciler` service), which is
  # what makes the relative bind mounts inside compose.yaml — `./compose.yaml`,
  # `./ts-serve.json` — resolve to the same paths for the daemon as for the
  # CLI. Unset, it self-mounts as /dev/null and there is nothing to reconcile
  # against; that is a refusal, recorded once, not an error every tick.
  if [[ -z "$project_dir" || ! -d "$project_dir" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" refused \
      "the node's project directory is not bind-mounted into this container — set AGENT_OPS_PROJECT_DIR in .env to the directory holding compose.yaml, then run docker compose up -d once" \
      "$pending_apply"
    return 0
  fi
  if [[ ! -f "$host_file" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" refused \
      "there is no compose.yaml in $project_dir — AGENT_OPS_PROJECT_DIR must name this stack's own directory, the one holding the compose.yaml this node runs" \
      "$pending_apply"
    return 0
  fi
  if [[ ! -w "$host_file" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" refused \
      "$host_file is not writable from this container — the project directory must be bind-mounted read-write" \
      "$pending_apply"
    return 0
  fi

  # --- Drift, through the same library the badge uses -------------------------
  local drift drift_status
  drift="$(COMPOSE_DRIFT_HOST="$host_file" COMPOSE_DRIFT_IMAGE="$image_file" compose_drift_status)"
  drift_status="$(jq -r '.status // "null"' <<<"$drift" 2>/dev/null || echo null)"
  if [[ "$drift_status" == "null" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" refused \
      "this image carries no copy of compose.yaml to reconcile against" \
      "$pending_apply"
    return 0
  fi

  # A recreate that has not completed is retried whatever drift now says: the
  # file was already replaced before the recreate ran, so drift reads in-sync
  # from that moment on and would otherwise never ask again — the containers
  # staying stale in exactly the silence this whole mechanism exists to end.
  if [[ "$drift_status" == "in-sync" && "$pending_apply" != "true" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" in-sync ""
    return 0
  fi

  # --- The `.env` gate --------------------------------------------------------
  local missing
  missing="$(compose_reconcile_missing_env "$image_file" "$env_file" | paste -sd, - 2>/dev/null || true)"
  if [[ -n "$missing" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" refused \
      "the merged compose.yaml requires ${missing}, which this node's .env does not define and the file itself gives no default for — add it to .env by hand; nothing was applied" \
      "$pending_apply"
    return 0
  fi

  # --- A roll falling due, and the two cycle locks -----------------------------
  local cycle_stale review_stale held
  cycle_stale="$(jq -r '.lock_stale_after // 4' "$config_file" 2>/dev/null || echo 4)"
  # repository_review is the current spelling; project_review is still
  # accepted as a deprecated alias (agent-ops#592, D7) — read directly against
  # the raw file here, same as the rest of this function, so both spellings
  # resolve without going through config_defaults.
  review_stale="$(jq -r '.repository_review.lock_stale_after // .project_review.lock_stale_after // 6' "$config_file" 2>/dev/null || echo 6)"
  [[ "$cycle_stale"  =~ ^[0-9]+$ ]] || cycle_stale=4
  [[ "$review_stale" =~ ^[0-9]+$ ]] || review_stale=6

  # A due roll defers, before either lock is even read: watchtower and this
  # library recreate the same containers, and the marker is the one signal
  # that says the other one is about to. See compose_reconcile_roll_pending
  # for why the same marker the pre-update hook reads as an override is read
  # here as a reason to wait, and _compose_reconcile_waited_out for why the
  # marker cannot be allowed to decide how long that lasts.
  local roll_until=""
  roll_until="$(compose_reconcile_roll_pending "$state_dir" || true)"
  if [[ -n "$roll_until" ]] && ! _compose_reconcile_waited_out "$now" "$cycle_stale"; then
    _compose_reconcile_settle "$state_dir" "$now" deferred \
      "$COMPOSE_RECONCILE_ROLL_REASON" "$pending_apply" "" "" \
      "the marker is in force until $roll_until"
    return 0
  fi

  held="$(compose_reconcile_lock_held "$state_dir/lock.json" "$cycle_stale")"
  if [[ -n "$held" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" deferred \
      "an implementation cycle is in flight ($held) — retrying on the next tick" \
      "$pending_apply"
    return 0
  fi
  held="$(compose_reconcile_lock_held "$state_dir/review-lock.json" "$review_stale")"
  if [[ -n "$held" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" deferred \
      "a project review is in flight ($held) — retrying on the next tick" \
      "$pending_apply"
    return 0
  fi

  # --- Apply ------------------------------------------------------------------
  # This container is resolved to the daemon before anything is written: it is
  # the one precondition of an apply that can fail for a reason nothing here
  # can put right, and installing a file this tick cannot then act on only
  # widens the window in which the node runs a compose.yaml none of its
  # containers came from.
  _compose_reconcile_self "$docker_cmd" "$project_dir"
  if [[ -z "$compose_reconcile_self_id" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" deferred \
      "this container cannot identify itself to the daemon, so there is no sibling to hand the recreate to — retrying on the next tick" \
      "$pending_apply"
    return 0
  fi

  local host_sha to_sha from_sha
  host_sha="$(compose_reconcile_sha "$host_file")"
  to_sha="$(compose_reconcile_sha "$image_file")"
  from_sha="$host_sha"
  # On the tick that finishes an apply its predecessor began, the file is
  # already installed, so the host copy no longer holds the digest the apply
  # replaced and the two would read the same. The marker does hold it — `from`
  # is written there before the install for exactly this — so the `reconciled`
  # verdict and its event name both files rather than the same one twice.
  if [[ "$pending_apply" == "true" && "$host_sha" == "$to_sha" \
        && -n "$compose_reconcile_tick_from" ]]; then
    from_sha="$compose_reconcile_tick_from"
  fi

  # Recorded before the install, and recorded rather than settled: this tick
  # may not live to write a second verdict, and what a reader must not find in
  # that case is the verdict of the tick before it. Before the install because
  # the gap between the two is the one moment in which the file is current and
  # nothing is left asking for the recreate — the pre-update hook would allow a
  # roll into it, and a tick killed in it would leave drift reading in-sync
  # with `pending_apply` false, which is the silence this whole mechanism
  # exists to end. A tick killed the other side of this record simply installs
  # on the next one. `pending_apply` is true from here until a recreate returns
  # 0, which is what has the successor finish what this one started.
  _compose_reconcile_record "$state_dir" "$now" applying \
    "$COMPOSE_RECONCILE_APPLYING_REASON" true "$from_sha" "$to_sha"

  if [[ "$host_sha" != "$to_sha" ]]; then
    if ! _compose_reconcile_install "$image_file" "$host_file" "$to_sha"; then
      _compose_reconcile_settle "$state_dir" "$now" deferred \
        "could not write $host_file — retrying on the next tick" \
        true "$from_sha" "$to_sha"
      return 0
    fi
  fi

  # Truncated per apply, and the header is this side's: it is what says an
  # apply was attempted at all on a tick that never came back to say anything
  # else. A state directory this container cannot write is not a reason to
  # skip the recreate, so the sibling is pointed at /dev/null instead and the
  # verdict carries what it can.
  local apply_log=/dev/null
  if [[ -n "$state_dir" && -d "$state_dir" ]]; then
    apply_log="$state_dir/compose-apply.log"
    printf '# %s — applying compose.yaml %s -> %s\n' \
      "$now" "${from_sha:0:12}" "${to_sha:0:12}" > "$apply_log" 2>/dev/null \
      || apply_log=/dev/null
  fi

  local up_log up_rc=0
  up_log="$(_compose_reconcile_apply "$docker_cmd" "$docker_socket" "$project_dir" \
    "$compose_reconcile_self_id" "$compose_reconcile_self_image" "$apply_log" 2>&1)" || up_rc=$?
  if (( up_rc != 0 )); then
    # The file is installed and the containers are not yet created from it, so
    # the retry has to be driven by the marker rather than by drift.
    # The docker output rides in `detail`, never in `reason`: `reason` is what
    # the transition test compares one tick against the next, and compose's
    # own last line carries timings and progress that differ every run — in
    # `reason` it would make every retry a fresh transition and log one event
    # per tick, the same trap the lock description's age already sprang once.
    _compose_reconcile_settle "$state_dir" "$now" deferred \
      "the recreate exited $up_rc — the file is installed, retrying it on the next tick" \
      true "$from_sha" "$to_sha" "$(printf '%s' "$up_log" | tail -n 1)"
    return 0
  fi

  # Reached only on a tick whose own container the recreate did not replace —
  # the retry, ordinarily, since the apply that carries a `reconciler` change
  # stops this process at its own service. The tick that does not get here
  # leaves `applying` standing, and its successor settles it.
  _compose_reconcile_settle "$state_dir" "$now" reconciled "" false "$from_sha" "$to_sha"
  return 0
}

# This container's own id and image, into `compose_reconcile_self_id` and
# `compose_reconcile_self_image`, or both empty.
#
# Asked of the daemon rather than of this container, because nothing inside a
# container reliably names it: `$HOSTNAME` is the container's short id at
# creation, but watchtower clones `Config.Hostname` forward when it recreates
# one (agent-ops#1072), so after a roll it names a container that no longer
# exists. Compose's own labels do survive that cloning, and the project
# directory — unique to this stack on this host, and already the thing every
# other path here is resolved against — is what picks this stack's reconciler
# out from a neighbouring stack's. It is matched as Compose cleaned it before
# writing it: see `_compose_reconcile_clean_path`. `AGENT_OPS_SERVICE` names
# the service in the service's own definition, so the lookup follows a rename
# that keeps the two in step.
#
# The id, because the sibling inherits this container's mounts by it. The
# image as an *id* rather than a reference, because that pins the bytes this
# container is actually running, which a moved `:latest` would not, and an
# image a running container holds cannot be pruned out from under the
# `docker run`.
_compose_reconcile_self() {  # <docker> <project-dir>
  local docker_cmd="$1" project_dir="$2" id=""
  compose_reconcile_self_id=""
  compose_reconcile_self_image=""
  id="$("$docker_cmd" ps --quiet --no-trunc \
        --filter "label=com.docker.compose.project.working_dir=$project_dir" \
        --filter "label=com.docker.compose.service=${AGENT_OPS_SERVICE:-reconciler}" \
        2>/dev/null | head -n 1)"
  [[ -n "$id" ]] || return 0
  compose_reconcile_self_image="$("$docker_cmd" inspect --format '{{.Image}}' "$id" 2>/dev/null | head -n 1)"
  [[ -n "$compose_reconcile_self_image" ]] || return 0
  compose_reconcile_self_id="$id"
}

# The one name an apply on this node may run under. Per *node* rather than per
# host, so two stacks on one host neither collide nor serialise against each
# other, and an operator finding it in `docker ps` can see whose it is.
_compose_reconcile_sibling_name() {
  printf 'agent-ops-compose-apply-%s' \
    "$(printf '%s' "${NODE_NAME:-node}" | tr -c 'A-Za-z0-9_.-' '-')"
}

# Succeed iff an apply of this node's is running right now. Both filters are
# needed and neither is enough: the name alone would match a container an
# operator had given it, and the label alone would match the other stack's
# apply on a shared host.
_compose_reconcile_sibling_alive() {  # <docker>
  local id
  id="$("$1" ps --quiet --no-trunc \
        --filter "name=^$(_compose_reconcile_sibling_name)$" \
        --filter "label=com.pullwright.agent-ops.compose-apply=true" \
        2>/dev/null | head -n 1)"
  [[ -n "$id" ]]
}

# Run the project's `docker compose up -d --remove-orphans` in a transient
# sibling container. Prints whatever the sibling printed and returns its exit
# status — or nothing at all, on the apply that stops this container: see the
# header for why that is the expected path and not a failure.
#
# **Through `env -i`, and that is not tidiness.** Compose resolves a `${VAR}`
# from the process environment first and the project's `.env` only after, and
# this image sets `TZ=Etc/UTC` in its own `ENV` — the one name it defines that
# `compose.yaml` also interpolates. A sibling started with the image's
# environment would therefore deploy every service with `TZ: Etc/UTC` however
# the node's `.env` is written, silently moving the hour a node's cron fires,
# on an apply whose whole claim is to install the file byte for byte. The
# container this runs in escapes that only because its own service declares
# `TZ: ${TZ:-UTC}`, which is a protection the sibling has no way to inherit.
# Cleared instead, so `.env` is the only thing that decides — the same input a
# human's own `docker compose up -d` in that directory reads — and any future
# collision is cleared with it. Three names are put back, and each is the
# CLI's own need rather than configuration: `PATH` finds the binary, `HOME` is
# where it looks for `config.json`, and `DOCKER_HOST` names the socket the
# sibling was actually given, so the mount and the client cannot disagree
# about where the daemon is.
#
# `--entrypoint env` steps over the image's own entrypoint at the same time,
# which prepares a node's state volumes and has nothing to do here. No network
# at all, like the service itself: the daemon performs any pull, on the host's
# network. `--sig-proxy=false` because the client is attached and its own
# container is one the `up` stops: a SIGTERM delivered to this process would
# otherwise be forwarded into the sibling and abort Compose half-way through
# the recreate, which is the incident this whole mechanism exists to prevent,
# reached by a different road.
#
# **Its mounts are this container's own, by `--volumes-from`.** The three it
# needs are the three this service already has and no others — the socket, the
# project directory at the absolute path it has on the host, and the state
# volume the apply log is written to — and a named volume cannot be asked for
# by path from inside the container that holds it, since the path is a mount
# destination and not somewhere on the host at all. The socket's own group is
# added separately, read off the mounted socket rather than from a variable,
# so it is this host's real `DOCKER_GID` whatever `.env` says.
#
# **And its ceilings are this container's own, read back from the daemon.**
# Every service in `compose.yaml` is bounded because an unbounded container on
# a small host takes the host down, and a `docker run` inherits none of that.
# Read back rather than taken from `AGENT_OPS_RECONCILER_MEMORY` and its
# siblings, because Compose interpolates those at deploy time and they reach
# no container's environment — the daemon holds what a node actually chose.
# `--cpus` is expressed as the period and quota it is shorthand for, since
# `NanoCpus` comes back as an integer and dividing it out is exact.
# `--log-driver none`: the sibling's output is captured in the apply log on
# the state volume and streamed to this client, `--rm` would take a
# daemon-side copy away with the container anyway, and a third copy is one
# more unbounded file on the node's disk.
#
# **The name is the mutex, which is why it carries no timestamp.** The `up`
# starts this container's replacement before the sibling has finished, and that
# replacement's own first tick can fall due seconds later — it will read
# `pending_apply` and want a recreate of its own, and two `docker compose up -d`
# runs against one project take no lock against each other. The tick that finds
# the sibling alive settles on `applying` and never reaches this function; a
# fixed name per node is the backstop under that check, making the daemon
# refuse a second apply (`name is already in use`) if one is ever asked for
# between the two. `--rm` is what keeps the name free: the daemon removes the
# container when it exits, so the name is held for exactly as long as an apply
# is running.
_compose_reconcile_apply() {  # <docker> <socket> <project-dir> <id> <image> <log>
  local docker_cmd="$1" socket="$2" project_dir="$3" id="$4" image="$5" log="$6"
  local gid memory pids nanocpus
  local -a group_args=() limits=()

  gid="$(stat -c %g "$socket" 2>/dev/null || true)"
  [[ "$gid" =~ ^[0-9]+$ ]] && group_args=(--group-add "$gid")

  IFS=$'\t' read -r memory pids nanocpus < <("$docker_cmd" inspect --format \
    '{{.HostConfig.Memory}}{{"\t"}}{{.HostConfig.PidsLimit}}{{"\t"}}{{.HostConfig.NanoCpus}}' \
    "$id" 2>/dev/null || true)
  [[ "${memory:-}"   =~ ^[0-9]+$ ]] && (( memory > 0 ))       && limits+=(--memory "$memory")
  [[ "${pids:-}"     =~ ^[0-9]+$ ]] && (( pids > 0 ))         && limits+=(--pids-limit "$pids")
  [[ "${nanocpus:-}" =~ ^[0-9]+$ ]] && (( nanocpus >= 10000 )) \
    && limits+=(--cpu-period 100000 --cpu-quota "$(( nanocpus / 10000 ))")

  # shellcheck disable=SC2016  # the sibling's own shell expands these, not this one
  "$docker_cmd" run --rm \
    --name "$(_compose_reconcile_sibling_name)" \
    --label com.pullwright.agent-ops.compose-apply=true \
    --network none \
    --sig-proxy=false \
    --log-driver none \
    "${limits[@]}" \
    "${group_args[@]}" \
    --volumes-from "$id" \
    --entrypoint env \
    "$image" \
    -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/home/agent \
    "DOCKER_HOST=unix://$socket" \
    sh -c 'docker compose --project-directory "$1" up -d --remove-orphans >> "$2" 2>&1; rc=$?; cat "$2" 2>/dev/null; exit "$rc"' \
    compose-apply "$project_dir" "$log"
}

# Stage the image's copy beside the target, prove it arrived intact, then
# truncate the target in place and write it. In place because a bind-mounted
# file pins its inode — see the header. `cp` to a dotfile in the same
# directory keeps the staging on the same filesystem as the target and out of
# the way of `check-node-compose.sh`'s own backup-file check, which looks for
# `.env` backups specifically.
_compose_reconcile_install() {  # <image-file> <host-file> <expected-sha>
  local src="$1" dst="$2" want="$3" staged
  staged="$(dirname "$dst")/.compose.yaml.reconcile.$$"
  cp -- "$src" "$staged" 2>/dev/null || { rm -f -- "$staged"; return 1; }
  if [[ "$(compose_reconcile_sha "$staged")" != "$want" ]]; then
    rm -f -- "$staged"
    return 1
  fi
  cat -- "$staged" > "$dst" 2>/dev/null || { rm -f -- "$staged"; return 1; }
  rm -f -- "$staged"
  return 0
}

# Read the marker once, at the top of a tick, into the six things the rest of
# the tick judges itself against. One `jq` for all six: the fields are one
# small object's, and this runs on every node every five minutes.
#
# The dedup baseline has to be taken here rather than re-read per verdict,
# because one tick writes two: `applying` before the recreate and the
# recreate's own outcome after it. Re-reading would compare the second against
# the first and find a transition every single time — a node whose recreate
# keeps failing would log a pair of events every five minutes into a log
# replicated to every peer, which is the exact trap the transition test exists
# to avoid and which the lock description's own age sprang once already.
# Against the tick's opening state instead, a repeated failure is one event and
# a real change is still one event.
#
# `since` and the two digests are read for the same reason in a different
# direction: they are what the *next* verdict has to carry forward. A wait for
# a roll is bounded from `since` (`_compose_reconcile_waited_out`), and `from`
# is the digest the apply replaced, which the host file no longer holds once
# the file is installed.
_compose_reconcile_begin_tick() {  # <state-dir>
  local fields=""
  compose_reconcile_tick_status=""
  compose_reconcile_tick_reason=""
  compose_reconcile_tick_since=""
  compose_reconcile_tick_from=""
  compose_reconcile_tick_to=""
  compose_reconcile_tick_pending=false
  fields="$(jq -r '[.status // "", .reason // "", .since // "", .from // "", .to // "",
                    (if .pending_apply then "true" else "false" end)] | @tsv' \
    "$1/.compose-reconcile.json" 2>/dev/null || true)"
  [[ -n "$fields" ]] || return 0
  IFS=$'\t' read -r compose_reconcile_tick_status compose_reconcile_tick_reason \
    compose_reconcile_tick_since compose_reconcile_tick_from compose_reconcile_tick_to \
    compose_reconcile_tick_pending <<<"$fields"
  [[ "$compose_reconcile_tick_pending" == "true" ]] || compose_reconcile_tick_pending=false
  return 0
}

# Record the verdict, and log it iff it is a *transition* — a different status,
# or a different reason for the same status. A tick every few minutes must not
# write eight identical deferrals through one long cycle; what a reader needs
# is when the node entered this state and why.
#
# `detail` is recorded but never compared: it is for whatever varies run to
# run — a command's own last line of output — which in `reason` would defeat
# the whole transition test.
#
# Recording and printing are two functions because one tick can write two
# verdicts and must print exactly one: `applying` is recorded before the
# recreate starts, and whatever the recreate returns is what the caller of
# `compose_reconcile_run` reads. The verdict just built is left in
# `compose_reconcile_verdict`, which is the only thing `_compose_reconcile_settle`
# below adds to this.
_compose_reconcile_record() {  # <state-dir> <now> <status> <reason> [pending] [from] [to] [detail]
  local state_dir="$1" now="$2" status="$3" reason="$4" pending="${5:-false}" from="${6:-}" to="${7:-}" detail="${8:-}"
  local marker="$state_dir/.compose-reconcile.json"
  local prev_status="${compose_reconcile_tick_status:-}" prev_reason="${compose_reconcile_tick_reason:-}"
  local since="$now" verdict=""
  compose_reconcile_verdict=""

  # The digests are carried across an unfinished apply exactly as
  # `pending_apply` is, and for the same reason: a lock taken or a roll falling
  # due between the install and the retry must postpone the apply, not forget
  # what it was applying. Without this the `reconciled` verdict that eventually
  # closes such an apply names the installed file as both its `from` and its
  # `to`, and the digest it replaced is gone.
  if [[ "$pending" == "true" && -z "$to" ]]; then
    from="${compose_reconcile_tick_from:-}"
    to="${compose_reconcile_tick_to:-}"
  fi

  # When the node entered this state, as against `at`, which is every tick.
  # The same test the event below makes, and they share it for the same
  # reason: `status` and `reason` are what change when something changes.
  [[ "$status" != "$prev_status" || "$reason" != "$prev_reason" \
     || -z "${compose_reconcile_tick_since:-}" ]] \
    || since="$compose_reconcile_tick_since"

  verdict="$(jq -nc --arg at "$now" --arg since "$since" --arg s "$status" --arg r "$reason" \
    --argjson p "${pending:-false}" --arg from "$from" --arg to "$to" --arg d "$detail" \
    '{status: $s, at: $at, since: $since}
     + (if $r  == "" then {} else {reason: $r} end)
     + (if $d  == "" then {} else {detail: $d} end)
     + (if $to == "" then {} else {from: (if $from == "" then null else $from end), to: $to} end)
     + (if $p then {pending_apply: true} else {} end)' 2>/dev/null)" || return 0
  [[ -n "$verdict" ]] || return 0
  compose_reconcile_verdict="$verdict"

  if [[ -n "$state_dir" && -d "$state_dir" ]]; then
    if printf '%s\n' "$verdict" > "$marker.tmp.$$" 2>/dev/null; then
      mv "$marker.tmp.$$" "$marker" 2>/dev/null || rm -f "$marker.tmp.$$" 2>/dev/null
    else
      rm -f "$marker.tmp.$$" 2>/dev/null
    fi
  fi

  # `in-sync` is the steady state and has no event: a node that is doing
  # nothing because there is nothing to do is not news, and log.jsonl is
  # replicated to every peer.
  [[ "$status" != "in-sync" ]] || return 0
  [[ "$status" != "$prev_status" || "$reason" != "$prev_reason" ]] || return 0
  [[ -n "$state_dir" && -d "$state_dir" ]] || return 0
  # An `applying` the marker already carried into this tick is the same apply
  # being retried, not a second one beginning. The marker says `applying` on
  # every tick that runs a recreate — that is what the pre-update hook reads
  # to keep a roll off a project mid-apply — but the event is the news that
  # one started, and a retry is not news.
  [[ "$status" != "applying" || "${compose_reconcile_tick_pending:-false}" != "true" ]] || return 0

  local event fields
  case "$status" in
    applying)   event=compose-reconcile-applying ;;
    reconciled) event=compose-reconciled ;;
    deferred)   event=compose-reconcile-deferred ;;
    refused)    event=compose-reconcile-refused ;;
    *)          return 0 ;;
  esac
  # `since` is dropped with `at`: an event is only ever written on a transition,
  # which is the one moment the two are equal.
  fields="$(jq -c 'del(.status, .at, .since)' <<<"$verdict" 2>/dev/null || echo '{}')"
  # No cycle id: this runs outside any cycle, in its own container, and a
  # fabricated one would be worse than an honest null — the same discipline
  # scripts/publish-revert-rate.sh's own out-of-cycle rows already keep.
  log_event_append "$state_dir/log.jsonl" cycle "" "${NODE_NAME:-${HOSTNAME:-unknown}}" "$event" "$fields"
}

# _compose_reconcile_record, and then print the verdict it built — what a tick
# ends on, once, whatever path it took to get there.
_compose_reconcile_settle() {  # <state-dir> <now> <status> <reason> [pending] [from] [to] [detail]
  _compose_reconcile_record "$@"
  [[ -n "${compose_reconcile_verdict:-}" ]] || return 0
  printf '%s\n' "$compose_reconcile_verdict"
}
