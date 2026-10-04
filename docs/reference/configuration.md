# Configuration reference

## Configuration

Edit `config.json` before first run, then check it with
[`scripts/doctor.sh`](../guides/operating/diagnose-by-symptom.md#checking-an-installation) — every key below is
described in `config.schema.json` too, and the doctor validates your file
against it. The schema is the enforceable statement of this table: it knows
each key's type, its range, and whether it may be left out, and it rejects a
key it has never heard of, so a misspelling is caught the moment you check
rather than silently running on a default you did not choose. Both
`agent-cycle.sh` and `review-cycle.sh` validate against the same schema at
startup and refuse to run at all on a config that fails it, so `doctor.sh` is
how you catch a misconfiguration before it costs you a cycle, not the only
thing standing between you and one.

Every key below is set the same way — as a key of the JSON object in
`config.json`, and `repos`' per-repo keys (`nice`,
`implementation_plan_path`, `stage_timeouts`, `stage_inactivity`) on the
repo's own entry inside that array. Editing that file is the whole of it:
there is no command that sets a key, and the pipeline never writes to
`config.json` itself — not even the values that tune themselves — so a value
stays exactly what you left it. On a fleet already running, the edit is a
change to a file the container reads, and reaches the nodes like any other:
merge it, and each node restarts into the new image between cycles, per
[Making a change when every instance is a
container](../guides/contributing/README.md#making-a-change-when-every-instance-is-a-container).

Keys:

<!-- config-table:start id=main — GENERATED from config.schema.json by scripts/render-config-table.sh; edit the schema, not these rows -->
| Key | Default | Notes |
|---|---|---|
| `repos` | see `config.json` | Array of `{"slug": "...", "sources": [...]}`. `sources` is that repo's work sources in priority order (`security`, `issues:urgent`, `review-feedback`, `merge-conflicts`, `dequeued`, `landing-refusals`, `human-visibility`, `abandoned-drafts`, `failed-runs`, `issues:high`, `tech-debt`, `issues:medium`, `implementation-plan`, `project-review`, `issues:low`, `code-quality`). `security` (open Dependabot + security code-scanning alerts) is always first, and any security-related...[continued below](#extended-notes-repos) |
| `state_dir` | *(required)* | Lock, shared log, stage transcripts. Required — there is no default; this installation's own value is `~/.local/state/poetic-agents`, shown in the specification as a worked example. |
| `workspace_root` | *(required)* | Ephemeral clones. Each cycle gets its own subdirectory, and the state repository keeps its mirror here. Required — there is no default; this installation's own value is `~/.cache/poetic-agents/workspaces`, shown in the specification as a worked example. |
| `state_repo` | `Poetic-Poems/agent-ops-state` | Private repository through which `state_dir` replicates between nodes. See [Keeping every node warm](../guides/operating/watch.md#keeping-every-node-warm). Leave it out and nothing syncs — a single-node install behaves exactly as before. The value shown is this installation's own private repository, not a generic default — every installation names its own. |
| `cycles_retained` | *(unset)* | Cycle directories kept in the replicated copy — bounds disk use, derived from `schedule.cycle_interval_minutes` to hold ~8.3 days of history regardless of cadence (requirement 1d); a configured value floors it, never caps it. Your own `state_dir` is not pruned. A value below the derivation does nothing — it has no `STATE_SYNC_*` escape hatch, and the disk floor is `min_free_workspace_bytes` (2.0c), not this key. |
| `state_local_cycles_retained` | *(unset)* | Cycle and review directories the node's own `state_dir` keeps; the same push that replicates prunes to it. Deliberately far above `cycles_retained`, so the local machine is always the longer record. A span of history, not a literal count (requirement 1d): absent, it is derived from `schedule.cycle_interval_minutes` to hold the same ~41.7 days 1000 cycles was sized for at the historical hourly cadence; a configured value is a floor under that derivation, never a ceiling. A...[continued below](#extended-notes-state_local_cycles_retained) |
| `state_local_streams_retained` | *(unset)* | Cycle and review directories whose derived files are kept — the stage event streams (`<stage>.stream.jsonl`) and any fleet-log snapshot (`.fleet-log.jsonl`) a run left behind by dying before its own cleanup, which otherwise removes the snapshot when the run ends. Both are large and local-only — never replicated — so they are bounded well below `state_local_cycles_retained`; the records themselves are untouched. The count applies to `cycles/` and to `reviews/` each, and the...[continued below](#extended-notes-state_local_streams_retained) |
| `log_retained_bytes` | `2000000` | Size at which `scripts/rotate-logs.sh` rotates `dashboard.log`, `state-sync.log`, `doctor.log`, `revert-rate.log`, `tech-debt-archive.log`, `wake-poll.log`, `cron.log` and `review-cron.log`. `log.jsonl`, `review-log.jsonl` and `revert-rate.jsonl` are never rotated. |
| `log_generations` | `3` | Rotated generations kept beside each live log (`<name>.1` … `<name>.<log_generations>`). |
| `analytics_retained_days` | `0` | How long the analytics records in `log.jsonl`/`review-log.jsonl` are retained, independent of `scripts/rotate-logs.sh`'s size-based rotation (neither file is ever in its rotation set) and of `scripts/state-sync.sh`'s pruning of `cycles/`/`reviews/` (neither reaches either file). `0` (the default) means retain indefinitely — today's behaviour, unaffected by this key: nothing yet enforces an expiry against it. |
| `constraint_min_share` | `0.3` | The minimum share of fleet node-time a candidate must account for before the constraint statement names it as the binding constraint — below it, the statement reads "insufficient evidence" rather than naming the largest bucket regardless of size. |
| `constraint_min_sample_seconds` | `14400` | The minimum aggregate node-seconds the time account must cover before the constraint statement states one at all — below it, the statement reads "insufficient evidence" rather than trusting a share computed from too little data. |
| `coordinator_model` | `claude-haiku-4-5-20251001` | Selection is cheap triage. |
| `implementer_model_default` | `claude-sonnet-5` | For code changes. |
| `implementer_model_trivial` | `claude-haiku-4-5-20251001` | For docs, comments, register entries only. |
| `reviewer_model_default` | `claude-sonnet-5` | Quality gate before the landing gate, for work the Implementer graded `complexity:low` or `complexity:medium`. |
| `reviewer_model_complex` | `claude-opus-5` | The same gate for work graded `complexity:high` — the Implementer grades each PR ex post and labels it; the higher of that grade and the PR's existing label picks the tier. Leave it empty to review everything on `reviewer_model_default`. |
| `approver_model_default` | `claude-sonnet-5` | The Approver's model for work graded `complexity:medium`, active once `merge_autonomy` (see below) is above `human`. Leave it empty to switch the whole stage off — no App review is ever posted, at any level. |
| `approver_model_complex` | `claude-opus-5` | The same gate for work graded `complexity:high`, refuse-by-default. Leave it empty to run every Approver engagement on `approver_model_default`. |
| `approver_model_critical` | `claude-fable-5` | The Approver's model for adjudicating a pull request the Approver has refused twice in a row — the rarest and most expensive tier, re-entered every round while that two-refusal streak holds, until an approval resets it; the escalation issue a refusal raises stays deduplicated to one per pull request rather than one per round. Leave it empty to fall back to `approver_model_complex`. |
| `approver_restale_escalate_after_hours` | `24` | Hours the restale sweep retries a pull request before escalating it to `enabler_assignee` instead: a stale Approver `CHANGES_REQUESTED` — its `commit_id` no longer matching the head, but with no commit authored since (a rebase-only push, never a fix) — measured from the review's own `submitted_at`; the same trigger's genuine-progress case when a re-review reaches a verdict but posts nothing to GitHub (an adjudication escalate, most often), measured from the first such...[continued below](#extended-notes-approver_restale_escalate_after_hours) |
| `approver_unreviewed_engage_after_hours` | `2` | Hours an open, ready pull request the pipeline raised may carry no Approver review at all before the restale sweep engages the Approver for it — the recovery for a cycle that died, or a verdict write that was refused, between the Reviewer's handoff and the Approver (agent-ops#890). |
| `enabler_model` | `claude-opus-5` | The Enabler: re-examines long-blocked items and escalates the ones needing you. The most expensive model here, engaged rarely — see [Blocked items and the Enabler](../guides/operating/diagnose-by-symptom.md#an-item-is-blocked-or-void). Leave it empty to switch the stage off. |
| `enabler_model_critical` | `claude-fable-5` | The Enabler's model for its narrower bounded pass — the `adjudicate-first`/`decide-tactical` adjudication or decide pass over one item alone, see [Blocked items and the Enabler](../guides/operating/diagnose-by-symptom.md#an-item-is-blocked-or-void). Leave it empty to run that pass on `enabler_model` itself. |
| `enabler_assignee` | `warwickallen` | GitHub login every Enabler escalation is assigned to. Required whenever `enabler_model` is set — the Script refuses to start a cycle rather than raise an unassigned escalation, since the assignment is what excludes the issue from the pipeline's own `issues` source (see [Issue priority](../guides/working-with-pullwright/README.md#issue-priority) and requirement 16.4 in the spec). The login shown is this installation's own maintainer, not a generic default — every installation names its own. |
| `enabler_after_coordinator_cycles` | `3` | How many cycles that actually ran a Co-Ordinator must pass, after an item is blocked, before the Enabler looks at it. Counting cycles rather than hours means a fleet that spent the night stood down on a usage limit has not "waited". |
| `refinement_after_coordinator_cycles` | *(same as `enabler_after_coordinator_cycles`)* | The same wait, but for an item the pipeline recorded as too under-specified to work on (an issue picks up the `needs-refinement` label) rather than one blocked by something in the world. Left unset it waits exactly as long as any other block; set it separately once fleet behaviour tells you refinement items should age faster or slower. |
| `enabler_recheck_hours` | `72` | Hours before the Enabler re-examines an item it has already examined. This is the bound on how long new evidence — a diagnosis posted into the very thread whose absence blocked the item — can sit unread. `0` switches re-examination off. |
| `enabler_escalation_label` | `pw::enabler-escalation` | Label applied to every issue the Enabler raises, for your filters and for its own duplicate check. The pipeline creates it in every repository it gathers data for, not only the one it happens to work, at most once per `labels_ensure_interval_hours` — so there is nothing to set up; without it the issue is still raised, just unlabelled. |
| `escalation_autonomy` | `decide-with-veto` | The D18 escalation-autonomy ladder, four rungs, each including the one below it (with one exception, below): `always-escalate` (today's behaviour — every Enabler escalation goes straight to a human), `adjudicate-first` (one bounded Enabler adjudication pass runs first, but only over a refinement disagreement; it either confirms the earlier refinement or escalates anyway), `decide-tactical` (one bounded Enabler decide pass runs first over *any* escalation — an ordinary blocked...[continued below](#extended-notes-escalation_autonomy) |
| `escalation_adjudication_max_passes` | `3` | How many `decide-tactical` passes one item may spend since its last human touch, whatever their reason — or ever, if it has had none — see [Blocked items and the Enabler](../guides/operating/diagnose-by-symptom.md#an-item-is-blocked-or-void). A fresh reason still gets its own pass under this cap, and closing an escalation about the item resets the budget in full rather than granting one further pass on top of a lifetime total; only a run of unrelated tactical questions on the...[continued below](#extended-notes-escalation_adjudication_max_passes) |
| `standing_decisions_file` | `docs/STANDING-DECISIONS.md` | The installation's standing-decisions file: one dated line per answer you have given the pipeline, which its `decide-tactical` pass reads before deciding anything, so a question you have already answered is answered the same way again rather than escalated — see [Blocked items and the Enabler](../guides/operating/diagnose-by-symptom.md#an-item-is-blocked-or-void). Relative to the installation directory unless absolute. Leave it empty to supply none; the pass still sees the...[continued below](#extended-notes-standing_decisions_file) |
| `decision_veto_window_hours` | `24` | Hours a `decide-with-veto` decision that carries an *act* — closing an abandoned draft behind its void — waits before the act is taken, so you can veto it by reopening the decision's log issue *before* anything happens rather than after. `0` acts on the next cycle. A decision that merely accepts something (no act) is unaffected: it takes effect at once, and reopening its log issue is still the correction. Only `escalation_autonomy: decide-with-veto` can produce an act at all...[continued below](#extended-notes-decision_veto_window_hours) |
| `escalation_refile_after_hours` | `24` | Hours a human's own close of an escalation issue suppresses the *next* filing for the same item (`open_question_escalate`/requirement 8f, `approver_escalate`/requirement 8c) — closing the issue is not the releasing act, so without this guard a human who closes without also releasing the gate gets a fresh issue every refusing round. `0` disables the guard: every refusing round files, as before this key existed. A re-escalation a failed post-close adjudication owes always files...[continued below](#extended-notes-escalation_refile_after_hours) |
| `needs_refinement_label` | `pw::needs-refinement` | Label put on an **issue** while the pipeline has it recorded as too under-specified to work on, and taken off again when that clears — see [Items nobody has specified](../guides/operating/diagnose-by-symptom.md#an-item-is-blocked-or-void). You can also apply it yourself to flag one directly; the pipeline reads that back the same way. The pipeline creates it in every repository it gathers data for, not only the one it happens to work, at most once per...[continued below](#extended-notes-needs_refinement_label) |
| `refinement_max_per_engagement` | `3` | How many under-specified items one Enabler engagement will take on. Ordinary blocked items are never displaced by them, and items over the cap simply wait for a later engagement. `0` switches the refinement work off while still recording it. |
| `refiner_model` | `claude-sonnet-5` | The Refiner: writes a specification for an item nobody has scoped yet and marks it `refined`, before it would otherwise have to be blocked and wait for the Enabler — see [Refined items and the Refiner](../guides/operating/configure.md#work-source-controls). Engaged every cycle there is unrefined work to do, so how often it runs and how good it has to be pull against each other: what it writes is the brief an Implementer works from. Leave it empty to switch the stage off. |
| `refined_label` | `pw::refined` | Label put on an **issue** once the Refiner has written it a specification — see [Refined items and the Refiner](../guides/operating/configure.md#work-source-controls). Purely informational: nothing reads it back, so removing it by hand does nothing. The pipeline creates it in every repository it gathers data for, not only the one it happens to work, at most once per `labels_ensure_interval_hours` — so there is nothing to set up. Leave it empty to switch the labelling off; the...[continued below](#extended-notes-refined_label) |
| `refiner_max_per_engagement` | `5` | How many unrefined items one Refiner engagement will write specifications for. Items over the cap simply wait for a later engagement. `0` switches proactive refinement off — if any `refinement_policy` source is `required` when it does, that source's items wait, unlabelled, until the cap is raised again; `agent-cycle.sh` logs a warning and `doctor.sh` warns about it every cycle, rather than refusing to start. |
| `refinement_policy` | `{"issues": "required", "tech-debt": "required"}` | Per source: `required` (never select unrefined), `preferred` (rank refined items first, but an unrefined one may still be picked), or `exempt` (no refinement dimension — the default for every source not listed). Shipped default: `issues` and `tech-debt` both `preferred` — the two sources whose items can otherwise carry a specification the Co-Ordinator composed itself rather than one already written elsewhere (a merge conflict, a review comment, a security finding). See...[continued below](#extended-notes-refinement_policy) |
| `unvoid_label` | `pw::unvoided` | The label you apply on GitHub to ask for a voided item to be reopened — see [Blocked and void items](../guides/operating/diagnose-by-symptom.md#an-item-is-blocked-or-void). No stage ever applies it, so "only a human may clear a void" still holds; this is just a way to say so from the issue itself. The pipeline creates it in every repository it gathers data for, not only the one it happens to work, at most once per `labels_ensure_interval_hours`; `scripts/doctor.sh` warns...[continued below](#extended-notes-unvoid_label) |
| `labels_ensure_interval_hours` | `24` | How often, in hours, the pipeline re-lists a repository's labels to create any that are missing (installation step 4, below). Every repository the cycle gathers data for gets this, not only the one it works, so a label you delete comes back within this interval rather than only the next time that repository happens to be selected. `0` re-lists on every cycle. |
| `label_prefix` | `pw::` | Namespace prefix for labels the pipeline fully owns, colour, description and existence kept in sync with configuration rather than only ever created once — see `lib/labels.sh`'s `labels_reconcile`. Every other label keeps today's create-only behaviour, so an operator's own colour/description choice is never undone. Leave it empty to disable reconciliation and deletion entirely. |
| `void_retire_after_days` | `30` days | Days a voided item sits fully actioned — its issue or pull request closed, or its tech-debt register row flipped to `resolved`/`not-debt` — before the pipeline stops carrying it in the void extract. This does not touch whether the item is void (still forever, still only a human's `unvoided` label undoes it, see [Blocked and void items](../guides/operating/diagnose-by-symptom.md#an-item-is-blocked-or-void)); it only stops an old, settled verdict from being handed to the...[continued below](#extended-notes-void_retire_after_days) |
| `reservation_release_stuck_after_days` | `14` days | Days a reservation-release marker (a `td/<id>`/`td-record/<id>` branch delete a cleanup could not land) may keep failing its retried delete before the sweep treats it as permanently stuck — an archived target repository, a protected branch, a login that lost push access — rather than retrying and warning identically forever. Past this age, the marker escalates exactly once, as a distinct `reservation-release-stuck` event rather than the recurring `warning`, and keeps retrying...[continued below](#extended-notes-reservation_release_stuck_after_days) |
| `prompt_overrides` | `{}` | Add house rules to a stage's operating prompt, or replace it outright, without forking `prompts/`. The Approver's prompt takes no override — it is the trust gate the merge-autonomy ladder rests on. `implementer` and `reviewer` may additionally be scoped to one repository via that repository's own `repos[].prompt_overrides` entry — see "Configuration" above. See [Prompt overrides](#prompt-overrides). |
| `pr_label` | `pw::agent` | Applied to every PR this system raises. Do not name it `obsolete`, which is reserved for a human to mark one of these PRs as unwanted. The claim loop stamps this value onto every work order's own `pr_label` field, guaranteed regardless of the Co-Ordinator's own output, and the Implementer labels its pull request with it. |
| `branch_prefix` | `agent/` | Branch naming: `agent/<item-slug>`. |
| `max_open_agent_prs` | `8` | Back-pressure limit: draft PRs, changes-requested PRs and claims across all configured repositories — not PRs only waiting on approval or merge. |
| `candidates_max` | `3` | How many ranked candidates the Co-Ordinator returns; the Script claims down the list, so a lost race costs the next-best item rather than the cycle. |
| `coordinator_prompt_max_bytes` | `500000` | The largest assembled prompt the Script will hand the Co-Ordinator. What a context window rejects is the whole prompt, not the runtime input alone, so the Script measures the rendered base prompt, subtracts it, and trims the two bands that carry a whole document each — an issue's entire thread and a tech-debt issue's entire thread — into what is left. Prose is shed and candidacy is not: every entry stays selectable, and every cut carries a marker naming how many bytes went...[continued below](#extended-notes-coordinator_prompt_max_bytes) |
| `max_chained_cycles` | `3` | The most cycles that may run back-to-back in one lineage — the cron-fired original plus its immediate continuations, instead of each waiting for the next cron firing. A productive cycle chains to this cap regardless of remaining work (the remaining-sources gate counts enabled source categories, which back-pressure never empties) — up to `max_chained_cycles − 1` further full Co-Ordinator passes, the accepted price of the drain rate. `1` disables chaining. |
| `claim_ttl_hours` | *(unset)* | Hours before a dead node's claim-registry entry is swept (`lib/claim.sh gc`) — derived from `schedule.cycle_interval_minutes` to stay 6 firings wide at whatever cadence is configured, floored at a cycle's own worst-case runtime so a fast cadence cannot derive it below that (requirement 1d); a configured value floors it, never caps it. |
| `abandoned_draft_after_hours` | *(unset)* | Hours a draft PR this system raised may sit untouched before it counts as abandoned and finishing it becomes selectable work (the `abandoned-drafts` source) — derived from `schedule.cycle_interval_minutes` to stay 4 firings wide at whatever cadence is configured, floored at a cycle's own worst-case runtime so a fast cadence cannot derive it below that (requirement 1d); a configured value floors it, never caps it. Also the staleness threshold `scripts/sweep-orphan-branches.sh` uses. |
| `human_nudge_idle_hours` | `24` | Hours an approved, green pull request may sit idle — nothing left for the pipeline to do, only a merge click nobody was asked for — before `scripts/sweep-human-visibility.sh` posts one nudge comment naming `enabler_assignee`. `0` disables the nudge; the sweep still keeps a live review request on every such PR regardless (see [Configuration](#configuration) → `enabler_assignee`). |
| `merge_queue_dequeue_notice_max_age_hours` | `24` | Hours a merge-queue-dequeue notice comment (`scripts/sweep-human-visibility.sh`, requirement 38f) may still fire for after the removal event's own time — bounds the notice to genuinely new information rather than an event a sweep is only now seeing for the first time. `0` disables the notice entirely, at the cost of losing the only human signal this pipeline raises for a merge-group failure. |
| `merge_autonomy` | `human` | The D18 merge-autonomy trust ladder: `human` (today's behaviour — a human approves and merges), `agent-approves` (the Approver App reviews; a human still merges), `agent-merges-routine`/`agent-merges-all` (the Script itself lands an eligible pull request — see `merge_autonomy_routine_sources` — and a human's residual act narrows to whatever the classifier refused). A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). Every...[continued below](#extended-notes-merge_autonomy) |
| `merge_budget_per_day` | `8` | D18's spend governor: a rolling-24-hour cap on pull requests this pipeline may land in one repository, counted from GitHub's own merged-PR record. A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). `0` means unlimited. Reaching the cap approves a pull request but does not merge it — the backlog queues visibly; landing more than the cap is a counting anomaly that freezes the repository to `agent-approves` and escalates to a human. |
| `merge_autonomy_routine_sources` | `["tech-debt"]` | D18 WI-7: which work sources may be armed automatically at `agent-merges-routine` and above — a pull request also needs a `complexity:*` grade in `merge_autonomy_routine_complexity`, and — below `agent-merges-all` — to touch no protected path; at `agent-merges-all` a protected-path hit is deferred to the critical-tier and `landing_cool_off_hours` controls rather than refused. A `repos[]` entry may override this per repository — see...[continued below](#extended-notes-merge_autonomy_routine_sources) |
| `merge_autonomy_protected_paths` | `[".github/*", "deploy/*", "prompts/*", "lib/*", "config.schema.json", "config.json", "agent-cycle.sh", "review-cycle.sh", "CODEOWNERS"]` | D18 Stage 3: the whole-path prefixes a routine-tier landing must touch none of — below `agent-merges-all` a hit refuses outright; at `agent-merges-all` it is deferred to the critical-tier and `landing_cool_off_hours` controls instead. An entry ending `/*` matches a whole-path prefix; any other entry matches an exact path. A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). Defaults to agent-ops's own gate paths, which...[continued below](#extended-notes-merge_autonomy_protected_paths) |
| `merge_autonomy_routine_complexity` | `["low", "medium"]` | D18 Stage 3: which `complexity:*` grades may be armed automatically at `agent-merges-routine` and above — a pull request also needs a `source` in `merge_autonomy_routine_sources`, and — below `agent-merges-all` — to touch no protected path. A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). Widening past the default to include `high` is a bigger step than it looks: requirement 26a already forces `high` onto the riskiest...[continued below](#extended-notes-merge_autonomy_routine_complexity) |
| `landing_cool_off_hours` | `24` | D18 WI-12 (Stage 4): the wait, in hours, between the Approver's own approval of a protected-path pull request and the arming step landing it — only at `agent-merges-all`, and only alongside the critical-tier control. Measured from the standing review's own timestamp, re-read fresh every cycle; a fresh push restarts it, since the standing review's own commit no longer matches the pull request's current head. A `repos[]` entry may override this per repository — see...[continued below](#extended-notes-landing_cool_off_hours) |
| `approver_app_id` | *(unset)* | The Pullwright Approver GitHub App's id. Every `merge_autonomy` level above `human` needs it set, and `scripts/doctor.sh` fails the config otherwise. `doctor.sh` also cross-checks it against the node's `PULLWRIGHT_APPROVER_APP_ID` environment, so the id the token wrapper mints against can never silently differ from the one recorded here. One id for the whole App identity: which of that App's installations mints a given repository's token is resolved separately, per repository...[continued below](#extended-notes-approver_app_id) |
| `crash_loop_after` | `4` | Consecutive failures, with no intervening recovery, before the Script files a crash-loop escalation issue — either same-detail Co-Ordinator failures (counted per repository, plus a fleet-wide fallback group for a repo-less event), or same-exit-code cycles that died before any stage started (fleet-wide). Neither class blames an item, so without this nothing ever surfaces a deterministic Co-Ordinator failure — the dashboard shows a healthy idle fleet. `0` (or absent) disables both checks. |
| `crash_loop_repo` | `Pullwright/agent-ops` | Where the crash-loop escalation issues are filed — the pipeline's own repository, i.e. whichever repository you run this pipeline from. Deduplicated like an Enabler escalation and assigned to `enabler_assignee`, so the pipeline never selects its own SOS as work. Empty disables both checks. The value shown is this installation's own repository, not a generic default — every installation names its own. |
| `crash_loop_min_clear_minutes` | `30` | Minutes a crash-loop escalation's clearing success must hold, under the same detail and in that run's own repository (fleet-wide for the repo-less fallback group), before the Script closes the issue — hysteresis against a flapping condition opening a fresh issue every time it dips back below the failure threshold. `30` (two of `schedule.cycle_interval_minutes`'s own default 15-minute firings) gives a recurrence time to reach this node's own union before the success is...[continued below](#extended-notes-crash_loop_min_clear_minutes) |
| `escalation_webhook_url` | *(unset)* | An alias for `notify_webhook_url`, accepted for one release. Set it and `doctor.sh` will warn — rename it to `notify_webhook_url` before the alias is removed. Empty (the default) contributes nothing. |
| `notify_webhook_url` | *(unset)* | The URL every notification POSTs to — every escalation issue filed or auto-closed, every `pager-fired`/`pager-cleared`, and every fleet-wide stand-down beginning or ending — one compact JSON body per event, gated by `notify_events` and coalesced by `notify_min_interval_seconds`. `escalation_webhook_url` is accepted as an alias for one release; `doctor.sh` warns if that is the only one set. The `NOTIFY_WEBHOOK_URL` environment variable wins over both, and is the non-public...[continued below](#extended-notes-notify_webhook_url) |
| `notify_events` | `["escalation", "pager", "fleet-standdown"]` | Which notification classes actually POST: `escalation`, `pager` and `fleet-standdown`, all on by default. Drop one to quiet it without losing the others — a class not listed here is silently skipped before the webhook is even read. |
| `notify_min_interval_seconds` | `600` | How long, per notify event *and* key, between two pushes — so a fact that keeps repeating (the same dead-credential escalation refiling every cycle) arrives as one message and a count, not one per cycle, while the `end` of a stand-down is never swallowed by the `begin` that shares its key. `0` disables coalescing outright: every eligible event posts. |
| `pager_enabled` | `true` | Whether the pager framework evaluates its fleet-level invariants at all. `true` by default — the dashboard's own fired/cleared history and banner are worth having even on an installation with no `pager_repo` configured to file into. |
| `pager_repo` | *(unset)* | Where the pager framework's own `pw::pager` issues are filed. Empty (this installation's own choice, left unset) falls back to `crash_loop_repo` at read time — which for this installation already resolves to `Pullwright/agent-ops` — rather than repeating that value here for two config keys to keep in step. |
| `pager_min_firing_minutes` | `15` | Minutes. How long a fleet-level invariant must stay firing before the pager framework files anything — hysteresis against a blip that clears on its own. `0` files on the first firing evaluation. |
| `pager_stale_file_after_minutes` | `180` | Minutes. How long the dashboard's `node-stale` pager invariant waits, continuously firing, before opening a tracking issue — longer than `pager_min_firing_minutes` on purpose: the underlying fact (a node's publication age already past twice `node_stale_after_minutes`) is itself slow to form. |
| `pager_dashboard_fetch_seconds` | `30` | Seconds. How long a viewer may take fetching a node's `data.js` before the dashboard's `dashboard-unreadable` pager invariant treats it as unreadable from that viewer's vantage — a failed parse trips it regardless of how fast it answered. |
| `pager_idle_cycles` | `6` | How many of a node's own most recent cycles must all have ended idle with real demand waiting (excluding a deliberate back-pressure throttle) before the dashboard's `idle-with-demand` pager invariant fires. |
| `pager_repair_rate_percent` | `20` | Percent. How much of a trailing 24h's selections may need a work-order-repaired repair before the dashboard's `work-order-repaired-rate` pager invariant fires. |
| `pager_escalation_burst` | `10` | How many escalations may be filed fleet-wide in a trailing 24h before the dashboard's `escalation-burst` pager invariant fires — independently of a re-flagged item's own repeat inside that window, which always fires it. |
| `pager_landing_armed_within_days` | `7` | Days. How long a repository configured at merge_autonomy agent-merges-routine or above may go with zero landing-armed events, despite landing-refused activity in that same window, before the dashboard's `landing-never-armed` pager invariant fires. |
| `monitor_model` | `claude-sonnet-5` | The Pipeline Monitor: one scheduled read of the pipeline's own state, producing a dated report and at most `monitor_max_filings_per_run` filings — see [The Pipeline Monitor](../guides/operating/watch.md#the-pipeline-monitor). Leave it empty to switch the pipeline off. |
| `monitor_max_input_bytes` | `300000` | The largest digest the Script will hand the Pipeline Monitor. The Monitor never reads the fleet log or `data.js` itself; it reads this digest, and the Script bounds it by shedding samples and the specs' gotcha sections before it ever truncates. `0` disables the bound. |
| `monitor_max_filings_per_run` | `3` | The most items one monitor run may file (tech-debt issues, `pw::decision` records and escalations together). Everything past the cap is deferred, named in the report with its finding key, and offered again next run. `0` files nothing and reports everything. |
| `monitor_tactical_keys` | `[]` | The configuration keys the Monitor may decide on its own authority, recorded as a `pw::decision` a human vetoes by reopening. Empty (the default) means it proposes tactical levers in its report and moves none. |
| `monitor_promote_after` | `2` | How many Monitor reports must restate the same finding key before the Script turns it into a `pager: add invariant <key>` tech-debt issue and marks the key `promoted`, so the model stops re-reporting it. `0` disables promotion. |
| `timeout_coordinator` | *(unset)* | Minutes, and an override. Leave it out — the backstop tunes itself, and a key set here outranks the derivation for as long as it is there. A repo entry's own `stage_timeouts` outranks this key in turn, for that repo alone — see [`repos`](#extended-notes-repos). |
| `timeout_implementer` | *(unset)* | Minutes, and an override. As above. |
| `timeout_reviewer` | *(unset)* | Minutes, and an override. As above. |
| `timeout_enabler` | *(unset)* | Minutes, and an override. As above. |
| `timeout_refiner` | *(unset)* | Minutes, and an override. As above. |
| `timeout_approver` | *(unset)* | Minutes, and an override. As above. |
| `inactivity_coordinator` | *(unset)* | Minutes of total silence before the stage is treated as wedged, and an override. Omit it — the threshold is derived; `0` disables the watchdog. A repo entry's own `stage_inactivity` outranks this key in turn, for that repo alone — see [`repos`](#extended-notes-repos). |
| `inactivity_implementer` | *(unset)* | Minutes of total silence before the stage is treated as wedged, and an override. Omit it — the threshold is derived; `0` disables the watchdog. |
| `inactivity_reviewer` | *(unset)* | Minutes of total silence before the stage is treated as wedged, and an override. Omit it — the threshold is derived; `0` disables the watchdog. |
| `inactivity_enabler` | *(unset)* | Minutes of total silence before the stage is treated as wedged, and an override. Omit it — the threshold is derived; `0` disables the watchdog. |
| `inactivity_refiner` | *(unset)* | Minutes of total silence before the stage is treated as wedged, and an override. Omit it — the threshold is derived; `0` disables the watchdog. |
| `inactivity_approver` | *(unset)* | Minutes of total silence before the stage is treated as wedged, and an override. Omit it — the threshold is derived; `0` disables the watchdog. |
| `lock_stale_after` | *(unset)* | Hours, and a floor rather than the value. The threshold is derived from the stage backstops plus slack, so it moves with them; set this only to insist on something longer. |
| `stage_budget` | *(unset)* | Tuning for how the stage budgets derive themselves. Every key has a default in the code and none of them is a timeout; you almost certainly want none of it. |
| `limit_cooldown_default` | `3` | Hours. Stand-down after a usage-limit error. |
| `limit_escalate_after_hours` | `24` | Hours. How long an automatic usage-limit stand-down may run before an escalation issue is filed; `0` turns it off. A manual stand-down never escalates. |
| `github_min_core_budget` | `300` | GitHub REST points a cycle must have left before it starts. `0` turns the check off for this resource. |
| `github_min_graphql_budget` | `100` | GitHub GraphQL points a cycle must have left before it starts. `0` turns the check off for this resource. |
| `github_retry_max_wait_seconds` | `60` | Seconds. How long a single `gh` call may wait out a rate-limit refusal before failing; a process may spend twice this in total. `0` turns retrying off. |
| `min_free_workspace_bytes` | `2147483648` | Bytes. The floor under the free-space threshold `state_dir` and `workspace_root` must each clear before a cycle starts one — `workspace_headroom_factor` can derive a higher threshold above it, never below. Below the effective threshold on either the cycle stands down first. `scripts/doctor.sh` warns on the same floor. `0` turns the check off outright. |
| `workspace_headroom_factor` | `2` | The multiplier over the largest recorded clone footprint that can raise the free-space floor above `min_free_workspace_bytes` (requirement 2.0c). `0`, or no footprint ever recorded, leaves the plain floor governing. |
| `min_free_memory_bytes` | `536870912` | Bytes. Memory the host must have available before a cycle starts one; below it the cycle stands down before any stage runs. `scripts/doctor.sh` warns on the same floor. `0` turns the check off. |
| `host_budget_enforce` | *(unset, defaults to `false`)* | Whether requirement 2.0g's host-budget check (issue #757) refuses to start a cycle when the declared container ceilings on this host overcommit it, or only publishes the figures. `false` by default — advisory, not enforced; set `true` once an installation has confirmed the declared sum actually fits. |
| `host_budget_reserved_memory_bytes` | `536870912` | Bytes. Memory margin the host-budget check (issue #757) holds back for the host/VM itself, beyond the sum of every running container's declared ceiling. Only matters when `host_budget_enforce` is `true`. |
| `host_budget_reserved_cpus` | `0` | CPU cores. Margin the host-budget check (issue #757) holds back for the host itself, beyond the sum of every running container's declared `cpus:` ceiling. `0` by default. Only matters when `host_budget_enforce` is `true`. |
| `disable_default_ttl` | *(unset)* | Hours. How long `--disable` lasts when neither `--for` nor `--until` says, derived from `schedule.cycle_interval_minutes` to stay 4 firings wide at whatever cadence is configured (requirement 1d); a configured value floors it, never caps it. See [Pausing the pipelines](../guides/operating/run-and-pause.md#the-disableenable-switch). |
| `none_selected_recheck_hours` | *(unset)* | Hours. The Co-Ordinator is engaged at least this often even when nothing has changed — derived from `schedule.cycle_interval_minutes` to stay 24 firings wide at whatever cadence is configured (requirement 1d); a configured non-zero value floors it, never caps it. See [Skipping no-op cycles](../guides/operating/run-and-pause.md#staying-warm-without-spending). `0` disables that safety net entirely — not recommended — and is never raised by the derivation. |
| `image_behind_grace_hours` | `3` | Hours a node may sit behind the newest published image before the dashboard's **image behind** badge turns amber and `scripts/check-node-image.sh` exits non-zero. A roll defers while a cycle is in flight, so being behind an image published more recently than this is the ordinary mid-roll state. See [Is this node on the newest image](../../deploy/docker/README.md#is-this-node-on-the-newest-image). |
| `updater_stuck_after_minutes` | `20` | Minutes a container may still be the one that was told to roll before the dashboard's **updater stuck** badge turns amber (`deploy/docker/watchtower-pre-update.sh`, `lib/updater-health.sh`). Comfortably beyond one watchtower poll (`WATCHTOWER_POLL_INTERVAL`, 300s) plus an image pull, so an ordinary roll never trips it. |
| `node_health_live_stale_after_minutes` | `3` | Minutes the liveness marker may age before `scripts/node-health.sh --live` (and the container healthcheck it backs) reports the node not live. A few missed minute-ticks, never the cycle lock. |
| `node_health_forge_check_cache_seconds` | `30` | Seconds `scripts/node-health.sh --ready` caches its one GitHub rate-limit read before refreshing it, so polling readiness cannot itself become a load source. |
| `node_stale_after_minutes` | `30` | Minutes a node's last confirmed publication into the shared state may age before the dashboard's fleet strip (and `scripts/doctor.sh`) call it stale, applied identically to a peer's row and to a node's own. Roughly three missed heartbeat/fetch cycles at the shipped cadence. |
| `dashboard_refresh_seconds` | `5` | Seconds. How often an open dashboard tab polls for freshly-written data, matching the [heartbeat](../guides/operating/watch.md#keep-the-dashboard-fresh) cadence — it fetches a small stamp every tick and the full payload only when the stamp says it changed. Untick the page's *auto-refresh* box to pause it while reading. |
| `schedule.cycle_hours` | `*` | The hour field of the containerised node's implementation-cycle crontab line (`deploy/docker/render-crontab.sh`); `*` means every hour. |
| `schedule.cycle_interval_minutes` | `15` | Minutes between implementation-cycle firings within an allowed hour (the no-op short-circuit keeps an idle firing cheap); `60` fires once per hour, as every release before this key existed. |
| `schedule.excluded_minutes` | `[0]` | Minutes the per-node `CYCLE_MINUTE` (env or hash) may never land on. This repo's own config excludes `0` because poetic's hourly sync workflow owns the top of the hour; a fresh install with no such conflict should ship `[]`. |
| `schedule.excluded_minutes_reason` | see `config.json` | Free-text note on *why* `excluded_minutes` excludes what it does — documentation only, read by nobody. |
| `schedule.review_hour` | `3` | The hour the containerised node's review tick fires. |
| `schedule.review_offset_minutes` | `29` | Minutes past `CYCLE_MINUTE` (mod 60) the review tick's minute is set to, so the node's two heavy pipelines land apart within the hour. |
| `schedule.heartbeat_minutes` | `5` | Interval, in minutes, of the containerised node's dashboard-heartbeat cron line. |
| `schedule.state_sync_push_minutes` | `5` | Interval, in minutes, of the containerised node's `state-sync.sh push` line. |
| `schedule.state_sync_fetch_minutes` | `7` | Interval, in minutes, of the containerised node's `state-sync.sh fetch` line. |
| `schedule.wake_poll_minutes` | `2` | Interval, in minutes, of the containerised node's wake-poll cron line (`scripts/wake-poll.sh`, issue #613) — how often it checks for a source-relevant change and wakes an idle node between ordinary cycle firings. |
| `schedule.resource_sample_minutes` | `5` | Interval, in minutes, of the containerised node's resource-usage sampling (`scripts/collect-resource-usage.sh`, issue #606) — a cheap cgroup/proc tick; disk sampling is throttled separately by `resources.disk_sample_interval_minutes`. |
| `schedule.log_rotation_minute` | `19` | The minute past every hour the containerised node's `rotate-logs.sh` line runs. |
| `schedule.doctor_offset_minutes` | `44` | Minutes past `CYCLE_MINUTE` (mod 60) the hourly unattended `doctor.sh` pass's minute is set to (agent-ops#543), on the same per-node jitter `review_offset_minutes` uses. |
| `schedule.revert_rate_hour` | `2` | The hour the containerised node's daily revert-rate publishing tick (`scripts/publish-revert-rate.sh`, agent-ops#579) fires. |
| `schedule.revert_rate_offset_minutes` | `51` | Minutes past `CYCLE_MINUTE` (mod 60) the daily revert-rate publishing tick's minute is set to (agent-ops#579), on the same per-node jitter `doctor_offset_minutes` uses. |
| `schedule.tech_debt_archive_hour` | `4` | The hour the containerised node's daily tech-debt archive publishing tick (`scripts/publish-tech-debt-archive.sh`, agent-ops#878) fires. |
| `schedule.tech_debt_archive_offset_minutes` | `37` | Minutes past `CYCLE_MINUTE` (mod 60) the daily tech-debt archive publishing tick's minute is set to (agent-ops#878), on the same per-node jitter `revert_rate_offset_minutes` uses. |
| `schedule.changelog_roll_hour` | `6` | The hour the containerised node's weekly CHANGELOG.md roll (`scripts/roll-changelog.sh`, agent-ops#1809) fires. |
| `schedule.changelog_roll_offset_minutes` | `13` | Minutes past `CYCLE_MINUTE` (mod 60) the weekly CHANGELOG.md roll's minute is set to (agent-ops#1809), on the same per-node jitter `tech_debt_archive_offset_minutes` uses. |
| `schedule.changelog_roll_day_of_week` | `1` | The day of week the containerised node's weekly CHANGELOG.md roll fires, cron's own convention (`0`-`6`, Sunday is `0`); the product default (`1`) is Monday. |
| `schedule.monitor_hour` | `5` | The hour the containerised node's daily Pipeline Monitor run is due (`monitor-cycle.sh`). Its crontab line fires hourly and stands down unless this hour's daily run is still owed, or a pager page fired since the last run. |
| `schedule.monitor_offset_minutes` | `19` | Minutes past `CYCLE_MINUTE` (mod 60) the hourly Pipeline Monitor tick's minute is set to, on the same per-node jitter `doctor_offset_minutes` uses. |
| `revert_rate_baseline` | `{"source": "docs/reviews/2026-08-15-merge-autonomy-baseline.md", "generated": "2026-08-15", "repos": [{"slug": "Poetic-Poems/poetic", "count": 84, "reverts": 0, "follow_up_fixes": 31}, {"slug": "Poetic-Poems/poetic-fiddle", "count": 119, "reverts": 0, "follow_up_fixes": 44}, {"slug": "Pullwright/agent-ops", "count": 120, "reverts": 0, "follow_up_fixes": 106}]}` | The D18 Stage 0 merge-autonomy baseline, copied once from `docs/reviews/2026-08-15-merge-autonomy-baseline.md` rather than re-derived — `scripts/publish-revert-rate.sh` compares every window's rate against it. A fresh install ships no baseline until Stage 0 records one. The value shown is this installation's own baseline, not a generic default — a fresh install records its own at Stage 0. |
| `resources` | see `config.json` | Per-container and per-volume budgets D14 compares measured actuals against (`scripts/doctor.sh` warns on a breach; the dashboard renders the comparison per node). `memory_bytes`/`cpu_cores` mirror `deploy/docker/compose.yaml`'s own `mem_limit`/`cpus`, which remain the enforcement mechanism; `bandwidth_bytes_per_hour` and every `disk_bytes` are provisional, set before any real fleet window existed. |
<!-- config-table:end -->

Every `*_model` key above, plus `repository_review.defaults.model` (or a repo's
own override) below, also accepts a
provider-qualified id — `anthropic/claude-sonnet-5` alongside the bare
`claude-sonnet-5` — with identical behaviour; the qualifier is optional
because Anthropic is the only executable provider today. A qualifier naming
any other provider is rejected at cycle start with an error naming the key,
not passed to the `claude` CLI. No existing config needs to change.

The `repository_review` object configures the separate repository-review pipeline — see [Repository review](../guides/operating/watch.md#the-pipeline-monitor).

<!-- config-table:notes id=main — GENERATED from config.schema.json by scripts/render-config-table.sh; edit the schema, not this section -->

### Extended notes: `repos`

Array of `{"slug": "...", "sources": [...]}`. `sources` is that repo's work sources in priority order (`security`, `issues:urgent`, `review-feedback`, `merge-conflicts`, `dequeued`, `landing-refusals`, `human-visibility`, `abandoned-drafts`, `failed-runs`, `issues:high`, `tech-debt`, `issues:medium`, `implementation-plan`, `project-review`, `issues:low`, `code-quality`).

- `security` (open Dependabot + security code-scanning alerts) is always first, and any security-related item is prioritised ahead of all non-security work.
- `issues:urgent` comes second and likewise outranks the repo walk, because an issue you have marked `Urgent` is the strongest thing you can say short of a security alert.
- `review-feedback` (agent PRs where you asked for changes we haven't answered yet) comes third and also outranks the repo walk — finishing beats starting, and a stuck PR otherwise occupies a back-pressure slot forever.
- `merge-conflicts` (agent PRs otherwise ready for review or merge but conflicting with their base) comes fourth for the same reason — a rebase-and-resolve unblocks a PR you are waiting to land, and nothing else on it can proceed until it merges cleanly.
- `dequeued` (agent PRs GitHub's merge queue removed over a merge-group checks failure without merging) comes fifth, alongside `merge-conflicts`: a real defect in the pull request itself, of the same "finishing beats starting" kind, just surfaced by the queue's speculative merge rather than by git.
- `landing-refusals` (agent PRs the Script's own landing gate keeps declining to arm over an unreconciled human comment) comes sixth, immediately after `dequeued`: a human veto sitting unanswered on an otherwise-ready pull request is the same "finishing beats starting" gap, just raised by the pipeline's own arming step rather than by GitHub.
- `human-visibility` (an agent PR the sweep could not confirm a human was actually asked to review, or nudge, after `human_nudge_idle_hours` idle) comes seventh: finished work invisible to the human whose merge everything waits on is the same "finishing beats starting" gap.
- `abandoned-drafts` (draft PRs this system raised and then left untouched past `abandoned_draft_after_hours`) comes eighth for the same reason — finishing a stalled draft of ours turns a slot silted with a dead draft into a PR you can merge.
- `project-review` (the latest repository review's recommendations that aren't already tech-debt or issues) sits just above `issues:low` and `code-quality` (non-security code-scanning findings), which are last.

The four `issues:<band>` tokens are the *same* source at four ranks, banded by each issue's `Priority` field — see [Issue priority](../guides/working-with-pullwright/README.md#issue-priority); list a subset to have the pipeline see only those bands, or none to turn issues off for that repo. Adding a repo or source is a config-only change.

At runtime, repos are ordered most-overdue first — each repo's default-branch staleness age scaled by `2^(-nice/3)` — ahead of this list order; with no `nice` set anywhere that is least-recently-updated first, exactly as before.

A repo entry that lists `implementation-plan` must also carry `implementation_plan_path` — the path, relative to that repo's root, of its plan document; the Co-Ordinator reads whatever this says, so a repo with a differently named or located plan needs no prompt change, only its own path. The Script refuses to start a cycle if a repo lists the source without it — a repo that doesn't list `implementation-plan` needs no such key. (This installation's own poetic-fiddle entry uses `docs/IMPLEMENTATION-PLAN.md`, shown below as a worked example — there is no product default for the path itself.)

A repo entry may also carry `nice` — an optional integer from `-19` to `19` (absent means `0`), after Linux `nice`: each repo's default-branch staleness age is multiplied by `2^(-nice/3)` (each three steps of `nice` is a 2x change in attention), so a negative value buys the repo earlier attention and a positive one later. It biases the walk but never starves a repo — the global tiers still outrank the walk, and a repo that alone has qualifying work is selected regardless of its `nice`. The Script refuses to start a cycle if `nice` is not an integer in that range.

A non-zero `nice` shows as a badge against that repo in the dashboard's work-sources panel, naming the value and the weighting it buys; a repo at `0` or with no key shows nothing there, so a fleet that has set none sees the panel unchanged.

A repo entry may also carry `previous_slugs` — the slugs this repository was known as before a rename (e.g. an organisation move), each as `owner/name`. A blocked item recorded with one of these as its `repo` is resolved to this entry's own `slug` before the Script looks it up in any digest, so a block predating the rename still clears once the issue it names is closed or the pull request it names merges, rather than staying blocked forever because the digest the cycle gathers is always keyed by the current `slug`. This affects only that lookup: the pipeline always acts against the current `slug` everywhere else, and a renamed repository needs no other config change.

A repo entry may also carry `stage_timeouts` and `stage_inactivity` — the per-repo form of the `timeout_<actor>` and `inactivity_<actor>` keys below, each an object in minutes keyed `coordinator`, `implementer`, `reviewer`, `approver` and `enabler`, any subset of them. The Refiner spans repos, so it has no per-repo form and takes `timeout_refiner` / `inactivity_refiner` only. A repo's entry is the most specific level of the precedence — this entry, then the fleet-wide key, then the derived value — so set one only to insist on a number for one repo; omit them and both the backstop and the watchdog tune themselves. `scripts/doctor.sh`'s pinned-cap warning covers every level, naming the repo for a per-repo override.

A repo entry may also carry `merge_autonomy` — the per-repo override of the top-level key of the same name, on the same precedence: this entry wins when present, the top-level key otherwise. Omit it and the repository follows the fleet-wide default.

A repo entry may also carry `merge_budget_per_day` — the per-repo override of the top-level key of the same name, on the same precedence. Omit it and the repository follows the fleet-wide default.

A repo entry may also carry `merge_autonomy_routine_sources` — the per-repo override of the top-level key of the same name, on the same precedence. Omit it and the repository follows the fleet-wide default.

A repo entry may also carry `merge_autonomy_protected_paths` — the per-repo override of the top-level key of the same name, on the same precedence. Omit it and the repository follows the fleet-wide default (today's nine agent-ops paths) — a repository whose own gate code lives elsewhere should name its own list rather than inherit agent-ops's.

A repo entry may also carry `merge_autonomy_routine_complexity` — the per-repo override of the top-level key of the same name, on the same precedence. Omit it and the repository follows the fleet-wide default.

A repo entry may also carry `landing_cool_off_hours` — the per-repo override of the top-level key of the same name, on the same precedence. Omit it and the repository follows the fleet-wide default.

A repo entry may also carry `escalation_autonomy` — the per-repo override of the top-level key of the same name, on the same precedence. Omit it and the repository follows the fleet-wide default.

A repo entry may also carry `preview` — this repository's preview-deployment arrangement (D19 Phase 1), read by the Implementer's and Reviewer's own preview-check step instead of either stage naming a provider or a repository. Absent, or absent its own `provider`, is `none` — no preview deployment, so neither stage runs a preview step. `{"provider": "vercel"}` is what poetic-fiddle's own entry sets; `vercel.bypass_secret_env` (default `VERCEL_AUTOMATION_BYPASS_SECRET`) and `vercel.token_env` (default `VERCEL_TOKEN`) each name an environment variable rather than carry a credential, and need setting only when a second Vercel-deployed repository wants a distinct secret on the same node.

A repo entry may also carry `prompt_overrides` — the per-repo layer of the top-level key of the same name, keyed `implementer`/`reviewer` only, resolved one stage at a time on the same precedence as `merge_autonomy`: this entry's own stage wins when present, the top-level `prompt_overrides` entry for that stage otherwise. Naming any other stage (`coordinator`, `enabler`, `refiner` or `monitor` — none of them yet runs against one known repository) is rejected at validation time rather than silently ignored. See [Prompt overrides](#prompt-overrides).

Every optional key goes on the repo's own entry, beside `slug` and `sources`:

```json
"repos": [
  {
    "slug": "Poetic-Poems/poetic",
    "sources": ["security", "issues:urgent", "tech-debt", "issues:low"]
  },
  {
    "slug": "Poetic-Poems/poetic-fiddle",
    "sources": ["security", "issues:urgent", "implementation-plan", "issues:low"],
    "implementation_plan_path": "docs/IMPLEMENTATION-PLAN.md",
    "nice": -5,
    "stage_timeouts": { "implementer": 90 },
    "stage_inactivity": { "implementer": 20 },
    "preview": { "provider": "vercel" }
  }
]
```

Each of them is set by editing `config.json`, like every other key here — see [Configuration](#configuration) for how that edit reaches a fleet already running.

### Extended notes: `state_local_cycles_retained`

Cycle and review directories the node's own `state_dir` keeps; the same push that replicates prunes to it. Deliberately far above `cycles_retained`, so the local machine is always the longer record. A span of history, not a literal count (requirement 1d): absent, it is derived from `schedule.cycle_interval_minutes` to hold the same ~41.7 days 1000 cycles was sized for at the historical hourly cadence; a configured value is a floor under that derivation, never a ceiling. A value below the derivation is therefore inert: the floor preserves the span of history the base count was chosen to keep at this installation's own cadence. `STATE_SYNC_LOCAL_RETAINED` bypasses the derivation outright, but only for tests — it is not an operator lever for wanting a lower count. Disk use is bounded separately, by requirement 2.0c's own free-space threshold — `min_free_workspace_bytes`'s floor, raised by `workspace_headroom_factor`'s derivation over the largest recorded clone (agent-ops#904) — not by this count.

### Extended notes: `state_local_streams_retained`

Cycle and review directories whose derived files are kept — the stage event streams (`<stage>.stream.jsonl`) and any fleet-log snapshot (`.fleet-log.jsonl`) a run left behind by dying before its own cleanup, which otherwise removes the snapshot when the run ends. Both are large and local-only — never replicated — so they are bounded well below `state_local_cycles_retained`; the records themselves are untouched. The count applies to `cycles/` and to `reviews/` each, and the running cycle's own record is kept whatever it says. Derived from `schedule.cycle_interval_minutes` to hold ~2.1 days regardless of cadence (requirement 1d); a configured value is used as configured, a cap as well as a floor (agent-ops#1826), because these files are the ones large enough to fill a disk — and, because `config.json` is built into the image, it applies to every node. `STATE_SYNC_STREAMS_RETAINED` in a node's `.env` sets the count for that node alone, ahead of this key; a value that is not a positive integer is ignored with a warning. Neither prunes anything on a node without `state_repo` (agent-ops#1936). The disk floor is `min_free_workspace_bytes` (2.0c), and under it the push prunes further still (2.5).

### Extended notes: `approver_restale_escalate_after_hours`

Hours the restale sweep retries a pull request before escalating it to `enabler_assignee` instead: a stale Approver `CHANGES_REQUESTED` — its `commit_id` no longer matching the head, but with no commit authored since (a rebase-only push, never a fix) — measured from the review's own `submitted_at`; the same trigger's genuine-progress case when a re-review reaches a verdict but posts nothing to GitHub (an adjudication escalate, most often), measured from the first such engagement against that standing review's own id; or a ready pull request with no Approver review at all whose recovery engagements are not producing one, measured from the first such engagement at its current head.

### Extended notes: `escalation_autonomy`

The D18 escalation-autonomy ladder, four rungs, each including the one below it (with one exception, below): `always-escalate` (today's behaviour — every Enabler escalation goes straight to a human), `adjudicate-first` (one bounded Enabler adjudication pass runs first, but only over a refinement disagreement; it either confirms the earlier refinement or escalates anyway), `decide-tactical` (one bounded Enabler decide pass runs first over *any* escalation — an ordinary blocked item as much as a refinement disagreement — and either settles it, decides a tactical trade-off on the pipeline's own authority, or escalates anyway), or `decide-with-veto` (the same pass under a wider mandate: it may also accept a residual exposure in a repository you own where the filer named a default, and corroborate an abandoned draft's void — and where a decision carries such an act, the act waits out `decision_veto_window_hours` first, so reopening the decision's own log issue vetoes it *before* anything happens). An owner-only decision always escalates, at every rung. A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos).

The same setting also governs a second, independent case: a Reviewer's own open question about a pull request's work order or scope (D18, agent-ops#668). That path runs its own bounded pass only at `adjudicate-first` exactly — `decide-tactical` and `decide-with-veto` both behave the same as `adjudicate-first` there, not a further widening — so you cannot enable one Enabler-side rung without also getting the open-question path at its `adjudicate-first` behaviour.

### Extended notes: `escalation_adjudication_max_passes`

How many `decide-tactical` passes one item may spend since its last human touch, whatever their reason — or ever, if it has had none — see [Blocked items and the Enabler](../guides/operating/diagnose-by-symptom.md#an-item-is-blocked-or-void). A fresh reason still gets its own pass under this cap, and closing an escalation about the item resets the budget in full rather than granting one further pass on top of a lifetime total; only a run of unrelated tactical questions on the same item between touches is what this bounds.

### Extended notes: `standing_decisions_file`

The installation's standing-decisions file: one dated line per answer you have given the pipeline, which its `decide-tactical` pass reads before deciding anything, so a question you have already answered is answered the same way again rather than escalated — see [Blocked items and the Enabler](../guides/operating/diagnose-by-symptom.md#an-item-is-blocked-or-void). Relative to the installation directory unless absolute. Leave it empty to supply none; the pass still sees the repository's own decision records and its recently closed escalations.

### Extended notes: `decision_veto_window_hours`

Hours a `decide-with-veto` decision that carries an *act* — closing an abandoned draft behind its void — waits before the act is taken, so you can veto it by reopening the decision's log issue *before* anything happens rather than after. `0` acts on the next cycle. A decision that merely accepts something (no act) is unaffected: it takes effect at once, and reopening its log issue is still the correction. Only `escalation_autonomy: decide-with-veto` can produce an act at all, so at every other rung this key does nothing.

### Extended notes: `escalation_refile_after_hours`

Hours a human's own close of an escalation issue suppresses the *next* filing for the same item (`open_question_escalate`/requirement 8f, `approver_escalate`/requirement 8c) — closing the issue is not the releasing act, so without this guard a human who closes without also releasing the gate gets a fresh issue every refusing round. `0` disables the guard: every refusing round files, as before this key existed. A re-escalation a failed post-close adjudication owes always files regardless of the window.

### Extended notes: `needs_refinement_label`

Label put on an **issue** while the pipeline has it recorded as too under-specified to work on, and taken off again when that clears — see [Items nobody has specified](../guides/operating/diagnose-by-symptom.md#an-item-is-blocked-or-void). You can also apply it yourself to flag one directly; the pipeline reads that back the same way.

The pipeline creates it in every repository it gathers data for, not only the one it happens to work, at most once per `labels_ensure_interval_hours` — so there is nothing to set up; without it the item is still recorded and still reaches the Enabler, you just do not see it in the issue list, and a label you apply yourself does nothing.

Leave it empty to switch the labelling off in both directions.

Do not set it to `blocked`, which is a label that excludes an issue from the pipeline's work source, nor to `obsolete`, which is reserved for a human to mark one of the pipeline's own draft pull requests as unwanted.

### Extended notes: `refined_label`

Label put on an **issue** once the Refiner has written it a specification — see [Refined items and the Refiner](../guides/operating/configure.md#work-source-controls). Purely informational: nothing reads it back, so removing it by hand does nothing.

The pipeline creates it in every repository it gathers data for, not only the one it happens to work, at most once per `labels_ensure_interval_hours` — so there is nothing to set up.

Leave it empty to switch the labelling off; the item is still recorded as refined and the Co-Ordinator still reads that record.

Do not set it to `blocked`, which is a label that excludes an issue from the pipeline's work source, nor to `obsolete`, which is reserved for a human to mark one of the pipeline's own draft pull requests as unwanted.

### Extended notes: `refinement_policy`

Per source: `required` (never select unrefined), `preferred` (rank refined items first, but an unrefined one may still be picked), or `exempt` (no refinement dimension — the default for every source not listed). Shipped default: `issues` and `tech-debt` both `preferred` — the two sources whose items can otherwise carry a specification the Co-Ordinator composed itself rather than one already written elsewhere (a merge conflict, a review comment, a security finding). See [Refined items and the Refiner](../guides/operating/configure.md#work-source-controls). Every source the Refiner's own candidate gathering reads — `issues`, `security`, `code-quality`, `review-feedback`, `abandoned-drafts`, `merge-conflicts`, `dequeued`, `landing-refusals`, `tech-debt`, `project-review` and `implementation-plan` — reaches an engagement; the latter two are read only for a repo whose `sources` lists them and whose policy for them is not itself `exempt`. A `required` source is refused at startup with `refiner_model` empty, and `failed-runs` is refused whenever it is `required` regardless of `refiner_model` — it has no candidate array for the Refiner to ever reach (requirement 1c). `refiner_max_per_engagement: 0` with `refiner_model` set only warns, every cycle, rather than refusing: it is a deliberate pause of a stage that still exists, so a `required` source's items simply wait, unlabelled, until the cap is raised.

### Extended notes: `unvoid_label`

The label you apply on GitHub to ask for a voided item to be reopened — see [Blocked and void items](../guides/operating/diagnose-by-symptom.md#an-item-is-blocked-or-void). No stage ever applies it, so "only a human may clear a void" still holds; this is just a way to say so from the issue itself. The pipeline creates it in every repository it gathers data for, not only the one it happens to work, at most once per `labels_ensure_interval_hours`; `scripts/doctor.sh` warns while a repo has not got it yet. Do not set it to `blocked` or `obsolete`.

### Extended notes: `void_retire_after_days`

Days a voided item sits fully actioned — its issue or pull request closed, or its tech-debt register row flipped to `resolved`/`not-debt` — before the pipeline stops carrying it in the void extract. This does not touch whether the item is void (still forever, still only a human's `unvoided` label undoes it, see [Blocked and void items](../guides/operating/diagnose-by-symptom.md#an-item-is-blocked-or-void)); it only stops an old, settled verdict from being handed to the Co-Ordinator and the dashboard's data forever. `0` disables retirement.

### Extended notes: `reservation_release_stuck_after_days`

Days a reservation-release marker (a `td/<id>`/`td-record/<id>` branch delete a cleanup could not land) may keep failing its retried delete before the sweep treats it as permanently stuck — an archived target repository, a protected branch, a login that lost push access — rather than retrying and warning identically forever. Past this age, the marker escalates exactly once, as a distinct `reservation-release-stuck` event rather than the recurring `warning`, and keeps retrying silently after that. `0` disables escalation.

### Extended notes: `coordinator_prompt_max_bytes`

The largest assembled prompt the Script will hand the Co-Ordinator. What a context window rejects is the whole prompt, not the runtime input alone, so the Script measures the rendered base prompt, subtracts it, and trims the two bands that carry a whole document each — an issue's entire thread and a tech-debt issue's entire thread — into what is left. Prose is shed and candidacy is not: every entry stays selectable, and every cut carries a marker naming how many bytes went and the URL to read it whole. Raise it for a Co-Ordinator model with a larger context window; `0` disables the bound, which is how every release before this key behaved.

### Extended notes: `merge_autonomy`

The D18 merge-autonomy trust ladder: `human` (today's behaviour — a human approves and merges), `agent-approves` (the Approver App reviews; a human still merges), `agent-merges-routine`/`agent-merges-all` (the Script itself lands an eligible pull request — see `merge_autonomy_routine_sources` — and a human's residual act narrows to whatever the classifier refused). A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). Every level above `human` needs `approver_app_id` and `approver_model_default` set, and a human `CHANGES_REQUESTED` blocks landing regardless of level.

### Extended notes: `merge_autonomy_routine_sources`

D18 WI-7: which work sources may be armed automatically at `agent-merges-routine` and above — a pull request also needs a `complexity:*` grade in `merge_autonomy_routine_complexity`, and — below `agent-merges-all` — to touch no protected path; at `agent-merges-all` a protected-path hit is deferred to the critical-tier and `landing_cool_off_hours` controls rather than refused. A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). Takes `landingSourceToken`s, not the `sourceToken`s `repos[].sources` takes: issue work is the plain `issues` here, never `issues:<band>`, because banding is spent at gathering time and a finished work order carries the bare word.

### Extended notes: `merge_autonomy_protected_paths`

D18 Stage 3: the whole-path prefixes a routine-tier landing must touch none of — below `agent-merges-all` a hit refuses outright; at `agent-merges-all` it is deferred to the critical-tier and `landing_cool_off_hours` controls instead. An entry ending `/*` matches a whole-path prefix; any other entry matches an exact path. A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). Defaults to agent-ops's own gate paths, which govern nothing outside agent-ops itself. A resolved `[]` is valid — a repository whose gate code lives elsewhere may legitimately want it — but `scripts/doctor.sh` warns when it reaches a repository trusted at `agent-merges-routine` or above, since that repository's routine landings would otherwise have no path able to refuse one.

### Extended notes: `merge_autonomy_routine_complexity`

D18 Stage 3: which `complexity:*` grades may be armed automatically at `agent-merges-routine` and above — a pull request also needs a `source` in `merge_autonomy_routine_sources`, and — below `agent-merges-all` — to touch no protected path. A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). Widening past the default to include `high` is a bigger step than it looks: requirement 26a already forces `high` onto the riskiest class of diff (concurrency/locking, security, CI/workflow machinery, shared library code), so admitting it here routes exactly that class through automatic landing, with the protected-path list as the remaining belt-and-braces control.

### Extended notes: `landing_cool_off_hours`

D18 WI-12 (Stage 4): the wait, in hours, between the Approver's own approval of a protected-path pull request and the arming step landing it — only at `agent-merges-all`, and only alongside the critical-tier control. Measured from the standing review's own timestamp, re-read fresh every cycle; a fresh push restarts it, since the standing review's own commit no longer matches the pull request's current head. A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). `0` disables the wait.

### Extended notes: `approver_app_id`

The Pullwright Approver GitHub App's id. Every `merge_autonomy` level above `human` needs it set, and `scripts/doctor.sh` fails the config otherwise. `doctor.sh` also cross-checks it against the node's `PULLWRIGHT_APPROVER_APP_ID` environment, so the id the token wrapper mints against can never silently differ from the one recorded here. One id for the whole App identity: which of that App's installations mints a given repository's token is resolved separately, per repository owner, from the `PULLWRIGHT_APPROVER_INSTALLATION_IDS`/`PULLWRIGHT_APPROVER_INSTALLATION_ID` environment (agent-ops#913) — never from this key.

### Extended notes: `crash_loop_min_clear_minutes`

Minutes a crash-loop escalation's clearing success must hold, under the same detail and in that run's own repository (fleet-wide for the repo-less fallback group), before the Script closes the issue — hysteresis against a flapping condition opening a fresh issue every time it dips back below the failure threshold. `30` (two of `schedule.cycle_interval_minutes`'s own default 15-minute firings) gives a recurrence time to reach this node's own union before the success is trusted; `0` closes on the first success, as every release before this key existed.

### Extended notes: `notify_webhook_url`

The URL every notification POSTs to — every escalation issue filed or auto-closed, every `pager-fired`/`pager-cleared`, and every fleet-wide stand-down beginning or ending — one compact JSON body per event, gated by `notify_events` and coalesced by `notify_min_interval_seconds`. `escalation_webhook_url` is accepted as an alias for one release; `doctor.sh` warns if that is the only one set. The `NOTIFY_WEBHOOK_URL` environment variable wins over both, and is the non-public, per-node way to set this credential without committing it to this tracked file. Empty (all three sources) disables the channel: nothing is attempted, and a node with none configured behaves exactly as before. Setting it takes a second edit each node: the webhook's host must also be named in that node's `EGRESS_EXTRA_ALLOW`, or the egress fence answers every POST with a `403` and the node is as silent as it was before the webhook existed — `doctor.sh` checks for this.

<!-- config-table:notes-end -->

### Prompt overrides

`prompts/*.md` are this product's own content — they ship with every image
and every `git pull`. Editing one directly is a fork: it stops receiving this
repository's future updates to that stage. `prompt_overrides` in
`config.json` lets you add to, or replace, any stage's prompt from files that
live outside `prompts/`, so an installation's house rules survive an update
instead of needing to be re-applied after every one.

```json
"prompt_overrides": {
  "coordinator": {
    "extend": ["prompt-overrides/coordinator-house-rules.md"]
  },
  "implementer": {
    "extend": ["prompt-overrides/implementer-house-rules.md"]
  }
}
```

Keys are stage names — `coordinator`, `implementer`, `reviewer`, `enabler`,
`refiner` — each holding:

- **`extend`** — an array of file paths, appended to the stage's prompt in
  the order listed, after everything `prompts/<stage>.md` already says. This
  is the mode to reach for: it adds guidance without touching a single byte
  of the shipped prompt, so it can never fall out of sync with an update to
  it. Each fragment is wrapped with a fixed reminder that this repository's
  specs (`docs/*-SPEC.md`) outrank every prompt — an extension may add
  guidance, it cannot exempt your installation from a numbered requirement.
- **`replace`** — a single file path substituted for `prompts/<stage>.md`
  itself, before any `extend` fragments are appended. **Use this rarely, and
  know what it costs**: a replaced prompt stops receiving this product's
  updates to that stage's behaviour entirely — every future fix or new
  capability that ships in `prompts/<stage>.md` passes your installation by
  until you re-merge it by hand. `extend` covers nearly everything a house
  rule needs; reach for `replace` only when a stage's approach itself, not
  just its guidance, needs to differ.

There is deliberately no `approver` key. The Approver's adversarial prompt
is the gate the merge-autonomy trust ladder rests on: letting an
installation extend or replace it would soften the one check every
autonomous landing depends on, so its prompt is this product's own content
at every trust level.

A relative path in either key resolves against `state_dir` (the default
`~/.local/state/poetic-agents`), not the agent-ops working tree — the one
location this repository guarantees survives an image roll on a container
node and a `git pull` on the host, so your override content is never at risk
of being overwritten by an update the way a change committed to `prompts/`
would be. An absolute path, or one starting `~/`, is honoured as given. A
path that does not resolve to a readable file is treated as if it were
absent — a typo in a *path* does not fail a cycle. A typo in the
*structure* does, at startup: an unknown stage key, a string where
`extend`'s array is meant, or a misspelled `extend`/`replace` would each be
silently ignored if tolerated — you would get today's exact shipped prompt
with no indication why — so `agent-cycle.sh` refuses to start until
`prompt_overrides` is an object keyed only by the five stage names, each
holding only `extend` (an array of strings) and/or `replace` (a string).
For the `coordinator` and `enabler`
stages, that is still visible: a configured file going missing (or a new one
appearing, or an existing one changing) moves the hash the no-op
short-circuit tracks (see [Skipping no-op cycles](../guides/operating/run-and-pause.md#staying-warm-without-spending)),
so a broken path shows up as an unexplained Co-Ordinator or Enabler run
rather than being silently swallowed. `implementer` and `reviewer` overrides
need no such tracking — those stages only ever run once an item is already
selected, so nothing about them feeds the "is there anything new to do at
all" decision.

Leaving `prompt_overrides` out of `config.json` entirely — or a stage out of
it — reproduces today's exact prompt, byte for byte; nothing here changes
behaviour until you configure it. There is no per-repo scoping yet: an
override applies to every repo the stage runs against, because the
Co-Ordinator selects across every configured repo in one invocation per
cycle rather than one per repo.


## Repository review configuration (`repository_review` block in `config.json`)

<!-- config-table:start id=review — GENERATED from config.schema.json by scripts/render-config-table.sh; edit the schema, not these rows -->
| Key | Default | Notes |
|---|---|---|
| `repository_review.lock_stale_after` | *(unset)* | Hours, and a floor. Derived from the review backstop, multiplied by how many repositories are configured for review (floored at one), since they can all be reviewed back to back inside one lock. |
| `repository_review.defaults.model` | `claude-sonnet-5` | The lead model driving the review skill (which delegates to lower-cost subagents itself). Accepts the provider-qualified form (`anthropic/claude-sonnet-5`) as well as the bare id — see [Configuration](#configuration). |
| `repository_review.defaults.pr_label` | `project-review` | Applied to every review PR. Distinct from `autonomous-agent`, so review PRs never count against `max_open_agent_prs`. Do not name it `obsolete`. |
| `repository_review.defaults.branch_prefix` | `review/` | Branch name `review/<date>`. |
| `repository_review.defaults.timeout_review` | *(unset)* | Minutes, and an override. Leave it out — the backstop tunes itself. |
| `repository_review.defaults.inactivity_review` | *(unset)* | Minutes of total silence before the review stage is treated as wedged, and an override. Omit it — the threshold is derived; `0` disables the watchdog. |
| `repository_review.defaults.min_days_between_reviews` | `6` | Skip a repo reviewed within this many days. This is what makes a daily cron tick behave as "about once a week" and stay robust to a sleeping machine. |
| `repository_review.defaults.min_prs_between_reviews` | `5` | Skip a repo with fewer than this many PRs merged into its default branch since its last review. Independent of `min_days_between_reviews` — a review needs both enough elapsed days and enough merged PRs. |
| `repository_review.defaults.not_before` | *(unset)* | Optional. Hold reviews until this timestamp — e.g. `2026-07-30T16:00:00Z` — while the implementation pipeline carries on. Use this rather than `agent-cycle.sh --disable`, which is shared and would stop the cycles too, and rather than raising `min_days_between_reviews`, which has to be lowered again afterwards. It expires by itself; leaving the key in place once the date has passed does nothing. An unparseable value stands reviews down rather than running through it. As...[continued below](#extended-notes-repository_reviewdefaultsnot_before) |
| `repository_review.defaults.report_directory` | *(unset)* | Optional. Where the review pipeline writes its report set (`README.md`, `01-summary.md`, ...) and reads past ones from — a GNU `date` format string, resolved with `date -u +"<format>"` relative to the repo root, e.g. `docs/reviews/project-review-%Y-%m-%d`. Absent everywhere, `reviews/project-review-%Y-%m-%d` is used, unchanged. Use only date-level specifiers (`%Y`, `%y`, `%m`, `%d`, `%j`) and literal text: a format carrying `%H`, `%M` or `%S` writes a directory that...[continued below](#extended-notes-repository_reviewdefaultsreport_directory) |
| `repository_review.defaults.review_instructions` | *(unset)* | Optional. An array of paths, appended in order, of installation-held text added to the Reviewer-Agent's runtime input as *instructions* for this repository — see [Review instructions and context](../guides/operating/configure.md#repositories). A relative path resolves against `state_dir`, exactly like `prompt_overrides`. A path that does not resolve is a fail-fast error, not a silent skip. |
| `repository_review.defaults.review_context` | *(unset)* | Optional. An array of paths, appended in order, of installation-held background for this repository — what it is for, its domain, its relationships and consumers — added to the Reviewer-Agent's runtime input as *context*. Same path resolution and fail-fast-on-missing behaviour as `review_instructions`. |
| `repository_review.defaults.repo_context_file` | *(unset)* | Optional. A path *inside the repository under review* (e.g. `.github/REVIEW-CONTEXT.md`), read from the clone and added to the runtime input as repository-supplied context — never instruction, see [Review instructions and context](../guides/operating/configure.md#repositories). Unset by default; a missing file is simply absent, not an error. |
| `repository_review.repos` | see `config.json` | Repositories to review. Each entry is `{"slug": "owner/name"}`, plus any of `defaults`' own keys to override it for that repository alone. |
| `project_review` | *(unset)* | Deprecated alias for `repository_review` (agent-ops#592, D7): accepted with the identical shape while the fleet rolls onto an image containing the rename. `scripts/doctor.sh` warns when this is the only one set, naming `repository_review` as the replacement. Setting both is a configuration error (`config_schema_errors` refuses it, naming both keys) rather than a silent precedence, since resolving one of two present keys is exactly the quiet failure this schema exists to...[continued below](#extended-notes-project_review) |
<!-- config-table:end -->

<!-- config-table:notes id=review — GENERATED from config.schema.json by scripts/render-config-table.sh; edit the schema, not this section -->

### Extended notes: `repository_review.defaults.not_before`

Optional. Hold reviews until this timestamp — e.g. `2026-07-30T16:00:00Z` — while the implementation pipeline carries on. Use this rather than `agent-cycle.sh --disable`, which is shared and would stop the cycles too, and rather than raising `min_days_between_reviews`, which has to be lowered again afterwards. It expires by itself; leaving the key in place once the date has passed does nothing. An unparseable value stands reviews down rather than running through it. As `defaults.not_before` it holds every configured repository off before the pipeline even takes its lock; a repository's own `not_before` override additionally holds that repository off for longer (or shorter) than the installation-wide value, checked per repository once the cycle is under way.

### Extended notes: `repository_review.defaults.report_directory`

Optional. Where the review pipeline writes its report set (`README.md`, `01-summary.md`, ...) and reads past ones from — a GNU `date` format string, resolved with `date -u +"<format>"` relative to the repo root, e.g. `docs/reviews/project-review-%Y-%m-%d`. Absent everywhere, `reviews/project-review-%Y-%m-%d` is used, unchanged. Use only date-level specifiers (`%Y`, `%y`, `%m`, `%d`, `%j`) and literal text: a format carrying `%H`, `%M` or `%S` writes a directory that discovery, which probes a day at a time, can never find again — so every past review reads as missing.

### Extended notes: `project_review`

Deprecated alias for `repository_review` (agent-ops#592, D7): accepted with the identical shape while the fleet rolls onto an image containing the rename. `scripts/doctor.sh` warns when this is the only one set, naming `repository_review` as the replacement. Setting both is a configuration error (`config_schema_errors` refuses it, naming both keys) rather than a silent precedence, since resolving one of two present keys is exactly the quiet failure this schema exists to catch. The old spelling stops being accepted once every node in the fleet reports an image containing the rename (`repository_review`) — there is no calendar-based deprecation window: this installation has no release train to express one in, config.json ships inside the image (so a node never runs new code against an old config file of its own), and the fleet roll is the only compatibility window that genuinely exists.

<!-- config-table:notes-end -->

