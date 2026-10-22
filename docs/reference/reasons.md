# Reason codes — catalogue and quick reference

This page documents every reason code the four closed vocabularies below
enumerate — stand-down causes, item fates, pager kinds and landing refusal
classes — with an explanation of what each means, whether it represents a
fault, and what to do about it. `lib/reason-codes.sh` extracts each family
mechanically from the code itself, and `test/reason-codes.test.sh` fails if
a code is added to any of the four without a matching entry here — so this
page's coverage is checked, not merely asserted.

Use this page to understand a reason code when you see it in:
- Log lines and event streams
- Issue comments and pull request bodies
- The dashboard's panels

See "Not yet catalogued" below for the families this page does not cover
yet, and why. For full operational guidance on symptoms and remedies, see
the [Operator guide](../guides/operating/).

## Stand-down causes

When the pipeline pauses and does not evaluate candidates, the reason carries a **cause** — a short code explaining why. These appear in `stand-down` events in the union log and on the dashboard's Fleet panel.

### `disabled-node`

The node running this installation is explicitly paused. Human action required.

- **Is a fault?** No. The node is paused by design.
- **What to do:** The operator or another actor set this node to disabled status. Check the configuration and re-enable when ready.

### `disabled-fleet`

The entire fleet is paused. Human action required.

- **Is a fault?** No. The fleet is paused by design.
- **What to do:** Check the configuration for `disabled` set fleet-wide. Re-enable when ready.

### `usage-limit`

This node hit a usage limit (most often token spend or request rate) and is now in cooldown. This is expected behavior when the pipeline hits its budget.

- **Is a fault?** No. Cooldown is automatic and temporary.
- **What to do:** Wait for the cooldown to expire, or run `agent-cycle.sh --clear-limit` to clear it immediately if you want to resume sooner.

### `github-budget`

This node exhausted its GitHub API budget for the window. Cooldown applies automatically.

- **Is a fault?** No. Budget management is automatic.
- **What to do:** Wait for the window to roll over, or adjust budget settings in config.

### `unreachable`

GitHub could not be reached. This is an outage or a network connectivity issue.

- **Is a fault?** Yes. Check GitHub status and network connectivity.
- **What to do:** Wait for GitHub to recover, or check network and proxy settings on this node.

### `unauthorized`

GitHub access was denied (likely a token scope or authentication issue).

- **Is a fault?** Yes. Check credentials and token scopes.
- **What to do:** Verify the GitHub token is valid and has the required scopes.

### `credential-refused`

A credential provider (e.g., credential-helper for a nested token) refused to serve.

- **Is a fault?** Yes. Check credential configuration.
- **What to do:** Verify credential storage and permissions on this node.

### `disk-low`

The disk is running low on free space (below the configured threshold).

- **Is a fault?** Maybe. Check disk usage and clean up if needed.
- **What to do:** Free up disk space or adjust the low-disk threshold in configuration.

### `disk-full`

The disk has no free space left.

- **Is a fault?** Yes. The pipeline cannot run.
- **What to do:** Free up disk space immediately.

### `memory-low`

The host's available memory is low.

- **Is a fault?** Maybe. Check system memory usage.
- **What to do:** Free up memory or increase available memory on the host.

### `host-overcommit`

The host is overcommitted (CPU, memory, or I/O contention detected).

- **Is a fault?** Maybe. Check host resource availability.
- **What to do:** Reduce load on the host or increase host resources.

### `roll-pending`

A deployment or image roll is pending on this node.

- **Is a fault?** No. The node is pausing to be updated.
- **What to do:** Wait for the deployment to complete, or force it if needed.

### `back-pressure`

The pipeline is applying backpressure: work is piling up faster than it is being claimed and completed.

- **Is a fault?** No. This is a normal throttling mechanism.
- **What to do:** Wait for the backlog to clear, or adjust pipeline settings to process more items per cycle.

### `awaiting-tick`

The node is idle and waiting for the next scheduled tick (cron cycle).

- **Is a fault?** No. Normal idle state between scheduled cycles.
- **What to do:** None. The pipeline is resting between scheduled evaluations.

### `peer-claimed`

Another node (or an earlier cycle on this node) claimed all available work before this cycle got to it.

