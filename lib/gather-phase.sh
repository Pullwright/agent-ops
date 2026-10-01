#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/gather-phase.sh — issue #1958's continuation of #771's split: the phase
# between the repo-ordering/candidate-gathering loop (`gather_ordered_repos`/
# `compute_skip_lists`, already lib/candidate-gather.sh as of #773) and the
# Co-Ordinator stage itself (lib/coordinator-phase.sh). One function,
# `run_gather_phase`, covering — in order — band eligibility and the
# Enabler/Refiner pre-fetches (lib/eligibility.sh), the decision-veto sweep
# and pending decision acts (lib/decision-veto.sh), back-pressure's
# finishing-sources narrowing (requirement 2.2a), the requirement-4i
# prompt-fit ladder (lib/coordinator-input.sh), and the no-op short-circuit
# (requirement 3b, lib/noop-skip.sh).
#
# A pure move out of agent-cycle.sh's own top-level script body — never into
# functions, so the body keeps its exact original indentation (including
# column-0 `if`/`while` blocks) rather than being reformatted as a function's
# own, the same as lib/candidate-gather.sh and lib/decision-veto.sh already
# do. Several test/*.test.sh files lift specific lines out of this file by
# literal pattern, the same way they did out of agent-cycle.sh before the
# move; only the file path changed for them.
#
# The requirement-4i prompt-fit machinery's *placement* in the phase sequence
# is deliberate (lib/coordinator-input.sh's own header explains why: the
# 2026-08-21 context-overflow outage) and is unchanged by this move — the
# whole of this phase, fit machinery included, still runs at exactly the same
# point between back-pressure and the Co-Ordinator stage as it always did;
# only the file it lives in changed, not its position relative to any other
# step.
#
# Sourced by agent-cycle.sh, after every lib/*.sh file this function's body
# calls into.

