## Requirements

### The Script — requirements, continued (part 8 of 10; 4i–8d: The assembled Co-Ordinator prompt is bounded by its model'…)

4i. **The assembled Co-Ordinator prompt is bounded by its model's context
   window.** Requirement 4g's own text records that moving the fleet-state
   aggregates off argv "raised the ceiling; it did not stop the set from still
   climbing toward whatever ceiling came next". The next ceiling arrived on
   2026-08-21. The assembled prompt reached ~226580 tokens against the
   Co-Ordinator model's 200000-token window and the API refused it outright:
   four consecutive cycles, every node, `coordinator exited 1`, with no
   recovery anywhere in the fleet and no work selected while it lasted. The
   growth was ordinary — ~212999 tokens three cycles earlier, ~220498 two
   cycles earlier — one issue comment at a time, past a limit no code in this
   repository had ever measured itself against. `coordinator_prompt_max_bytes`
   is that measurement: the largest prompt the Script will assemble, in bytes,
   because bytes are what it can count without a tokenizer. `0` disables the
   bound, which is how every release before it behaved.

   **The bound is on the prompt, not on the runtime input.** What the window
   rejects is the whole message, and the base prompt is over 100 KB of it and
   grows with every requirement written into `prompts/coordinator.md` — so a
   budget for the input alone would let prompt growth silently consume the
   input's headroom and arrive back at this same outage. The Script therefore
   measures the *rendered* base prompt (requirement 4b's substitution already
   applied), the fenced scaffolding, and the whole of the runtime input
   document with an empty `repos` — assembled from the same values requirement
   4's own build uses, so what is subtracted is exactly what will be spent —
   and hands what remains to `lib/coordinator-input.sh` as the allowance. The
   overhead is measured against an *empty* `repos` rather than against the
   unfitted array on purpose: the two differ by the indentation of the lines
   the fit removes, so an overhead taken from the fatter array would narrow
   the allowance as the fit worked, and the ladder's own measurements could
   not be trusted. Measurement is of the array as `jq .` will render it, not
   of its compact form, for the same reason: a bound is worth nothing measured
   in units the window does not charge in.

   **Two bands are trimmed, and only two.** `issues` and `tech_debt` are the
   arrays that carry a whole document each — an issue's entire thread
   (requirement 3j), a tech-debt issue's entire thread (requirement 3t) — and are
   the only two whose size tracks the repository's history rather than the
   number of open pull requests. That pairing is not new: requirement 2.2a's
   back-pressure block already singles out exactly those two, for exactly this
   reason, when it empties them on a restricted cycle. Every other pre-fetched
   band is left alone, because per requirement 17h the Script's own compose
   step (`compose_selected_candidate_text` in `lib/candidate-select.sh`)
   pastes each of their bodies *verbatim* into the work order, and together
   they were 34 KB of the 354 KB that overflowed. The small, per-repo scalar
   fields a repo entry carries alongside its bands — `implementation_plan_path`,
   `report_directory` and `report_directory_resolved` (requirement 3k) — are
   not bands at all and are never
   candidates for shedding: each is a short string, present only for a repo
   whose `sources` configures the matching source, and negligible next to any
   band this ladder trims.

   **Prose is shed; candidacy is not.** The fit walks a ladder of ten
   rungs — `{newest comments kept, bytes per comment, bytes per body}`,
   generous first — stopping at the first that fits, so an input a little over
   the allowance loses a little prose. Every rung leaves the entry's `ref`,
   `number`, `url`, `title`, `priority`, `labels` and `updated_at` untouched,
   so a trimmed item is ranked and selected exactly as an untrimmed one is.
   Every cut names itself: a truncated body or comment ends in
   `…[Script: elided N of M bytes to fit the context window — read it whole at
   <url>]`, and dropped comments are counted in `comments_elided` on the entry.
   Per requirement 17h, an entry carrying any such mark needs no live read
   before it may be *selected*: once picked, the Script itself composes
   `context`/`acceptance` from a fresh live read of the whole thread, never
   from the trimmed extract — see `prompts/coordinator.md`'s "Trimmed entries
   need no live read before you select them" bullet — one fetch for the one
   item picked, rather than a thread's worth of tokens for every item
   considered. A prose-only trim also leaves the gatherer's own entry order
   alone, so a trimmed cycle differs from an untrimmed one in prose and in
   nothing else.

   **Dropping entries is the last rung, and it is loud.** Once the tightest
   tier is applied there is nothing left but entries, and those are capped per
   band per repo against a fixed sequence (300, 200, 128, then halving: 64,
   32, … 1 — agent-ops#2191 added the first three so a backlog a sliver over
   the identity-only rung's own byte count trims proportionately instead of
   losing 68% of itself to a jump straight to 64). The first fixed cap that
   fits is then refined: the Script binary-searches the gap between it and
   the cap before it (which did not fit) for the highest per-band-per-repo
   cap in that gap that still fits, so a byte-rich/entry-poor backlog is not
   stopped by a fixed step that leaves most of the allowance unspent
   (agent-ops#2221). The search never looks outside the gap the fixed
   sequence already brackets, so its result is always below the cap that
   did not fit — at most double the fixed cap that did, and less than double
   for the three widest steps — which is the same never-more-than-halving
   bound agent-ops#2191 established for the fixed sequence itself. Within
   whichever cap is finally chosen, entries are kept by the highest
   `Priority` band
   first and the freshest thread within a band for `issues`, and the freshest
   thread first for `tech_debt`, which carries no band (agent-ops#1379: the
   ascending-by-number order the cap once kept meant that, pinned at 64 for
   weeks, the ~90 newest `pw::type:tech-debt` issues — the fresh defects —
   were the ones dropped on every cycle, and nothing but a fallback pick could
   ever reach them). The count is recorded as `issues_elided`/`tech_debt_elided` on the
   repo entry the Co-Ordinator reads, and the whole fit is applied *before*
   `coordinator_eligible_items` — beside requirement 2.2a's own emptying of
   these two bands, and for its stated reason: requirement 3x's corroboration
   must measure the set actually offered, or a dropped entry would read as an
   unaccounted-for decline. A fit that shed anything logs
   `coordinator-input-fitted` carrying the rung, the byte counts and a
   human sentence naming what was trimmed — an informational record, not a
   `warning`, because a fleet whose backlog has outgrown the window will trim
   on every cycle and a standing warning for the ordinary case is how a log
   stops being read. A fit that still does not fit at one entry per band logs
   a `warning` as well, saying so *before* the API refuses the prompt. Both
   events also carry a `terms` object (issue #645) breaking the overhead down
   by band — `prompt` (the rendered base prompt), `blocked`, `refinements`,
   `claimed`, and `scaffold` (the fence wrapper plus the small, static
   `models`/`pr_label`/`candidates_max`/`refinement_policy` fields and the
   JSON structure `coordinator_fit_overhead_json` itself adds) — so a refusal
   names which half of the document was actually too big without a live shell
   into the container to re-derive each band from `.fleet-log.jsonl` by hand.
   `scaffold` is the remainder of the total overhead after the other four are
   subtracted, not a fifth independent measurement, which keeps the five
   terms summing to the existing overhead total exactly.

   **The tail of the ladder is three trims, not a drop, and requirement
   34e's fourth refusal (agent-ops#683) is the decision, reasoned.** Before
   that refusal existed, reaching `0:0:1000` meant every candidate's body was
   pared to a title-level fragment and its comments emptied — exactly the
   shape that compelled the mass-flagging incident 34e's fourth bullet
   describes — which made "drop entries here instead of trimming them" a real
   fix to weigh: an entry this small could not be judged either way, so
   keeping it costs a candidate slot for something the Co-Ordinator could not
   use. Requirement 34e's refusal removes that harm at its source: a trimmed
   entry can no longer force a block, so all a bottom-rung entry still buys
   the Co-Ordinator is its identity fields (`ref`, `title`, `priority`,
   `labels`, `updated_at`) — enough to rank it, and enough to select and
   live-read it should its title alone look worth the fetch. Dropping it
   instead would remove that option for no remaining harm left to trade it
   against. The same reasoning licenses the two rungs beneath `0:0:1000`
   (agent-ops#1379): `0:0:300`, a short opening, and `0:0:0`, the identity
   fields alone with every comment gone and the body replaced by its own
   elision marker — an entry reduced to exactly what #683 established the
   Co-Ordinator can still rank, select and live-read. They exist because
   `0:0:1000` still renders at about 1,900 bytes an entry, and from
   2026-09-04 to 2026-09-23 every fitted cycle on every node ran past it into
   the entry caps, dropping 74–246 entries a cycle: the caps had become the
   ordinary case, and an entry the Co-Ordinator never sees is not a
   candidate at all. On the fleet's 2026-09-23 input (317 entries, 251 of
   them tech-debt in one repository) the three tail rungs render at about
   1,900, 1,190 and 875 bytes an entry, so the identity-only rung holds the
   whole backlog inside a ~280 KB allowance and the caps are reached only
   once identities alone outgrow the window. Requirement 34e's refusal and
   requirement 3x's exemption reach the two new rungs exactly as they reach
   `0:0:1000`, since both read the elision marker the rungs leave, not the
   rung number.

   **Every degradation here is toward the unbounded input, never toward an
   empty one.** A budget of `0`, a non-numeric budget, a stdin document that
   is not an array, or a `jq` failure at any rung all answer with the input
   unchanged: a misread bound that stripped a cycle's candidates would be a
   worse failure than the overflow it exists to catch, because the overflow is
   visible and starvation is not. `lib/coordinator-input.sh` takes the repo
   array on stdin at every call site for requirement 4g's reason, and
   `test/coordinator-input.test.sh` pins that with an array genuinely past
   `MAX_ARG_STRLEN` — the first draft of its own reporting function bound the
   array as `--argjson` and that test is what caught it.

   **Requirement 3b's fingerprint is unaffected by what the fit sheds.** The
   fingerprint hashes the fitted array, because that is what the Co-Ordinator
   is given, and the shedding is deterministic — but a new comment on an issue
   whose thread was trimmed away must still buy the next cycle a fresh look.
   It does, and not by accident: requirement 3b's own sampling already carries
   each open issue's `updated_at` in the source-state digest, independently of
   this array and expressly because "a triage action that makes an issue
   selectable, or stops it being, always moves this digest". The elided bytes
   are covered by a signal that was never in the elided bytes.

   **A stage the API refuses says which refusal it was.** `coordinator exited
   1` was every record the fleet kept of the four cycles it lost, and
   requirement 2.7's escalation sent its reader to `coordinator.out.stderr`,
   which an API refusal leaves empty — the refusal is a `result` with
   `is_error: true` in `coordinator.out`. `handle_stage_failure` therefore
   reads that file: a refusal makes the `attempt-failed` detail "<stage> was
   refused by the API before it could run: <terminal reason>", and the API's
   own message travels beside it on the event as `api_message`. What counts as
   a refusal is `api_error_status` being a number on the record — the API
   itself saying it declined the request — and expressly not `is_error` alone,
   which covers every way a stage can end badly including ones that ran first;
   calling those "refused before it could run" would put a confident falsehood
   where an honest exit code used to be. `terminal_reason` names which refusal
   where the runner recorded one, and the status stands in where it did not
   (`api_error_529`). The split is
   load-bearing — requirement 2.7 counts consecutive failures carrying the
   *same* detail, and the message names a token count that moved every cycle,
   so a detail built from it would have read as four distinct failures and the
   ladder would never have fired on the outage it was needed for. The
   escalation's own hint now names `coordinator.out` first.

   One refusal carries no status at all and is recognised by its shape
   (2026-09-15, ockham-2): a node whose subscription OAuth credential lapsed
   while it stood down — re-enabled after days on Standby, its refresh token
   expired with nothing having used it — records `terminal_reason:
   "api_error"`, `api_error_status: null` and `result: "Failed to
   authenticate: OAuth session expired and could not be refreshed"`, because
   the runner refused the request itself, having no credential to make it
   with, before any API call could return a status. Six consecutive cycles
   read `coordinator exited 1` (and `enabler`, `refiner`), the same useless
   account #641 fixed for the status-bearing kind. So `stage_api_refusal`'s
   gate is the numeric status *or* that shape — the runner's own `api_error`
   reason *and* an authentication message (`authenticat|oauth|unauthori[sz]ed`,
   case-insensitive) — and the shape is named `authentication_failed`,
   whether or not a status rides with it, so one outage never reads as two
   details. The gate is deliberately both halves: an `api_error` with no
   status and no such message still gets its honest exit code.

   **Not every refusal is deterministic, and the record now says which
   (issue #1073).** `stage_api_refusal`'s stable token cannot itself carry
   that distinction — the whole point of narrowing it was to keep a moving
   detail from splitting one outage into several — so `stage_api_refusal_class`
   reads it from the same `api_error_status` (and, for a named connection-level
   `terminal_reason`, from that) as a sibling, stable value: `refused` for a
   named deterministic reason (`prompt_too_long`, `invalid_request_error`) or
   any other 4xx — the API considered the request and declined it, and no
   amount of retrying changes that — and `transient` for a 5xx or a
   connection-level fault — the request never reached a considered answer,
   the fault is external, and it clears on its own — and `refused` for
   `authentication_failed`, which no retry clears, only a person completing
   the login. `handle_stage_failure`
   carries it on the `attempt-failed` event as `api_refusal_class`, empty
   when `stage_api_refusal` found nothing to classify. `crash_loop_verdict`
   is the one reader of this field today (requirement 2.7); no other part of
   this requirement changes on its account.

4j. **The unsheddable half of the Co-Ordinator's input is bounded too, and
   `refinements` is bounded by candidacy.** Requirement 4i bounds the prompt
   and sheds `issues` and `tech_debt` to meet the bound. It says nothing about
   the rest of the input document, and on 2026-08-21 that omission cost the
   fleet eight hours: `refinements` had reached 237,339 bytes — 24 `spec`
   payloads totalling 219,175 of them — and the prompt text plus the
   unsheddable bands came to 387,840 bytes against a 350,000-byte maximum
   *before a single candidate was added*. The allowance came out negative, the
   ladder was never walked, and the Co-Ordinator was refused on every node of
   the fleet, eleven consecutive cycles, with no work selected anywhere. The
   bound requirement 4i had just added was in force and could not help,
   because nothing it could shed was the thing that was too big.

   `refinements` is a ledger and is never retired: it holds every refinement
   the Enabler or the Refiner has ever settled, keyed by repo and item. Most
   entries are a line — `ts`, `cycle`, and a `comment_url` pointing at the
   thread where the refinement lives. An entry for an item with no thread to
   hold it (a review recommendation, a plan task) instead carries the
   specification itself, in markdown, several kilobytes of it. Of the 24 such
   payloads in the ledger that day, 22 — 203,645 bytes — belonged to items no
   band of that cycle still named as a candidate.

   **Which of the two an item takes is settled by the item, never by its
   band.** Requirement 36b's own carrier rule reads the item: an item with a
   thread takes the pointer, an item without takes the payload. Reading the
   *source band* instead is what agent-ops#1128 cost: this requirement's list
   of thread-less types named tech-debt, which was true when it was written and
   stopped being true when agent-ops#875 moved that band onto
   `pw::type:tech-debt` issues — issues with a number, a URL and a thread like
   any other. `lib/refinement.sh` went on keying the two shapes on
   `source == "issues"`, so every tech-debt refinement took the payload shape
   it no longer needed: on 2026-08-31 that was 98 of the 106 candidates and
   229,399 bytes of `spec` in the one band this requirement cannot shed, with
   the allowance 97,465 bytes negative and requirement 4i's ladder pinned at
   its last rung on every node of the fleet. The test is the gather entry's own
   `number`, which every issue-backed source carries and no thread-less one
   does.

   **One home per refinement.** `refinement_record_fields` records the pointer
   or the payload and never both: a `comment_url` and a `spec` describing the
   same refinement are not redundancy that costs nothing, because the payload
   is kilobytes in the unsheddable band and the pointer already resolves to the
   same text — requirement 17f's own traceability check reads that comment for
   exactly this reason. A verdict offering both is recorded as the pointer
   alone. `coordinator_refinements_view` applies the same rule on the read
   side, shedding a `spec` that sits beside a `comment_url` whatever its
   candidacy: the ledger is never retired, so entries written before the rule
   existed are still read, and those are the ones a fixed writer alone would
   never reach.

   So the Script scopes it, to what a selection this cycle could actually
   read (agent-ops#1379 narrowed the rule agent-ops#643 introduced). The rule
   falls out of what `prompts/coordinator.md` does with the band. "Look the
   item up here before you decide it is under-specified" and the
   `refinement_policy` gate both read an entry's *presence*, for an item the
   Co-Ordinator is weighing; a `comment_url` is the pointer requirement 17h's
   Script-side composition follows once the item is selected; and a `spec`
   is pasted by the Co-Ordinator itself only for an item from a source it
   derives live (`project-review`, `implementation-plan`), because for every
   pre-fetched band the Script splices the recorded refinement in at
   composition (`refinement_traceability_repair`) from the full ledger, never
   from this view. Nothing reads `ts` or `cycle`. By 2026-09-23 no spec
   survived the candidacy rule and the ledger itself was the weight: 848
   entries, 384 of them under a slug the fleet no longer configures,
   rendering at 167 KB of `ts`, `cycle` and `comment_url` in the unsheddable
   band on every cycle, of which 308 entries named an item the Co-Ordinator
   could select. `coordinator_refinements_view` therefore keeps a repository
   only when the cycle's repo array names it; within it, an entry only when
   some pre-fetched band of that repository offers the item this cycle, or
   when the item's ref is one no pre-fetched band ever constructs — an issue
   number (`issues`, `tech-debt`), a `pr-<n>-…` pull-request ref, a
   `dependabot-alert-<n>`/`code-scanning-alert-<n>` finding, a
   `human-visibility-…` violation or a frozen `TD-…` register id — since a
   ref of one of those shapes is selectable only from the band that offers
   it, whereas any other ref may be an item the Co-Ordinator derives itself
   and must still find here; and per entry `{comment_url}` where the pointer
   exists (a `spec` beside it is shed whatever the candidacy, agent-ops#1128's
   rule read from the ledger's side), `{spec}` only for a self-derived item,
   and otherwise `{}` — presence, which is all the prompt reads for a refined
   item the Script will compose for. On that day's ledger and input the
   view is 37 KB. A refinement for an item no engagement could select is
   bytes the Co-Ordinator is told to read and can never act on, so dropping
   it removes no judgement — the same test `coordinator_blocked_view` is
   trimmed against, applied to the other half of the same document.

   **The view is computed once and spent unchanged.** `blocked` can afford to
   call its own view at both the measurement and the assembly, because that
   view reads nothing of the repo array but its slugs, which no rung of the
   fit changes. This one is scoped against the candidates in
   `ordered_repos_json`, which requirement 4i's fit reassigns — calling it
   twice would measure the overhead against the unfitted candidate set and
   spend it against the fitted one, an error in the safe direction and still a
   measurement that is not of the thing it claims to be. It is scoped against
   the *unfitted* array on purpose, for the same reason 4i measures its
   overhead against an empty `repos`: the fit only ever removes candidates, so
   the scoping stays independent of the rung the ladder settles on, and an
   entry kept for a candidate the ladder later sheds is a handful of bytes
   already accounted for. "4. Co-Ordinator stage" calls the view again per
   engagement against that repository's own entry, so each engagement carries
   only its own repository's refinements.

   **A hopeless allowance sheds everything it can rather than nothing at
   all.** The negative-allowance branch requirement 4i introduced warned and
   then fell past the fit entirely, sending the array whole — which is how a
   350,052-byte `issues` extract went into a prompt already over the window
   without it. Shedding nothing is the worst available answer in precisely the
   one case where nothing can be enough. The Script now clamps the allowance
   to 1 before walking the ladder: `coordinator_fit_bands` reads 0 or less as
   "bound off" and returns the array unchanged, whereas 1 fails every rung —
   prose, then entry caps — and lands in that function's final branch, which
   hands back the smallest array the ladder can build together with
   `fits: false`. The `warning` still names the overhead, the maximum and the
   fact that the API may refuse the prompt regardless; the clamp only stops
   the cycle from making its own refusal more likely on the way out. This
   preserves requirement 4i's own "every degradation is toward the unbounded
   input, never toward an empty one" for every *other* path: a budget of 0
   still means the bound is off, and it is only this branch — where the Script
   has already established that no input fits — that shedding is forced.
4k. **A stage runs nothing that the checkout it runs in supplies.** Headless
   `claude -p` treats its working directory as trusted, and a stage's working
   directory is often a checkout of a pull-request head. Two controls keep
   that checkout from making the runner execute anything before, or apart
   from, the stage's own prompt:
   - **The image's managed policy.** `deploy/docker/claude-managed-settings.json`
     is installed root-owned at `/etc/claude-code/managed-settings.json`
     (component 7), outside `/app`, which `agent` owns. It sets
     `allowManagedHooksOnly: true`, so no user, project, local or plugin hook
     runs; `allowedMcpServers: []`, so no MCP server starts, whether from
     `.mcp.json`, a settings file, an agent's frontmatter or a plugin; and
     `disableSkillShellExecution: true`, so inline shell in a skill or a
     custom command is replaced by a placeholder rather than run. The managed
     file outranks every other settings source, and project instructions and
     project skills load under it unchanged. The image build checks the three
     pins, and its acceptance step runs `scripts/claude-policy-probe.sh`
     against the built image. A scratch checkout plants a hook; an MCP server,
     approved by the MCP-approval keys the launcher admits; and inline shell
     in a project command and in a project skill. The checkout must run none
     of the four, and must run all four once the policy is removed.
   - **The launcher's settings check.** No managed key can switch off a
     project's `env`, which sets variables in the runner's process and in
     every command it runs, or the settings that name commands the runner
     executes itself (`apiKeyHelper`, `awsAuthRefresh`,
     `awsCredentialExport`, `gcpAuthRefresh`, `otelHeadersHelper`,
     `proxyAuthHelper`, `processWrapper`), or those that fetch plugins
     (`enabledPlugins`, `extraKnownMarketplaces`). So `run_claude_stage`
     (requirement 4d) vets `.claude/settings.json` and
     `.claude/settings.local.json` in its working directory, the only place
     Claude reads project settings from, against an allowlist before it
     starts anything. The allowlist holds keys that cannot run anything,
     change the environment or change what the stage may do (`$schema`,
     `includeCoAuthoredBy`, `includeGitInstructions`, `cleanupPeriodDays`,
     `respectGitignore`, and `permissions` holding only `allow`, which a
     stage's untrusted workspace ignores). It also holds `hooks` and the
     project MCP-approval keys, but only while the managed policy pins the
     control that makes them inert. The rest of `permissions` is refused,
     because it sets what the stage may do: `deny` takes a tool away from the
     stage, and `disableBypassPermissionsMode` silently drops the run out of
     bypass mode. A file holding any other key, or one that is not a JSON
     object `jq` can read, means the stage is not launched. It returns 1,
     leaves `<stage>.out` and its stream empty, and leaves `stage_kill_reason`
     empty, since the stage was neither capped nor re-run. It writes to
     `<stage>.out.stderr` the file, what is wrong with it, and whether the
     commit the checkout holds carries it as the working tree does. That
     last part matters because the working tree is what is vetted, and a
     clone can be reused by the next stage, so a file an earlier stage wrote
     there refuses that stage too and appears nowhere in the pull request.
     `handle_stage_failure` reads that line, never a variable a later
     failure could inherit, and records one of two stable details:
     "`<stage>` was not launched: the commit its checkout holds carries
     Claude Code project settings no stage may load", or "`<stage>` was not
     launched: its checkout's working tree holds Claude Code project
     settings, not in the commit, that no stage may load". So a pull request
     that adds such a file is blocked with that reason rather than reviewed
     by a runner it can direct, and a file a stage left behind is told apart
     from one the pull request commits.

5. If the work order is `{"selected": false}`, log `none-selected` with the
   Co-Ordinator's reason **and the fingerprint computed in requirement 3b**
   (omitted entirely, not stored empty, when the cycle was unfingerprintable —
   the next cycle must find no fingerprint rather than an empty one it could
   match against an equally empty sample of its own), release the lock, and
   exit. This event is the only thing that makes the next cycle cheap.
6. **Workspace.** Create `workspace_root/<cycle-id>/` and clone the selected
   repo into it, fresh from GitHub. This applies the multi-agent
   ways-of-working rule shared by all Poetic repositories: every agent works
   in its own dedicated fresh clone taken from the tip of the default branch
   before commencing any changes. (A full clone — stages may rebase onto a
   `default_branch` that has moved and need the merge base.) Agents only
   ever run inside this
   workspace; the Script must refuse (assert) to launch a stage whose
   working directory is outside `workspace_root`. The user's own clones
   under `~/Code` are never touched.

   The clone goes through `lib/repo-clone.sh`'s `clone_repo`, which runs `git
   clone`, not `gh repo clone`. Both fetch the same objects over the same
   transport, but `gh` first resolves the repository through a GraphQL query,
   which is billed against the API budget — and this step is the last thing a
   cycle does before the Implementer, with the Co-Ordinator engagement and the
   claim already paid for. On 2026-08-12T20:52Z that query is where a cycle
   died: `GraphQL: API rate limit already exceeded`, having spent everything
   and produced nothing. Git's own transport is not rate-limited, so this step
   cannot fail that way. Authentication is unchanged —
   `deploy/docker/entrypoint.sh` wires git's own credential helper to
   `!gh auth git-credential` (component 7), an unqualified `gh` that `PATH`
   resolves to the transport shim and so to the on-demand credential seam
   (component 22c), so the helper serves this HTTPS remote exactly as it
   serves the push that follows.
   `review-cycle.sh` clones through the same function, so the two cannot
   diverge, and `CLONE_GIT` substitutes a stub for tests — a seam this needs in
   its own right, because a test that wants the clone to fail can no longer get
   that from a fail-fast `gh` on `PATH`.

   Anything already at the clone's target path is **residue, and is discarded
   rather than inspected**. Both callers derive the path from an id minted
   moments earlier and unique to the run, so nothing legitimate can be there;
   what can is the partial clone of a run the machine killed mid-`git clone`.
   The discard is unconditional by choice: a check that the directory "is a
   complete repository at the expected remote and revision" passes on a clone
   that is complete and *dirty* — a dead cycle's working tree, carrying its
   half-finished edits — which is the residue likeliest to mislead the stage
   that inherits it and the hardest to tell from a good clone.

6b. **The workspace root is reclaimed, because the exit trap cannot be
   trusted to do it.** The clone is deleted in the cycle's exit trap, and a
   trap is exactly what `SIGKILL` does not run: a cycle killed by the machine
   — an out-of-memory kill, a host freeze, a container recreate mid-stage —
   leaks its entire clone, and nothing looks at that directory again. The
   residue is invisible until the volume is full, at which point it is the
   reason the volume is full. Measured 2026-08-24: 17 orphans and 4.2 GB
   across the two ockham nodes, the oldest 32 days old; 5 more and ~2.5 GB on
   VM1 (#605).

   So both pipelines reap `workspace_root` before they clone — and before
   every stand-down, since a node with nothing to do is the node whose
   housekeeping matters most. The rule is a **property, never the naming
   convention**: anything directly under `workspace_root` that nothing has
   written to within the reap window cannot belong to a live run. Keying it
   on `<cycle-id>` would have missed the two largest orphans found in the
   field — `scratch-implementor/` (968 MB) and `scratch/` (101 MB) — because
   the pipeline does not create those. The stage agents do, following the
   target repository's own dedicated-clone rule, choosing names the framework
   never sees and cannot predict.

   The window is requirement 4f's derived cycle-lock window — the same number
   `scripts/doctor.sh` reports — floored at 24 hours, so no new constant is
   configured. The floor is what binds in practice and is what makes the reap
   safe against the one legitimate overlap: a review cycle and an
   implementation cycle hold separate locks and do run at once. Freshness is
   read from the **tree**, never the directory's own mtime, which git stamps
   once at clone and never moves again — reading it alone would reap the
   workspace of a cycle five hours into its Implementer. Entries whose name
   begins with `.` are never candidates: the fleet's own stores share this
   directory (`.agent-ops-state`, `.agent-ops-peers`), are bounded by their
   own retentions (requirement 2.5), and a node whose last fetch was days ago
   is a stale node, not one that should lose its peers.

   What is reclaimed is a **fact the fleet can read**, not a silent tidy-up:
   a `workspaces-reaped` event carries the count, the bytes and the names,
   and is written only when something was actually reclaimed. The names are
   the diagnostic — a node reaping a workspace every cycle is a node being
   killed every cycle, which nothing else reports. Reclaiming disk never
   fails a cycle: every failure inside the reap is swallowed.
6a. **The pipeline creates its own labels.** As it gathers each repository's
   data — not only, and not first, at the one it later selects to work — the
   Script ensures every label this system applies exists there, creating
   only those that are absent: `pr_label`, `enabler_escalation_label`,
   `needs_refinement_label`, `refined_label`, `unvoid_label`,
   `complexity:low|medium|high`, `blocked`, `blocked:needs-refinement`,
   `obsolete`, `open-question` (the Reviewer's own projection,
   requirement 8f), `pw::type:tech-debt`, `pw::owner-decision`
   (`techdebt_file_issue`'s own marker for an owner-only `file_debt`/
   `file_issue`, requirements 23d, 36c, 42a — a fourth fixed name, for the
   same reason as `pw::type:tech-debt`: only a collaborator with triage can
   apply a label, so a filed issue's membership of the owner-only band is
   trustable even though its body stays untrusted data) and `pw::decision`
   (requirement 36e's decision-log issue — a fifth fixed name, for the same
   reason again: it is what `scripts/sweep-decision-vetoes.sh` searches
   every configured repository for, and only a fixed name is trustable
   across a fleet of them) — `blocked` and `obsolete` being
   human-only controls no pipeline stage ever applies itself: `blocked`
   excludes an issue from selection (requirement 16.4), and `obsolete`
   corroborates closing a still-open, still-diff-carrying
   `pr-<n>-abandoned-…`/`pr-<n>-review-…` draft (requirements 34d, 34k;
   TD-PPagop-26081308) — a repository without either label does not offer
   the human either control at all, and ensuring against every gathered
   repository rather than only a selected one is what gives that control to
   a repository no cycle has chosen to work in yet. `pw::type:tech-debt` is
   a third fixed name, also not configurable: D15's trust anchor (D24) for
   tech debt filed as a GitHub issue rather than an in-repo register
   record — only a collaborator with triage can apply a label, which is
   what makes an issue's membership of the `tech-debt` work band trustable
   even though its body stays untrusted data. Ensuring against every gathered
   repository is also what lets the Co-Ordinator's own
   `needs_refinement`/`blocked` projection (requirement 34e) and the
   Refiner's `refined_label` projection (requirement 39c (The Refiner)) reach a fresh
   repository the moment either first fires there, rather than failing
   silently until some later cycle happens to select work in it
   (agent-ops#687). `review-cycle.sh` calls the plain, unstamped
   `labels_reconcile_role` (`lib/labels.sh`) for each repository's own resolved
   `repository_review` pr_label (its override, or
   `repository_review.defaults.pr_label`, requirement 342) and
   `pw::type:tech-debt` in each repository it
   is about to review — so a repository in `repository_review.repos` but not
   gathered as an implementation-pipeline target also has the label R12's own
   `gh issue create --label pw::type:tech-debt` relies on, rather than only
   the two ever coinciding by configuration accident — the same shape as the
   selected repository's own
   unconditional listing below, not the rate-limited helper, because a
   repository is selected for review at most once per
   `min_days_between_reviews` days, longer than any interval a stamp there
   could bound (`docs/spec/review.md` R5.0b) — and
   `create_escalation_issue` calls that same unstamped helper for
   `enabler_escalation_label` in the repository an escalation is filed in,
   which is often one no cycle otherwise touches. A label whose configured name is empty is switched off
   and is not created. And no configurable label may carry a reserved *name*:
   `scripts/doctor.sh` fails a config that sets any label key to `obsolete`
   or `pw::type:tech-debt`, or an issue-side key to `blocked`, because a
   stage projecting a configured label under a reserved name would apply the
   human-only control itself — requirement 34k's corroboration, in
   `pr_label`'s case, onto every draft the pipeline raises — or, for
   `pw::type:tech-debt`, D24's own tech-debt trust anchor, onto whichever
   configured key carries it. Every description `labels_catalogue`
   emits, for every role, is at most 100 characters — GitHub's own limit on a
   label's `description` field; a longer value is refused outright by the
   create call, so a catalogue entry past the limit could never be created in
   any repository, on any node, ever (issue #888).
   `test/labels.test.sh` asserts the limit by reading
   `labels_catalogue`'s own output for every role rather than a fixture list,
   so a future entry that regresses past it fails there before it ever
   reaches GitHub.

   Four properties are load-bearing, for every catalogue entry outside
   `label_prefix`'s own namespace (see below). It **only ever creates**: an
   existing label keeps whatever colour and description it has, because
   operators recolour labels and a pipeline that reasserted its own idea of
   them every cycle would undo that work on a schedule. It is **never fatal**: a
   repository whose labels cannot be listed, or a token that may not create
   them, is reported and nothing more — the tolerances the callers already
   carry (`refinement_label_add`'s own retry below, requirement 36a's retry
   without the label) stay exactly where they are, so this makes the common
   case work without becoming a new way to lose a cycle. It is **per
   gathered repository, not per selected one**: every repository a cycle
   gathers data for gets this, whether or not the Co-Ordinator goes on to
   select work there — the property this replaces, "per worked repository,
   not per configured repository", is exactly what left gaps 1–3 above
   unreachable until a repository's first selection. And it is
   **rate-limited, not once-forever**: a per-`(repository, role)` stamp file
   under `state_dir` (`labels_ensure_interval_hours`, default 24h) bounds how
   often the listing runs once a repository already has every label, so the
   steady state stays a single listing per repository per interval and zero
   writes, while a label a human deletes still comes back within one
   interval — periodic rather than once-forever is what keeps that promise
   true regardless of whether the repository is ever selected again. The
   interval is read as **whole hours, from the value's integer part**, and
   `config.schema.json` types it `integer` so a fractional one is refused at
   configuration time. Both halves are load-bearing on their own: `24.0`
   satisfies that type (JSON Schema counts a zero fraction as an integer, and
   the value reaches the stamp check as the literal that was configured), so
   the check truncates rather than requiring whole digits — a decimal it read
   as non-numeric would disable the rate limit outright and list every
   repository every cycle, which is the failure this interval exists to
   prevent, arrived at silently.

   The selected repository gets one further, **unconditional** listing on top
   of the above: immediately before the Implementer stage, `agent-cycle.sh`
   calls the plain, unstamped `labels_reconcile_role` again for `$repo_slug`,
   whatever the gathered-repository ensure's own stamp said. That stamp only
   guarantees `pr_label` existed at the gather loop's listing, not at this
   later point in the same cycle — and a stamp fresh enough to have skipped
   the gather loop's listing entirely is exactly the state in which nothing
   else in the cycle is still checking. The Implementer is one
   `gh pr create --label` on a missing label away from losing its whole run,
   which is what this second, unrate-limited listing exists to prevent —
   costing one extra listing per cycle, the same price `main` always paid for
   the selected repository before agent-ops#687 introduced the gathered-
   repository ensure above.

   `refinement_label_add` (requirement 34e) self-heals the one failure mode
   this cannot pre-empt — the ensure above ran, but this repository's stamp
   had not yet been written, or the projection is racing a repository this
   cycle is gathering right now: a failed add retries, once, through
   `labels_ensure_one` (`lib/labels.sh`) via an injectable
   `REFINEMENT_LABEL_ENSURE` hook, memoised per `(repo, label)` per process
   so a token that genuinely cannot create labels is billed once per cycle,
   not once per projection.

   Why it exists: every one of these labels was previously something a
   human had to create by hand in every target repository, and nothing said
   so when they had not — the projection simply did not happen and the item
   was handled anyway, so the signal the label exists to give was silently
   absent, worse still for a repository the pipeline had not yet selected
   work in, which got no ensure at all until it did. That is a product bug
   rather than an installation's own problem (the customer-zero rule,
   `docs/ROADMAP.md`): a new installation must not need a checklist of `gh
   label create` commands, and a label a human deletes must come back on its
   own — in every repository it configures, not only the one currently being
   worked.

   `lib/labels.sh` also exposes `labels_reconcile`/`labels_reconcile_role`:
   full CRUD — create, reconcile colour/description drift, and delete once no
   longer catalogued — for any label whose name starts with `label_prefix`
   (config.schema.json, default `pw::`), leaving every label outside that
   namespace on the create-only path above unchanged. Deletion is scoped to
   MODE `full`, which `labels_reconcile_role` passes only for its `target`
   role — the one catalogue call that is a repository's complete desired
   label set — because `review` and `escalation` are each a partial subset of
   `target`'s own catalogue, and a delete scoped to a subset would remove
   labels the other role still wants; both reconcile colour/description drift
   under MODE `additive` without ever deleting.

   That "partial subset" is a standing constraint on the catalogue, not an
   observation about it: every `label_prefix`-named label the `escalation`
   role wants appears in `target`'s arm of `labels_catalogue` as well, and a
   future entry added to one must be added to the other in the same change.
   A repository may hold both roles at once — `pager_repo` is empty by
   default and falls back to `crash_loop_repo`, which an installation
   routinely also configures in `repos[]` — and an escalation-only prefixed
   entry in such a repository is created by the `escalation` reconcile and
   deleted by the `target` one on the next cycle, each undoing the other,
   with GitHub's own `DELETE` detaching the label from every issue already
   carrying it on every lap. `pw::decision` and `enabler_escalation_label`
   are in both arms already; `pw::pager` is in both for this reason, so
   lib/pager.sh's dedup search and `monitor-cycle.sh`'s own
   `--label pw::pager` page listing keep finding the issues they filed.
   `test/labels.test.sh` pins the relation itself rather than a second
   literal list.

   Every call site —
   `lib/coordinator-phase.sh`'s `ensure_labels_for`, `review-cycle.sh`'s own
   review-role
   ensure, `lib/enabler.sh`'s `create_escalation_issue`/
   `create_decision_log_issue`, and `lib/candidate-gather.sh`'s
   gathered-repository ensure (through `labels_reconcile_stamped`,
   `labels_ensure_stamped`'s own rate-limited shape but dispatched through
   `labels_reconcile_role`) — calls `labels_reconcile_role` rather than
   `labels_ensure_role` (TD-PPagop-26082809). The `labels-ensured` event
   (2.6's own event catalogue) carries `updated`/`deleted` alongside
   `created`/`failed` accordingly.

   `labels_reconcile_role` guards two hazards TD-PPagop-26082809's own review
   (PR #846) raised as latent for as long as nothing called it, both now live:
   an empty *catalogue capture* — `labels_catalogue`'s own `jq` failing
   silently after `config_defaults` succeeded, a failure its exit status
   cannot distinguish from "genuinely nothing to catalogue" — downgrades
   `target`'s own MODE `full` to `additive` rather than reaching
   `labels_reconcile`'s delete pass with nothing to protect the whole
   `label_prefix` namespace from (`target`'s own catalogue can never
   legitimately be empty: `pr_label` alone is required and non-empty); and
   `scripts/doctor.sh` fails a configured `label_prefix` that already matches
   an existing, uncatalogued label in a configured repository, live against
   that repository's own label listing — a short or generic prefix (e.g.
   `"b"`) would otherwise silently pull an unrelated human label (e.g. `bug`)
   into the next reconcile's delete scope.

   Moving the four genuinely per-installation-configurable defaults
   (`enabler_escalation_label`, `needs_refinement_label`, `refined_label`,
   `unvoid_label`; `pr_label` has no product default to move) under
   `label_prefix`'s namespace is also part of TD-PPagop-26082809 — a fresh
   installation that does not override them gets the `pw::`-prefixed product
   default. `blocked`, `blocked:needs-refinement`, `obsolete`,
   `open-question` and `complexity:low|medium|high` stay unprefixed: each is
   fixed and non-configurable for a reason a rename would defeat rather than
   honour (this requirement's own text above) — `obsolete` most concretely,
   since it is applied by a human from memory (requirement 34k), and a
   renamed label the pipeline reads would silently stop matching the one a
   human actually types. Whether these five should also move under
   `label_prefix` despite that is an open question left for a maintainer,
   not a gap this item closes.
6c. **Labels a stage asks for (issue #714).** Beyond the catalogue above,
   which the Script alone decides, the Refiner and the Implementer may each
   *name* a small number of descriptive labels of their own on their final
   message — the Refiner's per-item verdict (requirement 39h) and the
   Implementer's summary (requirement 26b) — for the Script to create and
   apply. The Script remains the only writer, exactly as requirement 6a
   already holds for every catalogue label: a stage names, it never creates
   or applies one itself.

   **The invariant that makes this safe: a minted label is inert.** Nothing
   in this pipeline may read a stage-minted label to decide anything —
   selection, exclusion, voiding, corroboration, tiering or landing all stay
   exactly as they are, blind to whatever a stage chose to name. Its
   corollary: a future gate that wants to read a label adds that name to the
   reserved set below in the same change, since from that point on the name
   is no longer inert.

   **Reserved names, refused case-insensitively (GitHub matches label names
   that way), and never created or applied under any circumstance:**
   `blocked` (selection exclusion, requirement 16.4), `blocked:*` (the
   `blocked:needs-refinement` reason pair requirement 38b projects alongside
   it, and any future reason label in that namespace), `obsolete` (void
   corroboration, requirement 34k), `complexity:*` (Reviewer/Approver
   tiering, requirement 8a), `pw::type:tech-debt` (D24's tech-debt trust
   anchor), `pw::owner-decision` (the Refiner's own default-first rule,
   requirement 39d), `pw::decision` (`scripts/sweep-decision-vetoes.sh`'s own
   sweep target), `open-question` (the landing gate's open-scope-question
   hold, requirement 8f), and every non-empty configured label name —
   `pr_label`, `enabler_escalation_label`, `needs_refinement_label`,
   `refined_label`, `unvoid_label`, and every project-review pull-request
   label in force (`repository_review.defaults.pr_label` and each repository's
   own override of it, requirement 342: `review-cycle.sh` skips a
   repository's whole review while an open pull request carries that label,
   so a minted one claiming the name would be read to decide something).
   That last value is resolved per repository rather than globally, so the
   reserved set takes the union of every value in force anywhere — a
   superset by design, the same way `scripts/doctor.sh`'s own review-label
   check reads them. `lib/labels.sh`'s `labels_reserved_names`
   is the one place this set is declared; every one of these names is read
   somewhere in this pipeline today to make a decision, not only the smaller
   set issue #714's own body named as illustration — the inertness invariant
   has to hold against what the pipeline actually reads, not a partial
   accounting of it, so the reserved set is the complete one rather than a
   literal copy of the issue's own list. `scripts/doctor.sh`'s existing
   reserved-name check (requirement 6a) extends the same way: a configured
   label may not claim `blocked:*` either, not only the exact word `blocked`.

   **Validation, entirely Script-side and never fatal to the stage's own
   verdict or PR:** a candidate name must be non-empty, at most 50
   characters, and match `config.schema.json`'s own `$defs.label` pattern
   (no comma — `gh --add-label` accepts a comma-joined list, so a name
   carrying one could silently apply as several labels instead of the one
   requested) — `lib/labels.sh`'s `labels_validate_name`. A name failing any
   check, or matching the reserved set above, is refused rather than
   created; colour is optional (a neutral grey default, `labels_ensure_one`'s
   own), description is optional. **Capped**, so a verbose model cannot turn
   one item into a label-creation spree: at most 3 per item
   (`lib/labels.sh`'s `labels_mint`, its own `CAP` parameter), and at most 10
   per Refiner engagement — the per-item cap resets with every claimed item,
   the per-engagement one is a single pool `_refiner_apply_labels` shares
   across every item the engagement processes (only the Refiner spans more
   than one item per engagement; the Implementer's own call is always for
   its one PR, so its per-item cap of 3 is the only one that can ever bind).
   A refusal — reserved, over a cap, or a create/apply GitHub itself
   refused — is recorded and dropped, never a failed cycle.

   **No lifecycle.** The Script creates (`labels_ensure_one`) and applies a
   minted label once and then forgets it: it is never removed, never
   recorded as an own-label action (`label_own_action_fields`, requirement
   34g — nothing reads a minted label back the way that record exists to let
   a projection be undone), and `release_refinement_label` must not touch
   one. One `labels-minted` event per item (requirement 33) carries `repo`,
   `item`, `actor` (`"refiner"` or `"implementer"`), and the names created,
   applied and refused. `item` is the **item ref**, from both emitters and
   whatever the actor — the same value every other per-item event carries
   (`refiner-examined`, `issue-prioritised`, `item-refined`), not the issue
   or pull-request number the label was actually applied to. For a
   tech-debt item the two differ, and it is the ref that keeps one item's
   whole trail greppable out of `log.jsonl` by a single key.
7. **Implementer stage.** Launch the Implementer in the clone (model from
   the work order, `--dangerously-skip-permissions`, stage timeout), passing
   the implementer prompt plus the work order, and this cycle's `cycle` id and
   `node` name — because any comment the Implementer leaves must carry
   requirement 9d's header and requirement 3e's marker, and a model cannot
   know either on its own.
8. **Reviewer stage.** If the Implementer reports `complete`, launch the
   Reviewer in the same workspace (model per requirement 8a, same flags,
   stage timeout), passing the reviewer prompt, the work order, the
   Implementer's summary (PR URL, branch, complexity), and this cycle's
   `cycle` id and `node` name — the same reason as the Implementer's above.
8a. **The Reviewer's model follows the item's complexity.** The Script
   resolves an effective complexity for the PR and launches the Reviewer with
   `reviewer_model_complex` when it is `high`, `reviewer_model_default`
   otherwise. Resolution takes the **highest** of two signals, either of which
   may be absent: the `complexity` field of the Implementer's summary
   (requirement 27) and the PR's `complexity:*` label (requirement 26a), read
   best-effort via `gh pr view --json labels` — an unreadable label simply
   contributes nothing. Taking the maximum is what makes the label's
   raise-never-lower rule hold at the decision point too: a PR once graded
   `high` is reviewed as `high` in every later finishing round, however small
   that round's own work was. When *neither* signal exists, the fallback is
   `low` for a work order the Co-Ordinator classified trivial (its `model` is
   `implementer_model_trivial`, requirement 19 — the classification already
   answers the question, so the trivial tier is never asked to self-grade)
   and `medium`, the default tier, otherwise. The Reviewer's `stage-start`
   event carries the resolved `complexity` and the chosen `model`
   (requirement 33), which is what lets the distribution of self-assessments
   be audited for drift.
8b. **Approver stage (D18 WI-5, `docs/reviews/2026-08-14-autonomy-investigation.md`
   §5.2).** Requirement 31d's own read intercepts ahead of everything below: a
   pull request confirmed merged never reaches this stage at all (requirement
   32c) — there is no `ready` verdict left to clear a gate on, only a
   completion already recorded. Once the Reviewer's `ready` verdict has
   cleared every existing
   gate — `review_gate_verdict`, the closing-keyword gate, the draft flip
   (requirement 31a), the re-request (requirement 31b), `ensure_human_reviewer`
   (requirement 38) — and only then, the Script resolves this repository's
   effective `merge_autonomy` level (`merge_autonomy_effective_level`,
   `lib/merge-autonomy.sh`, requirement 2.3b). At `human` nothing further
   happens: the cycle logs `pr-ready` and releases the claim exactly as it
   always has, with no Approver engagement of any kind. At any level above
   `human`, the Script logs `pr-ready` and releases the claim exactly as it
   always has, and only then runs the Approver stage (`### The Approver`) —
   deliberately after, not before: a refusal is a GitHub review sitting on an
   already-ready pull request, not a reason to keep it from the human, exactly
   as a human's own `CHANGES_REQUESTED` never has, so nothing about the
   handoff itself waits on this stage or can be affected by how it ends.

   **A fail-closed kill-switch read is distinguished from a configured
   `human`, and retried once (agent-ops#1081).** The Approver stage's own
   level resolution does not simply call `merge_autonomy_effective_level` and
   read `human` off it — that function's own collapsed answer cannot tell a
   genuinely configured (or manually killed) `human` apart from
   `merge_autonomy_kill_state` (requirement 2.3b) failing closed on a
   transport failure reading the kill switch with no cached copy
   (TD-PPagop-26081507), which a single GitHub REST rate-limit refusal is by
   far the most common cause of (agent-ops#1101's own three call sites hit the
   identical shape on the same node within an hour). So the stage calls
   `merge_autonomy_kill_state` itself first, with its own `RETRY` argument
   set: on a fail-closed read, that function classifies the real cause of
   this call's own `unreachable` answer via `github_limit_kind`
   (`lib/github-limit.sh` — reused, not reclassified) and, only when the
   cause was rate-limiting, waits out `github_limit_wait_plan`'s existing
   wait/backoff and asks GitHub once more before giving up — the same
   "classify, then retry only a rate limit" shape requirement 8c's own
   `approver_post_or_warn` retry already applies to the write side. The cause
   classified is `fleet_flag_fetch_cause`'s own answer (agent-ops#1118): the
   kill flag's own `$cache.err` unless that is itself the flag file's
   ambiguous 404 and `fleet_repo_visible`'s repo probe (TD-PPagop-26081602) is
   what actually failed, in which case it is `$cache.repo-err` instead — a
   lone rate-limited repo probe, not merely a rate-limited flag fetch, is
   retried and reported on its own real cause rather than the flag's
   unhelpful "Not Found". All three facts a caller needs — `.record.kind`,
   `.retried`, and now `.cause` — travel in the document
   `merge_autonomy_kill_state` itself returns, never a global: this call
   happens inside a `$(...)` command substitution to capture that document at
   all, and a subshell's writes to a global never reach the caller back.

   If the kill switch is genuinely enabled, the stage proceeds to
   `merge_autonomy_effective_level` exactly as before (unaffected — the
   merge-budget freeze only ever caps a level *down* to `agent-approves`, so a
   fail-closed `human` is entirely a property of the kill switch and never the
   freeze). If it is not enabled and the reason was the fail-closed synthesis,
   the stage logs a `warning` naming the pull request, the kill flag, and the
   cause carried in `merge_autonomy_kill_state`'s own returned document (never
   read directly off `$cache.err` or `$cache.repo-err` — that function alone
   knows which one actually applies), distinguishing whether a retry was
   actually taken (per requirement 8b's own contract that every other way
   this stage cannot run logs a `warning` rather than acting on silently) and
   then
   returns exactly as the plain `human` path always has — no App review, no
   change to the pull request's own state. A genuinely configured or manually
   killed `human` still logs nothing at all, the same silence as before this
   fix. This is not a new terminal state: once the retry (if any) is
   exhausted, the pull request is left carrying no App review — exactly the
   shape issue #890's own recovery sweep is built to recover, once it lands.

   The tier is resolved *after* the Reviewer stage has run, not from the
   `complexity` requirement 8a computed to choose the Reviewer's own model:
   the Reviewer may correct a `complexity:*` label it finds plainly wrong for
   the diff (requirement 30), in either direction, and that correction must
   reach this same round's Approver rather than only the next one
   (agent-ops#470). The Script re-reads the PR's `complexity:*` label once
   the Reviewer stage completes and folds it through `reviewer_complexity`
   (`lib/cycle-state.sh`) a second time — the same function requirement 8a
   already uses — with requirement 8a's own resolved `complexity` standing in
   for the Implementer's summary grade. This keeps the raise-never-lower rule
   (requirement 26a) in force at the Approver's decision point too: the tier
   can rise on a mid-cycle correction, but never settles below what the round
   was already reviewed at. `low` maps to **Trivial** — no model call, the
   Script itself posts an `APPROVE` review — `medium` to **Standard**
   (`approver_model_default`) and `high` to **High** (`approver_model_complex`,
   empty falling back to `approver_model_default`, the same escalation-off
   convention requirement 8a's own `reviewer_model_complex` uses). A
   **Critical** fourth tier (`approver_model_critical`, falling back to
   `approver_model_complex`) is never chosen by complexity — see requirement
   8c for the refuse-streak that chooses it, and this requirement's own next
   paragraph for the second, independent cause D18 WI-12 (Stage 4,
   agent-ops#415) adds.

   **A protected path forces Critical too, whatever the complexity grade
   says (D18 WI-12, same design §7 risk 1).** Before choosing a tier, the
   Script asks `landing_protected_paths_hit` (`lib/landing.sh`, the one
   protected-path classifier requirement 8d's gate 2 already reads) whether
   this pull request's diff touches a protected path. A hit — or that
   classifier's own exit 2 (an unreadable or truncated changed-file list),
   exit 3 (a `merge_autonomy_protected_paths` list it cannot evaluate
   against a path at all, TD-PPagop-26082320/TD-PPagop-26082325), or any
   exit code outside its documented 0/1/2/3 contract (e.g. 128+n from the
   command-substitution subshell being signal-killed mid-gate,
   agent-ops#1232) — every one of which routes *to* Critical rather than
   away from it, the opposite fail-closed polarity from gate 2's own
   exit-2/3 handling — this call site does not distinguish any of them the
   way gate 2's own `unknown:` reason does, since every cause forces the
   same tier here: the condition guarding the forced tier names only the
   legitimate exit 1 (no protected path touched) as an exemption, rather
   than enumerating the fail-closed codes, so nothing outside the
   documented contract can silently skip the forced tier —
   routes to Critical regardless of `complexity`, including
   `complexity:low`, which alone would have short-circuited to the
   deterministic Trivial approval with no model call at all: a one-line
   docs-graded change to `lib/` or `prompts/` gets the same critical-tier
   scrutiny as a genuine security fix, because both are self-modifying
   changes to the gate itself. This read costs one changed-file lookup per
   Approver engagement, and never runs at `merge_autonomy: human`, where
   the stage has already returned. The `approver-verdict` event's own
   `tier` field reads `critical` for either cause; a `critical_reason`
   field (`protected-path` or `refuse-streak`) distinguishes which one,
   since requirement 8d's own gate 4.5 needs to know it was specifically
   the critical tier that ran, not merely that an adjudication happened to
   land on the same model.

   `approver_model_default` empty disables the whole stage (the same
   convention `enabler_model` empty already uses for the Enabler) — every
   level above `human` then behaves exactly as `human` does, logged as a
   `warning` rather than acted on silently. `scripts/doctor.sh` fails a
   configured level above `human` with `approver_model_default` unset, the
   same fail-fast pairing it already applies to `approver_app_id`
   (requirement 2.3b) — this is a defence a *correctly* configured
   installation should never exercise at runtime, kept only for the same
   reason `lib/approver-token.sh`'s own credential-absent path is a `warning`
   and not a blocked pull request: an Approver that cannot run must cost a
   missing review, never a stranded PR.
8c. **Refuse-wins, and the adjudication path (D18 WI-5, same design §5.2).**
   A refusal is posted as a real `REQUEST_CHANGES` review from the Approver's
   own GitHub App identity (`lib/approver-token.sh`, requirement 14b), so
   GitHub itself holds the pull request at `CHANGES_REQUESTED` and the
   existing `review-feedback` source (requirement 3c) picks it up next cycle
   — no new work source, no new gate, the same mechanism a human's own
   `CHANGES_REQUESTED` already drives. Before choosing a tier, the Script
   counts the Approver identity's own current refuse streak — the number of
   `CHANGES_REQUESTED` reviews it has most recently posted on this pull
   request in a row, read fresh from the reviews list and stopping at its own
   most recent `APPROVE` (`approver_refuse_streak`, `lib/approver.sh`), never
   a count kept independently of GitHub's own record. A streak of two or more
   replaces the ordinary tiered engagement with one **adjudication**
   engagement on `approver_model_critical`, regardless of what the complexity
   grade alone would have chosen — the disagreement, not the diff, is what
   this tier is for.

   The adjudication prompt carries the pull request's prior refusal review
   bodies, oldest first (`approver_prior_refusal_bodies`), so the engagement
   judges whether those reasons were actually answered, not the diff cold a
   third time. Its verdict is `land`, `refuse` or `escalate`, and only
   `escalate` pages a human on its own (agent-ops#1214 — the prompt gives the
   model exactly this three-way meaning, and the Script's behaviour must
   match it): `land` posts an `APPROVE` review; `refuse` posts a fresh
   `REQUEST_CHANGES` review and is otherwise an ordinary refusal — the pull
   request returns to `review-feedback` (requirement 3c) next cycle exactly
   like any other refusal, raising no escalation on its own, *unless* the
   refuse streak (the same counter this requirement already reads) has
   reached the recurrence threshold of four — the third *consecutive*
   adjudication `refuse` on this pull request, since adjudication itself only
   starts once the streak already reads two — in which case it also raises
   the escalation issue below: a `refuse` naming a concrete, unanswered
   defect is work the next Implementer round can act on, but the same
   disagreement recurring three adjudication rounds running is not settling
   by itself. `escalate` raises the escalation issue
   (`approver_escalate`, reusing `create_escalation_issue`, requirement 34a's
   shared identity for that function, with the same `enabler_escalation_label`
   and `enabler_assignee` every other escalation this pipeline raises uses)
   without a fresh review, since the pull request already sits at
   `CHANGES_REQUESTED` from the two refusals that triggered this engagement.
   A stage failure or an unparseable verdict is treated the same as an
   explicit `escalate` — "cannot settle" is not read as "nothing wrong". The
   escalation issue's body states what a human should do (review and merge
   the pull request themselves), why the pipeline stopped — naming whichever
   of the three conditions actually triggered it (an explicit `escalate`, an
   unparseable/failed verdict, or a `refuse` that kept recurring), never a
   fixed "could not resolve the disagreement" sentence for all three — and
   the adjudication engagement's own `reasons`; its footer names the pull
   request as `pr-<n>-approver-adjudication`, which is what
   `create_escalation_issue`'s own open-issue dedup matches on across
   repeated rounds, so a persisting disagreement raises one issue, not one
   per cycle.

   **The filing itself is rate-limited per close (agent-ops#779, decided on
   #784 as behaviour (b)).** `create_escalation_issue`'s own dedup matches
   *open* issues only, so a human who closes the escalation issue without
   also reviewing and merging the pull request — closing is not the
   releasing act — would otherwise get a fresh issue on every subsequent
   adjudication round. Before filing, `approver_escalate` reads the most
   recently closed `enabler_escalation_label` issue for this pull request's
   own `pr-<n>-approver-adjudication` reference live from GitHub
   (`escalation_recent_close`, `lib/enabler.sh`, never a log join — the same
   "ask the thing that actually changed" reasoning `approver_refuse_streak`
   already applies). Filing is suppressed — logged as a `warning` naming the
   prior issue and the UTC instant the window lapses, with no GitHub write —
   while `now − closedAt` is less than `escalation_refile_after_hours`
   (`escalation_refile_suppressed`, `lib/escalation-autonomy.sh`, a pure
   comparator), *unless* it is the one immediate re-escalation a failed
   post-close adjudication owes: `approver_escalate` runs only from the
   adjudicating branch, so "an adjudication pass ran this round" is always
   true here, and the carve-out reduces to whether an `approver-escalated`
   event for this pull request already exists on the log at or after that
   close (`escalation_event_logged_since`). That first post-close filing
   always proceeds, window or not — each human close buys at most one
   immediate re-file plus whatever the window permits after it lapses.
   Whenever a recent close is found and the filing proceeds regardless of
   which of those two paths let it through, the issue body gains a "Why this
   is back" section naming the prior issue, its close time, and that the
   pull request's own `CHANGES_REQUESTED` state — not the closed issue — is
   what still blocks it. `escalation_refile_after_hours: 0` disables the
   guard outright, guarded explicitly rather than left to the arithmetic:
   every refusing round files, exactly as before this guard existed. The
   identical guard, sharing both functions, applies to requirement 8f's own
   `open_question_escalate` below.

   The escalation is retired — closed with a comment naming what ended the
   disagreement, and an `approver-escalation-retired` event (`pr_url`,
   `issue_number`, `issue_url`, `cause`) — the moment the pipeline can see
   that disagreement is over, from either of the two places that can happen
   without the human ever touching the issue (agent-ops#1215): `cause:
   "land"`, the instant this round's own adjudication posts an `APPROVE` that
   actually reaches GitHub (`approver_escalation_retire`, called from this
   same `land` branch, gated on `approver_post_or_warn`'s own delivery
   confirmation rather than the verdict alone); or `cause: "merged"`, when
   `scripts/sweep-closed-issues.sh`'s fleet-wide merged-pull-request listing
   (requirement 17c) finds the pull request merged some other way — a
   human's own click, a later automatic landing, or a merge queue resolving
   well after this round. Both read back the same dedup lookup
   `create_escalation_issue` performs on the way in — an open issue carrying
   `enabler_escalation_label` whose body quotes this `pr-<n>-approver-
   adjudication` reference — and both are a no-op, logging nothing, when no
   such issue is open, which is the common case: most pull requests never
   escalate at all. Both close it inside the same
   `pipeline_comment_header`/`pipeline_comment_marker` envelope every other
   comment this system posts carries (requirement 3f), and both skip an issue
   GitHub reports reopened (`stateReason`, read on the same listing): a
   human's own re-open wins over either retirement, the same answer
   requirement 34k's one-shot rule and requirement 17c's own
   `state_reason: "reopened"` check give everywhere else this system closes
   something. Left unretired before this, the escalation survived its
   own disagreement indefinitely — agent-ops#1202 sat open for eight hours
   after the adjudication that answered it, asking a human to review and
   merge a pull request that had already merged, until they closed it by
   hand.

   No *Approver* engagement merges, at any tier, at any `merge_autonomy`
   level. `agent-merges-routine` and `agent-merges-all` run the identical
   Approver review this requirement and 8b describe, but this stage never
   lands anything at any level — landing, where it happens at all, is
   requirement 8d's own separate arming step, run strictly after this stage
   returns (see "## The Landing Gate"). The cardinal rule survives
   regardless of level:
   the model never holds approve or merge rights; every GitHub write this
   stage makes is a Script-issued `gh api` call under the Approver's own
   minted token (`approver_post_review`), never a prompt-issued `gh pr
   review` or `gh pr merge` — `prompts/approver.md` is explicitly forbidden
   both, and the model's only output is a JSON verdict.

   **The token those writes spend is minted fresh once the engagement
   returns, never the one read before it started (agent-ops#945).** Before
   launching the model, the Script confirms an installation token can be
   minted at all (`approver_token_get`) purely as a pre-engagement gate — "is
   the credential even readable" — the same value the Trivial tier's own
   deterministic, no-model approval spends directly, since nothing runs
   between that read and its one write. Every other tier launches a model
   engagement that can run for minutes to close to an hour, near an
   installation token's own ~1 h life, so once it returns the Script reads
   `approver_token_get` again, once, immediately before the first write, and
   spends that one fresh mint across the whole write block — both
   `techdebt_file_debt`/`techdebt_file_issue` filings (requirement 40) and
   both `approver_post_or_warn` call sites — rather than the token read
   before the engagement, which a long-enough round can outlive. The restale
   sweep's own re-review (requirement 46, `_approver_restale_review`) gets
   the same treatment for free: it re-enters this same function rather than
   duplicating it. A token that cannot be minted again once the engagement
   returns logs a `warning` distinguishing that ("mintable at stage entry,
   not after") from the pre-engagement gate's own failure text, escalates if
   an adjudication was in progress (the same "cannot settle" treatment an
   unparseable verdict already gets), and otherwise costs a missing review
   this round, never a stranded PR. The verdict the engagement actually
   reached was still paid for in full, so this path also logs its own
   `approver-verdict` event — `posted: false`, the verdict and the rest of
   this requirement's own fields populated exactly as the ordinary path at
   the tail of this stage populates them (agent-ops#1066) — without setting
   `approver_stage_verdict`/`approver_stage_adjudicating`/`approver_stage_tier`,
   which stay at this stage's own entry-time reset so that requirement 8d's
   landing gate never arms a pull request that carries no App review at all.

   A review GitHub itself refused — an installation that lost review rights
   mid-round, an API outage — is logged as a `warning` naming the pull
   request and the event (`approver_post_or_warn`, requirement 33) and
   changes nothing else: the pull request stays exactly as the human already
   had it, which is 8b's "a missing review, never a stranded PR" at the one
   point where the failure is the write itself rather than the decision.
   `approver_post_review`'s own refusal — GitHub's actual status and body —
   lands in `approver-post.err` in the cycle directory, the same "keep what
   GitHub actually said" discipline `techdebt_file_debt`'s own
   `tech-debt-file.err` already applies, and the `warning` names that file.

   **A refusal that is specifically a GitHub REST rate-limit refusal is
   classified and retried, not dropped on the first attempt (agent-ops#1082).**
   `approver_post_or_warn` classifies what it just left in
   `approver-post.err` via `github_limit_kind` (`lib/github-limit.sh` —
   reused, not reclassified) and, only when the cause was rate-limiting,
   tries the write once more through `github_limit_wait_plan`'s existing
   wait/backoff (the same policy the `gh` wrapper's own single attempt
   already applies, taken a second time here because that wrapper commits to
   exactly one wait-and-retry per call and gives up silently once it does) —
   `github_limit_primary_reset_epoch` answers the "when does this reset"
   question a primary refusal needs for that wait the same way the wrapper's
   own retry does. The `warning` this logs either way names the rate limit
   distinguishably from a generic refusal, and whether a retry was actually
   attempted, so an operator can tell "no human review reached this pull
   request because the owner's shared REST budget was gone" from a genuine
   fault — the same distinction requirement 38a's own review-request read
   and the idle-nudge check's reviews read draw at their own call sites.
8d. **The arming step (D18 WI-7, same design §5.1/§6/§7; agent-ops#410).**
   Immediately after `run_approver_stage` returns — never before, and gating
   nothing above it, the same placement 8b already establishes for the
   Approver stage itself relative to the handoff — `run_landing_stage`
   (`lib/landing.sh`, called from `agent-cycle.sh`'s own phase sequence)
   decides whether to land the
   pull request this cycle just reviewed. It arms nothing at all unless this
   very round's own Approver engagement reached an explicit, non-adjudicating
   `approve` — an adjudication's own `land` does not count, because a
   disagreement settled this round is not the same fact as an engagement
   that agreed the first time, and a tier the Approver stage never reached
   at all (the stage disabled, a credential absent, an unparseable verdict)
   arms nothing by construction. Everything else is re-read fresh from
   GitHub at the moment of decision, never reused from earlier in the round
   — the same discipline `lib/review-gate.sh` established for the ready-gate
   handoff, applied here because nothing that arms an automatic merge may
   trust state more than one function call old:

   1. `merge_autonomy_effective_level` (`lib/merge-autonomy.sh`), called
      with `FRESH` (issue #513) so the kill switch bypasses this process's
      own memo — must still be `agent-merges-routine` or
      `agent-merges-all`. The kill switch or a WI-6 budget freeze may have
      moved since the Approver stage ran. A refusal here names its actual
      cause (`landing_autonomy_refusal_reason`, `lib/landing.sh`, D18 issue
      #576, exercised end to end — one case per `merge_autonomy` rung — by
      `test/landing-kill-switch-wiring.test.sh`): a second, independent read
      of `merge_autonomy_kill_state` (also `FRESH`, since gate 1's own LEVEL
      read already carries it) tells the fleet-wide kill switch apart from a
      repository that simply has not had its level raised, since LEVEL alone
      is the *collapsed* answer and does not itself say why it collapsed. The
      `kill-switch:` tag this branch prefixes onto its `reason`
      (`landing-refused`, requirement 33) is what lets
      `scripts/publish-dashboard.sh`'s landings digest (`byReason`,
      `dashboard/index.html`) group it apart from every other refusal class,
      including the plain "effective level is …" wording this gate emits
      when the level was simply never raised — one tag among the class
      prefixes every colon-carrying refusal reason in this step wears
      (requirement 33).
   2. `landing_eligible` (`lib/landing.sh`) — the deterministic classifier: a
      `complexity:*` grade in this repository's own
      `merge_autonomy_routine_complexity` (default `["low", "medium"]`; D18
      Stage 3, agent-ops#725), a `source` in this repository's own
      `merge_autonomy_routine_sources`, and `landing_protected_paths_hit`
      reporting no protected path touched (`.github/`, `deploy/`,
      `prompts/`, `lib/`, `config.schema.json`, `CODEOWNERS` — anchored
      whole-path prefixes, in the shape `scripts/is-docs-only.sh` uses for
      its own allowlist; `lib/landing.sh` is self-protecting through the
      `lib/` prefix already). Reads the changed-file list fresh from GitHub
      (`gh api repos/SLUG/pulls/N/files`), bounded and truncation-checked
      the way `lib/github-limit.sh`'s `GITHUB_PR_LIST_LIMIT` bounds a `gh pr
      list` — a truncated or unreadable list is `unknown`, never a pass, and
      so is a `merge_autonomy_protected_paths` list `_landing_is_protected`
      cannot even evaluate against a path (a non-string entry, which raises
      rather than returns false; TD-PPagop-26082320) — never read as "no
      protected path touched" merely because the comparison itself failed.
      The two causes are distinct exit codes from `landing_protected_paths_hit`
      (2 for the changed-file list, 3 for the protected-paths list) and
      `landing_eligible` names which one fired in its own `unknown:` reason
      text, rather than blaming the changed-file list regardless of cause
      (TD-PPagop-26082325). Any exit code outside `landing_protected_paths_hit`'s
      documented 0/1/2/3 contract (e.g. 128+n from the command-substitution
      subshell being signal-killed mid-gate, agent-ops#1232) is `unknown` too
      — `landing_eligible`'s own `hit_rc` case names the legitimate exit 1
      explicitly and fails every other unrecognised code closed, rather than
      falling through to the same `eligible` arm exit 1 reaches. `unknown` is
      treated as `ineligible` at this and every other call site; an empty or
      unrecognised `source` or
      `complexity` is `ineligible`, never eligible by omission. Widening
      `merge_autonomy_routine_complexity` to admit `high` interacts with
      requirement 26a, which already forces that grade onto anything
      touching concurrency/locking, security, CI/workflow machinery or
      shared library code — so this key's ceiling and that rule's floor meet
      at the same diffs, and the protected-path gate below stays in force
      regardless of this key (risk register item 1's belt and braces).
      Protected paths refuse arming at every level below
      `agent-merges-all` unconditionally. At `agent-merges-all` a hit
      is deliberately reported `eligible` instead (D18 WI-12, Stage 4,
      agent-ops#415) — this classifier alone cannot see the two
      compensating controls §7 risk 1 requires, so it defers rather than
      refuses, and gate 4.5 below is what actually decides. A resolved
      `merge_autonomy_protected_paths` of `[]` — schema-valid, since the
      schema constrains each entry to a non-empty string but sets no
      `minItems` — disables this gate for that repository at every level: an
      operator may legitimately want that for a repository whose own gate
      code lives elsewhere, so this classifier honours the empty list
      exactly as any other, but reaching it silently would leave a
      repository at `agent-merges-routine` or above with its deadliest
      landing gate off with nothing to show for it; `scripts/doctor.sh`
      (component 14, D18 Stage 3, TD-PPagop-26082403) warns, naming the
      repository and its configured level, when its resolved list is empty
      and its configured `merge_autonomy` is `agent-merges-routine` or
      above, the same shape as its neighbouring `landing_cool_off_hours 0`
      warning.
   3. `review_gate_verdict` (`lib/review-gate.sh`) — must read `clean`.
      Stricter than the ready-gate handoff's own use of this function
      (requirement 31a): there, an alerts-only `unknown` still lets the
      handoff proceed with a logged warning; here, any word but `clean` —
      `dirty` or either flavour of `unknown` — refuses arming outright.
   4. The Approver App's own review is genuinely standing `APPROVED` on
      GitHub right now (`landing_approver_standing_review`,
      `lib/landing.sh`), and no human `CHANGES_REQUESTED` stands
      (`_handoff_blocking_reviewers`, `lib/handoff.sh`, requirement 34a's
      own standing-position computation, reused rather than re-derived for
      the human half). Both fresh reads, and the first is not redundant
      with the explicit `approve` gate 0 already required: `approver_post_or_warn`
      always returns 0 even when the write itself failed ("a missing
      review, never a stranded PR", requirement 8b) — a review GitHub
      itself refused reaches this point with `approver_stage_verdict` still
      reading `approve`, which is this process's own *intent*, never proof
      the review exists. `_handoff_latest_reviews` cannot answer the first
      half either way — it excludes bots outright (requirement 34a), and
      the Approver posts as one — so `landing_approver_standing_review`
      reads the same endpoint directly, filtered to the App's own login.
      `landing_approver_standing_review_at` (D18 WI-12) is what this gate
      actually calls — the same one reviews-list read, plus the standing
      review's own `submitted_at` and `commit_id`, at no extra cost — since
      gate 4.5 needs both and it is never worth a second fetch.

      Neither of the two reads above sees a plain comment: a human cannot
      leave a formal `REQUEST_CHANGES` review on this system's own pull
      requests at all (GitHub refuses that review type from a pull request's
      own author, and every pipeline write and every human comment here land
      under the same account), so an ordinary comment is their only
      instrument, and `_handoff_blocking_reviewers` reads only formal
      reviews. `lib/reconciliation-gate.sh`'s `reconciliation_gate`
      (requirement 31c, agent-ops#533) already closes that gap at the
      Reviewer's own ready-flip — a pull request carrying an unreconciled
      comment since it last left draft cannot be flipped Ready in the first
      place — but that gate runs once, at hand-off, and does not reach here:
      a plain comment posted after the pull request is already Ready, in the
      window before a later cycle's arming step lands it, was answered by
      neither mechanism (agent-ops#672). Gate 4 closes that residual window
      by calling `reconciliation_gate` itself a second time, unbounded (no
      `NOT_AFTER`) — this stage never flips the pull request out of draft the
      way the Reviewer's own call must guard against, so the real current
      "last left draft, and stayed left" anchor is exactly the read this gate
      needs. `dirty` refuses arming, naming the unreconciled comment(s) as
      the reason; any other answer that is not `clean` — `unknown`, where the
      timeline or the comment list could not be read, and the empty word left
      behind by a call that did not execute at all — refuses too (#753's
      ruling on agent-ops#746), naming the pull request and what could not
      be confirmed. Neither is unfolded as a case distinct from the other,
      and neither is conditioned on `merge_autonomy_effective_level`: unlike
      the Reviewer's own reconciliation read at hand-off, which does
      tolerate an `unknown` there with a logged warning, this arming-time
      instance never lets an unanswered question pass. Only the exact word
      `clean` passes silently: a veto check that reads as clear on the one
      path where it never ran is the failure this gate exists to prevent.
      Because every non-`clean` word now refuses before this gate sequence
      can reach an arm, the landing audit record (requirement 8x) can only
      ever carry a `comment-reconciliation` entry reading `clean`.
   4.5. D18 WI-12 (Stage 4, agent-ops#415): only at `agent-merges-all`, and
      only for a pull request `landing_protected_path_controls_ok`
      (`lib/landing.sh`) itself re-confirms still touches a protected path —
      gate 2 above already deferred, rather than refused, that case. Three
      controls must hold — the two compensating controls §7 risk 1 names,
      plus the head-match that is what makes the second of them measurable
      here: the
      approving engagement ran at the Critical tier (requirement 8b's own
      `critical_reason`; read from this round's own in-process fact on the
      round that first approved the pull request, or from the fleet log's
      `approver-verdict` event, `landing_retry_tier`, on a landing-retry
      sweep re-arm outside that round — requirement 8u); the standing
      review's own `commit_id` (gate 4's own read) still matches a fresh
      read of the pull request's current `headRefOid`; and the configurable
      `landing_cool_off_hours` (default 24, `0` disables) has elapsed since
      gate 4's own `submitted_at`, re-read fresh every time this gate runs
      rather than cached anywhere. A push after approval moves `headRefOid`
      without touching the standing review at all — nothing in this
      pipeline dismisses a stale review on push — so a `commit_id` mismatch
      refuses on its own, regardless of how much of the cool-off has
      otherwise elapsed: there is no fresher `submitted_at` to measure from
      until the Approver reviews the new head, which is the sense in which
      a fresh push restarts the wait rather than merely pausing it. Any
      control unmet refuses, naming the tier it actually found, the
      mismatched commits, or the remaining cool-off time; an unreadable
      re-check of the changed-file list or of the pull request's current
      head is `unknown`, never a pass. A pull request that does not touch a
      protected path at all clears this gate immediately, since none of the
      three controls applies to it.
   5. `merge_budget_decide`/`merge_budget_apply_decision`
      (`lib/merge-budget.sh`, requirement 2.3c) — only `arm` proceeds.
      `hold` (the budget is exhausted) and `refuse` (the count could not be
      established) are applied — logging `merge-budget-hold`, or a
      `warning` for `refuse` — and stop here; neither arms anything, and
      this call itself does not queue a retry of its own. The landing-retry
      sweep (requirement 8u, "## The Landing Gate") is what re-enters this
      whole gate sequence for such a pull request on a later cycle, rather
      than this gate doing so itself. `merge_budget_decide` reads an
      ALREADY_ARMED count from its own caller and discounts it from the live
      merged-PR count before comparing to the cap — GitHub's own record only
      ever shows a pull request as merged once the merge has actually landed,
      never the moment this gate arms its enqueue or auto-merge, so any two
      calls into this gate within one cycle must share a running tally or
      each reads the same not-yet-merged count and both arm (requirement
      8u's own bound; PR #557 review round 2 widened this from a tally
      private to the landing-retry sweep's own pass to
      `landing_armed_by_repo`, a cycle-scoped map keyed by repository slug
      that this gate's two call sites — the sweep and this stage's own gate
      0 — both read and grow, since either can run first within one cycle
      process).
   6. `merge_queue_probe` (`lib/merge-queue.sh`) — the pull request must not
      already be queued, and must not have been queued and removed without
      being re-queued since. "Could not read" is "possibly queued or
      dequeued" (the same rule the merge-queue-awareness discipline already
      applies elsewhere in this document), so it refuses too. A dequeue this
      stage finds is never its own to retry (PR #557 review round 2):
      `merge_queue_dequeue_actionable` (`lib/merge-queue.sh`) only ever
      chooses the refusal's wording, never whether it refuses — a `manual`
      removal is the maintainer's own deliberate act, reversing it would
      silently undo their click every cycle for as long as the pull request
      stays open, and any other reason (chiefly `failed_checks`) is exactly
      what `scripts/gather-dequeued.sh`'s own `dequeued` source exists to
      diagnose and fix before a human re-queues — arming it blindly here
      instead would re-run the same failing merge group once per cycle
      indefinitely, for no forward progress.

   Any read above that cannot be answered is a refusal — logged
   `landing-refused` (requirement 33) — never a pass, and every refusal
   path costs exactly that: one log event, never a blocked pull request,
   never a withheld claim, the same "a missing action costs a missing
   action, never a stranded PR" contract 8b already establishes for the
   Approver stage. Only once every gate above clears does `landing_arm`
   (`lib/landing.sh`) perform the one write: `merge_queue_for_branch`
   (`lib/merge-queue.sh`, beside `merge_queue_probe`) reads whether the pull
   request's base branch itself carries an active merge queue — where it
   does, `enqueuePullRequest` (GraphQL); where it does not, `gh pr merge
   --auto --squash`. Both run under the Approver App's own minted
   installation token, as a leading one-invocation `GH_TOKEN="$token" gh …`
   assignment — never `export`, exactly as `approver_post_review` already
   does and for the same reason: never the pipeline's own authoring
   identity — the owner's `GH_TOKEN`, or, once provisioned, the forge
   authoring App (D25, component 14g) — which would collapse the
   two-identity audit trail §5.3 exists for into the same account
   authoring, approving and landing every pull request. A successful arm
   logs `landing-armed`
   exactly once, naming the `method` actually used (`enqueued` or
   `auto-merge`), and never withholds anything requirement 8b already did.
   `auto-merge` names the *call* made (`gh pr merge --auto --squash`), not a
   guarantee it armed anything to fire later: with the `gh` CLI version the
   node image installs, that call merges the pull request immediately from
   `CLEAN`/`UNSTABLE` rather than deferring, and only genuinely arms
   auto-merge from `BLOCKED` (agent-ops#553; `lib/landing.sh`'s own header
   carries the full finding).

   The fleet-wide kill switch and a per-repository downgrade (setting
   `merge_autonomy` back to `human` or `agent-approves`) both disarm
   cleanly: `merge_autonomy_effective_level` is what gate 1 above reads,
   never the raw configured value, so the very next round this function
   runs for a repository at or below `agent-approves` refuses at gate 1
   before any other read — no separate switch, no partial disarm.
