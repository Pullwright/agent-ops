#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/coordinator-phase.sh — issue #1958's second continuation of #771's
# split, after lib/gather-phase.sh. One function, `run_coordinator_through_
# finishing_phase`, covering everything from the Co-Ordinator stage itself
# (one invocation per repository, issue #587) through candidate selection
# and the claim, the workspace, the Implementer stage, the Reviewer stage,
# the Approver stage and the landing-arming step — the whole of what used to
# be the rest of agent-cycle.sh's own top-level script body, ending on the
# script's own final statement.
#
# A pure move out of agent-cycle.sh's own top-level script body — never into
# functions, so the body keeps its exact original indentation (including
# column-0 `if`/`while` blocks) rather than being reformatted as a function's
# own, the same as lib/candidate-gather.sh, lib/decision-veto.sh and
# lib/gather-phase.sh already do. Three function definitions this body
# already contained (`ensure_labels_for`, `premerge_rebase_only_capture`,
# `rebase_only_advisory_check`) travel with it unchanged — each is still
# defined, and only used, inside this same function's body. Several
# test/*.test.sh files lift specific lines out of this file by literal
# pattern, the same way they did out of agent-cycle.sh before the move; only
# the file path changed for them.
#
# Sourced by agent-cycle.sh, after every lib/*.sh file this function's body
# calls into, as the very last statement of the cycle.

