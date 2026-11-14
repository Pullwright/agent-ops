# Summary

## What this project is

Pullwright/agent-ops is operations tooling for the Poetic autonomous-agent pipelines: an
implementation cycle (`agent-cycle.sh`), a repository-review cycle (`review-cycle.sh`), a
Pipeline Monitor (`monitor-cycle.sh`), and a local dashboard (`dashboard/index.html`). It is
entirely Bash + `jq` + `gh`/GitHub API orchestration — 1,000 tracked files, ~220,000 lines of
shell across `lib/` (125 files) and `scripts/` (84 files), 281 test files, 133 documentation
files, and 1,137 commits since 2026-07-13.

It is single-maintainer software (Warwick Allen, two GitHub handles), MIT-licensed
(provisionally, pending a stated move to FSL-1.1-ALv2), run against the maintainer's own
`Poetic-Poems/poetic` and `poetic-fiddle` repositories and against this repository itself.
This is its seventh project review; the series treats each prior review as a verified
baseline and re-checks every finding against current code and live GitHub state rather than
assuming anything carried forward.

## Overall assessment

The project continues to improve on the metric this series has watched most closely: four of
the prior round's 23 recommendations are now fully delivered — the repository's largest
undecomposed function was split (R-15/F-CODE-01), a Dependabot gap for the base OS image was
closed (R-09/F-DEPS-05), a container-image vulnerability scan landed (R-06/F-CI-09), and a
missing pager invariant for a previously-incident-causing failure mode was added
(R-21/F-OPS-04). A genuinely thorough, multi-stage security-hardening chain (the
backgrounded-wait-guard sequence) also closed end-to-end this window.

But the review's own headline risk from last round is unchanged for a third consecutive cycle:
`redact_add_literal` still has no registration for the Vercel credentials that caused a real
secret-leak incident six weeks ago (F-SEC-09), 50 days and zero PRs after being filed. This
review adds a second High-severity item by escalating F-OPS-02 (the unbounded half of
`state-sync.sh`'s `do_push`) from Medium to High: it is the exact mechanism behind a real,
already-occurred multi-hour fleet-wide wedge, and the asymmetry with its sibling `do_fetch` —
hardened twice this very window — has widened rather than closed. Both High items share the
same shape: fully scoped, small-to-medium effort, zero issue-thread activity, simply not yet
picked up. Closing them (R-01, R-02) is the single most important thing to act on this round.

## Headline strengths

- Four prior recommendations fully delivered this window: the `run_standdown_checks`
  decomposition (F-CODE-01), the Dependabot `docker`-ecosystem gap (F-DEPS-05), the
  container-image vulnerability scan (F-CI-09), and the memory-cgroup pager invariant
  (F-OPS-04).
- A thorough, multi-PR defense-in-depth security chain (the backgrounded-wait-guard hook
  hardening) closed end-to-end, moving a `PreToolUse` hook to a root-owned path and
  mechanically verifying every directory in the chain that could be used to recreate it.
- Test investment kept pace with code growth (281 files, up from 277; four new, well-targeted
  files with no real network calls) and a real fleet-observed performance pathology
  (`do_fetch`'s lock-contention giving up on ordinary `flock` contention) was diagnosed and
  fixed with cron-log evidence.
- A new self-healing mechanism (a two-strikes circuit breaker on repeated void-refusals, #2792)
  extends the same "stop re-discovering the same failure indefinitely" discipline the
  memory-cgroup pager fix embodies.
- Zero live secrets or PII found in a fresh scan of the working tree; the egress allowlist and
  credential-isolation boundary remain structurally sound.

## Headline risks

- **F-SEC-09 (High):** the Vercel-secret redaction gap is unchanged in code across three
  review cycles spanning 50 days, with no PR ever opened against it — the direct sibling of a
  real incident this project has already had once.
- **F-OPS-02 (High, escalated this round):** `do_push`'s unbounded steps are the exact
  mechanism behind a real 7-hour fleet-wide wedge; its sibling `do_fetch` was hardened twice
  this window while `do_push` received nothing.
- **F-ARCH-01 (Medium):** the stage-orchestration god-flow pattern is only partly converging —
  one instance was fixed this window, but the next two largest functions
  (`maybe_run_enabler` +16%, `run_approver_stage` +25%) grew faster in two weeks than the
  fixed one did when it was first escalated.
- **F-GOV-04 (Medium):** the open-issue backlog has grown to 609 (77% tech-debt-labelled), up
  from 581 two weeks ago; the owner's architectural mitigation (`#2437`) is active but has sat
  `BLOCKED` for 25 days.
- **F-CI-08/F-DOC-06 (Medium):** wiring `toc` and `spec` into the required-status-check
  ruleset is a fully-specified, one-click, owner-only edit that has now sat open 21–38 days —
  the cheapest unaddressed item in this entire review.

## Scope and method

This review was conducted against a fresh clone of `main` (revision `e2bae5e5`), treating the
2026-10-27 review (revision `58b6e42`, 66 commits earlier) as a verified baseline: every one of
its 38 substantive findings and 23 recommendations was re-verified with fresh evidence — code
re-read at current line numbers, every cited GitHub issue/PR re-checked against its *live*
current state via `gh` — rather than assumed carried forward. The 13 checklist dimensions were
delegated to five parallel subagents, each tasked with re-verifying every prior finding in its
assigned dimensions *and* hunting for new findings from the 66 intervening commits and from
deeper sampling (complexity hot-spots, duplication, a fresh secret-shape scan, live `--help`
testing, live ruleset/issue/PR state). This review's own lead pass independently spot-checked
the most consequential claims (F-SEC-09's code state, the ruleset's required-checks list, the
Trivy scan's presence, the standdown decomposition) before consolidating.

Exhaustive: the three cycle entrypoints, `lib/standdown.sh`, `lib/claim-key.sh`,
`lib/redact.sh` and its test file, `scripts/preview-deploy.sh`, `.github/workflows/` in full,
`docs/STANDING-DECISIONS.md`, `docs/DATA-HANDLING.md`, the branch ruleset, and every issue/PR
cited by the prior review. Sampled: the remaining `lib/`/`scripts/` population (depth-first on
the largest files — `lib/landing.sh`, `lib/candidate-select.sh`, `lib/enabler.sh`,
`lib/approver.sh` — plus `grep`-based sweeps for patterns like TODO markers, `cfg()`/
`expand_home()` redefinitions, and secret shapes), the 66 intervening commits' diffs (read in
full for anything security-, architecture-, or CI-relevant; skimmed otherwise), and 281 test
files (read a representative subset in full, inventoried the rest by name and diff).

Not run: `./scripts/run-tests.sh`'s real Docker-based test suite (no Docker daemon in this
sandbox — same limitation as every prior review in this series; its Docker-free `--list` fast
path was independently re-confirmed working); live fleet/node telemetry (OPS findings rely on
code and issue/incident history, not live host state); the scheduled CHANGELOG-roll cron (runs
on a deployed node outside this review's reach — only the absence of its resulting PR is
directly verifiable). `gh` was authenticated and reachable throughout, so all GitHub
issue/PR/ruleset state cited above is live, not cached.
