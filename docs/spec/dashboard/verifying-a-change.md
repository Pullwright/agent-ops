## Verifying a change

- `./scripts/lint-shell.sh` clean — shellcheck over every shell script in the
  repository, not just this component's. `.github/workflows/shellcheck.yml`
  runs the same script on every pull request, so this is a gate rather than a
  good intention: it used to be neither, and four findings accumulated here
  unnoticed (pipeline spec, acceptance check 1g).
- `test/dashboard-exposure.test.sh` passes: the page is reachable on the host's
  loopback and on no network, in each of the ways the two compose profiles
  arrange that. `dashboard-local` publishes every port scoped to `127.0.0.1`
  (`DASHBOARD_PORT` moving the host side alone) and carries no `network_mode`,
  while its server binds `0.0.0.0` on the container port the mapping names —
  the two halves fail in opposite directions, one to a page on every interface
  and one to a page that answers nothing. The `tailnet` `dashboard` publishes
  no port, keeps the sidecar's namespace and takes the default bind, so Serve
  reaches it and nothing else does. The only other service that publishes
  anything is the node-health HTTP surface (`node-health`,
  `docs/spec/implementation/requirements` requirement 60d), guarded the same
  way and for the same two reasons — one loopback-scoped mapping, no
  `network_mode`, `0.0.0.0` inside the container — and every mapping either
  publisher declares is `127.0.0.1`-scoped. A bare `serve-dashboard.sh` still
  resolves to `127.0.0.1`.
- `test/version.test.sh` passes: a stamped image reports its build, an empty
  stamp (what a local `docker build` produces) falls through to git, a checkout
  reports `HEAD` and flags uncommitted work, neither source reports `null`
  rather than a half-filled guess, and the `(#N)` parser takes a squash-merge
  marker without taking a mid-subject issue reference for one. And none of the
  states that make a read fail — a repository with no commits, a clone with no
  `origin`, a stamp truncated mid-write — aborts a `set -e` caller, because
  `scripts/state-sync.sh` is one and a node that stops pushing is a node the
  fleet loses sight of.
- `test/union-stream.test.sh` passes: every reader that folds the fleet
  union from a stream reads only the event types it declares — the
  Publisher's own programs between their `# union-reader:` markers against
  `union_reader_events`, each library fold's `<NAME>_JQ` against its
  `<NAME>_EVENTS`, the usage-limit fold `LIMIT_UNION_JQ` among them — and
  the checker itself catches a planted undeclared read; `union_events`, the
  tolerant raw-line event stream every such reader shares, keeps the named
  events' objects past every line that is not one (a bare number or string,
  a spliced line, a record whose `event` is not a string), and
  `union_event_in` answers false rather than nothing for a non-string
  `event`; `union_stream` keeps the declared events in log order and closes with the
  span under both timestamp rules and the SINCE gate, aborts on a record that
  is not an object without writing its span line (and drops it under
  `--objects`); and `union_partition` writes one file per reader, delivers an
  event two readers declare to both, and leaves no file behind when its pass
  fails.
