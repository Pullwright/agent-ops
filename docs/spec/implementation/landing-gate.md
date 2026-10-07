## The Landing Gate

The only branch this system protects is each repository's default branch.
**No model ever pushes to it, approves a pull request targeting it, or merges
one** — GitHub's branch protection enforces this anyway, and it holds at
every `merge_autonomy` level (D18, `docs/reviews/2026-08-14-autonomy-investigation.md`
§5.1) this document's requirements implement: the model's own prohibition is
unconditional, never something a trust level relaxes.

Who else may approve or land a pull request this system raises is what
`merge_autonomy` names, per repository (config, requirement 2.3b's own
resolution, `lib/merge-autonomy.sh`):

- **`human`** — today's behaviour, byte-for-byte, and the product default: a
  human approves and a human merges, on every pull request. Nothing below
  this section changes.
- **`agent-approves`** — the Approver stage (requirements 8b/8c, `### The
  Approver`) gives an independent second read, under a non-author GitHub App
  identity ("Pullwright Approver"), and posts a real `APPROVE` or
  `REQUEST_CHANGES` review. **A human still merges.** The App's review is
  additional, not a replacement for the human's own — a `CHANGES_REQUESTED`
  from either blocks the same way, and the App can never dismiss or approve
  around a human's own `CHANGES_REQUESTED` any more than the pipeline's own
  authoring identity could.
