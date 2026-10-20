## Acceptance checks

### Acceptance checks — continued (part 7 of 9; items 1h–2s, 79)

1h. <a id="impl-ac-1h"></a>**A log past `log_retained_bytes` rotates, keeps `log_generations`, and
   never touches `log.jsonl`.** `test/rotate-logs.test.sh` passes: a log under
   the threshold is left alone; one over it is renamed to `.1` and a fresh
   empty file takes its place; a second rotation shifts `.1` to `.2` rather
   than overwriting it, and a generation beyond `log_generations` is dropped;
   `log.jsonl` and `review-log.jsonl` grow past the threshold untouched; and
   `once-pr4-verify.log` is removed if present. `test/publish-dashboard.test.sh`
   passes its cron-panel case: with `cron.log` short and `cron.log.1` present,
   the panel's tail draws from both, newest last.
1h-i. <a id="impl-ac-1h-i"></a>**Analytics retention is a stated policy, and rotation and pruning
   both already conform to it (requirement 2.6d).**
   `test/rotate-logs.test.sh` passes an added assertion: the shipped
   config's own `analytics_retained_days` resolves to `0` (retain
   indefinitely) through `config_defaults`, the same resolution the pipeline
   itself uses, asserted beside the existing behavioural proof that
   `log.jsonl`/`review-log.jsonl`/`revert-rate.jsonl` never rotate — the
   policy and the exclusion that already conforms to it, pinned together.
   `test/state-sync.test.sh` passes the assertion added to its own
   local-retention case (1d): a push that prunes `cycles/`/`reviews/` to
   `state_local_cycles_retained` leaves `log.jsonl`'s content exactly as it
   was. `test/item-lifecycle.test.sh` passes its two-node fixture: two
   independent unions built by `fleet_logs` for two different nodes over the
   identical underlying events fold to identical `records[]`, and
   concatenating both folds' records and reducing by `{repo, item}` yields
   exactly one record per item, never two. `config.schema.json` declares
   `analytics_retained_days`, `default: 0`, with `x-docs.readme`/
   `x-docs.spec`, and `scripts/render-config-table.sh --check` passes with
   it rendered into all four `config-table` regions.
1i. <a id="impl-ac-1i"></a>**Per-installation prompt overrides extend or replace a stage's prompt,
   and the fingerprint tracks them (requirement 4a).**
   `test/prompt-overrides.test.sh` passes: with no `prompt_overrides`
   configured (or a stage absent from it), `stage_prompt_text` is
   byte-identical to `cat prompts/<stage>.md`; a configured `extend` list is
   appended in order, each fragment wrapped in the "specs outrank every
   prompt" disclaimer; a configured
   `replace` substitutes the base prompt entirely, with any `extend` still
   appended after it, and falls back to the shipped prompt when the
   configured file is unreadable; an override for a different stage has no
   effect; an unreadable base prompt that no `replace` covers makes
   `stage_prompt_text` fail rather than return empty; and `stage_prompt_sha`
   changes for every one of those cases,
   including a configured `extend` file that does not exist. The digest is
   content-addressed: relocating the whole installation (prompts, state
   directory, `$HOME`) with identical config and content computes the
   identical fingerprint, and a `replace` file whose content equals the
   shipped prompt's computes the no-override fingerprint, because it serves
   the same bytes. `prompt_overrides`'s own structural shape — a non-object,
   an unknown stage key, a non-object stage value, an unknown key within a
   stage, a non-array `extend`, a non-string `extend` entry or `replace` — is
   config.schema.json's concern rather than this library's (requirement 1b);
   test/config-schema.test.sh asserts one rejection per class, naming the
   offending path.
1j. <a id="impl-ac-1j"></a>**The Co-Ordinator's repo/work-sources table is config-driven, and names
   no consumer repo in `prompts/coordinator.md` (requirement 4b).**
   `test/coordinator-brief.test.sh` passes: `coordinator_work_sources_table`
   renders one Markdown row per repo, each `sources` entry numbered in the
   order given, in the order the repos array itself gives; reordering a
   repo's `sources` reorders its row's numbering; an empty `repos` array
   renders only the header and separator. `prompts/coordinator.md` itself
   contains no real consumer repo slug, including in its worked JSON
   examples, which use generic placeholder slugs instead.
   `test/noop-skip.test.sh` passes: a change to the rendered table busts the
   no-op fingerprint, and an input predating the `coordinator_work_sources_
   table` key canonicalises the same as one carrying it empty.
