# Labels reference

Every label the pipeline creates or reads, across the three roles a
repository can hold (`target`: a repository the implementation pipeline
works; `review`: a repository the project-review pipeline reviews;
`escalation`: where escalation issues are filed). Generated from
`lib/labels.sh`'s own catalogue by `scripts/render-labels-table.sh`; edit
that file's catalogue and metadata, not the table below.

A configurable label's name here is the product's own documented example
(`config.schema.json`'s `x-docs.value`) where the key has no product
default, or its schema `default` otherwise — the same convention
[docs/reference/configuration.md](configuration.md) uses. An installation
that renames one still gets the behaviour this table describes, under
whatever name it chose; `lib/labels.sh`'s own header explains which five
names stay fixed regardless of configuration and why.

<!-- labels-table:start -->
| Label | Applied by | Meaning | Removing it does |
|-------|------------|---------|-------------------|
| `blocked` | Hand-applied, or Script-projected under requirement 38b. | Keeps the pipeline from selecting this issue; hand-applied or Script-projected (38b) | The issue becomes selectable by scripts/gather-issues.sh again, unless another hold still applies. |
| `blocked:needs-refinement` | Script-projected alongside `blocked`, naming why. | Projected alongside `blocked`: too under-specified to work on, say what done looks like (38b) | Nothing reads this label on its own; remove `blocked` itself to make the issue selectable again. |
| `complexity:high` | The Implementer, grading the work order it just finished. | Graded by the Implementer; picks the higher Reviewer tier | The Script falls back to its own default Reviewer-tier choice, since no grade is recorded. |
| `complexity:low` | The Implementer, grading the work order it just finished. | Graded by the Implementer; picks the Reviewer tier | The Script falls back to its own default Reviewer-tier choice, since no grade is recorded. |
| `complexity:medium` | The Implementer, grading the work order it just finished. | Graded by the Implementer; picks the Reviewer tier | The Script falls back to its own default Reviewer-tier choice, since no grade is recorded. |
| `obsolete` | A human only; no pipeline stage ever applies it. | Hand-applied to say a still-open, diff-carrying draft PR is unwanted; no pipeline stage applies this | lib/void-guard.sh's corroboration for voiding that draft pull request goes with it; nothing re-applies it automatically. |
| `open-question` | The Reviewer, projected onto a pull request. | Reviewer-projected: an open scope question blocks unattended landing until adjudicated (D18 #668) | The landing gate stops treating the pull request as blocked by an open question. |
| `project-review` | The project-review pipeline, onto every review pull request it raises. | Raised by the project-review pipeline | That pull request stops being distinguished from an implementation one, and starts counting against `max_open_agent_prs`. |
| `pw::agent` | The claim loop (requirement 17a), onto every pull request the implementation pipeline raises. | Raised by the autonomous implementation pipeline | Every gatherer, and the `max_open_agent_prs` back-pressure limit, stop counting that pull request as the pipeline's own. |
| `pw::decision` | The Enabler, when it takes a tactical decision under decide-tactical. | A tactical decision the pipeline took under decide-tactical; reopen to veto | scripts/sweep-decision-vetoes.sh stops finding the issue as a decision log to check for a veto. |
| `pw::enabler-escalation` | The Enabler, onto every issue it files escalating a blocked item; also usable as `crash_loop_repo`/`pager_repo`'s own escalation label. | Raised by the Enabler: a blocked item that escalates | The Enabler's own duplicate guard stops finding the issue as an existing escalation, and may file a second one for the same block. |
| `pw::needs-refinement` | The Script, projected while an issue's refinement block is open; a human may also apply it by hand to flag an item themselves. | Too under-specified to work on; say what done looks like | The issue becomes selectable again once any other hold (e.g. `blocked`) also lifts. |
| `pw::owner-decision` | The Approver or Enabler, via lib/tech-debt-file.sh's `techdebt_file_issue`. | Filed with an owner-only choice still open; the Refiner escalates rather than guessing | The Refiner stops treating the issue as owner-only, and may specify it to a stated default instead of declining with needs-refinement. |
| `pw::pager` | lib/pager.sh, when a fleet-level invariant fires. | Raised by lib/pager.sh: a fleet-level invariant is firing | lib/pager.sh's own dedup search and monitor-cycle.sh's `--label pw::pager` listing stop finding the issue, and the pager's own auto-close has no label left to clear. |
| `pw::refined` | The Script, once the Refiner has written the issue a specification. | The Refiner has written this a specification | Nothing re-applies it until the Refiner runs on that issue again; the specification already written stays in the issue regardless. |
| `pw::type:tech-debt` | Whichever stage files the tech-debt issue (`gh issue create`, per AGENTS.md's "Tech debt" workflow). | Tech debt: a known gap or shortcut with a knowable fix. Managed by Pullwright. | The issue stops being found by scripts/gather-tech-debt.sh and by the `/td` skill's dedup search, and D24's trust anchor for treating its body as tech debt rather than untrusted content is withdrawn. |
| `pw::unvoided` | A human, by hand on GitHub — no pipeline stage ever applies this one. | Apply to ask the pipeline to reconsider an item it voided | The request to reconsider the void is withdrawn; removing it only ever undoes a human's own ask. |
<!-- labels-table:end -->