- **Is a fault?** No. This is normal contention.
- **What to do:** None. The next cycle will evaluate candidates again.

### `pre-claimed`

All eligible candidates were already claimed by another cycle before this one's Co-Ordinator ran.

- **Is a fault?** No. This is normal contention between cycles.
- **What to do:** None. The next cycle will evaluate candidates again.

### `raced`

This cycle and another cycle both tried to claim work; the other cycle won the race.

- **Is a fault?** No. This is normal race-based contention.
- **What to do:** None. Cycles retry automatically.

### `coordinator-declined`

The Co-Ordinator evaluated candidates but declined to claim any (all failed refinement checks, for example).

- **Is a fault?** Maybe. Check candidate eligibility and refinement settings.
- **What to do:** Investigate why candidates are not eligible; see the logs for details.

### `untraceable`

Every candidate failed the refinement traceability or compose check; no claim was attempted.

- **Is a fault?** Yes. Check refinement configuration and work-order composition.
- **What to do:** Review the Refiner stage output and check for configuration drift.

### `no-demand`

No eligible work exists. The pipeline has nothing to do.

- **Is a fault?** No. Normal idle state when there are no open issues or PRs to work on.
- **What to do:** None. Work will resume when new eligible items appear.

## Item fates

`lib/item-lifecycle.sh`'s terminal-fate fold (docs/reference/flow-schema.md's
"Terminal fates") assigns every item exactly one of these seven values, by
one strict priority order — each rule below is checked only once every rule
ahead of it has failed to match.

### `landed`

A `merge-observed` or `issue-closed-post-merge` event exists for this item — the strongest possible evidence, which outranks every other fate.

- **Is a fault?** No. This is the item's normal, successful end state.
- **What to do:** None.

### `voided`

The latest `item-void` event for this item has no later `unvoided` — a human or the Enabler recorded that no work exists here.

- **Is a fault?** No, usually. A stale item correctly retired.
- **What to do:** None, unless the void looks wrong — reopen with `unvoided` if so.

### `superseded`

An `orphan-branch-released {reason: "superseded"}` event resolves to this item: another pull request completed the same work.

- **Is a fault?** No. The item is redundant.
- **What to do:** None; the branch has already been released.

### `blocked`

The latest `attempt-failed` event for this item has no later `unblocked` — a standing block, which outranks the uncorroborated intent `abandoned` records.

- **Is a fault?** Maybe. A block can be transient (waiting on a dependency) or a sign the item needs human judgement.
- **What to do:** Read the `attempt-failed` event's own reason; follow its `unblock_condition` if one was given.

### `abandoned`

A `draft-obsolete-flagged` event exists: the pipeline's own recorded intent to abandon a draft pull request, pending a human's `obsolete` label corroborating it.

- **Is a fault?** No. Flagging is working as designed.
- **What to do:** Confirm with the `obsolete` label if the draft really is dead, or push to it again if it is not.

### `open`

None of the fates above match: the item has entered (some event names it) but nothing yet says it has left.

- **Is a fault?** No. This is the ordinary in-progress state.
- **What to do:** None.

### `unaccounted`

The item is also `voided`, but that void's own timestamp is *later* than the earliest landing evidence — a void recorded for an item that had, on the log's own evidence, already merged. The fold does not guess which side is right; it surfaces the contradiction instead of silently picking one.

- **Is a fault?** Yes. The void and the merge evidence disagree about this item.
- **What to do:** Read both events named in the `unaccounted[]` record and work out which one is wrong.

## Pager kinds

