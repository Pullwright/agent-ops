## Requirements

### The Script — requirements, continued (part 7 of 10; 3w–4h: **Verdict quality is a rate, and every verdict pays for its …)

3w. **Verdict quality is a rate, and every verdict pays for its own
   denominator (issue #319).** Requirement 3t made a confabulated verdict
   detectable and requirement 3v made it recoverable, and between them they
   answer "did it happen on this cycle, and did the fleet survive it". Neither
   can answer the question the detection exists to serve: *how often does this
   happen, and does that rate justify changing `coordinator_model`?* A rate
   needs both terms, and only the rejections were ever counted.

   **The unit is the verdict, not the cycle.** Requirement 15's per-repository
   split makes a cycle produce one verdict per configured repository, each an
   independent answer from the model about its own repository alone.
   Requirement 3v's `corroboration` event is the record a rate is computed
   from, carrying `attempt` (always `1` — since issue #587 there is no retry
   for it to distinguish a second answer from), `verdict` and the Script's own
   `eligible_total`. A cycle writes at most one, after every engagement has
   answered and only when the merged candidate list came back empty: it
   corroborates, together, exactly those repositories that returned
   `"selected": false`, and its `eligible_total` is the Script's count across
   those repositories' own bands, not the fleet's.

   What they did not carry, and now do, is **`coordinator_model`** — the model
   id the stage was *invoked* with, not a key of its envelope's `modelUsage`
   map. The invocation id is what an operator sets, what requirement 33a's
   `stage-end` metering already records for the same run, and what an
   installation changing this setting on one node needs the two rates
   attributed to; `modelUsage` names whatever the session actually reached
   for, subagents included, so keying on it would split one setting across
   several labels and disagree with every other record of the same run. This
   is the same choice, for the same reason, that `lib/metering.sh` documents.
   Every one of a cycle's per-repository engagements runs under the same id,
   so the cycle's own corroboration verdict is attributed unambiguously.

   A third `verdict` value, `accepted-by-selection`, appears in history and is
   read by the dashboard's aggregate but is written by no current code path:
   it recorded the retry issue #587 removed getting it right on a second
   engagement, and carried `eligible_total` for the same reason the other two
   do — a denominator counting only the verdicts still phrased as
   `none-selected` would credit that recovery to nobody. A reader computing a
   rate over history must still accept it.

   **`none-selected` carries `eligible_total` and `coordinator_model` on every
   branch**, which matters for the cycles that log no `corroboration` at all:
   the gate only corroborates a verdict when the Script found something
   to corroborate it against, so a cycle whose bands were genuinely empty has
   only its `none-selected` to say so. Without the figure there, "nothing was
   eligible" — a clean verdict that is no part of any rate — cannot be told
   from an event written before any of this existed.

   `eligible_total` is the Script's count across **every** pre-fetched band
   from requirement 3x onward, where it used to be the tech-debt band alone.
   That is a change of denominator, not of meaning — it was always "what the
   Script handed over that this verdict owes an account of" — but a reader
   comparing a figure from before and after should expect it to step up, and
   the rejection rate computed from it to become a rate over verdicts about
   the whole input rather than about one band of it.

   Neither field changes what the fingerprint covers or how requirements 3t
   and 3v decide: a rejected verdict still omits `fingerprint` entirely, an
   accepted one still carries it, and the fallback still fires on exactly the
   same condition. They are a record of the decision, not an input to it.

   A reader that meets a verdict from before this requirement may fall back to
   the model on that cycle's own coordinator `stage-end` — the same invocation
   id, so the fallback never disagrees with the field — which is what lets the
   dashboard's aggregate (`docs/spec/dashboard/README.md`, the Co-Ordinator's own row
   of `counts.actor_scorecards`) populate from history already on disk rather
   than only from cycles run after this shipped. What it must **not** do is
   count a cycle's `corroboration` and its `none-selected` as two verdicts:
   requirement 3v writes both for the same answer whenever a rejection reaches
   the fallback path with nothing to pick, and both for a clean stand-down, so
   the two records are read per cycle and the `corroboration` wins where there
   is one.
