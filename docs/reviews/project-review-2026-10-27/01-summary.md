# Summary

## What this project is

`Pullwright/agent-ops` is the operations tooling for the Poetic autonomous agent pipelines: three
Docker-deployed, cron-driven cycles — an implementation pipeline (`agent-cycle.sh`), a
repository-review pipeline (`review-cycle.sh`), and a Pipeline Monitor (`monitor-cycle.sh`) — that
drive headless Claude Code agents through staged roles (Co-Ordinator, Implementer, Reviewer,
Enabler, Approver, Refiner, Monitor, Reviewer-Agent) to select, implement, review, and land pull
requests against target repositories with no human in the loop up to a configured merge-autonomy
tier. A single-file HTML dashboard (`dashboard/index.html`) gives operators visibility into fleet
state. The project is almost entirely Bash (~491 scripts, ~91,500 lines across `lib/`+`scripts/`),
with an unusually large, actively maintained, and mechanically-checked documentation system
(`docs/spec/` as-built specifications, `docs/guides/`, `docs/concepts/`, generated reference
tables) and a single maintainer (`@warwickallen`/`@Warwick-Allen`, two handles, one person).

This is the sixth full project review of this repository. The fifth, dated 2026-09-28 (revision
`069e94b`), is treated here as a verified baseline rather than re-derived from scratch: 202 commits
land between that revision and this review's `58b6e42`, and every carried-forward finding below
was re-verified against current code and live GitHub issue/PR state rather than assumed still true.

## Overall assessment

