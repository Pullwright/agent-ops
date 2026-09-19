#!/usr/bin/env bash
#
# lib/fleet-sizing.sh — the fleet-sizing figure (docs/ROADMAP.md D21/D14
# "Price the fleet and the tokens", issue #612): per node, the items it
# landed that no peer would have taken, set against its idle-without-demand
# hours and its share of contended `claim-lost` events. A node whose idle
# time and contention are both elevated while it rarely delivers anything a
# peer would not have is over-provisioned, and this is the figure that must
# be willing to say so — `lib/constraint.sh`'s own fleet-wide sentence can
# already name "node count" as the constraint, but only as one bucket in a
# six-way ranking; this is the per-node breakdown behind that bucket, never
# a replacement for it (issue #612's own scope bound).
#
# Three functions, read-log/pure-classify split on the same terms
# `lib/node-time-state.sh`/`lib/constraint.sh` already keep:
#
#   fleet_sizing_contention_by_node   reads the log directly: per node,
#                                     `selection` counts and contended
#                                     `claim-lost` counts (cause `held` or
#                                     `pr-held` — the same measure
#                                     `scripts/pickup-metrics.sh` already
#                                     computes fleet-wide before/after an
#                                     adoption boundary; this is the same
#                                     population, just grouped by node
#                                     instead of by era, since fleet sizing
#                                     asks "which node," not "before or
#                                     after which rollout"). Factored here
#                                     rather than left inline in
#                                     pickup-metrics.sh so the one
#                                     computation serves both that script's
#                                     own report and this dashboard figure,
#                                     never two independently-maintained
#                                     counts of the same events.
#   fleet_sizing_exclusive_landings_by_node
#                                     pure: reads `item_lifecycle_fold`'s own
#                                     `records[]` (never the raw log a second
#                                     time) and reports, per node, how many
#                                     landed items it claimed and how many of
#                                     those had no competing `claim-lost` from
#                                     any other node on the same {repo, item}
#                                     — "no peer would have taken it," in the
#                                     issue's own words.
#   fleet_sizing_classify            pure: folds a node-time-state account
#                                     (`lib/node-time-state.sh`'s own
#                                     `by_node[node]["idle-without-demand"]`),
#                                     the contention counts above and the
#                                     exclusive-landing counts above into a
#                                     per-node verdict and a fleet-wide
#                                     sentence, on the identical
#                                     insufficient-evidence discipline
#                                     `constraint_classify` already keeps —
#                                     never a guess dressed as a number.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller owns those.

