## Acceptance checks

### Acceptance checks — continued (part 10 of 10; items 2j-i–7f)

2j-i. <a id="impl-ac-2j-i"></a>**The merge reconciles repositories correctly, and a rejected verdict
   costs a mechanical pick, never the cycle (requirements 15z, 3v; issue
   #587).** `test/coordinator-merge-fallback.test.sh` passes, against
   `run_coordinator_stage_attempt`, `fallback_select_candidate`,
   `coordinator_merge_candidates` and `coordinator_corroborate_and_fallback`
   lifted verbatim out of `lib/stage-attempt.sh`:
   - **`coordinator_merge_candidates`'s six-tier order, unit-tested
     directly.** A security-tier candidate wins even ranked last within its
     own repository; an `issues`-source candidate whose *own* repository
     marks it `Urgent` outranks a `review-feedback` candidate from a
     later-walk-order repository, while the identical ref is not treated as
     `Urgent` by a different repository that does not mark it so (the tier
     lookup is scoped to the candidate's own repository's `issues` array);
     all six named tiers (security, urgent issues, review-feedback,
     merge-conflicts, dequeued, abandoned-drafts) sort in the prompt's own
     order regardless of walk order; two residual-tier candidates from
     different repositories — carrying no cross-repository tier of their own
     — order by walk order alone, whichever of the residual sources either
     one is; two same-tier candidates from different repositories break
     their tie by walk order, and two candidates from the *same* repository's
     own tier break theirs by that repository's own rank; `candidates_max`
     caps the *merged* result (four raw candidates across two repositories,
     capped to two, keep the more-overdue repository's own two rather than
     one from each — repository order dominates a residual tier entirely);
     no internal `_tier`/`_repo_order`/`_rank` tag leaks onto a returned
     candidate; a non-array `candidates` argument degrades to an empty
     result, a non-array `repos` argument still merges by tier/rank alone,
     and a non-numeric `candidates_max` degrades to the documented default
     (`3`) — never a crash.
   - **`coordinator_corroborate_and_fallback` scopes corroboration to the
     repositories that said no.** A repository that selected needs no
     corroboration at all, even when a *different* selected repository's own
     eligible item went unreported — asserted directly: an eligible item
     belonging to a repository outside the false-repos list produces zero
     `corroboration` events regardless of whether it was ever accounted for.
     A false repository's own unaccounted item is rejected (`attempt: 1`
     always now — there is no second attempt to distinguish it from, since
     issue #587 dropped the model retry a fleet-wide rejection used to buy),
     and the mechanical fallback fires and finds it, with no `none-selected`
     event at all (the cycle selected something). A false repository whose
     own `needs_refinement`/`voided` report fully accounts for its band is
     accepted, with no fallback call and no `td_verdict_rejected`. When the
     fallback also finds nothing, the resulting `none-selected` carries
     `td_verdict_rejected: true`, the unaccounted `bands` tally, and no
     `fingerprint` (requirement 3t: a rejected verdict must never arm the
     no-op short-circuit) — proving the fingerprint-omission rule survives
     the retry's removal intact. When every configured repository's own
     bands are genuinely empty, no `corroboration` event fires at all (there
     is nothing to corroborate), and the resulting `none-selected` carries no
     `td_verdict_rejected`.
   - **`refinement_policy` binds the mechanical pick.** Against
     `fallback_select_candidate` in isolation: under
     `{"tech-debt": "required"}` an unrefined tech-debt item is not selected
     and a lower band wins instead.
   - **`fallback_select_candidate`'s band order and shapes, unit-tested
     directly** (no stage stub needed): against a synthetic
     `ordered_repos_json`, a security finding outranks a tech-debt item in
     the same repo; a `landing-refusals` entry outranks tech-debt and carries
     its own existing branch/PR; every band empty prints `null`, not a crash
     or an empty-string candidate accepted downstream as one.
   - **`sources` bounds the mechanical pick (requirement 3x).** The same
     fixture with its `sources` narrowed to the four finishing bands and its
     `issues`/`tech_debt` emptied — requirement 2.2a's own back-pressure
     shape — yields `null` rather than the security finding still sitting in
     its `findings` array, and yields that finding again the moment the token
     is restored.
   - **The gate is no longer tech-debt-only, and stays scoped to the
     repositories that said no (requirement 3x, issue #322).** A silent
     `selected: false` over a non-empty `issues` array and a non-empty
     `review_feedback` array — with the tech-debt band empty, so a
     tech-debt-only gate would have accepted it — is rejected, `eligible_total`
     counts both bands, and the `warning` and `corroboration` both carry a
     `bands` tally naming each; the rejected verdict's own mechanical
     fallback then picks the highest reachable band. A report filed under the
     wrong `source` leaves its actual band exactly as unaccounted as silence
     would. A verdict answering each band by its own route (a
     `needs_refinement` for the issue, a `voided` for the review-feedback
     entry) is accepted, buys no fallback call, and keeps its fingerprint.
   - **The argv cap survives the split (requirement 4g, TD-PPagop-26081401/
     26081406).** 3000 unclaimed tech-debt items, none reported back, still
     reach the `warning`/`corroboration` events in full past `MAX_ARG_STRLEN`
     (131072 bytes); 3000 recorded `needs_refinement` reports, read back
     through the same function, still fully account for an equally large
     eligible set.
   - **A no-verdict or zero-candidate Co-Ordinator engagement omits the
     fingerprint (requirement 15y).** The three consequences of requirement 15y
     are asserted in lifted blocks from `agent-cycle.sh`: the all-engagements-
     failed exit exits 0 when every engagement failed (full failure), exits 9
     when only some failed (partial failure), and exits 9 when zero repositories
     are configured (zero-configured case), proving every failure mode is
     correctly distinguished; an engagement that produced no verdict omits the
     fingerprint and records the count in `engagements_failed`, so the next
     cycle asks again (requirement 3t, requirement 3b), while a complete cycle
     where every engagement answered arms the fingerprint and carries no
     `engagements_failed` at all; a `selected:true` engagement that returned an
     empty `candidates` array is folded into the false-repos set with a reason
     naming the contract violation ("selected:true but returned no candidates"),
     contributes nothing to the merged candidates, and is distinguished from a
     non-empty list, which is carried into the merge as before.
2j-ii. <a id="impl-ac-2j-ii"></a>**The corroboration covers every pre-fetched band (requirement 3x,
   issue #322).** `test/verdict-corroboration.test.sh` passes:
   `coordinator_eligible_items` emits `{repo, item, source}` for each band the
   repo's own `sources` lists and nothing for a band it does not (the
   `code-quality` half of a `findings` array whose repo lists only `security`
   is the case that separates the two); drops a `merge_conflicts` entry that
   is a never-nudged Dependabot PR while keeping its superseded sibling, which
   the prompt requires in `voided`; admits an issue only under its own
   `Priority` band's token and drops one recorded blocked (repo-scoped exactly
   as `exclude_blocked_or_void_items` scopes it, blank `repo` included); bounds
   everything by the narrowed `sources` list a back-pressured cycle leaves
   behind, so a restricted cycle owes no account of `findings`
   or `human_visibility` still sitting populated; and
   degrades to `[]` on malformed repos, and to filtering nothing rather than
   everything on a malformed `blocked`. `unaccounted_items` matches a
   `needs_refinement` report on repo **and** item **and** source — the same
   ref filed under another band, or against another repo, accounts for
   nothing — while a `voided` entry, which carries no source, accounts for its
   repo+item in whichever band it was eligible in; it applies
   `refinement_policy` per entry's own source, so `"required"` exempts that
   band and no other; and every entry it returns carries the band it was
   eligible in. `test/coordinator-merge-fallback.test.sh` passes the wiring:
   a silent `selected: false` over a non-empty `issues` array and a non-empty
   `review_feedback` array — with the tech-debt band empty, so requirement 3t
   alone would have accepted it — is rejected, `eligible_total` counts both
   bands, and the `warning` and `corroboration` both carry a `bands` tally
   naming each; a report filed under the wrong `source` leaves its band
   unaccounted; and a verdict answering each band by its own route (a
   `needs_refinement` for the issue, a `voided` for the review-feedback entry)
   is accepted on the first attempt, buys no retry, and keeps its
   fingerprint. `test/verdict-corroboration.test.sh` also passes
   `unaccounted_items`' fit-ladder exemption (requirement 4i, agent-ops#683): a
   4th `trimmed-json` argument naming one eligible item exempts only that
   item, on the same repo+item+source key as `voided`/`needs_refinement`,
   leaving any other still-unaccounted item flagged; an omitted 4th argument
   exempts nothing, matching the function's behaviour before this change; and
   malformed trimmed JSON degrades to exempting nothing rather than
   everything.
2j-iii. <a id="impl-ac-2j-iii"></a>**A `needs_refinement` block against an entry the fit ladder trimmed
   this cycle is refused, never recorded, and the completeness check owes no
   account of it either (requirement 34e's fourth refusal, requirement 3x's
   matching exemption; agent-ops#683).** `test/coordinator-input.test.sh`
   passes `coordinator_fit_trimmed_items`/`coordinator_fit_trim_refusal_reason`
   in isolation: a cycle driven to the ladder's bottom rung with every entry
   still present marks every one of them trimmed; an untrimmed cycle marks
   nothing; a cycle trimmed only enough to clip one of two entries marks only
   that one; an entry whose comment prose alone was clipped — its body inside
   the rung's cap and its comment list kept whole — is marked trimmed on the
   marker inside that comment; and the refusal function refuses only an entry
   whose repo+item the trimmed set carries, names the rung in its reason, and
   degrades to
   refusing nothing on an empty or malformed trimmed set.
   `test/fit-trim-block-refusal.test.sh` then drives the real
   `record_needs_refinement_block` (lifted verbatim, the same technique
   `test/dependency-block-refusal.test.sh` uses) and passes: an
   agent-ops#683-shaped report — the Co-Ordinator citing a trimmed body's own
   lack of acceptance criteria — is refused with a `warning` naming the item
   and the rung, applies no label, and writes no `attempt-failed` at all; a
   genuine report against an item this cycle's fit never touched is recorded
   exactly as requirement 34e already describes; the refusal is scoped to
   `stage == "coordinator"` — the identical entry reported by a Refiner or an
   Implementer is not refused on this bar, since neither reads this cycle's
   fit-ladder-trimmed Co-Ordinator input; and the malformed-entry bar
   (requirement 34d) still runs ahead of this one. The same file then proves
   the two halves compose: with both of a fully-trimmed cycle's eligible items
   left unreported (as the refusal above forces), `unaccounted_items` finds
   nothing unaccounted — a `"selected": false` verdict over that cycle is
   accepted — while `coordinator_unassessable_items` still surfaces both as
   unassessable for the log, closing the loop the incident opened: the
   refusal alone would have just relocated the mass-flag into a
   corroboration-rejected retry loop over the same trimmed input, and this is
   the assertion that it does not.
   Both those files supply the trimmed set themselves, so neither can tell
   whether `agent-cycle.sh` ever builds one — the gap agent-ops#933 lived in
   for as long as the gate shipped. `test/coordinator-input-wiring.test.sh`
   closes it, over the exemption-set block lifted verbatim and driven off the
   fit report a genuinely-trimmed cycle actually left behind rather than a
   hand-written one: the block's `if` takes its true branch, so
   `coordinator_fit_trimmed_json` comes back non-empty and
   `coordinator_fit_rung` non-zero; requirement 3x's own accounting inside
   that same lifted block counts those candidates unassessable and logs
   `coordinator-input-fit-unassessable` carrying the count, the rung and its
   detail sentence; and `coordinator_fit_trim_refusal_reason`, given a
   `needs_refinement` report naming one of the items that block actually
   trimmed, refuses it and names the rung. Every one of those assertions
   fails against the pre-fix gate, which is what the empty-input fixtures
   above could not do.
2f. <a id="impl-ac-2f"></a>**A preview nobody can reach is never reported as a healthy one
   (requirement 24a).** `test/preview-deploy.test.sh` passes: against a stubbed
   `gh` and a stubbed Vercel that answers the login flow to any request not
   carrying the project's bypass secret, a built and reachable preview is exit
   0; a preview behind Vercel Authentication is exit 2 naming
   `VERCEL_AUTOMATION_BYPASS_SECRET`, with a different diagnosis for a secret
   that is unset and one that is rejected, since the two have different fixes;
   a failed build is exit 1 naming the inspector, and carries the tail of the
   build log when `VERCEL_TOKEN` is set; a preview that built and then serves a
   500 is exit 1 and is distinguished in words from a build failure; an
   application's own redirect is followed rather than mistaken for the login
   flow; no deployment at all, a SHA deployed only to Production, and a
   deployment still building are each exit 2; and `--wait` re-asks rather than
   answering from its first look. With no `--repo` and no `--pr` it resolves
   the checked-out branch's own pull request without combining `--repo` with
   an unidentified pull request — a shape the real `gh` CLI refuses, since
   `--repo` overrides the ambient-repository inference `gh pr view` otherwise
   uses to find the current branch's PR — and an explicit `--repo` with no
   `--pr` resolves the number first through `gh pr list --head <branch>`
   rather than combining the two; that refusal is pinned directly against the
   installed `gh` binary, not assumed by the stub. `--fetch <path>` against a
   preview behind the same stubbed wall still returns that route's status,
   headers and body — proving the bypass secret it sends internally reaches a
   protected preview's own content — while the secret's value never appears
   anywhere in the command's output; a binary body is noted rather than
   dumped, and an oversized one is truncated with a note naming the size.
   `prompts/implementer.md` and `prompts/reviewer.md` are asserted to invoke
   the check with `--fetch` in the same literal form, so the two cannot drift
   (requirement 34a). Against the real API and a
   real protected preview, `scripts/preview-deploy.sh --repo
   Poetic-Poems/poetic-fiddle --pr <n>` from a shell with no bypass secret set
   reports that the deployment built and that the page could not be checked.
   `test/preview-config.test.sh` covers the config-block half of the same
   requirement (D19 Phase 1): `preview_config_for_repo` resolves a configured
   `{"provider": "vercel"}` entry unchanged, falls back to
   `{"provider": "none"}` for a repo carrying no `preview` key at all and for
   a slug absent from `repos[]` entirely, and `preview_config_export_vercel_credentials`
   exports the two fixed variable names `scripts/preview-deploy.sh` reads
   from whichever variable name a `vercel.bypass_secret_env`/`vercel.token_env`
   override names, is a no-op on the defaulted names, and is inert for
   `provider: "none"`. `test/config-schema.test.sh` covers `scripts/doctor.sh`'s
   (component 14) own side of this same requirement, alongside its other
   cross-key rules: the shape half through `config_schema_errors` directly
   (rejecting an unknown `provider`, an unknown key inside `preview`, a
   `bypass_secret_env` that is not a bare shell identifier), and the
   credential-presence check through a real `scripts/doctor.sh` run, asserting
   it warns rather than fails when a `"vercel"`-configured repo's named
   variable is unset on the node it runs on.
2g. <a id="impl-ac-2g"></a>**Every pipeline comment is visibly attributed (requirement 9d).**
   `test/comment-identity.test.sh` passes: `pipeline_actor_label` returns the
   right display name for each of `script`, `coordinator`, `implementer`,
   `reviewer`, `enabler`, `review-script`, `project-reviewer` and `monitor`,
   and fails open — prints the token itself — for one it does not recognise;
   `pipeline_comment_header` renders `**<Display>** · autonomous pipeline ·
   node \`<node>\`` for a known and an unknown actor alike;
   `pipeline_comment_marker` carries both the cycle id and the actor token,
   still prefixed with `PIPELINE_COMMENT_MARKER_PREFIX`; and each of
   `prompts/implementer.md`, `prompts/enabler.md` and `prompts/reviewer.md`
   contains the literal header form `pipeline_comment_header` produces for its
   own actor token. `prompts/reviewer.md` also contains the literal
   instruction to post an unconditional completion comment (requirement 30b),
   pinned by a distinctive phrase from that instruction.
   `test/abandoned-drafts.test.sh` separately proves an
   older, actor-less marker and a newer, actor-carrying one both still exclude
   a comment from the activity clock, and that all three prompts (now
   including `prompts/implementer.md`) still carry
   `PIPELINE_COMMENT_MARKER_PREFIX`.
3. <a id="impl-ac-3"></a>A second invocation while one holds the lock exits without acting.
3a. <a id="impl-ac-3a"></a>**The lock-held case above costs a `stat`, a cache read and a `kill -0`,
   never the fleet-log union (requirement 1; agent-ops#2312).**
   `test/lock-skip-before-union.test.sh` passes: the lock pre-check that
   recognises a live, not-yet-stale holder
   is defined and called in `agent-cycle.sh` before the
   `fleet_logs` snapshot that materialises `union_log`, before the
   stage-budget derivation that reads it, and before the full lock
   acquisition that re-derives the precise `lock_stale_after` from it. The
   same file asserts the derived-threshold cache that pre-check compares
   against (agent-ops#2321): `.lock-stale-after-sec-cache` is written
   immediately after that derivation and read back inside the pre-check's
   own body, so each cycle's write is what the *next* cycle's pre-check
   reads.
   Separately, `test/union-read-memory-bound.test.sh` passes: run over a
   generated union of at least 100 MB, `log_latest_ts` (`lib/label-marker.sh`)
   and `crash_loop_open_escalations` (`lib/crash-loop.sh`) each still return
   the correct answer under a `ulimit -v` of 50,000 KB — a bound neither
   reader's pre-fix form (a whole-union `jq -s`/`jq -rs` slurp) can pass —
   and `label_own_actions_map`, audited against the same question, does too.
4. <a id="impl-ac-4"></a>A simulated stale lock (fake lock file, old timestamp, dead PID) is taken
   over with a logged warning. A simulated foreign lock (fake lock file
   naming a different `host`, fresh timestamp, a pid that is alive here
   because it collides with an unrelated local process) is taken over
   immediately with a logged warning, and that local process is left
   running.
4a. <a id="impl-ac-4a"></a>**A signal leaves a record, a released claim, and no orphaned model
   (requirement 9c).** `test/signal-exit.test.sh` passes: with the signal
   machinery lifted from `agent-cycle.sh` (and from `review-cycle.sh`), a
   TERM delivered mid-stage kills the stub stage's own process group, logs
   an `attempt-failed` whose detail is `<stage> terminated by SIGTERM`,
   releases the claim — `have-pr` when a breadcrumb names a PR, `no-pr`
   otherwise — and exits 143 through the EXIT trap; a stage that had
   already ended cleanly is not blamed (the event says `cycle`); and the
   requirement-1 takeover grace TERMs a live stale holder, proceeds as soon
   as the holder exits rather than sleeping out the full grace, and still
   takes the lock over.
5. <a id="impl-ac-5"></a>An injected `limit-hit` event with a future `resume_at` and
   `reset_known: true` causes a stand-down with no probe launched; an expired
   one does not stand down. With `reset_known: false`, the cycle launches
   exactly one probe: a stubbed `claude` answering a clean envelope yields a
   `limit-cleared` event (`by: auto-probe@<node>`) and the cycle proceeds; a
   stub answering the limit phrase logs a fresh `limit-hit` and a stand-down
   whose reason ends `(probe: still limited)`; a stub that exits non-zero
   with no output changes no limit state and the reason ends
   `(probe: inconclusive)`. `--dry-run` with the same injected event launches
   no probe.
5a. <a id="impl-ac-5a"></a>**A crash loop, of either class and in each configured repository
   independently, is detected once and escalated once (requirement 2.7).**
   `test/crash-loop.test.sh` passes: for
   `crash_loop_verdict`, a stream of threshold-many consecutive same-detail
   Co-Ordinator failures yields a verdict carrying the count, the window and
   every failing node; one fewer yields nothing; a Co-Ordinator success
   anywhere in the run resets the count (including the `stage-end 0` that
   precedes an `unparseable final message` failure, which counts as one, not
   threshold-plus); a detail change restarts the count at one; item-stage
   failures and other nodes' noise never contribute; a threshold of 0 is the
   off switch. Per-repository grouping (agent-ops#1630): repository A
   accumulating `crash_loop_after` consecutive same-detail failures while
   repository B succeeds every cycle in between still yields A's own verdict,
   untouched by B's success; an event carrying no `repo` at all still yields
   its own verdict, with no `repo` field, independent of every real
   repository's own group in the same stream; two repositories independently
   crash-looping in the same cycle both yield their own verdict — one
   JSON-Lines line each, each carrying its own `repo`, `detail` and count.
   `crash_loop_reverify` matches a retry to the correct one of several
   same-cycle verdicts by `repo` as well as `detail`/`first_ts`, so a retry
   queued for one repository's own run is never mismatched to another's, even
   sharing a detail and a first_ts. `crash_loop_preselection_verdict` passes the same shape of
   cases against the class `crash_loop_verdict` cannot see: threshold-many
   consecutive cycles that each logged `cycle-start` then `cycle-end` with
   the same non-zero `exit_code` and no `stage-start` anywhere between them
   yields a verdict carrying the count, the window, every failing node and
   the `exit_code`; one fewer yields nothing; a completed cycle that reaches
   a selection-path stage (`coordinator`, `implementer` or `reviewer`)
   resets the count whatever that stage then exits, as does a clean
   (`exit_code` 0) cycle, while an Enabler or Refiner `stage-start` never
   counts as recovery; an exit-code change restarts the count at
   one; a cycle with no `cycle-end` at all is dropped, counted neither way;
   item-stage failures and other nodes' noise never contribute; a threshold
   of 0 is the off switch. For `crash_loop_escalated_since`, an escalation
   event for the same detail after the run's first failure suppresses
   re-escalation, while an older one — a closed issue from a past loop —
   does not, and a different detail never matches. For
   `crash_loop_open_escalations`, two `crash-loop-escalated` events bound to
   the same `issue_number` (a rebind, agent-ops#1140) yield only the
   newer-by-`ts` one's own fields, regardless of the events' order in the
   log, while a single escalation still round-trips exactly as it always
   did. For `crash_loop_detail_recurred_since` (the 2026-09-05 fleet flap):
   a same-detail Co-Ordinator failure at or after a given timestamp reads as
   a recurrence whether or not it ever reaches `crash_loop_after`; no such
   failure, a different detail, or one strictly before the timestamp does
   not; a failure exactly at the timestamp counts (the boundary is
   inclusive). The same file replays the 2026-09-05 incident's own real
   timestamps end to end: the first run's verdict names its real first
   failure and count, a verdict computed once the clearing success is
   already logged never fires, the second flap is on its own a genuinely new
   threshold-crossing run, and `crash_loop_detail_recurred_since` correctly
   reads that second flap as a recurrence of the first run's own detail
   since its clearing success — the fact `crash_loop_retire_resolved` (lib/
   enabler.sh) relies on to keep the first run's issue open across the flap
   rather than closing it and forcing a fresh one. `test/crash-loop-escalate.
   test.sh` covers that reliance directly, with `gh`/`create_escalation_issue`
   stubbed: replaying the same incident, a clearing success younger than
   `crash_loop_min_clear_minutes` is never retired, a same-detail failure
   since the clearing success blocks retirement outright regardless of how
   old that success is, a success that has genuinely held the window with no
   recurrence is retired exactly as before, and `crash_loop_min_clear_
   minutes` 0 restores instant retirement on the first nameable success.

   **A fleet that recovers node by node still retires (agent-ops#2311).**
   `test/crash-loop.test.sh` covers the two readers directly: the success
   lookup names the *earliest* qualifying success at or after whatever
   instant it is given, so a later instant skips an earlier success, and
   `crash_loop_detail_last_failure_since` names the latest same-detail
   failure across nodes, nothing when the detail never failed at or after
   the instant asked about, nothing for a different detail, and — under a
   non-empty `repo` — only that repository's own failures.
   `test/crash-loop-escalate.test.sh` covers the retirement those two
   compose into, `crash_loop_min_clear_minutes` at its schema default: a run
   whose second node clears half an hour after the first retires, with the
   *later* node's success named in the closing comment; a same-detail
   failure after the only clearing success leaves the issue open; a
   recurrence that itself clears and then stays quiet past the window
   retires, naming that settled success; a recurrence re-arms the window
   even where an earlier success is long past it, so a flapping run stays
   open; and a fleet that recovered hours ago and has been succeeding every
   cycle since, right up to `UNION_LOG_HORIZON`, retires — naming the
   success that ended the incident rather than the newest one in the log,
   which no elapsed window could ever be measured against. A sixth fixture
   covers the boundary the clamp hands back to the recurrence guard: a
   same-detail failure sharing the clearing success's own timestamp, with the
   window long elapsed and no failure after, still leaves the issue open and
   logs no retirement.
   The same file also covers per-repository dedup and retirement
   (agent-ops#1630), two repositories sharing a generic detail (e.g. both
   "coordinator exited 1"): repository B's own run still files its own
   escalation issue undeterred by repository A's own same-detail escalation;
   repository A's own escalation is retired on repository A's own clearing
   success even while repository B, sharing the detail, is still actively
   failing under its own independent run; and repository B's own clearing
   success never retires repository A's own still-open escalation. And the
   transition case the same grouping has to survive: an escalation carrying
   no `repo` at all — one filed before agent-ops#1630 — is still retired by a
   repository-scoped clearing success, which is named in the closing comment,
   and its flap guard still sees a repository-scoped recurrence of its own
   detail and blocks that retirement.

   **The escalation quotes the API's own words (agent-ops#2308).**
   `crash_loop_verdict`'s own emitted object now carries the run's newest
   counted event's own `api_message`, when any event in the run carried one,
   and `crash_loop_escalate`'s issue body quotes it in a fenced block, naming
   the model credential as a third possibility alongside "the image or the
   config" whenever the run's own `detail` is credential-shaped
   (`authentication_failed`, `workspace_scope_refused`, or a 4xx
   `api_error_<status>`). `test/crash-loop-escalate.test.sh` covers this
   directly: a four-event run carrying the 2026-10-10 outage's own workspace-
   scope message yields a verdict whose `api_message` is that message, and
   the filed issue body both quotes it and names `ANTHROPIC_API_KEY`; the
   original, api_message-less `four_fails` run's own issue body quotes
   nothing extra and names no credential.
   back-pressure, and the logged reason states the count's composition
   (`N ready + N draft + N unraised claim(s)`).
5b. <a id="impl-ac-5b"></a>**A personal access token's own expiry is read, recorded, and escalated
   once per credential (requirement 2.7a).** `test/token-expiry.test.sh` passes:
   `token_expiry_parse` turns a `GitHub-Authentication-Token-Expiration`
   header value into an ISO-8601 UTC instant and a day count that floors
   toward zero — a fractional remainder rounds down, six hours out reads 0
   days rather than 1, and a token already past its own expiry reads 0
   rather than a negative number — while an empty or unparseable value is
   refused outright rather than read as some fallback date;
   `token_expiry_escalated_for` matches on the exact node *and* `expires_at`,
   so a rotated token (a new expiry) escalates again despite the repeated
   event name, and another node's identical expiry never cross-matches.
   `test/token-expiry-wiring.test.sh` passes against the block lifted
   verbatim out of `agent-cycle.sh`: a recorded `token_expiry` under
   `TOKEN_EXPIRY_WARN_DAYS` files exactly one issue, through
   `create_escalation_issue` in `crash_loop_repo` under
   `enabler_escalation_label` and keyed `token-expiry:<node>:<expires_at>`,
   and logs one `token-expiry-escalated` event naming that expiry; a second
   cycle over the same expiry — reading the first cycle's own event back out
   of the log union, as state-sync would deliver it — files nothing and logs
   nothing further; a rotated token files again; and a token at or above the
   threshold, a `token_expiry` of `null`, and a missing
   `.doctor-status.json` each file nothing. In every one of those cases the
   block falls through and the cycle proceeds — unlike requirement 2.0b's,
   this check never stands the cycle down, because a token that has not yet
   expired blocks nothing the cycle needs.
6a. <a id="impl-ac-6a"></a>**The switch stops both pipelines and lets go by itself.**
   `--disable 'testing'` then a plain invocation of *both* `agent-cycle.sh` and
   `review-cycle.sh`: each logs a stand-down carrying the reason, exits 0, and
   launches no `claude`. `--enable` restores both. Then plant a record whose
   `expires_at` is already past and run a cycle: it must clear the switch, log
   `enabled` saying the disable expired, and proceed — the assertion that an
   agent which sets the switch and dies costs a few cycles rather than every
   future one. Assert the ambiguous cases resolve toward *disabled*: a
   truncated record, and one whose `expires_at` is gibberish, both keep the
   pipeline down.
6c. <a id="impl-ac-6c"></a>**A review round is answered exactly once.** With a PR carrying an
   unanswered `CHANGES_REQUESTED`, a cycle must select it (`source:
   "review-feedback"`, `item` the round's ref, `branch` the PR's existing
   branch) and the Implementer must push to that branch without opening
   anything. Then the check that matters: run another cycle and assert the PR
   is **no longer a candidate**, while `gh pr view --json reviewDecision` still
   reports `CHANGES_REQUESTED`. Those two facts are true simultaneously, and
   that is the point — the agent cannot clear a review on its own PR, so
   nothing about the PR's state ever says "answered", and only the turn rule
   (a marked reply or a re-requested review since the blocking review, never a
   commit's date — see the design note on why) distinguishes "our move" from
   "theirs". Get it wrong and the PR is re-fixed hourly forever while every
   cycle looks productive. Assert the reopen too: a *new* review after the
   agent's push makes it a candidate again under a *new* ref, or a round that
   once went `blocked` will swallow the human's next attempt to unstick it.
6d. <a id="impl-ac-6d"></a>**Back-pressure cannot deadlock the pipeline (requirement 2.2a).** Set
   `max_open_agent_prs` to 0 with a *finishing* candidate present — a
   review-feedback round, a merge-conflicted PR, a dequeued PR *or* an abandoned
   draft: the cycle
   must **not** stand down, and must reach the Co-Ordinator with every repo's
   `sources` narrowed to
   `["review-feedback", "merge-conflicts", "dequeued", "abandoned-drafts"]`. With none present
   it must stand down as before. This is the check that a system whose PRs have all
   been sent back for changes — or all stalled as abandoned drafts or wedged on
   conflicts, the very slots the cap is counting — can still dig itself out;
   without it, the state the pipeline is least able to escape is the one it is
   guaranteed to reach.
6e. <a id="impl-ac-6e"></a>**An abandoned draft is finished, not restarted (requirements 3e, 15c).**
   With an open *draft* PR carrying `pr_label` on a `branch_prefix`
   branch whose `updatedAt` is older than `abandoned_draft_after_hours`, a cycle
   must select it (`source: "abandoned-drafts"`, `item` the head-SHA-scoped ref,
   `branch` the PR's existing branch), and the Implementer must check out that
   branch and push to it without opening a new PR or branch. Assert the freshness
   gate: the same PR with a recent `updatedAt` is **not** a candidate — a draft
   merely being worked, or one a peer node just touched, must never be stolen.
   Assert a *ready* PR of ours is never an abandoned-drafts candidate (that is
   review-feedback's job). And assert the claim uses a file claim, not a
   create-ref against the already-existing branch (requirement 17a), or every
   attempt would 422 and no abandoned draft could ever be picked up.
6f. <a id="impl-ac-6f"></a>**A conflicted PR is rebased, not restarted (requirements 3g, 15d).** With an
   open *non-draft* PR carrying `pr_label` on a `branch_prefix` branch
   whose `mergeable` is `CONFLICTING`, a cycle must select it (`source:
   "merge-conflicts"`, `item` the head-SHA-scoped ref, `branch` the PR's existing
   branch), and the Implementer must check out that branch, rebase onto the base
   and push without opening a new PR or branch. Assert the guards: a PR whose
   `mergeable` is `UNKNOWN` is **not** a candidate — mergeability is computed
   asynchronously and guessing would rebase a PR that may not conflict; a *draft*
   conflicted PR is not a candidate here (that is abandoned-drafts' job once it
   goes stale); and a *mergeable* PR is never a candidate. And assert the claim
   uses a file claim, not a create-ref against the already-existing branch
   (requirement 17a), or every attempt would 422 and no conflicted PR could be
   picked up.
6i. <a id="impl-ac-6i"></a>**A merge-group-checks-failure dequeue is fixed, not restarted
   (requirements 3z, 15d; TD-PPagop-26081409).** With an open *non-draft* PR
   carrying `pr_label` on a `branch_prefix` branch whose `mergeable`
   is `MERGEABLE` and whose most recent `merge_queue_probe` reports
   `queued: false`, a non-null `dequeued_at`, and `dequeue_reason` exactly
   `failed_checks`, a cycle must select it (`source: "dequeued"`, `item` the
   head-SHA-scoped ref, `branch` the PR's existing branch), and the
   Implementer must check out that branch, push a fix without opening a new PR
   or branch, and never attempt to re-queue it. Assert the guards: a PR whose
   `mergeable` is `CONFLICTING` is **not** a candidate here (that is
   requirement 3g's job, and the two candidate rules must never both admit the
   same PR head); a PR whose `dequeue_reason` is anything other than
   `failed_checks` (including empty/unreadable) is **not** a candidate; a
   currently-queued PR (`queued: true`) is never a candidate; and **a dequeue
   the pipeline has already answered is not a candidate at a moved head** — a
   marked `actor=implementer` reply newer than `dequeued_at` excludes the PR
   even though the probe still reports the same dequeue, which is what stops
   the fixed pull request being re-offered on every cycle until a human
   re-queues it. Assert the clause's own edges too: the same reply *before*
   `dequeued_at` does not exclude (so a second dequeue re-opens candidacy),
   another actor's marked comment or an unmarked one does not exclude, and a
   reviews or comments read that fails yields no candidate rather than one.
   And assert the claim uses a file claim, not a create-ref against the
   already-existing branch (requirement 17a), or every attempt would 422 and no
   dequeued PR could be picked up.
6g. <a id="impl-ac-6g"></a>**The review runs at the tier the work graded itself (requirements 26a,
   8a).** `test/cycle-state.test.sh`'s reviewer-complexity section passes: the
   resolution takes the highest valid grade among the summary's `complexity`
   and the PR's `complexity:*` label values (a label `high` outranks a summary
   `medium`, and vice versa); an unknown grade contributes nothing rather than
   failing; and with no valid grade at all it falls back to `low` for a
   trivial-classified work order and `medium` otherwise. Driving a cycle
   end-to-end: the Implementer's PR carries exactly one `complexity:*` label,
   its summary carries `complexity`, and the reviewer's `stage-start` event
   records the resolved `complexity` and a `model` equal to
   `reviewer_model_complex` when and only when the grade is `high`.
6b. <a id="impl-ac-6b"></a>**The no-op short-circuit skips only what it can prove, and stops skipping
   when anything moves.** Drive a cycle that ends `none-selected`, confirm the
   event carries a fingerprint, then run a second cycle: it must stand down
   *without launching the Co-Ordinator* — that saving is the entire feature, so
   time both and see it. Then the half that actually matters, and the half
   it is tempting to skip because the happy path passed: assert
   per-source that the fingerprint *changes* when a commit lands, an issue is
   relabelled or assigned, a workflow's conclusion flips, a claiming PR closes,
   a draft PR of ours crosses the `abandoned_draft_after_hours` staleness
   threshold (assert this one especially — it is the sole transition that moves
   no other signal, so the `abandoned_drafts` array is the only thing that can
   carry it), a ready PR of ours turns `CONFLICTING` after its base moved (assert
   this one too — like the staleness transition it moves no other fingerprinted
   signal once the base advance is a cycle past, so the `merge_conflicts` array is
   the only thing that can carry it), a ready PR of ours is dequeued over a
   merge-group checks failure (assert this one too — it moves *no* other
   fingerprinted signal at all, not even `mergeable`, so the `dequeued` array
   is the only thing that can carry it), an item is unblocked or unvoided, a source is
   added to `config.json`, or `prompts/coordinator.md` is edited. Each of those is a
   source of work, and
   any one of them missing from the fingerprint is an unbounded silent stall
   that no other check in this document would catch. Assert too that a
   scheduled workflow rerunning green does *not* change it (see requirement 3b
   — this is where the feature quietly dies), and that a repo whose state could
   not be sampled makes the cycle unfingerprintable rather than skippable.
7. <a id="impl-ac-7"></a>**A blocked verdict round-trips.** Append an `attempt-failed` for a
   selected item, then run a cycle: the Co-Ordinator's input must list that
   item as blocked, with its detail. This is the one check that catches the
   writer and the reader disagreeing about the event key (requirements 33/34)
   — nothing else in the system will tell you they disagree, because both
   halves look correct in isolation and the only symptom is work being
   silently redone.
7a. <a id="impl-ac-7a"></a>**The mandatory re-check round-trips too (requirement 18a).**
   `test/cycle-state.test.sh`'s requirement-18a section passes, proving both
   halves the requirement adds on top of check 7's general case. The
   comparison itself — a blocked GitHub issue's `updated_at` against the
   *later* of the block's `ts` and its `recheck_clean_ts` — is the
   Co-Ordinator's own judgement (prompts/coordinator.md, "A blocked issue
   with fresh evidence must be re-read"), not shell code, so the test mirrors
   that documented rule to check the real data `blocked_items` computes:
   with only an `attempt-failed` on record, an issue `updated_at` after the
   block's `ts` reads as due a mandatory re-read and one no later than `ts`
   does not (half 1, "forces the whole-thread re-read"); appending a
   `recheck-clean` folds `recheck_clean_ts` in, and the same, unchanged
   `updated_at` that just read as due now reads as not — a thread that said
   nothing new is not paid for twice (half 2, "stops the next cycle repeating
   it"); moving `updated_at` again past the `recheck_clean_ts` flips it back
   to due, so the marker's suppression lasts only as long as the thread
   stays quiet. Together with check 7, this is the writer
   (`recheck-clean`, requirement 33) and the reader (`blocked_items`'s fold)
   agreeing on both timestamps a blocked GitHub issue carries, the same way
   check 7 catches them agreeing on one.
7b. <a id="impl-ac-7b"></a>**An orphaned claim branch is put back in front of the pipeline
   (requirement 17b).** `test/sweep-orphan-branches.test.sh` passes: with a
   stubbed `gh`, a stale moved ref with no PR and no registry entry yields a
   draft PR carrying `pr_label` and a `recovered` action; a stale unmoved
   ref in the same state yields a ref delete and a `released` action; a ref
   with an open PR, a ref with a live registry entry, and a ref younger
   than `abandoned_draft_after_hours` are each left untouched; a registry
   read that fails with anything but 404 leaves the ref alone and says so
   (`warning`, fail closed); a missing label falls back to an unlabelled PR
   loudly; a stale ref with commits ahead but a merged PR against its head
   yields a ref delete and a `released` action rather than another recovery
   draft, and a failure to determine the merge state leaves the ref alone
   and says so; a stale ref with commits ahead, no merged PR of its own, but
   a rival branch sharing its stem merged after its first commit
   yields a ref delete and a `released` action carrying `reason: superseded`
   and the rival's URL, with **no** `pr create` call ever made; a same-stem
   rival that merged before this branch's own first commit does not count,
   and a tech-debt id's own eight-hex-digit numeric suffix (`TD-PPagop-
   26081403`) is never mistaken for the twelve-character random one, so
   neither collapses two unrelated same-scope items to one stem — both still
   yield the ordinary recovery draft, silently; and a failed or unparseable
   rival lookup also still yields the ordinary recovery draft, but with a
   `warning` naming the branch, distinct from the silent no-match case; and
   a backlog past the per-run cap acts on the cap's worth and reports the
   remainder (`deferred`) rather than flooding or staying silent. For the `td-record/*` namespace
   (TD-PPagop-26082310): a stale record branch whose only pull request was
   closed without merging yields a ref delete carrying
   `reason: "filing-declined"` and, on a clean 404 for `tech-debt/<id>.md` at
   the default branch, a second `released` for the paired `td/<id>`
   reservation, with **no** `pr create` call ever made; a 200 for that record
   keeps the reservation, and a contents read failing with anything but 404
   keeps it and says so (`warning`, fail closed); a *merged* filing is
   released by the ordinary merged-PR arm instead, never counted as declined
   and never asked the reservation question at all; a record branch with an
   open PR is left untouched and one with no PR at all is still recovered as
   a draft, both by the ordinary flow; and a run with only one action of
   headroom left defers the
   declined pair whole — neither ref touched — so the per-run cap holds
   strictly rather than overshooting by the release.
7c. <a id="impl-ac-7c"></a>**Claim visibility is deterministic, both shapes and both directions
   (requirement 3o, issue #175).** `test/claim.test.sh`'s `claims`/`branches`
   section passes: a fresh branch claim's registry entry appears in `claims`'
   output tagged `kind: "branch"` with its item; an entry older than
   `claim_ttl_hours` does not (the staleness escape survives); and `branches`
   no longer recognises the `td/` namespace at all — a live `td/*` ref
   matches nothing it lists, regardless of its age or its registry entry.
   `test/noop-skip.test.sh` covers
   the fingerprint half: a fresh entry added to `claimed` changes the
   fingerprint, and an empty `claimed` array canonicalises identically to an
   absent key, so a claim ageing back out of the array changes it too — the
   same silent-stall shape `abandoned_drafts` and `merge_conflicts` close for
   their own transitions.
7d. <a id="impl-ac-7d"></a>**The PR-keyed claim outlives the PR's own raising (requirement 17a,
   issue #360).** `test/pr-claim-hold-through-review.test.sh` passes: with
   `release_claim` and `release_pr_claim` lifted from `lib/candidate-select.sh`
   and
   the real `lib/claim.sh` running against a create-only `gh` stub,
   `have-pr-pending` drops the item-keyed registry entry and leaves the
   `pr-<n>` one standing; a peer's own claim on that same `pr-<n>` loses
   (rc 3) for as long as it stands, and wins only once `release_pr_claim`
   has run; `release_pr_claim` is idempotent; `have-pr`/`no-pr` still
   drop both entries together in the one call, the ordinary end-of-cycle
   shape; and an unhandled `errexit` abort after `pr-raised` — the one
   ending no handler reaches — still releases the `pr-<n>` entry through
   the EXIT trap's backstop, proven by running the real `cleanup` under
   `set -e`. `test/claim.test.sh` covers the back-pressure half: `count`
   counts the item-keyed entry a cycle just won and does not count a
   `pr-<n>` entry surviving on its own; and, given the pull requests the
   caller has already counted, it drops an item claim naming one of them
   while keeping a claim on a PR the caller's sum does not hold — matching
   whole numbers, so a claim on PR 90 survives a caller that counted PR 9.
7e. <a id="impl-ac-7e"></a>**The back-pressure block hands its parts to each other correctly
   (requirement 2.2).** The counting seam, not the parts: issue #427 and the
   over-correction in PR #434 were both defects of this wiring, and both
   shipped past a suite that tested `lib/claim.sh count` thoroughly and its
   caller not at all. `test/backpressure-wiring.test.sh` passes, against the
   block lifted verbatim from `agent-cycle.sh` with a `gh` stub replaying a
   listing per repo and a `lib/claim.sh` stub recording its argv: each repo's
   claim count is asked for against that repo's own drafts and
   pipeline-owed PRs and no others, so a claim on an approved PR waiting
   on a human keeps counting; a repo whose listing could not be read names no
   PRs at all, counting every claim, which is the fail-closed reading beside
   its own zeroed counts; and the composition line states the split the
   operator and the dashboard card both read. The same test covers the
   exclusion's level-awareness (D18 WI-6, requirement 2.3c): the identical
   approved, non-`CHANGES_REQUESTED` pull request is excluded for a repo at
   `human` and counted for one whose `merge_autonomy_effective_level` is
   `agent-merges-routine`, and in the counted case its claim does not
   double-count on top of it — so the difference is demonstrably the level
   and not a change to the underlying rule.
7f. <a id="impl-ac-7f"></a>**The decision site folds in what requirement 2.2's count could not see
   yet (requirement 2.2b, issue #459).** `test/backpressure-decision.test.sh`
   passes, against the fold-in block lifted verbatim from `agent-cycle.sh`: a
   repo with no `merge_conflicts`/`dequeued` candidates adds nothing and
   leaves `adjusted_open_count`, `open_composition` and `backpressure_tripped`
   untouched; a candidate PR already among `counted_prs_json`'s drafts and
   pipeline-owed PRs (it happened to also be `CHANGES_REQUESTED`) is not
   added again; a candidate PR that count did not hold is added exactly once,
   grows `adjusted_open_count` by it, and is named in `open_composition`; the
   same PR named by both `merge_conflicts` and `dequeued` is not
   double-counted; two repos' candidates are both folded in, and a PR number
   shared by two repos is scoped per repo rather than conflated; a fold-in
   that reaches `max_open_agent_prs` trips `backpressure_tripped` from `0` to
   `1` even though requirement 2.2's own count left it untripped; and an
   already-tripped cycle with nothing left to fold in stays tripped without
   its composition line changing.
