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

1. `shellcheck agent-cycle.sh scripts/*.sh lib/*.sh` is clean.
1a. **The role guard holds in both directions.** `test/role.test.sh` passes:
   every value that is not `active` stands the node down with a cron-log line,
   exit 0 and nothing written under `state_dir`; `--dry-run`, `--once` and the
   switch commands run regardless of the role.
1b. **The image builds and carries the whole toolchain, on both
   architectures.** `docker build -f deploy/docker/Dockerfile -t agent-ops .`
   succeeds, and inside it, as user `agent`: `bash`, `git`, `jq`, `curl`,
   `python3`, `perl`, `flock`, `sha256sum`, `rsync`, `node`, `claude`, `gh`
   (≥ 2.60), `supercronic`, `shellcheck` and `squid` (the egress-proxy service's
   fence, requirement-checked at check 10) all resolve; `shellcheck
   --version` prints `0.10.0`, the same version
   `.github/workflows/shellcheck.yml` pins; `supercronic -test
   /app/deploy/docker/crontab` reports the crontab valid; the `test/` suite
   passes inside the container; and `/app/agent-cycle.sh` with no role set
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
1b-i. **A documentation-only change builds nothing, and everything else
   builds.** `test/is-docs-only.test.sh` passes: `scripts/is-docs-only.sh`
   calls a change documentation-only when every path in it is under `docs/`
   — except `docs/STANDING-DECISIONS.md` and every `docs/*-SPEC.md`, which the
   image *does* deliver to a running stage and so count as code — or is
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
   decide-tactical pass as its precedents; `monitor-cycle.sh` passes each
   specification's `$SCRIPT_DIR/docs/*-SPEC.md` path to `monitor_digest_gotchas`
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
1c. **The stack comes up from nothing and is idempotent.** With a `.env` copied
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
1c-i. **A roll waits for a cycle.** `test/watchtower-pre-update.test.sh`
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
   `roll-pending` override (requirement 39c (Finish-then-continue), agent-ops#1096, scoped by
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
1c-ii. **The dashboard is published to the host's loopback and to no network.**
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
1c-iii. **A node can tell when its compose.yaml has fallen behind.**
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
1c-iv. **A node can tell when it has fallen behind the newest published
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
1c-v. **The tailnet sidecar refuses to start without `TS_AUTHKEY`, and does
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
1c-vi. **A node applies its own merged compose.yaml, and only when it is
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
   `compose.yaml`
   declares the service in the `auto-update` profile with the socket, the
   same-absolute-path project mount, `network_mode: none`, neither shared
   anchor and no secret of its own — the lines through which the reconciler is
   armed and bounded, the way 1c-iii pins the mount line that arms the drift
   check.
1d. **State replicates per node, and comes back as peers.**
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
1e. **The fleet flags reach every node.** `test/toggle.test.sh` passes,
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
1e-i. **The drain is a mode on the same switch, and never loosens a stop
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
1f. **A provider-qualified model id resolves; an unsupported one fails fast
   (requirement 1a).** `test/model-id.test.sh` passes: a bare id and its
   `anthropic/`-qualified form resolve to the same value; an empty value (the
   "disable this stage" convention) passes through unresolved; a qualifier
   naming any other provider fails, printing nothing and naming the offending
   key and provider on stderr; and an assignment of the rejected form under
   `set -euo pipefail` — the exact context every `cfg` read in `agent-cycle.sh`
   and `review-cycle.sh` uses — aborts the script rather than silently
   continuing with the qualified string.
1g. **Every shell script in the repository is shellcheck-clean, and a caller
   may lint a named subset instead of the whole tree.** `./scripts/lint-shell.sh`
   exits 0. Invoked with no arguments, it discovers the file set — every
   tracked `*.sh`, plus every tracked file whose first line is a sh or bash
   shebang, so the init scripts and git hooks are included and a script added
   tomorrow is covered without anyone adding it to a list. Invoked with one or
   more arguments that each name a file that actually exists, it lints only
   those files instead, through the same mechanism, so the size guard
   (requirement 1g-i) and the confined SC1091/SC2154/SC2034 handling apply to
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
1g-i. **A script too large to lint in the memory available is degraded, or —
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
1g-ii. **Every GraphQL document this repository sends still validates
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
1h. **A log past `log_retained_bytes` rotates, keeps `log_generations`, and
   never touches `log.jsonl`.** `test/rotate-logs.test.sh` passes: a log under
   the threshold is left alone; one over it is renamed to `.1` and a fresh
   empty file takes its place; a second rotation shifts `.1` to `.2` rather
   than overwriting it, and a generation beyond `log_generations` is dropped;
   `log.jsonl` and `review-log.jsonl` grow past the threshold untouched; and
   `once-pr4-verify.log` is removed if present. `test/publish-dashboard.test.sh`
   passes its cron-panel case: with `cron.log` short and `cron.log.1` present,
   the panel's tail draws from both, newest last.
1h-i. **Analytics retention is a stated policy, and rotation and pruning
   both already conform to it (requirement 2.6d).**
   `test/rotate-logs.test.sh` passes an added assertion: the shipped
   config's own `analytics_retained_days` resolves to `0` (retain
   indefinitely) through `config_defaults`, the same resolution the pipeline
   itself uses, asserted beside the existing behavioural proof that
   `log.jsonl`/`review-log.jsonl`/`revert-rate.jsonl` never rotate — the
   policy and the exclusion that already conforms to it, pinned together.
   `test/state-sync.test.sh` passes the assertion added to its own
   local-retention case (1d): a push that prunes `cycles/`/`reviews/` to
   `state_local_cycles_retained` leaves `log.jsonl`'s content exactly as it
   was. `test/item-lifecycle.test.sh` passes its two-node fixture: two
   independent unions built by `fleet_logs` for two different nodes over the
   identical underlying events fold to identical `records[]`, and
   concatenating both folds' records and reducing by `{repo, item}` yields
   exactly one record per item, never two. `config.schema.json` declares
   `analytics_retained_days`, `default: 0`, with `x-docs.readme`/
   `x-docs.spec`, and `scripts/render-config-table.sh --check` passes with
   it rendered into all four `config-table` regions.
