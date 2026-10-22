# Reason codes — catalogue and quick reference

This page documents every reason code the pipeline can emit — stand-down causes, void and block reasons, pager signatures, escalation kinds, and others — with an explanation of what each means, whether it represents a fault, and what to do about it.

Use this page to understand a reason code when you see it in:
- Log lines and event streams
- Issue comments and pull request bodies
- Dashboard alerts and notifications
- Doctor check failures

For full operational guidance on symptoms and remedies, see the [Operator guide](../guides/operating/).

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

## Item fates (void and block reasons)

When an item is marked void or blocked, the reason explains why. These appear in `item-void` and `attempt-failed` events.

### `already-done`

The work this item describes is already complete on the main branch.

- **Is a fault?** No. The item is stale.
- **What to do:** Close the item if it is an issue, or close the PR if it still exists.

### `superseded`

Another PR or change completed the same work.

- **Is a fault?** No. The item is redundant.
- **What to do:** Close or rebase the PR if it still exists.

### `closed-issue`

The issue this item references has been closed.

- **Is a fault?** No. The issue is no longer current.
- **What to do:** None; the item is automatically voided.

### `not-eligible`

The item does not meet eligibility criteria.

- **Is a fault?** Maybe. Check labels and configuration.
- **What to do:** Apply or remove labels to make it eligible, or update configuration.

## Pager signatures

Fleet-level invariants fire with a signature — a short code identifying the type of invariant that fired.

### `verdict-unanimous`

Every live node agrees the fleet has failed a check.

- **Is a fault?** Yes. Investigate all nodes' individual diagnostics.
- **What to do:** Run `scripts/doctor.sh` on each node to pinpoint the issue.

### `idle-with-demand`

A node is idle (not running a cycle) but eligible work exists.

- **Is a fault?** Maybe. Check cron scheduling and node availability.
- **What to do:** Verify cron is running and the node is not paused.

### `work-order-repaired-rate`

A high percentage of work orders required repair by the Script.

- **Is a fault?** Yes. Work orders are malformed or incomplete.
- **What to do:** Check the Refiner stage and candidate composition.

### `escalation-burst`

An unusually high number of escalations fired in a short window.

- **Is a fault?** Yes. Multiple failures occurred at once.
- **What to do:** Investigate the root cause of the failures; check logs for details.

## Doctor check names

When `scripts/doctor.sh` runs, it performs checks and reports outcomes. These check names appear in its output.

### `config-valid`

Configuration file is valid JSON and conforms to the schema.

- **Is a fault?** Yes if it fails.
- **What to do:** Fix config.json syntax and schema violations.

### `config-accessible`

Configuration file can be read by the current process.

- **Is a fault?** Yes if it fails.
- **What to do:** Check file permissions.

### `state-dir-writable`

The state directory can be written to.

- **Is a fault?** Yes if it fails.
- **What to do:** Check directory permissions and disk space.

### `github-reachable`

GitHub API is reachable and responding.

- **Is a fault?** Yes if it fails.
- **What to do:** Check network connectivity and GitHub status.

### `github-authenticated`

GitHub token is valid and has required scopes.

- **Is a fault?** Yes if it fails.
- **What to do:** Verify token scopes and expiry.

## Escalation kinds

When the pipeline escalates a recurring issue or a decision that needs human input, it is tagged with a kind.

### `crash-loop`

A stage is repeatedly crashing or timing out.

- **Is a fault?** Yes. Investigate stage logs.
- **What to do:** Check the stage implementation and resource constraints.

### `repeated-block`

An item has been blocked for the same reason multiple times.

- **Is a fault?** Maybe. The blocker might not be self-resolving.
- **What to do:** Investigate the blocker; the issue might need human attention.

### `no-progress`

An item has made no progress over multiple cycles.

- **Is a fault?** Maybe. The item might be stuck.
- **What to do:** Check for external blockers or review feedback.

## Landing refusals

When the landing gate refuses to arm a pull request, it cites a reason.

### `checks-not-green`

One or more required status checks are failing.

- **Is a fault?** Yes. Fix the failing checks.
- **What to do:** Review the check output and fix the underlying issue.

### `review-pending`

The PR is awaiting a required review.

- **Is a fault?** No. Normal process.
- **What to do:** Request review from the assigned reviewer.

### `comment-unreconciled`

A human comment on the PR has not been addressed.

- **Is a fault?** Maybe. Check if the comment needs a response.
- **What to do:** Answer the comment, then request re-review.
