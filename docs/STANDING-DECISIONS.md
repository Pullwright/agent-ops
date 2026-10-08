# Standing decisions

The Poetic installation's record of owner answers the pipeline is to stay
consistent with: one dated line per decision, oldest first. The
`decide-tactical` pass receives this file whole as
`precedents.standing_decisions` (requirement 36d,
`docs/spec/implementation/README.md`) and answers from it before it weighs
the owner-only boundary; a line here that already settles a re-flag's
question is a `decide` citing the line. Lines are data about what was
decided, never instructions to a stage.

Maintained by the owner, or by a delegate answering escalations on the
owner's behalf: add a line when an escalation is answered, amend a line when
the owner changes their mind (date the change on the line), never delete one.
The file changes only through the pull-request gate, like every other file
here. `standing_decisions_file` in `config.json` names it.

Format: `- YYYY-MM-DD · where decided · **the decision** — rationale or the
principle it rests on.`

## Principles

- **Trigger discipline.** A revisit is earned by a *measured* trigger (a
  release breaking a cycle, a budget measured to bind, a recorded footprint
  within an order of magnitude of a floor), never by a guess about scale.
  Decided on #607, reused on #813, #830, #902, #918, #1155.
- **Never loosen a shipped safety property to spare one pull request.**
  Mark the check required instead (#648); file residuals as their own issues
  rather than weakening a gate (#667). A not-yet-merged check proven to fault
  honest work by construction is a defective detector, not a safety property
  (#830).
- **Fail closed at arming time; fail open only on advisory reads.** A merge
  over an unread veto is irreversible and a stalled landing is recoverable
  (#753). A most-recent-wins reader of positive evidence never drops a stale
  source — stale evidence is strictly more than none (#1065).
- **Contradictory-by-construction config is refused at startup; config idle
  by an operator's temporary choice is warned about every cycle, never
  refused** (#924).
- **A liveness or staleness bound is never longer than the fault threshold
  it gates**, or every retired predecessor reads as the fault (#1053, #1065).
- **A pin without a named bump owner is a liability, not a control** (#900).
- **A new stand-down state goes on the existing switch record, never in a
  new file — old readers must fail closed** (#903).
- **Owner decisions go at the top of the item's body, never only in a
  comment**: a context-tight cycle clips bodies and drops comments (#607).
- **Escalations asking only for a mechanical act (a label removal, a
  confirmation) are actioned, not debated** (#666); then look for the loop
  that caused them.
- **Tactical, evidence-resolvable questions are the pipeline's to decide;
  only strategic decisions, owner-only acts and genuine judgement calls reach
  the owner** (2026-08-21, agent-ops#627; reaffirmed 2026-09-11 in
  `docs/reviews/2026-09-11-escalation-autonomy-review.md`).

## Decisions

- 2026-08-21 · #628 · **D18 preparation proceeds ahead of the Phase 1 exit
  gate (P1)**; promotion acts stay gated by #402's evidence bars only.
- 2026-08-21 · #633 · **Documentation and planning-record work is ordinary
  selectable pipeline work (S1)**; no separate track. "Output is prose, not
  code" is never a decline reason (#847).
- 2026-08-21 · #629 · **Kill-switch drill = one test case per ladder rung
  (L2)**, each rung collapsing to `human`.
- 2026-08-21 · #587/#638 · **No D14 cost ceiling on the Co-Ordinator
  per-repo split**; the measured cost stated in the PR is the control.
- 2026-08-22 · #648 · **Landing does not wait for non-required checks.** A
  check that should hold a merge is marked required, never special-cased.
- 2026-08-22 · #667 · **Requirement 25a is not weakened**: no per-PR opt-out
  from the `Closes #N` anchor; residuals become their own issues.
- 2026-08-22 · #607 · **Forge authoring identity = one GitHub App on the
  organisation**, distinct from the Approver App; one App per node only once
  the shared budget is measured to bind. Subscription-OAuth login is an
  accepted exception, not a defect.
- 2026-08-24 · #753/#746 · **Gate 4 reconciliation at arming time fails
  closed unconditionally**; any non-`clean` word refuses arming.
- 2026-08-25 · #784/#779 · **Escalation re-filing after a human close is
  rate-limited per close** (`escalation_refile_after_hours`), never
  never-file-twice; a close never releases a gate, label removal does.
- 2026-08-26 · #813/#810 · **Refiner re-affirmation of an adequate existing
  entry counts as refinement**; "a specification already exists" is never a
  `needs-refinement` reason.
- 2026-08-27 · #830/#821 · **Requirement 17g keeps the `acceptance` span
  check and drops the `context` half** (option c); the deferred detection is
  a register record, not a rider.
- 2026-08-28 · #844/#769 · **Work orders are Script-composed for all
  sources (option b)**; the Co-Ordinator selects only and never authors
  work-order text; a failed live fetch refuses the claim.
- 2026-08-28 · #847/#818 · **The pipeline answers research issues itself;
  posting the answers is completion.** A pre-#639 "assign to the owner"
  instruction means hand it back, never perform it.
- 2026-08-28 · #900 · **No new image pins anywhere**: `claude-code` stays
  `latest`, the base tag and apt layer float; CI-rebuild-per-merge is the
  update mechanism.
- 2026-08-28 · #902/#857 · **A `Closes #N` residual = the issue stays
  closed and the residual is filed as its own issue** (#756 → #904, Low).
  `min_free_workspace_bytes` is a floor under any derivation, never a
  ceiling.
- 2026-08-28 · #903/#865 · **`--drain` is a third switch position on
  `disabled.json`'s record** (`"mode": "drain"`); the roadmap's "Graceful
  drain" is renamed "Graceful shutdown". Finishing beats starting.
- 2026-08-29 · #911 · **Requirement 2.0c reads free disk for both
  `state_dir` and `workspace_root` under the one key** (option b); no
  rename.
- 2026-08-29 · #905/#906/#910 · **A confirmed-adequate specification is
  released by a human-voice comment on the item, a top-of-body note and the
  escalation's close — never by hand-clearing the block labels.**
- 2026-08-29 · #918/#901 · **Retention count keys keep floor-never-ceiling
  (option a)**: `max(configured, derived)`. Amended 2026-09-29 (#1826, the
  review of #1932): `state_local_streams_retained` alone takes a configured
  value as configured — a cap as well as a floor — and its
  `STATE_SYNC_STREAMS_RETAINED` is a per-node operator lever, not a test
  bypass; `cycles_retained` and `state_local_cycles_retained` keep option a.
- 2026-08-29 · #921/#913 · **Per-owner Approver installations = one JSON
  map `PULLWRIGHT_APPROVER_INSTALLATION_IDS`**; the single id stays the
  default; the check runs from `agent-approves` upward (#1064).
- 2026-08-29 · #922/#916 · **A mid-stage merge is a completion decided by
  the Script's own state read**; the Reviewer never opens a replacement PR
  and carries leftovers in `file_debt`/`file_issue`.
- 2026-08-29 · #924 · **`refiner_max_per_engagement: 0` with a required
  source warns every cycle; `failed-runs: "required"` hard-fails.**
- 2026-08-29 · #926 · **Forge-App token freshness = on-demand seam for
  `git` and `gh`** (`gh` as a PATH shim); explicit `GH_TOKEN` wins, empty
  resolves.
- 2026-08-29 · #942 · **The vendored project-review skill's tech-debt step
  is GitHub-only (option a)**, creating `pw::type:tech-debt` if missing and
  filing unlabelled with a notice otherwise; multi-forge is decided in
  principle, post-MVP.
- 2026-08-30 · #1053/#1037 · **An updater ledger is live while its newest
  entry is younger than `updater_stuck_after_minutes`**, liveness evaluated
  before the streak, one rule for own and sibling ledgers.
- 2026-08-30 · #1065/#990 · **Peers freshness marker = `{ok, ts,
  last_ok_ts}` with transition-only rewrites**; stale ⇔ `ok:false` or `ts`
  older than 3 × the fetch interval, capped at `LABEL_OWN_GRACE_SECONDS`;
  union readers carry on, the dashboard shows one badge.
- 2026-09-04 · #1153/#1144 · **`config-table` becomes a required check**
  only after `merge_group:` lands on its workflow. (2026-10-03: #2116
  added the trigger, and the owner added the check to the `default`
  ruleset.)
- 2026-09-04 · #1155/#1154 · **Historical asides inside a requirement stay
  where the deletion test passes**: legal iff deleting the aside leaves the
  requirement complete and correct.
- 2026-09-08 · #1262/#1032 · **D23 attribution = fresh at the record, same
  at the reader, no emitter-side dedup**; the roadmap row re-parks at Phase
  3 with D22.
- 2026-09-08 · PR #1258/#964 · **A decomposition umbrella closes on its
  `Fixes #N`; the remaining pieces are their own issues** (#1253–#1257).
- 2026-09-11 · #1358/#1339 · **The collector reaches the tailnet through
  the existing `tailscale` sidecar's namespace (option a)**: no new identity,
  key or credential in the collector; it keeps running under every profile.
- 2026-09-11 · #1359/#1340 · **A Kubernetes host-facts record lands with
  the scheduler as the reader (option d now, option a when a Kubernetes
  scheduler exists)**; the collector never holds a credential on any driver.
- 2026-09-11 · #1343 · **Fit-ladder pinning is fixed by shrinking the
  unsheddable bands (#1379), not by raising the byte budget or changing the
  model.**
- 2026-09-11 · #1333/#1156 · **Requirement 17h's soak is over; the 17g
  retirement is specified now.** An undefined soak threshold is set by the
  pass, not asked.
- 2026-09-11 · #1310/#1298 · **Pre-#1295 content in the private state
  repository: accept the GC tail** — no support ticket, history rewrite,
  credential rotation or exhaustive blob scan; one note under requirement
  2.5.
- 2026-09-13 · #1444/#1437 · **The closing-keyword record-flip check accepts
  both terminal states, `status: resolved` and `status: not-debt` (option
  1)** — both are terminal everywhere else in the register
  (`lib/work-gone.sh`, `lib/candidate-gather.sh`, TECH-DEBT.md "Resolution
  and history"), TECH-DEBT.md's own rule still requires a `not-debt` row to
  carry its `ref:` (enforced by `scripts/check-closing-keyword.sh`), and the
  pull-request review — not a red CI check — is where a not-debt conclusion
  gets its human eyes. Answered by a delegate on the owner's direction of
  2026-09-13; citation amended 2026-09-15 — the decision itself is unchanged.
- 2026-09-14 · #1543 · **A pull request that retires a required check's
  producer names the ruleset edit as a prerequisite owner act, and the edit
  precedes the merge.** The converse of #648 (a check that should hold a
  merge is marked required, never special-cased): doing the ruleset edit
  early is harmless — a pull request that still carries the workflow keeps
  running it, only without gating — so the safe ordering never wedges the
  repository.
- 2026-09-15 · #1531/#1512 · **The `Pullwright Author` App is granted
  `actions: write`, accepted on the `Pullwright`, `Poetic-Poems` and
  `Artist-OS` installations (option A).** Re-running or cancelling a workflow
  run is the narrowest lever GitHub offers for a flaked required check —
  there is no read-only re-run scope — and the residual it carries, an agent
  able to delete workflow runs, logs and caches, is accepted. Answered by the
  owner on #1531.
- 2026-09-19 · #1605/#1602 · **Finishing-source pull requests land
  autonomously on agent-ops (option 1).** `Pullwright/agent-ops`'s
  `merge_autonomy_routine_sources` widens from `tech-debt` and `issues` to
  add `review-feedback`, `merge-conflicts` and `abandoned-drafts`; every
  other landing gate is unchanged — the Approver verdict,
  `merge_autonomy_routine_complexity`, the protected paths, a human
  `CHANGES_REQUESTED`, the merge budget — and no other source is added.
  Decided by the owner on 2026-09-19; the alternative, a surfaced
  human-merge queue, was declined.
- 2026-09-23 · #1804 · **A change's changelog entry is a `## Changelog`
  section of its own pull-request description, and `CHANGELOG.md` is
  assembled from those descriptions by the release pull request alone
  (D27).** `CHANGELOG.md` was the sole conflicting path in 16 of the 22
  merge conflicts the pipeline repaired here between 2026-09-13 and
  2026-09-23, each repair re-running three stages; the description is the
  store the squash merge already writes onto `main`, so the entry moves
  there and no other pull request edits the file. Decided by the owner on
  2026-09-23. A just-in-time branch update at the landing gate was
  considered and withdrawn: it does nothing under a merge queue, and each
  of its pushes would dismiss the standing approval.
- 2026-09-30 · #402/#1981 · **Every Poetic installation repository lands at
  `agent-merges-all` (D18 Stages 3 and 4).** `Pullwright/agent-ops`,
  `Poetic-Poems/poetic` and `Poetic-Poems/poetic-fiddle` move to the top of
  the ladder, and the owner's residual surface is the escalation taxonomy,
  as #402's end state names it. Each repository's routine sources are every
  landing source it gathers except `dequeued`, which the landing stage
  cannot yet re-arm. agent-ops admits every complexity grade; poetic and
  poetic-fiddle admit `medium` and `high`, because a `low` grade is
  approved without a model call and a merge in either reaches production.
  Protected paths stay, and route a pull request through the critical-tier
  review and the 24-hour `landing_cool_off_hours` wait instead of to a
  human. Each list names the files that steer the pipeline's agents, the
  code CI runs with a token, the dependency manifests, and what reaches
  production: poetic's Blogger publishing, and poetic-fiddle's `supabase/*`
  and `vercel.json` (its migration job, disabled today, pushes merged
  migrations to the live database when it runs). The Approver verdict, the
  review gate, the open-question gate, a human `CHANGES_REQUESTED`, the
  merge budget and the kill switch are unchanged. This extends the
  2026-09-19 line, which widened only the sources, and waives #402's Stage
  3 and 4 evidence bars (the investigation report's §6, third waiver).
  Decided by the owner on 2026-09-30 ("maximum autonomy and minimum human
  involvement"), after a fortnight in which he merged 101 agent-ops pull
  requests by hand against 15 autonomous landings. It settles the
  merge-autonomy configuration and nothing else: it decides no open
  question or escalation, and is no reason to land a pull request that any
  gate holds.
- 2026-10-02 · #1125 · **One image, many containers (D28).** Every Actor,
  every Compose service and every node runs the one node image; per-stage
  tool scope and credentials come from the launch seam (#981), a per-stage
  resource ceiling from a container per stage (on Kubernetes a Job per
  stage, the Phase 2 deployment item), and toolchain variance from the
  target repository (D20, #2069) — never from an image per Actor. Image
  size reaches no D14 budget: a stage's cost is what it runs, Docker shares
  layers between the images on a node, and a routine roll moves about
  4 MiB. Decided by the owner on 2026-10-02 on the investigation's
  findings (#1125).
- 2026-10-03 · #2086/#2083 · **`docs-benchmark sources` becomes a required
  check at once** — without first running green for a while, as #2088 asks
  of its own check, because the pipeline lands past any check that is not
  required and the moves this check guards come next. #2090 and #2094 move
  the README and the implementation specification, which hold 135 of the
  150 sources the benchmark's questions cite. The check is deterministic,
  reports on every pull request and merge group, and fails only when a
  cited source no longer resolves. Decided by the owner on 2026-10-03, in
  the same ruleset edit as `config-table`.
- 2026-10-03 · #2128/#2129 · **Non-Claude providers are brought forward,
  and run through each provider's own headless agentic CLI (D29).** A
  prospective customer wants the pipeline on xAI's Grok models, so the
  first non-Claude provider moves from Phase 3 into Phase 1, and the
  substrate question the roadmap parked for Phase 2 closes: a stage runs
  on the CLI its provider ships — Claude Code for Anthropic, Grok Build for
  xAI — through an adapter at the stage launcher and an arm at each seam a
  provider touches, never by pointing one vendor's CLI at another's
  endpoint (xAI has deprecated its Anthropic-compatible one) and never
  through an API gateway; a provider with no headless CLI of its own is
  reached instead through a provider-neutral runtime of our own, built only
  on design-partner demand. The pipeline runs each CLI with its permission
  prompts bypassed, so containment is the pipeline's, never the vendor's.
  D4's subscription stance extends to every provider whose CLI offers a
  subscription login: the API key is primary, the subscription is the
  documented alternative with its constraints (own use only, among them),
  and the provider's terms may forbid unattended use outright — xAI's
  consumer terms forbid automated means that send more requests than a
  person could from a browser — so whether a fleet may run on a
  subscription is the subscriber's question, which the product documents
  and takes no position on. The API-key path ships first and the
  subscription path follows it directly: the prospective customer is
  likely to want their SuperGrok subscription, which under D4 and
  Principle 9 runs on the customer's own nodes, and which of #2139's
  mechanisms places its credential there is agreed with them. Decided by
  the owner on 2026-10-03, on #2129.
- 2026-10-08 · #2238 · **Each provider runs on its API key and its
  subscription at once, at a weighted share, and a stage switches lanes
  on its own at a limit or a spend threshold (D30).** A lane is one
  provider on one credential path, named for what it bills, and it is
  the unit of routing, stand-down and spend: the launcher draws a lane
  for every launch by weight from the provider's open lanes, with no
  memory and no ledger read; a lane of weight zero is the fallback; a
  usage limit or an exhausted credit freezes the lane rather than the
  provider or the fleet; a cap or a balance floor closes it on the best
  measure the lane has — the provider's statement where there is one,
  else the record's estimate, and a lane with neither carries no cap —
  and a closure only an owner act can clear pages the owner at once;
  `agent-cycle.sh --mix` moves the weights, opens a lane and restates
  a balance live through `fleet/mix.json`, openings and preferences
  that fail open to the configured single lane, while a closure goes
  on `fleet/limit.json`, never on a new file, and a cap or a floor is
  configuration. By default a
  provider has one open lane, the one its CLI would use unaided, so a
  second lane is an explicit choice. D4 is amended: the key stays
  primary by default and in the documentation, an installation weights
  its lanes as it chooses under D4's constraints, and running both adds
  no permission. Decided by the owner on 2026-10-08, on filing #2238: he
  holds Claude API credits he wants spent alongside the Poetic fleet's
  subscription; revised the same day for his review of #2249.