1i. **Per-installation prompt overrides extend or replace a stage's prompt,
   and the fingerprint tracks them (requirement 4a).**
   `test/prompt-overrides.test.sh` passes: with no `prompt_overrides`
   configured (or a stage absent from it), `stage_prompt_text` is
   byte-identical to `cat prompts/<stage>.md`; a configured `extend` list is
   appended in order, each fragment wrapped in the "specs outrank every
   prompt" disclaimer; a configured
   `replace` substitutes the base prompt entirely, with any `extend` still
   appended after it, and falls back to the shipped prompt when the
   configured file is unreadable; an override for a different stage has no
   effect; an unreadable base prompt that no `replace` covers makes
   `stage_prompt_text` fail rather than return empty; and `stage_prompt_sha`
   changes for every one of those cases,
   including a configured `extend` file that does not exist. The digest is
   content-addressed: relocating the whole installation (prompts, state
   directory, `$HOME`) with identical config and content computes the
   identical fingerprint, and a `replace` file whose content equals the
   shipped prompt's computes the no-override fingerprint, because it serves
   the same bytes. `prompt_overrides`'s own structural shape — a non-object,
   an unknown stage key, a non-object stage value, an unknown key within a
   stage, a non-array `extend`, a non-string `extend` entry or `replace` — is
   config.schema.json's concern rather than this library's (requirement 1b);
   test/config-schema.test.sh asserts one rejection per class, naming the
   offending path.
1j. **The Co-Ordinator's repo/work-sources table is config-driven, and names
   no consumer repo in `prompts/coordinator.md` (requirement 4b).**
   `test/coordinator-brief.test.sh` passes: `coordinator_work_sources_table`
   renders one Markdown row per repo, each `sources` entry numbered in the
   order given, in the order the repos array itself gives; reordering a
   repo's `sources` reorders its row's numbering; an empty `repos` array
   renders only the header and separator. `prompts/coordinator.md` itself
   contains no real consumer repo slug, including in its worked JSON
   examples, which use generic placeholder slugs instead.
   `test/noop-skip.test.sh` passes: a change to the rendered table busts the
   no-op fingerprint, and an input predating the `coordinator_work_sources_
   table` key canonicalises the same as one carrying it empty.
1ja. **The assembled Co-Ordinator prompt cannot outgrow its model's context
   window (requirement 4i).** `test/coordinator-input.test.sh` passes:
   `coordinator_fit_bands` hands an already-fitting array back byte-identical
   with `applied: false`; a `0`, non-numeric or non-array input changes
   nothing; an oversized array is trimmed to inside its allowance with every
   candidate still present, every identity field intact and the gatherer's own
   entry order undisturbed; each truncated body or comment ends in an elision
   marker naming its byte counts and its `url`; dropped comments are counted
   in `comments_elided` and the newest are the ones kept; the ladder's ninth
   and tenth rungs are `0:0:300` and `0:0:0`, an allowance only the
   identities fit lands on the tenth with nothing dropped and the first
   entry cap is the eleventh, while a fixture of the fleet's 2026-09-23 shape
   (317 entries, 251 of them tech-debt in one repository) settles on the
   identity-only rung inside the allowance that day's terms leave and its
   ~200-entry counterpart on the short-opening rung; an allowance no
   amount of prose-shedding can meet drops entries highest-`Priority`-and-
   freshest first, counted in `issues_elided`, and tech-debt entries
   freshest first, so the highest-numbered survive a cap; an allowance one entry cannot
   meet reports `fits: false` and still returns a usable array; `tech_debt` is
   trimmed on the same terms and `review_feedback`/`merge_conflicts` are not
   trimmed at all; and the rendered detail line names the allowance and spells
   out what the rung capped. Pinning requirement 4g, a repo array genuinely
   past `MAX_ARG_STRLEN` passes through both the already-fits and the
   must-trim paths with nothing on stderr and the array whole — the shape that
   caught this module's own first draft binding it as `--argjson`.

   And `test/coordinator-input-wiring.test.sh` passes, over the block lifted
   verbatim out of `agent-cycle.sh`: for three shapes of oversized input —
   long bodies, long threads, many entries — at three configured maxima, the
   prompt reassembled around the block's own output is inside the maximum;
   a larger maximum never yields a smaller prompt (which an overhead measured
   against the unfitted array would have caused); a maximum of `0` leaves the
   array untouched and logs nothing; a trim logs exactly one
   `coordinator-input-fitted` carrying the rung, the byte counts, the detail
   line and a `terms` breakdown by band, and no `warning`; a cycle needing no
   trim logs nothing; both shapes of "cannot fit" — a maximum the prompt text
   alone exceeds, and an allowance the ladder bottoms out inside — each log a
   `warning` saying which it was, itself carrying the same `terms` breakdown,
   with its five bands summing to the overhead total the block itself
   computed. The same file also lifts the exemption-set block that reads the
   fit's report downstream of all this, covered under acceptance check 2j-iii
   below. The same test lifts `handle_stage_failure`'s two refusal
   readers and drives them over the record the fleet actually produced on
   2026-08-21: the refusal is named `prompt_too_long`, its name carries none
   of the numbers the crash-loop ladder groups on, the API's message is kept
   beside it, a refusal the runner did not name falls back to `api_error_<n>`,
   and a stage that ran and then failed, a clean result, an empty transcript
   and an unparseable one are none of them called a refusal.

