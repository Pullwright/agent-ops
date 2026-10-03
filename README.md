# Pullwright

Pullwright is a self-hosted, unattended pipeline that selects, implements,
and reviews pending work in a GitHub repository, raising mergeable pull
requests for human review and approval. It is for anyone who wants routine
engineering work — tech debt, triaged issues, review feedback, security
findings — picked up and carried to a pull request without a human having
to start each one by hand.

## How a cycle works

```
cron (schedule.cycle_interval_minutes)
  └─ agent-cycle.sh                 ← the Script: lock, stand-down checks, repo ordering
       ├─ Co-Ordinator (Haiku)      ← selects ≤ 1 item, emits a work order; nothing else
       ├─ Implementer (Sonnet/Haiku)← ephemeral clone, feature branch, draft PR
       ├─ Reviewer (Sonnet/Opus)    ← corrects the branch, flips the PR to ready
       │     └─ Human Reviewer      ← approves/merges per `merge_autonomy`
       ├─ Enabler (Opus, rarely)    ← re-examines long-blocked items at the end of a
       │                              cycle: unblocks, voids, or raises an issue
       │                              assigned to the Human saying what to do
       └─ Refiner (Haiku)           ← same end of the cycle: writes the specification
                                      an unscoped item lacks, before it has to be
                                      blocked and wait for the Enabler
```

A second pipeline reviews a repository on its own schedule rather than
picking up discrete items, and a third, the Pipeline Monitor, reads both and
reports on them once a day. `docs/concepts/glossary.md` defines every term
used above.

## Start here

| If you are… | Start with |
|---|---|
| a person working in a repository the pipeline works on | [Working with Pullwright from a target repository](docs/guides/working-with-pullwright/README.md) |
| an operator running an installation | [Operating](docs/guides/operating/README.md) |
| a contributor changing the pipeline itself | [Contributing](docs/guides/contributing/README.md) |
| looking for a configuration key | [Configuration reference](docs/reference/configuration.md) |
| looking for anything else | [`docs/README.md`](docs/README.md), the map of every document in this repository |

## Guides

Each guide below lists the sections moved into it, so a link into the old
single-file README can still be found by name:

- **[Working with Pullwright from a target repository](docs/guides/working-with-pullwright/README.md)** —
  what it does, responding to your review comments, staying in front of you,
  issue priority, reserving an issue for yourself, cross-item dependencies,
  handing a pull request to the pipeline, merge autonomy.
- **[Operating](docs/guides/operating/README.md)** —
  installation (including the egress fence), checking an installation,
  operation, pausing the pipelines, which node runs the cycles, keeping
  every node warm, skipping no-op cycles, diagnosing a cycle, repository
  review, the Pipeline Monitor, monitoring, troubleshooting, removing a node
  for good, uninstall.
- **[Contributing](docs/guides/contributing/README.md)** —
  for maintainers, branch workflow, development.
- **[Configuration reference](docs/reference/configuration.md)** —
  every configuration key, its default, and its extended notes.

## Status and licence

Pullwright is under active development; the reference installation runs it
against Poetic-Poems's own [poetic](https://github.com/Poetic-Poems/poetic)
and [poetic-fiddle](https://github.com/Poetic-Poems/poetic-fiddle)
repositories, and against this repository itself. Licensed under the terms
in [`LICENCE`](LICENCE) — currently plain MIT, provisionally, pending a move
to FSL-1.1-ALv2 (see `docs/ROADMAP.md`, decision D5).