`lib/pager-invariants.sh` registers each fleet-level invariant under a
`key` via `pager_register` — the kind named in a fired page's title and its
`ref:` line (`lib/pager.sh`'s `pager_file`).

### `verdict-unanimous`

Every live node's doctor verdict names the same failing check.

- **Is a fault?** Yes. Investigate the named check across nodes.
- **What to do:** Handled automatically by `pager_remedy_verdict_unanimous`; the page names the suspect check to go and read.

### `page-outlived-item`

An open `pw::pager`/escalation page's own item (the PR or issue its body links) has already gone terminal — merged or closed.

- **Is a fault?** No, by itself. The page is just stale.
- **What to do:** Handled automatically by `pager_remedy_page_outlived_item`, which closes the stale page.

### `firing-missed`

A node the fleet expects to be cycling appears to have had a firing dropped outright, rather than merely running a long cycle.

- **Is a fault?** Yes. A scheduled tick never happened.
- **What to do:** Check that node's own cron/supercronic logs and crontab, or (on Kubernetes) for a `concurrencyPolicy: Forbid` skip.

### `node-stale`

A node has not confirmed a publication into the shared state for over twice `node_stale_after_minutes`.

- **Is a fault?** Yes, unless the node has been decommissioned.
- **What to do:** Confirm the node (container/host) is still running and check its state-sync push logs. If the node has left the fleet for good, delete its `nodes/<node>` branch on the state repository — fleet membership is any `nodes/*` branch, so the page cannot clear until that branch is gone.

### `updater-stuck`

A container this node's own updater told to roll has been stuck for over twice `updater_stuck_after_minutes`.

- **Is a fault?** Yes. A deploy did not complete.
- **What to do:** Check watchtower / the deploy pipeline on that node directly, or (on Kubernetes) for an `ImagePullBackOff` or a rollout stuck past `progressDeadlineSeconds`.

### `review-pipeline-failing`

The repository-review pipeline (`review-cycle.sh`) has failed its last several attempts on this node with no successful `review-end` between them.

- **Is a fault?** Yes.
- **What to do:** Start with that node's own project-reviewer verdict (the dashboard's Review stage health panel), then check `review-log.jsonl` and the Reviewer stage's own logs on that node directly.

### `dashboard-unreadable`

A viewer fetching this node's `data.js` found it slower than `pager_dashboard_fetch_seconds` or unparseable — a fact the node cannot observe about itself.

- **Is a fault?** Yes.
- **What to do:** Check network/tailnet conditions to that node and the size of its `data.js` directly.

### `idle-with-demand`

A node's own selection/stand-down history shows real demand going unclaimed for several cycles running.

- **Is a fault?** Maybe. Check cron scheduling and node availability.
- **What to do:** The page's own evidence carries the node's most recent `none-selected` reason and `coordinator-input-fitted` detail; check the Co-Ordinator's own verdicts and eligibility gates on that node directly.

### `coordinator-fit-ladder-pinned`

The coordinator input ladder (`lib/coordinator-input.sh`) has bottomed out at its own tightest rung and is still shedding backlog entries on every fitted cycle for a full day.