# --- Read: per-node selection/contended-claim-lost counts -------------------
#
# The identical event population `scripts/pickup-metrics.sh`'s own
# before/after fold reads (`selection` and `claim-lost` whose `cause` is
# `held` or `pr-held` — a `claim-lost` with no `cause` at all, from before
# requirement 17a added the field, is excluded rather than guessed at, same
# as there), just grouped by node instead of split into an adoption-boundary
# era: fleet sizing has no "before finish-then-continue" question to ask, so
# there is nothing here for that boundary to answer.
# shellcheck disable=SC2016  # jq's own $all/$since, not the shell's.
FLEET_SIZING_CONTENTION_BY_NODE_JQ='
  def ratio($c; $s): (if $s == 0 then null else ($c / $s) end);

  ($all | map(select(type == "object"))) as $all2
  | ($all2 | map(select($since == "" or (.ts // "") >= $since))) as $ev
  | ($ev | map(.ts // "") | map(select(. != "")) | sort) as $ts_all
  | ($ev | map(select(.event == "selection" and ((.node // "") != "")))) as $sel
  | ($ev | map(select(.event == "claim-lost"
      and ((.node // "") != "")
      and (.cause == "held" or .cause == "pr-held")))) as $cont
  | ($sel  | group_by(.node) | map({key: .[0].node, value: length}) | from_entries) as $sel_by_node
  | ($cont | group_by(.node) | map({key: .[0].node, value: length}) | from_entries) as $cont_by_node
  | (($sel_by_node | keys) + ($cont_by_node | keys) | unique) as $nodes
  | ($nodes | map(. as $n | {
        key: $n,
        value: {
          selections: ($sel_by_node[$n] // 0),
          contended_losses: ($cont_by_node[$n] // 0),
          ratio: ratio(($cont_by_node[$n] // 0); ($sel_by_node[$n] // 0))
        }
      }) | from_entries) as $by_node
  | {
      window: {
        from: (if ($ts_all | length) == 0 then null else $ts_all[0] end),
        to:   (if ($ts_all | length) == 0 then null else $ts_all[-1] end)
      },
      fleet: {
        selections: ($sel | length),
        contended_losses: ($cont | length),
        ratio: ratio(($cont | length); ($sel | length))
      },
      by_node: $by_node
    }
'

# fleet_sizing_contention_by_node LOG_FILE [SINCE]
# Print `{window, fleet, by_node}` folded from LOG_FILE (or stdin, "-" or
# omitted). Always succeeds, printing the all-empty shape for a missing,
# empty or unreadable log, on the same terms `item_lifecycle_pickup_pairs`
# already does.
fleet_sizing_contention_by_node() {
  local src="${1:--}" since="${2:-}" all_json="" out=""
  if [[ "$src" == "-" ]]; then
    all_json="$(jq -c -R 'fromjson? // empty' 2>/dev/null | jq -sc '.' 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    all_json="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null | jq -sc '.' 2>/dev/null || true)"
  fi
  [[ -n "$all_json" ]] || all_json='[]'
  out="$(jq -nc --arg since "$since" 'input as $all | ('"$FLEET_SIZING_CONTENTION_BY_NODE_JQ"')' \
    <<<"$all_json" 2>/dev/null || true)"
  [[ -n "$out" ]] || out='{"window":{"from":null,"to":null},"fleet":{"selections":0,"contended_losses":0,"ratio":null},"by_node":{}}'
  printf '%s' "$out"
}

# --- Pure: exclusive landings per node ---------------------------------------
#
# "No peer would have taken it": a landed item whose only `selection` events
# (there can be more than one — an abandoned draft resumed by a later cycle
# reselects the same item) all belong to the same node, and no *other* node
# ever logged a `claim-lost` for that same {repo, item}. The landing node
# itself is read from the last `selection` chronologically — the one that
# actually carried the item through to the merge this fold's own caller
# already confirmed (`fate == "landed"`) — never the first, which a resumed
# draft would misattribute to whichever node happened to try first.
#
# Deliberately reads `item_lifecycle_fold`'s own `records[].instants[]`
# rather than the raw log a second time: those instants already carry every
# event this {repo, item} pair ever saw, `claim-lost` included, so this fold
# adds no new event scan, only a different projection of one already made.
# shellcheck disable=SC2016  # jq's own $lifecycle, not the shell's.
FLEET_SIZING_EXCLUSIVE_LANDINGS_JQ='
  ($lifecycle.records // []) as $records
  | ($records | map(select(.fate == "landed"))) as $landed
  | ($landed | map(
        (.instants | map(select(.event == "selection")) | sort_by(.ts) | last | .node) as $landing_node
        | (.instants | map(select(.event == "claim-lost")) | map(.node) | map(select(. != null)) | unique) as $lost_nodes
        | select($landing_node != null)
        | {node: $landing_node,
           exclusive: ((($lost_nodes - [$landing_node]) | length) == 0)}
    )) as $per_item
  | ($per_item | group_by(.node)
      | map({key: .[0].node, value: {
          landed: length,
          exclusive: (map(select(.exclusive)) | length)
        }})
      | from_entries)
'

# fleet_sizing_exclusive_landings_by_node LIFECYCLE_FILE
# Print `{"<node>": {landed, exclusive}, ...}` from `item_lifecycle_fold`'s
# own output at LIFECYCLE_FILE (read via `--slurpfile`, never captured into a
# bash variable — `records[]` is log-scale, the same "nothing that scales
# with the log is ever held in a bash variable" rule `item_lifecycle_fold`'s
# own header states, agent-ops#1620). Always succeeds, printing `{}` for a
# missing, empty or unreadable file.
fleet_sizing_exclusive_landings_by_node() {
  local lifecycle_file="${1:-}" out=""
  if [[ -n "$lifecycle_file" && -s "$lifecycle_file" ]]; then
    out="$(jq -nc --slurpfile lc "$lifecycle_file" \
      '($lc[0]) as $lifecycle | ('"$FLEET_SIZING_EXCLUSIVE_LANDINGS_JQ"')' 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='{}'
  printf '%s' "$out"
}

# --- Pure: the per-node verdict and the fleet-wide sentence ------------------
#
# Three inputs, each already a small per-node summary (never the raw log or
# `records[]` itself — those stay behind the two functions above):
#
#   $time_account   `node_time_state_fold`'s own output — only `.window` and
#                   `.by_node[node]["idle-without-demand"]` are read.
#   $contention     `fleet_sizing_contention_by_node`'s own output.
#   $exclusive      `fleet_sizing_exclusive_landings_by_node`'s own output.
#
# A node is a shrink candidate when all three hold at once: its
# idle-without-demand share of the window is at or above MIN_IDLE_SHARE, its
# share of the *fleet-wide* pool of contended claim losses is at or above
# MIN_CLAIM_LOST_SHARE, and its exclusive-landing count is at or below
# MAX_EXCLUSIVE_LANDINGS_FOR_SHRINK. All three, never any one alone: a node
# idle only because it joined the fleet an hour ago is not over-provisioned,
# and a node that loses every race it enters but still delivers exclusive
# work is earning its place regardless of how thin its idle time is.
#
# The whole verdict gates on the same insufficient-evidence discipline
# `constraint_classify` already keeps — below the minimum sample, or with
# fewer than two nodes (a shrink candidate needs a peer to have contended
# with, or "share of contended losses" cannot mean anything), `status` reads
# "insufficient-evidence" and `shrink_candidates` is `[]`, never a guess.
# shellcheck disable=SC2016  # jq's own $time_account/etc, not the shell's.
FLEET_SIZING_CLASSIFY_JQ='
  ($time_account.window // {from: null, to: null, seconds: 0}) as $window
  | ($time_account.nodes // []) as $nodes
  | ($time_account.by_node // {}) as $tbn
  | ($contention.by_node // {}) as $cbn
  | ($contention.fleet.contended_losses // 0) as $fleet_contended
  | ($exclusive // {}) as $ebn

  | ($window.seconds // 0) as $window_seconds
  | ($window.from == null) as $no_account
  | (if $no_account then true
     else ($window_seconds <= 0 or $window_seconds < $min_sample_seconds) end) as $below_sample
  | (($nodes | length) < 2) as $too_few_nodes

  | ($nodes | map(
        . as $node
        | ($tbn[$node]["idle-without-demand"] // 0) as $idle_s
        | (if $window_seconds > 0 then ($idle_s / $window_seconds) else null end) as $idle_share
        | ($cbn[$node].contended_losses // 0) as $cl
        | ($cbn[$node].selections // 0) as $sels
        | (if $fleet_contended > 0 then ($cl / $fleet_contended) else null end) as $cl_share
        | ($ebn[$node].exclusive // 0) as $excl
        | ($ebn[$node].landed // 0) as $landed_total
        | (($idle_share != null and $idle_share >= $min_idle_share)
           and ($cl_share != null and $cl_share >= $min_claim_lost_share)
           and ($excl <= $max_exclusive)) as $shrink
        | {
            node: $node,
            idle_without_demand_seconds: $idle_s,
            idle_share: (if $idle_share == null then null else ((($idle_share*1000)|round)/1000) end),
            claim_lost_contended: $cl,
            selections: $sels,
            claim_lost_share: (if $cl_share == null then null else ((($cl_share*1000)|round)/1000) end),
            exclusive_landings: $excl,
            total_landings: $landed_total,
            verdict: (if $shrink then "shrink-candidate" else "healthy" end),
            recommendation: (if $shrink then
                "remove " + $node + " from the fleet: " + (($idle_share*100|round)|tostring)
                + "% idle-without-demand this window, " + (($cl_share*100|round)|tostring)
                + "% share of fleet-wide contended claim losses, and " + ($excl|tostring)
                + " exclusive landing(s)"
              else null end),
            lever: (if $shrink then
                "node count: run fewer nodes, no cost in elapsed time"
              else
                "no action indicated: idle time and contention here are not both elevated, or exclusive delivery justifies the node"
              end)
          }
    )) as $by_node

  | ($by_node | map(select(.verdict == "shrink-candidate") | .node)) as $shrink_candidates

  | (if $no_account then "no-time-account-data"
     elif $below_sample then "window-below-minimum-sample"
     elif $too_few_nodes then "too-few-nodes"
     else null end) as $insufficient_reason
  | (if $insufficient_reason == null then "ok" else "insufficient-evidence" end) as $status

  | (if $insufficient_reason == "no-time-account-data" then
       "Insufficient evidence: no node time-state events recorded yet, so the time account (#597) has nothing to fold over this window."
     elif $insufficient_reason == "window-below-minimum-sample" then
       "Insufficient evidence: only " + ($window_seconds|tostring) + " second(s) observed this window, below the "
         + ($min_sample_seconds|tostring) + " minimum needed to judge fleet size."
     elif $insufficient_reason == "too-few-nodes" then
       "Insufficient evidence: " + ($nodes|length|tostring) + " node(s) recorded, and a shrink candidate needs at least one peer to have contended with."
     elif ($shrink_candidates | length) == 0 then
       "No node meets the shrink thresholds this window (idle-without-demand share at or above "
         + (($min_idle_share*100|round)|tostring) + "%, contended-claim-loss share at or above "
         + (($min_claim_lost_share*100|round)|tostring) + "%, at most " + ($max_exclusive|tostring)
         + " exclusive landing(s)); fleet size is not indicated as excessive by this measure."
     else
       "Fleet-sizing candidate(s) for shrinking: " + ($shrink_candidates | join(", "))
         + " (see by_node for the evidence behind each one)."
     end) as $sentence

  | {
      window: $window,
      nodes: $nodes,
      min_idle_share: $min_idle_share,
      min_claim_lost_share: $min_claim_lost_share,
      max_exclusive_landings_for_shrink: $max_exclusive,
      min_sample_seconds: $min_sample_seconds,
      status: $status,
      insufficient_reason: $insufficient_reason,
      sentence: $sentence,
      shrink_candidates: $shrink_candidates,
      by_node: $by_node
    }
'

# fleet_sizing_classify TIME_ACCOUNT_JSON CONTENTION_JSON EXCLUSIVE_JSON \
#   [MIN_IDLE_SHARE [MIN_CLAIM_LOST_SHARE [MAX_EXCLUSIVE_LANDINGS_FOR_SHRINK [MIN_SAMPLE_SECONDS]]]]
#
# Defaults (0.3, 0.3, 0, 14400) mirror `constraint_classify`'s own
# MIN_SHARE/MIN_SAMPLE_SECONDS defaults where the same shape of threshold
# applies, and set MAX_EXCLUSIVE_LANDINGS_FOR_SHRINK to 0 — "few exclusive
# landings" read at its strictest — for a caller that wants no threshold of
# its own.
fleet_sizing_classify() {
  local time_account_json="${1:-}" contention_json="${2:-}" exclusive_json="${3:-}" \
        min_idle_share="${4:-0.3}" min_claim_lost_share="${5:-0.3}" \
        max_exclusive="${6:-0}" min_sample_seconds="${7:-14400}"
  [[ -n "$time_account_json" ]] || time_account_json='{}'
  [[ -n "$contention_json" ]] || contention_json='{}'
  [[ -n "$exclusive_json" ]] || exclusive_json='{}'
  jq -nc \
    --argjson time_account "$time_account_json" \
    --argjson contention "$contention_json" \
    --argjson exclusive "$exclusive_json" \
    --argjson min_idle_share "$min_idle_share" \
    --argjson min_claim_lost_share "$min_claim_lost_share" \
    --argjson max_exclusive "$max_exclusive" \
    --argjson min_sample_seconds "$min_sample_seconds" \
    "$FLEET_SIZING_CLASSIFY_JQ" 2>/dev/null
}