- `test/publish-dashboard.test.sh` passes: the launcher exits 0 on a healthy
  (shortened) window and while another publish holds the lock; it leaves
  `log.jsonl` untouched while `lock.json` names a live pid in this container,
  repairing `review-log.jsonl` in the same window, and repairs `log.jsonl`
  once that pid has gone; a cold window
  fetches from GitHub exactly once, a window following a fresh fetch not at
  all, and an aged stamp is refetched on the next tick; the batched cost scan
  matches the per-file semantics (day cut-off, torn-file tolerance, each row's
  own instant carried through as `ts` — `null` for a directory name that
  doesn't parse as one, which still counts toward the totals but drops out of
  `recent_costs` rather than guessing) and the
  whole publish stays within its process budget on a long history; a stage
  whose envelope parses but whose `result` is empty or whitespace-only still
  renders its cycle, with that stage's status `null`, while a stage whose
  envelope itself does not parse (a torn, mid-write file) still drops the
  whole cycle, exactly as before (TD26072802); the streamed union readers
  (agent-ops#1649) keep what their whole-array forms computed in the cases a
  small fixture never reaches — a log tail past the trim threshold is the
  newest `MAX_LOG_TAIL` rows newest first, ties by log position; the per-cycle
  summary and the node-latest pass take the later of two records at one `ts`;
  a line in the log that is not an object never reaches the readers, since
  `fleet_logs` drops it before its sort, so the detail render stays whole,
  the cycle beside it renders from its own events, the scorecards keep their
  window, and the line is counted in `log_repair.dropped_log_lines`; a node-latest
  pass that produces nothing is reported and replaced by the empty map; and an
  empty item-lifecycle result falls back to the empty record set; and every
  node in a synthetic fleet answers for **itself** — a peer mid-cycle reports
  its own running stage, repo, source and item from its published log, a peer
  whose cycle ended reports idle and when, a node that has never run reports
  `live: null`, and our own row comes from the lock rather than the newest
  `cycle-start` (a tick that started, found the lock held and ended must not
  masquerade as what this node is doing). With the fleet's newest cycle
  unfinished, `status.last_cycle` skips past it to the newest that logged
  `cycle-end`, so the field the headers date it by is never null.
  The cost scan attributes each
  transcript to the actor that wrote it, names a review's as the Project
  Reviewer rather than a second cycle Reviewer, and leaves the actors summing
  to the total. The batched cost scan's per-model entries (issue #594, D21)
  each carry that model's own `tokens_input`/`tokens_output`/
  `tokens_cache_creation`/`tokens_cache_read`, summed from a canned envelope's
  `modelUsage` map the same way its `costUSD` already is, with a `modelUsage`
  entry that is not an object skipped exactly as the existing `costUSD`
  handling skips it; the `unknown`-model fallback carries all four as `null`,
  never `0`. `counts.stage_gaps` folds a synthetic event set of `stage-end`/
  `review-stage-end` records into its per-stage `runs`/`median_of_run_p50`/
  `worst_run_p95`/`worst_run_max`: a `stage-end` with `gaps: null` is excluded
  from `runs` rather than counted as a silent one, a `review-stage-end` (which
  carries no `.stage`) rolls up under the literal `project-reviewer` rather
  than colliding with the implementation pipeline's own `reviewer` stage, and
  `window_from`/`window_to` reflect the full synthetic set's own timestamps,
  not `COST_SCAN_DAYS`. Each node's version comes from its own heartbeat, and a peer
  publishing none reads as unknown rather than inheriting ours; the
  compose-drift and image-drift verdicts ride the same rule — a peer's from
  its heartbeat, a peer publishing none as null, never locally computed, and
  our own row answering for itself. And the
  pull-request index — driven through `DASHBOARD_GH_CMD`, so a GitHub tick
  costs no API call — resolves every reference the page holds including the
  version a node runs (which no open-PR query names), reads each pull request
  at most once, re-reads none of them on the following tick, carries forward
  across a `--no-github` tick, and bounds a cold fill to a few references
  rather than one burst. Two hand-appended `cycle: "manual"` records a
  fortnight apart raise no row in Recent cycles, take none of the `MAX_CYCLES`
  budget, and leave the real cycle at the top — while both events stay in the
  log tail. With more no-op ticks in the log than `MAX_CYCLES` — newer than
  the real work, as the `*/15` cadence produces — no stand-down or lock-held
  skip shape raises a row, the substantive cycles still fill the detail list,
  and `noop_ticks` counts every one of them, split by kind, carrying the
  newest tick's timestamp; a stand-down that also logged a `claim-lost`
  (issue #245's raced shape) keeps its row and stays out of the count, and so
  does one whose `cycle-end` never came. A union carrying events that belong
  to no cycle — one stamped `cycle: null`, as `publish-revert-rate.sh` writes
  its `rework` rows, and one with no `cycle` field at all (`log-repaired`) —
  leaves the window whole: the real cycle renders with its stages and its own
  events, `cycle_render.ok` is true, and the log tail excludes the cycle-less
  `rework` row on its event type the same as any other (spec 33/47,
  TD-PPagop-26082920) — a `cycle: null` row is not exempt from that exclusion
  — so only the cycle-less `log-repaired` row stays in the log tail.
  Conversely, a detail
  render that cannot run at all still publishes the rest of the page, but says
  so on stderr and sets `cycle_render.ok` false with `jq`'s reason attached,
  rather than serving the empty `cycles[]` as though the fleet had been idle.
  And with `cron.log` short and a
  `cron.log.1` beside it —
  `scripts/rotate-logs.sh` having just rotated — the cron panel's tail draws
  from both, oldest first, rather than going blank for the tick after a
  rotation. A cycle that lost a claim to a peer's contention (`claim-lost`,
  cause `held`) before a `selection` that names `race_losses` is marked
  `raced: true` carrying that same count, whichever `outcome` it then reached;
  one that lost every candidate carries `standdown_cause` — `"raced"` for
  contention, `"unreachable"` when every loss was a GitHub outage instead,
  `"pre-claimed"` when nothing was ever attempted because the cycle's own
  gather had already seen every candidate claimed (implementation spec 17a's
  `claim-skipped`), and `"untraceable"` when every candidate failed the
  refinement-traceability check and the repair could not rescue one, or the
  Script's own compose step could not build a work order at all
  (implementation spec 17f/17h) — and
  only a cycle with a `held` loss is marked `raced` at
  all: a GitHub outage names no peer to contend with, and a pre-claimed
  skip was never contention in the first place, so neither shape may wear
  contention's badge (implementation spec 17a, issue #245). The same is true
  of the selection-integrity cause: a work order the Script refused to
  hand on names no peer either.
  An item that is blocked *and* void reaches `void[]` and not
  `blocked[]` (implementation spec 34h, acceptance check 8g), while an ordinary
  block beside it is still listed — a subtraction that over-reached would empty
  the panel that says the pipeline is stuck, which looks exactly like a pipeline
  that is not. Each of the five GitHub sources (TD-PPagop-26080201) is
  exercised both ways against a stubbed `gh`: healthy, each of the four
  state-carrying sources reads `answered`, while a healthy `pr list` leaves
  `github.ok` true; with one source's call failing (a rate limit), that
  source alone reads `failed` (or, for `pr list`, is named in `github.error`
  directly) and `github.ok` turns false — while an unrelated repo's own
  healthy call for the same source still reads `answered` in the same tick,
  proving the failure is told apart per-repo rather than flipping the state
  for every repo at once.
  The actor-scorecards aggregate (issue #610, D22) is asserted from two
  synthetic logs. The first drives the Co-Ordinator's own `measure` — the
  folded issue #319 corroboration rate — through the same five shapes its
  predecessor's test did: a verdict rejected then recovered by the retry that
  followed it (and whose picked item later lands, proving the `picks_landed`
  join), an accepted one over a non-empty eligible set (denominator only), one
  written before implementation spec 3v recorded `corroboration` events, an
  empty eligible set (neither term), and a verdict rejected twice that the
  Script then had to pick for (whose picked item never lands). A cycle counts
  its verdict **once** — spec 3v writes both a `corroboration` and a
  `none-selected` for the same answer, and counting both would inflate every
  denominator by exactly the cycles that stood down cleanly — and two models
  in the same window carry separate rates and separate `picks_landed` counts;
  a `selection` is attributed to the Co-Ordinator model and never to the
  Implementer `model` the event itself carries; and the picks-landed rate is
  gated on `picks_status` over its own two picks rather than riding on the
  corroboration rate's sample, so a rate the page must not state cannot reach
  it through the other population. The second log drives the
  outcome join across the other four actors: an Implementer item killed once
  (a deduped `stage-rerun` rework record attributed to it) then landed on a
  clean rerun — `landed_with_rework`, not `landed_unchanged`, and cost/
  wall-clock summed across *both* attempts, not just the one that landed it —
  beside a second, trivial-tier item landed unchanged on a different model,
  proving the two tiers stratify into separate rows; a Reviewer earning both a
  `human-change-request` and a `post-merge-revert` on one item and a
  `post-merge-revert` alone on a second — three escape records over two
  reviewed items reading as **two** escaped items, so the count is of items
  rather than records, and the second item, whose only record is keyed by its
  pull request's own number, counts at all only because `pr_url` re-keys it
  onto the work item; an Enabler's `enabler-adjudicate` and `enabler-decide` stage-ends
  sharing the critical tier though each names a different item, one landed and
  one voided, with cost-per-landed reading only the landed one's own spend,
  plus a third item met by *both* of those stages that is examined **once**,
  not once per stage name feeding the row — the count the row-level item dedup
  exists for, and the one whose absence would halve cost-per-landed;
  and a Refiner's two `item-refined` events, one bounced back
  (`refinement-bounce-back`) and one landed, read from the refined-item count
  rather than from the Refiner's own (itemless) stage-end. A log with no
  stage-end for any of the five actors still ships the card as a real object,
  `rows: []` on each of the five, rather than omitting the key.

- `test/dashboard-render.test.sh` passes its plain-`grep` check, run without
  `node` and independent of the harness below, that the header's documentation
  nav carries all six `blob/main/<path>` links (README, the three pipeline
  specs, the metering schema, the roadmap) verbatim in `dashboard/index.html`.
- `test/dashboard-render.test.sh` passes: `dashboard/index.html`'s own inline
  script, run unmodified under `node` against checked-in `DASHBOARD_DATA`
  fixtures and a DOM stub that only builds trees (`createElement`/
  `createTextNode`/`appendChild`, plus a serialiser — no layout, styling or
  event dispatch), renders the cells the fixtures name. This is what catches a
  page that renders the *wrong* thing rather than merely throwing: a cycle
  live in the Co-Ordinator stage with nothing selected yet reads "In
  progress", never the finished-cycle "Ended"; a cycle with no `cycle-end` and
  no node claiming it reads "No clean end" with fleet data and "Not ended"
  without any; a `needs-refinement` blocked row carries its badge and is
  removed by the hide filter; and the log tail's Node, Repo and Actor columns
  answer all three positionally — an actor read from `stage`, from `by`
  and from `handoff`, the review pipeline's named as the Project Reviewer, the
  clone step and the cycle-level events naming none, and a missing node
  keeping its own cell rather than letting the repository slide into it. A
  `disabled`/`enabled` event's badge is asserted to carry its `scope` (issue
  #426) — `disabled · node`, `enabled · fleet` — and a fleet-scoped one whose
  `fleet_flag` is `"failed"` to append `fleet flag: failed` to its Detail cell.
  A cycle fixture carrying `raced: true` renders the `↻ raced` badge beside its
  outcome badge, and no other cycle in that fixture renders it — the marker
  answers "how did this cycle get its outcome", not a second outcome of its
  own (issue #245); it also renders the "recovered race ×N" badge naming the
  count, while a separate fixture of a cycle that lost *every* candidate
  (`raced: true`, `standdown_cause: "raced"`, outcome `stand-down`) carries
  the `↻ raced` marker and never that one, having recovered nothing; and a
  third, of a cycle that skipped every candidate as pre-claimed
  (`raced: false`, `standdown_cause: "pre-claimed"`), renders as an ordinary
  stood-down row wearing neither race badge — a selection defect contends
  with nobody. Both race badges further require more than one active peer
  (issue #829): a fixture whose `fleet.nodes` names exactly one node carrying
  `role: "active"` renders neither `↻ raced` nor "recovered race ×N" for a
  recovered cycle or a lost-every-candidate one, even though both still carry
  `raced: true`/`race_losses` — while a fixture naming two active nodes
  renders both badges exactly as the fleet-less fixtures above do. A peer
  whose last-known `role` is `"active"` but which is itself stale
  (`heartbeat_age_s` past the staleness threshold) does not count toward
  that active-node total either (issue #1005): a fixture naming one
  genuinely active node and one stale peer with a stale `role: "active"`
  renders neither badge for a recovered cycle, the same as the single-node
  fixture above — a peer that has gone dark that long could not have
  contended for the claim any more than one correctly excluded on `role`
  alone. A fixture whose `noop_ticks` counts more filtered ticks than the forty slots
  hold (issue #271) renders its substantive cycles as ordinary rows plus the
  one summary line — the total, the stood-down/lock-held-skip split and the
  newest tick's age — while a fixture with a zero aggregate (and one with no
  `noop_ticks` key at all, a `data.js` from before the field existed) renders
  no such line. A fixture carrying `noop_ticks.overlap` (11a, agent-ops#1287)
  alongside a non-zero `total` renders a second line naming the overrun
  count, and a fixture carrying `overlap` with `total` at `0` still renders
  that second line on its own — the old total-gated skip must not swallow it,
  since a fleet whose every cycle does real work can still lose firings to
  one running long. The
  per-repo `nice` badge is asserted from two fixtures, because both of its
  silences are load-bearing and neither is visible on the page that has them:
  a repo at `-5` carries a blue badge naming `×3.17` and earlier attention, one
  at `3` a grey badge naming `×0.5` and later, both disclaiming starvation,
  under a note naming the Script rather than the Co-Ordinator; a repo with no
  key beside them carries nothing; and a config whose repos are all `0` or
  keyless renders no badge and no note anywhere on the page. A node behind an
  image published longer ago than `image_behind_grace_hours` carries an
  **image behind** badge naming the registry commit, while one whose registry
  check failed carries **image unverified** instead (#155). A node carrying a
  node-scoped disable (`switch.disabled`) shows a **disabled** badge beside
  its role badge, naming the reason and the expiry, while its own enabled
  self carries no such badge (#379). Two further fixtures separate that from
  the local record a fleet-wide `--disable` leaves on the node that issued it
  (`switch.scope: "fleet"`, implementation spec 2.3): with the fleet flag set,
  the page raises the fleet banner alone — no second banner for the mirror and
  no **disabled** badge on the issuing node, while a peer's genuine
  `--this-node` disable beside it still badges; with the flag cleared, the
  surviving mirror raises this node's own banner and badge, both naming it as
  a leftover of a fleet-wide disable since cleared rather than as a
  node-scoped decision. The merge-autonomy kill switch (D18 issue #576,
  `fleet.flags.merge_autonomy_kill`) is asserted from three further fixtures:
  a `state: "disabled"`, `record.kind: "manual"` one raises its own banner
  naming the reason, who set it and the `--restore-merge-autonomy` command
  that clears it, while never claiming every node stands down (the fleet
  switch's own wording) or badging any node disabled; a `record.kind:
  "fail-closed"` one still raises the banner but explains the state repo
  could not be confirmed clear rather than naming an operator, and omits the
  clear command a cause no command fixes has no business offering; and a
  fixture carrying no `merge_autonomy_kill` flag at all — every `data.js`
  from before this field existed — raises no such banner. A cycle whose
  `selection` carried `race_losses` (implementation spec 17d, #248) shows a
  blue **recovered race ×N** badge beside its title in the cycle history —
  informational, not a warning, since losing a claim race and then winning a
  later one is the claims (17a) working as designed — while a cycle with no
  `race_losses` at all shows none. A source marked
  `failed` in `github.inputs[<slug>].state` (TD-PPagop-26080201) renders a
  "couldn't read" marker in place of its count, and a fixture carrying no
  `state` field at all — every repo's data from before this field existed —
  renders exactly as it always did. The spend-today card's persisted
  GMT/local/24h choice (#186) is asserted by seeding the harness's
  `localStorage` stub rather than
  simulating the click: with no stored choice the card reads "today (GMT)"
  against `spend_today_usd`, and a stored `24h` relabels it "last 24h" and
  sums only the `recent_costs` rows within a rolling 24 hours; a stored
  `local` is asserted for its label only, since which rows fall on the
  reader's own calendar date depends on the moment the suite runs. The void
  list's two caps are asserted from a twelve-row fixture whose
  two oldest rows sit *first* in the data, because the cap is only meaningful
  once the list is sorted: the heading counts twelve, the ten newest render
  (the tenth-newest last), neither old row appears until asked for, the
  see-more control names how many are held back, and every row carries both
  the height cap and the class that makes it open. A fixture inside the cap
  renders no control at all.
  The actor and model scorecards (issue #610, D22) are asserted from
  `actor-scorecards.json`, which carries a populated row for every shape the
  card renders: all five actors' cards appear, in D12 order, each headed and
  each table's columns named; a Co-Ordinator row whose own base outcome
  columns read "insufficient evidence" (it never joins to one item) beside a
  `measure` that clears its own sample and states a real corroboration rate
  and picks-landed ratio, and a second Co-Ordinator row below the minimum
  sample on both of that measure's two independent gates — rendering
  "insufficient evidence" in place of each rate rather than stating a
  picks-landed percentage off two picks; an Implementer row split `unchanged`/`w/ rework` with its
  own cost-per-landed and wall-clock-per-landed figures, and a second,
  trivial-tier row rendered `insufficient evidence` below the minimum sample;
  a Reviewer row whose own `measure` reads as an escape rate, not a
  corroboration rate; an Enabler row naming the `critical` tier and an
  unblock-success measure; and a Refiner row whose measure counts bounce-backs
  against items refined. A `finished.json`-shaped fixture predating the
  aggregate entirely renders the "written by a Publisher that did not record
  it yet" empty state rather than a clean-looking empty card set it has no
  data for.
  The cost section's blocks (issue #330) render inside one `.costgrid`
  container in reading order — by-day, by-model, by-actor, then both cost
  notes — at the same depth as the charts rather than as paragraphs beside the
  section. Document order is what is asserted because it is what the layout
  rests on: a multi-column flow fills each column top-to-bottom in document
  order, so the order of the appends *is* the order a reader sees, whichever
  column each block lands in. Out of scope by the same tree-building limit:
  the pull-request hover card's pointer/focus behaviour, and which column the
  browser balances each cost block into — that is layout, and layout is what
  this stub does not do; it is covered by the manual check below.
  A fixture with no `status.stage_health` renders "No cycle has completed
  on this node" in the Stage health section and raises no banner (agent-ops
  #662); one carrying a `failing` stage raises the red banner naming it,
  lists that row with its own consecutive-failure count and failure detail
  alongside an `ok` and an `idle` row rendered distinctly, and badges the
  same node's own fleet-strip card with its failing-stage count —
  independent of that card's running/idle state, which is the property this
  check exists for: a node whose cycles are completing normally while a
  stage keeps failing must not read as plain "running" or "idle".
  A fixture with no `status.review_stage_health` renders the same "no run
  has completed" empty state in the Review stage health section, separately
  from Stage health's own (agent-ops#996); one carrying a `failing`
  `project-reviewer` raises its own red banner and badges the fleet strip
  independently of `stage_health`'s own failing count — a node whose
  implementation-pipeline stages are all healthy while `project-reviewer`
  fails must read as failing too, not masked by the other panel's own green
  verdict.
- The back-pressure card agrees with the gate it depicts, in both directions,
  from two fixtures of its own. `backpressure-claims.json` (issue #427) holds
  a changes-requested PR, a draft, an approved PR waiting on a human, one
  unraised item claim and one `pr-<n>` exclusion entry: the gauge reads 3 of
  3 and trips red, counting the claim the open-PR listing cannot show it and
  not the exclusion entry, whose PR is in that listing already.
  `backpressure-claim-scope.json` (the over-correction in PR #434) holds seven
  registry rows against two PRs: the gauge reads 4 of 8 and does not trip,
  having dropped the `enabler` and `refiner` pseudo-slug tombstones, the
  `pr-<n>` entry, and the item claim on the draft already counted — while
  keeping the item claim on the *approved* PR, which sits in the human's queue
  outside the sum and so is the only record of that work in flight. Both
  assert the `title` tooltip verbatim, because it is the composition
  `agent-cycle.sh` logs and the two are meant to be readable against each
  other. The live-claims panel below is asserted to still show the
  pseudo-slug rows in full: the gauge's narrowing is a statement about the
  cap, not about what an operator hunting a stuck item may see.
  `backpressure-otherwise-eligible.json` (D18 WI-6, issue #946) holds a
  repository configured at `agent-merges-routine` with three ready PRs — an
  approved `complexity:high`, an approved `complexity:low`, and a
  `CHANGES_REQUESTED` `complexity:high`: the gauge reads 2 of 3, counting the
  latter two toward the cap and putting only the approved `complexity:high`
  one in the human-waiting figure — confirming both halves of the rule at
  once, that the level-aware exclusion is narrowed to an otherwise-eligible
  pull request rather than every ready one, and that the narrowing itself
  never reaches a `CHANGES_REQUESTED` pull request, which the pipeline owes a
  change at every level.
- The **Token economics** and **Stall profile** panels (issue #594, D21) are
  each asserted from their own fixture. `token-economics.json` holds three
  stage/model rows over `cost_rows[]`'s new `tokens_*` fields — one with a
  healthy sample and a high cache-read share (reads its ratio and "no action
  indicated"), one with a healthy sample and a low share (names the lever:
  the prompt prefix may be varying, consider stabilising it), and one below
  `TOKEN_MIN_SAMPLE` (reads "insufficient evidence" instead of a rate) — plus
  an `unknown`-model row carrying `tokens_*: null` on every field, asserted
  absent from both the by-stage and by-model breakdowns entirely rather than
  folded in as zero. `token-economics-dedup.json` (issue #1591) holds one
  model shared by two actors within one cycle and by three actors across two
  more, asserting the by-model row counts all five as distinct transcripts —
  clearing `TOKEN_MIN_SAMPLE` where a `cycle`-only dedup would have left it
  short — while the by-stage rows for those same actors are unaffected.
  `stall-profile.json` holds `counts.stage_gaps` rows
  exercising all five of that panel's own Decision branches: a stage whose
  `worst_run_max` is at `STALL_NEAR_BACKSTOP_RATIO` of its known backstop
  (names the lever and the direction — raise it), one comfortably inside it
  ("no action indicated"), one below the minimum sample and below that ratio
  ("insufficient evidence"), one below the minimum sample but *at or above*
  that ratio (still names the lever and the direction — the near-backstop
  read does not wait on a sample, since `worst_run_max` is exact at any size),
  and one this page holds no backstop for at all ("no cap on record for this
  stage"); the panel's own caption is asserted to state its window separately
  from the cost charts' and to label its across-run figures as such rather
  than as pooled percentiles.
- `test/dashboard-refresh.test.sh` drives the SPA refresh tick itself (issue
  #1288), under a second, narrower stub (`test/dashboard-refresh-harness.js`)
  that fires the page's own `#refreshbtn` click listener — the one external
  hook onto `tick()` — against a scripted, synchronous sequence of simulated
  `stamp.js`/`data.js` fetch outcomes; unlike `test/dashboard-render.test.sh`
  it asserts nothing about the DOM, only which files get fetched. A page load
  seeded with `data.js`'s own embedded fingerprint disagreeing from
  `stamp.js`'s (the two-request race a publish landing between the page's
  initial `<script src>` pair can produce) still fetches `data.js` on the
  first tick rather than reading the disagreement as "unchanged". A `data.js`
  fetch that fails leaves the tab's own comparison fingerprint unmoved, so
  the very next tick — polled with the *same* fingerprint the failed fetch
  never got to apply — retries rather than skipping; only a fetch that
  actually lands may advance it, confirmed by a further tick then correctly
  reading that fingerprint as unchanged.
- `test/rework-panel.test.sh` drives `lib/rework-panel.sh`'s own fold
  directly, on `test/item-lifecycle.test.sh`'s own precedent: the three
  questions computed correctly over one hand-traceable fixture (tokens'/
  elapsed time's rework share against first-pass yield's literal
  zero-attributed definition, `whose`'s attributed/not-attributed split, the
  escape ladder's population/caught/escaped/escape_rate at each rung, and
  the two distinct reasons a `cost_to_catch_at_next` reads `null` — terminal
  rung versus genuinely unmeasurable, and a third: a catch whose own cycle
  this log meters nothing for, dropped from the average rather than counted
  as a zero-cost sample); dedup, including that two genuinely
  distinct `post-merge-revert` corrections on the same item (different
  `evidence.by`) both count, that two nodes logging the same repetition
  count once toward `rework_count` and `whose`, and that the copy kept is
  the first by `ts` — visible in `cost_to_catch_at_next`'s own average,
  which reads that same deduped stream, so only the surviving copy's cycle
  is charged there rather than every node's echo of it; `how_much`'s own
  token/elapsed/cost share deliberately reads the stream *before* that
  reduction instead, so both nodes' cycles count as rework spend for the
  one deduped repetition (the fixture asserts the full 1000 of the fleet's
  1000 tokens here, never the 100-of-1000 undercount dropping the echoing
  node's cycle would produce); the Reviewer-waving-work-through signature
  demonstrated against a constructed before/after fixture (a rising
  `escape_rate` at the `agent-review` rung alongside a *falling* `caught`
  count at that same row); and the degradations (a malformed line, a missing
  log) that yield a conforming report rather than aborting the fold.
  `test/dashboard-render.test.sh`'s own `rework.json`/`rework-outage.json`
  fixtures then check only that `D.rework` renders as the panel's own three
  sections and its three static caveats (the share's cycle granularity,
  rework never being a target of zero, and the human-gate coverage gap), and
  that an unassembled payload (every field `null`) reads as an outage rather
  than a quiet zero-rework tick — the fold's own correctness is
  `rework-panel.test.sh`'s job, not this one's.
- `test/fleet-sizing.test.sh` and `test/fleet-pricing.test.sh`
  (`docs/ROADMAP.md` D21/D14, issue #612) drive `lib/fleet-sizing.sh`'s and
  `lib/fleet-pricing.sh`'s own folds directly, on `test/constraint.test.sh`'s
  own precedent: `fleet-sizing.test.sh` demonstrates the acceptance
  criterion itself — a constructed fixture carrying one over-provisioned
  node (high idle-without-demand share, high share of the fleet-wide
  contended-claim-loss pool, no exclusive landings) and one healthy node,
  asserting the fold names the first as a shrink candidate and the second as
  healthy — plus the three insufficient-evidence gates (no time-account
  data, a window below the minimum sample, fewer than two nodes) and that a
  node with real exclusive delivery is never recommended for removal
  regardless of how idle or contended it otherwise reads;
  `fleet-pricing.test.sh` demonstrates every row of the fate-mapping
  priority order landing in its own bucket on one constructed
  `cost_rows[]` (including that a row already claimed by rework outranks
  its own landed terminal fate), that the six buckets reconcile to
  `total_usd` to the cent, and the turns-per-landed-item mean/median over a
  constructed set of landed and open items. `test/dashboard-render.test.sh`'s
  own `fleet-sizing.json`/`fleet-sizing-outage.json` and
  `fleet-pricing.json`/`fleet-pricing-outage.json` fixtures then check only
  that `D.fleet_sizing`, `D.spend_fate` and `D.turns_per_landed_item` render
  as their own panels — the shrink candidate and the healthy node on the same
  table, every fate bucket's own lever in the same cell as its figures, the
  by-stage/model turns table — and that an unassembled payload on any of the
  three reads as an outage rather than a quiet zero, the same discipline the
  constraint and rework fixtures just above already exercise.
- `claim-expired-tombstone.json` (agent-ops#839) holds one claim backdated to
  `do_expire()`'s sentinel `1970-01-01T00:00:01Z` alongside one with a real,
  recent `ts`: the live-claims panel's Held column reads the first "expired —
  pending cleanup" and never a fabricated day-count, while the second still
  renders its ordinary relative age.
- On a node that has been up for at least ten minutes,
  `grep 'github: refreshing' <state_dir>/dashboard.log | tail -3` shows one
  line roughly every five minutes, and `github.fetched_at` in `data.js` is
  within about five minutes of `generated_at`. Those two facts are the whole
  of "the PR panels are live"; nothing else on the page distinguishes a
  refresh that is happening from one that is not. (If that `grep` comes back
  empty or says "binary file matches", check for a hole before concluding the
  heartbeat is dead — `tr -d '\0' < dashboard.log | wc -c` against the file's
  size. The launcher repairs one at the top of each window, so this should
  only ever be true of a log written by a node that has not yet rolled.)
- `scripts/publish-dashboard.sh` against the real `state_dir` produces valid
  JSON (`data.js` minus the wrapper passes `jq empty`), and `grep` finds no
  `/home/…` path or token in the output.
- Open the page and confirm the panels populate: a failed cycle appears under
  Failures, and its transcript + stderr open inline. On a fleet, each node's
  card names what that node is doing and the header counts how many are working;
  on a single node the header carries the detail itself and there is no strip.
- On that same page, the cost section reads down the left column and on down
  the right, with no column running conspicuously past the other and the cost
  notes last (issue #330). This one is checked by eye in a browser, in both
  colour schemes and on either side of the 760px breakpoint, because the split
  is decided by the browser from the rendered heights: nothing that runs
  without layout can see it, and the DOM-stub harness above deliberately
  asserts only the document order the split is taken over.
- With a `blocked` row whose `kind` is `needs-refinement` in `data.js`, the
  Blocked items table shows a **refinement** badge next to that row's item id,
  the heading names how many refinement blocks there are, and its "hide N
  refinement blocks" checkbox — shown only when at least one exists — removes
  those rows from the table (and the heading's count) when checked, restoring
  them when unchecked. An ordinary blocked row (`kind` unset or `""`) carries
  no badge and is unaffected by the filter. `test/dashboard-render.test.sh`
  asserts the badge, the count and the checkbox's label from a fixture; the
  checkbox's own click behaviour is outside its tree-building DOM stub, so
  stays a manual check here.
- With more than ten `void` rows in `data.js`, the Void items table shows the
  ten newest, `See more — N older items` at its foot reveals the rest and turns
  into `See fewer`, and a row whose reason runs past three lines is clipped with
  an ellipsis and opens to the whole of it when clicked (clicking again closes
  it). Leave a row open and use the control: the re-render that follows must
  keep both that row open and the list expanded — the same survives-a-rebuild
  rule the cycle rows and open transcripts follow. Like the refinement filter,
  the assertions cover what renders and the clicking is manual here.
- While a cycle is in flight, its row in Recent cycles reads **in progress**
  from the moment it starts — including during the Co-Ordinator stage, before
  any `selection` is logged, which is the whole window in which the log-derived
  ladder has nothing to say — and no finished row's badge changes. Check the
  first minute of a cycle specifically: that is where reading the ladder alone
  produces "Ended". `test/dashboard-render.test.sh` asserts this from a fixture
  in that exact window; this manual check is for confirming it against a real
  running pipeline too.
- A pull-request number behaves the same way under a pointer, a finger and a
  keyboard. Hover one and the card opens; move off and it closes. Click it and
  the card opens **and stays**, the page does not go to GitHub, moving the
  pointer away does not close it, and hovering another number does not move it;
  click the same number again, click off the card, use its close button or
  press `Escape` and it closes — while a click *inside* the card does not.
  Ctrl/cmd-click still opens the PR in a new tab, and `Enter` on a focused
  number still navigates. On a phone (or a touch-emulating browser) a tap opens
  the card rather than GitHub, the card fits the viewport, and its close button
  and *View on GitHub ↗* link are both reachable. Leave a card open across a
  refresh or two: it is still there, and still pinned if it was pinned — a
  rebuild destroys the focused anchor, so this is where a stray `focusout` can
  close the card the reanchor just reopened.
- The page has zero console/page errors (it renders headlessly under a browser
  with no thrown errors).

