#!/usr/bin/env bash
#
# lib/constraint.sh — the constraint statement (docs/ROADMAP.md D21's "state
# the constraint" bullet, issue #609): one sentence naming what is limiting
# this installation's throughput right now, over what share of the window,
# and what to do about it.
#
# `constraint_classify` is a pure `jq` fold over the node time-state account
# `lib/node-time-state.sh`'s `node_time_state_fold` already produces — it
# reads no raw events itself, so it cannot drift from that account's own
# arithmetic (docs/ROADMAP.md's own "computed from the time account, not
# asserted"). No network, no config beyond what is passed in, testable
# against canned input.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller owns those.

# --- The candidate set --------------------------------------------------
#
# Six candidates, fixed order, always present in `candidates`: four are
# attributed straight from the time account's own causes, two are named but
# never evaluable from this account alone.
#
#   cron-latency      idle-with-demand / awaiting-tick
#   back-pressure     idle-with-demand / back-pressure
#   node-count        idle-with-demand / peer-claimed, PLUS
#                      idle-without-demand — both read as "more node
#                      capacity than there is work for," so both recommend
#                      shrinking the fleet rather than fixing anything;
#                      idle-without-demand alone is never named the
#                      constraint on its own terms (it is the healthy zero,
#                      not a resource binding anything), but it is exactly
#                      what makes a shrink recommendation possible, so
#                      folding it into this candidate's own share is what
#                      lets "run fewer nodes" compete on equal footing with
#                      the grow-side candidates below rather than being
#                      structurally unable to lead the sentence.
#   model-capacity    externally-blocked / usage-limit — isolated from the
#                      externally-blocked bucket's other seven causes
#                      (`lib/node-time-state.sh`'s own
#                      `externally_blocked_by_cause`), since only usage-limit
#                      is a model-capacity signal; the rest are a host or
#                      GitHub fault this item never recommends fixing by
#                      raising model capacity.
#   human-merge-gate  never evaluable here: the time account carries no
#                      per-node cause for a pull request waiting on a human
#                      decision, and merge_budget's own deferral
#                      observability (#574) measures pull-request wait time,
#                      a different unit from node-seconds. Structural, not a
#                      missing record — see docs/ROADMAP.md D21's own
#                      three-way split of time, spend and flow accounts.
#   pipeline-defect-rate  never evaluable here, for the identical reason:
#                      the rework record (#596) counts tokens, elapsed time
#                      and items, never a node-time-state cause.
#
# idle-with-demand's other cause, coordinator-declined, names no candidate
# here on purpose — it is a model-selection question (D22's own "which
# model runs each actor"), a different lever category from the six this
# item ranks. Its seconds are not silently dropped: they are still visible
# in the account's own `idle_with_demand_by_cause` breakdown a caller
# renders beside this sentence as evidence, just never rankable as "the
# constraint" by this fold.