3x. **Verdict corroboration, generalised to every pre-fetched band (issue
   #322).** Requirement 3t machine-checks a `none-selected` verdict against
   exactly one band. A verdict claiming "no candidates" over a non-empty
   `issues` array — or `findings`, `review_feedback`, `abandoned_drafts`,
   `merge_conflicts`, `human_visibility` — went entirely
   un-corroborated, which is the same failure shape as issue #310 one band
   over: requirement 3j's pre-fetch closed the "model declines to read the
   source live" hole for `issues`, and nothing closed the "model misdescribes
   what it was handed" one. Nothing would even have *detected* the issues band
   being confabulated away; the fleet would have stood down cycle after cycle
   with a well-formed reason, exactly as it did on 2026-08-11.

   The principle, stated once so it does not have to be rediscovered a third
   time: **every load-bearing negative the model asserts must be corroborated
   against the Script's own count of what it handed over.**

   **The eligible set is one set, computed once** (`coordinator_eligible_items`
   → `eligible_items_json`), `{repo, item, source}` per entry, with `source`
   the same token the repo's `sources` list, a `needs_refinement` entry and
   `refinement_policy` all use. It is read at the same point requirement 3t's
   tech-debt-only predecessor was — after requirement 2.2a's back-pressure
   decision — and each band is gated on the repo's own **`sources` list**
   rather than merely on its array being non-empty. The list is the authority
   because back-pressure narrows it without emptying `findings`
   or `human_visibility`, and a verdict owes no account of
   a band the cycle forbade it to select from. Three bands need more than
   "every entry in the array", and each for a reason already written down
   elsewhere:

   - `issues` is one source at four ranks (requirement 15e), so an issue is
     eligible only under its own `Priority` band's token: a repo configured
     `issues:high` alone was never offered its Medium issues.
   - `issues` also still carries blocked entries after requirement 3u's own
     pass, which deliberately keeps the ones whose thread has moved so
     requirement 18a's live re-read can happen. A blocked issue is not
     selectable until that re-read unblocks it, so it is dropped here — on
     exactly `exclude_blocked_or_void_items`' matching rule, blank `repo`
     included, so the two passes cannot disagree about what was offered.
   - `merge_conflicts` carries the one entry shape `prompts/coordinator.md`
     tells the Co-Ordinator to skip in silence: a Dependabot PR this system
     has not yet asked to rebase is "not a candidate of any kind" (requirement
     3s). Its *superseded* sibling is the opposite case — the prompt requires
     that one in `voided` — so it stays eligible and owes an account.

   Every other band is exactly "an entry's presence in this array is the
   candidate test", which is the prompt's own words for all six of them.

   **The rule is one rule** (`unaccounted_items`, requirement 3t's
   `tech_debt_unaccounted_items` generalised and renamed): an eligible entry is
   accounted for by a `needs_refinement` report the Script *recorded* under
   that entry's own `source`, or by a `voided` entry it disposed of, and by
   nothing else; an entry whose source's `refinement_policy` is `"required"`
   is exempt (requirement 39a (The Refiner)), per source rather than per call. Requirement
   3t's "count what was recorded, never what was claimed" property is
   preserved band by band rather than re-argued per band — the corroboration
   is fed `log_needs_refinement_items`' and `log_voided_items`' own
   collections, as before. Deliberately *not* six copies of one rule: the only
   thing that varies by band is which items are eligible, and that is the
   eligible set's job.

   **So is an eligible entry the fit ladder actually trimmed this cycle**
   (requirement 4i's own exemption, agent-ops#683), on the same "per source"
   shape but keyed on the individual entry rather than the whole band:
   requirement 34e's fourth refusal already discards any `needs_refinement`
   report against one, so demanding an account of it here would demand a
   report the Script's own other rule throws away — the identical
   self-defeating loop the `"required"` exemption above exists to avoid, for a
   different reason. `coordinator_fit_trimmed_items` (`lib/coordinator-input.sh`)
   is the exemption set, matched against the eligible set on the same `{repo,
   item, source}` key `unaccounted_items` already keys everything else on.
   This is what stops the refusal from simply relocating the mass-flag into a
   corroboration-rejected retry loop over the same trimmed input: without it, a
   Co-Ordinator that (correctly) declines to guess at a trimmed candidate's
   acceptance criteria would find its `"selected": false` rejected for leaving
   that candidate unaccounted, retried against byte-identical input, and
   rejected again — the fallback selection (below) then handing an Implementer
   a candidate the Co-Ordinator was never given enough of the thread to brief.
   The count of eligible entries the exemption actually covers is logged
   separately, once per cycle and whatever the Co-Ordinator went on to decide,
   as `coordinator-input-fit-unassessable` (carrying `unassessable_total` and
   the rung) — `coordinator_unassessable_items` — so a human reading the cycle
   log can still see how much of a cycle's backlog went unassessed even though
   no per-item report was asked for. A cycle the fit trimmed nothing in has
   nothing to say here and says nothing: the event is written only where the
   count is above zero, so the ordinary cycle carries no such record.

   **Rejections are tagged with the band.** The `warning` and the rejected
   `corroboration` both carry a `bands` object (`{"issues": 3, "tech-debt":
   1}`), every `unaccounted` entry carries its own `source`, and the
   `none-selected` written when a rejection reaches the fallback with nothing
   to pick carries `bands` too. There is still exactly **one**
   `corroboration` event per verdict, never one per band: requirement 3w's
   rate has the verdict as its unit, and a per-band event would inflate its
   denominator by however many bands a cycle happened to have work in. The
   `td_verdict_rejected` field keeps its now-inaccurate name — it is what
   `scripts/publish-dashboard.sh` and every such event already in the retained
   log key on, and renaming it would silently zero the rejection count for the
   history the dashboard can still see.

   **One prompt change is load-bearing, and it is the reason `issues` can be
   corroborated at all.** Every other pre-fetched band's decline routes are
   already exhaustive: report it, void it, or select it. The `issues` band had
   a third — requirement 16's judgement half, "a question or discussion rather
   than actionable work", which `scripts/gather-issues.sh` cannot filter and
   requirement 16a explicitly told the Co-Ordinator *not* to report. Left as
   it was, either the issues band stays un-corroborated (the hole this
   requirement exists to close) or every discussion issue is flagged
   unaccounted forever, rejecting every verdict and driving requirement 3v's
   fallback to hand an Implementer a discussion thread as work. So requirement
   16a's exclusion list loses that one case: a question or discussion issue is
   reported in `needs_refinement` like any other item nobody has yet said what
   "done" would mean for. It is not company for the other four on that list —
   claimed, blocked, void and assigned are all cases where something else
   already recorded the item, and nothing records a question. The cost is one
   `needs-refinement` label and one Enabler engagement per discussion issue,
   once (requirement 34e refuses a re-report of an already-blocked item); the
   alternative was a band nobody could check.

3y. **Refiner-only pre-fetch: `project-review` and `implementation-plan`.**
   These two sources have no array in `ordered_repos_json` and gain none: the
   Co-Ordinator reads the repository's latest review folder — its own
   `report_directory_resolved` where present (requirement 3k), the path
   `report_directory_most_recent` already resolved deterministically, read
   with no walk of its own; the hand-rolled fallback walk over `report_directory`
   (requirement 3k; `reviews/project-review-YYYY-MM-DD/` where the repository
   configures neither `repository_review.repos[]`'s nor
   `repository_review.defaults`' own `report_directory`) only where
   `report_directory_resolved` is absent — and the repo's plan document live
   while it evaluates each candidate (requirement 15, `prompts/coordinator.md`),
   and that live read is the authority for selection: it reads a
   Script-resolved field rather than deriving the path itself, and it still
   reads the folder's own contents fresh every cycle rather than trusting a
   candidate set computed ahead of it. What requirement 39a (The Refiner)'s candidate set needs is a
   *different* thing — a structured array it can name an item out of — so the
   Script builds one for the Refiner alone: `refiner_repos_json`, a copy of
   `ordered_repos_json` in which a repo entry may additionally carry
   `project_review` and `implementation_plan`. Nothing else reads that copy,
   and `ordered_repos_json` itself is passed on untouched, so the Co-Ordinator
   cannot be handed a stale array in place of its own live read.

   The copy is taken from the snapshot `compute_band_eligibility` sets aside
   (`refiner_prefetch_source_json`, `lib/eligibility.sh`) before its own
   decision-pending withholding runs, never from `ordered_repos_json` as the
   Co-Ordinator finally sees it — the same reason requirement 35e's
   `live_pr_refs_json`/`live_td_refs_json` snapshots are taken before the
   blocked/void subtraction. An item a pending `decide-tactical` decision
   withholds from Co-Ordinator ranking (requirement 36d) must stay a full
   Refiner candidate, because a Refiner engagement writing the unmarked
   `item-refined` that supersedes the decision in `decisions_map` is the only
   thing that ever frees it: deriving this copy from the post-withholding
   aggregate would withhold the item from both stages at once, leaving no
   actor able to supersede the decision and so no cycle in which the item
   could ever become selectable again. Every *other* subtraction the band
   pass makes — requirements 3t/3u's blocked and void exclusions — is already
   applied by the time the snapshot is taken, so a blocked or void entry is
   absent from the Refiner's bands exactly as it is from the Co-Ordinator's.

   Each array is filled by its own gatherer — `scripts/gather-project-review.sh`
   and `scripts/gather-implementation-plan.sh` (Components) — called for a repo
   only where the read can be acted on: `refiner_model` is set, since
   requirement 39 (The Refiner)'s own first guard returns without launching anything when it
   is not, and every read paid for under an empty one buys an array no
   engagement can ever spend; the repo's own `sources` lists that source
   **and** its `refinement_policy` (requirement 39a (The Refiner)) is not `exempt`, since an
   exempt source's candidates would be discarded unread; and for
   `implementation-plan`, only where `implementation_plan_path` is configured
   (requirement 3k), the same value the startup guard already requires. A repo
   meeting neither condition costs no API call, the rule requirement 3t's own
   pre-fetch follows for its `sources` gate.

   Both gatherers are deliberately **narrower** than requirement 3t's: they
   deduplicate against nothing, check for no existing pull request, and apply
   none of requirement 15's exclusions, because none of that is theirs to
   decide — the Co-Ordinator's live read still makes every selection judgement,
   and requirement 39a (The Refiner)'s own clauses 2–4 (policy, already-refined, blocked/
   void/claimed) reduce the candidate set. What they must carry is what the
   Refiner cannot write a specification without: a recommendation's own detail
   section and its ready-to-run improvement prompt, a plan task's whole
   task-list line.

   **A prompt is carried whole or not at all.** An improvement prompt lives in
   a fenced block, and may legitimately contain a fenced block of its own — the
   cost-policy block the project-review skill requires in every prompt is
   itself presented as one, and a prompt that quotes a patch or a command
   transcript is the same shape. The review gatherer therefore takes everything
   between the **first** and the **last** fence line of a prompt's section,
   treating any fence line between them as content; it never stops at the first
   closing fence, which would hand the Refiner a prompt silently truncated at
   its nested block and no way to know a specification was written from half of
   one. For the two-fence section the skill's own template produces the two
   rules are identical, and for any section whose fences balance this one
   strictly adds; a section with an odd fence count is malformed under either
   reading, and this one answers it by keeping the prompt's own opening.

   Each item's `ref` is the one the rest of the pipeline already knows it by,
   so a block filed against a refined item resolves through the readers that
   already exist: `review-YYYY-MM-DD-R-NN` for a recommendation
   (`WORK_GONE_REVIEW_RE`, requirement 34i's `scripts/gather-review-status.sh`)
   and the plan task's own id for a task (`WORK_GONE_PLAN_RE`,
   `scripts/gather-plan-status.sh`). Minting a ref of any other shape would
   produce items nothing downstream could ever clear.

3b. **No-op short-circuit (cost control).** The Co-Ordinator costs the same to
   say "nothing to do" as it does to select work. On a quiet week that is 24
   identical answers a day, every one of them paid for. Before launching it,
   compute a **fingerprint** of every input its verdict depends on; if the most
   recent `none-selected` event carries the same fingerprint and is younger
   than `none_selected_recheck_hours`, log `stand-down` with the reason and the
   fingerprint, and exit without launching anything.

   The claim this makes is deliberately narrow, and stating it precisely is
   what keeps it safe: *every input is byte-identical to when it last declined,
   therefore its verdict would be the same*. It is **not** the claim "there is
   no work" — nobody but the Co-Ordinator can know that, and avoiding asking it
   is the entire point. The rule never has to be right about the repository,
   only about whether anything moved.

   - **The fingerprint must cover every input, or the pipeline silently
     stalls.** A source left out is a source that can gain work without waking
     the pipeline, and the symptom is nothing at all: no error, no failed
     stage, just tidy `stand-down` events and no PRs. Map each source to a
     signal and keep the map in the shared library: `head_sha` covers every
     file-backed source at once (implementation-plan, project-review, the
     code); the pre-fetched `findings` cover security and code-quality
     verbatim; the pre-fetched `review_feedback`, `merge_conflicts`,
     `dequeued`, `landing_refusals` and `abandoned_drafts` arrays cover those
     five sources verbatim, and `tech_debt`
     (requirement 3t) covers the tech-debt band the same way (a source
     exempted from the map is one nobody re-checks when the map changes;
     `tech_debt`'s coverage is what lets requirement 3t's machine
     corroboration compare the Co-Ordinator's verdict against the Script's
     own eligible count without a stale fingerprint standing in the way) —
     the latter two matter especially
     among the finishing sources, because each turns on a transition the
     open-PR digest does not carry: `abandoned_drafts` gains an entry the cycle a
     draft goes stale (the mere passage of time), and `merge_conflicts` the cycle a
     ready PR's `mergeable` resolves to `CONFLICTING` after its base moved. Hashing
     those arrays is the *only* thing that busts the fingerprint at those
     transitions, since the open-PR digest below moves for a new or updated PR but
     not for time passing or a base advancing elsewhere; the pre-fetched
     `issues` array of requirement 3j verbatim, *and* an issues digest
     (number, `updated_at`, labels,
     assignee, `Priority` — labels and assignee because requirement 16.4
     excludes on them, `Priority` because requirement 15e *ranks* on it and a
     re-prioritised issue is a different verdict from the same set of issues.
     `updated_at` is not a substitute for digesting the field itself: it is
     GitHub's to move or not on an issue-field edit, and a ranking signal whose
     only coverage is a timestamp somebody else owns is the "covered by
     something else" trap this list exists to close. The verbatim array is the
     only cover for an *edit* to an existing comment — which moves no digest
     field, while the Co-Ordinator reads the thread from the array — and the
     digest stays alongside because it is sampled independently, so a cycle
     whose issues fetch degraded to `[]` still gets its fingerprint busted by
     the digest when a real issue moves); a
     workflows digest for failed-runs; an open-PR digest, because a PR is a
     claim (16.3) and closing one creates a candidate while touching no commit,
     issue or alert; the `claimed` array of requirement 3o, projected to
     `repo|item` like `blocked`/`void` below, for the same class of gap
     `abandoned_drafts` and `merge_conflicts` close — a peer's claim, or that
     claim ageing past `claim_ttl_hours`, moves no commit, issue, alert, or
     (until its PR exists) the open-PR digest above; the `blocked`/`void`
     extracts projected to `repo|item`, so
     a human's hand-appended `unblocked` takes effect; the `refinements` map of
     requirement 3h projected to `repo|item|ts`, listed in its own right rather
     than left to the `unblocked` that always accompanies it, because "covered
     by something else" is how a source ends up covered by nothing; the Enabler's eligible
     set projected to `repo|item|reason` together with its config and prompt
     hash (requirement 35b); and — the three everyone
     forgets — the selection config, a hash of `prompts/coordinator.md`
     **and any `prompt_overrides.coordinator` files configured for it**
     (requirement 4a), and the rendered repo/work-sources table itself
     (requirement 4b), hashed verbatim because it is not the same claim as
     `repos[].sources`: back-pressure (requirement 2.2a) can narrow that array
     to a repo's finishing sources for one cycle while the table keeps
     showing that repo's full configured priority regardless, so only the
     table's own bytes cover a config edit to a non-finishing source landing
     during such a cycle.
     Without those, editing the selection rules — in the shipped
     prompt, in an installation's own extension, or in `config.json`'s
     `repos` array — does nothing until an unrelated commit lands, and you
     spend the afternoon debugging an edit that was correct.
   - **Digest what the verdict reads, not what merely changed.** Requirement 15
     makes a failed run a candidate when a workflow's *most recent run is a
     failure* — a fact about the conclusion. Digesting run ids instead makes
     every scheduled workflow bust the fingerprint on its own cadence.
     `poetic` schedules `sync-framework.yml` at `0 * * * *`: hourly, the same
     cadence as this pipeline. That one workflow reduced the entire
     short-circuit to a no-op that still paid for a Co-Ordinator every hour —
     installed, logged, green, and saving nothing. Digest conclusions, and drop
     runs still in flight (a run in progress is not yet a failure, and sampling
     one mid-flight registers two changes for a workflow that ends where it
     began).
   - **A sample that failed is not a sample.** The signals this rule needs
     beyond the Co-Ordinator's own runtime input are proxies for reads *it*
     performs, so they must be gathered by a deterministic script
     (`scripts/gather-source-state.sh`) that marks `ok: false` on any API
     error. An unfingerprintable cycle simply runs the Co-Ordinator. This is
     the one place the `[]`-on-failure convention of requirement 3a must not be
     copied: `gather-findings.sh` may degrade, because its output *is* the
     Co-Ordinator's input and a fingerprint recording "no findings" faithfully
     records what the model saw. A failing issues API degrading to `[]` would
     instead be a stable lie — it would match the next equally-failed sample
     and skip, and go on skipping for as long as the outage lasted.
   - **A sample read for absence must be complete.** The open-issue and
     open-PR listings are paged to completion (`api_json_paged`,
     `scripts/gather-source-state.sh`), because requirement 34i reads a
     blocked item's *absence* from them as "the work is closed": a
     single-page sample on a repository holding more open issues than one
     page carries reports every issue past the page as closed, and the
     work-gone sweep then clears real blocks out from under real work —
     which is what falsely unblocked #874 on 2026-09-04 and handed the
     phantom-refinement fleet stand-down its trigger, and what cleared the
     hand-flag blocks on #874/#877/#878 eleven seconds after they formed
     the same day. A page that fails mid-walk fails the whole sample into
     `ok: false` (deciding nothing), and a `gh` that returns no output at
     all is a failed sample, never an empty digest — both the same
     direction the previous bullet already demands. The workflow-runs
     window stays a single page by design: nothing reads absence from it,
     and its own clause above names the drop-off the safe direction.
   - **Fingerprint before the Co-Ordinator runs, and record that value.**
     Anything that changed while it was working is something it may not have
     seen, so it must be allowed to bust the next cycle's fingerprint. A
     fingerprint taken afterwards would absorb that change and skip on it.
   - **The forced recheck is the safety valve, not a nicety.**
     `none_selected_recheck_hours` bounds how long a gap in coverage — or a
     Co-Ordinator that would have decided differently on a second look — can
     hold the pipeline down. At 24 cadence firings (requirement 1d) an idle
     day costs one Co-Ordinator run instead of 24, and any stall is capped at
     24 skipped firings — a day at the historical hourly cadence, more or less
     elsewhere depending on how fast the cadence actually is. Setting it to
     `0` makes fingerprint coverage load-bearing forever.
   - `--dry-run` and `--once` bypass the skip (a human asking for a cycle wants
     an answer, not a cached verdict) but still *compute and record* the
     fingerprint, so a `--once` that finds nothing spares the next cron tick
     the same question.
4. **Co-Ordinator stage.** Launch the Co-Ordinator (headless, model
   `coordinator_model`, `--dangerously-skip-permissions`, stage timeout),
   passing it the ordered repo list (each entry carrying its work sources and
   its pre-fetched `findings`) and the blocked-item extract from the shared
   log. Capture its final message from the stage's own transcript
   (requirement 4d) and parse the work order from it.
4a. **Per-installation prompt overrides.** Every stage prompt this Script
   assembles — the Co-Ordinator's here, the Implementer's (requirement 7), the
   Reviewer's (requirement 8), the Enabler's (requirement 35), and the
   Refiner's (requirement 39) — is built by
   `lib/prompt-overrides.sh`'s `stage_prompt_text`, not a bare
   `cat prompts/<stage>.md`, so a consumer can add or replace a stage's operating
   prompt from `config.json`'s `prompt_overrides` without forking `prompts/`
   (issue #79). The Approver (requirement 8b) is the one deliberate
   exception: `run_approver_stage` assembles its prompt with an empty
   overrides object (`'{}'`), never the configured `prompt_overrides`, and
   the schema's enumeration omits `approver` to match. Its adversarial
   prompt is the gate the D18 trust ladder rests on
   (`docs/reviews/2026-08-14-autonomy-investigation.md` §5.2), and an
   installation able to extend or replace it could soften the one check
   every autonomous landing depends on (#469). For stage `<s>`, `prompt_overrides.<s>.extend` names zero or
   more files whose content is appended, in order, after the base prompt, each
   under a heading naming the entry's *configured* path — the string written
   in `config.json`, never the node-resolved location, so the assembled text
   is identical on every node serving the same config and content — and each
   wrapped in a fixed disclaimer that it may add guidance but does not exempt
   the installation from any numbered requirement in this document — the
   specs outrank every prompt, and an extension is not an exception to that.
   `prompt_overrides.<s>.replace` names one file substituted for
   `prompts/<s>.md` as the base, before any `extend` fragments are appended;
   it is the sharper tool, since a replaced prompt stops receiving this
   product's updates to that stage entirely, and the README flags it as such.
   A relative path in either key resolves against `state_dir` — the one
   location this repository guarantees survives an image roll or a
   `git pull`, unlike `prompts/` itself, which is baked into the image and the
   working tree alike. `prompt_overrides` absent, or a stage missing from it,
   reproduces today's exact prompt bytes: `stage_prompt_text` degrades to
   `cat prompts/<s>.md` with nothing appended. An unreadable configured path
   (missing file, bad permissions) is tolerated the same way — dropped from
   the assembled prompt, not a cycle failure — but still moves
   `stage_prompt_sha` (below), so a broken path cannot silently reproduce the
   fingerprint of a working one. That tolerance covers configured overrides
   only: the base prompt is this product's own content, so an unreadable
   `prompts/<s>.md` that no readable `replace` has substituted fails the cycle
   rather than launching the stage on an empty prompt — a stage given a work
   order and no instructions would spend a model to no purpose.
   That tolerance is for *runtime* faults only.
   `config.json`'s `prompt_overrides` itself must be structurally valid to
   full depth — an object (possibly `{}`) keyed only by the six stage names,
   each stage an object holding only `extend` (an array of file-path strings)
   and/or `replace` (a file-path string); any other shape — an unknown stage
   key, a non-object stage value, an unknown key within a stage, a wrong
   type — is a fatal misconfiguration at startup, caught by the schema gate
   (requirement 1b), the same as a missing `implementation_plan_path`
   (requirement 3k). The two faults differ in kind: a configured file can
   legitimately be absent this cycle and its absence still moves the
   fingerprint, but a structural typo is a static authoring error that would
   otherwise be swallowed by the assembly functions' own tolerance and serve
   the unmodified shipped prompt every cycle — with, for a misspelled stage
   key, no fingerprint movement to betray it.

   The Co-Ordinator's and Enabler's assembled prompts also feed the no-op
   fingerprint (requirement 3b, 35b): `coordinator_prompt_sha` and
   `enabler_prompt_sha` are `stage_prompt_sha`'s content-addressed digest of
   the stage's assembled prompt: the base file's content hash, then each
   configured `extend` entry's content hash keyed by its configured path,
   with a configured-but-unreadable entry recorded explicitly under that
   same configured name — rather than a bare `sha256sum` of
   `prompts/<s>.md`. A changed, added, removed, or newly
   unreadable override therefore busts the fingerprint exactly as an edit to
   the shipped prompt does; without this, an installation's own extension
   could change the Co-Ordinator's or Enabler's behaviour while the
   short-circuit went on citing a `none-selected` verdict reached under the
   old text. No resolved filesystem path enters the digest: `none-selected`
   fingerprints are compared fleet-wide across the shared log (requirement
   3b), so two nodes serving identical prompt bytes from different install
   paths must compute the same fingerprint, and relocating an installation
   without changing a byte of served content must not bust the
   short-circuit. The digest is a pure function of the override
   configuration and the contributing files' bytes, never of the node's
   filesystem layout.

   **A per-repository layer, for the two stages that already run against a
   single known repository (agent-ops#588).** The Co-Ordinator runs once per
   cycle across every configured repository together (requirement 4), so an
   installation-wide `prompt_overrides` entry is the only granularity it can
   take; the Implementer (requirement 7) and the Reviewer (requirement 8)
   each already run against exactly one repository — the one the Co-Ordinator
   selected that cycle — so `repos[].prompt_overrides` (`config.schema.json`'s
   `repoPromptOverrides`) lets a repository add or replace its own
   `implementer`/`reviewer` prompt without reaching into the installation-wide
   key that would otherwise apply to every repository at once.
   `lib/prompt-overrides.sh`'s `prompt_overrides_json_for_repo` resolves the
   two layers before either stage's prompt is assembled: for a stage `<s>` in
   `{implementer, reviewer}`, the selected repository's own
   `repos[].prompt_overrides.<s>` entry wins outright — the whole
   `{extend, replace}` object, not a field-by-field merge with the
   installation-wide entry — when that repository's own entry sets `<s>`,
   the installation-wide `prompt_overrides.<s>` entry otherwise; the same
   precedence `stage_timeouts` and `merge_autonomy` already give one actor's
   or one scalar's repository-level override. A repository that sets neither
   stage, or that is missing from `repos[]` entirely, sees the
   installation-wide object unchanged — `prompt_overrides_json_for_repo`
   degrades to reading `.prompt_overrides` directly, byte for byte. Every
   other stage name is refused on a repository's own entry rather than
   silently ignored: `repoPromptOverrides`, unlike the installation-wide
   `promptOverride` enumeration, admits only `implementer` and `reviewer` as
   properties, and `additionalProperties: false` turns a `coordinator`,
   `enabler`, `refiner` or `monitor` key there into the same schema-gate
   fatal misconfiguration (requirement 1b) as any other unknown key — none of
   those four stages has a single repository to scope an override to yet.
4b. **The repo/work-sources table is generated from `config.json`, not
   hand-maintained in the prompt (issue #78).** `prompts/coordinator.md`
   carries a `@@WORK_SOURCES_TABLE@@` marker where a table naming consumer
   repos and their `sources` used to be hand-written — the prompt file names
   no real repo anywhere, including its worked examples, which use generic
   placeholder slugs instead. `lib/coordinator-brief.sh`'s
   `coordinator_work_sources_table` renders one Markdown row per entry of
   `config.json`'s `repos` array, numbering that repo's configured `sources`
   in the order given — the plain configured list, never a cycle's
   back-pressure-restricted view (requirement 2.2a), so the table always
   states each repo's full configured priority, matching what "Target
   repositories" above documents for this installation. The Script (after
   requirement 4a's `stage_prompt_text` has assembled the base prompt and any
   configured overrides) replaces every occurrence of the marker with this
   table before appending the runtime input. Adding a repo or reordering a
   repo's `sources` in `config.json` therefore changes the Co-Ordinator's
   brief with no edit to `prompts/coordinator.md` — the config-only change
   the README already claimed for this, now actually true. The rendered
   table joins the no-op fingerprint (requirement 3b) as its own input,
   `coordinator_work_sources_table`, computed from the plain configured
   `repos` array before the fingerprint is taken: the runtime input's
   `repos[].sources` is *not* sufficient cover on its own, because
   back-pressure (requirement 2.2a) narrows that array to a repo's finishing
   sources for one cycle while the table — and the prompt the Co-Ordinator
   actually reads — keeps showing that repo's full configured priority
   regardless, so a config edit to a non-finishing source landing during
   such a cycle would otherwise change the assembled prompt without busting
   the fingerprint.
4c. **An assembled prompt reaches its stage on stdin, never in argv.** Every
   stage this Script launches — the Co-Ordinator here, the Implementer
   (requirement 7), the Reviewer (requirement 8) and the Enabler
   (requirement 35) — is invoked as `claude -p` with the prompt written to
   the process's standard input, not as a command-line argument. Linux caps a
   single argv entry at `MAX_ARG_STRLEN`, 32 pages — 131072 bytes — a
   compile-time constant that no `ulimit` raises and that `getconf ARG_MAX`,
   which reports the far larger limit on the *total*, does not describe. The
   Co-Ordinator's assembled prompt is already of that order: its base file
   alone passed 60 KB in July 2026 and the runtime input it carries grows
   with the fleet's repo and work-source count, so the margin is measured in
   paragraphs and every prompt edit spends some of it. Exceeding it fails at
   `execve`, before any model is reached: the stage exits 126 with
   `Argument list too long` on stderr, the cycle records `attempt-failed` and
   then ends *successfully* with nothing selected (requirement 9 makes a
   failed stage a failed attempt, not a failed cycle), and the node is
   indistinguishable on the dashboard from one with no work to do. It is the
   silent-stall shape the no-op fingerprint rules exist to prevent, arriving
   by a different door — and, because prompts ship in the image, it arrives
   fleet-wide on the same image roll. The delivery mechanism is a here-string
   rather than a pipe so the invocation stays a single process whose exit
   status is the stage's own; under `pipefail` a `printf | claude` would
   report printf's SIGPIPE as the stage's result whenever a stage exited
   without draining its input. `review-cycle.sh` launches its stages through
   the same function (requirement 4d), so the review pipeline's smaller
   prompt — the one that would sit broken longest before anyone noticed — is
   covered by construction rather than by a second copy kept in step by hand.
4d. **One stage launcher, and it streams.** Every headless `claude`
   invocation either pipeline makes — the five stages of this document, the
   usage-limit probe of requirement 1b, and the Reviewer-Agent of
   `docs/spec/review.md` R5.3 — goes through `run_claude_stage` in
   `lib/stage-run.sh`: one implementation, sourced by both cycle scripts,
   rather than a copy in each. It launches the invocation in its own process
   group (`set -m`), so the stage timeout's kill reaches every descendant
   (requirement 9c), and it runs the invocation under
   `--output-format stream-json --verbose`. An optional resume-session-id
   argument passes `--resume` instead of starting a fresh conversation —
   requirement 9e's salvage is the one caller that ever supplies it, and every
   other caller's invocation is unaffected. Each invocation therefore leaves
   three files beside each other:
   `<stage>.stream.jsonl` — every event the run emitted, one JSON object per
   line, flushed as the run proceeds; `<stage>.out` — that stream's final
   `result` event and nothing else; and `<stage>.out.stderr` — the
   invocation's diagnostics, kept in a separate file so stray output can
   never break the parse of the envelope.
   The streaming form is chosen for *when* its output arrives, not for its
   shape: `--output-format json` writes one object at the very end, so a
   stage killed at its cap leaves an empty file and nothing whatever is known
   about how far it had got, while a stream is a record of the run that
   survives the kill and is readable while the run is still going. What lands
   in `<stage>.out` is byte-for-byte the envelope the non-streaming form
   produced, so every reader of a stage transcript — the result parsers, the
   per-stage metering record (requirement 33a), limit detection (requirement
   2.1), the dashboard's own rendering — reads exactly what it read before. A
   stage that was killed, or that died before emitting a `result` event,
   leaves `<stage>.out` empty, which is the same degradation those readers
   already handle for a stage that never ran.
   The streams are **local-only**: they are excluded from the state
   replication in both directions and pruned to `state_local_streams_retained`
   directories (requirement 2.5). A `.out` is one JSON object; a stream is
   every message and every tool result, and the mirror holds `cycles_retained`
   cycles per node in git history, so replicating them would trade a bounded
   repository for an unbounded one.
4e. **Two caps on a stage, and they answer different questions.** Every stage
   is bounded by a **backstop** — the `timeout_<actor>` wall-clock cap, which
   `run_claude_stage` enforces by killing the process group — and by a
   **liveness watchdog**: `inactivity_<actor>` minutes during which the stage
   produced no output whatsoever. Whichever fires first kills the stage, by
   the same sequence (TERM to the process group, a five-second grace, then
   KILL) and with the same exit status, 124.
   The watchdog reads the stage's own event stream (requirement 4d): inside
   the poll loop that already runs every two seconds, it compares the file's
   size against the largest size seen. Liveness is **monotonic growth of that
   file** — not a beat count, not a timestamp inside the events, and nothing
   the stage cooperates in. There is therefore no cadence for a loaded node to
   miss: contention stretches every gap proportionally, and a threshold with
   several times the observed headroom absorbs that with no load-relative
   correction. A stage emits nothing for this and can fake nothing.
   The two caps exist because a single wall-clock number conflates "this is
   taking a long time" with "this has stopped", and the record says the
   pipeline only ever killed the first. Across 456 stage runs there is not one
   instance of a genuinely hung actor: every killed run was emitting steadily
   when the wall reached it, at a tempo indistinguishable from runs that
   succeeded. Nor is such a kill merely a delay — a killed Reviewer records no
   verdict, so the pull request reaches the human with no pipeline review at
   all and nothing in the merge record says the gate never ran.
   A third thing stops a stage, and it is not a cap at all: **the account
   saying no**. The stream carries the runner's own `rate_limit_event`, and a
   `rate_limit_info.status` of `rejected` means nothing the stage does from
   here can succeed. It is stopped on the spot. Limit detection (requirement
   10) has always run on the transcript *after* a stage ended, so a stage that
   hit a limit early went on holding the node for the rest of its cap while
   every call it made was refused.
   Only `rejected` stops a stage. The runner's vocabulary for that field is
   `allowed`, `allowed_warning` and `rejected`; `allowed_warning` means "you
   are close", which a stage must be allowed to run through, and any value not
   recognised is likewise left alone to fall through to the phrase matcher
   that has always handled this. The asymmetry is deliberate and is §3.2's:
   failing to abort early costs the rest of a wall-clock cap, while aborting a
   healthy stage throws away everything it had done. The check is made only on
   an event of the runner's own — a top-level `rate_limit_event`, never a
   string inside a tool result, since an Implementer working on limit
   detection reads fixtures shaped exactly like one.
   The `rate_limit_info` that stopped the stage becomes the stand-down's
   evidence, and is better evidence than the prose path can produce: it states
   `resetsAt` as an epoch, so `reset_known` is `true` and the fleet is spared
   the usage probe requirement 1b spends on every cycle of an *estimated*
   stand-down. It is also the only source available on this path at all — a
   stage stopped at the refusal never writes a final message for the phrase
   matcher to read. `lib/limit-detect.sh`'s `limit_decide_structured` maps it
   to the same `resume_at`/`class`/`reset_known` triple the prose path
   produces, so the two cannot yield differently-shaped stand-downs, and
   declines rather than guessing when the record says nothing usable.
   **`kill_reason`** distinguishes all three on the `stage-end` /
   `review-stage-end` event: `inactivity`, `backstop` or `rate-limit`, and
   absent when the stage ended on its own. `exit_code: 124` cannot carry it,
   and they imply different corrections — a backstop kill argues the cap is
   too tight for work that was progressing, an inactivity kill argues the
   stage stopped, and a rate-limit stop argues nothing about the caps at all.
   The `attempt-failed` detail says which in words, for the Enabler and for
   whoever asks why the item is blocked.
   A watchdog kill also logs a **`warning`**. Its kill path had fired zero
   times in the whole recorded history when it was built, so the first firing
   is news either way: a wedged actor caught, or a threshold too tight for
   something a stage legitimately does — which would be this mechanism
   reintroducing, from the other side, the failure it exists to end. The rate
   is the thing to watch, and a rate nobody is told about is not watched.
   **Neither cap is a configured constant.** Both are derived per
   (actor, repository, model) by requirement 4f, from a shipped prior when
   there is no history to derive from — the watchdog's prior being ten
   minutes, roughly three and a half times the longest run-average gap ever
   recorded and far above anything a healthy stage has been seen to do. A key
   present in the configuration is an override and wins; `0` disables the
   watchdog for that actor and leaves the backstop as the only cap. Erring
   generous is deliberate, because the loss function is asymmetric: too
   generous costs the marginal minutes of a session that was going to fail
   anyway, bounded by the backstop above it, while too tight throws away
   everything the stage had done.
   **`scripts/doctor.sh` proves the signal exists on this node.** The watchdog
   is worthless if the runtime buffers stdout when the destination is not a
   tty: the file would stay empty until the run ended, and every healthy stage
   would be killed at its threshold. So the doctor makes one real invocation
   of the cheapest configured model and samples the stream *while it is still
   running* — a finished run looks identical either way — and fails loudly,
   naming the `inactivity_*` escape hatch, if the output arrived only at the
   end. It is the one check there that spends, for the reason requirement 1b's
   usage-limit probe spends: some questions can only be answered by asking.
4f. **Both caps are derived, per (actor, repository, model), from the
   pipeline's own record of itself.** Requirement 4e gives every stage a
   backstop and a watchdog; this decides what those two numbers are.
   `lib/stage-budget.sh` folds the fleet log union — the same stream the
   blocked extract, the void extract and the no-op fingerprint read — into one
   table per cycle. Nothing is stored: a derived value is a pure function of
   events every node already shares, so four nodes agree with nothing to
   replicate and no controller state to reconcile.
   **The cell is `(actor, repository, model)`.** Not the actor alone —
   reviewing this repository costs three to four times what reviewing the
   others does, because every diff is checked against a five-thousand-line
   specification, and that cost rises with every edit to it. Not
   `(actor, repository)` either: the strongest single predictor of how long a
   stage runs is the model it ran under, and a cell pooling two of them has a
   bimodal duration distribution that no single moment or quantile describes.
   Complex-model reviews here run about twice as long at every quantile as
   default-model ones and were killed roughly six times as often; a controller
   given their average holds a cap far too tight for one and needlessly loose
   for the other, and converges for neither. Node is deliberately *not* a
   dimension, though nodes differ in speed: it would cut the largest cell to
   about eleven runs and the interesting one to about five, and no estimator
   recovers a distribution's tail from five observations — while the tail is
   the entire quantity of interest. The Enabler and its
   `enabler-adjudicate`/`enabler-decide` passes (requirements 36b/36d) are
   keyed `(actor, *, model)`, spanning repositories, so none of them has one.
   The Co-Ordinator is keyed `(actor, repository, model)` like every other
   implementation actor (issue #1629): since the per-repository split
   (requirement 15z, agent-ops#1560/#587) each engagement already runs for
   exactly one repository, and its own `stage-end` carries that repository
   directly rather than through the cycle-level `selection` join every other
   actor uses — a per-repository cycle no longer resolves to one repository,
   so that join is not available to it. A run from before the split carries
   no repository at all and is still read as `(coordinator, *, model)`, a
   pool that is fixed from the moment this shipped: every engagement since
   carries its own repository, so nothing new is added to it. A brand-new
   `(coordinator, <repo>, model)` cell — no runs of its own yet — resolves
   against that frozen pool instead of the shipped prior directly, exactly
   as `stage_budget_resolve`'s own precedence tier 3a does for it alone; once
   it has a run of its own, `stage_budget_table` seeds its backstop
   controller from the frozen pool's own value rather than the shipped prior
   too, so the two do not disagree at the boundary where a cell first gets an
   entry of its own. This is deliberately not folded into the ordinary
   `pooled_inactivity`/`model_inactivity` shrinkage chain every actor already
   gets for its watchdog threshold: that chain blends a *statistic* (a
   weighted average of gap maxima), which tolerates a repository's own data
   also sitting inside the coarser pool above it; the backstop is a
   *stateful* replay of kills and streaks, where the same run folded in twice
   — once directly, once already baked into a pooled seed computed from it —
   would double the effect of every kill it carried. The frozen `*` pool has
   no such overlap with a real repository cell, which is what makes this one
   case safe to seed this way at all.
   **The watchdog threshold is estimated; the backstop is controlled.** They
   are different quantities and deserve different instruments, and splitting
   them is also what removes any wait for data. The threshold's sample is
   inter-event gaps (requirement 33a), so a single long stage yields
   observations of the thing being measured and a new repository has a usable
   distribution within a few cycles. A run duration is one observation per
   stage per cycle, which is genuinely slow — so the backstop is not fitted at
   all.
   *The threshold* is `k x max(gap)` over the window, k defaulting to four,
   shrunk towards the pooled estimate and floored at the shipped prior. The
   maximum rather than a mean plus so many standard deviations is the
   load-bearing choice: a run killed for inactivity at threshold `T` records a
   maximum gap of `T`, so the next threshold computed from it is `k x T` and
   the estimator *widens* under censoring. A mean-plus-sigma rule takes the
   same censored observation in below its true value, pulls the estimate down,
   tightens the threshold and censors more — a spiral that, simulated over the
   real distributions, never converges and never recovers the tail. It also
   assumes nothing about the distribution, which matters because gaps are
   heavy-tailed. It never narrows below the prior whatever the data say, and
   never exceeds the backstop above it.
   *The backstop* is a multiplicative-increase, additive-decrease controller,
   folded over the cell's runs in time order. It is the mirror image of the
   congestion control the shape is borrowed from, and deliberately: there the
   danger is a window grown too large, so it backs off hard and recovers
   slowly; here the danger is a cap set too small — that is what destroys a
   stage — so the sharp move is upward and the cautious one downward. A
   backstop kill multiplies the cap, being the only unambiguous evidence it is
   too tight and precisely the censored observation that broke the estimator
   approach. A step down needs three things at once: a run of clean stages, an
   observed kill rate inside the objective, and a 95th percentile of
   *completed* runs still well clear of the reduced cap. A killed run
   contributes no duration at all — its recorded length is its cap, not its
   length. Floors and ceilings bound the fold: never below the value the fold
   started from, never below twice that percentile, never above a fixed
   multiple of that same starting value, and when floor and ceiling disagree
   the floor wins, because throughput is a preference and discarding a
   finished stage is not. That starting value is the shipped prior for every
   cell but one — a warm-started `(coordinator, <repo>, model)` cell starts
   from the frozen `(coordinator, *, model)` pool instead (below), so its
   floor and its ceiling scale with the seed it inherited rather than with the
   prior.
   **Cold start is hierarchical shrinkage, not a threshold.** A cell's
   estimate is `(n·own + n₀·prior) / (n + n₀)`, with the prior the pooled
   value one level up — the same actor and model across every repository,
   falling back to the same actor across every model, and the shipped prior at
   the root. There is no run count at which a cell switches on; it slides.
   That is what makes the model dimension affordable: a model used twice in a
   repository contributes almost nothing of its own and sits essentially at
   the pooled estimate, rather than producing the wild cell a hard split would
   give. An installation with no history at all runs on the shipped priors,
   which is the whole requirement — a customer must never be asked to choose a
   timeout, and must get sensible behaviour on cycle one.
   **Precedence, most specific first:** a `stage_timeouts` /
   `stage_inactivity` entry on the repository being worked; the plain
   `timeout_<actor>` / `inactivity_<actor>` key; the adaptive value for the
   cell; the shrunk pooled value for the actor; the shipped prior.
   Configuration outranks the derivation deliberately — an installation that
   has said what it wants is not to be argued with — and, just as
   deliberately, **the pipeline never writes to `config.json`**: a customer's
   configuration stays theirs, and a self-tuning value can never become
   pull-request churn in somebody else's repository. The corollary is that a
   configured cap pins itself permanently, which `scripts/doctor.sh` warns
   about, because a number set once and forgotten looks exactly like a system
   still adapting — at every level of the precedence above, not only the
   plain `timeout_<actor>` / `inactivity_<actor>` keys: the Refiner's own
   pair, and each repository's `stage_timeouts` / `stage_inactivity` entry,
   named by that repository's slug so the warning says which entry to edit.
   **Every value is announced.** The `stage-start` /
   `review-stage-start` event carries `backstop_min`, `inactivity_min`,
   `source` (`config`, `cell`, `pooled` or `prior`) and `basis` (`own`,
   `shrunk`, `pooled` or `prior` — `pooled` wherever the value came from a
   level above the cell, so a cell with no runs of its own can never announce
   `own`), so a reader looking at a stage finds the numbers it
   was given and where each came from; `scripts/doctor.sh` reports the whole
   table; and the dashboard holds a live stage against the cap that stage was
   actually given rather than against a shared constant. A self-tuning number
   that cannot be traced is a mystery number.
   **`lock_stale_after` is derived, not asserted.** It was a constant checked
   against other constants, and that check had to be re-derived by hand every
   time any of them moved — three times in the two days before this was
   written, each raise forcing a knock-on recalculation somewhere else. The
   threshold is now the sum, over the six actors, of the widest backstop each
   could draw this cycle, plus slack; a configured `lock_stale_after` is a
   floor under it rather than the value. Erring long is close to free, because
   a dead holder is taken over on its pid rather than on its age, so this
   bounds only how long a live but hung cycle may hold on. The review
   pipeline derives its own the same way, doubling the widest Reviewer-Agent
   backstop because one lock can span two repositories reviewed back to back.
4g. **Fleet-state JSON reaches `jq` on stdin, never in argv.** Requirement
   4c's cap is an `execve` fact, not a prompt fact, and prompts are not the
   only unbounded strings this Script builds: the void extract, the blocked
   extract, the refinements map, the claims array and the pre-fetched repo
   array all grow with the fleet's history, and each used to ride into `jq`
   as an `--argjson` value — a single argv entry capped at `MAX_ARG_STRLEN`
   (131072 bytes). On 2026-08-12 the void extract reached 133615 bytes and
   the cap bit twice, in two different ways. At the no-op fingerprint and
   Co-Ordinator input builds the call is unguarded, so under `set -e` every
   cycle on every node died at `execve` with `Argument list too long`, exit
   126, before the Co-Ordinator ran — and because that death precedes both
   selection and any stage launch, it wrote no `attempt-failed`, so
   requirement 2.7's crash-loop ladder, which counts consecutive
   Co-Ordinator `attempt-failed` events, never saw it: the union log showed
   only `cycle-start`/`cycle-end` pairs while the dashboard's work-source
   panel, fed by the publisher's own fetch, kept advertising candidates no
   Co-Ordinator would ever read. At the act-on-void sweep (requirement 34k),
   the register-void pass (since retired) and the unvoid-label read
   (requirement 34f), the same delivery sat behind `2>/dev/null || echo
   '[]'` guards and degraded silently instead — and what those three
   implement is exactly the machinery that retires void state, so the
   failure had disabled its own remedy. Every fleet-state aggregate
   therefore arrives on the `jq` call's standard input — one JSON document
   per line, bound positionally with `input as $name` in the order printed,
   an order coupling each call site states beside the `printf` — and only
   values bounded by configuration (a model name, a config object, a prompt
   sha, one repo's register ids) may still travel as `--arg`/`--argjson`.
   Delivery is a here-string, not a pipe, for requirement 4c's reason: under
   `pipefail` a producer's SIGPIPE must not become the reader's status.
   Every converted site carries its own regression pin, built from an input
   the assertion beside it first proves is genuinely past the cap and asserted
   in the direction that site fails — silent `[]`, or silent pass-through —
   so a reintroduced `--argjson` fails a test rather than a fleet:
   `test/unvoid-label.test.sh`, `test/verdict-corroboration.test.sh` and
   `test/cycle-state.test.sh` for the void extract, `test/work-gone.test.sh`,
   `test/needs-refinement.test.sh`, `test/label-marker.test.sh`,
   `test/pr-claim-exclusion.test.sh` and `test/enabler-eligibility.test.sh`
   for the blocked extract, the own-actions map, the claims arrays and the
   open-issues map. TD-PPagop-26081401 completed the sweep over the sites
   TD-PPagop-26081301 did not enumerate — the merge-conflicts candidate fold
   (`test/merge-conflicts.test.sh`), the per-repo claims fold
   (`test/pr-claim-exclusion.test.sh`), the verdict-contradiction warning and
   corroboration events and the `unaccounted_items` eligible-set read feeding
   them (`test/coordinator-merge-fallback.test.sh`,
   `test/verdict-corroboration.test.sh`), the hand-flagged-refinement
   accumulator (`test/needs-refinement.test.sh`), `work_gone_clearances`'s
   register/review/plan status maps (`test/work-gone.test.sh`), the Enabler
   and Refiner claim accumulators, and their own unparseable-verdict warnings
   (`test/enabler-verdicts.test.sh`, `test/refiner-verdicts.test.sh`).
   TD-PPagop-26081406 completed the sweep over the sites neither prior item
   enumerated: the Co-Ordinator's recorded-refinement and voided
   accumulators, both `{needs_refinement, voided}` builds feeding
   `unaccounted_items` and the retry's own merge of both attempts'
   accumulators (`test/verdict-corroboration.test.sh`,
   `test/coordinator-merge-fallback.test.sh`), the per-repo entry build that
   feeds the Co-Ordinator's whole input (`test/repo-entry-build.test.sh`),
   the review-feedback, abandoned-drafts, issues, human-visibility-hygiene
   and unvoid-request gatherers' own candidate builds and folds
   (`test/review-feedback.test.sh`, `test/abandoned-drafts.test.sh`,
   `test/issues-prefetch.test.sh`, `test/gather-human-visibility-hygiene.test.sh`,
   `test/gather-unvoid-requests.test.sh`), `refiner_candidate_items`
   (`test/refiner-eligibility.test.sh`), and the Dependabot-conflict nudge's
   own accumulator (`test/nudge-dependabot-rebase.test.sh`).
   TD-PPagop-26081501 converts the one site TD-PPagop-26081406 found but did
   not enumerate: `lib/handoff.sh`'s own `handoff_answer_events`, shared by
   `scripts/gather-review-feedback.sh`'s direct call and
   `scripts/sweep-human-visibility.sh`'s through `handoff_round_answered`,
   whose three arguments are a repo's whole reviews, comments and rerequests
   (`test/handoff.test.sh`, `test/review-feedback.test.sh`).
   TD-PPagop-26081502 converted the one site TD-PPagop-26081406 found but did
   not enumerate: `agent-cycle.sh`'s own invocation of
   `scripts/gather-human-visibility-hygiene.sh`, which handed that script's
   whole `$violations` argument as a single argv element to the script's own
   `execve` (`test/gather-human-visibility-hygiene.test.sh`).
   TD-PPagop-26081503 completed the sweep over four further sites found after
   TD-PPagop-26081406 resolved, three of which survive:
   `gather-source-state.sh`'s final state build
   (`test/gather-source-state.test.sh`), `gather-findings.sh`'s
   combine-and-order build (`test/gather-findings.test.sh`),
   and `publish-dashboard.sh`'s
   `github_json` build (`test/publish-dashboard.test.sh`).
   TD-PPagop-26081506 converted the two sites that item's own Implementer
   found but left out of scope, both in `publish-dashboard.sh` upstream of
   the `github_json` build: the per-repo `prs_json` fold and the
   merge-queue queue-answers merge (`test/publish-dashboard.test.sh`).

   **A converted site binds by position, so each argument is one document.**
   `input as $name` reads whichever document comes next; unlike the
   `--argjson` it replaces, it does not reject an argument carrying two —
   the shape an unslurped `gh api --paginate` read leaves behind — so every
   later binding shifts onto the wrong value with nothing raised. What
   guarantees one document per argument is the caller: each converted site
   slurps its reads (`jq -s -c`) before handing them over. Only
   `handoff_answer_events` additionally asserts it, by requiring the document
   stream to be exhausted once its three bindings are read
   (`[inputs] | length`, never a fourth `input` binding — `try` swallows the
   assertion's own error on jq ≤ 1.6, and a bound document cannot be told
   from a trailing literal `null` on any version). It asserts because its
   verdict is `handoff_round_answered`'s tri-state, where a shifted binding
   reads as an *answered* round and costs requirement 3c's silent starvation
   rather than a visible failure.

   **The cap is per argv element, not per flag.** `--arg` is bound by
   `MAX_ARG_STRLEN` exactly as `--argjson` is, so a rendered string counts
   against this requirement wherever it grows with fleet state. Two sites
   carry one: `scripts/gather-review-feedback.sh` assembles every fresh review
   and inline comment into one body, and `scripts/gather-human-visibility-hygiene.sh`
   renders its survivor set into a digest. Both keep
   that value JSON-encoded and hand it to their candidate build on stdin
   beside the array(s) it came from — an `--arg` there would put the same
   bytes back into a single argv element and leave the threshold where it
   was. Their tests drive each build with a body past the cap.

   No site outside every prior item's enumeration remains outstanding: the
   two sites this requirement once filed rather than fixed —
   `agent-cycle.sh`'s own invocation of
   `scripts/gather-human-visibility-hygiene.sh`, which handed that script's
   whole `$violations` argument as a single argv element to the script's own
   `execve` (TD-PPagop-26081502), and `publish-dashboard.sh`'s own per-repo
   `prs_json` fold and its queue-answers merge, both upstream of the
   `github_json` build TD-PPagop-26081503 converted and still carrying the
   fleet-wide PR index into `jq` as `--argjson` (TD-PPagop-26081506) — are
   both now converted; this requirement claims no more than the sites named
   above.

   **A shell script's own CLI invocation is bound by the same cap.**
   `MAX_ARG_STRLEN` is a kernel-wide per-argument `execve` limit, not a
   `jq`-specific one, and it binds a script's own positional arguments
   exactly as it binds `jq --argjson` — a cap this requirement's
   `jq`-specific framing had not considered until TD-PPagop-26081406 found
   it (TD-PPagop-26081502). `agent-cycle.sh` used to hand
   `scripts/gather-human-visibility-hygiene.sh` the fleet-wide
   human-visibility violations log as that script's own second positional
   argument, unbounded past the call; the script now reads it from stdin
   instead, the same shape its own internal `jq` calls already took, and
   `agent-cycle.sh` pipes `$violations` in rather than passing it
   positionally. Regression-pinned in
   `test/gather-human-visibility-hygiene.test.sh` by driving the real
   script directly over a violations log genuinely past the cap.

   **The rule is the Publisher's too.** It was first written for the Script,
   because that is where the 2026-08-12 outage happened, and that scoping is
   what let the same defect survive two doors down: `execve`'s cap is a
   property of the process, not of the program, and the Publisher reads the
   very same unbounded extracts from the very same log. On 2026-08-14 the void
   extract reached 132539 bytes and `publish-dashboard.sh` died at its assemble
   — every node at once, since the extract is a property of the shared log
   rather than of a node — in a third way, distinct from both of 4c's: the call
   is neither guarded nor under `set -e`, so `$data_json` came back empty and
   the write that followed emitted `window.DASHBOARD_DATA = ;`. That is a
   JavaScript syntax error, so every dashboard on the fleet went on rendering
   the payload it had loaded last, for 75 minutes, while every tick logged a
   successful write of a file it had just corrupted. So the Publisher's void
   and blocked extracts and its counts roll-up reach `jq` by file or stdin like
   any other fleet-state aggregate, pinned by `test/publish-dashboard.test.sh`;
   and, because a cap is only the readiest of the ways that assemble can die,
   the Publisher **asserts its payload parses before it writes**. An assemble
   that failed leaves the previous `data.js` in place and exits non-zero: a
   page that ages visibly against its own `generated_at` reports the outage,
   where an unparseable one only hides it.

4h. **A guard that answers with a literal says on the union log that it
   did.** Requirement 4g changed how the fleet-state aggregates are
   *delivered*; it did not change what a read that fails anyway still
   answers. Ninety-one call sites in this Script carry the shape `cmd …
   2>/dev/null || <literal>`, and at sixty-seven of them the literal is an
   answer indistinguishable from a real one — an empty array, a zero, an
   empty object — over an input that can genuinely fail at run time: a
   config, lock or log file read off disk, a `gh api` or `lib/claim.sh`
   subprocess, a `date` parse of fleet state, a stage-output JSON file under
   `cycle_dir`. Nothing downstream can tell "no items" from "I could not
   compute the items", and on 2026-08-14 nothing did: `unaccounted_items`'
   own guard turned an `execve` failure into *zero unaccounted items*, and
   requirement 3v's corroboration accepted the Co-Ordinator's
   `none-selected` verdict on that evidence, in the cycle with the most
   recorded refinement to account for. So each of those sixty-seven captures
   its command's own stdout **and stderr** where it used to discard the
   latter, and on failure writes a `guard-degraded` event — `{site, detail,
   n}`, the site's own label, the captured text, and which occurrence of that
   label this is — through `guard_warn` before
   falling back. **The fallback value itself is unchanged at every one of
   them**: this removes the silence, never the tolerance, so a cycle degrades
   exactly as far as it degraded before and no guard can turn a bad read into
   a dead cycle. The other twenty-four sites are deliberately unconverted,
   each carrying a one-line comment naming which of the two triage tests it
   passes — the input cannot fail at run time, or the fallback is a
   pass-through of a value the caller already accepted, which is
   distinguishable from a computed answer by construction — so that the next
   reader does not re-triage what has already been triaged.

   **The three names in a guard are one name.** The shape names its variable
   three times over — the assignment's target, the value reported as
   `detail`, and the variable the fallback is assigned to — and across
   sixty-seven near-identical one-liners that is precisely the shape a
   copy-paste slip hides in, invisible to a test suite in which the guarded
   command succeeds. The void closed-merge site shipped in this requirement's
   own first pass reporting and restoring `void_json` where it assigns
   `void_actioned_json`, which on any failure of that call would have left
   the captured error text standing where an `--argjson` reads it moments
   later *and* emptied the void extract for the cycle — every voided item
   selectable again — reintroducing at the guard the exact fault the guard
   exists to report. So the agreement of the three names is asserted
   structurally over every site at once (acceptance check 1m), not one case
   at a time.

   **The report is bounded, and stays off the query path.** `guard-degraded`
   lands on the fleet-replicated union log — the unbounded input requirements
   4c and 4g exist because of — so the report carries the limits its
   destination requires rather than trusting every call site to fail rarely.
   A guard that fails *persistently* (a `date` parse of a field that
   is simply always absent; a `gh` outage across the whole repo loop) would
   otherwise write one event per occurrence per cycle per node: only the
   first `GUARD_WARN_SITE_MAX` (default 3) occurrences of any one site label
   are reported, each numbered `n`, the last of them marked `final` so the
   silence that follows is legible rather than mistaken for recovery. The cap
   is on repeats of one label, not on distinct sites: a label carrying a loop
   variable (`claim-count:<slug>`) still reports per slug, because those are
   different facts. `detail` is capped to its leading 500 bytes for the same
   reason — it is a failed command's own output, which for a `gh api` body
   has no bound of its own, and the cause is at the front of it.

   A management command (`--status`, `--disable`, `--enable`) reports to
   stderr instead of the log. Those run before the lock and deliberately
   create no cycle directory, so that a read-only query leaves nothing
   behind; their `cycle_id` names a cycle that never ran, and an event
   stamped with it would record a failed read during somebody's query as
   though it were pipeline state. Nothing is lost — every fleet-state read a
   management command guards is read again by real cycles, which report it
   under a cycle id that resolves — and stderr is where the human who typed
   the command is already looking.

   **What `2>&1` costs at the two sites where the value is used raw.**
   Capturing stderr is what makes `detail` useful, but it also merges a
   *successful* command's stderr into the captured value. At every converted
   site but two, the value is handed to `jq`, `date` or `wc`, or shape-checked
   before use, and so cannot carry an advisory line into a decision. The
   repo-ordering pair is the exception: `default_branch`
   is interpolated straight into the next API path and `commit_ts` into the
   staleness sort, both previously unchecked, so a future `gh` release that
   began writing an advisory line on a successful `api --jq` would corrupt
   both silently. Each therefore carries a shape check after its capture —
   the sibling of the `claim.sh count` site's own `=~ ^[0-9]+$` — reporting
   through `guard_warn` and falling back to the same literal, so a malformed
   success is treated exactly like a failure rather than trusted.