- **`agent-merges-routine`**, **`agent-merges-all`** — accepted and validated
  (requirement 2.3b: a level here with no `approver_app_id`, or with the
  repository's own ruleset still requiring code-owner review, is a
  `scripts/doctor.sh` failure) and reviewed identically to `agent-approves`
  (requirement 8c). Landing differs: once the Approver's own engagement this
  round reaches an explicit, non-adjudicating `APPROVE`, the arming step
  (requirement 8d, `run_landing_stage`, `lib/landing.sh`) re-reads every
  gate below fresh and, only if every one clears, lands the pull request
  itself — enqueued where the base branch has an active merge queue, or
  `gh pr merge --auto --squash` where it does not — under the Approver
  App's own minted token, never the pipeline's authoring identity. A human's
  residual act narrows to whatever the classifier below refused. The
  classifier draws one distinction between the two levels, and only one: the
  same `merge_autonomy_routine_complexity` ceiling and the same
  `merge_autonomy_routine_sources` list bind at `agent-merges-all` as at
  `agent-merges-routine`, but a protected-path hit — refused outright at
  `agent-merges-routine` — is deferred at `agent-merges-all` to the
  compensating controls D18 WI-12 (Stage 4, agent-ops#415) adds: the
  Critical Approver tier, forced by the hit itself regardless of complexity
  (requirement 8b), and the `landing_cool_off_hours` wait since that
  approval — measured only against a standing review whose own `commit_id`
  still matches the pull request's current head, so that a push after
  approval restarts it (gate 4.5 of the sequence below). So a repository set
  to `agent-merges-all` lands exactly one class of pull request
  `agent-merges-routine` would not — the protected-path one, and only once
  every one of those controls holds. The two levels are also distinct in configuration and
  in requirement 2.3b's own validation, and differ in behaviour elsewhere
  (requirement 34d's void corroboration).

  A pull request is eligible to land automatically iff **all** of:
  - `merge_autonomy_effective_level` is `agent-merges-routine` or
    `agent-merges-all` at the moment of decision (never the raw configured
    value — the kill switch and a WI-6 budget freeze both bind here);
  - its resolved `complexity` is a member of
    `merge_autonomy_routine_complexity` (config, D18 Stage 3,
    agent-ops#725, default `low`/`medium`) for this repository — an empty
    or unrecognised complexity never arms, the first half of a deliberate
    belt and braces. Requirement 26a already forces `high` onto anything
    touching concurrency, security, CI/workflow machinery or shared
    library code, so widening this list to admit `high` routes exactly
    that class of diff through automatic landing;
  - its work order's `source` is a member of `merge_autonomy_routine_sources`
    (config, default `tech-debt`) for this repository;
  - below `agent-merges-all`, its diff touches none of
    `merge_autonomy_protected_paths` (config, D18 Stage 3, agent-ops#724) —
    the second half of the belt and braces, and this design's own answer to
    risk register item 1 (a pull request self-modifying the gate it is
    riding through it). Defaults to agent-ops's own nine whole-path
    prefixes — `.github/*`, `deploy/*`, `prompts/*`, `lib/*`,
    `config.schema.json`, `config.json`, `agent-cycle.sh`,
    `review-cycle.sh`, `CODEOWNERS` — the paths that gate *this*
    repository's own behaviour; a `repos[]` entry's own
    `merge_autonomy_protected_paths` overrides the list for that repository
    alone, the same precedence `merge_autonomy_routine_sources` uses, for a
    repository whose own gate code lives elsewhere. An entry ending `/*`
    matches as a whole-path prefix, any other entry only that exact path.
    At `agent-merges-all` a hit is not eligibility's own answer: it is
    deferred to gate 4.5's compensating controls (D18 WI-12), which refuse
    unless the approving engagement ran at the Critical tier, the standing
    review's own `commit_id` still matches the pull request's current head,
    and the `landing_cool_off_hours` wait since it has elapsed.
    The last three of agent-ops's own default joined the list at the human
    review the first draft deferred them to: `agent-cycle.sh` is the engine
    that calls the arming step, `review-cycle.sh` is the review pipeline's
    entry point, and `config.json` carries the `merge_autonomy` level and
    `merge_autonomy_routine_sources` this very gate reads.

  An eligible pull request still arms nothing unless every one of a second
  set of gates, each re-read fresh rather than reused from earlier in the
  round, also clears: the required checks are green and the security-alert
  delta is clean at the current head (`review_gate_verdict`, stricter here
  than the ordinary ready-gate handoff — an alerts-only `unknown` refuses
  arming even though it only warns there); the Approver App's own review is
  genuinely standing `APPROVED` on GitHub right now — not merely this
  round's own in-process verdict, since a write GitHub itself refused still
  reports success to the stage that requested it (requirement 8b's own "a
  missing review, never a stranded PR"); no human `CHANGES_REQUESTED`
  stands, and no unreconciled human comment stands either — a plain comment
  posted after the pull request was already Ready, which a formal review
  cannot be, since GitHub refuses a `REQUEST_CHANGES` review from a pull
  request's own author and every pipeline write and human comment here land
  under the same account (agent-ops#672, closing the residual window left
  after `lib/reconciliation-gate.sh` closed the same gap at the Reviewer's
  own ready-flip, agent-ops#533); the merge budget (below) says `arm`, not
  `hold` or `refuse`; and
  the pull request is not already in the merge queue, nor was it ever queued
  and removed without being re-queued since — a dequeue this stage never
  reverses itself, whether a maintainer's own deliberate removal or a
  checks failure `scripts/gather-dequeued.sh`'s own `dequeued` source exists
  to diagnose and fix instead (`merge_queue_dequeue_actionable`,
  `lib/merge-queue.sh`; PR #557 review round 2 of TD-PPagop-26081701).
  **Any of these that cannot be read is a refusal, logged `landing-refused`,
  never a pass** —
  the same fail-closed discipline `lib/review-gate.sh` established for the
  ready-gate handoff, applied here to the one place a pull request lands
  without a human click.

The fleet-wide kill switch (requirement 2.3b) forces every repository's
*effective* level to `human` regardless of what is configured, independent
of this section — `merge_autonomy_effective_level` is what every approval
and landing path (`run_approver_stage`, `run_landing_stage`) reads, never
the raw configured value. Disabling the level for one repository (setting
`merge_autonomy` back to `human` or `agent-approves`, per repository or
fleet-wide) or pulling the kill switch both disarm cleanly and immediately:
neither the Approver stage nor the arming step executes any further write
at or below the level that change takes effect, and nothing about a pull
request already landed is undone.

Above `human` but below `agent-merges-routine`, the only thing bounding how
fast pull requests actually merge is a human's own click — this document
arms no rate of its own there. `merge_budget_per_day` (requirement 2.3c,
`lib/merge-budget.sh`) is what replaces that bound at `agent-merges-routine`
and above: a rolling-24-hour cap on pull requests this pipeline may land in
one repository, enforced at the arming step itself (`merge_budget_decide`,
one of the gates above) rather than left to however often a human happens
to click merge. Reaching the cap approves a pull request through the
ordinary review path but does not arm its landing — the backlog queues
visibly rather than merging past the cap. A counting anomaly — more pull
requests landed in a window than the cap ever permitted, which a correct
governor should never observe — freezes a repository's
`merge_autonomy_effective_level` at `agent-approves` until a human clears
it, independent of whatever level is configured.

Nothing above re-attempts a held or refused pull request from *within* the
round that held or refused it — a human merging it by hand, or a later
round's own fresh Approver approval re-entering the arming step, are both
still real paths. What closes the gap between those and never is the
landing-retry sweep (requirement 8u, `_landing_stage_attempt`,
TD-PPagop-26081701): once per cycle, for every repository at
`agent-merges-routine` or above, it re-enters the same seven gates above —
unchanged, not a second copy of them — for every open, non-draft pull request
whose Approver review is genuinely standing `APPROVED` on GitHub right now.
A pull request whose gates still refuse is refused again, at whatever cost
that refusal already had (a `complexity:high` pull request, or a
protected-path hit below `agent-merges-all`, is never eligible in the first
place, so the classifier refuses it identically every time it is asked); a
pull request whose refusal reason has
since cleared — the budget window rolling over, the kill switch or a
per-repo freeze lifting, a `merge_autonomy`/`merge_autonomy_routine_sources`
config change, a required check going green, a transient read that now
succeeds, or D18 WI-12's own `landing_cool_off_hours` finally elapsing on a
protected-path pull request at `agent-merges-all` (the one refusal reason
that clears with nothing but time, and so the one this sweep is the sole
route out of) — lands on this sweep's own pass rather than waiting for a human or
a fresh review round. The one gate the sweep answers differently from the
original round is the pull request's own `source`: never re-derivable from
GitHub (there is no field for it), so the sweep reads it back from the
fleet's own union log instead (`landing_retry_source_map`,
`lib/union-log-scan.sh`) and skips a pull request it cannot resolve one for,
rather than guessing. A pull
request a peer node's fleet-wide `pr-<n>` claim currently holds — under
whatever item ref won it there, a `review-feedback` round most often — is
excluded before any of that: this sweep and the requirement-46 restale
sweep below are the two fleet-wide pull-request sweeps that act across every
node's own work rather than a single cycle's own claimed item, so both
consult the claim that keeps two nodes off the same pull request through one
shared read, `_approver_sweep_claimed_pr_numbers` (`lib/approver.sh`),
fetched once per repository per pass and never per candidate (issue #987,
TD-PPagop-26082509).

Every other branch **created by this system** (i.e. under `branch_prefix`)
is entirely at the agents' disposal: the Reviewer may amend, add to, rebase,
or force-push such a branch as it judges best — always with
`git push --force-with-lease`, never a bare `--force`, so a peer's own push to
the same branch (a still-running Implementer, a concurrent finishing-source
cycle on the same PR — requirement 17a's PR-keyed claim narrows but does not
eliminate the window, issue #360) is refused rather than silently overwritten.
Agents must not rewrite branches outside `branch_prefix` — those belong to
humans, and the target repos' own rule (force-pushing requires explicit
instruction) applies.

The Reviewer's purpose is to spend cheap model time so that the Human
Reviewer's time is spent on work that is already close to mergeable; the
Approver's purpose, where configured, is to spend a second, independent
slice of cheap model time so that a human's own approval — never withdrawn by
any level above `human` — meets a pull request that has already survived one
more adversarial read. At `human`, the landing gate is the only point at
which a human is required and it is a single, undivided act (approve and
merge together); above it, the human's residual act narrows to the merge
itself, but never disappears within what this document currently
implements.