1k. **A stage prompt reaches `claude` on stdin, at a size argv could not
   carry (requirement 4c).** `test/stage-prompt-delivery.test.sh` passes: for
   `run_claude_stage` as sourced from `lib/stage-run.sh` — the one copy both
   pipelines call, which the file asserts by finding the function in neither
   cycle script — a 200000-byte prompt, comfortably past `MAX_ARG_STRLEN`,
   exits 0, arrives on the stub's stdin whole, appears
   nowhere in its argv, and leaves the JSON envelope in `out_file` where the
   caller's parser looks for it; an ordinary short prompt is delivered byte
   for byte. The oversize prompt is sized to the kernel's constant rather
   than to the prompt of the day, so the check keeps its meaning if a prompt
   is ever trimmed; the file first confirms the cap exists on the kernel it
   is running on, and says so and skips rather than passing vacuously if it
   does not.
1k1. **A stage streams as it runs, and leaves the envelope its readers
   expect (requirement 4d).** `test/stage-stream.test.sh` passes, against a
   `claude` stub that emits stream-json a line at a time with a pause
   between lines: the invocation is made with `--output-format stream-json
   --verbose`; `<stage>.stream.jsonl` grows *while the stage is still
   running*, which is the property the non-streaming form could not provide
   and the one every later use of the stream rests on; every emitted event
   survives in it; `<stage>.out` holds exactly the final `result` event, one
   line, and `metering_fields` derives from it the same record it derives
   from a bare `--output-format json` envelope carrying the same numbers; a
   stream whose last line is torn — the shape a killed stage leaves — still
   yields the earlier `result` event if it has one, and yields an empty
   `.out`, not a corrupt one, if it does not; and a stage that emitted no
   `result` event at all leaves `.out` existing and empty, which is what its
   readers already treat as "no envelope". `test/state-sync.test.sh` passes:
   a `*.stream.jsonl` written into a cycle directory reaches neither the
   mirror nor the pushed branch while the `.out` beside it reaches both, one
   already in the mirror from before the exclusion is deleted from it, and
   `state_local_streams_retained` removes the streams of older cycle and
   review directories while leaving those directories and every other file
   in them in place.
1k2. **A stage's inter-event gaps are measured while it runs (requirement
   33a).** `test/stage-gaps.test.sh` passes: `stage_gap_stats` summarises a
   known sample at the nearest rank — checked at the ranks where definitions
   differ, not only in the middle — leaves one long silence among short ones
   visible as `max` without moving `p50`, skips an unreadable observation
   rather than failing the record, and reports `null` only for a sample with
   nothing readable in it. Against a stub emitting with controlled pauses:
   an eight-second silence is measured rather than averaged away, gaps are
   counted per observed growth of the stream, the silence after the final
   event is counted even though no event closed it, a stage that emitted
   nothing at all still reports the one gap that was all of it, and the
   stage's own envelope and exit status are unaffected by being measured.
   Timing assertions bound from below, never exactly: a loaded machine makes
   a silence look longer, never shorter. `test/metering.test.sh` passes:
   `gaps` is carried through as given, is `null` when the caller supplies
   none, and degrades to `null` — rather than failing the whole record —
   when the caller supplies something unparseable.
