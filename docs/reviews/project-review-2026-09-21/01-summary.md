# Summary

## What this project is

`Pullwright/agent-ops` is the operations tooling for the Poetic autonomous agent pipelines: a
self-hosted, unattended system that automatically selects, implements, and reviews pending work
across `Poetic-Poems/poetic`, `Poetic-Poems/poetic-fiddle`, and `agent-ops` itself, raising
mergeable pull requests for human review at a configurable trust ladder. It has four components,
each with an as-built requirements specification under `docs/`: the implementation pipeline
(`agent-cycle.sh`), the repository-review pipeline (`review-cycle.sh` — the very component
conducting this review), the Pipeline Monitor (`monitor-cycle.sh`), and a local dashboard
(`scripts/publish-dashboard.sh` / `dashboard/index.html`).

The stack is almost entirely Bash (398 `.sh` files, ~2.6 MB in `lib/` alone), with one Python
helper and a single static-HTML dashboard with vanilla JS. It runs as a Docker container deployed
to a small fleet of nodes over Tailscale, driven by `supercronic` against a crontab, and depends
on GitHub (API and Actions), the Claude API/CLI, and optionally Vercel and a webhook notification
service. A single maintainer operates it; self-review is structural and candidly disclosed in
`AGENTS.md` — approvals come from the maintainer's own second GitHub identity or the Pullwright
Approver GitHub App, with an explicitly stated "no succession plan."

This is the fourth project review of this repository (following 2026-08-23, 2026-08-31, and
2026-09-05), and the codebase has moved fast in the interval: 180 commits landed between the prior
review's pinned revision and this one's, out of 739 commits in the last 60 days overall.

## Overall assessment

agent-ops remains an unusually mature, actively self-improving pipeline for a project this young,
and the pattern from prior reviews continues: real production incidents get found, fixed, and
regression-tested fast, often within the same day. Of the three prior review's 34 findings, 9
findings this review re-verified are now genuinely resolved — not relabelled — including the
dashboard's headline keyboard-accessibility gap, the security/governance documentation gaps
(`SECURITY.md`, `CONTRIBUTING.md`, issue/PR templates, a licence-transition notice, a personal-
data inventory), and two of the prior review's four ARCH/CODE duplication findings.

Against that, this review's most important finding is new and more serious than anything found in
the prior three rounds: a live Vercel token and GitHub App private-key paths were printed into an
agent session transcript on 2026-09-16 (agent-ops#1627), and the issue remains open six days later
with no rotation decision recorded. Independent code reading confirms the general gap the incident
exposed is real and still unpatched — the redaction pass that would need to catch a recurrence of
this before it reached the fleet's state-mirror repository structurally cannot, for any secret
shape outside a handful of matched token prefixes plus one registered webhook literal. This is the
first High-severity finding across four consecutive reviews of this repository; no Critical finding
exists.

Beyond that, the review surfaced a coherent secondary pattern: several places where *detection* has
genuinely improved since the last review but *remediation* has not kept pace. The memory-cgroup
verdict now reaches the dashboard automatically every hour, yet a live node has been running with
an unbounded memory ceiling and a double-digit OOM-kill count for multiple days because the fix
needs host access no container in this architecture has, and nothing pages on it. A mirror-lock
wedge that caused a 7-hour production incident was fixed — but by the fix's own admission, only for
one call site, leaving the statistically more likely wedge source (a hung network call) still
unbounded, and no outbound `gh` API call anywhere in the pipeline has a timeout. And the stage-
orchestration decomposition effort that prior reviews flagged as this codebase's single biggest
maintainability debt is working when applied — one of seven flagged god functions is now cleanly
split — but is losing the race against growth: two of the remaining four are larger today than when
they were first flagged, and a brand-new entry point (`monitor-cycle.sh`) was built with the exact
undecomposed-flow shape the fix exists to eliminate, rather than reusing the pattern the codebase
had already proven elsewhere.

## Headline strengths

- Redaction, credential-minting, and token-cache code is written with unusually explicit
  adversarial reasoning (a `/dev/shm` symlink-race guard, argv-exposure avoidance for JWTs, an
  associative-array-subscript injection guard) — well above what a project of this maturity would
  typically invest.
- The dashboard's keyboard-accessibility gap, all four missing governance documents (`SECURITY.md`,
  `CONTRIBUTING.md`, issue/PR templates), and the missing personal-data inventory are all now
  genuinely fixed, each landing in one coherent commit rather than a partial patch [F-UX-01,
  F-GOV-01, F-DATA-01].
- `shellcheck -x` is clean across the whole `lib/`/`scripts/` tree; zero genuine TODO/FIXME/HACK
  markers remain; the two most recent commits on `main` at review time both choose to fail closed
  (drop or empty a file rather than risk committing it unredacted) — discipline holding in the
  newest code, not just the reviewed baseline.
- Real production incidents are found, root-caused, and regression-tested fast: a 7-hour mirror-
  lock wedge, three chained memory-livelock incidents, and a `log.jsonl` performance regression all
  produced genuine, well-documented fixes within days, each fix's PR explaining the specific
  incident that taught the lesson.
- Issue/PR hygiene is healthy despite a large open-issue count (312, 246 of them tech-debt): no
  multi-month stale backlog exists, and all 7 open PRs were opened within the review's own final
  week [F-GOV-02].

## Headline risks

