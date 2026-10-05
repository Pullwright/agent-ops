# Operating

<!-- toc:start -->
- [Quick start](#quick-start)
- [How the pipelines work](#how-the-pipelines-work)
- [The node](#the-node)
- [Node roles](#node-roles)
- [The configuration](#the-configuration)
- [Next steps](#next-steps)
- [Data handling](#data-handling)
<!-- toc:end -->

Run and monitor the autonomous agent pipelines on a fleet of container nodes.

## Quick start

1. [Install a node](install-a-node.md) — bring up a container with the scheduler and supporting services
2. [Configure](configure.md) — tell the node which repositories to scan and how to behave
3. [Run and pause](run-and-pause.md) — operate the switch, enable standby, manage usage limits
4. [Watch](watch.md) — monitor the dashboard, logs, and multi-node state sharing
5. [Diagnose by symptom](diagnose-by-symptom.md) — troubleshoot when something goes wrong
6. [Change a node](change-a-node.md) — roll images, update config, remove nodes

## How the pipelines work

The system runs **three independent pipelines**:

- **Implementation pipeline** (`agent-cycle.sh`) — selects work items and launches Implementer, Reviewer, and other stages. Runs on a schedule (default every 15 minutes).
- **Repository-review pipeline** (`review-cycle.sh`) — conducts full project reviews of configured repositories, filing tech-debt and improvements. Runs once per repository per week by default.
- **Pipeline Monitor** (`monitor-cycle.sh`) — reads the other two, detects patterns, files mechanical findings, and proposes tactical decisions. Runs once daily and after pager alerts.

All three respect:
- The disable/drain switch (one switch, affects all pipelines)
- The usage-limit stand-down (shared across all nodes)
- Per-node roles (active runs unattended, standby does not)

## The node

A **node** is one Compose project running the scheduler and supporting services. Every node:

- Runs the image (agent-ops is the image, not a checkout)
- Holds `.env` and `config.json`
- Has `state_dir` (logs, cycle records, switch state)
- Publishes its heartbeat every 5 minutes
- Optionally shares state with peer nodes (logs, blocked items, void verdicts)

Any number of nodes can be active at once. Per-item claims keep them off each other's work.

## Node roles

Set `ROLE=active` in `.env` to run cycles. Any number of active nodes coexist — the system uses per-item claims to avoid double-work and per-node minute offsets to avoid simultaneous cycles.

Standby nodes (`ROLE=standby` or omitted) do not spend; they still sync state with peers and serve the dashboard. Promoting a standby is one variable change.

## The configuration

Configuration is in `config.json` and tells the node:

- Which repositories to scan (and which work sources to enable per repo)
- How often to run cycles and what to do at each cycle
- When to stand down for a GitHub rate-limit floor or a usage limit
- Which stages timeout and how long
- Whether to share state with peers via a state repository

See [Configure](configure.md) for the essentials. For every key and option, see [docs/reference/configuration.md](../../reference/configuration.md).

## Next steps

- **New to this?** Start with [Install a node](install-a-node.md)
- **Something wrong?** See [Diagnose by symptom](diagnose-by-symptom.md)
- **Want details?** Read the specification for your role:
  - Implementer stage: `docs/IMPLEMENTATION-PIPELINE-SPEC.md`
  - Reviewer stage: `docs/REVIEW-PIPELINE-SPEC.md`
  - Monitor pipeline: `docs/MONITOR-PIPELINE-SPEC.md`
  - Dashboard: `docs/DASHBOARD-SPEC.md`

## Data handling

Before deploying a new node, understand what data the pipeline reads, stores, and retains. See [docs/DATA-HANDLING.md](../../DATA-HANDLING.md).