1k3. **A stage that stops producing is stopped, and the two kills are told
   apart (requirement 4e).** `test/stage-watchdog.test.sh` passes, against a
   `claude` stub whose output it controls: a stage that goes quiet for longer
   than its inactivity threshold is killed, returns 124, and reports
   `stage_kill_reason` `inactivity`; a stage that keeps emitting through a
   span several times that threshold is *not* killed, which is the assertion
   that matters most, since the whole failure being replaced was killing
   stages that were working; a stage that emits nothing but outlives its
   backstop reports `backstop`, not `inactivity`; a threshold of `0` disables
   the watchdog, leaving a silent stage to run to its backstop; a stage that
   ends on its own reports no kill reason at all; the killed process group is
   dead rather than orphaned; and the stream written before the kill survives
   it, which is what makes the forensics of requirement 4d worth having. The
   `warning` body is produced for an inactivity kill and for nothing else.
   The same file covers requirement 4e's third stop: a stream reporting the
   account `rejected` stops the stage at once, attributes it to `rate-limit`
   rather than to either cap, and carries the runner's own record — reset time
   included — out for the stand-down; an `allowed_warning` does *not* stop it,
   nor does the same status string appearing inside a tool result, which is
   what an Implementer working on limit detection would be reading.
   `test/limit-detect.test.sh` passes: `limit_decide_structured` returns the
   stated reset as a known one, maps a seven-day limit to the weekly class and
   a five-hour one to `other`, falls back exactly as the prose path does when
   no reset is stated, and declines rather than guessing on an empty,
   unparseable or non-object record; and `limit_standdown_since` names the
   first hit of the current freeze — the earliest `limit-hit` with no later
   `limit-cleared` — printing nothing on an empty stream, on one whose last
   limit event is a `limit-cleared`, and never a hit from before that clear.
   Both `limit_union_record` and `limit_standdown_since` read past a spliced
   line — the head of a record run into a whole later one — before or after
   the governing hit, with most-recent-wins intact across it (a clear past
   the line still retires the hit, and a hit after that clear governs and
   starts a new freeze); a line that parses to a non-object is skipped; and
   each exits non-zero when its `jq` fails outright. `limit_union_state`
   answers the governing hit, the freeze's start and the `since` of every
   `limit-freeze-escalated` event (a non-string `since` left out) from one
   pass past a spliced line, agrees with the two readers built on the same
   fold, answers null, null and an empty list for a stream with no limit
   events, and exits non-zero when its `jq` fails outright.
   `test/doctor.test.sh` passes: `--offline` reports the stream-flushing
   probe skipped rather than running it, so the suite never spends.
