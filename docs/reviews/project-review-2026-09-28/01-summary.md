# Summary

## What this project is

agent-ops (Pullwright/agent-ops) is the operations tooling behind a fleet of autonomous
coding-agent pipelines: an implementation cycle that autonomously selects work items, runs
Implementer/Reviewer/Enabler/Approver/Refiner Claude Code stages against target repositories, and
merges via GitHub; a repository-review cycle (the pipeline currently producing this document); a
Pipeline Monitor that scheduledly observes the fleet's own state; and a single-file static
dashboard. It is a Bash/jq project with no package manifest — roughly 72,300 lines of `lib/`/
`scripts/` shell across 174 files, 94,800 lines of test code across 237 files, and four detailed
as-built specification documents.

Audience and maturity: single-maintainer, production-critical for that maintainer's own fleet, and
self-hosting — the pipeline reviews and implements changes on its own repository, including this
one. This is the fifth full project review; the prior four (2026-08-23, 2026-08-31, 2026-09-05,
2026-09-21) established a pattern of low defect density and strong self-correction, with most
High/Medium findings resolved or explicitly tracked within one to two review cycles.

## Overall assessment

agent-ops remains a genuinely mature, actively self-improving pipeline: of the 2026-09-21 review's
37 substantive findings, 18 are confirmed resolved this round — including both fixes landed within
a day of that review's own baseline commit, a real personal-data leak in shipped deploy defaults
found and fixed unprompted, and continued measurement-over-estimation discipline (a second
estimate-vs-measurement gap closed this window, following the first one closed last round). Code
quality signals stay strong: zero dead-code markers, a clean shellcheck sweep, and new subsystems
(the changelog-assembly pipeline, `lib/stage-budget.sh`, `lib/stage-health.sh`, `lib/rebase-only.sh`)
that are uniformly well-bounded, well-tested, and free of the seam-drift or unbounded-loop patterns
this review specifically hunted for.

