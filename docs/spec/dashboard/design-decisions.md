## Design decisions

- **Single generated data file + committed page**, rather than a server or a
  build: the cheapest thing that works, openable as a `file://` with nothing
  running, and trivial to regenerate.
- **Local/private, no GitHub Pages or Action.** An earlier draft proposed a
  scheduled Action publishing to a companion repo; it was dropped as needless
  cost and exposure. The machine is authenticated and the repos are public, so
  the local Publisher fetches all GitHub data itself; a localhost page can't be
  viewed while the machine sleeps anyway, which was the Action's only draw.
- **Remote access is tailnet-scoped, never public.** The README's "View it
  away from home" section layers `tailscale serve` in front of the untouched
  loopback server (`deploy/tailscaled.init` runs the daemon on this
  systemd-less WSL distro): the server still binds `127.0.0.1`, Tailscale
  authenticates each viewing device against the owner's own tailnet, and
  traffic is end-to-end WireGuard. This loses nothing while the machine
  sleeps — the pipeline only produces telemetry while awake. Public exposure
  (`tailscale funnel`, Pages, shareable tunnel URLs) stays rejected for the
  reasons above.
- **The page fetches nothing external.** All GitHub reads happen in the
  Publisher via `gh`; the page reads only its local `data.js`. Offline-capable,
  dependency-free, no CORS or rate-limit concerns.
- **Redaction is unconditional** even though the data is local, so a
  screenshot or copied file is safe and a future private repo can't leak.
- **Limit detection is independent of the log**, because the pipeline's logger
  misses weekly-limit phrasing — the dashboard reads the transcripts directly.
- **A skipped GitHub fetch is not a failed one.** Once the heartbeat runs every
  few seconds, most ticks publish with `--no-github` to spare the API, and a
  full fetch happens only once per window. If a `--no-github` tick simply wrote
  `github.ok = false` with empty `prs`/`inputs`, the dashboard would blank the
  PR list and work sources — and raise the "GitHub unavailable" banner — 59
  ticks out of 60, turning a deliberate skip into a standing false alarm. So a
  skip carries the **last real fetch forward** (cached beside the state, marked
  `stale`) and never touches `ok`. `ok` therefore means one thing only: the
  most recent *attempted* fetch and whether it succeeded. `ok === false` — the
  banner's trigger — now fires only for a fetch that ran and failed; a skip is
  `ok` unchanged, and a never-yet-fetched page is `ok: null`, neither of which
  is an alarm. The staleness is not hidden: `stale`/`fetched_at` say how old the
  GitHub half is, distinct from the whole page's `generated_at`.
- **Carrying a fetch forward silently is what let a broken cadence hide, so
  the two ages are now both on the page.** The decision above is right, and it
  has a cost: a fetch that is never taken is indistinguishable, on screen,
  from one taken a moment ago. When the launcher's gate turned out never to
  fire under cron (see **Heartbeat**), the page went on reporting "data 3s
  ago" over PR data half an hour old, and every panel rendered perfectly. Two
  things follow, and both are load-bearing rather than decorative. The header
  shows `data <age> · GitHub <age>`, and past 12 minutes the second turns
  amber and raises its own banner — a reader can now see which half of the
  page is old. And the cadence has a test (`test/publish-dashboard.test.sh`,
  driven through `LAUNCHER_PUBLISH_CMD` so it costs no API call) asserting
  that a cold window fetches exactly once, a warm one not at all, and an aged
  stamp is refetched on the next tick. A behaviour whose failure mode is
  *looking healthy* cannot be left to a careful reading of the script.
- **The GitHub tick's gate is a duration, not a point in the schedule.** The
  rule "fetch when the last fetch is older than N" holds whenever the tick
  runs; the rule "fetch on the tick that lands at second zero" holds only if
  such a tick exists, which is a property of cron's alignment, the loop's
  bounds and how long a publish took — three things that are decided
  elsewhere and that no test here was watching. The first rule also degrades
  the way this page wants: on a missed window it fetches late rather than not
  at all, and on a GitHub outage it retries at the cadence rather than at the
  tick rate, because the stamp records the *attempt*.
- **The blocked and void lists are not computed here.** `blocked[]` and
  `void[]` come from the same shared implementation the Script feeds its
  Co-Ordinator (`lib/cycle-state.sh`, per requirement 34a of
  `docs/spec/implementation/README.md`) — `open_blocked_items` and
  `void_items`; only the projection for display is local. The dashboard originally had its own near-copy of the
  rule, and the two silently disagreed — which matters more here than
  anywhere else, because this page is where someone looks to find out why the
  pipeline is repeating itself. A monitor that reimplements the thing it
  monitors will agree with it right up until the moment that would have been
  useful. Anything else the page reports that the pipeline also computes
  belongs under the same rule: share the definition, don't mirror it.
- **A cycle's source is a column, not a detail.** Which source the
  Co-Ordinator drew an item from is not a fact about that one cycle so much as
  a fact about the pipeline: read down the column and you see the mix it is
  actually working — all security this week, or nothing but tech-debt for two
  days. That reading only exists if every row shows it at once, which a
  per-row expand forecloses. The detail row still repeats it verbatim
  alongside the rest of the record; the duplication is deliberate.
- **An outcome is something a cycle has to finish to have.** The Publisher
  classifies a cycle by reading its events against a ladder — `pr-ready`, then
  `pr-raised`, `attempt-failed`, `none-selected`, `stand-down`,
  `cycle-skipped`, `selection` — and that ladder answers the question "how did
  this go?" for a cycle that is over. Asked of one still working it answers
  anyway, in the past tense, and its floor is the worst available reading: a
  cycle whose Co-Ordinator is still choosing has logged nothing on the ladder
  at all, so a job three minutes old rendered as **Ended** for the whole
  length of its first stage. So the column now consults `ended_at` first — the
  `cycle-end` timestamp, which is the only thing in the record that says the
  cycle is over — and reports a state until there is an outcome to report.
  Which state needs one fact the log cannot supply: a `cycle-start` with no
  end looks identical whether the cycle is running or the node died holding
  it, so the row asks the fleet whether any node claims that cycle as its live
  one, exactly as the node cards do, and says **no clean end** when none does.
  That last one is an accusation, so it is withheld where the data cannot
  support it: `data.js` written before the fleet strip existed carries no node
  list at all — which is what a page reloaded from an updated checkout reads
  until the Publisher next runs — and there the row says only **not ended**.
  Nothing is lost by dropping the mid-flight rungs: how far a running cycle
  has got is what the Item, Stages and PR cells beside it already show, and
  they show it without asserting that it stopped there.

  `status.last_cycle` is the same mistake one field over, and is fixed the same
  way: it means "the last cycle the fleet ran, and how it went", both readers
  take a finished cycle for granted — the headers date it by `ended_at`, the
  node cards badge it by `outcome` — and it was nonetheless filled with the
  newest cycle-start, finished or not. So an unfinished newest cycle dated the
  fleet's last activity with a null, which `fmtAgo` renders as an em-dash:
  "last cycle — ago". It now selects the newest cycle carrying an `ended_at`,
  and is null when none has, which the headers already render as no last-cycle
  clause at all. The general rule both cases are instances of: **a field whose
  readers assume a finished cycle must select for one**, because every cycle
  list on this page is newest-first and the newest is exactly the one most
  likely to still be running.
