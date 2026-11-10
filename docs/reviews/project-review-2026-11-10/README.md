# Project review — agent-ops

**Date:** 2026-11-10 · **Reviewer:** the project-review skill · **Revision reviewed:**
`e2bae5e5` (`main`)

On its seventh review, agent-ops continues to improve on the metric this series tracks most
closely: four of the prior round's 23 recommendations are now fully delivered (the repository's
largest undecomposed function was split, a Dependabot gap for the base OS image was closed, a
container-image vulnerability scan landed, and a missing pager invariant was added). But the
prior round's #1 priority — a Vercel-credential redaction gap that is the direct sibling of a
real secret-leak incident this project has already had — remains unchanged in code across three
consecutive review cycles spanning 50 days, with no PR ever opened against it. This review adds
a second High-severity item by escalating the severity of `state-sync.sh`'s unbounded `do_push`
steps, the exact mechanism behind a real, already-occurred multi-hour fleet-wide wedge. Closing
both (R-01, R-02) is the single most important thing to act on this round.

## Contents

| Document | What it contains |
|---|---|
| [Summary](01-summary.md) | What the project is, its overall health, headline strengths and risks, and this review's scope and method. |
| [Findings](02-findings.md) | All findings by dimension (32 substantive, plus 4 newly resolved this round and the rest reconfirmed): 0 critical, 2 high, 14 medium, 16 low. |
| [Recommendations](03-recommendations.md) | 20 prioritised recommendations, each mapped to the finding(s) it addresses and to a tracking GitHub issue. |
| [Improvement prompts](04-improvement-prompts.md) | One self-contained, ready-to-paste AI-agent prompt per recommendation, in priority order. |
| [Tech debt filed](https://github.com/Pullwright/agent-ops/issues?q=label%3Apw%3A%3Atype%3Atech-debt) | No new issue filed this round — every finding maps to an issue this review series already filed in a prior round (see `02-findings.md`'s closing note and the recommendations' `Tracked as` column); three stale issues (`#1036`, `#2326`, `#2813`) describing already-resolved work are flagged for the maintainer to close (R-19). No frozen `tech-debt/` register item was found already resolved by this round's sampling. |

## Scope note

This review was conducted against a fresh clone of `main`, treating the 2026-10-27 review
(revision `58b6e42`, 66 commits earlier) as a verified baseline: every prior finding was
re-verified with fresh evidence — code re-read at current line numbers, every cited GitHub
issue/PR re-checked against its *live* current state — rather than assumed carried forward. The
13 checklist dimensions were delegated to five parallel subagents, each tasked with
re-verifying every prior finding *and* hunting for new findings from the intervening commits and
from deeper sampling, followed by this review's own independent spot-checks of the most
consequential claims. See [Summary § Scope and method](01-summary.md#scope-and-method) for
exactly what was read in full, what was sampled, and what could not be run in this environment
(notably: the Dockerized test suite, and live fleet/node access).