- **Is a fault?** Yes. The eligible backlog has outgrown `coordinator_prompt_max_bytes`.
- **What to do:** Raise the byte budget, or reduce the backlog (close stale issues, tighten a repo's own sources).

### `work-order-repaired-rate`

More than `pager_repair_rate_percent` of a day's selections needed a work-order-repaired repair — a work order composed from trimmed input.

- **Is a fault?** Yes. Work orders are arriving malformed or incomplete.
- **What to do:** Check the fit report and the trimmed candidates' own sizes directly.

### `blocked-label-orphaned`

A `blocked:<reason>`/`blocked` label is still live on an issue with no open block behind it.

- **Is a fault?** Yes. The label has outlived the thing it described.
- **What to do:** Handled automatically by `pager_remedy_blocked_label_orphaned`.

### `claim-unreconciled`

A branch claim was never reconciled — neither examined by the Enabler, escalated, nor filed as tech debt — within the window this invariant checks.

- **Is a fault?** Yes.
- **What to do:** Handled automatically by `pager_remedy_claim_unreconciled`.

### `gather-claimed-degraded`

A gather step reported `guard-degraded` — it could not fully corroborate its own input — within the window this invariant checks.

- **Is a fault?** Yes. A gather's own correctness guard tripped.
- **What to do:** Handled automatically by `pager_remedy_gather_claimed_degraded`.

### `escalation-burst`

More than `pager_escalation_burst` escalations were filed fleet-wide in the trailing 24h, or the same re-flag reason paged the same item twice.

- **Is a fault?** Yes. A mechanical burst from a handful of unfixed bugs.
- **What to do:** The page's own evidence carries the reason histogram; start from whichever reason recurs most.

### `digest-truncated`

A `source-state-digest` event reported fewer items than a live query of the same window actually finds.

- **Is a fault?** Yes. A digest is under-reporting its own source state.
- **What to do:** Handled automatically by `pager_remedy_digest_truncated`.

### `landing-never-armed`

A pull request has stood approved for longer than `landing_armed_within_days` without ever reaching `landing-armed`.

- **Is a fault?** Yes, usually. Something keeps refusing to arm it.
- **What to do:** Handled automatically by `pager_remedy_landing_never_armed`, which reads the pull request's own `landing-refused` history.

### `landing-refused-unknown`

At least half (and at least five) of a trailing-24h window's `landing-refused` events, fleet-wide, carry class `unknown` or a read failure rather than a deterministic refusal.

- **Is a fault?** Yes. Landing's own gate reads are failing rather than judging.
- **What to do:** Handled automatically by `pager_remedy_landing_refused_unknown`.

### `pr-unreviewed`

A pull request older than `approver_unreviewed_engage_after_hours` carries no standing review, no `approver-verdict`, no Approver warning, and no `approver-unreviewed-engaged` event — the unreviewed-engagement sweep never ran for it even once.

- **Is a fault?** Yes. A pull request fell outside the sweep meant to catch exactly this.
- **What to do:** Handled automatically by `pager_remedy_pr_unreviewed`.

## Landing refusal classes

`_LANDING_REFUSAL_CLASSES` (`lib/landing.sh`) is the closed set of values
`_landing_refuse` may be called with, logged as a `landing-refused` event's
own `class` field and, for a persistent class, posted on the pull request
itself (`_landing_notice_body`).

### `malformed-pr-url`

The pull request's own URL could not be parsed for its number.

- **Is a fault?** Yes. An internal bookkeeping error.
- **What to do:** Check how this pull request's URL was recorded.

### `kill-switch`

Landing's own kill switch is set, below this installation's configured autonomy level.

- **Is a fault?** No. This is an explicit operator choice.
- **What to do:** Clear the kill switch when ready to resume landing.

### `autonomy-level`

This installation's configured `merge_autonomy` does not permit the Script to arm this pull request itself.

- **Is a fault?** No. This is an explicit configuration choice.
- **What to do:** A human arms the pull request, or raise `merge_autonomy` if the pipeline should do it from now on.

### `ineligible`

A deterministic eligibility read came back negative (e.g. a protected-path control, below).

- **Is a fault?** Depends. The `reason` text names which specific control failed.
- **What to do:** Read the `reason` text for the specific control that refused.

### `unknown`

An eligibility or protected-path read could not be classified into any of this file's other deterministic classes — most often because the live GitHub read itself failed.

- **Is a fault?** Yes. A read failed closed rather than judging normally.
- **What to do:** Check GitHub connectivity and the pull request's own state directly.

### `open-question-unreadable`

The pull request's own labels could not be read to confirm no open question stands.

- **Is a fault?** Yes. A GitHub read failed.
- **What to do:** Check GitHub connectivity, then re-check.

### `review-gate`

The pull request has not yet received the review this installation requires before arming.

- **Is a fault?** No. Normal process.
- **What to do:** Wait for the required review.

### `approver-login-unreadable`

The Approver App's own login could not be read.

- **Is a fault?** Yes. A GitHub App read failed.
- **What to do:** Check the Approver App's installation and token.

### `approver-review-unreadable`

The pull request's own review list could not be read to confirm the Approver's review actually landed.

- **Is a fault?** Yes. A GitHub read failed.
- **What to do:** Check GitHub connectivity, then re-check.

### `approver-review-not-approved`

The Approver's own review is not standing `APPROVED` on GitHub.

- **Is a fault?** Depends. The review may have been dismissed or superseded.
- **What to do:** Check the pull request's review history for why the Approver's approval is not standing.

### `human-veto-unreadable`

The pull request's own review list could not be read to confirm no human `CHANGES_REQUESTED` stands.

- **Is a fault?** Yes. A GitHub read failed.
- **What to do:** Check GitHub connectivity, then re-check.

### `human-changes-requested`

A human review stands `CHANGES_REQUESTED` on this pull request.

- **Is a fault?** No. A human has asked for changes; see `review-feedback` in the Implementer's own operating prompt.
- **What to do:** Answer the review and push a fix; see the pull request's own review comments.

### `reconciliation-unanswered`

A plain human comment posted since this pull request last left draft carries no `<!-- agent-ops:reconciles comment=<id> -->` citation answering it.

- **Is a fault?** No, until it has stood a while. Normally cleared by the next `landing-refusals` work order.
- **What to do:** Answer the named comment and post the `reconciles` citation.

### `reconciliation-unreadable`

The pull request's own comments could not be read to check for an unanswered one.

- **Is a fault?** Yes. A GitHub read failed.
- **What to do:** Check GitHub connectivity, then re-check.

### `protected-path-cooloff`

The pull request touches a protected path and its own cool-off window (`landing_cool_off_hours` since approval) has not yet elapsed.

- **Is a fault?** No. This is a deliberate wait.
- **What to do:** Wait for the cool-off to elapse; the notice names when it will.

### `protected-path-tier`

The pull request touches a protected path but either did not run at the critical review tier, or no approval timestamp could be established.

- **Is a fault?** Yes. The protected-path review requirement was not met.
- **What to do:** Re-review at the critical tier.

### `protected-path-stale-head`

A push to this protected-path pull request after approval restarted its own cool-off.

- **Is a fault?** No. This is the cool-off working as designed — a late push is itself unreviewed.
- **What to do:** Wait for the restarted cool-off to elapse, or get the new head reviewed.

### `merge-queue-unreadable`

The pull request's own merge-queue status could not be read.

- **Is a fault?** Yes. A GitHub read failed.
- **What to do:** Check GitHub connectivity, then re-check.

### `merge-queue-occupied`

The pull request is already in the merge queue.

- **Is a fault?** No. It is mid-transaction.
- **What to do:** Wait for it to leave the queue (merge, or be dequeued).

### `dequeued-actionable`

The pull request was dequeued by a merge-group failure this pipeline can diagnose and fix (see `merge-conflicts`/`dequeued` in the Implementer's own operating prompt).

- **Is a fault?** Yes, usually — something in the merge group's own speculative merge failed.
- **What to do:** An Implementer engagement diagnoses the failed `merge_group` run and fixes the cause.

### `dequeued-manual`

The pull request was dequeued and needs a human's own re-queue click; nothing further can be automated.

- **Is a fault?** No, necessarily. Re-queueing is always a human's "Merge when ready" click.
- **What to do:** Re-click "Merge when ready" once satisfied the dequeue reason is resolved.

### `approver-token-unmintable`

The Approver's own installation token could not be minted.

- **Is a fault?** Yes. A GitHub App credential failed.
- **What to do:** Check the Approver App's installation and credentials.

### `arm-failed`

`landing_arm` could not enqueue or auto-merge the pull request — either it failed outright, or it exited 0 while printing no method.

- **Is a fault?** Yes. Arming itself failed.
- **What to do:** Check `landing_arm`'s own log output for this pull request directly.

### `open-question`

The pull request carries an unresolved open question — one an adjudication pass could not settle, or one that has not yet gone through adjudication — tracked by its own escalation issue.

- **Is a fault?** No. A human decision is pending.
- **What to do:** See the linked escalation issue.

## Not yet catalogued

Three of the families #2098 named have no closed code vocabulary in the
codebase today, so there is nothing here for a test to derive mechanically
and nothing to link to without inventing one:

- **`scripts/doctor.sh`'s check names.** `doctor.sh` emits free-text messages
  through `ok()`/`warn()`/`fail()` under `section()` headings; it has no
  named per-check code at all.
- **The kinds of escalation.** Nothing in `lib/` or `scripts/` enumerates a
  closed set of escalation kinds as string constants.
- **The Monitor's own finding classes.** `docs/spec/monitor.md`'s M14
  describes three classes (mechanical/tactical/strategic) in prose, but no
  `lib/*.sh` file encodes them as a vocabulary a test could extract.

Giving any of these a named code vocabulary is a design decision — touching
a large, already-dense file (`doctor.sh` is over 3000 lines) to introduce a
convention it does not have — not a docs-and-wiring change, so it is out of
scope here. See the tech-debt issue this pull request files for the proposal.