But the headline shift this round is not a new defect — it's a change in the shape of the backlog.
The 2026-09-21 review's own High-severity finding, a live secret printed into a session transcript,
remains completely unresolved: issue #1627 has gone from 6 days of silence to **13 days**, with
still zero comments and no visible rotation decision. That alone would be concerning; what makes it
a pattern rather than an isolated stall is that the prior review's own *remediation-tracking*
mechanism has started failing the same way. agent-ops#1756 — filed specifically to close four
outstanding god-function-decomposition gaps — has had zero activity since its own creation. Two
fully-scoped, `refined`, ready-to-execute issues (#1146, a documentation fix open 29 days across
four review cycles; #1753, a CLI-flag fix open since the prior review) sit unpicked despite
requiring no further design work. This review surfaces that pattern explicitly as F-GOV-02: it is
not that the pipeline can't find its own problems — the evidence shows it finds them well, and even
self-corrects mid-cycle when it catches a real inconsistency (see PR #1577's own Reviewer-stage
self-catch, F-GOV-03) — it's that a growing minority of found, scoped, low-risk items are not
getting picked up for execution.

## Headline strengths

- Four fixes landed within days of the prior review's own baseline, including two secret-handling
  hardening fixes (#1741, #1730) that shipped with dedicated new tests the same week.
- A genuine, unprompted personal-data leak (real username/home path/timezone in shipped deploy
  defaults) was found and fixed within this window (F-SEC-08), with no review having flagged it
  first.
- Measurement-over-estimation discipline is compounding: a second previously-estimated threshold
  (disk-footprint headroom) was re-derived from real measurement this window, following the same
  treatment applied to a different threshold last round.
- New subsystems added this window (changelog assembly, stage budgeting, stage health, rebase-only
  merge handling) are uniformly well-bounded and well-tested — no new unbounded loop, seam drift, or
  duplication pattern was found in any of them.
- The suite continues to grow faster than the code it tests (1.31:1 test-to-code LOC ratio) while
  staying green: a sample of 11 recently-touched test files all ran clean directly against this
  sandbox's `jq` 1.7, matching CI.

## Headline risks

- A live Vercel token and GitHub App private-key paths exposed in a session transcript on
  2026-09-16 remain unresolved 13 days later, with zero comments on the tracking issue and no
  visible rotation decision [F-SEC-05].
- The redaction-coverage gap that exposure revealed — non-token-shaped runtime secrets aren't
  registered for masking — is itself unfixed 8 days after being scoped, and
  `docs/DATA-HANDLING.md` still overstates what the mirror-push redaction pass covers
  [F-SEC-09, F-DATA-03].
- The pipeline's own remediation-tracking has started stalling on already-scoped work: a
  meta-tracking issue for god-function decomposition has had zero activity since it was filed, and
  two other fully-scoped, ready-to-execute issues have sat unpicked for 8–29 days
  [F-ARCH-01, F-GOV-02].
- A memory-cgroup remediation gap first flagged last round is now five investigations deep with
  zero remediation and still no paging path, while a related self-inconsistency in the same
  subsystem's shipped defaults compounds it [F-OPS-01].
- Two independent instances of the same "check runs but isn't a required merge gate" pattern now
  exist (`config-table`/`toc`, and the newly-added `changelog-section`) — the second one arrived
  with the same gap already built in [F-CI-01, F-CI-06].

## Scope and method

This review treats the 2026-09-21 review (revision `5284c02`) as a verified baseline and re-verified
every one of its findings against the current tree (revision `069e94b`, 63 commits / 196 files
later) with fresh evidence — code re-read in full where files were small enough, and every cited
GitHub issue re-checked live via `gh issue view`/`gh issue list`/`gh pr view`/`gh pr list` rather
than assumed carried-forward. The 13 checklist dimensions were delegated to five parallel
subagents (grouped ARCH+CODE, SEC+DATA, TEST+CI, DEPS+TOOL, PERF+OPS, UX+DOC+GOV), each tasked with
re-verifying every prior finding in its dimensions *and* hunting for new findings from the
intervening commits and from deeper/different sampling; consolidation and rating stayed with the
lead reviewer.

**Read in full:** all four as-built specs' security/data/config-handling sections; `AGENTS.md`;
`agent-cycle.sh`, `review-cycle.sh`, `monitor-cycle.sh`; `lib/redact.sh`, `lib/claim-key.sh`,
`lib/claim.sh`; `docs/DATA-HANDLING.md`; `SECURITY.md`; all `.github/workflows/*.yml`; every issue
and PR cited by a finding above (checked live via `gh`, not from memory of the prior review's
text); the prior four reviews' index/findings/recommendations documents.

**Sampled:** `lib/` (104 files) and `scripts/` (70 files), prioritising files touched by the
63-commit window (`git diff 5284c02..HEAD --stat`), the largest/fastest-growing files
(`scripts/publish-dashboard.sh`, `scripts/doctor.sh`, `dashboard/index.html`), and the four
genuinely new subsystems this window introduced (`lib/rebase-only.sh`, the changelog-assembly
chain, `lib/stage-budget.sh`, `lib/stage-health.sh`). Test files: a sample of 11 recently-touched
files run directly rather than exhaustively.

**Automated checks run:** `shellcheck` (clean on every file checked, after tracing a handful of
false-positive `-x` cross-file warnings back to genuine sourced globals); direct execution of a
sample of test files (`bash test/<name>.test.sh`, this sandbox's `jq` 1.7 matches CI's, so this is
a faithful — if partial — signal); `gh run list --workflow=build-image.yml --limit 50` and
equivalent for other workflows, to corroborate CI health from real run history rather than reading
alone; live `gh api` reads of the current branch ruleset and `doctor.sh`'s own acceptance checks,
run directly against this checkout.

**Could not be run in this environment:** the Docker-based test suite (`./scripts/run-tests.sh`
requires a Docker daemon, unavailable in this sandbox) — mitigated as above by direct sampled runs
and CI run-history corroboration, consistent with every prior review's own documented mitigation
for the same constraint. No live fleet/node access, so two findings that would benefit from it
(F-CI-07's changelog-roll-fired check; confirming F-OPS-01's current `oom_kill_count` trend beyond
what the issue thread already states) are flagged as needing a from-the-fleet check rather than
resolved by this review. No automated accessibility checker was needed this round since the
dashboard's only human-facing surface received no new interactive elements (confirmed by diff).