run_gather_phase() {
# --- 3. Repo ordering (most overdue first: staleness age weighted by each repo's nice — lib/repo-order.sh; identical to least-recent-first when no nice is set) ---
gather_ordered_repos
compute_skip_lists

# --- 3c/3u, 35a/35b, 3y, 39a. What this cycle is allowed to act on ---
# The band eligibility the blocked/void skip-lists decide, the Enabler's
# eligible set, the Refiner's own two pre-fetched sources and the Refiner's
# candidate set — one seam, `lib/eligibility.sh` (#771), because the four
# answer one question between them over the same inputs, and in an order that
# matters: both stage sets are computed from the extracts the band pass has
# just settled, so a Refiner and an Enabler engagement in the same cycle can
# never disagree about what is already spoken for. Each ends where it did
# inline, `enabler_allowed`/`refiner_allowed` included.
compute_band_eligibility
compute_enabler_eligible_set
prefetch_refiner_sources
compute_refiner_candidates

# --- Decision-veto sweep (agent-ops#937) ---
# Here, not inside run_standdown_checks above: `record_needs_refinement_block`
# needs `blocked_json`, which compute_skip_lists (called above, in step 3) has
# only just set — run_standdown_checks runs before that. See
# lib/decision-veto.sh's own header.
run_decision_veto_sweep

# --- Pending decision acts (requirement 36f) ---
# After the veto sweep, never before: a reopen this cycle has just discovered
# cancels a pending act, and doing the acts first would race it.
run_pending_decision_acts

# --- 2.2a Back-pressure, decided (requirement 2.2a) ---
# Deferred from step 2.2 until the sources were gathered. Back-pressure's stated
# purpose is to throttle new work and stop the landing gate silting up — and the
# four *finishing* sources do neither: `review-feedback` answers a review the
# human has already written, `merge-conflicts` rebases a ready PR that is
# waiting to land, `dequeued` fixes the merge-group checks failure that got a
# ready PR of ours removed from the merge queue, and `abandoned-drafts`
# carries a stalled draft this system started to completion. All are the
# activity that *un*-silts the gate — indeed an abandoned draft is itself
# occupying one of the very back-pressure slots the cap is counting, and a
# conflicted or dequeued PR is one nothing can land to free a slot until it
# is fixed. So when back-pressure trips we do not stand down if
# any has work waiting; we restrict every repo's source list to those four.
#
# No new prompt machinery is needed for that, and deliberately so: the
# Co-Ordinator is already told the runtime input's `sources` are authoritative
# over its own table (requirement 15). Narrowing the list is therefore an
# instruction it already knows how to obey, and the restriction cannot be
# reasoned around — a source it cannot see is a source it cannot select.
# The system still cannot open a new PR while the gate is full; it can only
# finish what is already in it.
#
# "a conflicted or dequeued PR is one nothing can land to free a slot until
# it is fixed" above claims those two already hold a slot requirement
# 2.2's own count counts — but that count was taken before this cycle's
# merge-conflict and dequeued candidates were gathered (they arrive only
# once ordered_repos_json's sources are populated, in step 3), and neither
# gatherer's candidate rule reads `reviewDecision` at all
# (scripts/gather-merge-conflicts.sh, scripts/gather-dequeued.sh) — so a
# conflicted or dequeued PR that is not *also* `CHANGES_REQUESTED` passed
# through 2.2's count exactly like an ordinary human-queue PR. For `dequeued`
# it is not even a coincidence: a PR only reaches the merge queue after
# approval, so its `reviewDecision` is `APPROVED` by construction. Fold in,
# here, whatever `counted_prs_json` — 2.2's own record of which PRs its count
# held — does not already hold, so the trip decision made at this site
# actually reflects every slot that source occupies, not just the ones that
# happened to also be `CHANGES_REQUESTED`. `ordered_repos_json` already
# carries this cycle's `merge_conflicts`/`dequeued` candidates (gathered
# above, in step 3) whether or not back-pressure ends up tripped, so this
# runs unconditionally rather than only inside the `if` below.
finishing_extra_prs_json="$(jq -c --argjson counted "$counted_prs_json" '
    [.[] | . as $repo | (($repo.merge_conflicts // [])[], ($repo.dequeued // [])[]) | {slug: $repo.slug, number}]
    | unique_by([.slug, .number])
    | map(select(.number as $n | ($counted[.slug] // []) | index($n) | not))
  ' <<<"$ordered_repos_json" 2>&1)" \
  || { guard_warn "backpressure:finishing_extra_prs" "$finishing_extra_prs_json"; finishing_extra_prs_json='[]'; }
finishing_extra_count="$(jq 'length' <<<"$finishing_extra_prs_json" 2>/dev/null)" || finishing_extra_count=0
[[ "$finishing_extra_count" =~ ^[0-9]+$ ]] || finishing_extra_count=0
if (( finishing_extra_count > 0 )); then
  adjusted_open_count=$(( adjusted_open_count + finishing_extra_count ))
  open_composition="$open_composition + $finishing_extra_count merge-conflict/dequeued PR(s) occupying a slot the pipeline-owed count above did not"
  if (( adjusted_open_count >= max_open_agent_prs )); then
    backpressure_tripped=1
  fi
fi

# A drain narrows unconditionally, not only when back-pressure trips
# (requirement 2.9): it must stop new intake regardless of how full the gate
# is, so it reaches this same restriction whether or not `backpressure_tripped`
# is itself set — the two conditions merely share the one narrowing mechanism
# 2.2a already provides.
if (( backpressure_tripped )) || (( DRAINING )); then
  finishing_waiting="$(jq '[.[].review_feedback[]?, .[].merge_conflicts[]?, .[].dequeued[]?, .[].abandoned_drafts[]?] | length' <<<"$ordered_repos_json")"
  if (( finishing_waiting == 0 )); then
    if (( DRAINING )); then
      # At-rest detection (requirement 2.9): this cycle's own gather already
      # found nothing in any of the four finishing bands, but a claim can be
      # taken moments before its PR exists, so drain_remaining_count also
      # checks the claim registry before calling it "at rest" — see
      # lib/drain.sh's header for why a band count alone is not enough.
      drain_remaining="$(drain_remaining_count "$ordered_repos_json")"
      drain_at_rest=0
      (( drain_remaining == 0 )) && drain_at_rest=1
      drain_write_state "$state_dir" "$DRAIN_DISABLED_AT" "$drain_remaining" "$drain_at_rest"
      if (( drain_at_rest )); then
        # One `drained` event per disabled_at, deduplicated across the union
        # log (requirement 2.9): a peer node can reach "at rest" first, and
        # this reads its event before deciding to log its own.
        drain_union_log="$(fleet_logs "$state_dir" "$(fleet_peers_dir "$workspace_root")" log.jsonl 2>/dev/null || true)"
        if [[ "$(drain_event_logged "$drain_union_log" "$DRAIN_DISABLED_AT")" != "1" ]]; then
          log_event "drained" "$(jq -nc --arg d "$DRAIN_DISABLED_AT" '{disabled_at: $d}')"
        fi
        log_event "stand-down" "$(jq -nc \
          --arg r "draining: at rest — no finishing-source pull request waiting and no live claim on one; waiting for --enable or the drain's own expiry" \
          '{reason: $r, cause: "no-demand"}')"
        set_node_state_terminal idle-without-demand no-demand
      else
        log_event "stand-down" "$(jq -nc \
          --arg r "draining: no finishing-source pull request waiting, but $drain_remaining live claim(s) on a finishing-source ref elsewhere have not yet resolved" \
          '{reason: $r, cause: "peer-claimed"}')"
        set_node_state_terminal idle-with-demand peer-claimed
      fi
      exit 0
    fi
    log_event "stand-down" "$(jq -nc \
      --arg r "back-pressure: $adjusted_open_count open agent PRs with a pipeline-side next action >= $max_open_agent_prs ($open_composition), and no review feedback, merge conflict, dequeued pull request, or abandoned draft is waiting to be finished" \
      '{reason: $r, cause: "back-pressure"}')"
    set_node_state_terminal idle-with-demand back-pressure
    exit 0
  fi
  # `issues` and `tech_debt` are emptied along with the narrowing, not merely
  # left unwalked: they are the two arrays that carry a whole document each —
  # an issue's entire thread, a tech-debt item's entire file (requirement 3t) —
  # and a restricted cycle paying the Co-Ordinator to read candidates it is
  # forbidden to pick is the exact spend back-pressure exists to stop. The
  # other non-finishing arrays are compact enough that stripping them buys
  # nothing.
  #
  # Emptying `tech_debt` is also what keeps requirements 3t/3x's corroboration
  # honest, which is why `eligible_items_json` is computed below this and
  # not back at "3c/3u. Pre-fetched-band eligibility": a back-pressured cycle
  # forbids the tech-debt and issues sources outright, so its `selected: false`
  # owes no account of either, and measuring eligibility before the narrowing
  # would report every eligible item as unaccounted — a false contradiction every
  # restricted cycle, and one that would strip the no-op fingerprint exactly
  # when the gate is fullest. The narrowing of `sources` just below does the
  # same job for the bands this block leaves populated (`findings`,
  # `human_visibility`): `coordinator_eligible_items` reads
  # the list, not the array. A drain narrows exactly the same way — refusing
  # new intake means every non-finishing source, not merely `issues`/
  # `tech_debt` — so the Refiner (which reads only those two, requirement 2.9)
  # goes idle by construction with no special-casing of its own.
  ordered_repos_json="$(handoff_narrow_repos_to_finishing_sources "$ordered_repos_json")"
  ordered_repos_json="$(jq -c '[.[] | .issues = [] | .tech_debt = []]' <<<"$ordered_repos_json")"
  if (( DRAINING )); then
    drain_write_state "$state_dir" "$DRAIN_DISABLED_AT" "$(drain_remaining_count "$ordered_repos_json")" 0
    log_event "warning" "$(jq -nc \
      --arg d "draining: restricted to finishing sources ($finishing_waiting PR(s) awaiting review-feedback, merge-conflict, dequeued, or abandoned-draft completion) — no new intake while draining" \
      '{detail: $d}')"
  fi
  if (( backpressure_tripped )); then
    log_event "warning" "$(jq -nc \
      --arg d "back-pressure: $adjusted_open_count open agent PRs with a pipeline-side next action >= $max_open_agent_prs ($open_composition) — restricted to finishing sources ($finishing_waiting PR(s) awaiting review-feedback, merge-conflict, dequeued, or abandoned-draft completion)" \
      '{detail: $d}')"
  fi
fi

# The repo/work-sources table prompts/coordinator.md used to hand-maintain is
# generated from config.json instead (requirement 4b), from the plain
# configured repo list (`all_repos_json`), never the cycle's back-pressure-
# restricted `ordered_repos_json` — so it always shows each repo's full
# configured priority regardless of this cycle's restrictions (see "--- 4.
# Co-Ordinator stage ---" below, which substitutes this same value into the
# prompt). Computed here, ahead of the fingerprint, and hashed verbatim:
# `ordered_repos_json`'s `sources` is *not* a substitute for it, because
# back-pressure (requirement 2.2a) narrows that array's `sources` to the three
# finishing sources for a repo with work waiting, while this table — and the
# prompt text the Co-Ordinator actually reads — still shows that repo's full
# configured list regardless. Without hashing the table itself, a config edit
# to a non-finishing source during a back-pressure cycle would change the
# assembled prompt while leaving the fingerprint's `repos[].sources`
# unchanged — the exact silent-stall shape this rule exists to prevent.
coordinator_sources_table="$(coordinator_work_sources_table "$all_repos_json")"

# --- 3ac. The Co-Ordinator's prompt, fitted to its model's context window
#          (requirement 4i, agent-ops#641) ---
# The base prompt, rendered here rather than at "--- 4. Co-Ordinator stage ---"
# below, because the fit immediately after it cannot decide what the runtime
# input may spend until it knows what the prompt text has already spent. The
# substitution is the same one it has always been; only its position moved.
coordinator_base_prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" coordinator "$prompt_overrides_json")"
coordinator_base_prompt="${coordinator_base_prompt//@@WORK_SOURCES_TABLE@@/$coordinator_sources_table}"

# On 2026-08-21 this Script assembled a Co-Ordinator prompt of ~226580 tokens
# against its model's 200000-token window, and the API refused it — four
# cycles running, every node, `coordinator exited 1`. Nothing had broken: the
# `issues` band had simply grown, one comment at a time, from ~212999 tokens
# three cycles earlier. Requirement 4g's own text had already named this
# shape — moving the aggregates off argv "raised the ceiling; it did not stop
# the set from still climbing toward whatever ceiling came next" — and this is
# the next ceiling, measured at last.
#
# The allowance handed to `coordinator_fit_bands` is what the configured
# maximum has left after everything the fit cannot shed, each term measured
# rather than assumed:
#
#   - the rendered base prompt, which is over 100 KB on its own;
#   - the fenced scaffolding the runtime input is wrapped in;
#   - the rest of the input document — `blocked`, `refinements`, `claimed`,
#     the model names and the refinement policy — assembled here from the very
#     same values "4. Co-Ordinator stage" will assemble the real one from, with
#     an empty `repos`, so what is subtracted is exactly what will be spent.
#
# Deriving the overhead against the *unfitted* array would be the tempting
# shortcut and is not what happens: the two differ by the indentation of the
# lines the fit removes, and an overhead measured on the fatter array would
# quietly narrow the allowance as the fit worked. Measuring it against an empty
# `repos` makes it independent of the rung, which is what lets the ladder's own
# measurements be trusted.
#
# Placed here, after back-pressure and before `coordinator_eligible_items`
# below, for the reason that block states of its own emptying of these same two
# bands: the eligible set must be what the Co-Ordinator is actually given, or
# requirement 3x's corroboration would demand an account of an entry the
# Script never offered.
# Initialised ahead of the guard because `set -u` is in force and the second
# `if` below reads it whichever way the first one went.
coordinator_fit_allowance=0
# Same reason, and the same `set -u` constraint, but initialised to a real
# empty-object value rather than left unset: the exemption-set gate far below
# (`coordinator_fit_trimmed_json`'s own `if`) has to read this whichever way
# the fit ran, and a bash parameter-expansion default of a bare pair of braces
# cannot stand in for that safely — `${parameter:-word}` closes on the *first*
# unquoted closing brace, so a bare-braces default reads as an open brace with
# a stray closing brace appended, and on every path where this variable
# actually was assigned a real fit report, that stray brace corrupted it into
# invalid JSON the gate silently read as "fit did not run" (agent-ops#933).
# Initialising here removes the default (and the trap) entirely: every reader
# below can use the value unconditionally.
coordinator_fit_report_json='{}'

# The Co-Ordinator's view of `refinements` (requirement 4j/issue #643),
# computed once, here, and spent unchanged by both the overhead measurement
# below and the input assembly under "--- 4. Co-Ordinator stage ---".
# `blocked` can afford to call its own view at both places because
# `coordinator_blocked_view` reads nothing of the repo array but its slugs,
# which no rung of the fit changes; this one is scoped against the
# candidates in `ordered_repos_json`, which the fit below reassigns, so
# calling it twice would measure the overhead against the unfitted candidate
# set and spend it against the fitted one — an error in the safe direction and
# still a measurement that is not of the thing it claims to be. Scoped against
# the unfitted array on purpose, for the same reason the overhead is measured
# against an empty `repos`: the fit only ever removes candidates, so this stays
# independent of the rung, and an entry kept for a candidate the ladder later
# sheds is a handful of bytes already accounted for.
#
# Unconditional, outside the bound's own guard: `coordinator_prompt_max_bytes`
# of `0` switches off the *fit*, not the Co-Ordinator's input document, and the
# assembly below reads this variable on every path.
coordinator_refinements_json="$(coordinator_refinements_view "$refinements_json" "$ordered_repos_json")"
if (( coordinator_prompt_max_bytes > 0 )); then
  coordinator_fit_blocked_json="$(coordinator_blocked_view "$blocked_json" "$ordered_repos_json")"
  coordinator_fit_overhead_json="$(jq -nc \
    --argjson blocked "$coordinator_fit_blocked_json" \
    --arg model_default "$implementer_model_default" \
    --arg model_trivial "$implementer_model_trivial" \
    --arg label "$pr_label" \
    --argjson cmax "$candidates_max" \
    --argjson policies "$refinement_policy_json" \
    'input as $refinements | input as $claimed
     | {repos: [], blocked: $blocked, refinements: $refinements, claimed: $claimed,
        models: {default: $model_default, trivial: $model_trivial}, pr_label: $label,
        candidates_max: $cmax, refinement_policy: $policies}' \
    <<<"$coordinator_refinements_json"$'\n'"$claimed_json" 2>/dev/null)" \
    || coordinator_fit_overhead_json='{"repos":[]}'
  # The wrapper "4. Co-Ordinator stage" puts around the rendered input: a blank
  # line, the heading, the two fence lines and the trailing newline. Counted
  # rather than estimated so the arithmetic below has no unmeasured term in it.
  coordinator_fit_scaffold_bytes="$(printf '%s' '

## Runtime input for this cycle

```json
```
' | wc -c)"
  # Requirement 4i's own terms (issue #645): the same four values already
  # folded into `coordinator_fit_overhead_json` above, read individually
  # through the one rendering function this block already has
  # (`coordinator_rendered_bytes`), so a refusal's log line names which band
  # was actually big rather than only the combined total.
  coordinator_fit_prompt_bytes="$(printf '%s' "$coordinator_base_prompt" | wc -c)"
  coordinator_fit_blocked_bytes="$(coordinator_rendered_bytes <<<"$coordinator_fit_blocked_json")"
  coordinator_fit_refinements_bytes="$(coordinator_rendered_bytes <<<"$coordinator_refinements_json")"
  coordinator_fit_claimed_bytes="$(coordinator_rendered_bytes <<<"$claimed_json")"
  coordinator_fit_overhead_bytes=$((
    coordinator_fit_prompt_bytes
    + $(printf '%s' "$coordinator_fit_overhead_json" | coordinator_rendered_bytes)
    + coordinator_fit_scaffold_bytes ))
  # The remainder, not a fifth independent measurement: the fence wrapper, the
  # small and static scaffold fields (`models`, `pr_label`, `candidates_max`,
  # `refinement_policy`) and the JSON structure `coordinator_fit_overhead_json`
  # itself adds are not worth a byte count each, so this term is whatever is
  # left once the four measured bands are subtracted from the total — which
  # keeps the breakdown summing to `coordinator_fit_overhead_bytes` exactly.
  coordinator_fit_scaffold_term_bytes=$((
    coordinator_fit_overhead_bytes
    - coordinator_fit_prompt_bytes
    - coordinator_fit_blocked_bytes
    - coordinator_fit_refinements_bytes
    - coordinator_fit_claimed_bytes ))
  coordinator_fit_allowance=$(( coordinator_prompt_max_bytes - coordinator_fit_overhead_bytes ))
  coordinator_fit_terms_json="$(jq -nc \
    --argjson prompt "$coordinator_fit_prompt_bytes" \
    --argjson blocked "$coordinator_fit_blocked_bytes" \
    --argjson refinements "$coordinator_fit_refinements_bytes" \
    --argjson claimed "$coordinator_fit_claimed_bytes" \
    --argjson scaffold "$coordinator_fit_scaffold_term_bytes" \
    '{terms: {prompt: $prompt, blocked: $blocked, refinements: $refinements,
              claimed: $claimed, scaffold: $scaffold}}')"
fi
# An allowance that came out at or below zero is *not* the same fact as the
# bound being switched off, and must not go through the same door: the prompt
# text and the unsheddable half of the input have between them already spent
# the whole maximum, so no rung of the ladder can make this cycle's prompt fit
# — the remedy is a smaller unsheddable half (issue #643's own fix, the
# refinements view above) or a larger `coordinator_prompt_max_bytes`.
#
# What this case must *not* do is what it did between agent-ops#642 and #643:
# warn, fall past the fit entirely, and send the array whole. "The prompt is
# already too long" is the one circumstance in which shedding nothing is the
# worst available answer — on 2026-08-21 it put a 350,052-byte issues extract
# into a prompt that was over the window without it, and the API refused the
# stage on every node of the fleet for eight hours. A hopeless budget is still
# a budget: the ladder is walked to its last rung, the array comes back as
# small as it can be built, and the prompt goes out with the best chance the
# Script can give it rather than the worst.
#
# 1, not 0: `coordinator_fit_bands` reads a budget of 0 or less as "bound off"
# and hands the array back unchanged, which is precisely the behaviour this
# block exists to avoid. A budget of 1 fails every rung — prose first, then
# entry caps — and lands in that function's final branch, which returns the
# smallest array the ladder can build together with `fits: false`. The warning
# below still tells the operator the whole truth; the clamp just stops the
# cycle from making it worse on the way out.
if (( coordinator_prompt_max_bytes > 0 && coordinator_fit_allowance <= 0 )); then
  log_event "warning" "$(jq -nc \
    --arg d "the Co-Ordinator's prompt text and unsheddable input ($coordinator_fit_overhead_bytes bytes) already meet or exceed coordinator_prompt_max_bytes ($coordinator_prompt_max_bytes) — no runtime-input fit can make this cycle's prompt fit; shedding the candidate bands to the ladder's last rung anyway, and the API may still refuse it" \
    --argjson terms "$coordinator_fit_terms_json" \
    '{detail: $d} + $terms')"
  coordinator_fit_allowance=1
fi
if (( coordinator_prompt_max_bytes > 0 )); then
  coordinator_fit_json="$(coordinator_fit_bands "$coordinator_fit_allowance" <<<"$ordered_repos_json" 2>&1)" \
    || { guard_warn "coordinator_fit" "$coordinator_fit_json"; coordinator_fit_json=""; }
  if [[ -n "$coordinator_fit_json" ]] && jq -e '.repos | type == "array"' <<<"$coordinator_fit_json" >/dev/null 2>&1; then
    ordered_repos_json="$(jq -c '.repos' <<<"$coordinator_fit_json")"
    coordinator_fit_report_json="$(jq -c '.fit' <<<"$coordinator_fit_json")"
    coordinator_fit_detail_text="$(coordinator_fit_detail "$coordinator_fit_report_json")"
    if [[ -n "$coordinator_fit_detail_text" ]]; then
      # An informational record, not a warning: a fleet whose backlog has
      # outgrown the window will trim on every cycle from here on, and a
      # standing `warning` for the ordinary case is how a log stops being read.
      log_event "coordinator-input-fitted" "$(jq -nc --arg d "$coordinator_fit_detail_text" \
        --argjson f "$coordinator_fit_report_json" --argjson terms "$coordinator_fit_terms_json" \
        '{detail: $d} + $f + $terms')"
      # Not fitting is the other thing entirely: the identity fields alone have
      # outgrown the allowance, the ladder has nothing left to shed, and the
      # API will refuse the prompt this cycle is about to send. Say so *before*
      # it does, so the union log carries the cause rather than an exit code —
      # the exact gap agent-ops#641 was filed into.
      if ! jq -e '.fits' <<<"$coordinator_fit_report_json" >/dev/null 2>&1; then
        log_event "warning" "$(jq -nc --arg d "$coordinator_fit_detail_text" \
          --argjson terms "$coordinator_fit_terms_json" '{detail: $d} + $terms')"
      fi
    fi
  fi
fi
# --- end of requirement 4i's fit ---

# The fit's own exemption set for requirement 34e's fourth refusal and
# requirement 3x's matching completeness exception (agent-ops#683): which
# issues/tech-debt candidates this cycle's fit actually trimmed, `{repo,
# item, source}` per entry, on the same shape `coordinator_eligible_items`
# below produces. Read straight off `ordered_repos_json` as the fit above
# left it — never the pre-fit array, which carries none of the markers
# `coordinator_fit_trimmed_items` looks for — and only when the fit actually
# ran: an untouched array has nothing to find, and asking would cost a jq
# pass for an empty answer on every ordinary cycle.
coordinator_fit_trimmed_json="[]"
coordinator_fit_rung=0
if jq -e '.applied == true' <<<"$coordinator_fit_report_json" >/dev/null 2>&1; then
  coordinator_fit_trimmed_json="$(coordinator_fit_trimmed_items <<<"$ordered_repos_json")"
  coordinator_fit_rung="$(jq -r '.rung // 0' <<<"$coordinator_fit_report_json" 2>/dev/null || echo 0)"
fi

# The Script's own count of what *every* pre-fetched band could actually offer
# this cycle, and which repo+item+source triples make it up — the
# machine-corroboration baseline "5a. Verdict corroboration" below tests the
# Co-Ordinator's verdict against (requirement 3x, issue #322; requirement 3t
# measured only `tech_debt` here), and which requirement 3b's fingerprint
# hashes as part of each band's own array regardless. Taken here rather than at
# "3c/3u. Pre-fetched-band eligibility" so that it reads what the Co-Ordinator
# is actually about to be given: back-pressure just above empties `issues` and
# `tech_debt` and narrows every repo's `sources` to the four finishing ones,
# and an eligible set counted before that would hold items this cycle forbids
# it to select (see that block's own comment, and
# `coordinator_eligible_items`').
eligible_items_json="$(coordinator_eligible_items "$ordered_repos_json" "$blocked_json")"
eligible_items_total="$(jq 'length' <<<"$eligible_items_json" 2>&1)" \
  || { guard_warn "eligible_items_total" "$eligible_items_total"; eligible_items_total=0; }

# The count behind requirement 3x's trimmed exemption (agent-ops#683): how
# many of this cycle's eligible candidates the fit above actually trimmed —
# the ones `unaccounted_items` below no longer demands a `needs_refinement`/
# `voided` account for. Logged once per cycle whatever the Co-Ordinator went
# on to decide, because it is a fact about this cycle's input rather than
# about the verdict — and only where there is a count to log, so the ordinary
# cycle, whose fit trimmed nothing, carries no such record.
coordinator_unassessable_json="$(coordinator_unassessable_items "$eligible_items_json" "$coordinator_fit_trimmed_json")"
coordinator_unassessable_total="$(jq 'length' <<<"$coordinator_unassessable_json" 2>&1)" \
  || { guard_warn "coordinator_unassessable_total" "$coordinator_unassessable_total"; coordinator_unassessable_total=0; }
if (( coordinator_unassessable_total > 0 )); then
  log_event "coordinator-input-fit-unassessable" "$(jq -nc \
    --argjson n "$coordinator_unassessable_total" --argjson rung "$coordinator_fit_rung" \
    --arg d "the fit ladder trimmed $coordinator_unassessable_total of this cycle's eligible candidate(s) (rung $coordinator_fit_rung) — requirement 34e refuses a needs_refinement report against any of them, and requirement 3x's completeness check asks for none either" \
    '{detail: $d, unassessable_total: $n, rung: $rung}')"
fi

# --- 3b. No-op short-circuit (requirement 3b) ---
# The Co-Ordinator costs the same to tell us "nothing to do" as it does to
# select work. On a quiet week that is 24 identical answers a day. If every
# input to its verdict is byte-identical to the last time it declined, the
# verdict is already known and buying it again buys nothing.
#
# The fingerprint must cover *every* input — see lib/noop-skip.sh for the map
# of source to signal, and for why a gap here is a silent stall rather than a
# visible bug. Two of them are not repo state at all and are the easiest to
# leave out: the config that decides which repos and sources exist, and the
# prompt that holds the selection rules. Without them, editing coordinator.md
# — or a configured prompt_overrides.coordinator fragment (requirement
# 4a) — would do nothing until an unrelated commit happened to land somewhere.
#
# `repo_nice` belongs in this same object for the same reason, though what it
# guards against is the ordering feature (requirement 3, lib/repo-order.sh)
# rather than a source: repo *order* is deliberately normalised out of the
# fingerprint — `sort_by(.slug)` in lib/noop-skip.sh's canon, asserted by
# test/noop-skip.test.sh — because the walk order was never itself an input
# to what the Co-Ordinator may select, only to which candidate it reaches
# first. An edit to a repo's `nice` changes only that order, so without this
# key such an edit would move nothing: the exact silent-stall shape the rest
# of this block already describes, just reached from the ordering side
# instead of a missing source. Only non-zero entries are carried, and the key
# is omitted entirely when the map is empty — repo_nice_selection_config
# (lib/repo-order.sh) returns `{repo_nice: …}` or a bare `{}` accordingly —
# so a config with no `nice` set anywhere fingerprints byte-identical to how
# it did before this feature shipped: no fleet-wide spurious wake the day
# this lands.
repo_nice_json="$(repo_nice_selection_config "$all_repos_json")"
selection_config_json="$(jq -nc \
  --arg cm "$coordinator_model" \
  --arg md "$implementer_model_default" \
  --arg mt "$implementer_model_trivial" \
  --argjson cmax "$candidates_max" \
  --argjson nice "$repo_nice_json" \
  '{coordinator_model: $cm, models: {default: $md, trivial: $mt}, candidates_max: $cmax}
   + $nice')"
coordinator_prompt_sha="$(stage_prompt_sha "$PROMPTS_DIR" "$state_dir" coordinator "$prompt_overrides_json")"
# The Enabler's three inputs join the fingerprint for the same reason (requirement
# 35b). Its eligible set is the third array whose candidacy turns on something no
# repo signal carries — an item becomes eligible when the fleet has run its third
# Co-Ordinator since the block, which moves no commit, issue, alert or PR — so
# without it the escalation path would come due during a quiet week and wait for
# the forced recheck to be noticed. The set empties again once the engagement's
# examined markers land, which is what lets the fleet go back to skipping.
enabler_config_json="$(jq -nc \
  --arg m "$enabler_model" \
  --arg n "$enabler_after_coordinator_cycles" \
  --arg rn "$refinement_after_coordinator_cycles" \
  --arg rh "$enabler_recheck_hours" \
  --arg lbl "$enabler_escalation_label" \
  --arg rmax "$refinement_max_per_engagement" \
  '{enabler_model: $m, after_coordinator_cycles: $n, refinement_after_coordinator_cycles: $rn,
    recheck_hours: $rh, escalation_label: $lbl, refinement_max_per_engagement: $rmax}')"
# Absent rather than fatal when the prompt is missing: a missing Enabler prompt
# is a stage that does not run (see `maybe_run_enabler`), not a cycle that dies.
# Covers a configured prompt_overrides.enabler fragment too (requirement 4a),
# the same as the Co-Ordinator's hash above.
enabler_prompt_sha=""
[[ -f "$PROMPTS_DIR/enabler.md" ]] \
  && enabler_prompt_sha="$(stage_prompt_sha "$PROMPTS_DIR" "$state_dir" enabler "$prompt_overrides_json")"

# The Refiner's own inputs join the fingerprint for the same reason (requirement
# 39b): its candidate set turns on the same `refinements`/`blocked`/`void`
# state the fingerprint already carries, but a `refinement_policy` edit moves
# none of those and must still bust the no-op short-circuit on its own.
refiner_config_json="$(jq -nc \
  --arg m "$refiner_model" --arg lbl "$refined_label" --arg rmax "$refiner_max_per_engagement" \
  --argjson policy "$refinement_policy_json" \
  '{refiner_model: $m, refined_label: $lbl, refiner_max_per_engagement: $rmax, refinement_policy: $policy}')"
refiner_prompt_sha=""
[[ -f "$PROMPTS_DIR/refiner.md" ]] \
  && refiner_prompt_sha="$(stage_prompt_sha "$PROMPTS_DIR" "$state_dir" refiner "$prompt_overrides_json")"

# The eight fleet-state arrays arrive on stdin, one JSON document per line,
# bound positionally below in the order printed — never in argv (requirement
# 4g). Each `--argjson` value is a single argv entry capped at MAX_ARG_STRLEN
# (131072 bytes), and on 2026-08-12 the void extract alone crossed it: this
# unguarded call then died at execve with `Argument list too long`, exit 126,
# on every cycle of every node, before the Co-Ordinator ran — and without an
# `attempt-failed` for requirement 2.7's crash-loop ladder to count. Only
# values bounded by configuration stay in argv. A here-string rather than a
# pipe, for requirement 4c's reason: under `pipefail` a producer's SIGPIPE
# must not become this assignment's status.
noop_stdin="$(printf '%s\n' \
  "$ordered_repos_json" "$source_states_json" "$blocked_json" "$void_json" \
  "$refinements_json" "$claimed_json" "$enabler_eligible_json" "$refiner_candidates_json")"
noop_input="$(jq -nc \
  --argjson sc "$selection_config_json" \
  --argjson ec "$enabler_config_json" \
  --arg psha "$coordinator_prompt_sha" \
  --arg esha "$enabler_prompt_sha" \
  --arg wst "$coordinator_sources_table" \
  --argjson rc "$refiner_config_json" \
  --arg rsha "$refiner_prompt_sha" \
  'input as $repos | input as $states | input as $blocked | input as $void
   | input as $refinements | input as $claimed | input as $eligible | input as $rcand
   | {
     repos: [ $repos[] as $r
              | $r + { state: ((first($states[]? | select(.slug == $r.slug))) // {ok: false}) } ],
     blocked: $blocked,
     void: $void,
     refinements: $refinements,
     claimed: $claimed,
     enabler_eligible: $eligible,
     selection_config: $sc,
     coordinator_prompt_sha: $psha,
     enabler_config: $ec,
     enabler_prompt_sha: $esha,
     coordinator_work_sources_table: $wst,
     refiner_candidates: $rcand,
     refiner_config: $rc,
     refiner_prompt_sha: $rsha
   }' <<<"$noop_stdin")"
noop_fingerprint_value="$(noop_fingerprint <<<"$noop_input")"

# Computed even when the skip is bypassed, because it is also what a
# `none-selected` records for the *next* cycle to compare against. A --once run
# that finds nothing to do should still spare the following cron tick the same
# question.
noop_skip=""
if [[ -n "$noop_fingerprint_value" ]] && ! (( DRY_RUN || ONCE )); then
  noop_skip="$(noop_skip_reason "$noop_fingerprint_value" "$union_log" "$none_selected_recheck_hours")"
fi
if [[ -n "$noop_skip" ]]; then
  noop_state=""; noop_cause=""
  IFS=$'\t' read -r noop_state noop_cause < <(node_time_state_idle_split "$eligible_items_total" awaiting-tick)
  log_event "stand-down" "$(jq -nc --arg r "$noop_skip" --arg f "$noop_fingerprint_value" --arg c "$noop_cause" \
    '{reason: $r, fingerprint: $f, cause: $c}')"
  set_node_state_terminal "$noop_state" "$noop_cause"
  exit 0
fi

# Requirement 3u/issue #320: `void` is never sent to the Co-Ordinator at all.
# Every band the Script pre-fetches whole is already void-filtered before this
# point (the loop above), and the three sources the Co-Ordinator still derives
# itself — project-review, failed-runs, implementation-plan — have no
# pre-fetched array for the Script to filter, exactly as before this change;
# what has stopped is handing the model a raw list to apply that same
# judgement to by eye. "Voiding an item yourself" (prompts/coordinator.md) is
# unaffected: the model can still report a fresh `voided` entry from evidence
# it read this cycle, and the Script's own void corroboration (requirement
# 34d) validates it independently, with no existing list to compare against.
# `void_json` still joins the no-op fingerprint above unchanged — a fresh void
# state must still buy the next cycle a fresh look even though the model
# itself never reads it.
#
# `blocked` stays, but trimmed by coordinator_blocked_view (above) to the
# fields "Re-checking blocked items" and "A blocked issue with fresh evidence
# must be re-read" actually read, a one-line `detail`, and the repositories
# this cycle engages. Every other pre-fetched band's own blocked entries
# never reach the Co-Ordinator either (the loop above already excluded
# them), so what remains of this list's purpose is `issues`' live re-check
# duty and the three Co-Ordinator-derived sources' own exclusion-1 check.
coordinator_blocked_json="$(coordinator_blocked_view "$blocked_json" "$ordered_repos_json")"
}
