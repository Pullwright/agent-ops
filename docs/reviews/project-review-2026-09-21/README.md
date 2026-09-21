# Project review — agent-ops

**Date:** 2026-09-21 · **Reviewer:** Claude (project-review skill) · **Revision reviewed:** `5284c02` (`main`)

On its fourth review, agent-ops remains an unusually mature, actively self-improving pipeline —
9 of the prior review's 34 findings are now genuinely resolved, including the dashboard's keyboard-
accessibility gap and every missing governance/security document. But this round surfaces the
project's first High-severity finding in four reviews: a live Vercel token and GitHub App
private-key paths were printed into an agent session transcript on 2026-09-16, the incident remains
open and unrotated six days later, and the redaction machinery that should catch a recurrence
structurally cannot for that class of secret — that is the single most important thing to act on.
Beyond it, a clear secondary pattern emerged: detection has genuinely improved in several places
(memory-cgroup verdicts, mirror-lock wedges) while remediation hasn't kept pace, and the codebase's
long-standing decomposition debt was just reproduced wholesale in a brand-new entry point instead
of avoided.

## Contents

| Document | What it contains |
|---|---|
| [Summary](01-summary.md) | What the project is, its overall health, headline strengths and risks, and this review's scope and method. |
| [Findings](02-findings.md) | All 46 findings by dimension (37 substantive, 9 resolved this round): 0 critical, 1 high, 15 medium, 21 low. |
| [Recommendations](03-recommendations.md) | 20 prioritised recommendations, each mapped to the finding(s) it addresses and to a tracking GitHub issue. |
| [Improvement prompts](04-improvement-prompts.md) | One self-contained, ready-to-paste AI-agent prompt per recommendation, in priority order. |
| [Tech debt filed](https://github.com/Pullwright/agent-ops/issues?q=label%3Apw%3A%3Atype%3Atech-debt) | 7 new issues filed this run (agent-ops#1752–#1758); the remaining 13 recommendations map onto issues already open from prior reviews, cited rather than duplicated. No existing tech-debt register item was found resolved this run (agent-ops has no per-item register — `tech-debt/` is a frozen historical archive; see `TECH-DEBT.md`). |

## Scope note

This review was conducted against a fresh clone on `main`, treating the 2026-09-05 review
(revision `916a951`, 180 commits earlier) as a verified baseline: every prior finding was
re-verified with fresh evidence rather than assumed carried-forward. The 13 checklist dimensions
were delegated to six parallel subagents, each tasked with re-verifying every prior finding *and*
hunting for new findings from the intervening commits and from deeper sampling. See
[Summary § Scope and method](01-summary.md#scope-and-method) for exactly what was read in full,
what was sampled, and what could not be run in this environment (notably: the Dockerized test
suite, and an automated accessibility checker).
