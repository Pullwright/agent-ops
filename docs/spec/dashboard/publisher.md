## The Publisher (`scripts/publish-dashboard.sh`)

Reads the state above, assembles one JSON object, embeds this tick's own
`fingerprint` in it (below), redacts the whole thing, and writes it as
`window.DASHBOARD_DATA = {…}` to `data.js` (atomically: temp file + `mv`),
then writes `window.DASHBOARD_STAMP = {generated_at, fingerprint}` the same
way to a `stamp.js` sibling, carrying that identical fingerprint value — the
no-op skip's own (below), so client and skip logic never disagree about what
"changed" means. Falls back to `$now_iso`, unique to this tick, whenever
`local_state_fingerprint` could not produce a whole hash, or whenever this
tick's own cycle render failed: either failure would otherwise read as
"unchanged" to every open tab forever. Both writes happen back to back, with
nothing state-changing between them, so the two files' own content can never
disagree about which publish they came from — but a *reader* fetching them as
two separate HTTP requests is not part of that atomicity, and can still
observe them from two different publishes (a publish landing between the
requests). That only matters for the plain `<script src>` pair `index.html`
loads on first open, not for the SPA refresh tick, which always re-fetches
`data.js` itself once its fingerprint has moved — see "the client" below for
how the first load avoids the same wedge by reading its starting fingerprint
back out of `data.js` rather than out of `stamp.js`. It is `set -uo pipefail`
(not `-e`) because most reads are best-effort, and ends `exit 0`. It sets its
own `PATH` for cron and is `shellcheck`-clean.
Several measures keep a *rebuild* proportional to the window rather than to
the whole history: the
transcript cost scan reads envelopes in batches (one `jq` per 25 files, the
cycle's day and instant both derived from `input_filename` — the cycle/review
id's own `YYYYMMDDTHHMMSSZ-…` prefix reformatted to a plain ISO 8601 `ts`,
`null` for a directory name that doesn't match it rather than a guessed one;
a torn mid-write envelope costs at most the rest of its batch for one tick),
the detail window (the `MAX_CYCLES`
cycles shown with transcripts) is assembled in a single `jq` program over
every stage file the window touches — handed in via `--rawfile`, so jq opens
each one itself rather than a fork per cycle re-reading and re-parsing it —
plus the events of just the cycles being rebuilt, kept from the fleet-wide
event union as it streams past, and every potentially large intermediate
reaches `jq` as a file, never argv (a single argument caps at 128 KB, which
transcript-bearing JSON exceeds).

The readers of the fleet-wide event union (`$events_jsonl`, and the
`review-log.jsonl` union beside it) fold it as a stream — `jq -n` over
`inputs`, with `reduce`/`foreach` for an aggregate — or keep only the event
types they declare before anything is gathered (`lib/union-stream.sh`,
agent-ops#1649). What a reader holds is what its answer is about:

- **One per-cycle summary entry** (`cycle-summary.json` — a count, the newest
  `ts`, the distinct event types, the overlap count, and the latest
  `repo`/`item`/selection `source` by `ts`, the later record winning a tie).
  The no-op tick classification, the overlap count, the detail cache's key and
  the cost join's cycle index are all read from it. A summary that cannot be
  built fails the detail window's render, since every cache key is taken from
  it.
- **One latest `cycle-start` per node** (the later of two at one `ts`), then
  that cycle's own events, for the per-node live state. A first pass that
  produces nothing is replaced by the empty map and reported on stderr.
- **The newest `MAX_LOG_TAIL` events** for the log tail, kept in a buffer that
  is trimmed back to that many whenever it passes twice that many plus one.
- **The events of the rebuilt cycles** for the detail window. A read that
  fails (a record that is not an object, an unreadable `$order`) fails the
  render — `cycle_render.ok: false` with jq's own error, no cycle rebuilt and
  nothing cached.
- **Only the event types it declares**, for every other roll-up. One streamed
  pass at the start of a full build (`union_partition`) writes one kept file
  per reader — the actor scorecards, the blocked-row enrichment, the landing
  and decision digests, the escape-audit roll-up, the GitHub budget card,
  `open_blocked_items` and `void_items` — each closed by the whole log's span.
  The stage-gap series takes its own stream over the review union, and the
  `lib/` folds the Publisher calls (`rework_panel_build`,
  `node_time_state_fold`, `stage_budget_observations`, `crash_loop_verdict`,
  and `blocked_items`/`void_items`/`draft_obsolete_flags` inside the
  item-lifecycle fold) each gather their declared types in the one `jq`
  process that folds them. `fleet_sizing_contention_by_node` keeps its
  selections and contended claim losses.

A roll-up that reports the whole log's time span (`window_from`/`window_to`
on the scorecards and the stage-gap series, `window` on the item lifecycle
and the fleet-sizing contention) takes it from the span its stream folds
over every event, not from the events it kept. Three readers on this path
gather log-scale data. The item-lifecycle fold gathers every item-scoped
event, because its `records[]` carries each item's whole history as
`instants`; its output is itself log-scale, so the scorecards read a
`{repo, item, fate}` projection of it. Four of the pager's invariants
(`lib/pager-invariants.sh`, on a GitHub tick) gather the union unfiltered.
The stand-down banner's `limit_union_record` reads through
`lib/limit-detect.sh`'s own reader (agent-ops#2037).

