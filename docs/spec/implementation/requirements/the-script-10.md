## Requirements

### The Script — requirements, continued (part 10 of 13; 9–17d: Failure handling and execution control…)

9. <a id="impl-9"></a>**Failure handling.** If any stage times out, exits non-zero, or returns
   an unparseable summary: kill that stage's process group, log
   `attempt-failed` with enough detail for a future cycle to know the item
   is blocked and what would unblock it, and — if a draft PR was already
   opened — comment on it that the agent has abandoned it and why, leaving
   the PR and branch for the human to keep or discard.

   Naming that pull request is the Script's job, not the failed stage's, and
   it tries four things in order, each less dependent on the stage than the
   last: the `pr_url` of a parseable final message; a pull-request URL
   grepped from the stage's output; the `.git/agent-ops-pr-url` breadcrumb in
   the clone (requirement 23); and finally an open pull request whose head is
   the branch this cycle claimed (requirement 17a), asked of GitHub directly.
   **The last of those is the one that must exist**, because the first three
   are all things the Implementer had to remember to do, and a stage that
   emitted no parseable final message is exactly a stage that may have
   remembered none of them — whereas the branch was computed and pushed by
   the Script before the stage began. Each lookup coming up empty is an
   ordinary outcome, not an error: under `errexit` a non-zero from any of
   them kills the cycle before it logs the very failure this requirement is
   about (see Gotchas).

   The consequences of failing to name it are not confined to this
   requirement, which is why the fourth lookup is required rather than
   merely sensible: no stage-failure comment reaches the pull request
   (above), no `pr_url` travels on the `attempt-failed` event (requirement
   32a), and so the Enabler's one power to clear this kind of block by act
   rather than by verdict — `complete_handoff`, gated on that field
   (requirement 32b) — is unavailable for precisely the failure it exists to
   recover.
9a. <a id="impl-9a"></a>**A reported verdict is not a failure.** A stage that runs to completion
   and ends with `{"status": "blocked", …}` or `{"status": "void", …}`
   (requirement 27) has not failed: it has spent a full model run
   establishing something worth keeping. Record it against the selected item,
   carrying the stage's own words verbatim, rather than routing it through
   requirement 9's path (which would file it as "exited 0", discarding what it
   found) or, worse, dropping it. This is what stops the pipeline buying the
   same discovery every cycle for as long as the item exists.
9b. <a id="impl-9b"></a>**`blocked` and `void` are different states and must not share one.**
   This is the requirement most likely to be read as pedantry and collapsed
   into "an item that can't proceed". Do not.
   - **`blocked`** — the work is real, something is in the way *for now* (an
     unmerged dependency, a red check, a decision nobody has taken). Record
     `attempt-failed` with the stage's `reason` and `unblock_condition`. The
     Co-Ordinator is expected to re-check these and clear them (`unblocked`)
     when the impediment lifts.
   - **`void`** — there is no work: the premise is false, almost always
     because the item is already done on `default_branch`. Pass the stage's
     `reason` and `evidence` through requirement 34d's shared corroboration
     guard first; record `item-void` only if it passes, `attempt-failed`
     (outcome `void-refused`) if it does not. **No agent may ever clear a
     recorded void**; only a human, by appending `unvoided` to the log by
     hand.
   The failure mode if you merge them is specific, silent, and was found in
   production rather than in review. An already-done recommendation is filed
   as `blocked`. The next Co-Ordinator, obeying its standing instruction to
   clear blockers that have gone away, checks the item, finds the work is
   done, correctly concludes that nothing is in its way, and logs `unblocked`.
   The item returns to the pool, is selected, is rediscovered as already done,
   and is filed again — indefinitely. Every component behaves exactly as
   specified. The bug is that one channel carried two meanings, so the
   evidence that should have shut the item forever (*the work is done*) was
   the very evidence that reopened it. If a state can be cleared by the same
   fact that ought to make it permanent, it is the wrong state.
