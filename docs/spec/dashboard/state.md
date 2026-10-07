## State it reads (verified 2026-07-14)

All paths derive from `config.json` (tilde-expanded `state_dir` and
`workspace_root`), read the same way `agent-cycle.sh` reads them.

- **`log.jsonl` — the FLEET's, not just ours** (requirements 33 and 2.5): this
  node's log unioned with every peer's fetched copy, via the same
  `lib/fleet.sh` read the pipelines use. That read takes a line a NUL run
  (an unclean stop, "Integration" below) or a splice has damaged apart before
  its sort, keeping the records it holds and dropping the rest (implementation
  spec requirement 2.5). What survives is parsed line-by-line with
  `fromjson? // empty`, so a half-written trailing line (the Script may be
  appending), or any other malformed line, never aborts the parse. What those
  drops cost is not left invisible: the union lands raw on disk once and is
  parsed from there, so both line counts describe the one snapshot rather
  than two reads a pipeline's own appends can separate, and the difference,
  plus the damaged lines `fleet_logs` reports it took apart or dropped (its
  damage file), rides the payload as `log_repair.dropped_log_lines`
  (agent-ops#794, #2037) — the log tail panel's own title names it whenever
  it is non-zero, "The Site" below. `revert-rate.jsonl`'s own read (below) is
  counted the identical way, into `log_repair.dropped_revert_rate_lines`,
  named the same way on the revert-rate panel's title. Blocked items use
  requirement 34's semantics (most recent `attempt-failed`/`unblocked` per
  `repo`+`item`) *less* the void set, which is requirement 34h's
  `open_blocked_items`; void items use
  requirement 34c's (most recent `item-void`/`unvoided`). Both come
  from the shared library, never from a local copy of the rule. With no peers
  the union reduces exactly to the old local read. Each blocked row is joined
  against the `escalated` and `enabler-examined` events *later than that block*
  (implementation spec 35, 36a), which is what gives the row its escalation link
  and the Enabler's last verdict; a mark older than the block belongs to an
  earlier one and is ignored.

  **Not every record in it came from a cycle.** A human may append one by hand
  — an `unvoided` to reopen an item, an `unblocked`, a `limit-hit` — and those
  carry the `cycle: "manual"` sentinel of implementation spec 33. The Publisher
  therefore admits to the cycle list only ids of the pipelines' own shape
  (`^[0-9]{8}T[0-9]{6}Z-`); every other id is a record about the pipeline
  rather than a run of it, and belongs in the log tail alone. The readers that
  act on those records — the limit stand-down, the blocked and void sets — key
  on the event and the item, never on the cycle, so none of them notices the
  distinction.