`data.js`'s size is dominated by capped transcripts, not by the small
per-item records like `blocked[]`: one cycle at both caps (`TRANSCRIPT_CAP`
of `result` and of `stderr`, on all three stages) measures 245,676 bytes on
its own — `(40000 + 40000) * 3` bytes of capped text plus ~5.7 KB of envelope
and structure — so the `MAX_CYCLES`-cycle window bounds near `40 *
245,676 ≈ 9.4 MB` in the pathological case of every shown cycle maxing out
both caps on every stage (measured directly, not derived from the constants
alone). Against that, `blocked[]`'s `kind` field (added for TD26072603) costs
9 bytes a row when empty (`"kind":""`) and 25 when it is `needs-refinement`
(`"kind":"needs-refinement"`) — measured by publishing a 20-row synthetic
`blocked[]` before and after the field was added (14,910 bytes total, +340
bytes for the field across the 20 rows, half of them `needs-refinement`) — so
even a blocked list two orders of magnitude longer than any fleet has run
stays a rounding error against the transcript budget above. No cap on
`blocked[]`'s length exists or is warranted by this change.
`--no-github` skips the live GitHub fetch for a faster, offline run. Rather
than blanking the GitHub panels, it reuses the last real fetch — cached at
`<state_dir>/.dashboard-github.json` and re-marked `stale` — so the PR list,
work sources and ok/error state all persist, and no false "GitHub unavailable"
banner fires. That is what lets the sub-minute heartbeat refresh local state
every few seconds while hitting the GitHub API only once per window.

`--now <iso8601>` overrides the single instant (`now_iso`/`now_epoch`) every
rolling window in this script measures from — the WI-8 landing digest's
`in_window`/`stale()` cutoffs, the merge-budget reading, the decisions digest,
the GitHub-budget card, and the cost roll-ups' `day_cut`/`today`/`recent_cut`
— the same test seam `scripts/publish-revert-rate.sh` and
`scripts/autonomy-stage-report.sh` already provide. Omitted, it defaults to
the real wall clock; it exists only so a test can pin every window this
script computes to a calendar date it controls, rather than the clock the
test happens to run under.

