# Project review — agent-ops

**Date:** 2026-09-28 · **Reviewer:** Claude (project-review skill) · **Revision reviewed:** `069e94b` (`main`)

On its fifth review, agent-ops remains a mature, actively self-improving pipeline — 18 of the prior
review's 37 substantive findings are now confirmed resolved, including an unprompted fix for a real
personal-data leak in shipped deploy defaults and continued measurement-over-estimation discipline.
But the headline shift this round is a change in the backlog's shape rather than a new defect: the
prior review's own High-severity finding, a live secret printed into a session transcript, remains
completely unresolved 13 days on with zero comments, and the pipeline's own remediation-tracking has
started stalling the same way on already-scoped, ready-to-execute work — that combination is the
single most important thing to act on.

## Contents

| Document | What it contains |
|---|---|
| [Summary](01-summary.md) | What the project is, its overall health, headline strengths and risks, and this review's scope and method. |
| [Findings](02-findings.md) | All 58 findings by dimension (40 substantive, 18 resolved this round): 0 critical, 1 high, 18 medium, 21 low. |
| [Recommendations](03-recommendations.md) | 20 prioritised recommendations, each mapped to the finding(s) it addresses and to a tracking GitHub issue. |
| [Improvement prompts](04-improvement-prompts.md) | One self-contained, ready-to-paste AI-agent prompt per recommendation, in priority order. |
| [Tech debt filed](https://github.com/Pullwright/agent-ops/issues?q=label%3Apw%3A%3Atype%3Atech-debt) | 4 new issues filed this run (agent-ops#1916–#1919); the remaining 16 recommendations map onto issues already open from prior reviews, cited rather than duplicated. 13 items in the frozen `tech-debt/` register were found already resolved by earlier, previously-uncredited PRs and had their frontmatter flipped in place (one further candidate, the multi-part god-function item, was checked and correctly left open — only one of its parts is actually fixed); see `TECH-DEBT.md`. |

## Scope note

This review was conducted against a fresh clone on `main`, treating the 2026-09-21 review
(revision `5284c02`, 63 commits earlier) as a verified baseline: every prior finding was
re-verified with fresh evidence — code re-read, every cited GitHub issue re-checked live — rather
than assumed carried-forward. The 13 checklist dimensions were delegated to five parallel
subagents, each tasked with re-verifying every prior finding *and* hunting for new findings from
the intervening commits and from deeper sampling. See
[Summary § Scope and method](01-summary.md#scope-and-method) for exactly what was read in full,
what was sampled, and what could not be run in this environment (notably: the Dockerized test
suite, and live fleet/node access).
