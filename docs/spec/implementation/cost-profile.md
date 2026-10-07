## Cost profile

A worst-case cycle is one small Haiku selection pass, one Sonnet
implementation (the dominant cost), and one review — Sonnet by default, Opus
only when the work graded itself `complexity:high` (requirement 8a), which the
rubric of requirement 26a confines to the minority of PRs whose contents
warrant it; the reviewer `stage-start` events carry the grade, so a creep
toward `high` that would erode this bound is auditable in the log. Stand-down
cycles cost nothing but a few `gh` calls — except under an *estimated*
usage-limit stand-down, where each cycle also spends the 2.1b probe.
That spend is self-limiting from both ends: while the limit is real the
probe's answer is the limit message, which serves no tokens and costs
nothing, and the first answered probe (a fraction of a cent of
`implementer_model_trivial`) retires the stand-down fleet-wide, so at most
one probe per stand-down is ever paid for. Because back-pressure caps open agent PRs
at `max_open_agent_prs`, sustained spend is bounded by the rate at which pull
requests land — a human's own merge click at `merge_autonomy: human` and
`agent-approves`, the arming step (requirement 8d) from `agent-merges-routine`
up — the system cannot run ahead of its only consumer.

The Approver (requirements 8b/8c) costs nothing at the product default
(`merge_autonomy: human`): the stage is never engaged. Where an installation
has raised the level, its own worst case mirrors the Reviewer's — Sonnet by
default, Opus only for `complexity:high` — plus one deterministic,
zero-token `APPROVE` for every `complexity:low` pull request, which the
grading rubric (requirement 26a) already routes the majority of trivial work
through. The Critical tier (`approver_model_critical`, the design's own
Fable/Opus-class default) fires only on a refuse streak of two — a genuine,
persistent disagreement — not per pull request, so its cost is bounded by how
often the Standard/High tiers actually refuse something twice running, which
the design accepts as noise (§5.2).

The floor matters as much as the ceiling, because it is paid on every quiet
day and nothing about it looks like waste. Before requirement 3b, an idle
repository still bought 24 full Co-Ordinator passes a day, each one reading
the configured repositories and concluding, correctly and expensively, that there was nothing to
do (measured: ~2m35s of Haiku per pass against the configured repositories). The no-op
short-circuit replaces those with a handful of `gh` calls and a hash, leaving
one forced pass a day (`none_selected_recheck_hours`) as the safety valve —
roughly a 96% cut in the idle floor, and no change at all to a busy day, where
every cycle has something to fingerprint that moved. A busy day carries a
chaining surcharge instead: finish-then-continue (39) runs each productive
cycle's lineage to `max_chained_cycles` regardless of remaining work — the
gate's "sources remain" half is near-unconditional and the fingerprint just
changed — so up to `max_chained_cycles − 1` further full Co-Ordinator passes
follow every productive cycle. Accepted for the drain rate, and tunable; see
the finish-then-continue design decision.

The Enabler is the one stage that spends a top-tier model, so what bounds it is
worth stating as a number rather than a hope. Nothing is engaged until an item
has survived `enabler_after_coordinator_cycles` selection passes; a claim that is
never released (requirement 35c) means at most one engagement per item per
`claim_ttl_hours` even when everything fails; and an examined item is not looked
at again for `enabler_recheck_hours`. So the ceiling for an item that is
permanently stuck is **one Opus pass every 72 hours**, and every item eligible at
the same moment shares a single pass. In the steady state the cost is therefore
near zero — a fleet with nothing blocked engages nothing at all — and it rises
only when the pipeline is genuinely stuck, which is the one situation in which
paying for a careful answer is obviously worth it. The comparison that matters is
not against an idle cycle but against the alternative: an item needing a human
sat blocked indefinitely, and every cycle in between spent a Co-Ordinator pass
re-reading and re-skipping it.