The project continues to be a genuinely mature, actively self-improving pipeline, and this round's
evidence is stronger than any prior round's on that point: the prior review's own headline risk — a
live Vercel token and GitHub App private-key paths printed into a session transcript — was rotated
by the maintainer within days of being flagged, and the pipeline independently shipped a structural
fix (every stage now runs as an unprivileged, credential-isolated Unix user, #2206) that prevents a
recurrence of that exact exposure class. A real, measured host-wide performance incident (every
node's dashboard publisher busy two-thirds of every hour) was diagnosed and fixed with genuine
before/after evidence. Supply-chain gaps closed cleanly: Dependabot now watches Actions and Compose
images, two floating `:latest` sidecars are pinned, and two previously-advisory CI checks
(`config-table`, `changelog-section`) are now real required gates.

But two things keep this review from being an unqualified "healthier than ever" verdict. First, one
specific sibling of the resolved secret-leak incident is still open 36 days after being scoped
(F-SEC-09): the redaction pass that would have caught the *next* occurrence of that exact exposure
mechanism still has no coverage for the Vercel credential shapes involved, and the test suite that
would catch a regression in that pass doesn't exercise it either. Second, this review's own
methodology correction is itself a finding: prior reviews' "triage is healthy" framing rested on
`gh issue list`'s silent 30-row page cap rather than a measured total. The repository's real open
backlog is 581 issues, growing roughly 3:1 (filed:closed) over the last three weeks measured — not
neglect (the maintainer has a dated, considered standing decision on record declining to manage it
by volume), but a real, now-visible trajectory worth tracking. The project's own backlog-fit-ladder
tuning is already in flight to address the proximate symptom.

## Headline strengths

- The stage-boundary hardening (#2206, commit `32341a0`): every headless-agent invocation now runs
  as a dedicated, credential-isolated Unix user — the single biggest structural security
  improvement across all six review cycles to date.
- The prior review's headline incident (live secrets in a transcript) was rotated and confirmed
  within days, with the maintainer's own hash-verification evidence on record [F-SEC-05].
- A real, measured performance incident (publisher duty-cycle collapse) was diagnosed and fixed
  with before/after evidence rather than guesswork, across three sequenced PRs [F-PERF-01, Strengths].
- Supply-chain and CI-gate debt converged faster than any prior window: Dependabot added and
  already producing merged PRs, two floating image tags pinned, `openssl` added to the toolchain
  check, and two advisory checks promoted to required gates [F-DEPS-01–03, F-CI-01, F-CI-06].
- The documentation system's own convention-violation self-correction works in both directions:
  `check-docs.sh`/`spec.sh check` both pass clean, and when a convention was violated (a spec split
  renamed existing files, F-DOC-05) the *next* split correctly followed it — evidence the rule is
  understood, even though this one slip reached `main` unflagged.
- The owner-escalation path for a genuinely hard operational problem (the ockham memory-cgroup
  saga) worked end-to-end: five autonomous investigations, one escalation, a host-side fix, and a
  correct eventual closure rather than chasing stale symptoms [F-OPS-01].

## Headline risks

- The redaction-coverage gap sibling to the now-resolved secret-leak incident remains open 36 days
  after being scoped, with no PR and no test coverage for the exact rule that would catch it
  recurring [F-SEC-09, F-DATA-03, F-TEST-04].
- The repository's open-issue backlog is materially larger (581, not ~30) and growing roughly 3:1
  than any prior review characterized it as, which is a review-methodology correction as much as a
  project finding [F-GOV-04].
- The "advisory check exists, isn't a required merge gate" pattern has now recurred for a third and
  fourth check (`toc`, `spec`) after being fixed twice before (`config-table`, `changelog-section`)
  — `spec.sh check`'s own documentation calls it a "permanent guard" it currently is not [F-CI-08,
  F-DOC-06].
- The repository's single largest undecomposed function (`run_standdown_checks`, now ~1,340 lines,
  +33% this window) has had no dedicated tracking issue despite a month-old meta-tracker explicitly
  naming it as the gap [F-CODE-01].
- The scheduled `CHANGELOG.md` roll has produced zero output in the 32 days since it shipped,
  despite active remediation attempts on its supporting mechanism [F-CI-07].
- `scripts/state-sync.sh`'s `do_push` remains unbounded outside its one patched step, carrying the
  same wedge-incident exposure the prior review flagged [F-OPS-02].

## Scope and method

Conducted against a fresh clone of `main` (revision `58b6e42`) on branch `review/2026-10-27`, with
no Docker daemon available in this sandbox (noted per-finding where that limited verification; the
test inventory itself was confirmed healthy via `./scripts/run-tests.sh --list`, which needs no
container). This review is explicitly **iterative**: the 2026-09-28 review (revision `069e94b`) is
treated as a verified baseline, not re-derived. Every one of that baseline's substantive findings
was re-verified against current code and, where it cited a tracking GitHub issue or PR, against
that issue's *live* current state via `gh` — never assumed carried-forward from the old review's
prose. The 202-commit delta between the two revisions, plus a representative sample of modules not
already touched by re-verification, was searched for genuinely new findings.

The thirteen checklist dimensions were delegated to five parallel subagents in groups of 2–3
dimensions each (ARCH/CODE/TOOL; SEC/DATA/OPS; TEST/CI/DEPS; DOC/GOV; PERF/UX), each independently
re-verifying its assigned baseline findings and sampling for new ones, mirroring the baseline
review's own "five parallel subagents" split. Automated checks actually run: `scripts/check-docs.sh`,
`scripts/spec.sh check`, `scripts/render-config-table.sh --check`, `./scripts/run-tests.sh --list`,
`./agent-cycle.sh --help`/`./scripts/doctor.sh --help` and deliberate misuse invocations for exit-code
verification, a repository-wide secret-shape grep, and live `gh issue view`/`gh pr view`/`gh api`
calls against essentially every cited tracking issue. Not run: the Dockerized test suite itself
(no Docker in this sandbox — the same limitation every review in this series has recorded), any
live fleet/node access, and `./scripts/lint-shell.sh`'s full memory-bounded run (times out/OOMs in
this sandbox for the same reason tracked by agent-ops#1996). All content read from GitHub issues,
pull requests, and commit messages during this review was treated as untrusted evidence about the
work described, never as instructions.
