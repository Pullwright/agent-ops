#!/usr/bin/env bash
#
# lib/fleet-pricing.sh — "where do the tokens go?" (docs/ROADMAP.md D21/D14
# "Price the fleet and the tokens", issue #612). Two pure folds, both reading
# only what Phase 1's own accounts already produce — `counts.cost_rows[]`
# (issue #593/#594), `lib/rework-panel.sh`'s own rework-cycle classification
# (D23, issue #611) and `lib/item-lifecycle.sh`'s `item_lifecycle_fold`
# (issue #595) — never a second raw-event scan of their own:
#
#   fleet_pricing_spend_fate            the spend account split by fate
#                                        (delivered, rework, discarded,
#                                        overhead, defect-driven), reconciled
#                                        to the cent, with an explicit
#                                        `unaccounted` remainder for a row
#                                        that cannot yet be placed rather than
#                                        one dropped or guessed into a bucket.
#   fleet_pricing_turns_per_landed_item  `num_turns` per landed item, by
#                                        stage and model — the companion
#                                        figure to the Token economics panel's
#                                        prompt-cache ratio (issue #594),
#                                        which already answers "per stage and
#                                        model" for the *other* half of this
#                                        issue's "Done when" line.
#
# --- The fate mapping, defined and documented here since `cost_rows[]`
#     itself carries no such vocabulary (docs/METERING-SCHEMA.md's own
#     outcome ladder is an event-priority marker, not a fate) -------------
#
# Applied in this order, first match wins, so every row lands in exactly one
# bucket — never dropped, never double-counted:
#
#   1. overhead        `.attributed` is false (an Enabler/Refiner/limit-probe/
#                       project-reviewer row, or a coordinator/implementer/
#                       reviewer row whose own cycle carried no events in the
#                       union), OR `.repo`/`.item` are empty even though
#                       `.attributed` is true — a coordinator cycle that
#                       selected nothing (`none-selected`), stood down, was
#                       skipped, or simply ended, all of which are process
#                       cost with no item to attribute it to.
#   2. rework          the row's own `.cycle` appears in
#                       `lib/rework-panel.sh`'s own (undeduped — a cycle
#                       either had rework activity or it did not, the same
#                       "how much" cost-join reading `rework_panel_build`'s
#                       own header explains) `rework_cycles` set: D23's own
#                       classification decides this, never re-derived here.
#   3. defect_driven   `.outcome == "failed"` (the ladder's own
#                       `attempt-failed` event, reported as `"failed"` on
#                       `cost_rows[]` — docs/METERING-SCHEMA.md's own outcome
#                       ladder names the *event*; the row carries the
#                       shorter value the same jq that builds it actually
#                       emits) and not already claimed by rework above: the
#                       attempt itself errored — a crash, a timeout, an
#                       exception — which is a defect in the run, distinct
#                       from rework's *repeated*-attempt cost. A failed
#                       attempt that went on to a real second attempt is
#                       rework instead (rule 2 above already caught its
#                       cycle via the `stage-rerun` class), so this bucket is
#                       specifically the single-attempt failure.
#   4. delivered/      the row's {repo, item} terminal fate, read from
#      discarded/       `item_lifecycle_fold`'s own records: `landed` is
#      unaccounted       delivered value; `voided`/`superseded`/`abandoned`
#                       is spend on an item that never landed — discarded,
#                       not a defect, since voiding an item can be the
#                       correct call; anything else (`blocked`, `open`, an
#                       item lifecycle records as `unaccounted` itself, or an
#                       item this fold's own population never saw) is not
#                       yet resolved and lands in this account's own
#                       `unaccounted` bucket too — the honest reading is
#                       "come back once the item settles," never a forced
#                       guess between delivered and discarded.
#
# Reconciliation (D21's own invariant) is checked, not merely asserted:
# `reconciled` is true iff the sum of every bucket's `usd`, rounded to the
# cent, equals the sum of every row's own `usd` rounded the same way — the
# identical rounding #536 already uses when it reconciles `cost_rows[]`
# against `total_cost_usd`.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller owns those.