- **A record in the log is not the same thing as a cycle, and the cycle list
  now says so.** The Publisher built one row per distinct `cycle` value in the
  log union, which quietly assumed every record came from a run. Some do not:
  the pipelines' own documented escape hatch for a stuck item is a hand-written
  `unvoided` (README, "Unsticking an item"), and it carries the
  `cycle: "manual"` sentinel. Every such record, from every node, therefore
  collapsed into a single phantom row — and each of the row's cells then
  failed in the direction that looks most like a real problem. With no
  `cycle-start` the Started column falls back to the first event's timestamp,
  so the row was dated to the earliest hand-edit anyone had ever made; with no
  `cycle-end` and no node claiming it, the Outcome column reached for the
  accusation above and read **no clean end**, permanently, of something that
  was never running; with no `cycles/manual` directory the Stages cell showed
  three empty stages. And because the fleet ordering is a reverse *lexical*
  sort of the id — the one sort that interleaves every node's history
  correctly, since a real id begins with its UTC timestamp — `manual`
  outranked every digit and pinned itself above every genuine cycle, holding
  one of the `MAX_CYCLES` slots.
  The fix filters on the id's shape where the list is built, rather than
  special-casing `manual` or re-sorting by `started_at`: the sort is not
  wrong, and a shape filter covers the next sentinel too. Doing it in the
  Publisher rather than the page keeps the events themselves in the log tail,
  which is where a record about the pipeline belongs, and leaves untouched
  every reader that acts on them — the limit stand-down, the blocked and void
  sets — because each keys on the event and the item, never on the cycle.
