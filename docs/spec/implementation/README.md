# Autonomous Implementation Pipeline — as-built specification

Split from a single file by #2094 so every part is within the 100,000-byte documentation size budget (`docs/README.md` "Size budget").

<!-- toc:start -->
  - [Acceptance checks](acceptance-checks/acceptance-checks-01.md)
  - [Acceptance checks — continued (part 2 of 6; items 2m–7f)](acceptance-checks/acceptance-checks-02.md)
  - [Acceptance checks — continued (part 3 of 6; items 7g–11e)](acceptance-checks/acceptance-checks-03.md)
  - [Acceptance checks — continued (part 4 of 6; items 39a–8s)](acceptance-checks/acceptance-checks-04.md)
  - [Acceptance checks — continued (part 5 of 6; items 8t–50)](acceptance-checks/acceptance-checks-05.md)
  - [Acceptance checks — continued (part 6 of 6; items 51–52b)](acceptance-checks/acceptance-checks-06.md)
  - [Components](components/components-01.md)
  - [Components — continued (part 2 of 3; 12b–17d)](components/components-02.md)
  - [Components — continued (part 3 of 3; 17e–24b)](components/components-03.md)
- [Configuration](configuration.md)
- [Cost profile](cost-profile.md)
- [Design decisions](design-decisions.md)
- [Environment (verified 2026-07-20)](environment.md)
- [Gotchas](gotchas.md)
- [The Landing Gate](landing-gate.md)
  - [The Approver](requirements/approver-01.md)
  - [The Approver — requirements, continued (part 2 of 2; 51–55: Fleet-level invariants (the pager)…)](requirements/approver-02.md)
  - [The Co-Ordinator (selection only)](requirements/co-ordinator-01.md)
  - [The Co-Ordinator — requirements, continued (part 2 of 2; 18a–20: Fresh evidence on a blocked issue makes requirement 18's r…)](requirements/co-ordinator-02.md)
  - [The Enabler](requirements/enabler-01.md)
  - [The Enabler — requirements, continued (part 2 of 2; 36f–38g: The delegate mandate (D18, PR #1389, recommendation 3 of…)](requirements/enabler-02.md)
  - [Every stage (untrusted external content)](requirements/every-stage.md)
  - [The Implementer](requirements/implementer.md)
  - [Logging and state](requirements/logging-and-state-01.md)
  - [Logging and state — requirements, continued (part 2 of 2; 34i–34n: A block whose work is gone is cleared without asking anyone…)](requirements/logging-and-state-02.md)
  - [The Refiner](requirements/refiner.md)
  - [The Reviewer](requirements/reviewer.md)
  - [The Script (`agent-cycle.sh`)](requirements/the-script-01.md)
  - [The Script — requirements, continued (part 2 of 10; 2–2.3: Stand-down checks…)](requirements/the-script-02.md)
  - [The Script — requirements, continued (part 3 of 10; 2.3a–2.4: The fleet switch…)](requirements/the-script-03.md)
  - [The Script — requirements, continued (part 4 of 10; 2.5–2.5: The fleet's shared memory…)](requirements/the-script-04.md)
  - [The Script — requirements, continued (part 5 of 10; 2.5a–3a: Compose reconciliation…)](requirements/the-script-05.md)
  - [The Script — requirements, continued (part 6 of 10; 3c–3v: Review-feedback pre-fetch (requirement 3c)…)](requirements/the-script-06.md)
  - [The Script — requirements, continued (part 7 of 10; 3w–4h: Verdict quality is a rate, and every verdict pays for its …)](requirements/the-script-07.md)
  - [The Script — requirements, continued (part 8 of 10; 4i–8d: The assembled Co-Ordinator prompt is bounded by its model'…)](requirements/the-script-08.md)
  - [The Script — requirements, continued (part 9 of 10; 8e–59: The classifier-escape audit re-checks the outcome, not jus…)](requirements/the-script-09.md)
  - [The Script — requirements, continued (part 10 of 10; 60–60: The CLI surface: `scripts/node-health.sh`…)](requirements/the-script-10.md)
<!-- toc:end -->

## About this document

This is the as-built requirements specification for the implementation
pipeline: the numbered requirements the system satisfies, the components that
satisfy them, the acceptance checks that prove it, and the reasoning behind
them. It describes the system as it exists, and it must keep doing so — any
change to the pipeline lands together with the edit that keeps this document
accurate (see `AGENTS.md`, "As-built specifications"). Where this document is
silent, follow the conventions of the two target repositories (their
`AGENTS.md` files — or `CLAUDE.md`, for a repository that has not migrated —
are binding on any agent working inside them).

Requirement ids may recur across `###` sections — e.g., "requirement 39c
(The Refiner)" and "requirement 39c (Finish-then-continue)" name two
different requirements — and, for the two legacy ids 17b and 17g, even
within the single section that defines both of each pair ("The Co-Ordinator
(selection only)"). A citation of an id defined in more than one place is
qualified with its owning section unless the surrounding clause already
names the owner (e.g., "the Refiner's (requirement 39)"); a citation of an
id defined in exactly one place may be left bare.


## What it is

A pipeline that, on a configured cadence
(`schedule.cycle_interval_minutes`), picks **at most one** well-scoped item
of pending work from the configured GitHub repositories, implements it on a
feature branch in an ephemeral clone, reviews and corrects the result, and
leaves a mergeable pull request for approval and landing at the repository's
configured `merge_autonomy` level (see "## The Landing Gate"). It runs
unattended on a containerized node; human involvement narrows to
whatever that level still requires.

```
cron (schedule.cycle_interval_minutes)
  └─ agent-cycle.sh                 ← the Script: lock, stand-down checks, repo ordering
       ├─ Co-Ordinator (Haiku)      ← selects ≤ 1 item, emits a work order; nothing else
       ├─ Implementer (Sonnet/Haiku)← ephemeral clone, feature branch, draft PR
       ├─ Reviewer (Sonnet/Opus)    ← corrects the branch, flips the PR to ready
       │     └─ Human Reviewer      ← approves/merges per `merge_autonomy` (D18)
       ├─ Enabler (Opus, rarely)    ← re-examines long-blocked items at the end of a
       │                              cycle: unblocks, voids, or raises an issue
       │                              assigned to the Human saying what to do
       └─ Refiner (Haiku)           ← same end of the cycle: writes the specification
                                      an unscoped item lacks, before it has to be
                                      blocked and wait for the Enabler
```

## Actors

1. The **Cronjob** — the crontab entry that fires the Script.
2. The **Script** (`agent-cycle.sh`) — a bash script that orchestrates one
   whole cycle. It launches every agent; agents never launch other agents.
3. The **Co-Ordinator** — a headless Claude Code invocation that selects one
   item of work and emits a work order. It does not implement anything.
4. The **Implementer** — a headless Claude Code invocation that carries out
   the work order and raises a draft pull request.
5. The **Reviewer** — a headless Claude Code invocation that checks and
   corrects the Implementer's branch, then marks the pull request ready.
5a. The **Approver** — a headless Claude Code invocation, engaged only where
   `merge_autonomy` is above `human` (D18, "## The Landing Gate"), that
   independently judges a pull request the Reviewer has already marked ready
   and returns a verdict. It writes no code and pushes nothing; the Script
   turns its verdict into a real GitHub review — `APPROVE` or
   `REQUEST_CHANGES` — posted under a non-author GitHub App identity
   ("Pullwright Approver"), never under this system's own authoring account.
6. The **Human Reviewer** — gives final approval (at `human`) or an
   additional one alongside the Approver's own (above `human`), through the
   ordinary GitHub process. Merges the pull request directly at `human` and
   `agent-approves`; at `agent-merges-routine` and `agent-merges-all`, the
   arming step lands an eligible pull request itself (D18, "## The Landing
   Gate"), and the Human Reviewer's own role narrows to whatever that
   classifier did not cover. Not launched by any part of this system.
7. The **Enabler** — a headless Claude Code invocation, engaged rarely and at
   the end of a cycle, that re-examines items recorded as blocked which the
   pipeline has not cleared by itself. It unblocks, voids, or leaves them
   blocked with a fresher condition; where an item was never specified well
   enough to select, it specifies it (requirement 36b); and where an item
   cannot be moved without escalating, it composes a GitHub issue that the
   Script files, assigned to a human — directly, or after one bounded pass
   per `escalation_autonomy`: an adjudication, for a refinement-disagreement
   item only (requirement 36b), or, at `decide-tactical`, a decide pass over
   any escalation, which may settle it or decide a tactical question on the
   pipeline's own authority instead of paging a human at all (requirement
   36d). It writes no code and raises no pull request.
8. The **Refiner** — a headless Claude Code invocation, engaged from the same
   end-of-cycle cleanup as the Enabler and immediately after it, that writes
   the specification an under-specified item lacks *before* the item has to be
   blocked and wait for the Enabler to reach it (requirement 39 (The
   Refiner)). Every item it takes ends `refined` — the specification posted
   as a comment on the item's own issue, or returned as `refined_spec` where
   the source has no thread to write into — or `needs-refinement`, where
   only a human can supply what is missing (requirements 39c (The Refiner)
   and 39d). It also bands every open issue
   whose `Priority` is unset, a one-way ratchet the Script alone enforces
   (requirement 39g). Its powers are otherwise deliberately narrower than the
   Enabler's: it writes no code, raises no pull request, and can neither
   escalate nor void.

Two further Actors belong to the sibling pipelines rather than to this one,
and are named here because `lib/pipeline-marker.sh`'s `pipeline_actor_label`
and `dashboard/index.html`'s `ACTOR` map carry every Actor token this system
has, whichever pipeline runs it (requirement 9d):

9. The **Project Reviewer** (token `project-reviewer`) — the
   repository-review pipeline's single agent. Specified at
   `docs/spec/review.md`, *Actors*, where that document calls it the
   Reviewer-Agent.
10. The **Pipeline Monitor** (token `monitor`) — the Monitor pipeline's
   single agent: a scheduled reading of this pipeline's own recorded state,
   whose mechanical findings are filed as `pw::type:tech-debt` issues that
   this pipeline's own `tech-debt` work source then selects (requirement 16).
   Specified at `docs/spec/monitor.md`, *Actors*. It never runs as a
   stage of `agent-cycle.sh` and writes no label this pipeline's Co-Ordinator
   keys on.