1ja. <a id="impl-ac-1ja"></a>**The assembled Co-Ordinator prompt cannot outgrow its model's context
   window (requirement 4i).** `test/coordinator-input.test.sh` passes:
   `coordinator_fit_bands` hands an already-fitting array back byte-identical
   with `applied: false`; a `0`, non-numeric or non-array input changes
   nothing; an oversized array is trimmed to inside its allowance with every
   candidate still present, every identity field intact and the gatherer's own
   entry order undisturbed; each truncated body or comment ends in an elision
   marker naming its byte counts and its `url`; dropped comments are counted
   in `comments_elided` and the newest are the ones kept; the ladder's ninth
   and tenth rungs are `0:0:300` and `0:0:0`, an allowance only the
   identities fit lands on the tenth with nothing dropped and the first
   entry cap is the eleventh, while a fixture of the fleet's 2026-09-23 shape
   (317 entries, 251 of them tech-debt in one repository) settles on the
   identity-only rung inside the allowance that day's terms leave and its
   ~200-entry counterpart on the short-opening rung; an allowance no
   amount of prose-shedding can meet drops entries highest-`Priority`-and-
   freshest first, counted in `issues_elided`, and tech-debt entries
   freshest first, so the highest-numbered survive a cap; a backlog whose
   entries past the first fixed cap that fits are disproportionately larger
   than the ones ahead of it — the fixture pinning that the fixed cap alone
   would leave over half the allowance unspent, rather than assuming it — is
   refined towards the highest per-band-per-repo
   cap in the gap below the next-loosest fixed cap that still fits that
   allowance, leaving under half of it unspent and dropping far fewer
   entries, while the cap chosen stays under
   double the fixed cap it refines (agent-ops#2221); an allowance one entry cannot
   meet reports `fits: false` and still returns a usable array; `tech_debt` is
   trimmed on the same terms and `review_feedback`/`merge_conflicts` are not
   trimmed at all; and the rendered detail line names the allowance and spells
   out what the rung capped. Pinning requirement 4g, a repo array genuinely
   past `MAX_ARG_STRLEN` passes through both the already-fits and the
   must-trim paths with nothing on stderr and the array whole — the shape that
   caught this module's own first draft binding it as `--argjson`.

   And `test/coordinator-input-wiring.test.sh` passes, over the block lifted
   verbatim out of `agent-cycle.sh`: for three shapes of oversized input —
   long bodies, long threads, many entries — at three configured maxima, the
   prompt reassembled around the block's own output is inside the maximum;
   a larger maximum never yields a smaller prompt (which an overhead measured
   against the unfitted array would have caused); a maximum of `0` leaves the
   array untouched and logs nothing; a trim logs exactly one
   `coordinator-input-fitted` carrying the rung, the byte counts, the detail
   line and a `terms` breakdown by band, and no `warning`; a cycle needing no
   trim logs nothing; both shapes of "cannot fit" — a maximum the prompt text
   alone exceeds, and an allowance the ladder bottoms out inside — each log a
   `warning` saying which it was, itself carrying the same `terms` breakdown,
   with its five bands summing to the overhead total the block itself
   computed. The same file also lifts the exemption-set block that reads the
   fit's report downstream of all this, covered under acceptance check 2j-iii
   below. The same test lifts `handle_stage_failure`'s two refusal
   readers and drives them over the record the fleet actually produced on
   2026-08-21: the refusal is named `prompt_too_long`, its name carries none
   of the numbers the crash-loop ladder groups on, the API's message is kept
   beside it, a refusal the runner did not name falls back to `api_error_<n>`,
   and a stage that ran and then failed, a clean result, an empty transcript
   and an unparseable one are none of them called a refusal.

   `test/stage-api-refusal.test.sh` (agent-ops#2308) passes, sourcing
   `lib/stage-attempt.sh` directly: a bare `terminal_reason: "api_error"`
   (no `prompt_too_long`/`invalid_request_error`/connection-fault name riding
   with it) now carries its own HTTP status in the returned token
   (`api_error_400`), where before this fix it fell through to the literal,
   status-less string `"api_error"`; a key the API refuses for carrying no
   workspace scope is named `workspace_scope_refused` and classified
   `refused`, with the API's own message kept beside it; the existing
   `authentication_failed` case and a bare `api_error_503` are both
   unchanged.

1k. <a id="impl-ac-1k"></a>**A stage prompt reaches `claude` on stdin, at a size argv could not
   carry (requirement 4c).** `test/stage-prompt-delivery.test.sh` passes: for
   `run_model_stage` as sourced from `lib/stage-run.sh` — the one copy both
   pipelines call, which the file asserts by finding the function in neither
   cycle script — a 200000-byte prompt, comfortably past `MAX_ARG_STRLEN`,
   exits 0, arrives on the stub's stdin whole, appears
   nowhere in its argv, and leaves the JSON envelope in `out_file` where the
   caller's parser looks for it; an ordinary short prompt is delivered byte
   for byte. The oversize prompt is sized to the kernel's constant rather
   than to the prompt of the day, so the check keeps its meaning if a prompt
   is ever trimmed; the file first confirms the cap exists on the kernel it
   is running on, and says so and skips rather than passing vacuously if it
   does not.
1k0. <a id="impl-ac-1k0"></a>**The stage launcher is provider-neutral, the Claude adapter behind it
   changed nothing, and a second adapter is one file away — reached the way a
   cycle script reaches it (requirement 4d).**
   `test/stage-run.test.sh` passes, against a `claude` stub emitting a fixed
   four-event transcript: a stage's `<stage>.stream.jsonl`,
   `<stage>.out` and `<stage>.out.stderr` are byte-for-byte the fixture
   strings the file pins (the shape this launcher produced before
   `lib/substrate-claude-code.sh` was extracted out of it),
   the prompt still arrives on the binary's stdin unchanged, and the argv is
   still the Claude adapter's own — so nothing downstream of the launcher can
   tell the dispatch happens. A stub substrate, defined and registered
   entirely inside the test (never written to `lib/`, never added to
   `config.schema.json`, never installed in the image), then proves the
   dispatch itself: registering it costs exactly the two things requirement
   4d's seam names — one `substrate` enum entry and one provider configured
   with it — and `run_model_stage` reaches it, with its own binary and argv,
   without `lib/stage-run.sh` changing at all. **And it is reached through
   the whole chain a cycle script drives**, not from a map set up by hand:
   `providers_load` from a `providers` block, then
   `resolve_model_id_into` on a qualified id, then `run_model_stage` on what
   that assigned, with `stage_provider` naming the provider it resolved to.
   The printing `resolve_model_id`'s own fallback is pinned in the same file
   (identical bare id, substrate back to `claude-code`), because requirement
   1a's reason for preferring the assigning form is a silent fallback rather
   than an error — a seam tested from a hand-populated `MODEL_PROVIDER` alone
   would pass over the step that chooses the adapter. The same file pins the
   **empty** model — requirement 1a's "disable this stage" convention, which
   is an ordinary input to this map's readers and not an error: under the
   `set -euo pipefail` every cycle script runs, both `stage_model_substrate`
   and `run_model_stage` resolve it to the `anthropic`/`claude-code` fallback
   and dispatch, rather than aborting the calling script on bash's own
   bad-array-subscript error for an empty associative-array subscript
   (issue #2234).
   The same file's part 6 covers the credit mix's own draw (issue #2241,
   D30): against a stub whose `init` event reports whichever `apiKeySource`
   its own launched environment actually implies, 300 distinct seeds at a
   configured weight of 2:1 split within ten points of that ratio and the
   same seed always draws the same lane; a weight of 1:0, a node holding
   only a login, and a node holding both credentials with no `lanes` block
   configured at all each land every launch on the one lane each case
   documents, whatever the others' weights say; an explicit lane argument
   bypasses the draw outright; and a credential present but configured
   (`enabled: false` on both lanes) into total unavailability refuses to
   launch at all — `stage_kill_reason: "no-open-lane"` and an empty stream —
   rather than running unmanaged, which is reserved for a node holding
   neither credential. Stubbed `union_stream`/`fleet_logs` readers are called
   zero times across every one of those cases, pinning "the launcher reads
   no ledger" as a call count rather than an assertion about one path alone.
1k1. <a id="impl-ac-1k1"></a>**A stage streams as it runs, and leaves the envelope its readers
   expect (requirement 4d).** `test/stage-stream.test.sh` passes, against a
   `claude` stub that emits stream-json a line at a time with a pause
   between lines: the invocation is made with `--output-format stream-json
   --verbose`; `<stage>.stream.jsonl` grows *while the stage is still
   running*, which is the property the non-streaming form could not provide
   and the one every later use of the stream rests on; every emitted event
   survives in it; `<stage>.out` holds exactly the final `result` event, one
   line, and `metering_fields` derives from it the same record it derives
   from a bare `--output-format json` envelope carrying the same numbers; a
   stream whose last line is torn — the shape a killed stage leaves — still
   yields the earlier `result` event if it has one, and yields an empty
   `.out`, not a corrupt one, if it does not; and a stage that emitted no
   `result` event at all leaves `.out` existing and empty, which is what its
   readers already treat as "no envelope". `test/state-sync.test.sh` passes:
   a `*.stream.jsonl` written into a cycle directory reaches neither the
   mirror nor the pushed branch while the `.out` beside it reaches both, one
   already in the mirror from before the exclusion is deleted from it, and
   `state_local_streams_retained` removes the streams of older cycle and
   review directories while leaving those directories and every other file
   in them in place.
1k2. <a id="impl-ac-1k2"></a>**A stage's inter-event gaps are measured while it runs (requirement
   33a).** `test/stage-gaps.test.sh` passes: `stage_gap_stats` summarises a
   known sample at the nearest rank — checked at the ranks where definitions
   differ, not only in the middle — leaves one long silence among short ones
   visible as `max` without moving `p50`, skips an unreadable observation
   rather than failing the record, and reports `null` only for a sample with
   nothing readable in it. Against a stub emitting with controlled pauses:
   an eight-second silence is measured rather than averaged away, gaps are
   counted per observed growth of the stream, the silence after the final
   event is counted even though no event closed it, a stage that emitted
   nothing at all still reports the one gap that was all of it, and the
   stage's own envelope and exit status are unaffected by being measured.
   Timing assertions bound from below, never exactly: a loaded machine makes
   a silence look longer, never shorter. `test/metering.test.sh` passes:
   `gaps` is carried through as given, is `null` when the caller supplies
   none, and degrades to `null` — rather than failing the whole record —
   when the caller supplies something unparseable.
1k3. <a id="impl-ac-1k3"></a>**A stage that stops producing is stopped, and the two kills are told
   apart (requirement 4e).** `test/stage-watchdog.test.sh` passes, against a
   `claude` stub whose output it controls: a stage that goes quiet for longer
   than its inactivity threshold is killed, returns 124, and reports
   `stage_kill_reason` `inactivity`; a stage that keeps emitting through a
   span several times that threshold is *not* killed, which is the assertion
   that matters most, since the whole failure being replaced was killing
   stages that were working; a stage that emits nothing but outlives its
   backstop reports `backstop`, not `inactivity`; a threshold of `0` disables
   the watchdog, leaving a silent stage to run to its backstop; a stage that
   ends on its own reports no kill reason at all; the killed process group is
   dead rather than orphaned; and the stream written before the kill survives
   it, which is what makes the forensics of requirement 4d worth having. The
   `warning` body is produced for an inactivity kill and for nothing else.
   The same file covers requirement 4e's third stop: a stream reporting the
   account `rejected` stops the stage at once, attributes it to `rate-limit`
   rather than to either cap, and carries the runner's own record — reset time
   included — out for the stand-down; an `allowed_warning` does *not* stop it,
   nor does the same status string appearing inside a tool result, which is
   what an Implementer working on limit detection would be reading.
   `test/stage-run.test.sh`'s part 6 covers requirement 4e's fourth stop, the
   credit mix's own lane verification (issue #2241, D30): a forced lane the
   stream's `init` event contradicts is stopped at once, `kill_reason:
   "lane-mismatch"`, naming both the forced and the observed lane; a forced
   `subscription` run whose `init` instead reports a Console login (`/login
   managed key`) is *not* stopped — it runs to completion, earns a one-time
   warning, and the very next launch in the same process draws `api`, the
   subscription lane now closed, confirmed against a run that is not the one
   that discovered it earning no warning of its own. `stage_lane_mismatch_standdown`
   writes the local switch (`state_dir/disabled.json`, `kind: "auto"`,
   `scope: "node"`, indefinite) naming the forced and observed lanes in its
   own reason iff the last run's own `kill_reason` was `lane-mismatch`, and
   is a no-op for every other run; all 8 of `run_model_stage`'s own call
   sites (`agent-cycle.sh`'s Implementer and Reviewer, `review-cycle.sh`'s
   Reviewer-Agent, `monitor-cycle.sh`'s Monitor, and the Co-Ordinator,
   Approver, Enabler and Refiner each in their own `lib/*.sh`) call it
   unconditionally, the same convention `stage_watchdog_warning` already is.
   `test/limit-detect.test.sh` passes: `limit_decide_structured` returns the
   stated reset as a known one, maps a seven-day limit to the weekly class and
   a five-hour one to `other`, falls back exactly as the prose path does when
   no reset is stated, and declines rather than guessing on an empty,
   unparseable or non-object record; and `limit_standdown_since` names the
   first hit of the current freeze — the earliest `limit-hit` with no later
   `limit-cleared` — printing nothing on an empty stream, on one whose last
   limit event is a `limit-cleared`, and never a hit from before that clear.
   Both `limit_union_record` and `limit_standdown_since` read past a spliced
   line — the head of a record run into a whole later one — before or after
   the governing hit, with most-recent-wins intact across it (a clear past
   the line still retires the hit, and a hit after that clear governs and
   starts a new freeze); a line that parses to a non-object is skipped; and
   each exits non-zero when its `jq` fails outright. `limit_union_state`
   answers the governing hit, the freeze's start and the `since` of every
   `limit-freeze-escalated` event (a non-string `since` left out) from one
   pass past a spliced line, agrees with the two readers built on the same
   fold, answers null, null and an empty list for a stream with no limit
   events, and exits non-zero when its `jq` fails outright.
   `test/doctor.test.sh` passes: `--offline` reports the stream-flushing
   probe skipped rather than running it, so the suite never spends.
1k4. <a id="impl-ac-1k4"></a>**Both stage caps derive themselves, and in the safe direction
   (requirement 4f).** `test/stage-budget.test.sh` passes against fixture
   logs with absolute dates: a stage is keyed to the repository its cycle
   selected and to the model it ran, two repositories are two cells, and a
   Co-Ordinator run from before the per-repository split (with no repository
   on its own event) has no repository axis; an unseen cell answers from the
   shipped prior, as does an empty table, so a first cycle needs no
   configuration; one backstop kill multiplies the cap and repeated kills are
   bounded by the ceiling, while three clean runs move it not at all; a killed
   run is counted as a run and contributes no duration, so the percentile is
   over completed runs only; a long silence widens the watchdog threshold and
   consistently short ones never narrow it below the prior, and it never
   exceeds the backstop; one run leaves a cell marked `shrunk` and carries
   only a fraction of its own estimate; configuration outranks the derivation
   and says so on the event; the derived lock clears the summed worst-case
   backstops plus slack, treats a configured value as a floor, and still
   derives from the priors alone against an empty table; and a malformed log,
   a `stage-end` predating `kill_reason`, one predating the gap statistics and
   a malformed `stage_budget` object each yield a usable answer rather than
   none. The same file passes the Co-Ordinator warm start (issue #1629): a
   post-split event is keyed to its own repository rather than falling to
   `*`, a brand-new `(coordinator, <repo>, model)` cell with no runs of its
   own resolves its backstop and watchdog from the frozen `(coordinator, *,
   model)` pool rather than the shipped prior — reported `pooled`, via the
   pooled tier, never `cell`, and never the frozen cell's own `own` however
   many runs that cell has — and an unrelated actor (the Refiner, the
   Enabler) is untouched by any of it; once that repository cell has a run of
   its own its backstop continues from the same warm value rather than
   resetting to the prior, and a kill against the repository cell's own
   history multiplies that warm seed exactly once rather than replaying the
   frozen pool's own kills a second time on top of it.
   `test/stage-overrun.test.sh` passes: the dashboard holds a live stage
   against the cap announced on its own `stage-start`, falling back to the
   fleet-wide widest for that actor and then to the shipped prior, and makes
   no claim at all about a stage none of those names.
   `test/config-schema.test.sh` passes: `scripts/doctor.sh` reports the
   derived lock rather than checking a configured one — reading
   `stage_budget_all_overrides` from `lib/stage-budget.sh`, the same
   function `agent-cycle.sh` derives the cycle lock from, so the two never
   disagree — and warns that a configured cap pins itself, at every level of
   the precedence: the plain `timeout_<actor>` / `inactivity_<actor>` keys
   including the Refiner's, and a repository's own `stage_timeouts` /
   `stage_inactivity` entry, naming that repository in the warning.
   `test/publish-dashboard.test.sh` passes: the dashboard publisher — the
   fourth caller of `stage_budget_lock_seconds`, alongside both cycle scripts
   and `scripts/doctor.sh` — derives `config.lock_stale_after` from
   `stage_budget_all_overrides` too, so a plain `timeout_<actor>` key and a
   wider per-repository `stage_timeouts` entry both reach it exactly as they
   reach `agent-cycle.sh`'s lock and `scripts/doctor.sh`'s report, rather than
   the dashboard silently deriving from an empty overrides map of its own.
1k5. <a id="impl-ac-1k5"></a>**A killed stage's uncommitted work is not lost with it (requirement
   4l, issue #2186).** `test/stage-snapshot.test.sh` passes, against a real
   local bare repository standing in for `origin` (no GitHub, no network): a
   stage killed by the watchdog after leaving real, uncommitted changes in
   its working tree — a tracked file's edit and an untracked new file alike —
   has both land in a commit pushed to the claimed branch before the final
   `kill -KILL`, the commit message itself Conventional-Commits-shaped so it
   does not fail the CI format check of the draft it lands on; a stage killed
   by the backstop gets the identical treatment, since a productively-looping
   stage's unsaved work is exactly as worth keeping as a wedged one's; a
   stage with nothing uncommitted when it is killed leaves the claimed
   branch's ref exactly where it was, so `release_branch_if_untouched`
   (lib/claim.sh) still reaps a genuinely untouched claim exactly as before;
   and a stage killed while still standing on the clone's default branch —
   where the Script's own hand-over leaves it, before the stage's first `git
   checkout` — moves that branch's ref on `origin` not at all, and mints no
   other ref in its place, however much uncommitted work its tree holds.
1l. <a id="impl-ac-1l"></a>**Repos are walked most-overdue-first by nice-weighted effective age,
   and it never starves a repo (requirement 3).** `test/repo-order.test.sh`
   passes: `repo_order_by_effective_age` returns an order byte-identical to
   a plain least-recently-updated-first `sort` of the same lines when every
   repo's `nice` is `0` or absent; scaling by `2^(-nice/3)` moves a
   negative-`nice` repo earlier and a positive-`nice` repo later, checked in
   both directions; a missing or unparseable timestamp reads as epoch 0 and
   stays maximally overdue at neutral `nice`; two repos with equal effective
   ages break by slug; the output is always a permutation of the input
   lines, never a subset or a reordering that drops or duplicates one; and
   `repo_nice_selection_config` returns `{}` — no key — for a config with
   no non-zero `nice` (absent, `null`, `0` and `-0` alike) and exactly the
   non-zero entries, floor-normalised, otherwise. `test/noop-skip.test.sh`
   passes: a `repo_nice` entry in `selection_config` changes the no-op
   fingerprint; and an input carrying an empty `repo_nice` map does *not*
   canonicalise the same as one omitting the key entirely — omission is the
   neutral form the producer emits for the shipped config (no `nice` keys
   anywhere), so it must drop the key rather than emit `{}`. Separately: a
   `nice` outside `-19`..`19`, or non-integer, makes `agent-cycle.sh` refuse
   to start, naming every offending repo's slug.
78. <a id="impl-ac-78"></a>**A guard reports its degradation and still answers exactly what it
   always did (requirement 4h).** `test/guard-degradation.test.sh` passes.
   `guard_warn` and `stage_budget_overrides` are lifted whole out of
   `agent-cycle.sh`, `gather_claimed`, `unaccounted_items` and
   `coordinator_eligible_items` out of `lib/candidate-select.sh` (#771), and
   the fleet stand-down date parse by its own
   start/end markers, the way `test/verdict-corroboration.test.sh` and
   `test/pr-claim-exclusion.test.sh` already lift theirs — so the file cannot
   pass against a paraphrase. Every case asserts **both** halves: that one
   `guard-degraded` event was written, naming that site and carrying the
   failed command's own output as `detail`, and that the caller-visible value
   is the same literal it was before requirement 4h. The failures are induced
   the way each site can really fail — an unparseable `CONFIG_FILE`, a
   `gather_claimed` claims array genuinely padded past `MAX_ARG_STRLEN`
   (131072 bytes, proven past the cap by the assertion beside it, the same
   mechanism the 2026-08-14 incident hit), malformed JSON reaching
   `unaccounted_items` and `coordinator_eligible_items`, an unparseable
   `resume_at` — and each pairs with a healthy-input case asserting the log
   stays *silent*, so a guard that fires unconditionally fails too. Separately
   and structurally, over the whole of `agent-cycle.sh`: every one of the
   guard sites reports and restores the variable its own assignment targets,
   and the sweep counts the sites it found and fails if that count collapses,
   so a parser that silently matched nothing cannot pass the check vacuously.
   Reintroducing requirement 4h's own `void_actioned_json`/`void_json`
   mismatch at any site must fail this file. The report's own bounds are
   asserted too: a site repeated seven times yields exactly
   `GUARD_WARN_SITE_MAX` events, numbered, with only the last marked `final`;
   three distinct labels interleaved all report, so the cap is per label and
   not per cycle; a 4000-byte `detail` is stored at 500; and a guard raised
   under `MANAGE_ACTION` writes nothing to the log and names its site on
   stderr, while the same site under a real cycle still logs. The usage-limit
   union read and the automatic-freeze escalation of requirement 2.1/1c are
   lifted out of `lib/standdown.sh` by their own markers: the union carrier
   reads the governing hit past a spliced line silently; a read that fails
   outright leaves it empty, marks the union's answers unknown and reports
   `cycle:union_record`; and a union the snapshot could not build is not
   read at all and is treated the same way. A three-day freeze past a
   spliced line files its escalation keyed on its start and logs
   `limit-freeze-escalated` with `since_basis: union`, and does not file
   again once that event sits in the union past a spliced line; a failed
   union read, and a union that could not be built, each file nothing and
   log a `warning` that the escalation waits for the next cycle; a flag-only
   freeze three days old files its escalation keyed on the flag record's
   `ts`, logs that time as `since` with `since_basis: flag`, and says in the
   issue body that it is the time `fleet/limit.json` was last written, while
   one an hour old files nothing; and a flag-only freeze whose record has no
   `ts` files nothing and reports `freeze_since:flag`.
2. <a id="impl-ac-2"></a>`--dry-run` completes against the real repos: stand-down checks pass,
   ordering is computed, the findings pre-fetch runs, the Co-Ordinator selects
   an item or declines with a reason, the work order is printed, nothing
   further launches, and the log records the cycle.
2a. <a id="impl-ac-2a"></a>`scripts/gather-findings.sh Poetic-Poems/poetic` prints a valid JSON
   array (possibly empty), and prints `[]` and exits 0 for a repo with the
   features disabled — never a non-zero exit that would abort the cycle.
2b. <a id="impl-ac-2b"></a>`scripts/gather-abandoned-drafts.sh Poetic-Poems/does-not-exist autonomous-agent agent/ 3`
   prints `[]` and exits 0 — a missing repo, a disabled feature, an API error, or
   an unparseable threshold never aborts the cycle. Its candidate rule is
   regression-tested in `test/abandoned-drafts.test.sh`.
2i. <a id="impl-ac-2i"></a>**The GitHub API budget gates the cycle, and a short refusal is waited
   out.** `test/github-limit.test.sh` passes: `github_limit_verdict` returns
   `ok` above both floors, `exhausted` naming the binding resource below
   either, the **later**-resetting resource when both are below, and `unknown`
   — never `exhausted` — for a snapshot that is missing, empty or unparseable;
   `github_limit_kind` tells a secondary refusal from a primary one and both
   from an ordinary failure; `github_limit_wait_plan` waits until a stated
   reset, refuses a reset beyond the per-call bound, clamps to what is left of
   the process budget and returns nothing once that budget is spent; and
   `github_pr_list_truncated` fires exactly at the cap. The wrapper itself is
   exercised against a stub `gh`: a rate-limited call is retried once and its
   stdout emitted exactly once, a non-rate-limit failure is returned
   unretried, and `gh`'s own stderr reaches the caller either way. The meter
   is the headers (agent-ops#1087): `github_limit_headers_to_resource` builds
   `core` from a metered response's `x-ratelimit-*` headers — case-
   insensitively, a refused call's included, never another pool's, and
   nothing rather than zeros when they are absent; `github_limit_graphql_resource`
   builds `graphql` from the `rateLimit` object with `resetAt` as an epoch
   and nothing from an error document; `github_limit_snapshot`, against a
   stub answering both reads as GitHub does, carries both pools, carries one
   when only one read, and is no snapshot at all when neither did; and
   `github_limit_resource_pristine` recognises the endpoint's empty window
   (full, unused, reset an hour from a fixed clock) but not the same bucket an
   hour into its window nor a header reading with its own probe used — so a
   snapshot made only of empty windows is `unknown`, never `ok`, one real
   pool beside one is judged on the real pool, and a header reading below the
   floor is `exhausted`.
2o. <a id="impl-ac-2o"></a>**The budget is recorded, and the record adds up (requirement 2.0d).**
   `test/github-limit.test.sh` passes: `github_limit_budget_delta` gives the
   difference in `used` within one window, the new window's `used` flagged
   `window_rolled` across a roll, `null` for a count that went backwards, for
   no previous reading, and for a pool missing on either side — that pool
   only; and `github_budget_record`, against a stub and a `log_event` of the
   pipeline's shape, logs one `github-budget` event per reading —
   `cycle-start` with no movement and the cycle opened, `stage` naming its
   stage and its movement, and an unreadable `cycle-end` recorded
   `readable: false` with the last good snapshot left in place for the next
   delta. `test/github-budget-report.test.sh` passes: over two nodes' logs
   with a damaged line, the report counts every reading and the unreadable
   one apart, takes each hour's peak used and minimum remaining from readable
   readings only, counts primary refusals (never a 404) and requirement-2.0
   stand-downs per hour, excludes a rolled reading from a stage's movement,
   sums each cycle's own core/graphql spend excluding a window-rolled or
   unreadable reading from it (requirement 48, agent-ops#1086), sums per
   node, honours `--since`, unions this node's log with its peers' in the
   fleet-shaped read, says so on an empty log, and errors on a named log
   that does not exist; and, over the `gh` transport shim's own ledger
   (requirement 2.0e), unions this node's ledger with a peer's the same
   fleet-shaped way, sums each cache outcome across that union, prints the
   shim's own section, and reads as zero calls — never an error — when
   explicit log files were given instead of a `state_dir`.
   `scripts/github-budget-report.sh` passes `shellcheck`.
2p. <a id="impl-ac-2p"></a>**The `gh` transport shim conditions a cacheable read, serves
   last-known-good under a refusal, and never touches anything else
   (requirement 2.0e, agent-ops#1084).** `test/gh-shim.test.sh` passes, both
   the pure functions (sourced directly) and the shim end to end against a
   stub "real gh" binary answering from a per-call JSON plan:
   `gh_shim_classify` sorts a plain GET as `read`, a GET carrying
   `--paginate` or `--slurp` (either alone, or both together) as `paginate`,
   an explicit or
   body-flag-implied non-GET method as `write` — even carrying `--paginate` —
   the literal `graphql`
   endpoint and a caller already carrying `-i`/`--include` each as their own
   class, and anything that is not `gh api` at all (or has no endpoint) as
   `other`; `gh_shim_split_blocks` parses a single response and a
   multi-page capture alike, and zero blocks from output
   with no HTTP status line in it at all; `gh_shim_header_end_offset` finds
   the body's own first byte, so a body carrying CRs or ending without a
   newline is returned exactly as the wire carried it, and offsets to 0 for
   output with no header terminator at all; `gh_shim_should_use_lkg` accepts a
   primary rate-limit refusal and a bare `5xx` but never a secondary limit or
   an ordinary error status; a cache entry's body and metadata round-trip
   exactly, embedded newlines included, and lives under its identity's and
   its path's directory, never at the cache root; `gh_shim_cache_dir` is
   stable for one (identity, path) and differs by either; and
   `gh_shim_cache_invalidate` drops
   a write's own path — every entry cached for it, whatever its argv, and
   the directory itself — and its parent resource for the write's own identity
   only, leaving an unrelated path and another identity's cache of the very
   same path untouched, is a no-op for a path nothing cached or an empty
   identity or path, and removes exactly its two directories from a
   300-entry cache of unparseable entries in well under a second — the
   assertion that it never opens an entry (agent-ops#1422);
   `gh_shim_prune_cache` keeps an entry younger than its horizon, drops one
   older at any depth together with the directory that emptied and a
   flat-layout entry left by the layout before this one, and leaves
   `http-cache/` and a live identity's directory in place. End to end: a repeated GET sends `If-None-Match` and
   a `304` is served from the cache with exit 0; a primary-limit `403` with a
   stored body is served last-known-good with a `PW_GH_CACHE=stale age=<s>`
   marker and exit 0, and the same refusal falls through to the real
   (failing) answer once the cached entry is older than
   `PW_GH_STALE_CEILING_SECONDS`; a successful write invalidates the reads it
   feeds and is itself never conditioned; a `POST`, `graphql`, `--input` and
   a caller's own `-i` each reach the real binary with unmodified argv and
   return its output unmodified, none of them ever cached; output the shim
   cannot split into responses at all is passed
   through to the caller with the real binary's own exit status rather than
   dropped; a non-`api`
   subcommand's output and exit status (success and failure alike) pass
   through unmodified; and `PW_GH_NO_CACHE=1` forces the same unmodified
   passthrough for an otherwise-cacheable read, still ledgered as `bypass`.
   A `--paginate` call drives its own pagination (agent-ops#1114): a fresh
   call fetches every page with its own `-i` and merges their own bodies into
   one JSON array, byte-spliced rather than reparsed, and caches page 1, page
   2 and the whole-call last-known-good entry separately; an identical
   repeat call sends each earlier page's own stored `ETag`, 304s every page
   but the final one — which is always re-fetched in full, unconditioned —
   merges the identical document with no new cache entry, and ledgers the
   call `miss`, `hit` being unreachable while the walk's final page is
   always a real fetch (agent-ops#2183); a call where only the newest page
   changed still sends page 1's previous `ETag` (304ing it unconditionally
   server-side), re-fetches only the changed page, overwrites that page's
   own cache entry in place, and ledgers the call `miss`; a page served
   from cache takes its continuation from the live response's own `Link`
   header whenever one is present and from the stored `next` only when it
   is not, so a response carrying a `Link` that names a further page the
   stored entry does not still continues the walk, fetches that page and
   ledgers the call `miss` — the preference order being what is checked
   here, a real `304` from GitHub carrying no `Link` at all; a page whose
   stored `next` is `null` is never conditioned on a later walk, even when
   cached — it is re-fetched in full every time, so a collection that grows
   a real next page past an exactly-full final page is seen on the very
   next walk rather than truncated forever behind a stale `304`; a call
   naming no `per_page` of its own gets the
   real binary's own default of 100 added to page 1's query string, while
   one already named — in the endpoint's own query string, or an explicit
   `-F`/`-f` field alongside `-X GET` — is left alone; a page refused
   mid-walk abandons the attempt and falls back to one whole-call request —
   the same last-known-good body a previous successful call stored, with the
   same `PW_GH_CACHE=stale age=<s>` marker and exit 0, and that fallback
   request alone, unlike the per-page attempt, never carries `-i`; a
   `--slurp` call wraps each page's own raw body as its own array element,
   unreshaped; a `--paginate --jq` call concatenates each page's own
   already-filtered body in order, exactly as the real binary's own re-run-
   per-page semantics does, never an array-splice of text that was never a
   JSON array; and a page whose body is not itself a JSON array in plain
   mode is tried once (with `-i`) and then abandoned in favour of the same
   unconditioned whole-call fallback, which reaches the real binary with the
   caller's own argv and `--paginate`/`--slurp` both untouched, exactly this
   pathway's own behaviour before agent-ops#1114. A page that is an empty
   JSON array — leading, trailing, or the only page there is — or whose
   inner bytes are whitespace only, contributes neither an element nor a
   separator, so the merged document parses rather than carrying the
   `[{…},]` or `[,{…}]` an unconditional splice would leave. A plain
   (non-`--paginate`) read of the same endpoint neither
   conditions a later walk's page 1 nor truncates it: the walk still follows
   its own stored `next` to page 2 even when every page `304`s, and a plain
   read made after a walk is itself still unconditioned by the walk's own
   per-page entry.
   `lib/gh-shim.sh` and `scripts/gh-shim.sh` pass `shellcheck -x`.
2q. <a id="impl-ac-2q"></a>**The on-demand credential seam mints a fresh token once the previous
   one is within `refresh_buffer` of expiry, never re-identifies an
   explicit `GH_TOKEN`, and degrades exactly like the identity it fronts for
   (D18 decision 1 as amended, agent-ops#1021).** `test/gh-shim-auth.test.sh`
   passes, end to end against a stub "real gh" binary and stubbed
   `curl`/`openssl` (never a live App or network call): with `GH_TOKEN`
   empty and the forge authoring App configured, both `gh auth
   git-credential` (standing in for the credential helper `git push` calls)
   and an ordinary `gh` call present a freshly-minted token, and a second
   call within the token's lifetime reuses it — no second mint; with
   `PW_GH_NOW_EPOCH` advanced past that token's `expires_at`, the next call
   of either kind presents a *different*, freshly-minted token, not the
   stale one — the contract `TD-PPagop-26082833` named and this item exists
   to close; a non-empty `GH_TOKEN` in the calling environment (including the
   shape `GH_TOKEN="$(approver_token_get)" gh …` uses) reaches the stub
   unchanged and mints nothing; with no forge authoring App configured, an
   ambient `GH_TOKEN` authenticates every call exactly as before this item;
   and, App configured but a mint refused, the call presents
   `PW_GH_DEGRADE_TOKEN` rather than failing or reaching the real binary with
   no credential at all. `test/forge-auth.test.sh` continues to pass
   unmodified — `PW_GH_DEGRADE_TOKEN` unset in every one of its cases, so
   `forge_auth_effective_gh_token`'s `gh-token-degraded` path still falls
   back to `GH_TOKEN` exactly as before — and `test/forge-auth.test.sh`,
   `test/gh-shim.test.sh` and `test/gh-shim-auth.test.sh` all pass
   `shellcheck`.
2r. <a id="impl-ac-2r"></a>**The seam mints against the installation covering the repository the
   call targets, and reaches for the PAT when none does.**
   `test/gh-shim-auth.test.sh` passes: with
   `PULLWRIGHT_AUTHOR_INSTALLATION_IDS` naming two owners and no scalar
   default, a call naming the first owner presents that installation's own
   token, a call naming the second presents the other's, a call naming a
   third presents `PW_GH_DEGRADE_TOKEN` — never another owner's token — and
   a call naming no owner presents `PW_GH_DEGRADE_TOKEN` too; adding a
   scalar default turns those last two into the default installation's own
   token while a mapped owner still wins over it; and a non-empty `GH_TOKEN`
   passes through whatever the owner. The same three outcomes hold through
   `gh auth git-credential`, driven by the `path=` attribute of a buffered
   request, whose bytes the stub "real gh" receives unchanged. Every
   `gh_shim_target_owner` rule is pinned on its own — `-R`/`--repo` in both
   spellings and outranking a positional, `HOST/OWNER/REPO` and github.com
   URLs, `gh api` `repos`/`orgs`/`users` paths with and without a leading
   slash or query string, a graphql `owner` field and a
   `repository(owner: "…")` literal including across a line break, the
   `origin` remote fallback for a bare call inside a work tree (HTTPS and
   SSH), and the cases that must name *nobody* — another forge's URL or
   remote, a path naming no owner, a request without `path=` or for another
   host, a three-segment path whose first segment is no hostname, and a flag's
   value that merely looks like a slug (`gh repo clone --branch feat/x
   acme/widgets` names `acme`). One group is asserted against a work tree
   whose `origin` is `Poetic-Poems/poetic`: `gh pr checkout agent/1051`,
   `gh pr view feat/x` and `gh pr diff docs/x` each resolve to
   `Poetic-Poems` and never to the branch's first segment — the failure this
   change would otherwise introduce, since an owner named `agent` resolves to
   no installation and would hand a `Poetic-Poems` clone the scalar
   default's token.
   After `gh_shim_resolve_token`, `gh_shim_identity` names a token the seam
   minted by its installation — `app-<app id>-<installation id>` — and a
   fresh mint for the same installation, the previous token gone from the
   mint cache and the clock past its expiry, keeps that identity; the other
   mapped installation and the scalar default are each their own; and the
   PAT the seam degrades to, as well as a caller's own non-empty `GH_TOKEN`
   even for a mapped owner, are each a hash of the token, never an App tag
   (agent-ops#1422).
2l. <a id="impl-ac-2l"></a>**A rejected or missing credential is classified apart from an outage,
   and stands the cycle down before the Co-Ordinator ever runs (requirement
   2.0b, agent-ops#691, TD-PPagop-26082306).** `test/github-limit.test.sh`
   passes: `github_auth_probe` returns `ok` for a working token,
   `unauthorized` — carrying GitHub's own response as `detail` — for an HTTP
   401, `unauthorized` again — `detail` now leading "no token present" rather
   than an HTTP status — for `GH_TOKEN`/`GITHUB_TOKEN` unset or empty with no
   `gh auth login` session either, and `unreachable` for every other failure,
   never conflating any of the three. `test/auth-failure-wiring.test.sh`
   passes against the block lifted verbatim from `agent-cycle.sh`: an
   `unauthorized` verdict exits 0 without falling through to the rest of the
   cycle (so no Co-Ordinator engagement follows it); the logged stand-down
   reason states `GitHub authentication failed (HTTP 401) — GH_TOKEN is
   invalid or expired` for a rejected token, or
   `GitHub authentication failed — no GH_TOKEN/GITHUB_TOKEN is set and gh has
   no stored credentials` for a missing one — either way never 2.0's or the
   claim loop's own "outage, not contention" wording — and exactly one
   escalation is filed through `create_escalation_issue` in `crash_loop_repo`,
   labelled, assigned, keyed `auth-failure:<node>`, and titled/worded for
   whichever of the two it is (never claiming an HTTP 401 that never
   happened); `ok` and `unreachable` verdicts fall through
   untouched, filing nothing.

2s. <a id="impl-ac-2s"></a>**A refused model credential stands the cycle down before the Co-Ordinator
   ever runs, the model-credential analogue of 2l above (requirement 2.0h,
   agent-ops#2308).** `test/standdown-credential-preflight.test.sh` passes
   against the block lifted verbatim from `lib/standdown.sh`: a `refused`
   verdict from `run_model_stage credential-probe` exits 0 without falling
   through to the gather, logs `stand-down` with `cause: "credential-
   refused"` and the API's own message (`stage_api_refusal_message`) as the
   reason, and files exactly one escalation through `create_escalation_issue`
   in `crash_loop_repo`, keyed `credential-refused:<node>`, body quoting the
   message; a second cycle of the same still-refused container probes again
   and escalates again (through the same dedup); an `ok` verdict falls
   through and is not probed again on a second cycle of the same healthy
   container, but is probed again after a fresh container start
   (`_updater_health_own_started` reading a different value); a `transient`
   verdict (a 5xx) stands nothing down; a `refused` verdict whose own
   `stage_api_refusal` token is not credential-shaped — `credit_exhausted`
   riding a 429, which reaches the classifier's own default arm as
   `refused` — stands nothing down and files nothing either, the probe
   having run, so the gate is proven to read both halves rather than the
   class alone; a container-start reading that is unavailable (an empty
   `_updater_health_own_started`) probes on its second cycle as well as its
   first, rather than comparing its own two empty records as unchanged;
   `--dry-run` makes no probe call at all.

   A node whose previous probe was `refused` and whose current probe gets a
   genuine clean reply retires its own `credential-refused:<node>`
   escalation (agent-ops#2414). `test/credential-refused-retire-resolved.test.sh`
   covers `credential_refused_retire_resolved` (lib/enabler.sh) directly,
   stubbing `gh`, and shows it closes a matching open issue with a comment
   naming the retiring cycle and the probe's own timestamp; leaves untouched
   an open issue that names a *different* node, even when `gh issue list`
   itself returns it among the results (the function's own body-match
   guard, not GitHub's `--search`, is what scopes this per node); and is a
   quiet no-op when no matching open issue exists — kept out of
   `test/standdown-credential-preflight.test.sh` itself because sourcing
   `lib/enabler.sh`/`lib/notify.sh` into that file widens shellcheck's `-x`
   variable pool enough to surface unrelated SC2030 findings against that
   file's own pre-existing subshell-local assignments. Against the extracted
   0h block itself, `test/standdown-credential-preflight.test.sh` shows the
   retirement call (stubbed there) fires exactly once on the cycle after a
   `refused` verdict is followed by a clean one; it does not fire when the
   node was never refused, when a transient 5xx follows a refused verdict
   (not itself evidence the credential has cleared), or on `--dry-run` —
   even against a node already recorded as refused, a dry-run cycle probes
   nothing and so retires nothing either.

   The retirement trigger persists rather than being consumed unconditionally
   (agent-ops#2511). `test/credential-refused-retire-resolved.test.sh` shows
   `credential_refused_retire_resolved` returns non-zero, rather than always
   0, on each of its three failure windows: a stubbed `gh issue close`
   failure (logging a `warning` event naming the issue and that it will
   retry next cycle, leaving `credential-refused-retired` unlogged); a
   stubbed `gh issue list` failure distinct from a genuinely empty result —
   the former logs a `warning` event and returns non-zero, the latter stays
   a quiet no-op returning 0; and a `gh issue list` call that succeeds but
   returns a payload `jq` cannot parse (agent-ops#2554), which logs its own
   `warning` event naming the unparseable payload and the retry, attempts no
   close, leaves `credential-refused-retired` unlogged, and returns non-zero
   rather than reading the empty match that payload also yields as a
   genuinely empty lookup. `test/standdown-credential-preflight.test.sh`
   shows the 2.0h block reads that return value: on a recovered probe where
   the stubbed retirement function reports success, the state file's
   verdict advances to `"ok"`; where it reports failure, the state file's
   verdict stays `"refused"`, so the next cycle's gate (`cred_prev_verdict ==
   "refused"`) probes again and retries the close rather than forfeiting it
   for the container's remaining lifetime. It also shows a `transient` probe
   immediately following a `refused` verdict leaves the state file's verdict
   at `"refused"` rather than advancing it to `"ok"`, so a later genuinely
   clean probe still finds `cred_prev_verdict == "refused"` and still
   triggers retirement.
   An `"ok"` verdict does not survive a fresh container start through an
   inconclusive probe, but a `"refused"` one does (agent-ops#2554, review
   round 2). `test/standdown-credential-preflight.test.sh` shows a healthy
   container that restarts and gets a `transient` reply on the new boot's
   very first cycle leaves the state file's verdict empty, not the old
   boot's `"ok"` — so a later cycle of the new boot still re-probes rather
   than reading that stale verdict as settled — and that the new boot then
   settles at its own genuinely-confirmed `"ok"`. It also shows the
   opposite case: a `refused` node that restarts and gets a `transient`
   reply on the new boot's first cycle keeps the state file's verdict at
   `"refused"` rather than resetting it, so a later genuinely clean reply on
   the new boot still retires the open escalation.

79. <a id="impl-ac-79"></a>**A missed CI trigger is nudged exactly once, and only when genuinely
   absent (requirement 69).** `test/ci-trigger.test.sh` proves, against a stubbed `gh`: a
   check run appearing at any poll before the window elapses stops polling
   and never calls the nudge push; a confirmed-empty check-runs list through
   the whole window nudges exactly once, naming the head commit it nudged;
   a nudge push that itself fails is reported `nudge-failed` and is not
   retried within the same call; a window ending on an unreadable read is
   `unknown`, never nudged, even when an earlier poll in the same window was
   also unreadable and a later one came back confirmed-empty (the window's
   own last read decides it); a pull request currently in a merge group is
   left alone; and an unreadable merge-queue probe is `unknown`, never
   nudged — fail-closed, not "assume not queued". The same file also proves
   `review_gate_required_checks`'s own behaviour is unchanged by this
   addition.
