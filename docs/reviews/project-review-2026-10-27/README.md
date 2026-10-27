# Project review — agent-ops

**Date:** 2026-10-27 · **Reviewer:** the project-review skill · **Revision reviewed:** `58b6e42` (`main`)

On its sixth review, agent-ops is healthier than any prior round on the metric that matters most:
the prior review's headline risk — a live secret printed into a transcript — was rotated within
days and structurally prevented from recurring by a new credential-isolation boundary (#2206). But
the direct sibling of that incident, a redaction gap for one specific credential class, is still
open 36 days after being scoped, and this review's own methodology correction — the repository's
real open-issue backlog is 581, not the ~30 every prior review's `gh issue list` default page
suggested — means both this and every project review before it understated how much is actually
queued. Closing the redaction gap (R-01) is the single most important thing to act on this round.

## Contents

| Document | What it contains |
|---|---|
| [Summary](01-summary.md) | What the project is, its overall health, headline strengths and risks, and this review's scope and method. |
| [Findings](02-findings.md) | All findings by dimension (38 substantive, plus 13 fully and several partially resolved this round): 0 critical, 1 high, 19 medium, 17 low. |
| [Recommendations](03-recommendations.md) | 23 prioritised recommendations, each mapped to the finding(s) it addresses and to a tracking GitHub issue. |
| [Improvement prompts](04-improvement-prompts.md) | One self-contained, ready-to-paste AI-agent prompt per recommendation, in priority order. |
| [Tech debt filed](https://github.com/Pullwright/agent-ops/issues?q=label%3Apw%3A%3Atype%3Atech-debt) | 6 new issues filed this run (agent-ops#2694–#2699); the remaining 17 recommendations map onto issues already open from prior reviews or this installation's own standing-decision record, cited rather than duplicated. No frozen `tech-debt/` register item was found already resolved by this round's sampling. |

## Scope note

This review was conducted against a fresh clone of `main`, treating the 2026-09-28 review
(revision `069e94b`, 202 commits earlier) as a verified baseline: every prior finding was
re-verified with fresh evidence — code re-read, every cited GitHub issue/PR re-checked against its
*live* current state — rather than assumed carried-forward. The 13 checklist dimensions were
delegated to five parallel subagents, each tasked with re-verifying every prior finding *and*
hunting for new findings from the intervening commits and from deeper sampling. See
[Summary § Scope and method](01-summary.md#scope-and-method) for exactly what was read in full,
what was sampled, and what could not be run in this environment (notably: the Dockerized test
suite, and live fleet/node access).
