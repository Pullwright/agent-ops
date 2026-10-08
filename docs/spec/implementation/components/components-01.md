## Components

What exists, and the requirements each part answers to:

1. `config.json` with the values above.
2. `agent-cycle.sh` implementing requirements 1–13 (including the findings
   pre-fetch, requirement 3a; the switches, requirements 2.3, 2.3a and 2.3b;
   the role guard, requirement 2.4; and the
   implementation-plan path passthrough and its startup validation,
   requirement 3k) — the cycle's own spine: argument handling, the
   lock, the management commands (`run_manage_command`, `lib/manage.sh`,
   #771), the eligibility pass (`lib/eligibility.sh`, #771), the stand-down
   reason ladder (`run_standdown_checks`, `lib/
   standdown.sh`, #771), the claim loop and candidate selection (`lib/
   candidate-select.sh`, #771), the ordered sequence of phases, and the exit
   path. Two of those phases are whole modules of their own: the gather-fit
   phase (`run_gather_phase`, `lib/gather-phase.sh`, #1958) and the
   Co-Ordinator-through-finishing sequence
   (`run_coordinator_through_finishing_phase`, `lib/coordinator-phase.sh`,
   #1958), which between them carry the no-op short-circuit (requirement 3b)
   and the Refiner-only pre-fetch's `refiner_repos_json` copy (requirement
   3y) this file calls through to. The Enabler's engagement, requirements
   35–37 — `maybe_run_enabler`
   (the single call site in the cleanup, every guard, and the per-verdict
   actions), `enabler_claim_key` and `create_escalation_issue` — is
   `lib/enabler.sh` (#771), sourced and called from the cleanup trap exactly
   as it was inline.
2a. `lib/standdown.sh` implementing requirement 2, the stand-down reason
   ladder in full: `run_standdown_checks`, called once from `agent-cycle.sh`
   in place of the inline block it replaces (#771) — the GitHub API budget,
   credential and free-disk-space checks (2.0, 2.0b, 2.0c), the fleet-wide
   usage-limit cooldown and
   its own probe (2.1), the per-cycle claim GC and orphan-branch/closing-
   keyword/human-visibility/Approver-restale/landing-retry/classifier-escape/
   reservation-release-retry sweeps (2.1a–2.1g, and requirement 46's own
   sweep between the human-visibility and landing-retry ones — the call site
   only: the sweep itself is `lib/approver.sh`, component 14c), and
   back-pressure across every configured repository (2.2).
   Reads and writes `agent-cycle.sh`'s own cycle-state globals directly
   (`backpressure_tripped`, `open_composition`, `adjusted_open_count`,
   `counted_prs_json`, among others) rather than through return values, the
   same way the inline block it replaces did — deliberately not `local`, so
   the call is indistinguishable, to the rest of the cycle, from the code it
   replaces. Sourced, never executed. Must pass `shellcheck`.
2b. `lib/candidate-select.sh` implementing the claim loop and candidate
   selection (requirements 3o, 3p, 3t, 3u, 17f, among others; #771): the
   per-source gatherers (`gather_findings`, `gather_review_feedback`,
   `gather_abandoned_drafts`, `gather_merge_conflicts`, `gather_dequeued`,
   `gather_human_visibility_hygiene`,
   `gather_issues`, `gather_issues_excluded`, `gather_tech_debt`,
   `gather_project_review_candidates`, `gather_implementation_plan_candidates`,
   `gather_unvoid_requests`, `gather_hand_flagged_refinements`,
   `gather_source_state`, `gather_register_status`, `gather_review_status`,
   `gather_review_current`, `gather_plan_status`, `gather_workflow_basenames`),
   the claim exclusion and
   blocked/void filters (`exclude_claimed_prs`, `exclude_claimed_items`,
   `exclude_blocked_or_void_items`, `exclude_blocked_or_void_issues`,
   `exclude_decision_pending_items`,
   `candidate_preclaimed`, `pr_number_for_candidate`), `emit_first_seen`,
   `coordinator_blocked_view`/`coordinator_refinements_view`, the
   refinement-traceability check and repair from #768
   (`refinement_traceability_fault`/`refinement_traceability_repair`), and the
   needs-refinement/voided accounting the Co-Ordinator's verdict is checked
   against (`unaccounted_items`, `coordinator_eligible_items`,
   `record_needs_refinement_block`, `log_needs_refinement_items`,
   `log_voided_items`, `log_unblocked_items`, `log_recheck_clean_items`,
   `release_refinement_label`, `detect_and_log_limit_hit`). Also carries
   `release_claim`/`release_pr_claim`/`claim_branch_for` (requirement 17a's
   own item-keyed and PR-keyed claim release, moved beside the code that
   calls them). Sourced, never executed. Must pass `shellcheck`.
2c. `lib/stage-attempt.sh` implementing the Co-Ordinator stage-attempt
   sequence and the failure handling every stage shares (requirement 3v,
   4d and 4i; #771; issue #587): `run_coordinator_stage_attempt` (one
   launch/parse/salvage attempt, called once per configured repository —
   requirement 15), `fallback_select_candidate` (the mechanical last resort
   once a `none-selected` verdict has failed corroboration — requirement 3v),
   `coordinator_merge_candidates` (the Script's own cross-repository
   reconciliation of every repository's own returned candidates —
   requirement 15z), and
   `extract_json_result`/`stage_salvage_result`/`dump_stage_output`/
   `stage_api_refusal`/`stage_api_refusal_message`/`handle_stage_failure`,
   used by every stage this pipeline runs. Sourced, never executed. Must
   pass `shellcheck`.
2d. `lib/candidate-gather.sh` implementing the repo-ordering/candidate-
   gathering loop and the skip-list extracts built directly on top of it
   (requirement 3, the requirement-34 blocked/void skip-lists; #771):
   `gather_ordered_repos` orders every configured repository by effective
   staleness (`lib/repo-order.sh`) and, for each, folds claims, first-seen
   state and the per-repo entry into `ordered_repos_json`/
   `source_states_json`/`claimed_json`/`unvoid_requests_json`/
   `hand_flagged_refinements_json`. Every pre-fetched source's gather script
   runs fresh only for the one repository `expensive_gather_pick_repo`
   (`lib/expensive-gather-cache.sh`) picks this cycle (requirement 48); every
   other configured repository's eight bands come from that same node's
   cache of its own last turn, with this cycle's `sources` gating and claim
   exclusion re-applied regardless.
   `compute_skip_lists` reconciles the `unvoid`/hand-flagged
   `needs_refinement` label overrides against the cycle's own claim, then
   derives `blocked_json`/`void_json`, the skip-lists everything downstream
   (eligibility, the Enabler's threshold, the Co-Ordinator's input) reads.
   Both are pure moves out of `agent-cycle.sh`'s own top-level script body —
   never before functions, so their bodies keep the original top-level
   indentation rather than being reformatted as a function's own — reading
   and writing the cycle's own globals exactly as they did inline. Sourced,
   never executed, called once each from `agent-cycle.sh` in place of the
   inline block they replace. Must pass `shellcheck`.
2e. `lib/manage.sh` implementing requirement 2.3's management commands in
   full (#771): `run_manage_command`, called once from `agent-cycle.sh` in
   place of the inline block it replaces, before the lock and before any `gh`
   call — `--status`, `--disable`, `--enable`, `--clear-limit` and
   `--kill-merge-autonomy`, together with the five reporters they print
   through (`toggle_status_report`'s companions `fleet_status_report`,
   `limit_status_report`, `merge_autonomy_status_report`,
   `current_limit_record` and `refresh_dashboard`). Returns at once when no
   management action was asked for, so the call site carries no guard of its
   own; every action it does handle exits the process, so nothing after the
   call site is reachable from one. Reads the cycle's own globals directly and
   declares nothing `local`, the same way `run_standdown_checks` does and for
   the same reason. Sourced, never executed. `merge_autonomy_status_report` is
   lifted verbatim out of this file by `test/merge-autonomy.test.sh`
   (acceptance check for #454), and the whole of it is exercised end-to-end
   through `agent-cycle.sh --disable`/`--enable`/`--status` in
   `test/toggle.test.sh`. Must pass `shellcheck`.
2f. `lib/eligibility.sh` implementing requirements 3t/3u, 35a/35b, 3y and 39a
   (The Refiner) (#771): what this cycle is allowed to act on, once the gatherers have
   finished and before anything is offered to a model.
   `compute_band_eligibility` runs every pre-fetched band but `issues`
   through `exclude_blocked_or_void_items` (`issues` has its own narrower
   pass through `exclude_blocked_or_void_issues`) and settles
   `refinements_json`; before that subtraction it snapshots
   `live_pr_refs_json` and `live_td_refs_json` — requirement 35e's two live
   sets — from the untouched
   gather, because the entries the subtraction removes are exactly the ones
   that filter is asked about (issue #1119; `live_td_refs_json` widened this
   the same way by issue #1699). It settles `decisions_json` alongside
   `refinements_json` and then, only where `refiner_model` is set, makes a
   further subtraction of its own, over the same bands:
   `exclude_decision_pending_items` withholds every item that map still names
   a pending `decide-tactical` decision for, unless the item's own `.source`
   resolves `refinement_policy`-exempt (requirement 36d, agent-ops#1057),
   under a loop variable deliberately distinct from the generic pass's so
   each list stays separately pinnable. Immediately before that pass — and so
   after the blocked/void subtraction, never before it — it snapshots
   `refiner_prefetch_source_json` for `prefetch_refiner_sources` to seed from,
   for the mirror of the reason `live_pr_refs_json` is snapshotted above: an
   item this pass withholds from the Co-Ordinator is exactly one the Refiner
   must still see, since only a Refiner engagement reaching it can ever
   supersede the decision and lift the withholding (requirement 3y). Both
   gates — the per-entry policy check and the per-cycle `refiner_model`
   check — exist for the same reason: withholding an item nothing could ever
   restore would make it permanently invisible rather than withheld for one
   cycle, reopening the hole agent-ops#1049 closed (the Reviewer's and the
   Enabler's finding on PR #2047).
   `compute_enabler_eligible_set` derives
   `enabler_eligible_json` from the source-state digests of the repositories
   that sampled cleanly — how "is that escalation issue still open?" is
   answered without a `gh` call per escalation — consumes both snapshots for
   requirement 35e's filter, and ends by setting
   `enabler_allowed`. `prefetch_refiner_sources` seeds `refiner_repos_json`
   from that snapshot and fetches the Refiner's own
   two extra sources into it, which `ordered_repos_json`
   deliberately never gains. `compute_refiner_candidates` derives
   `refiner_candidates_json` from the same extracts the Enabler set just
   used — so a Refiner and an Enabler engagement in the same cycle can never
   disagree about what is already spoken for — and ends by setting
   `refiner_allowed`. Four functions in one module rather than four modules
   because they answer one question between them over the same inputs, in an
   order that matters. All four are pure moves out of `agent-cycle.sh`'s own
   top-level script body — never before functions, so their bodies keep the
   original top-level indentation, the same way `lib/candidate-gather.sh`'s
   do — reading and writing the cycle's own globals exactly as they did
   inline, `enabler_allowed`/`refiner_allowed` included. Sourced, never
   executed, called once each from `agent-cycle.sh` in place of the inline
   blocks they replace. `test/cycle-state.test.sh` reads the band list out of
   this file and `test/refiner-priority-triage.test.sh` lifts the Refiner
   pre-flight's own `refiner_model` call-site guard from it. Must pass
   `shellcheck`.
2g. `lib/expensive-gather-cache.sh` implementing requirement 48
   (agent-ops#1086): the per-node cache `gather_ordered_repos` reads and
   writes so its eight expensive bands are read fresh from GitHub for one
   configured repository per cycle rather than every one of them.
   `expensive_gather_pick_repo` picks the configured repository whose cache
   file (under `state_dir/expensive-gather/`) is oldest, ties broken by
   slug — slicing its own sorted stream with a reader that consumes its
   input (`sed -n '1p'`, never `head`), because its caller takes it in
   `$(…)` under `set -e` and `pipefail` would promote the `sort`'s SIGPIPE
   to a whole aborted gather (agent-ops#806, the same rule
   `scripts/state-sync.sh`'s `kept_cycles` follows);
   `expensive_gather_cache_load`/`expensive_gather_cache_save` read
   and atomically write that repository's raw gather. Sourced, never
   executed, ahead of `lib/candidate-gather.sh` (its only caller). Must pass
   `shellcheck`. `test/expensive-gather-cache.test.sh` exercises all three
   functions directly: the epoch-0 tie-break for a never-cached repository,
   round-tripping a saved snapshot, the pick rotating to the next-oldest
   cache once one repository is saved, a never-cached repository always
   outranking any already-cached one, an empty configured set picking
   nothing, a corrupt cache file loading as empty rather than raising a
   parse error, and a configured set past one pipe buffer picking cleanly
   rather than 141.
2h. `lib/gather-phase.sh` implementing the phase between the repo-ordering/
   candidate-gathering loop and the Co-Ordinator stage itself (requirements
   3b, 3y and 2.2a among them; #1958, continuing #771's split):
   `run_gather_phase`, called once from `agent-cycle.sh` in place of the
   inline block it replaces, runs — in this order — `gather_ordered_repos`/
   `compute_skip_lists` (`lib/candidate-gather.sh`), the band eligibility and
   Enabler/Refiner pre-fetch pass (`lib/eligibility.sh`), the decision-veto
   sweep and pending decision acts (`lib/decision-veto.sh`), back-pressure's
   narrowing of the finishing sources (requirement 2.2a), the requirement-4i
   prompt-fit ladder (`lib/coordinator-input.sh`) and the no-op short-circuit
   (requirement 3b, `lib/noop-skip.sh`). Several of its paths exit the cycle
   outright — a stand-down, a back-pressure trip, a no-op — so the
   Co-Ordinator stage below it is reached only when there is a prompt worth
   sending. The requirement-4i machinery's *placement* in that order is
   deliberate and unchanged by the move (`lib/coordinator-input.sh`'s own
   header records why: the 2026-08-21 context-overflow outage). A pure move
   out of `agent-cycle.sh`'s own top-level script body — never before
   functions, so the body keeps the original top-level indentation, the same
   way `lib/candidate-gather.sh`'s and `lib/eligibility.sh`'s do — reading
   and writing the cycle's own globals exactly as it did inline. Sourced,
   never executed. Must pass `shellcheck`.
2i. `lib/coordinator-phase.sh` implementing the Co-Ordinator-through-
   finishing phase sequence, the whole of the cycle from the Co-Ordinator
   stage to the exit (requirements 4, 8b, 15, 17a and 31c among them; #1958,
   continuing #771's split): `run_coordinator_through_finishing_phase`,
   called once from `agent-cycle.sh` as that file's own final statement, runs
   the Co-Ordinator stage itself (one invocation per configured repository,
   issue #587, through `lib/stage-attempt.sh`), candidate selection and the
   claim (`lib/candidate-select.sh`, `lib/claim.sh`), the workspace and
   clone, the Implementer stage, the Reviewer stage and its handoff
   (`lib/handoff.sh`, `lib/reconciliation-gate.sh`), the Approver stage
   (`lib/approver.sh`) and the landing-arming step (`lib/landing.sh`).
   Carries three functions of its own, defined and called within the one
   invocation exactly as they were inline: `ensure_labels_for` (requirement
   6a's per-repository label ensure), `premerge_rebase_only_capture` and
   `rebase_only_advisory_check`. Its claim dispatch holds one of the two
   copies of requirement 17a's existing-branch source list that must agree
   with `PREFLIGHT_EXISTING_BRANCH_SOURCES` (`lib/preflight.sh`). The
   `review-gate-checks-read` event it logs keeps its own
   `agent-cycle.sh:review-gate-checks-read` detector string, which names the
   Reviewer-handoff *site* as distinct from `lib/enabler.sh`'s
   handoff-recovery one (`lib/rework.sh`) and is a value downstream readers
   key on, not a file path. A pure move out of `agent-cycle.sh`'s own
   top-level script body on the same terms as `lib/gather-phase.sh` above;
   several `test/*.test.sh` files lift blocks out of it by literal pattern,
   the same way they did out of `agent-cycle.sh` before the move. Sourced,
   never executed, last of every `lib/*.sh` file its body calls into. Must
   pass `shellcheck`.
3. `scripts/gather-findings.sh` implementing requirement 3a: given a repo
   slug, prints a normalised JSON array of the repo's open Dependabot and
   code-scanning alerts, degrading to `[]` (exit 0) when a feature is
   disabled or inaccessible. Must pass `shellcheck`.
3c. `scripts/gather-review-feedback.sh` implementing requirement 3c: given a
   repo slug, PR label and branch prefix, prints the JSON array of PRs awaiting
   our reply to a human's review, each carrying every review body and inline
   comment in the round verbatim. Fails safe to `[]` (exit 0). Must pass
   `shellcheck`.
3f. `scripts/gather-abandoned-drafts.sh` implementing requirement 3e: given a
   repo slug, PR label, branch prefix and staleness threshold, prints the JSON
   array of this system's own abandoned draft PRs (open, draft, ours, whose last
   real activity — the head commit, and the reviews and comments not carrying
   `lib/pipeline-marker.sh`'s marker — is untouched past the threshold), each
   carrying the draft PR's body verbatim and a head-SHA-scoped ref. A PR either
   of whose nested collections `gh pr list` returned at its 100-item cap, or
   whose head-commit date could not be read, is excluded for the cycle rather
   than judged on possibly-incomplete activity (requirement 3e). Its
   candidate rule is regression-tested in `test/abandoned-drafts.test.sh`. Fails
   safe to `[]` (exit 0). Must pass `shellcheck`. Sources
   `lib/pipeline-marker.sh`, which implements the write side of the same
   requirement and, together with it, requirement 9d's visible attribution:
   `PIPELINE_COMMENT_MARKER_PREFIX`, the fixed substring this script matches
   on; `pipeline_comment_marker CYCLE_ID ACTOR`, which every pipeline-authored
   PR or issue comment is stamped with; `pipeline_actor_label TOKEN`, the Actor
   token→display map, failing open on an unknown token; and
   `pipeline_comment_header ACTOR NODE`, the leading visible line every such
   comment opens with. `agent-cycle.sh`'s and `review-cycle.sh`'s own comments
   call these directly; the Implementer's, Enabler's, Reviewer's and Refiner's
   comment instructions (`prompts/implementer.md`, `prompts/enabler.md`,
   `prompts/reviewer.md`, `prompts/refiner.md`) spell both the header and the
   marker out literally, via the cycle id and node name each receives at
   invocation. One definition
   (requirement 34a): the reader and every writer that is a shell source this
   file, and the four prompts — which a model reads, so they must spell both
   forms out — are asserted against `PIPELINE_COMMENT_MARKER_PREFIX` by
   `test/abandoned-drafts.test.sh` and against the header's literal form by
   `test/comment-identity.test.sh`, so neither can drift between any of them.
   This file also defines requirement 31c's own citation line the same way:
   `PIPELINE_RECONCILES_MARKER_PREFIX`, the fixed substring
   `lib/reconciliation-gate.sh` (component 20a) matches on, and
   `pipeline_reconciles_marker COMMENT_ID`, which prints
   `<!-- agent-ops:reconciles comment=COMMENT_ID -->` — the line a pipeline
   comment carries to cite a standing human comment as reconciled.
   `prompts/reviewer.md` is the one place that spells this form out literally
   (a model reads prose, not shell), and `test/comment-identity.test.sh`
   asserts it against `pipeline_reconciles_marker`'s own output, the same way
   it pins the header above.
3g. `scripts/gather-merge-conflicts.sh` implementing requirement 3g (extended by
   requirement 3s for Dependabot's own PRs): given a
   repo slug, PR label and branch prefix, prints the JSON array of ready-but-
   conflicted PRs — this system's own (open, non-draft, ours, `mergeable`
   definitively `CONFLICTING`) and Dependabot's own (same, but by authorship
   instead of label/branch) — each carrying the PR's body verbatim, its base,
   and a head-SHA-scoped ref; a Dependabot entry additionally carries `bot:
   true`, `rebase_requested`, `superseded_by` and (when superseded)
   `superseded_evidence`. Fails safe to `[]` (exit 0). Must pass `shellcheck`.
3s. `lib/dependabot-bump.sh` and `scripts/nudge-dependabot-rebase.sh`
   implementing requirement 3s. The library holds `DEPENDABOT_LOGIN`
   (`app/dependabot`, the login Dependabot's PRs carry through `gh`'s
   GraphQL-backed `--json` reads), `dependabot_rebase_marker` (the
   head-SHA-scoped HTML-comment marker `gather-merge-conflicts.sh` reads and
   `nudge-dependabot-rebase.sh` writes), `dependabot_bump_family` and
   `dependabot_bump_version` (parsing a Dependabot branch name into a
   dependency+manager family and a target version), and
   `dependabot_newer_open_pr` (given a PR's number, branch and every open
   Dependabot PR in the repo, the number of another one bumping the same
   family to a strictly newer version, via `sort -V`, if any). The script
   takes, on stdin, the merge-conflicts candidate array
   `gather-merge-conflicts.sh` produced for one repo, and for every candidate
   carrying `bot: true`, `rebase_requested: false` and no `superseded_by`,
   posts a `@dependabot rebase` comment (this system's ordinary comment
   header and marker, plus the rebase marker) and drops that candidate from
   the array it prints back on stdout as `{"conflicts": [...], "actions":
   [...]}` — `actions` records one `{"number", "outcome": "requested"|
   "failed"}` per attempt, for the caller to log; a `"failed"` outcome is not
   retried within the same run, since the candidate it would have retried was
   already dropped from `conflicts` either way, and the next cycle's
   `gather-merge-conflicts.sh` read (still reporting `rebase_requested:
   false`, since no comment landed) causes the same attempt again. Every other
   candidate (not a bot PR, already nudged, or superseded) passes through
   `conflicts` untouched with no action recorded. Fails safe to
   `{"conflicts": [], "actions": []}` on unreadable stdin. Both must pass
   `shellcheck`; `lib/dependabot-bump.sh`'s parsing and comparison rules are
   regression-tested in `test/dependabot-bump.test.sh`, the script's
   nudge/drop/pass-through behaviour in `test/nudge-dependabot-rebase.test.sh`,
   and the two together (through the real `gather-merge-conflicts.sh`, via
   `MERGE_CONFLICTS_GH`) in `test/merge-conflicts.test.sh`.
3z. `scripts/gather-dequeued.sh` implementing requirement 3z: given a repo
   slug, PR label and branch prefix, prints the JSON array of this system's
   own PRs (open, non-draft, ours, `mergeable` exactly `MERGEABLE`) whose most
   recent `lib/merge-queue.sh` `merge_queue_probe` reports `queued: false`, a
   non-null `dequeued_at`, and `dequeue_reason` reading, case-insensitively,
   `failed_checks`, and whose dequeue `lib/handoff.sh`'s
   `handoff_round_answered` reports still `unanswered` as of `dequeued_at` —
   each carrying the PR's body verbatim, its base, a head-SHA-scoped ref, and
   the probe's own `dequeued_at`/`dequeue_reason`, ordered by `dequeued_at`
   oldest first. Fails safe to `[]` (exit 0), including on a reviews or
   comments read it cannot make. Must pass `shellcheck`; its candidate rule is
   regression-tested in `test/gather-dequeued.test.sh`.
53. `scripts/gather-landing-refusals.sh` implementing requirement 53: given a
   repo slug, PR label, branch prefix and the fleet-wide union log, prints the
   JSON array of this system's own PRs (open, non-draft, ours) whose most
   recent `landing-refused` event (read from the union log via
   `lib/landing.sh`'s `landing_latest_refusal_reason`) has a `reason`
   beginning `reconciliation-unanswered:` or `reconciliation-unreadable:`, and
   which `lib/reconciliation-gate.sh`'s `reconciliation_unreconciled_comments`
   (asked fresh, unbounded) still reports at least one unreconciled comment
   for — each carrying the PR's `head_sha`, the refusal's own
   `refused_at`/`reason`, every unreconciled comment as
   `{id, at, author, body}`, an assembled `body` of the same verbatim and
   oldest-first, and a ref scoped to the sorted, hyphen-joined set of
   unreconciled comment ids, ordered by `refused_at` oldest first. Fails safe
   to `[]` (exit 0), including on a timeline or comments read it cannot make.
   Must pass `shellcheck`; its candidate rule is regression-tested in
   `test/gather-landing-refusals.test.sh`.

   `lib/reconciliation-gate.sh` gains `_reconciliation_gate_unreconciled`
   (the "unreconciled" test `reconciliation_gate` itself uses, factored out
   for reuse — requirement 34a), the public `reconciliation_unreconciled_
   comments`, and a `who` field on `_reconciliation_gate_comments`'s own
   output; `reconciliation_gate` itself is behaviour-unchanged and remains
   regression-tested in `test/reconciliation-gate.test.sh`.
   `lib/landing.sh` gains `landing_latest_refusal_reason PR_URL [LOG_FILE]`,
   the same `LOG_FILE`/stdin convention `landing_retry_tier` already
   established, printing `TS<TAB>REASON` for the most recent `landing-refused`
   event logged against PR_URL, or nothing.

   `gather_landing_refusals` (`lib/candidate-select.sh`) and its wiring into
   `lib/candidate-gather.sh`'s per-repo gather loop are otherwise identical to
   `review-feedback`/`merge-conflicts`/`dequeued`: gated on `sources` naming
   `landing-refusals`, read as a tenth expensive-gather band (`lib/expensive-
   gather-cache.sh`) alongside its nine siblings, and claim-excluded
   (`exclude_claimed_prs`/`exclude_claimed_items`) and first-seen-emitted
   the same way. Deliberately **not** folded into requirement 2.2a's
   four-source back-pressure/drain finishing set (`lib/drain.sh`'s own ref
   pattern and band count), nor into the claim-pattern/void-guard parity
   the other four finishing sources share (`lib/claim.sh`, `lib/void-
   guard.sh`) — a candidate here is selectable exactly like `human-
   visibility`: within the ordinary repo-then-source walk, at its configured
   rank, never given a cross-repo priority bump nor counted toward back-
   pressure exemption. Extending that parity is a separate policy decision
   this item's own refined scope did not ask for.

   `scripts/sweep-human-visibility.sh`'s idle nudge (requirement 38c) takes
   an optional fourth argument, the fleet-wide union log; when a pull
   request's most recent `landing-refused` event reads
   `reconciliation-unanswered:`/`reconciliation-unreadable:`, and a fresh
   `reconciliation_unreconciled_comments` call still confirms it, the nudge
   text names that reason instead of "waiting on a merge click" — reusing the
   existing `<!-- agent-ops:human-nudge -->` marker's once-per-state
   suppression unchanged. `lib/standdown.sh`'s own call site passes
   `union_log` as this fourth argument. Regression-tested in
   `test/sweep-human-visibility.test.sh`.
3t. `scripts/gather-human-visibility-hygiene.sh` implementing requirement 38e:
   given a repo slug and this repo's slice of
   `human_visibility_violations` (`lib/human-visibility-hygiene.sh`, a pure
   reduction over the log union), prints a JSON array holding at most one
   candidate — the violations that survive a live, read-only re-check (a
   repo-level listing failure only if the listing still fails; a pull request
   only if it is still open and not a draft, and its own warning class's own
   live signal still holds: a `could not request review from …` warning only
   while `gh pr view --json reviewRequests,reviews` shows no live
   request (Bot-typed — `__typename`-keyed on this reader — and
   `[bot]`-suffixed entries excluded, a requested team
   counted — tech-debt/TD-PPagop-26081403.md) and no non-bot review with
   state `APPROVED` or `CHANGES_REQUESTED` yet given — never read from
   `reviewDecision` (agent-ops#391, TD-PPagop-26081505); a
   `could not read the pull request's reviews …` warning
   (`_handoff_pr_approved`'s own read failing inside the idle-nudge check)
   drops unconditionally once the `gh pr view` call this re-check opens with
   succeeds at all: since agent-ops#1085 moved `_handoff_pr_approved`
   (`lib/handoff.sh`) onto the same GraphQL surface this `gh pr view` call
   already asks `reviews` from, a successful read here already *is* proof
   the read that failed now works, and no second call is made to confirm it
   (before that migration, that read was a separate REST `gh api …/reviews
   --paginate` call, a different API surface a successful `gh pr view`
   proved nothing about, and this re-check ran it a second time to find
   out); a
   `could not read the pull request's state …` warning
   (`scripts/sweep-human-visibility.sh`'s own broad `gh pr view --json
   reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,reviews,
   comments` call — the read that gates every downstream check the sweep
   makes for a pull request — failing) only while re-running that same call
   verbatim still fails; the narrower `gh pr view` this re-check opens with
   omits `statusCheckRollup` entirely and proves nothing about it on its own
   either; a
   `could not post the idle nudge comment` warning only while no comment
   carries both the exact `agent-ops:human-nudge` HTML-comment form and the
   pipeline-marker stamp on the same comment (agent-ops#390, #428); a `no legal
   review-request candidate` warning (tech-debt/TD-PPagop-26081001.md) only
   while `gh pr view --json author,reviews,reviewRequests` still shows no
   non-author, non-bot, submitted review, no review request already pending
   under that same filter, and `enabler_assignee` — read back out of the
   warning's own detail text — still names the pull request's own author; a
   `could not post the merge-queue-dequeued notice` warning
   (TD-PPagop-26081504) only while no comment carries the
   `agent-ops:merge-queue-dequeued:` marker, the same kind of read the idle
   nudge's own class makes for its own marker;
   any other warning shape for as long as the pull request stays open and
   not a draft; an unreadable re-check is kept, not dropped) — carrying a
   ref scoped to the surviving violations' own identities and details
   (`human-visibility-<hash>`), a
   `problems` line per violation and a body naming each one and the timestamp
   of the latest event that carried it (the one the reduction kept). Its own
   source, `source: "human-visibility"`, ranked immediately after
   `merge-conflicts` (config.schema.json); the Co-Ordinator's and
   Implementer's prompts give it its own section, because the work order it
   deserves is not the same as another source's. Called for every repo
   whose `sources` include `human-visibility`, whenever
   `human_visibility_violations` names that repo, and assigned to that
   repo's own `human_visibility` array. Sources `lib/github-limit.sh` like
   every other gatherer (requirement 2.0a), which matters more here than most:
   an unreadable re-check keeps its violation, so a rate-limit refusal taken
   at face value would offer a candidate for a violation that had already
   resolved. No violations, or none surviving the
   live re-check, is `[]` (exit 0) — the ordinary answer almost every cycle
   gets. Regression-tested in `test/gather-human-visibility-hygiene.test.sh`,
   (the reduction) `test/human-visibility-hygiene.test.sh` and (the Script's
   own gate and assignment between the two) `test/human-visibility-wiring.test.sh`;
   must pass `shellcheck`.
3j. `scripts/gather-issues.sh` implementing requirement 3j: given a repo slug,
   prints `{"candidates": […], "excluded": […]|null}`. `candidates` is the
   JSON
   array of the repo's candidate issues — open, unassigned, not labelled
   `blocked`, naming no unresolved `Blocked-by:` reference (requirement 34j,
   each reference's state checked live once the candidate's whole thread is
   in hand), pull requests dropped, and `pw::type:tech-debt`-labelled issues
   dropped on the same unreported terms (they are the `tech-debt` band's,
   requirement 3t) — each carrying the bare issue number as
   its ref, the `Priority` band (default `Medium`, read as the source-state
   digest reads it), and the whole thread verbatim (`body` plus `comments`).
   `excluded` is `{number, reason}` for every issue the three deterministic
   drops above removed (never a pull request), `reason` one of `"assigned"`,
   `"blocked-label"`, `"blocked-by: <ref>"` (agent-ops#447). Fails safe to
   `{"candidates":[],"excluded":null}` (exit 0) with failures loud on stderr —
   `excluded` is `null`, not `[]`, because a filter that did not run to
   completion does not know the set to be empty (requirement 3j).
   Its filter and shape are regression-tested in `test/issues-prefetch.test.sh`
   and `test/dependency-gate.test.sh`; must pass `shellcheck`.
3t. `scripts/gather-tech-debt.sh` implementing requirement 3t: given a repo
   slug — and nothing else, since an issue is not read off a branch — lists
   that repo's open issues carrying the `pw::type:tech-debt` label and prints
   the JSON array of the ones that survive the deterministic filter it shares
   with `scripts/gather-issues.sh` (`lib/issue-prefetch.sh`: not a pull
   request, not assigned, not labelled `blocked` whatever the case, and
   naming no still-open `Blocked-by:` reference — requirement 34j), each
   carrying `source: "tech-debt"`, its bare issue number as `ref` (a string)
   and as `number`, `url`, `title`, `labels`, `author`, `created_at`,
   `updated_at`, its `body`, and its whole comment thread verbatim as
   `comments` — sorted by issue number ascending. A repo with no such issues
   prints `[]`; an API failure prints `[]` with `gh`'s diagnosis on stderr.
   Fails safe to `[]` (exit 0). Claimed/blocked/
   void exclusion is deliberately not this script's job — the cycle applies
   `exclude_claimed_items` and the new `exclude_blocked_or_void_items`
   (both in `lib/candidate-select.sh`, alongside `exclude_claimed_prs`) once the
   repo's claim/blocked/void state is in hand, so there is one definition of
   each exclusion rather than one per gatherer. Its shape is
   regression-tested in `test/gather-tech-debt.test.sh`; must pass
   `shellcheck`.
3y. `scripts/gather-project-review.sh` implementing requirement 3y's
   project-review half: given a repo slug, default branch and — optionally —
   that repository's own resolved `report_directory`
   (`docs/spec/review.md` R4a: a GNU `date`(1) format string,
   defaulting here to `reviews/project-review-%Y-%m-%d`, so a caller passing
   only the first two arguments reads the shipped layout), reads the latest
   existing directory that format names — the only one ever live, discovered
   through the shared `lib/report-directory.sh` rather than a fixed pattern,
   so this gatherer and `review-cycle.sh`'s own skip-guard cannot answer
   "which review is current" two different ways for the same repository. The
   resolved directory is what `lib/eligibility.sh`'s Refiner pre-fetch passes
   (per repository, resolved by `config_repository_review_repos`). Prints the
   JSON array of that review's recommendations, one per
   `## R-NN` section of `03-recommendations.md`, each carrying
   `review-<date>-R-NN` as `ref`, its `id`, `review_date`, `title`, `url`,
   the section verbatim as `body`, and the fenced prompt body for the same id
   from `04-improvement-prompts.md` as `improvement_prompt` — everything
   between the first and the last fence line of that prompt's section, so a
   prompt with a nested code block of its own arrives whole rather than
   truncated at it; sorted by recommendation number ascending, the review's
   own priority order. A repo with no report directory at all, none the
   format's own past instances match, or no `03-recommendations.md` in the
   latest prints `[]` silently; an API failure prints
   `[]` with `gh`'s diagnosis on stderr. Fails safe to `[]` (exit 0). Its
   shape is regression-tested in
   `test/gather-project-review.test.sh`; must pass `shellcheck`.

   Given `--current-date` before the repo slug, performs only the `reviews/`
   listing — never fetching `03-recommendations.md`/
   `04-improvement-prompts.md` — and prints one JSON object instead of the
   candidate array: `{"ok": true, "date": "2026-08-10"}` when a review
   folder resolves, `{"ok": true, "date": ""}` when the listing succeeds and
   offers none at all (including a clean 404 on `reviews/` itself — a
   definite fact), or `{"ok": false}` for any other failure, which decides
   nothing. The empty date is read off `report_directory_most_recent`'s own
   exit status, not merely its empty output: `lib/report-directory.sh`'s walk
   (`_report_directory_walk`, via `report_directory_find_dirs`) exits nonzero
   when one of its listings fails for a reason other than the queried path
   not existing (a 404), distinct from exiting zero when every listing
   succeeded and simply matched nothing — so a rate limit landing mid-walk is
   `{"ok": false}` rather than the empty date, without this script
   re-implementing the walk's own listing/regex probe to tell the two apart.
   The exit status is the *whole* of that signal: what both functions print is
   byte-for-byte what they printed before the distinction existed, in every
   case, including a multi-segment format's walk that lists one level
   successfully and fails at the next — degraded and found-something are not
   exclusive, and a caller ignoring the status still gets the something. Two
   callers ignore it deliberately, and have to say so rather than say nothing:
   `review-cycle.sh`'s `most_recent_review_date` (R4's skip-guard) and
   `lib/candidate-gather.sh`'s `report_directory_resolved` (requirement 3k)
   each pipe the result through `cut` under `set -euo pipefail` from an
   errexit-live context, where `pipefail` would otherwise carry the walk's
   nonzero status onto their own assignment and take the cycle down over a
   transient listing failure; both end that pipeline with `|| true`. The
   answer decides nothing rather than retiring, on a rate limit,
   refs whose retirement nothing can clear. This is requirement 34n's
   `review-superseded` signal
   (TD-PPagop-26082309): `lib/candidate-gather.sh` calls it once per repo
   already carrying unretired review-shaped void residue, and
   `void_review_plan_actioned` (`lib/void-liveness.sh`) reads the date back
   to tell a void'd `review-<date>-R-NN` ref whose folder is still current
   from one whose folder has been superseded. The default mode's own
   behaviour is unchanged by this flag's presence.
3y. `scripts/gather-implementation-plan.sh` implementing requirement 3y's
   implementation-plan half: given a repo slug, default branch and
   `implementation_plan_path`, prints the JSON array of the document's open
   tasks — every task-list line whose checkbox is empty (`- [ ]`, `* [ ]`,
   `1. [ ]`) and whose leading `id:` token matches `WORK_GONE_PLAN_RE`
   (`lib/work-gone.sh`, sourced rather than restated so an id this mints is
   always one `scripts/gather-plan-status.sh` can later resolve a block
   against) — each carrying that id as `ref`/`id`, the text after the colon as
   `title`, `url`, and the whole line verbatim as `body`; in document order,
   the plan's own sequence. A done task needs no forward specification and is
   skipped, as is a line whose leading token is not that shape. A missing or
   unreadable document prints `[]` silently; an API failure prints `[]` with
   `gh`'s diagnosis on stderr. Fails safe to `[]` (exit 0). Its shape is
   regression-tested in `test/gather-implementation-plan.test.sh`; must pass
   `shellcheck`.
3q. `lib/dependency-gate.sh` implementing requirement 34j: `dependency_refs`,
   which parses every `Blocked-by:` reference out of a body of text into a
   normalized JSON array (same-repo references as a bare number, cross-repo
   as `owner/repo#N`), and `dependency_clearances`, which given the open
   blocked set and this cycle's own reshaped `issues` candidates prints the
   blocked issues whose dependencies are proven resolved by their presence
   there — pure, reading nothing itself. Both are shared by
   `scripts/gather-issues.sh` (the holding half) and `agent-cycle.sh` (the
   releasing half, in the same pre-extract window as requirement 34i).
   Unit-tested (`test/dependency-gate.test.sh`); must pass `shellcheck`.
3r. `lib/issue-prefetch.sh` implementing the issue-walking half requirements 3j
   and 3t share: `ISSUE_DETERMINISTIC_FILTER_JQ`, the jq definitions
   `issue_deterministic_ok` (not a pull request, not assigned, not labelled
   `blocked` whatever the case) and `issue_exclude_reason` (which of
   `"assigned"`/`"blocked-label"` a rejected issue is reportable under, `null`
   otherwise — a pull request is never reported); and `issue_blocked_by_ref`,
   which prints the display form of a thread's first still-open `Blocked-by:`
   reference (requirement 34j) or nothing, treating a reference whose state
   cannot be read as still open. Sourced by both `scripts/gather-issues.sh`
   and `scripts/gather-tech-debt.sh`, so the drops the two bands share cannot
   drift apart; `issue_blocked_by_ref` calls `dependency_refs`, so
   `lib/dependency-gate.sh` must be sourced first. What qualifies an issue for
   candidacy at all — every open issue for `issues`, only the
   `pw::type:tech-debt`-labelled ones for `tech-debt` — is deliberately left
   to each caller. Regression-tested through both callers'
   own tests (`test/issues-prefetch.test.sh`, `test/gather-tech-debt.test.sh`);
   must pass `shellcheck`.
3k. `scripts/gather-register-status.sh` implementing requirement 34i's register
   half: given a repo slug, default branch and item ids, prints a JSON object
   mapping each id to the `status` its own item file declares on that branch.
   An id resolves only when exactly one file claims it by `id` or `legacy-id`
   — the filename is a shortlist, never the answer — and everything short of
   that certainty is absent from the output, which the caller reads as "not
   known to be gone". A repo with no `tech-debt` tree prints `{}` silently; an
   API failure prints `{}` with `gh`'s diagnosis on stderr. Called once per
   repo that has blocked register items and not at all otherwise, so it is
   bounded by the backlog rather than by the register. Fails safe to `{}` (exit
   0); regression-tested in `test/work-gone.test.sh`; must pass `shellcheck`.
3o. `scripts/gather-review-status.sh` implementing requirement 34i's
   project-review half: given a repo slug, default branch and recommendation
   refs, prints a JSON object mapping each ref a merged pull request's title
   or body names to `"merged"`, searched over the repo's 100
   most-recently-closed pull requests targeting that branch. Called once per
   repo that has blocked project-review items and not at all otherwise. Fails
   safe to `{}` (exit 0); regression-tested in `test/work-gone.test.sh`; must
   pass `shellcheck`.
3p. `scripts/gather-plan-status.sh` implementing requirement 34i's
   implementation-plan half: given a repo slug, default branch,
   `implementation_plan_path` and task ids, prints a JSON object mapping each
   id to `"done"` or `"open"`, read off that task's own checkbox
   (`- [ ]`/`- [x]`) in the document. An id resolves only when exactly one
   task-list line names it as a whole word; two such lines, or none, are
   absent from the output. Called once per repo that has blocked plan-task
   items and an `implementation_plan_path` configured, and not at all
   otherwise. Fails safe to `{}` (exit 0); regression-tested in
   `test/work-gone.test.sh`; must pass `shellcheck`.
3v. `scripts/gather-workflow-basenames.sh` implementing the one read
   requirement 34n's liveness rule needs and no other source provides: given a
   repo slug, prints `{ok, basenames}` mapping each of the repo's workflow ids
   to its file's basename without extension — the half requirement 19 mints a
   `failed-run-` item id from, which `scripts/gather-source-state.sh`'s own
   `workflows` digest (3b) carries only by id. Called once per repo that still
   carries unretired `failed-run-` void residue and not at all otherwise, so it
   is bounded by that residue rather than by the fleet. `ok: false` on any API
   failure and never on a legitimately empty workflow list, since requirement
   34n reads `ok` before trusting the map for anything. Fails safe (exit 0);
   unit-tested (`test/gather-workflow-basenames.test.sh`); must pass
   `shellcheck`.
3b. `scripts/gather-source-state.sh` implementing requirement 3b's sampling:
   given a repo slug and default branch, prints one JSON object holding that
   repo's head SHA and its issues, workflows and open-PR digests, with `ok:
   false` if any of it could not be fetched cleanly. The issues digest carries
   each issue's `Priority` band (requirement 15e), resolved the same way the
   Co-Ordinator resolves it — unset or unrecognised reads as `Medium` — so a
   re-prioritised issue busts the fingerprint and a missing field does not.
   Never exits non-zero — a
   cost-control feature must not become a reliability risk — but must not
   pretend a failed call is an empty result either (see requirement 3b). Must
   pass `shellcheck`.
3d. `scripts/state-sync.sh` implementing requirement 2.5: `push` and `fetch`.
   Called by both pipelines (the push from the cleanup that ends a cycle) and
   by the container crontab (the every-few-minutes push and the fetch).
   Every mode is a no-op when `state_repo` is unset. Needs `rsync`, `git`
   (and `tar` for the fetch), and degrades to a warning and exit 0 when one
   is missing, because a node that cannot replicate is still a node that can
   run. Unit-tested against a local bare repository
   (`test/state-sync.test.sh`); must pass `shellcheck`.
3i. `scripts/rotate-logs.sh` implementing requirement 2.6: rotates
   `dashboard.log`, `state-sync.log`, `doctor.log`, `revert-rate.log`,
   `tech-debt-archive.log`, `wake-poll.log`, `cron.log` and
   `review-cron.log` by size,
   leaving `log.jsonl`, `review-log.jsonl` and `revert-rate.jsonl`
   untouched. Called by its
   own container crontab line, independent of both pipelines. Unit-tested
   against a synthesised `state_dir` (`test/rotate-logs.test.sh`); must pass
   `shellcheck`.
3e. `lib/claim.sh` implementing requirement 17a: `claim` (kinds `branch` and
   `file`), `release`, `count` and `gc`, exit codes 0 won/done, 3 lost, 1
   error; requirement 3o's `claims` and `branches` — read-only listings
   that always print a JSON array (empty on any read failure) and exit 0,
   since a claim-visibility gather must never fail a cycle over one listing
   coming up short; and requirement 37's `expire <target-slug> <key>` —
   backdates a registry entry's `ts` to a fixed date long past any realistic
   `claim_ttl_hours`, carrying every other field over unchanged, so `gc`
   retires it on its very next sweep rather than releasing it. A silent
   no-op when the entry cannot be read or `state_repo` is unset, on the same
   reasoning as the read-only listings — an annotation is advisory, like the
   registry it targets. Called by `agent-cycle.sh` (the claim loop after
   selection, the release hooks on every no-PR ending, the `count` inside
   back-pressure, `claims`/`branches` once per repo ahead of the
   Co-Ordinator, and `expire` from `maybe_run_enabler`'s discard path).
   `CLAIM_GH` substitutes a stub for tests, following
   `STATE_SYNC_GH`. Unit-tested with concurrent-claim races against a
   filesystem-CAS stub (`test/claim.test.sh`); must pass `shellcheck`.
3h. `lib/refinement.sh` implementing the refinement class: requirement 16a's
   well-formedness bar for a `needs_refinement` entry, requirement 34e's block
   fields and label projection and requirement 38b's `blocked`/`blocked:<reason>`
   label projection beside it (`REFINEMENT_GH` substitutes a stub for tests,
   following `CLAIM_GH`), requirement 35d's per-engagement cap, and requirement
   36b's `item-refined` payload and thrash guard — `refinement_is_disagreement`
   beside it, the same "needs-refinement block with `refined_before` set" shape
   read without the verdict/`issue-closed` conditions the guard itself also
   checks, since `escalation_autonomy`'s `adjudicate-first` setting
   (agent-ops#627, requirement 36b) is this predicate's one caller — plus, for
   the Refiner, requirement 39a's `refiner_candidate_items`/`refiner_policy_value`
   and requirement 39b's `refiner_engagement_set`. Sourced after
   `lib/void-guard.sh`, whose `entry_field_text` it shares rather than keeping a
   second opinion about what counts as a filled-in field (requirement 34a).
   Also carries the Refiner stage itself (moved from `agent-cycle.sh`, #771):
   `maybe_run_refiner`, `refiner_claim_key` and
   `refiner_filter_unbandable_triage`, sourced and called from the cleanup
   trap exactly as they were inline.
   Unit-tested (`test/needs-refinement.test.sh`, `test/refiner-eligibility.test.sh`);
   must pass `shellcheck`.
3s. `lib/label-marker.sh` implementing requirement 39f's own-label-action
   memory: `label_own_action_fields` (the payload an `own-label-action` event
   carries), `label_own_actions_map` (every such event for one label, reduced
   to the latest per repo+item), `label_filter_own_applications` (a gathered
   hand-flag candidate list with the Script's own applications dropped, which
   is what `agent-cycle.sh` calls), `label_own_stale_applications` (those of
   the candidates the filter drops that have no block still open, which is
   what `agent-cycle.sh` retries `refinement_label_remove` on) and
   `label_is_own_application` (the same question for one item, expressed in
   terms of the filter so the two cannot disagree). A pure reader of the log,
   on the same "library stays a pure function" boundary `stage_budget_overrides`
   documents for its own config read — the events themselves are logged at the
   call site in `agent-cycle.sh`, alongside the `refinement_label_add`/`_remove`
   calls requirement 39f's writes extend. Unit-tested
   (`test/label-marker.test.sh`); must pass `shellcheck`.
3m. `lib/work-gone.sh` implementing requirement 34i's decision:
   `work_gone_clearances`, which given the open blocked set, the cycle's
   source-state digests and the register, review and plan status maps prints
   one entry per block whose work no longer exists, and
   `work_gone_register_ids`, `work_gone_review_refs` and `work_gone_plan_ids`,
   which each name the blocked ids shaped like their class so the matching read
   above is asked for those and no others. Pure — it reads nothing itself — and
   every unknown resolves to no clearance. Unit-tested (`test/work-gone.test.sh`);
   must pass `shellcheck`.
3w. `lib/void-liveness.sh` implementing requirement 34n's third, fourth,
   fifth and seventh actioned signals: `void_liveness_actioned`, which given
   the void extract and
   this cycle's own per-repo, per-shape gather (`{ok, ids}` for `alert`,
   `failed-run` and `merge-conflict`) prints one
   `{repo, item, by}` per void whose id its source no longer yields;
   `void_review_plan_actioned`, which does the same for a project-review ref a
   merged pull request names (`review-merged`) or whose review folder is no
   longer the repository's current one (`review-superseded`,
   TD-PPagop-26082309 — the fourth input, `REVIEW_CURRENT_JSON`, is repo ->
   the repo's current review folder's own date string from
   `scripts/gather-project-review.sh --current-date`, absent for a repo whose
   read failed and empty-string for one whose read found no folder at all),
   and an implementation-plan task id a checked box
   names, reading the status maps `scripts/gather-review-status.sh` (3o) and
   `scripts/gather-plan-status.sh` (3p) already print; and
   `void_config_actioned`, which given the extract and the **unnarrowed**
   configured repo array prints one entry per void whose repo the config no
   longer names (`repo-dropped`, any shape) or whose shape names a source that
   repo no longer lists (`source-dropped`), the residue liveness cannot reach
   because an ungathered source never writes the `.ok` marker liveness needs.
   All three take the unbounded
   extract on stdin, never in argv (requirement 4g), and all fail safe to `[]`
   — an unknown, a gather that did not succeed, an empty or unreadable repo
   array and a malformed input alike
   decide no retirement. Pure — they read nothing themselves; the shape regexes
   for the two on-demand-reader classes and the register class are
   `lib/work-gone.sh`'s own
   (requirement 34a), so this file is sourced after it. Unit-tested
   (`test/cycle-state.test.sh`); must pass `shellcheck`.
3s. `lib/preflight.sh` implementing requirement 34m's decision:
   `preflight_done_reason`, which given a repo, an item, its claim branch, the
   cycle's source-state digests and (for a tech-debt item) its one freshly
   read register row, wraps them into the one-entry blocked list
   `work_gone_clearances` (3m) expects and returns its reason, or nothing.
   `preflight_defer_reason` is the non-terminal signal (#279): for every item
   but a finishing source's own `pr-<n>-…`-shaped one it checks
   the same digest for an open pull request already carrying the claim
   branch (`preflight_open_pr_reason`), and its hit defers the claim —
   released, `warning` logged, no void — because that is the one fact here
   that can become false again. `preflight_branch_merged_reason`
   is the other done-signal, kept separate because it is impure (one live
   `gh api compare` call against the target repository) and `preflight_existing_branch_source`
   is the gate that scopes it to the five sources whose branch predates the
   claim (review-feedback, merge-conflicts, dequeued, landing-refusals,
   abandoned-drafts) — see
   requirement 34m for why an ordinary claim's freshly created branch cannot
   use this check. `preflight_review_feedback_reason` is the third done-signal
   (requirement 34m, issue #1360), scoped to `review-feedback` items alone:
   one live `gh api pulls/<n>/reviews` call, recomputing the blocking review
   via `lib/handoff.sh`'s `handoff_latest_positions` — the one
   standing-position-per-reviewer definition `scripts/gather-review-
   feedback.sh` (3c) also calls (requirement 34a, issue #1373) — and voiding
   when the item's own review id no longer names it. `preflight_done_reason`
   and `preflight_open_pr_reason` are pure — they read nothing themselves —
   sourced after `lib/work-gone.sh`, whose function `preflight_done_reason`
   wraps, and after `lib/handoff.sh`, whose `handoff_latest_positions`
   `preflight_review_feedback_reason` calls. Unit-tested
   (`test/preflight.test.sh`); must pass `shellcheck`.
3n. `scripts/sweep-orphan-branches.sh` implementing requirement 17b's sweep:
   given a repo slug, examines every `<branch_prefix>*` and
   `td-record/*` ref, and
   prints one JSON action object per orphan handled (`recovered`, `released`,
   `deferred`, `warning`) for the Script to log. `td-record/*` is delete-only,
   never recovered: a filing pull request closed without merging releases that
   ref (`reason: "filing-declined"`) and then, once `<id>`'s record is
   confirmed absent from the default branch, its paired `td/<id>` reservation
   too — a pair whose two actions are reserved against the per-run cap
   together, so a run without room for both defers it whole rather than
   deleting the record and stranding the release. Fail-closed on every
   unanswered question; `SWEEP_GH` stubs `gh` and `AGENT_OPS_CONFIG`
   overrides the config for tests. Unit-tested
   (`test/sweep-orphan-branches.test.sh`); must pass `shellcheck`.
3r. `scripts/sweep-human-visibility.sh` implementing requirement 38c's sweep:
   given a repo slug (and, for the nudge comment's header and marker, a cycle
   id and a node name), examines every open, non-draft, `pr_label`-carrying
   pull request and prints one JSON action object per pull request it acted on
   (`human-review-requested`, `nudged`, `dequeue-notice`, `warning`) for the
   Script to log as `human-review-requested`, `human-nudged`,
   `human-dequeue-notice` and `warning` respectively — `nudged` (the ordinary
   idle nudge) and `dequeue-notice` (the merge-queue-dequeue notice,
   requirement 38f) are deliberately distinct actions, never merged into one
   name, so requirement 38e's reduction can tell which of the two a pull
   request's warning was actually resolved by. Fail-safe on every unanswered
   question — a read it cannot make is a `warning`, never an assumed clean
   answer; `SWEEP_GH` stubs `gh` (and is passed through as `HANDOFF_GH`, since
   the sweep's decisions are `lib/handoff.sh`'s) and `AGENT_OPS_CONFIG`
   overrides the config for tests. Unit-tested
   (`test/sweep-human-visibility.test.sh`); must pass `shellcheck`.
3a. The shared library (`lib/cycle-state.sh`, `lib/limit-detect.sh`,
   `lib/github-limit.sh` (requirement 2.0's `github_limit_snapshot`,
   `github_limit_verdict` and `github_limit_describe`; requirement 2.0a's `gh`
   wrapper, `github_limit_kind` and the pure `github_limit_wait_plan`;
   requirement 2.0b's `github_auth_probe`, the same free call classifying a
   401, and a missing token, apart from every other failure; requirement
   2.0d's `github_limit_headers_to_resource`, `github_limit_graphql_resource`,
   `github_limit_resource_pristine`, `github_limit_budget_fields`,
   `github_limit_budget_delta` and `github_budget_record`; and the
   `GITHUB_PR_LIST_LIMIT` listing
   bound with `github_pr_list_truncated`, whose callers — the back-pressure
   gate, the four PR-listing gatherers, and the void guard's supersession
   corroboration (requirement 3s) — must agree on what a truncated page is
   even though they treat one differently. Sourced by both cycle scripts,
   `lib/claim.sh`, `lib/void-guard.sh` and every
   `scripts/gather-*`/`scripts/sweep-*` that calls GitHub. Unit-tested,
   `test/github-limit.test.sh`),
   `lib/gh-shim.sh` (requirement 2.0e's `gh` transport shim — see component
   22c for its own functions; reuses this file's `github_limit_kind` and
   `github_limit_headers_to_resource` rather than re-implementing either.
   Unit-tested, `test/gh-shim.test.sh`),
   `lib/memory.sh` (requirement 2.0f's `memory_available_kb`,
   `memory_total_kb`, `memory_verdict` and `memory_describe` — the one place
   free host memory is read and judged, sourced by both `agent-cycle.sh`,
   whose pre-cycle stand-down acts on the verdict, and `scripts/doctor.sh`,
   whose advisory warning reports it; plus `memory_cgroup_field`,
   `memory_cgroup_stat`, `memory_cgroup_verdict` and
   `memory_cgroup_describe`, the read-only cgroup v2 inspection doctor.sh
   reports an unbounded container with. Unit-tested, `test/memory.test.sh`
   and `test/memory-wiring.test.sh`),
   `lib/disk-space.sh` (requirement 2.0c's `disk_space_free_kb`,
   `disk_space_verdict`, `disk_space_describe` and `disk_space_same_filesystem`
   — the one place free space on a directory's filesystem is read and judged,
   sourced by both `agent-cycle.sh`, whose pre-clone stand-down acts on the
   verdict for both `state_dir` and `workspace_root`, and `scripts/doctor.sh`,
   whose advisory warning reads the same `min_free_workspace_bytes` floor
   through the same functions for the same two directories, so the gate and
   the warning cannot silently disagree about what "low" means, nor about
   which directories that covers.
   Unit-tested, `test/disk-space.test.sh`),
   `lib/host-budget.sh` (requirement 2.0g's `host_budget_declared_mem_bytes`/
   `host_budget_declared_cpu_nanos` and their own unknown-container counts,
   `host_budget_summary_json`, `host_budget_mem_verdict`/
   `host_budget_cpu_verdict` and `host_budget_describe` — the one place the
   sum of every running container's declared ceiling on a host is computed
   and judged against that host's own totals, sourced by both
   `scripts/collect-host-facts.sh` (which publishes the sum into the
   host-facts record's `budget` section) and `agent-cycle.sh`/
   `scripts/doctor.sh` (which each read that record back and judge it
   through these same functions, so the stand-down and the advisory warning
   cannot silently disagree about what "over budget" means). Unit-tested,
   `test/host-budget.test.sh` and `test/host-budget-wiring.test.sh`),
   `lib/repo-clone.sh` (requirement 6's `clone_repo`, the one clone both
   pipelines take, with `CLONE_GIT` substituting a stub for tests),
   `lib/toggle.sh`, `lib/noop-skip.sh`, `lib/role.sh`, `lib/void-guard.sh`,
   `lib/refinement.sh`, `lib/label-marker.sh`, `lib/work-gone.sh`,
   `lib/void-liveness.sh`, `lib/preflight.sh`, `lib/model-id.sh`,
   `lib/crash-loop.sh` (requirement 2.7's `crash_loop_verdict`,
   `crash_loop_preselection_verdict` and `crash_loop_escalated_since`, all
   pure readers of the union stream),
   `lib/pager.sh` and `lib/pager-invariants.sh` (requirement 51's fleet-level
   invariant framework — `pager_register`/`pager_evaluate`/`pager_file`/
   `pager_close`, and the two invariants, `verdict-unanimous` and
   `page-outlived-item`, it ships with — sourced by
   `scripts/publish-dashboard.sh` alone, never by `agent-cycle.sh`, since it
   evaluates on the Publisher's own tick, not a cycle's. Unit-tested,
   `test/pager.test.sh` and `test/pager-invariants.test.sh`),
   `lib/token-expiry.sh` (requirement 2.7a's `TOKEN_EXPIRY_WARN_DAYS`,
   `token_expiry_header`, `token_expiry_parse` and
   `token_expiry_escalated_for` — the one place the warning threshold and
   the header's own parsing live, sourced by both `scripts/doctor.sh`, which
   reads the header, and `agent-cycle.sh`, which escalates on what it read,
   so the two can never judge the same token differently. Unit-tested,
   `test/token-expiry.test.sh`),
   `lib/human-visibility-hygiene.sh` (requirement 38e's
   `human_visibility_violations`, another pure reader of the union stream,
   reducing requirement 38c's `warning` events to the identities — pull
   request or bare repo — still unresolved),
   `lib/handoff.sh` (requirement 31a's `confirm_pr_ready`, shared with
   requirement 32b; requirement 31c's `confirm_pr_draft` (agent-ops#539), the
   same "confirm against GitHub, don't trust the call's own exit status"
   shape mirrored in the reverse direction, called by `handoff_complete_review`
   on a `dirty` reconciliation verdict and printing
   `reverted`/`already-draft`/`failed`; requirement 31b's
   `confirm_review_requested`, the same promise for the round after the
   first; requirement 38a's
   `ensure_human_reviewer`, the same promise again where nobody's review is
   blocking at all; requirement 3c's `handoff_answer_events` and
   `handoff_round_answered`, the answered-from-events predicate shared with
   requirement 38c's sweep; requirement 31d's `pr_merge_state`
   (agent-ops#916), printing `open`/`merged<TAB>sha`/`failed`, fail-closed the
   same way `confirm_pr_ready` already is; and requirement 9's
   `pr_url_for_branch`, which names the pull request on a claimed branch when
   the stage that opened it named nothing; `HANDOFF_GH` substitutes a stub for
   tests),
   `lib/merge-observed.sh` (requirement 32c's `reviewer_merge_observed`,
   agent-ops#916/#1062: given a merged pull request's URL, its merge commit
   (when known) and the Reviewer's own verdict JSON (`{}` at either advisory
   stage-start call site — the Reviewer's own, or requirement 31f's
   Implementer one), logs `merge-observed`, files whatever `file_debt`/
   `file_issue` the verdict carries — under the ordinary pipeline login,
   omitting `TOKEN` exactly as `lib/enabler.sh`'s own use of the two fields
   does — and releases the PR-keyed claim. Depends on `lib/handoff.sh`'s
   `pr_merge_state`, `lib/candidate-select.sh`'s `release_pr_claim` and
   `lib/tech-debt-file.sh`'s `techdebt_file_debt`/`techdebt_file_issue`, so is
   sourced after all three),
   `lib/stage-run.sh` (requirement 4d's `run_model_stage`, the one stage
   launcher both pipelines call, with `stage_stream_file` and
   `stage_result_line` naming and reading the stream it writes, and
   `stage_gap_stats` summarising the inter-event gaps it measures from that
   stream for requirement 33a, `stage_rejected_rate_limit` reading the
   refusal that stops a stage on the spot, and
   `stage_project_settings_refusal`, with
   `stage_project_settings_allowed_keys` and
   `stage_project_settings_origin`, vetting the working directory's
   project settings before any launch for requirement 4k),
   `lib/stage-budget.sh` (requirement 4f's derivation:
   `stage_budget_observations` over the log union, `stage_budget_table`
   holding the estimator, the controller and the shrinkage,
   `stage_budget_resolve` applying the precedence,
   `stage_budget_all_overrides` taking the widest configured cap per actor
   across the plain `timeout_<actor>` / `inactivity_<actor>` keys and every
   repository's own `stage_timeouts` / `stage_inactivity`, and
   `stage_budget_lock_seconds` deriving the lock from it; sourced by both cycle
   scripts, by `scripts/doctor.sh` and by the dashboard publisher, all four of
   which must agree about what a stage is allowed) and
   `lib/metering.sh`) holding every
   rule that more than one component computes — at minimum requirement 34's blocked
   semantics, requirement 35a's eligibility rule (the Script engages on it, the
   dashboard reports what came of it), requirement 3h's refinement
   carry-forward, requirement 33's `attempt-failed` field shape, requirement
   33a's per-stage metering record (`lib/metering.sh`'s `metering_fields`,
   sourced by `agent-cycle.sh` and `review-cycle.sh` so a stage in either
   pipeline emits the same shape; `docs/METERING-SCHEMA.md` is the contract;
   unit-tested in `test/metering.test.sh`), the usage-limit
   phrase pattern of requirement 10, the switch of requirement 2.3 and the
   fleet flags of requirements 2.3a and 2.1 (`lib/toggle.sh`'s `fleet_*`
   functions; `TOGGLE_GH` substitutes a stub for tests, following
   `CLAIM_GH`), the role guard of requirement 2.4 (read
   by both pipelines), the fingerprint rule of requirement 3b and the
   provider-qualified model id resolution of requirement 1a
   (`lib/model-id.sh`'s `resolve_model_id_into`) — sourced by `agent-cycle.sh`,
   `review-cycle.sh` and the dashboard's publisher rather than copied into
   any of them. Unit-tested directly (`test/*.test.sh`, plain bash assertions, no
   framework) and `shellcheck`-clean. These rules are the system's memory of
   what it has already tried; a second copy of one is a bug with a delay
   fuse, and both copies read correctly right up until they disagree.
3l. `lib/repo-order.sh` implementing requirement 3's two pure functions:
   `repo_order_by_effective_age`, given the cycle's now-epoch and the repos
   array, reorders the Script's timestamp lines most-overdue-first by
   nice-weighted effective age, ordering identically to a plain
   least-recently-updated-first sort when every repo's `nice` is `0` or
   absent; and `repo_nice_selection_config`, the fingerprint producer's
   half, which distils the same repos array into the `selection_config`
   contribution — `{repo_nice: …}` carrying the non-zero entries only,
   floor-normalised, or `{}` when there are none, so a neutral config adds
   no key at all (the canon hashes `selection_config` wholesale, and an
   empty map is not the same bytes as an omitted key). Sourced by
   `agent-cycle.sh` only. Unit-tested (`test/repo-order.test.sh`); must
   pass `shellcheck`.
4. `prompts/coordinator.md`, `prompts/implementer.md`, `prompts/reviewer.md`,
   `prompts/enabler.md` and `prompts/refiner.md` implementing requirements
   14–20, 21–27, 28–32, 36/36b and 39c/39d respectively. Each prompt must
   embed the relevant shared-repo conventions from this document so a stage
   never depends on context it wasn't given. The Enabler's additionally
   carries the escalation issue's template, since the quality of that issue is
   the whole of requirement 36a's ask of a human; the Refiner's carries no
   such template, since it has no escalation power of its own.
4e. `prompts/approver.md` implementing requirements 40–44 (D18 WI-5): judge
   only, never fix, posture keyed to the tier word it is told — one defined
   for each of `standard`, `high`, `critical` and `adjudication`, the four
   the `## Tier` section can carry (requirement 41) — no GitHub-write
   instruction of any kind, ends with a
   verdict-only JSON object. Sourced by `lib/approver.sh`'s `run_approver_stage`
   only.
4f. `prompts/enabler-adjudicate.md` implementing requirement 36b's
   `escalation_autonomy: "adjudicate-first"` adjudication pass
   (agent-ops#627): one item, judged from the existing refinement, the
   re-flag's own reason and the drafted escalation issue; no power to write a
   new specification and no GitHub-write instruction of any kind; ends with a
   verdict-only JSON object carrying `verdict` (`adequate`/`inadequate`) and
   `evidence`. Launched by `lib/enabler.sh`'s `run_enabler_adjudication` only.
   Absent from `prompt_overrides`' enumeration for the same reason `approver`
   is (requirement 4a): it is the pass that decides whether a human is asked,
   so no installation may extend or replace it.
4a. `lib/prompt-overrides.sh` implementing requirement 4a: `stage_prompt_text`
   (the assembled prompt for a stage, honouring `config.json`'s
   `prompt_overrides.<stage>.extend`/`.replace`) and `stage_prompt_sha` (the
   same assembly's contribution to the no-op fingerprint, requirements 3b and
   35b). Sourced by `agent-cycle.sh` only — `review-cycle.sh` runs its own
   `prompts/project-reviewer.md` outside this mechanism. Byte-identical to
   `cat prompts/<stage>.md` with nothing configured; unit-tested
   (`test/prompt-overrides.test.sh`) for that no-op case, for `extend`
   ordering and its disclaimer wrapper, for `replace` (including falling back
   to the shipped prompt when the configured file is unreadable), and for
   every one of those changing `stage_prompt_sha`; must pass `shellcheck`.
   `prompt_overrides_json_for_repo` (agent-ops#588) resolves requirement 4a's
   per-repository layer down to the same `{stage: {extend, replace}}` shape
   `stage_prompt_text`/`stage_prompt_sha` already take, so neither of those two
   functions has any per-repository knowledge of its own; `agent-cycle.sh`
   calls it against the cycle's own `$repo_slug` immediately before assembling
   the Implementer's (requirement 7) and Reviewer's (requirement 8) prompts,
   the two call sites `prompt_overrides_json` (the plain installation-wide
   object) still feeds directly for every other stage.
4b. `lib/coordinator-brief.sh` implementing requirement 4b:
   `coordinator_work_sources_table`, given `config.json`'s `repos` array,
   renders the Markdown table naming each repo and its numbered `sources`
   that `agent-cycle.sh` substitutes into the Co-Ordinator's assembled
   prompt in place of its `@@WORK_SOURCES_TABLE@@` marker. Sourced by
   `agent-cycle.sh` only. Unit-tested (`test/coordinator-brief.test.sh`) for
   the row-per-repo shape, in-order numbering, an input reordered from
   `config.json`'s own order, and the empty-array edge case; must pass
   `shellcheck`.
4i. `lib/coordinator-input.sh` implementing requirement 4i:
   `coordinator_fit_bands`, given a byte allowance on argv and the cycle's
   repo array on stdin, walks the ten-rung prose ladder and then the
   per-band entry caps until the array renders inside that allowance, and
   prints `{repos, fit}` — the trimmed array and a record of which rung was
   reached, what it capped, the byte counts before and after, and whether it
   fitted at all. `coordinator_fit_detail` renders that record as the one
   human sentence the union log carries. `coordinator_apply_rung` is the
   single `jq` program both ladders run, so a rung and an entry cap cannot
   drift apart in what they do to an entry. Sourced by `agent-cycle.sh` only.
   Unit-tested (`test/coordinator-input.test.sh`) for the untouched
   already-fits case, the three fail-open degradations, prose shed without
   candidacy, identity fields preserved, the elision markers and their URLs,
   newest-comments-kept, entry dropping in the stated keep-order (tech-debt
   freshest-first), entry order left alone when nothing is dropped, the two
   trim rungs beneath `0:0:1000` and the first entry cap's position beyond
   them, the binary search that refines a fixed entry cap towards whatever
   higher cap in its gap still fits the allowance (bounded below double the
   fixed cap it refines, agent-ops#2221), the fleet's 2026-09-23 shape settling on a trim rung, the
   unfittable case, the two whole-document bands trimmed and the other bands
   not, the rendered detail line, and — pinning requirement 4g — an array
   genuinely past
   `MAX_ARG_STRLEN` through both the fits and the trims paths.
   `test/coordinator-input-wiring.test.sh` covers the seam separately, over
   the `agent-cycle.sh` block lifted verbatim: the allowance arithmetic,
   measured by reassembling the real prompt around the block's output, and
   the three events the union log depends on. Both must pass `shellcheck`.
   `coordinator_fit_trimmed_items`, given the *fitted* repos array, prints
   `{repo, item, source}` for every issues/tech-debt entry `fit_entry`
   actually clipped — detected off the elision marker in a body or a comment
   body, or `comments_elided`, never re-measured — and
   `coordinator_fit_trim_refusal_reason`, given an entry and that set, is
   requirement 34e's fourth refusal (agent-ops#683).
   Both are unit-tested directly in `test/coordinator-input.test.sh`
   (bottom-rung marking, a middle rung marking only the entries it actually
   touched, an untrimmed cycle marking nothing, and the refusal function's own
   match/no-match/malformed-input cases) and exercised through the real
   `record_needs_refinement_block`/`unaccounted_items` in
   `test/fit-trim-block-refusal.test.sh`.
5. `README.md`: a landing page naming what the system does and pointing at
   the guides under `docs/guides/` and the configuration reference at
   `docs/reference/configuration.md` — `docs/guides/working-with-pullwright/README.md`
   (what it does, review, merge autonomy), `docs/guides/operating/README.md`
   and its linked pages (install steps (below), how to operate it
   (`--dry-run`, `--once`, reading the log and stage transcripts), and how to
   uninstall) and `docs/guides/contributing/README.md` (for maintainers,
   branch workflow, development). The operating guide documents the
   container as the only way a node runs, and points at the runbook
   (component 7) for the detail.
6. The crontab line: never installed by hand on a containerized node — it is
   the cycle line of `deploy/docker/crontab.tmpl`, rendered per node at
   container start and run by supercronic inside the scheduler service, with
   the node's role coming from `ROLE` in its `deploy/docker/.env`
   (requirement 2.4) rather than from a crontab environment variable.
7. `deploy/docker/` — the node image and the node stack (see "The node image"
   and "The node stack" above): `Dockerfile`, `entrypoint.sh`, `crontab`, the
   minimal `claude-settings.json` seed and `claude-managed-settings.json`, the
   managed policy of requirement 4k that the image installs root-owned at
   `/etc/claude-code/managed-settings.json`; `compose.yaml`, `ts-serve.json`,
   `watchtower-pre-update.sh` (the hook that makes a roll wait for a running
   cycle) and `.env.example`; and the node runbook `deploy/docker/README.md` with the
   unattended `cloud-init.yaml` that performs its first three steps. The
   runbook is the operator-facing counterpart to those two sections: bring-up,
   everyday commands, updating, changing a node's role, the failover drill and
   a symptom-to-cause table.
8. `deploy/agent-ops-dashboard.init` and `deploy/tailscaled.init` — the legacy
   WSL SysV path for the laptop, superseded on a containerised node.
9. `.github/workflows/build-image.yml` — the build-and-publish path for
   component 7's image: build, verify the toolchain, validate the crontab, run
   the `test/` suite inside the image, and check the role guard; then publish
   to GHCR on `main` only. It carries `packages: write` and authenticates as
   the workflow's own `GITHUB_TOKEN`, so nothing about publishing depends on a
   human's credentials. Its `changes` job decides whether there is an image
   worth building at all, through `scripts/is-docs-only.sh` — the allowlist of
   paths the image is not the delivery path for (requirement 1b-i). The rule lives in
   the script rather than in the workflow for the reason component 10 gives
   about its own file set, and because a rule that decides what reaches a node
   is worth unit-testing. The build job is bounded twice over: `timeout-minutes:
   90` on the job, and a per-test `timeout 600` inside the test-suite loop —
   the same bound `scripts/run-tests.sh` applies, written the same way, so a
   hung test is cut off at the same point whether a developer or CI is running
   it. Neither figure grades a slow run: the suite costs ~20 minutes per
   architecture inside the image, and the margin above that exists only so the
   job stops falling back to Actions' implicit six-hour default, where a test
   that hangs — this suite exercises real signal and process-group handling —
   would spin unexplained for hours before anyone noticed.
10. `scripts/lint-shell.sh` and `.github/workflows/shellcheck.yml` — the
    shell linter and the job that enforces it (acceptance checks 1g and 1g-i).
    The file set and the invocation live in the script, so a developer's run
    and CI's are the same run — with one deliberate asymmetry, the size guard
    of 1g-i, which lets a 3 GB node skip the one script it cannot lint without
    being OOM-killed while a 16 GB runner still checks it; the workflow's job
    is to install a **pinned** shellcheck
    (version and tarball checksum, both in the workflow) and call it. The pin
    is the point: the runner image's own version moves without notice, and a
    linter that gains a check overnight fails pull requests that changed
    nothing. Component 9 runs the test suite, which only ever reads the scripts
    it calls; this reads all of them. `deploy/docker/Dockerfile` (component 7)
    installs the same pinned release — the amd64 checksum byte-identical to
    this workflow's — so an Implementer working inside the node image can run
    `scripts/lint-shell.sh` itself before pushing, rather than pushing blind
    and finding out from this workflow (requirement 1b).
10a. `scripts/check-graphql-drift.sh` and
    `.github/workflows/graphql-drift.yml` — the GraphQL schema-drift check and
    the nightly job that runs it (acceptance check 1g-ii,
    TD-PPagop-26082930). Every GitHub read in this repository is asserted only
    against a `gh` stub it writes itself, and a stub answers in whatever shape
    its own fixture declares, so a field GitHub renames or moves cannot fail a
    test; this asks GitHub instead.
    Each operation's selection set is wrapped in `... @skip(if:true) { … }`
    before it is sent. GraphQL validates a document in full *before* executing
    any of it, so every field inside the fragment is still checked while
    nothing is collected — which is what lets the two mutations,
    `enqueuePullRequest` (`lib/landing.sh`) and `setIssueFieldValue`
    (`lib/issue-priority.sh`), be validated nightly without a pull request
    being enqueued or an issue's Priority written.
    The request is a `{query, variables}` JSON body posted with `--input`, not
    a set of `-f query=…` arguments: `gh api graphql` builds one map from
    every `-f`/`-F` pair and lifts all but `query` into `variables`, so a
    document declaring a variable actually named `$query` collides with the
    reserved key carrying the document itself — gh 2.96.0 refuses the call,
    other versions send the placeholder *as* the document, and either way a
    valid document reads as this check's own failure. Variables are coerced
    even when the body is skipped, so each declared variable is given a
    placeholder chosen by its type from a closed table (`String`/`ID`, `Int`,
    `Float`, `Boolean`, and `[]` for any list); a type not in that table fails
    the run naming the file, line and variable rather than being guessed at,
    because a guess GitHub rejects is indistinguishable from the drift this
    exists to report. `lib/github-limit.sh` is sourced, so a secondary limit
    is waited out rather than turning the nightly red — which matters more
    here than for a work source that merely degrades, since by this check's
    own design a red run is meant to become work.
    **Discovery is a search, never a list, and is checked from the other
    side.** Documents are found by walking the tree for `-f query='` at an
    argv token boundary — the one form all of them use — rather than read from
    a list, the same reason component 10 gives
    about its own file set. Three kinds of file carry the delimiter without
    sending anything and are excluded: `test/`, because a stub answers without
    asking and this check's own fixtures are deliberately broken documents;
    the script itself, which quotes the delimiter throughout its commentary;
    and Markdown outside `prompts/` — CHANGELOG.md, `docs/`, README.md — which
    is prose about these documents rather than any of them. `prompts/` is the
    deliberate exception: a prompt file is the instruction an agent carries
    out, so its documents are sent as surely as `lib/`'s — and the token
    boundary is what keeps a prompt's own prose about the form (a Markdown
    code span, where the character before `-f` is a backtick) from opening a
    document whose closing quote is the real call's own. Any shell script
    anywhere in the tree is searched, whether or not whoever added it knew
    this check exists. Four things fail rather than passing quietly: finding
    no document anywhere; a file that opens a document it never closes (a
    typographic quote in place of an apostrophe used to make the scan run to
    end of file and contribute nothing); a document whose shape cannot be
    read, reported with which of the three malformations it is; and — the
    cross-check that closes the "one spelling is still a list" gap — a file
    that mentions `api graphql` at all and yields no document, which is how a
    call site written `-f query="…"` or assembled in a variable would
    otherwise be invisible to the very check meant to cover it.
    Discovery walks the tree rather than `git ls-files`, unlike component 10
    beside it, because the `test/` suite runs inside the node image, where
    `.dockerignore` and `scripts/run-tests.sh` have both dropped `.git`: an
    index-keyed discovery would find nothing there and report it as no drift,
    leaving the one case worth having — the real tree, walked as the nightly
    walks it — assertable only on a developer's checkout, which is the shape
    of the failure this check exists to retire.
    **Two verdicts, never collapsed.** Drift is "GitHub answered, and the
    answer was that this document is wrong"; unable is "no answer was
    obtained". A response carrying both a `type`d error (`NOT_FOUND`,
    `FORBIDDEN`, `RATE_LIMITED` — what GitHub could not *do*) and an untyped
    validation error is partitioned rather than tested as a whole, so a token
    without reach for one field does not discard real drift beside it. Exit 0
    every document validates, 1 at least one is wrong, 2 at least one was not
    checked — and **2 wins where both apply**, because a run that could not
    answer for every document has not established the "no drift" half of its
    verdict either; any drift found is still printed and annotated. Unable is
    never reported as clean, and never as drift. The run's last line reports
    documents *answered* of documents *found*, counted after the call and only
    on a complete answer, so a run whose every call failed on credentials says
    `0 of 2` rather than `2 of 2`. `--list` prints what would be checked and
    validates nothing, so its exit status reports only whether it could list
    (0 listed something, 2 nothing to list) and never 1 — a malformed document
    is listed, marked, rather than dropped. Unit-tested against a stubbed `gh`
    (`test/graphql-drift.test.sh`), whose first case runs the real discovery
    over this repository's own tree so a document added in a shape the scanner
    cannot see fails there rather than going unchecked; must pass
    `shellcheck`.
11. `scripts/watch-node.sh` — a read-only wrapper around
    `docker compose exec -T scheduler tail` for watching a node's `cron.log`
    or cycle log (`log.jsonl`, requirement 33) from outside, in place of the
    docker-exec incantation. Resolves the stack directory from `STACK_DIR` or
    the working directory, and refuses to run against one with no
    `compose.yaml`. Fetched alongside `compose.yaml` during bring-up
    (component 7, including `cloud-init.yaml`) so every node carries it from
    the start. Unit-tested against a stubbed `docker` on `PATH`
    (`test/watch-node.test.sh`); must pass `shellcheck`.
12. `scripts/check-node-compose.sh` — the host-side half of the compose-drift
    answer (see "The node stack"; the in-container half is
    `lib/compose-drift.sh`). Run on a node's host from the stack directory
    (or `STACK_DIR`; a host running two stacks, once per directory), it
    verifies what no container can: `.env`'s own permissions and backup
    siblings (below), the stack's `compose.yaml` against the copy inside the
    *running* image, the mount that arms the in-container check, the
    watchtower pre-update hook label on every running agent-ops container,
    and watchtower's actual environment — lifecycle hooks enabled, schedule
    and interval not both set — plus an advisory count of lifecycle mentions
    in watchtower's log, and whether the reconciler can apply the next
    merged `compose.yaml`: a reconciler whose `.State.Status` is not
    `running` (a restart loop included, which Docker reports as running)
    fails, and otherwise its own audit (`reconcile-compose.sh --audit`,
    requirement 2.5a) is relayed line for line. Every check but the first is
    read-only against Docker (`docker compose exec/ps`,
    `docker inspect/logs`, `diff`), so it is safe to allow-list like
    `watch-node.sh`; the `.env` check reads only the host filesystem
    (`stat`, a glob) and runs even when the stack is down. Exit 0 all checks
    passed, 1 at least one failed, 2 unable to check — before any check ran,
    or because one could not be made (`UNKN`: the audit's own `unable`, or no
    answer from it, which is what an image older than `--audit` gives) and
    none failed — and unable is never reported as clean. Fetched at bring-up
    beside
    `compose.yaml` (component 7, including `cloud-init.yaml`). Unit-tested
    against a stubbed `docker` on `PATH` (`test/check-node-compose.test.sh`);
    must pass `shellcheck`.

    The `.env` check (agent-ops#696) flags, never fixes: `.env` not `0600`
    (see "Bring up a node" in `deploy/docker/README.md` for why — the same
    protection the Approver App's private key already gets) names the file
    and its actual mode; any `.env.bak*`/`*.env.old` sibling beside it names
    each match — a leftover from an ad-hoc token-rotation backup, which the
    same runbook section says to make instead as an in-place edit or a
    `0600` temporary file, never a dated copy.
12a. `scripts/check-node-image.sh` — asks whether this node is running the
    newest image the repository has published (see "The node stack"; the
    library is `lib/image-drift.sh`). Rather than a second, host-side
    registry client, it runs the check inside the scheduler container over
    its stdin (`docker compose exec -T scheduler bash <<INNER`, following
    #154's stdin-not-argv fix at a smaller scale) — the container carries
    the toolchain and the node's own `build-info.json`, neither of which the
    host is assumed to have. An empty cache path is passed, so the answer is
    always this instant's, never `scripts/state-sync.sh` or
    `scripts/publish-dashboard.sh`'s last cached one. Exit 0 current, or
    behind by less than `config.json`'s `image_behind_grace_hours`
    (read from inside the container, the same value the dashboard badge
    uses), 1 behind past it, 2 unable to check — a registry the container
    could not reach, or no `compose.yaml` in the stack directory. Fetched at
    bring-up beside `compose.yaml` (component 7). Unit-tested against a
    stubbed `docker` on `PATH` (`test/check-node-image.test.sh`); must pass
    `shellcheck`.