run_coordinator_through_finishing_phase() {
# --- 4. Co-Ordinator stage — one invocation per repository (issue #587) ---
# `coordinator_base_prompt` is rendered further up, ahead of requirement 4i's
# fit, because that fit has to know how many of the window's bytes the prompt
# text itself has already spent before it can decide what the runtime input may
# have. It is identical across every repository's invocation below — only the
# small per-repo runtime input differs — which is what lets provider-side
# prompt caching discount the repeated prefix on every engagement after the
# first (see the pull request that introduced this loop for the measured
# per-cycle cost, priced under D14).
#
# Each repo in `ordered_repos_json` — already in requirement 3's walk order —
# gets its own engagement, seeing only its own `repos` entry, `blocked`,
# `refinements` and `claimed`: a repo B block or claim can never leak into
# repo A's prompt, and a repo carries no bytes of another repo's backlog. The
# five requirement-15a-15e cross-repo tiers (security, urgent issues,
# review-feedback, merge-conflicts, dequeued, abandoned-drafts) that used to
# let one completion judge "is repo Z's finding more urgent than repo A's
# plain issue" directly no longer have a single completion to be judged in —
# no per-repo engagement ever sees another repo's candidates — so the Script
# performs that reconciliation itself, once every repo has answered, in
# `coordinator_merge_candidates` below.
coord_all_candidates_json='[]'
coord_false_repo_slugs_json='[]'
coord_false_reasons=()
# How many of this cycle's engagements never produced a verdict at all — a
# refused launch, a wedged run, an unparseable final message. Distinct from
# `coord_false_repo_slugs_json` (a repository that answered, and answered
# "nothing here"): a repository that was never successfully asked has
# established nothing about its own backlog, which is what the two guards
# below this loop turn on.
coord_n_failed=0
# Accumulated by hand across every repo's own log_needs_refinement_items/
# log_voided_items call below: each call resets its own
# coord_recorded_refinement_json/coord_recorded_voided_json to just that call's
# own band (lib/candidate-select.sh) rather than adding to a running total,
# which is exactly right when there is one call per cycle but loses every
# earlier repo's own band here unless this loop folds each one in itself.
coord_fleet_recorded_refinement_json='[]'
coord_fleet_recorded_voided_json='[]'

coord_n_repos="$(jq 'length' <<<"$ordered_repos_json")"
for (( coord_ri = 0; coord_ri < coord_n_repos; coord_ri++ )); do
  coord_repo_entry="$(jq -c --argjson i "$coord_ri" '.[$i]' <<<"$ordered_repos_json")"
  coord_repo_slug="$(jq -r '.slug' <<<"$coord_repo_entry")"
  coord_repo_only_json="$(jq -c '[.]' <<<"$coord_repo_entry")"
  # A blocked entry with no `repo` at all (a fleet-level block, never tied to
  # one repository) is included in every repo's own list rather than none —
  # `(.repo // $r) == $r` reads true whether the entry names this repo or
  # names none — so a fleet-wide block can never be silently dropped from
  # every per-repo view the way excluding it outright would risk.
  coord_repo_blocked_json="$(jq -c --arg r "$coord_repo_slug" \
    '[.[] | select((.repo // $r) == $r)]' <<<"$coordinator_blocked_json")"
  coord_repo_refinements_json="$(coordinator_refinements_view "$refinements_json" "$coord_repo_only_json")"
  coord_repo_claimed_json="$(jq -c --arg r "$coord_repo_slug" '[.[] | select(.repo == $r)]' <<<"$claimed_json")"
  coord_repo_input="$(jq -nc \
    --arg model_default "$implementer_model_default" \
    --arg model_trivial "$implementer_model_trivial" \
    --arg label "$pr_label" \
    --argjson cmax "$candidates_max" \
    --argjson policies "$refinement_policy_json" \
    'input as $repos | input as $blocked | input as $refinements | input as $claimed
     | {repos: $repos, blocked: $blocked, refinements: $refinements, claimed: $claimed,
        models: {default: $model_default, trivial: $model_trivial}, pr_label: $label,
        candidates_max: $cmax, refinement_policy: $policies}' \
    <<<"$(printf '%s\n' "$coord_repo_only_json" "$coord_repo_blocked_json" "$coord_repo_refinements_json" "$coord_repo_claimed_json")")"

  coordinator_prompt="$coordinator_base_prompt

## Runtime input for this cycle

\`\`\`json
$(jq . <<<"$coord_repo_input")
\`\`\`
"
  # The slug's own `/` is flattened out of the filename, never carried into
  # it: `$cycle_dir/coordinator-Pullwright/agent-ops.out` names a directory
  # component nothing in this cycle creates, and `run_claude_stage` redirects
  # into both `stage_stream_file "$out_file"` and `"$out_file.stderr"` — so
  # every engagement, in every repository, on every cycle, would die in its
  # own backgrounded subshell before `claude` was ever exec'd. One flat file
  # per repository in the cycle directory instead, which is also the shape
  # `scripts/state-sync.sh` and `scripts/publish-dashboard.sh` already expect
  # a cycle's stage transcripts to have.
  coordinator_out="$cycle_dir/coordinator-${coord_repo_slug//\//-}.out"
  if ! run_coordinator_stage_attempt "$coordinator_out" "$coordinator_prompt" \
      "$(jq -nc --arg r "$coord_repo_slug" '{repo: $r}')"; then
    # This repo's own engagement failed to launch or never produced a
    # parseable message — run_coordinator_stage_attempt already logged
    # attempt-failed/handle_stage_failure for it (no claim of this repo's own
    # to release; the Co-Ordinator holds none). One repo's failure must not
    # cost every other repo this cycle's own chance, so the loop continues
    # rather than exiting the way the single fleet-wide attempt used to.
    coord_n_failed=$(( coord_n_failed + 1 ))
    continue
  fi
  coord_repo_work_order_json="$coord_attempt_result_json"

  if (( DRY_RUN )); then
    jq --arg r "$coord_repo_slug" '{repo: $r} + .' <<<"$coord_repo_work_order_json"
  fi

  log_unblocked_items "$coord_repo_work_order_json"
  log_recheck_clean_items "$coord_repo_work_order_json"
  # This repo's own entry, verbatim: the void guard (requirement 34d) tests a
  # verdict against the same candidates that produced it, so it can never
  # refuse a void over something this engagement could not have seen.
  log_voided_items "$coord_repo_work_order_json" "$coord_repo_only_json"
  coord_fleet_recorded_voided_json="$(jq -nc 'input as $a | input as $b | $a + $b' \
    <<<"$coord_fleet_recorded_voided_json"$'\n'"$coord_recorded_voided_json")"
  # Requirement 16a's reports, recorded after the two clearing paths above so
  # an item this cycle unblocked or voided is not immediately re-blocked by a
  # report in the same message.
  log_needs_refinement_items "$coord_repo_work_order_json"
  coord_fleet_recorded_refinement_json="$(jq -nc 'input as $a | input as $b | $a + $b' \
    <<<"$coord_fleet_recorded_refinement_json"$'\n'"$coord_recorded_refinement_json")"

  coord_repo_selected="$(jq -r '.selected' <<<"$coord_repo_work_order_json")"
  if [[ "$coord_repo_selected" == "true" ]]; then
    # Requirement 20's single-selection grace, preserved verbatim through the
    # split: a work order that carries no `candidates` array at all — the
    # work-order fields at the top level instead — is still read as a
    # one-candidate list, with the same four fields stripped the pre-split
    # "5b" block stripped. Dropping it here would lose that repository's whole
    # selection in silence, and invisibly: a repository that said
    # `"selected": true` is not in `coord_false_repo_slugs_json`, so
    # requirement 3v's corroboration cannot catch the loss either.
    coord_repo_cands="$(jq -c --argjson idx "$coord_ri" \
      '(if (.candidates | type) == "array" then .candidates
        else [del(.selected, .unblocked, .recheck_clean, .voided)] end)
       | to_entries
       | map(.value + {_repo_order: $idx, _rank: .key})' \
      <<<"$coord_repo_work_order_json" 2>/dev/null)"
    [[ -n "$coord_repo_cands" ]] || coord_repo_cands='[]'
    if [[ "$(jq 'length' <<<"$coord_repo_cands" 2>/dev/null || echo 0)" == "0" ]]; then
      # `"selected": true` with a `candidates` array present but empty is a
      # contract violation the engagement itself should never produce — the
      # grace path above always contributes exactly one candidate, so this
      # can only be an explicit empty array. Trusting the `true` verdict
      # anyway would leave this repository out of `coord_false_repo_slugs_json`
      # while contributing nothing to the merge: requirement 3v's
      # corroboration is scoped to that set, so this repository's own
      # eligible items would be checked by nothing, and a fleet-wide
      # `none-selected` could arm the no-op fingerprint (requirement 3b)
      # against a backlog no verdict actually accounted for. Fold it into the
      # false set instead, exactly as an honest `"selected": false` is.
      coord_false_repo_slugs_json="$(jq -c --arg r "$coord_repo_slug" '. + [$r]' <<<"$coord_false_repo_slugs_json")"
      coord_false_reasons+=("$coord_repo_slug: reported selected:true but returned no candidates")
    else
      coord_all_candidates_json="$(jq -nc 'input as $a | input as $b | $a + $b' \
        <<<"$coord_all_candidates_json"$'\n'"$coord_repo_cands")"
    fi
  else
    coord_false_repo_slugs_json="$(jq -c --arg r "$coord_repo_slug" '. + [$r]' <<<"$coord_false_repo_slugs_json")"
    coord_false_reasons+=("$coord_repo_slug: $(jq -r '.reason // "no reason given"' <<<"$coord_repo_work_order_json")")
  fi
done

# The running fleet-wide totals, restored to the names the corroboration
# below (and any future reader) expects — exactly what the single fleet-wide
# invocation's own one call to each log_* function used to leave behind.
coord_recorded_refinement_json="$coord_fleet_recorded_refinement_json"
coord_recorded_voided_json="$coord_fleet_recorded_voided_json"

# Not one engagement produced a verdict: exit exactly where the single
# fleet-wide attempt exited, and for the same reason. Every failure is
# already recorded (`run_coordinator_stage_attempt` logs attempt-failed and
# calls `handle_stage_failure`, which sets this node's own terminal state),
# and this cycle established *nothing* about any repository's backlog — so
# the corroboration/stand-down below must not run at all: with no repository
# in `coord_false_repo_slugs_json` it would sail past both corroboration
# branches and log a `none-selected` carrying `noop_fingerprint_value`,
# arming `noop_skip_reason` against a fingerprint no model ever saw. A launch
# failure is typically node-wide — an API refusal, a usage limit, an image
# fault — so "every engagement failed" is the ordinary shape of this failure,
# not an exotic one, and the symptom it would buy is the silent stall
# `lib/noop-skip.sh`'s own header calls this system's signature failure mode.
if (( coord_n_repos > 0 && coord_n_failed >= coord_n_repos )); then
  exit 0
fi

# --- 5. Merge, corroborate, and — only if every repo came back empty —
#        mechanically fall back (requirements 3v/15z/17a) ---
# `candidates_max` is a fleet-wide cap here for the first time: no per-repo
# engagement could enforce it across repos it never saw, so each one is
# still free to return up to its own `candidates_max`, and the Script caps
# the merged, tier-ordered result before it ever reaches "5b" below.
candidates_json="$(coordinator_merge_candidates "$coord_all_candidates_json" "$ordered_repos_json" "$candidates_max")"
coord_n_merged="$(jq 'length' <<<"$candidates_json" 2>/dev/null || echo 0)"
selected_by_fallback=0
coord_reason="$(printf '%s; ' ${coord_false_reasons[@]+"${coord_false_reasons[@]}"})"
coord_reason="${coord_reason%; }"
[[ -n "$coord_reason" ]] || coord_reason="no repository reported a verdict this cycle"
# A cycle that could not ask every repository says so in its own stand-down
# reason, rather than letting the repositories that *did* answer read as the
# whole fleet's verdict.
if (( coord_n_failed > 0 )); then
  coord_reason="$coord_reason (+$coord_n_failed of $coord_n_repos engagement(s) produced no verdict at all)"
fi

if (( coord_n_merged == 0 )); then
  # `coord_n_failed` is passed through so a partial cycle cannot arm the
  # no-op short-circuit either: a fleet-wide fingerprint claims every
  # configured repository was asked and had nothing, which is exactly what a
  # cycle with a failed engagement has not established.
  if ! coordinator_corroborate_and_fallback "$coord_false_repo_slugs_json" "$coord_reason" \
      "$coord_recorded_refinement_json" "$coord_recorded_voided_json" "$coord_n_failed"; then
    exit 0
  fi
fi

# --- 5b. Candidates, and the claim (requirement 17a) ---
# `candidates_json` is already the merged, tier-ordered, `candidates_max`-
# capped list "5" above built — either the reconciled real candidates from
# every repo that selected, or the one-candidate fallback pick. The claim
# itself is taken by the Script, never the model: keys are derived
# deterministically (two nodes must compute the same name for the same
# item), the write is create-only so GitHub arbitrates the race, and a lost
# race just moves down the ranking instead of costing the cycle.

if (( DRY_RUN )); then
  # A dry run claims nothing: record the top of the ranking and stop.
  log_event "selection" "$(jq -c --argjson fb "$selected_by_fallback" \
    '.[0] | {repo, item, source, model, title} + (if $fb == 1 then {selected_by: "script-fallback"} else {} end)' \
    <<<"$candidates_json")"
  exit 0
fi

# The gather-time claims, snapshotted before `claimed_json` is reused just
# below as the claim loop's winner slot: the loop's pre-claim check reads
# what this cycle's own gather saw, and reading it out of a variable about
# to be overwritten would silently compare against nothing.
claims_at_gather_json="$claimed_json"
claimed_json=""
n_cand="$(jq 'length' <<<"$candidates_json")"
claim_attempts=0
claim_unreachable=0
# race_losses (requirement 17d): how many candidates this cycle lost to a
# peer genuinely holding the item (cause "held" — healthy contention, not an
# outage), distinct from `claim_unreachable`. Carried on both the eventual
# `selection` (only when it recovered from a loss — issue #245) and the
# all-claimed `stand-down` below, so a rising rate is visible without
# cross-referencing `claim-lost` events by hand — the observability
# finish-then-continue and the faster cadence both raise the concurrent-claim
# frequency for (#248).
race_losses=0
# claim_skips: candidates dropped without an attempt because this cycle's own
# gather already saw them claimed (candidate_preclaimed above). Deliberately
# not folded into race_losses: a loss knowable from data in hand is the
# Co-Ordinator proposing claimed work — a selection defect — where a race
# loss is healthy contention, and the dashboard's `↻ raced` badge must keep
# meaning only the second.
claim_skips=0
# trace_faults: candidates dropped by requirement 17f that the repair above
# could not rescue, or by requirement 17h (agent-ops#769) failing to compose
# a work order at all. Counted separately from both of the above for the
# reason issue #767 exists: without it, a cycle whose every candidate failed
# traceability left `claim_attempts` and `claim_skips` at zero and fell
# through the reason ladder below to `raced` — reporting healthy contention,
# with `race_losses: 0` and not one `claim-lost` event to its name, for 15
# hours. A stand-down that names the wrong cause is worse than one that names
# none: it sends the reader after a claim problem that was never there.
trace_faults=0
for (( ci = 0; ci < n_cand; ci++ )); do
  cand="$(jq -c --argjson i "$ci" '.[$i]' <<<"$candidates_json")"
  c_repo="$(jq -r '.repo // ""' <<<"$cand")"
  c_item="$(jq -r '.item // ""' <<<"$cand")"
  c_source="$(jq -r '.source // ""' <<<"$cand")"
  c_db="$(jq -r '.default_branch // "main"' <<<"$cand")"
  c_takeover="$(jq -r '.takeover // false' <<<"$cand")"
  [[ -n "$c_repo" && -n "$c_item" ]] || continue
  # Requirement 17h (agent-ops#769, resolving #844 option (b)): for every
  # source the Script already gathers as structured data, `context`/
  # `acceptance`/`title` are composed here — from a live fetch for
  # `issues`/`tech-debt` (the only two the fit ladder ever trims), from the
  # never-trimmed pre-fetched entry otherwise — never left as whatever the
  # model (or the fallback) wrote. `compose_selected_candidate_text` returns
  # 2 for the three sources the Co-Ordinator still derives itself live
  # (`project-review`, `failed-runs`, `implementation-plan`, which have no
  # band entry to compose from and were never subject to the trimming this
  # requirement exists to close) — `cand` is left exactly as selected for
  # those, and requirement 17f below still checks the model's own text the
  # way it always has. A compose failure (1: the item was not found in
  # this cycle's own gather, or the live fetch failed) is fail-closed, folded
  # into the same `untraceable` cause requirement 17f already uses for "a
  # construction-time check refused to hand this candidate on, no peer
  # involved" — a failed live read is exactly that, not a reason to fall back
  # to a trimmed or stale entry.
  c_composed=0
  if [[ -n "$c_source" ]]; then
    c_compose_out=""
    c_compose_rc=0
    c_compose_out="$(compose_selected_candidate_text "$cand" "$ordered_repos_json" "$refinements_json")" \
      || c_compose_rc=$?
    if (( c_compose_rc == 0 )); then
      cand="$c_compose_out"
      c_composed=1
    elif (( c_compose_rc == 1 )); then
      trace_faults=$(( trace_faults + 1 ))
      log_event "claim-skipped" "$(jq -nc --arg r "$c_repo" --arg i "$c_item" --arg s "$c_source" \
        --arg d "the Script could not compose this candidate's context/acceptance from a live read or this cycle's own gather — treated as untraceable rather than assumed compliant" \
        '{repo: $r, item: $i, source: $s, cause: "untraceable", detail: $d}')"
      continue
    fi
  fi
  # Requirement 17f (issue #626): checked before the pre-claimed check below,
  # cheaper and unrelated to it — a candidate that fails traceability is
  # never safe to hand to an Implementer regardless of whether it is also
  # already claimed elsewhere.
  #
  # Scoped to a model-composed work order, which is the only kind that can
  # carry another item's refinement at all: a fallback pick (requirement 3v)
  # is built by `fallback_select_candidate` out of the very band entry it
  # names, in jq, so a cross-item swap is not a shape it can take. It also
  # composes `context` from that entry's own record and never from
  # `refinements`, so a spec-refined item picked mechanically would fail the
  # verbatim check every single time — and, the fallback's own candidate list
  # being one candidate long, faulting it would leave the cycle with nothing
  # to claim, disarming the one path that exists to keep the fleet moving
  # when the model will not select. A requirement 17h compose (`c_composed`)
  # is exempt for the identical reason: `compose_selected_candidate_text`
  # already calls `refinement_traceability_repair` itself, unconditionally,
  # so the splice this check exists to verify has already happened by
  # construction — checking it again would only ever pass, at the cost of a
  # redundant `gh` read for a `comment_url`-recorded refinement.
  c_trace_fault=""
  c_repaired=""
  (( selected_by_fallback || c_composed )) \
    || c_trace_fault="$(refinement_traceability_fault "$cand" "$refinements_json")"
  if [[ -n "$c_trace_fault" ]]; then
    # Supply the refinement rather than discard the work (issue #767). The
    # Script is holding the text while it asks whether the model copied it,
    # so the honest move is to write it in and let the item through — 17b/20
    # require the work order to *carry* the refinement, not the model to have
    # been the one who carried it. `refinement_traceability_repair` declines
    # the one fault where appending is unsafe (a `comment_url` naming a
    # different issue: corrupt ledger, and the very cross-item swap #626 is
    # about), so a fault that survives the repair is still a hard skip.
    c_repaired="$(refinement_traceability_repair "$cand" "$refinements_json")"
    if [[ -n "$c_repaired" ]] \
       && [[ -z "$(refinement_traceability_fault "$c_repaired" "$refinements_json")" ]]; then
      cand="$c_repaired"
      log_event "work-order-repaired" "$(jq -nc --arg r "$c_repo" --arg i "$c_item" --arg s "$c_source" --arg d "$c_trace_fault" \
        '{repo: $r, item: $i, source: $s, cause: "untraceable", detail: $d}')"
      c_trace_fault=""
    fi
  fi
  if [[ -n "$c_trace_fault" ]]; then
    trace_faults=$(( trace_faults + 1 ))
    log_event "claim-skipped" "$(jq -nc --arg r "$c_repo" --arg i "$c_item" --arg s "$c_source" --arg d "$c_trace_fault" \
      '{repo: $r, item: $i, source: $s, cause: "untraceable", detail: $d}')"
    continue
  fi
  if candidate_preclaimed "$c_repo" "$c_item" "$claims_at_gather_json"; then
    claim_skips=$(( claim_skips + 1 ))
    log_event "claim-skipped" "$(jq -nc --arg r "$c_repo" --arg i "$c_item" --arg s "$c_source" \
      '{repo: $r, item: $i, source: $s, cause: "pre-claimed"}')"
    continue
  fi
  claim_attempts=$(( claim_attempts + 1 ))
  claim_rc=0
  pr_claim_lost=0
  c_pr_key=""
  if [[ "$c_source" == "review-feedback" || "$c_source" == "abandoned-drafts" \
        || "$c_source" == "dequeued" || "$c_source" == "landing-refusals" \
        || ( "$c_source" == "merge-conflicts" && "$c_takeover" != "true" ) ]]; then
    # No new branch to create — the PR already exists (a human's review round for
    # review-feedback, this system's own stalled draft for abandoned-drafts, a
    # ready-but-conflicted PR of ours for merge-conflicts, a checks-failure-
    # dequeued PR of ours for dequeued, a PR gate 4 keeps refusing to arm over
    # an unreconciled comment for landing-refusals). The lock is a
    # create-only registry file keyed on the item ref, not a branch create that
    # would 422 against the branch already there.
    #
    # This set is `PREFLIGHT_EXISTING_BRANCH_SOURCES` (lib/preflight.sh) plus
    # the `merge-conflicts` takeover carve-out below; the two must agree, or a
    # source preflight believes has a pre-existing branch would have a fresh
    # one minted for it here and the candidate's own `branch` overwritten with
    # it (requirement 53, issue #979).
    #
    # A `merge-conflicts` candidate carrying `takeover: true` (requirement 3s,
    # issue #250) is the one exception: it names Dependabot's PR, not one of
    # ours, and taking it over means a genuinely new PR on a genuinely new
    # branch — the ordinary branch-claim path below, same as any fresh item.
    claim_kind="file"; claim_key="$c_item"
    c_branch="$(jq -r '.branch // ""' <<<"$cand")"
    c_pr_number="$(pr_number_for_candidate "$cand" "$c_item")"
    CLAIM_NODE="$node_name" CLAIM_CYCLE="$cycle_id" CLAIM_ITEM="$c_item" CLAIM_SOURCE="$c_source" \
      CLAIM_PR_NUMBER="$c_pr_number" \
      "$SCRIPT_DIR/lib/claim.sh" claim file "$c_repo" "$c_item" \
      >>"$cycle_dir/claim.log" 2>&1 || claim_rc=$?
    if (( claim_rc == 0 )) && [[ -n "$c_pr_number" ]]; then
      # Issue #238: the item claim just won is scoped to this round/head SHA
      # (requirements 3c/3e/3g), so it excludes nothing about a peer working the
      # *same PR* under a different item ref — which is exactly how PR #205 was
      # worked by three nodes at once. A second, PR-keyed file claim taken here,
      # alongside it, is what actually excludes fleet-wide: GitHub arbitrates it
      # the same create-only way. Losing it means a peer holds this PR already
      # (under whatever ref won there); nothing was pushed under the item claim
      # yet, so release it and fall through to the next candidate exactly as a
      # lost item claim would — carrying this claim's *own* rc outward, not a
      # flattened 3, so that an unreachable GitHub here still reads as rc 1 and
      # still counts toward the outage stand-down below rather than being
      # miscounted as a fleet politely yielding to itself.
      c_pr_key="pr-${c_pr_number}"
      pr_claim_rc=0
      CLAIM_NODE="$node_name" CLAIM_CYCLE="$cycle_id" CLAIM_ITEM="$c_item" CLAIM_SOURCE="$c_source" \
        CLAIM_PR_NUMBER="$c_pr_number" \
        "$SCRIPT_DIR/lib/claim.sh" claim file "$c_repo" "$c_pr_key" \
        >>"$cycle_dir/claim.log" 2>&1 || pr_claim_rc=$?
      if (( pr_claim_rc != 0 )); then
        timeout "$claim_release_timeout" "$SCRIPT_DIR/lib/claim.sh" release file "$c_repo" "$c_item" \
          >>"$cycle_dir/claim.log" 2>&1 || true
        claim_rc=$pr_claim_rc
        pr_claim_lost=1
      fi
    fi
  else
    c_branch="$(claim_branch_for "$c_source" "$c_item")"
    claim_kind="branch"; claim_key="$c_branch"
    CLAIM_NODE="$node_name" CLAIM_CYCLE="$cycle_id" CLAIM_ITEM="$c_item" CLAIM_SOURCE="$c_source" \
      "$SCRIPT_DIR/lib/claim.sh" claim branch "$c_repo" "$c_branch" "$c_db" \
      >>"$cycle_dir/claim.log" 2>&1 || claim_rc=$?
  fi
  if (( claim_rc == 0 )); then
    claim_active=1
    claim_pr_key="$c_pr_key"
    # Requirement 20/23 (agent-ops#956): pr_label is how every gatherer finds
    # this system's own pull requests again, so the Script stamps its own
    # configured value here unconditionally, the same way it stamps `branch`
    # above — never trusting the Co-Ordinator's copy or the mechanical
    # fallback's composition to be present or correct.
    claimed_json="$(jq -c --arg b "$c_branch" --arg pl "$pr_label" \
      '. + {branch: $b, pr_label: $pl}' <<<"$cand")"
    break
  fi
  # 3 = a peer holds it (healthy contention: the work is being done, just not
  # by this node) — 1 = GitHub was unreachable (fail-closed: this node could
  # not have pushed the work either, but no work is being done by anyone).
  # Opposite operational conditions, so `cause` tells them apart instead of
  # the event wearing one reason for both. `pr-held` is the same healthy
  # contention as `held`, distinguished only so a reader can tell the two
  # claims apart: this candidate's own item claim won, but a peer already
  # holds the PR it targets under a different item ref. It renames `held`
  # alone — an `unreachable` PR-keyed claim is still an outage and must still
  # be counted as one, or a fleet-wide outage during the second claim would
  # stand down reporting contention that never happened.
  case "$claim_rc" in
    3) claim_cause="held"; race_losses=$(( race_losses + 1 )) ;;
    1) claim_cause="unreachable"; claim_unreachable=$(( claim_unreachable + 1 )) ;;
    *) claim_cause="$claim_rc" ;;
  esac
  if (( pr_claim_lost )) && [[ "$claim_cause" == "held" ]]; then
    claim_cause="pr-held"
  fi
  log_event "claim-lost" "$(jq -nc --arg r "$c_repo" --arg i "$c_item" --arg b "$c_branch" \
    --argjson rc "$claim_rc" --arg cause "$claim_cause" --arg pr "$c_pr_key" \
    '{repo: $r, item: $i, branch: $b, rc: $rc, cause: $cause} + (if $pr == "" then {} else {pr_claim_key: $pr} end)')"
  # claim-race-duplicate (docs/FLOW-SCHEMA.md, D23): only `held`/`pr-held` —
  # healthy contention, a peer genuinely already working this item — is a
  # repetition; `unreachable` is an outage and any other cause is a selection
  # defect, neither of which is "work duplicated by a race". The same
  # distinction scripts/pickup-metrics.sh's own header draws and reuses
  # (issue #596's own instruction: reuse that rule, do not restate it
  # differently).
  rework_claim_race_json="$(rework_claim_race_duplicate_fields "$claim_cause" "$claim_rc" "$c_repo" "$c_item")"
  [[ -n "$rework_claim_race_json" ]] && log_event "rework" "$rework_claim_race_json"
done

if [[ -z "$claimed_json" ]]; then
  # Same test as the reason text below, structured: a fleet-wide dashboard
  # reader (or any other consumer) needs "why did this cycle stand down?"
  # without re-parsing prose (issue #245). `raced` means every candidate was
  # lost to healthy contention (at least one `held`); `unreachable` means
  # GitHub itself could not be reached for any of them — an outage, not the
  # fleet politely yielding to itself; `pre-claimed` means nothing was ever
  # attempted, because every candidate was one this cycle's own gather had
  # already seen claimed — not contention at all, but the Co-Ordinator
  # proposing claimed work past both the deterministic filters and its own
  # exclusion 3, which is a selection defect worth its own name.
  if (( claim_attempts > 0 && claim_unreachable == claim_attempts )); then
    standdown_reason="GitHub could not be reached for any candidate — this is an outage, not contention"
    standdown_cause="unreachable"
  elif (( claim_attempts == 0 && claim_skips > 0 )); then
    standdown_reason="every candidate was already claimed before this cycle's Co-Ordinator ran — skipped without an attempt"
    standdown_cause="pre-claimed"
  elif (( claim_attempts == 0 && trace_faults > 0 )); then
    # Requirement 17f dropped every candidate and the repair could not rescue
    # one (issue #767), or requirement 17h (agent-ops#769) could not compose
    # one at all — the item was missing from this cycle's own gather, or its
    # live fetch failed. Both share this one cause: nothing was claimed,
    # nothing was raced, and nothing about the fleet is busy — this is a
    # defect in the work orders reaching the gate, and it is named as one so
    # no reader mistakes it for contention again.
    standdown_reason="every candidate failed the refinement traceability or compose check — no claim was attempted"
    standdown_cause="untraceable"
  else
    standdown_reason="every candidate is already claimed elsewhere"
    standdown_cause="raced"
  fi
  # A raced stand-down chains (requirement 39): a cycle that lost every
  # attempted claim to peers has spent its Co-Ordinator learning the fleet
  # is busy, not that the fleet is done — `ordered_repos_json` still says
  # sources remain, and the winners' claims are visible to a fresh gather
  # now in a way they were not when this cycle gathered, so the chained
  # cycle's own deterministic filters route it to the next-best item
  # instead of the same fight. The same bounded price (`max_chained_cycles`)
  # a productive chain pays. The other three causes never chain: against an
  # `unreachable` GitHub a fresh cycle buys a second Co-Ordinator engagement
  # and the same empty-handed ending; after a `pre-claimed` stand-down — a
  # selection defect, not contention — an identical re-run is more likely to
  # repeat the defect than to route around it; and an `untraceable`
  # stand-down is the Script's own construction-time check refusing to hand a
  # candidate on — no peer's claim or absence explains the fault, so a fresh
  # cycle would spend its chain budget re-composing the same broken work
  # order rather than routing around a peer.
  if [[ "$standdown_cause" == "raced" ]] \
      && ! (( ONCE )) \
      && chain_should_continue "$chain_count" "$max_chained_cycles" "$ordered_repos_json"; then
    chain_eligible=1
  fi
  log_event "stand-down" "$(jq -nc --argjson n "$n_cand" --arg r "$standdown_reason" --arg c "$standdown_cause" \
    --argjson rl "$race_losses" --argjson sk "$claim_skips" \
    --argjson tf "$trace_faults" \
    '{reason: $r, candidates: $n, cause: $c, race_losses: $rl}
     + (if $sk > 0 then {claim_skips: $sk} else {} end)
     + (if $tf > 0 then {trace_faults: $tf} else {} end)')"
  # node-state (docs/FLOW-SCHEMA.md, D21): translates this stand-down's own
  # (unchanged) cause vocabulary onto the six-state one — see
  # node_time_state_for_cause's header for why raced/pre-claimed/
  # untraceable are translated rather than renamed.
  nts_state=""; nts_cause=""
  IFS=$'\t' read -r nts_state nts_cause < <(node_time_state_for_cause "$standdown_cause")
  # `if`, not `&&`: an unrecognised cause is the expected degradation here
  # (node_time_state_for_cause prints nothing rather than guessing a state),
  # and a trailing `&&` whose test fails is a non-zero status at exactly the
  # place `set -e` acts on — this stand-down would abort with 1 instead of
  # reaching the `exit 0` below, recording an ordinary ending as a failure.
  if [[ -n "$nts_state" ]]; then
    set_node_state_terminal "$nts_state" "$nts_cause"
  fi
  exit 0
fi

work_order_json="$claimed_json"
selected_repo="$(jq -r '.repo // ""' <<<"$work_order_json")"
selected_item="$(jq -r '.item // ""' <<<"$work_order_json")"
selected_source="$(jq -r '.source // ""' <<<"$work_order_json")"
selected_branch="$(jq -r '.branch // ""' <<<"$work_order_json")"
selected_source="$(jq -r '.source // ""' <<<"$work_order_json")"
selected_default_branch="$(jq -r '.default_branch // "main"' <<<"$work_order_json")"
# `preview` (D19 Phase 1, requirement 24a) is stamped onto the work order here,
# deterministically, rather than left to the Co-Ordinator to copy: the same
# reasoning `pr_label`'s own header comment already gives — a mechanical field
# needs no model judgement, and a claimed_json path (review-feedback,
# merge-conflicts, dequeued, landing-refusals, abandoned-drafts) never passes
# through the Co-Ordinator at all, so this is the one point every path
# converges on before either stage prompt is assembled.
selected_preview_json="$(preview_config_for_repo "$DEFAULTED_CONFIG" "$selected_repo")"
work_order_json="$(jq -c --argjson p "$selected_preview_json" '. + {preview: $p}' <<<"$work_order_json")"
# Remapped once here, ahead of both the Implementer and the Reviewer stage
# launches below, since both inherit this same shell's exported environment.
preview_config_export_vercel_credentials "$selected_preview_json"
# `race_losses` is present only when this selection recovered from at least
# one lost claim (issue #245) — an ordinary first-try selection, still the
# overwhelming majority, carries nothing new on this event. `selected_by`
# (requirement 3v, issue #321) is present only for a mechanical fallback
# pick, letting a human reading the raw log tell a fallback pick from a
# model pick by eye; no downstream reader in this repository keys on it —
# the dashboard's actor and model scorecards panel (issue #610) reports
# verdict quality as the corroboration rate computed from `corroboration`
# events instead.
log_event "selection" "$(jq -c --argjson n "$race_losses" --argjson fb "$selected_by_fallback" \
  '{repo, item, source, model, title, branch} + (if $n > 0 then {race_losses: $n} else {} end)
   + (if $fb == 1 then {selected_by: "script-fallback"} else {} end)' \
  <<<"$work_order_json")"

# Rework record (docs/FLOW-SCHEMA.md, D23, issue #596): three of the nine
# classes are detected the moment a finishing source is selected — the
# candidate itself (gather-review-feedback.sh, gather-merge-conflicts.sh,
# gather-abandoned-drafts.sh) is the detector, and selection is this cycle's
# own commitment to reworking it, tied to {repo, item, pr_url}.
# `rework_selection_fields` prints nothing for any other source.
rework_selection_fields_json="$(rework_selection_fields "$work_order_json")"
[[ -n "$rework_selection_fields_json" ]] && log_event "rework" "$rework_selection_fields_json"

# Finish-then-continue (requirement 39): a claim just won is real work, and
# `ordered_repos_json` — gathered once, ahead of the Co-Ordinator, and
# untouched since — is cheap evidence of whether more might be waiting
# (lib/chain.sh). `--once` is a human or a test asking for exactly one
# cycle, not an unattended tick, so it never chains regardless. The next
# chained cycle runs its own Co-Ordinator, with its own fresh gather and its
# own no-op fingerprint, so this is only ever a cheap "was it worth asking
# again", never a prediction of what that cycle will find. Set before the
# pre-flight check below so that even a cycle that voids out here — real
# work, just none of it left to do — still chains rather than wasting the
# rest of its tick.
if ! (( ONCE )) && chain_should_continue "$chain_count" "$max_chained_cycles" "$ordered_repos_json"; then
  chain_eligible=1
fi

# --- 5c. Pre-flight already-done check (issue #245) ---
# Deterministic, no LLM, run before the clone and the Implementer engagement
# either one is paid for: ask whether the item this cycle just claimed is
# already done — its register row resolved, its issue closed, its
# work-order branch already merged, or (for a finishing source, whose item is
# the `pr-<n>-…` shape `lib/work-gone.sh` recognises) its pull request
# already closed or merged — and, separately, whether it should be *deferred*
# because an open PR already carries the just-claimed branch (a non-terminal
# signal; see below).
# `source_states_json` already carries every repo this cycle walked, gathered
# well before the claim, which is all an issue or a finishing source's PR
# needs. A register-shaped ref would additionally need its own fresh register
# read here, because a freshly claimed item was never a member of the blocked
# set `register_status_json` is scoped to — but no currently-live source
# claims a register-shaped ref (the `tech-debt` band moved to
# `pw::type:tech-debt`-labelled issues, agent-ops#875), so no source pays for
# one; `preflight_done_reason` still accepts a register map for a repository
# that has not migrated off register-shaped refs.
preflight_reason="$(preflight_done_reason "$selected_repo" "$selected_item" "$selected_branch" \
  "$source_states_json" '{}')"
# The ancestry check is one of the two live `gh` calls in this section
# (lib/preflight.sh's header explains why it is gated to the four sources
# whose branch predates the claim), so it only runs when the cheaper, pure
# checks above found nothing.
if [[ -z "$preflight_reason" ]] && preflight_existing_branch_source "$selected_source"; then
  preflight_reason="$(preflight_branch_merged_reason "$selected_repo" "$selected_default_branch" "$selected_branch")"
fi
# The other live call (issue #1360): a `pr-<n>-review-<id>` item's blocking
# review may already be superseded — most often because this cycle's own
# `review_feedback` band was replayed from a non-selected node's
# `expensive-gather` cache (requirement 48) rather than read fresh — and
# `work_gone_clearances` above cannot see that, since the pull request itself
# stays open throughout. Gated to `review-feedback` the same way the ancestry
# check above is gated to its own four sources: `preflight_review_feedback_reason`
# itself no-ops on any other source's item shape, but there is no reason to pay
# the call for one.
if [[ -z "$preflight_reason" && "$selected_source" == "review-feedback" ]]; then
  preflight_reason="$(preflight_review_feedback_reason "$selected_repo" "$selected_item")"
fi
if [[ -n "$preflight_reason" ]]; then
  log_item_void "preflight" "$preflight_reason" \
    "$(jq -nc --arg e "$preflight_reason" '{evidence: $e}')"
  release_claim no-pr
  exit 0
fi
# The stale-open-PR signal defers rather than voids (requirement 34m; #279):
# it is the one pre-flight fact that can become false again — that pull
# request may close unmerged tomorrow — and its usual cause is the digest's
# own staleness, sampled before the Co-Ordinator engagement. A void is
# terminal (requirement 34h), so the claim is released and the item left for
# a later cycle's fresh digest instead.
preflight_defer="$(preflight_defer_reason "$selected_repo" "$selected_item" "$selected_branch" \
  "$source_states_json")"
if [[ -n "$preflight_defer" ]]; then
  log_event "warning" "$(jq -nc \
    --arg d "pre-flight deferred $selected_repo $selected_item — $preflight_defer; claim released, the item is re-judged against a fresh digest next cycle" \
    '{detail: $d}')"
  release_claim no-pr
  exit 0
fi

# --- 6. Workspace ---
repo_slug="$(jq -r '.repo' <<<"$work_order_json")"
impl_model="$(jq -r '.model' <<<"$work_order_json")"

clone_dir="$workspace_root/$cycle_id"
assert_in_workspace "$clone_dir"
# `clone_repo` (lib/repo-clone.sh) — `git clone`, not `gh repo clone`, because
# `gh` resolves the repository through a GraphQL query that is billed against
# the API budget, and this is the last step before the cycle's expensive stage.
# That file holds the full reasoning and the `CLONE_GIT` test seam; both
# pipelines clone through it so they cannot diverge.
if ! clone_repo "$repo_slug" "$clone_dir" 2>"$cycle_dir/clone.err"; then
  log_event "attempt-failed" "$(jq -nc --arg d "$(cat "$cycle_dir/clone.err")" '{stage: "workspace", detail: $d}')"
  # The claim was taken before the clone; a cycle that ends here must not
  # keep holding the item (requirement 17a's release rules).
  release_claim no-pr
  exit 0
fi
# `du -sb` of the clone just made, logged against its own repository's slug
# (agent-ops#904, the residual of #756): requirement 2.0c's own derivation
# reads this back from the union log on a later cycle, on any node, so a
# repository's clone size only ever has to be measured once for the whole
# fleet to learn it. Best-effort — an unreadable `du` logs nothing rather
# than a fabricated size, the same "no evidence" convention
# `disk_space_free_kb` already uses.
clone_footprint_bytes="$(disk_space_clone_footprint_bytes "$clone_dir")"
if [[ -n "$clone_footprint_bytes" ]]; then
  log_event "clone-footprint" "$(jq -nc --arg repo "$repo_slug" --argjson bytes "$clone_footprint_bytes" \
    '{repo: $repo, bytes: $bytes}')"
fi

# --- 6a. Labels (requirement 6a) ---
# The gather loop above ("Labels (requirement 6a, agent-ops#687)") already
# ensured $repo_slug's `target` catalogue this cycle, but only if its stamp
# had gone stale — a fresh stamp skips the listing there entirely, and a
# fresh stamp only guarantees the label existed at the *last* listing, not
# now. A stamp this fresh is exactly the state in which nothing else is
# still looking, so `pr_label` deleted since then would go unnoticed for up
# to `labels_ensure_interval_hours` (24h default) — and the Implementer is
# one `gh pr create --label` away from losing its whole run to that gap. So
# the selected repository still gets its own unconditional, unstamped
# listing here, immediately before the stage that needs the label to
# exist — one extra listing per cycle, the same cost main paid before
# agent-ops#687, for the one repository where a miss is most expensive.
ensure_labels_for() {
  local slug="$1" role="$2" report
  report="$(labels_reconcile_role "$CONFIG_FILE" "$SCHEMA_FILE" "$slug" "$role" 2>/dev/null || true)"
  [[ -n "$report" ]] || return 0
  log_event "labels-ensured" "$(jq -nc --arg repo "$slug" --arg role "$role" \
    --arg report "$report" '
    {repo: $repo, role: $role}
    + ($report | split("\n") | map(select(length > 0) | split("\t"))
       | {created: [.[] | select(.[0] == "created") | .[1]],
          updated: [.[] | select(.[0] == "updated") | .[1]],
          deleted: [.[] | select(.[0] == "deleted") | .[1]],
          failed:  [.[] | select(.[0] == "failed")  | .[1]]})')"
}
ensure_labels_for "$repo_slug" target

# --- 6b. Rebase-only pre-capture (requirement 31e, agent-ops#1806) ---
# The Reviewer-stage-start check below (requirement 31e) needs to know what
# this pull request's diff looked like *before* the Implementer stage moves
# it, so it is captured here, ahead of that stage, while `$selected_branch`
# still names the pre-push head. A `merge-conflicts` item carrying
# `takeover: true` names Dependabot's own pull request, not one of ours —
# ordinary fresh work (requirement 3s) the Implementer's own procedure
# excludes from this treatment, so it is excluded here too. Best-effort: an
# unreadable ref here simply leaves both empty, and the check below then
# runs the Reviewer stage as normal rather than guessing.
premerge_old_head=""; premerge_old_base=""; premerge_base_name=""
premerge_rebase_only_capture() {
  [[ "$selected_source" == "merge-conflicts" ]] || return 0
  [[ "$(jq -r '.takeover // false' <<<"$work_order_json")" != "true" ]] || return 0
  premerge_base_name="$(jq -r '.base // empty' <<<"$work_order_json")"
  [[ -n "$premerge_base_name" ]] || return 0
  premerge_old_head="$(git -C "$clone_dir" ls-remote origin "refs/heads/$selected_branch" 2>/dev/null | awk '{print $1; exit}')"
  premerge_old_base="$(git -C "$clone_dir" ls-remote origin "refs/heads/$premerge_base_name" 2>/dev/null | awk '{print $1; exit}')"
}
premerge_rebase_only_capture

# --- 6c. Implementer stage-start merge check (requirement 31f, agent-ops#1062) ---
# Requirement 31d's read gave the Reviewer a cheap, advisory look at whether
# its own subject had already merged before an engagement was spent on it
# (escalation #922) — but the Implementer's own five finishing sources
# (`preflight_existing_branch_source`: review-feedback, merge-conflicts,
# dequeued, landing-refusals, abandoned-drafts, less a `merge-conflicts`
# takeover, whose `pr_url` names Dependabot's own pull request rather than a
# subject this stage can retire) hand it a work order whose `pr_url` can be
# just as stale, and nothing asked GitHub about it before paying for the
# stage. Requirement 5c's own pre-flight (`preflight_branch_merged_reason`)
# already runs earlier this same cycle, but against `source_states_json` /
# an ancestry compare sampled before the Co-Ordinator engagement — exactly
# the gap a pull request can merge inside. This is the live read
# `pr_merge_state` (`lib/handoff.sh`) gives instead, one call, immediately
# ahead of the stage it would otherwise waste — advisory, like the
# Reviewer's: an unreadable answer simply runs the stage, since nothing about
# a merge caught here is irreversible the way a draft flip, an Approver
# review or a landing attempt is, and the Reviewer's own handoff-time read
# still guards whatever this stage produces regardless.
pre_implementer_merge_state=""; pre_implementer_merge_sha=""
implementer_subject_pr_url=""
if preflight_existing_branch_source "$selected_source" \
    && [[ "$(jq -r '.takeover // false' <<<"$work_order_json")" != "true" ]]; then
  implementer_subject_pr_url="$(jq -r '.pr_url // empty' <<<"$work_order_json")"
fi
if [[ -n "$implementer_subject_pr_url" ]]; then
  pre_implementer_merge_result="$(pr_merge_state "$implementer_subject_pr_url")" || true
  IFS=$'\t' read -r pre_implementer_merge_state pre_implementer_merge_sha <<<"$pre_implementer_merge_result"
fi
if [[ "$pre_implementer_merge_state" == "merged" ]]; then
  reviewer_merge_observed "$implementer_subject_pr_url" "$pre_implementer_merge_sha" '{}' "implementer-stage-start"
  release_claim no-pr
  echo "$implementer_subject_pr_url"
  exit 0
fi

# --- 7. Implementer stage ---
# implementer is one of the two stages requirement 4a's per-repository layer
# covers (agent-ops#588): $repo_slug's own repos[].prompt_overrides.implementer
# entry wins when present, the installation-wide prompt_overrides.implementer
# entry otherwise — prompt_overrides_json_for_repo resolves that precedence
# before stage_prompt_text ever sees it.
implementer_prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" implementer "$(prompt_overrides_json_for_repo "$DEFAULTED_CONFIG" "$repo_slug")")

## Work order

\`\`\`json
$(jq . <<<"$work_order_json")
\`\`\`

## Cycle

$cycle_id

## Node

$node_name
"
impl_out="$cycle_dir/implementer.out"

stage_budget_apply implementer "$selected_repo" "$impl_model" "{}" "$selected_item"
if run_claude_stage implementer "$(( stage_backstop_min * 60 ))" "$impl_model" "$implementer_prompt" "$impl_out" "$clone_dir" "$(( stage_inactivity_min * 60 ))"; then
  impl_rc=0
else
  impl_rc=$?
fi
log_event "stage-end" "$(jq -nc --argjson rc "$impl_rc" --arg kr "$stage_kill_reason" --argjson m "$(metering_fields "$impl_model" "$impl_out" "$stage_gaps_json")" \
  --arg r "$selected_repo" --arg i "$selected_item" \
  '{stage: "implementer", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m
   + (if $r == "" then {} else {repo: $r} end) + (if $i == "" then {} else {item: $i} end)')"
rework_stage_rerun_maybe "implementer" "$stage_kill_reason" "$selected_repo" "$selected_item"
log_node_state_transition overhead
# `if`, not `&&`: an empty warning is the common case, and a trailing
# `&&` whose test fails is a non-zero status at exactly the place
# `set -e` acts on — the same trap that cost a --once cycle its
# failure handling at dump_stage_output.
watchdog_warning="$(stage_watchdog_warning implementer || true)"
if [[ -n "$watchdog_warning" ]]; then
  log_event "warning" "$watchdog_warning"
fi
(( ONCE )) && dump_stage_output "$impl_out"

impl_result="$(jq -r '.result // empty' "$impl_out" 2>/dev/null || true)"
impl_status_json="$(extract_json_result "$impl_result" 2>/dev/null || true)"
if (( impl_rc == 0 )) && [[ -z "$impl_status_json" ]]; then
  impl_status_json="$(stage_salvage_result implementer "$impl_out" "$impl_model" "$clone_dir" || true)"
fi
# Requirement 9's fallback chain, cheapest first and least dependent on the
# stage last. The first three all read something the Implementer had to do:
# report the URL, print it where it could be grepped, write the breadcrumb.
# That is fine for the failures they were written for and useless for the one
# that matters most — a stage that emitted no parseable final message is a
# stage that may have skipped every step after opening the PR — so the chain
# ends by asking GitHub about the branch the Script itself pushed, which needs
# nothing from the model at all. Not free (one API call), so it runs last and
# only when the item is otherwise unnameable.
#
# This one variable is the whole downstream supply: `pr-raised`, the Reviewer
# stage, the Reviewer's hand-back, the `blocked`/`void` verdict paths and both
# `handle_stage_failure` calls read it, so the fallback belongs here rather
# than in any of them (requirement 34a).
impl_pr_url="$(jq -r '.pr_url // empty' <<<"$impl_status_json" 2>/dev/null || true)"
[[ -z "$impl_pr_url" ]] && impl_pr_url="$(extract_pr_url "$impl_out")"
[[ -z "$impl_pr_url" ]] && impl_pr_url="$(read_pr_url_breadcrumb "$clone_dir")"
[[ -z "$impl_pr_url" ]] && impl_pr_url="$(pr_url_for_branch "$selected_repo" "$selected_branch")"

impl_status="$(jq -r '.status // empty' <<<"$impl_status_json" 2>/dev/null || true)"

# A reported `void` is the Implementer saying the work order describes no work —
# the item is already done on default_branch, or its premise is otherwise false.
# It is terminal (requirement 34c): no agent may clear it, because the only
# evidence that would ever arrive ("it's already done") is the reason it is void
# in the first place. Recording this as `blocked` instead is what let an
# already-done recommendation be unblocked by the next Co-Ordinator and
# re-selected indefinitely.
if (( impl_rc == 0 )) && [[ "$impl_status" == "void" ]]; then
  # Requirement 34d, extended by issue #243 from the Co-Ordinator alone to
  # every stage: the Implementer reads the tree itself (requirement 27b), but
  # that does not stop a model citing the wrong artefact from it — see
  # lib/void-guard.sh's own note on issue #243. `repos` is passed as `[]`: the
  # Implementer gathers no per-cycle candidate list, so `void_guard_reason`'s
  # PR-diff check (Co-Ordinator only) simply has nothing to test against; the
  # citation check needs nothing from it.
  impl_void_entry="$(jq -nc --arg r "$selected_repo" --arg i "$selected_item" \
    --arg reason "$(jq -r '.reason // "no reason given"' <<<"$impl_status_json")" \
    --argjson x "$impl_status_json" '{repo: $r, item: $i, reason: $reason, evidence: ($x.evidence // "")}')"
  if impl_void_refusal="$(void_guard_reason "$impl_void_entry" '[]' "$(void_obsolete_ctx_json "$selected_repo")")"; then
    log_item_void "implementer" \
      "$(jq -r '.reason // "no reason given"' <<<"$impl_status_json")" \
      "$(jq -c '{evidence: (.evidence // "")}' <<<"$impl_status_json")"
  else
    log_event "warning" "$(jq -nc \
      --arg d "implementer void refused for ${selected_repo:-<no repo>} $selected_item — $impl_void_refusal; recorded blocked instead" \
      '{detail: $d}')"
    log_attempt_failed "implementer" \
      "void refused ($impl_void_refusal). The Implementer's stated reason was: $(jq -r '.reason // "no reason given"' <<<"$impl_status_json")" \
      "$(jq -nc --arg c "Establish from the repository itself whether this item describes any remaining work." \
        '{unblock_condition: $c}')"
  fi
  # A void item has no work, so its claim must not outlive the verdict — the
  # branch (if untouched) and the registry entry both go. A refused void is
  # recorded blocked instead, but the claim releases the same way either way:
  # the Implementer found no PR to raise for this item.
  release_claim no-pr
  exit 0
fi

# The escape hatch (requirement 9f): the Implementer started this item and
# found the specification it was handed insufficient — not "something in the
# world is wrong" (that is `blocked`), but "the brief itself does not say
# enough to build against". Recorded through the same
# `record_needs_refinement_block` a Co-Ordinator's own `needs_refinement`
# report uses, attributed to `stage: "implementer"` — which also clears any
# `refined` mark the item was carrying, since a refinement that led to this is
# exactly the one requirement 39d says must not stand unexamined.
if (( impl_rc == 0 )) && [[ "$impl_status" == "needs-refinement" ]]; then
  impl_nr_entry="$(jq -nc --arg r "$selected_repo" --arg i "$selected_item" --arg s "$selected_source" \
    --arg reason "$(jq -r '.reason // "no reason given"' <<<"$impl_status_json")" \
    --arg missing "$(jq -r '.missing // ""' <<<"$impl_status_json")" \
    --arg evidence "$(jq -r '.evidence // ""' <<<"$impl_status_json")" \
    '{repo: $r, item: $i, source: $s, reason: $reason, missing: $missing, evidence: $evidence}')"
  record_needs_refinement_block "$impl_nr_entry" "implementer" || true
  # No PR exists yet on this path — the Implementer stops before step 2's
  # claim, exactly like `blocked` without one — so the branch releases with it.
  if [[ -n "$impl_pr_url" ]]; then
    gh pr comment "$impl_pr_url" --body "$(pipeline_comment_header script "$node_name")

The Implementer found this item's specification insufficient: $(jq -r '.reason // "no reason given"' <<<"$impl_status_json") Recorded as needing refinement; the pipeline's Refiner will look at it again.

$(pipeline_comment_marker "$cycle_id" script)" >/dev/null 2>&1 || true
    release_claim have-pr
  else
    release_claim no-pr
  fi
  exit 0
fi

# A reported `blocked` is a verdict, not a stage failure: the Implementer ran to
# completion and found real work it cannot proceed with yet. Record it against
# the item, carrying the model's own reason and unblock_condition so a later
# Co-Ordinator can judge whether the impediment has since gone (requirement 34),
# rather than re-selecting the item and paying for the same discovery every
# cycle.
if (( impl_rc == 0 )) && [[ "$impl_status" == "blocked" ]]; then
  log_attempt_failed "implementer" \
    "$(jq -r '.reason // "no reason given"' <<<"$impl_status_json")" \
    "$(jq -c --arg u "$impl_pr_url" \
       '{unblock_condition: (.unblock_condition // "")}
        + (if $u == "" then {} else {pr_url: $u} end)' <<<"$impl_status_json")"
  if [[ -n "$impl_pr_url" ]]; then
    gh pr comment "$impl_pr_url" --body "$(pipeline_comment_header script "$node_name")

The Implementer stopped on this PR: $(jq -r '.reason // "no reason given"' <<<"$impl_status_json") Recorded blocked; the pipeline's Enabler will re-examine it, and will raise an issue if a human is needed.

$(pipeline_comment_marker "$cycle_id" script)" >/dev/null 2>&1 || true
    release_claim have-pr
  else
    release_claim no-pr
  fi
  exit 0
fi

if (( impl_rc != 0 )) || [[ -z "$impl_status_json" ]] || [[ "$impl_status" != "complete" ]]; then
  handle_stage_failure "implementer" "$impl_rc" "$impl_out" "$impl_pr_url"
  exit 0
fi

# Requirement 25a's and requirement 25c's findings from the Implementer-side
# gates below, empty when they found nothing — handed to the Reviewer as
# `## Script findings` entries rather than acted on here. Declared before the
# gates can set them, since the prompt that reads them is built
# unconditionally under `set -u`.
closing_keyword_finding=""
changelog_section_finding=""

if [[ -n "$impl_pr_url" ]]; then
  log_event "pr-raised" "$(jq -nc --arg u "$impl_pr_url" --arg r "$repo_slug" --arg i "$selected_item" \
    '{pr_url: $u, repo: $r} + (if $i == "" then {} else {item: $i} end)')"
  # The open PR is now the visible claim for the item-keyed entry; back-pressure
  # counts the PR from here on, not that entry (lib/claim.sh count excludes the
  # PR-keyed entry below from its own count for the same reason). The PR-keyed
  # exclusion claim (issue #238) is deliberately *not* dropped here — the
  # Reviewer stage below still has to write to this PR, and a peer must stay
  # excluded from it until this cycle actually ends (issue #360).
  release_claim have-pr-pending

  # Requirement 25a: `.github/workflows/closing-keyword.yml` guards this
  # repository alone — a workflow file protects the repository that ships
  # it, and only agent-ops does. Run the same deterministic check here,
  # against the PR the Script already has the URL for, so an issue-sourced
  # pull request in poetic or poetic-fiddle — which carry no such workflow —
  # cannot slip through on prompt instruction alone either
  # (TD-PPagop-26080803, the same silent-skip shape issue #240 was filed
  # over).
  #
  # A dirty verdict here is review feedback, not a refusal. What it finds is
  # a pull-request *body* edit — the exact class of defect the Reviewer's own
  # step 4 fixes and pushes within the same cycle, and nothing about the diff
  # it is about to read. Refusing the handoff would turn a self-healing case
  # into an item recorded `attempt-failed` and blocked pending an Enabler
  # engagement, and buy no safety: the same gate is asked again at the
  # Reviewer's `ready` handoff, which is the only way a pull request reaches
  # a human or a merge. What this call buys is that the Reviewer *knows* —
  # it cannot see the later gate's verdict from inside its own session
  # (prompts/reviewer.md step 7 says so), so unwarned it would hand off and
  # be handed back, spending the review either way and losing the item too.
  ck_result="$(closing_keyword_gate "$impl_pr_url")" || true
  ck_word=""; ck_reason=""
  IFS=$'\t' read -r ck_word ck_reason <<<"$ck_result" || true
  case "$ck_word" in
    dirty)
      closing_keyword_finding="$ck_reason"
      log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$ck_reason" \
        '{detail: ($u + " fails the closing-keyword check as raised: " + $d + " — handed to the Reviewer to fix"), pr_url: $u}')"
      ;;
    unknown)
      log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$ck_reason" \
        '{detail: ("could not check whether " + $u + " carries its closing keyword: " + $d), pr_url: $u}')"
      ;;
  esac

  # Requirement 25c, agent-ops#1808: the same script-side extension applied to
  # `.github/workflows/changelog-section.yml`, on the closing-keyword gate's
  # own pattern just above — a workflow file guards agent-ops alone, so
  # poetic and poetic-fiddle need the same deterministic check run here
  # instead. A dirty verdict is feedback, not a refusal, for the identical
  # reason: what it finds is a pull-request body edit the Reviewer's own step
  # 4 already fixes, and the enforcing call is the one at the Reviewer's
  # `ready` handoff (lib/handoff.sh's `handoff_complete_review`), not this one.
  cs_result="$(changelog_section_gate "$impl_pr_url")" || true
  cs_word=""; cs_reason=""
  IFS=$'\t' read -r cs_word cs_reason <<<"$cs_result" || true
  case "$cs_word" in
    dirty)
      changelog_section_finding="$cs_reason"
      log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$cs_reason" \
        '{detail: ($u + " fails the changelog-section check as raised: " + $d + " — handed to the Reviewer to fix"), pr_url: $u}')"
      ;;
    unknown)
      log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$cs_reason" \
        '{detail: ("could not check whether " + $u + " carries its owed changelog section: " + $d), pr_url: $u}')"
      ;;
  esac

  # Requirement 56 (issue #1543): a pull request that deletes, or edits away,
  # the workflow job producing a required status check on this repository's
  # default branch can never report that context again — GitHub evaluates a
  # `pull_request` workflow from its head commit — and only an owner can drop
  # the context from the ruleset. Name that prerequisite now, at pull-request
  # time, rather than waiting for a downstream item to happen to block on
  # this one the way #1540 did, 6+ hours after PR #1503 deleted
  # .github/workflows/tech-debt-register.yml. `lib/review-gate.sh`'s own
  # backstop (requirement 55) catches the same fact again at the Reviewer's
  # `ready` handoff, as a safety net for a finding missed here.
  # `|| true` for the same reason `closing_keyword_gate`'s own call above
  # carries one: this block is advisory, and nothing it can fail at is worth
  # ending a cycle whose pull request is already raised. The function itself
  # promises exit 0 (see its header), so this guards the call site against a
  # future edit to it, not against today's behaviour.
  rcp_findings="$(required_check_preflight_findings "$repo_slug" "$selected_default_branch" "${impl_pr_url##*/}")" || true
  if [[ -n "$rcp_findings" ]]; then
    rcp_created="$(required_check_preflight_escalate "$repo_slug" "$selected_item" "$impl_pr_url" \
      "$selected_default_branch" "$rcp_findings")" || true
    if [[ -n "$rcp_created" ]]; then
      rcp_issue_url="${rcp_created#*$'\t'}"
      log_event "required-check-preflight-escalated" "$(jq -nc --arg u "$impl_pr_url" \
        --arg n "${rcp_created%%$'\t'*}" --arg iu "$rcp_issue_url" --arg f "$rcp_findings" \
        '{pr_url: $u, issue_number: ($n | tonumber), issue_url: $iu, findings: $f}')"
      gh pr comment "$impl_pr_url" --body "$(pipeline_comment_header script "$node_name")

This pull request deletes, or edits away, the workflow job producing a required status check — a ruleset amendment is an owner-only prerequisite before it can merge. Filed as $rcp_issue_url (issue #1543).

$(pipeline_comment_marker "$cycle_id" script)" >/dev/null 2>&1 || true
    else
      log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg f "$rcp_findings" \
        --arg d "$impl_pr_url deletes or edits away the workflow job producing a required status check, and the owner-act escalation could not be filed — will retry next cycle" \
        '{detail: $d, pr_url: $u, findings: $f}')"
    fi
  fi

  # Requirement 26b/6c (issue #714): the Implementer may *name* labels for its
  # own pull request in its summary's optional `labels` field — the Script
  # remains the only writer, exactly as it already is for `complexity:*` and
  # every projected label. `length` guards against paying for a mint call (and
  # an empty `labels-minted` event) on the overwhelmingly common summary that
  # names none.
  impl_labels_json="$(jq -c '.labels // []' <<<"$impl_status_json" 2>/dev/null || echo '[]')"
  if [[ "$(jq 'length' <<<"$impl_labels_json" 2>/dev/null || echo 0)" -gt 0 ]]; then
    impl_mint_report="$(labels_mint "$repo_slug" pr "${impl_pr_url##*/}" "$impl_labels_json" \
      < <(labels_reserved_names "$CONFIG_FILE" "$SCHEMA_FILE"))"
    log_event "labels-minted" "$(jq -nc --arg r "$repo_slug" --arg i "$selected_item" \
      --arg by "implementer" --argjson x "$impl_mint_report" \
      '{repo: $r, item: $i, actor: $by} + $x')"
  fi
fi

# --- 8. Reviewer stage ---
# Requirement (agent-ops#916, escalation #922, decision 3): a cheap, advisory
# read ahead of a whole Reviewer engagement — has $impl_pr_url already merged
# in the gap between the Implementer's own handoff and here? Merged is acted
# on immediately, the same completion the handoff-time read below reaches for
# a merge caught mid-Reviewer-pass, without spending the stage on a pull
# request no longer there to review. Unreadable just runs the stage as
# normal: nothing here is the last word, since the fail-closed read ahead of
# `confirm_pr_ready` still guards whatever this stage produces.
pre_reviewer_merge_state=""; pre_reviewer_merge_sha=""
if [[ -n "$impl_pr_url" ]]; then
  pre_reviewer_merge_result="$(pr_merge_state "$impl_pr_url")" || true
  IFS=$'\t' read -r pre_reviewer_merge_state pre_reviewer_merge_sha <<<"$pre_reviewer_merge_result"
fi
if [[ "$pre_reviewer_merge_state" == "merged" ]]; then
  reviewer_merge_observed "$impl_pr_url" "$pre_reviewer_merge_sha" '{}' "reviewer-stage-start"
  echo "$impl_pr_url"
  exit 0
fi

# Requirement 31e (agent-ops#1806): a merge-conflicts item's Implementer push
# resolves a conflict — a real commit, authored fresh, unlike a bare rebase —
# but frequently changes nothing about the pull request's own net content: a
# clean rebase, or a both-sides-kept resolution reproduced on the moved base.
# `premerge_old_head`/`premerge_old_base` were captured before the
# Implementer stage ran (step 6b); comparing the diff they name against the
# diff the pushed head now carries, by patch-id rather than by authored date
# (which a conflict-resolution commit moves just like any other), is what
# tells that apart from a rebase whose diff genuinely changed, which still
# takes the full Reviewer engagement below. Advisory exactly like the
# merge-state read above it: an unreadable comparison just runs the stage as
# normal, never guessed at as rebase-only.
#
# Both heads are read from `origin`, not from the clone's own working tree:
# the question this answers is "did the *push* change the diff", and
# `git -C "$clone_dir" rev-parse HEAD` would instead answer "did the
# Implementer's working tree change it" — true even of an Implementer that
# reported `complete` having pushed nothing at all. An unmoved head is
# caught explicitly for the same reason: no push happened, which is not the
# same thing as a push that changed no content, and must take the full path.
rebase_only_new_head=""; rebase_only_new_base=""
rebase_only_advisory_check() {
  [[ -n "$premerge_old_head" && -n "$premerge_old_base" && -n "$impl_pr_url" ]] || return 1
  rebase_only_new_head="$(git -C "$clone_dir" ls-remote origin "refs/heads/$selected_branch" 2>/dev/null | awk '{print $1; exit}')"
  rebase_only_new_base="$(git -C "$clone_dir" ls-remote origin "refs/heads/$premerge_base_name" 2>/dev/null | awk '{print $1; exit}')"
  [[ -n "$rebase_only_new_head" && -n "$rebase_only_new_base" ]] || return 1
  [[ "$rebase_only_new_head" != "$premerge_old_head" ]] || return 1
  git -C "$clone_dir" fetch --quiet origin "$premerge_old_head" "$premerge_old_base" \
    "$rebase_only_new_head" "$rebase_only_new_base" >/dev/null 2>&1 || true
  rebase_only_push "$clone_dir" "$premerge_old_base" "$premerge_old_head" \
    "$rebase_only_new_base" "$rebase_only_new_head"
}
rebase_only="false"
rebase_only_advisory_check && rebase_only="true"

# Requirement 8a: the reviewer tier follows the item's complexity — the
# highest of the Implementer's ex-post grade (its summary's `complexity`) and
# the PR's raise-never-lower `complexity:*` label, falling back to the
# Co-Ordinator's own classification when neither says anything: a
# trivial-tier work order needs no self-grade to be `low`. The label read is
# best-effort; an unreadable label contributes nothing and the choice
# degrades to the default tier.
impl_complexity="$(jq -r '.complexity // empty' <<<"$impl_status_json" 2>/dev/null || true)"
label_grades=()
if [[ -n "$impl_pr_url" ]]; then
  mapfile -t label_grades < <(gh pr view "$impl_pr_url" --json labels \
    --jq '.labels[].name | select(startswith("complexity:")) | sub("^complexity:"; "")' 2>/dev/null || true)
fi
impl_trivial=0
[[ "$impl_model" == "$implementer_model_trivial" ]] && impl_trivial=1
rev_complexity="$(reviewer_complexity "$impl_complexity" "$impl_trivial" ${label_grades[@]+"${label_grades[@]}"})"
rev_model="$reviewer_model_default"
[[ "$rev_complexity" == "high" ]] && rev_model="$reviewer_model_complex"

# The `## Script findings` section, present only when a script-side check has
# something the Reviewer needs to act on — carrying its own leading newline so
# an empty one leaves the surrounding sections spaced exactly as before. Each
# finding is its own bullet, so either, both, or neither of the two checks
# can contribute without the other's absence changing the section's shape.
script_findings_section=""
if [[ -n "$closing_keyword_finding" || -n "$changelog_section_finding" ]]; then
  script_findings_section="
## Script findings
"
  if [[ -n "$closing_keyword_finding" ]]; then
    script_findings_section="$script_findings_section
- **Closing keyword (requirement 25a):** $closing_keyword_finding"
  fi
  if [[ -n "$changelog_section_finding" ]]; then
    script_findings_section="$script_findings_section
- **Changelog section (requirement 25c):** $changelog_section_finding"
  fi
  script_findings_section="$script_findings_section
"
fi

# reviewer is requirement 4a's other per-repository stage — same resolution
# as the Implementer's above, against the same $repo_slug this cycle worked.
reviewer_prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" reviewer "$(prompt_overrides_json_for_repo "$DEFAULTED_CONFIG" "$repo_slug")")

## Work order

\`\`\`json
$(jq . <<<"$work_order_json")
\`\`\`

## Implementer summary

\`\`\`json
$(jq . <<<"$impl_status_json")
\`\`\`
$script_findings_section
## Cycle

$cycle_id

## Node

$node_name
"
rev_out="$cycle_dir/reviewer.out"

# Requirement 31e: the engagement itself is what a confirmed rebase-only push
# skips — never the handoff, the Approver round or the arming step below it,
# all of which this branch falls straight through to with a synthesised
# `ready`. The Reviewer's verdict is this pipeline's own state, so carrying it
# across a push that changed no content costs nothing; the Approver's verdict
# is a GitHub artefact, and every repository this pipeline may act on mandates
# `dismiss_stale_reviews_on_push: true` (D18 Stage 3,
# `docs/PULLWRIGHT-DAY-ONE-AUTONOMY.md` §1a), so that push dismissed the
# standing approval whatever its patch-id said. `run_approver_stage` below is
# the only thing that mints a replacement, and `_landing_retry_sweep_repo`'s
# own recovery cannot reach a pull request with no standing approval left to
# find — so ending the cycle here would strand it, not save it. Falling
# through also puts `handoff_complete_review`'s fresh required-checks read
# (`review_gate_verdict`) at the post-push head, which is #1806's own
# "provided the required checks pass on the new head" proviso: a diff that is
# patch-id-identical on a base that *moved* can still go red.
# `$reviewer_prompt` above is built either way — a local file read, not a
# model call — so that its embedded work-order text stays outside this
# branch's indentation.
if [[ "$rebase_only" == "true" ]]; then
  log_event "reviewer-carried-forward" "$(jq -nc --arg r "$selected_repo" --arg i "$selected_item" \
    --arg u "$impl_pr_url" --arg oh "$premerge_old_head" --arg nh "$rebase_only_new_head" \
    '{repo: $r, item: $i, pr_url: $u, old_head: $oh, new_head: $nh, rebase_only: true}')"
  rev_rc=0
  rev_status_json="$(jq -nc --arg u "$impl_pr_url" \
    '{status: "ready", pr_url: $u, fixes_applied: [], comments_left: 0,
      ci: "carried forward: the Implementer push changed no net content (requirement 31e)"}')"
else
  stage_budget_apply reviewer "$selected_repo" "$rev_model" \
    "$(jq -nc --arg c "$rev_complexity" '{complexity: $c}')" "$selected_item"
  if run_claude_stage reviewer "$(( stage_backstop_min * 60 ))" "$rev_model" "$reviewer_prompt" "$rev_out" "$clone_dir" "$(( stage_inactivity_min * 60 ))"; then
    rev_rc=0
  else
    rev_rc=$?
  fi
  log_event "stage-end" "$(jq -nc --argjson rc "$rev_rc" --arg kr "$stage_kill_reason" --argjson m "$(metering_fields "$rev_model" "$rev_out" "$stage_gaps_json")" \
    --arg r "$selected_repo" --arg i "$selected_item" \
    '{stage: "reviewer", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m
     + (if $r == "" then {} else {repo: $r} end) + (if $i == "" then {} else {item: $i} end)')"
  rework_stage_rerun_maybe "reviewer" "$stage_kill_reason" "$selected_repo" "$selected_item" "$impl_pr_url"
  log_node_state_transition overhead
  # `if`, not `&&`: an empty warning is the common case, and a trailing
  # `&&` whose test fails is a non-zero status at exactly the place
  # `set -e` acts on — the same trap that cost a --once cycle its
  # failure handling at dump_stage_output.
  watchdog_warning="$(stage_watchdog_warning reviewer || true)"
  if [[ -n "$watchdog_warning" ]]; then
    log_event "warning" "$watchdog_warning"
  fi
  (( ONCE )) && dump_stage_output "$rev_out"

  rev_result="$(jq -r '.result // empty' "$rev_out" 2>/dev/null || true)"
  rev_status_json="$(extract_json_result "$rev_result" 2>/dev/null || true)"
  if (( rev_rc == 0 )) && [[ -z "$rev_status_json" ]]; then
    rev_status_json="$(stage_salvage_result reviewer "$rev_out" "$rev_model" "$clone_dir" || true)"
  fi
fi

# Requirement 31d (agent-ops#916, escalation #922, decisions 2 and 3; moved
# ahead of the stage-failure exit below by agent-ops#1063): the handoff's own
# fail-closed read of whether $impl_pr_url has already merged — ahead of
# confirm_pr_ready's isDraft read inside handoff_complete_review below, and
# decisive over the Reviewer verdict's own word, which is why this runs before
# $rev_status is even branched on, and before the stage-failure early exit
# too. A confirmed merge is a completion whether the Reviewer never noticed
# ("ready"), noticed and said so ("blocked", naming the merge), or never
# produced a parseable verdict at all — a crash, a timeout, an unparseable
# final message — none of those reach pr-ready, an Approver engagement or a
# landing attempt. A Reviewer claiming a merge GitHub denies is a model error
# and falls through to the ordinary attempt-failed handling below unchanged,
# since merge_state is "open" (or "failed") in that case, not "merged".
merge_state=""; merge_sha=""
if [[ -n "$impl_pr_url" ]]; then
  merge_result="$(pr_merge_state "$impl_pr_url")" || true
  IFS=$'\t' read -r merge_state merge_sha <<<"$merge_result"
fi

if [[ "$merge_state" == "merged" ]]; then
  # A merged subject retires the *item*; it says nothing about the *node*. So
  # where the stage produced no parseable verdict — the one shape that would
  # otherwise have gone through the stage-failure exit just below, which this
  # read now precedes — take the usage-limit read that exit would have taken
  # (`handle_stage_failure`'s own `detect_and_log_limit_hit`) before
  # completing: a Reviewer stopped the moment the account refused is what
  # requirement 35's Enabler guard and the fleet's own stand-down both key on
  # (`limit_hit_this_cycle`, the `limit-hit` event), and engaging the fleet's
  # most expensive model moments after a limit simply re-hits it. Guarded to
  # the no-verdict shape, never taken on a verdict that parsed, so this reads
  # exactly what the failure exit would have read and nothing more.
  if (( rev_rc != 0 )) || [[ -z "$rev_status_json" ]]; then
    detect_and_log_limit_hit "$rev_out" || true
  fi
  reviewer_merge_observed "$impl_pr_url" "$merge_sha" "$rev_status_json" "reviewer"
  echo "$impl_pr_url"
  exit 0
fi

if (( rev_rc != 0 )) || [[ -z "$rev_status_json" ]]; then
  handle_stage_failure "reviewer" "$rev_rc" "$rev_out" "$impl_pr_url"
  exit 0
fi

rev_status="$(jq -r '.status // empty' <<<"$rev_status_json")"

if [[ "$rev_status" == "ready" && "$merge_state" == "failed" ]]; then
  # Fail-closed exactly as `confirm_pr_ready` already is (see
  # `pr_merge_state`'s own header): "could not tell whether this merged"
  # must never read as "safe to hand off" — this is the last check before an
  # irreversible act (the draft flip, the Approver, landing), and nothing
  # downstream re-asks it.
  log_reviewer_handback \
    "the Reviewer reported ready, but whether $impl_pr_url has already merged could not be confirmed" \
    "$impl_pr_url" "Retry once a node can read GitHub's pull-request state for this pull request."
  exit 0
fi

if [[ "$rev_status" == "ready" ]]; then
  # Requirement 31c (agent-ops#249) and 32b (agent-ops#440): a Reviewer's
  # "ready" is a model reading a check list, exactly the judgement that
  # missed poetic-fiddle #216's CodeQL alert hidden inside an otherwise-green
  # list. Before any handoff mechanism runs, ask GitHub directly, the same
  # "confirm, don't trust" shape requirement 31a already applies to the draft
  # flag itself — `handoff_complete_review` (lib/handoff.sh) is the one
  # gate-and-flip implementation this call site shares with the Enabler's
  # `complete_handoff` recovery path below, so neither can hand a pull
  # request to a human without running the same checks the other does.
  gate_default_branch="$(jq -r '.default_branch // "main"' <<<"$work_order_json")"
  review_json="$(handoff_complete_review "$impl_pr_url" "$gate_default_branch" "$enabler_assignee" "$cycle_started_at")"
  gate_word="$(jq -r '.gate.word // ""' <<<"$review_json")"
  gate_reason="$(jq -r '.gate.reason // ""' <<<"$review_json")"
  gate_checks_unreadable="$(jq -r '.gate.checks_unreadable // false' <<<"$review_json")"
  # The item-lifecycle record's "checks green" instant (requirement 49, issue
  # #595) — the one genuine gap `review-gate-checks-read` never closed, since
  # its own `ok` names whether the *read* succeeded, not what it found:
  # `gate_word` is "clean" only once the required-checks read succeeded *and*
  # reported nothing outstanding (`review_gate_verdict`, lib/review-gate.sh),
  # so this is the first point in the whole pipeline that fact is knowable.
  [[ "$gate_word" != "clean" ]] || log_event "checks-green" "$(jq -nc --arg u "$impl_pr_url" \
    --arg r "$selected_repo" --arg i "$selected_item" \
    '{pr_url: $u} + (if $r == "" then {} else {repo: $r} end) + (if $i == "" then {} else {item: $i} end)')"
  ck_word="$(jq -r '.closing_keyword.word // ""' <<<"$review_json")"
  ck_reason="$(jq -r '.closing_keyword.reason // ""' <<<"$review_json")"
  cs_word="$(jq -r '.changelog_section.word // ""' <<<"$review_json")"
  cs_reason="$(jq -r '.changelog_section.reason // ""' <<<"$review_json")"
  rc_word="$(jq -r '.reconciliation.word // ""' <<<"$review_json")"
  rc_reason="$(jq -r '.reconciliation.reason // ""' <<<"$review_json")"
  rc_revert="$(jq -r '.revert // ""' <<<"$review_json")"
  review_safe="$(jq -r '.safe // false' <<<"$review_json")"

  # TD-PPagop-26081404: bookkeeping for `review_gate_unknown_streak_verdict`,
  # logged unconditionally — regardless of which branch below is taken, or
  # none of them — so a run of consecutive failures can be told apart from
  # ordinary noise. `gate.checks_unreadable`, not the word alone: a genuinely
  # dirty alert outranks an unreadable check list for the word and the
  # handback below (see `handoff_complete_review`'s own header), so the word
  # alone would record `{ok: true}` for an evaluation whose required-checks
  # read failed outright — falsely resetting the very streak this event
  # exists to count.
  gate_checks_ok=true
  [[ "$gate_checks_unreadable" == "true" ]] && gate_checks_ok=false
  log_event "review-gate-checks-read" "$(jq -nc --argjson ok "$gate_checks_ok" \
    --arg r "$selected_repo" --arg i "$selected_item" \
    '{ok: $ok} + (if $r == "" then {} else {repo: $r} end) + (if $i == "" then {} else {item: $i} end)')"
  # check-failure (docs/FLOW-SCHEMA.md, D23, issue #596's own detector
  # naming): `ok: false` here is this per-attempt read failing — the same
  # node/API fact `review_gate_unknown_streak_verdict` counts a run of
  # (`gate_checks_unreadable`, `handoff_complete_review`'s exit 2). The
  # *escalation* of a run of these, `review-gate-checks-degraded`, is
  # deliberately never counted here too: it is a summary of repetitions
  # already recorded at their own per-attempt site, not a fresh one.
  rework_check_failure_json="$(rework_check_failure_fields "$gate_checks_ok" "$gate_reason" \
    "agent-cycle.sh:review-gate-checks-read" "$selected_repo" "$selected_item" "$impl_pr_url")"
  [[ -n "$rework_check_failure_json" ]] && log_event "rework" "$rework_check_failure_json"

  if [[ "$review_safe" != "true" ]]; then
    if [[ "$gate_word" == "dirty" ]]; then
      log_reviewer_handback \
        "the Reviewer reported ready, but $impl_pr_url is not safe to hand off: $gate_reason" \
        "$impl_pr_url" "Get every required check green and clear the named security-severity code-scanning alert, then let the Reviewer re-examine it."
      exit 0
    fi
    if [[ "$gate_checks_unreadable" == "true" ]]; then
      # A node fact, not a pull-request fact — logged as its own warning so a
      # `gh` degraded on this node is visible as a pattern across items rather
      # than only as N pull-request-shaped handbacks naming nothing to fix. The
      # handback itself still runs: an unread required-check list is refused
      # exactly like a genuinely failing one, and its unblock_condition names
      # the node-level cause rather than telling the Enabler to inspect a pull
      # request that may already be fine.
      #
      # TD-PPagop-26081404: `gh` degraded enough to fail this read is rarely
      # wrong once — a node past a rate limit, or fighting a transient auth
      # problem, is typically wrong for several consecutive items, and each one
      # earning its own warning buries the pattern a human would actually act
      # on. Once this node's own log shows `review_gate_unknown_streak_after`
      # of these in a row, one louder escalation event replaces the per-item
      # warning instead of piling another one on top of it — once per streak,
      # not once per item past the threshold: `review_gate_degraded_since`,
      # inside `review_gate_escalate_unreadable_streak` (TD-PPagop-26081603),
      # is the same already-escalated dedup `crash_loop_escalated_since` gives
      # requirement 2.7's crash loop, keyed on the run's own `first_ts`, so an
      # already-escalated run logs nothing further here (the bookkeeping event
      # above still records the failure, and the handback below still refuses
      # the handoff) until a successful read starts a new streak.
      streak_json="$(review_gate_escalate_unreadable_streak)"
      if [[ -z "$streak_json" ]]; then
        log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$gate_reason" \
          '{detail: ("this node could not read " + $u + "'\''s required checks, so the handoff was refused rather than trusted on an unread check list: " + $d), pr_url: $u}')"
      fi
      log_reviewer_handback \
        "the Reviewer reported ready, but $impl_pr_url's required checks could not be confirmed: $gate_reason" \
        "$impl_pr_url" "Retry once a node can read GitHub's required-checks API for this pull request — nothing found here implicates the pull request itself."
      exit 0
    fi
    if [[ "$ck_word" == "dirty" ]]; then
      log_reviewer_handback \
        "the Reviewer reported ready, but $impl_pr_url is not safe to hand off: $ck_reason" \
        "$impl_pr_url" "Add the missing closing keyword (Closes/Fixes/Resolves #N) for the issue this PR claims to close, then let the Reviewer re-examine it."
      exit 0
    fi
    if [[ "$cs_word" == "dirty" ]]; then
      log_reviewer_handback \
        "the Reviewer reported ready, but $impl_pr_url is not safe to hand off: $cs_reason" \
        "$impl_pr_url" "Add or fix the pull request description's ## Changelog section (requirement 25c) with a gh pr edit --body-file, then let the Reviewer re-examine it."
      exit 0
    fi
    if [[ "$rc_word" == "dirty" ]]; then
      # Requirement 31c's reconciliation gate (agent-ops#533): a human posted
      # a general PR comment since this pull request last left draft, and no
      # pipeline comment since cites a `<!-- agent-ops:reconciles
      # comment=<id> -->` line naming it — a requested change silently
      # dropped rather than implemented or contested (PR #512).
      #
      # human-change-request (docs/FLOW-SCHEMA.md, D23, issue #596): this is
      # the class #533 used to leave undetected entirely (a plain PR comment
      # is invisible to the review gate) — now caught here, at this same
      # refusal, and given its own machine-legible class rather than living
      # only in the `attempt-failed` `detail` string `log_reviewer_handback`
      # writes below. Attributed to the Reviewer: this refusal fires at its
      # own handoff, the one place this class is detected today.
      log_event "rework" "$(rework_human_change_request_fields "$rc_reason" \
        "$selected_repo" "$selected_item" "$impl_pr_url")"
      #
      # agent-ops#539: `handoff_complete_review` does not merely refuse this
      # handoff any more — it also reverts the pull request to draft
      # (`confirm_pr_draft`), because leaving it exactly as the Reviewer's
      # own step-7 `gh pr ready` had just left it is what let that same flip
      # survive to become the next round's reconciliation anchor and disarm
      # this gate one round later (see `_reconciliation_gate_anchor`'s
      # header). `revert` carries what that call found; `failed` is worth its
      # own warning, since a human could otherwise merge a
      # `CHANGES_REQUESTED` pull request that GitHub still shows as ready.
      if [[ "$rc_revert" == "failed" ]]; then
        log_event "warning" "$(jq -nc --arg u "$impl_pr_url" \
          --arg d "$impl_pr_url carries an unreconciled human comment and could not be converted back to draft — it remains ready, and a human could merge it with the comment still unanswered" \
          '{detail: $d, pr_url: $u}')"
      fi
      log_reviewer_handback \
        "the Reviewer reported ready, but $impl_pr_url is not safe to hand off: $rc_reason" \
        "$impl_pr_url" "Answer every unreconciled human comment on the pull request — implement it or explicitly contest it in the completion comment — citing each with its own <!-- agent-ops:reconciles comment=<id> --> line, then let the Reviewer re-examine it."
      exit 0
    fi
    # The gates were clean and the flip itself did not take.
    log_reviewer_handback \
      "the Reviewer reported ready, but $impl_pr_url is still a draft and the handoff could not be completed" \
      "$impl_pr_url" "Confirm the pull request is out of draft with CI green."
    exit 0
  fi

  # `unknown` is "the question could not be put" — a degraded `gh` on this
  # node, not a fault in this pull request — so it warns rather than blocks,
  # the same way an unreadable alert list does just below. A node degraded
  # enough for this to matter does not get past `handoff_complete_review`
  # above in any case: it already refused the handoff, with its own warning,
  # the moment its required-check list came back unreadable rather than
  # merely unable to confirm an alert or a keyword.
  if [[ "$ck_word" == "unknown" ]]; then
    log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$ck_reason" \
      '{detail: ("could not confirm " + $u + " carries its closing keyword: " + $d), pr_url: $u}')"
  fi

  if [[ "$cs_word" == "unknown" ]]; then
    log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$cs_reason" \
      '{detail: ("could not confirm " + $u + " carries its owed changelog section: " + $d), pr_url: $u}')"
  fi

  if [[ "$rc_word" == "unknown" ]]; then
    log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$rc_reason" \
      '{detail: ("could not confirm every human comment on " + $u + " since it last left draft is reconciled: " + $d), pr_url: $u}')"
  fi

  if [[ "$gate_word" == "unknown" ]]; then
    log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$gate_reason" \
      '{detail: ("could not confirm " + $u + " carries no new security-severity code-scanning alert: " + $d), pr_url: $u}')"
  fi

  # Requirement 31a: the verdict is the Reviewer's — it is the only actor that
  # read the diff — but the handoff is a fact about the PR, and asking GitHub
  # costs one field. `pr-ready` now means the PR is not a draft, not that
  # somebody said so; `handoff` records which of them made it true.
  handoff_result="$(jq -r '.handoff // ""' <<<"$review_json")"
  # `safe: true` already guarantees one of the two arms below — the flip word
  # is the last thing `handoff_complete_review` checks before it says so — so
  # the case needs no `*)` arm refusing the handoff; the refusal for a flip
  # that did not take is the `review_safe != "true"` block above. The default
  # is still set, because the one place an unmatched word could surface is
  # `pr-ready` below, and an unset variable under `errexit`/`nounset` would
  # abort the cycle at exactly the point it records what it did.
  handoff_by="script"
  case "$handoff_result" in
    already)
      handoff_by="reviewer"
      ;;
    flipped)
      handoff_by="script"
      log_event "warning" "$(jq -nc --arg u "$impl_pr_url" \
        --arg d "reviewer reported ready but left $impl_pr_url a draft; the Script completed the handoff" \
        '{detail: $d, pr_url: $u}')"
      ;;
  esac

  # Requirement 31b: the draft flip above is the whole handoff exactly once per
  # pull request. On every later round — a review the Implementer has just
  # answered, most of all — the PR never left ready, `confirm_pr_ready`
  # truthfully answers `already`, and nothing has put the PR back in front of
  # the human: their review request was consumed when they submitted the review,
  # and the author cannot clear `CHANGES_REQUESTED`. So the second half of the
  # handoff is asked of GitHub too, on the same terms and for the same reason
  # requirement 31a asks about the draft flag — inside `handoff_complete_review`
  # itself now, unconditionally, not gated on `source == "review-feedback"`: the
  # question ("does a human's review block this PR, and have they been asked to
  # look again?") is answerable from the PR itself, costs one API call to
  # answer `no` on a first-round PR, and gating it on the Co-Ordinator's
  # classification would make a mislabelled source a silently unnotified human.
  rereview_state="$(jq -r '.rereview.state // ""' <<<"$review_json")"
  rereview_who="$(jq -r '.rereview.who // ""' <<<"$review_json")"
  if [[ "$rereview_state" == "failed" ]]; then
    # A warning, never a handback: the pull request is finished, green and
    # visible, and only the notification is missing (see lib/handoff.sh).
    log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg w "$rereview_who" \
      --arg d "changes requested on $impl_pr_url are answered, but review could not be re-requested from ${rereview_who:-the reviewer} — they will not see it in their review queue" \
      '{detail: $d, pr_url: $u} + (if $w == "" then {} else {reviewers: ($w | split(","))} end)')"
  fi

  # Requirement 38: nothing's `CHANGES_REQUESTED` above means there is no
  # blocking reviewer to re-request from — but the pull request may still be
  # exactly where a human needs to look (a first review, or an approval
  # nobody has acted on). `handoff_complete_review` asks GitHub the same way,
  # targeted at `enabler_assignee` instead of a blocking reviewer set.
  human_reviewer_state="$(jq -r '.human_reviewer.state // ""' <<<"$review_json")"
  human_reviewer_who="$(jq -r '.human_reviewer.who // ""' <<<"$review_json")"
  if [[ "$human_reviewer_state" == "failed" || "$human_reviewer_state" == "failed-rate-limited" ]]; then
    # agent-ops#1082: `ensure_human_reviewer` (lib/handoff.sh) tells a rate-limit
    # refusal apart from any other read failure at this call site — an operator
    # reading this warning needs to know whether nobody was notified because the
    # shared REST budget was gone, or because something else genuinely failed.
    rate_note=""
    [[ "$human_reviewer_state" == "failed-rate-limited" ]] \
      && rate_note=" — GitHub's REST rate limit refused the read"
    log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg a "$enabler_assignee" --arg w "$human_reviewer_who" \
      --arg d "$impl_pr_url is ready with nothing blocking it, but review could not be requested from ${human_reviewer_who:-$enabler_assignee} — it will not appear in their review queue$rate_note" \
      '{detail: $d, pr_url: $u} + (if $w == "" then {reviewers: [$a]} else {reviewers: ($w | split(","))} end)')"
  fi

  log_event "pr-ready" "$(jq -nc --arg u "$impl_pr_url" --arg h "$handoff_by" \
    --arg rr "$rereview_state" --arg w "$rereview_who" \
    --arg hr "$human_reviewer_state" --arg ha "$enabler_assignee" \
    --arg r "$selected_repo" --arg i "$selected_item" \
    '{pr_url: $u, handoff: $h}
     + (if $r == "" then {} else {repo: $r} end)
     + (if $i == "" then {} else {item: $i} end)
     + (if $rr == "" or $rr == "none" then {} else {review_requested: $rr} end)
     + (if $w == "" then {} else {reviewers: ($w | split(","))} end)
     + (if $hr == "" or $hr == "skip" then {}
        else {human_review_requested: $hr, human_reviewer: $ha} end)')"
  # The cycle's last write to this PR (issue #360) — the PR-keyed exclusion
  # claim pr-raised left standing above is released only now, at the actual
  # handoff, not back when the item-keyed claim was.
  release_pr_claim

  # --- 8f. Open-question signal (D18, agent-ops#668) ---
  # `open_questions` is additive to a `ready` verdict, never a substitute for
  # it — the handoff above has already happened regardless of what follows
  # here. Projected as a label (requirement 8f's own landing gate,
  # `_landing_stage_attempt`, and the 2.1e retry sweep both read it with no
  # log join) and logged as its own event so the escalation/adjudication
  # path that gate drives has the question's own words to work from, not
  # only the label's bare presence. A later Reviewer round raising a further
  # question while an earlier one still stands is additive too: the label
  # projects as `present` and the new question still gets its own event, but
  # the pull request was already held and stays held.
  oq_json="$(jq -c '[.open_questions[]? | select(type == "object")]' <<<"$rev_status_json" 2>/dev/null)"
  [[ -n "$oq_json" && "$oq_json" != "null" ]] || oq_json='[]'
  if [[ "$(jq 'length' <<<"$oq_json" 2>/dev/null || echo 0)" != "0" ]]; then
    if [[ "$impl_pr_url" =~ /pull/([0-9]+)$ ]]; then
      oq_number="${BASH_REMATCH[1]}"
      # `landing_open_question_label_project` documents exit 1 for its own
      # `unrecorded` and `failed` words (lib/landing.sh) as ordinary outcomes,
      # never a fault — under this script's `set -euo pipefail`, an unguarded
      # `var=$(cmd)` takes that exit status and would abort the cycle before
      # the Approver or landing stage ever ran (agent-ops#889). `|| true` on
      # both calls keeps the captured word regardless of which one printed.
      oq_proj="$(landing_open_question_label_project "$selected_repo" "$oq_number")" || true
      if [[ "$oq_proj" == "failed" ]]; then
        # Self-heal, once: the common cause is a repository this pipeline has
        # not created the label in yet, the same gap
        # `refinement_label_add`'s own retry (agent-ops#687) exists to close.
        refinement_label_ensure_one "$selected_repo" "$LANDING_OPEN_QUESTION_LABEL" >/dev/null 2>&1 || true
        oq_proj="$(landing_open_question_label_project "$selected_repo" "$oq_number")" || true
      fi
      log_event "open-question-raised" "$(jq -nc --arg u "$impl_pr_url" --arg r "$selected_repo" \
        --arg proj "$oq_proj" --argjson qs "$oq_json" \
        '{pr_url: $u, repo: $r, label_projection: $proj, questions: $qs}')"
      if [[ "$oq_proj" != "added" && "$oq_proj" != "present" ]]; then
        log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg l "$LANDING_OPEN_QUESTION_LABEL" \
          --arg d "$impl_pr_url carries an open question but the $LANDING_OPEN_QUESTION_LABEL label could not be confirmed on it (projection: $oq_proj) — the landing gate cannot hold it on this label alone until a later read succeeds" \
          '{detail: $d, pr_url: $u, label: $l}')"
      fi
    else
      log_event "warning" "$(jq -nc --arg u "$impl_pr_url" \
        --arg d "$impl_pr_url carries an open question but no pull request number could be parsed from its URL — the open-question label was not projected" \
        '{detail: $d, pr_url: $u}')"
    fi
  fi

  # --- 8b. Approver stage (D18 WI-5) ---
  # After every existing gate has passed and the handoff itself is complete —
  # review_gate_verdict, the closing-keyword gate, confirm_pr_ready,
  # confirm_review_requested, ensure_human_reviewer, the pr-ready log and the
  # claim release, all above — the tiered Approver gets one independent look,
  # for every repository whose merge_autonomy is above `human`. Placed last
  # and gating nothing above it: a refusal is a GitHub review sitting on an
  # already-ready pull request, not a reason to withhold the pr-ready log or
  # the claim release, exactly as a human's own CHANGES_REQUESTED never
  # withheld either of those — so this runs after both, never before.
  #
  # The tier is resolved now, not from `rev_complexity` as computed for the
  # Reviewer at requirement 8a: the Reviewer stage that just ran may have
  # corrected the PR's `complexity:*` label (prompts/reviewer.md step 4), and
  # that correction must reach this same round's Approver, not just the next
  # one (agent-ops#470).
  approver_complexity="$(approver_stage_complexity "$impl_pr_url" "$rev_complexity" "$impl_trivial")"
  run_approver_stage "$impl_pr_url" "$approver_complexity"

  # --- 8d. Landing arming step (D18 WI-7) ---
  # Immediately after the Approver, and gating nothing above it for the same
  # reason 8b gates nothing above it: an arm or a refusal is a fact about
  # this pull request's landing, never a reason to withhold the pr-ready log,
  # the claim release, or the Approver's own review. See run_landing_stage's
  # own header for the seven gates it re-reads fresh before arming anything.
  run_landing_stage "$impl_pr_url" "$approver_complexity"
else
  # Requirement 32a: a Reviewer that cannot hand off hands *back*, not out. The
  # verdict names a real impediment on a real PR, which is a blocked item —
  # the Enabler's input — and never, by itself, a summons to a human.
  log_reviewer_handback \
    "reviewer verdict '${rev_status:-unparseable}': $(jq -r '.reason // .ci // "no detail given"' <<<"$rev_status_json")" \
    "$impl_pr_url" "Resolve what the Reviewer left on the pull request, or escalate it."
fi

echo "$impl_pr_url"
}