Those measures bound a rebuild; they do not make one cheap. A full publish
grew from 5.1 s when they were introduced (#51) to 18.1 s by 2026-08-25 —
roughly fifteen dashboard panels later, each legitimately adding a `jq` pass
over the same inputs — against a heartbeat that asks for one every five
seconds. The launcher had no way to tell "publishing every 5 s as designed"
from "publishing continuously and never idle": both look like a full window of
`wrote …` lines, and two idle nodes held two of six cores producing
byte-identical payloads.

So the Publisher has the no-op short-circuit the Co-Ordinator has
(`lib/noop-skip.sh`, requirement 3b), on the same claim: if nothing it reads
has moved since it last published, publishing again buys the same bytes at the
same price. A `--no-github` tick fingerprints every path under the state dir
and the peers dir — plus `config.json`, the page template and the script
itself — and exits without building anything when that fingerprint matches the
one stored beside the last publish. The skipped ticks are counted and reported
by the next real publish (`… after N no-op tick(s)`) rather than logged one by
one.

Two properties make that safe against the stale-page failure `lib/noop-skip.sh`
warns about, where a missed input stalls everything silently. It covers by
exclusion rather than enumeration — everything under the state dir counts
except what the Publisher and its heartbeat write themselves (the served
directory, `dashboard.log*`, and the `.dashboard-fingerprint`,
`.dashboard-skips`, `.dashboard-tick-cost`, `.dashboard-payload`,
`.dashboard-cycle-cache/` and `.dashboard-cyclerows-cache/` bookkeeping
beside it), what the
Publisher never reads (`state-sync.log`, `doctor.log`, `tech-debt-archive.log`, and the `*.err`
sidecars), and the caches a timer rewrites with identical content — so an
input a later panel adds is covered on the day it is added, and the failure
direction of a mistake is a needless rebuild, never a stale page. Those caches
(`fleet-cache/*.json`, `.image-drift-cache.json`, `.doctor-status.json`,
`.dashboard-*.json`) are excluded from the size-and-mtime scan and folded in by
**content hash** instead, so a verdict that actually changed still rebuilds
while one merely rewritten does not. Directory entries are not counted at all:
adding or replacing a file moves its directory's mtime, which would put back
exactly the self-reference these exclusions remove, and a file that appears,
changes or vanishes is already visible as a file. Anything this script writes
under the state dir has to join that list on the day it is added, or it
invalidates the very skip it sits beside. Getting this wrong is not
theoretical — the fingerprint counted its own outputs for a day and a half, so
no tick ever skipped and the feature it was built for saved nothing (#801,
#803). And a GitHub tick never skips, so even a fingerprint wrong in the
dangerous direction can only hold a stale page until the next one, about five
minutes (`LAUNCHER_GITHUB_MAX_AGE`) — the cadence the dashboard published at
before the sub-minute heartbeat existed (#26).

### The tiered publish

Skipping only helps a node with nothing happening on it. A node running a cycle
writes to `state_dir` continuously, so its fingerprint moves on every tick and
it rebuilds every time — which is the node where the cost actually lands. A full
publish measured 15.8s on `ockham-container`, and against the launcher's 1:9
duty cycle that put the page about two and a half minutes behind the pipeline it
exists to show.

So a tick has two kinds, and `--fast` chooses:

- A **full build** assembles the whole payload, and writes it to
  `<state_dir>/.dashboard-payload` afterwards. Every GitHub tick is a full
  build, which is what bounds how stale anything carried forward can be — no
  separate clock, and nothing that can drift out of step with the one cadence
  guaranteed to run.
- A **fast build** recomputes only what moves between ticks — `status`,
  `cycles`, `log_tail`, `cron_tail`, `fleet`, `revert_rate`, `log_repair` —
  and merges those keys over the last full payload. The history roll-ups
  (`counts` and its actor-scorecard and classifier-escape enrichments,
  `blocked`, `void`, `landings`, `github_budget`, `rework`, `constraint`,
  `fleet_sizing`, `spend_fate`, `turns_per_landed_item`, and
  the stage budgets inside `config`) are not computed at all: they read the
  fleet's whole history and change on the scale of cycles, not ticks.
  `constraint` is the one whose skipping is worth its own sentence: it is what
  needs a *second* fleet-wide log union (`review-log.jsonl` beside
  `log.jsonl`), so computing it on a fast tick would double that read on the
  per-tick path for a value the fast payload does not carry. `fleet_sizing`
  reads the node time-state account that union produces rather than fetching
  it again, so it is gated for the same reason at no further cost. The stage
  budgets read that same union a second time (issue #1586, so that
  `config.stage_backstops` can carry a `project-reviewer` entry) rather than
  fetching it again, so this stays a single extra read shared by two
  roll-ups, not two.

A fast build emits only the keys it recomputed and merges them **over** the
cached payload rather than assembling a whole object from variables the skipped
regions never set. That direction is the safety property: a key it forgets keeps
its previous value, where a key a full-style assemble forgot would render `null`
and blank a panel. Staleness is bounded and visible against `generated_at`; a
blanked panel is neither. A fast build with no usable payload cache is silently
a full build, and a merge that fails re-runs itself in full rather than leaving
the page to age.

The cycle window is cached per cycle under `<state_dir>/.dashboard-cycle-cache/`,
keyed on that cycle's stage files (size and mtime), how far its own events have
got (count and newest timestamp), and a digest of the program that renders it —
so an image roll invalidates every entry, which is the case a key made only of
inputs would miss. A cycle that renders to nothing caches that verdict too, or
it is recomputed on every tick for as long as it stays in the window. The cache
is pruned to the window on each publish: entries are never touched on a hit, so
an mtime sweep would evict exactly the cycles still in use.

The window itself — which `MAX_CYCLES` ids the cache above even gets asked to
render — is cached too, under `<state_dir>/.dashboard-cyclerows-cache/`
(#993). Without it, every tick re-globs the local and every peer's `cycles/`
directory (bounded by `state_local_cycles_retained`, 1000 on every node) to
produce a list bounded by the constant `MAX_CYCLES`, however few of those
1000 entries actually moved since the last tick. The key is a stat, not a
content hash: the local and each peer's `cycles/` directory mtime, at
nanosecond resolution (which moves exactly when an entry is added or removed
— the same signal a cache entry's own key uses for a stage file, never
reused here as a *liveness* signal, which is the distinct use #803's cache
key confused; nanosecond rather than whole-second resolution because the
union log below is already protected against a same-second change by its
own size field, but a `cycles/` directory has only its mtime to catch one),
plus the union event log's own size and mtime (covers the ids known only
from the event stream). The key is stat'd before the union log is read and
built, not after: reading it first would let a log append or directory
change that lands in the gap between the read and the stat get baked into a
key that still matched the stale cache, serving rows missing whatever just
landed until some later, unrelated tick moved the key. A tick whose key is
unchanged copies the cached row list straight into place, falling through to
a rebuild if the copy itself fails rather than publishing an empty window; a
tick whose key moved rebuilds the row list and refreshes the cache —
but the key file is written only once the rebuilt rows have themselves
been copied into the cache, never independently: a rebuild whose own rows
copy fails removes both cache files instead of leaving a key that vouches
for rows it never persisted, so the next tick's key comparison misses and
rebuilds from a fresh glob rather than serving the stale or partial rows a
lone surviving key would otherwise keep vouching for.

That render **excludes events belonging to no cycle before it groups the union
by `.cycle`**, and reports its own success or failure as `cycle_render`. Both
halves are load-bearing. The union carries records no cycle produced —
`scripts/publish-revert-rate.sh` stamps its post-merge-revert `rework` rows
`cycle: null` deliberately, since they are mined outside any cycle and an
invented id would be a worse answer than an honest null, and `log-repaired`
does likewise — and grouping those into a bucket keyed `null` is a hard `jq`
error, not a null row: it kills the program that renders *every* cycle in the
window at once. The cache then drains as the window slides over cycles that
were never rendered, so a fault of any duration ends in the same place, an
empty `cycles[]`. Because that is also what an idle fleet produces, the failure
has to be stated rather than inferred: `jq`'s first error line goes to the
Publisher's log **and** into `cycle_render.error`, and the publish otherwise
completes, since one broken panel must not cost the other twenty. A tick that
rebuilt nothing — every cycle already cached — is `ok`, which is the common
case and not a failure.

A failed render also **withholds the state fingerprint** the next tick's
no-op skip reads. That stamp asserts "this page is what that state renders
to", which a died render makes false; leaving it would let the skip hold the
broken window in place until some unrelated part of the state moved, which on
a quiet node is unbounded. Dropping it costs one rebuild and puts the retry on
the next tick, so a transient fault heals itself with nothing else changing.
The cache sweep is *not* conditioned on the render: it prunes to the window,
which is correct whatever the render did.

Measured on `ockham-container` (35,574 union events, 1000 local cycles, three
peers): a full build 15.8s → 11.1s, and a fast build 4.4s — which at 1:9 puts a
cycle's progress on the page inside about 45 seconds, against two and a half
minutes before. The `cycles` payload is byte-identical to the unbatched build's.

Redaction is unconditional: `/home/<user>` and `/Users/<user>` → `~`, and
`ghp_/gho_/github_pat_/sk-…/Bearer …` token shapes → `[REDACTED-TOKEN]`,
applied to the whole serialised payload before writing. The pattern set
itself is `lib/redact.sh`, shared with `scripts/state-sync.sh`, which
applies the identical pass to what it pushes to the private state-mirror
repository (`docs/spec/implementation/requirements` requirement 2.5,
agent-ops#966) — one place to add a pattern for a new secret shape, rather
than two. A bearer secret carried in a webhook URL's own path (the
configured `notify_webhook_url`/`escalation_webhook_url`) has no such shape,
so the Publisher registers that resolved value for masking
(`redact_add_literal`, `lib/redact.sh`, agent-ops#1721) right after it
resolves it, before this pass runs — the same registration
`scripts/state-sync.sh` makes for its own push. A value containing a
newline registers as a no-op instead (a single `sed` rule cannot span one),
so the Publisher checks the same condition itself immediately before the
call and warns on stderr when it holds (agent-ops#1730) — the run still
succeeds and the existing token-shape redaction is unaffected, but the value
itself reaches the payload unmasked, and this is the one operator-visible
signal that happened.

The `DASHBOARD_DATA` shape (the contract the page renders):

```
{ generated_at, max_open_agent_prs,
  node,                                // which node's Publisher wrote this page
  config:  { models, timeouts, pr_label, branch_prefix, repos, … },
  status:  { running, lock:{pid,started_at,alive},          // THIS node's lock
             current:{stage,repo,item,source,title},
             last_cycle:{id,node,ended_at,outcome,repo,item,title},  // the FLEET's newest FINISHED
             limit:{active,note}, switch:{…},
             doctor:{timestamp,verdict,fails[],warns[],skips,
                     token_expiry:{expires_at,days_remaining} | null} | null,
                                    //   THIS node's most recent hourly
                                    //   `doctor.sh --unattended` pass
                                    //   (agent-ops#543), read from
                                    //   state_dir/.doctor-status.json —
                                    //   null until the first hourly pass
                                    //   has run. token_expiry (agent-ops#694)
                                    //   is this node's PAT's own
                                    //   expiry, read from GitHub's
                                    //   `GitHub-Authentication-Token-
                                    //   Expiration` response header; null
                                    //   when that header was absent (an
                                    //   installation token, or any credential
                                    //   GitHub states no expiry for)
             stage_health:{computed_at,threshold,idle_after_hours,
                           stages:{<stage>:{verdict,consecutive_failures,
                                             last_success,last_detail}}} | null,
                                    //   THIS node's most recent per-stage
                                    //   verdict (agent-ops#662), read from
                                    //   state_dir/.stage-health.json —
                                    //   null until this node's first cycle
                                    //   since this check shipped has
                                    //   completed
             review_stage_health:{computed_at,threshold,idle_after_hours,
                           stages:{<stage>:{verdict,consecutive_failures,
                                             last_success,last_detail}}} | null },
                                    //   THIS node's most recent
                                    //   `project-reviewer` verdict
                                    //   (agent-ops#996), the review
                                    //   pipeline's own symmetric shape, read
                                    //   from state_dir/.review-stage-health.json
                                    //   — null until this node's first
                                    //   review-cycle.sh run since this check
                                    //   shipped has completed
  counts:  { cycles_shown, failures_shown, prs_reached_ready,   // fleet-wide
             spend_today_usd, spend_total_usd,
             by_day[], by_model[], by_actor[],   // both pipelines' actors;
                                    //   by_model[].n counts transcripts that
                                    //   touched that model, not transcripts
                                    //   attributed to it — a transcript
                                    //   spending on two models counts under
                                    //   both (issue #536); by_day/by_actor
                                    //   count transcripts, unaffected
             recent_costs[],       // {ts, cost} per row, last 3 days, for the
                                    //   spend-today card's GMT/local/24h toggle
             cost_rows[],           // {day, model, actor, usd, cycle,
                                     //  tokens_input, tokens_output,
                                     //  tokens_cache_creation,
                                     //  tokens_cache_read,
                                     //  repo, item, source, outcome,
                                     //  attributed} per row, one per
                                     //   (transcript × model)
                                     //   touched — each carries that model's
                                     //   own costUSD, not the transcript's
                                     //   whole total_cost_usd (issue #536) —
                                     //   over the whole COST_SCAN_DAYS
                                     //   window, unsummed — backs the
                                     //   model/actor charts' own time-frame
                                     //   selector (issue #334), and the
                                     //   token/prompt-cache panels' own use of
                                     //   the same selector (issue #594, D21).
                                     //   tokens_* are that model's own token
                                     //   counts (docs/METERING-SCHEMA.md) —
                                     //   null together on an `unknown`-model
                                     //   row, never 0, since that row has no
                                     //   per-model breakdown to attribute them
                                     //   to. `cycle` is
                                     //   the transcript's own id, shared by
                                     //   every row it split into — the
                                     //   selector's client-side re-aggregation
                                     //   dedupes on it so a transcript that
                                     //   touched two models still counts once
                                     //   under `by_actor`'s windowed `n`,
                                     //   never twice (issue #536).
                                     //   repo/item/source/outcome (issue
                                     //   #593, D21) are joined onto `cycle`
                                     //   from the same fleet-wide event
                                     //   union `cycles[]` renders from —
                                     //   never rotated (requirement 2.6),
                                     //   retained per
                                     //   `analytics_retained_days` rather
                                     //   than by cycles[]'s own MAX_CYCLES
                                     //   cap (requirement 2.6d) — and
                                     //   populated only when `attributed` is
                                     //   true: a
                                     //   coordinator/implementer/reviewer
                                     //   row whose own cycle has events in
                                     //   that union. Every other row —
                                     //   enabler/refiner/limit-probe (which
                                     //   share their triggering cycle's id
                                     //   but spent on a different item),
                                     //   project-reviewer (whose cycle id
                                     //   never reaches log.jsonl), or a
                                     //   coordinator/implementer/reviewer
                                     //   row whose cycle has no events in
                                     //   the union at all (rare, since the
                                     //   union is never rotated) — carries
                                     //   all four as
                                     //   null and `attributed:false`, never
                                     //   dropping the row itself. See
                                     //   docs/METERING-SCHEMA.md for the
                                     //   field-by-field contract
             actor_scorecards: {    // one card per actor with a model choice
               window_from, window_to, //   (D12), one row per model and tier,
               min_sample,             //   graded on outcome (issue #610, D22)
                                      //   — supersedes `coordinator_verdicts`
                                      //   (issue #319) and the two "model
                                      //   used" pies (issue #529). `min_sample`
                                      //   is `lib/verdict-fate.sh`'s own
                                      //   `MIN_SAMPLE` convention (agent-ops#573).
               actors: [ {
                 actor,               // "coordinator"|"implementer"|"reviewer"
                                      //   |"enabler"|"refiner" — always all
                                      //   five, `rows: []` when a card has
                                      //   nothing to report, never absent
                 rows: [ {
                   model, tier,       // the stratum (D22): Implementer splits
                                      //   trivial/default, Reviewer default/
                                      //   complex, Enabler default/critical
                                      //   (by stage name); the Co-Ordinator
                                      //   and the Refiner have one tier,
                                      //   "default". "unmapped" when a
                                      //   historical model id matches neither
                                      //   of an actor's two *current* tier
                                      //   configs
                   attempts, clean,   // every stage-end for this row (item-
                                      //   carrying or not); `clean` has no
                                      //   `kill_reason` — a fleet-wide crash-
                                      //   loop escalation cannot be pinned to
                                      //   one attempt and is not subtracted
                   items_examined,    // the item-carrying subset only (the
                                      //   Co-Ordinator's and the top-level
                                      //   Enabler's/Refiner's own engagements
                                      //   never carry one — see each actor's
                                      //   own `measure` below instead)
                   landed, landed_unchanged, landed_with_rework,
                   voided, abandoned, other_fate,
                                      // terminal fate (`lib/item-lifecycle.sh`,
                                      //   requirement 49) of the items this
                                      //   row's stage-ends touched;
                                      //   `landed_with_rework` is a landed
                                      //   item carrying a deduped `rework`
                                      //   record (docs/FLOW-SCHEMA.md) whose
                                      //   `attributed_stage` names this row's
                                      //   own actor; `other_fate` sums
                                      //   blocked/open/superseded/unaccounted
                   first_pass_yield,  // landed_unchanged / landed, null only
                                      //   if landed is 0 — computed
                                      //   whatever `sample` is, since a
                                      //   consumer other than the renderer
                                      //   below may want the raw figure
                   cost_per_landed_usd, wallclock_per_landed_ms,
                                      // summed from the landed item's own
                                      //   stage-end(s) `cost_usd`/
                                      //   `duration_ms` (docs/METERING-SCHEMA.md)
                                      //   divided by items landed — not
                                      //   `cost_rows`, which is never
                                      //   `attributed` for the Enabler or the
                                      //   Refiner and would leave those two
                                      //   permanently null
                   sample, status,    // sample = landed+voided+abandoned;
                                      //   status is "insufficient-sample"
                                      //   below `min_sample`, "ok" otherwise
                                      //   — the renderer swaps first_pass_
                                      //   yield/cost/wall-clock above for an
                                      //   "insufficient evidence" badge on
                                      //   this status, D22's "stratify or
                                      //   abstain"; the gate is display-side
                                      //   only, and the payload fields above
                                      //   carry their computed figure either
                                      //   way
                   measure            // this row's own actor-specific
                 } ] } ] },           //   measure, absent for no row (every
                                      //   actor below has one) — see below
                                      // Co-Ordinator: {kind:"coordinator-corroboration",
                                      //   corroborated, rejected, rate,      folds
                                      //   sample, status,                    issue
                                      //   picks_total, picks_landed,         #319's
                                      //   picks_landed_rate, picks_status}   rate in
                                      //   — two rates over two populations, so
                                      //   two gates: `status` is the
                                      //   corroboration rate's (sample =
                                      //   `corroborated`), `picks_status` the
                                      //   picks-landed rate's (sample =
                                      //   `picks_total`), each
                                      //   "insufficient-sample" below
                                      //   `min_sample` on its own count
                                      // Reviewer: {kind:"reviewer-escape-rate",
                                      //   escapes, of, rate, sample, status} —
                                      //   items (not records) carrying a
                                      //   deduped `human-change-request` or
                                      //   `post-merge-revert` rework record
                                      //   against items reviewed;
                                      //   post-merge-revert's own `item` is the
                                      //   reverted pull request's number, re-
                                      //   keyed onto the work item via `pr_url`
                                      //   (`pr-raised`/`pr-ready` carry both)
                                      // Enabler: {kind:"enabler-unblock-success",
                                      //   examined, landed, rate, sample, status}
                                      //   — `examined`/`landed` are this row's
                                      //   own `items_examined`/`landed`
                                      // Refiner: {kind:"refiner-refinement-success",
                                      //   refined, landed, bounced_back, rate,
                                      //   sample, status} — items refined
                                      //   (`item-refined` events with
                                      //   `by:"refiner"`), never stage-end
                                      //   attempts, since the Refiner's own
                                      //   stage-end spans several items
             stage_gaps: {          // the stall profile (issue #594, D21):
               window_from, window_to, //   docs/METERING-SCHEMA.md's own
                                      //   `gaps`, rolled up by stage. Its own
                                      //   window, deliberately not
                                      //   COST_SCAN_DAYS — the source is
                                      //   log.jsonl/review-log.jsonl's
                                      //   retained union (analytics_retained_
                                      //   days), not the transcripts the cost
                                      //   scan walks
               by_stage: [ {
                 stage,               // stage-end's own `stage` (coordinator/
                                      //   implementer/reviewer/enabler/
                                      //   enabler-adjudicate/enabler-decide/
                                      //   refiner), or the literal
                                      //   "project-reviewer" for a
                                      //   review-stage-end row (which carries
                                      //   no `.stage`) — not the same
                                      //   vocabulary as cost_rows[].actor
                 runs,                // stage-ends whose gaps was non-null;
                                      //   gaps:null ("not measured") is
                                      //   excluded, never counted as silent
                 median_of_run_p50,   // nearest-rank median over each run's
                                      //   own gaps.p50 — rendered "across
                                      //   runs," never a pooled percentile
                 worst_run_p95,       // the largest gaps.p95 any one run saw
                                      //   — also "across runs," not pooled
                 worst_run_max        // the longest silence any run saw — a
                                      //   max of maxima, so this one is exact
               } ] }
  cycles:  [ { id, node, started_at, ended_at, outcome, repo, item, source, title,
               pr_url, reason, fail_detail, warning, total_cost_usd, limit_hit,
               raced, race_losses,          // true/count iff the cycle lost a claim
                                             //   to a peer's contention (implementation
                                             //   spec 17a) before its outcome; present
                                             //   whether or not it recovered
               standdown_cause,             // "raced" | "unreachable" | "pre-claimed"
                                             //   | "unauthorized" | "disk-full"
                                             //   | "disk-low"
                                             //   | "untraceable" | null — only on
                                             //   an outcome of "stand-down"
               stages:{ coordinator|implementer|reviewer:
                        { ran, cost_usd, duration_ms, num_turns, is_error,
                          terminal_reason, model, status, result, stderr,
                          limit_hit, limit_text } },
               events[] } ],           // most recent 40 FLEET-WIDE, newest first
                                       //   ids of the cycle shape only — a
                                       //   hand-appended record is not a cycle
                                       //   — and substantive only: no-op
                                       //   ticks aggregate below instead (#271)
  cycle_render: { ok,                  // did the window above actually render?
                  error },             //   false + jq's own first error line
                                       //   when the one program that renders
                                       //   every cycle died, which empties
                                       //   cycles[] outright. The page has no
                                       //   other way to tell that from an idle
                                       //   fleet; absent in a payload written
                                       //   before the key existed
  noop_ticks: { total, standdown, skipped,   // no-op ticks held out of cycles[],
                overlap, last_ts },          //   counted by kind + the newest
                                             //   timestamp — O(1) however many
                                             //   (overlap: 11a's own overrun-
                                             //   slot count, not a no-op —
                                             //   never folded into total)
  blocked: [ { repo, item, ts, detail, stage,           // from the log union,
                                                        //   blocked and not void
               kind,                                    // "" ordinarily, "needs-refinement" for a
                                                         //   refinement block (implementation spec 34e)
               escalation_issue, escalation_url,        // an open ask of the human
               enabler_outcome, enabler_ts } ],         //   … or the last verdict
  void:    [ { repo, item, ts, detail, stage, evidence } ],
  github:  { ok, error, fetched_at, stale,
             prs: [ { …, queued, dequeued } ],  // merge-queue state (D17); see
                                                 //   "Merge-queue awareness" below
             claims[],
             inputs:{<slug>:{issues, failed_runs, findings,
                             issues_total,      // true count behind `issues`'
                                       //   own one-page cap (agent-ops#1171);
                                       //   null when the best-effort Search
                                       //   API read that answers it did not
                                       //   land this tick — never 0 by default
                             tech_debt:[{id,title,status,url}],  // open
                                       //   pw::type:tech-debt issues only;
                                       //   status is always "open"
                             tech_debt_total,   // the Search API's own
                                       //   .total_count behind `tech_debt`'s
                                       //   own top-40 cap — free (returned in
                                       //   the same call as the rows), so
                                       //   always a number when that call
                                       //   answered at all
                             state:{issues, failed_runs, tech_debt, findings}}},
                                       // "answered" | "failed", per source,
                                       //   per repo
             pr_index: { "<owner>/<repo>#<n>":                  // one per
                         { repo, number, title, url, state,     //   number the
                           is_draft, author, labels[], base,    //   page shows
                           created_at, merged_at, closed_at,
                           merge_commit, review_decision,
                           mergeable, checks, cached_at } } },
  fleet:   { nodes:  [ { node, role, heartbeat_ts, heartbeat_age_s,
                         last_cycle, self, stale,       // self first; self's
                                            //   heartbeat_ts/_age_s/stale are
                                            //   read back from the shared
                                            //   state exactly like a peer's
                                            //   (`fleet_publication_status`,
                                            //   agent-ops#602) rather than
                                            //   from this node's own clock —
                                            //   self CAN read stale here
                         version: { pr, commit, short, built_at,
                                    repo, source, dirty },  // null if unknown
                         compose: { status, diff_lines },   // the node's own
                                            //   compose.yaml against its
                                            //   image's copy (#131); null if
                                            //   unreported
                         compose_reconcile: { status, at,   // what that
                                              since,        //   node's own
                                              reason,       //   reconciler did
                                              detail,       //
                                              from, to,     //
                                              pending_apply },
                                            //   about that drift (2.5a):
                                            //   "in-sync", "applying" (a
                                            //   recreate is under way in a
                                            //   sibling container),
                                            //   "reconciled"
                                            //   (carrying both files' SHA-256
                                            //   as `from`/`to`), "deferred"
                                            //   or "refused" (both carrying
                                            //   `reason`, and `detail` where
                                            //   a command's own output is
                                            //   worth keeping); `at` is when
                                            //   the tick wrote it and `since`
                                            //   when the node entered it;
                                            //   `pending_apply` rides every
                                            //   verdict from before the
                                            //   install until a recreate
                                            //   returns;
                                            //   null on a node
                                            //   with no reconciler, which is
                                            //   every node until its owner's
                                            //   one enabling `up -d`
                         image: { status, registry_commit,  // the node's own
                                  registry_created_at },     //   commit against
                                            //   the registry's newest
                                            //   published one (#155); null if
                                            //   unreported
                         switch: { disabled, reason, by,    // the node's OWN
                                    actor, kind, scope, mode, //   disable record
                                    since, expires_at,        //   (#379); `scope`
                                    drain: { remaining,       //   is "node" for a real
                                              at_rest,        //   `--disable --this-node` and
                                              checked_at } }, //   "fleet" for the local mirror a
                                            //   fleet-wide --disable leaves on
                                            //   the node that issued it (2.3);
                                            //   never the fleet flag itself;
                                            //   null if unreported. `mode` is
                                            //   "stop" or "drain" (2.3d); `drain`
                                            //   is present only in drain mode and
                                            //   only once a cycle's own at-rest
                                            //   check matches this record's
                                            //   `since` (2.9) — absent otherwise
                         stage_health: { computed_at, threshold,
                                          idle_after_hours,           // the
                                            //   node's own per-stage verdict
                                            //   (#662), from its heartbeat's
                                            //   own `stage_health` field for
                                            //   a peer, or this node's own
                                            //   .stage-health.json for self;
                                            //   null if unreported
                                          stages: { "<stage>": {
                                            verdict, consecutive_failures,
                                            last_success, last_detail } } },
                         review_stage_health: { computed_at, threshold,
                                          idle_after_hours,           // the
                                            //   node's own `project-reviewer`
                                            //   verdict (#996), the review
                                            //   pipeline's symmetric shape,
                                            //   from its heartbeat's own
                                            //   `review_stage_health` field
                                            //   for a peer, or this node's
                                            //   own .review-stage-health.json
                                            //   for self; null if unreported
                                          stages: { "<stage>": {
                                            verdict, consecutive_failures,
                                            last_success, last_detail } } },
                         mirror: { status, count, last_rebuilt_at },  // the
                                            //   node's own state-sync
                                            //   mirror-rebuild verdict
                                            //   (#604), from its heartbeat's
                                            //   own `mirror` field for a
                                            //   peer, or this node's own
                                            //   .mirror-rebuild-state.json
                                            //   for self; `status` is always
                                            //   "rebuilt" when present; null
                                            //   if this node has never had to
                                            //   rebuild, or is unreported
                         updater: { status, at, seconds, reason, host },  // the
                                            //   worst live watchtower
                                            //   pre-update hook verdict
                                            //   across this node's own
                                            //   ledger and every sibling
                                            //   container's (#603,
                                            //   agent-ops#1037): "rolled",
                                            //   "deferring" or "stuck"; null
                                            //   if unreported or not yet
                                            //   determinable. `reason`
                                            //   ("allow" or "defer") is
                                            //   present only on "stuck",
                                            //   naming which of the two
                                            //   ways it got there. `host`
                                            //   names the sibling ledger the
                                            //   verdict came from; absent
                                            //   when this node's own
                                            //   container's verdict won
                                            //   outright
                         provider_unreachable: { stage, detail, count,
                                          first_ts, last_ts, nodes,
                                          escalate, repo? },      // the
                                            //   transient-refusal
                                            //   verdict (#1073,
                                            //   `crash_loop_verdict`'s own
                                            //   `escalate: false` case), read
                                            //   fresh from the union log every
                                            //   publish and applied to every
                                            //   node its own `nodes` names.
                                            //   `repo` is present iff the run
                                            //   is repository-scoped
                                            //   (agent-ops#1630); only the
                                            //   first such run is published
                                            //   when several repositories are
                                            //   transient at once, which
                                            //   agent-ops#1624 tracks;
                                            //   null when no such run is
                                            //   currently active or this node
                                            //   was not one it named
                         live: { cycle, since, running, ended_at,
                                 stage, repo, item, source, title } } ],
                                            // what THAT node is doing; null
                                            //   until it has run a cycle
             flags:  { disabled, limit,                 // cached fleet flags (2.3a)
                       merge_autonomy_kill: { state, record? } },
                                            // D18 issue #576; {state:"enabled"}
                                            //   when clear
             peers:  { stale, ok, ts, last_ok_ts },      // the peers directory's own
                                            //   freshness marker (implementation
                                            //   spec 2.5/#990), read straight off
                                            //   `<peers_dir>/.last-fetch.json`;
                                            //   `stale` is `fleet_peers_stale`'s
                                            //   own verdict (lib/fleet.sh), the
                                            //   fleet-strip badge's one source of
                                            //   truth; `ok`/`ts`/`last_ok_ts` are
                                            //   the marker's own fields, all null
                                            //   when no fetch has ever run
             claims: [ { repo, key, kind, node, cycle, item, source, ts, sha } ] },
  log_tail:  [ … ],                    // recent events, newest first, fleet-wide
                                       //   minus review-gate-checks-read: pure
                                       //   machine bookkeeping (implementation
                                       //   spec 31c), one per ready-gate
                                       //   evaluation with nothing an operator
                                       //   can act on, which would otherwise
                                       //   displace rows that have something
                                       //   to say — and minus first-seen for
                                       //   the same reason (spec 33), one per
                                       //   item a gather first reports, read
                                       //   only by scripts/pickup-metrics.sh —
                                       //   and minus rework too (spec 33/47,
                                       //   TD-PPagop-26082920), pending the
                                       //   Phase 2 rework panel (#611): no
                                       //   detail to show and no reader yet,
                                       //   provisional rather than permanent
  cron_tail: [ "line", … ] }
```

`github.pr_index` is the record behind every `#number` the page renders — the
open-PR table, the cycle that raised one, the version a node is running. Its
references are gathered from the page itself (each shown cycle's `pr_url`, each
node's reported version), so it holds exactly what is on screen and cannot grow
past it. Entries for open pull requests come free with the label query above;
the rest cost one `gh pr view` each, and a **merged or closed pull request is
never re-read** — its record cannot change, so `<state_dir>/.dashboard-prs.json`
caches it permanently and a warm index costs nothing per tick. Only entries
still open are refreshed, and only hourly. A cold index is filled at most eight
references per tick: forty `gh pr view` calls at up to `GH_TIMEOUT` each would
not fit in the heartbeat's window, and nothing waits on it — an unindexed
number renders as the plain link it has always been.

**Merge-queue awareness** (D17, agent-ops#374/#375): each open pull request in
`github.prs[]` carries `queued` (`true`/`false`/`null` — `null` only when the
probe below has never once answered for it) and `dequeued` (`true` while it is
a state a human should look at). `queued` is `lib/merge-queue.sh`'s
`merge_queue_probe` read directly — the same probe
`scripts/sweep-human-visibility.sh` (requirement 38f) already uses, shared
rather than reimplemented — for every open, **non-draft** pull request the
label query returns; GitHub will not enqueue a draft, so one is never worth
the call, and this needs no miss budget of its own the way `pr_index` and the
tech-debt roster do, because the set probed is exactly this tick's open agent
pull requests, already bounded by `max_open_agent_prs`. `dequeued` is *not*
the probe's own `dequeued_at`/`dequeue_reason` (the last removal event on the
pull request's timeline, regardless of age or of a later re-queue —
agent-ops#394's still-open finding against that reading): it is a small state
machine the Publisher keeps itself, `{queued, warn}` per pull request in
`<state_dir>/.dashboard-queue.json`, rewritten wholesale each GitHub tick from
that tick's own open pull requests (so a merged or closed one simply has no
entry next tick, rather than being pruned by rule). `warn` sets the tick
`queued` is observed to flip from `true` to `false`, stays set on every later
tick that still reads not-queued — a maintainer glancing at the page between
heartbeats must still see it — and clears the moment either `queued` reads
`true` again or the pull request drops out of the open list. A probe that
cannot answer (`merge_queue_probe` failing, same as any other best-effort
GitHub read) carries the last known answer forward unchanged, both the badge
shown this tick and what is written back to the cache, rather than ever
guessing `false` — the one direction that could silently clear a live warning
or falsely raise one — and does not itself trip `github.ok`, the same
treatment `sweep-human-visibility.sh` gives the identical probe. A repository
with no merge queue enabled needs no detection of its own: `isInMergeQueue` is
always `false` and no `RemovedFromMergeQueueEvent` ever fires there, so
`queued`/`dequeued` are always `false` and the open-PR table renders exactly
as it did before this feature existed. The open-PR table (below) shows
`queued` as a **queued** badge distinct from ready/draft/conflicting — "landing
hands-off" — and `dequeued` as an amber warning badge beside the pull
request's ordinary state badge; the same `dequeued` also raises a page-wide
amber banner (`⚠ N open agent PR(s) removed from the merge queue without
merging.`) beside the failing-checks one, so it is visible without opening the
table.

`github.inputs[<slug>].tech_debt` is that repo's open tech-debt issues as
work: one row per open `pw::type:tech-debt`-labelled issue, carrying the
issue's own `title`, a link to it, and `status: "open"` (issue #881; every row
this label search can return is open by construction, so no other status
ever appears). The search that fills it hands back the true count behind its
own 40-row cap in the same call — `.total_count` — so nothing further is
read to know whether the cap has clipped anything, and nothing is cached
between ticks: unlike the frozen register this replaced, a label search
answers every row in one call, so there is no per-tick miss budget to spend
and no per-item metadata to keep warm.

`fleet.claims` is the live claim registry (implementation spec 17a), read on
the GitHub tick and carried between ticks by the same cache as `github` (it
rides in `github.claims`; `fleet.claims` is the surfaced view). One recursive
`git/trees` call enumerates the registry — path and blob SHA per claim — and
each body is then read by SHA from `git/blobs` unless
`<state_dir>/.dashboard-claims.json` already holds it. Since a blob's SHA is a
hash of its bytes, a cache hit cannot be stale, so a fleet whose claims are
not moving costs one API call a tick however many claims it holds. (It was a
`contents/` walk: one call for the claims directory, one per repository under
it and one per claim.) Every node renders the same fleet, so any node's URL
answers "what is the operation doing" — `node` (header: "· <name>") is what
tells two otherwise identical tabs apart.

### Fleet-level invariants (the pager)

`lib/pager.sh`'s registry of fleet-level invariants (implementation spec
requirement 51) is evaluated from inside this script's own `WITH_GITHUB`
block — gated on `WITH_GITHUB` specifically, not merely `FULL`: firing or
clearing an invariant may create or close a GitHub issue, which a
`--no-github` tick (the test suite, or a local-only refresh) must never do.
By the time that block runs, this node's own union log
(`events_jsonl`) and every peer's heartbeat (`fleet_nodes_json`) have
already been assembled earlier in this same run, so `pager_evaluate` reads
both without a second fetch of either. `pager_enabled` (default `true`)
gates the whole call; `false` skips it outright, the same as `--no-github`
does structurally.

One invariant needs a third artefact, which this block therefore assembles
itself: `review-pipeline-failing` (agent-ops#1282) reads the review
pipeline's own log, not the implementation one, so the block runs
`fleet_logs` a second time over `review-log.jsonl` — fleet-replicated like
`log.jsonl`, and excluded from neither — and hands the result to
`pager_evaluate` as `REVIEW_UNION_LOG_FILE`. It is assembled here rather
than alongside `events_jsonl` above because it has exactly one reader, on a
path already gated to `WITH_GITHUB`: an ordinary tick never pays for it.
The block also reads the two config keys agent-ops#1282 added —
`pager_stale_file_after_minutes`, passed to
`pager_register_builtin_invariants` as `node-stale`'s own per-key filing
hysteresis, and `pager_dashboard_fetch_seconds` — along with the raw
(unconverted-to-seconds) `node_stale_after_minutes` and
`updater_stuck_after_minutes` those invariants compare against directly.

Because `pager_evaluate` may itself append `pager-*` transition events to
this node's own `log.jsonl`, the payload's own `pager` array is read from a
*fresh* re-union of the fleet log — `fleet_logs` run again, after
`pager_evaluate` returns — rather than the `events_jsonl` snapshot taken
before it: that snapshot cannot see what this tick itself just wrote. This
is the one place in the script that reads the union log twice in a single
run, and deliberately so.

The `pager` key of the payload (present on a `FULL` build, carried forward
by a fast one on the same terms every other `FULL`-only key already is) is
an array of the invariants currently in the `fired` state:
`{key, first_seen, evidence, nodes, issue_number, issue_url}` — `nodes`,
when the invariant supplied one, is which fleet nodes the evidence names,
for the node-card badge below; `issue_number`/`issue_url` are `null` for a
filing that failed and fell back to `escalation_webhook_notify`'s own
webhook-only path, so a page can still be firing on the dashboard with
nothing to click through to.