- **`<workspace_root>/.agent-ops-peers/<node>/`** — each fetched peer's state
  tree (implementation spec 2.5): its `heartbeat.json` becomes a `fleet.nodes[]`
  entry ({node, role, heartbeat, last cycle, version, compose, image, switch};
  older than `node_stale_after_minutes` (30 by default — three missed
  heartbeat/fetch cycles, not clock jitter) → `stale: true`, through the one
  verdict `lib/fleet.sh`'s `fleet_publication_status` computes for a peer's row
  and a node's own row alike (agent-ops#602)); its `cycles/<id>/`
  and `reviews/<id>/` transcripts
  render peer cycles with exactly the fidelity of local ones, and its `.out`
  envelopes join the fleet-wide cost roll-ups (every node spends one Claude
  account, so per-node spend would be the misleading number). The merged cycle
  detail list is capped at `MAX_CYCLES` *fleet-wide*, newest first across all
  nodes — that cap is what holds `data.js` near its single-node size however
  many nodes report. An id that exists on disk always renders from the owning
  node's directory (the D-before-E source ranking in the Publisher); an id
  known only from events renders from its events alone.

  **A no-op tick holds none of those slots** (issue #271). The `*/15` cadence
  makes most firings no-ops — the stand-down short-circuit (`cycle-start` →
  `stand-down` → `cycle-end`) and the lock-held skip (`cycle-start` →
  `cycle-skipped` → `cycle-end`) — and at a slot each they shrank the window
  from half a day of history to a couple of hours of mostly nothing. The
  Publisher classifies them ahead of the cap, by exactly those event shapes,
  and surfaces them as the single O(1) `noop_ticks` aggregate — total, split
  by the outcome value the ladder would have given the row (`stand-down` /
  `skipped`), and the newest timestamp — never as rows or a second list,
  because the cap is what protects `data.js`'s size and the aggregate must
  not grow with what it counts. A cycle that logged anything beyond those
  shapes keeps its row: a raced stand-down (`claim-lost`, 17d's badge), a
  pre-claimed one (`claim-skipped` — a selection defect, implementation spec
  17a), a hand-appended `unvoided` sharing its id, or a kill that cost it its
  `cycle-end` all carry information a count would bury.

  `noop_ticks.overlap` (implementation spec 11a, agent-ops#1287) rides in the
  same aggregate but is not a no-op count at all: it is a flat count of this
  window's own `cycle-skipped {reason: "overlap"}` events — schedule slots
  supercronic silently dropped because the cycle logging them was still
  running — and that cycle keeps its own row in `cycles[]` regardless, since
  it ran real stages of its own. `overlap` is never added into `total`,
  which still counts only ticks held out of the list; it travels alongside
  because a human scanning the fleet needs both numbers from the one place.

  Its **`log.jsonl` is also what says whether that peer is working, and on
  what** — `fleet.nodes[].live`. A peer publishes no lock (state-sync excludes
  it: a copied lock is a lock no process holds), so the answer is derived from
  the peer's own most recent cycle in the union stream, which requirement 33's
  `node` stamp makes separable: running until that cycle logs `cycle-end`, the
  live stage being the last `stage-start` with no matching `stage-end`, and the
  work whatever its `selection` event named. That derivation cannot see a node
  killed mid-cycle — a `cycle-start` with no end looks the same as one still in
  flight — so the page bounds the claim rather than the Publisher overstating
  it: a stale heartbeat renders as "state unknown", and a cycle running past
  `lock_stale_after` (the pipeline's own bound, past which it would take such a
  lock over — a derived figure since requirement 4f, which the Publisher
  computes and passes under that name) is flagged as possibly dead. A second,
  far earlier bound catches the case that actually happens. Every stage is
  capped by its own backstop, which `run_claude_stage` enforces by killing the
  process group and logging
  `stage-end` after — so a live stage older than its cap is not a slow stage but
  one whose process is already gone, and the page says so in minutes where
  `lock_stale_after` takes hours. A Co-Ordinator capped at twenty minutes
  against that rule's several hours is the whole of the gap: a node rolled
  mid-cycle read as
  "coordinator choosing work" for most of the way to its next cycle. A *peer's*
  bounds are measured to that peer's own heartbeat rather than to the reader's
  clock — what is known is what that node had published, and both timestamps are
  stamped by its clock, so the difference carries no skew between machines. Our
  own row is measured to `generated_at`, which is that same clock: self's
  `heartbeat_ts` is what the shared state last held for this node
  (`fleet_publication_status`, agent-ops#602), so it lags this render by a push
  interval plus a fetch interval even when publication is healthy, and by the
  whole outage when it is not — bounding our own live stage by it would delay
  the overrun badge, and suppress it outright on exactly the row an operator
  reads during a publication failure.
  `live.stage_since` is what makes this answerable, and `live.stage_backstop_min`
  — the cap that stage was actually given, announced on its own `stage-start`
  and carried through unchanged — is what it is held against. Every stage now
  has its own, so a shared configuration key could only ever approximate it;
  `config.stage_backstops`, the fleet-wide widest per actor, is the fallback for
  a row whose event predates the announcement, and a shipped prior the fallback
  after that. A stage none of those names (the review pipeline's) is one the
  rule makes no claim about.
- **`revert-rate.jsonl`** (D18 issue #579) — the fleet's own union, on the
  identical terms as `log.jsonl`/`review-log.jsonl`: this node's own file
  unioned with every fetched peer's, never rotated, reduced to the newest row
  per repository (by `ts`) rather than every row ever appended. See "Revert
  rate by repository" below.
- **`fleet-cache/{disabled,limit}.json`** — the fleet flags' cached copies
  (requirement 2.3a), maintained by `lib/toggle.sh` and refreshed by this
  Publisher's own GitHub tick. Read as plain files, so a `--no-github` tick and
  a standby node surface them with no API call. Surfaced as `fleet.flags` and
  rendered as banners: the fleet switch (suppressed when the local switch
  banner already covers it — the setting node writes both levels), and the
  fleet-wide usage-limit stand-down (shown when the local log union has not
  caught up — a standby with no state yet, or a hit seconds old elsewhere).
  Both banners name the flag's `actor` (falling back to the older `by` /
  `node` fields on records that predate it) and its `kind` (requirement 2,
  #244) — whose decision the stand-down is, and whether it was a decision at
  all: a `manual` limit record renders in the operator's voice ("set by …
  (manual)", never probed, `--clear-limit` lifts it early) rather than the
  detector's estimated-retry phrasing.
- **`fleet-cache/merge-autonomy-kill.json`** — the D18 merge-autonomy kill
  switch's own cached copy (D18 issue #576, `lib/merge-autonomy.sh`'s
  `MERGE_AUTONOMY_KILL_FLAG`). Narrower than the `disabled`/`limit` flags
  above and read differently from them for it: those two fail *open* on an
  unreadable record, so their raw cached bytes (`null` when clear) are the
  whole story; the kill switch fails *closed* (an unreachable state repo with
  no cache reads as engaged, `lib/merge-autonomy.sh`'s own header), a
  distinction only `merge_autonomy_kill_state` draws. This Publisher never
  calls that function outside its own GitHub tick — it always attempts a live
  fetch the first time a process asks it, which a `--no-github` tick or a
  standby node must not pay for — so the `--no-github`/local-only value runs
  the raw cache through `_toggle_eval` instead (the pure half of the same
  machinery, no network), defaulting to `{"state":"enabled"}` when no cache
  exists at all: a display default for "nothing confirms a kill", never the
  live gate's own fail-closed reasoning, which only applies once a fetch has
  actually found the repo unreachable. The live GitHub tick calls
  `merge_autonomy_kill_state` for real and overwrites this value with its
  accurate answer, fail-closed synthesis included — which also carries
  `merge_autonomy_kill_state`'s own `retried` boolean (always `false` here:
  this Publisher passes no `RETRY`, agent-ops#1081), where the local-only
  `_toggle_eval` value does not. Surfaced as
  `fleet.flags.merge_autonomy_kill` — `{state, retried?, cause?, record?}`
  on a live tick (`cause` present only on the fail-closed synthesis,
  agent-ops#1118 — the real diagnosis `fleet_flag_fetch_cause`,
  `lib/toggle.sh`, resolved for that read), `{state, record?}` on the
  local-only value — and rendered as its own banner,
  deliberately not folded
  into the fleet-switch banner above: cycles keep running while the kill
  switch is engaged, only landing collapses to `human` fleet-wide, so "every
  node stands down" would misreport it. A `record.kind` of `"fail-closed"`
  (the marker `merge_autonomy_kill_state` writes and nothing else does) omits
  the `--restore-merge-autonomy` advice a genuine `manual` kill's banner
  carries, since no command fixes a state-repo outage. `scripts/doctor.sh`
  reads the same function directly (its own "the merge-autonomy kill switch
  is …" line) — this is the same position, on the dashboard instead of a
  one-shot pass.
- **`disabled.json`** — the switch (requirement 2.3), read through
  `lib/toggle.sh`: the same code the pipelines gate on, so the dashboard cannot
  disagree with them about whether cycles are meant to be running (requirement
  34a). Surfaced as `status.switch` and rendered as the *first* banner, ahead
  of the usage-limit one.

  This panel earns its place by being the one thing a disabled pipeline looks
  like. Everything else on the page renders a disabled pipeline exactly as it
  renders a quiet one: no cycles, no PRs, no failures, no errors. Without the
  banner, a switch someone set on Tuesday is indistinguishable from a week with
  nothing to do — which is how it goes unnoticed until Friday. Show the reason,
  who set it (`actor`, falling back to `by`), its kind, and its expiry (or that
  it has none and needs `--enable`), since those are precisely the questions an
  operator has next.

  The same read (`toggle_switch_summary`, `lib/toggle.sh`) also feeds the
  node card's own **disabled** badge (implementation spec 2.3, `--this-node`
  — the graceful, single-node form): a node stood down that way sets no flag
  file anything else on this page reads, so without a badge on its own card it
  looks exactly like an idle one. This node's copy is read live, the same as
  its role and lock; a peer's arrives in its heartbeat as `switch`, on the
  same absent-means-unknown rule every other peer-only field on the card
  follows — a peer whose heartbeat predates the field, like one whose image
  or compose verdict does, renders no badge rather than a false "enabled".

  **A record's `scope` decides which of those two things it is** (implementation
  spec 2.3). A fleet-wide `--disable` also writes a local record on the node
  that issued it, tagged `scope: "fleet"` — a *mirror* of the fleet switch, not
  a stand-down of that node's own. While `fleet.flags.disabled` is set the page
  suppresses both the local banner and that node's badge in favour of the fleet
  banner, because one decision must not render as two problems, and an amber
  **disabled** badge on exactly one node of a uniformly-down fleet reads as a
  fault peculiar to that node. When the fleet flag is *clear* and a mirror
  survives, the opposite applies and both render, saying so: that node alone is
  standing down under a fleet decision lifted elsewhere — `--enable` on a peer
  clears the flag but cannot reach this node's file — and nothing else on the
  page would account for it.

  **`mode` (implementation spec 2.3d/2.9) changes the label, never the
  scope/mirror logic above.** `toggle_switch_summary` carries `mode`
  (`"stop"`/`"drain"`) alongside `scope`, so the same badge and the same two
  banners (node-scoped, fleet-wide) this section already describes render for
  a drain exactly as for a stop — only the text differs: **disabled** becomes
  **draining (N left)** or **drained**, and the banner headline reads "is
  draining"/"has drained" rather than "is disabled". `N` and whether it is
  `drained` come from `switch.drain` (`{remaining, at_rest, checked_at}`),
  folded in by `scripts/publish-dashboard.sh`/`scripts/state-sync.sh` from the
  last cycle's own at-rest check (requirement 2.9's cache) only when its
  `disabled_at` still matches the live record's — omitted, and rendered as a
  bare "draining" with no count, when no cycle has checked yet since this
  drain began (a `--drain` just issued, or one just extended). A drain never
  suppresses the badge/banner the way an *enabled* pipeline does — it is
  exactly as visible as a full stop, since "no new work, but existing work
  still landing" is just as easy to mistake for a quiet week as an outright
  stop is.
- **`cycles/<cycle-id>/<stage>.out`** — the stage's `result` envelope: the
  final line of the event stream `claude --output-format stream-json` wrote,
  truncated into this file by `run_claude_stage` and identical to what
  `--output-format json` used to leave here (requirements 11 and 4d). The
  stream itself, `<stage>.stream.jsonl`, is local to the node that ran it and
  never replicates, so this Publisher never sees one on a peer and reads none
  on its own node either. Fields used: `result` (final message → parsed
  into the work order / status object via the same algorithm `agent-cycle.sh`
  uses — straight parse, else the last fenced ``` block regardless of its
  info string (a bare fence or one tagged anything other than `json` is not
  ambiguous — only the fence's presence is, issue #237), else the
  earliest brace-opening line whose suffix parses as one JSON value;
  `test/extract-json-result.test.sh` holds the ports to it), `total_cost_usd`,
  `duration_ms`, `num_turns`, `is_error`, `terminal_reason`/`stop_reason`,
  `modelUsage` (→ model id). `<stage>.out.stderr` is shown for debugging.
  `docs/METERING-SCHEMA.md` is the formal contract for these fields — types,
  units, and what change to them is additive versus breaking — reused
  unchanged by the per-stage record `lib/metering.sh` writes to `log.jsonl`
  (requirement 33a); this reader and that one derive the same figures
  independently from the same envelope and are expected to agree.

  The **actor** that spent it is the transcript's own filename, and needs no
  new field: `cycles/<id>/{coordinator,implementer,reviewer,enabler,refiner}.out`
  name themselves, and `reviews/<id>/reviewer-<repo>.out` is normalised to
  `project-reviewer` from the directory two levels up — it belongs to the
  repository-review pipeline, not to the cycle Reviewer. Any other stem
  passes through verbatim, on the same fail-open rule as the source labels
  below.
- **`reviews/<review-id>/reviewer-<repo>.out`** — the repository-review
  pipeline's envelopes, read by the cost scan on exactly the same terms as a
  cycle's. It is one Claude account paying for both pipelines, so a roll-up
  that skipped this directory was not a per-pipeline figure but a wrong total —
  and it skipped the single most expensive actor per run, which is also the one
  an operator is most likely to be weighing up.

  `total_cost_usd` is a **local estimate computed from token counts**, priced
  as though the tokens had been billed per-token through the API. Under the
  subscription auth this pipeline runs on, it is not an amount charged and not
  a draw against any plan limit — it measures work done, not money spent. The
  envelope carries no quota, rate-limit, or credits-remaining field of any
  kind; do not expect one to appear here. See the design decision on plan
  limits below before building anything that treats these dollars as budget.
  Missing/partial files degrade to a null stage — never a crash.
- **`lock.json`** — `{pid, started_at, host}`. A live pid means a cycle is
  running now — but `kill -0` only answers that question inside the PID
  namespace that minted the pid, and the dashboard shares the scheduler's
  state volume without ever sharing its PID namespace (they are separate
  containers, `deploy/docker/compose.yaml`). So the Publisher reads `host`
  (the container that wrote the lock) first: only when it matches this
  container's own `$HOSTNAME`, or is absent (a lock predating the `host`
  stamp), does it trust `kill -0`. Any other lock is unanswerable from here —
  a pid that happens to match a live process in the dashboard's own namespace
  proves nothing about the scheduler's, and the reverse — so it reads as not
  alive, exactly as if there were no lock at all; `fleet.nodes[].live` for
  this node then falls back to the same log-derived state a peer's row uses.
  This is the same namespace confusion #130 fixed in the watchtower
  pre-update hook and TD-PPagop-26072901 fixed in both cycle scripts'
  `acquire_lock`. The cycle id is `<started>-<node>-<pid>` (older records
  `<started>-<pid>`) and the lock carries that same pid — last in either
  shape —
  so the running cycle's own events are exactly those whose id ends in
  `-<pid>`. From them the Publisher derives `status.current` — what the live
  cycle is working on right now: the running stage (the last `stage-start` with
  no matching `stage-end`) and the item the Co-Ordinator selected
  (`repo`/`item`/`source`/`title`). It is `null` when idle, and its fields fill
  in as the cycle progresses — `repo`/`item`/`title` appear only once selection
  has happened, since the Co-Ordinator stage runs before it has chosen anything.

  This is also **our own** `fleet.nodes[].live`, rather than the log derivation
  the peers get: a live pid is not an inference, and the derivation is wrong in
  one real case anyway — a tick that starts, finds the lock held and ends is the
  newest `cycle-start` on this node while the cycle actually holding the lock is
  still running. With no live lock our row falls back to the peers' derivation
  and is marked not running; a `cycle-start` with no `cycle-end` behind a dead
  lock is a cycle that was killed, and the page says so rather than rounding it
  to "idle".
- **`cron.log`** — tail shown, for "cron fired but nothing happened".
  `scripts/rotate-logs.sh` (agent-ops `docs/spec/implementation/requirements/the-script-04.md`
  requirement 2.6) renames it to `cron.log.1` once it grows past
  `log_retained_bytes`, so the tail is read from `cron.log.1` followed by
  `cron.log` — never the live file alone — and a rotation never empties the
  panel.
- **`build-info.json` (in the image) or git `HEAD`** — what code this node is
  running, read through `lib/version.sh` and reported as `fleet.nodes[].version`
  ({pr, commit, short, built_at, repo, source, dirty}). `.dockerignore` keeps
  `.git` out of the image — the image is a deployment of this repository, not a
  copy of a working tree — so CI stamps the answer in at build time
  (`.github/workflows/build-image.yml`, `deploy/docker/Dockerfile`), and this
  reader falls back to git for a checkout, and to `null` for neither. The
  **pull request** is the useful half: a SHA names the bytes, `#89` names the
  change, and the page renders it through the same record card as every other
  number. Our own is read directly; a peer's arrives in its heartbeat, because
  a peer publishes no container. See the design decision on version skew below.
- **GitHub, via `gh`** (best-effort; the machine is authenticated and the
  repos are public): open PRs carrying `pr_label` with `statusCheckRollup`,
  `mergeable`, `mergeStateStatus`, `reviewDecision`, author, labels,
  draft/ready, and merge-queue state (`queued`/`dequeued`, D17 — see the
  Publisher below); most-recent-per-workflow
  failing runs on the default branch; open issues, each with the `Priority`
  band the Co-Ordinator ranks it by (read from the REST issues listing's
  `issue_field_values`, since `gh issue list --json` cannot see issue fields,
  and defaulted to `Medium` exactly as the pipeline defaults it — see the
  implementation-pipeline spec, requirement 15e), capped at one REST page
  (`per_page=30`, agent-ops#1171) with the true count behind that cap read
  separately, best-effort, as `issues_total`; security and code-quality
  findings, via `scripts/gather-findings.sh`; the tech-debt ledger's open
  items — one label search per repo for open `pw::type:tech-debt` issues
  (issue #881), capped at 40 (`{id, title, status, url}`; `status` is always
  `"open"`, since the search only ever returns open issues) with the true
  count behind that cap read alongside, for free, as `tech_debt_total` — the
  Search API's own `.total_count`, returned in the same call as the page of
  results; and one record per pull request
  the page refers to (`github.pr_index`, keyed `<owner>/<repo>#<number>`) — the
  open ones from the query above, the rest by `gh pr view`, cached permanently
  once terminal (see the Publisher).

  All five sources above (issues, failing runs, the tech-debt listing,
  findings, `pr list`) are read per repo as one of two states, `answered` or
  `failed`, carried in `github.inputs[<slug>].state` for the first four — `pr
  list` keeps its own long-standing pass/fail signal folded straight into
  `github.ok`/`github.error` instead, since no per-repo PR count is ever
  rendered for a `failed` marker to replace. The reason for the other four is
  that they used to conflate "nothing to report" with "the call did not
  answer": `gh_json` (the Publisher's plain reader) discards stderr, so a call
  that timed out, rate-limited or 500'd printed nothing, and nothing is
  exactly what a legitimately empty result also prints. A repo's tech-debt
  ledger can be genuinely empty, so "no open debt" and "the listing call
  failed" had become indistinguishable on the page — observed directly
  during PR #163's own testing, where a repo's ledger read empty on one tick
  and thirteen items the next with nothing in the register having changed
  (TD-PPagop-26080201, against the register-backed listing this replaced).
  `gh_call` (the Publisher's stderr- and exit-status-preserving reader,
  alongside `gh_json`) and `gather-findings.sh`'s own exit code are what make
  the distinction: any non-2xx response is `failed`. `gather-findings.sh`
  draws the same line without a state of its own to carry it: a repo with
  neither alert type enabled (403 or 404, provided a 403's own message does
  not name a rate limit) still exits 0 and reads `answered`, exactly as a
  repo with both features on and nothing open does; only a real failure — a
  timeout, rate limit or outage — exits 1 and reads `failed`. A `failed`
  source renders a "couldn't read" marker in place of its count, never a bare
  zero (see the Site, below). `github.ok`/`github.error` reflect a `failed`
  state from *any* of the five sources, not only `pr list`'s (historically
  the only one that raised the "GitHub unavailable" banner). If `gh` fails,
  the GitHub panels mark themselves stale and the rest still renders. On a
  `--no-github` refresh the fetch is skipped entirely and the last successful
  result is carried forward (see the Publisher below), so only a fetch that
  was *attempted and failed* ever shows as unavailable.

  `github.error` is a classified, collapsed summary, not the raw failures
  concatenated: every failed call's own message (`<source> failed for
  <slug>: <gh's own diagnosis>`) is classified by its embedded cause — 401 or
  "Bad credentials" as auth, 403 or a rate-limit phrase (`LIMIT_PHRASE_REGEX`,
  shared with `lib/limit-detect.sh`) as rate-limit, a connection/timeout
  string as network, anything else as other — and same-cause failures
  collapse into one line naming the cause with a call and repo count (e.g.
  "GitHub authentication failed (HTTP 401) — GH_TOKEN is invalid or expired ·
  15 calls across 3 repos"); a tick that fails more than one way gets one
  line per cause. This is what keeps the banner readable through an outage
  that touches every source of every repo — during the 2026-08-22 token
  expiry it was fifteen semicolon-joined "Bad credentials" bodies with the
  one fact that mattered, the token being dead, stated nowhere in the text.
  The full uncollapsed list still reaches `dashboard.log` (the launcher
  already tees the Publisher's own stderr there), and `github.error` names
  the log rather than inlining every message.

**Usage-limit detection.** The pipeline's own detector and the Publisher share
one phrase pattern and reset-time parser (`lib/limit-detect.sh`), so a
weekly-limit message ("resets Jul 17, 4am …") or a monthly spend-cap message
now gets logged as `limit-hit` by the Script itself, not just spotted by the
dashboard. The Publisher still also scans recent transcripts for limit
phrasing directly, as a backstop for any cycle where a `limit-hit` never made
it into the log for some other reason (a crash before `log_event` ran, or a
cycle from before this detector existed) — so the dashboard can still show a
stand-down the log itself missed.

The banner is built from the same reduction the pipelines gate on
(`limit_union_record`), so a `limit-cleared` event retires the banner at the
moment it retires the stand-down; a dashboard still reporting a limit the
pipelines have lifted would be exactly the disagreement requirement 34a
exists to prevent. Its wording comes from `limit_describe`, which states
whether `resume_at` is a reset the provider gave or an interval this system
chose. An estimate presented as a deadline gets waited out instead of
questioned — which is how a lifted spend cap kept the fleet down for a
further 22 hours on 2026-07-26 — so an unstated reset is labelled as such and
names both ways out: the plan's rollover, which needs nobody, and raising the
cap then running `agent-cycle.sh --clear-limit`, which needs a human and only
if sooner is wanted. Flags written by a node on the previous release carry
`needs_human` instead of `reset_known`; the banner inverts it rather than
treating its absence as "reset known".

