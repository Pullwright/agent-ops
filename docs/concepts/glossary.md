---
title: Glossary
summary: Every coined or repurposed term this product uses, defined once
audience: evaluator
kind: explanation
---

# Glossary

This defines every term Pullwright coins or repurposes, in alphabetical
order. Each entry gives a short definition and a pointer to the requirement
or section that is authoritative for the term. Each entry also carries a
stable anchor (the `<a id="…">` before its heading) that does not change if
the heading's own wording later does, so other documents, code, and agents
can link to a definition without the link going stale.

## Entries

<a id="active"></a>
### Active

The node role value `AGENT_OPS_ROLE=active` marks a machine as the one that
spends: it runs the implementation cycle and the daily review tick. Only the
exact value `active` counts — unset, empty, or misspelled all mean
[standby](#standby).

Authoritative: docs/guides/operating/README.md § "Which node runs the cycles".

<a id="agent-approves"></a>
### `agent-approves`

A [merge autonomy](#merge-autonomy) level at which the Approver App gives a
pull request an independent second review and posts a real `APPROVE` or
`REQUEST_CHANGES`, but a human still merges every pull request.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "The Landing Gate".

<a id="agent-merges-all"></a>
### `agent-merges-all`

The top [merge autonomy](#merge-autonomy) level. Eligible pull requests land
automatically exactly as at [`agent-merges-routine`](#agent-merges-routine),
except that a hit on a [protected path](#protected-path) — refused outright
one level down — is instead deferred to the Critical Approver tier and the
[cool-off](#cool-off) wait.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "The Landing Gate".

<a id="agent-merges-routine"></a>
### `agent-merges-routine`

A [merge autonomy](#merge-autonomy) level at which the Script's own arming
step lands an eligible pull request itself, once the Approver has given an
explicit, non-adjudicating `APPROVE` and every landing gate re-reads clear.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "The Landing Gate".

<a id="approver"></a>
### Approver

A headless Claude Code invocation, engaged only where [merge
autonomy](#merge-autonomy) is above `human`, that independently judges a
pull request the Reviewer has already marked ready and returns a verdict.
The Script turns that verdict into a real GitHub review posted under a
non-author GitHub App identity ("Pullwright Approver"), never under this
system's own authoring account.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "Actors", item 5a.

<a id="back-pressure"></a>
### Back-pressure

The primary throttle on both spend and on the [Landing Gate](#landing-gate)
silting up: when the count of open draft pull requests, `CHANGES_REQUESTED`
pull requests, and live [claims](#claim) across configured repositories
reaches `max_open_agent_prs`, a cycle stands down rather than adding more.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 2 (step 2).

<a id="band"></a>
### Band

A priority rank — `Urgent`, `High`, `Medium` (the default when unset), or
`Low` — that orders the Co-Ordinator's walk over open issues. A band is
spent at gathering time (`issues:urgent`, `issues:high`, and so on) and
collapses to the plain [source](#source) `issues` by the time an item
becomes a [work order](#work-order).

Authoritative: config.schema.json `sourceToken`; docs/IMPLEMENTATION-PIPELINE-SPEC.md
requirement 39g.

<a id="blocked"></a>
### Blocked

A status meaning real work exists but something is in the way. The
Co-Ordinator re-checks a blocked item itself each cycle and clears it (an
`unblocked` event) once the impediment, or the underlying work, has gone;
an item that nothing clears reaches the Enabler. Distinct from
[void](#void), which means there is no work at all.

Authoritative: docs/guides/operating/README.md § "Blocked and void items".

<a id="chain"></a>
### Chain (finish-then-continue)

Finish-then-continue (issue #248): once a cycle that won a [claim](#claim)
has fully ended, it may launch another cycle immediately rather than
waiting for the next cron firing, as long as sources remain and the
lineage is under `max_chained_cycles`.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 39 (§ "The
Script (`agent-cycle.sh`)").

<a id="claim"></a>
### Claim

The Script's own atomic, per-item lock, taken before the Implementer
starts and never by the model itself: a branch claim (`agent/<item-ref>`,
created at the default branch's own head — the claim branch *is* the
working branch) for a fresh item, or a file claim for a source whose branch
and pull request already exist (`review-feedback`, `merge-conflicts`,
`dequeued`, `landing-refusals`, `abandoned-drafts`).

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 17a.

<a id="co-ordinator"></a>
### Co-Ordinator

A headless Claude Code invocation that selects at most one well-scoped item
of work each cycle and emits a [work order](#work-order). It does not
implement anything.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "Actors", item 3.

<a id="cool-off"></a>
### Cool-off

`landing_cool_off_hours`: the wait, at [`agent-merges-all`](#agent-merges-all)
only, between the Approver's own approval of a [protected-path](#protected-path)
pull request and the arming step landing it. It is measured only against a
standing review whose own `commit_id` still matches the pull request's
current head, so a push after approval restarts it.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "The Landing Gate".

<a id="decide-tactical"></a>
### `decide-tactical`

The third rung of `escalation_autonomy`. Before the Script files an
[escalation](#escalation) issue for any Enabler `escalate` verdict, one
bounded pass runs first and may settle the item (recorded as an ordinary
`unblocked`) or decide a tactical question on the pipeline's own authority
— the human-touch equivalent, recorded as one comment plus a
`decision-taken` event — instead of [paging](#page) a human at all. It
never widens the owner-only boundary requirement 36a sets.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 36d.

<a id="drain"></a>
### Drain

Set with `--drain <reason> [--for …] [--until …] [--this-node]`: stops a
node (or the fleet) from picking up new work while letting work already in
flight finish. A drain reaches "at rest" once every repository's finishing
[bands](#band) (`review-feedback`, `merge-conflicts`, `dequeued`,
`abandoned-drafts`) are empty and no live claim names a finishing-source
item.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirements 2.3d and
2.9.

<a id="enabler"></a>
### Enabler

A headless Claude Code invocation, engaged rarely and at the end of a
cycle, that re-examines items recorded as [blocked](#blocked) which the
pipeline has not cleared by itself. It unblocks, voids, or leaves them
blocked with a fresher condition; specifies an item nobody has scoped well
enough to select; or, where an item cannot be moved any other way,
[escalates](#escalation) it. It writes no code and raises no pull request.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "Actors", item 7.

<a id="escalation"></a>
### Escalation

The GitHub issue the Script files, assigned to a human, when the Enabler's
verdict is that an item cannot be moved without one. Closure is the whole
protocol, and the issue body says so: the human does the thing and closes
the issue.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 36a.

<a id="human-level"></a>
### `human` (merge autonomy level)

The default [merge autonomy](#merge-autonomy) level, and today's behaviour
byte-for-byte: a human approves and a human merges every pull request.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "The Landing Gate".

<a id="human-reviewer"></a>
### Human Reviewer

Gives a pull request's final approval at [`human`](#human-level), or an
additional one alongside the Approver's own above `human`, through the
ordinary GitHub process. The Human Reviewer merges every pull request at
`human` and [`agent-approves`](#agent-approves); at
[`agent-merges-routine`](#agent-merges-routine) and
[`agent-merges-all`](#agent-merges-all), the arming step lands an eligible
pull request itself, and the Human Reviewer's own role narrows to whatever
that classifier did not cover (see [Landing Gate](#landing-gate)). Not
launched by any part of this system.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "Actors", item 6, read
together with § "The Landing Gate".

<a id="implementer"></a>
### Implementer

A headless Claude Code invocation that carries out one [work
order](#work-order) on a branch and raises a draft pull request.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "Actors", item 4.

<a id="landing-gate"></a>
### Landing Gate

The chain of gates, each re-read fresh rather than reused from earlier in
the round, that decides whether — and by whom — a pull request may be
approved and landed on a repository's protected default branch. No model
ever pushes to that branch, approves a pull request targeting it, or
merges one, at any [merge autonomy](#merge-autonomy) level; GitHub's own
branch protection enforces this independently of the gate.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "The Landing Gate".

<a id="merge-autonomy"></a>
### Merge autonomy

The per-repository setting (`merge_autonomy`) naming who, besides a human,
may approve or land a pull request this system raises: one of
[`human`](#human-level), [`agent-approves`](#agent-approves),
[`agent-merges-routine`](#agent-merges-routine), or
[`agent-merges-all`](#agent-merges-all).

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "The Landing Gate".

<a id="merge-budget"></a>
### Merge budget

`merge_budget_per_day`: a rolling 24-hour cap, per repository, on how many
pull requests the pipeline may land at [`agent-merges-routine`](#agent-merges-routine)
and above. Reaching the cap approves a pull request through the ordinary
review path but does not arm its landing — the backlog queues visibly
rather than merging past the cap.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 2.3c.

<a id="node"></a>
### Node

One machine running the pipeline — a laptop, a cloud VM, or a container —
any number of which may make up a fleet. `AGENT_OPS_ROLE` says whether a
given node is [active](#active) or [standby](#standby).

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "The node image";
docs/guides/operating/README.md § "Which node runs the cycles".

<a id="no-op-cycle"></a>
### No-op cycle (no-op short-circuit)

A cheap stand-down that skips launching the Co-Ordinator entirely when a
fingerprint of everything its verdict would depend on matches the
fingerprint already recorded against the last time it found nothing to do.

Authoritative: docs/guides/operating/README.md § "Skipping no-op cycles".

<a id="owner-decision"></a>
### Owner decision

An item explicitly reserved for the human owner's own judgement, marked by
the `pw::owner-decision` label on a filed issue or an `Owner decision: yes`
line in a record — never by prose alone. Marking it this way keeps the item
inside requirement 36a's owner-only boundary regardless of what
`escalation_autonomy` would otherwise let the pipeline decide.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 36a.

<a id="page"></a>
### Page

To interrupt a human directly with an [escalation](#escalation), as
distinct from a verdict the pipeline settles or decides on its own
authority. [`decide-tactical`](#decide-tactical) and the rungs of
`escalation_autonomy` above it exist to page a human less often, never to
page one for anything requirement 36a's owner-only boundary reserves.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "Actors", item 7;
requirement 36d.

<a id="pipeline-monitor"></a>
### Pipeline Monitor (Monitor)

The Monitor pipeline's single agent (token `monitor`): a scheduled reading
of the implementation and review pipelines' own recorded state, whose
mechanical findings are filed as `pw::type:tech-debt` issues that the
implementation pipeline's own `tech-debt` source then selects. It never
runs as a stage of `agent-cycle.sh`.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "Actors", item 10;
docs/MONITOR-PIPELINE-SPEC.md § "Actors".

<a id="protected-path"></a>
### Protected path

One of the whole-path prefixes (`merge_autonomy_protected_paths`) that a
routine-tier landing must not touch. A hit refuses landing outright below
[`agent-merges-all`](#agent-merges-all); at `agent-merges-all` it is instead
deferred to the Critical Approver tier and the [cool-off](#cool-off) wait.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "The Landing Gate";
config.schema.json `merge_autonomy_protected_paths`.

<a id="refined"></a>
### Refined / needs-refinement

The two verdicts the Refiner reaches for a claimed item: `refined`, once
the item carries a posted specification (a comment on the issue, or a
`refined_spec` field for a source with no thread to write into), or
`needs-refinement`, where only a human can supply what is missing. The
Refiner can neither escalate nor void an item.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirements 39c and
39d.

<a id="refiner"></a>
### Refiner

A headless Claude Code invocation, engaged from the same end-of-cycle
cleanup as the Enabler and immediately after it, that writes the
specification an under-specified item lacks *before* the item has to be
blocked and wait for the Enabler to reach it. It also bands every open
issue whose `Priority` is unset. It writes no code, raises no pull
request, and can neither escalate nor void.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "Actors", item 8.

<a id="reservation"></a>
### Reservation

The hard switch that keeps the pipeline off an issue: assigning yourself to
an issue drops it from the Co-Ordinator's candidate list until you unassign
it.

Authoritative: docs/guides/working-with-pullwright/README.md § "Reserving an issue for yourself".

<a id="reviewer"></a>
### Reviewer

A headless Claude Code invocation that checks and corrects the
Implementer's branch, then marks the pull request ready for review.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "Actors", item 5.

<a id="reviewer-agent"></a>
### Reviewer-Agent (Project Reviewer, repository reviewer)

The repository-review pipeline's single headless Claude Code invocation,
which runs the project-review skill and raises one ready review pull
request per run. Also called the Project Reviewer (token
`project-reviewer`) in the implementation pipeline's own Actors list, and
referred to informally as the repository reviewer.

Authoritative: docs/REVIEW-PIPELINE-SPEC.md § "Actors";
docs/IMPLEMENTATION-PIPELINE-SPEC.md § "Actors", item 9.

<a id="script"></a>
### Script

`agent-cycle.sh`, the bash script that orchestrates one whole cycle. It
launches every agent; agents never launch other agents.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md § "Actors", item 2.

<a id="source"></a>
### Source

Names which gatherer a [work order](#work-order)'s item came from:
`security`, `issues`, `review-feedback`, `merge-conflicts`, `dequeued`,
`landing-refusals`, `human-visibility`, `abandoned-drafts`, `failed-runs`,
`tech-debt`, `implementation-plan`, `project-review`, or `code-quality`. A
gathering token may also carry a [band](#band) (`issues:<band>`); that
suffix is gone by the time the source reaches a finished work order.

Authoritative: config.schema.json `sourceToken`.

<a id="stand-down"></a>
### Stand-down

The fleet or a node pausing new work. A usage-limit stand-down lasts until
`resume_at`, or until a cycle's own minimal probe confirms the account has
recovered, whichever comes first; a [no-op cycle](#no-op-cycle)'s
stand-down lasts until something the Co-Ordinator would read has changed.

Authoritative: docs/guides/operating/README.md § "Lifting a usage-limit stand-down"; §
"Skipping no-op cycles".

<a id="standby"></a>
### Standby

The node role value that means a machine does not spend:
`AGENT_OPS_ROLE=standby`, or any value other than the exact string
[`active`](#active).

Authoritative: docs/guides/operating/README.md § "Which node runs the cycles".

<a id="state-repository"></a>
### State repository

`state_repo`: the private repository through which `state_dir` replicates
between nodes. Its default branch carries the small shared surface — the
claim registry and the fleet flags (`fleet/disabled.json`,
`fleet/limit.json`). Empty or absent means single-node operation, where
every mode of `scripts/state-sync.sh` becomes a no-op.

Authoritative: config.schema.json `state_repo`; docs/IMPLEMENTATION-PIPELINE-SPEC.md,
requirement 2.5.

<a id="void"></a>
### Void

A status meaning there is no work: the item is already done, or its
premise was false. No agent can ever clear a void item itself — the only
evidence that would prove it ("it's already done") is the reason it is
void, so an agent allowed to clear it would free the item to be
rediscovered every cycle. Distinct from [blocked](#blocked), where real
work exists but is impeded.

Authoritative: docs/guides/operating/README.md § "Blocked and void items".

<a id="work-order"></a>
### Work order

The JSON object the Co-Ordinator emits for the one item it selected:
`source`, `item`, `branch`, `context`, `acceptance`, and the other fields
the Script and Implementer need. The Script derives and injects the claim
branch itself; a work order's `pr_label` is guaranteed correct regardless
of whether the model copied it correctly.

Authoritative: docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 20 (§ "The
Co-Ordinator (selection only)").

## Older names

A reader may still meet one of these retired names in live output — a
label an installation has not migrated, or a config key kept as an alias —
even though the current name is what this glossary and the rest of the
documentation use.

| Older name | Current name | Where |
|---|---|---|
| `enabler-escalation` | `pw::enabler-escalation` | `enabler_escalation_label` default (agent-ops#1863) |
| `needs-refinement` | `pw::needs-refinement` | `needs_refinement_label` default (agent-ops#1863) |
| `refined` | `pw::refined` | `refined_label` default (agent-ops#1863) |
| `unvoided` | `pw::unvoided` | `unvoid_label` default (agent-ops#1863) |
| `autonomous-agent` | `pw::agent` (recommended) | `pr_label` has no schema default; an installation may still carry the older value |
| `escalation_webhook_url` | `notify_webhook_url` | accepted as an alias for one release; `doctor.sh` warns on the old name |

Issue agent-ops#1863 records that PR #1860 moved the first four keys' schema
defaults to their `pw::`-prefixed form without a rename migration, so an
installation configured before that change — this one included — still
carries the older, unprefixed label names live.
