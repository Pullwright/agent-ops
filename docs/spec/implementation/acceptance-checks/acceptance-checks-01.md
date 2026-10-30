## Acceptance checks

Every change to the system must leave all of these passing; before opening a
pull request, run the ones the change touches and any it could regress.

**No check below may expect a particular value from `config.json`.** The
shipped configuration is asserted to be *valid* — that it matches
`config.schema.json`, and that `scripts/doctor.sh` passes it — and every other
fixture supplies its own configuration, either a block the test writes itself
or `test/fixtures/config-base.json`, the base `test/config-schema.test.sh`
mutates. Where a check is genuinely about the shipped file rendering or
resolving correctly, it reads the values it needs back out of it (through
`config_defaults`, the same resolution the code uses) rather than repeating
them. Changing a configured value — a threshold, a cadence, an autonomy rung,
a repository added or removed — is a configuration change, and must never
oblige anyone to edit a test.

1. <a id="impl-ac-1"></a>`shellcheck agent-cycle.sh scripts/*.sh lib/*.sh` is clean.
1a. <a id="impl-ac-1a"></a>**The role guard holds in both directions.** `test/role.test.sh` passes:
   every value that is not `active` stands the node down with a cron-log line,
   exit 0 and nothing written under `state_dir`; `--dry-run`, `--once` and the
   switch commands run regardless of the role.
1b. <a id="impl-ac-1b"></a>**The image builds and carries the whole toolchain, on both
   architectures.** `docker build -f deploy/docker/Dockerfile -t agent-ops .`
   succeeds, and inside it, as user `agent`: `bash`, `git`, `jq`, `curl`,
   `python3`, `perl`, `flock`, `sha256sum`, `rsync`, `node`, `claude`, `gh`
   (≥ 2.60), `supercronic`, `shellcheck` and `squid` (the egress-proxy service's
   fence, requirement-checked at check 10) all resolve; `shellcheck
   --version` prints `0.10.0`, the same version
   `.github/workflows/shellcheck.yml` pins; `supercronic -test
   /app/deploy/docker/crontab` reports the crontab valid; the `test/` suite
   passes inside the container, save for the one narrower class of change
   check 1b-i carves out of it; and `/app/agent-cycle.sh` with no role set
   exits 0 through the requirement 2.4 guard. The build itself asserts one
   thing about `gh` beyond its version, because `gh` is the one part of the
   toolchain installed unpinned: a `grep -aF` over the installed binary for
   each of the two stderr diagnoses `review_gate_required_checks` splits its
   verdict on (requirement 31c) — a release that reworded either fails the
   build at that step, here rather than on a node. Misspelling either
   substring must make the build fail there, which is how the guard is
   verified to be doing anything at all. `.github/workflows/build-image.yml`
   runs every one of these against both the `linux/amd64` and the `linux/arm64`
   build on every pull request that touches the image — each architecture in
   its own job, natively on a runner of that same architecture
   (`ubuntu-latest` and `ubuntu-24.04-arm`), with no emulation anywhere in the
   tested path — so a change that breaks either architecture's image cannot be
   merged, and it is the only place the `test/` suite runs in CI. On `main` the
   workflow publishes both architectures as one manifest list per tag.
1b-i. <a id="impl-ac-1b-i"></a>**A documentation-only change builds nothing, everything else builds,
   and one narrower class builds without running the suite.**
   `test/is-docs-only.test.sh` passes: `scripts/is-docs-only.sh`
   calls a change documentation-only when every path in it is under `docs/`
   — except `docs/STANDING-DECISIONS.md` and the four specification files
   `monitor-cycle.sh` names (`docs/spec/implementation/gotchas.md`,
   `docs/spec/review.md`, `docs/spec/monitor.md` and
   `docs/spec/dashboard/README.md`), which the image *does* deliver to a
   running stage and so count as code — or is
   `README.md`, `CLAUDE.md`, `AGENTS.md`, `TECH-DEBT.md`, `LICENCE` or
   `deploy/docker/README.md`, and calls it code otherwise — `prompts/*.md`
   included, since those are Markdown documents *and* the operating
   instructions of requirement 1a's stages, so classifying by file extension
   would let a change to a node's behaviour skip the build that deploys it.
   Everything under `tech-debt/` is code for the weaker reason that the
   allowlist does not name it: nothing reads `/app/tech-debt/`, so an edit to
   the frozen register costs a build nobody needed rather than reaching a
   node, and that is the side of the mistake this classifier is built to
   take. An
   empty path list, or none, is code. The test the allowlist encodes is "the
   image is not the delivery path for this file", which is weaker than
   "nothing reads it" and cuts both ways: a cycle working on this repository
   reads its own `CLAUDE.md` and its `AGENTS.md`, but from the `gh repo
   clone` in `workspace_root` — current the moment a pull request merges,
   with no image involved — so those stay documentation-only despite being
   read. `docs/STANDING-DECISIONS.md` and the specifications' `## Gotchas`
   sections are the opposite case: `agent-cycle.sh` resolves
   `standing_decisions_file` against `$SCRIPT_DIR`, which is `/app` in the
   image, and `lib/escalation-autonomy.sh` feeds the file to the
   decide-tactical pass as its precedents; `monitor-cycle.sh` passes each of
   those four `$SCRIPT_DIR/docs/spec/` paths to `monitor_digest_gotchas`
   as the Monitor's known signatures — both reach a node only through the
   image, so a change confined to either still needs one. Every other
   stage's working directory is under `workspace_root` or `state_dir`
   (requirement 6's assertion pins the first), so /app is never a working
   directory nor an ancestor of one and its `CLAUDE.md` and `AGENTS.md` are
   never loaded as project memory.
   `.github/workflows/build-image.yml`'s `changes` job runs it over the
   change's own diff (three-dot, so a pull request is judged on what its
   branch did and not on what `main` did
   meanwhile) and, when the answer is yes, skips every *step* of the `build`
   jobs and the whole of `publish`; a checked-out state it cannot diff builds.
   The skip is neither a `paths-ignore:` filter nor a job-level `if:` on
   `build`, because each of those leaves a required check that never reports
   and a pull request that can never merge: a filtered-out workflow reports
   nothing at all, and a skipped *matrix* job never expands its matrix, so it
   reports one check run named for the uninterpolated
   `Build and test (${{ matrix.platform }})` while the two names the ruleset
   requires go unreported. Skipping the steps instead leaves both legs running
   and reporting success on every pull request, at the cost of a runner that
   starts and does nothing. Every job here therefore reports on every pull
   request, and `Work out what changed` joins the other three as a required
   check. Only an explicit "yes" skips: a `changes` job that fails rather than
   answers leaves the steps' condition unsatisfied-by-emptiness and they run,
   since a skipped job reading as success would otherwise carry a dead runner
   through to `publish` and leave a merge to `main` with no image at all.
   `publish` states that condition itself rather than inheriting it through
   `needs`, its `build` jobs now being successful on a documentation-only
   change rather than skipped. A documentation-only merge to `main` publishes
   no image, and no tag carries that commit's SHA.
   The script's `--skip-suite-only` mode asks the narrower question the
   allowlist above cannot: of the paths the image *is* the delivery path for,
   which does no test read? `docs/STANDING-DECISIONS.md` alone, and the mode
   answers yes only when every path in the change is either that file or in
   the inert set. The four specification files are deliberately not on that
   list, because `test/monitor-digest.test.sh` reads their real `## Gotchas`
   sections and a change to one of them can fail a test. The `changes` job
   emits the answer as a second output, `skip_suite`, computed in the same
   step and false whenever `docs_only` is true; exactly one step reads it —
   "Run the test suite inside the image", skipped when either output is
   `true`. Every other step of the `build` jobs, and the whole of `publish`,
   stays gated on the documentation-only answer alone, so a change in this
   narrower class still builds the image on both architectures, still
   verifies the toolchain, the crontab and the role guard, and still
   publishes to GHCR on `main` — it only declines to spend the suite's ~40
   minutes per architecture proving nothing such a change could break. The
   test covers all three outcomes and guards this one's premise: it fails if
   any `test/*.test.sh` but itself so much as names
   `docs/STANDING-DECISIONS.md` outside a comment, so the exemption lapses
   loudly the day a test starts depending on the file's content rather than
   going on quietly skipping a suite that by then exercises it.
