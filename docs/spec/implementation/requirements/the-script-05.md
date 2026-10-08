## Requirements

### The Script — requirements, continued (part 5 of 10; 2.5a–3a: Compose reconciliation…)

2.5a. **Compose reconciliation.** A node's `compose.yaml` lives on that node's
   host, and no image roll can replace it: watchtower recreates a container
   from the *old* container's `Config`, so a label, a service's environment,
   a mount or a whole new service merged to `main` reaches a node only when
   something on that host runs `docker compose up -d`. Requirement 2.5's
   `compose` verdict reports that gap and is all it does. The `reconciler`
   service (`deploy/docker/compose.yaml`, profile `auto-update`, the same
   image, `network_mode: none`) closes it: `supercronic` runs
   `scripts/reconcile-compose.sh` every five minutes from
   `deploy/docker/reconcile-crontab`, and `lib/compose-reconcile.sh` holds
   what it decides. No model is in that path and none can be — the file it
   installs is the one the image shipped, byte for byte, and the only
   judgement taken is whether now is a safe moment to install it.

   A tick does nothing at all unless `lib/compose-drift.sh` reports drift —
   the same library requirement 2.5's own verdict comes from, so the actor and
   the alarm cannot disagree about what drift is. It reads the node's copy
   through the project directory bind-mounted at the absolute path it has on
   the host (`AGENT_OPS_PROJECT_DIR` in `.env`, the mount on both sides of
   that service): the same path on both sides is what makes the file's own
   relative bind sources (`./compose.yaml`, `./ts-serve.json`) resolve
   identically for the Compose CLI inside the container and for the daemon
   outside it. That copy is the one thing in the directory this container
   reads itself, so it needs read access to `compose.yaml` and to nothing
   else there — a `compose.yaml` it cannot read is `refused`, naming the
   file's owner and mode and the quoted `chmod` to run — and an `in-sync`
   node depends on nothing beyond it. On drift, in order:

   - **This container is named to the daemon first** (the lookup described
     under the sibling below), because the `.env` gate and the apply both go
     through its own mounts by its id. A lookup that comes up empty is
     `deferred` and reads and installs nothing.

   - **Every `${VAR}` the new file requires must be a key in this node's
     `.env`.** Required means the braced forms with no default and no
     alternate — `${VAR}`, `${VAR:?…}`, `${VAR?…}`; `${VAR:-…}`, `${VAR-…}`,
     `${VAR:+…}` and `${VAR+…}` are not, compose's `$$` escape is not a
     reference at all, and whole-line comments are stripped first (through
     the identical filter `lib/compose-drift.sh` applies), since compose
     parses YAML before it interpolates and a comment is gone by then. Bare
     `$VAR` is deliberately not scanned for: this file does not use it, and a
     scan loose enough to catch it reads the shell fragments in a surviving
     comment as node configuration. One missing name refuses the whole apply,
     records which name, and changes nothing — compose would otherwise
     interpolate an empty string and deploy it. `.env` is never written and
     its values are never read: the scan keeps the key name and discards
     everything after the `=`. It is read **through the daemon**,
     `docker cp` from this container's own mount of it, so an `.env` root
     owns at mode 0600 — the one `cloud-init.yaml` writes — needs no access
     of this container's own and nobody on the host has to widen access to
     it. No `.env` at all is the empty key set; one that exists and cannot
     be fetched is `deferred`, because an empty key set would refuse for
     every `${VAR}` in the file and send its reader to the wrong file.
   - **`lock.json` and `review-lock.json` defer it, exactly as they defer a
     roll** (`deploy/docker/watchtower-pre-update.sh`), bounded by the same
     `lock_stale_after` and `repository_review.lock_stale_after`, and judged by
     that hook's *foreign* rule alone: this container writes neither lock and
     shares no PID namespace with whatever did, so every lock is honoured
     without a liveness check until it is released or goes stale.
     `roll-pending.json` (requirement 39c (Finish-then-continue)) defers it as well, and on its own,
     and is read *before* either lock: the marker the pre-update hook reads as
     licence to destroy a container is read here as a reason to wait, because
     watchtower and this actor recreate the same containers and must never be
     doing so at once. The scope question the hook has to answer — `lock.json`
     yes, `review-lock.json` no — does not arise, since either lock defers
     this anyway. An `until` that will not parse reads as epoch 0, so a
     corrupt marker holds nothing back.

     **That wait is bounded by this node's own patience and not by the
     marker.** `chain_write_roll_pending` re-arms the marker at every cycle
     boundary whose image still reads `behind`, and
     `chain_clear_landed_roll_pending` leaves it alone while that is true
     (requirement 39c (Finish-then-continue)), so a node whose roll cannot land — watchtower
     crash-looping, a registry it cannot reach — carries a live marker for as
     long as the condition lasts, and a deferral that followed the marker and
     nothing else would leave that node running a `compose.yaml` none of its
     containers came from for exactly as long, up to and including the merged
     file that would end it. The deferral therefore holds only while it is
     younger than `lock_stale_after`, measured from the verdict's own `since`
     — the same bound a cycle lock gets and for the same reason: a signal this
     pipeline would no longer honour about its own cycles is not one to honour
     about a roll. Past it the apply goes ahead, and the sibling's name is what
     keeps two recreates apart if the roll does land in the middle. The
     marker's `until` moves forward with every re-arming, so it is recorded in
     `detail` and never in `reason`, which would otherwise make each cycle
     boundary a fresh transition and reset the very timestamp the bound is
     measured from. What that timestamp measures is a *continuous* roll
     deferral: a lock taken in between has the tick report the lock instead,
     which resets `since` and restarts this clock. That costs nothing, because
     a tick that finds a lock held defers whatever the roll marker says — the
     marker is not what holds the apply back in that window, and this bound is
     only ever about the marker.
   - **Then the image's copy is written over the node's, in place, and
     `docker compose up -d --remove-orphans` is run for that project
     directory — both from a transient sibling container running as root,
     never from this one.**
     In place — the existing inode truncated and rewritten from
     a copy staged beside it and verified byte-for-byte first — because a
     bind mount of a *file* pins the inode it was created against: a rename
     would leave every container the recreate did not touch mounting the old
     content, reporting drift for ever with nothing left to reconcile.

     From a sibling because `reconciler` is a service of the very project the
     `up` recreates, and on a real apply it is always one of the services that
     changed: the compose change that drifted arrives on the same image roll
     that carries it. Compose recreates a container by creating its
     replacement, stopping the old one, removing it and renaming the new one,
     and only then starting everything in dependency order — so an `up` driven
     from inside this container reaches its own service, stops the process
     driving it and dies there, leaving the project stopped or
     created-but-never-started, with `restart: unless-stopped` no help because
     an explicit stop cancels the restart and a container that was never
     started has no restart to resume. That is what took `ockham-container`'s
     whole stack down on 2026-09-28, on the first real apply anywhere on the
     fleet (agent-ops#1913). The sibling is a `docker run --rm` of the image
     *this container is running*, `--network none`, `--sig-proxy=false` so a
     signal delivered to the attached client cannot abort a recreate half-way,
     and `--user 0` — the shape watchtower uses to update itself. As root it
     can write a stack directory and read an `.env` that root owns, which the
     install and Compose's own interpolation both need, and it gains nothing
     by it: a process holding the Docker socket is root on the host by
     another name. The install is the same function this library defines,
     sourced in the same image, run immediately before the `up`; an install
     that fails exits with a status of its own, so the verdict can say which
     of the two did not happen, and is `deferred` with `pending_apply`. Its
     mounts are this
     container's own, by `--volumes-from`: the three it needs are the three
     this service already has and no others — the socket, the project
     directory at the absolute path it has on the host, and the state volume —
     and a named volume cannot be asked for by path from inside the container
     holding it, the path being a mount destination and not a place on the
     host at all. Its ceilings are this container's own too, read back from
     the daemon rather than from `AGENT_OPS_RECONCILER_MEMORY` and its
     siblings, which Compose interpolates at deploy time and which reach no
     container's environment: every service in that file is bounded because an
     unbounded container on a small host takes the host down, and a
     `docker run` inherits none of it. Its command is
     `env -i PATH=… HOME=… DOCKER_HOST=… docker compose …`, which steps over the image's
     own entrypoint (a node's state-volume preparation, irrelevant here) and,
     more importantly, **clears the environment Compose interpolates from**:
     Compose resolves a `${VAR}` from the process environment ahead of the
     project's `.env`, and this image's own `ENV` sets `TZ`, which
     `compose.yaml` interpolates — so a sibling holding the image's
     environment would deploy every service with the image's `TZ` however the
     node's `.env` is written, moving the hour that node's cron fires, on an
     apply whose whole claim is to install the merged file byte for byte. The
     container this library runs in escapes that only because its own service
     declares `TZ: ${TZ:-UTC}`. Cleared, the node's `.env` is the only input
     interpolation has — the same input a human's own `docker compose up -d`
     in that directory reads — and any later collision between an image `ENV`
     and a compose variable is cleared with it. `PATH` and `HOME` are put back
     because they are the CLI's own needs and not configuration: one finds the
     binary, the other is where it looks for `config.json`. `DOCKER_HOST` is
     put back for the same reason and to close the same kind of gap: cleared,
     the CLI inside falls back to `/var/run/docker.sock` however the socket
     was actually mounted, so naming it is what keeps the mount and the client
     from disagreeing about where the daemon is.

     What the sibling prints is written to `$state_dir/compose-apply.log` from
     inside it, through the state volume it inherits, and echoed to the
     attached client. On the apply that replaces `reconciler` there is nowhere
     else for it to go: the process capturing it is one of the ones the apply
     stops, and `--rm` takes the sibling's own daemon-side log away with the
     container. The file holds the most recent apply alone, opened by a header
     line this side writes before the sibling starts — it is local diagnostics
     on a node whose disk this must not fill, it is excluded from replication
     for the same reason `.compose-reconcile.json` is, the event log already
     records *that* an apply failed, and the failing run's last line rides in
     the verdict's `detail`.

     It carries no Compose labels, so `--remove-orphans` cannot
     see it. **Its name is `agent-ops-compose-apply-<node>`, and that name is
     the mutex**: the `up` starts this container's replacement before the
     sibling has finished, that replacement's own first tick can fall due
     seconds later and will read `pending_apply` and want a recreate of its
     own, and two `docker compose up -d` runs against one project take no lock
     against each other. The tick that finds the sibling still running settles
     on `applying` and never asks for a second apply at all; a fixed name per
     node is the backstop under that check, having the daemon refuse the
     second (`name is already in use`) if one is ever asked for between the
     two. `--rm` is what keeps the name free, held for exactly as long as an
     apply runs. One left behind would defer every apply with that same
     message until it was removed — loud, and in the verdict, which is the
     failure to prefer. Per
     *node* rather than per host, so two stacks on one host neither collide nor
     serialise against each other. It is run attached: the tick whose own
     container the recreate does not replace reads the exit status directly,
     and the tick whose container it does replace dies there while the sibling
     runs to completion.

     The container and its image are asked of the daemon, by Compose's own
     `com.docker.compose.project.working_dir` and
     `com.docker.compose.service` labels on this stack's project directory,
     and the image is taken as an *id* rather than a reference. The directory
     is matched as Compose cleaned it before writing it — `filepath.Abs`
     collapses `//`, `/./` and `..` and drops a trailing slash — so a node
     whose `.env` reads `AGENT_OPS_PROJECT_DIR=/srv/agent-ops/` runs and is
     found, rather than deferring on every tick with a reason pointing at the
     daemon instead of at one line of `.env`. Nothing inside the
     container can answer instead: `$HOSTNAME` is the container's short id at
     creation, but watchtower clones `Config.Hostname` forward when it
     recreates one (agent-ops#1072), so after a roll it names a container that
     no longer exists. A lookup that comes up empty is a `deferred` verdict
     that installs nothing — there is no sibling to hand the recreate to, and
     the one thing that must not follow is running it here after all.

   The verdict is `$state_dir/.compose-reconcile.json`: `in-sync`,
   `applying` (an apply is in flight and a sibling is recreating the project),
   `reconciled` (carrying the SHA-256 of both files), `deferred` (a lock, a
   roll falling due, a container the daemon cannot name, an `.env` it could
   not fetch, or an install or a recreate that failed) or `refused` (no
   project directory, no `compose.yaml` in it or one this container cannot
   read, no copy in the image, or a missing `${VAR}`). Every verdict carries
   `at`, the
   time this tick wrote it, and `since`, the `at` of the last tick whose
   `status` or `reason` differed from the tick before — when the node entered
   the state rather than when it last confirmed it, which is what "how long
   has this been going on" needs and what the roll-pending bound above is
   measured from. A `since` read back that is not a timestamp of the shape
   this library writes is treated as absent, so the next verdict starts its
   clock afresh rather than carrying the value forward. The marker is read
   one field per line, with `reason`, the one free-text field, last and
   verbatim, so a newline in it cannot cost the marker `pending_apply`. It
   is local to the node and excluded from replication like
   `.stage-health.json`, and the verdict alone travels, folded into
   `heartbeat.json` as `compose_reconcile` beside the `compose` drift verdict
   it acts on (requirement 2.5; rendered on every dashboard's fleet strip,
   `docs/spec/dashboard/site.md`).

   **The verdict is read back for the host by the same library.**
   `scripts/reconcile-compose.sh --audit` runs no tick; it prints one
   `<class> <message>` line per finding (`ok`, `bad`, `info` or `unable`), and
   is what `scripts/check-node-compose.sh` (component 12) asks, so the host
   needs neither `jq` nor the marker's path. It reports whether the daemon
   can name this container by its project directory — a stack brought up
   through another spelling of that directory, such as a symlink to it,
   fails that lookup on every apply with nothing else wrong, and the finding
   names the directory the stack was brought up from and the quoted `cd` and
   `up` that fix it — and then judges the verdict. `in-sync` and `reconciled`
   are `ok`; `refused` is `bad`; a deferral for a lock or a due roll is
   `info` until it has stood, by its `since`, longer than the larger of the
   two `lock_stale_after` bounds, which is longer than any wait this library
   honours, and every other deferral is `bad` at once; `applying` is `info`
   until it has stood that long. Whatever the status, a verdict whose `at` is
   more than four ticks old is `bad`, because the schedule has stopped, and
   one that cannot be parsed or carries no `at` is `bad`; no verdict at all is
   `unable`, unless the container has been up for four ticks already.

   **`applying` is recorded before the file is installed, carries
   `pending_apply`, and stands for as long as the sibling runs.** A verdict
   written only once `up` returns is one a tick that dies mid-apply never
   writes, which leaves the verdict of the tick before it standing: a peer
   reading the heartbeat sees a node merely waiting rather than one stopped
   half-way through recreating itself. Before the *install*, because the gap
   between installing the file and recording the intention is the one moment
   in which drift reads in-sync and nothing is left asking for a recreate: a
   tick killed in it leaves every container running a `compose.yaml` it was
   not created from, with the marker saying the node is idle. A tick killed
   the other side of that record simply installs on the next one.

   For as long as the sibling runs, because this marker is also what the
   pre-update hook above reads to keep a roll off a project mid-apply. A tick
   that finds a container matching the apply's own name and label alive
   rewrites `applying` with a fresh `at` and settles there, ahead of the locks,
   the roll marker and the drift check alike — any other verdict would clear
   that guard in the middle of the recreate it exists to protect, and
   watchtower's next poll is five minutes away at most. The marker therefore
   tracks the apply's real duration, and the hook's own ten-minute freshness
   window is the backstop under a reconciler that never came back rather than
   the mechanism itself.

   `pending_apply` stays on every verdict from that moment until a recreate
   actually returns 0 — deferrals and refusals included — and is what makes
   the next tick retry the recreate rather than the drift check: the file is
   installed before the recreate runs, so from that moment drift alone would
   never ask again, and a lock taken or a roll falling due in between must
   postpone that retry, never discard it. `from` and `to` are carried across
   those deferrals with it, because once the file is installed the host copy no
   longer holds the digest the apply replaced and the `reconciled` verdict that
   finally closes the apply would otherwise name the installed file twice.
   Ordinarily the tick that retries is running in the container the apply
   itself created.

   Transitions — a status, or a reason, that differs from the one the marker
   held **at the start of this tick**, which is also what sets `since` — append
   `compose-reconcile-applying`, `compose-reconciled`,
   `compose-reconcile-deferred` or `compose-reconcile-refused` to `log.jsonl`
   through `lib/log-event.sh`'s envelope with `cycle: null`; an unchanged
   verdict appends nothing, and `in-sync` never appends at all. At the start
   of the tick, not re-read per verdict, because one tick writes two: comparing
   the second against the first would find a transition every time, and a node
   whose recreate kept failing would log a pair of events every five minutes
   into a log replicated to every peer. For the same reason `applying` is
   logged only when the tick began with no apply outstanding: the marker says
   it on every tick that runs a recreate, because that is what the hook reads,
   but a retry of an apply already pending is the same apply and is not news.
   **Only `status` and `reason` are compared** for that test, and both are
   stable while the state is: a deferral's reason names the lock, the container
   that wrote it and when, and carries no age, and a failed recreate's reason
   names the exit status alone. Anything that varies run to run — the
   recreate's own last line of output — is recorded beside them in `detail`,
   which is never compared, because in `reason` it would make every tick of a
   long deferral a fresh transition.

   **One thing it does not do.** It does not close the window between reading
   the lock and Compose stopping a container: a cycle that starts inside those
   few seconds dies with the recreate, exactly as it would under the manual
   ritual, and what makes that rare rather than routine is that this runs
   every five minutes and defers on every tick that finds the lock held, so it
   lands in an idle window rather than a chosen one.

   **Delivery.** The reconciler is itself compose-level, so it reaches an
   existing node the one way anything compose-level does: one last
   `docker compose up -d` on that host, with `AGENT_OPS_PROJECT_DIR` set
   (`deploy/docker/README.md`, `deploy/docker/.env.example`).
   `deploy/docker/cloud-init.yaml` sets that variable, and this host's
   `DOCKER_GID`, on a node it provisions, so a node built from it needs no
   such visit. A node without the service keeps the `compose drifted` badge
   and the manual ritual, and nothing else about it changes. The Kubernetes
   target (`deploy/kubernetes/`) needs none of this: a pod's spec is applied
   by the cluster from the manifest it is reconciled against, so there is no
   host-held deployment file to fall behind in the first place.

   **What the Docker socket costs.** This is the first container in the stack
   to hold that socket read-write, which is root on the host by another name,
   and the same grant `watchtower` has held since the stack existed
   (`collector` holds it read-only). Three things bound it: the service takes
   neither shared anchor, so it carries no `GH_TOKEN`, no `ANTHROPIC_API_KEY`
   and neither App's private key — the container that can create containers
   holds no credential, and the containers holding credentials cannot reach
   the socket; it is `network_mode: none`, so nothing it reads has a route
   out; and it runs one fixed script from the image, on a schedule from the
   image, over a file from the image. What they do not bound is the image
   itself: whoever controls what CI publishes already controls the scheduler's
   credentials by the roll that delivers it, and now also controls this host's
   daemon. That is a real widening and it is the price of the feature,
   accepted on the same terms as watchtower's own socket. D24's staged
   containment is of untrusted *content* reaching a stage; it does not speak
   to the image supply chain, and this does not change that.
2.6. **Log rotation.** Requirement 2.5 bounds the *records* in `state_dir` —
   `cycles/` and `reviews/` are pruned on every push — but its logs are
   appended to forever otherwise. `scripts/rotate-logs.sh`, on its own
   crontab line independent of the pipelines, bounds eight of them:
   `dashboard.log`, `state-sync.log`, `doctor.log`, `revert-rate.log`,
   `tech-debt-archive.log`, `wake-poll.log`, `cron.log` and
   `review-cron.log`. Each is renamed to `<name>.1` (an existing `.1` first
   shifts to `.2`, and so
   on) once it reaches `log_retained_bytes`, keeping the newest
   `log_generations` generations; a fresh, empty file replaces it
   immediately, so nothing is ever left missing. A plain rename is enough —
   every writer here reopens the file by name on each append (`>>"$log"` per
   cron invocation), so no process holds a descriptor across the rotation
   and `copytruncate` is not needed. `log.jsonl`, `review-log.jsonl` and
   `revert-rate.jsonl` (requirement 2.6b) are never rotated: the union
   readers (blocked/void extraction, the no-op fingerprint, the usage-limit
   cooldown, the revert-rate dashboard panel) scan them whole, and dropping
   their head would silently change what the Co-Ordinator believes has been
   tried, or which node's revert-rate row is newest. Because `cron.log` is
   published to the node's state branch
   (requirement 2.5) and its tail is rendered on the dashboard (the
   `docs/spec/dashboard/site.md` cron panel), `scripts/publish-dashboard.sh` reads
   `cron.log.1` too whenever the live file alone is shorter than the tail
   window, so a rotation never empties the panel. `doctor.log` (requirement
   2.6a), `revert-rate.log` (requirement 2.6b) and `tech-debt-archive.log`
   (requirement 2.6c) are bounded here on size alone, like `dashboard.log`
   and `state-sync.log`: all three are local to the node and excluded from
   the state branch. The dashboard reads `doctor.log`'s and
   `revert-rate.log`'s structured siblings (`.doctor-status.json`,
   `revert-rate.jsonl`) instead of either text file, so nothing needs
   either one's tail kept across a rotation; `tech-debt-archive.log` has no
   such sibling at all — nothing reads it back, on this node or any other,
   since what it publishes lands directly in the state repository's own
   `tech-debt-archive/` tree, so it is rotated purely to keep the file
   itself from growing unbounded. `.doctor-status.json` itself is not in
   this rotation set at all — each unattended pass overwrites it in place
   (`mv -f` over the previous run), so it never grows.
2.6a. **The unattended doctor pass** (agent-ops#543). `scripts/doctor.sh
   --unattended`, on its own hourly crontab line, runs unprompted the same
   configuration and GitHub checks requirement 1b's acceptance check 1m
   covers for an operator running the command by hand — `issue_priority_options_complete`
   above all: the `Priority` field gap the Refiner's triage duty
   (requirement 39g) depends on shows up only against a live repository, and
   nobody would otherwise see it between one operator-invoked pass and the
   next. It is a new flag, not `--offline` with its meaning stretched: the
   cut here is by *cost*, not by network. The whole Configuration section and
   the whole GitHub section run — every call there is a GET doctor.sh already
   declares safe against a live node — and only the two checks that spend are
   skipped, each with its own reason distinct from `--offline`'s: the Claude
   credentials check (no credential is read) and the stream-flushing probe
   (no model call is made). The crontab line's own minute is
   `schedule.doctor_offset_minutes` past the node's base cycle minute (mod
   60, 44 by default) — the same per-node jitter requirement 2.5's review
   line uses, keeping a fleet of nodes off the same GitHub-API minute. A
   `fail` verdict exits 1, which the crontab line swallows (`|| true`):
   nothing on the image reads a cron job's exit status, and the alternative —
   supercronic's own "job failed" log line, once an hour, for a routine
   configuration warning — would read as a crashed script to an operator
   tailing `docker compose logs`. The run's actual verdict travels a
   different way: at the end of a completed run (never from one of the
   argument- or config-unusable exits near the top of the script, which bail
   before `state_dir` is even resolved) it writes
   `state_dir/.doctor-status.json` — `{timestamp, verdict, fails[], warns[],
   skips, token_expiry}`, `verdict` the worst of `fail`/`warn`/`ok` —
   atomically (`mktemp` then `mv -f`), the third declared exception to
   doctor.sh's read-only rule alongside the state/workspace directories and
   the trial crontab render. `scripts/publish-dashboard.sh` reads this file
   rather than re-running the pass itself — the GitHub section alone is
   several calls per configured repository, too much to repeat on the
   dashboard's own 5-minute heartbeat — and surfaces it as `status.doctor`
   (`docs/spec/dashboard/site.md`), local to this node only: nothing here
   replicates it to peers, unlike the compose/image/switch verdicts the
   fleet heartbeat carries. `doctor.log` (requirement 2.6) keeps the run's
   own text output, rotated on size like `dashboard.log`;
   `.doctor-status.json` is excluded from the state branch (requirement 2.5)
   alongside the dashboard's own local caches, since nothing but this node's
   own Publisher ever reads it.

   `token_expiry` — `{expires_at, days_remaining} | null` — is the
   PAT-expiry warning (requirement 2.7a, agent-ops#694): read
   from the same GitHub section, the same free `/rate_limit` call requirement
   2.0 already reads, `--include`d for the `GitHub-Authentication-Token-
   Expiration` response header GitHub states on every authenticated request.
   `null` when that header is absent (an installation token, or any other
   credential GitHub states no expiry for) — never a warning or
   a failure, since an absent header says nothing about the token's health.
2.6b. **The revert-rate publishing tick** (D18 issue #579, a WI of umbrella
   #402). `scripts/publish-revert-rate.sh`, on its own daily crontab line,
   runs `scripts/mine-merge-history.sh` unprompted so Stage 2's exit
   criterion ("revert rate ≤ baseline") is measured continuously rather than
   only when a promotion review remembers to run the miner by hand — the
   Stage 0 baseline it exists to compare against was itself produced once,
   on 2026-08-15, and had not run again until this component. `scripts/mine-merge-
   history.sh` gained a `--since ISO8601` flag for this caller alone: it
   bounds the mined population to pull requests merged at or after that
   instant, both as the REST `since` query parameter (which narrows the
   pages fetched, on GitHub's own "last updated after" semantics) and as an
   exact `merged_at` filter afterwards (which is what actually bounds the
   population) — without it, a caller meant to run daily would re-mine each
   configured repository's entire merge history on every tick.

   Per repository, three `--since`-bounded mining passes compute three
   figures: **rolling** — merged pull requests in the last
   `--window-days` (14 default) excluding the last 48 hours (whose own
   48-hour post-merge observation window has not yet elapsed), floored at
   `--min-samples` (10) before a rate is published at all — computed as the
   arithmetic difference between a 14-day-bounded pass and a 48-hour-bounded
   pass, which is exact rather than approximate: any pull request an outcome
   check could classify as a revert or follow-up of one merged within the
   last 48 hours must itself have merged within the last 48 hours too (it
   merges after the original, and no later than "now"), so every partner a
   14-day pass could find for such a pull request is already present in the
   48-hour pass, and the two passes agree on its classification — the
   subtraction removes exactly the still-unsettled population, nothing more
   and nothing less; **cumulative-since-baseline** — every merged pull
   request since `revert_rate_baseline.generated`, unfiltered, which is what
   this criterion itself compares against the baseline (both all-population
   aggregates, measured the same way; see below for how this figure is
   computed without re-mining that whole population on every tick); and
   **baseline** — the stored Stage 0 figures (`revert_rate_baseline` — see
   Configuration), copied in once
   rather than re-derived at runtime the way `scripts/autonomy-stage-
   report.sh` (component 22, issue #571, out of this component's scope)
   still does for its own one-off comparison by scanning `docs/reviews/` —
   nothing here reads that directory. A repository absent from
   `revert_rate_baseline.repos`, or the whole key absent, publishes its
   rolling figure unaffected and reads baseline (and, absent the whole key,
   cumulative too) `null` throughout, rather than failing the run.

   **Bounding the cumulative-since-baseline pass** (TD-PPagop-26082204): a
   fixed `--since` bound that never advances would otherwise re-mine every
   labelled pull request merged since the baseline, from scratch, on every
   tick, forever — an unbounded and ever-growing cost, unlike the rolling and
   recent passes above, whose own `--since` bound is always "now minus a
   fixed offset". Instead, each node caches the *settled* portion of that
   population — merged more than 48 hours ago, whose post-merge outcome
   (revert or follow-up fix) cannot change again, "Post-merge outcome" in
   `scripts/mine-merge-history.sh`'s own header — per repository, in
   `<state_dir>/revert-rate-cumulative-state.json`: the settled aggregate
   itself (`{count, post_merge: {reverts, follow_up_fixes}}`), the
   `settled_until` instant it is settled as of, and the `baseline_since` it
   was computed against. A run with no usable cached entry for a repository
   (new to this node, or the configured baseline has moved since the entry
   was written) falls back to one full `--since revert_rate_baseline.generated`
   pass, exactly as every run used to — the one place this pass is
   still unbounded, and only once per repository per node — and seeds the
   cache from it (that pass's own result, minus the still-unsettled tail the
   recent pass above already mined, becomes the new settled aggregate). A run
   with a usable entry instead mines only the delta since that entry's own
   `settled_until`, subtracts out the still-unsettled tail the same way (the
   recent pass mined at the new `since_recent` bound, reused at no extra API
   cost), and adds what remains — now-settled pull requests merged between
   the old `settled_until` and the new one — into the cached aggregate. This
   is the rolling figure's own "since subtraction" argument again, with
   `settled_until`/`since_recent` standing in for the 14-day/48-hour pair: any
   pull request an outcome check could classify as a revert or follow-up of
   one merged since the old `settled_until` must itself have merged since
   that same instant too, so the delta pass finds every partner the rolling
   figure's own recent pass would, and the subtraction removes exactly the
   still-unsettled population. Published `cumulative` is always the rolled-
   forward settled aggregate plus the recent pass's own tail — the same
   figure a full re-mine would give, never an approximation of it. The cache
   is this node's own local memoisation, not fleet data: it is excluded from
   the state branch (requirement 2.5) the same way `.doctor-status.json` is,
   and a repository with no configured baseline (`baseline_since` empty)
   neither reads nor writes an entry for it.

   Every mining pass reads GitHub through `scripts/mine-merge-history.sh`'s
   own `lib/github-limit.sh` wrapper and `gh_retry`, so the fleet-wide rate
   limit and a transient network failure are both handled there, not
   reimplemented here: a repository whose passes still fail after those
   retries is skipped for the run (no row published for it, logged why on
   stderr) rather than a fabricated figure, and the run itself exits
   non-zero — the crontab line's own `|| true` keeps a partial run from
   reading as a crashed script in `cron.log`, the same reasoning 2.6a's
   `doctor.sh --unattended` line uses.

   One JSON line per repository is appended to `revert-rate.jsonl` in
   `state_dir` — envelope `{ts, node, event, repo, window_days, rolling,
   cumulative, baseline, above_baseline}`, `above_baseline` comparing
   cumulative against baseline (`null` when either is unavailable). Unlike
   `.doctor-status.json`, this file is fleet-wide data, on the identical
   terms as `log.jsonl`: never rotated (requirement 2.6), not excluded from
   the state branch (requirement 2.5), read back through `lib/fleet.sh`'s
   `fleet_logs` union rather than verbatim off one node's own copy. The
   crontab line's own minute is `schedule.revert_rate_offset_minutes` past
   the node's base cycle minute (mod 60, 51 by default), at
   `schedule.revert_rate_hour` (2 by default) — the same per-node jitter
   2.6a's doctor line uses, but daily rather than hourly, keeping this
   node's several scheduled passes off the same GitHub-API minute.
   `scripts/publish-dashboard.sh` reads the union and surfaces it as
   `revert_rate` (`docs/spec/dashboard/site.md`, "Revert rate by repository"),
   reduced to the newest row per repository across every node.
2.6c. **The tech-debt archive publishing tick** (D15 as revised, issue #878,
   following #869/#875/#879). `scripts/publish-tech-debt-archive.sh`, on its
   own daily crontab line, mirrors every `pw::type:tech-debt`-labelled issue,
   per configured repository, into the state repository (`state_repo`) as
   one JSON file per issue under `tech-debt-archive/<owner>/<repo>/
   <number>.json` — `{number, title, state, state_reason, author, labels,
   created_at, updated_at, closed_at, body}`, read straight off the label
   search below. The working store (a GitHub issue) is mutable and its
   membership of the `pw::type:tech-debt` band can change or vanish at any
   time — an edit, a close, a relabel, a delete — so this mirror's guarantee
   lives in the state repository's own git history rather than in the file's
   current content: every write here is a commit on `main`, and this script
   never deletes a file, so an issue that is later edited, closed, deleted or
   relabelled away still has its last-archived state on record, on the
   identical durability terms `claims/` (requirement 17a) and `fleet/*.json`
   (requirements 2.1 and 2.3a) already rely on.

   **Placement (D14).** A GitHub Actions workflow was rejected as needing its
   own cross-repo credential for `state_repo` — a component paying for a
   capability every node already has through its own `gh` login — and riding
   `scripts/publish-dashboard.sh`'s 5-minute heartbeat was rejected the other
   way: that cadence exists so the dashboard's own panels stay near-live, and
   tech-debt volume does not move anywhere near that fast. A once-a-day
   cadence, on its own crontab line exactly like `scripts/publish-revert-
   rate.sh`'s (requirement 2.6b), costs this node nothing between runs and
   needs no new secret.

   **Budgeting the API cost.** Two listings per configured repository,
   whatever the archive's size: one label search — `GET /repos/{slug}/
   issues?labels=pw::type:tech-debt&state=all`, paginated, which doubles as
   the empty-body audit's own source (no separate call, since the search
   already returns each issue's body) — and one open-pull-request listing,
   for the legacy-filing audit below. Past those two, every further call is
   bounded by what changed, never by how much debt exists: a per-repository
   memo of each issue's last-seen `updated_at`
   (`tech-debt-archive/<owner>/<repo>/_index.json`, itself one more GET)
   decides which issues are unchanged since the last run and skips them
   outright. An issue whose `updated_at` moved costs one GET (the archive
   file's current blob `sha`, needed for the contents API's optimistic
   concurrency — absent when the file is new) and one PUT; the index itself
   costs one further PUT, only when at least one issue changed.

   **The audits**, both logged and neither fixed here — this script only
   ever writes into `state_repo`, never into a target repository:

   - an empty body on a `pw::type:tech-debt` issue is a data-quality defect
     in the working store itself, read off the label search with no extra
     call;
   - an open pull request whose head branch starts with
     `TECHDEBT_RECORD_BRANCH_PREFIX` (`td-record/`, `lib/tech-debt-file.sh`)
     is a debt record filed the pre-migration way —
     `techdebt_file_debt`'s own former `tech-debt/<id>.md`-on-a-branch shape,
     retired by agent-ops#874, never labelled `pw::type:tech-debt` by
     construction — and is therefore invisible to the label search above
     regardless of whether the filing itself succeeded; flagging it is what
     gives an operator visibility into a filing predating that migration
     which this archive cannot mirror, until a human resolves the pull
     request itself.

   Exit status is 0 iff every configured repository's label search and
   archive writes succeeded; 1 if any repository's search failed or any
   individual write failed — a failed write's issue keeps its old
   `updated_at` in the index, so it is picked up and retried again on the
   next scheduled run rather than being fabricated or silently dropped. The
   crontab line's own `|| true` keeps a partial run from reading as a
   crashed script, the same reasoning 2.6b's own line uses.
2.6d. **Analytics retention** (D21, agent-ops#598). `log.jsonl` and
   `review-log.jsonl` already carry every analytics record this pipeline
   produces — the per-stage metering record (requirement 33a,
   `docs/METERING-SCHEMA.md`), the rework record (requirement 47,
   `docs/FLOW-SCHEMA.md`) and the item-scoped events the item-lifecycle fold
   reads (requirement 49, `docs/FLOW-SCHEMA.md`) — and requirement 2.6
   already excludes both files from `scripts/rotate-logs.sh`'s size-based
   rotation, for its own stated reason: the union readers scan them whole.
   `analytics_retained_days` states that exclusion as a consequence of a
   stated policy rather than a side effect of a different rule: these two
   files' analytics content is retained for `analytics_retained_days` days,
   independent of any transcript rotation or pruning — `0` (the default)
   means retained indefinitely, which is today's behaviour, unchanged. No
   pruner in this codebase may remove an analytics record inside that
   window: requirement 2.5's `state-sync.sh` push already prunes only
   `cycles/` and `reviews/`, directories neither file lives in, and
   requirement 2.6's rotation already excludes both by name — both are
   therefore already-conforming consequences of this policy rather than
   independent decisions that happen to agree with it, and a future
   compaction of either file has this requirement as the one place to
   consult before removing anything. Where the records eventually live, and
   what a non-zero `analytics_retained_days` should actually be once an
   installation wants less than indefinite retention, are open questions of
   their own (`docs/ROADMAP.md`'s D21 open-questions table, priced under
   D14) — this requirement states the contract, not the number, and
   enforcing it (actually expiring anything) is future work this key does
   not yet perform.

   **De-duplication.** A record two or more nodes might independently
   produce for the same real-world occurrence — a claim race today, or,
   going forward, any record derived by folding the fleet-wide union rather
   than emitted once by the process that observed it — must never be
   counted twice merely because more than one node holds a copy.
   `docs/FLOW-SCHEMA.md`'s "Do not double-count" already states and tests
   this for the rework record, reducing first-wins-by-`ts` on `{repo, item,
   class}` (`{…, evidence.by}` for `post-merge-revert`). This requirement
   generalises that property to bind every analytics record this policy
   retains: a record's identity is its own natural key — `{repo, item}` for
   the item-lifecycle record, `{repo, item, class[, evidence.by]}` for the
   rework record, the equivalent stable key for any future one — reduced
   first-wins-by-`ts`, never the emitting node or the timestamp of the raw
   event that happened to produce a given copy: two nodes independently
   observing the same occurrence log it under their own, necessarily
   different `node` (and often `ts`), so including either in the identity
   would defeat the very dedup this property exists to guarantee. `ts`
   serves only to pick a survivor when more than one candidate shares that
   key. A fold built this way is idempotent under multiple publishers by
   construction: `fleet_logs` (requirement 2.5, `lib/fleet.sh`)
   hands every node an identical union of the same underlying events
   regardless of which node is doing the reading, so two nodes folding that
   union produce identical record sets, and merging those two outputs by
   the same identity yields one copy of each record, never two — proved
   directly for the item-lifecycle fold by `test/item-lifecycle.test.sh`'s
   two-node fixture, and for the rework record by
   `test/rework-panel.test.sh`'s own "first-wins" fixture.
2.7. **Crash-loop escalation.** A Co-Ordinator failure pins no item
   (requirement 33's fields are set only after selection), so the entire
   blocked → Enabler → escalation ladder that covers item failures never
   sees it — and the cycle still ends 0, so the dashboard shows a healthy
   idle fleet. When such a failure is deterministic and ships in the image,
   every node fails identically, cycle after cycle, and the record diverges
   completely from reality: the 2026-08-01 argv-cap outage ran ~15 hours ×
   4 nodes before a human noticed, and nothing in the system would ever
   have said so. So the Script reads the one signal that class does leave.
   After the requirement-2.5 union snapshot and before the stand-down
   checks (a fleet that is also standing down must still raise the alarm),
   `lib/crash-loop.sh` scans the union for two independent failure
   classes, each escalated through the shared `crash_loop_escalate` path:

   - `crash_loop_verdict` scans for `crash_loop_after` or more
     **consecutive** Co-Ordinator `attempt-failed` events carrying **one
     identical detail**, with no Co-Ordinator success (`stage-end`, stage
     `coordinator`, exit 0) for that same repository anywhere in the fleet
     in between — **grouped by the event's own `repo` field** (agent-ops#1630),
     so one repository's own deterministic failure accumulates its own
     consecutive count independently of every other configured repository,
     printing one JSON-Lines object per repository (plus one for the
     repo-less fallback group below) that has independently reached
     `crash_loop_after`, rather than at most one verdict for the whole
     fleet. Since issue #587 split Co-Ordinator selection into one
     engagement per configured repository, each engagement's own
     `attempt-failed`/`stage-end` events already carry that repository's
     own `repo` field (the `{repo: <slug>}` `extra` merge
     `run_coordinator_stage_attempt` and `handle_stage_failure` both make,
     `lib/stage-attempt.sh`) — without this grouping, every other
     repository's own success reset a repository's count every cycle,
     starving it of an escalation rung with no other symptom (requirement
     2.7 exists precisely to give the Co-Ordinator's own failures a rung,
     so a gap that silently removes it for a subset of repositories is the
     same failure class this requirement was built against, just narrower).
     An event that carries no `repo` at all — history from before issue
     #587, or a future Co-Ordinator caller that legitimately has none —
     falls back into its own group, reduced exactly as the whole stream
     used to be: fleet-wide, resetting on any repo-less success, and
     independent of every real repository's own group. Identical detail is
     what separates the deterministic class from transient noise within a
     group; any same-repository success resets that group's own count. The
     run's own `escalate` field (issue #1073) is `false` when every failure
     it counted carries `api_refusal_class: "transient"` on its own
     `attempt-failed` event — the API was unreachable (a 5xx, a dropped
     connection), not refusing a considered request — and `true` otherwise,
     including a run with no class at all. `detail` alone cannot carry
     this: it is the field the count groups on (requirement 4i), and
     folding a second axis into it would split one outage into as many
     "distinct" failures as it had status codes. See requirement 4i's own
     text on `stage_api_refusal` and `stage_api_refusal_class` for where
     the class comes from and why it travels beside `detail` rather than
     inside it. `crash_loop_reverify`, the escalated/deferred dedup checks,
     the flap guard (`crash_loop_detail_recurred_since`) and the retirement's
     own success lookup (`crash_loop_last_success_since`) are all matched on
     `repo` too, so two repositories that happen to share a generic detail
     (e.g. both saying "coordinator exited 1") can never dedup, defer or
     retire against each other's own run. The two families differ in what an
     *absent* `repo` means, because they read different things.
     `crash_loop_escalated_since`, `crash_loop_deferred_since` and
     `crash_loop_reverify` match a prior write of this pipeline's own, so an
     absent `repo` matches only an equally repo-less one — a repo-less run
     and a repository-scoped run are distinct runs and must not be confused
     for each other. `crash_loop_last_success_since` and
     `crash_loop_detail_recurred_since` read evidence about the Co-Ordinator
     itself, so an absent `repo` imposes no constraint at all and they read
     the whole fleet, exactly as they did before this grouping existed: an
     escalation filed before agent-ops#1630 carries no `repo`, while every
     Co-Ordinator event logged since issue #587 carries one, so the other
     reading would leave every such issue permanently unretirable (the
     success it needs to name could never again be found) with its flap
     guard reading the empty set.
     `crash_loop_preselection_verdict` below stays fleet-wide, grouped only
     by `exit_code` — it fires before selection ever assigns a repository
     to anything, so it has no `repo` to group by.
   - `crash_loop_preselection_verdict` scans for `crash_loop_after` or
     more **consecutive** cycles that each logged `cycle-start` followed by
     a `cycle-end` with a **non-zero `exit_code`** and *no* `stage-start`
     for any stage anywhere in between, grouped by that `exit_code` (there
     is no `detail` string on this path). This is the class the
     Co-Ordinator check above cannot see: a cycle that dies while
     assembling its own runtime input — `execve` failing on an oversized
     argv, the shape of both the 2026-08-01 argv-cap outage and the
     2026-08-12 void-extract one — writes no `attempt-failed` for any
     stage, so the union shows only the `cycle-start` / `cycle-end`
     pair. A completed cycle that starts a **selection-path** stage
     (`coordinator`, `implementer` or `reviewer`) resets the count,
     whatever that stage then does — reaching selection is itself proof
     the systemic block is not reproducing right now, and what happens to
     an item once a stage is running already has its own recovery ladder.
     A `stage-start` from the Enabler or the Refiner never resets the
     count: both run from the cycle's cleanup path, after any
     pre-selection death has already happened, so counting them as
     recovery would blind this check the moment their non-zero-exit
     guards (the "a cycle that ended badly" bail-outs in requirements 35
     and 39) were ever relaxed. A cycle with no `cycle-end` at all (still
     running, or killed too abruptly to log one) is dropped, counted
     neither way.

   The Script (agent-cycle.sh) loops over every line `crash_loop_verdict`
   returns, escalating each independently, before turning to
   `crash_loop_preselection_verdict`'s own single verdict (agent-ops#1630) —
   so two repositories that both crash-loop in the same cycle each get their
   own escalation attempt, neither waiting on nor folded into the other. On a
   verdict from either reader whose `escalate` is not `false` — every
   `crash_loop_preselection_verdict` run qualifies, since an `execve`
   failure is never a network refusal and that reader carries no class at
   all — and unless `crash_loop_escalated_since` finds a
   `crash-loop-escalated` event with the same detail (and the same `repo`,
   where the verdict carries one) at or after the run's own first failure
   (so the same loop is never escalated twice, while a fresh loop with an
   old detail escalates anew), `crash_loop_escalate_or_defer` (lib/enabler.sh)
   decides whether this verdict is safe to file right here. This point in
   the cycle runs before the Co-Ordinator's own attempt (deliberately — the
   alarm must fire even on a cycle that stands down before reaching it), so
   a verdict computed here can never see a recovery that attempt is about to
   produce.

   - A **fresh** verdict — `crash_loop_deferred_since` finds no prior
     `crash-loop-deferred` event for this exact first_ts+detail(+repo), so
     nothing has attempted to file it before — is filed immediately, through
     the Enabler's own `create_escalation_issue`: same open-issue dedup (item
     ref `crash-loop:coordinator` for the first class — `crash-loop:coordinator:
     <repo>` where the verdict names one (agent-ops#1630) — `crash-loop:
     pre-selection` for the second, so either class, and each repository
     within the first, can escalate independently of every other), same
     label, same load-bearing assignee that keeps the pipeline from
     selecting its own SOS as work. Success logs `crash-loop-escalated` with
     the verdict's fields (`repo` included, when the verdict carries one)
     and the issue's number and URL. Failure logs
     `crash-loop-deferred` instead, carrying the verdict's own fields
     (`detail`, `first_ts`, …) untouched plus a human-readable `message`, and
     queues the same attempt in `crash_loop_pending_refile` for a same-cycle
     late recheck rather than waiting a full extra cycle.
   - A **deferred retry** — a `crash-loop-deferred` event already exists for
     this exact run, meaning an earlier cycle already tried and failed to
     file it — is not filed here at all: the verdict computed at this point
     in *this* cycle is exactly as stale as the one that earlier cycle
     already failed to file. It is queued in `crash_loop_pending_refile`
     without attempting `create_escalation_issue`.

   `crash_loop_refile_pending` drains that queue from `cleanup()` (agent-
   ops#1074), after the Enabler, the Refiner, and every stage this cycle
   might have run — Co-Ordinator included — has had its chance. It
   re-gathers the union log fresh (`fleet_logs`, the same call the cycle's
   own opening snapshot makes) so this cycle's own now-complete Co-Ordinator
   attempt, if any, is folded in, then re-verifies each queued attempt with
   `crash_loop_reverify` (lib/crash-loop.sh): re-running whichever detector
   produced the queued verdict and checking whether it still names the same
   run (same `detail`, same `first_ts`). Still active, it is filed exactly as
   a fresh verdict is (through `crash_loop_escalate`, the same success/
   failure paths above). Broken — no verdict at all, or one naming a
   different run, meaning a Co-Ordinator success (or, for pre-selection, a
   cycle reaching a selection stage) has happened since — the filing is
   dropped and `crash-loop-dropped` records why, naming the run's own
   `detail`/`first_ts`. A union log this step cannot regather (`fleet_logs`
   returning nothing) is never evidence of recovery: every still-queued
   attempt is filed on its original verdict instead of being re-verified at
   all — silence must never retire an alarm. Filing every retry off the
   stale, pre-Co-Ordinator verdict instead of through this queue is exactly
   what turned the 2026-08-29/30 Ockham outage's last hour into a false
   alarm (agent-ops#1070): the escalation and the Co-Ordinator success that
   refuted it landed in the same cycle, the escalation first only because
   detection runs before the Co-Ordinator does.

   The cycle proceeds normally regardless of any of the above: detection
   must never suppress the recovery attempt that might end the loop.
   `crash_loop_after` 0 (or absent), or an empty `crash_loop_repo` or
   `enabler_assignee`, disables both checks; `--dry-run` never files.

   `crash_loop_retire_resolved` (lib/enabler.sh) closes the other side of the
   same gap: an already-open Co-Ordinator-class escalation (`stage:
   "coordinator"` — pre-selection has no single resetting event to name in
   the closing comment) whose run has broken since. It runs from step 1b,
   **before** either `crash_loop_escalate_or_defer` call, against the
   cycle's ordinary start-of-cycle union log — no same-cycle race to lose the
   way a deferred filing does, since an open issue's run either broke some
   earlier cycle or it did not, and any union snapshot since would show it
   either way. For each `crash-loop-escalated` event not yet followed by a
   `crash-loop-retired` event naming the same `issue_number`
   (`crash_loop_open_escalations`) — when more than one `crash-loop-escalated`
   event names the same `issue_number` (a rebind: `create_escalation_issue`'s
   own open-issue dedup keys on the item ref and label alone, never on
   `detail`/`first_ts`, so a run reusing a still-open issue logs a second
   such event against it, agent-ops#1140), the one judged is the newest by
   `ts` (carrying that repository's own `repo`, when the escalation was
   repository-scoped, agent-ops#1630) — a `crash_loop_reverify` finding the
   run broken *and* a `crash_loop_last_success_since`, scoped to that same
   `repo` where the escalation carries one and to the whole fleet where it
   does not (an escalation filed before agent-ops#1630 carries none, while
   every success logged since issue #587 carries one, so reading its absence
   as "repo-less successes only" would leave those issues permanently
   unretirable), naming the Co-Ordinator
   success that broke it close the issue with a comment naming that success,
   and log `crash-loop-retired`; a run still active leaves the issue
   untouched. Both conditions are required, and the second is the load-
   bearing one: a run stops matching the detector whenever it stops being
   *that* run, which a fleet still failing does every time the failures
   change `detail`, and which a raised `crash_loop_after` or a peer that has
   stopped syncing its log does without any change in the fleet at all. An
   escalation whose clearing success cannot be named is left open for a human
   to close — the detector's silence is never evidence the loop broke, in
   this direction any more than in the deferred-filing one.

   Two further guards (agent-ops#1134 review) stop retirement from closing an
   issue a *new* run of the same shape has already claimed, or is about to:

   - **Retiring before filing, not after.** `create_escalation_issue`'s own
     open-issue dedup is a live `gh issue list` query, not a read of
     `$union_log` — so if step 1b instead retired *after* filing, a resolved
     run's still-open issue could be rebound to a same-detail run that
     re-crosses `crash_loop_after` later in the very same cycle (`create_
     escalation_issue` finds the still-open issue and reuses it rather than
     filing fresh), and retirement would then close that issue on the
     strength of a union snapshot that predates the rebind — silently
     dropping the alarm for the live run's entire remaining life, since every
     later escalation attempt for it dedupes against its own now-closed-but-
     reused issue number. Running retirement first closes the resolved run's
     issue before either filing call can see it, so a same-cycle re-crossing
     opens a fresh issue instead of inheriting the retired one.
   - **A same-detail run already active in that same repository anywhere in
     `$union_log`, regardless of its own `first_ts`, blocks retirement
     outright** — a plain `crash_loop_verdict` recompute against the same
     log, filtered to the entry's own `repo` (agent-ops#1630 — a sibling
     repository's own same-detail run is not evidence about this one),
     checked before the `crash_loop_reverify` per-issue check above. This is
     the residual,
     cross-node version of the same race the reordering above closes only
     within one node's own cycle: a peer can have escalated (and so rebound
     the still-open issue to) a new same-detail run in an earlier cycle whose
     rebind has not yet reached this node's peer-synced union, even though
     that union already shows the new run's own failures. `crash_loop_
     reverify` alone cannot see this — it only refuses to retire the *exact*
     run an open issue names (same `detail` **and** `first_ts`), and the new
     run's `first_ts` necessarily differs from the old one's.

   A third and fourth guard, added for the 2026-09-05 fleet flap, stop
   retirement from closing an issue a same-detail run is about to reclaim
   within minutes: six escalations filed in four hours, every one the
   identical detail, each retired within minutes of a lone fleet-wide
   Co-Ordinator success — one node's own cycle succeeding once — before that
   same detail resumed failing and re-crossed `crash_loop_after` as what the
   two guards above read as a "new" run only a few cycles later. Neither
   guard above catches this while it is happening: the reordering only
   protects one node's own cycle, and the same-detail-active check recomputes
   `crash_loop_verdict`, which stays silent until the resumed failures
   themselves re-cross threshold — a ramp that took as little as two minutes
   of fleet time, nowhere near long enough for another cycle's own
   `crash_loop_reverify` to catch first. Retiring the instant a clearing
   success is found is what let each flap open a fresh issue:
   `create_escalation_issue`'s own open-issue dedup is a live query, and a
   closed issue leaves it nothing to find.

   - **`crash_loop_detail_recurred_since`** (lib/crash-loop.sh) blocks
     retirement outright when the same `detail`, in that same repository
     (agent-ops#1630 — fleet-wide for an escalation that carries no `repo`,
     on the same terms as `crash_loop_last_success_since` above), has already
     resumed failing,
     anywhere in `$union_log`, at or after the clearing success — whether or
     not it has reached `crash_loop_after` again. Unconditional, not a
     tunable: closing the issue while the very log the decision is reading
     already contradicts the "the loop has broken" comment the close is
     about to post is the mistake "silence must never retire an alarm"
     always forbade, met here from the other direction.
   - **`crash_loop_min_clear_minutes`** requires the clearing success itself
     to be at least this many minutes older than the union snapshot's own
     requirement-39f horizon (`log_latest_ts`, passed to
     `crash_loop_retire_resolved` as `UNION_LOG_HORIZON`) before it is
     trusted — a deterministic stand-in for "now" that never reads the wall
     clock, giving a same-detail recurrence that has not yet reached this
     node's own peer-synced union time to arrive and trip the guard above
     instead. The default, 30, is two of `schedule.cycle_interval_minutes`'s
     own default 15-minute firings: long enough that a same-detail
     recurrence gets at least two more fleet-wide chances to reach this
     node's own union before the clearing success is trusted — the
     2026-09-05 flap's own gaps between a retirement and the next same-
     detail failure were as short as two minutes, nowhere near enough
     without this. `0` restores instant retirement on the first nameable
     success, the behaviour before this key existed, for an installation
     that would rather see every flap than wait out a window.

   Together the two guards turn a flapping incident into one issue that
   stays open and gets rebound — with a fresh `crash-loop-escalated` event
   logged against the same `issue_number` each time, per the tie-break
   above — across every recurrence inside the window, rather than a fresh
   issue per flap.

   A `crash_loop_verdict` run whose `escalate` is `false` — the API was
   unreachable, not refusing a request — never reaches `crash_loop_escalate`
   at all: the Script logs `provider-unreachable` with the verdict's own
   fields instead. This is deliberately not an issue: nothing in this
   repository can fix a provider outage, and an escalation asserting
   "almost certainly deterministic … no amount of retrying will clear it"
   over evidence that says the opposite is worse than no escalation, which
   is exactly what happened for the 2026-08-29/30 Ockham outage (agent-ops
   #1070, filed and closed as not-a-defect against this requirement).
   `scripts/publish-dashboard.sh` does not read that event: it sources
   `lib/crash-loop.sh` and re-runs `crash_loop_verdict` over the same
   fleet-wide union (`fleet_logs`) itself, keeping the verdict only when
   `escalate` is `false`, and surfaces it — a run is still current exactly
   when no Co-Ordinator success on any node has reset it — on the affected
   nodes' own cards, beside their updater and image verdicts.
   Recomputing rather than reading the event is what lets a node publish
   the fact without having been the node whose cycle logged it, and it is
   gated on `crash_loop_after` alone, so the badge appears whether or not
   `crash_loop_repo`/`enabler_assignee` would have allowed an escalation.
   `docs/spec/dashboard/site.md` documents the field and the badge. A run this
   verdict counts is still counted and still resets on a Co-Ordinator
   success exactly as an escalating run does; `escalate` changes only what
   the Script does with a verdict that already fired, never whether one
   fires.
2.7a. **Token-expiry escalation** (agent-ops#694). GitHub states a
   personal access token's own expiry on every authenticated API response,
   in the `GitHub-Authentication-Token-Expiration` response header. On 2026-08-22
   that date arrived unread and every node lost GitHub at once — requirement
   2.0b's `github_auth_probe` classifies the resulting 401 and escalates,
   but only once the token is already dead. This requirement is the warning
   before that cliff: `scripts/doctor.sh`'s own hourly `--unattended` pass
   (requirement 2.6a) reads the header — the same free, GET-only
   `/rate_limit` call requirement 2.0 already reads, `--include`d for the
   header — and records `{expires_at, days_remaining}` (or `null`, absent a
   header) in `.doctor-status.json`'s `token_expiry` field. `doctor.sh` is
   read-only by its own declared contract, so the read stops there; the
   escalation itself runs in `agent-cycle.sh`, immediately after 1b's
   crash-loop check and before the requirement-2's stand-down checks, on the
   same "raise the alarm even if the fleet is also standing down, then
   proceed normally" placement 1b uses — a token that has not yet expired
   blocks nothing this cycle needs.

   `agent-cycle.sh` reads this node's own `state_dir/.doctor-status.json` —
   no GitHub call of its own — and, when `token_expiry.days_remaining` is
   below `TOKEN_EXPIRY_WARN_DAYS` (`lib/token-expiry.sh`, a fixed constant at
   7 days rather than a config key: agent-ops#694 calls this "a reasonable
   default, not a decision that needs a human"), escalates through the same
   fleet-scoped, deduplicated route 1b's crash loop and 2.0b's auth failure
   already use: `create_escalation_issue` in `crash_loop_repo`, labelled
   `enabler_escalation_label`, assigned `enabler_assignee`, item ref
   `token-expiry:<node>:<expires_at>`. Deliberately not routed through
   `escalation_autonomy` (D18, agent-ops#627) — that ladder is scoped to one
   specific escalation, an Enabler refinement-disagreement (requirement
   36b), and there is no disagreement to adjudicate over a date comparison —
   the same reasoning 2.0b's own block gives for the identical choice.

   Deduplicated on the expiry timestamp itself
   (`token_expiry_escalated_for`, keyed on node and `expires_at`), not on
   whether an open issue currently exists: a personal access token's expiry
   is a fixed fact about one credential, so a human closing the issue without
   rotating the token must not reopen the gate on the very next cycle — it
   reopens only once the token is actually rotated, which is exactly when
   `expires_at` changes. This is a stricter dedup than crash-loop's own
   `crash_loop_escalated_since` needs (that check resets on a `first_ts` run
   boundary, because a recurring failure has no natural id the way a
   credential's own expiry does). A failed filing logs a `warning` and
   retries next cycle, same as 1b and 2.0b. Skipped entirely on `--dry-run`
   and when `crash_loop_repo` or `enabler_assignee` is unset, the same as
   both of those checks.
2.8. **Per-stage health.** During the 2026-08-21 incident (01:38-12:09Z)
   every stage in every node's cycles failed for 10.5 hours, and every signal
   an operator had said otherwise: `agent-cycle.sh --status` reported
   `cycle: RUNNING — held by pid …` (the process was alive), no
   `check-node-*.sh` complained (nothing there reads a stage's own outcome),
   and the dashboard stayed green. All three were technically true — the
   needed detection already existed, as `stage-end`'s own `exit_code` — but
   nothing read it (issue #662). This is narrower and cheaper than
   requirement 2.7's crash-loop escalation above, which it complements rather
   than replaces: 2.7 is fleet-wide, matches on one identical failure detail,
   and files a GitHub issue, built for one specific deterministic class of
   Co-Ordinator failure. This is node-local, purely informational — nothing
   here ever opens an issue, blocks a cycle, or escalates anything — and
   answers a narrower question for every stage the Script runs, not only the
   Co-Ordinator: is this stage's most recent run of attempts on this node
   succeeding?

   `lib/stage-health.sh`'s `stage_health_verdicts` is a pure reader of one
   node's own event stream on stdin — deliberately never the fleet union
   `crash_loop_verdict` reads: a stage that is healthy on every other node
   says nothing about whether it is healthy on this one. For each of
   `coordinator`, `approver`, `approver-adjudicate-open-question`,
   `enabler-adjudicate`, `enabler-decide`, `enabler`, `refiner`, `implementer`
   and `reviewer` —
   every stage that logs a `stage-end` of its own, so that a stage this
   reader does not name can never be one whose failures go unread — it
   derives, from that stage's own `stage-end`
   and `attempt-failed` events, joined on `cycle` (every event carries one,
   via `log_event`) plus stage: `last_success` (the most recent `stage-end`
   with exit_code 0, or null), `consecutive_failures` (a running streak of
   `stage-end`s that each count as failed — either a non-zero `exit_code`, or
   a zero one with an `attempt-failed` carrying `stage_failure: true` logged
   for that same `cycle` (a stage can exit 0 while its attempt nonetheless
   failed, e.g. an unparseable final message, and that counts exactly as
   much as a non-zero exit; TD-PPagop-26082504) — reset to 0 by a `stage-end`
   that fails neither test. `stage_failure: true` is what distinguishes a
   genuine stage-attempt failure from an `attempt-failed` that instead
   records a verdict about the *item* a stage reached by running to
   completion — a needs-refinement block, a hand-flag, a void-refusal (`kind:
   "needs-refinement"`/`"item-block"` respectively, issue #1498, read by
   `lib/refinement.sh`, `lib/enabler.sh` and the dashboard for reasons
   unrelated to this join), a hand-flagged label, a Reviewer hand-back, an
   Implementer's own `blocked`/`void-refused` report — which shares the event
   name and the stage+cycle join key (requirement 34 reads both the same way
   to block an item) but is not a stage failure, and whose writer therefore
   never sets the field (issue #1511). The same reduction `crash_loop_verdict`
   already uses, but per-stage, per-node, and without requiring an identical
   failure detail, since "always wrong in some new way" is exactly as
   unhealthy as "always wrong the same way"), `last_detail` (the current
   streak's own most recent failure's
   detail — its matching `attempt-failed` by that same `cycle` join, or,
   where a non-zero exit has no matching `attempt-failed`, a synthesized
   `"stage-end exited <exit_code>"` — cleared to null the moment a success
   resets the streak, so an already-cleared streak's failure never leaks in
   as the current one's detail), and a
   `verdict` — `idle` (no `stage-end` record at all, i.e. never invoked, or a
   last success older than `IDLE_AFTER_HOURS` with nothing failed since —
   a stage with no recent work is not unhealthy), `failing`
   (`consecutive_failures` has reached `THRESHOLD`), or `ok` (anything else,
   including one or two failures below `THRESHOLD` — "one failure does not
   trigger a verdict" is the issue's own acceptance bar). `THRESHOLD` (3) and
   `IDLE_AFTER_HOURS` (48) are ordinary function parameters shared by every
   stage, not config keys: every stage here shares the same one-whole-attempt-
   per-cycle invocation shape once it does run, so one pair of numbers covers
   all of them, and three consecutive whole-cycle failures already reaches
   the same order of confidence `crash_loop_after`'s own default (4) requires
   before requirement 2.7 escalates — well before that heavier, issue-filing
   mechanism would ever fire.

   `agent-cycle.sh`'s `cleanup()` (requirement 35's own call site) calls
   `stage_health_write_status` at the end of every real cycle, after
   `cycle-end` is logged and before the state-sync push: it recomputes the
   verdict from this node's own `$log_file` — which by then already carries
   every `stage-end`/`attempt-failed` event this cycle logged — and writes it
   atomically (`mktemp` then `mv -f`) to `state_dir/.stage-health.json` as
   `{computed_at, threshold, idle_after_hours, stages}`, on
   `write_unattended_status`'s own precedent (requirement 2.6a). `--status`
   reads this file (never recomputes it) and prints it as a new `stages:`
   section, one line per stage — `coordinator failing (11 consecutive, last
   success 8h ago)`, `reviewer idle (never run)` — or a plain "no data yet"
   line on a node that has not completed a cycle since upgrading. A failing
   stage's line is followed by an indented `last: <last_detail>` line when
   the streak carries one (2026-09-15): the record held the detail all
   along, but the terminal showed only the count, so six cycles of a lapsed
   login on ockham-2 read as any failure at all when the detail — requirement
   4i's `authentication_failed` — named the one thing to do.
   `check-nodes.sh` (external to this repository; not committed here) prints
   `--status` per node and so inherits the new section for free, with
   nothing in this repository to change.

   Unlike `.doctor-status.json`, this verdict is not local to the node that
   computed it: `scripts/state-sync.sh`'s heartbeat write folds it in as
   `stage_health`, the same way `compose`/`image`/`switch` already travel —
   this node's own answer about itself, published like any other fact only
   this node can state — and `.stage-health.json` itself is excluded from
   general replication (`scripts/state-sync.sh`'s `EXCLUDES`) so its content
   travels exactly once, through the heartbeat, rather than twice.
   `scripts/publish-dashboard.sh` reads its own `.stage-health.json` (rather
   than recomputing it, on `.doctor-status.json`'s identical precedent) and
   surfaces it as `status.stage_health`; a peer's verdict comes from its
   heartbeat's `stage_health` field or reads null, never a verdict this node
   derives on that peer's behalf. `docs/spec/dashboard/site.md` documents the
   page's own Stage health section and fleet-strip badge.

   `stage_health_verdicts`/`stage_health_write_status` take the event pair
   (default `stage-end`/`attempt-failed`) and the output filename (default
   `.stage-health.json`) as parameters, generalized rather than hard-coded so
   a second pipeline with its own event stream can reuse the identical
   reduction over its own events (agent-ops#996): `docs/spec/review.md`
   requirement R19 is the repository-review pipeline's own symmetric verdict,
   for its one real stage `project-reviewer`, computed from `review-log.jsonl`'s
   `review-stage-end`/`review-attempt-failed` events into its own
   `state_dir/.review-stage-health.json` and folded into the heartbeat as a
   field of its own, `review_stage_health`, never merged into `stage_health` —
   the two pipelines' event streams and cycle-id shapes differ enough (a
   `review-cycle.sh` run's own id can cover several repositories) that R19
   keeps them computed, written and rendered separately rather than implying
   a shared computation that does not exist.
2.9. **Drain at-rest detection and reporting** (agent-ops#865, `lib/drain.sh`).
   While `DRAINING` is set (requirement 2.3d), the site that applies
   requirement 2.2c's unconditional narrowing also decides whether the drain
   has reached rest, and caches that decision for the readers that must not
   pay for a fresh one.

   **At rest** ⇔ requirement 2.2a/2.2c's own finishing set — every repo's
   `review_feedback`/`merge_conflicts`/`dequeued`/`abandoned_drafts` bands,
   combined — is empty across every configured repo *and* no live claim
   (requirement 17a) names a finishing-source ref (`pr-<n>-review-…`,
   `-conflict-…`, `-dequeued-…`, `-abandoned-…`) in any of them. The second
   half exists because a claim can be won moments before its pull request is
   opened: this cycle's own gather would see no PR yet in that case, and a
   `drained` event fired on that gap would tell a reader "nothing is left" of
   work that is, in fact, still in flight. `drain_remaining_count` (checked
   before either the stand-down or the narrowing decision, in the same
   `finishing_waiting`-gated block requirement 2.2a's own restriction lives
   in) is the larger of the finishing bands' combined length and the live
   finishing-claim count — a floor, not a sum, since the ordinary case is a
   claim whose pull request this same gather already counted and adding both
   would double it; `drain_at_rest` is simply whether that floor is zero.

   **The cache** (`drain-state.json` in `state_dir`: `{disabled_at, remaining,
   at_rest, checked_at}`) exists because `--status`, the heartbeat
   (`scripts/state-sync.sh`) and the dashboard (`scripts/publish-dashboard.sh`)
   are each read far more often than a cycle runs, and a fresh gather (the
   per-repo `lib/claim.sh claims` calls requirement 17a's own listing needs)
   on every one of those reads would be exactly the expense a cache exists to
   avoid — the same reasoning `fleet-cache/` already applies to the fleet
   switch (requirement 2.3a). Written once per cycle that actually ran the
   check (whether or not the restricted set turned out empty), and read by
   name against the *live* record's own `disabled_at`: a reader whose cached
   `disabled_at` does not match the switch's current one reports honestly
   that no cycle has checked since the current drain began (a fresh `--drain`
   just issued, or an extension), rather than showing a stale count from a
   drain that has since ended or restarted.

   **The `drained` event** fires once at-rest first becomes true, keyed on
   `disabled_at` and deduplicated across the union log (`lib/fleet.sh`'s
   `fleet_logs`, the same union `current_limit_record`/
   `landing_approver_adjudication_history` already read for their own
   once-per-record dedup): before logging it, the cycle that just found rest
   scans the union for an existing `drained` event carrying the same
   `disabled_at` and logs nothing if one is already there. The scan
   (`drain_event_logged`) reads the union through the tolerant event stream
   requirement 2.1's reduction reads (`union_events`) and skips a line that
   does not parse; a scan that fails outright reports a `guard-degraded`
   event and answers "not yet logged", since a second `drained` event is the
   cheaper mistake, and a union that could not be built (requirement 2.5) is
   treated the same way, reported as a `warning`. This is the
   correctness property a fleet needs and a single node does not — two nodes
   can independently reach "at rest" for the same drain in the same window,
   and only one `drained` event may exist for it, or a reader counting drains
   over time would overcount. No escalation and no webhook follow it: this is
   advisory, the same as `--status`'s own report, and a drain does not exit or
   auto-convert to a stop on reaching rest — it keeps ticking, and a cycle
   with nothing to finish continues to report `at_rest: true` on every
   subsequent check without repeating the event.

   **Reporting.** `agent-cycle.sh --status` prints a `drain:` line
   (`drain_status_line`, `lib/drain.sh`) whenever the local record's `mode` is
   `"drain"` — `DRAINING — N finishing-source item(s) left` or `DRAINED — at
   rest as of <time>`, or an honest "no cycle has checked yet" when the cache
   is absent or stale. `toggle_switch_summary` (requirement 34a) carries the
   record's `mode` unconditionally; `scripts/publish-dashboard.sh` and
   `scripts/state-sync.sh` each additionally fold the cache into that same
   object as `drain: {remaining, at_rest, checked_at}` when the mode is
   `"drain"` and the cache's own `disabled_at` matches — never a stale count —
   so the dashboard badge and the heartbeat's `switch.drain` field read
   identically to `--status`'s own line. `docs/spec/dashboard/site.md` documents
   the badge and banner text this drives.

   **Stage interaction.** The Enabler (requirement 35) is unaffected: its own
   eligible set (`compute_enabler_eligible_set`) is computed ahead of
   requirement 2.2c's narrowing, from the unrestricted gather, so it keeps
   acting on a blocked pull request regardless of source — the only route by
   which one gets further action while draining, exactly as for a
   back-pressured cycle. The Refiner needs no special-casing at all: it reads
   only the `issues`/`tech_debt` arrays requirement 2.2c already empties, so
   it goes idle by construction the moment intake is narrowed, whether by
   back-pressure or by a drain. Chaining (requirement 39) is unchanged — a
   drain that finished something still chains under its existing rule,
   `chain_sources_remain`'s own count of `.sources` lengths, unaffected by
   which mechanism narrowed them.
3. **Repo ordering.** For each configured repo, fetch the timestamp of the
   most recent commit on its default branch via `gh api`. A repo entry may
   also carry `nice`, an optional integer from `-19` to `19` (absent means
   `0`), read from that repo's `config.json` entry. Compute each repo's
   effective age as `(now − timestamp) × 2^(-nice/3)` and sort
   most-overdue-first by that effective age: `lib/repo-order.sh`'s
   `repo_order_by_effective_age`, sourced and applied by the Script. The
   prompt's part is descriptive only: `prompts/coordinator.md` presents the
   order as Script-computed — staleness weighted by each repo's configured
   attention bias — and instructs the Co-Ordinator to honour it as given;
   the `nice` values themselves never reach the model. With every repo's
   `nice` absent or `0`, effective age is plain age and the walk is a
   least-recently-updated-first sort — same order, same ties. Equal effective ages break by slug, deterministically. A missing or
   unparseable timestamp reads as epoch 0 — the oldest possible commit — so
   that repo stays maximally overdue at neutral `nice`, because a repo the
   Script cannot date is not one a `nice` value should be able to defer. The
   most-overdue repo gets first look, and this ordering takes precedence
   over the per-repo source priorities — but it does not outrank the global
   cross-repo tiers: security (15a), review-feedback (15b), abandoned-drafts
   (15c), merge-conflicts (15d) and urgent issues (15e) all still override
   the walk regardless of repo order. A `nice` value biases the walk; it
   never starves a repo, and a repo that alone has selectable work is chosen
   whatever its `nice`. The Script refuses to start a cycle if any
   configured repo's `nice` is not an integer in `-19`..`19`, failing fast
   and naming every offending slug, the same guard as
   `implementation_plan_path` (requirement 3k).
3a. **Findings pre-fetch (cost control).** For each configured repo whose
   `sources` include `security` or `code-quality` (requirement 48: freshly for the one repository this cycle picks, replayed from this node's expensive-gather cache for the rest), run
   `scripts/gather-findings.sh <repo-slug>` — a deterministic script that uses
   `gh api` to pull the repo's open Dependabot alerts and open code-scanning
   alerts, normalises each into a compact finding (`source` of `security` or
   `code-quality`, a `security` boolean, `severity`, a stable `ref`, `title`,
   `url`, and location/package), and prints them as a JSON array. It must
   degrade to `[]` (and exit 0) when a repo has the feature disabled or the
   token lacks access, so a missing feature never fails the cycle. Attach each
   repo's array to that repo's entry in the Co-Ordinator's runtime input as
   `findings`. Doing this in the Script — not in the Co-Ordinator — spends no
   model tokens on paginating and digesting those verbose APIs.