- **An empty panel states its own cause (the 2026-08-29 blackout).** For ten
  days every dashboard in the fleet reported "No substantive cycles in the
  fleet window" while all four nodes worked normally. Three things had to line
  up. `scripts/publish-revert-rate.sh` began emitting `rework` rows with
  `cycle: null` (#941); the detail render grouped the union by `.cycle`
  without filtering those out, which is a fatal `jq` error rather than a null
  row, and it renders the whole window in one program, so the error cost every
  cycle at once; and that `jq`'s stderr went to `/dev/null` behind a guard
  whose only action was to leave the cache alone, after which the publish
  reported a successful write. The cache then drained to empty as the window
  slid over cycles that were never rendered, and the page — which had no way
  to distinguish an empty list from an idle fleet — supplied a plausible
  explanation for it.
  The filter is the defect fix and is deliberately the same one the file's
  three other `group_by(.cycle)` readers already applied; it was written four
  times and omitted once. But a filter only closes this instance. What made
  the instance cost ten days was that the failure had no way to be seen, so
  the render now reports its verdict twice — to the Publisher's log for
  whoever is reading logs, and in the payload as `cycle_render` for whoever is
  reading the page. The rejected alternative was to make the render failure
  fatal to the publish: it is not, because every other panel on the page is
  still correct, and a page that stops updating is a worse answer than a page
  with one panel that says what is wrong with it. Nor is the cache sweep
  skipped on a failed render — it prunes to the window, which is right
  whatever the render did; it was the render's silence, not the sweep's
  correctness, that turned a fault into a blackout.
- **A no-op tick is counted, not listed (issue #271).** `MAX_CYCLES = 40` was
  sized for an hourly cadence; the `*/15` change (#268) quadrupled the tick
  rate without touching it, and most of the new ticks are no-ops — a
  stand-down short-circuit or a lock-held skip, three events and no stage.
  Filling the fleet's forty detail slots with those cut the window from
  roughly half a day of history to two-to-four hours, most of it rows
  carrying nothing. The two candidate fixes were to raise `MAX_CYCLES`,
  which grows `data.js` — the very thing the fleet-wide cap protects — or to
  stop no-op ticks consuming slots; the second was chosen, with the filtered
  ticks surfaced as the `noop_ticks` aggregate rather than dropped, so the
  cadence itself stays visible (a fleet whose ticks stop aggregating has a
  scheduler problem this line would otherwise hide). The aggregate is O(1)
  by construction — three counts and one timestamp, never a second list —
  and the filter matches the exact three-event shapes rather than every
  `stand-down`/`skipped` outcome, so a stand-down that carries more than
  the shape (a raced one, #245) keeps its detail row and its badges. What
  this costs: a *fresh* stand-down no longer has a row of its own, and its
  reason text is a log-tail read rather than a click — the aggregate's
  newest-tick timestamp and the standing banners (switch, usage-limit) are
  what keep that reading a glance.
  Losing a claim to a peer's contention and then claiming the next
  candidate is not a different outcome from an ordinary first-try
  selection — the cycle still did whatever `outcome` already says, PR raised
  or otherwise — so `raced` is not folded into the outcome ladder as a new
  rung. It is a fact about *how* the cycle got there, rendered as its own
  small badge beside the outcome badge (`↻ raced`, titled with the loss count
  and whether the race was recovered or the cycle stood down over it), the
  same layering the in-flight badge below already uses for "still working"
  beside a floor reading it does not want to overwrite. A `standdown_cause`
  of `"raced"` on a stood-down cycle gets the identical badge, for the same
  reason "Stood down" alone does not say whether the fleet's own contention or
  a GitHub outage caused it — reading the reason text is not a substitute a
  glance at the column can make. A `standdown_cause` of `"pre-claimed"`
  deliberately gets no badge: no peer raced this cycle for anything — its
  Co-Ordinator proposed work the gather had already seen claimed — and the
  row's reason text names that defect; its `claim-skipped` events are also
  what keep the row out of the `noop_ticks` aggregate, so the shape stays
  visible in the history rather than being counted away. Blue, like the "recovered race ×N" badge
  beside the item and for implementation spec 17d's reason: contention is the
  fleet working, and amber on this page is reserved for what wants acting on.
  The two badges do not say the same thing twice, either: `race_losses` is a
  count of this cycle's own `claim-lost` events, so a cycle that lost every
  candidate carries one without ever having claimed anything, and "recovered
  race" is withheld from it — an outcome of `stand-down` is exactly the case
  the word "recovered" would be false of.
  Both badges further require more than one currently *active* node (issue
  #829): `claim-lost`'s cause `held` means some claim already existed when
  this cycle tried to take it, but only an active node ever attempts one
  (`role_current`, `lib/role.sh`) — a standby fetches its peers and serves
  its own dashboard but runs no cycles, so it can never be the peer a claim
  was lost to. With `fleet.nodes` present and at most one node carrying
  `role: "active"` and not itself stale, no peer could have contended for
  anything, so `↻ raced` and "recovered race ×N" render nothing for that
  cycle even though its `raced`/`race_losses` fields are unchanged — the row
  still reads its plain outcome, "Stood down" or otherwise, exactly as if
  the fields were absent. A peer's last-known `role: "active"` from before it
  went stale (issue #1005) does not count toward that total either: a
  heartbeat old enough to be stale (`heartbeat_age_s` past the same threshold
  `nodeUnknown()` reads) cannot vouch for what the peer is doing now, and a
  node that has stopped heartbeating at all cannot be contending for a claim.
  Fleet-less data (no `fleet` key at all) says nothing about how many nodes
  are active, so it is not read as "one" and renders as it always has, and
  fleet data naming two or more active nodes renders both badges
  exactly as before this distinction existed.
- **An overrun-slot count is not a no-op tick, and must not share its gate**
  (implementation spec 11a, agent-ops#1287). `noop_ticks.overlap` counts
  `cycle-skipped {reason: "overlap"}` events — schedule slots supercronic
  silently dropped because the cycle logging them was still running its own
  stages — and that cycle keeps its ordinary row in `cycles[]` regardless: it
  is the opposite of the stand-down/lock-held pair above, which are logged by
  a tick that did nothing at all. Reusing the existing summary line's
  `!agg.total` gate would have hidden the overrun count on any fleet whose
  every cycle does real work — exactly the fleet an operator most needs to
  see it on, since a lightly-loaded fleet with idle-tick no-ops to spare is
  the one least likely to overrun in the first place. The line renders on its
  own condition, `agg.overlap` alone, alongside rather than folded into the
  no-op summary's own sentence, since these firings were never held out of
  the list the way a no-op tick's own are.
- **Distinct classes of data are distinguished by shape, not colour alone.**
  Source tags are outlined and square; outcome badges are filled pills. Both
  are colour-coded, and the two sit side by side, so without the shape
  difference "Failed" and `security` would read as the same kind of label in
  the same red. Colour then carries identity *within* a class, shape carries
  the class itself — which is also the only reason eight source colours are
  legible at all: eight hues is past what hue alone reliably separates,
  especially for a colour-blind reader. Any future class of badge on this page
  should take a third shape rather than a ninth hue. The in-flight badge takes
  the rule the same way: it stays a filled pill, because it sits in the outcome
  column and belongs to that class, and carries the page's existing live/idle
  dot inside it — the same mark the header and the node cards use for the same
  meaning — so "still working" is legible without colour and without inventing
  a shape for a thing that is not a new class of data.
- **The source label/colour map is display-only, and fails open.** The
  vocabulary itself belongs to the Co-Ordinator (`prompts/coordinator.md`'s
  `sources` list) — the page cannot share that definition the way it shares
  the blocked/void rule above, because `data.js` carries only whatever token
  the pipeline already emitted. So the map styles tokens; it never decides
  them. An unrecognised source renders in grey with its raw token, never
  dropped and never silently blank: a source added upstream then shows up
  unstyled, which is a prompt to add a colour, rather than invisibly missing
  from the mix — the one thing the column exists to show.
- **A `nice` badge has to name the Script, because the panel it sits in names
  the Co-Ordinator.** The page's one per-repo surface is headed "Work sources
  (what the Co-Ordinator sees)", and a `nice` is the one ordering input the
  Co-Ordinator is deliberately never given: the Script computes the walk order
  and hands over the finished list, and the values themselves never reach the
  model (pipeline spec, requirement 3). A badge dropped in unqualified would
  therefore make the page assert the opposite of the design, on the surface an
  operator reads precisely when asking why a repo keeps coming up first — and
  the next place that reading sends them is the Co-Ordinator's prompt, where
  there is nothing to find. Hence the note above the panel rather than the
  tooltip alone: a tooltip is invisible to a glance, absent under a finger, and
  this is the half of the answer that decides where someone looks next.
- **A neutral `nice` renders nothing, not a zero.** A repo at `0` and a repo
  with no `nice` key are the same repo, and a fleet that has set none is the
  ordinary case, so neither draws a badge and the note stays off the page
  entirely — a config with no `nice` anywhere renders byte-for-byte the page it
  rendered before the feature existed. This is the same omit-never-empty
  contract `lib/repo-order.sh` keeps for the no-op fingerprint, kept here for
  the matching reason: a neutral config should be indistinguishable from one
  predating the feature, on the page as in the hash. A `nice 0` badge would
  also be the wrong kind of information — three repos each wearing one says
  the weighting is a thing being *used*, when what it means is that nobody has
  touched it.
- **Plan limits are not on this page, because they are not obtainable
  (checked 2026-07-17).** The obvious feature request — show used vs remaining
  credits for the current session and the weekly limit, in the header — was
  investigated and dropped as not buildable, and this note exists so it is
  investigated once rather than every time someone notices the gap. For an
  individual Pro/Max subscriber there is no supported source: no `claude usage`
  subcommand exists; `--output-format json` carries no quota field (see "State
  it reads"); `/usage` is interactive-only; and the Admin/Usage API is
  documented as *"unavailable for individual accounts"* — it needs an
  organisation on Console API billing. The numbers do appear to be cached in
  `~/.claude/.credentials.json`, and that is the temptation to resist: it is
  undocumented internal structure inside a secrets file, so it can change shape
  without notice, and Claude Code itself serves those bars from a cache up to
  an hour stale. A stale limit bar is worse than no limit bar, because it is
  the one number an operator would act on — and it would sit next to a
  freshness clock implying it was current. If a supported read ever ships, the
  header centre is where it goes.
- **Cost is labelled as an estimate, not as spend.** The cards and charts say
  "Est. token cost" rather than "Spend", with a note saying what the figure is.
  They previously said "Spend today", which on subscription auth quietly
  asserts two false things: that the money was charged, and that the dashboard
  is tracking a budget. Someone reading a spend figure next to a pipeline that
  can hit a usage limit will reasonably join those two facts up, and conclude
  the dollars are what runs out. They are not related: the limit is denominated
  in tokens and time, and no arithmetic on this page converts one into the
  other. The figure is worth showing — it is a good proxy for how hard the
  pipeline is working, and it is the only per-cycle cost signal there is — but
  it has to be named for what it measures. A second `p.costnote` underneath
  states the currency (USD) outright (issue #438): every dollar figure on the
  page — cards, charts, the estimate note above it — is the same fixed
  currency regardless of the Claude account's own billing region, and that
  isn't obvious from a bare `$` sign to a reader whose local currency also
  uses one.
- **Cost is cut by actor as well as by model and by day, because the actor is
  the only one of the three anybody chooses.** The day is a fact about when the
  cron fired; the model is nearly a restatement of the actor, since
  `config.json` pins one model per role. What an operator can actually decide is
  which agent does what — whether the Reviewer needs Opus on complex work,
  whether the Enabler is earning its cycles, what a repository review really
  costs against an implementation cycle. None of that is legible from the
  other two charts, and all of it was already on disk: the actor is the
  transcript's own filename, so this cut needed no new field, no new log event
  and no extra API call.
- **The cost charts balance into columns instead of a fixed grid (issue
  #330).** A `.two`/`.stack` split — by-day alone on the left, by-model and
  by-actor stacked on the right — left a gap under the right column on any
  day that by-day's sixty rows ran noticeably longer than the other two
  combined, because the split was pinned at build time to a guess about
  relative height rather than measured against it. `column-count: 2` with
  `break-inside: avoid` on each block instead lets the browser's own balance
  algorithm decide the split from the rendered heights on every load: the
  blocks — day, model, actor, then both cost notes — stay in that reading
  order and simply land wherever the shorter side is, no JS layout code and
  no new data needed.

  What this buys is a split that is right for the data in front of it rather
  than for the data the layout was written against, plus the note's own
  height reclaimed from a gap it used to sit below. It does not flatten the
  section: while by-day holds sixty rows and the other blocks hold five rows
  or fewer each, no arrangement of them fills a column that one of them sets
  the height of, so the right column still ends well short of the left.
  Closing that would mean letting by-day itself break across both columns,
  which buys the space at the price of a chart whose heading stands over half
  of it.
- **"Today" defaulted to GMT with no way to say so, until #186.** The card's
  figure was always `spend_today_usd`, computed against `date -u`, and nothing
  on the page told a reader in another zone that "today" wasn't theirs. Fixing
  that needed two things the Publisher alone can't decide: which reading the
  reader wants, and which calendar day a given cost fell on *for them*. Neither
  is knowable server-side — a dashboard has no fixed reader, let alone a fixed
  zone — so `recent_costs` ships raw `{ts, cost}` rows (three days back, ample
  padding either side of any real zone or of a `last 24h` window) and the
  arithmetic for "local" and "24h" runs client-side, against `new Date()`. The
  chosen mode is `localStorage`, not a query param or a server-side setting: a
  dashboard has no accounts and no URL a reader necessarily bookmarks, and a
  choice that reset on every visit would answer #186 no better than not asking
  at all. `spend_today_usd` itself is untouched — GMT stays the default and the
  cheap path when a reader never touches the toggle.

  Adding it exposed that the roll-ups were **not totals**. The scan read
  `cycles/` and not `reviews/`, so the Project Reviewer — the most
  expensive actor per run — contributed nothing to spend-today, spend-total,
  by-day or by-model. That is a worse fault than a missing chart: the numbers
  were not per-pipeline, they were simply short, and nothing on the page said
  so. Both directories are now scanned. The figures step up on review weeks;
  they were wrong before, not inflated now.
- **A pull-request number is rendered by one widget everywhere, and it carries
  its record.** `#89` on its own says almost nothing, and the click that would
  explain it costs a context switch — enough friction that nobody spends it
  while scanning, which is what this page is for. So every number on the page
  goes through one renderer that attaches a record card: repo, title, state,
  author, opened/merged times, the merge commit, labels, and — while it is open
  — checks, review decision and mergeability. It is deliberately generic rather
  than special-cased per panel, and the newest use is the one that proves the
  point: on a fleet card the number *is* the version statement, so the record
  behind it is the whole of what makes the card readable.

  Two things keep it honest. The card names **the cycle that raised the PR**,
  joined client-side out of the cycle list rather than recorded anywhere — the
  pipeline already logs `pr_url` per cycle, so the join cannot fall out of step
  with the table three panels down, and it costs nothing. And a number with no
  entry yet says exactly that, rather than rendering an empty card: an index
  miss is the ordinary state of a PR raised since the last fetch, not an error.

  **The card is a peek on hover and a pin on click, and a click does not follow
  the link.** Hover was the whole interaction to begin with, and on a phone
  there is no hover: the tap that opened the card was the same tap that left
  for GitHub, so the card flashed and the page was gone. That is the reader who
  needs it most — a phone is where the dashboard gets checked away from a desk,
  and where opening GitHub to answer "did that land?" costs the most. So a
  plain click now opens the card and pins it, and the *View on GitHub ↗* link
  the card already carried is the way through.

  The two modes are kept apart, because mixing them is what makes this
  pattern annoying elsewhere: a card opened by hovering closes by unhovering,
  and a card opened by clicking closes only by clicking — off it, on the number
  again, on its close button, or `Escape`. A pinned card therefore neither
  evaporates when the pointer drifts nor chases the pointer onto the next
  number along, which matters because reading one is a deliberate stop. The
  close button exists for the pinned case alone: dismissing by "tap the blank
  page behind it" is not an affordance anyone can see, and the number that
  opened the card is under the reader's own thumb.

  Navigation is not lost, only unbound from the plain click. Modifier and
  middle clicks still open the PR, the `href` stays on the anchor so the status
  bar and "copy link address" tell the truth, and `Enter` still navigates —
  keyboard focus already opens a peek without spending the activation, and the
  card is not in the tab order behind the link, so pinning it from the keyboard
  would strand a reader in front of links they could not reach.

  The index is affordable because a **merged or closed pull request is
  immutable** — cached permanently by ref, so a warm tick spends nothing however
  many numbers are on screen — and because the cold fill is bounded to a few
  references a tick, since forty `gh pr view` calls at `GH_TIMEOUT` each would
  not fit in the heartbeat's window. Its reference set is gathered from the page
  itself, which is also what stops the cache growing: it holds what is on
  screen, and needs no expiry rule of its own.
- **A node's version is a pull-request number, and the image has to be told
  it.** "Which version is this container running?" had no answer anywhere. A
  fleet is *routinely* mid-update — `watchtower-pre-update.sh` defers a roll
  while a cycle is in flight — so nodes differing is normal, and the question
  that matters ("has the fix reached the node that needed it?") could only be
  answered by exec'ing into containers. The answer is now on the card.

  It is a pull-request number rather than a SHA because a SHA names the bytes
  and a pull request names the change: `#89` has a title, a diff, a review and a
  merge time behind it, and the widget above puts all of that one hover or one
  click away.
  The commit is shown too, abbreviated and linked, for anyone reconciling
  against `docker image inspect`. And the image cannot work either out for
  itself — `.dockerignore` keeps `.git` out, correctly, because the image is a
  deployment and not a working tree — so CI stamps `build-info.json` at build
  time and `lib/version.sh` falls back to git for a checkout. A peer's version
  travels in its heartbeat, since a peer publishes no container; a peer that
  publishes none reads as *unknown* rather than inheriting ours, on the same
  rule as every other derived peer fact.

  The `behind` marker is grey, not amber. Being behind is the expected state
  during a roll, and colouring an ordinary condition as a warning teaches an
  operator to ignore the colour. What it is there to catch is a node that stays
  behind — a watchtower that has stopped rolling — which shows up as the marker
  failing to clear, and which nothing else on this page would reveal.

  Beneath the version sits the node's *deployment file*, which the image
  cannot answer for: a node holds its own `compose.yaml`, no roll can update
  it, and a merged compose change sat inert on every node twice before
  anything said so (#131). The card renders the heartbeat's compose-drift
  verdict (implementation spec 2.5, `lib/compose-drift.sh`) as a badge —
  **compose drifted** when the node's copy differs materially from the copy
  its image shipped, **compose unverified** when the file is not mounted into
  the containers at all, which itself means the file predates the check and
  is behind. Both are amber where `behind` is grey, deliberately: `behind`
  resolves itself on the next idle poll, while a drifted compose resolves
  only when something acts on it, and an amber that never clears by itself is
  exactly the alarm that was missing. `in-sync` renders nothing, and so does
  an absent verdict — a peer on an image from before the check, or an install
  that is no container — because for an image the roll already on its way
  will start answering, and a node whose rolls have stopped is the version
  line's `behind` failing to clear, already caught above.

  Beside those badges, on the same line, is what that node's own reconciler
  did about the drift: the heartbeat's `compose_reconcile` verdict
  (implementation spec 2.5a, `lib/compose-reconcile.sh` — the actor the drift
  badge had no counterpart for until the `reconciler` service existed). It
  renders on the same discipline as everything else here, which leaves three
  of its five states visible. **reconcile refused** is amber: the node
  will not apply the merged file — its project directory is not configured,
  or the new file needs a `${VAR}` this node's `.env` does not define — and
  nothing will change until a human acts, which is the one state that stays
  put. **reconcile deferred** is grey, `behind`'s colour and `behind`'s
  reasoning: a cycle is in flight, a watchtower roll is due, or a recreate
  failed, and the next tick a few minutes away retries it. **reconcile
  applying** is grey for that same reason and shown for one of its own: a
  sibling container is recreating that node's stack at this moment, which
  resolves itself on the next tick — but it is also the state a node is left
  in when the apply's own container does not come back, and an apply that
  began with nothing anywhere saying so is what left `ockham-container`'s
  stack down for five hours (implementation spec 2.5a, agent-ops#1913). Its
  title says when the apply began — the verdict's `since`, since `at` is
  rewritten by every tick that finds the apply still running — what clears it
  and what to do if it does not. `reconciled` and
  `in-sync` render nothing,
  because a `reconciled` verdict has already cleared the drift badge beside
  it. Each badge's title carries the recorded reason verbatim. An absent
  verdict also renders nothing, and that is the common case rather than an
  edge one: a node whose owner has not run the one enabling `up -d` has no
  reconciler, and its card reads exactly as every card did before this
  existed — the drift badge, and the per-node ritual in its title. The
  verdict is the node's own and is never derived here for a peer, on the
  same rule the compose verdict above follows: only that node's container
  holds that node's project directory and its Docker socket.
- **The `behind` version marker cannot tell a uniformly stale fleet from a
  healthy one, so a second badge compares against the registry instead
  (#155).** `behind` (above) compares nodes with each other —
  `fleetNewestVersion()` — which is exactly what reads as agreement when
  every node adopts the same broken image at once, as happened across
  #149/#154: four nodes, four identical commits, four green cards. The image
  badge (`lib/image-drift.sh`, via the heartbeat) instead compares each
  node's own commit against `ghcr.io/pullwright/agent-ops:latest`'s own
  `org.opencontainers.image.revision` label — read anonymously over the
  registry's API, never `origin/main`, since a documentation-only merge
  publishes no image at all and would otherwise read as false staleness (see
  "The node stack" in the implementation-pipeline spec).

  **image behind** is grey while the registry's newest image is younger than
  `image_behind_grace_hours` (`config.json`, surfaced in `config`) — the same
  colour and the same reasoning as the version line's own `behind`, since the
  same explanation applies. Past the grace it turns amber, `compose`'s
  colour: by then the ordinary deferred-roll explanation has had time to
  resolve itself, and a node still behind may have a watchtower that has
  stopped rolling altogether. **image unverified** is its own grey badge
  rather than silence — unlike compose's absent-verdict case, nothing else
  on the page would otherwise say the registry check was even attempted,
  whether because it failed outright or (routinely, right after this code
  first rolls out) a peer's heartbeat predates it. `current` renders
  nothing, the same rule every other in-sync verdict on this page follows.

  The registry query is a real network round trip, unlike every other field
  on this card, so it is not repeated on the dashboard's 5-second tick:
  `<state_dir>/.image-drift-cache.json` (excluded from state-sync
  replication, like the other local caches) holds the last answer, and
  `scripts/state-sync.sh`'s own heartbeat push shares the same file, so
  whichever of the two next crosses `IMAGE_DRIFT_TTL` pays the one query.
- **Neither `behind` nor `image behind` can catch an update mechanism that
  has stopped working altogether, ahead of and independent of the drift it
  eventually causes (#603).** On 2026-08-14 watchtower tried to create two
  replacement containers it had never stopped, hit a name collision, and
  logged `Session done Failed=2` on every poll thereafter while the node
  stayed on the previous image — through a fleet roll the other three nodes
  had already taken. Every badge above still read healthy, because none of
  them read the update mechanism's own verdict, only the staleness it
  eventually causes. The card renders the heartbeat's updater verdict
  (implementation spec 2.5, `lib/updater-health.sh`) as a third badge below
  compose and image. The verdict is this node's own worst *live* one across
  every container sharing its `pre-update` label, not only the container
  that published the heartbeat (agent-ops#1037) — `u.host`, when present,
  names which sibling ledger it came from, and the badge's title makes that
  sibling the roll's subject ("the roll of the sibling container on
  `<host>`") rather than a suffix a reader could miss; absent, the subject is
  "this container's roll" and the verdict is this heartbeat's own container's.
  The badge itself reads: **updater deferring**, grey, naming how long
  `deploy/docker/watchtower-pre-update.sh` has been holding that roll
  back for a cycle or review in flight — it resolves the moment that
  ends, the same colour and reasoning as `behind`, and only while that defer
  streak stays inside `updater_defer_stuck_after_seconds`. **updater stuck**,
  amber, `compose`'s colour for a fault only a human clears, in either of two
  shapes the badge's title distinguishes (`u.reason`): the hook allowed a
  roll — on every poll since the time named, watchtower asking again each
  time — and the container it allowed is still the one running — same
  hostname, so watchtower never actually replaced it — and the retry that
  follows repeats the very operation that collided, so it will not clear on
  its own; or the defer streak above has itself outlasted
  `updater_defer_stuck_after_seconds`, past which no lock the hook honours
  could still be legitimately held, so "an implementation cycle or review is
  in flight" is no longer a true reading. Both shapes hold only while
  watchtower is still asking: `updater_status` reads liveness first
  (implementation spec 2.5, agent-ops#1071), and a hostname whose own newest
  ledger entry has itself gone older than `updater_stuck_after_minutes`
  renders no badge at all rather than a permanent **updater stuck** — the
  node's watchtower has stopped polling that container altogether (taken
  down deliberately, or the container itself retired), which is a different
  fact from either amber shape above and not one this badge asserts.
  `rolled` (the ordinary case), an absent verdict — a peer whose heartbeat
  predates the check, or one still inside the short window before its own
  first poll — and any other status this page does not recognise (a future
  release, or a truncated/corrupt heartbeat field) all render nothing, the
  same absent-means-unknown rule `compose` and `image` already follow: an
  unrecognised status is routed explicitly to "render nothing" rather than
  folded into `deferring`'s benign badge, the same way `image`'s own
  `unverified` branch is routed explicitly rather than folded into
  `current`'s silence.
- **A crash-loop run the Script has classified `transient` renders as a
  fourth badge, below updater, rather than as an escalation issue (issue
  #1073).** `lib/crash-loop.sh`'s `crash_loop_verdict` groups consecutive
  Co-Ordinator failures by their identical `detail` for requirement 2.7's
  escalation ladder; what it could not previously say is whether the API was
  refusing a request outright (deterministic, will not clear by retrying) or
  simply unreachable (a 5xx, a dropped connection — external, and self-
  clearing). On 2026-08-29/30 the Ockham host lost outbound network for four
  hours, every failure recorded a 503 verbatim, and the only signal of it was
  a crash-loop escalation asserting "almost certainly deterministic … no
  amount of retrying will clear it" — false on the escalation's own evidence,
  and gone the moment the network returned. A run whose `escalate` field
  reads `false` — every failure it counted classified `transient` — now never
  reaches that escalation at all; the Publisher reads the same union log
  directly (`fleet_logs`, not the heartbeat: this is a fleet-wide fact, not
  one only the affected node can report on its own behalf) and renders
  **provider unreachable**, amber like `updater stuck` — a fault worth a
  human's attention, but not one this node's own code caused — on every
  node the run's own `nodes` names, titled with the consecutive count, the
  repository the run belongs to where it has one, the
  verbatim detail, and how long the run has been going. It renders nothing
  the moment no such run is currently active (the newest verdict's
  `escalate` reads `true`, or no run has reached `crash_loop_after` at all)
  — there is no separate "cleared" state to track, since the union log is
  read fresh every publish and a Co-Ordinator success for that same
  repository, anywhere in the fleet, ends the run the same way it already
  ends the escalating case. `crash_loop_verdict` counts per repository
  (agent-ops#1630) and so can name more than one transient run at once; the
  Publisher keeps only the first, since this field holds a single verdict —
  a narrowing agent-ops#1624 tracks rather than one this badge hides, so an
  absent badge is not evidence that no other repository is in the same
  state.
- **A fifth badge reads the host-facts record a node's own collector
  writes (`scripts/collect-host-facts.sh`, agent-ops#1283,
  `docs/HOST-FACTS-SCHEMA.md`), a fact source none of the four badges
  above can reach: each of them reads what runs *inside* the scheduler
  container, and the D24 fence puts this container on the far side of its
  own host's real network path, so nothing above can tell a host's own
  egress MTU, a container's own OOM-kill count, or a Kubernetes rollout's
  own stall from in here.** The Publisher folds `state_dir/host-facts/
  <node>.json` (self) and `<peers_dir>/<peer>/host-facts/<peer>.json`
  (each peer) into that node's row as `host`, `null` when no record
  exists for that node yet — the collector's own schedule, not this
  page's 5-second tick, so a freshly rolled node reads `null` here for a
  while exactly as it does for `compose`/`image` above. The card renders
  one amber badge, **host degraded**, naming the worst of three facts it
  checks for, in this order: an MTU mismatch between `DOCKER_MTU` and the
  host's own measured egress MTU (`host.network.mtu_match`) — the same
  fact `doctor.sh`'s Egress section now reads from the identical file,
  here because a card is checked far more often than `doctor.sh` runs;
  any container this node runs having been OOM-killed at least once
  (`containers[].memory.oom_kill_count`); or a Kubernetes Deployment stuck
  below its desired replica count past its own progress deadline
  (`rollouts[].stalled`).
  Everything else the record carries — per-container memory/cpu figures,
  a per-container image digest mismatch, the updater ledger tail — stays
  out of this badge deliberately: it is either routine, or already
  covered by `image`/`updater` above, and is one click away in the raw
  record for anyone who needs it. This node's own viewer-vantage self-probe
  (`viewer_probe.<this node>`, agent-ops#1286's own check) is excluded too,
  for a different reason than routine: the collector ships with no route to
  a peer's tailnet (#1339), so every compose node's self-probe fails from
  its first tick regardless of health, and folding it into this badge would
  light every card permanently rather than flag a real fault. The probe
  still runs and its result is in the record for anyone reading it
  directly; it rejoins this badge once #1339 gives it a route to succeed on
  a healthy node. No badge (and no line at all) when the record is absent
  or carries none of the three facts above.
- **A sixth badge, `resource budget`, compares this node's own measured
  CPU/memory/bandwidth/disk against `config.json`'s `resources` budgets
  (requirement 55, D14, agent-ops#606)** — the dashboard's half of the same
  comparison `doctor.sh`'s own "Resource budgets" section makes, over the
  identical `resource_budget_report` derivation (`lib/resource-usage.sh`).
  The rule is stated twice, not shared: `doctor.sh` calls
  `resource_budget_breaches`, and this page — JavaScript in a browser, with
  no route to a bash library — re-states it in `resourcesLine`, so keeping
  the two in step across an edit is a maintenance obligation, pinned by
  `resource_budget_breaches`'s own boundary test. The row's
  `resources` field (self: recomputed live from this node's own
  `.resource-samples.jsonl`; a peer: carried in its heartbeat, `null` when
  the peer predates this feature or has not run its collector yet) is the
  windowed `{latest, median/growth, p95}` report per container/volume;
  `D.config.resources` is this run's own resolved (schema-defaulted)
  budgets. Amber, titled with every breach found — each named as
  `<container>'s <resource> (p95 <actual> > budget <budget>)`, or for a
  volume, `<volume>'s disk usage (<actual> > budget <budget>), growing
  <n> bytes/day` when the report has a growth figure — on the same "badges
  only for an exceptional condition" discipline `host degraded` above
  already holds: a container or volume within budget contributes nothing,
  so the badge itself, not just its absence, is the signal. Growth rate is
  named ahead of the bare figure for a disk breach because D21's lever rule
  requires it: "this volume has grown every day for thirteen days" is the
  sentence a human actually needs, not an isolated byte count. Every other
  figure the report carries — a container's own latest/median, a resource
  nobody has budgeted — stays out of this badge on the same "routine, one
  click away in the raw record" reasoning the host-facts badge above
  already gives for per-container memory/cpu; the full report is in
  `D.fleet[<node>].resources` for anyone reading it directly. No badge when
  the row carries no `resources` field at all.
- **The role badge shows the role the node published**, green for `active`
  and grey for anything else, and that is the published value rather than a
  guess: both publishers normalise it (implementation spec 2.5,
  `lib/role.sh`'s `role_declared`), so `ROLE=Active` reaches the page as
  `active`, and a process that was handed no role at all publishes
  `unknown`, which the badge shows as `unknown` rather than quietly reading
  as `standby`. The page is not the only reader — requirement 51's
  `firing-missed` exempts a node whose role is a standby's — so an invented
  `standby` would be a claim with consequences.
- **A seventh badge, `mirror rebuilt`, surfaces the heartbeat's mirror-rebuild
  verdict (implementation spec 2.5, `lib/mirror-integrity.sh`,
  agent-ops#604/#997)** — a fact that reached every node's own heartbeat from
  the day #604 shipped, but reached no dashboard until now: a human learned
  their disk had quietly damaged a state-sync mirror only by running `jq`
  over a peer's `heartbeat.json` directly, having first thought to suspect
  it. The row's `mirror` field (self: read from this node's own
  `.mirror-rebuild-state.json`; a peer: carried in its heartbeat, `null`
  when the peer predates this field or has never had to rebuild) is `null`
  until this node's state-sync push has had to discard and rebuild its
  mirror at least once, else `{status: "rebuilt", count, last_rebuilt_at}`.
  Amber, `compose`'s colour for a fault worth a human's attention — a
  rebuild does not clear itself the way a deferring updater does — titled
  with `count` and, where known, how long ago the most recent rebuild was:
  a single rebuild is a transient a git fetch/prune already recovered from,
  but `count` climbing on one node is the failing-disk pattern the verdict
  exists to catch, which is only useful to whoever sees it. No badge when
  the row carries no `mirror` field, or the field is `null` — the same
  absent-means-unknown rule the compose and image badges already follow.
- **A node-scoped disable (implementation spec 2.3, `--disable --this-node`,
  issue #379) gets its own badge beside the role badge**, not just the
  page-top switch banner. The banner (above) is keyed to *this* node's own
  switch, so it already covers a node-scoped disable on the node whose page
  you are reading — but the fleet strip shows every node, and a peer's own
  node-scoped disable sets no fleet flag and appears in no banner at all.
  Without a per-card badge, a peer stood down that way is indistinguishable
  from an idle one, on the same page that goes to some trouble to say so for
  a fleet-wide disable. Amber, **disabled**, titled with the reason, who set
  it and its expiry — the same three facts the switch banner leads with, read
  through the same `toggle_switch_summary` (`lib/toggle.sh`) so the two
  cannot disagree (requirement 34a). Renders nothing when the node is
  enabled, and nothing when the field is absent (a peer's heartbeat from
  before this check existed) — the same absent-means-unknown rule the
  compose and image badges already follow, never a false "enabled" for a
  peer this node cannot actually answer for.

  It also renders nothing for a record tagged `scope: "fleet"` while the fleet
  flag is set: that record is the mirror a fleet-wide `--disable` leaves on the
  node that issued it, and badging it would single that node out of a fleet
  that is uniformly down. A mirror whose fleet flag has since been cleared is
  the exception and the reason the tag is worth carrying — it badges amber and
  says what it is, since that node is genuinely down alone and no banner on the
  page explains why. A record with no `scope` reads as `"node"`, matching
  `lib/toggle.sh`.
- **Blocked and void are shown as separate lists**, never merged into
  "items not being worked". They ask opposite things of the person reading:
  a blocked item may need them to clear its path; a void item needs nothing
  unless the verdict itself is wrong, and reopening one is a deliberate act
  only they can perform (appending `unvoided` to the log by hand — say so on
  the page, since it is the only escape hatch and it exists nowhere in the
  UI). Collapsing them costs the operator the one distinction the pipeline
  cannot make for itself.

  Separate lists means *separate*: an item holding both marks is void
  (implementation spec 34h) and belongs to the void list alone, which is why
  `blocked[]` is `open_blocked_items` and not `blocked_items`. It is not a
  corner case. `item-void` clears no block, so every `void` verdict the Enabler
  reaches — its ordinary way of retiring work that turned out to be already
  done — leaves the `attempt-failed` before it standing, and the page listed the
  item in both tables from then on. On the fleet that found this, fifteen of the
  sixteen rows under "Blocked items" were items the pipeline had already
  finished with, the oldest of them a fortnight dead, and the panel that exists
  to say *the pipeline is stuck on these* was reporting a backlog that had been
  cleared. The heading's count is the part that misleads fastest: it is read at
  a glance, by someone deciding whether to intervene at all.

  **The void list is capped and the blocked list is not**, for the same reason
  they are separate. Void is the page's one unbounded list of work nobody need
  act on: rows only accumulate — a hand-appended `unvoided` is the sole way one
  leaves — while the panels that do want an answer sit below it, so left whole
  it eventually pushes failed cycles and the work sources off the screen with a
  list whose entire message is "nothing to do here". Blocked is the opposite
  and is never capped: hiding a row there hides work. So void shows its ten
  newest rows, each clipped to three lines, and both caps open where they are —
  a `See more` at the foot of the table, any row expanding to its full text on
  a click — because the Enabler's reason *is* the row, and a truncation that
  could not be undone would leave the one question a void item ever raises
  ("is this verdict right?") unanswerable on the page. The heading keeps
  counting every void item rather than the rows shown, so the number read at a
  glance stays the fleet's.

  Ordering is part of that cap, not a nicety beside it: `void_items` groups by
  repo and item, so a cap over the list as it arrives keeps whichever ids sort
  first, which answers no question anyone has. The page sorts newest-first
  before slicing, making the kept rows the ten most recent verdicts — the ones
  a mistaken void is most likely to be among, and the only ones whose `Since`
  column then reads in order.

  The blocked list then makes one further distinction *within* itself, in its
  `Escalated` column: an item waiting on a human through an open issue, versus
  one still the pipeline's own to clear. That column is a link when the Enabler
  has raised an escalation (implementation spec 36a) and the Enabler's last
  verdict otherwise, because those are two quite different messages to the
  reader — "nothing will happen here until you act" and "the pipeline looked at
  this properly and is still working on it". Before it, both rendered as an
  identical row of prose, and the one item on the page that had been *addressed
  to the operator* looked exactly like the four that had not. The link is
  deliberately the escalation issue rather than a copy of its text: the issue is
  where the ask is maintained, and closing it is the whole protocol.

  A blocked row also carries `kind` (implementation spec 34e), and a row whose
  `kind` is `needs-refinement` gets a **refinement** badge and counts toward a
  "hide N refinement blocks" filter beside the panel's heading (TD26072603). An
  ordinary block is waiting on the world — a merge, a fix, an answer already
  asked for — and the Co-Ordinator is expected to clear it once that changes. A
  refinement block is waiting on the pipeline's own Enabler and, past one
  refinement, on escalation — `escalation_autonomy` deciding whether that
  reaches a human straightaway or is adjudicated first: reading "blocked: 9"
  with no way to tell the two populations apart understates how much of the
  backlog is a specification gap rather than a stalled merge. The filter
  defaults to showing both — hiding is
  an explicit, per-session choice, never the page's default view — because the
  count in the heading is itself information ("that many things need
  attention"), and defaulting to hidden would bury exactly the population this
  change exists to surface.
- **The live indicator says what, not just that.** The header's running dot
  once reported only that a cycle was in flight and since when; the item it was
  working on lived several panels down, in the cycles table. But "what is the
  pipeline doing right now?" is the exact question a glance at the header is
  for, and making the operator scroll to answer it defeats the point of having a
  live indicator at all. So the running state now carries `status.current` — the
  live stage and the selected work — rendered inline beside the dot, reusing the
  same source-tag vocabulary as the cycles column so the two read as one thing.
  It is *derived, not newly logged*: the id/pid tie between the lock and the
  running cycle's events is enough to reconstruct it from state already on disk,
  so the reader gains the answer without the pipeline emitting anything new or
  the Publisher making an extra call. The fields appear in the order the cycle
  learns them — stage first, then repo/item/title once the Co-Ordinator selects
  — which doubles as a coarse progress read: a header stuck on `coordinator`
  with no item is a cycle still choosing; one naming an item under `implementer`
  is a cycle at work.
- **With a fleet, "what is it doing" has one answer per node, so it is asked per
  node.** The readout above was designed when a node and the pipeline were the
  same thing, and it sat in the header because there was one of it. Once several
  containers run at once, a single header readout has to pick one node's work to
  stand for every node's — and whichever it picks, the reading a glance takes
  from it ("the pipeline is on TD26071401") is false. So the live state moved
  down to the fleet strip, one full readout per card, beside the identity and
  freshness that say whose it is; the header keeps the shape of the question it
  can still answer for the whole fleet — *how much of it is working* — and drops
  the part it cannot. A single-node page is unchanged, header detail included:
  with one node there is nothing to summarise, and the fleet strip does not
  render at all.

  Three things follow from a peer's state being *derived from its published log*
  rather than observed. Its card is dated ("as of its last push, 2m ago") rather
  than presented as now. A peer whose heartbeat has gone stale reports **state
  unknown** instead of last half-hour's news dressed as current — the one
  reading that would be actively misleading. And a cycle still "running" past
  `lock_stale_after` is flagged as possibly dead, because a node killed
  mid-cycle leaves precisely the trace of one still working: a `cycle-start`
  with no end, for ever. Our own row is exempt from all three — the lock is a
  live pid, not an inference — but it gets the mirror-image case: a dead lock
  over an unfinished cycle is reported as **no clean end**, which is what a
  stopped container leaves behind and which "idle" would quietly
  absorb.

  A fourth reaches the same verdict far sooner, and is the one that fires in
  practice. A stage still live past its own backstop has outlived the timer
  that would have killed it, so the cycle is over whatever the log says; a
  Co-Ordinator is bounded in tens of minutes where `lock_stale_after` is
  several hours, and a node rolled mid-cycle sat in that gap reading
  "coordinator choosing work". The cap it is held against is the one that
  stage was given, announced on its own `stage-start` (requirement 4f), so the
  rule follows a backstop that moves without needing to be told. Judged against the node's own heartbeat, never the reader's clock, so
  the verdict is about what that node published and not about how long ago it
  published it. Our own row is **not** exempt from this one, unlike the three
  above: a live pid proves the cycle script is alive, not that the stage it
  last logged still is — and were that script alive, its own timer would have
  ended the stage.
- **The page refreshes its data in place, not by reloading.** The heartbeat
  once published every 5 minutes and the page reloaded itself every 60s with
  `location.reload()`. When the heartbeat moved to ~5s
  (`publish-dashboard-launcher.sh`), a full reload every few seconds was
  unusable: it collapsed every expanded cycle row, closed open transcripts,
  flashed the screen and snapped scroll to the top. So the one-shot render was
  made re-runnable and the refresh now re-fetches `data.js` and re-renders in
  place. Two properties keep that cheap and non-disruptive. It re-renders
  **only when the data actually changed** — comparing a signature that omits
  `generated_at` (which moves every publish) — so an idle pipeline's open tabs
  sit perfectly still. And the fetch is an **injected cache-busted `<script>`,
  not `fetch()`**, so the page keeps loading from a `file://` URL with no
  server and no CORS — the same reason the initial load uses a plain
  `<script src>`. Expanded rows, open `<details>` and scroll position are
  carried across the re-render in two small keyed maps. One deliberate
  consequence of only-on-change: the relative "3m ago" cells stop advancing
  while the pipeline is idle and catch up the moment new data lands — the
  header's own staleness clock keeps ticking, so freshness is never in doubt.
- **`data.js` itself is only fetched when it might have changed** (issue
  #1288). "Cheap and non-disruptive" above was still true only *after*
  paying to download `data.js` on every tick — 2.7–2.9 MB measured on real
  nodes, continuously, whether or not the underlying state had moved: about
  45 GB/day per tab left open, and over a slow enough path (agent-ops#1286)
  a single tick took longer than the interval it was fired at, so the tab
  never caught up at all. The fix keeps the cache-busted `<script>`
  injection (a tab still needs no server) but adds a second, few-dozen-byte
  sibling, `stamp.js`, carrying `{generated_at, fingerprint}` — the
  Publisher's own no-op-skip fingerprint (below), which by construction
  changes exactly when `data.js`'s content might have. Every tick fetches
  `stamp.js`; `data.js` follows only when its `fingerprint` differs from the
  one the tab last loaded. `generated_at` still ticks the header clock on
  every tick regardless, so the staleness display is exactly as live as
  before — only the multi-megabyte fetch became conditional. Two follow-up
  correctness fixes to the first version of this: a `data.js` fetch that
  failed used to advance the tab's fingerprint anyway, permanently wedging it
  on stale data with no retry; and the page's first load — a plain
  `<script src>` pair, not the refresh tick's cache-busted one — used to seed
  that fingerprint from `stamp.js`, which a publish landing between the two
  requests could answer for a newer publish than the `data.js` the tab
  actually got. See "the client" above for both.
- **The dequeued warning is the Publisher's own memory, not GitHub's timeline**
  (agent-ops#375, D17). The obvious first design reads `merge_queue_probe`'s
  `dequeued_at`/`dequeue_reason` straight through — the same fields
  `scripts/sweep-human-visibility.sh` already posts a notice from — but that
  field answers "when did this pull request last leave the queue", not "does
  it need a human's attention right now", and the two come apart exactly the
  way agent-ops#394 found against the sweep's own use of it: the timeline
  read fires on a removal from arbitrarily long ago, even after a later
  re-queue, because nothing in it says "and nothing has changed since". A
  dashboard badge that could relight itself off ancient history is worse than
  none, so instead the Publisher keeps its own `{queued, warn}` per pull
  request across ticks (`<state_dir>/.dashboard-queue.json`) and derives
  `dequeued` from the transition it itself observes — `warn` sets the tick
  `queued` flips `true` → `false`, holds while it keeps reading `false`, and
  clears the moment `queued` reads `true` again. That is strictly a
  comparison this Publisher can make about *this* pull request's *current*
  state, never a re-reading of a GitHub event that predates the question.
- **A capped work source says how much it is hiding, not just what it shows**
  (agent-ops#1171). The open-issues panel reads one REST page (`per_page=30`)
  and the tech-debt panel keeps only the top 40 rows, both for the reasons
  given above — but neither cap used to say so: a repo at 47 open issues or
  120 open tech-debt items rendered identically to one that genuinely had 28
  or 40, and the panel is headed "what the Co-Ordinator sees" on a page an
  operator reads precisely to judge whether the pipeline is keeping up.
  `issues_total` and `tech_debt_total` fix that without changing what either
  cap fetches or shows. The issues listing is a plain REST page with no
  `.total_count` of its own, so its total costs a second call — the Search
  API's `.total_count` (the same read `lib/pager-invariants.sh` already makes
  for a different invariant) — best-effort and never promoted to a real
  failure: it is its own endpoint with its own, tighter rate limit, and a
  miss on a cosmetic total the main listing never needed has no business
  joining `gh_fail_msgs` or flipping `github.ok` — it simply leaves
  `issues_total` `null`, which the page reads exactly as it read a `data.js`
  from before the field existed. The tech-debt listing, by contrast, *is*
  already a Search API call (issue #881), so its own `.total_count` comes
  back in the same response as the rows — free, and always a number whenever
  that one call answered at all. The page itself only ever adds text: "N of
  M" replaces a bare count solely where the total is a known number greater
  than what is shown, so a healthy, uncapped repo (`total` absent, `null`, or
  equal to the count) renders precisely as it always has.
- **The tech-debt ledger reads a label search, not the frozen register**
  (issue #881, following D15 as revised, #869). Every register in the fleet
  is now frozen (#880 and its sibling issues in the other repositories) and
  tech debt lives instead as `pw::type:tech-debt`-labelled GitHub issues, so
  the `contents/tech-debt` listing this panel used to read had quietly
  stopped answering the live ledger — it still returned 200, but against an
  archive that no longer grows. The fix reads the same source the
  Co-Ordinator itself now does (`scripts/gather-tech-debt.sh`): a search for
  open `pw::type:tech-debt` issues. The dashboard's own read is a plain
  Search API call rather than that gatherer's paginated GraphQL walk,
  because the panel only ever needs `{id, title, status, url}` and a total —
  never the issue bodies or comment threads that walk exists to fetch. This
  also retired the per-tick miss budget and the blob-SHA-keyed metadata
  cache (`<state_dir>/.dashboard-td.json`) the old listing needed: a search
  answers every row it can show in the one call that also answers the total,
  so there is nothing left to warm across ticks.
  `scripts/gather-register-status.sh` was considered for retirement alongside
  this change but left untouched: it answers a different question (whether a
  `Blocked-by:` reference naming a pre-freeze register id has since
  resolved, implementation-pipeline-spec requirement 34i) for a caller
  (`lib/candidate-select.sh`) that has nothing to do with this panel, and
  retiring it would have silently broken that caller's own legacy-reference
  clearance.
- **Union readers stream rather than slurp** (agent-ops#1649). A `jq -s` over
  the fleet-wide event union materialises every parsed event in one process
  — about five bytes of resident memory per byte of log: 396 MB on a
  77.7 MB union under `jq` 1.6, 208 MB on a synthetic 42 MB one under
  `jq` 1.7 — so a Publisher built from a dozen such readers has a working
  set that is a linear function of a log `scripts/rotate-logs.sh` never
  rotates, and any memory ceiling sized for it expires as the log grows.
  The readers therefore fold the stream (the Publisher section above lists
  what each one keeps), and each computes what its whole-array form
  computed over the same log, failing where that one failed: a record that
  is not an object aborts a reader that indexed every record (and fails the
  detail window's render) rather than being skipped, and is dropped by the
  readers whose whole-array form dropped it. Five things about the form are
  load-bearing.
  - *One declaration per reader.* A reader gathers only the event types it
    declares, so a program that reads a type its declaration lacks sees
    none of them and reports a quiet zero. Each declaration is written once
    — `union_reader_events` for the Publisher's own readers, a `<NAME>_EVENTS`
    variable beside each library fold's `<NAME>_JQ` — and the gathering
    step reads it; `test/union-stream.test.sh` fails when a program reads a
    type its declaration does not name.
  - *One pass for many readers.* `union_partition` writes every
    declared reader's kept events in one parse of the union, rather than
    each reader parsing the whole union for itself.
  - *One span helper.* `union_stream` and `union_partition` close their
    kept events with the span of every record (`{"span": {"lo", "hi"}}`), and
    `union_split_span` parts that from the events on the consumer's side. The
    span has two rules because the whole-array readers computed two things:
    `any` (`.ts // empty`, the empty string counted) is what
    `[ .[] | .ts // empty ] | min`/`max` gave the scorecards and the
    stage-gap series, and `nonempty` (`.ts // ""` without the empty string,
    gated by SINCE) is what the sorted non-empty timestamps gave the
    item-lifecycle and fleet-sizing windows; each reader keeps its own rule,
    so its output is unchanged. A stream that aborts writes no span line,
    and the consumer slurps only a stream that exited cleanly, so a
    truncated stream is never folded as though it were the whole log.
  - *`|=`, never `as`, in a `reduce`.* A `reduce` keeps its one map at the
    top of the accumulator and updates an entry with `|=`, never through an
    `as` binding of anything read from the accumulator: the binding is a
    second reference to the map, so every update copies all of it and a
    linear fold turns quadratic (measured: 20,000 updates of a 3,000-key map
    take about a second that way under `jq` 1.7, against about an eighth of
    that with `|=`).
  - *Raw lines for an uncleaned union.* A union no `read_events` has cleaned
    is read `-R` with `fromjson? // empty` per line, because plain `inputs`
    aborts at the first spliced record.

  The readers that still hold log-scale data do so by construction or are
  not yet converted (agent-ops#2042): the item-lifecycle fold gathers every
  item-scoped event (`records[]` is each item's whole history), and the
  readers of its output — the rework panel, spend by fate, turns per landed
  item and exclusive landings — load that output whole; four of the pager's
  invariants (`lib/pager-invariants.sh`, on a GitHub tick) gather the union
  unfiltered; and `limit_union_record` reads through `lib/limit-detect.sh`'s
  own reader (agent-ops#2037).
- **The working set is the publish's `TMPDIR`, and the rebuild is a child,
  not an `exec`** (agent-ops#1827, #1933). A publish spools through its own
  `mktemp` calls and through those of a dozen libraries, and the 2026-09-28
  incident (`docs/spec/implementation/design-decisions.md` §Design decisions) showed
  what a working set removed by one trap and library files removed by none
  leaves behind. Pointing `TMPDIR` inside the working set makes the one
  removal cover every spool without a trap in every library, and naming the
  set after the pid lets the sweep of requirement 2.5 tell a dead publish's
  set from a live one's, which age cannot: a publish has run for hours on a
  loaded node. The fast tick's `exec` into a full build was the one exit
  that ran no trap by construction, and it leaked a set per rebuild; a
  child costs the fast tick's set for the rebuild's duration and needs no
  second place that must remember what the trap does. The signal traps the
  issue proposed were not adopted: bash runs the `EXIT` trap on an untrapped
  fatal signal, so they would have tested nothing, and a trapped signal
  would have held the hook past its `timeout`. What the `TERM` case did
  find, once it sent the signal the way `timeout` does, was a straggler: a
  command forked between `timeout`'s first signal and bash's next check,
  which never receives the second and recreates an entry after the removal
  has listed the directory — hence the rename before the removal.
