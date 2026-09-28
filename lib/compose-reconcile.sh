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
#      stand back for as long as a `roll-pending` marker says a watchtower
#      roll is due on this node, so the two updaters never recreate the same
#      container at once;
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
# **`applying` is recorded before the sibling starts.** The verdict used to be
# written only once `up` returned, so an apply that died mid-way left the
# previous verdict standing: the heartbeat still said `deferred`, and a peer
# reading it saw a node merely waiting rather than one stopped half-way
# through recreating itself. The marker is written first instead, carrying
# `pending_apply`, so the state is visible for as long as it lasts and the
# next tick — ordinarily in the container the apply itself replaced — retries
# the recreate and settles it.
#
# Verdicts, one compact JSON object, written to `$state_dir/.compose-
# reconcile.json` and carried to every dashboard in this node's heartbeat
# (IMPLEMENTATION-PIPELINE-SPEC requirement 2.5a):
#
#   {status:"in-sync", at}                  nothing to do
#   {status:"applying", at, from, to,       the file is installed and a
#    pending_apply:true}                    sibling container is recreating
#                                           this project; whichever generation
#                                           of this container ticks next
#                                           finishes the verdict
#   {status:"reconciled", at, from, to}     the file was replaced and the
#                                           project recreated; `from`/`to` are
#                                           the SHA-256 of the old and new file
#   {status:"deferred", at, reason}         a cycle is in flight, a roll is
#                                           due, or the recreate itself failed
#                                           — retried on the next tick in every
#                                           case
#   {status:"refused", at, reason}          the node is not configured for
#                                           reconciliation, or the new file
#                                           needs a `${VAR}` its `.env` does
#                                           not define. Nothing was applied.
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
# stubbed), _DOCKER_SOCKET (what the sibling is given, and whose group the
# sibling is added to) and _NOW.

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