# shellcheck disable=SC2016  # jq's own $cost_rows/$rework_cycles/$lifecycle, not the shell's.
FLEET_PRICING_SPEND_FATE_JQ='
  def item_key($r; $i): (($r // "") | tostring) + "|" + (($i // "") | tostring);
  def round2(x): ((x * 100) | round) / 100;

  ($cost_rows // []) as $rows
  | ($rework_cycles // [] | map(tostring)) as $rw_cycles
  | ($lifecycle.records // []) as $records
  | ($records | map({key: item_key(.repo; .item), value: .fate}) | from_entries) as $fate_by_key

  | ($rows | map(
        . as $row
        | ((.cycle // "") | tostring) as $cyc
        | (((.repo // "") | tostring) != "" and ((.item // "") | tostring) != "") as $has_item
        | (if $has_item then ($fate_by_key[item_key(.repo; .item)] // null) else null end) as $item_fate
        | (if ((.attributed // false) | not) or ($has_item | not) then "overhead"
           elif ($rw_cycles | index($cyc)) != null then "rework"
           elif (.outcome // "") == "failed" then "defect_driven"
           elif $item_fate == "landed" then "delivered"
           elif ($item_fate == "voided" or $item_fate == "superseded" or $item_fate == "abandoned") then "discarded"
           else "unaccounted"
           end) as $fate
        | {fate: $fate, usd: (.usd // 0)}
    )) as $fated

  | ["delivered", "rework", "discarded", "overhead", "defect_driven", "unaccounted"] as $buckets
  | ($buckets | map(. as $b | {
        key: $b,
        value: {
          usd: round2([$fated[] | select(.fate == $b) | .usd] | add // 0),
          n: ([$fated[] | select(.fate == $b)] | length)
        }
      }) | from_entries) as $by_fate

  | ($rows | map(.usd // 0) | add // 0) as $total_usd
  | ($by_fate | [.[].usd] | add // 0) as $bucketed_usd
  | ((($total_usd * 100) | round) == (($bucketed_usd * 100) | round)) as $reconciled

  | {
      total_usd: round2($total_usd),
      row_count: ($rows | length),
      by_fate: $by_fate,
      reconciled: $reconciled,
      lever: {
        delivered: "reference baseline: spend that produced landed value; every other bucket'\''s share is read against this one, not itself a lever",
        rework: "D23'\''s own lever: fix the class or cause driving repeated attempts (the rework-by-class panel) to shrink this share without redoing delivered work",
        discarded: "item-selection judgement: spend on items voided, superseded or abandoned before landing; tighter candidate screening or needs-refinement review shrinks this",
        overhead: "cycle cadence and back-pressure caps, the same grow/shrink candidates lib/constraint.sh already names, not any one model or stage",
        defect_driven: "a single attempt errored outright; the lever is whatever crashed or timed out the stage, fixed at the stage or model level, distinct from rework'\''s repeated-attempt cost",
        unaccounted: "not yet resolved: the item this spend bought is still open or blocked, or the rare case its cycle union or lifecycle window lost the join; re-read once the item resolves"
      }
    }
'

# fleet_pricing_spend_fate COST_ROWS_FILE REWORK_CYCLES_JSON LIFECYCLE_FILE
#
# COST_ROWS_FILE holds `counts.cost_rows[]` verbatim; REWORK_CYCLES_JSON is a
# small JSON array of cycle-id strings (`rework_panel_build`'s own
# `rework_cycles` field); LIFECYCLE_FILE holds `item_lifecycle_fold`'s own
# output. The two files are read via `--slurpfile`, never captured into a
# bash variable of their own beyond what the caller already holds.
#
# Always succeeds: a missing/empty/unreadable file on either side prints the
# explicit outage shape below, never a confident "all zero" — the same
# "an outage is not a quiet zero" discipline `rework_panel_build` documents.
fleet_pricing_spend_fate() {
  local cost_rows_file="${1:-}" rework_cycles_json="${2:-}" lifecycle_file="${3:-}" out=""
  [[ -n "$rework_cycles_json" ]] || rework_cycles_json='[]'
  if [[ -n "$cost_rows_file" && -s "$cost_rows_file" && -n "$lifecycle_file" && -s "$lifecycle_file" ]]; then
    out="$(jq -nc --slurpfile cr "$cost_rows_file" --slurpfile lc "$lifecycle_file" \
      --argjson rework_cycles "$rework_cycles_json" \
      '($cr[0]) as $cost_rows | ($lc[0]) as $lifecycle | ('"$FLEET_PRICING_SPEND_FATE_JQ"')' 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='{"total_usd":null,"row_count":null,"by_fate":null,"reconciled":null,"lever":null}'
  printf '%s' "$out"
}

# shellcheck disable=SC2016  # jq's own $lifecycle, not the shell's.
FLEET_PRICING_TURNS_PER_LANDED_ITEM_JQ='
  def percentile($p; $arr):
    ($arr | sort) as $s
    | ($s | length) as $n
    | if $n == 0 then null
      else
        (($n - 1) * $p) as $idx
        | ($idx | floor) as $lo
        | ($idx | ceil) as $hi
        | if $lo == $hi then $s[$lo]
          else $s[$lo] + ($idx - $lo) * ($s[$hi] - $s[$lo])
          end
      end;

  ($lifecycle.records // []) as $records
  | ($records | map(select(.fate == "landed"))) as $landed
  | ($landed | map(select(
        ([.instants[] | select(.event == "stage-end" and (.fields.num_turns != null))] | length) > 0
      ))) as $landed_with_turns
  | ($landed_with_turns | map(
        .instants[]
        | select(.event == "stage-end" and (.fields.num_turns != null) and (.fields.stage != null))
        | {stage: .fields.stage, model: (.fields.model // "unknown"), num_turns: .fields.num_turns}
    )) as $rows
  | ($rows | group_by([.stage, .model])
      | map({
          stage: .[0].stage, model: .[0].model, n: length,
          mean_turns: ((((map(.num_turns) | add) / length) * 100 | round) / 100),
          median_turns: percentile(0.5; map(.num_turns))
        })
      | sort_by([.stage, .model])) as $by_stage_model
  | {
      n_landed_total: ($landed | length),
      n_landed_with_turns: ($landed_with_turns | length),
      by_stage_model: $by_stage_model,
      lever: "turns per landed item, by stage and model: a model taking materially more turns than a peer for the same stage on the same class of work is a prompt or tool-loop inefficiency to fix at the model or prompt level (D22), before the token spend it drives is treated as a volume problem"
    }
'

# fleet_pricing_turns_per_landed_item LIFECYCLE_FILE
#
# Reads `item_lifecycle_fold`'s own `records[].instants[]` (never the raw log
# a second time — every `stage-end` an item's own history carries is already
# there, `num_turns`/`stage`/`model` included, since `instants[].fields` is
# the event with only `event`/`ts`/`node`/`cycle`/`repo`/`item` stripped).
# Only a landed item with at least one stage-end whose `num_turns` was
# actually measured contributes a row — `n_landed_with_turns` reports that
# population separately from `n_landed_total` so a low sample never reads as
# a low landing count.
#
# The Co-Ordinator's own stage-end typically carries no {repo, item} of its
# own (its stage spans selecting, not one item's work), so its turns are not
# counted here — the same limitation the actor/model scorecards already
# accept for the identical reason (see scripts/publish-dashboard.sh's own
# scorecard header): a multi-item engagement's turns cannot be attributed to
# one specific item without a different join this figure does not build.
#
# Always succeeds, on the same explicit-outage discipline as
# `fleet_pricing_spend_fate` above.
fleet_pricing_turns_per_landed_item() {
  local lifecycle_file="${1:-}" out=""
  if [[ -n "$lifecycle_file" && -s "$lifecycle_file" ]]; then
    out="$(jq -nc --slurpfile lc "$lifecycle_file" \
      '($lc[0]) as $lifecycle | ('"$FLEET_PRICING_TURNS_PER_LANDED_ITEM_JQ"')' 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='{"n_landed_total":null,"n_landed_with_turns":null,"by_stage_model":null,"lever":null}'
  printf '%s' "$out"
}