1c. <a id="impl-ac-1c"></a>**The stack comes up from nothing and is idempotent.** With a `.env` copied
   from `.env.example` and `COMPOSE_PROFILES=local`, `docker compose up -d` in
   `deploy/docker/` starts `scheduler` and `dashboard-local` on fresh volumes;
   `curl http://127.0.0.1:$DASHBOARD_PORT/` and `/data.js` return 200; the
   scheduler's log shows supercronic reading the crontab and the 5-minute
   heartbeat firing; `agent-cycle.sh` and `review-cycle.sh` stand the node down
   through the requirement 2.4 guard with `ROLE=standby`; and a second
   `up -d` reports every container `Running` without recreating one.
   `docker compose --profile tailnet config` is valid. And the `local`
   profile's exposure is the host's loopback and nothing more:
   `docker compose --profile local config` shows `dashboard-local` publishing
   with host IP `127.0.0.1` and no `network_mode`, so the same curl from
   another machine on the host's network is refused. Check 1c-ii is the same
   property guarded on every commit, where this one needs a node.
1c-i. <a id="impl-ac-1c-i"></a>**A roll waits for a cycle.** `test/watchtower-pre-update.test.sh`
   passes: `deploy/docker/watchtower-pre-update.sh` exits 75 while, inside
   that pipeline's `lock_stale_after`, either `lock.json` or
   `review-lock.json` names a live process in the hook's own container — or
   *any* process in another container: the suite models one lock read under
   the writer's hostname and a neighbour's, deferring in both while the
   writer's process lives, and deferring for the neighbour regardless of the
   pid, which it has no way to check. It exits 0 when the locks are free,
   stale, unreadable, or dead by the writer's own reading, and exits 0
   rather than blocking when it cannot read `config.json` at all. Both cycle
   scripts stamp `host` into the locks they write; the suite pins that too.
   `docker compose config` shows every service on the
   agent-ops image carrying
   `com.centurylinklabs.watchtower.lifecycle.pre-update` pointing at that
   script, and `watchtower` carrying `WATCHTOWER_LIFECYCLE_HOOKS=true`.
   On a live node: `docker compose exec scheduler
   /app/deploy/docker/watchtower-pre-update.sh` echoes its finding and exits
   0 when idle, 75 during a cycle. The same suite also pins the
   `roll-pending` override (requirement 68 (Finish-then-continue), agent-ops#1096, scoped by
   agent-ops#1102): a valid, unexpired `$state_dir/roll-pending.json` makes
   the hook exit 0 despite a live `lock.json` naming a live process in the
   hook's own container — but never despite a live `review-lock.json`, which
   still defers on its own ordinary judgement whatever the marker says, and
   whose deferral the hook's own output never reports as an override; an
   expired or unparseable marker leaves the ordinary lock-based judgement
   above unchanged; and no marker at all behaves exactly as it did before the
   marker existed. The allow the override does grant says so in the hook's
   own output — it names the lock it overrode rather than the "no cycle in
   flight" the marker-free allow reports. And the same suite pins the
   compose-apply deferral (agent-ops#1913): a `$state_dir/.compose-reconcile.json`
   reading `applying` with a fresh `at` makes the hook exit 75 on an otherwise
   idle node, and keeps it at 75 even where `roll-pending` has just overridden
   a live `lock.json`; a marker whose `at` is fresh and whose `since` is hours
   old still defers, and the line reports the `since`, because an apply still
   running has its `at` rewritten every tick and what an operator needs is
   when it began; and the same marker past the ten-minute bound, one whose
   `at` will not parse, one holding any other status, junk, and no marker at
   all each leave the hook exactly where it was.
1c-ii. <a id="impl-ac-1c-ii"></a>**The dashboard is published to the host's loopback and to no network.**
   `test/dashboard-exposure.test.sh` passes: in `deploy/docker/compose.yaml`
   every port `dashboard-local` publishes is scoped to `127.0.0.1`, the mapping
   is `127.0.0.1:${DASHBOARD_PORT:-8787}:8787` so `DASHBOARD_PORT` moves only
   the host side, and it carries no `network_mode`; its server is told to bind
   `0.0.0.0` on that same container port, without which the published mapping
   would reach nothing; the `tailnet` `dashboard` is in the sidecar's namespace
   (`network_mode: service:tailscale`), publishes no port and is given no bind
   address, so it keeps loopback where Serve proxies to it; the `node-health`
   service (requirement 60d) publishes the one mapping
   `127.0.0.1:${NODE_HEALTH_PORT:-8788}:${NODE_HEALTH_PORT:-8788}`, takes no
   `network_mode`, and is told to bind `0.0.0.0` on that same port; those two
   are the only services that publish anything at all, and every mapping
   either of them declares is `127.0.0.1`-scoped.
   `scripts/serve-dashboard.sh` invoked with
   no bind address resolves to `127.0.0.1`, and to `0.0.0.0` when given it.
   The socket-level half of the property — that a request from another machine
   is refused — is check 1c, which needs the stack up; this check runs in the
   image, where there is no Docker.
1c-iii. <a id="impl-ac-1c-iii"></a>**A node can tell when its compose.yaml has fallen behind.**
   `test/compose-drift.test.sh` passes: identical copies read `in-sync` and
   so do copies differing only in comments and blank lines; a material
   difference reads `drifted` with a positive `diff_lines`; a missing mount
   reads `unmounted` inside a container and `null` outside one; an image
   carrying no copy of its own reads `null`, never a guess; no path returns
   non-zero (the verdict is computed inside a heartbeat push running under
   `set -e`); and `deploy/docker/compose.yaml` mounts itself read-only at
   `/host/compose.yaml`, the path the library reads — the line through which
   the check is armed. The file-level assertions of 1c-i pin the
   repository's copy and prove nothing about any node's; this check is what
   covers the gap they leave.
1c-iv. <a id="impl-ac-1c-iv"></a>**A node can tell when it has fallen behind the newest published
   image.** `test/image-drift.test.sh` passes: a checkout (not a CI-stamped
   image) reads `null`; a matching commit reads `current`; a differing one
   reads `behind`, carrying the registry's commit and the image's creation
   label; a token, manifest or config-blob fetch that fails, or an image
   carrying no revision label, reads `unverified` with a reason, never a
   guessed verdict; the multi-platform index this repository actually
   publishes is walked one level to reach the labels, into a per-platform
   image and never into one of the attestation manifests buildx writes
   beside them (whose config blob carries none of these labels, so reading
   one would report the whole fleet `unverified` while the registry was
   answering perfectly well); a second call inside
   `IMAGE_DRIFT_TTL` costs no network call, while an empty cache-file path
   always re-fetches; no path returns non-zero; and
   `.github/workflows/build-image.yml`'s publish step stamps both the
   revision and creation labels the check reads. `test/check-node-image.test.sh`
   passes against a stubbed `docker`: current, and behind within the
   configured grace, both exit 0; behind past the grace exits 1, naming the
   registry commit and the grace exceeded; a registry the container could
   not reach exits 2; a node not running a CI-stamped image at all is not a
   failure; and no `compose.yaml` in the stack directory, or a scheduler
   that cannot be exec'd into, is exit 2, never a clean pass.
1c-v. <a id="impl-ac-1c-v"></a>**The tailnet sidecar refuses to start without `TS_AUTHKEY`, and does
   not retry forever over one — and neither does the dashboard sharing its
   namespace.** On a live node with the `tailnet` profile selected and
   `TS_AUTHKEY` unset, `docker compose up -d` exits non-zero — Docker reports
   `cannot join network namespace of container: … is restarting` — leaving
   both `tailscale` and `dashboard` in a failed state, and `docker compose
   logs tailscale` carries one line per attempt naming the missing variable
   and the active profile (six identical lines, observed on issue #728's
   keyless run against `main` @ `412b025`), never reaching `tailscaled` — no
   new node key is registered against the tailnet. `docker compose ps` shows
   neither restarting indefinitely — but they settle by **different
   mechanisms, and at different counts**, and the check asserts each
   separately. `tailscale` reaches `Exited` with a
   `RestartCount` of 5: it starts, exits non-zero six times over (one
   initial attempt plus five retries), and its own `restart: on-failure:5`
   bounds the retries where the rest of the file is `unless-stopped`.
   `dashboard` reaches **`Created` with a `RestartCount` of 0**: joining the
   network namespace of a container that is not running is refused at
   *start*, so the container never runs, never exits, and a policy keyed on
   exit codes is never consulted — whether that policy is `on-failure:5` or
   the anchor's `unless-stopped` makes no observed difference, since neither
   is ever consulted; both settle at zero attempts immediately
   (TD-PPagop-26091401 records the measurement against TD-PPagop-26082303,
   whose belief that `unless-stopped` retries this failure indefinitely did
   not reproduce). `docker events` over the window shows five restart
   attempts for the sidecar and none for the dashboard, not an unbounded
   stream from either.

   The dashboard half is **observed**: on VM1, 2026-08-24, `dashboard` sat at
   `status=created, RestartCount=0, ExitCode=128` behind a `tailscale` at
   `status=exited, RestartCount=5, ExitCode=1`. That run had `TS_AUTHKEY`
   *set but invalid* rather than unset, so it is not this check's own
   precondition and does not discharge it — the sidecar failed at
   `tailscale up` instead of at the entrypoint. It transfers for the
   dashboard regardless, whose view of both cases is identical: the sidecar
   is stopped, and the namespace cannot be joined. The sidecar's own unset
   path — one line per attempt naming the missing variable, `tailscaled`
   never reached — is separately observed, on issue #728's keyless run
   against `main` @ `412b025`, corroborated on the deployed node
   `ockham-container` with `TS_AUTHKEY` genuinely absent.
   With `TS_AUTHKEY` set, the same `up -d` starts both containers normally and
   `docker compose exec tailscale tailscale status` succeeds.
1c-vi. <a id="impl-ac-1c-vi"></a>**A node applies its own merged compose.yaml, and only when it is
   safe to.** `test/compose-reconcile.test.sh` passes against a stubbed
   `docker` that creates nothing: identical copies read `in-sync`, run no
   docker command and log nothing; drift with every required `${VAR}` present
   and no lock held installs the image's copy byte-for-byte, runs exactly one
   `docker compose --project-directory <dir> up -d --remove-orphans`, keeps
   the file's **inode** (a bind mount of a file pins the inode it was created
   against), leaves `.env` untouched, and logs one `compose-reconciled`
   carrying both digests and `cycle: null`; the tick after it finds nothing to
   do. That recreate is asserted to run in a **transient sibling** — a
   `docker run --rm` of the image the stubbed daemon reports for this
   container, taking this container's own mounts by `--volumes-from` and its
   own memory, pids and cpu ceilings read back from the daemon, no network,
   no signal proxying, no daemon-side log, `docker` as its entrypoint and the
   socket it was given named in its `DOCKER_HOST` — and never from inside the
   project, which is the whole of agent-ops#1913. The stub models what each of
   the two shapes leaves behind, so the property held to is the outcome and
   not the command line: **a tick killed exactly where the recreate would kill
   it ends with every service of the project running**, its marker reading
   `applying` with `pending_apply` and its `to` digest, and the next tick
   retries the recreate and settles it `reconciled` — with the project still
   running, the retry cleared, and a `from` that is the digest the apply
   replaced rather than the one it installed. A container whose own id the
   stubbed daemon cannot name reads `deferred`, installs nothing and recreates
   nothing at all, while one whose project directory is spelt with a trailing
   slash reconciles, the lookup asking for the path Compose would have cleaned
   it to. While a container carrying the apply's own name and label is alive,
   a tick reads `applying` with a fresh `at` and starts no second recreate,
   although a held `lock.json` and a live `roll-pending.json` would each have
   deferred it, and logs no further event.
   A `${VAR}` with no default that `.env` does not define reads `refused`,
   names the variable and changes nothing — while the same variable carrying
   a default does not, which is what distinguishes the check from a scan that
   would refuse every node. A held `lock.json` or `review-lock.json` reads
   `deferred` and applies nothing; the same lock past `lock_stale_after` does
   not defer; a live `roll-pending.json` reads `deferred` on its own, with no
   lock held at all and with the marker's own window in `detail` rather than
   in `reason`, while an expired one and one whose `until` will not parse hold
   nothing back; a marker re-armed under a wait already running is the same
   wait, keeping its `since` and logging nothing further, and a wait longer
   than `lock_stale_after` stops honouring the marker and applies; and a
   second and third deferral for the same reason log no further event. A recreate that exits non-zero reads
   `deferred` with `pending_apply`, having already installed the file, and the
   next tick retries the recreate although no drift remains — and two further
   failed ticks whose stubbed `docker` prints a different last line each time
   still log one event between them, the stub varying deliberately because
   that line lives in `detail` and only `reason` is compared. A cycle starting
   between the install and the retry reads `deferred` naming that cycle and
   **keeps** `pending_apply`, since a postponed retry that was discarded would
   leave the node running a `compose.yaml` none of its containers came from.
   A stack this container's uid can neither write nor read `.env` in — the
   root-owned stack `cloud-init.yaml` leaves, played by the suite's own files
   with the owner's bits removed, which the stub lifts only for the daemon's
   `docker cp` and for a sibling started with `--user 0` — reconciles,
   installing the file in place and leaving every mode as it was; an in-sync
   node with an unreadable `.env` still reads `in-sync` and asks the daemon
   nothing; a `compose.yaml` this container cannot read is `refused`, naming
   its owner and mode and a `chmod` whose path is quoted; an install the
   sibling cannot perform is `deferred` as the write that failed, with
   `pending_apply` kept and the file untouched; an `.env` the daemon cannot
   hand over is `deferred` and names `.env` rather than any variable; and no
   `.env` at all refuses as every required variable missing. A marker with no
   `since`, and one already holding `"since": "false"`, start the clock on
   the tick that reads them; an unchanged `in-sync` keeps the `since` it
   began with; and a newline in a stored `reason` keeps `pending_apply`, the
   status and both digests. The audit (`reconcile-compose.sh --audit`, called
   both directly and through the script with `state_dir` from `config.json`)
   passes a fresh `in-sync`; fails a verdict four ticks old, a refusal
   (quoting it), a lock deferral older than the larger lock bound, any
   deferral that is not for a lock or a roll, an `applying` that old, a
   marker that will not parse or has no `at`, and a container the daemon
   cannot name by its project directory (naming the directory it was brought
   up from and the quoted `cd` that fixes it); reports a fresh lock or roll
   deferral and a fresh `applying` as information; reports no verdict as
   `unable` on a container that has just started and as a failure on one up
   for four ticks; keeps a multi-line reason on one line; and writes and logs
   nothing and asks the daemon only `ps` and `inspect`.
   `compose.yaml`
   declares the service in the `auto-update` profile with the socket, the
   same-absolute-path project mount, `network_mode: none`, neither shared
   anchor and no secret of its own — the lines through which the reconciler is
   armed and bounded, the way 1c-iii pins the mount line that arms the drift
   check.
1d. <a id="impl-ac-1d"></a>**State replicates per node, and comes back as peers.**
   `test/state-sync.test.sh`
   passes: a push carries the logs, cycles, reviews and switch but not the
   locks or the dashboard, and — of the `gh` transport shim's own state
   (requirement 2.0e) — carries its per-call ledger and `budget.json` but
   neither its stored response bodies nor its lock files, onto the node's own
   `nodes/<NODE_NAME>` branch
   with a heartbeat naming the node, its role, its newest cycle, its version,
   its compose-drift verdict (asserted end to end: a node whose fixture
   copies differ publishes `drifted` with the differing-line count), an
   image-drift slot (what the verdict itself says is 1c-iv's own coverage;
   this asserts only that state-sync.sh asks for one, and that its cache file
   does not replicate), and its own node-scoped switch (issue #379,
   `toggle_switch_summary` — a node whose `disabled.json` is set publishes
   `switch.disabled: true` with the record's reason); a second
   push amends rather than accumulating history; a standby pushes its own
   branch and never a peer's; the branch keeps
   `cycles_retained` cycles while the node's own `cycles/` and `reviews/` are
   pruned to the newest `state_local_cycles_retained` by the same push,
   newest always kept, and `log.jsonl` is byte-for-byte untouched by that
   same local prune regardless of how many cycle/review directories it
   removes (requirement 2.6d); every file the push commits has been through
   `redact_file` first
   (requirement 2.5, `lib/redact.sh`) — a token- and home-path-shaped
   fixture planted in `cron.log` and in a cycle transcript reaches the
   branch as `[REDACTED-TOKEN]` and `~`, neither raw form survives, and the
   redacted transcript still parses as JSON, while a file the pass cannot
   rewrite at all is warned about and dropped or emptied rather than
   committed as it stands, every other file in the same push still reaching
   the branch redacted, and a file that resists removal and truncation too
   abandons the push with a `state-sync-push-failed` event and no commit
   (requirement 2.5's cascade, agent-ops#1679 and agent-ops#1703); a
   configured `notify_webhook_url` reaches the branch as `[REDACTED-WEBHOOK]`
   too — no shape rule matches a bearer secret carried in a URL path, so this
   asserts the runtime-literal registration (agent-ops#1721) instead — while
   an unrelated URL of similar shape is left untouched, and with the value
   unset the existing shape-based redaction is unaffected; a `notify_webhook_url`
   (config-sourced or from `NOTIFY_WEBHOOK_URL`) containing a newline registers
   as a no-op instead of poisoning the shared rule set — the existing
   token-shape redaction still applies to the rest of the same push, the raw
   value itself reaches the branch unmasked, and `state-sync.sh` warns about
   it on stderr rather than leaving the gap silent (agent-ops#1730);
   a fetch materialises a peer whole
   under the peers directory, leaves the node's own `state_dir` alone, never
   includes the node itself, and prunes a peer whose branch is gone; the
   union read (`lib/fleet.sh`) carries both nodes' events in time order; and
   pipeline events written through `log_event` carry the node's name. Over a
   union holding a spliced peer line whose head is older than the node's own
   `limit-hit` and whose recovered `limit-hit` is newer, a whole record `cat`
   joined to the next peer file's first record, and a NUL run in a third,
   `fleet_logs` puts every record at its own timestamp's place, leaves every
   line parseable with no NUL byte, passes a record that carries a nested
   record through byte for byte, counts the three damaged lines in its
   damage file and removes its candidate file; the freeze's start read off
   that union is the node's hit and the governing hit the recovered one; a
   `sort`, `awk`, candidate `jq` or `tr` that fails makes the build fail and
   still leaves no candidate file; and a clean union builds with nothing
   counted. The same file covers `fleet_repair_log`: a NUL run is cleared
   from a plain-text and a JSONL target alike, with the stump it cut dropped,
   the record it ran into recovered and the loss recorded; a spliced line
   with no NUL byte is replaced by the record split out of it, in its place,
   with a `log-repaired` record counting one line dropped and one record
   recovered, and a second call adds nothing; a damaged line with no intact
   record and a line that is not a record are both dropped and counted, with
   none recovered; a record carrying a nested record is left exactly as it
   is; a whole record that lost only its newline is kept with the one it ran
   into; a spliced line before an unterminated last line is repaired, with
   the last line kept byte for byte and unterminated after the repair
   record, and a file whose only damage is that line is not rewritten; a
   file holding a NUL run and a splice recovers the splice's record too; a
   step that fails under `set -e` (the `awk` that counts the plan) ends the
   repair rather than the caller, leaving the file and no working copy
   behind; and the swap keeps a file that grew during the repair, discarding
   the repaired copy, while replacing one whose size is unchanged.
1e. <a id="impl-ac-1e"></a>**The fleet flags reach every node.** `test/toggle.test.sh` passes,
   including its fleet section against the contents-API stub (`TOGGLE_GH`):
   a flag one node writes reads as disabled on another; an unreachable
   state repo falls back to the cached copy, and to enabled with none; a
   404 is clear and clears the cache; a garbage flag is disabled; the limit
   flag only ever extends; a delete never reports cleared for a flag still
   set — including on a repo-level 404 from its read-for-sha, which it
   probes with `fleet_repo_visible` unconditionally rather than accepting as
   clear (TD-PPagop-26081604) — and reports which of the two ways it can
   succeed actually happened — `deleted` when a flag was removed, `absent`
   when there was nothing to remove — which
   `fleet_flag_write_outcome`/`fleet_flag_delete_outcome` (issue #426)
   translate, along with a genuine failure, into the `ok`/`failed`/
   `unconfigured` vocabulary requirement 33 documents; and — end to end,
   offline — `--disable` on node A publishes `fleet/disabled.json` and both
   real pipelines on node B stand down naming the fleet switch, `--enable`
   on A genuinely removes the flag, and a `fleet/limit.json` published by A
   stands B down until its `resume_at`.
   The same file covers requirement 2.3's actor/kind fields and requirement
   2's kind gates (#244): a disable record carries `kind: manual` and a
   non-empty `actor` that is never `unknown` (`NODE_NAME` when set, the
   user otherwise, `id -un` with no `USER` at all); the published
   `fleet/disabled.json` names the setting node as its actor; a limit flag
   published with evidence carries `kind: auto`, its node as `actor`, and
   the evidence; a hand-written `kind: manual` `fleet/limit.json` stands a
   node down with a reason naming its actor and the manual kind, is not
   probed (no probe note in the reason) and is not cleared; and an
   automatic freeze older than `limit_escalate_after_hours` attempts the
   1c escalation (offline, where `gh` fails fast, the attempt is the logged
   `warning` naming the freeze's start). The same file covers `--this-node`
   (requirement 2.3, #379): `--disable --this-node` reports plainly that only
   this node stands down, writes the local record and publishes no fleet
   flag, and a peer's own cycle is unaffected; `--enable --this-node` leaves
   a fleet flag another node set untouched while clearing only the local
   record; a node carrying both a node-scoped disable and a fleet disable
   stands down for the local one first and, once that alone is cleared, for
   the fleet one next; a node-scoped disable clears itself and logs `disable
   expired` carrying `scope: "node"` and no `fleet_flag`, on the same TTL
   terms as the fleet switch; a fleet-wide disable past its TTL clears itself
   the same way, logging `fleet disable expired` carrying `scope: "fleet"`
   and `fleet_flag: "ok"` and actually removing `fleet/disabled.json`
   (issue #426, defect 3 — the outcome used to be discarded); and
   `--this-node` given with a command other than
   `--disable`/`--drain`/`--enable` (`--status` here) exits 64 naming the
   three it modifies (requirement 2.3d). Every `disabled`/
   `enabled` event this file's e2e block logs is asserted for `scope` — a
   plain `--disable`/`--enable` carries `"fleet"`, a `--this-node` one
   `"node"` and no `fleet_flag` at all — and a fleet-scoped `--enable` for
   `fleet_flag: "ok"`, including the case where the node clearing a live
   fleet flag has no local record of its own to report (acceptance 4: the
   defect that used to leave that resumption silently absent from the log).
   It covers `--status`'s own
   distinction in all three combinations: with only the local record set it
   reports no fleet switch and names `--enable --this-node` as what clears
   it; with only the fleet flag set it reports that record, its reason, and
   that this node adds no node-scoped disable of its own; with both set it
   reports both and spells out that `--enable` clears both while `--enable
   --this-node` leaves the node down under the fleet switch.

   The same file covers the record's `scope` (requirement 2.3): an unmodified
   `--disable` tags its local record `fleet` while still publishing the flag,
   and `--status` names that record as the fleet switch's mirror rather than
   as a second, node-scoped disable; `--enable --this-node` refuses a mirror
   with exit 64, naming plain `--enable`, and leaves the record in place; a
   mirror that survives a peer's `--enable` is reported as a leftover of a
   cleared fleet switch and cleared by `--enable` on its own node; a
   `--disable` whose fleet publish fails is retagged `node` with its
   `disabled_at` unmoved and no flag published, and `--enable --this-node`
   then clears it; `--disable --this-node` tags `node`, and that scope
   reaches peers through `toggle_switch_summary`; and a record written
   without the field reads as `node` through both `toggle_scope` and the
   summary.

   The same file covers the per-process memo's own key and its hit
   (requirement 2.3a): a `clear` memoised by a default-mode read is not
   served to a `probe-404` read of the same flag and the same `state_dir`,
   which probes for itself and reads `unreachable`; and a memo entry that is
   empty, or that has vanished since it was written, falls through to a live
   fetch rather than being served as a confirmed answer.
1e-i. <a id="impl-ac-1e-i"></a>**The drain is a mode on the same switch, and never loosens a stop
   (requirements 2.3d, 2.2c, 2.9).** `test/toggle.test.sh` passes: at the
   library level, `toggle_disable` defaults the record's `mode` to `"stop"`
   and writes `"drain"` when asked, `toggle_mode` reads either back and
   defaults a record with no field, an empty record and no argument at all to
   `"stop"`, `toggle_switch_summary` carries `mode` to peers, and a drain
   record still reads `.state == "disabled"` — mode is orthogonal to state,
   which is why `review-cycle.sh` needs no branch of its own. End to end,
   offline: `--drain` with no reason exits 64 naming the requirement;
   `--drain <reason>` writes an otherwise ordinary switch record carrying
   `mode: "drain"` and logs a `disabled` event carrying `mode` beside `scope`;
   `--status` reports `DRAINING` for it and never `DISABLED`; `--drain` over
   an active stop exits 64 naming `--enable` as the way out and leaves the
   stop's own record and reason untouched; a peer's unmodified `--disable`
   likewise refuses a fleet-scoped `--drain` on a *second* node that carries
   no local record at all, leaving `fleet/disabled.json` a stop and writing
   no record on the refusing node, while `--drain --this-node` under that
   same fleet stop is allowed and leaves the flag untouched; `--disable` over an active drain
   tightens it to `mode: "stop"` with the new reason; `--drain` over an active
   drain extends it, logging `extends`; `--enable` clears a drain exactly as
   it clears a stop; and a real `review-cycle.sh` run under a drain exits 0
   logging a `review-stand-down` whose reason names the drain mode rather than
   a bare `disabled`.

   `test/drain.test.sh` passes, covering `lib/drain.sh`'s own pure functions
   against a stubbed `lib/claim.sh` (the same `"$AGENT_OPS_ROOT/lib/claim.sh"
   claims <slug>` seam `agent-cycle.sh` uses, so no `gh`, lock or cycle is
   involved): `drain_remaining_count`/`drain_at_rest` read zero and at-rest
   for empty bands and no claims, count the four finishing bands across
   repos, still surface a live finishing-source claim whose pull request the
   gather has not seen yet, ignore a claim that names no finishing-source ref,
   and take the *larger* of the two counts rather than their sum so a claim
   its own band already counts is not doubled; `drain_write_state`/
   `drain_read_state` round-trip `{disabled_at, remaining, at_rest,
   checked_at}` and read as `null` before any cycle has written one; and
   `drain_status_line` says so honestly when no cache exists or the cache
   belongs to an older drain, and otherwise reports `DRAINING` with the
   remaining count or `DRAINED` with the check's own timestamp. The
   `drained` event's own dedup (`drain_event_logged`) is asserted against a
   union log carrying a matching `disabled_at`, a differing one, and none; a
   spliced line in the union does not hide a matching event; and a read that
   fails outright answers "not logged" and reports itself through
   `guard_warn`.
1f. <a id="impl-ac-1f"></a>**A provider-qualified model id resolves; an unsupported one fails fast
   (requirement 1a).** `test/model-id.test.sh` passes: a bare id and its
   `anthropic/`-qualified form resolve to the same value; an empty value (the
   "disable this stage" convention) passes through unresolved; a qualifier
   naming any other provider fails, printing nothing and naming the offending
   key and provider on stderr; and an assignment of the rejected form under
   `set -euo pipefail` — the exact context every `cfg` read in `agent-cycle.sh`
   and `review-cycle.sh` uses — aborts the script rather than silently
   continuing with the qualified string. The same file covers the two
   resolution forms requirement 1a distinguishes: `resolve_model_id_into`
   assigns the bare id to the variable it names *and* leaves the provider
   recorded in the caller's own `MODEL_PROVIDER`, while the printing
   `resolve_model_id` returns the identical bare id and leaves that map
   empty, because the command substitution it is called in discards the
   recording; an empty value assigns empty, records nothing and succeeds,
   since the three cycle scripts call this under `set -e` and a disabled
   stage must not abort startup; and a rejected qualifier fails and records
   nothing.
1g. <a id="impl-ac-1g"></a>**Every shell script in the repository is shellcheck-clean, and a caller
   may lint a named subset instead of the whole tree.** `./scripts/lint-shell.sh`
   exits 0. Invoked with no arguments, it discovers the file set — every
   tracked `*.sh`, plus every tracked file whose first line is a sh or bash
   shebang, so the init scripts and git hooks are included and a script added
   tomorrow is covered without anyone adding it to a list. Invoked with one or
   more arguments that each name a file that actually exists, it lints only
   those files instead, through the same mechanism, so the size guard
   (acceptance check 1g-i) and the confined SC1091/SC2154/SC2034 handling apply to
   a selected file exactly as to a swept one; an argument that does not name
   an existing file is not a selector and is forwarded to shellcheck as an
   option instead, same as every argument is when no selector is present —
   there is no separate flag for this, and no new validation for a typo'd
   path. Either way the files are checked **one process
   per file** with `-x`, which is what lets `source` resolve between the
   pipelines and `lib/` instead of raising SC1091 on each of them. `-x` follows
   a `source` by path whether or not the target was also passed in, so the file
   set does not have to share a process for this to work; what sharing one did
   do was couple every script's fate to every other's, and a process that died
   on the largest script took the other 253 scripts' coverage with it (#770).
   Clean means
   nothing reported at all, info findings included; a false positive is
   silenced by a `# shellcheck disable=` in the file that carries it, with a
   comment saying why, never by an exclusion in the runner.
   `.github/workflows/shellcheck.yml` runs the same script on every pull
   request against a pinned shellcheck (component 10).
   `test/lint-shell.test.sh` passes.
1g-i. <a id="impl-ac-1g-i"></a>**A script too large to lint in the memory available is degraded, or —
   where not even that fits — skipped, and never allowed to kill the cycle;
   and this is judged against every file, not only ones above some fixed line
   count (agent-ops#1305).** What "too large" measures is the **union `-x` actually
   parses** — the file plus every file it names in a `# shellcheck source=`
   directive, transitively, each counted once (`analysed_lines`,
   `scripts/lint-shell.sh`) — and never the file's own length. #771 is why
   the distinction matters: splitting `agent-cycle.sh` moved its bulk into
   the `lib/*.sh` modules it sources, and `-x` re-inlines every one of them,
   so the file's own `wc -l` fell from 10,136 to 2,865 while the union it
   costs stayed at 26,262. A guard reading the file's own length would have
   declared the problem solved and gone on to OOM-kill the node it ran on.
   The largest unions in this tree are 35,674 lines for `agent-cycle.sh`,
   12,953 for `scripts/publish-dashboard.sh`, 9,367 for `scripts/doctor.sh`
   and 7,196 for `review-cycle.sh` — every one of them a whole entry point's
   worth of `lib/*.sh`, and every one of them growing with the tree, which is
   the reason the guard costs a union rather than compares it to a constant.
   The GHC runtime shellcheck is built on ignores `+RTS -M` (the release
   binary is not linked with `-rtsopts`) and reserves a 1 TB address space, so
   neither a heap cap nor `ulimit -v` can bound it; the only thing that can is
   not running it. So `scripts/lint-shell.sh` reads the smallest of its own
   cgroup ceiling, its own explicit `LINT_SHELL_BUDGET_MIB` (unset by
   default — never the *parent* cgroup's `memory.high`, deliberately, since
   agent-ops#1620: that ceiling has to be sized for
   `scripts/publish-dashboard.sh`'s real working set, ~1.4 GiB, and this
   guard needs roughly ≤700 MiB to keep steering the largest unions off `-x`,
   and one knob could not hold both without livelocking the node the way it
   did for most of 2026-09-16) and `MemAvailable`, names whichever of the
   three actually bound it, and estimates **every** file's own cost to follow
   with `-x` by interpolating/extrapolating between three measured points
   (`estimated_follow_mib`: 4,945 union lines at 396 MiB, 23,569 at 1,983
   MiB, 26,262 at 4,543 MiB, the last of these a floor rather than a peak
   since that run never finished) rather than gating on a fixed line count
   first. This is what closes agent-ops#1305's own reading of the guard: a
   line count picked to isolate one file says nothing about what the node
   running it can afford, and the former 10,000-line gate let everything
   below it follow sources unconditionally, whatever the budget.
   `scripts/doctor.sh` is the clearest case — 9,367 union lines, under that
   gate, and an estimated 772 MiB to follow, against the 768 MiB a node
   explicitly budgeted at that figure actually has. That is an uncosted
   `shellcheck -x` sized at the incident's own first measured kill (964 MB
   anon-rss), on a node the guard was reporting nothing about. A file whose
   estimate fits the budget follows with `-x`; one whose estimate exceeds it
   but whose budget is still at least `LINT_SHELL_PLAIN_MIB` (1,024, a
   roughly constant cost regardless of the file's own size) is linted
   without `-x`, suppressing SC1091, SC2154 and SC2034 for that file — all
   three artefacts of the degradation rather than findings about the code:
   without `-x` shellcheck sees none of the modules the file sources, so a
   `source` line raises SC1091 and every variable crossing the boundary reads
   as unassigned (SC2154) or as assigned and never read (SC2034), which after
   #771 is 25 of them in `agent-cycle.sh` with nothing wrong with any of them.
   Below `LINT_SHELL_PLAIN_MIB` the file is not linted at all, and which of
   the two reduced modes a node lands in is a property of that node's budget
   rather than of the file. A scheduler container with `LINT_SHELL_BUDGET_MIB`
   unset has its whole container ceiling to work with — 1,536 MiB by default,
   which is above `LINT_SHELL_PLAIN_MIB` — so nothing there is ever skipped:
   `agent-cycle.sh` without `-x` completes in 634 MiB, comfortably inside that
   ceiling, where before #771's split it was killed at that ceiling and
   skipped outright. A node whose operator has set `LINT_SHELL_BUDGET_MIB` to
   today's typical parent-ceiling figure — 768 MiB, `scripts/
   cgroup-parent-setup.sh`'s own `--limit` default — has that instead, which
   is *below* `LINT_SHELL_PLAIN_MIB` — so on one of those the skip path is
   reached in practice, for every file whose estimate exceeds the budget:
   `agent-cycle.sh`, `scripts/publish-dashboard.sh` and `scripts/doctor.sh` as
   the tree stands. Setting it is a node-level act, like the Vercel variables
   above: `LINT_SHELL_BUDGET_MIB` is named in `deploy/docker/compose.yaml`'s
   shared environment block, so a node carries it by way of its own `.env` and
   a `docker compose up -d` — that block being an allowlist with no
   `env_file:` beside it, a variable absent from it never reaches the
   container at all, however it is spelled in `.env`. That is the trade
   agent-ops#1305 accepted deliberately —
   reduced local coverage, announced on stderr, is strictly better than an
   invocation the node cannot afford — and it is
   another reason the skip does not fail the run: CI has the memory and
   checks all three in full. What no local ceiling can buy is following the
   sources *inside* it, and nothing else can either: a 172-line entry point
   over the same modules — 23,569 lines of union — already costs 1,983 MiB,
   against `agent-cycle.sh`'s 26,262-line union at the time of that
   measurement passing 4,543 MiB before the kernel stops it. The cost is the
   union, the union is this pipeline's whole codebase, and following it from
   an entry point is a CI-sized job by construction. So the guard's reduced
   modes are permanent for the largest entry points rather than a stage on
   the way to something better, and the checks they give up are recovered in
   CI rather than one day locally.
   Degrading and skipping are both announced on stderr naming the file, its
   own length, its union, the estimated cost, and which ceiling bound the
   budget, because silence would read as coverage that did not happen; a skip
   alone does not fail the run, since CI has the memory and does check it —
   `.github/workflows/shellcheck.yml` sets `LINT_SHELL_FOLLOW_MIB: 0`, which
   disables the guard outright (every file follows with `-x` whatever the
   estimate says) rather than merely raising a threshold, so the gate's
   coverage does not quietly track how much memory a runner happens to have,
   which is also what keeps the three suppressed checks checked in full on
   every pull request.
1g-ii. <a id="impl-ac-1g-ii"></a>**Every GraphQL document this repository sends still validates
   against GitHub's live schema, checked nightly rather than at merge time.**
   `.github/workflows/graphql-drift.yml` runs
   `./scripts/check-graphql-drift.sh` on a daily schedule, and exit 0 is every
   discovered document validating (component 10a). Being off the pull-request
   path is the point rather than a compromise: this failure arrives without a
   commit. GitHub moved `mergeMethod` and `mergingStrategy` off `MergeQueue`
   onto `MergeQueue.configuration` between 2026-08-16 and 2026-08-23, GraphQL
   rejects the whole document for one unknown field, and
   `merge_queue_for_branch` — which asked for both and read neither — returned
   non-zero on every call for the six days that followed, while `landing_arm`
   reported only its own gate-7 refusal and the suite stayed green. Nothing a
   pull request could have gated would have caught that, and gating one on
   GitHub's endpoint being reachable would cost every merge for no return.
   A red run reaches the pipeline as a `failed-run-graphql-drift` candidate
   (requirement 19) for as long as its run is still inside the single
   unpaginated 100-run page of the default branch that both the Co-Ordinator's
   own live query and `scripts/gather-source-state.sh` read — measured at
   11h18m on 2026-08-29, so roughly the next seven hourly cycles and no
   longer. That is better than a mark on a page nobody opens and less than a
   durable work item; TD-PPagop-26082936 records the gap and what would close
   it.
   `test/graphql-drift.test.sh` passes: the repository's own documents are all
   discovered — `lib/issue-priority.sh`, `lib/landing.sh`,
   `lib/merge-queue.sh`, `prompts/implementer.md` and `prompts/reviewer.md`,
   seven documents between them — and all reach `gh` as a `{query, variables}`
   body whose document is wrapped, with neither mutation's field left
   collectable; a document declaring a variable named `$query` is checked
   rather than overwritten by its own placeholder; a document that never
   closes is annotated at the line it opens on instead of contributing
   nothing, and a prompt that describes the form in a code span before using
   it yields exactly one document, the real one; a moved field fails the run
   annotated with the file and the line its document starts on, in GitHub's own
   wording, and counts as answered because GitHub answered; a transport
   failure reports `0 of 2`, not `2 of 2`; an unreadable document alongside an
   unanswered one exits 2 rather than letting drift mask it; a response
   carrying a `type`d error beside real drift reports both; a multi-line
   GraphQL message stays one `::error` line; the three shape malformations
   report three distinct reasons; a file that calls `api graphql` and yields
   no document fails the run naming what discovery recognises; a variable type
   with no placeholder is annotated with its line; `--help` reaches the whole
   exit-code contract; `--list` lists a malformed document and exits 0, and
   exits 2 over a tree with nothing to list; a tree with no document at all
   exits 2 saying it refuses to report no drift; `test/`, this repository's
   CHANGELOG and this document itself all quote the delimiter and none is
   checked as a document, while a `prompts/` file carrying one is; two
   documents in one file are each found at their own line; and an anonymous
   shorthand query is wrapped like any other.
1g-iii. <a id="impl-ac-1g-iii"></a>**The four hand-pinned toolchain `ARG` defaults in
   `deploy/docker/Dockerfile` — `SUPERCRONIC_VERSION`, `SHELLCHECK_VERSION`,
   `CLAUDE_CODE_VERSION`, `GROK_BUILD_VERSION` — are checked against their own
   upstream release feed nightly rather than at merge time, and a stale pin
   is reported as an issue rather than fixed.** `.github/workflows/
   docker-toolchain-drift.yml` runs `./scripts/check-docker-toolchain-drift.sh`
   on a daily schedule (component 10b). None of these four is visible to any
   Dependabot ecosystem — unlike the base image and the compose/Action
   manifests `.github/dependabot.yml` already covers — because each is a
   bare version string an install step substitutes into a URL or an `npm
   install`, not a manifest entry any ecosystem parses (issue #2697). Being
   off the pull-request path, like component 10a's GraphQL check beside it,
   is the point: the drift this catches is an upstream release, which does
   not arrive with a commit to this repository, so gating a merge on it
   would cost every pull request for no return.
   The script never bumps a pin and never opens a pull request — issue
   #2708's own decide-tactical decision rejected that shape, because the two
   GitHub-released pins (`SUPERCRONIC_VERSION`, `SHELLCHECK_VERSION`) each
   sit beside two architecture-specific checksums
   (`*_SHA1SUM_{AMD64,ARM64}`/`*_SHA256_{AMD64,ARM64}`), so a correct bump
   recomputes three values, not one, which is implementer work rather than
   safe template substitution in a scheduled job, and because the rejected
   alternative — accepting manual review as the permanent model — is a
   standing human obligation, owner-only under requirement 36a condition 5.
   `SUPERCRONIC_VERSION` and `SHELLCHECK_VERSION` resolve against GitHub's
   releases API for `aptible/supercronic` and `koalaman/shellcheck`
   respectively (the same releases each one's own install step in
   `deploy/docker/Dockerfile` downloads from); `CLAUDE_CODE_VERSION` and
   `GROK_BUILD_VERSION` resolve against the npm registry's own `latest`
   dist-tag for `@anthropic-ai/claude-code` and `@xai-official/grok` — two
   different feeds, read through two different resolvers, never one path
   reused for both. `lib/github-limit.sh` is sourced ahead of everything
   else, exactly as component 10a's own script does, so a rate-limit refusal
   on either GitHub releases lookup is waited out rather than read as "could
   not check" — the issue-filing call gets that same coverage only because
   the workflow's own `GH_TOKEN` (`secrets.GITHUB_TOKEN`) is passed through
   as `techdebt_file_debt`'s `TOKEN` argument; the tokenless default every
   other `techdebt_file_debt` caller relies on execs `gh` directly (`env -u
   GH_TOKEN gh`) rather than the shadowed shell function, and would bypass
   this coverage entirely.
   Each resolved version is validated against a conservative character
   allowlist before it is used for anything else — interpolated into the
   filed issue body or into `--list`'s own output — since a GitHub release
   tag name or an npm `latest` version field is upstream-controlled text
   that could otherwise carry injected markdown or instruction-shaped
   content into the pipeline's own work queue (issue #2726). A version
   that fails the allowlist is treated exactly like an unresolvable one:
   logged, discarded, and never forwarded, so it exits the same way an
   unresolved pin already does rather than opening a new exit path.
   On any drift, filing goes through `lib/tech-debt-file.sh`'s
   `techdebt_file_debt` (component 23d) under a stable title, so a second
   scheduled run that finds the same or further drift comments on the issue
   a prior run already opened rather than filing a duplicate — the "updates
   the existing open one" half of the behaviour falls out of that dedup
   rather than this script tracking any state of its own between runs. The
   filed issue is labelled `pw::type:tech-debt` for the ordinary tech-debt
   gatherer to serve, never a pull request: bumping a pin, including
   recomputing the two GitHub-released pins' checksums, happens afterward as
   ordinary selected implementer work. The two GitHub-released pins' own
   issue text additionally names the checksum recompute, so the implementer
   who eventually picks up the filed issue is not surprised that the bump
   moves three values.
   Exit 0: every pin's upstream version was resolved — whether or not any had
   drifted, and whether a drift was newly filed or commented onto an
   existing issue. Exit 1: a pin had drifted but the filing itself failed.
   Exit 2: at least one pin's upstream version could not be resolved at
   all — never reported as clean, and never as drift, the same convention
   component 10a's own exit contract uses. `--list` prints every pin and its
   resolved upstream version and files nothing, never returning 1.
   `test/docker-toolchain-drift.test.sh` passes: stubbed against both a `gh`
   and a `curl` recorder — never the real GitHub releases API or the real
   npm registry, the same reason component 10a's own test stubs `gh` rather
   than asking GitHub — it asserts no drift files nothing; a drifted pin
   with no existing open issue opens one naming the stale pin, its pinned
   and upstream versions, and the checksum-recompute note; a drifted pin
   with an existing open issue comments on it instead of opening a second
   one; an unresolvable upstream version exits 2 and files nothing; a
   resolved version that fails the allowlist (one GitHub tag, one npm
   version, each carrying markdown-shaped text) exits 2, files nothing, and
   never appears in `--list`'s own output; and `--list` prints every pin
   without filing. Must pass `shellcheck`.
