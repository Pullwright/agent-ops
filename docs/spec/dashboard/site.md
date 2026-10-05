## The Site (`dashboard/index.html`)

One self-contained file: inline CSS + vanilla JS, no framework, no build step,
no external network requests (works fully offline). Renders from
`window.DASHBOARD_DATA`; every panel handles missing data gracefully.
Theme-aware (light/dark via `prefers-color-scheme`); wide tables scroll
inside their own container. Refreshes in place rather than reloading: on a
configurable interval (`config.json`'s `dashboard_refresh_seconds`, default
5s) it injects a cache-busted `<script>` — not `fetch()`, so it keeps working
from a `file://` URL with no server or CORS — fetching `stamp.js` (a few dozen
bytes: `{generated_at, fingerprint}`) first, and `data.js` itself only when
`stamp.js`'s `fingerprint` no longer matches the one the page last loaded
(issue #1288: every open tab was re-downloading the multi-megabyte `data.js`
on every tick, unconditionally, regardless of whether the underlying data had
moved). A refresh tick's own `data.js` fetch failing (a lost connection: the
injected `<script>`'s `onerror` fires) leaves the page's last-loaded
fingerprint unmoved, so the very next tick sees its stamp still disagree and
retries — advancing it regardless, on a fetch that never actually landed,
would wedge the tab on stale data indefinitely, since every later tick would
then find its own fresher stamp "agree" with a fingerprint the tab never
actually applied. It re-renders the body **only when the data actually
changed** (a signature compare that ignores the always-moving `generated_at`);
the header's own staleness clock still ticks every refresh, from `stamp.js`'s
own `generated_at`, whether or not `data.js` was worth re-fetching. Expanded
cycle rows, opened void rows and a void list showing past its cap, open
transcript panels and scroll position survive the re-render — both the page's
own scroll position and, independently, the position scrolled to within any
transcript box (a stage's status/result/stderr, or the cron.log tail): each
such box carries a stable key across rebuilds so a reader mid-scroll through a
long transcript is not dropped back to its top by the next refresh; the
header's staleness clock ticks every interval and warns if the heartbeat looks
stopped.

The page's very first load — a plain `<script src>` pair in `<head>`, not the
refresh tick's cache-busted injection — fetches `data.js` and `stamp.js` as
two separate, uncoordinated HTTP requests, so a publish landing between them
can pair a *newer* stamp with the `data.js` the tab actually has (the
Publisher's own back-to-back writes only make the two files agree with each
other, not with what a reader fetches when — see the Publisher section
above). `index.html` sidesteps this rather than relying on that window being
narrow: `data.js` carries the Publisher's fingerprint embedded in its own
JSON, and the page's starting comparison value is read from there, not from
`stamp.js`, so it is always exactly the fingerprint of the data the tab
actually parsed on load, however stale that publish might already be by the
time `stamp.js` answers. Only the initial load needs this — every later tick
already re-fetches `data.js` itself the moment its fingerprint moves, so it
can never fall behind its own stamp.

The header carries **two** clocks, because the page has two ages: `data <age>`
from `generated_at`, which moves every few seconds, and `· GitHub <age>` from
`github.fetched_at`, which moves once per heartbeat window. Everything sourced
from GitHub — PRs, checks, issues, work sources, claims — is as old as the
second clock however recent the first is, and the design that makes that so
(a `--no-github` tick carrying the last fetch forward rather than blanking the
panels) is exactly what would otherwise hide a stalled fetch: half-hour-old PR
data renders identically to fresh. Past 12 minutes the GitHub clock turns
amber and a banner names the fetch time. That banner is distinct from the
`ok === false` one: this is a fetch that stopped happening, that one is a
fetch that ran and failed.

### The status header and live panels

Panels: status header ("· <node>" naming the page's own node, then the live
state — on a single-node page that node's own running/idle plus the stage,
repo, work source and item it is working on; on a fleet page a **summary**:
how many of how many nodes are running, who and in which repo while that is
still a glance (three or fewer), and badges counting any nodes that look dead
or whose state has gone stale) + a static **documentation nav** (`Docs:`
followed by six links — README, the three pipeline specs, the metering
schema, the roadmap — each opening the file at `blob/main/<path>` on GitHub
in a new tab; no data behind it, so it renders identically on every load) +
disabled / fleet-switch / merge-autonomy-kill-switch / usage-limit
/ fleet-limit / failing-checks / dequeued-pr / gh-down / node-stale /
doctor-fail / doctor-warn / stage-health-failing banners
(the switch first: when it is set, every other quiet signal on the page
is a consequence of it rather than news, and an operator reading them in the
other order goes looking for a fault that isn't there);
**the fleet strip** — one card per node carrying that node's own live state
(name, role — with a **disabled** badge beside it when that node carries its
own node-scoped disable (#379), naming the reason and expiry — running/idle,
the stage, repo, work source and item in flight and
since when — or, when idle, when its last cycle ended and how it went — the
**version it is running** as `image #<pr> <short-sha> · built <age>` with the
pull request carrying its record card, a grey `behind` marker when the fleet
holds a newer build and an amber `modified` one on a checkout with uncommitted
work, and how
fresh that answer is: read live for our own row, "as of its last push" for a
peer — or "no publication seen yet" for a peer nothing has ever been read back
for, `fleet_publication_status`'s `unknown` being a different claim from an
aged publication and never worded as one); a red **N stage(s) failing** badge (agent-ops#662) beside the
running/idle state, independent of it — the whole point being a node whose
process is alive and whose cycles are completing, which reads as plain
"running" or "idle", while one or more stages have failed every attempt for
`threshold` cycles running (see the Stage health section below for which,
and since when); any stale node — self included (agent-ops#602) — bordered
red; a stale *peer* additionally reports its running/idle state as "state
unknown", since only a peer's own liveness claim depends on a heartbeat that
can go stale — self's is read straight from its own lock and log regardless
of its publication verdict; one amber **peer view stale** badge across the
whole strip, not per card, when `fleet.peers.stale` is set (implementation
spec 2.5/#990) — a frozen or dead fetch cron makes every peer card go stale
at once, and this badge is what says the cause is "this node cannot see the
fleet" rather than "the fleet is down"; reads *"peer view stale — last
successful fetch `<last_ok_ts>`, failing since `<ts>`"* for `ok: false`, or
*"peer view stale — fetch not running since `<ts>`"* for a stale `ok: true`;
self is definitionally fresh and unaffected, and nothing renders once the
marker is fresh or for a node that has never fetched; click a card to
filter the cycle list and the recent log to that node, click again to clear —
the filter survives refreshes like every other UI state; **live claims** — the
registry rows, i.e. work no other node will pick up. Both, plus the cycles
table's Node column,
appear only once the fleet has more than one node (or a claim exists): a
single-node page renders exactly as it always did.

The live-claims panel's own **Held** column reads a row's `ts` through the same
relative-time renderer as the rest of the page, with one exception: a claim
whose `ts` is the fixed sentinel `lib/claim.sh`'s `do_expire()` backdates a
discarded Enabler/Refiner tombstone to (`1970-01-01T00:00:01Z`, implementation
spec 35c) never renders that literal ~56-year age. The panel recognises the
sentinel and reads the row "expired — pending cleanup" instead (agent-ops#839)
— the claim is correctly marked for `gc`'s next TTL sweep, and the column says
so rather than a number that was never a real age.

The strip is rebuilt on every refresh tick alongside the header, not only when
the body re-renders, because its cards carry running clocks ("since 18m ago")
and the body deliberately sits still while the data is unchanged.
Then metric cards (spend today/total — fleet-wide, one shared account —
failures, reached-ready, back-pressure gauge vs `max_open_agent_prs`. The
gauge's own figure is the same four-part sum `agent-cycle.sh` trips its cap
on (requirement 2.2) — draft PRs, ready PRs still `CHANGES_REQUESTED`, and
live claims — rather
than a figure the page derives from the open-PR listing alone: a live claim
is work already in flight whose PR does not exist yet, so it cannot appear
there. For a repository configured at `agent-merges-routine` or above, the
card additionally narrows the human-queue exclusion to an **otherwise-
eligible** ready pull request (D18 WI-6, issue #946), mirroring requirement
2.2's own level-aware paragraph: a ready, non-`CHANGES_REQUESTED` pull
request whose `complexity:*` label is outside that repository's
`merge_autonomy_routine_complexity` list stays in the human queue, since
nothing downstream of the Approver will ever land it automatically. A
`CHANGES_REQUESTED` pull request is exempt from the narrowing at every
level, exactly as it is in requirement 2.2 — the pipeline still owes it a
change — so the card can never hold fewer pull requests against the cap
than the plain rule would. This reads the repository's
*configured* `merge_autonomy` level (`D.config`) combined with the
fleet-wide kill switch the page already fetches for the banner above — never
the live effective level, which also needs a per-repository merge-budget-
freeze read the Publisher does not make on every tick — and complexity
alone, never a pull request's originating source, which carries no field on
GitHub and is not data this page holds. Which registry rows those are is `claim.sh count`'s rule, transcribed
rather than re-derived — a card reporting a different figure from the gate it
depicts is worse than no card — and it excludes two kinds of row. Rows under a
**pseudo-slug** (`enabler`, `refiner`) are the Enabler's and Refiner's
engagement tombstones: never released, retired only by `claim.sh gc`, and
never seen by the cycle, which asks `claim.sh count` for one configured repo
at a time. The page reads the whole registry in one tree call, so it must
re-impose that scope itself or the gauge climbs with every item the Enabler
examines and pins red against an open gate. Rows **naming a pull request
already in the sum** are that PR a second time: the `pr-<n>` exclusion entry
always, and a `pr-<n>-<kind>-<scope>` item ref when its PR is among the drafts
or pipeline-owed PRs counted above — but not when that PR sits in the
human's queue (conflicted, dequeued), where the claim is the only record the
work is in flight. The card's `title` tooltip spells out the same split the cycle logs,
e.g. "1 pipeline-owed + 0 draft + 1 unraised claim(s) — plus 13 waiting
on human (14 raw)", with a line underneath naming the raw open-PR total and,
when it differs, how many of those are sitting only in a human's queue
(approved, or awaiting a review nothing is
`CHANGES_REQUESTED`-blocking): a full human queue reads as "waiting on
human", not as the pipeline sitting idle). The spend-today card's own word
"today" is a button:
clicking it cycles the card's label and figure through **today (GMT)** (the
Publisher's own `spend_today_usd`), **today (local)** and **last 24h** (both
computed here, from `counts.recent_costs`, against the reader's own clock and
zone — the one thing about "today" the Publisher itself cannot know). The
choice is written to `localStorage` (`dashboard.spendMode`) as it is made and
read back on every load, so it survives a real reload and not just the
in-place refresh the rest of this section describes — the first state on this
page to do so — and an unset or unrecognised stored value reads as the GMT
default rather than an error; open PRs (a **queued** badge in place of ready for
one currently in a merge queue, and an amber **dequeued** badge beside a pull
request's state badge for one a queue removed without merging — see
"Merge-queue awareness" above); recent cycles (outcome and work source at
a glance — a cycle that has not logged `cycle-end` shows the state it is in
rather than an outcome it has not reached: **in progress** while a node claims
it as its live cycle (greyed when that node's own report has gone stale,
amber and questioned once it is running past `lock_stale_after`), **no clean
end** when no node is running it, and **not ended** when the data carries no
node state to ask; click a row for per-stage detail with
the parsed status, full transcript, and stderr; beneath the table, one muted
summary line for `noop_ticks` — the count held out of the list, split stood
down / lock-held skips, with how fresh the newest is — shown only when there
are any, plus a second muted line naming any overrun-slot firings
(`noop_ticks.overlap`, implementation spec 11a) — shown whenever there are
any, independently of the first line, since these were never held out of the
list the way a no-op tick's own are — and both only while the list is
unfiltered, since the aggregate is fleet-wide and must not sit under a
single node's rows; a window that is
*all* no-ops reads "No substantive cycles in the fleet window." over that
line, keeping "No cycles recorded yet." for a page with genuinely nothing —
except that a `cycle_render.ok` of `false` outranks both of those and every
node-filtered variant, since the list is then empty for a reason that is not
the fleet's: a red banner names the Publisher's own failure and quotes its
error, because an empty list that is silently attributed to an idle fleet is
how the 2026-08-29 blackout went ten days unnoticed);
failures,
blocked and void items (the void list newest first — it arrives grouped by
repo and item, which no reader wants — and **capped twice**: the ten newest
rows, each three lines tall, with the rest behind a `See more — N older items`
control at the foot of the table and any row opening to its full text when
clicked, both choices surviving a refresh. The heading counts every void item,
not the rows shown); work sources per repo (including the security and
code-quality findings, shown first, that the Co-Ordinator prioritises, and the
open issues, listed in `Priority` band order with the band on each, which is
the order the Co-Ordinator reaches them in) — the issues and tech-debt counts
read as plain numbers unless their own source cap actually clipped something,
in which case they read "shown of total" instead (`issues_total`/
`tech_debt_total`; see the Publisher and "Design decisions" below);
each repo whose `config.json` entry carries a non-zero `nice` (pipeline spec,
requirement 3) also carries a **badge** naming that value, blue below zero and
grey above, with the weighting it buys — `2^(-nice/3)`, the multiple by which
the Script inflates that repo's staleness age when it orders the repo walk —
and the disclaimer that it biases the walk without starving anything. A note
above the panel says the **Script** is what acts on a `nice`, because the panel
is headed with what the *Co-Ordinator* sees and a `nice` is the one ordering
input it is never given; without that line the badge would assert, on the
page's only per-repo surface, exactly the thing requirement 3 is careful not to
do. A repo at `0` or with no key carries neither badge nor note, so a fleet
that has set no `nice` anywhere renders the panel it rendered before the
feature existed. The values reach the page unaided — `config.repos` already
ships wholesale — so this is rendering only: the Publisher is unchanged;
**Actor and model scorecards** (immediately below the work sources, and
deliberately: that panel is what the Co-Ordinator was handed, this one is how
each actor's model choice did with what it was handed — issue #610, D22);
the cost charts — by-day, by-model, by-actor, then the two cost notes —
flowed through a CSS multi-column layout in that reading order, letting the
browser balance the split by height rather than pinning by-day to a column of
its own, since it runs to sixty rows against five each for by-model/by-actor,
with a **time-frame selector** (issue #334) above the grid — one `<select>`,
labelled as covering the model and actor charts, offering 1/7/30/90
days and the unlabelled lifetime default — that re-aggregates `counts.cost_rows`
client-side on change rather than re-fetching, so all the windowed charts
redraw from the same choice with no round trip; recent log; `cron.log` tail. An
option is disabled whenever its span exceeds how far back `cost_rows` actually
reaches — capped both by the Publisher's own `COST_SCAN_DAYS` truncation and,
on a younger fleet, by how long the pipeline has been running — since selecting
it would otherwise silently show the same figures as a narrower window (or as
Lifetime) without saying so; the Lifetime option itself is never disabled. A
persisted choice the control has since disabled this way (grown stale as
`cost_rows` moved) renders, and aggregates, as Lifetime instead — keeping the
selected `<option>` and the chart it drives in agreement — and reverts to the
persisted choice on its own once the window it names is available again.

Three of the panels above — the fleet-node cards, the cycle rows and the
void-item rows — are keyboard-reachable, not just clickable. Each is a plain
`<div>`/`<tr>` with none of a native control's keyboard behaviour, so each
carries `tabindex="0"`, `role="button"`, and a `keydown` handler firing on
Enter or Space in place of a click — the same activation a `<button>` gets
for free, and the reason the pull-request-reference card below is built on
`<a>` rather than either of these. Each also carries an `aria-label` naming
the action a click-derived affordance alone would not announce: "Filter
cycles and log events to `<node>`" (or "Show every node's cycles and log
events" once that filter is already active) for a fleet card, "Expand detail
for cycle started `<time>`" for a cycle row, "Expand full text for `<item>`"
for a void row. All three show the page's ordinary accent-coloured
`:focus-visible` outline on focus, matching every other focusable control on
the page.

### The GitHub-budget and autonomous-landings panels

The **GitHub API budget** panel (issue #1090) is the first section on the
page, deliberately: it answers the same question requirement 2.0's own gate
asks — is the shared rate-limit bucket about to bind — before the first
`guard-degraded` refusal shows up further down the page, not after. It
spends no `gh` call of its own: it renders `github_budget`, which the
Publisher folds from the fleet-wide `github-budget` events
`lib/github-limit.sh`'s `github_budget_record` logs at cycle start, after
every model stage and at cycle end (requirement 2.0d, agent-ops#1088) — the
same source `scripts/github-budget-report.sh` sums on demand. A full-build-
only roll-up, on `landings`'/`escape_audits`' own precedent ("The tiered
publish" above): it reads the fleet's whole history and is carried forward
unchanged on a fast tick.

`github_budget` is `{readings, latest, per_hour[], floors,
cycle_interval_minutes, about_to_bind, quiet}`:

- `readings` is the count of every `github-budget` event in the fleet-wide
  union, fleet-wide and all-time — never windowed. `0` (with every other
  field null-shaped) is the card's own **empty state**: no such event
  anywhere in the log, rendered as "nothing to report" rather than a blank
  card or an error. This is distinct from `null` (never `0`), which means
  the roll-up itself could not be assembled this tick — the same "outage, not
  a quiet night" distinction `landings`/`escape_audits` already make.
- `latest` is `{ts, core, graphql}` from the newest `readable: true` event by
  its own `ts` — also never windowed, since the point of the "meter gone
  quiet" badge below is noticing a *stale* latest reading, which a 24h window
  would silently drop instead of reporting. `core`/`graphql` are each either
  the pool's own `{limit, used, remaining, reset}` or `null` when that pool's
  read failed on an otherwise-readable event; `null` (with `readings > 0`)
  when no event has ever been readable. The panel renders both pools' used/
  limit/remaining and `reset` as a countdown, plus how long ago the reading
  was taken, followed by the same shared-bucket note the report script's own
  preamble states: while every node authenticates as one user (D25
  unprovisioned) the figures are the *bucket's*, not any one node's.
- `per_hour[]` is `{hour, readings, core_peak_used, refusals,
  budget_standdowns}` per UTC hour (`.ts[0:13]`, matching the report script's
  own `hour` grouping) — trailing 24h only, unlike `latest` above:
  `readings` and `core_peak_used` (the peak `core.used` among that hour's
  *readable* readings) come from the `github-budget` events themselves;
  `refusals` counts `guard-degraded` events matching the report script's own
  `is_refusal` predicate (a `detail` matching `rate limit (already )?exceeded`,
  case-insensitively); `budget_standdowns` counts `stand-down` events
  matching its `is_budget_standdown` predicate (`has("github_resource")`) —
  copied verbatim from `scripts/github-budget-report.sh` so the two can never
  disagree about what counts as either. Rendered as a table, newest hour
  first, the same shape the report script's own "did it bind" table prints.
- `floors` is `{core, graphql}`, copied from `config.json`'s own
  `github_min_core_budget`/`github_min_graphql_budget` (default 300/100) —
  requirement 2.0's own gate floors, read via config defaults rather than a
  value hardcoded here, so the two can never drift apart.
  `cycle_interval_minutes` is `schedule.cycle_interval_minutes` (default 15),
  the cadence source the "meter gone quiet" badge below is measured against.
- **`about_to_bind`** is `null` with no readable reading to judge (`readings
  == 0` or `latest == null`); otherwise `true` when `latest`'s `core` or
  `graphql` remaining is below its configured floor — the identical
  `remaining < floor` comparison `github_limit_verdict` itself makes, so a
  `0` floor (disabled) can never trip it, the same as the gate it mirrors.
  Renders a red **about to bind** badge.
- **`quiet`** is `null` on the empty state (`readings == 0`, nothing to
  judge); otherwise `true` when no *readable* `github-budget` event falls
  within the last two configured cycle intervals of `now` — an unreadable
  meter reads the same as no meter at all. Renders an amber **meter gone
  quiet** badge, distinct from `about_to_bind`'s red one: the two answer
  different questions (the bucket is nearly spent vs. nothing has told this
  page whether it is) and either, both or neither may be true at once.

The **Autonomous landings** panel (D18 WI-8, agent-ops#411) is the
asynchronous audit that D18 accepts unattended merging in exchange for. Risk 6
of `docs/reviews/2026-08-14-autonomy-investigation.md` — "overnight merges with
nobody watching" — is accepted deliberately, and this panel is the named
condition: the queue re-tests, `failed-runs` turns post-merge breakage back
into selectable work, and once a day a human sees everything the Script landed
without them. It is permanent rather than rollout scaffolding, because at
`agent-merges-all` it is the only routine account of what merged.

It renders `landings`, which the Publisher assembles from the fleet-wide event
union (never a private counter, so a landing armed on any node appears on every
node's page): one row per `landing-armed` inside the window — default 24 h,
overridable for tests by `LANDING_DIGEST_WINDOW_HOURS` — carrying when, the
repository, the pull request, its title and state where GitHub was read this
tick, the work source, the complexity it was armed at, the `enqueued`/
`auto-merge` method `landing_arm` actually used, and the node that armed it.

Each row is joined to the **`landing-audit-record` that justified it**
(requirement 8x, D18, agent-ops#578) — the one durable record
`_landing_stage_attempt` assembles and writes at the same moment it arms a
pull request, rather than a fact this panel re-joins from separate events
at report time. The join is by `pr_url` and the arming cycle, earliest
record at or after the arm: `_landing_stage_attempt` writes
`landing-armed` first and `landing-audit-record` second, moments apart
from the same function call, so this never has to reach further than the
earliest match at or after the arm's own timestamp. `landing-armed`
carries no pointer of its own to the record that follows it, so the cycle
every event is stamped with stands in for one: an arm and the record
written by its own call always agree on it, which is what makes a *second*
arm of the same pull request unambiguous — an arm whose record write never
completed reads as unexplained rather than borrowing the record a later
cycle wrote. A landing with no matching record still renders — its own
Record cell reading `missing`, beside (not in place of) the
classifier-escape audit's own column, rather than the tier/verdict cells
quietly reading `unknown` alone — and is called out again in its own
summary line naming how many landings in the window carry no record: an
unexplained landing is the single most important row this panel can carry,
and now that a durable per-landing record exists, "the record could not be
found" and "the record said so" read as different facts, never the same
silent null. A `landing-armed` from before requirement 8x shipped can
never have a matching record — the write it would join to did not yet
exist — so its Record cell stays `missing` permanently; its tier and
verdict still render where locatable, from the older `approver-verdict`
join this panel used before requirement 8x, kept on purely as that
fallback.

Three things it will not hide, each a way a digest could mislead by omission:

- **Refusals**, counted and grouped by reason class over the same window. Two
  landings beside forty refusals is a classifier holding the line; two beside
  none may be a gate that is not running at all. A panel showing only successes
  could not tell those apart, and the second is the one worth waking for. The
  class is the `landing-refused` event's own `class` field (`byReason`,
  `dashboard/index.html`) — one of `lib/landing.sh`'s own
  `_LANDING_REFUSAL_CLASSES` (TD-PPagop-26082823), naming the gate that
  refused (`kill-switch`/`autonomy-level` for gate 1, `ineligible`/`unknown`
  for gate 2's `landing_eligible` and gate 4.5's
  `landing_protected_path_controls_ok` alike, `open-question`/
  `open-question-unreadable`, `review-gate`, and a class per remaining gate:
  `malformed-pr-url`, `approver-login-unreadable`,
  `approver-review-unreadable`, `approver-review-not-approved`,
  `human-veto-unreadable`, `human-changes-requested`,
  `reconciliation-unanswered`, `reconciliation-unreadable`,
  `merge-queue-unreadable`, `merge-queue-occupied`, `dequeued-actionable`,
  `dequeued-manual`, `approver-token-unmintable`, `arm-failed`) — set as a
  literal at every `_landing_refuse` call site in `_landing_stage_attempt`
  and `_landing_open_question_resolve`, never derived from the
  human-readable `reason` string beside it, so a reader grouping on it never
  has to parse prose that might embed varying content of its own (chiefly
  `$pr_url` — itself a `https://…` string carrying its own scheme colon —
  which is exactly what garbled a whole family of sentence-form refusals
  into one-off groups keyed on a URL fragment before this field existed,
  TD-PPagop-26082502). An event logged before this field existed carries no
  `class` key at all, which the Publisher's own `refused` projection — the
  one thing that carries the field off the raw event and into `landings`,
  and so the one place dropping it would silently cost the grouping
  altogether — normalises to `class: null`. `byReason` therefore keys its
  fallback on the *value*, not the key: a `class` that is absent, `null` or
  empty reads the same, and each falls back to that superseded
  text-before-its-first-`:` split — never an event that names a class.
- **The merge budget** (D18 issue #574), per repository: `merge_budget_per_day`'s
  effective cap against consumption, its status (`ok`/`held`/`frozen`), and,
  when held or frozen, the oldest waiting pull request and its age. An
  unlimited repository (`0`) reads as `∞`, never as a cap of zero. Consumption
  is sourced from the same rolling-24h count `lib/merge-budget.sh` itself
  reads, never a private one recomputed here: `landing-armed`,
  `merge-budget-hold` and `merge-budget-frozen` each carry the `cap`/`count`
  `merge_budget_decide` read at that decision, so the single latest of the
  three for a repository — across the whole retained log, not only this
  digest's own window, the same reasoning the audit-record join above
  already uses — is that repository's state **as of that last gate-5
  decision, not a live read**, and of unbounded age: a repository whose backlog is empty, or whose
  candidates all fail eligibility before reaching gate 5, keeps whatever event
  last fired indefinitely — what the row then *reports* from that event is
  bounded by the ageing rule below, but the event itself is never discarded. This is what keeps the freeze's own reason and the
  oldest waiting pull request visible without a live read of the freeze flag
  or `merge_budget_oldest_waiting`: both ride the
  `merge-budget-frozen`/`merge-budget-hold` event that already fires the
  moment `lib/merge-budget.sh` establishes them, rather than a second network
  call this dashboard tick has no business making. A repository this tick has
  never seen a budget decision for falls back to `config.json`'s configured
  cap, reported `ok` with nothing yet consumed — a real absence of data, not a
  claim that nothing has landed. A repository that *has* a recorded decision
  keeps that decision's own `cap` — never re-read from `config.json` — until
  its next gate-5 decision refreshes it, even if an operator edits
  `merge_budget_per_day` for that repository in the meantime: the recorded
  `cap` and `count` are read together, as the coherent pair
  `merge_budget_decide` actually reasoned from, and a superseding-cap edit
  becomes visible only once a fresh decision carries the new value alongside
  a fresh count measured against it. The `cap` outlives that pair: once the
  count beside it ages out of this digest's window (below), the recorded `cap`
  is the one field of a superseded decision the row still carries, so a
  repository whose configured cap has moved since its last gate-5 decision
  keeps reading against the old one until the next decision lands.

  `consumed` for an `ok` row is the count `merge_budget_decide` read *before*
  granting the arm that logged it — the landing the arm itself produced is
  never in it, so a repository that just spent its last permitted landing this
  window reads, for example, 7/8, not 8/8. An unlimited repository never has a
  `count` to read at all: `merge_budget_decide` short-circuits a zero cap
  before counting, so its row instead counts this digest's own `landing-armed`
  events inside the window — the same plain count the `armed`/`refused` rows
  above already give, and what this panel counted before the per-repository
  `budget` block existed. An `ok` row is aged back to unmeasured the same way
  a held row is: once its own event falls outside this digest's window, the
  count it carries has already rolled off the governor's own rolling-24h
  clock, so `consumed` resets to `0` rather than presenting a count that is no
  longer live as though it still were. A held row is aged back to `ok` on the
  identical rule, because a hold is a rolling-24h fact too, and one nothing
  has refreshed for a full window has already rolled off the governor's own
  clock; its `consumed` resets to unmeasured with it — an aged hold's `status`
  and `consumed` read exactly like a repository gate 5 has never reached,
  rather than carrying its stale count forward under a status now claiming to
  be healthy. A frozen row is never aged back this way, because a freeze
  stands until a human clears the fleet flag, not until time passes. Every held or frozen row carries the
  source event's own timestamp so the page can render its age (`held · as of
  2d ago`) rather than presenting a stale decision as current; an `ok` row
  never carries `as_of`, aged back or not, since once its count resets to
  unmeasured its `status`, `consumed` and `as_of` read as a repository gate 5
  has never reached does, which likewise has no age to show. `cap` is the one
  field that still separates the two, and only where the configured cap has
  moved since that aged decision — the persistence rule above.

  A held or frozen repository never renders folded into the plain
  `consumed/cap` text an `ok` repository gets, and never folded into the
  refusals count above either — a budget hold is not an eligibility refusal,
  even though both mean a pull request did not land that cycle. Each earns its
  own row, badged `held` or `frozen`; a `frozen` row also states why, in the
  same words `merge_budget_apply_decision` logged at the moment it froze the
  repository.
- **Its own failure.** A payload the Publisher could not assemble sets `armed`
  to `null` and renders as "could not be assembled this tick", explicitly
  distinguished from a quiet night. An empty array is a real and reportable
  nothing; `null` is an outage, and the two must never render alike.

Each `armed` row also carries the classifier-escape audit's own verdict
(requirement 8e, agent-ops#572) — `audit`, one of `"clean"`, `"escape"`,
`"unverifiable"` or `null` (not yet audited), joined by `pr_url` against the
newest `classifier-escape`/`landing-audit` event for that pull request — and
`audit_reason`, rendered as a badge on the row (green/red/amber respectively)
so a human reading one landing sees, without leaving the row, whether the
Approver's own decision was independently re-checked and what it found.
`null` reads "pending", never folded into a false "clean": a landing this
audit has not reached yet is not the same fact as one it checked and cleared.

Beside the digest, `counts.escape_audits` (requirement 8e) is the audit's own
all-time scoreboard — `checked`/`clean`/`escapes`/`unverifiable`, plus
`escape_list`/`unverifiable_list` naming each one — folded from the same
`classifier-escape`/`landing-audit` events, fleet-wide, but **never windowed**
like the digest above it: an escape is a permanent fact about one merged pull
request, and letting it age out of a 24 h window would recreate the exact
"row nobody reads" the audit exists to prevent. A payload the Publisher could
not assemble sets every field to `null`, the same "outage, not a quiet night"
distinction `armed` above makes.

### The Decisions and Constraint panels

The **Decisions** panel (agent-ops#937) is the same D18 pattern applied to a
decision rather than a landing: `escalation_autonomy: "decide-tactical"`
(agent-ops#936) lets the pipeline take a tactical decision on its own
authority instead of paging the owner, and this panel is the log a human can
scan in one place, alongside the lever they can pull — reopening the closed
`pw::decision` issue `lib/enabler.sh`'s `create_decision_log_issue` files for
every `decide` verdict, which vetoes the decision
(`scripts/sweep-decision-vetoes.sh`, `lib/decision-veto.sh`). It renders
`decisions`, sourced from the fleet-wide event union, never a private log:
one row per `decision-taken` event inside the window — default 7 days,
overridable for tests by `DECISIONS_DIGEST_WINDOW_DAYS` — carrying when it
was taken, the repository, the item, the decision's own text, a link to its
log issue (its own `issue_number`/`issue_url`, present unless filing it
failed, in which case the row still renders, its own cell reading "not
filed" rather than being dropped for want of one), and a status badge:
`vetoed` where a `decision-vetoed` event for the same log issue postdates it,
`pending act` where the decision carries a `decide-with-veto` act
(requirement 36f) that no `decision-acted` event has yet performed or
cancelled — the one status where the lever still changes what happens rather
than only undoing it — and `stands` otherwise. A row's `act_after` is what
the `pending act` badge names as its title, so the owner can see from the
panel alone how long they have. A payload the Publisher could not assemble sets
`decisions` to `null`, rendered as "the decisions digest could not be
assembled this tick", the same outage-not-a-quiet-night distinction `armed`
above makes; an empty window is a real, reportable "no decisions taken",
never confused with it.

The **Constraint** panel (D21, `docs/ROADMAP.md`; issue #609) leads the
page's analytics cluster — everything from here to Scorecards exists to
justify or refute the one sentence this panel states. It renders
`constraint`, assembled by `lib/constraint.sh`'s `constraint_classify` over
the node time-state account `lib/node-time-state.sh`'s `node_time_state_fold`
already produces (issue #597) — never a second fold over raw events, so it
cannot disagree with that account's own arithmetic. A payload the Publisher
could not assemble sets `constraint.sentence` (and every other field) to
`null`, rendered "the constraint statement could not be assembled this
tick", the same outage-not-a-quiet-tick distinction every other roll-up on
this page makes.

**The sentence's own grammar.** One line, always present: `<candidate's own
label> accounted for <share>% of fleet node-time between <window.from> and
<window.to>; <recommendation>`, with a grow-direction candidate's own
sentence additionally stating `(up to <effect_node_seconds>s recoverable
this window, an upper bound)` — the expected effect, in node-seconds, never
in money or a unit of delivered work (D21's own scope bound; `docs/
ROADMAP.md`'s open-questions table still has D21's numerator open). A
shrink-direction candidate's own sentence states the recommendation alone,
with no recoverable figure — shrinking does not recover producing time, it
avoids spending idle time a smaller fleet would not have had.

**The candidate table**, `constraint.candidates`, always exactly six, fixed
order, each `{key, label, evaluable, seconds, share, direction,
recommendation, effect_node_seconds, effect_note, not_evaluable_reason,
depends_on}`:

| Candidate (`key`) | Attributed from | `direction` |
| --- | --- | --- |
| `cron-latency` | `idle_with_demand_by_cause["awaiting-tick"]` | `grow` |
| `back-pressure` | `idle_with_demand_by_cause["back-pressure"]` | `grow` |
| `node-count` | `idle_with_demand_by_cause["peer-claimed"]` + `totals["idle-without-demand"]` | `shrink` |
| `model-capacity` | `externally_blocked_by_cause["usage-limit"]` | `grow` |
| `human-merge-gate` | never evaluable from this account (`#574`) | `null` |
| `pipeline-defect-rate` | never evaluable from this account (`#596`) | `null` |

`node-count` deliberately folds two different time-account signals into one
lever: `peer-claimed` idleness (nodes contending over a shrinking backlog)
and the fleet-wide `idle-without-demand` healthy zero (nothing eligible
anywhere) both read as "more node capacity than there is work for," and both
recommend the same fix — run fewer nodes — so folding them is what lets the
shrink case compete for `leading_candidate` on equal footing with the three
grow-side candidates, rather than being structurally unable to lead the
sentence the way a lone `idle-without-demand` reading would be (it is the
healthy zero, not a resource anything is bound on — see the roadmap's own
"a constraint is not the largest bucket" pitfall). `idle_with_demand_by_cause`'s
fourth cause, `coordinator-declined`, names no candidate here on purpose: it
is a model-selection question (D22's own "which model runs each actor"), a
different lever category from the six this item ranks. Its seconds are never
silently dropped — they render in the account breakdown beneath the sentence
(below), just never rankable as "the constraint" by this fold.

The last two candidates are never evaluable from the time account alone, and
say so on every single call, never flipping to evaluable regardless of
whether `#574`/`#596` have since landed: D21's own three-way split names
time, spend and flow as separate accounts, and the human merge gate (pull-
request wait time) and the pipeline's own defect rate (rework's tokens,
elapsed time and item counts) are spend/flow-account measures, not a
node-time-state cause this account's fold can attribute a share of
node-seconds to. Ranking them against the four time-account candidates would
need a separate attribution this item does not build — `not_evaluable_reason`
states this in the object itself, `depends_on` names the record it would
start from.

**Never the largest bucket by default.** `status` is `"ok"` or
`"insufficient-evidence"`, with `insufficient_reason` naming one of three
distinct empty states, never collapsed into one "nothing to report": `"no-
time-account-data"` (the account has no `node-state` events at all —
`window.from` is null, the state of the world before issue #597 lands, or
any window with none in it), `"window-below-minimum-sample"` (an account
exists but `expected_total_seconds` is zero, or below
`constraint_min_sample_seconds` — too little observed to trust any share
computed from it; zero is stated separately because it is below *any*
minimum, `constraint_min_sample_seconds: 0` included, and because it is what
a single `node-state` event produces — a zero-length window, and so every
candidate's `share` null while `window.from` is not), and `"no-
candidate-above-minimum-share"` (a sufficient sample, but every evaluable
candidate's own share is below `constraint_min_share` — the sentence still
names the largest observed candidate, as context, but `leading_candidate`
stays `null`). `constraint_min_share` (default `0.3`) and
`constraint_min_sample_seconds` (default `14400`) are `config.json` keys,
echoed back on the object so a reader can see what gated the verdict without
a second lookup; `cadence_bound_minutes` (`schedule.cycle_interval_minutes`)
rides beside them purely informationally — the same resolution floor
`scripts/pickup-metrics.sh` states beside its own figures, never a gate this
fold applies itself.

**The account's own breakdown by state**, `constraint.account` — the same
shape `scripts/node-time-state.sh` prints, `window`/`totals`/
`expected_total_seconds`/`balanced`/`idle_with_demand_by_cause`/
`externally_blocked_by_cause`/`by_node` — renders beneath the sentence and
the candidate table as the evidence for or against it, never a second
verdict of its own: the totals table (all six states plus `unaccounted`),
then the idle-with-demand cause breakdown, then the externally-blocked cause
breakdown. `externally_blocked_by_cause` (issue #609) is the one addition
`node_time_state_fold` itself gained for this item — `externally-blocked`
seconds split by its own nine causes, `usage-limit` isolated from the other
eight so the account can tell "model capacity is the constraint" from "a
host or GitHub fault is," on the same terms `idle_with_demand_by_cause`
already split idle-with-demand seconds by its own four causes. **The window
is the retained log union and nothing more** — `log.jsonl` and
`review-log.jsonl` are both unioned and neither is ever rotated by size
(requirement 2.6), so every share this panel states is honestly "over the
node-state history this fleet still has," the same bound every other
history roll-up on this page already carries.

`scripts/constraint.sh` is the read-only CLI a human or another tool can run
directly — `lib/constraint.sh`'s own header is the field-by-field contract,
mirrored here rather than duplicated. It is never called from this panel's
own render path; the Publisher computes `constraint` once per full build,
exactly as it does `rework` and the actor scorecards, and the page only ever
reads the payload.

### The Fleet-sizing and revert-rate panels

The **Fleet sizing** panel (D21/D14, `docs/ROADMAP.md`; issue #612) sits
directly under Constraint, as the per-node evidence behind that panel's own
`node-count` candidate: `constraint` states one fleet-wide bucket, this
states which node, if any, is the one to remove. It renders `fleet_sizing`,
assembled by `lib/fleet-sizing.sh`'s `fleet_sizing_classify` over three
inputs, none of them a second raw-event scan of a fold this page already
paid for: the same node time-state account `constraint` itself reads
(`by_node[node]["idle-without-demand"]`); `lib/fleet-sizing.sh`'s own
`fleet_sizing_contention_by_node`, the identical selection/contended-
claim-lost population `scripts/pickup-metrics.sh` already counts
(TD-PPagop-26080808), grouped by node instead of by adoption era; and
`lib/fleet-sizing.sh`'s own `fleet_sizing_exclusive_landings_by_node` over
`item_lifecycle_fold`'s own records — a landed item whose only competing
`claim-lost` events (if any) came from its own claiming node is "exclusive":
no peer would have taken it. A payload the Publisher could not assemble sets
`fleet_sizing.sentence` (and every other field) to `null`, the same
outage-not-a-quiet-tick discipline `constraint` itself follows.

**The verdict, per node**, `fleet_sizing.by_node[]`, each `{node,
idle_without_demand_seconds, idle_share, claim_lost_contended, selections,
claim_lost_share, exclusive_landings, total_landings, verdict,
recommendation, lever}`. `idle_share` is that node's own
idle-without-demand seconds over the window's own length — a *time* share;
`claim_lost_share` is that node's own contended `claim-lost` count over the
**fleet-wide** pool of contended losses — a *pool* share, deliberately a
different kind of denominator, since "how much of this node's own time was
idle" and "how much of the fleet's own contention does this node account
for" are different questions the fold answers separately rather than
blending into one number. `verdict` is `"shrink-candidate"` only when all
three of idle share, claim-lost share and exclusive landings cross their own
threshold at once — high idle time or high contention alone is not enough,
and a node that is idle and contended but still delivers exclusive work is
earning its place regardless. `recommendation` is non-null only on a
shrink-candidate, naming the node and its own evidence in one sentence;
`lever` states the decision every row informs either way — "run fewer
nodes" on a shrink-candidate, "no action indicated" (with the reason) on a
healthy one — the lever rule (D21) applied per row, not only to the
fleet-wide sentence above it.

**The thresholds**, echoed on the object so a reader can see what gated the
verdict without a second lookup: `min_idle_share` and `min_claim_lost_share`
(default `0.3` each, the same default `constraint_min_share` uses, for the
same "roughly a third" reading of "elevated") and
`max_exclusive_landings_for_shrink` (default `0` — "few exclusive landings"
read at its strictest). **Never a guess below the evidence floor**: the same
`status`/`insufficient_reason` shape `constraint` uses, with one addition —
`"too-few-nodes"` (fewer than two nodes recorded; a shrink candidate needs
at least one peer to have contended with, which a single-node fleet cannot
supply) alongside `"no-time-account-data"` and
`"window-below-minimum-sample"` (`min_sample_seconds`, default `14400`, the
same default `constraint_min_sample_seconds` uses). `shrink_candidates` is
the plain list of node names `verdict == "shrink-candidate"`, `[]` — never
omitted — when the fleet is not indicated as over-provisioned by this
measure; the sentence states which reading applies in words.

The **Revert rate by repository** panel (D18 issue #579) is the continuous
half of Stage 2's exit criterion ("revert rate ≤ baseline"):
`scripts/mine-merge-history.sh` produced that criterion's Stage 0 baseline
once, by hand, on 2026-08-15, and nothing measured it again until this panel —
a regression is now a reportable fact on the day it happens, not only at a
promotion review. It renders `revert_rate`, which the Publisher assembles the
same way `landings` is: a fleet-wide union read over `revert-rate.jsonl`
(never rotated, replicated exactly like `log.jsonl` — `scripts/publish-
revert-rate.sh`'s own daily tick appends one row per repository, per node),
reduced to the newest row per repository across every node by that row's own
`ts` (union-with-most-recent-event-wins, the same rule the blocked and void
extractions use over `log.jsonl`), then joined against `config.repos` so a
repository whose publishing tick has never once succeeded still gets a row —
`{repo}` alone, no other keys — rather than silently vanishing from the
table. A join failure (the whole read could not be assembled) sets
`revert_rate` to `null`, rendered "could not be assembled this tick" and
explicitly distinguished from every repository simply having no data yet, on
the same "its own failure" principle the landings panel above uses.

Each row states three figures, per repository:

- **Rolling window** — the day-of operational signal: every merged, labelled
  pull request in the last `window_days` (14 by default) whose own 48-hour
  post-merge observation window has already elapsed, i.e. excluding anything
  merged in the last 48 hours, floored at `min_samples` (10) before a rate
  renders at all. Below the floor, the row states the sample size and that it
  is under the floor instead of a rate a reader would over-read from a
  handful of pull requests. The window's cadence and its own two instants
  (`rolling.since` .. `rolling.excludes_merged_after`) both render beneath the
  figure, in muted text, so a reader never has to hold the cadence in their
  head, and a row a node stopped publishing weeks ago does not read as
  current: the second instant is the "now" the rate is actually current as
  of, minus the 48 hours it excludes.
- **Cumulative since baseline** — every merged, labelled pull request since
  `revert_rate_baseline.generated`, unfiltered. This is the figure Stage 2's
  own exit criterion reads: an all-population aggregate compared against the
  all-population baseline it was measured the same way. Its own `since` date
  renders beneath it, same as the rolling window's bounds.
- **Baseline** — the stored Stage 0 figures themselves
  (`config.json`'s `revert_rate_baseline`, copied in once from `docs/reviews/
  2026-08-15-merge-autonomy-baseline.md` rather than re-derived at runtime).

A `vs baseline` badge compares cumulative against baseline — the two measured
the same way — green `at/below baseline` or red `above baseline`; a
repository absent from `revert_rate_baseline.repos` (or missing the whole
`revert_rate_baseline` block) renders neither figure nor badge as a rate,
reading `no data` rather than a comparison against nothing. All three figures
render as a percentage with the sample size that produced it (`25% (n=12)`),
never a bare percentage a reader cannot judge the weight of.

### The Rework panel

The **Rework** panel (D23, `docs/ROADMAP.md`; issue #611) answers exactly
three questions from the rework record and the item lifecycle record
(`docs/FLOW-SCHEMA.md`, requirements 47 and 49) and adds nothing else. It
renders `rework`, assembled by `lib/rework-panel.sh`'s `rework_panel_build`
from the same fleet-wide event union `escape_audits` above already reads,
and — like that panel, never `revert_rate`'s own rolling window — **never
windowed**: which rung eventually caught a given defect is a permanent fact
about it, on the same argument `escape_audits`' own paragraph above makes for
never letting an escape age out of a 24 h window. A payload the Publisher
could not assemble sets every top-level field to `null`
(`{how_much: null, whose: null, escape_ladder: null, clean_count: null,
rework_cycles: null}` — the last of those is not a fourth question but the
cycle-id set this fold's own cost join already computed, lifted to the top
level so the Spend by fate panel below can classify a `cost_rows[]` row as
rework by the identical membership test rather than re-deriving it, issue
#612),
the same "outage, not a quiet log" distinction every other roll-up on this
page makes — and so does a fold that aborted part-way, which
`rework_panel_build` reports with that same shape rather than with the
all-zero one. The two are opposite claims — nothing to report, versus nothing
was computed — and never render alike. A missing, empty or unreadable log is
the former: the fold runs to completion over an empty stream and its all-zero
report is the true statement "no rework recorded."

D23 is emphatic that rework is never a target of zero — a Reviewer catching
a defect is the system working, not failing — so this panel never collapses
its three questions into one score a reader could misread as "rework good,
rework bad":

- **How much?** `how_much.tokens`/`.elapsed_ms`/`.cost_usd`, each
  `{total, rework, rework_share}` — the fleet's whole per-cycle spend
  (`stage-end`'s own `cost_usd`/`duration_ms`/`tokens.*`, summed null-as-zero
  per `docs/METERING-SCHEMA.md`, joined to a `rework` event by the `cycle`
  field both carry from the same `log_event` envelope) against the subset
  spent on a cycle that also carries at least one rework record. That join is
  cycle-granular and the page says so in those words beneath the figure: a
  `stage-end` meters a stage, and the rework record does not say which part
  of a cycle a repetition consumed, so no apportionment within a cycle is
  derivable and a rework-bearing cycle counts in full — `rework_share` is an
  upper bound on what repetition cost, never a measured split, and a reader
  meets that sentence on the panel rather than only here.
  `how_much.first_pass_yield` is `{landed_total, first_pass, yield}` —
  `first_pass` is deliberately the narrow, literal reading issue #611's own
  refinement specifies: a landed item with **zero rework records whose
  `attributed_stage` is non-null**, not zero rework records of any class. A
  landed item that bounced once on `review-round-trip` (attribution `null`,
  D23's own attribution rule) still counts as first-pass by this definition
  — including, perhaps surprisingly, an item whose only rework record is a
  `post-merge-revert` (also unattributed): the worst outcome the ladder below
  can show still reads as "first-pass" here, because attribution and outcome
  severity are two different axes and this figure reads only the former.
  `how_much.rework_count` is the raw, deduped rework record count, reported
  once more explicitly for the same reason the escape ladder's own `caught`
  figures are — see the signature below. Every *count* on this panel
  (`rework_count`, `whose`, the escape ladder) reads a stream reduced
  first-wins-by-`ts` on the record's own stable identity, per
  `docs/FLOW-SCHEMA.md`'s "Do not double-count": `{repo, item, class}`,
  plus `evidence.by` for `post-merge-revert` (more than one corrective pull
  request can be detected for the same original), plus `ts` and `evidence`
  for the fleet-wide classes that carry neither `repo` nor `item` (crash-loop
  escalation, a backstop `stage-rerun`) — which without that narrowing would
  share one key across the whole log's history and collapse every occurrence
  of the class, for all time, to the first ever recorded. The rework *spend*
  in `how_much` reads the stream before that reduction, since each copy names
  the cycle its own node really spent tokens in; deduping there would drop a
  cycle that genuinely did rework and make the upper bound above an
  undercount instead.
- **Whose?** `whose.by_attributed_stage` — one `{stage, count}` row per
  non-null `attributed_stage` value actually present (today: `reviewer`,
  from `human-change-request`, and whichever stage names its own
  `stage-rerun`) — plus `whose.not_attributed`, `{count, by_class}`: the
  seven classes `docs/FLOW-SCHEMA.md`'s own attribution rule leaves `null`
  by design, broken down by class. Never inferred: a class with no
  detector-supplied attribution stays in `not_attributed` here exactly as it
  does in the record itself.
- **How far did it get?** `escape_ladder`, one row per detection stage in
  the pipeline's own rising cost order — `agent-review` (every class but the
  two below: a Reviewer or an earlier stage catching something before a
  human ever looks), `human-gate` (`human-change-request` — the
  reconciliation gate's own dirty verdict, at either of its two handoff
  sites),
  `post-merge` (`post-merge-revert` — nothing caught it until a corrective
  pull request landed after merge). Each row is
  `{stage, population, caught, escaped, escape_rate, cost_to_catch_at_next,
  cost_to_catch_at_next_note}`. The ladder's population is deliberately
  narrower than "every landed item": only landed items with **at least one
  caught defect, at any rung** — a landed item with zero rework records of
  any class may have had zero real defects, or one nothing here ever caught,
  and the two are indistinguishable from this record alone, so this panel
  does not guess which. That excluded population is `clean_count`, reported
  once, separately, rather than folded into a rate that would otherwise
  overstate how much passed undetected. `caught` at a rung is
  **item-granular, not defect-granular**: a rework record carries no defect
  identity (`docs/FLOW-SCHEMA.md`), so every item is first collapsed to the
  single furthest rung any of its own rework records reached, and only then
  is `caught` tallied as the landed items whose furthest rung was this row —
  never a count of the defects actually caught there. An item carrying two
  independent defects — one bounced back at `agent-review`, a second nothing
  caught until `post-merge` — credits only the `post-merge` row:
  `agent-review`'s own `caught` count is unaffected by the round trip that
  did catch something, despite that catch being real, and that same item
  counts toward `agent-review`'s `escaped` instead. `test/rework-panel.test.sh`'s
  item 4 is exactly this shape. Read every per-rung `caught` figure — and, by
  extension, the `population` each later rung inherits from the rung before
  its own `escaped` items, since that population is built from the same
  furthest-rung collapse — as a **floor** on the defects actually caught or
  outstanding there, never an exact count. The escape-rate signature itself
  stays legible under this reading (see "The Reviewer-waving-work-through
  signature" below): the collapse is pessimistic about an active Reviewer,
  crediting it with nothing on exactly the item this paragraph describes, so
  the direction of the bias only ever understates catches, never invents
  them. `escape_rate` at a rung is the share
  of that rung's own population — items not yet caught when they reached
  it — that went on uncaught to a later rung; `post-merge` is terminal and
  reports `escaped`/`escape_rate` as `null`, never a `0` that would misread
  as "always caught here." `cost_to_catch_at_next` is the average
  tokens/elapsed-time/cost of the cycles that caught a defect at the row's
  own next rung (the same per-cycle metering join `how_much` uses) — `null`
  with its own `cost_to_catch_at_next_note` explaining why: `post-merge`'s
  row states "terminal rung, nothing further to escape to," while
  `human-gate`'s row states that a `post-merge-revert` record carries no
  `cycle` at all (mined after the fact, outside any cycle,
  `docs/FLOW-SCHEMA.md`) and so its cost is genuinely unmeasurable — a
  different reason for the same `null`, and the panel never conflates them.
  A catch whose own `cycle` the log carries no `stage-end` for (a peer's log
  that failed to fetch, a cycle whose stage events no longer survive) is
  dropped from that average rather than folded in as a zero-cost sample, so
  `n` counts the catches actually measured and never the catches that
  happened; a rung with catches but metering for none of them reads `null`
  with the note "no human-gate catch with metered cycle spend in this window
  to measure," on the same "an outage is not a quiet zero" distinction every
  other roll-up on this page makes.

**The Reviewer-waving-work-through signature.** A rising escape rate at the
`agent-review` rung alongside a *falling* `caught` count at that same row is
the signature D23 warns a naive reader could mistake for improvement: a
Reviewer that stops bouncing work back looks, by that one figure alone, like
a Reviewer catching fewer defects — when the defects still happen and
simply surface later, at a more expensive rung. This panel never blends
`caught` and `escape_rate` into one score for exactly that reason: reading
them side by side on the same row is what keeps the regression legible
rather than cancelling out. `test/rework-panel.test.sh` demonstrates this
directly against a constructed before/after fixture, on
`test/item-lifecycle.test.sh`'s own precedent of a hand-built log exercising
every case at once.

**A residual coverage gap, stated on the panel's own face** (issue #611's
own correction to its original filing, which had named a different, already-
resolved gap — agent-ops#533, `lib/reconciliation-gate.sh`, PR #539): the
`human-gate` rung can only see what the reconciliation gate itself observes,
at either of its two handoff sites (the Reviewer's own ready handoff and the
Enabler's handoff-recovery path, agent-ops#1032). A human change request
posted *after* a pull request is already ready, or acted on directly with no
handoff ever running, is invisible to that detector. The page states this
immediately beneath the escape ladder, in the same words, so a reader never
mistakes the `human-gate` row's own count for a complete one.

**Which files conflict most often** (issue #1805) is a further breakdown,
rendered directly beneath the clean-count line and above the two interpretive
paragraphs described above (the never-a-target-of-zero framing and the
coverage gap), scoped to the `merge-conflict` class alone rather than one of
the panel's own three fleet-wide questions:
`rework.merge_conflict_paths`, read verbatim from `lib/rework-panel.sh`'s own
fold (never recomputed by the Publisher or the page), reports `total` (every
`merge-conflict` rework record) against `known` (the subset whose own
candidate carried a computed `evidence.conflicted_paths` — an item whose
dry-run merge could not be computed is counted in the former, never the
latter, the same "an outage is not a quiet zero" distinction every other
figure on this page keeps), the ten most frequent conflicting paths across
every known entry (`top_paths`, `{path, count}`, ties broken by path
ascending), and the share of known entries whose *only* conflicting path was
`CHANGELOG.md` (`changelog_only`, `{count, share}`) — the figure D27 (moving
the changelog entry out of `CHANGELOG.md` and into the pull request's own
description, issue #1804) exists to drive toward zero. `total == 0` (no `merge-conflict` rework recorded yet)
renders a plain "no conflicted-path data recorded yet" line rather than an
empty table; this is distinct from the panel's own top-level outage
(`rework: null`), which still shows the ordinary "could not be assembled"
message and never reaches this section at all.

### The Doctor and stage-health panels

The **Doctor** panel (agent-ops#543) renders `status.doctor`: the most recent
hourly `scripts/doctor.sh --unattended` pass on *this* node, read from
`state_dir/.doctor-status.json` rather than recomputed — its GitHub section is
too expensive to repeat on the dashboard's own 5-minute heartbeat, so a
separate hourly `crontab.tmpl` line runs it and this Publisher just reads the
result. One row per `fail`/`warn` line the pass printed, each carrying a
level badge (`fail` red, `warn` amber) and the message verbatim, plus when the
pass last ran; a clean pass says so instead of rendering an empty table, and
no pass having run yet (a node whose image predates the flag, or one still on
its first hour) says that too, rather than either looking identical to a
clean pass. A `fail` or `warn` also raises its own page-top banner (naming the
count and pointing at this section), the same way failing PR checks do —
because, like those, a `warn` this pass leaves unclaimed the same way a
misconfigured `Priority` field did before this existed is otherwise invisible
between one operator-invoked `doctor.sh` and the next.

Above the fail/warn table, a standing line (agent-ops#694) states this node's
PAT expiry once any unattended pass has recorded one:
`token_expiry.days_remaining` and `.expires_at`, read from GitHub's own
`GitHub-Authentication-Token-Expiration` response header. Unlike the
fail/warn rows, this line renders whenever `token_expiry` is non-null,
including on an otherwise-clean pass — it is a figure this node always has an
answer for, not a message that only appears when something is wrong. A badge
reads amber below `TOKEN_EXPIRY_WARN_DAYS` (7; `lib/token-expiry.sh`) and grey
at or above it, with a rotate-`GH_TOKEN` nudge alongside the amber reading;
`token_expiry: null` (an installation token, or any other
credential GitHub states no expiry for) renders nothing here at all. This is
the dashboard half of the warning the 2026-08-22 fleet-wide outage
(agent-ops#691) needed and never had — the expiry date was knowable a month
out, and every node lost GitHub at once, misdiagnosed as an outage, before an
operator noticed hours later.

This panel itself renders only this node's own `status.doctor` — a
repository's configuration and this node's own GitHub access are this
node's alone to report, so a peer's doctor pass has nothing to add here.
`doctor`'s own *verdict* does now travel in `fleet.nodes[].doctor`, the same
way `compose`/`image`/`switch` already did, and since agent-ops#1397 a
bounded `fails` travels beside it — the first three entries, each truncated
to 200 characters, so that a page can name the check that failed without the
whole fleet re-fetching unbounded diagnostic prose every
`schedule.state_sync_fetch_minutes`. `warns`, `skips` and `token_expiry`
stay node-local still. All of that is for `lib/pager.sh`'s own
`verdict-unanimous` invariant (implementation spec requirement 51) to read
fleet-wide, not for this panel, which stays node-local by design.

The **Stage health** panel (agent-ops#662) renders `status.stage_health`: the
most recent per-stage verdict computed on *this* node, read from
`state_dir/.stage-health.json` (written by `lib/stage-health.sh`'s
`stage_health_write_status` at the end of every cycle, and — for the
`monitor` row alone — at the end of every Pipeline Monitor run that engaged
its stage, `docs/spec/monitor.md` M17) rather than
recomputed, on `status.doctor`'s own precedent just above. One row per stage
(`coordinator`, `approver`, `approver-adjudicate-open-question`,
`enabler-adjudicate`, `enabler-decide`, `enabler`, `refiner`, `implementer`,
`reviewer`, `monitor`),
each carrying a verdict badge (`failing` red,
`idle` grey, `ok` green), when it last succeeded, and — for a `failing`
row — its consecutive-failure count and the most recent attempt's own
failure detail; no cycle having completed since this check shipped says so,
rather than rendering an empty table. A `failing` row also raises its own
page-top banner naming which stage(s), the same way a `doctor` `fail` does —
this is the reading that was missing entirely during the 2026-08-21
incident (issue #662): `cycle: RUNNING` and a clean Doctor pass both stayed
true while every stage failed for 10.5 hours, because neither reads a
stage's own `exit_code`.

The panel, the fleet-strip badge and the banner all iterate whatever keys
`stages` actually holds rather than a fixed list, which is what lets the
`monitor` row appear beside the implementation pipeline's nine without a
render change: `monitor-cycle.sh` computes the verdict for `["monitor"]` over
its own `monitor-log.jsonl` and **merges** it into the same file, so the two
writers each replace only their own stages and carry the other's forward
(`docs/spec/monitor.md` M17). What the Monitor pipeline *found* is
not on this page at all — its dated report lives in the state store — and
surfacing it is deferred at `tech-debt/TD-PPagop-26091101.md`.

A non-empty `pager` array (implementation spec requirement 51) raises its
own page-top banner, `.banner.pager-firing` — a fourth colour modifier
alongside `.amber`/`.green`/`.red`, since a firing invariant is neither an
ordinary warning nor a clean pass — naming every firing key and its
evidence, each linking `issue_url` when the tracking issue exists. For each
entry that carries a `nodes` array, every node card named in it gets a
badge (`b-purple`, the same purple family as the `.banner.pager-firing`
banner above) reading the invariant's own key, titled with its evidence — so a
`verdict-unanimous` page naming every active node marks every one of their
cards, while an invariant with no `nodes` (most of `page-outlived-item`'s
own firings, which are about an issue, not a node) raises the banner alone.

Unlike `status.doctor`, this verdict is not local to the node that computed
it: `scripts/state-sync.sh`'s heartbeat carries it as `stage_health`, on the
same terms as the compose/image/switch verdicts, so the fleet strip's own
**N stage(s) failing** badge (above) can render for a peer, not only for this
page's own node — a peer's badge comes from its heartbeat's `stage_health`
field or renders nothing at all, never a verdict this page derives for that
peer.

The **Review stage health** panel (agent-ops#996) is `Stage health`'s
equivalent for the repository-review pipeline's own one real stage,
`project-reviewer`: it renders `status.review_stage_health`, read from
`state_dir/.review-stage-health.json` (written by `lib/stage-health.sh`'s
`stage_health_write_status` at the end of every `review-cycle.sh` run that
reviewed at least one repository, `docs/spec/review.md` R19) rather
than recomputed, on the Stage health panel's own precedent just above. One
row — `project-reviewer` — badged and detailed exactly the same way (`failing`
red, `idle` grey, `ok` green; a `failing` row's consecutive-failure count and
last-attempt detail); no run having completed since this check shipped says
so, rather than rendering an empty table. A `failing` row raises its own
page-top banner, the same as `Stage health`'s own — this is the reading R17
of `docs/spec/review.md` deferred as a follow-on, closed here: the
`review-stage-end`/`review-attempt-failed` detection this panel reads
already existed, but until #996 nothing read it, the exact gap #662 closed
for the implementation pipeline's own nine stages.

A separate panel and a separate `review_stage_health` field, not a
`project-reviewer` row folded into `Stage health` itself: the two pipelines'
event streams (`log.jsonl` vs `review-log.jsonl`) and cycle-id shapes differ
(a `review-cycle.sh` run's own `cycle` id, unlike `agent-cycle.sh`'s, can
cover several repositories, `docs/spec/review.md` R19), so their
verdicts are computed, written and travel separately, and this page renders
them separately rather than implying a shared computation that does not
exist. Unlike `status.doctor`, this verdict is not local to the node that
computed it either: the heartbeat carries it as `review_stage_health`, on the
identical terms as `stage_health` — a peer's own panel data and fleet-strip
badge come from its heartbeat's `review_stage_health` field or render
nothing at all, never a verdict this page derives for that peer.

### The actor, token-economics and stall-profile panels

The **Actor and model scorecards** panel renders `counts.actor_scorecards`
(issue #610, D22) — one card per actor with a model choice (D12), one row per
model and tier, graded on **outcome**: what a stage-end's own attempts
*produced*, not how many of them there were. It supersedes the Co-Ordinator
verdict-quality panel (issue #319 — its corroboration rate is folded into the
Co-Ordinator card's own `measure` rather than left rendering beside it) and
the two "model used" pies (issue #529 — that ratio is now every row's own
`attempts`, split by model and tier rather than drawn as a chart of its own).

Every row's outcome figures — `landed`/`voided`/`abandoned`, first-pass yield,
cost and wall-clock per landed item — are joined through
`lib/item-lifecycle.sh`'s own fold (requirement 49) over the subset of that
row's stage-ends that carry `{repo, item}`: the Implementer's and Reviewer's
always do, the Enabler's two per-item adjudication stages do, and the
Co-Ordinator's own engagement and the top-level Enabler's and Refiner's own
do not — each spans several items in one engagement, so `items_examined`
reads `0` there by construction and that actor's own measure (below) is built
from a different, genuinely per-item event instead. That subset is reduced to
distinct `{repo, item}` **once per row**, not once per stage name feeding it:
a row can be fed by more than one stage — the Enabler's `critical` row by both
`enabler-adjudicate` and `enabler-decide` — and an item that met both would
otherwise count as two examined items and, if it landed, two landed ones,
halving that row's own cost-per-landed. Cost and wall-clock still sum across
every one of that item's own stage-ends in the row; only the item count is
deduplicated. `landed_with_rework`
reads a landed item's deduped `rework` records (docs/FLOW-SCHEMA.md, "Do not
double-count") for one whose own `attributed_stage` names this row's actor —
today that is only ever non-empty for a `stage-rerun` (any actor) or a
`human-change-request` (Reviewer only), per that document's own "Attribution"
section; every other class carries `attributed_stage: null` and so never
moves a row from `landed_unchanged` to `landed_with_rework`. `attempts`/
`clean` count *every* stage-end for the row's stage name(s), item-carrying or
not, so the Co-Ordinator's and the top-level Enabler's/Refiner's own
engagements are not undercounted the way restricting to the joinable subset
would; `clean` is a stage-end with no `kill_reason` — the other half of
`stage-rerun`, a fleet-wide crash-loop escalation, cannot be pinned to one
attempt among several sharing a stage and node and is not subtracted here.

Cost and wall-clock per landed item read the landed stage-end's own
`cost_usd`/`duration_ms` (docs/METERING-SCHEMA.md) directly, summed across
every stage-end that touched the item and divided by items landed — not
`counts.cost_rows[]`, whose own `attributed` field is `false` by construction
for the Enabler and the Refiner (they share their triggering cycle's id with
whichever stage of that cycle owns the item), which would leave those two
actors' cost/wall-clock permanently null.

Each actor's own **measure** answers the question specific to it, D22's own
list: the **Co-Ordinator's** is issue #319's own corroboration rate, folded in
here per model rather than left as its own panel — `corroborated`/`rejected`/
`rate`, plus whether the items it picked (`selection`) went on to land,
`picks_landed` of `picks_total`. That is two rates over two different
populations, so each carries its own gate rather than sharing one: `status`
answers for the corroboration rate over `corroborated`, `picks_status` for the
picks-landed rate over `picks_total`. A row can have verdict history enough to
state a rejection rate and two picked items — a landing rate off two picks is
the spurious ordering "stratify or abstain" exists to refuse, and it must not
reach the page on the strength of the *other* rate's sample.
The **Reviewer's** is an escape rate:
items — not raw rework records — carrying a deduped `human-change-request` or
`post-merge-revert` record against items reviewed; a `post-merge-revert`
record's own `item` is the reverted pull request's number, not the work item a
stage-end names, so it is re-keyed onto the work item via `pr_url`
(`pr-raised`/`pr-ready` already carry both) before the join, and is left
unjoined — excluded from every row — where no such mapping is on record. The
**Enabler's** is unblock success: `landed` of `items_examined`, the same two
figures its own row already states. The **Refiner's** is refinement success:
items it refined (`item-refined` events carrying `by: "refiner"` — the
Enabler logs the same event, with no `by`, for its own unblock-as-refined act,
and is excluded here) against how many were later bounced back
(docs/FLOW-SCHEMA.md's `refinement-bounce-back`) — never the Refiner's own
stage-end attempts, since that engagement spans several items and has no
per-item identity of its own to count.

**Stratify or abstain** (D22): every row states its own `sample` — `landed` +
`voided` + `abandoned`, the closed population its rate is drawn from — and
`status`, `"insufficient-sample"` below `counts.actor_scorecards.min_sample`
(`lib/verdict-fate.sh`'s own `MIN_SAMPLE` default of 5, agent-ops#573, reused
rather than a second threshold invented for this card) or `"ok"` otherwise;
below the minimum the row's first-pass yield, cost and wall-clock read
"insufficient evidence" rather than a number too thin to mean anything. A
row's own `measure` carries the same gate on its own sample — and one gate per
rate it states, not one per measure, since the populations are often different:
the Co-Ordinator's corroborated-verdict count is rarely the same as its
picked-item count. A row's **stratum** is its
own `model` and `tier`: Implementer splits `trivial`/`default`, Reviewer
`default`/`complex`, Enabler `default`/`critical` by stage name
(`enabler` vs. `enabler-adjudicate`/`enabler-decide`); the Co-Ordinator and
the Refiner each have one configured model and so one tier, `default`. Tier
is derived by comparing a stage-end's own `model` id against that actor's two
*currently* configured tier values — there is no per-event record of which
config key resolved it at the time — so a historical run under a
since-changed mapping reads `"unmapped"` rather than a guess.

The card ships even on a log with no stage-end for any of the five actors,
each carrying `rows: []` rather than the card itself going missing — the page
distinguishes "nothing recorded in this window" from "this Publisher never
recorded any of this," and a `data.js` written before the aggregate existed
says so outright rather than rendering a clean-looking empty card set it has
no data for.

The **Token economics** panel (issue #594, D21) surfaces the token dimension
`lib/metering.sh` records on every stage and nothing before this read: two
breakdowns, **by stage** and **by model**, each a table of input/output/
cache-read/cache-write token totals plus the **prompt-cache ratio** —
`cache_read / (cache_read + cache_creation + input)`, stated in the table
header itself rather than left for a reader to infer, since an unstated
denominator is exactly the "counter on a wall" the lever rule (D21) forbids.
Both ride `counts.cost_rows[]` and the cost charts' own time-frame selector
(`windowedTokenBreakdown`, mirroring `windowedCostBreakdown`) — the same
window, moved by the same control, so a reader who narrows the time frame to
answer "what did yesterday cost" gets the same narrowing applied to "what did
yesterday's tokens buy." A `cost_rows[]` row whose four `tokens_*` fields are
all `null` (an `unknown`-model row with no readable `modelUsage`) is excluded
from both breakdowns entirely, never folded in as zero — see
`docs/METERING-SCHEMA.md`.

Each row's own `n` counts distinct transcripts, deduped by `(cycle, actor)`
rather than by `cycle` alone (`aggregateTokenRows`, issue #1591): the by-stage
breakdown's own groups are already one actor each, so that pair reduces to
`cycle` there and its `n` is unaffected, but the by-model breakdown groups by
model, where a cycle whose several actors share one model must count as that
many distinct transcripts, not one — a `cycle`-only dedup, correct for
`aggregateCostRows`'s own `by_actor`/`by_model` totals above, would undercount
it here.

Each row's own cache ratio carries the lever the figure informs, in the same
cell: below `TOKEN_MIN_SAMPLE` (5, the same minimum sample the actor/model
scorecards already use) it reads "insufficient evidence" rather than a rate
too thin to mean anything; at or above it, a ratio below
`CACHE_RATIO_ACTION_THRESHOLD` (0.5, stated on the page rather than left a
mystery number per implementation spec requirement 4f) names the lever
directly — the stage's own prompt prefix may be varying between cycles, worth
stabilising or revisiting its `prompts/` override — and a ratio at or above it
reads "no action indicated." Each breakdown also names its own largest token
consumer in a caption above the table — the actor or model whose D12
assignment is driving the token cost, the lever the by-stage/by-model split
itself informs.

The **Stall profile** panel (issue #594, D21) renders `counts.stage_gaps`: the
other series `lib/metering.sh` records and nothing read before this — how long
each stage went silent, by stage. It states its own window
(`window_from`/`window_to`) above the table, deliberately not the cost charts'
`COST_SCAN_DAYS`: its source is the `gaps` object on `stage-end`/
`review-stage-end` events in the retained log union, a materially different —
usually longer — span (`docs/METERING-SCHEMA.md`). The caption also states,
in words, that `median_of_run_p50` and `worst_run_p95` are read "across runs"
rather than as pooled percentiles, and that `worst_run_max` alone is exact (a
max of maxima is a max) — the same distinction `docs/METERING-SCHEMA.md`'s own
`gaps` section draws, restated here since it is the one place on the page a
reader could otherwise mistake a per-run figure for a fleet-wide percentile.

Each row's own **Decision** cell is the lever the stall profile informs (D21):
whether the stage-cap settings the watchdog enforces (implementation spec
requirement 4e) should move, and which way. `worst_run_max` is compared
against `stageBackstopMin` — the same figure the fleet strip's own
stage-overrun badge already holds a live stage against, so this panel cannot
recommend a number the rest of the page would disagree with — **before** the
sample-size check, and independently of it: `worst_run_max` is a max of
maxima, not a rate, so it is exact at any sample size, including a single
run. At or above `STALL_NEAR_BACKSTOP_RATIO` (0.9) of that backstop the cell
names the lever directly — raise the backstop before a healthy run is
killed — no matter how few runs the row carries. Only below that ratio does
the sample size matter: under `TOKEN_MIN_SAMPLE` runs the cell reads
"insufficient evidence"; at or above it, "no action indicated." A row whose
`stageBackstopMin` resolves to no positive number — no per-row announced
value, no entry for that stage in the published `config.stage_backstops`
(see the fast-tick section's note on stage budgets and issue #1586, so that
`config.stage_backstops` can carry a `project-reviewer` entry; this now covers
`project-reviewer`, and `refiner` the same way, once the fleet-wide fold has
observed a stage-end for it), and no shipped prior for that stage name —
reads "no cap on record for this stage" rather than guessing a direction.

### The spend-by-fate and turns-per-item panels

The **Spend by fate** panel (D21/D14, `docs/ROADMAP.md`; issue #612) is the
other half of "where do the tokens go?" — the fate account `docs/
ROADMAP.md`'s own D21 accounting decision calls for, whereas Token economics
and the Stall profile above answer "how efficiently" and "how quiet," this
answers "on what." It renders `spend_fate`, assembled by
`lib/fleet-pricing.sh`'s `fleet_pricing_spend_fate` over the same
`counts.cost_rows[]` the cost charts and Token economics already read, this
time joined against `lib/rework-panel.sh`'s own `rework_cycles` (issue #611's
cycle-membership test, never re-derived) and `item_lifecycle_fold`'s own
per-item terminal fate, both already computed elsewhere on the page. Unlike
Token economics this panel is **not** windowed by the cost charts' own
time-frame selector: a row's fate is a permanent fact about it, the same
"never windowed" argument the escape-ladder and rework panels above already
make for a caught defect's own rung.

Both `counts.cost_rows[]` and `rework_cycles` reach `fleet_pricing_spend_fate`
spooled to a file in `$work_tmp` and read via `--slurpfile` (issue #1691),
never as an `--argjson` value on `jq`'s own argv — the class requirement 4g
exists for, since a fleet's rework-bearing-cycle count is unbounded by
configuration and rides this join all-time. When `rework_panel_build` itself
reports its outage shape (`rework_cycles: null` — a fold that aborted, the
Rework panel's own paragraph above), that `null` is passed through verbatim,
never coalesced to `[]`: `fleet_pricing_spend_fate` reports its own all-null
outage shape in that case rather than computing a confident, reconciled
account with every rework-bearing row silently reclassified into
delivered/discarded/defect_driven — the same "an outage is not a quiet zero"
discipline every other roll-up on this page keeps.

**The fate mapping**, applied in this order, first match wins, so every row
lands in exactly one of six buckets — never dropped, never double-counted
(`lib/fleet-pricing.sh`'s own header carries the full reasoning; this is the
summary a reader of the page needs):

| Order | Fate | A row matches when |
| --- | --- | --- |
| 1 | `overhead` | `attributed` is false, or `repo`/`item` are both empty even though `attributed` is true (a coordinator cycle that selected nothing, stood down, was skipped, or simply ended) |
| 2 | `rework` | the row's own `cycle` is one `rework_panel_build`'s own `rework_cycles` names |
| 3 | `defect_driven` | `outcome == "failed"` (an attempt errored outright) and not already claimed by rework |
| 4 | `delivered` | the row's `{repo, item}` terminal fate, from `item_lifecycle_fold`, is `landed` |
| 4 | `discarded` | that terminal fate is `voided`, `superseded` or `abandoned` |
| 4 | `unaccounted` | anything else — `blocked`, `open`, an item lifecycle itself reports `unaccounted`, or an item this fold's population never saw: not yet resolved, never a forced guess between delivered and discarded |

**The `rework` bucket and the Rework panel's own `cost_usd.rework` are not
the same figure, and are not meant to reconcile against each other.** They
share issue #611's cycle-membership test and nothing else: the Rework panel
sums `stage-end` cost per cycle, over every row of a rework-bearing cycle,
while this account sums `cost_rows[]` (transcript × model) and sends a
rework-bearing cycle's *unattributed* rows — an Enabler, a Refiner, a
limit probe sharing that cycle id — to `overhead` instead, because rule 1
outranks rule 2. The bucket is therefore the narrower of the two by
construction. Each answers its own question against its own source; a reader
comparing them is comparing "what did rework-bearing cycles cost" with "what
did rework cost the work that was attributable to an item."

**Reconciliation is checked, not asserted**: `spend_fate.reconciled` is
`true` iff the six buckets' own *unrounded* sums add to
`spend_fate.total_usd`, both sides rounded to the cent exactly once at the
end — the identical rounding issue #536 already uses to reconcile
`cost_rows[]` against `total_cost_usd`. Rounding each bucket first and then
summing the six would be a different and wrong check: a `cost_rows[]` row is
one model's share of one transcript and routinely costs a fraction of a
cent, so six half-cent roundings accumulate into a mismatch over an account
whose rows are partitioned perfectly. The per-bucket `usd` the page renders
is rounded from those same unrounded sums afterwards, so a reader still sees
figures that add to within a cent of the total. A
`false` here is a bug in the fold, not a rounding note, and the panel says so
in words rather than rendering a silently-wrong table. Each bucket's own
`usd`/`n` and the decision it informs (the lever rule, D21) render together
in one row, `spend_fate.lever[<bucket>]` in the same cell as its own figures
— `delivered` is the reference baseline (not itself a lever), `rework`
points at D23's own class/cause accounting, `discarded` at item-selection
judgement, `overhead` at cycle cadence and back-pressure caps (the same
candidates `constraint` itself names), `defect_driven` at whatever crashed
or timed out the stage, and `unaccounted` says plainly that the item has not
resolved yet.

The **Turns per landed item** panel (D21/D14, `docs/ROADMAP.md`; issue #612)
is the companion figure to Token economics' own prompt-cache ratio for the
same "per stage and model" reading D21's own "Done when" line asks for. It
renders `turns_per_landed_item`, assembled by `lib/fleet-pricing.sh`'s
`fleet_pricing_turns_per_landed_item` over `item_lifecycle_fold`'s own
records — every landed item's own `stage-end` instants, `num_turns` and
`stage`/`model` read directly off them, never a second raw scan. Grouped by
`(stage, model)`, each row states `n` — the stage-ends sampled, not the
landed items behind them, since a landed item whose stage ran twice
contributes both of its stage-ends and each is its own turn count — plus
`mean_turns` and `median_turns` over exactly that sample. `n_landed_with_turns` — landed items carrying at least
one stage-end with a measured `num_turns` — is reported beside
`n_landed_total` rather than folded into it, so a landed item predating this
record (or whose stage-end predates `num_turns` being recorded at all) never
reads as a silent zero. The Co-Ordinator's own stage-end is not counted here
for the identical reason the actor/model scorecards above already exclude
its own engagement from their item-scoped joins: it typically carries no
`{repo, item}` of its own, since its stage spans selecting rather than one
item's work, so its turns cannot be attributed to one specific landed item
without a different join this figure does not build. The lever this
informs (D22): a model taking materially more turns than a peer for the
same stage on the same class of work is a prompt or tool-loop inefficiency
to fix at the model or prompt level, before the token spend it drives is
treated as a volume problem.

### The recent log and pull-request cards

The **recent log** is the newest 80 events, one row each: time, the event as a
badge, **Node**, **Repo**, **Actor**, and the event's own detail. A
`disabled`/`enabled` event's badge additionally names its `scope` (issue
#426, implementation spec requirement 33) — `disabled · node` or
`disabled · fleet`, `enabled · node` or `enabled · fleet` — since the bare
event name cannot say whether a stop or a resume was one node's own or the
whole fleet's, and that is the first thing a reader scanning the tail asks.
A fleet-scoped one whose `fleet_flag` reads `"failed"` additionally appends
`fleet flag: failed` to the Detail cell: a local switch that changed while
the fleet flag did not follow it is exactly the case an operator must not
mistake for a clean transition. The Node, Repo and Actor columns are different
kinds of answer to "where did this happen" — which machine ran it, which
repository it was aimed at, which agent was acting — so each gets its own cell,
read positionally, carrying a dash when the event does not answer it: the Repo
cell is the repository whether or not the other two are known. The Node column
renders regardless of fleet size, unlike the
cycles table's own Node column — this one has always carried the node, single
node included, so nothing about it changes when the fleet has one node. It is
also, together with the cycles table, subject to the fleet strip's node
filter: clicking a node card restricts the recent log to that node's events
too, filtered before the 80-row cap so a node whose events have aged out of
the fleet-wide newest 80 still shows its own newest ones, with the section
heading and empty state following the cycles table's own wording ("Recent log
events — `<node>` only (click its card to clear)" and "No log events from
`<node>`."). The actor is derived rather than logged, because no event carries an
`actor` field and each pipeline already records it somewhere else: the
implementation pipeline's `stage`; `handoff` on `pr-ready`, naming which actor
took the pull request out of draft; `by` on `unblocked` and on `item-refined`
(and on those two events only — `by` elsewhere names a *person*, who set the
switch or cleared a stand-down); the Enabler's own `escalated`,
`enabler-examined`, `enabler-adjudication` (implementation spec requirement
36b's `adjudicate-first` pass) and `item-refined`, and the Refiner's
`refiner-examined`, which carry none of the first three. `item-refined` is the one event with two
writers — the Enabler's refinement pass and the Refiner — and only the
Refiner's carries `by`, so one without it is the Enabler's. A review-pipeline
event is the Project Reviewer's, which is a different actor from the cycle
Reviewer even where the review pipeline writes `stage: "reviewer"` — the same
distinction the Publisher's cost scan draws from the transcript path, drawn the
same way so the two halves of the page cannot disagree about who did what.
Steps with no agent in them name none: the clone (`stage: "workspace"`) and a
handoff the Script completed itself (`handoff: "script"`), as do the
cycle-level events (`cycle-start`, `selection`, `cycle-end`, and the review
pipeline's lifecycle), which are the Script's records of a cycle's progress
rather than any agent's work. Like the source tags and the by-actor chart, this
fails open: a token the page has never heard of renders as itself, so an actor
added upstream shows up unlabelled rather than vanishing into a dash.

Every pull-request number anywhere on the page is rendered by one widget,
which makes it a link with a **record card** carrying that PR's entry from
`github.pr_index`: repo and number, state, title, author, when it was opened
and merged or closed, the abbreviated merge commit (itself a link), its labels,
and — while it is still open — checks, review decision and mergeability. It
also names **the cycle that raised it**, joined client-side from the cycle
list, so the two halves of the page connect without the pipeline logging
anything new. A number with no entry yet says so rather than rendering an empty
card.

The card opens two ways, and they do not cross:

- a **peek** follows the pointer — hover on to open, hover off to close, with
  the pointer free to cross onto the card itself (it holds links of its own).
  Keyboard focus opens a peek the same way, and blur closes it; `Escape`
  closes either kind.
- a **pin** is an explicit act — a click or a tap — and only another explicit
  act closes it: the same number again, a click or tap anywhere off the card,
  the card's own close button (shown on pinned cards only), or `Escape`.
  Hovering off a pinned card leaves it open, and hovering another number does
  not move it; clicking another number does.

**A plain click opens the card rather than following the link**, because on a
touch device the tap that opens the card was also the tap that left the page,
which made the card unreadable exactly where the record is least visible
otherwise. The link is preserved for every input that asks for it: modifier and
middle clicks open the PR in a new tab, keyboard activation (`Enter`)
navigates as it always did — focus alone already shows the card — the `href` is
untouched so "copy link address" and the status bar still work, and the card
carries a *View on GitHub ↗* link of its own.

An open card is carried across the body's rebuild like the expanded rows and
open transcripts are, peeked or pinned as it was — matched to the exact
occurrence it was opened on, so it cannot reappear against one of the same
number's twins elsewhere on the page.

