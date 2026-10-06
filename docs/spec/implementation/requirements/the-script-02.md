## Requirements

### The Script — requirements, continued (part 2 of 10; 2–2.3: Stand-down checks…)

2. **Stand-down checks.** Each check logs its reason and exits cleanly:

   Before check 0 below, and before every other check in this list: which
   GitHub credential this cycle *would* currently use is logged
   (`forge_auth_effective_gh_token`, component 14h, D25/agent-ops#607 as
   amended by agent-ops#1021) — but, since agent-ops#1021, nothing here
   resolves or exports one. A forge authoring App installation token carries
   GitHub's ~1 h lifetime, and a cycle routinely outlives that, so no single
   point in the process can resolve a credential once for its whole life
   without risking a stale one reaching whichever call comes after expiry.
   The credential is instead resolved on demand, per call, by the on-demand
   seam (component 22c): every `gh` invocation reaches `lib/gh-shim.sh`'s `gh`
   transport shim, installed ahead of the real binary on `PATH`, before
   dispatch, and plain `git` reaches the same shim through its own
   credential helper (`deploy/docker/entrypoint.sh`, component 7). Both mint
   only when `GH_TOKEN` is already
   empty — an explicit `GH_TOKEN` always passes through untouched, which is
   what keeps `lib/approver.sh`'s own
   `GH_TOKEN="$(approver_token_get)" gh …` posting as the Approver rather
   than being re-minted as the author. This step has no number of its own in
   the list below because it never itself stands the cycle down and changes
   nothing any check after it reads — it only logs which path 0b's probe two
   steps later, and every later call in the process, would resolve through
   the seam. Unnumbered rather than "0aa" or similar, since renumbering
   0a–0c would touch every cross-reference those letters already have
   elsewhere in this document.
   0. *GitHub API budget*: before any other check, read the meter — the
      `x-ratelimit-*` headers of one metered `GET /meta` for `core`, and the
      GraphQL `rateLimit` object for `graphql`, assembled into one snapshot by
      `github_limit_snapshot` — and stand the cycle down when either metered
      pool is below its floor —
      `core` below `github_min_core_budget`, or `graphql` below
      `github_min_graphql_budget`. Either floor set to `0` turns that
      resource's check off; both at `0` turns the check off entirely. The
      `stand-down` event carries the binding resource, its remaining points,
      and `resume_at` — which is GitHub's own stated reset, never an estimate,
      so unlike a usage-limit stand-down (1b) nothing probes it and nothing
      needs to. When both pools are below their floors the one resetting
      **later** binds, so the stand-down covers both.

      First, because it is the cheapest check — two points, against the
      thousands every check below it can spend, 1b's probe most literally.
      What it prevents is not a failed `gh` call but
      the cycle those calls sit inside. On 2026-08-12 an exhausted GraphQL
      budget read to the pipeline as a quiet GitHub: every gatherer degraded
      to `[]` (the `[]`-on-error trap in the Gotchas table), the Co-Ordinator
      engaged on that digest and selected an item, the claim was taken, and
      the cycle died at the clone with `GraphQL: API rate limit already
      exceeded`. Everything before the clone was spent answering a question
      GitHub answers for free.

      A meter that cannot be read is **not** a stand-down. An unreadable meter
      is no evidence about the budget, and a node that cannot reach it could
      not have run a cycle anyway; whatever call meets the real fault will
      report it. Standing down here would give a network blip the same face
      as an exhausted account.

      **Not `GET /rate_limit`** (agent-ops#1087). That endpoint is exempt from
      the limits it reports, which made it the obvious probe; it is also, read
      cold, not a reading. On 2026-08-30 three metered calls seven seconds
      apart, each followed within the same second by the endpoint, showed the
      response headers draining the shared bucket (`x-ratelimit-used` 92, 105,
      118 against one fixed reset) while the endpoint's body answered `used:
      0, remaining: 5000` every time with a `reset` exactly 3600 s from *now*,
      sliding with the clock — and the endpoint's own headers said the same.
      It is intermittently right, and nothing in the answer says which kind it
      is. Read as the first call of every cycle, it answered `ok` through 95
      recorded refusals in 48 hours. The headers on any *metered* response are
      computed on the request and describe the bucket GitHub enforces — the
      **user's** aggregate, so the whole fleet's, the publisher's and the
      owner's shell together, which makes this gate fleet-aware with no
      per-node arithmetic — and GraphQL's `rateLimit` object is the same kind
      of reading for that pool. A body-shaped snapshot that carries the
      empty-window signature — `remaining == limit`, nothing used, `reset`
      within `GITHUB_LIMIT_PRISTINE_SLACK` seconds of now + 3600 — is
      classified `unknown`, never `ok` (`github_limit_resource_pristine`); one
      real pool beside such an answer is judged on the real one. A refused
      probe still answers with the headers, which is also how 0a's wrapper
      reads a reset off the very refusal it is handling. `GET /rate_limit`
      remains what 0b's credential probe and the token-expiry read use: both
      want the call's status and headers, not its budget figures.

   0a. *A refusal shorter than the cycle is waited out, not reported.* The two
      GitHub limits divide by how far away their reset is, and this is the near
      half. `lib/github-limit.sh` defines a `gh` shell function that shadows the
      binary for every script sourcing it: a call GitHub refuses for rate
      reasons is retried once, after waiting until the stated reset (a primary
      limit) or a fixed short fallback (a secondary limit, for which GitHub
      states no reset anywhere `gh` surfaces). A wait longer than
      `github_retry_max_wait_seconds`, or than twice that across one process,
      is not taken at all — the cycle holds a lock and runs on a
      `cycle_interval_minutes` tick, so waiting out a primary limit inside one
      would collide with the next tick. That case belongs to 2.0, not here.

      The binary is reached with `command gh`, so a test's `PATH` stub is still
      what runs. A call invoked through `timeout`, `env` or `xargs` bypasses
      the wrapper, which is why `scripts/publish-dashboard.sh` — every call of
      which is deliberately under `timeout` to hold the heartbeat's window — is
      unaffected. stdout is buffered and emitted once the call is finished
      with, so a retried `gh api --paginate` cannot emit its early pages twice.

   0b. *GitHub credential check* (agent-ops#691, TD-PPagop-26082306): the same
      free `/rate_limit` call classifies two permanent credential faults apart
      from every transient failure — `github_auth_probe`
      (`lib/github-limit.sh`) prints `unauthorized`, rather than folding
      either into 2.0's `unknown`, for an HTTP 401 (GitHub read the request
      and rejected the credentials outright) **and** for `gh` refusing to send
      the request at all because it has no credentials — `GH_TOKEN`/
      `GITHUB_TOKEN` unset or empty and no `gh auth login` session either.
      Both are permanent: no wait and no retry ever clears an expired,
      revoked or absent token. Checked unconditionally — not gated behind
      `github_min_core_budget` / `github_min_graphql_budget`, because a dead
      or missing token is worth catching even on a node that has turned the
      budget floor off, and the call costs nothing either way.

      On 2026-08-22 a node's fine-grained PAT expired mid-day, and for the
      next ~3 hours every cycle ran a full Co-Ordinator engagement ($0.21,
      ~66 s, ~51k tokens) before every claim failed with `cause:
      "unreachable"` and the cycle stood down reporting "GitHub could not be
      reached for any candidate — this is an outage, not contention" — five
      cycles, $1.05, for a token that was never going to start working again
      on its own, misclassified in the one way that sends nobody looking at
      it. TD-PPagop-26082306 is the same misclassification in a different
      shape: a token unset or dropped from the environment makes `gh` fail
      locally with a "no authentication token / run `gh auth login`" message
      that matches neither the 401 pattern nor anything else, so it read as
      `unreachable` too and bought the same indefinite per-cycle spend. This
      check exists to stop paying for that discovery: it runs ahead of the
      Co-Ordinator (step 4), so an `unauthorized` verdict stands the cycle
      down before any model runs — for
      `GitHub authentication failed (HTTP 401) — GH_TOKEN is invalid or
      expired` when GitHub rejected a real token, or for
      `GitHub authentication failed — no GH_TOKEN/GITHUB_TOKEN is set and gh
      has no stored credentials` when there was no token to reject, the probe's
      own `detail` (leading "no token present" rather than an HTTP status)
      being what tells the two apart — and escalates through
      `create_escalation_issue` in `crash_loop_repo` — labelled
      `enabler_escalation_label`, assigned `enabler_assignee`, item ref
      `auth-failure:<node>`, titled and worded to match whichever of the two
      it is — the same duplicate-guarded route 1c's usage-limit freeze and
      requirement 2.7's crash loop already use, so a cycle that finds an open
      issue already naming this node does not file a second one. A failed
      filing logs a `warning` and retries next cycle, same as 1c.

      Deliberately **not** routed through `escalation_autonomy` (D18,
      agent-ops#627): that ladder decides whether one specific escalation —
      an Enabler refinement-disagreement (requirement 36b) — is adjudicated
      once before reaching a human, and its `adjudicate-first` path is itself
      a model engagement against GitHub. Routing a dead-credential escalation
      through it would spend exactly what this check exists to avoid, and
      there is no refinement disagreement here to adjudicate. Skipped
      entirely on `--dry-run` and when `crash_loop_repo` or
      `enabler_assignee` is unset, the same as 1c's freeze escalation — the
      stand-down itself is unconditional, only the filing is gated.

   0c. *Free disk space* (requirement 2.0c, agent-ops#756; both directories,
      agent-ops#992; the threshold derived, agent-ops#904): free like 0 and
      0b — `df -Pk` touches no network and costs nothing, so it runs ahead of
      every check below that can spend, and reading the fleet's own union log
      for the derivation below costs nothing further either, since `union_log`
      is already a local, already-fetched snapshot by the time this runs (1a).
      `scripts/doctor.sh` (component 14) has read `state_dir`'s and
      `workspace_root`'s free space and warned below a fixed 2 GiB since
      before this check existed, but that warning only ever reached a human
      running `doctor.sh` by hand; the cycle itself wrote straight into
      whatever room was actually left. On the ockham laptop that ran short, a
      write truncated mid-flight left zero-length git objects in both nodes'
      `state_dir` mirrors, permanently disabling `git gc` (#604), and left
      4.2 GB of orphaned clones in `workspace_root` behind it (#605) —
      starting work the host cannot finish is what made both possible, and
      this gate covers both directories the incident spanned.

      `lib/disk-space.sh` reads and judges free space the one way both
      `doctor.sh`'s advisory warning and this gate use, so the two cannot
      silently disagree about what "low" means, nor about which directories
      that covers, nor about which bound governed: `disk_space_free_kb` reads
      a directory's free KiB (empty, never `0`, when `df` cannot read it — an
      unreadable meter is no evidence of a full disk, the same reasoning 0's
      own `unknown` rests on), `disk_space_verdict` compares it against the
      *effective* threshold below (converted to KiB), `disk_space_describe`
      renders the one-line explanation both the stand-down event and the
      warning use verbatim, and `disk_space_same_filesystem` reports whether
      `state_dir` and `workspace_root` share a filesystem.

      The threshold this gate actually reads is not `min_free_workspace_bytes`
      alone but `disk_space_effective_min_bytes`'s derivation over it — a
      flat floor protects a fleet whose repositories stay far below it, but
      says nothing about one whose repository approaches or exceeds it, which
      is exactly the gap agent-ops#902 raised against #756's own PR #782 and
      #904 was filed to close. `disk_space_clone_footprint_bytes` (`du -sb`
      the clone directory, the same reading `workspace_orphans`,
      lib/workspace.sh, already takes) is measured once every successful
      `clone_repo` completes — agent-cycle.sh's own workspace step (6) and
      review-cycle.sh's own — and logged as a `clone-footprint` event,
      `{repo, bytes}`, against the cloned repository's own slug. The review
      pipeline writes it to the *shared* `log.jsonl` rather than its own
      `review-log.jsonl` (`docs/spec/review.md` R16's second shared
      exception, `limit-hit` being the first), because this is where its reader
      is. The figure is never GitHub's own reported repository size, which is
      the packed size, not what a clone occupies, and never a network call this
      gate would have to pay for. `disk_space_largest_footprint`, reading `union_log` the same
      "governing record off the fleet's own union" shape requirement 2.1's
      `limit_union_record` already uses, returns the single largest
      `clone-footprint` ever recorded, fleet-wide, unfiltered by which
      repositories are configured *now* — a footprint from a repository since
      dropped only ever pushes the derived threshold higher, never lower, the
      safe direction to err in. Nor does it age: a footprint recorded long ago
      and never bettered still governs today, with no expiry pruning it out.
      Where this unfiltered, unaged read proves too conservative on an
      installation whose repositories have shrunk since setting the fleet's
      largest recorded footprint, `workspace_headroom_factor` set to `0` is
      the operator's own lever — distinct from `min_free_workspace_bytes`'s
      own `0` below, it disables only the derivation, leaving the floor
      itself in force (agent-ops#1904, ratifying #904).
      `disk_space_effective_min_bytes` then derives
      `max(min_free_workspace_bytes, workspace_headroom_factor × that
      footprint)`: `min_free_workspace_bytes` is the floor *under* the
      derivation, never a ceiling, the same shape `lock_stale_after`
      (requirement 4f) and two of the three state-sync count keys
      (requirement 1d; `state_local_streams_retained` is the exception)
      already use elsewhere. With no footprint ever recorded — a fleet's first cycle,
      or a union log this node cannot read — the floor alone governs, failing
      in the same safe direction `disk_space_verdict`'s own "unreadable is not
      low" already does. `disk_space_governed_by` reports which bound actually
      produced the effective threshold, `"floor"` or `"derived"`, so a
      `stand-down` event or `doctor.sh` warning can say so rather than only
      report a number a reader would have to re-derive to interpret.

      Where the two share a filesystem — the common case, one host directory
      holding both — the gate takes exactly one `df` reading and judges it
      once, precisely as it did before this covered two directories. Where
      they differ — the shipped `deploy/docker/compose.yaml` mounts `state:`
      and `workspaces:` as two separate named volumes — the gate reads and
      judges each on its own (shared) effective threshold and stands the
      cycle down when *either* reads `low`; when both do, the `stand-down`
      event names the one with less free space. An unreadable `df` is "no
      evidence", not a stand-down, for either directory.

      Below the threshold, the `stand-down` event's `path` and `free_kb` name
      the short directory (the shorter of the two when both are), `cause` is
      `disk-full` when that directory's filesystem reports exactly zero KiB
      free, or `disk-low` for any smaller shortfall — both cover the same
      gate, differing only in how far past the threshold the shortfall runs —
      and `governed_by` and `min_bytes` name which bound produced the
      threshold and what it was, with `repo` and `footprint_bytes` added
      whenever `governed_by` is `"derived"`. `min_free_workspace_bytes` set to
      `0` turns the check off entirely for both directories, *regardless of
      any footprint recorded* — the same unconditional-off convention
      `github_min_core_budget`/`github_min_graphql_budget` use. That off switch
      lives inside `disk_space_effective_min_bytes` itself — a `0` floor
      derives `0`, whatever footprint it is handed — not only in this gate's
      own short-circuit around the whole block, so `scripts/doctor.sh`, which
      has no such short-circuit, cannot end up warning about a threshold
      derived over a floor an operator has explicitly switched off.

   0d. *The budget is recorded* (agent-ops#1087). `github_budget_record`
      (`lib/github-limit.sh`) takes a snapshot and logs it as a
      `github-budget` event — `{phase, stage?, readable, core: {limit, used,
      remaining, reset} | null, graphql: {…} | null, since_previous: {core,
      graphql, window_rolled}}` — at three points: `cycle-start`, the very
      reading 0's verdict then judges (recorded whether or not a floor is
      set, since the record is what D25's "measured to bind" trigger reads);
      `stage`, after every model run `run_model_stage` (`lib/stage-run.sh`)
      completes, naming the stage; and `cycle-end`, after the Enabler and the
      Refiner and before the `cycle-end` event, but only for a cycle that
      took the opening reading — an ending that never read GitHub (the
      switch, requirement 2.3) must not start now. `since_previous` is the
      bucket's movement since this process's last reading: within one window
      the difference in `used`, across a roll (the two `reset`s differ) the
      new window's `used`, flagged `window_rolled` as the lower bound it is,
      and `null` where either side lacks a figure or the count went
      backwards. A reading that cannot be taken is recorded `readable: false`,
      never skipped, and never fails the cycle or the stage. Each reading
      costs two points; a cycle with three stages costs ten.

      What the movement is, and is not: while every node authenticates as one
      user (D25 unprovisioned) the headers describe the user's aggregate, so
      a segment's movement is the *bucket's* — an upper bound on what the
      segment itself spent, exact only once identities are per node or a
      per-call ledger exists (agent-ops#1084). `scripts/github-budget-report.sh`
      (component 22b) sums the events and says so in its preamble.

   0e. *A `gh` transport shim makes REST reads conditional, serves
      last-known-good under a refusal, and ledgers every call*
      (agent-ops#1084). `since_previous`'s own upper-bound caveat (0d, above)
      is because every node authenticates as one user and the `x-ratelimit-*`
      headers describe that shared bucket, not any one caller's own spend —
      and because almost every GitHub read this fleet makes re-reads
      something a sibling node, or this same node's own last cycle, already
      read minutes earlier: four nodes each gather every configured
      repository on a 15-minute tick, and GitHub's own guidance is that a
      conditional request answered `304` does not count against the primary
      limit at all. `scripts/gh-shim.sh` (backed by `lib/gh-shim.sh`) is
      installed on `PATH` ahead of the real binary (`deploy/docker/Dockerfile`)
      so every `gh` call resolves to it first — this repository's own
      scripts (through `command gh`, `lib/github-limit.sh`'s own retry
      wrapper included) and a model-driven stage's bare `gh …` alike, which
      no library-level wrapper can reach.

      Only a plain `gh api <endpoint>` **GET** is ever cached or
      conditioned: not a call whose method resolves to non-GET (an explicit
      `-X`/`--method`, or gh's own default-to-POST when a body-supplying
      flag — `-f`/`-F`/`--raw-field`/`--field`/`--input` — is present with no
      override), not the literal `graphql` endpoint (always POST, never
      conditional), and not a call that already asks for `-i`/`--include`
      itself — most notably 0's own `github_limit_snapshot` probe, whose
      entire job is reading the bucket's *live* headers, so it must never be
      answered from a cache or a stale reading. Every one of those is passed
      to the real binary completely unmodified: same argv, same stdout, same
      stderr, same exit status. A `--paginate`/`--slurp` GET is conditioned
      too (agent-ops#1114), but not as a single request: a stale
      `If-None-Match` applied uniformly to every page a `--paginate` call
      fetches could 304 a later page whose content actually changed, so
      `gh_shim_handle_paginate` drives the walk itself — one real-binary call
      per page, page 1 the caller's own endpoint with a default
      `per_page=100` appended to its query string when neither it nor the
      caller's own args already name one (mirroring the real binary's own
      default for a paginated GET, so a walk that asks for no page size does
      not fall back to GitHub's 30-item server default instead), and every
      later page the previous one's own `Link: rel="next"` URL, each
      conditioned on that page's own stored `ETag` and cached the same way an
      ordinary `read` is, but under a cache key of its own namespace: page
      1's per-page argv is byte-identical to the argv a caller running the
      same endpoint without `--paginate` sends, and an entry a plain `read`
      wrote carries no `next`, so sharing one entry between the two would
      have a later walk `304` on it, read `next: null`, stop, and return page
      1 alone as the whole merged document. A page is conditioned on its own
      stored `ETag` only when that page's own last fetch found a further
      page (a non-`null` stored `next`); a page whose stored `next` is
      `null` is always re-fetched in full, unconditioned, never served
      `If-None-Match`. This is because GitHub answers a conditional request
      with the validators alone and no `Link` header at all, so a `304`'d
      page can only ever continue the walk from its own already-stored
      `next`, never from a live header — were a page whose stored `next` is
      `null` conditioned like any other, GitHub's count-based pagination
      means an append-only collection's final page can grow a real next page
      between walks while its own bytes, and so its `ETag`, stay identical:
      it would `304`, revealing nothing, and the walk would end on the stale
      `null` forever, silently dropping everything appended since. The pages
      are
      reassembled to match the real binary's own documented shape exactly,
      never reparsed: `--slurp` wraps every page's own raw body as its own
      array element; `-q`/`--jq`/`-t`/`--template` present re-runs that
      filter once per page in the real binary too, so every page's own
      already-filtered body is concatenated in call order; otherwise every
      page's body is expected to be a top-level JSON array, merged by
      splicing out each page's own outer `[`/`]` and joining with `,` — the
      separator belonging to the element that follows, so a page that is
      itself an empty array, or whose inner bytes are whitespace only,
      contributes neither an element nor a comma, as GitHub serves an empty
      array for any `Link: rel="next"` that outlived the items behind it,
      a `next` the shim itself stored and walked on from a later `304`
      included. A page
      that does not fit — a status other than a cache-backed `304` or `2xx`,
      unparseable output, or (plain-array mode) a body that is not itself an
      array — abandons the walk before printing anything partial and falls
      back to one real-binary call with the caller's own argv and
      `--paginate`/`--slurp` both untouched (`_gh_shim_paginate_legacy`,
      this pathway's entire behaviour before agent-ops#1114), which is also
      the only pathway a refusal is ever served last-known-good through
      (property 2, unchanged by this) — from the same whole-call cache entry
      a successful per-page walk also writes its merged result into. A
      write's invalidation only ever reaches that whole-call entry and page
      1's own relative path, never a later page's own absolute one, which
      costs at most one needless extra round trip on that page's own next
      fetch, never a wrong answer, since a `304` still depends on GitHub's
      own `ETag` match. The whole call is ledgered `hit` when every page
      served from its own `304` and `miss` when at least one page needed a
      real fetch — the one ledger entry that says more than "a call
      happened", surfacing the saving this closes agent-ops#1114 for in
      `scripts/github-budget-report.sh`'s own summary. A walk's final page
      is never conditioned (acceptance check 2p, agent-ops#2183), so the
      `hit` branch of this rule never currently obtains — every call that
      reaches a final page ledgers `miss` on that page's own real fetch
      alone.

      No pathway ever reshapes what the real binary printed. A conditioned
      read is the only call whose argv the shim adds to at all; what it
      returns on stdout is byte-for-byte the body a plain call would have
      printed — the response body taken from past the header terminator by
      byte offset, never reassembled line by line, so a body carrying CRs or
      ending without a newline round-trips unchanged. Output the shim cannot
      parse into responses at all is passed through rather than dropped,
      with the real binary's own exit status.

      A cacheable GET is retried with the stored `ETag` as `If-None-Match`;
      a `304` is served from the cache with exit 0. A primary rate-limit
      `403` (`github_limit_kind`, reused from 0a's own retry wrapper rather
      than re-implemented, so the two can never recognise a refusal
      differently) or a `5xx`, with a body cached within
      `PW_GH_STALE_CEILING_SECONDS` (default 3600), is served last-known-good
      with a `PW_GH_CACHE=stale age=<s>` line on stderr and exit
      `PW_GH_STALE_EXIT_CODE` (default 0, so an ordinary reader degrades
      gracefully; a caller that must not act on stale data sets this to a
      distinguishable code). A successful write drops the cache entries for
      its own path and that path's parent resource (a review `POST` to
      `.../pulls/5/reviews` invalidates both that listing and `.../pulls/5`
      itself) — a heuristic, not a semantic model of the API — and does so
      at a cost that does not depend on how many reads the node has cached:
      the cache is laid out as
      `http-cache/<identity>/<sha256(path)[0:24]>/<key>.json`, so a drop is
      the removal of the two directories the write names and never a scan
      that opens entries (agent-ops#1422). `PW_GH_NO_CACHE=1`
      opts one call out of all of this, still ledgered as a bypass.

      Every call is logged to `state_dir/gh-shim/ledger.ndjson` —
      `{ts, method, path, status, cache: hit|miss|stale|bypass, resource,
      used}` — under `flock`, and a cacheable GET that yielded ratelimit
      headers updates `state_dir/gh-shim/budget.json`, keyed by identity —
      `app-<app id>-<installation id>` for a token the seam minted itself
      (requirement 2.0e's own `gh_shim_resolve_token`, below), so the hourly
      rotation of an installation token keeps its cache and its budget
      reading, and a hash of `GH_TOKEN`/`GITHUB_TOKEN` for every other
      credential, since the forge authoring App and the owner's own PAT can
      legitimately see different data. `PW_GH_STATE_DIR`
      carries the resolved `state_dir` to wherever the shim runs — both
      `agent-cycle.sh` and `review-cycle.sh` export it once they compute
      `state_dir`, so every subprocess they fork, model-driven stages
      included, finds the same node's state without needing config.json of
      its own. `scripts/rotate-logs.sh` bounds the ledger's size like the
      node's other diagnostic logs (component 21); `scripts/github-budget-report.sh`
      (component 22b) sums it by cache outcome fleet-wide, the same
      `state_dir`/peers union `log.jsonl` already reads.

   0f. *Free host memory* (requirement 2.0f). Free, and for the same reason
      as 0c: reading `/proc/meminfo` touches no network and costs nothing, so
      it runs ahead of every check below that can spend. 0c refuses to start
      a cycle into a host that has no room to finish it; this refuses to
      start one into a host that has no memory to run it, which until this
      check existed nothing did. On the ockham WSL2 host — a VM capped at
      6 GiB, running two nodes whose cycles overlap for most of every hour —
      a cycle that started into no headroom pushed the VM into a
      Windows-backed swap file and stalled the whole machine; a git write
      truncated by that stall is what left the zero-length objects that
      permanently disabled `git gc` (#604). A stand-down costs one cycle, and
      the freeze it avoids costs the host.

      `lib/memory.sh` reads and judges free memory the one way both
      `doctor.sh`'s advisory warning (component 14) and this gate use, so the
      two cannot silently disagree about what "low" means:
      `memory_available_kb` reads the host's available KiB (empty, never `0`,
      when `/proc/meminfo` cannot be read — an unreadable meter is no
      evidence of an exhausted host, the same reasoning 0's own `unknown`
      rests on), `memory_verdict` compares it against `min_free_memory_bytes`
      (converted to KiB), and `memory_describe` renders the one-line
      explanation both the stand-down event and the warning use verbatim.

      Two deliberate choices about *which* meter. **MemAvailable, not
      MemFree**: the kernel's own estimate of what an allocation can have
      without swapping, which counts reclaimable page cache as available —
      MemFree would read a host whose cache is doing its job as critically
      short and stand down every cycle on a healthy machine. And **the
      host's, not this cgroup's**: `/proc/meminfo` is not namespaced, so a
      container reads the real machine, which is the only figure that
      describes what a gate protecting the host must protect. The cgroup's
      own accounting would describe this container alone and miss the peer
      node, the editor, and everything else sharing the machine.

      Below the floor, the `stand-down` event's `cause` is `memory-low`, and
      it carries both the available and the total KiB so a reader can tell a
      small host from a busy one. There is no `memory-full` counterpart to
      0c's `disk-full`: a host at exactly zero available memory is not a
      distinct state worth naming, only a more extreme shortfall.
      `min_free_memory_bytes` set to `0` turns the check off, the same
      convention `min_free_workspace_bytes` and
      `github_min_core_budget`/`github_min_graphql_budget` use.

      What this check does **not** do is make the container give memory back.
      It cannot: Docker exposes no `memory.high` setting, and a container can
      read its own cgroup v2 files but never write them. What Compose *can*
      choose is the cgroup the container is created **under**, and a ceiling
      on that parent governs the container while outliving it — so the knob
      that stops a cgroup ratcheting up to its hard ceiling is set once, on a
      parent, rather than re-applied to each new container after every roll.
      `AGENT_OPS_SCHEDULER_CGROUP_PARENT` selects it and
      `scripts/cgroup-parent-setup.sh` creates it; both are documented in
      `deploy/docker/compose.yaml`. The parent is the mechanism precisely
      because it is not what gets recreated: a ceiling written onto the
      container itself is wiped by the next `up -d`, watchtower roll or
      reboot, which on the measured fleet is a median of under an hour — and
      on a `systemd`-driver host by any `systemctl daemon-reload`, on a live
      container, since systemd re-applies the properties a unit declares and a
      `docker-<id>.scope` declares none (TD-PPagop-26090401). A slice parent
      declares `MemoryHigh`, so the same reload re-asserts it.

      What the pipeline contributes is still the detection —
      `memory_cgroup_verdict`, reported by `doctor.sh` (component 14) — and
      it draws the distinction the remedy turns on. A ceiling on the parent
      reads `parented` and is `[ ok ]`; a ceiling on the container itself
      reads `bounded` and now **warns**, naming itself as something the next
      roll will remove, because a state that is correct today and gone by
      tomorrow is not a healthy one to report as such. The parent's ceiling
      is not inferable from inside a cgroup namespace — the container's own
      `memory.high` reads `max` either way — so it is bind-mounted read-only
      at `/run/cgroup-parent/memory.high`, defaulting to `/dev/null`, which
      reads as "no parent ceiling" rather than as a guess.

      A ceiling on the parent is not, by itself, enough: `memory.high` only
      throttles, and throttling that never disengages because nothing
      anywhere is a hard enough wall to reclaim past — or to kill — is a
      livelock, not a mitigation (agent-ops#1305). `ockham-container` wedged
      75 minutes in exactly this band: `memory.current` sat above the
      parent's `memory.high` and below both cgroups' `memory.max`, 2,788,595
      throttle events accumulated at ~96/second, and every allocating task
      parked in uninterruptible `D` state — `docker exec` into the node
      included, which is what made the node undiagnosable remotely while it
      lasted. `doctor.sh`'s own `parented` verdict read this exact state as
      `[ ok ]` throughout, because `parented` only ever checked that the
      parent's `memory.high` sat below the child's own `memory.max`, never
      that the parent had a `memory.max` of its own for the kernel to
      reclaim past. `scripts/cgroup-parent-setup.sh` therefore also sets the
      parent's `memory.max` (`--max`, defaulting to the sum of what runs
      under it — `1536m`, matching `AGENT_OPS_SCHEDULER_MEMORY`'s own
      default) and `memory.swap.max` (`--swap`, defaulting to `0` — the
      incident also took 100% of host swap on a memory-capped WSL2 VM), and
      `--check` now exits 2 for a parent whose `memory.high` is set but whose
      `memory.max` is not. Two more mounts alongside `/run/cgroup-parent/
      memory.high` — `AGENT_OPS_SCHEDULER_CGROUP_MAX` at `/run/cgroup-parent/
      memory.max` and `AGENT_OPS_SCHEDULER_CGROUP_EVENTS` at
      `/run/cgroup-parent/memory.events`, the same `/dev/null`-default idiom
      — let `memory_cgroup_verdict` read the parent's own hard ceiling and let
      `doctor.sh` read the parent's raw throttle counter. `memory_cgroup_verdict`
      gains two verdicts from this: `livelocked` (a real parent `memory.high`
      with the parent's own `memory.max` either left at `max`, or a real
      number that is no higher than the child's own — either way nothing the
      child can reach reclaims or kills before it, so throttling never
      disengages — warns, and is never `[ ok ]`) and `unconfirmed` (the same
      real parent `memory.high`, but the parent's own `memory.max` window
      cannot be read — an un-migrated `compose.yaml`, or a node not yet
      re-run through `cgroup-parent-setup.sh` — warns rather than guessing
      `parented`, since a guess given as `[ ok ]` is exactly what left this
      incident's node wedged for 75 minutes). `parented` itself needs the
      parent's own `memory.max` to sit *strictly above* the child's, not
      merely to exist: agent-ops#1620 measured `ockham-container` livelocked
      for most of 2026-09-16 with a real parent `memory.max` (1536 MiB)
      coincident with the child's own — a hard ceiling that exists but adds
      no headroom over one the child already has is inert in exactly the same
      way an unbounded parent `memory.max` is, because the kernel's reclaim
      under `memory.high` throttles severely enough near a shared ceiling
      that the workload never makes enough progress to reach either kill
      point. Nor is a `memory.max` strictly above the child's own enough by
      itself: agent-ops#1643 extrapolated from both incidents that the band
      is reachable whatever the parent's `memory.max` is, so a parent
      `memory.max` (say 3072 MiB) genuinely above the child's own (1536 MiB)
      would still livelock if the parent's `memory.high` (say 768 MiB) sat
      far enough below the child's own `memory.max` — more than ~25% — for
      the kernel's reclaim under `memory.high` to throttle too severely
      across that wide a band for the workload ever to make progress toward
      either kill point. The live discriminator `parented` needs is therefore
      the throttle band's *width* (the parent's `memory.high` against the
      child's own `memory.max`), not merely whether the parent's `memory.max`
      sits above the child's — a narrow band, such as the interim
      `ockham-container` remedy's own (parent `memory.high` 1400 MiB against
      a `memory.max` of 1536 MiB, an ~8.9% gap), still reads `parented`.
      `doctor.sh` additionally reads the parent's `memory.events`
      `high` counter every run, persists one sample to `state_dir`, and warns
      on any rising delta since the last one — a signal that needs no ceiling
      to be correctly configured first, so it still fires on a `livelocked`
      or `unconfirmed` node, which is the exact gap this incident fell
      through.

      The script refuses to run inside a container, and refuses on the
      `/.dockerenv` sentinel (`lib/compose-drift.sh`'s own) rather than on
      `docker` being absent from `PATH`: that second test answered the
      question only while this image carried no Docker CLI, and it carries
      one now for the `reconciler` service (requirement 2.5a). Both checks
      stand, the sentinel first, because a CLI that resolves inside a
      container and then reaches no daemon fails several lines later as an
      unreadable `docker info` — which reads like a broken host rather than a
      script run in the wrong place.

      On a `cgroupfs` host the parent is a plain cgroup directory, and
      `scripts/cgroup-parent-setup.sh` delegates the `memory` controller down
      every ancestor of that directory — writing `+memory` to each
      `cgroup.subtree_control` — before it writes any ceiling. A cgroup's
      interface files exist only because an ancestor delegated the controller,
      so without this the parent has no `memory.high` to write to at all. It
      also removes any of the four interface paths it finds existing as a
      *directory* rather than a file, and reports doing so: Docker creates a
      missing bind source as a directory, and inside the cgroup filesystem a
      directory is a cgroup, so a `memory.high` that is a directory occupies
      the name the controller must use and the real file can never appear
      there.

      Two invariants follow, and both are what make the failure recoverable
      rather than terminal. A run that cannot finish **removes the parent it
      created**, so there is no bare directory left for Docker to mount a
      cgroup over — a parent that already existed is never removed, since it
      may hold containers. And the reboot persistence on such a host is a
      generated script (`/usr/local/sbin/agent-ops-cgroup-parent-<name>.sh`,
      rewritten on every run) that repeats those same steps in the same
      order, rather than a chain of `&&`-joined writes inline in a crontab
      entry: the inline form could not delegate, could not distinguish a
      missing file from a failed write, reported neither, and left exactly
      the directory Docker then poisoned (agent-ops#1347). Installing the
      hook replaces any earlier entry naming the same parent, so the old form
      does not survive an upgrade.

   0g. *Host budget* (requirement 2.0g, agent-ops#757). Free, and for the
      same reason as 0c/0f immediately above: it reads a file already sitting
      in this node's own `state_dir`, no network call and no Docker socket of
      its own (the runtime deliberately holds neither, agent-ops#603 — see
      0's own header), so it runs in the same band. 0c and 0f each protect
      the host against *this* node's own next cycle; neither says anything
      about the *other* containers sharing the same host. Per-container
      ceilings (D14, agent-ops#606) bound one container's blast radius, but
      Docker reserves nothing, so the sum of every limit on a host may freely
      exceed it — `deploy/docker/compose.yaml`'s own "Resource ceilings
      (D14)" comment already does this arithmetic by hand for the two-nodes-
      one-host layout ("one tailnet node at 2.4 GiB plus one local node at
      2.2 GiB leaves headroom for the VM itself"), and nothing before this
      requirement checked that the comment stayed correct. Measured on
      ockham 2026-08-24: six containers, none aware of any other, each
      believed it could take the whole 7.457 GiB VM, and the host froze
      repeatedly.

      The sum this requirement checks is computed and published by the
      host-facts collector (component from agent-ops#1283,
      `scripts/collect-host-facts.sh`), not measured here: `lib/host-facts.sh`
      now also reads the host's own `MemTotal` (`/proc/meminfo`) and CPU
      count (the `processor` line count in `/proc/cpuinfo` — not namespaced,
      the same property 0f's own header verifies for `/proc/meminfo`) into
      `host.mem_total_bytes`/`host.cpu_count`, and the compose driver — the
      one driver with a Docker socket, and so the only one that can enumerate
      every container on the host, not only this compose project's own three
      services — gains a `budget` section
      (`docs/HOST-FACTS-SCHEMA.md`) summing every *running* container's own
      declared `memory.max_bytes`/`cpu.limit_nanos` from `containers[]`
      (agent-ops#606's own per-container actuals section) and reporting each
      dimension's headroom alongside it, so the number is visible in the
      published record before anything binds on it, exactly as the issue's
      own "Done when" asks. `lib/host-budget.sh` is the one place this sum
      and its verdict are computed — the same "read and judge exactly one
      way" shape `lib/disk-space.sh` and `lib/memory.sh` already hold, so a
      caller can never disagree with another about what "over budget" means.
      A container with no readable ceiling is excluded from the sum, not
      treated as `0` or as unbounded, and counted separately
      (`mem_unknown_containers`/`cpu_unknown_containers`) — the same "no
      evidence is not evidence" reasoning 0's own `unknown` and 0c/0f's
      unreadable-meter branches already rest on: a sum that silently invented
      a number for an unmeasured container would be worse than one that says
      plainly it is a lower bound.

      Explicitly out of scope: the Kubernetes driver. The issue's own "Why
      Kubernetes does not close this" section frames this requirement as a
      same-host, co-tenant problem — two Compose projects on one machine,
      neither aware of the other, with no control plane owning the sum — and
      a Kubernetes cluster's `ResourceQuota`/`LimitRange` already assume the
      cluster owns the machine, which is a different problem this
      requirement does not attempt. The `budget` key is therefore absent
      outright under the `kubernetes` driver, a driver-specific omission
      (docs/HOST-FACTS-SCHEMA.md), not a degraded fact.

      This requirement's own gate reads the just-published record from this
      node's own `state_dir/host-facts/<node>.json` — the same file 0f's
      cgroup-parent detail and `doctor.sh`'s Egress section already read —
      and is silently a no-op when that file does not exist yet (a fresh node
      whose collector has not completed a first pass), does not parse, or
      carries no `budget` section (a Kubernetes node, or a record predating
      this requirement): the same "no evidence, no stand-down" reasoning 0c's
      unreadable `df` and 0f's unreadable `/proc/meminfo` already rest on.
      Where the record does carry a `budget`, `host_budget_mem_verdict`/
      `host_budget_cpu_verdict` compare `mem_declared_bytes`/
      `cpu_declared_nanos` plus a configured reserve
      (`host_budget_reserved_memory_bytes`, default 512 MiB, the same figure
      `min_free_memory_bytes` defaults to; `host_budget_reserved_cpus`,
      default `0` — CPU is time-sliced and ordinary oversubscription is not
      itself a fault the way overcommitted memory is, so this dimension holds
      containers to the host's own core count exactly rather than assuming a
      margin is wanted) against `mem_total_bytes`/`cpu_count * 1e9`. Either
      dimension reading `over` is an overcommit.

      Unlike 0c/0f, an overcommit does **not** stand the cycle down by
      itself: `host_budget_enforce` (default `false`) gates it. Off, the
      check is a complete no-op inside this requirement — the sum is still
      published in the host-facts record regardless, so it is visible to a
      human (or `doctor.sh`'s own advisory "Host budget" section, reading the
      same record through the same `lib/host-budget.sh` functions) before
      anything binds on it — which is what "advisory-by-default" (the
      issue's own words) means here: "an operator who knowingly overcommits a
      development box should be able to say so once" is exactly what leaving
      `host_budget_enforce` at its default does, with no fight against this
      requirement required. On: an overcommit logs a `stand-down` event with
      `cause: "host-overcommit"` (one of the sixteen tokens in the closed
      cause vocabulary, `docs/FLOW-SCHEMA.md`) whose `reason` carries
      `lib/host-budget.sh`'s own `host_budget_describe` — both dimensions'
      arithmetic, the declared sum, the reserve, the host total, and the
      unknown-container counts, regardless of which dimension actually
      tripped — and the raw `budget` object besides, so the event is never
      read as an assertion with no numbers behind it.

      Proof is `test/host-budget.test.sh` (`lib/host-budget.sh`'s pure
      summation/verdict/describe functions, driven against fixture
      `containers[]` arrays including a declared sum that cannot fit a small
      host — proving the overcommit path without waiting for a real host to
      run out, per the issue's own "Done when") and `test/host-budget-
      wiring.test.sh` (this requirement's own block lifted out of
      `lib/standdown.sh`, the same split `test/disk-space[-wiring].test.sh`
      already use for 0c).

   1. *Usage-limit cooldown*: the same signal arrives on two carriers, and
      the **later** `resume_at` wins. The log union's most recent `limit-hit`
      is as fresh as the last state-sync fetch; `fleet/limit.json` on the
      state repository's main is read live, which is what lets a limit one
      node hit a minute ago stop this cycle now rather than a fetch interval
      from now. If the winning `resume_at` is still in the future, stand
      down. The flag is written by whichever node hits a limit (requirement
      10's `limit_decide` supplies `resume_at`/`class`/`reset_known`, plus
      the node's name and a timestamp), **extend-only**: a writer never
      shortens an existing `resume_at`, so concurrent hits converge on the
      latest resume whatever order their contents-API writes land in. The
      write is best-effort — on failure the node logs a `warning` and relies
      on the union to carry its `limit-hit` to the fleet.

      Both carriers can be retired early, two ways — automatically by the
      probe of 1b when `reset_known` is false, or by hand with
      `--clear-limit` (requirement 12) — and both retirements are the same
      write: delete `fleet/limit.json` and log a `limit-cleared` event, which
      the union's reduction — most-recent-wins over `limit-hit` **and**
      `limit-cleared`, defined once in `lib/limit-detect.sh`
      (`LIMIT_UNION_JQ`'s `limit_union_fold`, read through
      `limit_union_record`, `limit_standdown_since` and `limit_union_state`)
      so every reader shares it — treats as superseding every earlier hit.
      Deleting rather than shortening the flag is what keeps extend-only
      intact for the concurrent-hit case it exists for.

      The reduction folds the union with `reduce` over the tolerant raw-line
      event stream every union reader shares (`union_events`,
      `lib/union-stream.sh`: `jq -nR`, each line parsed on its own, the
      objects kept), never as one slurped document: a line that does not
      parse, or parses to something other than an object, is skipped and
      every line around it still counts, and the reader holds one record at
      a time rather than the whole union. The stand-down reads the union
      once, with `limit_union_state`, which answers the governing hit, the
      freeze's start and the `since` of every `limit-freeze-escalated` event
      from one pass, for this check and for 1c alike. A read that fails
      outright — `jq` killed, or its input unreadable — exits non-zero, and
      the caller reports it rather than reading it as "no limit in force": a
      `guard-degraded` event (site `cycle:union_record`) here, and the flag
      carrier then decides alone, exactly as it does when the union holds no
      live hit. A union the cycle could not build (requirement 2.5,
      `union_build_ok`) is treated the same way without being read.

      A stand-down must have an exit that does not depend on a cycle running,
      because this check runs before any stage launches: while it holds, no
      cycle can reach a success, so nothing inside the pipeline can ever
      clear it. Without `--clear-limit` the only exit was `resume_at` passing
      — and when `reset_known` is false that is an invented time, so a
      stand-down could outlive its limit by up to `LIMIT_LONG_COOLDOWN_HOURS`
      with no way to say so. It did: a spend cap lifted on 2026-07-26 left the
      fleet down for a further 22 hours — and again on 2026-07-28, when a
      spend-cap message that actually recorded a 5-hour session window
      meeting the exhausted cap stood the fleet down for 24 hours over a
      limit that cleared within one. Requirement 1b is the automatic exit
      those two incidents argue for; `--clear-limit` remains the manual
      override.

      The logged reason states whether `resume_at` is a stated reset or an
      estimate, and `--status` reports the stand-down alongside the switch.
      Both answer "why is nothing happening?", and a status that knew only
      about the switch is how a stale cooldown went a day unexplained.

      Every `limit-hit` event and `fleet/limit.json` record carries `kind:
      "auto"`, `actor` (the detecting node — `limit-hit` events also keep
      logging it as the event's own `node`), `provider` (the provider the
      stage that hit the limit was running on — `lib/stage-run.sh`'s
      `stage_provider`, `anthropic` on every record this system has ever
      written, since that is the only provider that has ever existed; issue
      #2133), and `evidence` — the API's own
      response, truncated to 400 characters (the structured
      `rate_limit_info` object where the runner supplied one, else the first
      matching limit line of the transcript). An extension of the flag is
      therefore always accompanied by the fresh observation that justified
      it, because the only writer is the detector responding to a hit.
      `provider` is informational only here: the stand-down it names still
      covers the whole fleet regardless of which provider hit it (scoping it
      per-provider is #2135's business, not this one's). A
      record whose `kind` is `manual` only ever enters `fleet/limit.json` by
      an operator's hand: it is honoured as written until its `resume_at`
      passes or `--clear-limit` lifts it, is never probed (1b) and never
      escalates (1c), and its stand-down reason names its `actor` and says it
      is manual. A record with no `kind` reads as `auto` — every record this
      system has ever written was a detector's. `limit-cleared` events record
      their own `actor` and `kind` (`manual` for `--clear-limit`, `auto` for
      the probe), so the log distinguishes a human lifting a stand-down from
      the system retiring one.
   1b. *An estimated stand-down probes its own exit.* When the governing
      record's `reset_known` is false, `resume_at` is this system's invented
      time and carries no information about the limit — so before standing
      down, the Script spends one minimal headless invocation of
      `implementer_model_trivial` (a fixed one-line prompt, 180 s timeout,
      transcript kept as `limit-probe.out` in the cycle record), through the
      same provider-neutral `run_model_stage` (requirement 4d) every other
      stage launches on, and classifies
      it with `limit_probe_verdict` (`lib/limit-detect.sh`, regression-tested
      against canned transcripts): the limit phrase anywhere in the transcript
      is `limited`; otherwise a well-formed envelope with `is_error: false`
      and a non-empty `result` is `clear`; anything else — a timeout, a
      network failure, an empty file — is `inconclusive`. On `clear` it
      retires both carriers exactly as `--clear-limit` would (the
      `limit-cleared` event names `auto-probe@<node>` as `by`) and the cycle
      proceeds; on `limited` it records the re-observed hit through
      requirement 10 — whose parse also upgrades `reset_known` to true if the
      probe's message finally states a reset, stopping further probes until a
      time that is real — and stands down; on `inconclusive` it changes
      nothing and stands down, with the verdict appended to the logged
      reason either way.

      The economics run the right way round on both sides: a limited account
      answers the probe with the limit message at no token cost, and an
      unlimited one answers once for a fraction of a cent — the first `clear`
      verdict retires the stand-down fleet-wide, so the gate stops firing.
      A *stated* reset is never probed (the message named the time; asking
      earlier is the one spend that buys nothing), and `--dry-run` never
      probes (a cycle that promises to change nothing must not write
      `limit-cleared`, and a verdict it would have to ignore is pure cost).
      Nor is a `kind: manual` record ever probed: it is an operator's
      decision, not a detector's inference, and no probe verdict is evidence
      about whether the human still means it — a probe must never clear a
      deliberate human stand-down (#244).
   1c. *A long-running automatic freeze escalates; a manual stand-down never
      pages.* While an automatic stand-down holds, the Script ages it from
      the freeze's start as 1's union read gives it (`limit_union_state`'s
      `since`: the `ts` of the first `limit-hit` after the last
      `limit-cleared` in the union — the start of the current freeze, not its
      latest extension). When the union was read but holds no live hit — the
      stand-down rests on `fleet/limit.json` alone — it ages the freeze from
      the governing record's own `ts` instead, which is the flag record's
      time: when `fleet_limit_publish` (`lib/toggle.sh`) last wrote it, and,
      since every extension rewrites it, the latest extension. Once that age reaches
      `limit_escalate_after_hours` (0 disables the check), it files an
      escalation issue in `crash_loop_repo` — label
      `enabler_escalation_label`, assignee `enabler_assignee`, body carrying
      the governing record and the item ref `usage-limit-freeze:<since>` —
      through the same duplicate-guarded `create_escalation_issue` the
      Enabler and the crash-loop check use, and logs
      `limit-freeze-escalated` with the issue, the time it aged from
      (`since`) and which time that is (`since_basis`: `union` for the first
      hit, `flag` for the flag record's own `ts`, which the issue body names
      as such). That event in the union is what makes the escalation
      once-per-freeze: a cycle that finds one whose `since` is the time it
      ages from does not file again, and the open-issue guard catches the
      cross-node race the union has not yet carried. A flag-only freeze that
      is extended gets a new `since`, and so is aged and escalated afresh
      from that extension. A failed filing logs a `warning` and retries next
      cycle. Skipped on `--dry-run`, when `crash_loop_repo` or
      `enabler_assignee` is unset, and always for `kind: manual` — the
      operator who set a manual stand-down does not need to be paged about
      their own decision. Skipped too, for that cycle, when the union could
      not be built or read (1's `union_state_ok`): whether this freeze was
      already escalated cannot then be told, so nothing is filed, a `warning`
      says so, and the next cycle tries again — filing anyway would rest on
      the open-issue guard alone, which a closed escalation passes. And when
      the flag record carries no usable `ts`, the age test is skipped and
      reported (`guard-degraded`, site `freeze_since:flag`); it never runs on
      an empty time, since GNU `date -d ""` answers midnight today.
   1a. *Claim GC*: run `lib/claim.sh gc` (requirement 17a) — best-effort,
      skipped on `--dry-run` — so registry entries a dead node left behind
      are swept before back-pressure counts them. Every node runs it; no
      coordination is needed, because a registry delete is sha-guarded and a
      claim branch is deleted only if unmoved and PR-less, so the worst race
      outcome is a no-op.
   2. *Back-pressure*: if the number of draft PRs labelled `pr_label`, plus
      the ready PRs labelled `pr_label` whose `reviewDecision` is
      `CHANGES_REQUESTED`, across all configured repos, **plus the live
      claim-registry entries for those repos** (requirement 17a — work a
      node has claimed but not yet surfaced as a PR; an item-keyed entry is
      dropped the moment its PR exists), is ≥ `max_open_agent_prs`, stand
      down. This is the primary throttle on both spend and on the landing gate
      silting up. The count is approximate by design: N nodes can pass it
      simultaneously, so the stated bound is `max_open_agent_prs +
      (nodes − 1)`, transient.

      `lib/claim.sh count` drops every registry entry that names a pull
      request the PR listing above has already counted, because such an entry
      is that PR a second time rather than work in flight without one. Two
      shapes name a PR. A PR-keyed `pr-<n>` entry (requirement 17a, issue
      #238) is dropped unconditionally — it is only ever written for a PR that
      exists, and unlike an item-keyed entry it is held past its PR's own
      raising, until the claiming cycle ends (issue #360), so counting it
      would double-count that PR for as long as that cycle's Reviewer stage
      runs. An item-keyed entry whose ref is `pr-<n>-<kind>-<scope>` — the
      shape the five sources that finish an existing pull request
      (requirements 3c, 3e, 3g, 3z and 53; see
      requirement 3p) key their items on — is dropped only when that PR is
      among the drafts and
      pipeline-owed PRs actually counted, which is why the caller passes
      those numbers in per repo. A ready PR sitting in the human's queue is
      *not* among them (see below), so a conflicted or dequeued PR the
      pipeline is working keeps counting through its claim, which is then the
      only record that the work is in flight.

      The registry is wider than the configured repos: the Enabler and the
      Refiner claim engagement tombstones under the pseudo-slugs `enabler` and
      `refiner` (requirement 35c). Those never reach this count, because it is
      taken one configured repo at a time — an invariant `lib/claim.sh` states
      in its own header, and one any other reader of the registry (the
      dashboard's back-pressure card among them) has to re-impose for itself.

      A ready PR whose `reviewDecision` is **not** `CHANGES_REQUESTED` —
      approved, or awaiting a first or re-review with nothing currently
      `CHANGES_REQUESTED`-blocking it — does not count. Its next action
      belongs to a human, and the pipeline cannot shrink a full human queue
      by declining to open new work; counting it would only back-pressure
      the fleet for a queue it has no lever to drain (agent-ops#246). This is
      the same "whose turn is it" rule requirement 3c's review-feedback
      candidate filter uses (`scripts/gather-review-feedback.sh`), read here
      rather than re-derived, so the two definitions cannot disagree.

      This exclusion is level-aware (D18 WI-6): for a repository whose
      `merge_autonomy_effective_level` (requirement 2.3b) ranks
      `agent-merges-routine` or above, every **otherwise-eligible** ready
      pull request counts, `CHANGES_REQUESTED` or not. Above that level
      there is no human queue for an otherwise-eligible ready pull request
      to be parked in — the Approver App, not a human, is next in line — so
      the exclusion's own premise ("its next action belongs to a human") no
      longer holds for that pull request. The qualifier is load-bearing, not
      incidental: a ready, non-`CHANGES_REQUESTED` pull request the pipeline
      is barred from landing — by `complexity:*` grade or by originating
      source, `landing_eligible`'s (lib/landing.sh) own two deterministic
      gates — has no other actor to move it regardless of level, so it stays
      in the human queue exactly as it would below `agent-merges-routine`
      (issue #946). The narrowing reaches a non-`CHANGES_REQUESTED` pull
      request only, and that restriction is itself load-bearing: a
      `CHANGES_REQUESTED` pull request is owed a change by the pipeline at
      every level whatever its grade or source — the `review-feedback` source
      (requirement 17) re-engages it, and that path consults neither list —
      so it counts here as it does below `agent-merges-routine`. The
      narrowing can therefore only ever hold *more* pull requests out of the
      human queue than the un-narrowed rule does, never fewer against the
      cap: of the two ways to be wrong, opening work past a full cap is the
      one that is not recoverable next cycle. This is read
      through `landing_routine_eligible` (lib/landing.sh) rather than
      `landing_eligible` itself: the complexity-and-source subset of that
      function's gates, deliberately never its protected-path gate, which is
      a live changed-file read for a decision (arming a landing) this one
      has no need of — a protected path does not stop a human from landing a
      pull request, only the pipeline from doing so automatically. Complexity
      comes from the same pull-request listing this count already took (its
      own `complexity:*` label); a pull request's source carries no field on
      GitHub at all and is read back from a single pass over the fleet's own
      union log instead (`landing_retry_source_map`, `lib/union-log-scan.sh`
      — built once per repository per cycle, and only where that repository
      has at least one candidate to spend it on, so a repository with none
      reads the log no more often than it did before the map existed;
      shared with the 2.1e landing-retry sweep below, which uses the same
      map on the same terms rather than re-parsing the log once per
      candidate) — a candidate whose
      source cannot be resolved this way counts toward the cap rather than
      being excluded from it (fail-closed: of the two ways to be wrong here,
      opening work past a full cap is the one that is not recoverable next
      cycle), logged as a `warning` naming the repository and the pull
      request. Judged per repository, inside the same per-repository loop
      the count is already taken in, against the effective level (not the
      configured one), so a fleet-wide kill switch or a merge-budget freeze
      (requirement 2.3c) affecting the effective level un-excludes those
      pull requests again by the next cycle's process — this read is
      advisory, not a site that acts on the level, so it is memoised for the
      running process's whole lifetime like every other advisory read
      (requirement 2.3a). `counted_prs_json`'s own record of which pull
      requests this count held (2.2b, `claim.sh count`'s exclusion) is built
      from the identical otherwise-eligible verdict, per pull request, so the
      two can never disagree about the same one.

      The logged reason — of the stand-down here and of the restriction
      warning in 2.2a — states the count's full composition:
      `(N pipeline-owed + N draft + N unraised claim(s) — plus N waiting
      on human (N raw))`. The pipeline-owed figure is every ready pull
      request the pipeline owes action on: a `CHANGES_REQUESTED` PR at any
      level, plus, at `agent-merges-routine` and above, every
      otherwise-eligible ready PR the pipeline is next in line to land,
      `CHANGES_REQUESTED` or not — the exact set the level-aware paragraph
      above defines, which is why the label names the bucket rather than any
      one review state; a draft is work in
      flight (the Implementer's own claim marker, requirement 23); an
      unraised claim is a registry entry whose PR does not yet exist; the
      human-queue count is the ready PRs excluded from the trip, and the raw
      total is what the count would have been before that exclusion.
      Whether the cap stood the fleet down because the queue was genuinely
      full, or fired early on in-flight work, or would have tripped only on
      PRs already waiting on a human, is exactly what a cap-tuning decision
      needs — and it must be readable from the log line alone, because the
      PRs behind a historical count are merged or closed by the time anyone
      asks, leaving cycle-record archaeology as the only other answer.

      The listing behind the count asks for `GITHUB_PR_LIST_LIMIT` pull
      requests (`lib/github-limit.sh`) rather than inheriting `gh`'s
      undeclared default of 30, and a response that came back **at** that cap
      trips the gate on its own — with a `warning` naming the repository, and
      the composition suffixed to say the figures are floors. `gh` gives no
      signal that it truncated, so a capped listing simply produces low
      counts, and low counts open a gate whose purpose is to stay shut. Note
      that nothing bounds the listing at `max_open_agent_prs`: a pull request
      sitting in whichever queue the level-aware exclusion above currently
      parks it in still carries `pr_label` and is deliberately excluded from
      the sum above, so a repository can hold arbitrarily many open labelled
      PRs while the sum stays small. Of the two ways to be wrong here,
      deferring a cycle that could have run is recoverable next cycle and
      opening work past a full cap is not.
2.2a. **Back-pressure throttles starting work, not finishing it.** Compute the
   count in 2.2 but **defer the stand-down** until the sources are gathered
   (requirements 3c, 3g, 3z and 3e). If back-pressure has tripped *and* any
   `review_feedback`, `merge_conflicts`, `dequeued` or `abandoned_drafts`
   candidate exists, do
   not stand down: restrict every repo's `sources` to
   `["review-feedback", "merge-conflicts", "dequeued", "abandoned-drafts"]` and
   continue. Only
   stand down when the count is over and nothing is waiting to be finished. All
   four are *finishing* sources — they complete an already-open PR rather than
   opening a new one — and three are doubly apt here, because they already hold
   back-pressure slots the cap counts: an abandoned draft occupies a slot nothing
   will clear until the draft is finished, and a conflicted or dequeued PR
   occupies one nothing can land to free until it is fixed.

   Without this the pipeline deadlocks exactly when it is most stuck.
   `max_open_agent_prs` PRs all sitting on "changes requested" is a state the
   system can only escape by answering them — and the plain check stands the
   cycle down before the Co-Ordinator ever runs, so the one source that could
   clear them is never reached. The pipeline dies silently, and the fix
   (merge or close something by hand) is invisible unless you already know.

   The restriction preserves back-pressure's stated purpose exactly: the system
   still cannot open a *new* PR while the gate is full; it can only finish what
   is already in it, which is the one activity that *un*-silts the gate.
   Implement it by narrowing the `sources` lists rather than by adding a mode
   flag: the Co-Ordinator is already told the runtime input's `sources` are
   authoritative over its own table (requirement 15), so a source it cannot see
   is a source it cannot select — no new prompt concept, and nothing for it to
   reason around. The pre-fetched `issues` (requirement 3j) and `tech_debt`
   (requirement 3t) arrays are emptied along with the narrowing — they are the
   two that carry a whole document each, an issue's entire thread and a
   tech-debt issue's entire thread, and paying the Co-Ordinator to read candidates
   it cannot pick is the exact spend this gate exists to stop; the other
   non-finishing arrays are compact enough that stripping them would buy
   nothing. Emptying `tech_debt` here also settles requirement 3t's
   corroboration for a restricted cycle: the eligible set it measures is read
   after this narrowing, so a back-pressured `selected: false` — which forbade
   the tech-debt source outright and therefore owes no account of it — is never
   scored as contradicting a band it was not allowed to walk.
2.2b. **The decision site folds in what 2.2's count missed.** 2.2a's own
   justification for treating a conflicted or dequeued PR as doubly apt —
   "occupies one nothing can land to free until it is fixed" — is only
   true if that PR is actually counted somewhere. It usually is not: 2.2's
   count is taken before this cycle's `merge_conflicts` and `dequeued`
   candidates are gathered (they arrive only once each repo's sources are
   populated, in step 3, requirements 3g and 3z), and neither gatherer's
   candidate rule reads `reviewDecision` at all
   (`scripts/gather-merge-conflicts.sh`, `scripts/gather-dequeued.sh`). So a
   conflicted or dequeued PR that is not *also* `CHANGES_REQUESTED` passes
   through 2.2's count exactly like an ordinary PR waiting on a human — ready
   PRs are excluded from the trip unless `CHANGES_REQUESTED` (2.2's own rule)
   — and for `dequeued` this is not even a coincidence: a PR only reaches the
   merge queue after approval, so its `reviewDecision` is `APPROVED` by
   construction. Left uncorrected, the gate trips later than it should, and
   does so exactly when a conflicted or dequeued PR is what is filling it —
   the one state 2.2a's restriction exists to reach.

   So, at the decision site, before 2.2a's stand-down/restriction check: take
   the distinct PR numbers named across every repo's `merge_conflicts` and
   `dequeued` candidates (a number named by both counts once), drop whichever
   ones 2.2's own count already held — that repo's drafts and
   `CHANGES_REQUESTED`-ready PRs — add what remains to `adjusted_open_count`,
   and, when anything was added, re-evaluate `adjusted_open_count >=
   max_open_agent_prs`: a cycle whose plain 2.2 count left it untripped can
   trip here. State the addition in `open_composition`, in the same
   composition-line style 2.2 itself logs, so the log line stays the one
   place a cap-tuning read needs and stays legible against the dashboard
   card's word-for-word mirror of 2.2's own line (requirement 2.2,
   `docs/spec/dashboard/README.md`). This runs whether or not 2.2's own count
   tripped — both gathered arrays exist by this point regardless, from the
   same per-repo loop that builds `ordered_repos_json` ahead of this check —
   so a cycle 2.2 alone would have let run can still be correctly narrowed to
   the four finishing sources.

   The dashboard's own back-pressure card is unaffected: it mirrors
   requirement 2.2's count alone (`docs/spec/dashboard/README.md`), a continuous,
   cross-cycle read of live PR state rather than one cycle's stand-down
   decision, and has no access to the `mergeable`/queue-membership data this
   fold-in needs.
2.2c. **A drain (requirement 2.3d) narrows unconditionally.** 2.2a's own
   restriction — every repo's `sources` cut to `["review-feedback",
   "merge-conflicts", "dequeued", "abandoned-drafts"]`, `issues` and
   `tech_debt` emptied — is not only a back-pressure response: while a
   `mode: "drain"` record is active (agent-cycle.sh's own `DRAINING`, set at
   the switch check in requirement 2.3d, before this site), the same
   restriction applies regardless of whether `adjusted_open_count` ever
   reaches `max_open_agent_prs`. A drain's whole purpose is refusing new
   intake while finishing work already open, and 2.2a already is exactly that
   restriction — reusing it rather than inventing a second narrowing keeps
   every downstream consumer of `ordered_repos_json.sources` (the
   Co-Ordinator's own runtime input, `coordinator_eligible_items`, the
   Refiner's candidate set) blind to *why* it is narrowed, only that it is,
   which is the same property 2.2a's own design note claims for back-pressure.

   The one place this and 2.2a diverge is what happens when the restricted
   set turns out empty (`finishing_waiting == 0`): 2.2a alone stands the cycle
   down and exits, exactly as before back-pressure existed. A drain does not
   merely stand down — it is requirement 2.9's own at-rest check, described
   there, and it never treats "nothing to do this cycle" as a reason to
   revert to intake or to exit any differently than an ordinary quiet cycle
   would. Both conditions reaching this site simultaneously (back-pressure
   tripped *and* a drain active) narrow exactly once — the mechanism does not
   stack — and 2.9's own bookkeeping (the cached remaining count, the
   `drained` event) runs whenever `DRAINING` is set, whether or not
   back-pressure was what would have narrowed anyway.
2.3. **The switch.** A file, `state_dir/disabled.json`, whose presence stops
   cycles starting. Checked *before* the lock and before any `gh` call — a
   disabled pipeline should cost nothing — and honoured by both this Script and
   `review-cycle.sh` (`docs/spec/review.md`, R2a) through one shared
   implementation (requirement 34a), with `agent-cycle.sh` the only writer.
   Managed by four flags that manage the switch and run no cycle:
   `--disable [<reason>] [--for <90m|4h|2d|forever>] [--until <timestamp>] [--this-node]`,
   `--drain <reason> [--for <90m|4h|2d|forever>] [--until <timestamp>] [--this-node]`
   (requirement 2.3d), `--enable [--this-node]`, `--status`. `--until` takes a
   GNU `date`-compatible absolute timestamp, an alternative to `--for`'s
   relative duration; with both given, the later of the two deadlines wins and
   a warning names which. Transitions are logged (`disabled`, `enabled`),
   carrying the `scope` and `fleet_flag` vocabulary requirement 33 defines,
   and — since requirement 2.3d — the record's own `mode`.

   **`--this-node` (issue #379)** modifies `--disable` or `--enable` to act on
   this node alone, never on the fleet switch of requirement 2.3a: `--disable
   "<reason>" --this-node` writes `state_dir/disabled.json` exactly as an
   unmodified `--disable` does — same record shape, same `actor`/`kind`, same
   `--for`/`--until`/`disable_default_ttl` handling, same mandatory reason,
   same `extends` behaviour — and skips the fleet publish, printing plainly
   that only this node stands down. `--enable --this-node` clears only that
   local record and never touches `fleet/disabled.json`, so a fleet-wide
   disable (or a peer's own node-scoped one) is left exactly as it was.
   Unmodified `--disable`/`--enable` are unchanged: they still write and clear
   both levels. This is the graceful way to stand one node down for
   maintenance — no container recreate, no role flip — without pulling the
   rest of the fleet down with it. `--this-node` given with anything but
   `--disable` or `--enable` is a usage error (exit 64); the role guard's
   bypass list (requirement 2.4) is unchanged, since a switch command must
   stay usable on every node regardless of `--this-node`.

   **`scope` says which of those two a record is.** Because an unmodified
   `--disable` writes both levels, the node that issues a fleet-wide
   stand-down ends up holding a local record that is byte-identical to a
   `--this-node` one — so every reader announced a node-scoped disable nobody
   had asked for, and that node alone wore the dashboard's amber **disabled**
   badge while its peers, equally down, wore none. The record therefore
   carries `scope`: `"node"` for a stand-down of this node's own (a
   `--this-node` disable, or an unmodified one on a single-node operation with
   no `state_repo` configured), `"fleet"` for the local mirror of a fleet-wide
   one. A record with no `scope` reads as `"node"` — what every record written
   before the field existed effectively was, and the reading that keeps a node
   down rather than one that talks itself out of a stand-down.

   **This is not the same `scope` the `disabled` event carries** (issue #426,
   requirement 33), and the two part company in exactly one case, so they are
   computed separately rather than shared. The event records the operator's
   *instruction*, which is why a `--disable` on an installation with no
   `state_repo` still logs `scope: "fleet"` with `fleet_flag: "unconfigured"`
   saying why nothing was published. The record answers a different question —
   *is there a fleet flag for this to mirror?* — and with no state repo there
   is none, so it is `"node"`. Tagging it `"fleet"` there would have `--status`
   claim a mirror of a switch that cannot exist, and `--enable --this-node`
   refuse to clear the only record holding that node down. Everywhere else,
   including under `--this-node`, the two agree.

   The local write still happens first and is tagged with the *intent*, since
   it must be on disk before anything talks to GitHub; when the fleet publish
   then fails, the record is retagged `"node"` in place — leaving
   `disabled_at` and every other field untouched, because that node really is
   standing down alone and a record still claiming `"fleet"` would describe a
   switch that was never set. `--status` and the dashboard name a mirror as a
   mirror rather than as a second decision (requirement 2.3's `--status`
   bullet, `docs/spec/dashboard/README.md`), and **`--enable --this-node` refuses a
   `"fleet"` record outright** (exit 64, naming plain `--enable` as the
   command that undoes a fleet-wide disable). That refusal is not tidiness:
   the mirror is this node's fail-*closed* hold on itself for exactly the
   window in which the fleet flag cannot be read — that flag fails *open*
   (2.3a) — so clearing it while the fleet switch stands is how a node resumes
   the work the fleet was stood down to prevent.

   The mirror also closes a failure that had no signal at all. `--enable` run
   on a *peer* clears `fleet/disabled.json` but cannot reach this node's file,
   so the node stays down alone, indefinitely under `--for forever`, on a
   decision that was lifted elsewhere. Tagged, that state is nameable: both
   `--status` and the node's dashboard card report a record left over from a
   cleared fleet-wide disable and name `--enable` on that node as the fix.

   The record carries `actor` and `kind` alongside `by` and `reason` (#244).
   `actor` is `toggle_actor` (`lib/toggle.sh`): `NODE_NAME` when set, else
   the invoking user at this host, falling through `id -un` to the numeric
   uid — never `unknown`, because an unattributable flag is what let a
   deliberate operator stand-down read as a runaway automatic freeze. `kind`
   is `manual` for everything this entry point writes — an operator's or
   agent's decision, honoured until its expiry or `--enable`, never probed
   and never auto-cleared. A `--disable` issued while a switch is already set
   is an extension of the earlier decision, and the `disabled` event records
   the superseded record as `extends` rather than presenting a fresh stop.

   **Why it exists.** Both cron pipelines execute code out of the agent-ops
   working tree. An agent editing `agent-cycle.sh`, `lib/` or `prompts/` is
   editing the files the next tick will source; a cycle firing mid-edit runs
   half of one revision and half of another, and the resulting failure gets
   attributed to whatever the agent happened to be writing. That is also why
   the switch is shared rather than per-pipeline: the review pipeline runs out
   of the same tree and sources the same `lib/`, so a switch that stood down
   only the implementation pipeline would leave the hazard in place.

   Four details decide whether this helps or becomes its own outage:
   - **A disable expires** after `disable_default_ttl` unless it explicitly
     says `forever`. The switch's whole risk is that it is a deliberate,
     silent, total stop: an agent that sets it and then dies — killed, timed
     out, context exhausted, or simply finished and forgetful — has stopped
     every future cycle, and nothing will alert, because "no PRs" is what a
     working pipeline looks like on a quiet week. A TTL turns "forgot to
     re-enable" into a few lost cycles. This is the stale-lock rule of
     requirement 1 applied to the same failure.
   - **Everything ambiguous resolves toward disabled.** An unreadable record,
     or one whose `expires_at` won't parse, keeps the pipeline down. The file
     exists because something meant to stop the pipeline; recovering "enabled"
     from a truncated write runs the cycle the switch was set to prevent.
   - **A reason is required, and an unparseable `--for` or `--until` is an
     error.** The next person to wonder why nothing is happening is entitled
     to a reason, and a typo'd duration or timestamp — or a `--until` that
     names an instant already past — must not be guessed in either direction
     — one resumes the pipeline mid-edit, the other never resumes it.
   - **The switch stops the next cycle, not the one already running.** Say so
     when it is set while a lock is held, in `--status` and in `--disable`'s own
     output. An agent that disables the pipeline, assumes the coast is clear and
     starts editing has gained nothing and doesn't know it.
   - **`--status` distinguishes a node-scoped disable from a fleet-wide one, and
     says what clearing each leaves.** With neither set it reports the switch
     enabled; with only the fleet flag set it names that record and says a plain
     `--enable` clears it fleet-wide; with only a `scope: "node"` local record
     set (a `--this-node` disable) it says `--enable --this-node` clears it;
     with both set it reports both records and spells out the asymmetry —
     `--enable` clears both, `--enable --this-node` clears only the local
     record and leaves the node down under the still-set fleet switch. An
     operator who finds a node down for more than one reason is entitled to
     know which command undoes which.

     A `scope: "fleet"` local record is not a second reason, and is never
     reported as one. With the fleet flag still set, `--status` says the local
     record mirrors it and that `--enable` clears both levels; with the fleet
     flag clear it reports the orphan plainly — a mirror of a fleet switch
     since cleared, probably by `--enable` on another node, leaving this node
     standing down alone until `--enable` is run on it.

   Deliberately *not* bypassed by `--once` or `--dry-run`: "these files are
   being edited, do not run them" is no less true when a human runs them.