9c. <a id="impl-9c"></a>**A signal is a failure with a record.** The Script traps `TERM`, `INT`
   and `HUP` from the moment its cleanup trap is armed. The kills that reach
   it are real and routine — a peer taking over a stale lock TERMs the whole
   process group (requirement 1), an operator stops a container, a `--once`
   run is interrupted at the terminal — and before this requirement any of
   them ended bash between one statement and the next: no `attempt-failed`,
   no claim release, no `cycle-end`, and the in-flight stage's own process
   group (detached from the Script's by design, so the timeout can kill it
   whole) left running a model for a cycle that was already dead. The
   handler, in an order that is itself the requirement:
   1. kills the in-flight stage's process group, if any, with KILL — the
      signaller's patience is unknown and may be two seconds, and a stage
      whose cycle is dead has nothing left to negotiate;
   2. logs `attempt-failed` against the selected repo+item where one exists
      (so requirement 34's blocked extract sees the death), with detail
      `<stage> terminated by SIG<name>` naming the stage that was in flight
      — or `cycle` when none was — and carrying `pr_url` when the
      requirement-23 breadcrumb identifies one (read before the clone is
      deleted, since the breadcrumb dies with it);
   3. releases the claim (`have-pr` when a PR is known, `no-pr` otherwise),
      time-bounded to 8 seconds — releasing now beats waiting out the gc's
      `claim_ttl_hours`, but not at the price of the exit record — and
   4. exits `128+n` through the ordinary `exit`, so the EXIT trap still
      writes `cycle-end` with a truthful code, releases the lock and pushes
      state, and `maybe_run_enabler`'s cycle_rc guard skips the Enabler
      without being asked.
   A stage that had already ended cleanly is never blamed: the stage
   pid/name pair is advertised only while a stage is in flight. A signal
   landing during cleanup itself must not re-enter the handler.
   `review-cycle.sh` carries the same discipline as R7a of its own spec.
9d. <a id="impl-9d"></a>**Visible attribution.** Every pull-request or issue comment this system
   posts — from `agent-cycle.sh` directly, and from the Implementer, Reviewer,
   Enabler and Refiner — opens with a leading bold line naming the Actor that
   wrote it and the node it ran on:

   ```
   **<Display>** · autonomous pipeline · node `<node>`
   ```

   then a blank line, then the comment's own prose. The Actor is whichever
   stage **wrote** the comment, not the one it is about — the Script's own
   stage-failure note carries `**Script**`, with the stage that failed named in
   the prose (`The Implementer stopped on this PR: …`), spelled from the same
   token→display map below, and no other preamble.
   This exists because requirement 3e's own text already states the reason no
   other signal can: every pipeline write lands under `warwickallen`, the same
   GitHub account a human also comments as, so the author field cannot tell a
   human's comment from the pipeline's, including which comments are a human's
   own. `lib/pipeline-marker.sh`'s `pipeline_comment_header ACTOR NODE` prints
   the line; `pipeline_actor_label TOKEN` is the token→display map, matching
   this document's, `docs/spec/review/README.md`'s and
   `docs/spec/monitor.md`'s *Actors* sections and
   the vocabulary `dashboard/index.html`'s `ACTOR` map already uses, and it
   fails open on an unknown token — prints it raw — so an Actor added later
   degrades gracefully rather than vanishing from a comment. `agent-cycle.sh`
   and `review-cycle.sh` call it directly; a model cannot source shell, so
   `prompts/implementer.md`, `prompts/reviewer.md`, `prompts/enabler.md` and
   `prompts/refiner.md` each spell the header's literal form out and instruct
   their stage to open every comment with it, using the node name each receives
   at invocation verbatim (`## Node` for the Implementer and Reviewer; the
   runtime input's `node` for the Enabler and the Refiner, each of which
   already received it). Regression-tested by
   `test/comment-identity.test.sh`.
9e. <a id="impl-9e"></a>**Salvage before discard.** Before requirement 9's failure path fires on
   an unparseable final message — the Co-Ordinator, Implementer and Reviewer
   stages here, and requirement 37's Enabler engagement — the Script makes
   one bounded resume attempt, provided the failed run actually left a
   session behind to resume: `run_model_stage` again, `--resume`d onto the
   `session_id` the failed run's own envelope carried, prompted with nothing
   but "return the verdict JSON object, nothing else." A run that timed out
   or exited non-zero has no living session behind it and is never salvaged
   — only a process that exited 0 and still left `extract_json_result`
   nothing to parse gets the attempt (`stage_salvage_result`,
   `lib/stage-attempt.sh`). The resume is capped at a fixed, conservative
   `stage_salvage_backstop_sec`/`stage_salvage_inactivity_sec` (5 minutes /
   90 seconds) rather than requirement 4f's adaptive per-(actor, repository,
   model) budget — a continuation with no tool calls needs none of that
   estimation, and a bound that could grow to a whole stage's own backstop is
   not a bound worth having. The resume also forces `run_model_stage`'s own
   LANE (requirement 4d, issue #2436) onto the original run's own lane rather
   than letting the retry draw again under the `"<stage>-salvage"` name — it
   is the same launch continuing, not a new one, so it is billed and recorded
   on the one lane throughout — which means the resume inherits forcing's own
   failure mode: a node whose credential for that lane has gone away between
   the original run and the resume fails the salvage outright as "no open
   lane" (requirement 4d), where the undifferentiated draw this replaced
   could instead have landed on the node's other open lane.

   When the resume's own final message parses, its object is used exactly as
   if the original run had produced it — no failure is recorded here, no
   `attempt-failed`, no discard — and a `salvage` event with
   `outcome: "recovered"` is logged (requirement 33). When it does not
   (including when there was no session to resume at all), requirement 9's
   ordinary failure path runs unchanged, `salvage` events record
   `outcome: "attempted"` and `outcome: "failed"` for the attempt, and the
   resume's own use of `run_model_stage` never leaks into the *original*
   run's kill-reason, gap or rate-limit bookkeeping — `stage_salvage_result`
   saves and restores them around its own call, because
   `detect_and_log_limit_hit` still reads them against the original `.out`
   file afterwards and must see what that run actually reported, not what
   the resume did.

   The fenced-block parse this backs up is itself widened alongside it: a
   verdict fenced without a `json` info string, or with a different one,
   parses on the straight fallback and never needs a salvage at all — only
   the fence's *presence*, not its tag, was ever what told a verdict apart
   from prose (issue #237).

   This exists because a model slipping the final-message contract is not
   evidence the work itself was wrong. On 2026-08-07, poetic-2's completed
   conflict resolution of PR #205 was correct, fenced without a `json` tag,
   and discarded anyway — erasing the pipeline's memory that the conflict
   was fixed and triggering a three-node duplicate-work cascade on the same
   PR. A background task left running past the final message ("I'll check
   back shortly") is the same shape from the runner's side: real work,
   wrapped wrong. A discard should cost a retry only when a stage genuinely
   produced nothing usable, not when the parser of the day could not yet see
   what it produced.
9f. <a id="impl-9f"></a>**`needs-refinement` is the Implementer's own escape hatch, and a third
   state alongside `blocked` and `void` (extending requirement 9b).** A stage
   that ran to completion and reported `{"status": "needs-refinement", …}`
   (requirement 27) found real work whose *specification* — not the world
   around it — is what stopped it: no acceptance criterion it could find, a
   scope too vague for two implementations of it to agree. Recorded through
   `record_needs_refinement_block` (`lib/candidate-select.sh`), the same
   recorder a
   Co-Ordinator's own `needs_refinement` report uses (requirement 34e) and,
   independently, the Refiner's own decline (requirement 39d) — one
   definition (requirement 34a), three reporters, attributed by `stage`
   (`"coordinator"`, `"implementer"` or `"refiner"`) so a reader can tell
   which one found the gap.

   Distinct from `blocked` on purpose, on the same reasoning requirement 9b
   already gives `blocked` against `void`: `blocked` says something in the
   world is in the way and resolves when that changes; `needs-refinement`
   says the brief itself is short of what "done" would mean, and resolves
   only once someone — a human, or the Refiner working the item again — adds
   to it. Collapsing the two would age an honest "the spec doesn't say
   enough" on the same clock as "the build is red", when the two need
   entirely different attention and, per the reasoning below, different
   consequences for a `refined` mark the item might be carrying.

   If the item carried a `refined` mark (requirement 39c (The Refiner)) when the
   Implementer selected it, that mark no longer describes the item
   accurately — the specification it named was tried and found wanting — so
   recording the block also removes `refined_label` from the issue, if the
   item has one and carries it, mirroring `release_refinement_label`'s
   removal of `needs_refinement_label` when a block clears, but here on block
   *creation* rather than clearance, and for the positive label rather than
   the negative one. Requirement 3h's `refinements_map` independently stops
   naming the item from the moment a fresher `needs-refinement` block exists
   for it (comparing `ts` to `blocked_ts`), which is what stops a
   Co-Ordinator pasting a specification the Implementer has already found
   wanting into a future work order, whether or not the label removal itself
   succeeded.
9g. <a id="impl-9g"></a>**A stage killed abruptly states, in its own comment, whether it
   pushed.** Requirement 9's stage-failure comment, for every detail branch
   where the stage actually launched and so could have posted something
   before it stopped — the inactivity watchdog (`rc` 124, `stage_kill_reason`
   `inactivity`), the rate-limit stop, a plain wall-clock timeout (`rc` 124
   with no kill reason), and a generic non-zero exit such as a SIGKILL/OOM
   death — names the pull request's head SHA at the start of the round and
   at kill time, so a reader does not have to re-verify the stage's own
   comments against the head blob by hand to tell announced-but-unpushed work
   from work that landed. The two SHAs equal is the signal that matters
   most: it says plainly that the round pushed nothing, so every comment that
   round posted describes intent, not landed work. The two SHAs differing
   still names both, inviting the reader to diff the round's actual
   contribution against what its comments claimed, since some of it may have
   landed. Only the two branches where no stage ever ran — an API refusal
   before launch, and the "not launched" cases — carry no such sentence,
   since there is no stage activity to reconcile against a head SHA.

   The round-start SHA is read by whichever of `lib/coordinator-phase.sh`'s
   two call sites of `handle_stage_failure` can name a pull request before
   its stage launches — the Implementer's, for the five finishing sources
   whose work order already carries a `pr_url`
   (`preflight_existing_branch_source`), and the Reviewer's, whose subject is
   always the pull request the Implementer has just raised or confirmed —
   one `gh pr view --json headRefOid` call immediately ahead of that stage's
   own `run_model_stage`, held in `stage_pr_head_sha_at_start` and read
   inside `handle_stage_failure` as a global rather than threaded through as
   an argument, the same pattern `stage_kill_reason` itself already uses. An
   ordinary fresh claim has no pull request yet at round start — the
   Implementer raises it during the round — so that case leaves the variable
   empty and carries no such sentence. The kill-time SHA is read the same
   way, inside `handle_stage_failure` itself, once the stage has stopped.
   Either read missing or failing (no pull request yet, a closed pull
   request, a transient API fault) drops the sentence rather than the
   comment: the ordinary wedged-stage notice (requirement 9) still posts
   regardless.

   This exists because a stage that comments before it pushes can leave a
   pull request thread asserting fixes it never pushed, with nothing to
   reconcile the claim against the head SHA — observed live on PR #2218
   (agent-ops#2236), where a Reviewer's inactivity kill followed two long
   comments claiming fixes "in this round" that were absent from the diff,
   and the Script's own follow-up note ("produced no output at all … and was
   stopped as wedged") read as "the stage said nothing" rather than "the
   stage said a great deal and then failed to act on it". The same gap is not
   specific to the inactivity kill: PR #2437 (agent-ops#2510) showed it again
   through a SIGKILL, where a Reviewer named two findings it was "fixing on
   the branch", was killed at exit 137, and the stage-failure comment that
   followed named only the exit code — leaving the thread's most recent
   substantive comment describing work that did not exist. Any stage that
   can comment on a pull request before it pushes, stopped abruptly by any
   means, can produce the same gap.
10. <a id="impl-10"></a>**Usage-limit detection.** Two sources, and the structured one is
    preferred wherever it exists. When a stage was stopped because its stream
    reported the account `rejected` (requirement 4e), the `limit-hit` is
    derived from that `rate_limit_info` by `limit_decide_structured`: it
    states `resetsAt` as an epoch, so the stand-down is a fact rather than an
    estimate, and it is the only source available on that path at all, since a
    stage stopped at the refusal writes no final message for a phrase matcher
    to read. Otherwise — and whenever any stage's transcript matches the
    phrase table `limit_phrase_regex_for` selects for its own provider
    (`stage_provider`, issue #2135) in `lib/limit-detect.sh` — `LIMIT_PHRASE_REGEX`
    (the generic `hit your .* limit` stem plus the legacy `usage limit` /
    `rate limit` / `usage cap` / `quota exceeded` terms) for `anthropic` and
    any provider with no table of its own, or `XAI_LIMIT_PHRASE_REGEX`'s own
    disjoint weekly/spend-cap wording for xAI's Grok Build substrate (issue
    #2134), so its transient 429 text is never mistaken for a stand-down —
    sourced by the Script, `review-cycle.sh`, `monitor-cycle.sh` and
    `scripts/publish-dashboard.sh` so none can drift apart — it is parsed
    out of the prose. Either way the event is a `limit-hit`
    carrying the same three fields, because no reader downstream should have
    to know which source produced it: `resume_at`, `class`, and
    `reset_known`:
    - `resume_at` is parsed from an ISO-8601 timestamp in the message if
      present, else from a human-readable weekly reset clause (e.g. "resets
      Jul 17, 4am (Pacific/Auckland)" — the named zone is applied via `TZ`,
      not left in the string for `date -d`, and never combined with `date -u`
      in the same call, which would silently override the named zone), else
      a fallback: now + `limit_cooldown_default` for an ordinary/transient
      match, or now + a much longer cooldown (`LIMIT_LONG_COOLDOWN_HOURS`,
      ~1 day) when the phrasing says "weekly" or "monthly" and no reset time
      could be parsed at all — that fallback is too short for something that
      recurs on a multi-day cadence.
    - `class` is `weekly`, `monthly`, or `other`.
    - `reset_known` is true only when a reset time was actually stated in the
      message. False means `resume_at` is the fallback above — this system's
      own retry interval, carrying no information about the real reset — and
      everything reported to a human must say so rather than presenting it as
      a deadline.

    `reset_known` replaced a `needs_human` flag that claimed the spend-cap
    case "clears only when a human raises the cap". Every limit has two
    exits: the plan's rollover, which needs no one, and a cap increase, which
    needs a human and only if sooner is wanted. Calling the first exit
    nonexistent turned an unknown reset time into an apparent dead end.
    Readers accept the superseded field during a rollout, inverting its sense
    (`lib/limit-detect.sh`'s `limit_reset_known`), so a peer on the previous
    release is not misread as authoritative.

    There is no supported API for querying a subscription plan's remaining
    quota, so this fail-safe detection *is* the quota check, and
    back-pressure (2.2) is the primary spend control. `resume_at` is an upper
    bound to stand down *until*, never a promise the block lasts that long —
    but nothing inside a cycle can shorten it, because 2.1 stands the cycle
    down before any stage runs. Lifting it early is `--clear-limit`'s job and
    only `--clear-limit`'s.
11. <a id="impl-11"></a>**Cleanup.** Always: delete the cycle's workspace, engage the Enabler if
    this cycle should (requirement 35), log the schedule slots this cycle's
    own run overlapped, if any (requirement 11a), write a `cycle-end` event,
    release the lock. Tee each stage's stdout/stderr to
    `state_dir/cycles/<cycle-id>/` for debugging.
11a. <a id="impl-11a"></a>**Overrun-slot skips** (agent-ops#1287). supercronic will not start a job
    while the previous run of that job is still running: it logs the drop
    ("not starting: job is still running since … (…elapsed)") to the
    container log and nothing else records it, so a cycle that runs long
    loses its fleet a whole slot — or, on a fifteen-minute node, several —
    with no event of any kind in `log.jsonl`, reading `RUNNING` in
    `--status` and the dashboard the whole time while delivering nothing.

    Only the cycle holding the lock can ever know this happened: the process
    supercronic would have started for one of these firings never starts at
    all, so nothing else ever gets the chance to log it. At cleanup
    (requirement 11), before the lock releases and only for a cycle that
    actually acquired the lock *and* is the cron-fired original — its chain
    depth is 1 (requirement 67) and none of `--once`, `--dry-run` or
    `--wake-poll` was given — the Script computes which of its own
    schedule's slots fell strictly inside its own run — from its own start
    (`cycle_started_at`) and its own end, its own already-defaulted
    `schedule` block (`cycle_hours`, `cycle_interval_minutes`,
    `excluded_minutes` — the same block `deploy/docker/render-crontab.sh`
    renders into the crontab, requirement 1d), and the node's own true base
    minute (below) — and writes one `cycle-skipped {reason: "overlap",
    slot_ts, held_by: <cycle id>, elapsed_s}` event per slot, oldest first.
    `slot_ts` is the dropped firing's own instant; `elapsed_s` is how long
    this cycle had already been running at that instant — the same quantity
    supercronic's own log line reports, computed independently here since
    this process never reads that log.

    The node's own base minute is read straight out of the rendered crontab
    (`schedule_crontab_base_minute`, `lib/schedule-slots.sh`): the
    agent-cycle.sh line's own minute field is an ascending, comma-separated
    list — `cycle_minute, cycle_minute+cycle_interval_minutes, …` — so its
    lowest entry is `cycle_minute` itself, the node's real base regardless of
    which of that list's minutes this particular cycle happened to fire on.
    It is never re-derived by re-hashing `NODE_NAME` the way that script's
    own `hash_minute()` does, since re-hashing could drift from whatever the
    rendered schedule actually contains; reading the file it wrote cannot.
    That file is the one supercronic itself runs
    (`compose.yaml`'s `scheduler` names it), so the read is exact whether or
    not the render succeeded: the baked crontab a failed render leaves
    standing is a valid, working schedule carrying its own real minute list,
    and it is that schedule supercronic then fires on. Reading it can still
    fail — the file absent, or its `agent-cycle.sh` line's minute field not
    a plain comma-separated integer list (a crontab shaped by a template
    this parser does not recognise) — in which case `schedule_overrun_slots`
    falls back to `cycle_started_at`'s own minute-of-hour, correct only when
    this cycle happens to have fired on the lowest minute its own crontab
    line keeps (agent-ops#1324).

    Holding the lock alone would not make either base minute trustworthy:
    only the cron-fired original *is* supercronic's running job. A chained
    continuation (requirement 67) is spawned detached and disowned and its
    cron-fired parent then exits, ending supercronic's job, so the slots
    inside a chained cycle's run are not dropped at all — they fire, contend
    for the lock, and are already recorded by the contending tick as
    requirement 1's own `reason`-less `cycle-skipped`. Logging them here as
    well would double-count them, and — whenever the crontab read above
    failed — at a fabricated `slot_ts` besides, since a chained cycle starts
    whenever its predecessor happened to finish, an arbitrary minute-of-hour
    the fallback derivation would then take as the node's base. `--once` and
    `--dry-run` runs have the same shape: supercronic's job is untouched by
    them, so their firings land and contend as normal. So does a
    wake-poll-triggered run (requirement 54): `scripts/wake-poll.sh` invokes
    this script with `--wake-poll`, on whatever instant the poll detected a
    change at rather than the cron-fired job's own clock, so it is excluded
    here the same way. Nothing is lost by the narrowing, because every slot
    it declines to name is one the contending tick recorded. A human running
    the script with none of the three flags is the one case left ungated, a
    known bound rather than an oversight: distinguishing it from the cron
    firing needs machinery this does not carry.

    What it names is the slot series running forward from the node's own
    base minute, repeating at `cycle_interval_minutes` within each allowed
    hour. Read from the crontab, that series is the node's whole set, exact
    rather than a bound. Fallen back to the cycle's own firing minute
    instead, it is the node's whole series only when that firing minute was
    the lowest kept minute of its hour; a cycle that fired on a later one
    contributes no slot at any earlier minute-of-hour of any subsequent
    hour, because one firing minute does not identify which of the hour's
    kept minutes is the base (`:55` at a fifteen-minute interval is equally
    consistent with a base of 10, 25, 40 or 55). That fallback error is
    one-sided: every event written still names a firing that really was
    dropped, and the count is a lower bound on the firings lost, never an
    overstatement (agent-ops#1324) (`lib/schedule-slots.sh`'s
    `schedule_overrun_slots` and `schedule_crontab_base_minute`,
    `test/schedule-slots.test.sh`).

    These are ordinary `cycle-skipped` events, sharing their name with
    requirement 1's own lock-contention case, but unlike that case they
    never call `suppress_node_state_transitions` (`docs/reference/flow-schema.md`):
    the seconds they describe already belong to this cycle's own node-state
    timeline, finalized immediately before them at cleanup, not seconds of
    their own to account for separately.

    Two readers surface the count without this repository changing either:
    `scripts/publish-dashboard.sh`'s `noop_ticks` gains an `overlap` field —
    a flat count of the window's own `reason: "overlap"` events, never
    folded into `total`, since (unlike the stand-down/lock-held pair
    `noop_ticks` already counted) the cycle that logs one kept its own row
    in `cycles[]` by running real stages, and this is additional
    information about that row rather than a tick held out of the list
    (`docs/spec/dashboard/README.md`). `--status` gains an `overrun: N firing(s)
    overrun in the last 24h` line, this node's own count
    (`overlap_status_report`, `lib/manage.sh`) — `check-nodes.sh` (external
    to this repository; not committed here) already prints `--status` per
    node and so inherits it for free, on the same terms requirement 2.8's
    `stages:` section already does. The count reads the log through the
    tolerant event stream requirement 2.1's reduction reads (`union_events`)
    and skips a line that does not parse; a log not yet written counts zero, and
    a read that fails outright prints `overrun:  unreadable — this node's log
    could not be read` and reports a `guard-degraded` warning on stderr
    rather than a zero nobody counted.
12. <a id="impl-12"></a>**Flags.** `--dry-run` (run through step 5 then stop: prints the work
    order, launches no Implementer), `--once` (one verbose cycle in the
    foreground), `--repo <slug>` (restrict selection, for testing),
    `-h`/`--help` (print the usage text and exit), plus the
    switch's `--disable [<reason>] [--for <duration>] [--until <timestamp>]`,
    `--enable` and `--status` (requirement 2.3), which manage the switch and
    run no cycle.

    The usage text describes every flag the Script accepts, `--help`
    included: a flag the parser honours but the usage omits is one an
    operator can only find by reading the source.

    `--clear-limit [<provider>] [<reason>]` lifts a usage-limit stand-down
    (2.1) and runs no cycle either. With no provider, every provider's own
    stand-down lifts, as before issue #2135; naming one (matched against
    `PROVIDER_SUBSTRATE`'s configured keys, plus the always-valid
    `anthropic`) lifts only that provider's, leaving a different provider's
    own freeze untouched. Which of up to two bare tokens is the provider and
    which the reason is resolved against that same set, after
    `providers_load`: one token is the provider only if it names one and the
    reason otherwise, exactly as before the issue; two tokens are provider
    then reason, and a first token naming no configured provider is rejected
    (exit 64) rather than scoped to a provider that does not exist — there is
    no second reading of two bare tokens, and a silent mis-scope would log a
    `limit-cleared` nothing reads. It is deliberately not `--enable`: the switch and
    the stand-down are separate states with separate causes, and one command
    for both would let an operator clearing a spend cap silently re-enable a
    pipeline another agent had disabled to edit these files. It clears both
    carriers for the named scope, reports what it lifted and what it could
    not, and warns loudly on a failed flag delete — a flag left set keeps
    every node down after the operator believes they have resumed; naming a
    provider deletes the flag only when the flag's own current record already
    names that provider, leaving a different or wildcard record untouched.
    A wildcard record left that way is reported rather than passed over,
    because requirement 2.1's "a record without a provider applies to every
    provider" rule means it still holds the named provider down: the command
    warns that the stand-down was *not* fully lifted and names the bare
    `--clear-limit` that can delete it, the flag having no way to express
    "every provider but this one". The reason is
    optional, unlike `--disable`'s: a stand-down being lifted is
    self-explanatory in a way one being imposed is not.

    `--kill-merge-autonomy [<reason>]` and `--restore-merge-autonomy`
    (requirement 2.3b) manage the D18 kill switch and run no cycle either. Like
    `--clear-limit` this is deliberately not `--disable`/`--enable`: killing
    merge autonomy stops nothing else — cycles keep running normally, only
    approval and landing are forced back to `human` — so folding it into the
    switch would make an operator editing these files also, incidentally, force
    every repo's landing decisions onto a human, or vice versa. The reason is
    required on `--kill-merge-autonomy`, the same terms as `--disable`'s: the
    next person to wonder why every repo is stuck at `human` is entitled to
    one. Neither takes `--this-node`: the kill switch has no node-scoped form,
    since a node-scoped merge-autonomy override would contradict the
    fleet-wide identity a single Approver App holds.
13. <a id="impl-13"></a>The Script must pass `shellcheck` and must set its own `PATH` explicitly
    (cron's environment is minimal), covering `claude`, `gh`, `git`, `jq`.
    When provisioning a host, prove that a cron-style invocation can resolve
    `claude` by running it from a minimal environment (for example with a
    sanitized `PATH` and `HOME`) before relying on scheduled runs.
67. <a id="impl-67"></a>**Finish-then-continue** (issue #248): a cycle that wins a claim and
    launches the Implementer may, once it has fully ended, launch another
    cycle immediately rather than leave the next one to the next cron
    firing — `lib/chain.sh`. Two conditions, both cheap, both judged from
    what the cycle already gathered ahead of the Co-Ordinator
    (`ordered_repos_json`, ready before requirement 3b's fingerprint is
    even taken):
    - **Sources remain.** At least one configured repository's `.sources` —
      already narrowed by back-pressure (2.2a) if it was tripped — is
      non-empty. This counts enabled source *categories*, not items, and is
      near-unconditional in practice: back-pressure narrows `.sources` to
      the four finish-work sources rather than to empty, so a repo
      configuring any of `review-feedback`/`merge-conflicts`/`dequeued`/
      `abandoned-drafts` keeps the count non-zero however back-pressured the
      fleet is. It is not a prediction that work remains — the chained
      cycle's own Co-Ordinator and gather decide that, and at full price,
      since the cycle just finished changed the no-op fingerprint (3b) with
      its own PR. In effect the cap below is the only gate that fires after
      a productive cycle, and its cost is a deliberate trade — see the
      finish-then-continue design decision.
    - **The lineage has room.** This cycle's own place in an unbroken chain
      of immediate continuations, 1 for the cron-fired original, is still
      under `max_chained_cycles` (default 3). A chained cycle inherits its
      place plus one via `AGENT_CYCLE_CHAIN_COUNT`; `max_chained_cycles: 1`
      disables chaining outright.

    Never chains on `--once` (a human or a test asked for exactly one
    cycle) or past any stand-down before the claim section, the switch, or
    a cycle that selected nothing — all of those end before a claim is ever
    attempted, so `chain_eligible` is never true for them. One stand-down
    *inside* the claim section does chain, under the same two conditions
    above: the `raced` stand-down (17a), where every attempted claim was
    lost to a peer. That cycle's Co-Ordinator engagement bought the
    knowledge that the fleet is busy, not that it is done — and the
    winners' claims, invisible when this cycle gathered, are exactly what
    the chained cycle's fresh gather and requirement 3q's filters see, so
    the continuation is routed to the next-best item instead of the same
    fight. The other three causes never chain: an `unreachable` or
    `pre-claimed` stand-down against a fresh cycle buys a second engagement
    into the same outage, or the same selection defect, and the same
    empty-handed ending; an `untraceable` stand-down (17f, 17h) is the
    Script's own construction-time check refusing to hand a candidate on,
    which no peer's claim or absence had any part in, so a fresh cycle
    would spend the same chain budget re-composing the same broken work
    order rather than routing around anyone.
    Nor does it chain over an untrapped crash or a signal: the gate
    is `chain_eligible` *and* this cycle's own `exit_code == 0`, checked in
    `cleanup` (11) after everything else there has already run — the lock
    released, the Enabler engaged, `cycle-end` logged, state pushed. Every
    *ordinary* ending after a won claim (complete, blocked, void, a handled
    stage failure) exits 0 like a stand-down does, and does still chain: a
    failed or blocked item must not stall the fleet from picking up a
    different one sooner. The chained cycle is a genuinely new process —
    its own cycle id, its own lock acquisition, its own full cleanup —
    launched with the original argv (`ORIGINAL_ARGV`, captured before flag
    parsing consumes it), detached (backgrounded, `disown`ed, stdin from
    `/dev/null`, stdout/stderr appended to the same `cron.log` a cron
    firing already writes to) so the parent never waits on it and its life
    does not depend on the parent's — and launched with the default
    dispositions for `TERM`, `INT` and `HUP` restored, because `cleanup`
    ignores all three before it spawns (9c) and an *ignored* signal is
    inherited across both fork and exec into a shell that can never take it
    back. Without that reset a chained cycle would run deaf to every signal
    9c's handler exists to catch, and requirement 1's stale-lock takeover
    would reach it only through the `KILL` that follows its ignored `TERM`
    — no `attempt-failed`, no `cycle-end`, no claim released.
68. <a id="impl-68"></a>**A pending image roll overrides the chain, and widens the gap at every
    clean cycle-end, not only a chaining one** (agent-ops#1096, widened by
    agent-ops#1103). This covers two separable jobs, not one: cancelling a
    chain this cycle would otherwise take, and widening the gap a poll needs
    from whatever instant this cycle's own lock release happens to leave to
    one the five-minute poll is guaranteed to land in. A node running long or
    chained cycles never leaves `deploy/docker/watchtower-pre-update.sh` such
    a gap — every individual deferral stays correctly bounded by that
    pipeline's `lock_stale_after`, and the node still never rolls, because the
    next chained cycle's own claim reacquires the lock before the lock-free
    instant a poll would need — but the identical starvation reaches a node
    that is merely busy and never chains at all: chaining disabled
    (`max_chained_cycles: 1`), a chain that has exhausted `max_chained_cycles`,
    or any other clean cycle-end, since none of those leave more than the
    natural, possibly sub-second gap between this cycle's lock release and
    the next cron firing either. So immediately before the chain decision,
    inside the same `cleanup` (11), every cycle that ended cleanly
    (`exit_code == 0`) and was neither a `--once` nor a `--dry-run` run (a
    human or a test asking for exactly one cycle, real or dry, must not arm
    an override on the node it ran on) asks: is the image it is running
    behind the registry's newest
    (`lib/image-drift.sh`'s `image_drift_status`, read back through the
    identical cache the requirement-2.5 heartbeat push just above it already
    refreshed — no second registry round trip, no second signal)? If so,
    `chain_write_roll_pending` writes `$state_dir/roll-pending.json`
    (`{"until": <ISO8601>}`, `schedule.cycle_interval_minutes` from now,
    requirement 2.5's own exclusion list) regardless of `chain_eligible` —
    and, separately, `chain_image_behind` (`lib/chain.sh`) flips
    `chain_eligible` back to false wherever it was true — overriding, never
    granting, and a no-op on a cycle that was never going to chain anyway.
    `deploy/docker/watchtower-pre-update.sh` reads that marker back and
    honours it as an unconditional allow against `lock.json` alone —
    overriding only that pipeline's own ordinary in-flight-cycle deferral,
    never `review-lock.json`'s (agent-ops#1102: `review-cycle.sh` never wrote
    the marker and never decided to yield anything, so a project review
    beginning just after a yielding implementation cycle must keep deferring
    on its own ordinary judgement regardless) — until `until`: wide enough
    that the next poll is guaranteed to land inside it, which the true gap a
    declined chain (or a cycle with no chain to decline) leaves (the instant
    between this cycle's lock release and the next cron-fired cycle's own
    claim) is not.

    Because `until` is a fixed clock offset from this cycle's own end, not
    "the next cycle's own start", a cycle that reacquires `lock.json` before
    `until` passes would otherwise run its own stages underneath a marker
    that still authorises overriding that very lock (agent-ops#1102). So the
    other half of this mechanism runs at the *top* of every cycle, immediately
    after `acquire_lock`: if `$state_dir/roll-pending.json` exists, the same
    `image_drift_status` round trip (the identical TTL-backed cache, so this
    is a network call only when that cache was already due to refresh) is
    read again, and `chain_clear_landed_roll_pending` (`lib/chain.sh`) removes
    the marker unless the verdict still reads "behind". Re-acquiring the lock
    is itself the proof the gap the marker described has ended; once the
    verdict is no longer "behind" the marker has either already done its job
    (the roll landed in the gap) or was never earned by this node's own
    current image, and leaving it live either way would let a marker written
    for one roll authorise watchtower to destroy *this* cycle's own container
    for whatever publishes next. A verdict still reading "behind" leaves the
    marker untouched, and the cycle that just reacquired `lock.json` asks one
    further question before running its own stages under it (agent-ops#1102's
    own option 2): is watchtower actually invoking the pre-update hook and
    being turned away right now? `chain_updater_should_standdown`
    (`lib/chain.sh`) answers this off `lib/updater-health.sh`'s own
    `updater_status` verdict, read against the same `updater-ledger`
    directory the state-sync heartbeat already reads (no second signal) —
    "deferring", or "stuck" with `reason:"defer"`, both say watchtower is
    there and being refused; "rolled", a bare "stuck"/`reason:"allow"` (the
    roll is failing for reasons of its own, #1099's `Conflict` observation),
    and `null` (no live ledger evidence at all) all say idling fixes nothing,
    so the cycle runs normally. When it does say so, the cycle idles instead
    of running: it logs a `stand-down` naming `cause: "roll-pending"` and the
    marker's own `until`, settles into `externally-blocked`/`roll-pending`
    (`set_node_state_terminal`, `docs/reference/flow-schema.md`'s closed cause
    vocabulary), and exits 0 without ever reaching the Co-Ordinator — `chain_
    eligible` plays no part, since it is never raised this early in the
    cycle. This is capped at one stand-down per pending marker (`chain_roll_
    standdown_available`/`chain_roll_standdown_record`, `$state_dir/roll-
    standdown.json`): even a verdict that stays wrong every cycle cannot idle
    a node indefinitely, so a second cycle under the same still-live,
    still-"behind" marker logs a `roll-standdown-capped` event naming the
    marker and the spent count instead, and runs normally. The counter is
    cleared alongside the marker itself, by the same `chain_clear_landed_
    roll_pending` call above, once the verdict stops reading "behind" — so a
    later, genuinely new pending roll earns its own fresh stand-down
    allowance.

    The result is the bound the hook's own header now states: one cycle's
    length for a node that is merely busy, and `lock_stale_after` only for
    one that is actually wedged and so never reaches this check at all.
17d. <a id="impl-17d"></a>**Race-loss observability**: how many candidates a cycle lost to a peer
    genuinely holding the item (17a's `cause: "held"`, as opposed to
    `"unreachable"`) before it won its own claim, or — on the cycle that
    exhausts every candidate — before it stood down. Carried as
    `race_losses` on the `selection` event (only when it is greater than
    zero — 17a) and on that stand-down's event. Candidates skipped as
    pre-claimed (17a's `claim-skipped`) are deliberately *not* race
    losses and never inflate this count: a loss knowable from the cycle's
    own gather is a selection defect wearing contention's clothes, and
    folding it in would make the fleet look busier against itself than it
    is — the miscounting that let a day of one Co-Ordinator re-proposing
    four already-claimed issues read as healthy racing.
    A cycle recovering a race (winning after one or more losses) is
    healthy contention, not a fault: `scripts/publish-dashboard.sh` and
    `dashboard/index.html` surface it as an informational "recovered race
    ×N" badge, on the cycle history, the live-cycle panel and the fleet
    cards, wherever that cycle's `title`/`source` already render (never a
    warning colour). A cycle that lost *every* candidate recovered nothing
    and never carries that badge; it is marked instead beside its outcome,
    where the plain "Stood down" verdict cannot say by itself whether the
    fleet's own contention or a GitHub outage produced it — the same
    informational colour, and DASHBOARD-SPEC's `raced` / `standdown_cause`
    is the shape both readings come from. Faster cadence and
    finish-then-continue (39) both
    raise how often nodes contend for the same item, which is why this
    became worth watching rather than left to a `claim-lost` grep.