- Live production secrets were printed into an agent transcript six days before this review, and
  the redaction machinery that should catch a recurrence structurally cannot for the class of
  secret involved — the review's only High-severity finding, and its most important [F-SEC-05,
  F-DATA-03].
- A live fleet node has been running with an unbounded memory ceiling and a double-digit OOM-kill
  count for multiple days; the pipeline detects and reports this hourly but cannot fix it itself,
  and nothing escalates the gap to a human [F-OPS-01].
- A recently-hardened lock-wedge fix is explicitly scoped to one call site, and the pipeline's most
  frequent class of outbound call — `gh` API requests — has no timeout anywhere in a 1,208-line
  shim [F-OPS-02].
- The codebase's largest known maintainability debt — undecomposed, oversized stage-orchestration
  functions — is being fixed correctly but too slowly to keep pace with growth, and was just
  reproduced wholesale in a brand-new entry point rather than avoided [F-ARCH-01, F-CODE-01].
- Two of this repository's own as-built specs (the contract this project treats as binding) have
  been factually wrong about their own target-repository list since before the prior review, never
  caught until this pass [F-DOC-03].

## Scope and method

This review was conducted against a fresh clone on `review/2026-09-21`, pinned at commit
`5284c02` on `main`. The 2026-08-23/2026-08-31/2026-09-05 reviews were treated as a verified
baseline: every finding from the most recent of those (2026-09-05) was re-verified against the
current tree with fresh evidence — file paths, line numbers, and live GitHub issue state, not
assumed carried-forward — rather than re-derived from scratch, and every dimension additionally
hunted for new findings from the 180 commits landed since that review's pinned revision
(`916a951` → `5284c02`) and from deeper or differently-angled sampling.

The 13 checklist dimensions were delegated to six parallel subagents (ARCH+CODE, SEC+DATA,
TEST+CI, DEPS+TOOL, PERF+OPS, UX+DOC+GOV), each given the project map, its assigned dimensions,
and instructed to re-verify the prior baseline with live evidence before hunting for new findings,
and to dedup every candidate finding against `gh issue list` before treating it as new. All 13
dimensions were judged fully applicable; none was found inapplicable to this project.

**Read in full:** `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, all
`.github/workflows/*.yml` (1,020 lines, all 10 files), `.githooks/*`, `deploy/docker/Dockerfile`
(324 lines) and `compose.yaml`, all four `docs/*-SPEC.md` (structural read plus full read of
security/data/config-handling sections), `TECH-DEBT.md`, the three prior review index/findings/
recommendations documents, `agent-cycle.sh` (4,025 lines), `review-cycle.sh`, `monitor-cycle.sh`,
`lib/redact.sh`, `lib/github-app-token.sh`, `lib/approver-token.sh`, `lib/forge-auth.sh`,
`lib/mirror-lock.sh`, `lib/memory.sh`, `lib/resource-usage.sh`, `lib/disk-space.sh`,
`lib/log-event.sh`, `docs/DATA-HANDLING.md`, `docs/MONITOR-PIPELINE-SPEC.md`.

**Sampled, with the sampling strategy recorded in each dimension's own findings:** the largest/
most complex `lib/` files (`landing.sh`, `enabler.sh`, `candidate-select.sh`, `pager-
invariants.sh`, `refinement.sh`, `handoff.sh`, `approver.sh`, `cycle-state.sh`, `standdown.sh`,
`void-guard.sh`), a representative cross-section of ~15 further "ordinary" `lib/`/`scripts/`
files chosen for size/recency spread, `dashboard/index.html`'s full function-boundary list
(function sizes measured programmatically; not every body read in full), and a matched sample of
`test/*.test.sh` files against the code sampled (two independent random samples totalling ~45 of
223 test files, run directly outside Docker — see below).

**Automated checks run:** `shellcheck -x` against the full `lib/*.sh`/`scripts/*.sh` set
(`./scripts/lint-shell.sh`, matching CI's pinned v0.10.0) — clean, 0 findings, 2 files not fully
followed under `-x` due to this sandbox's own memory limit (an environment constraint noted in the
tool's own warning output, not a code defect: CI's runner has enough memory to follow them). A
live `gh api` read of the branch protection ruleset's actual required-status-check list (not
inferred from workflow triggers alone). `render-toc.sh --check` and `render-config-table.sh
--check` (both clean). A non-mutating `docker compose config` parse of `compose.yaml` against
`.env.example` (clean; the render incidentally surfaced this sandbox's own live-node secrets via
Compose's environment-precedence over the example file's blank placeholders — deleted immediately,
not reproduced, and not itself a repository defect).

**Could not be run in this environment:** the Docker-based test suite (`./scripts/run-tests.sh`
requires a Docker daemon, unavailable in this sandbox) — mitigated by running two independent
random samples (~45 of 223 files, ~20%) directly outside Docker, which passed cleanly except one
sandbox-environment artefact (an ambient credential variable overriding a test fixture, not a code
defect), and by corroborating CI's own recent run history via `gh run list` (last 50
`build-image.yml` runs: 45 success, 5 cancelled-as-superseded, 0 failures) rather than claiming a
locally-unverifiable pass. An automated accessibility checker (axe/Lighthouse) — none available
offline in this environment; the UX dimension's accessibility assessment is static-markup-only, a
carried-forward limitation from every prior review of this project.
