## Design decisions

Recorded so a future reader knows they were deliberate, not accidental.
History and superseded approaches belong here (and in Gotchas), never in the
requirements above, which state only what is.

- **The Script orchestrates every launch; the Co-Ordinator only selects.**
  Per-stage timeouts, clean kills, and restartability come free from the
  process model, and the cheap Co-Ordinator session is not held open while
  an implementation runs for an hour.
- **Agents work in ephemeral clones**, never in the user's working copies
  under `~/Code`, which the user may be editing at any moment. This is the
  multi-agent ways-of-working rule shared by all Poetic repositories: every
  agent — autonomous or interactive — makes its own dedicated clone from the
  default branch before commencing any changes, and never assumes the default
  branch still matches what it cloned when it opens the pull request.
- **Draft-PR claiming is fused with the review flow**: the Implementer's
  draft PR is simultaneously the repos' standard claim marker and the
  Reviewer's input; the Reviewer flipping it to ready is the hand-off to the
  landing gate.
- **An abandoned draft PR is itself a work source.** Draft-PR claiming (above)
  has a failure mode: a stage that dies mid-implementation leaves its draft PR
  behind as a claim nobody will ever finish, silting a back-pressure slot until a
  human notices. Rather than rely on that, the `abandoned-drafts` source
  (requirement 3e) treats a draft this system raised, still open and untouched for
  `abandoned_draft_after_hours`, as selectable work — the pipeline finishes its own
  stalled drafts. It ranks seventh, after security, urgent issues, review-feedback,
  merge-conflicts and dequeued, and ahead of
  all fresh work (requirement 15c): finishing beats starting, and it turns a slot
  silted with a dead draft into a landable PR; under back-pressure it is one of
  the four finishing sources the cycle narrows to (requirement 2.2a). Four
  choices make it
  safe: the draft/label/branch filter keeps it to *our* stalled work (never a
  human's PR, never a ready one); the ref is scoped to the head SHA, so a
  re-abandoned draft that has since gained commits is a new item rather than one
  stuck behind an old block; the clock is last **real** activity rather than
  GitHub's raw `updatedAt`, so the pipeline's own label edits and marked comments
  (`lib/pipeline-marker.sh`) cannot make a genuinely stalled draft look worked
  (TD26072605 — see the Gotchas table); and, because its candidacy uniquely turns
  on the clock, the candidate array is fed to the no-op fingerprint verbatim so
  the staleness transition — which moves no other signal — still wakes the
  pipeline (requirement 3b).
- **A merge conflict on an otherwise-ready PR is itself a work source.** A PR this
  system raised can go green, be reviewed, even be approved, and then conflict when
  the base advances underneath it — leaving a finished PR nothing can merge and
  a back-pressure slot nothing will clear. The `merge-conflicts` source
  (requirement 3g) treats such a PR — open, non-draft, ours, `mergeable`
  definitively `CONFLICTING` — as selectable work: the pipeline rebases and
  resolves its own conflicts. It ranks fourth, after security, urgent issues and
  review-feedback,
  and ahead of all fresh work (requirement 15d): it is otherwise ready to land and
  nothing else on it can proceed first; under back-pressure it is one of the four
  finishing sources the cycle narrows to (requirement 2.2a). It deliberately does
  *not* complete the underlying item — that is the eventual merge's job — so it
  touches only what the rebase requires. Two choices make it safe: `mergeable` must
  be `CONFLICTING`, never the asynchronously-computed `UNKNOWN`, so it never
  rebases a PR that may not conflict; and, because its candidacy turns on the base
  moving — which no signal on the PR itself carries — the candidate array is fed to
  the no-op fingerprint verbatim so the conflict appearing still wakes the pipeline
  (requirement 3b), the same fix abandoned-drafts needs for its clock-based
  candidacy.
- **A merge-queue dequeue over a merge-group checks failure is itself a work
  source (TD-PPagop-26081409, issue #374).** Requirement 38f made the pipeline
  merge-queue aware and told a human whenever GitHub dequeues a pull request of
  ours without merging — but a checks-failure dequeue is not merely something
  to tell a human about, it is a real defect in the pull request: its own head
  is green, yet the speculative merge with whatever sat ahead of it in the
  queue failed a required check. Left as a notice alone, that pull request
  reads to every other source as approved, mergeable and green, and waits
  indefinitely for a human to notice the notice comment and act — the same gap
  a textual conflict would leave if requirement 3g did not exist. The
  `dequeued` source (requirement 3z) closes it the same way: selectable work,
  ranked fifth, immediately after `merge-conflicts` and for the identical
  reason (it is otherwise ready to land, and nothing else on it can proceed
  until it is fixed); under back-pressure it is one of the four finishing
  sources the cycle narrows to, alongside `merge-conflicts`. Two choices keep
  it safe and non-overlapping: `mergeable` must be `MERGEABLE`, never
  `CONFLICTING` — that PR is requirement 3g's alone, so the two candidate
  rules can never admit the same head at once — and `dequeue_reason` is read
  as an allow-list (`failed_checks` only, confirmed against a real GitHub
  deployment), never a deny-list, because GitHub reports it as free text: a
  human manually removing their own queue entry must never be misread as
  something this system should push a fix over, which would undo the very
  action the human just took. Because its candidacy turns on a
  `RemovedFromMergeQueueEvent` no other signal on the pull request carries at
  all — not even `mergeable`, which is what `merge-conflicts` rides on — the
  candidate array is fed to the no-op fingerprint verbatim, the same fix
  abandoned-drafts and merge-conflicts each need for their own invisible
  transitions. The Implementer cannot re-queue what it fixes — no prompt in
  this pipeline enqueues a pull request, at any `merge_autonomy` level, and
  requirement 8d's arming step (the one thing that does, at
  `agent-merges-routine` and above) arms only on the round the Approver
  approves, never a later one, so a dequeued pull request's next queue entry
  is the human's own "Merge when ready" click either way
  (tech-debt/TD-PPagop-26081701.md) — so it diagnoses
  and fixes the merge-group's own failed run, then leaves the pull request
  ready with a comment naming what it found, exactly as far as this system's
  side of a merge queue can ever go. That last property is also what makes the
  source's third choice necessary: because the agent is forbidden the one
  action that clears the state it is keyed on, a fixed dequeue would otherwise
  stay a candidate for ever, and the head-SHA-scoped ref would mint a fresh,
  unblocked one on every fix push. So candidacy also requires the dequeue to be
  *unanswered* — no marked `actor=implementer` reply newer than `dequeued_at` —
  reusing `lib/handoff.sh`'s predicate rather than a second copy of it, exactly
  as requirement 3c does for a review round it likewise cannot dismiss. This is
  the first finishing source whose condition self-clears neither on a rebase
  (`merge-conflicts`) nor on activity (`abandoned-drafts`), and the clause is
  what gives it the property the other three get free.
- **Dependabot's own conflicted PRs get one nudge before a takeover, never a
  force-push (requirement 3s, issue #250).** poetic-fiddle #129 sat
  merge-conflicting for twelve days: dependabot will rebase its own PR on
  request, but nothing was asking, and the ordinary merge-conflicts rebase
  path only ever touches branches under our own `pr_label`/`branch_prefix` —
  a bot PR carries neither. The fix keeps the same array (`merge_conflicts`)
  and the same ranking rather than a new source, and keeps the same
  hands-off-a-branch-that-is-not-ours discipline the ordinary rebase case
  already has: this system asks (`@dependabot rebase`) rather than
  force-pushing the bot's branch itself, because Dependabot rewrites and
  re-force-pushes its own PRs on its own schedule and a competing force-push
  from this system would just be two writers fighting over the same ref.
  Only once Dependabot has had a full cycle and the PR is still conflicting
  at the *same* head does the pipeline take over — a new PR, on its own
  branch, closing the bot's — because at that point Dependabot is
  demonstrably not going to resolve it itself. A superseded bump (a newer
  Dependabot PR already covers the same dependency) is voided rather than
  nudged or taken over, through the *existing* void-recording path rather
  than a new one — so it stops being offered as a candidate every cycle,
  which is the problem this half of the fix set out to solve. Recording the
  void correctly needed one piece of care with the evidence text: void
  corroboration (`lib/void-guard.sh`) reads "PR #N" — bare, or as a
  `.../pull/N` URL — in evidence as a claim that PR *implements* the item,
  fetches whichever form a cited superseding PR uses, and correctly refuses
  it (a different, independent bump will never carry the superseded item's
  id). So `gather-merge-conflicts.sh` pre-formats the evidence itself, citing
  the superseded PR's *own* number — which the guard reads off the item's own
  id for a `pr-<n>-…` item cited in the entry's own repo, as a bare citation
  always is (issue #290) — and naming the superseding PR only by its branch
  name, never as "PR #M" and never by URL (issue #300: PR #281 taught the
  guard to resolve a URL citation live too, so citing the superseding PR by
  URL started failing the same live body/branch test a bare "PR #M" always
  did — the branch name is the one description of it neither extractor
  matches at all). A Co-Ordinator composing its own sentence naming "PR #135"
  instead would have every such void refused, silently, forever;
  pre-formatting the one sentence that must not vary was cheaper than
  teaching every future writer the distinction.

  **It originally did not also close the pull request** — TD-PPagop-26080901
  fixed the human-visibility gap above (issue #240) by excluding every
  `pr-<n>-conflict-…` void from `close-void-github-items.sh`'s act-on-void
  close (requirement 34k), because the identical shape also covers a live PR
  of ours whose conflict merely resolved, and closing that one destroys real
  work — pull request #264. The exclusion was on the id shape, not on the
  reason for the void, so it necessarily disabled the supersession auto-close
  too: a superseded bot PR was left to wait for a human to close it by hand,
  and these accumulated one per superseded bump, the same
  "visible to every human and every tool that reads GitHub rather than this
  pipeline's log" complaint issue #240 was filed against. TD-PPagop-26081304
  paid down that cost by minting the superseded case a distinct id shape,
  `pr-<n>-superseded-<head-sha>`, so `pr-<n>-conflict-…` could keep meaning
  only "the conflict resolved" while the new shape means "the bump itself is
  moot" — a claim closing the pull request never discards anything for. Its
  own corroboration is not the `-conflict-` shape's mergeability test, which
  cannot distinguish the two claims: it re-derives, live, whether the PR is
  still Dependabot's own and still superseded by a strictly-newer open bump of
  the same family, moving the Dependabot excuse `-conflict-` used to carry off
  a shape whose void closes nothing and onto the one shape that actually needs
  it.
- **The void guard's finishing-source id shortcut is slug-gated, and an entry
  naming no repo falls through rather than refuses.** PR #281 made URL
  citations resolve against the `owner/repo` the URL itself names, which
  handed `void_pr_matches_item`'s id shortcut a slug the entry never chose: a
  citation of `https://github.com/<any-owner>/<any-repo>/pull/281`
  corroborated item `pr-281-…` with no fetch at all, on the numbers
  coinciding across repositories (issue #290). The shortcut now fires only
  when the cited slug is the entry's own `repo`. The other direction was a
  choice: an entry naming no repo can never satisfy the gate and could have
  been refused outright, but #281 deliberately made exactly that entry's URL
  citations corroborable via the live fetch, so refusing would have
  reintroduced the "names no repo" dead end that improvement removed. It
  falls through to the ordinary body/branch test instead — the empty-repo
  entry loses only the id shortcut, never the ability to be corroborated.
  The shortcut itself stopped being no-fetch shortly after: TD-PPagop-26080807
  found that firing it with no live check at all left this shape corroborated
  by nothing but the id's own construction — in *every* stage, not only in the
  two that call with `repos: []`. The Co-Ordinator's candidate-diff test looks
  like a backstop and is not: it matches a candidate's `item`, and the
  gatherers put the synthetic id in `ref`, leaving `item` as whatever register
  id the branch or body named, or `null`. `void_finishing_pr_reason` now
  fetches the gated PR and reads its state, so the gate still needs no
  free-text match but no longer takes the citation on faith.
  What that fetch demands is deliberately not uniform: it is calibrated to what
  requirement 34k does with the void it corroborates. The two shapes whose void
  *closes* the pull request (`-abandoned-`, `-review-`) must show a closed PR,
  an empty diff, or the human-applied `obsolete` label (TD-PPagop-26081308) —
  the corroboration a human can give that a still-diff-carrying draft is
  unwanted, which no API call can — because closing a live branch on an
  uncorroborated "no longer wanted" is what cost pull request #264; the shape
  whose void closes nothing (`-conflict-`) is read against mergeability
  instead, because for it an empty diff is not the claim being made and
  demanding one would refuse every honest void the merge-conflicts source can
  write. Refusing is still the guard's
  preferred direction of failure — but only where a wrong acceptance is
  destructive, which is exactly where the strict reading now sits.
- **An issue's `Priority` is a rank, not a label — so the source is banded, not
  sorted.** Issues were a single rank in the walk, which meant the only way a
  human could say "this one first" was to file it as something else. GitHub's
  native `Priority` issue field already says it; requirement 15e simply makes
  the walk obey. The banding is expressed as four `issues:<band>` tokens in the
  repo's `sources` rather than as a sort *within* the issues source, because the
  ranking question is not "which issue first" but "an issue against a tech-debt
  item, a red `main`, a review recommendation" — a question a within-source sort
  cannot answer, and one the ordered `sources` list already answers for every
  other source. Keeping the ordering in config also keeps re-ranking a
  config-only change, which is what that list is for.

  Three placement choices carry the design. `Urgent` outranks even the finishing
  sources because a top band that still queued behind three tiers would not mean
  what it says, and back-pressure (requirement 2.2a) already guarantees it cannot
  starve them — once the open-PR ceiling is hit the cycle sees *only* the
  finishing sources. `Medium` is the unset default *and* sits exactly where the
  unbanded source used to, so an untriaged backlog is unmoved by this change and
  triage is the only thing that reorders anything: a default of "lowest" would
  have silently demoted every existing issue the day this landed, which is a
  re-prioritisation nobody asked for dressed as a default. And the band is
  dropped at the work order (requirement 21) because it is a statement about
  when work is picked up, not about what the work is — carrying it downstream
  would invite an Implementer or Reviewer to treat `Low` as licence to do less.
- **The Reviewer's model follows the Implementer's ex-post complexity
  self-assessment** (requirements 26a and 8a), not the Co-Ordinator's ex-ante
  classification. Complexity routinely reveals itself only during
  implementation — an item that read as a register edit turns out to touch
  the locking logic — so the agent that has just done the work grades it, and
  the grade picks the reviewer tier: `reviewer_model_complex` for `high`,
  `reviewer_model_default` otherwise. The known hazard is self-blindness: the
  PR most needing a strong review is the one whose author misunderstood
  something and didn't notice, and that author will grade it easy. Three
  choices contain it: the rubric is anchored to observable features of the
  diff (which subsystems it touched, whether the work deviated from the
  order) rather than felt difficulty; the grade rides the PR as a
  raise-never-lower label, so a PR once graded `high` is reviewed as `high`
  in every later finishing round however small that round's own work — with
  the Reviewer, the one agent that has read the whole diff without having
  written it, the only stage permitted to correct the label in either
  direction (requirement 30); and the resolved grade is logged on the
  reviewer's `stage-start`, so a drift toward `medium`-everything, or a creep
  toward `high` that erodes the cost bound, is visible in the log rather
  than discovered in the human's review queue. The label doubles as a signal
  to the Human Reviewer of how carefully to read. A self-escalating Reviewer
  (the default-tier Reviewer requesting an Opus re-run when out of its depth)
  was considered and deferred: it judges from the reviewer's seat, which is
  the most relevant one, but pays for two reviews on exactly the PRs that
  are already expensive, and it adds a stage outcome to the state machine.
  It remains open as a future *addition* to the labelling scheme, warranted
  only if the log shows the Implementer's grading under-firing.
- **Back-pressure on open agent PRs replaces a quota-balance check** as the
  primary throttle, because no supported API exposes a subscription plan's
  remaining quota; usage-limit errors are handled fail-safe via detection
  and cooldown (requirement 10).
- **The 6-hour stale rule became a 3-hour lock plus per-stage timeouts** —
  finer-grained, and a wedged stage can no longer consume six hours of
  quota.
- **Work-source categories are mapped to what actually exists** in the two
  repos (security findings, failed runs, tech-debt registers, GitHub issues,
  fiddle's implementation plan, project-review recommendations, and
  code-quality findings). User stories and road maps were dropped — neither
  repo has them; the config structure accepts new sources when they appear.
- **The weekly project review feeds the pipeline as a work source.** The
  review pipeline (`docs/spec/review.md`) produces, for each repo,
  two channels: the debt it surfaces, filed straight to GitHub as
  `pw::type:tech-debt`-labelled issues as the run goes (R12) — the primary,
  status-tracked channel, picked up by the `issues` source — and a
  `reviews/project-review-*/` folder of prioritised
  recommendations with ready-to-run improvement prompts, landed by the review
  pull request. The
  `project-review` source consumes the latter so that recommendations *not*
  also filed as an issue are still actioned rather than left to
  rot in a folder. It sits just above `code-quality` (a human-approved
  recommendation beats an automated one) and below the curated channels, and
  dedups against them via the `R-NN` cross-reference the review writes into
  each mirrored issue's body (required of the review by R12a of
  `docs/spec/review.md` — for a long time this bullet merely *assumed*
  it, which is why the dedup silently didn't work; see Gotchas). Because the recommendations file is
  regenerated each week (its `R-NN` IDs are per-review, so a ref is
  review-dated), an un-actioned recommendation is simply re-offered under a new
  ref by the next review; persistent items live as issues, whose numbers are
  stable — so the regeneration doesn't strand work. Done-ness is tracked by
  the PR referencing the ref (open = claimed, merged = done), the same
  PR-as-source-of-truth pattern the findings sources use, so the review folder
  stays an immutable point-in-time record.
- **Security findings are a first-class, always-first work source.** GitHub's
  own Dependabot and code-scanning alerts are treated as work items; within a
  repository any security-related candidate outranks all non-security work,
  and across repositories this source itself is the one tier above every
  other (requirement 15a),
  even a red `main` — a known, exploitable vulnerability is the highest-stakes
  thing the pipeline can be pointed at. Non-security code-scanning findings
  become the `code-quality` source, ranked below every curated source: real, but
  more speculative and higher-volume than curated tech-debt or filed issues, so
  they never crowd out deliberate work.
- **Findings are pre-fetched by the Script, not the model** (requirement 3a,
  `scripts/gather-findings.sh`). The Dependabot and code-scanning APIs are
  paginated and verbose; digesting them in the cheap Co-Ordinator session
  would burn tokens on plumbing. A deterministic bash+`gh`+`jq` script
  normalises them into compact findings the Co-Ordinator reads directly — the
  same pattern already used to feed it the ordered repo list and blocked
  extract. It fails safe to `[]` so a repo without the feature (or without
  token scope) costs nothing and breaks nothing.
- **Claim visibility is pre-fetched by the Script, not left to a per-candidate
  live check by the model** (requirement 3o, issue #175). Exclusion 3 used to
  ask the Co-Ordinator to discover a peer's claim itself — nominally one
  `git ls-remote` per repo, but a check the fleet's smaller Co-Ordinator model
  routinely skipped, and one the four finishing sources' file claims could
  never have shown up in even performed faithfully, since they mint no
  branch. The log's cost was concrete: item `78` logged nineteen `claim-lost`
  events across four nodes in one day, item `155` seven in one — each a paid
  Co-Ordinator run whose selection was doomed before it started, and often a
  stand-down where other work existed. The fix is the same pattern as
  findings, above: a deterministic bash+`gh`+`jq` gather (`lib/claim.sh
  claims`/`branches`) replaces a live judgement call with a lookup against
  pre-fetched data, complete over both claim shapes and immune to model size.
- **Tech-debt handling uses the repos' own claiming workflow directly**
  (all configured repos today keep identical per-item `tech-debt/` machinery and a
  `/td` skill, but the Implementer follows the documented workflow rather
  than dispatching through the skill, which exists to launch agents — the
  Implementer already is one).
- **The Co-Ordinator falls through** to the next category or repo when
  candidates fail the suitability bar, instead of giving up after the first
  category that yielded any candidate.
- **Branch names drop the repo slug** (`agent/<item-slug>`): a branch is
  already scoped to its repository.
- **Review feedback is a work source, and the human's turn is derived from
  review-thread events** (requirement 3c). Before it, an agent PR that
  received "changes requested" was a dead end: the open PR claimed its own
  item (requirement 16.3), no source read `reviewDecision`, and only a human
  could break the deadlock — by fixing it themselves or closing the PR and
  losing the work. The system could raise PRs but never answer the one person
  it raises them for.

  The mechanism turns on a constraint that looks like an obstacle and is
  actually the design: GitHub will not let a PR's author approve or dismiss a
  review on it, and this system is the author. So the agent *cannot* clear
  `CHANGES_REQUESTED` — which both preserves the landing gate for free (there is
  no route by which an agent marks its own work accepted) and means the PR's
  own state can never tell us the feedback was answered. Whose turn it is has
  to be derived, and the derivation is events GitHub itself stamps when they
  happen — a marked reply or a `review_requested` timeline event — never a
  commit's date: an early version compared the blocking review against the
  head commit's `committedDate`, and a conflict-resolution force-push
  re-stamps that date to push time with no review of its own having occurred,
  which silently satisfied the comparison on PR #205 (agent-ops#239). That
  single clause is the difference between a source that converges and one
  that re-fixes the same PR cycle after cycle, for ever, while looking productive.
- **The switch is one shared, expiring file** (requirement 2.3). Shared because
  the hazard is an agent editing the agent-ops tree, and *both* pipelines run
  out of that tree and source the same `lib/` — a per-pipeline switch would let
  the weekly review fire into a half-written `lib/limit-detect.sh`. Expiring
  because the switch is the only thing in this system whose deliberate purpose
  is a total, silent stop, which makes a forgotten one indistinguishable from a
  quiet week; `disable_default_ttl` bounds that at a few cycles, and `forever`
  remains available for a maintenance window someone actually means. In
  `state_dir` rather than the repo, because the repo is the thing being edited:
  a tracked switch would arrive and depart with branch checkouts and could be
  committed by accident. `agent-cycle.sh` is the only writer, so there is one
  record and one implementation to keep honest.
- **The no-op short-circuit fingerprints the Co-Ordinator's inputs rather than
  its answer** (requirement 3b). The alternative framings are all worse: caching
  the verdict for N hours is arbitrary and stale; asking a cheaper model whether
  anything changed reintroduces the token cost being avoided; and letting the
  Co-Ordinator decide when to skip asks the component being skipped to opt out.
  Hashing the inputs makes the skip a deterministic claim about bytes, which is
  a claim bash can make correctly and a test can pin — and it composes with the
  existing pre-fetch design, since the two most expensive inputs (`findings`,
  the blocked/void extracts) were already computed in the Script. It also fails
  in the right direction by construction: anything unexpected — a changed
  digest shape, a failed sample, a log the rule can't read — produces "no
  match", which costs one Co-Ordinator run. The rule can only be wrong by being
  *incomplete*, which is why requirement 3b's map of source-to-signal is
  normative and `none_selected_recheck_hours` caps the damage at 24 skipped
  firings — a day at the historical hourly cadence.

- **Finish-then-continue chains to its cap after real work, and that cost is
  accepted** (requirement 39, issue #248; surfaced in the review of #268).
  The "sources remain" half of the chain gate counts enabled source
  *categories*, not items, and back-pressure (2.2a) narrows a repo's
  `.sources` to the four finish-work sources rather than to empty — so for
  any fleet whose repos configure `review-feedback`, `merge-conflicts`,
  `dequeued` or `abandoned-drafts` the count is never zero and
  `max_chained_cycles` is the
  only gate that ever fires. Nor can a chained cycle short-circuit on the
  no-op fingerprint (3b): the productive cycle's own PR changed the inputs
  the fingerprint hashes. The behaviour is therefore "after a productive
  cycle, chain to the cap", and each link pays a full Co-Ordinator pass
  (~2m35s of Haiku by the cost profile's measure) whether or not anything
  was left to pick up — up to `max_chained_cycles − 1` passes per productive
  cycle, unconditionally. That is the accepted trade: #248 is after drain
  rate — work discovered minutes after a merge rather than at the next cron
  firing — and a gate that could predict remaining work would need the very
  gather-and-select pass it is trying to decide whether to spend. Tuning
  knob, not redesign: a fleet that finds the idle chains too dear lowers
  `max_chained_cycles` (`1` disables chaining).

- **The Enabler runs from the exit trap, not from nine call sites.** A model
  stage inside a cleanup handler is unusual enough to look like a mistake, so:
  the cycle has nine endings, and the escalation path matters most on the ones
  that selected nothing — a stand-down on back-pressure, a no-op skip, a lost
  claim. Calling it at each of those is nine places to keep in step and one to
  forget, and the one forgotten would be silent. The trap is the single place
  every ending already passes through; it still holds the lock, which is what
  keeps requirement 33's single-writer guarantee true for the events the
  engagement writes; and it already runs multi-minute work (the state-sync push,
  the dashboard publish), so the shape is not new. What the trap does demand is
  the discipline of requirement 37: an unguarded non-zero status inside it would
  abandon the rest of the cleanup, so every step tolerates its own failure and
  the call itself is `|| true`. That is a smaller, more testable obligation than
  nine call sites that must each stay correct.
- **The Enabler's claims are tombstones, not locks it releases.** Every other
  claim in this system is released when the work ends (requirement 17a); these
  are deliberately never released, and `lib/claim.sh gc` is what retires them.
  The reason is that the failure this bounds is *not* two nodes racing — that
  much a released lock would handle — but an engagement that produces no record
  at all: a timeout, a garbage final message, an item the model silently omitted.
  Release the claim and the next cycle re-engages the same item immediately, and
  goes on doing so hourly at Opus prices with nothing to show for it, since the
  eligible set is unchanged. Keeping the claim converts every such failure into
  "retried once per `claim_ttl_hours`", which is a bounded cost written in a
  config file rather than an unbounded one discovered in a bill. The key carries
  the block's timestamp, so a genuinely re-blocked item is a new key and is not
  gagged by the tombstone of the old one. `lib/claim.sh expire` (requirement 37)
  narrows that bound without abandoning it: it fires only for the one case the
  Script can actually distinguish from silence — an engagement it watched fail
  even after requirement 9e's salvage resume — and backdates the tombstone's
  `ts` rather than deleting it, so `gc`'s very next sweep retires it instead of
  the full TTL. A genuinely wedged item still costs at most one attempt per gc
  interval, which is the same shape as before this existed, just a shorter one.
- **The Script files every issue; the model only writes the words.** The
  Enabler could perfectly well run `gh issue create` itself, and it must not.
  Two reasons, both structural. The log is appended by the Script alone
  (requirement 33), and an escalation is a state change with a matching event —
  an issue created by the model is one whose number no `escalated` event records,
  so no later cycle can tell whether the ask is still open, and the closure loop
  of requirement 36a silently never fires. And the write powers a model needs to
  file an issue are the same ones it would need to close, label, or assign one;
  withholding them costs nothing here, because composing the issue is the part
  that actually needs judgement, and it keeps "no agent decides that this work is
  accepted" true by construction rather than by instruction. The same split as
  the rest of the pipeline: models report, the Script records.
- **An item nobody has specified is blocked by that fact** (requirements 16a,
  34e, 36b). The Co-Ordinator used to skip an under-specified or decision-gated
  item in silence, which meant every later cycle re-read and re-skipped it, no
  route ever made it selectable, and the human who could have written the
  missing criteria was never told it existed. Modelling that as a *class of
  block* rather than a new state was the whole design: selection exclusion,
  the Enabler threshold, the per-item claim, the escalation protocol and its
  duplicate guard, the issue-closed recheck and the human's hand-appended
  `unblocked` all key on `attempt-failed`/`unblocked` and needed no notion of
  why the item stopped. A parallel "unrefined" state would have re-earned each
  of those properties, slightly differently, and the differences would have been
  discovered one at a time.

  Three consequences follow that are easy to mistake for oversights. The label
  is a **projection** — applied to an issue-type item, removed with the block,
  never read back — because a label can only reach the `issues` source and the
  work items here are heterogeneous; a pipeline reading it would see a fraction
  of its own state. The refinement itself lands **where a future Co-Ordinator
  already reads**: an issue's thread for an issue, and requirement 3h's log-borne
  map for everything else, rather than a new write power over registers nobody
  else may edit. And an item is refined **once between human touches**, because
  a cheap model re-flagging an expensive model's specification is two models
  disagreeing, which a third pass settles only by luck; the escalation is not a
  fallback there, it is the correct answer.

- **The merge-autonomy kill switch fails closed only on a fresh, cache-empty
  node — everywhere else it still fails open (requirement 2.3b,
  TD-PPagop-26081507).** At WI-2 the switch simply reused `fleet_flag_fetch`,
  whose contract deliberately hides "unreachable with no cache" from its
  callers, so a fresh container (empty `fleet-cache/`) that could not reach
  the state repo resolved the switch as clear and ran at its *configured*
  level — mirroring `fleet/disabled.json`'s own direction. That was kept
  deliberately at WI-2, because the alternative was forking shared
  fleet-flag machinery for a flag nothing consumed yet:
  `merge_autonomy_effective_level` had no behaviour-affecting caller, so the
  direction cost nothing at the time. It could not stay, though: the two
  flags' risk profiles invert the moment WI-5/WI-7 arm a landing path — the
  fleet switch failing open runs a cycle a human still gates, while this flag
  failing open would keep a node *landing* pull requests at exactly the
  moment §6's lever exists for, and on exactly the node least likely to be
  noticed. Failing closed outright was rejected too — a state-repo outage
  would then silently halt autonomous landing fleet-wide, on every node, for
  as long as the outage lasted. TD-PPagop-26081507 resolved it
  asymmetrically instead: `lib/toggle.sh`'s `fleet_flag_fetch_status` tells
  `merge_autonomy_kill_state` apart the one case `fleet_flag_fetch` itself
  still can't — a clear-flag 404 from a transport-unreachable repo with no cached
  copy — and only the no-cache case now resolves to `human`. An established
  node with a cached copy keeps using it through a transient outage exactly
  as before, so the fail-closed blast radius is confined to fresh containers
  during an outage: the one population that cannot know whether an operator
  has pulled the lever. The fail-closed resolution is this one flag's alone:
  `fleet_flag_fetch` and its own callers (`fleet/disabled.json`, the
  usage-limit flag) still resolve a flag they cannot read to "nothing stands
  you down", and their flag-file 404 stays terminal — cache dropped, clear,
  no probe spent. The repo-existence probe below is likewise this one
  flag's: it runs only in the probing mode (`probe-404`) that
  `merge_autonomy_kill_state`, alone in the codebase, asks of
  `fleet_flag_fetch_status`. That confinement is deliberate (PR #474's
  review raised it, on a first cut that had placed the probe in the shared
  fetch body): shared, the probe would have widened the fail-open flags'
  cached path — a flag-file 404 whose probe failed transiently (a
  secondary-rate-limit 403 is the realistic case, on a path that would then
  spend two REST calls where it spent one) would fall back to a stale
  cached "disabled" record and stand a node down against a stand-down the
  operator had just cleared. Confined, `fleet_flag_fetch`'s contract stays
  byte-identical for the two flags whose fail-open direction is itself a
  decision recorded above, and their steady-state 404 spends no extra REST
  call. One residual fail-open case survived,
  knowingly, at TD-PPagop-26081507's own landing (found in PR #448's
  review): "unreachable" there meant only a transport-level failure, because
  the contents API answers a repo-level 404 — the state repo missing, or
  invisible to this token — with the same `404 Not Found` as a missing flag
  file, so a misconfigured `state_repo` slug or a token whose scopes lost
  access still resolved the switch as clear on exactly the fresh-node
  population the asymmetry protects. That was deliberately left out of
  TD-PPagop-26081507's own scope — a design decision in its own right, since
  the 404 path is the switch's steady state and the probe's own failure
  modes need the same explicit classification as the fetch's — and filed
  separately as TD-PPagop-26081602. That item closed it by having
  `fleet_flag_fetch_status`, in the kill-switch read's `probe-404` mode,
  probe `repos/<state_repo>` itself on a flag-file 404, cheap against the
  REST budget: only a probe that confirms the repo is visible resolves to
  clear, and any probe failure — 404, 403, a timeout —
  now gets the same cached-or-unreachable handling a transport failure on
  the flag fetch itself gets, so it fails closed on the same terms rather
  than being read as clear. `scripts/doctor.sh`'s kill-switch report gained
  the matching distinction, keyed on the synthesis naming itself
  (`record.kind: "fail-closed"`) rather than on a real kill naming itself
  `manual`: a hand-written flag file and a garbled one are both genuine
  kills carrying no `kind` at all, so the report keys on the one record whose
  shape it controls. A kill reads `SET`, the synthesis reads `could not be
  confirmed clear`, and an operator is no longer left reading
  `check_repo_access`'s state-repo report as the only way to tell the two
  apart.
- **The fleet-flag memo (issue #502, requirement 2.3a) is per-mode as well as
  per-flag, and an acting site can ask it for a fresh read (issue #513, PR
  #506 review follow-up).** Two gaps followed from shipping the memo against
  only `(NAME, STATE_DIR)`: first, the default mode and `probe-404` resolve
  one and the same contents-API 404 differently (clear vs a possible
  `unreachable`), so a default-mode `clear` memoised first could have been
  served to a later `probe-404` read of the same flag — no caller mixes
  modes for one flag name today, so the gap never fired, but nothing said it
  could not; `_fleet_flag_memo_file` now folds MODE into the memo's own
  filename, so `probe-404` and the default mode never share an entry.
  Second, the memo's whole bargain — one contents-API read per process
  rather than one per read — is right for a read that only ever computes
  with the answer (the back-pressure count, `void_obsolete_ctx_json`), and
  wrong the moment a read is what an outward action turns on:
  `run_approver_stage` posts a real GitHub review under the level it reads,
  so a kill an operator sets mid-cycle must stop it at that stage boundary,
  not wait for the process to end. Clearing the memo by hand at the call
  site (`_fleet_flag_memo_clear`) was rejected as the fix, because
  D18 WI-7's arming step needs the identical fresh read and must not be built
  on an underscore-private function two work items away
  from each other — `fleet_flag_fetch_status` instead grew a `FRESH`
  argument, a supported and documented part of its own contract, threaded
  through `merge_autonomy_kill_state`, `merge_budget_freeze_state` and
  `merge_autonomy_effective_level` so any future acting site opts in the same
  way. The freeze was threaded second: the arming step's eligibility contract
  promises that a WI-6 budget freeze binds at the moment of decision, and a
  memoised freeze read would have left that promise true of the kill switch
  alone. A fresh read still writes
  its answer back to the memo, so it costs exactly one extra contents-API
  read at the acting site itself and nothing downstream — the back-pressure
  loop's own N→1 saving (PR #499 review follow-up,
  test/backpressure-wiring.test.sh's "one kill-switch fetch per cycle
  regardless of repository count") is unaffected, since that read never
  passes FRESH.
- **The merge-budget freeze's own reachability fails open, the opposite of
  the kill switch it sits beside (requirement 2.3c).** Both are fleet flags
  managed through the same `lib/toggle.sh` machinery, and both cap
  `merge_autonomy_effective_level`, but the direction that made the kill
  switch fail closed (TD-PPagop-26081507, above) does not transfer: the kill
  switch protects an operator's own lever, which must hold even from a node
  that cannot currently confirm it, so an unreachable state repo with no
  cache has to assume the worst. A merge-budget freeze exists only because a
  live, reachable count on some node just observed a genuine counting
  anomaly; a *different* node's inability to reach the state repo a moment
  later is a fact about that node's network, not a second anomaly, and
  treating it as one would let a state-repo blip alone cap every repository
  fleet-wide at `agent-approves` with no anomaly behind it. Failing open
  costs nothing a fail-closed reading would have caught for free: the
  anomaly that set the flag is still sitting in `fleet/merge-budget-freeze-
  <slug>.json` for the next reachable read to find, and `scripts/doctor.sh`
  reports the flag's own reachability alongside it either way.
- **A merge-budget anomaly freezes to `agent-approves`, never `human`, and
  escalates to the repository itself, never `crash_loop_repo` (requirement
  2.3c).** Both choices follow from the same fact: the anomaly is a
  statement about one repository's landed-PR count, not about the fleet or
  about whether the Approver App can be trusted to review. Dropping all the
  way to `human` would additionally suspend the App's independent read on
  every future pull request in that repository — a strictly *bigger* change
  than a governor that miscounted has any evidence to justify — and filing
  the escalation fleet-wide, in the pipeline's own repository alongside
  crash-loop and usage-limit escalations, would put a single-repository fact
  in front of whoever triages the fleet's own SOS queue rather than whoever
  already owns that repository's backlog, exactly the reasoning
  `approver_escalate` (requirement 8c) already settled for a single pull
  request's adjudication failure.
- **`merge_budget_per_day` defaults to 8, the same number `max_open_agent_prs`
  already defaults to (requirement 2.3c).** Not a coincidence: both are, in
  their own way, an installation's first guess at how much unattended change
  it is comfortable absorbing per day, and shipping two different numbers for
  the same intuition would read as if one had been tuned and the other
  merely inherited. `0` means unlimited rather than the cap being omitted
  entirely, on the same "an explicit sentinel over an absent key" convention
  `stage_inactivity`'s own per-actor `0` already carries — an installation
  that wants no budget at all says so, rather than the absence of a key
  reading ambiguously as "unlimited" or "not yet configured".
- **The 24-hour count is scoped by a search qualifier, accepting the search
  index's lag, rather than filtered out of an unscoped listing (requirement
  2.3c).** The obvious implementation — list merged pull requests carrying
  `pr_label` and keep the ones inside the window — is not merely wasteful,
  it does not work: `gh pr list` orders by creation, so the listing is the
  label's whole lifetime history, and `GITHUB_PR_LIST_LIMIT` is 60. Every
  repository this fleet governs crosses 60 merged labelled pull requests
  within weeks and never comes back under it, so the listing truncates on
  every call, and a governor that reads a truncated listing as unreadable —
  correctly, since an undercount is its dangerous direction — can then only
  ever answer `refuse`. `arm`, `hold` and the anomaly freeze would all be
  unreachable in production while every fixture-sized test still passed. The
  qualifier bounds the *window* instead, so reaching the page cap once again
  means something real. Its cost is that GitHub's search index is eventually
  consistent, so a merge from the last few seconds may be missing and the
  count may be low by one — the dangerous direction, accepted knowingly:
  undercounting by one on a rolling 24-hour window is strictly better than
  never establishing a count at all, and the cycle's 15-minute tick confines
  the exposure to a merge landing inside the same tick that reads it. The
  exact alternative is a GraphQL walk of `pullRequests(states: MERGED,
  orderBy: {field: UPDATED_AT, direction: DESC})` with an early exit once
  `updatedAt` falls below the cutoff — no index, no lag — and it is what to
  reach for if the lag is ever shown to matter.
- **`fleet_flag_delete` probes every 404 unconditionally — there is no
  fail-open mode to opt into (requirement 2.3a, TD-PPagop-26081604).**
  TD-PPagop-26081602 taught the *read* side of the fleet-flag machinery to
  tell the contents API's two 404s apart — "the flag file does not exist"
  and "this repository does not exist, or is invisible to this token" — but
  only for the one caller that asked for it (`probe-404` mode); every other
  reader kept accepting the collapse, because their flags are fail-open by
  design and the ambiguity only adds one more way of doing so.
  `fleet_flag_delete` reused the same 404 branch and inherited the same
  collapse, but a delete is not a fail-open flag: `absent` is the word
  `fleet_flag_delete_outcome` and its callers (`--enable`, `--clear-limit`,
  `--restore-merge-autonomy`, the fleet-disable-expiry sweep) report as
  `unconfigured`, and an operator reading that word believes the flag is
  gone. On a misconfigured `state_repo` slug or a token whose scopes lost
  access, it was not — the flag stayed set for every peer whose token could
  still see it, and the issuing node's own cache (dropped on the strength of
  the false clear) stopped confirming the disagreement locally too. The
  asymmetry argument that justifies the read side's fail-open 404 does not
  carry over: there, the cost of getting it wrong is a node running a cycle
  whose landing is still bounded by `merge_autonomy_effective_level`'s own
  (separately fail-closed) read, recoverable at the next fetch; here the
  report is simply false, in the one direction this switch exists never to
  be. So the clear side has no mode to opt into — the unconditional accept is
  gone outright.
  `fleet_flag_delete` reuses `fleet_repo_visible` (extracted for exactly
  this reuse, per its own header) directly, unconditionally, on every 404
  its read-for-sha meets: only a probe that confirms the repo is visible
  resolves to `absent`. Anything else — 404, 403, a timeout — returns 1,
  which `fleet_flag_delete_outcome` already translates to `failed`; the
  vocabulary and its callers' warning branches (issue #426) needed no
  change; only the delete's own 404 branch did. Unlike the fetch side,
  there is deliberately no cached-or-unreachable fallback here — a delete
  has no cached copy of "the flag is gone" to fall back to, only the honest
  failure.
- **`approver_app_id` is one fleet-wide scalar, typed as a string.** D18's
  end-state is exactly one Approver App identity (§6 — the same fact that
  denies the kill switch a `--this-node` form), so a per-repository App id
  would contradict the design it serves. That one identity may still hold
  more than one *installation* (agent-ops#913, below) — App and installation
  are distinct layers in GitHub's own model, and only the latter varies per
  repository owner. A string rather than an integer because an App id is an
  opaque identifier this system never does arithmetic on. The name and
  shape were chosen at WI-2, before WI-3 creates the App and WI-4 mints
  tokens from it; those two WIs own the key's final surface and may extend
  it (the private key's own configuration, for one) — but any rename or
  reshaping must land with them, while the key is still consumed by
  `scripts/doctor.sh` alone.
- **The installation id is resolved per repository owner, from a JSON map in
  the environment, not derived from the API (agent-ops#913).** A GitHub App
  installation is per account, so once `repos[]` spans more than one owner —
  the day agent-ops itself moves to the `Pullwright` organisation while
  `poetic`/`poetic-fiddle`/`agent-ops-state` stay on `Poetic-Poems` (#912) —
  one `PULLWRIGHT_APPROVER_INSTALLATION_ID` can no longer back every
  repository this identity reviews. Three shapes were weighed: a per-owner
  environment variable (`PULLWRIGHT_APPROVER_INSTALLATION_ID_<OWNER>`,
  rejected — `deploy/docker/compose.yaml`'s `x-agent-ops-env` anchor
  enumerates every variable it passes through by name, so a new owner would
  need a compose edit on every node, exactly the per-node drift the anchor
  exists to prevent); deriving the installation from `GET /app/installations`
  with the App's own JWT (rejected — the installation id is an operator
  *declaration* of where the Approver may act, the same reason
  `approver_app_id` above is declared and doctor-reconciled rather than
  looked up, and a lookup would let an installation added on any account
  silently widen the fleet's reach); and the shape shipped, one JSON object
  (`PULLWRIGHT_APPROVER_INSTALLATION_IDS`, owner to installation id),
  threaded through the same compose anchor as a single line. Installation
  ids are not secrets (the App id itself already is not), so the map can
  live in plain `.env` beside the scalar default it falls back from for any
  owner it does not name. Resolution is case-insensitive (GitHub logins are)
  and lives in `lib/approver-token.sh`'s `approver_token_installation_id_for`
  alone — every caller passes a repository slug or bare owner, never an
  installation id it resolved itself, so the fallback rule cannot drift
  between call sites. That one function is also where the fallback *stops*:
  it accepts only a run of digits as an installation id, from either the map
  or the scalar, and resolves an empty slug to nothing at all. Both are
  deliberately fail-closed against the scalar, because in a multi-owner fleet
  the fleet-wide default is the wrong answer rather than a safe one — it
  mints one owner's token for another owner's repository, and GitHub's
  403/404 arrives at write time, diagnosed in the log as "GitHub did not
  issue a token" rather than as the configuration typo or caller error it
  was. The digits rule also protects two invariants that live elsewhere: the
  token cache is keyed by installation id and collapses every character
  outside `[0-9A-Za-z_-]`, so two malformed ids could otherwise collide on
  one cache file; and `scripts/doctor.sh` indexes associative arrays by
  installation id, where a subscript of `*` or `@` expands as every element
  rather than as a lookup.
- **The forge authoring App's id has no `config.json` key (D25,
  agent-ops#607), unlike the Approver's `approver_app_id`.** The Approver's
  id is declared in configuration because `merge_autonomy` pairing
  (requirement 2.3b) needs to know at startup whether an identity capable of
  approving is even configured — the id gates a decision this pipeline
  itself makes. Nothing gates on the authoring App's id the same way: it
  either mints a token this cycle authenticates with, or it does not, and
  `GH_TOKEN` is right there either way (D25's own degrade guarantee) — the
  same reason `GH_TOKEN` itself has never had a `config.json` key. Declaring
  it would buy a second place for the same three environment values to
  drift from, with nothing to reconcile against.
- **`GH_TOKEN` remains every node's degrade path rather than being retired
  once the forge authoring App exists (D25).** A single organisation-wide
  App identity was chosen over one App per node specifically to keep the
  shared installation's rate-limit budget and seat cost down (D25's own
  roadmap entry) — which means a genuine GitHub outage or misconfiguration
  affecting that one installation would otherwise strand every node at
  once, with no independent credential behind it. `GH_TOKEN` staying live as
  the fallback is what keeps that failure mode a per-node one instead, at
  the cost of every node still needing a personal access token provisioned
  regardless of whether the App is. A future decision could retire it once
  per-node independence is judged unnecessary; this one does not.
- **A refuse streak is counted from the reviews list, not kept as private
  state (D18 WI-5, requirement 8c).** `approver_refuse_streak` reads GitHub
  fresh, every time, rather than incrementing a counter this pipeline stores
  itself — the same discipline `lib/handoff.sh` and `lib/review-gate.sh`
  already apply to every other fact this document gates a decision on, and
  the same move agent-ops#449 made for `could_not_request`. A private counter
  would need its own reconciliation the moment a cycle dies mid-write, or two
  nodes touch the same pull request in the same hour; the reviews list
  already cannot disagree with itself, and it is the one record GitHub itself
  keeps that a `REQUEST_CHANGES` review actually posted, as opposed to one
  this pipeline merely believes it posted.
- **An Approver that cannot run costs a missing review, never a blocked pull
  request (requirement 8b).** Every failure path in `run_approver_stage` —
  the stage disabled, the credential absent, the identity login or the
  refuse streak unreadable, the token unmintable, the engagement itself
  timing out or returning nothing parseable — ends in a `warning` log event
  and nothing else: the pull request still reaches `pr-ready` exactly as it
  would at `merge_autonomy: human`. The alternative — hand the pull request
  back, the same fail-closed instinct `review_gate_verdict` and
  `confirm_pr_ready` apply to a fact about the *pull request* — was
  considered and rejected here specifically, because none of these failures
  are a fact about the pull request; they are facts about this node or this
  installation's configuration, and the human's own path to merging depends
  on none of them. `scripts/doctor.sh`'s own startup check (requirement 2.3b)
  is what should catch a genuinely broken configuration, at a moment an
  operator is looking, rather than a pull request being silently starved of
  human review while it waits for a stage to hand back.
- **A `REQUEST_CHANGES` write that keeps failing during adjudication cannot
  advance the refuse streak, and that is accepted, not a gap (agent-ops#1226).**
  Because `approver_refuse_streak` counts only `CHANGES_REQUESTED` reviews
  GitHub actually recorded (the bullet above), a write that keeps being
  refused — the App losing review rights, a sustained outage — cannot advance
  the streak past whatever already posted, so a sustained Approver-App write
  outage during adjudication cannot itself reach the recurrence threshold that
  would otherwise escalate. Raised as a judgement worth a human confirming
  rather than assuming when agent-ops#1225 introduced that threshold, and
  confirmed here: it matches the bullet immediately above — an Approver that
  cannot write already costs a missing review, never a blocked pull request —
  each failed write already logs its own `warning`, and the pull request
  keeps flowing through `review-feedback` on the refusals already standing.
- **The Trivial tier's zero-token approval leans on the grading rubric that
  already exists, rather than duplicating it (requirement 8b).** The design
  (§5.2) frames this tier as "`complexity:low`, no protected paths,
  size-capped diff" — a protected-paths classifier and a size cap are a later
  work item's job (WI-7), not built here. Nothing here waits for either:
  requirement 26a's own rubric already forces anything touching
  concurrency, security, state replication, CI/workflow machinery or shared
  library code to grade `high`, never `low` — the same rubric that already
  picks the Reviewer's own tier (requirement 8a). A second, independent
  fence around the same ground would duplicate a judgement the Implementer
  and Reviewer have already made twice; WI-7's classifier is a genuine
  addition for the tiers this work item does not implement landing for
  (`agent-merges-routine`/`agent-merges-all`), not a prerequisite for this
  one's own deterministic approval. D18 WI-12 (Stage 4, agent-ops#415)
  later reversed that last point on its own evidence, and the requirement
  now states the position that holds: the Trivial tier *is* conditioned on
  `landing_protected_paths_hit`, because a protected-path hit forces the
  Critical tier ahead of the complexity grade (requirement 8b), so a
  `complexity:low` change to `lib/` or `prompts/` no longer reaches the
  zero-token approval at all. The rubric argument above still stands for
  every path the classifier reports clean; what changed is that a rubric
  the Implementer and Reviewer can both misgrade is no longer the only
  fence around the gate's own code.
- **"### The Approver" sits after "### The Refiner", not after "### The
  Reviewer" it logically follows.** Every section from "### Logging and
  state" onward already occupies the integer range (33–39d) that would
  otherwise have gone to a stage inserted at that point in the document, and
  renumbering all of them — and every cross-reference to each, scattered
  throughout this file — for one new section was judged far riskier than one
  section whose own number range (40–44) does not physically follow its
  place in the pipeline's running order. Requirements 8b/8c, in "### The
  Script" where the Reviewer's own launch requirements already live, are
  what a reader tracing the pipeline's actual sequence finds first, and they
  point at "### The Approver" by name.

- **Re-affirmation (39c (The Refiner)) extends `refined` rather than adding a third
  verdict.** The tech-debt item that carried agent-ops#670's Part 2 forward
  (TD-PPagop-26082305) suggested a new verdict, distinct from
  `needs-refinement`, for an item the Refiner judges already adequately
  specified. #670's own design — written by a human before the tech-debt item
  existed — took the narrower route instead: the item is not a new *kind* of
  outcome, it is the same outcome (`refined`) reached without writing
  anything new. Reusing `refined` means the Script's recording path needed no
  structural change at all — `refinement_record_fields` (requirement 39c (The Refiner))
  already accepts a `comment_url`/`spec` on its own terms, never asking
  whether it was this cycle's own write — so the whole fix is confined to
  what the Refiner is told to do with an existing, adequate specification,
  never to a new switch case, a new label projection, or a new field on the
  verdict schema for every reader of it to learn. A third verdict would have
  bought nothing a re-affirmed `refined` does not already give: the item
  re-enters `refinements_map` (3h) and proceeds to selection either way.

- **Re-affirmation's non-`issues` scope (39c (The Refiner)) reads the candidate's own
  gatherer `entry` as "an existing specification," gated by the same
  adequacy bar as a fresh one (agent-ops#810, resolving agent-ops#813).**
  #670's Part 2 design described re-affirmation only for the `issues` case,
  where the Refiner cites a comment on a thread it can see; PR #805 shipped a
  parenthetical generalising it to every other source without saying what
  "an existing specification" means there — a prior `refined_spec` never
  enters the Refiner's own input, since `refiner_candidate_items` reads
  `$refinements` only for its `is_refined` exclusion and never folds a
  cleared entry into the `{repo, source, item, entry}` payload it builds.
  Three options were weighed: **1.** confine re-affirmation to the `issues`
  case and revert the parenthetical; **2.** define a non-`issues` "existing
  specification" as the candidate's own `entry`, counted only where the
  Refiner judges it adequate by the fresh-specification bar; **3.** fold each
  candidate's own prior `refinements_map` entry into the payload
  `refiner_candidate_items` builds, so a genuine prior `refined_spec` becomes
  visible and re-affirmation means citing that rather than the raw `entry`.
  Option 2, answered "yes," is what shipped. Option 1 was rejected because it
  recreates, for every non-`issues` source, the exact deadlock shape
  requirement 34e's own incident wrote out of the `issues` path: an item
  carrying a good human-written `entry` would have no honest `refined` to
  return and would fall to `needs-refinement`. Option 3 was rejected because
  a candidate carries no `refinements_map` entry by construction —
  requirement 39a (The Refiner)'s already-refined exclusion is *why* it is a candidate at
  all — so the fold would carry nothing in the incident's own shape (a block
  clearing what dropped the item from the map), and making it real would
  mean retaining cleared refinements as visible history when the commonest
  clearing cause — a block that has itself since cleared — is itself
  evidence against the prior text's adequacy. Revisiting this trade-off is
  warranted only on measurement — redundant re-specification of unchanged
  non-`issues` items shown to recur at material scale — never on a guess
  about how often it happens.

- **The GitHub credential check (0b) escalates unconditionally, never through
  `escalation_autonomy`.** That ladder decides whether one specific
  escalation — an Enabler refinement-disagreement (requirement 36b) — is
  adjudicated once before reaching a human, and its `adjudicate-first` path
  is itself a model engagement against GitHub. A rejected credential defeats
  that engagement the same way it defeats the Co-Ordinator, so routing
  through it would reintroduce the exact spend 0b exists to avoid, over a
  disagreement that does not exist here — there is nothing to adjudicate
  between. 0b instead follows 1c's and requirement 2.7's own precedent: an
  operational fact about the node, escalated straight through
  `create_escalation_issue`, deduplicated the same way.

The choices above (platform, models, permissions, system location) were
confirmed by the repo owner on 2026-07-13; no open questions remain.

- **The untrusted-content framing is a stated rule, not a security
  boundary.** Requirement 45 exists because every stage reads text anyone
  on the forge can author, with write credentials in its environment
  (review `reviews/project-review-2026-08-23` F-SEC-01; roadmap decision
  D24; register `TD-PPagop-26082407`). A framing in a prompt deters the
  naive majority of injection attempts and gives every stage one consistent
  rule to cite when it refuses; it stops no determined attacker, and D24
  says so plainly — the technical containments (network egress
  allowlisting, per-stage tool scoping) are D24's other pieces. The block
  is pinned byte-identical across the prompts for the same reason the
  final-message parser's three copies are pinned to each other: a rule with
  drifting copies is two rules.

- **The egress fence is compose topology plus a proxy, not a firewall in
  the image.** The image runs fully non-root with no `NET_ADMIN` anywhere
  but the tailscale sidecar, so an `iptables` rule in the entrypoint would
  have needed a capability expansion on every service that runs a stage —
  exactly the wrong direction for a control meant to contain a compromised
  stage, and a mechanism running *inside* the thing it fences. An
  `internal: true` network plus a squid sidecar needs neither: the
  enforcement lives outside the fenced container, in topology Docker
  applies, and the proxy variables are merely what points the tools at the
  one door (investigation credit: TD-PPagop-26082429, filed from the
  pipeline's own attempt at this work on the closed #752). Stated honestly,
  per D24: the fence removes the arbitrary-host exfiltration and
  command-and-control channel; it does not close GitHub-as-exfiltration (an
  allowlisted, writable, public destination by design), and DNS resolution
  still reaches the host's resolver through Docker's embedded DNS, so
  DNS-tunnelling exfiltration remains technically open — narrow, noisy, and
  accepted under D24's residual rather than pretended away.
- **The `claude` CLI's optional traffic is disabled, not allowlisted.**
  Auto-update checks, telemetry, error reporting and claude.ai MCP
  connectors are all turned off in the scheduler's environment
  (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `DISABLE_AUTOUPDATER=1`,
  `ENABLE_CLAUDEAI_MCP_SERVERS=false`), shrinking the allowlist to what
  stages actually need — and pinning stage behaviour to the shipped CLI
  version and code-default feature flags, which for an unattended fleet is
  a reproducibility gain, not a loss. The variables' quirk is recorded
  where they are set: some treat *any* value, `"0"` included, as opted
  out, so they are set to `"1"` or not at all, never templated.
- **A subject that merges mid-stage retires as a completion; the Reviewer
  never raises a replacement pull request (agent-ops#916, escalation #922).**
  Three forks the original issue left open were owner decisions, not
  conventions derivable from the code, and escalation #922 settled all three
  in one round: (1) the Reviewer may not open a replacement pull request when
  its subject merges mid-pass — a replacement it raises itself is invisible
  to every machine-readable record this pipeline keeps for one it raised
  (no `pr-raised`, no `pr-<n>` claim, no `complexity:*` label, no Approver
  engagement), which is exactly how #891 sat unreviewed for 9.4 hours after
  #883 merged 21 minutes into the Reviewer pass that produced it; instead the
  Reviewer stops, ends `blocked` naming the merge, and carries its leftovers
  in `file_debt`/`file_issue` — the Approver's own field shape, since the
  Reviewer carries no App identity of its own either. (2) A mid-stage merge
  is a completion, not `attempt-failed`, decided by the Script's own read of
  GitHub — never the Reviewer verdict's word — so it fires whether the
  Reviewer noticed or not, and a Reviewer claiming a merge GitHub denies
  falls through to the ordinary handling as a model error. (3) One read
  (`pr_merge_state`) serves two call sites at different strictness: fail-closed
  at the handoff, since nothing downstream ever re-checks; advisory at the
  Reviewer's own stage-start, since the handoff read still guards whatever
  the stage produces even when this earlier one could not be answered.
- **The escalation webhook was promoted to the installation's one notify
  channel rather than left as a filing-failure fallback (issue #1279,
  requirement 2m).** Everything the pipeline already knew to log — an
  escalation, a pager transition (requirement 51), a fleet-wide stand-down —
  ended on the dashboard and nowhere else; two incidents (the 2026-08-14
  watchtower stall and the 2026-08-08 mirror corruption) each ran for days
  because the dashboard was up and correct and nobody was looking at it. Two
  duplicated webhook-POST implementations already existed for narrower jobs
  — `escalation_webhook_notify` (`lib/enabler.sh`) and its parameterised twin
  `_pager_webhook_notify` (`lib/pager.sh`, which cannot share the first's
  cycle-scoped globals — see that file's own header) — which `lib/notify.sh`
  replaces for every notification in the three classes above, used from a
  cycle-context wrapper (`notify_post_cycle`) and directly (lib/pager.sh,
  threading every context parameter explicitly, the shape that file's whole
  design already commits to). `_pager_webhook_notify` itself survives for
  requirement 51's own filing-failure fallback alone — the two paths in
  `pager_file` where the pager's tracking or `pw::decision` issue could not
  be filed — which is not one of the three classes and still POSTs its own
  pre-#1279 body shape, ungated by `notify_events`; unpicking it also
  reaches into requirement 51's text, so it is tracked separately as #1329
  rather than folded in here. `escalation_webhook_url` stays accepted as an alias for one release
  rather than a breaking rename, so an installation that has already wired
  the old key into an alerting receiver keeps delivering to the same endpoint
  through the transition; `scripts/doctor.sh` warns on it so the rename is
  visible rather than silently indefinite. The alias carries the URL only, not
  the body: the pre-#1279 filing-failure payload was `{reason, detail, repo,
  item, node, cycle}`, and the one body every class now shares has no
  `reason`, `item` or `cycle` in it (`reason` became `title`, `item` folded
  into `key` as `<repo>#<item>`). One body for three classes is the point of
  the promotion, so the receiver-side edit is the deliberate cost of it rather
  than something the alias could have absorbed — which is why the CHANGELOG
  entry states the field-level change alongside the rename rather than leaving
  an operator to infer it from the key still working.

  The webhook's own test coverage split along the same seam as the code.
  `test/escalation-webhook.test.sh` tested one thing through one path — the
  filing-failure POST, reached only through `create_escalation_issue` — so a
  single file could cover both the channel and its wiring. With three classes
  reached from four files, the channel's own behaviour (the classes, the
  alias, the per-`(event, key)` rate limit) is `test/notify.test.sh`'s, and
  what `lib/enabler.sh` does with it is `test/enabler-notify-wiring.test.sh`'s.
  The second is deliberately not a subset of the first: the assertions worth
  keeping from before this rewrite are the ones about `create_escalation_issue`'s
  own return value and stdout, which no test of `notify_post` in isolation can
  make, and which matter more now than they did — the success path gained a
  notification, and it sits immediately before the `printf` every caller
  parses back.
- **`notify_min_interval_seconds` coalesces per `(event, key)` pair, not per
  notify class and not per key alone.** A coarser bucket (one shared key per
  class) would suppress a genuine second escalation about a *different* item
  behind an unrelated first one — a distinct fact is a distinct page. Keying
  per instance (`repo#item` for an escalation, the pager's own `key`, one
  static key per stand-down kind) means the coalescing this key exists for —
  the same fact repeating, the 2026-08-28 burst (#933–#938) — still
  collapses, because a repeating fact is by construction the same key every
  time, while two unrelated facts arriving close together both still post.
  The event has to be the other half of that pair for the same reason: a
  transition's two halves share one key by construction
  (`fleet-standdown-begin`/`-end`, `pager-fired`/`pager-cleared`), and the
  `begin` half re-posts every cycle for as long as the stand-down holds — so
  keying on the key alone kept that key's last send permanently inside the
  interval and suppressed the `end`, which is the half an operator is
  waiting on. "Began" and "ended" are two distinct facts, so by this entry's
  own rule they are two pages.
- **A configured `state_local_streams_retained` is a cap as well as a
  floor, and the fleet-log snapshot lives only as long as the run that
  wrote it (agent-ops#1826, #1932).** The standing decision of 2026-08-29
  (#918/#901) kept every retention count key floor-never-ceiling,
  `max(configured, derived)`, and called `STATE_SYNC_STREAMS_RETAINED` a
  test bypass rather than an operator lever; that line is amended in
  `docs/STANDING-DECISIONS.md`, not deleted. What changed the answer for
  this one key was measurement: at the shipped 15-minute cadence the
  derivation is 200, a fleet-log snapshot ran 45 MB on 2026-09-18 and about
  70 MB by 2026-09-28 (the union grows with `log.jsonl`, which nothing
  rotates), so 200 of them were 7.3–7.4 GB per node, and the two poetic
  nodes sharing one 38 GB disk lived at the disk-pressure valve's 2 GiB
  floor (agent-ops#1678) with daily `disk-low` stand-downs until, on
  2026-09-28, the other writers on that disk took the last 2 GiB and stood
  both nodes down for four hours (agent-ops#1930). Under the floor-only
  contract the only way down was a test-only variable compose did not
  forward. The cap alone was not the fix, and its first form would have
  done harm: a count below the derivation lets the directories later ticks
  leave push a running cycle out of the retained window, at which point the
  push deletes the stream its watchdog is reading and the stage is killed
  as `inactivity` — the node logs of 2026-09-10 to 09-28 held 24 such
  overtaken cycles on poetic-1 and 22 on poetic-2. Hence three changes that
  travel together: the record a live lock names is spared whatever the
  count; a tick that finds the lock held leaves no directory, since most
  directories at this cadence were such ticks, each holding nothing but a
  full snapshot; and the snapshot is removed by the cycle's own cleanup,
  because a count bounds how many snapshots are kept and never how large
  they are, and at any fixed count the retained bytes grow with the fleet's
  history. The count now governs the stage streams, whose size does not
  grow with history, and meets a snapshot only where a run died before its
  cleanup. The other two count keys keep the floor-only contract: a value
  below their derivation could only shorten the record they exist to keep.
- **Every process's scratch is one pid-named directory, an orphan is told
  by pid rather than age, and the sweep runs from the launcher
  (agent-ops#1827, #1933).** The 2026-09-28 disk-full incident on the host of
  `poetic-1` and `poetic-2` (agent-ops#1930) found the scheduler's writable
  layer at 1 GB twenty-six minutes after a fresh start: two abandoned 307 MB
  Publisher working sets and, beside them, the anonymous `tmp.*` files the
  libraries spool, none of it within the disk-pressure valve's reach. The
  issue's diagnosis — that bash runs no `EXIT` trap when an untrapped `TERM`
  kills it, so every publish the hook's `timeout 120` ends leaks its set —
  did not survive review: bash does run the trap (its `termsig_handler`
  calls `run_exit_trap` before re-raising the signal), the pull request's
  own `TERM` case passed forty-one times in a row with the proposed signal
  traps deleted, and the one reproduction on the node had compared `/tmp`
  before and after a publish while two other publishes were writing there,
  so it could not say whose directories it was looking at. What the
  incident did show is that a process's spools were scattered — the working
  set in one anonymous `mktemp -d`, each library's files beside it — so any
  exit that skipped one cleanup (the fast tick's `exec`, a `KILL`) or
  reached one and not another left something, and nothing could tell an
  orphan from a live publish's files, since neither carried its owner's
  name. Hence one directory per process, entered at start with `TMPDIR`
  pointed inside it, so that the process's own `EXIT` trap is the only
  cleanup any of its spools needs; a name carrying the pid, so that
  liveness — not age, which a publish that has run for hours (agent-ops#1620)
  would fail — is the test; the rebuild as a child rather than an `exec`, so
  the trap still runs; and the sweep in the launcher, which runs on every
  node every five minutes whatever the node's role, where a sweep in
  `agent-cycle.sh` alone never reached a standby node, although its launcher
  published every five minutes. Signal traps that turn `TERM` into `exit`
  were considered and rejected: they test nothing that fails without them,
  and a trapped signal is handled only after the foreground command returns,
  so a `timeout 15` GitHub call in its own process group would hold the hook
  past its `timeout 120`; the hook carries `-k 10` instead, so a publish
  whose exit outlasts ten seconds is killed and its directory swept.
  Reshaping the `TERM` case to start the publish under `timeout` itself, as
  the review asked, found the one real leak on the signal path: a command
  forked in the instant between `timeout`'s first signal and bash's next
  check never receives the group-wide second, outlives its parent, and
  recreates an entry after `rm -rf` has listed the directory — once in some
  thirty runs under load, one file. The release therefore renames the
  directory to a tombstone before removing it, with the signals ignored for
  the duration; forty further runs under load left nothing.