# constraint_classify ACCOUNT_JSON MIN_SHARE MIN_SAMPLE_SECONDS [CADENCE_BOUND_MINUTES]
#
# ACCOUNT_JSON is `node_time_state_fold`'s own output verbatim. Prints the
# constraint object:
#
#   window, nodes, expected_total_seconds  — echoed from the account
#   min_share, min_sample_seconds,
#   cadence_bound_minutes                  — echoed back, the last purely
#                                             informational (never gates
#                                             anything here — the caller's
#                                             own resolution-floor note)
#   status         "ok" | "insufficient-evidence"
#   insufficient_reason
#     null                             when status is "ok"
#     "no-time-account-data"           the account has no events at all
#                                       (`window.from` is null)
#     "window-below-minimum-sample"    expected_total_seconds < MIN_SAMPLE_SECONDS
#     "no-candidate-above-minimum-share"  every evaluable candidate's own
#                                       share is below MIN_SHARE
#   sentence            the one leading line, always non-null
#   leading_candidate   the winning candidate's own `key`, null when status
#                        is "insufficient-evidence"
#   candidates           all six, fixed order, each:
#     key, label, evaluable
#     seconds, share      null for a non-evaluable candidate
#     direction            "grow" | "shrink" | null
#     recommendation       null for a non-evaluable candidate
#     effect_node_seconds, effect_note
#                           the recommendation's own expected effect, in
#                           node-seconds recoverable (or idle node-seconds
#                           a shrink would not have spent) this window, an
#                           upper bound — never money, never a unit of
#                           delivered work (docs/ROADMAP.md D21's own scope
#                           bounds)
#     not_evaluable_reason, depends_on
#                           null for an evaluable candidate
#
# Never falls back to the largest available bucket and never defaults to a
# plausible constraint: below either the minimum share or the minimum
# sample, or with no account at all, `status` reads "insufficient-evidence"
# and `leading_candidate` is null, in as many words on `sentence` too.
# shellcheck disable=SC2016  # jq's own $account/$min_share/etc, not the shell's.
CONSTRAINT_CLASSIFY_JQ='
  def round3(x): (x * 1000 | round) / 1000;

  ($account.window // {from:null,to:null,seconds:0}) as $window
  | ($account.nodes // []) as $nodes
  | ($account.expected_total_seconds // 0) as $expected_total
  | ($account.idle_with_demand_by_cause // {}) as $idle
  | ($account.externally_blocked_by_cause // {}) as $eb
  | ($account.totals // {}) as $totals

  | ($idle["awaiting-tick"] // 0) as $cron_s
  | ($idle["back-pressure"] // 0) as $bp_s
  | (($idle["peer-claimed"] // 0) + ($totals["idle-without-demand"] // 0)) as $nc_s
  | ($eb["usage-limit"] // 0) as $mc_s

  | (if $expected_total > 0 then ($cron_s / $expected_total) else null end) as $cron_share
  | (if $expected_total > 0 then ($bp_s / $expected_total) else null end) as $bp_share
  | (if $expected_total > 0 then ($nc_s / $expected_total) else null end) as $nc_share
  | (if $expected_total > 0 then ($mc_s / $expected_total) else null end) as $mc_share

  | [
      {key:"cron-latency", label:"Cron latency (waiting for the next tick)",
       evaluable:true, seconds:$cron_s, share:(if $cron_share == null then null else round3($cron_share) end),
       direction:"grow", recommendation:"shorten schedule.cycle_interval_minutes, or move to event-driven dispatch",
       effect_node_seconds:$cron_s,
       effect_note:"upper bound: node-seconds this window that could move to producing if cron latency were removed",
       not_evaluable_reason:null, depends_on:null},
      {key:"back-pressure", label:"The back-pressure cap (max_open_agent_prs)",
       evaluable:true, seconds:$bp_s, share:(if $bp_share == null then null else round3($bp_share) end),
       direction:"grow", recommendation:"raise max_open_agent_prs, or climb a rung of the autonomy ladder in D18",
       effect_node_seconds:$bp_s,
       effect_note:"upper bound: node-seconds this window that could move to producing if the cap were raised",
       not_evaluable_reason:null, depends_on:null},
      {key:"node-count", label:"Node count (more nodes than there is work for)",
       evaluable:true, seconds:$nc_s, share:(if $nc_share == null then null else round3($nc_share) end),
       direction:"shrink", recommendation:"run fewer nodes: it costs no throughput and saves the idle spend",
       effect_node_seconds:$nc_s,
       effect_note:"upper bound: idle node-seconds this window a smaller fleet would not have spent",
       not_evaluable_reason:null, depends_on:null},
      {key:"model-capacity", label:"Model capacity (usage-limit stand-downs)",
       evaluable:true, seconds:$mc_s, share:(if $mc_share == null then null else round3($mc_share) end),
       direction:"grow", recommendation:"raise model capacity or quota for the blocked actor, or move it to a less-constrained tier",
       effect_node_seconds:$mc_s,
       effect_note:"upper bound: node-seconds this window that could move to producing if the quota were raised",
       not_evaluable_reason:null, depends_on:null},
      {key:"human-merge-gate", label:"The human merge gate",
       evaluable:false, seconds:null, share:null, direction:null, recommendation:null,
       effect_node_seconds:null, effect_note:null,
       not_evaluable_reason:"the time account carries no node-time-state cause for pull requests waiting on a human decision; the merge_budget governor'\''s own deferral observability (#574) measures pull-request wait time, not node-seconds, so it cannot rank alongside this account'\''s own candidates without a separate attribution this item does not build",
       depends_on:"#574"},
      {key:"pipeline-defect-rate", label:"The pipeline'\''s own defect rate",
       evaluable:false, seconds:null, share:null, direction:null, recommendation:null,
       effect_node_seconds:null, effect_note:null,
       not_evaluable_reason:"the rework record (#596) counts tokens, elapsed time and items, not a node-time-state cause; it cannot rank alongside this account'\''s own candidates without a separate node-seconds attribution this item does not build",
       depends_on:"#596"}
    ] as $candidates

  | ($window.from == null) as $no_account
  | (if $no_account then true else ($expected_total < $min_sample_seconds) end) as $below_sample
  | ($candidates | map(select(.evaluable == true))) as $evaluable_candidates
  | ($evaluable_candidates | max_by(.share // -1)) as $top
  | (if $top == null then null else $top.share end) as $top_share
  | (if $no_account then "no-time-account-data"
     elif $below_sample then "window-below-minimum-sample"
     elif ($top_share == null or $top_share < $min_share) then "no-candidate-above-minimum-share"
     else null end) as $insufficient_reason
  | (if $insufficient_reason == null then "ok" else "insufficient-evidence" end) as $status
  | (if $insufficient_reason == null then $top.key else null end) as $leading_key

  | (if $insufficient_reason == "no-time-account-data" then
       "Insufficient evidence: no node time-state events recorded yet, so the time account (#597) has nothing to fold over this window."
     elif $insufficient_reason == "window-below-minimum-sample" then
       "Insufficient evidence: only " + ($expected_total | tostring) + " node-second(s) observed between " +
         ($window.from // "?") + " and " + ($window.to // "?") + ", below the " +
         ($min_sample_seconds | tostring) + " minimum needed to state a constraint."
     elif $insufficient_reason == "no-candidate-above-minimum-share" then
       "Insufficient evidence: no candidate cleared the " + (($min_share*100|round)|tostring) +
         "% minimum share between " + $window.from + " and " + $window.to + " (largest: " +
         $top.label + " at " + (($top_share*100|round)|tostring) + "%)."
     elif $top.direction == "shrink" then
       $top.label + " accounted for " + (($top_share*100|round)|tostring) +
         "% of fleet node-time between " + $window.from + " and " + $window.to + "; " + $top.recommendation + "."
     else
       $top.label + " accounted for " + (($top_share*100|round)|tostring) +
         "% of fleet node-time between " + $window.from + " and " + $window.to + "; " + $top.recommendation +
         " (up to " + ($top.effect_node_seconds|tostring) + "s recoverable this window, an upper bound)."
     end) as $sentence

  | {
      window: $window,
      nodes: ($nodes | length),
      expected_total_seconds: $expected_total,
      min_share: $min_share,
      min_sample_seconds: $min_sample_seconds,
      cadence_bound_minutes: $cadence_bound_minutes,
      status: $status,
      insufficient_reason: $insufficient_reason,
      sentence: $sentence,
      leading_candidate: $leading_key,
      candidates: $candidates
    }
'

constraint_classify() {
  local account_json="${1:-}" min_share="${2:-0.3}" min_sample_seconds="${3:-14400}" cadence_bound_minutes="${4:-null}"
  [[ -n "$account_json" ]] || account_json='{}'
  [[ "$cadence_bound_minutes" =~ ^[0-9]+$ ]] || cadence_bound_minutes=null
  jq -nc \
    --argjson account "$account_json" \
    --argjson min_share "$min_share" \
    --argjson min_sample_seconds "$min_sample_seconds" \
    --argjson cadence_bound_minutes "$cadence_bound_minutes" \
    "$CONSTRAINT_CLASSIFY_JQ" 2>/dev/null
}