1k4. **Both stage caps derive themselves, and in the safe direction
   (requirement 4f).** `test/stage-budget.test.sh` passes against fixture
   logs with absolute dates: a stage is keyed to the repository its cycle
   selected and to the model it ran, two repositories are two cells, and a
   Co-Ordinator run from before the per-repository split (with no repository
   on its own event) has no repository axis; an unseen cell answers from the
   shipped prior, as does an empty table, so a first cycle needs no
   configuration; one backstop kill multiplies the cap and repeated kills are
   bounded by the ceiling, while three clean runs move it not at all; a killed
   run is counted as a run and contributes no duration, so the percentile is
   over completed runs only; a long silence widens the watchdog threshold and
   consistently short ones never narrow it below the prior, and it never
   exceeds the backstop; one run leaves a cell marked `shrunk` and carries
   only a fraction of its own estimate; configuration outranks the derivation
   and says so on the event; the derived lock clears the summed worst-case
   backstops plus slack, treats a configured value as a floor, and still
   derives from the priors alone against an empty table; and a malformed log,
   a `stage-end` predating `kill_reason`, one predating the gap statistics and
   a malformed `stage_budget` object each yield a usable answer rather than
   none. The same file passes the Co-Ordinator warm start (issue #1629): a
   post-split event is keyed to its own repository rather than falling to
   `*`, a brand-new `(coordinator, <repo>, model)` cell with no runs of its
   own resolves its backstop and watchdog from the frozen `(coordinator, *,
   model)` pool rather than the shipped prior — reported `pooled`, via the
   pooled tier, never `cell`, and never the frozen cell's own `own` however
   many runs that cell has — and an unrelated actor (the Refiner, the
   Enabler) is untouched by any of it; once that repository cell has a run of
   its own its backstop continues from the same warm value rather than
   resetting to the prior, and a kill against the repository cell's own
   history multiplies that warm seed exactly once rather than replaying the
   frozen pool's own kills a second time on top of it.
   `test/stage-overrun.test.sh` passes: the dashboard holds a live stage
   against the cap announced on its own `stage-start`, falling back to the
   fleet-wide widest for that actor and then to the shipped prior, and makes
   no claim at all about a stage none of those names.
   `test/config-schema.test.sh` passes: `scripts/doctor.sh` reports the
   derived lock rather than checking a configured one — reading
   `stage_budget_all_overrides` from `lib/stage-budget.sh`, the same
   function `agent-cycle.sh` derives the cycle lock from, so the two never
   disagree — and warns that a configured cap pins itself, at every level of
   the precedence: the plain `timeout_<actor>` / `inactivity_<actor>` keys
   including the Refiner's, and a repository's own `stage_timeouts` /
   `stage_inactivity` entry, naming that repository in the warning.
   `test/publish-dashboard.test.sh` passes: the dashboard publisher — the
   fourth caller of `stage_budget_lock_seconds`, alongside both cycle scripts
   and `scripts/doctor.sh` — derives `config.lock_stale_after` from
   `stage_budget_all_overrides` too, so a plain `timeout_<actor>` key and a
   wider per-repository `stage_timeouts` entry both reach it exactly as they
   reach `agent-cycle.sh`'s lock and `scripts/doctor.sh`'s report, rather than
   the dashboard silently deriving from an empty overrides map of its own.
1l. **Repos are walked most-overdue-first by nice-weighted effective age,
   and it never starves a repo (requirement 3).** `test/repo-order.test.sh`
   passes: `repo_order_by_effective_age` returns an order byte-identical to
   a plain least-recently-updated-first `sort` of the same lines when every
   repo's `nice` is `0` or absent; scaling by `2^(-nice/3)` moves a
   negative-`nice` repo earlier and a positive-`nice` repo later, checked in
   both directions; a missing or unparseable timestamp reads as epoch 0 and
   stays maximally overdue at neutral `nice`; two repos with equal effective
   ages break by slug; the output is always a permutation of the input
   lines, never a subset or a reordering that drops or duplicates one; and
   `repo_nice_selection_config` returns `{}` — no key — for a config with
   no non-zero `nice` (absent, `null`, `0` and `-0` alike) and exactly the
   non-zero entries, floor-normalised, otherwise. `test/noop-skip.test.sh`
   passes: a `repo_nice` entry in `selection_config` changes the no-op
   fingerprint; and an input carrying an empty `repo_nice` map does *not*
   canonicalise the same as one omitting the key entirely — omission is the
   neutral form the producer emits for the shipped config (no `nice` keys
   anywhere), so it must drop the key rather than emit `{}`. Separately: a
   `nice` outside `-19`..`19`, or non-integer, makes `agent-cycle.sh` refuse
   to start, naming every offending repo's slug.
1m. **A guard reports its degradation and still answers exactly what it
   always did (requirement 4h).** `test/guard-degradation.test.sh` passes.
   `guard_warn` and `stage_budget_overrides` are lifted whole out of
   `agent-cycle.sh`, `gather_claimed`, `unaccounted_items` and
   `coordinator_eligible_items` out of `lib/candidate-select.sh` (#771), and
   the fleet stand-down date parse by its own
   start/end markers, the way `test/verdict-corroboration.test.sh` and
   `test/pr-claim-exclusion.test.sh` already lift theirs — so the file cannot
   pass against a paraphrase. Every case asserts **both** halves: that one
   `guard-degraded` event was written, naming that site and carrying the
   failed command's own output as `detail`, and that the caller-visible value
   is the same literal it was before requirement 4h. The failures are induced
   the way each site can really fail — an unparseable `CONFIG_FILE`, a
   `gather_claimed` claims array genuinely padded past `MAX_ARG_STRLEN`
   (131072 bytes, proven past the cap by the assertion beside it, the same
   mechanism the 2026-08-14 incident hit), malformed JSON reaching
   `unaccounted_items` and `coordinator_eligible_items`, an unparseable
   `resume_at` — and each pairs with a healthy-input case asserting the log
   stays *silent*, so a guard that fires unconditionally fails too. Separately
   and structurally, over the whole of `agent-cycle.sh`: every one of the
   guard sites reports and restores the variable its own assignment targets,
   and the sweep counts the sites it found and fails if that count collapses,
   so a parser that silently matched nothing cannot pass the check vacuously.
   Reintroducing requirement 4h's own `void_actioned_json`/`void_json`
   mismatch at any site must fail this file. The report's own bounds are
   asserted too: a site repeated seven times yields exactly
   `GUARD_WARN_SITE_MAX` events, numbered, with only the last marked `final`;
   three distinct labels interleaved all report, so the cap is per label and
   not per cycle; a 4000-byte `detail` is stored at 500; and a guard raised
   under `MANAGE_ACTION` writes nothing to the log and names its site on
   stderr, while the same site under a real cycle still logs. The usage-limit
   union read and the automatic-freeze escalation of requirement 2.1/1c are
   lifted out of `lib/standdown.sh` by their own markers: the union carrier
   reads the governing hit past a spliced line silently; a read that fails
   outright leaves it empty, marks the union's answers unknown and reports
   `cycle:union_record`; and a union the snapshot could not build is not
   read at all and is treated the same way. A three-day freeze past a
   spliced line files its escalation keyed on its start and logs
   `limit-freeze-escalated` with `since_basis: union`, and does not file
   again once that event sits in the union past a spliced line; a failed
   union read, and a union that could not be built, each file nothing and
   log a `warning` that the escalation waits for the next cycle; a flag-only
   freeze three days old files its escalation keyed on the flag record's
   `ts`, logs that time as `since` with `since_basis: flag`, and says in the
   issue body that it is the time `fleet/limit.json` was last written, while
   one an hour old files nothing; and a flag-only freeze whose record has no
   `ts` files nothing and reports `freeze_since:flag`.
2. `--dry-run` completes against the real repos: stand-down checks pass,
   ordering is computed, the findings pre-fetch runs, the Co-Ordinator selects
   an item or declines with a reason, the work order is printed, nothing
   further launches, and the log records the cycle.
2a. `scripts/gather-findings.sh Poetic-Poems/poetic` prints a valid JSON
   array (possibly empty), and prints `[]` and exits 0 for a repo with the
   features disabled — never a non-zero exit that would abort the cycle.
2b. `scripts/gather-abandoned-drafts.sh Poetic-Poems/does-not-exist autonomous-agent agent/ 3`
   prints `[]` and exits 0 — a missing repo, a disabled feature, an API error, or
   an unparseable threshold never aborts the cycle. Its candidate rule is
   regression-tested in `test/abandoned-drafts.test.sh`.
2i. **The GitHub API budget gates the cycle, and a short refusal is waited
   out.** `test/github-limit.test.sh` passes: `github_limit_verdict` returns
   `ok` above both floors, `exhausted` naming the binding resource below
   either, the **later**-resetting resource when both are below, and `unknown`
   — never `exhausted` — for a snapshot that is missing, empty or unparseable;
   `github_limit_kind` tells a secondary refusal from a primary one and both
   from an ordinary failure; `github_limit_wait_plan` waits until a stated
   reset, refuses a reset beyond the per-call bound, clamps to what is left of
   the process budget and returns nothing once that budget is spent; and
   `github_pr_list_truncated` fires exactly at the cap. The wrapper itself is
   exercised against a stub `gh`: a rate-limited call is retried once and its
   stdout emitted exactly once, a non-rate-limit failure is returned
   unretried, and `gh`'s own stderr reaches the caller either way. The meter
   is the headers (agent-ops#1087): `github_limit_headers_to_resource` builds
   `core` from a metered response's `x-ratelimit-*` headers — case-
   insensitively, a refused call's included, never another pool's, and
   nothing rather than zeros when they are absent; `github_limit_graphql_resource`
   builds `graphql` from the `rateLimit` object with `resetAt` as an epoch
   and nothing from an error document; `github_limit_snapshot`, against a
   stub answering both reads as GitHub does, carries both pools, carries one
   when only one read, and is no snapshot at all when neither did; and
   `github_limit_resource_pristine` recognises the endpoint's empty window
   (full, unused, reset an hour from a fixed clock) but not the same bucket an
   hour into its window nor a header reading with its own probe used — so a
   snapshot made only of empty windows is `unknown`, never `ok`, one real
   pool beside one is judged on the real pool, and a header reading below the
   floor is `exhausted`.
2o. **The budget is recorded, and the record adds up (requirement 2.0d).**
   `test/github-limit.test.sh` passes: `github_limit_budget_delta` gives the
   difference in `used` within one window, the new window's `used` flagged
   `window_rolled` across a roll, `null` for a count that went backwards, for
   no previous reading, and for a pool missing on either side — that pool
   only; and `github_budget_record`, against a stub and a `log_event` of the
   pipeline's shape, logs one `github-budget` event per reading —
   `cycle-start` with no movement and the cycle opened, `stage` naming its
   stage and its movement, and an unreadable `cycle-end` recorded
   `readable: false` with the last good snapshot left in place for the next
   delta. `test/github-budget-report.test.sh` passes: over two nodes' logs
   with a damaged line, the report counts every reading and the unreadable
   one apart, takes each hour's peak used and minimum remaining from readable
   readings only, counts primary refusals (never a 404) and requirement-2.0
   stand-downs per hour, excludes a rolled reading from a stage's movement,
   sums each cycle's own core/graphql spend excluding a window-rolled or
   unreadable reading from it (requirement 48, agent-ops#1086), sums per
   node, honours `--since`, unions this node's log with its peers' in the
   fleet-shaped read, says so on an empty log, and errors on a named log
   that does not exist; and, over the `gh` transport shim's own ledger
   (requirement 2.0e), unions this node's ledger with a peer's the same
   fleet-shaped way, sums each cache outcome across that union, prints the
   shim's own section, and reads as zero calls — never an error — when
   explicit log files were given instead of a `state_dir`.
   `scripts/github-budget-report.sh` passes `shellcheck`.
2p. **The `gh` transport shim conditions a cacheable read, serves
   last-known-good under a refusal, and never touches anything else
   (requirement 2.0e, agent-ops#1084).** `test/gh-shim.test.sh` passes, both
   the pure functions (sourced directly) and the shim end to end against a
   stub "real gh" binary answering from a per-call JSON plan:
   `gh_shim_classify` sorts a plain GET as `read`, a GET carrying
   `--paginate` or `--slurp` (either alone, or both together) as `paginate`,
   an explicit or
   body-flag-implied non-GET method as `write` — even carrying `--paginate` —
   the literal `graphql`
   endpoint and a caller already carrying `-i`/`--include` each as their own
   class, and anything that is not `gh api` at all (or has no endpoint) as
   `other`; `gh_shim_split_blocks` parses a single response and a
   multi-page capture alike, and zero blocks from output
   with no HTTP status line in it at all; `gh_shim_header_end_offset` finds
   the body's own first byte, so a body carrying CRs or ending without a
   newline is returned exactly as the wire carried it, and offsets to 0 for
   output with no header terminator at all; `gh_shim_should_use_lkg` accepts a
   primary rate-limit refusal and a bare `5xx` but never a secondary limit or
   an ordinary error status; a cache entry's body and metadata round-trip
   exactly, embedded newlines included, and lives under its identity's and
   its path's directory, never at the cache root; `gh_shim_cache_dir` is
   stable for one (identity, path) and differs by either; and
   `gh_shim_cache_invalidate` drops
   a write's own path — every entry cached for it, whatever its argv, and
   the directory itself — and its parent resource for the write's own identity
   only, leaving an unrelated path and another identity's cache of the very
   same path untouched, is a no-op for a path nothing cached or an empty
   identity or path, and removes exactly its two directories from a
   300-entry cache of unparseable entries in well under a second — the
   assertion that it never opens an entry (agent-ops#1422);
   `gh_shim_prune_cache` keeps an entry younger than its horizon, drops one
   older at any depth together with the directory that emptied and a
   flat-layout entry left by the layout before this one, and leaves
   `http-cache/` and a live identity's directory in place. End to end: a repeated GET sends `If-None-Match` and
   a `304` is served from the cache with exit 0; a primary-limit `403` with a
   stored body is served last-known-good with a `PW_GH_CACHE=stale age=<s>`
   marker and exit 0, and the same refusal falls through to the real
   (failing) answer once the cached entry is older than
   `PW_GH_STALE_CEILING_SECONDS`; a successful write invalidates the reads it
   feeds and is itself never conditioned; a `POST`, `graphql`, `--input` and
   a caller's own `-i` each reach the real binary with unmodified argv and
   return its output unmodified, none of them ever cached; output the shim
   cannot split into responses at all is passed
   through to the caller with the real binary's own exit status rather than
   dropped; a non-`api`
   subcommand's output and exit status (success and failure alike) pass
   through unmodified; and `PW_GH_NO_CACHE=1` forces the same unmodified
   passthrough for an otherwise-cacheable read, still ledgered as `bypass`.
   A `--paginate` call drives its own pagination (agent-ops#1114): a fresh
   call fetches every page with its own `-i` and merges their own bodies into
   one JSON array, byte-spliced rather than reparsed, and caches page 1, page
   2 and the whole-call last-known-good entry separately; an identical
   repeat call sends each earlier page's own stored `ETag`, 304s every page
   but the final one — which is always re-fetched in full, unconditioned —
   merges the identical document with no new cache entry, and ledgers the
   call `miss`, `hit` being unreachable while the walk's final page is
   always a real fetch (agent-ops#2183); a call where only the newest page
   changed still sends page 1's previous `ETag` (304ing it unconditionally
   server-side), re-fetches only the changed page, overwrites that page's
   own cache entry in place, and ledgers the call `miss`; a page served
   from cache takes its continuation from the live response's own `Link`
   header whenever one is present and from the stored `next` only when it
   is not, so a response carrying a `Link` that names a further page the
   stored entry does not still continues the walk, fetches that page and
   ledgers the call `miss` — the preference order being what is checked
   here, a real `304` from GitHub carrying no `Link` at all; a page whose
   stored `next` is `null` is never conditioned on a later walk, even when
   cached — it is re-fetched in full every time, so a collection that grows
   a real next page past an exactly-full final page is seen on the very
   next walk rather than truncated forever behind a stale `304`; a call
   naming no `per_page` of its own gets the
   real binary's own default of 100 added to page 1's query string, while
   one already named — in the endpoint's own query string, or an explicit
   `-F`/`-f` field alongside `-X GET` — is left alone; a page refused
   mid-walk abandons the attempt and falls back to one whole-call request —
   the same last-known-good body a previous successful call stored, with the
   same `PW_GH_CACHE=stale age=<s>` marker and exit 0, and that fallback
   request alone, unlike the per-page attempt, never carries `-i`; a
   `--slurp` call wraps each page's own raw body as its own array element,
   unreshaped; a `--paginate --jq` call concatenates each page's own
   already-filtered body in order, exactly as the real binary's own re-run-
   per-page semantics does, never an array-splice of text that was never a
   JSON array; and a page whose body is not itself a JSON array in plain
   mode is tried once (with `-i`) and then abandoned in favour of the same
   unconditioned whole-call fallback, which reaches the real binary with the
   caller's own argv and `--paginate`/`--slurp` both untouched, exactly this
   pathway's own behaviour before agent-ops#1114. A page that is an empty
   JSON array — leading, trailing, or the only page there is — or whose
   inner bytes are whitespace only, contributes neither an element nor a
   separator, so the merged document parses rather than carrying the
   `[{…},]` or `[,{…}]` an unconditional splice would leave. A plain
   (non-`--paginate`) read of the same endpoint neither
   conditions a later walk's page 1 nor truncates it: the walk still follows
   its own stored `next` to page 2 even when every page `304`s, and a plain
   read made after a walk is itself still unconditioned by the walk's own
   per-page entry.
   `lib/gh-shim.sh` and `scripts/gh-shim.sh` pass `shellcheck -x`.
2q. **The on-demand credential seam mints a fresh token once the previous
   one is within `refresh_buffer` of expiry, never re-identifies an
   explicit `GH_TOKEN`, and degrades exactly like the identity it fronts for
   (D18 decision 1 as amended, agent-ops#1021).** `test/gh-shim-auth.test.sh`
   passes, end to end against a stub "real gh" binary and stubbed
   `curl`/`openssl` (never a live App or network call): with `GH_TOKEN`
   empty and the forge authoring App configured, both `gh auth
   git-credential` (standing in for the credential helper `git push` calls)
   and an ordinary `gh` call present a freshly-minted token, and a second
   call within the token's lifetime reuses it — no second mint; with
   `PW_GH_NOW_EPOCH` advanced past that token's `expires_at`, the next call
   of either kind presents a *different*, freshly-minted token, not the
   stale one — the contract `TD-PPagop-26082833` named and this item exists
   to close; a non-empty `GH_TOKEN` in the calling environment (including the
   shape `GH_TOKEN="$(approver_token_get)" gh …` uses) reaches the stub
   unchanged and mints nothing; with no forge authoring App configured, an
   ambient `GH_TOKEN` authenticates every call exactly as before this item;
   and, App configured but a mint refused, the call presents
   `PW_GH_DEGRADE_TOKEN` rather than failing or reaching the real binary with
   no credential at all. `test/forge-auth.test.sh` continues to pass
   unmodified — `PW_GH_DEGRADE_TOKEN` unset in every one of its cases, so
   `forge_auth_effective_gh_token`'s `gh-token-degraded` path still falls
   back to `GH_TOKEN` exactly as before — and `test/forge-auth.test.sh`,
   `test/gh-shim.test.sh` and `test/gh-shim-auth.test.sh` all pass
   `shellcheck`.
2r. **The seam mints against the installation covering the repository the
   call targets, and reaches for the PAT when none does.**
   `test/gh-shim-auth.test.sh` passes: with
   `PULLWRIGHT_AUTHOR_INSTALLATION_IDS` naming two owners and no scalar
   default, a call naming the first owner presents that installation's own
   token, a call naming the second presents the other's, a call naming a
   third presents `PW_GH_DEGRADE_TOKEN` — never another owner's token — and
   a call naming no owner presents `PW_GH_DEGRADE_TOKEN` too; adding a
   scalar default turns those last two into the default installation's own
   token while a mapped owner still wins over it; and a non-empty `GH_TOKEN`
   passes through whatever the owner. The same three outcomes hold through
   `gh auth git-credential`, driven by the `path=` attribute of a buffered
   request, whose bytes the stub "real gh" receives unchanged. Every
   `gh_shim_target_owner` rule is pinned on its own — `-R`/`--repo` in both
   spellings and outranking a positional, `HOST/OWNER/REPO` and github.com
   URLs, `gh api` `repos`/`orgs`/`users` paths with and without a leading
   slash or query string, a graphql `owner` field and a
   `repository(owner: "…")` literal including across a line break, the
   `origin` remote fallback for a bare call inside a work tree (HTTPS and
   SSH), and the cases that must name *nobody* — another forge's URL or
   remote, a path naming no owner, a request without `path=` or for another
   host, a three-segment path whose first segment is no hostname, and a flag's
   value that merely looks like a slug (`gh repo clone --branch feat/x
   acme/widgets` names `acme`). One group is asserted against a work tree
   whose `origin` is `Poetic-Poems/poetic`: `gh pr checkout agent/1051`,
   `gh pr view feat/x` and `gh pr diff docs/x` each resolve to
   `Poetic-Poems` and never to the branch's first segment — the failure this
   change would otherwise introduce, since an owner named `agent` resolves to
   no installation and would hand a `Poetic-Poems` clone the scalar
   default's token.
   After `gh_shim_resolve_token`, `gh_shim_identity` names a token the seam
   minted by its installation — `app-<app id>-<installation id>` — and a
   fresh mint for the same installation, the previous token gone from the
   mint cache and the clock past its expiry, keeps that identity; the other
   mapped installation and the scalar default are each their own; and the
   PAT the seam degrades to, as well as a caller's own non-empty `GH_TOKEN`
   even for a mapped owner, are each a hash of the token, never an App tag
   (agent-ops#1422).
2l. **A rejected or missing credential is classified apart from an outage,
   and stands the cycle down before the Co-Ordinator ever runs (requirement
   2.0b, agent-ops#691, TD-PPagop-26082306).** `test/github-limit.test.sh`
   passes: `github_auth_probe` returns `ok` for a working token,
   `unauthorized` — carrying GitHub's own response as `detail` — for an HTTP
   401, `unauthorized` again — `detail` now leading "no token present" rather
   than an HTTP status — for `GH_TOKEN`/`GITHUB_TOKEN` unset or empty with no
   `gh auth login` session either, and `unreachable` for every other failure,
   never conflating any of the three. `test/auth-failure-wiring.test.sh`
   passes against the block lifted verbatim from `agent-cycle.sh`: an
   `unauthorized` verdict exits 0 without falling through to the rest of the
   cycle (so no Co-Ordinator engagement follows it); the logged stand-down
   reason states `GitHub authentication failed (HTTP 401) — GH_TOKEN is
   invalid or expired` for a rejected token, or
   `GitHub authentication failed — no GH_TOKEN/GITHUB_TOKEN is set and gh has
   no stored credentials` for a missing one — either way never 2.0's or the
   claim loop's own "outage, not contention" wording — and exactly one
   escalation is filed through `create_escalation_issue` in `crash_loop_repo`,
   labelled, assigned, keyed `auth-failure:<node>`, and titled/worded for
   whichever of the two it is (never claiming an HTTP 401 that never
   happened); `ok` and `unreachable` verdicts fall through
   untouched, filing nothing.