# Print a reason and succeed iff `$state_dir/roll-pending.json` names an
# `until` that has not passed — agent-ops#1096's marker, read from the same
# file the pre-update hook reads and meaning the same thing: this node's last
# cycle boundary found its image behind and yielded, so watchtower is licensed
# to roll this stack at any moment until `until`.
#
# **Read here as a deferral, not as the override it is there.** The hook's
# question is "may this roll destroy a container", and the marker answers yes;
# the question here is "may this tick recreate the whole project", and the
# same marker answers no. Both updaters recreate the same containers, and on
# `ockham-container` on 2026-09-28 they were racing to recreate the same five
# within one second, with nothing surviving to say which stop was whose
# (agent-ops#1913). So the reconciler stands back while a roll is due and
# applies on the first tick after it has landed — `chain_clear_landed_roll_pending`
# removes the marker at the next cycle to reacquire the lock once the image is
# no longer behind, and `until` (`schedule.cycle_interval_minutes`) bounds it
# whatever else happens, so the wait is a cycle interval at worst. The scope
# question the hook has to answer — `lock.json` yes, `review-lock.json` no —
# does not arise here: this defers for either lock anyway, so the marker
# overrides nothing and only ever adds a reason to wait.
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
  printf 'a roll-pending marker from the last cycle boundary is in force until %s' "$until_ts"
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
  project_dir="${COMPOSE_RECONCILE_PROJECT_DIR:-${AGENT_OPS_PROJECT_DIR:-}}"
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
  # here as a reason to wait.
  local roll_due=""
  roll_due="$(compose_reconcile_roll_pending "$state_dir" || true)"
  if [[ -n "$roll_due" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" deferred \
      "a watchtower roll is due on this node ($roll_due) — the recreate waits until it has landed" \
      "$pending_apply"
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
  # The sibling's image is resolved before anything is written: it is the one
  # precondition of the apply that can fail for a reason nothing here can put
  # right, and installing a file this tick cannot then act on only widens the
  # window in which the node runs a compose.yaml none of its containers came
  # from.
  local image=""
  image="$(_compose_reconcile_self_image "$docker_cmd" "$project_dir")"
  if [[ -z "$image" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" deferred \
      "this container cannot identify its own image, so there is no sibling to hand the recreate to — retrying on the next tick" \
      "$pending_apply"
    return 0
  fi

  local from_sha to_sha
  from_sha="$(compose_reconcile_sha "$host_file")"
  to_sha="$(compose_reconcile_sha "$image_file")"

  if [[ "$from_sha" != "$to_sha" ]]; then
    if ! _compose_reconcile_install "$image_file" "$host_file" "$to_sha"; then
      _compose_reconcile_settle "$state_dir" "$now" deferred \
        "could not write $host_file — retrying on the next tick" \
        "$pending_apply"
      return 0
    fi
  fi

  # Recorded, not settled: this tick may not live to write a second verdict,
  # and what a reader must not find in that case is the verdict of the tick
  # before it. `pending_apply` is true from here until a recreate returns 0,
  # which is what has the successor finish what this one started.
  _compose_reconcile_record "$state_dir" "$now" applying \
    "a sibling container is recreating this project from the installed compose.yaml" \
    true "$from_sha" "$to_sha"

  local up_log up_rc=0
  up_log="$(_compose_reconcile_apply "$docker_cmd" "$docker_socket" "$project_dir" "$image" 2>&1)" || up_rc=$?
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
      true "" "" "$(printf '%s' "$up_log" | tail -n 1)"
    return 0
  fi

  # Reached only on a tick whose own container the recreate did not replace —
  # the retry, ordinarily, since the apply that carries a `reconciler` change
  # stops this process at its own service. The tick that does not get here
  # leaves `applying` standing, and its successor settles it.
  _compose_reconcile_settle "$state_dir" "$now" reconciled "" false "$from_sha" "$to_sha"
  return 0
}

# The image this container is running, or the empty string.
#
# Asked of the daemon rather than of this container, because nothing inside a
# container reliably names it: `$HOSTNAME` is the container's short id at
# creation, but watchtower clones `Config.Hostname` forward when it recreates
# one (agent-ops#1072), so after a roll it names a container that no longer
# exists. Compose's own labels do survive that cloning, and the project
# directory — unique to this stack on this host, and already the thing every
# other path here is resolved against — is what picks this stack's reconciler
# out from a neighbouring stack's. `AGENT_OPS_SERVICE` names the service in
# the service's own definition, so the lookup follows a rename that keeps the
# two in step.
#
# The image *id* rather than the reference: it pins the bytes this container
# is actually running, which a moved `:latest` would not, and an image a
# running container holds cannot be pruned out from under the `docker run`.
_compose_reconcile_self_image() {  # <docker> <project-dir>
  local docker_cmd="$1" project_dir="$2" id=""
  id="$("$docker_cmd" ps --quiet --no-trunc \
        --filter "label=com.docker.compose.project.working_dir=$project_dir" \
        --filter "label=com.docker.compose.service=${AGENT_OPS_SERVICE:-reconciler}" \
        2>/dev/null | head -n 1)"
  [[ -n "$id" ]] || return 0
  "$docker_cmd" inspect --format '{{.Image}}' "$id" 2>/dev/null | head -n 1
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
# `TZ: ${TZ:-UTC}`, so a sibling is not free to inherit what a sibling has.
# Cleared instead, so `.env` is the only thing that decides — the same input a
# human's own `docker compose up -d` in that directory reads — and any future
# collision is cleared with it. `PATH` and `HOME` are put back because the two
# are the CLI's own needs, not configuration: one finds the binary, the other
# is where it looks for `config.json`.
#
# `--entrypoint env` steps over the image's own entrypoint at the same time,
# which prepares a node's state volumes and has nothing to do here. No network
# at all, like the service itself: the daemon performs any pull, on the host's
# network. The socket's own group is what lets a uid-1000 sibling open it, read
# off the mounted socket rather than from a variable, so it is this host's real
# `DOCKER_GID` whatever `.env` says. The name is this node's and this moment's,
# so an operator finding the container in `docker ps` knows what it is and two
# stacks on one host cannot collide over it.
_compose_reconcile_apply() {  # <docker> <socket> <project-dir> <image>
  local docker_cmd="$1" socket="$2" project_dir="$3" image="$4"
  local gid name
  local -a group_args=()
  gid="$(stat -c %g "$socket" 2>/dev/null || true)"
  [[ "$gid" =~ ^[0-9]+$ ]] && group_args=(--group-add "$gid")
  name="agent-ops-compose-apply-$(printf '%s' "${NODE_NAME:-node}" | tr -c 'A-Za-z0-9_.-' '-')-$(date -u +%Y%m%dT%H%M%SZ)"
  "$docker_cmd" run --rm \
    --name "$name" \
    --label com.pullwright.agent-ops.compose-apply=true \
    --network none \
    "${group_args[@]}" \
    --entrypoint env \
    --volume "$socket:$socket" \
    --volume "$project_dir:$project_dir" \
    "$image" \
    -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/home/agent \
    docker compose --project-directory "$project_dir" up -d --remove-orphans
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

# Read the marker once, at the top of a tick, into the three things the rest
# of the tick judges itself against.
#
# The dedup baseline has to be taken here rather than re-read per verdict,
# because one tick now writes two: `applying` before the recreate and the
# recreate's own outcome after it. Re-reading would compare the second against
# the first and find a transition every single time — a node whose recreate
# keeps failing would log a pair of events every five minutes into a log
# replicated to every peer, which is the exact trap the transition test exists
# to avoid and which the lock description's own age sprang once already.
# Against the tick's opening state instead, a repeated failure is one event and
# a real change is still one event.
_compose_reconcile_begin_tick() {  # <state-dir>
  local previous=""
  previous="$(cat "$1/.compose-reconcile.json" 2>/dev/null || true)"
  compose_reconcile_tick_status="$(jq -r '.status // ""' <<<"$previous" 2>/dev/null || true)"
  compose_reconcile_tick_reason="$(jq -r '.reason // ""' <<<"$previous" 2>/dev/null || true)"
  compose_reconcile_tick_pending=false
  [[ "$(jq -r '.pending_apply // false' <<<"$previous" 2>/dev/null || echo false)" == "true" ]] \
    && compose_reconcile_tick_pending=true
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
  local verdict=""
  compose_reconcile_verdict=""

  verdict="$(jq -nc --arg at "$now" --arg s "$status" --arg r "$reason" \
    --argjson p "${pending:-false}" --arg from "$from" --arg to "$to" --arg d "$detail" \
    '{status: $s, at: $at}
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
  fields="$(jq -c 'del(.status, .at)' <<<"$verdict" 2>/dev/null || echo '{}')"
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
