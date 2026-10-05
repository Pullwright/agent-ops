## Requirements

### The Script — requirements, continued (part 4 of 10; 2.5–2.5: The fleet's shared memory…)

2.5. **The fleet's shared memory.** The pipelines' memory — `state_dir` — is
   published between nodes through the private repository named by
   `state_repo`, by `scripts/state-sync.sh`, one branch per node. Every mode
   of that script is a silent no-op when `state_repo` is unset, so a
   single-node operation behaves exactly as it did before the fleet existed.

   **What replicates.** Everything under `state_dir` except the live locks
   (`lock.json`, `review-lock.json`, `dashboard.lck`), the roll-pending
   marker (`roll-pending.json`, requirement 39c (Finish-then-continue), agent-ops#1096), the
   dashboard's own
   machinery (`dashboard/`, `dashboard.log`, `dashboard-server.log`,
   `.dashboard-github.json`, `.dashboard-claims.json`,
   `.image-drift-cache.json`), this node's own read-back of what the shared
   state holds for its own branch (`.state-sync-published.json`, "Publication
   freshness" below, agent-ops#602), `state-sync.log`, the unattended doctor
   pass's own local artefacts (`doctor.log`, `.doctor-status.json` —
   requirement 2.6a), the per-stage health snapshot's own raw file
   (`.stage-health.json` — requirement 2.8, its content excepted, below), the
   revert-rate publishing tick's own local text output and
   cumulative-since-baseline cache (`revert-rate.log`,
   `revert-rate-cumulative-state.json` — requirement 2.6b, the structured
   `revert-rate.jsonl` excepted, below), the tech-debt archive publishing
   tick's own local text output (`tech-debt-archive.log` — requirement
   2.6c, which has no structured sibling to except, since what it publishes
   lands directly in the state repository's own `tech-debt-archive/` tree),
   the stage event streams
   (`*.stream.jsonl`, requirement 4d), the fleet-log snapshot
   (`.fleet-log.jsonl`, "The union" below), the mirror's own durable
   rebuild record (`.mirror-rebuild-state.json`, "Mirror integrity" above),
   the two per-node caches whose own file mtimes *are* the schedule they
   gate — the label-ensure stamps (`labels-ensured/`, requirement 6a) and
   the expensive-gather cache (`expensive-gather/`, requirement 48) —
   the updater's own invocation ledger (`updater-ledger/`, below), and the
   `gh` transport shim's stored response bodies and lock files
   (`gh-shim/http-cache/`, `gh-shim/*.lock`, requirement 2.0e — the ledger
   and `budget.json` beside them excepted, below).
   The exclusions are not tidiness: a copied `lock.json` is a lock no process
   holds — peers read logs, never locks; `roll-pending.json` is this node's own
   instruction to its own watchtower hook, earned by its own cycle boundary,
   and a copy on a peer would tell that peer's hook to allow a roll nothing
   about that peer actually asked for; the
   dashboard is generated from the state beside it, so copying it would be
   copying a derivative of what is already being copied; a copied
   `.image-drift-cache.json` would answer for a registry query nobody on the
   peer ran, and a copied `.mirror-rebuild-state.json` likewise would answer
   for a rebuild nobody on the peer needed; a copied
   `.state-sync-published.json` would likewise answer for a fetch nobody on
   the peer ran — and unlike `.stage-health.json` below, no peer ever needs
   this node's own answer to "am I fresh", since a peer already judges this
   node by this node's own `heartbeat.json` `ts`, which a failed push simply
   never advances, so nothing folds it into the heartbeat either;
   `doctor.log`/`revert-rate.log`
   are each a local pass's own text
   output, superseded for a reader by the structured sibling that pass also
   writes (`.doctor-status.json` locally, `revert-rate.jsonl` fleet-wide —
   the asymmetry is exactly why one is excluded and the other is not);
   `tech-debt-archive.log` is excluded on the same "local pass's own text
   output" reasoning, but with no structured sibling to be superseded by at
   all — what it publishes goes straight into the state repository's own
   `tech-debt-archive/` tree, so nothing about it is fleet-wide data in the
   first place; a
   copied `.stage-health.json` would answer for a computation nobody on the
   peer ran, on the identical reasoning as `.image-drift-cache.json` — but
   unlike that cache, its *content* is meant to reach peers regardless, which
   is why it travels a different way, folded into the heartbeat below rather
   than replicated verbatim. `updater-ledger/` walks the identical path one
   level further down: a copied ledger would answer for invocations against
   containers nobody on the peer ever ran, so only its distilled verdict
   travels, as the heartbeat's own `updater` field (below).
   `gh-shim/http-cache/` is that reasoning again, with size behind it: it
   answers for reads nobody on the peer made, and it is both the largest
   thing under `state_dir` — one stored response body per distinct `gh api`
   GET this node has made — and the fastest-churning, since every fresh read
   rewrites an entry. Its two siblings are deliberately *not* excluded: the
   per-call ledger is fleet-wide telemetry
   `scripts/github-budget-report.sh` unions across nodes exactly as it
   unions `log.jsonl`, and `budget.json` is a reading of the one bucket
   every node shares, so both must travel.
   `labels-ensured/` and `expensive-gather/` carry a second reason on top of
   that one, and it is the sharper of the two: each schedules its own next
   run off its files' mtimes rather than off a timestamp written inside
   them, so a copy restored from the state branch arrives checkout-fresh —
   a node materialising either would read every repository as just-ensured
   or just-gathered and defer its next real ensure or real gather by a full
   interval, while serving the restored, arbitrarily stale snapshot. The
   streams are excluded on size as much as on relevance: what
   a peer reads of a stage is its result envelope, which replicates as
   `<stage>.out` exactly as before, while the stream beside it is every
   message and every tool result — kilobytes against megabytes — and the
   branch is a single rolling commit holding `cycles_retained` of them. The
   fleet-log snapshot is excluded on the same two grounds and more sharply
   still: it is a *derivative of what is already being sent* — the union of
   the very `log.jsonl` files the branch publishes — and one copy of it sits
   in every cycle directory, so a branch carried `cycles_retained` copies of
   the whole fleet's history, each one larger than the last, and every peer
   fetched all of them (#763). Both exclusions cover both transfers, the
   general one and the cycle directories' own filter, and delete any copy a
   node published before the rules existed. `log.jsonl`,
   `review-log.jsonl`, `revert-rate.jsonl`, `cycles/`, `reviews/`,
   `disabled.json` and the cron logs
   do replicate — they are what makes a spare node warm rather than merely
   installed. Git stores no empty directories, so a cycle that stood down
   before its first stage replicates as its `log.jsonl` entry alone.

   **Redaction.** Before `do_push()` commits, every file just staged by the
   two rsyncs above, plus the heartbeat just written, is passed through
   `redact_file()` (`lib/redact.sh`, agent-ops#966) in place: `/home/<user>`
   and `/Users/<user>` → `~`, and `ghp_/gho_/github_pat_/sk-…/Bearer …`
   token shapes → `[REDACTED-TOKEN]`. It is the same pattern set
   `scripts/publish-dashboard.sh` applies to its own payload
   (`docs/spec/dashboard/README.md`), shared through `lib/redact.sh` rather than
   reimplemented — the pattern only ever touches path- and
   token-shaped substrings, never JSON syntax, so `log.jsonl` and the other
   JSON/JSON-Lines files above stay parseable afterwards. Nothing upstream of
   this point stops a token or a home path that reaches a stage's own
   stdout/stderr — a verbose `git`/`curl` error, a stray `set -x`, a future
   bug — from landing in a transcript or a log; unlike the dashboard's
   published payload, the state repository is private, but it retains
   everything indefinitely (`log.jsonl` is never rotated, requirement 2.6),
   so this pass is the only backstop it has. Out of scope: anything already
   committed to the state repository's history before this pass existed —
   a one-off cleanup, not a push-time behaviour this requirement covers.

   A bearer secret carried in a webhook URL's own path
   (`https://hooks.slack.com/services/T…/B…/…`, the configured
   `notify_webhook_url`/`escalation_webhook_url`, requirement 2m) has no
   shape the fixed rules above can match (agent-ops#1721). Before the pass
   runs, `state-sync.sh` resolves that value the same way `agent-cycle.sh`
   and `scripts/publish-dashboard.sh` do (`notify_resolve_webhook_url`,
   `lib/notify.sh`) and registers it for masking with
   `redact_add_literal()` (`lib/redact.sh`) — additive to `REDACT_SED_ARGS`,
   never touching the shape rules, and a no-op when the value is empty or
   contains a newline: a single `sed` rule cannot span one, so registering
   such a value would break every rule in `REDACT_SED_ARGS`, not just its
   own, for the rest of the pass. `redact_add_literal()` stays silent either
   way, by design (`lib/redact.sh`'s own side-effect-free contract) — so
   `state-sync.sh` checks the same newline condition itself immediately
   before the call and warns on stderr when it holds (agent-ops#1730): the
   push still succeeds, but an operator running it interactively, or reading
   its captured log, is told the value is being left unmasked rather than
   finding out only by reading `REDACT_SED_ARGS` or the pushed content.
   `scripts/publish-dashboard.sh` registers the identical value the same
   way, right after it resolves it, before its own `redact()` pass
   (`docs/spec/dashboard/README.md`), with the identical stderr warning on the
   identical newline check. Registering the value itself, rather than
   adding a generic webhook-URL shape pattern, is deliberate: it is exact,
   costs no false positives, and covers whatever provider an installation
   actually configures, where a shape pattern would either miss an
   unlisted provider or chase an open-ended list of them.

   The pass handles a failure per file rather than unwinding on it
   (agent-ops#1679, below): a `redact_file` call that fails on one file —
   `redact_file` is a bare `sed -i`, so a directory the mirror copy cannot
   be rewritten in, a full disk, a file removed between `find`'s stat and
   `sed`'s open — is never fatal where it happens, because making it so is
   what deadlocked a whole push against its own unread process substitution
   for almost seven hours (#1679's own section below). What happens to that
   one file is a cascade, not a pass-through (the owner's ruling on #1698's own
   open question, agent-ops#1703): `redact_mirror_files` first `rm -f`s it
   out of the mirror, warning `WARNING: could not redact … — dropped from
   this push rather than committed unredacted`. Where the file resists
   removal too — typically because it sits under a directory `sed -i`'s own
   write-a-temp-file-and-rename could not write into any more than `rm`
   could — it is truncated in place instead, warning that it was emptied
   rather than dropped: truncating an existing file needs only the file's
   own write permission, which `rsync -a` carries over unchanged and
   independently of its directory's. Only where the file resists redaction,
   removal and truncation alike does the pass give up — ending the loop
   there and abandoning the push with nothing committed, through the same
   `state_sync_push_failed` path the deadline below already uses, the run
   ending non-zero and `mirror_lock`'s own exit trap releasing the lock
   behind it. Every file
   the branch carries has therefore actually been through the pass: nothing
   `redact_file` could not rewrite ever reaches the branch with its content
   intact. The cost is larger than "one file is missing": `mirror_write`'s
   own `add -A` stages a drop or an empty as a real change to the branch
   tip, so a dropped or emptied `log.jsonl` disappears from every peer's
   union, and a dropped or emptied `heartbeat.json` from a peer's own fleet
   strip, until this node's next successful push restores it — one push
   interval of reduced visibility, accepted in place of ever publishing a
   secret-shaped string into a repository that is private but never rotated
   (agent-ops#966).

   That one-off cleanup was decided, not left open: content pushed to
   `agent-ops-state` before this pass landed (2026-09-08T17:55Z) went up
   unredacted. What it carried was home paths, with no token-shaped string
   found in a 90.7 MB sample scanned against `lib/redact.sh`'s own pattern
   set. Every node branch tip has been redacted since the fleet rolled onto
   a post-fix image (all four `nodes/*` branches, by 2026-09-11T02:10Z). The
   owner accepted the resulting unreachable-object GC tail on 2026-09-11 and
   declined a purge, a GitHub Support ticket, a history rewrite, or
   credential rotation (agent-ops#1298). `main`, the repository's one
   append-only ref, was verified to carry nothing sensitive.

   **Mirror integrity.** Before either mode below touches the mirror,
   `mirror_init` (`scripts/state-sync.sh`) confirms it still deserves the
   trust a bare directory check used to hand it for free: a host whose disk
   quietly corrupts a loose object — an unclean shutdown mid-write, as
   happened on ockham-container from 2026-08-08 and ockham-2 on 2026-08-24
   — used to leave a `.git/` that opened fine but could not answer for what
   it held, with `git gc` failing at repair indefinitely (a `gc.log` that
   never clears) and the node reading from and publishing the damaged
   checkout for four days with no failure visible anywhere in the
   automation logs. On a mirror that already existed — never on one this
   call just created, since a fresh `git init` has nothing to have failed,
   and treating that as a rebuild would make every node's first-ever push
   report self-healing that never happened — `mirror_init` runs `git fsck
   --connectivity-only`: every object reachable from a ref exists and
   parses, without reading every object's full content the way a plain
   `git fsck` does. That bound is the right one, because the incident's own
   damage sat on a *peer's* remote-tracking ref, which is reachable, and it
   is cheap: measured against a mirror of 220k reachable objects, 0.2s with
   those objects packed and 1.8s with every one of them loose. The loose
   figure is the one that governs, because a mirror whose `git gc` is
   failing is precisely a mirror whose objects stop being packed, so
   unpacked is the shape damage actually arrives in. Either figure is three
   orders of magnitude inside the 5-minute push / 7-minute fetch interval
   this runs on, so no stamp-file gate is needed to keep it off the common
   path. A non-empty `.git/gc.log` fails the check in its own right, ahead
   of the fsck (#604's second clause, implemented 2026-09-15): it is git's
   record that its last garbage collection failed and its instruction to
   itself to decline every later `gc --auto` and merely reprint the old
   error, so the condition it names is permanent until the file goes — and
   `fsck` does not see it, because a store that was never packed is a
   valid store. On 2026-09-14/15 both workstation mirrors carried one
   (`pack-objects died of signal 9`, a gc the kernel had OOM-killed) over
   24,000–27,000 valid loose objects and 1.4–1.7 GiB. On any nonzero exit
   — 2 for an empty loose object, 3 for other corruption — or on that
   `gc.log`, `mirror_init` discards the checkout (`rm -rf`, `git init`,
   `remote add`) rather than repairing it: the mirror is wholly derived,
   this node's own branch is rsync'd back out of `state_dir` on the very
   next push and every peer branch is re-fetched at `--depth 1` by the very
   next fetch, so nothing in it is the only copy of anything, and repair
   (`git gc`) is exactly what the incident above already showed does not
   work. A rebuild is recorded durably in a small cache file under
   `state_dir` (`lib/mirror-integrity.sh`'s `mirror_rebuild_state_file`,
   excluded from replication like `.image-drift-cache.json` below, since it
   answers for this node alone) — living outside the mirror is what lets
   the record outlive the rebuild that produced it — and published as the
   heartbeat's `mirror` verdict (below), so a rebuild is as visible to a
   human or a peer as any other node fact, and a *second* rebuild is
   visibly a repeat rather than one more indistinguishable line.

   **Mirror object store.** After the check, on every push and fetch and
   whichever path the mirror took (kept, created or rebuilt), `mirror_init`
   applies `mirror_configure_store` (`lib/mirror-integrity.sh`): the seven
   git configuration keys `mirror_store_config` lists, each written only
   when it does not already hold its value, and the removal of `.git/logs`.
   The push below amends one rolling commit and force-pushes it, orphaning
   the previous snapshot every few minutes; under git's defaults the reflog
   kept every orphan reachable for thirty days, so a month of superseded
   snapshots accumulated as loose objects — gigabytes — before any was
   prunable, and the `gc --auto` that finally fired handed all of it to a
   `pack-objects` with one thread per CPU inside a scheduler whose
   `memory.max` is 1536m and which was usually running a stage. That is the
   gc the kernel killed, and the `gc.log` it left is what the check above
   now catches. So the store is bounded instead: no reflog
   (`core.logAllRefUpdates false`, and the existing reflog files removed,
   because with the setting false git still appends to any that exist —
   `git reflog expire` alone left the pile regrowing on 2026-09-15);
   unreachable objects pruned by the gc that finds them (`gc.pruneExpire
   now`, safe only because every git process that touches the mirror runs
   under `$mirror.lock`); the auto-gc run in the foreground of the `git
   commit` or `git fetch` that triggered it (`gc.autoDetach false`), so it
   completes inside that lock — a detached gc pruning at `now` would outlive
   the lock and race the next state-sync's fetch for objects it had written
   but not yet referenced — and, as a foreground gc never writes `gc.log`, a
   failure is retried at the next trigger rather than declining every gc for
   ever; a loose-object trigger of 1,000 (`gc.auto`) so the pile between gcs
   stays around a thousand objects rather than 6,700; a pack limit of one
   (`gc.autoPackLimit`), because the gc a loose trigger runs is an
   *incremental* repack and, at that moment, the mirror's remote-tracking
   ref for its own branch — moved by the depth-1 fetch that opens every
   push — still names the snapshot the amend has just superseded, so that
   one snapshot is packed and becomes garbage only when the push moves the
   ref, garbage an incremental repack never drops and a consolidating
   `repack -a -d` does — which git schedules at 50 packs by default and, at
   this limit, in the fetch that opens the push after every incremental gc;
   and a single-threaded, window-bounded repack (`pack.threads 1`,
   `pack.windowMemory 64m`), since the reachable set alone is small (about
   12.5 MiB packed on the Poetic nodes) and the ceiling is what killed the
   last one. Under those the store settles at one pack holding the current
   snapshot and at most the one before it, with the current snapshot's own
   objects loose until the next incremental gc. The keys live in the
   mirror's own `.git/config`, so a rebuild loses them — which is why they
   are applied on every run rather than at init, and why a mirror that
   predates this reaches the same state on its next push: its reflog-kept
   pile becomes unreachable the moment `.git/logs` goes, and the next
   auto-gc prunes it under the same bounds (the two VM nodes' 43,000-entry
   reflogs and 48–50 packs went that way by hand on 2026-09-15, 11–12 s
   and 210–280 MiB peak each). `test/state-sync.test.sh` forces the gc by
   planting two blobs whose ids fall in the `objects/17/` bucket `gc
   --auto` samples, with the threshold lowered through git's
   environment-config channel, and asserts the settled shape across six
   pushes.

   **Push.** Every node — active or standby — mirrors its `state_dir` into
   its **own branch**, `nodes/<NODE_NAME>`, every few minutes from the
   crontab and again from the cleanup that ends a cycle. No two nodes share
   a branch, so pushes cannot contend and nothing arbitrates them. Each push
   stamps `heartbeat.json` (`{node, role, ts, last_cycle, version, compose,
   compose_reconcile, image, switch, stage_health, mirror, updater}`)
   into the branch root — on a standby, which has no cycles to publish, the
   heartbeat is the entire point, and it is what lets the fleet dashboard
   tell a quiet node from a dead one. `role` is `lib/role.sh`'s
   `role_declared` — requirement 2.4's own normalisation, lowercased and
   stripped of whitespace, and `unknown` when the pushing process was handed
   no role at all. Normalised because a peer acts on it and must reach the
   same verdict the node's own guard would: `AGENT_OPS_ROLE=Active` runs
   unattended cycles, so it cannot be allowed to read as a standby.
   `unknown` rather than the guard's fail-closed `standby` because this
   field is a record, not a decision — every scheduled process is handed the
   variable by Compose, so an empty one means a hand run, and requirement
   51's `firing-missed` retires an open page for a node it believes has
   stopped being asked to cycle. `scripts/publish-dashboard.sh` builds its
   own row's `role` the same way, and reads a peer's from this field,
   writing `unknown` when a heartbeat carries none. `version` is `lib/version.sh`'s answer
   — what code the node is running, knowable to the fleet only because the
   node says so itself, since a peer publishes no container. `compose` is
   `lib/compose-drift.sh`'s, on the same reasoning one layer down: whether
   the node's own `compose.yaml` still matches the copy its image shipped
   (see "The node stack"), a question only that node can ask because the
   file lives on its host and only its own containers mount it (#131).
   `compose_reconcile` is `.compose-reconcile.json` read verbatim — what this
   node's own reconciler last did about that drift (requirement 2.5a), read
   rather than recomputed for the reason `stage_health` below is: the file is
   another container's finished verdict, and this script holds neither the
   Docker socket nor the project directory it was reached through. `null` on
   a node with no reconciler.
   `image` is `lib/image-drift.sh`'s: whether the node's own commit is the
   one `ghcr.io/pullwright/agent-ops:latest` currently names, read
   anonymously over the registry's own API rather than GitHub's (which would
   need the `read:packages` scope this pipeline does not hold) — the gap
   `version` alone cannot close, since comparing nodes only with each other
   cannot tell a fleet uniformly stale from a healthy one (#155). Unlike
   `version` and `compose`, a real network round trip sits behind it, so
   `scripts/publish-dashboard.sh`'s own 5-second tick cannot pay for it on
   every run: `.image-drift-cache.json`, named identically by both callers,
   holds the last answer for `IMAGE_DRIFT_TTL` seconds (240 by default) so
   whichever of the two next crosses that age pays the one query and the
   other reads its answer off disk.
   `switch` is `toggle_switch_summary`'s (`lib/toggle.sh`): this node's own
   node-scoped disable (requirement 2.3, `--this-node`), flattened to the
   shape the dashboard's badge renders from. The raw `disabled.json` does
   replicate (above), but a record is not a verdict — whether it is still in
   force is decided against a clock, and a reader deriving that for itself
   would be a second implementation of requirement 2.3's evaluation, free to
   disagree with what the node's own `--status` says. So the node publishes
   the verdict it reached, not just the file it reached it from. The
   fleet-wide switch needs no such carriage: it is a flag file every node
   already fetches for itself (requirement 2.3a).
   `stage_health` (requirement 2.8, `lib/stage-health.sh`) is this node's own
   `.stage-health.json`, read verbatim rather than recomputed — that file is
   already this cycle's finished verdict, written by the same cycle's own
   `cleanup()` before this push runs, so reading it keeps this one write the
   single source both the heartbeat and this node's own dashboard read,
   rather than two computations that could disagree. `null` on a node that
   has not completed a cycle since this check shipped.
   `mirror` is `lib/mirror-integrity.sh`'s `mirror_rebuild_verdict`: `null`
   until "Mirror integrity" above has ever had to discard and rebuild this
   node's checkout, else `{status: "rebuilt", count, last_rebuilt_at}`, read
   back from the durable record every push so a repeat rebuild bumps `count`
   rather than reading identically to the first.
   `updater` is `lib/updater-health.sh`'s `updater_status` (#603): the update
   mechanism's own verdict, ahead of and independent of the drift `image`
   above eventually catches — a node whose watchtower has stopped rolling
   altogether still reads as every other field's idea of healthy until this
   one says otherwise. Nothing inside a container can read watchtower's log
   or the Docker socket, so the one fact available is what
   `deploy/docker/watchtower-pre-update.sh` itself decided; that script
   records every invocation, one line per poll, to a durable ledger under
   `state_dir` (`updater-ledger/<hostname>.jsonl`, excluded from replication
   below like `.image-drift-cache.json`). `$HOSTNAME` tells a tailnet node's
   scheduler and dashboard containers apart — they share this state volume
   but not an identity — but it does **not** identify a container
   *generation*: watchtower clones `Config.Hostname` forward when it
   recreates a container (agent-ops#1072), so a roll's replacement inherits
   its predecessor's hostname and keeps appending to the very same file. Each
   line therefore also carries `started` — the *writing* container's own PID 1
   start time, in clock ticks since the host booted (field 22 of
   `/proc/1/stat`), `null` when unreadable — the one field two lines in the
   same file can disagree on across a roll, and so the only thing that can
   answer "did the container reading this line write it?" The hook and
   `updater_status` must read it identically, and from that field
   specifically: `/proc/uptime` is the *host's* uptime under Docker, not the
   container's, so it reads the same in every generation; and `stat -c %Y
   /proc/1` is the procfs inode's mtime, which the kernel sets when that inode
   is instantiated — the first lookup after a cache miss — rather than at
   process start, so it is a property of access history and moves whenever the
   dentry is reclaimed (measured on poetic-1, 2026-08-30: it read 2h25m later
   than PID 1's real start). An identity that can change under one container
   fails one way only — the reader stops recognising entries it wrote itself
   and reads `rolled` — silently retiring the `stuck` alarm this ledger
   exists to raise. Field 22 is fixed for the life of the process and
   strictly ordered across generations, a replacement always starting after
   what it replaced. Each line also
   carries `service` — the compose service name (`AGENT_OPS_SERVICE`:
   `scheduler`, `dashboard`, `dashboard-local`, `collector` or `reconciler`,
   `"unknown"` if unset) the writing container ran as. This field has a live limitation
   (agent-ops#1072): watchtower clones the writing container's environment
   forward the same way it clones its hostname, so a compose-level addition
   of `AGENT_OPS_SERVICE` never reaches a container created by a roll — every
   line on every node currently reads `service: "unknown"`, and the
   `service`-scoped "rolled" fallback scan below therefore currently admits
   every candidate rather than narrowing to a genuine sibling. This is
   ordinary compose drift, not fixed by this file; `lib/compose-drift.sh`
   already reports it for `compose.yaml` generally.
   Liveness first (agent-ops#1071, deciding agent-ops#1053): before
   `updater_status` reads anything under our own hostname, it checks that
   hostname's own newest ledger entry — whatever its verdict — is no older
   than `updater_stuck_after_minutes`; if it is, every claim about the
   present reads `null` outright, streak included, because nothing has
   polled this container recently enough to answer for it. This is the one
   gate for both self-states below, not a second threshold: a container
   whose last poll allowed a roll hours ago and has not been heard from
   since is indistinguishable, at the ledger, from one deliberately taken
   down after a roll (agent-ops#1046's `TD-PPagop-26082913`) — both get the
   same unanswerable reading. `rolled` is exempt: it is a claim about the
   past, already carries its own age in `seconds`, and keeps the hook's 7-day
   prune as its only bound.
   `updater_status` reads that ledger back as `{status: "rolled", at,
   seconds}` — the newest "allow" invocation the ledger can show was *not*
   written by the container now reading it. That is either the ordinary
   post-roll case (a different hostname entirely, from our own service — the
   scan is service-scoped, on the limitation just described, because a fresh
   container with no ledger entry of its own would otherwise read a stuck
   sibling *of a different service* sharing this ledger directory as evidence
   of its own roll, since that sibling keeps appending ever-newer "allow"
   entries every poll) or the identity case this hostname's own file can now
   answer directly: its trailing "allow" carries a `started` different from
   this container's own — the roll that produced this very container
   (agent-ops#1072), not evidence that it never happened. `{status:
   "deferring", at, seconds}` (this hostname's own most recent invocations
   have all deferred, back to `at`, and that streak has not yet outlasted
   `updater_defer_stuck_after_seconds`), `{status: "stuck", at, seconds,
   reason}` (a fault only a human clears, either `reason: "allow"` — this
   hostname's own most recent invocations have all allowed a roll, proven by
   `started` matching this container's own and never by the hostname alone
   (agent-ops#1072), back to `at`, and this same container is still running
   past `updater_stuck_after_minutes` later, the 2026-08-14 signature: a
   container told to go ahead that watchtower never actually replaced,
   which the retry alone will not clear since it repeats the operation that
   collided — or `reason: "defer"` — the defer streak above has itself
   outlasted `updater_defer_stuck_after_seconds`, past which
   `watchtower-pre-update.sh`'s own `held_by()` would no longer honour
   either lock, so this is no longer "a cycle in flight") or `null` (no
   invocation recorded under any hostname yet, our own newest entry is
   already older than `updater_stuck_after_minutes` (the liveness gate
   above), the run of "allow"s is too recent to classify either way, the
   trailing entry under our own hostname carries no `started` at all or this
   container cannot read its own — so no identity verdict is possible on the
   strength of that entry, in either direction (agent-ops#1072) — a threshold
   the caller passed is not a whole number of seconds, or a ledger entry's
   own timestamp will not parse — every one an unanswerable question, never a
   default the library picks for itself, and never epoch 0: unlike
   `held_by()`'s identical convention, which fails the lock *open*, epoch 0
   here would fail *closed*, into an alarm nothing could ever clear, since a
   corrupt timestamp can also defeat the hook's own 48h trim below).
   Once liveness holds, both self-states are measured from the *start* of
   the current run of like verdicts, not from its newest entry: watchtower
   re-runs the hook on every poll for as long as the container is still
   stale, so each records one entry per `WATCHTOWER_POLL_INTERVAL`, and
   timing the newest would measure the age of the last poll rather than of
   the condition — putting `stuck`, whose threshold is many polls wide,
   permanently out of reach. A ledger line that will not parse, mid-streak,
   is skipped rather than treated as ending the streak, so one transient bad
   line cannot silence an alarm early or reset a stuck container's clock. The
   `allow` streak's scan is additionally bounded by `started`: the run stops
   the moment `started` changes, not only when the verdict does, so a
   container watchtower rolls repeatedly inside `updater_stuck_after_minutes`
   — each replacement appending its own genuine "allow" under the one
   hostname it inherits — reads each roll on its own terms rather than one
   continuous streak spanning several *successful* rolls (agent-ops#1072,
   the residual false positive agent-ops#1071's liveness fix could not reach
   on its own). The `defer` streak needs no such bound: the entry immediately
   before any roll is always an "allow" — that is what authorises it — so a
   defer streak can never itself straddle a generation boundary; the ordinary
   verdict-mismatch break already stops it there.
   `updater_stuck_after_minutes` converts to `updater_stuck_after_seconds`
   the same way `image_behind_grace_hours` converts one layer up from
   `lib/image-drift.sh`, travelling as a parameter, never a literal inside
   the library. `updater_defer_stuck_after_seconds` is derived rather than
   configured: the longer of `lock_stale_after` and
   `repository_review.lock_stale_after` (in hours, read with the hook's own
   simple `// 4`/`// 6` defaults, not `acquire_lock`'s fuller derivation),
   converted to seconds — the same two values `watchtower-pre-update.sh`'s
   `held_by()` already bounds a deferral by, so a defer streak this function
   calls `stuck` is one no held lock could still legitimately justify.
   The published verdict is the worst *live* one across this node's own
   ledger and every sibling's (agent-ops#1037): every pipeline service on a
   node carries the `pre-update` label — `scheduler`, `dashboard`,
   `dashboard-local` and `node-health` inheriting it from the shared
   `x-agent-ops` block, `egress-proxy`, `collector` and `reconciler`
   declaring it on their own service (each deliberately skipping that anchor,
   which carries credentials they do not need) — so any of them can write a
   ledger file under a `$HOSTNAME` of its own, and a fault on one is
   invisible to a heartbeat published only from another's own file.
   `updater_status` folds in every other `<hostname>.jsonl` in the same
   `updater-ledger` directory, applying liveness to each file's own newest
   entry exactly as it does to its own (liveness is a property of a file,
   not of the service that wrote it, per agent-ops#1053) — regardless of
   `service`, unlike the `rolled` fallback scan, since the fold answers "is
   any container on this node stuck", not "did a peer of my own service
   roll". A sibling's `allow` streak has no PID 1 of this container's to
   compare against, so its identity bound is that same file's own trailing
   `started` — which still confines the streak to one generation exactly as
   the own-file case does, and still yields no `stuck` reading at all from a
   trailing entry with no `started` field. `stuck` outranks `deferring`,
   which outranks everything else; ties break on the older `at` (the one
   that has been in that state longer), then on hostname, so the fold is
   deterministic across two containers reading the same directory at once.
   `rolled` is never folded and a sibling never contributes one — it is
   exempt from liveness because it is a claim about the past, not the
   present, and folding it would attribute one container's own history to
   another. The published object gains `host`, naming the ledger a foreign
   verdict came from, only when a sibling's reading is worse than this
   container's own; it is absent when this container's own verdict wins
   outright, so the field never asserts about this container a fault that
   belongs to another. `egress-proxy` carries the `pre-update` label like
   every other pipeline service, but it mounts `state` read-only — precisely
   so the hook can read a running cycle's lock without the container needing
   a writable volume — so it can never record a ledger entry at all and is
   never a candidate the fold can find: an accepted blind spot, not a defect,
   since a stuck `egress-proxy` has no ledger of its own to be foreign to, on
   any node, ever.
   Each branch is a single rolling commit — `commit
   --amend` plus a force-push — because the state files carry their own
   history (`log.jsonl` is append-only, every cycle keeps its own directory)
   and a commit per push would be a second, redundant history whose only
   lasting effect is a repository that grows without bound. A mid-cycle push
   is fine: consumers read logs rather than adopting state, and the
   dashboard tolerates a torn transcript for one tick. The branch keeps the
   newest `cycles_retained` cycle directories. The node's own history is
   bounded separately, by the same push and before any mirroring: local
   `cycles/` and `reviews/` are pruned to the newest
   `state_local_cycles_retained` each — a deliberately longer record than
   the branch's, so everything the branch wants is always still on disk and
   the machine remains the fuller history of the two, with a floor of one so
   the cycle being recorded is always kept. The **derived** files inside
   those directories are bounded separately again, and far more tightly: the
   same push deletes every `*.stream.jsonl` and every `.fleet-log.jsonl`
   outside the newest `state_local_streams_retained` directories of
   `cycles/` and, separately, of `reviews/`, leaving the directories
   themselves — and everything else in them — untouched, and sparing
   whatever the count says the directory named by a live `lock.json` or
   `review-lock.json`: a cycle that runs for hours is overtaken by the
   directories later ticks leave (a node disabled while it runs writes one
   per firing), so the newest N need not include the one still being
   written, and a stream pruned under a running stage is what its watchdog
   reads as inactivity (`lib/stage-run.sh`). Two retentions rather than one
   because the two are different orders of size: keeping six weeks of cycle
   *records* costs megabytes, and keeping six weeks of the derived files
   inside them would cost tens of gigabytes. A tick that ran nothing leaves
   no record directory to count: the lock-held skip (requirement 1) and the
   review pipeline's lock-held skip and busy-peer stand-down
   (`docs/spec/review.md` R2) each remove the directory they made,
   whose only content is the snapshot taken before the lock.
   `STATE_SYNC_STREAMS_RETAINED`, forwarded from a node's `.env` by
   `deploy/docker/compose.yaml`, sets the count for that node ahead of the
   key: a positive decimal integer, or ignored with a warning in favour of
   the key (a word would end the push as an unbound variable, a malformed
   number would collapse the count to 1, a leading zero would read as
   octal); `scripts/doctor.sh` reports the variable while it is set, and
   `deploy/docker/.env.example` describes it. Every prune here runs only on
   a node with `state_repo` set, because the push is what prunes
   (agent-ops#1936).

   What qualifies as derived is the **property, not the filename**: large,
   wholly reconstructible from what the record already holds, and read only
   by the cycle that wrote it. Stating the rule as a list of names is what
   let `.fleet-log.jsonl` fall through to the record retention and be kept a
   thousand deep on every node and published to every branch (#763), and a
   file added to a record directory later that shares those three properties
   belongs on the list for the same reason. Nothing reports the omission: the
   disk does, once it is already gone. A mirror-level `flock` serialises the
   cron push against the end-of-cycle push.

   **The count-based retention above is a backstop for a busy fleet, not for
   a full disk (agent-ops#1678).** `state_local_streams_retained` is sized
   by the schedule alone, never by free space (requirement 1d), and a count
   configured for one disk (agent-ops#1826)
   says nothing about another, so nothing in the count itself stands between
   a fast cadence and a host with no room left: on 2026-09-18 both poetic nodes' 200 retained fleet-log
   snapshots reached 45 MB apiece, filled the shared host to zero free bytes,
   and stood both nodes down for disk (`disk-full`, requirement 2.0c) without
   either node ever having pruned a byte of the roughly 7 GB each was
   already holding — the count-based prune had already run and left exactly
   what it was configured to leave. So, immediately after that prune, `push`
   reads `state_dir`'s own free space through the same functions as the
   pre-clone stand-down (`lib/disk-space.sh`) and against
   `min_free_workspace_bytes` itself — the floor, not the effective threshold
   requirement 2.0c derives over it from the largest recorded clone, which
   this push has no union to read a footprint from; between the two the gate
   stands cycles down while this valve reads `ok` (agent-ops#1935); once it
   reads below the floor,
   `prune_derived_under_pressure` strips further, one cycle's derived files
   at a time, oldest cycle first, re-reading free space after each and
   stopping the moment it clears the floor or only the newest cycle's
   derived files remain — whichever comes first — and sparing the record a
   live lock names exactly as the count-based prune does. This is safe regardless of
   how the count is configured: a fleet-log snapshot is read only by the
   cycle that wrote it (the header above), so every retained copy but the
   newest already exists purely for after-the-fact diagnosis, and deleting an
   older one under pressure costs a live node nothing a live gate or
   watchdog still reads. `state_local_streams_retained`'s own derivation is
   unchanged by this — the key, or a node's `STATE_SYNC_STREAMS_RETAINED`,
   stays the operator's lever for the ordinary case, and this prune only
   ever removes what a free-space shortfall makes unsafe to keep regardless
   of that count. A `0` floor (`min_free_workspace_bytes` disabled) makes this prune
   a no-op too, the same as it does the pre-clone gate — one setting, one
   meaning of "off", for both. The floor is read defensively, not merely
   trusted: `min_free_workspace_bytes` falls back to `0` — the same "off" —
   when the value read from `config.json` or from
   `STATE_SYNC_MIN_FREE_WORKSPACE_BYTES` is not numeric (agent-ops#1729),
   normalising a hand-edited config carrying something like `"2GiB"` to a
   clean value before the arithmetic test that follows so no arithmetic-error
   noise reaches stderr, matching the tolerance `disk_space_verdict` already
   gives a non-numeric floor argument.
   `STATE_SYNC_MIN_FREE_WORKSPACE_BYTES` and
   `STATE_SYNC_FREE_KB` override the floor and the free-space reading
   respectively, both test-only — the shape `STATE_SYNC_STREAMS_RETAINED`
   takes for `test/state-sync.test.sh` too, though that one is also a
   per-node operator lever, forwarded by `deploy/docker/compose.yaml`
   (agent-ops#1826).
   `test/state-sync.test.sh` passes: a push comfortably clear of an injected
   floor still runs the ordinary count-based prune and never engages this
   one; a push injected below the floor engages it after the count-based
   prune, strips cycles and reviews alike down past what the count alone
   would have kept, oldest first, and stops at the newest cycle's derived
   files rather than the cycle directories themselves or the records inside
   them; and an injected floor of `0` leaves the count-based prune as the
   whole of what runs, however low the injected free-space reading, mirroring
   `disk_space_verdict`'s own `0`-disables contract. A non-numeric floor read
   from `config.json` itself behaves exactly like an injected `0`: the
   count-based prune still runs, and the pressure prune never engages.

   **Every process's scratch lies in one directory named after it, and
   the ones dead processes leave are swept (agent-ops#1827).** The pressure
   prune above can shed only what lives in `state_dir`; what a process
   spools through `mktemp` lands under `$TMPDIR` instead — in the container's
   writable layer, on the same disk. Each scheduled entry point
   (`agent-cycle.sh`, `review-cycle.sh`, `monitor-cycle.sh`,
   `scripts/doctor.sh`, `scripts/state-sync.sh`) and the dashboard Publisher
   (`scripts/publish-dashboard.sh`, `docs/spec/dashboard/integration.md` §Integration)
   therefore starts, before it sources any other library, by entering a
   scratch directory of its own — `agent-ops.<name>.<pid>.XXXXXX` under
   `$TMPDIR` — and points `TMPDIR` inside it for the rest of the process
   (`lib/scratch.sh`), so that every file it or a library it calls spools —
   `lib/gh-shim.sh`'s per-call directories, `lib/issue-priority.sh`'s cache,
   `lib/toggle.sh`'s flag memos, the Publisher's union files, `sort`'s spill
   files — lies inside it, and the process's `EXIT` trap releases the whole
   of it — renamed first to a `.agent-ops-sweep.<pid>.<name>` tombstone,
   with `TERM`, `INT` and `HUP` ignored for the duration, then removed — and
   puts `TMPDIR` back, so that a process started from that cleanup (the
   chained cycle of requirement 39) inherits a directory that exists. The trap is armed, on an empty name, before the
   directory is made; a process that cannot make one (a full or unwritable
   `$TMPDIR`) says so on stderr and exits 1 rather than aim its writes
   elsewhere. bash runs the `EXIT` trap on `exit`, on `set -e` and on an
   untrapped fatal signal alike, so a process a `timeout` ends with `TERM`
   releases its directory, and the rename is what makes that release
   complete: `timeout` signals the process first and its process group a
   moment later, and a command the shell forked in the instant between the
   first signal's arrival and its next check never receives the second,
   outlives the shell, and would otherwise recreate an entry under a
   directory `rm -rf` had already listed; what a `KILL` ends — the OOM killer, a container
   stopped past its grace, requirement 1's stale-lock takeover reaching its
   `KILL` — leaves the directory behind, and the sweep removes it:
   `scratch_sweep_dead_owners` runs at the start of every
   `scripts/publish-dashboard-launcher.sh` window, on every node whatever
   its role, and again at every cycle start, before the free-space gate
   (requirement 2.0c) reads the disk; a management command (`--status`,
   `--disable`, `--enable`) sweeps nothing, as it runs no cycle. The sweep
   removes every `agent-ops.<name>.<pid>.XXXXXX` and
   `agent-ops-fleet-flag-memo.<pid>` directory at the top of the base
   directory whose pid no longer exists, and every `.agent-ops-sweep.<pid>.…`
   tombstone a sweep that died left; it reads a pid as dead only when
   `/proc/<pid>` is absent *and* `kill -0` fails with ESRCH (EPERM is another
   user's live process, as under a `hidepid` `/proc`); it renames a
   directory to a tombstone and tests the pid again before removing it, and
   a pid found alive at that second test has its directory renamed back; and
   it leaves every other directory alone however old it is: a live publish
   on a loaded node has run for hours (agent-ops#1620), so age is not the
   test. The sweep never fails its caller, and says what it removed — in
   `dashboard.log` from the launcher, on stderr from a cycle — only when it
   removed something. `test/scratch.test.sh` passes: `scratch_enter` makes
   the directory under the prior `TMPDIR`, records that base, exports
   `TMPDIR` inside it, and `scratch_release` removes it and restores
   `TMPDIR`, set or unset; a base that cannot be written into fails the call
   with exit 1, a line on stderr and `TMPDIR` untouched; the sweep removes a
   directory of either shape under a pid that does not exist and a tombstone
   under a dead sweeper, counts them, and keeps one under the test's own
   live pid, one whose `kill -0` answers EPERM, a live sweep's tombstone, one
   of any other name, one whose pid field is not a number and a plain file;
   a second sweep removes nothing further; without an argument the sweep
   reads the base `scratch_enter` recorded, else `$TMPDIR`; and a missing
   directory yields a count of zero and exit 0.
   `test/publish-dashboard.test.sh` passes: a launcher window removes the
   scratch directories under a dead pid, keeps a live process's, and logs
   the count.

   **A push that cannot write says so, and an orphaned index lock does not
   stop it (agent-ops#1377).** The `flock` above is state-sync's own;
   `.git/index.lock` in the mirror is git's, taken by every command that
   writes the index and left behind by one that died mid-write — a container
   stopped under it, a git the kernel OOM-killed. Nothing examined it, so on
   poetic-1 (2026-09-09 to -11, 27 hours) and poetic-2 (2026-09-13 to -15,
   three days) every push failed at its first index write with `fatal:
   Unable to create '…/.git/index.lock': File exists` while the push's own
   progress lines kept printing, the node kept cycling, `--status` read every
   stage `ok`, and the only node-side voice was the doctor's hourly
   publication check (#602), into a file nothing surfaced. So, after
   `mirror_init` and before the first write, `do_push` clears that lock when
   three things hold — it exists, it is older than one push interval
   (`schedule.state_sync_push_minutes`, the interval this script itself runs
   on; a live git holds the index lock for seconds, so one older than the
   gap between two pushes belongs to a process that is not coming back), and
   no git process is working in the mirror (`mirror_git_busy`, read from
   `/proc`: any process named `git` whose working directory is the mirror or
   whose command line names it; where `/proc` cannot be read the answer is
   "busy") — and logs `state-sync-lock-cleared` `{age_s}` to `log.jsonl`,
   which replicates, rather than only to its own log. A lock any live git
   may hold is never removed; a young one is left with a line saying so.
   Independently, every writing git command of the push (`reset`, `clean`,
   `add`, `commit`, `push`) runs through `mirror_write`: on failure the first
   `fatal:`/`error:` line is said and logged as `state-sync-push-failed`
   `{step, detail}`, git's full stderr is passed through as before, and the
   run still ends non-zero — a push that did not push is a failure, and
   supercronic's exit-status line stays true. The doctor's own publication
   check is unchanged: it already fails a node whose read-back is older than
   `node_stale_after_minutes` — the fleet-wide definition of stale, applied
   identically to a peer's row and to a node's own so the two cannot
   disagree (that key's own notes) — and did so hourly throughout both
   incidents; a second, tighter threshold for the doctor alone would have the
   node call itself stale while its peers still called it fresh. What was
   missing was a reader, so `--status` gains two lines (`lib/manage.sh`, on
   the same terms as requirement 2.8's `stages:` section — `check-nodes.sh`
   prints `--status` per node and inherits them for free): `published:`,
   this node's own publication verdict through `fleet_publication_status`
   over `.state-sync-published.json` — `fresh`/`STALE` with the age and the
   threshold, `unknown` before the first read-back, `not configured` without
   a `state_repo` — and `doctor:`, the last unattended pass's verdict and
   age from `.doctor-status.json`, with the count of failing checks and the
   first of them (the same bounded `fails` the heartbeat carries, #1397), or
   a plain sentence when no pass has run. `test/state-sync.test.sh` drives
   the three lock cases (young, held by a live process, orphaned) and both
   events; `test/manage-status.test.sh` the two lines. The same file covers
   the two `--status` readers of the fleet union: past a spliced peer line,
   `decisions:` still counts the last day's `decision-taken` events across
   the node and its peer, and `current_limit_record` still returns the
   governing hit, with nothing reported; a read that fails outright prints
   `decisions: unreadable` rather than 0, and each reader reports its own
   site through `guard_warn`; and a union that could not be built (a `sort`
   that exits 2 stands in for one a full disk stopped) does the same, with
   `current_limit_record` leaving the flag carrier to answer alone.

   **A push that wedges holding `mirror_lock` releases it on its own, and a
   long hold is named as a possible wedge rather than reported as an
   ordinary one (agent-ops#1679).** On 2026-09-18 a push on `ockham-2`
   wedged for almost seven hours inside the redaction loop
   (`lib/redact.sh`, above), holding `mirror_lock` throughout. A `redact_file`
   call failing on one file (a permission error, a file removed between
   `find`'s stat and `sed -i`'s open, disk full) could unwind the whole run
   under `set -e` before `find` reached EOF, leaving `find` blocked writing
   into a pipe nothing was reading any more — the general hazard a process
   substitution read side left unconsumed by an `errexit` unwind creates.
   The exact trigger — which file, which error — was not recovered from the
   incident; this closes the general hazard regardless of cause.
   Meanwhile "another state-sync holds the mirror — nothing to do"
   (`mirror_lock`, above) is genuinely self-clearing only for an ordinary slow
   fetch, so nothing told the two apart: the doctor's own publication check
   (this same requirement, above) still caught the resulting silence hourly,
   into a file nothing surfaced, exactly as it did throughout #1377.

   Three changes, independent of each other: a failed `redact_file` call is
   now a warning and a cascade — drop, then (if the drop itself fails)
   empty, then (only if neither succeeds) abandon the push
   (`redact_mirror_files`, `scripts/state-sync.sh`, agent-ops#1703) — rather
   than a loop-ending failure, closing the specific hazard this incident
   traced to; the redaction pass runs under a deadline
   (`mirror_run_with_deadline`, `lib/mirror-lock.sh`) — one push interval by
   default, `STATE_SYNC_PUSH_DEADLINE_SECONDS` overriding it for tests —
   that backgrounds the pass and kills its whole process tree (a /proc walk
   over parent/child edges, generalising `mirror_git_busy`'s own search for
   a live git to any process) if it is still running past that bound,
   logging `state-sync-push-failed` `{step: "redaction-loop-deadline",
   detail}` (the shape `mirror_write` already uses, both now built by one
   `state_sync_push_failed` helper) and ending the push non-zero — a safety
   net regardless of whether a future wedge shares this incident's own
   cause; and `mirror_lock` itself now names how long the current holder has
   been running. That last part needs a fact the lock file itself cannot
   answer — `exec 9>"$mirror.lock"` truncates it on every attempt, winner
   and loser alike, so its mtime is reset by the very call that is asking —
   so the process that actually wins the flock stamps a start time into a
   marker beside it (`mirror_lock_mark_started`/`mirror_lock_clear_started`,
   `lib/mirror-lock.sh`) that only it writes and only it removes on release.
   A losing `mirror_lock` call reads that marker's age and says so: "holding
   for Ns" always, and "longer than one push interval — may be wedged" once
   that age passes `push_interval_seconds`. `--status`'s `published:` line
   (above) gains the same fact for a human who is not reading `cron.log`:
   `publication_status_report` (`lib/manage.sh`) probes the lock live
   (`mirror_lock_probe`, a momentary `flock`(1) against the lock file rather
   than a bash-builtin fd, since this is a read-only caller that never takes
   the lock itself) and appends the same "may be wedged" note once a live
   hold outruns one push interval — read live, since a wedge's whole defect
   is that it never reaches the confirmed-publication read-back the rest of
   that line is built from. `do_fetch` takes the same `mirror_lock` as
   `do_push`, so `mirror_lock_probe` also surfaces the marker's own `mode`
   ("push" or "fetch", stamped by `mirror_lock_mark_started`) and the note
   names the actual operation that is wedged — "a push has been holding …",
   "a fetch has been holding …" — falling back to the mode-neutral "a
   state-sync has been holding …" whenever the probe could not read a `mode`
   at all, rather than always saying "a push" regardless of which side
   wedged (agent-ops#1715). `test/state-sync.test.sh` covers the deadline in
   isolation (a simulated wedge via `sleep`, killed and reported `124`
   without waiting out its own runtime), a single unredactable file no
   longer aborting the loop and reaching the branch emptied rather than
   unredacted, a file only `sed` itself fails on — a PATH shim standing in
   for the full disk a test cannot stage, since any permission that stops
   `sed -i` stops `rm` too — dropped from the branch outright, a file that
   resists removal and truncation as well abandoning the push instead —
   event logged, lock freed, no branch pushed for that
   node at all — a genuinely slow redaction pass (thousands of
   trivial files) hitting the deadline end to end — event logged, lock
   freed, the very next push unobstructed — both sides of a real lock
   contention naming the holder's age — and `mirror_lock_probe`'s own `mode`
   field for a push-held marker, a fetch-held marker, and a marker with no
   readable mode; `test/manage-status.test.sh` covers the `published:`
   line's own note, on and off the wedge threshold, and under each of the
   same three mode cases.

   **Fetch.** Every node materialises every *other* node's branch, whole,
   under the peers directory (`lib/fleet.sh`, `<workspace_root>/
   .agent-ops-peers/<node>/`), on its own schedule: `git archive` into a
   temporary directory swapped atomically into place, so a union reader
   never sees half a peer. A branch that has been deleted is a node that has
   left the fleet — its peer copy is pruned on the next fetch. Nothing is
   ever written into a node's own `state_dir` from outside.

   A fetch probes with `git ls-remote --heads origin 'refs/heads/nodes/*'`
   before touching any branch, to tell apart the two ways that probe can
   come back empty-handed: a zero exit with no output is the genuine
   bootstrap case (the state repository has no node branches published
   yet), a silent no-op that returns 0; a non-zero exit is a real failure —
   bad credentials, a network outage, a corrupt mirror — logged from git's
   own stderr, that returns non-zero so the scheduler surfaces it (#693). A
   `git fetch` failing after a successful, non-empty probe is reported and
   handled identically, as a second, later real failure. Either kind of real
   failure also marks the peers directory stale: `fleet_mark_peers`
   (`lib/fleet.sh`) writes `<peers_dir>/.last-fetch.json`
   (`{"ok": bool, "ts": …, "last_ok_ts": …|null}`, `fleet_peers_marker`)
   after every fetch attempt that gets past the bootstrap check. `ts` is the
   attempt that established the current `ok`; `last_ok_ts` is the last fetch
   that actually succeeded, so a reader can tell a five-minute outage from a
   three-day one even while `ok` stays `false` throughout (owner decision,
   #990, escalation #1065). The transition rule: a success always rewrites
   (`ok: true`, `ts` = `last_ok_ts` = now); a failure rewrites only on the
   `ok: true` → `false` transition (or an absent, unreadable or zero-byte
   marker), carrying the previous marker's own `last_ok_ts` forward — falling
   back to its `ts` for a legacy `{ok: true, ts}` marker with no `last_ok_ts`
   field, and to `null` when there is no prior success to carry at all; a
   failure after a failure does not touch the file at all, not even with
   identical content, because its mtime feeds
   `scripts/publish-dashboard.sh`'s `local_state_fingerprint` and moving it
   on every attempt would rebuild the dashboard once per fetch attempt for as
   long as the outage lasts. So a reader that cares whether the peer copies
   below it might be frozen can tell without re-deriving the answer itself,
   and the marker stops moving once an outage sets in rather than churning on
   every attempt. The marker is written whole and renamed into place, for the
   same reason the peer trees beside it are: a reader that catches a plain
   truncate-then-fill mid-write sees neither the old answer nor the new one.
   The marker is absent only in the bootstrap case, where there has never
   been a real peer to be stale about.

   **Staleness.** `fleet_peers_stale` (`lib/fleet.sh`) is the one predicate
   for whether the marker is too old to trust, shared by `fleet_logs_healthy`
   below and the dashboard's fleet-strip badge (`fleet.peers` in the
   publisher's payload; docs/spec/dashboard/state.md) so the two can never disagree.
   Stale ⇔ the marker says `ok: false` (a real failure is in force, however
   long ago it started), or it says `ok: true` with `ts` older than the
   threshold (the fetch cron itself has stopped running, without ever
   logging a failure); an absent marker is not stale — the bootstrap case,
   caught instead by the union's own emptiness — and a marker present but
   unreadable *is* stale, the one case the two answers differ on, since a
   marker that will not parse is evidence of a write that went wrong rather
   than of a fetch that has never run. Neither that read nor
   `fleet_mark_peers`' own may fail its caller: both run under
   `set -euo pipefail` (`scripts/state-sync.sh`), where an unguarded
   assignment from a `jq` that rejects the file would abort the fetch at the
   read instead of reaching the rewrite. The threshold is
   `min(3 × schedule.state_sync_fetch_minutes × 60, LABEL_OWN_GRACE_SECONDS)`
   — 21 minutes at the shipped 7-minute cadence, capped at 1800s (#1053's
   principle: a staleness bound must never exceed the fault threshold it
   gates) — env-overridable as `FLEET_PEERS_STALE_SECONDS`, on the same
   `${VAR:-default}` shape `LABEL_OWN_GRACE_SECONDS` itself uses
   (`lib/label-marker.sh`), so a test can pin it. The dashboard's badge
   reads: *"peer view stale — last successful fetch `<last_ok_ts>`, failing
   since `<ts>`"* for `ok: false`, and *"peer view stale — fetch not running
   since `<ts>`"* for a stale `ok: true`; self is definitionally fresh and
   unaffected, and no badge renders at all once the marker is fresh again or
   for a node that has never fetched (single-node operation, or before its
   first state-sync).

   **Publication freshness** (agent-ops#602). A node's freshness is a fact
   about what it has *published*, never about its own clock: on 2026-08-08
   both laptop nodes reported themselves fresh for four days while
   `state-sync.sh push` was failing the whole time, because the dashboard's
   self row used to be built from `date` and a hardcoded `false` rather than
   read back from anywhere — every signal either node emitted was one it also
   consumed. The fix is one computation, `lib/fleet.sh`'s
   `fleet_publication_status`, applied identically to a peer's row and to a
   node's own (requirement 34a): given a publication timestamp and the
   configured threshold (`node_stale_after_minutes`, 30 by default — three
   missed heartbeat/fetch cycles at the shipped cadence, not clock jitter, the
   same reasoning `image_behind_grace_hours` and `updater_stuck_after_minutes`
   already carry one layer up), it returns `{ts, age_s, verdict}`, `verdict`
   one of `"fresh"`, `"stale"` or `"unknown"` (no timestamp has ever been read
   back for this node/peer — a fresh install, or the short window before a
   node's first successful push has been fetched back at all, not itself a
   fault).
   A peer's timestamp is its `heartbeat.json`'s own `ts` — already correct,
   since a failed push simply never advances it. Self's timestamp comes from
   this fetch: since the `git fetch` above already brings down this node's own
   branch alongside every peer's (`+refs/heads/nodes/*`), reading it back costs
   no extra network round trip (D14). Immediately after a successful fetch —
   never on the bootstrap no-op or a real failure, both of which `return`
   above before reaching this point — `do_fetch` reads
   `origin/nodes/$NODE_NAME`'s own `heartbeat.json` `ts` (falling back to the
   ref's own committer date on the unreachable-in-practice case of a branch
   with no `heartbeat.json` at all) and writes it to a local derived cache,
   `.state-sync-published.json` (`{ts}`, excluded from replication above like
   `.image-drift-cache.json` — no peer ever needs this node's own answer to
   "am I fresh"). A fetch that fails leaves this cache exactly as it was, so
   its age against the local clock grows into staleness on its own — the same
   property a frozen or missing cache needs to make a broken push visible
   without a second signal.
   `scripts/publish-dashboard.sh` reads this cache for the fleet strip's self
   row (falling back to a hardcoded fresh reading when `state_repo` is unset —
   single-node operation has no shared state to have gone stale against) and
   the identical `heartbeat.json` `ts` for every peer row, both through
   `fleet_publication_status`, so the two rows can never disagree about what
   counts as fresh. `scripts/doctor.sh` reads the same cache and the same
   function for this node's own check, gated on `state_repo` being configured
   (inert otherwise, per "What replicates" above): `"fresh"` is `ok`,
   `"unknown"` is `warn` (not itself a fault), and `"stale"` is `fail` — a
   push that has stopped working even while local cycles carry on, distinct
   from a genuinely idle node, which still pushes a heartbeat on its own
   schedule regardless of whether it has run a cycle.

   **The union.** What the fleet shares is memory, not authority: the
   blocked and void extractions (requirements 34/34c), the no-op fingerprint
   (3b) and the usage-limit cooldown (2.1) all read `fleet_logs` — this
   node's own log concatenated with every peer's, sorted into time order —
   so a lesson any node learned stands the whole fleet down, or spares it a
   re-check, within one fetch interval. Each cycle and each review takes that
   union **once**, into `.fleet-log.jsonl` in its own record directory, so
   every reader downstream sees one consistent stream rather than a moving
   one; `union_log` names it, and requirement 39f's horizon is captured from
   it immediately afterwards, with nothing written to it in between.

   A peer that has not repaired its own log at source (`fleet_repair_log`,
   which the dashboard launcher runs each window — `docs/spec/dashboard/README.md`),
   or history it replicated before it did, can still hand a node a
   NUL-holed line, or a spliced one: the head of a record cut off part-way
   with the whole of a later record on the same line, left by a write a full
   disk cut short, or by the gather's own `cat` joining a peer file whose
   last record lacks its newline (agent-ops#794, #2037). `fleet_logs` takes
   such a line apart before its sort, because the sort places a line at its
   first timestamp: a spliced line sits at its head's, and a record recovered
   from it after the sort would sit ahead of records older than itself. A NUL
   run becomes a line break (`tr -s '\0' '\n'`). One streaming `awk` pass
   under the C locale sets aside the candidate lines (`FLEET_CANDIDATE_AWK`:
   a line that does not open an object, does not end in `}`, or holds
   `{"ts":"` anywhere past its start) in a small file under `TMPDIR`, and
   passes every other line straight to the sort; one `jq` resolves the
   candidates into the same sort with the shared recovery
   (`FLEET_RECOVER_JQ`). A candidate that parses whole as an object passes
   unchanged, byte for byte — the `landing-audit-record` events that carry a
   nested record are exactly that; any other is split at each `{"ts":"`,
   and, walking from the left, the shortest run of pieces that parses as an
   object is kept each time, so a record that lost only its newline survives
   with the one it ran into, a stump is dropped, and only objects are ever
   emitted. Every recoverable record therefore sits at its own timestamp's
   place, and the snapshot is never repaired after it is built. The bulk of
   the union is never parsed or written to an extra file.

   `fleet_logs` exits non-zero when a stage after the gather fails — `tr`,
   `awk`, the candidate `jq` or the sort, which an OOM kill or a full disk
   stops — so a union that could not be built is never taken for one that
   holds nothing. A peer file that vanishes between the glob and its `cat`
   is not a failure. The cycle reports a failed build (`guard-degraded`, site
   `cycle:union_build`) and carries it as `union_build_ok` to the readers
   that must tell "could not read" from "nothing there": requirement 2.1's
   usage-limit read treats it exactly as a failed read, and its freeze
   escalation (1c) files nothing that cycle. The review and monitor runs log
   it as a `warning` and treat their usage-limit reads the same way, and
   `--status`, the drained dedup (2.9) and `scripts/node-health.sh` treat a
   failed build as a failed read of their own. The union's readers still
   skip a line that does not parse (requirement 2.1's reduction shows the
   form), for a malformed line the candidate test does not pick out.

   The snapshot is scratch with a cycle's
   lifetime: it is read only through that variable, by the script that just
   wrote it, and never by a peer or by a later cycle. That is why it neither
   replicates nor outlives the run that wrote it — the cycle's cleanup
   removes it once the Enabler and the Refiner have read it, the review's
   likewise, and only the snapshot of a run that died before its cleanup is
   left to the derived-file retention above — it is a *derivative* of the
   logs the fleet is already exchanging, and republishing it would send
   every node N copies of what it already has. The union is advisory speed; the
   claims of requirement 17a are the lock underneath it. Cross-node work
   arbitration has no other mechanism: there is no lease and no leader, and
   `claims/` on the state repository's `main` branch — which per-node
   branches never touch — is owned exclusively by `lib/claim.sh`.

   **The union readers' answer to a stale peers directory** (#990, escalation
   #1065). Of the union's five consumers, four carry on regardless and one
   degrades:

   - the blocked and void extractions (requirements 34/34c) — **carry on**:
     positive-evidence readers, for which a frozen peer copy is strictly more
     information than no peer copy at all, and the log-independent locks
     (the `blocked` label pair, requirement 17a's claims, just above) are
     what actually keep two nodes off one item;
   - the no-op fingerprint (3b) — **carry on**: its claim is "nothing the
     Co-Ordinator reads has changed", and frozen peers genuinely have not
     changed, so a skip is correct rather than merely safe, with
     `none_selected_recheck_hours` bounding any stall;
   - the usage-limit cooldown (2.1) — **carry on**: its evidence is positive
     and self-expiring — a missed peer `limit-hit` costs one refused
     engagement, after which `lib/limit-detect.sh` writes this node's own —
     and widening the cooldown on stale peers is a certain fleet-wide
     throughput loss traded against a self-correcting one;
   - the fleet dashboard — **degrade: badge** (the peers-staleness paragraph
     above; docs/spec/dashboard/state.md's `fleet.peers`).

   No code and no new per-reader logging attaches to the first three: the
   decision is prose, recorded here, not a code path — requirement 38b's own
   once-per-cycle warning is already the record that the fifth reader,
   `fleet_logs_healthy`, degraded the union for that cycle.
