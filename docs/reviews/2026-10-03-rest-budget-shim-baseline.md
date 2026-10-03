# REST budget shim before/after — 2026-10-03

#1084's last "done when" bullet asked for "before/after REST spend and
refusal count measured on fleet and posted to this issue", deferred to
#1117 because it needed the shim running on the fleet, not just merged.
#1115 (the `gh` transport shim) merged 2026-08-31T11:57:49Z; this is that
measurement, taken once the fleet's own logs showed the shim active for
more than a day.

Both windows are read fleet-wide (every node's `state_dir/log.jsonl`, this
node's own plus its three peers') with `scripts/github-budget-report.sh`.
The full output of each run is alongside this file:
[`2026-10-03-rest-budget-shim-baseline-pre.md`](2026-10-03-rest-budget-shim-baseline-pre.md),
[`2026-10-03-rest-budget-shim-baseline-post.md`](2026-10-03-rest-budget-shim-baseline-post.md).

- **Pre-shim window:** 2026-08-30T10:03:05Z–2026-08-31T11:58:01Z (the 26
  hours immediately before #1115 merged — the same window the script's own
  header cites as the fleet's REST-budget crisis period that motivated
  #1084 in the first place).
- **Post-shim window:** 2026-10-02T00:08:55Z–2026-10-03T02:58:52Z (the most
  recent ~27 hours as of this run — bounded by the shim ledger's own log
  rotation, which keeps only its last four ~5-hour segments, so no earlier
  ledger data survives to measure against).

## Before/after

| | Pre-shim | Post-shim |
|---|---:|---:|
| Window | 26.0h | 26.8h |
| Cycles with a budget record | 245 | 55 |
| REST core spend/cycle (median) | 509 | 46 |
| REST core spend/cycle (mean) | 598.7 | 114.5 |
| GraphQL spend/cycle (median) | 157 | 49 |
| Refusals reaching `guard-degraded` | 61 (56.5/day) | 0 (0/day) |
| Requirement-2.0 stand-downs | 15 | 0 |

The REST core spend a cycle needs fell by about 91% at the median (509 →
46). Refusals, the figure #1084 most cared about, went from averaging
close to one every half hour to none at all in the post-shim window.

Total core spend across all cycles also fell sharply (146,687 → 6,299, or
about 96% normalized per day), but cycle cadence changed over the same
five-week gap (245 cycles in the pre window vs. 55 in the post window), so
that total conflates the shim's effect with whatever else moved fleet
throughput in between. The per-cycle median and the refusal count, neither
of which depends on how many cycles ran, are the cleaner read of what the
shim itself did.

## The shim's own ledger, post-shim window

| calls | hit | miss | stale | bypass |
|---:|---:|---:|---:|---:|
| 29353 | 6314 (21.5%) | 12437 (42.4%) | 0 (0%) | 10602 (36.1%) |

`miss` dominates the breakdown — the largest of the four outcomes, ahead of
`bypass` and `hit`. Per #1084/#1117's own framing, the likely reason is
#1114: `--paginate`/`--slurp` reads are never sent conditionally, so every
one of them can only ever land as `miss` or `stale`, never `hit`. `stale`
being zero in this window is consistent with the zero refusals above — the
fleet never needed to degrade through a stale read because it never hit a
refusal to degrade from.
