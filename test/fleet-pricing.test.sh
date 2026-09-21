#!/usr/bin/env bash
#
# test/fleet-pricing.test.sh — regression test for lib/fleet-pricing.sh
# (docs/ROADMAP.md D21/D14 "Price the fleet and the tokens", issue #612).
#
# What matters here, one section per function:
#
#   fleet_pricing_spend_fate         every cost_rows[] row lands in exactly
#                                    one of six buckets (delivered, rework,
#                                    discarded, overhead, defect_driven,
#                                    unaccounted), the sum reconciles to the
#                                    cent against the rows' own total, and
#                                    the priority order (rework beats
#                                    outcome, outcome beats terminal fate) is
#                                    exercised on a row that could otherwise
#                                    read two different ways. REWORK_CYCLES_FILE
#                                    holding JSON `null` (rework_panel_build's
#                                    own outage shape) reports the outage
#                                    shape rather than computing against an
#                                    empty rework set (issue #1691), and a
#                                    rework-bearing-cycles count large enough
#                                    that the old `--argjson` form would have
#                                    been a size concern still classifies
#                                    correctly via `--slurpfile`.
#   fleet_pricing_turns_per_landed_item
#                                    num_turns averaged per (stage, model)
#                                    over landed items only, with the
#                                    zero-turns-measured population reported
#                                    separately from the landed total.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/fleet-pricing.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/item-lifecycle.sh
. "$SCRIPT_DIR/lib/item-lifecycle.sh"
# shellcheck source=lib/fleet-pricing.sh
. "$SCRIPT_DIR/lib/fleet-pricing.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# =============================================================================
# fleet_pricing_spend_fate
# =============================================================================
#
# item 1: landed, its own cycle (c1) never mentioned by rework — delivered.
# item 2: voided, its own cycle (c2) never mentioned by rework — discarded.
# item 3: never appears in the lifecycle log at all, outcome "failed" —
#         defect_driven takes priority over the unresolved-item fallback.
# item 4: landed, but its cycle (c4) IS in rework_cycles — rework wins over
#         the item's own terminal fate, on purpose: the priority order is
#         rework, then outcome, then terminal fate, never the reverse.
# c5: attributed but no repo/item at all (a coordinator cycle that found
#     nothing to select) — overhead, despite `attributed: true`.
# c6: attributed false outright (an Enabler/Refiner/project-reviewer row) —
#     overhead for the same reason, the more common path there.
# c7: attributed, repo/item set, but the item is still open in the
#     lifecycle fold (no merge/void/etc yet) — unaccounted: not yet
#     resolved, not a guess between delivered and discarded.

fate_log="$tmp_dir/fate.jsonl"
cat > "$fate_log" <<'EOF'
{"ts":"2026-01-01T00:00:01Z","node":"n1","cycle":"c1","event":"selection","repo":"r","item":"1"}
{"ts":"2026-01-01T00:00:02Z","node":"n1","cycle":"c1","event":"merge-observed","repo":"r","item":"1"}
{"ts":"2026-01-02T00:00:01Z","node":"n1","cycle":"c2","event":"selection","repo":"r","item":"2"}
{"ts":"2026-01-02T00:00:02Z","node":"n1","cycle":"c2","event":"item-void","repo":"r","item":"2"}
{"ts":"2026-01-03T00:00:01Z","node":"n1","cycle":"c4","event":"selection","repo":"r","item":"4"}
{"ts":"2026-01-03T00:00:02Z","node":"n1","cycle":"c4","event":"merge-observed","repo":"r","item":"4"}
{"ts":"2026-01-04T00:00:01Z","node":"n1","cycle":"c7","event":"selection","repo":"r","item":"7"}
EOF

lifecycle_file="$tmp_dir/lifecycle.json"
item_lifecycle_fold "$fate_log" "" > "$lifecycle_file"

cost_rows_file="$tmp_dir/cost-rows.json"
cat > "$cost_rows_file" <<'EOF'
[
  {"cycle":"c1","repo":"r","item":"1","outcome":"pr-ready",    "attributed":true,  "usd":10.00},
  {"cycle":"c2","repo":"r","item":"2","outcome":"pr-raised",   "attributed":true,  "usd":5.25},
  {"cycle":"c3","repo":"r","item":"3","outcome":"failed",      "attributed":true,  "usd":3.10},
  {"cycle":"c4","repo":"r","item":"4","outcome":"pr-ready",    "attributed":true,  "usd":7.00},
  {"cycle":"c5","repo":null,"item":null,"outcome":"none-selected","attributed":true,"usd":0.40},
  {"cycle":"c6","repo":null,"item":null,"outcome":null,        "attributed":false, "usd":1.85},
  {"cycle":"c7","repo":"r","item":"7","outcome":"selected",    "attributed":true,  "usd":2.00}
]
EOF

rework_cycles_file="$tmp_dir/rework-cycles.json"
printf '%s' '["c4"]' > "$rework_cycles_file"
out="$(fleet_pricing_spend_fate "$cost_rows_file" "$rework_cycles_file" "$lifecycle_file")"

assert_eq "total_usd is the sum of every row (10+5.25+3.10+7+0.40+1.85+2)" \
  "29.6" "$(jq -r '.total_usd' <<<"$out")"
assert_eq "row_count is 7" "7" "$(jq -r '.row_count' <<<"$out")"
assert_eq "reconciled is true: the six buckets sum back to total_usd to the cent" \
  "true" "$(jq -r '.reconciled' <<<"$out")"

assert_eq "delivered: item 1 alone (item 4 is claimed by rework instead)" \
  '{"n":1,"usd":10}' "$(jq -Sc '.by_fate.delivered' <<<"$out")"
assert_eq "rework: item 4, because its cycle is in rework_cycles, despite landing" \
  '{"n":1,"usd":7}' "$(jq -Sc '.by_fate.rework' <<<"$out")"
assert_eq "discarded: item 2 (voided)" \
  '{"n":1,"usd":5.25}' "$(jq -Sc '.by_fate.discarded' <<<"$out")"
assert_eq "overhead: c5 (attributed, no item) + c6 (unattributed) = 0.40+1.85" \
  '{"n":2,"usd":2.25}' "$(jq -Sc '.by_fate.overhead' <<<"$out")"
assert_eq "defect_driven: item 3, outcome failed, not claimed by rework" \
  '{"n":1,"usd":3.1}' "$(jq -Sc '.by_fate.defect_driven' <<<"$out")"
assert_eq "unaccounted: item 7, still open in the lifecycle fold" \
  '{"n":1,"usd":2}' "$(jq -Sc '.by_fate.unaccounted' <<<"$out")"

assert_eq "every bucket names the decision it informs (the lever rule, D21)" \
  "6" "$(jq -r '[.lever[] | select(type == "string" and length > 0)] | length' <<<"$out")"

# Sub-cent rows are the common case, not an edge one: a cost_rows[] row is
# one model's share of one transcript, and three of them at half a cent each
# is enough to break a reconciliation that rounds every bucket before summing
# the six (each rounds up to a full cent, so the buckets read 0.03 against a
# 0.015 total). The invariant must be judged on the unrounded arithmetic and
# rounded exactly once, or the panel calls a perfectly partitioned account a
# bug.
subcent_rows="$tmp_dir/subcent-rows.json"
cat > "$subcent_rows" <<'EOF'
[
  {"cycle":"c1","repo":"r","item":"1","outcome":"pr-ready","attributed":true, "usd":0.005},
  {"cycle":"c6","repo":null,"item":null,"outcome":null,   "attributed":false,"usd":0.005},
  {"cycle":"c3","repo":"r","item":"3","outcome":"failed",  "attributed":true, "usd":0.005}
]
EOF
empty_rework_file="$tmp_dir/empty-rework.json"
printf '%s' '[]' > "$empty_rework_file"

subcent_out="$(fleet_pricing_spend_fate "$subcent_rows" "$empty_rework_file" "$lifecycle_file")"
assert_eq "sub-cent rows spread over three buckets still reconcile (rounded once, at the end)" \
  "true" "$(jq -r '.reconciled' <<<"$subcent_out")"

assert_eq "an empty cost_rows file reconciles trivially (0 == 0)" \
  "true" "$(jq -r '.reconciled' <<<"$(fleet_pricing_spend_fate "$(printf '%s' '[]' > "$tmp_dir/empty-rows.json"; echo "$tmp_dir/empty-rows.json")" "$empty_rework_file" "$lifecycle_file")")"

assert_eq "a missing cost_rows file reports the outage shape, never a quiet zero" \
  "null" "$(jq -c '.reconciled' <<<"$(fleet_pricing_spend_fate "$tmp_dir/does-not-exist.json" "$empty_rework_file" "$lifecycle_file")")"

# A rework_panel_build outage (rework_cycles: null) must not coalesce to an
# empty rework set and compute a confident, reconciled account — issue #1691.
# Reuse the fate_log fixture above: without the outage, item 4's cycle (c4)
# is claimed by rework; with a null rework_cycles_file, nothing should be
# computed at all.
null_rework_file="$tmp_dir/null-rework.json"
printf 'null' > "$null_rework_file"
outage_out="$(fleet_pricing_spend_fate "$cost_rows_file" "$null_rework_file" "$lifecycle_file")"
assert_eq "a null rework_cycles_file (rework_panel_build's own outage shape) reports the spend-fate outage shape, never a computed account" \
  '{"by_fate":null,"lever":null,"reconciled":null,"row_count":null,"total_usd":null}' \
  "$(jq -Sc '.' <<<"$outage_out")"

assert_eq "a missing rework_cycles_file reports the outage shape too, never a quiet []" \
  "null" "$(jq -c '.reconciled' <<<"$(fleet_pricing_spend_fate "$cost_rows_file" "$tmp_dir/does-not-exist-rework.json" "$lifecycle_file")")"

# A rework-bearing-cycles count large enough that the old `--argjson` form
# would have been a correctness/size concern (issue #1691, requirement 4g's
# own class — the 2026-08-14 MAX_ARG_STRLEN outage): confirm the --slurpfile
# path still classifies correctly at this size, and still reconciles.
#
# The cycle ids here are the shape a real one has (`<stamp>-<node>-<pid>`,
# ~39 bytes), not a short synthetic one, because the size is the whole point:
# execve's per-argument ceiling is MAX_ARG_STRLEN, 32 pages — 131072 bytes on
# every Linux this runs on — and it is a cap on one argument's own length, so
# ARG_MAX's much larger total says nothing about it. 5000 ids of this shape
# serialise past that ceiling; 5000 short ones would not, and would leave this
# case asserting a claim it never actually exercised. The guard below checks
# that rather than trusting the arithmetic to stay true.
large_rework_rows="$tmp_dir/large-rework-rows.json"
large_rework_cycles="$tmp_dir/large-rework-cycles.json"
jq -nc '[range(0; 5000) | {cycle: ("20260919T111823Z-ockham-container-" + (. | tostring)), repo: "r", item: ("b" + (. | tostring)), outcome: "pr-ready", attributed: true, usd: 0.01}]' \
  > "$large_rework_rows"
jq -nc '[range(0; 5000) | ("20260919T111823Z-ockham-container-" + (. | tostring))]' > "$large_rework_cycles"
assert_eq "the fixture really is past execve's 131072-byte per-argument ceiling, so the old --argjson form could not have carried it" \
  "1" "$(( $(wc -c < "$large_rework_cycles") > 131072 ))"
large_out="$(fleet_pricing_spend_fate "$large_rework_rows" "$large_rework_cycles" "$lifecycle_file")"
assert_eq "5000 rework-bearing cycles (well past the old argv-size concern) all classify as rework" \
  '{"n":5000,"usd":50}' "$(jq -Sc '.by_fate.rework' <<<"$large_out")"
assert_eq "the large rework set still reconciles to the cent" \
  "true" "$(jq -r '.reconciled' <<<"$large_out")"

# =============================================================================
# fleet_pricing_turns_per_landed_item
# =============================================================================
#
# item 1: implementer/m1 num_turns 5, reviewer/m2 num_turns 3 — landed.
# item 2: implementer/m1 num_turns 9 — landed; averaged with item 1's 5 for
#         implementer/m1 (mean 7).
# item 3: open (never merges) — excluded from n_landed_total entirely.
# item 4: landed, but its own stage-end carries no num_turns at all — counts
#         toward n_landed_total, not toward n_landed_with_turns, and
#         contributes no row.

turns_log="$tmp_dir/turns.jsonl"
cat > "$turns_log" <<'EOF'
{"ts":"2026-01-01T00:00:01Z","node":"n1","cycle":"c1","event":"selection","repo":"r","item":"1"}
{"ts":"2026-01-01T00:00:02Z","node":"n1","cycle":"c1","event":"stage-end","stage":"implementer","model":"m1","num_turns":5,"repo":"r","item":"1"}
{"ts":"2026-01-01T00:00:03Z","node":"n1","cycle":"c1","event":"stage-end","stage":"reviewer","model":"m2","num_turns":3,"repo":"r","item":"1"}
{"ts":"2026-01-01T00:00:04Z","node":"n1","cycle":"c1","event":"merge-observed","repo":"r","item":"1"}
{"ts":"2026-01-02T00:00:01Z","node":"n1","cycle":"c2","event":"selection","repo":"r","item":"2"}
{"ts":"2026-01-02T00:00:02Z","node":"n1","cycle":"c2","event":"stage-end","stage":"implementer","model":"m1","num_turns":9,"repo":"r","item":"2"}
{"ts":"2026-01-02T00:00:03Z","node":"n1","cycle":"c2","event":"merge-observed","repo":"r","item":"2"}
{"ts":"2026-01-03T00:00:01Z","node":"n1","cycle":"c3","event":"selection","repo":"r","item":"3"}
{"ts":"2026-01-04T00:00:01Z","node":"n1","cycle":"c4","event":"selection","repo":"r","item":"4"}
{"ts":"2026-01-04T00:00:02Z","node":"n1","cycle":"c4","event":"stage-end","stage":"implementer","model":"m1","repo":"r","item":"4"}
{"ts":"2026-01-04T00:00:03Z","node":"n1","cycle":"c4","event":"merge-observed","repo":"r","item":"4"}
EOF

turns_lifecycle="$tmp_dir/turns-lifecycle.json"
item_lifecycle_fold "$turns_log" "" > "$turns_lifecycle"

turns_out="$(fleet_pricing_turns_per_landed_item "$turns_lifecycle")"
assert_eq "n_landed_total counts items 1, 2, 4 (item 3 is open)" \
  "3" "$(jq -r '.n_landed_total' <<<"$turns_out")"
assert_eq "n_landed_with_turns excludes item 4 (its stage-end carries no num_turns)" \
  "2" "$(jq -r '.n_landed_with_turns' <<<"$turns_out")"
assert_eq "implementer/m1: mean of 5 and 9 is 7, over 2 samples" \
  '{"mean_turns":7,"median_turns":7,"model":"m1","n":2,"stage":"implementer"}' \
  "$(jq -Sc '.by_stage_model[] | select(.stage=="implementer" and .model=="m1")' <<<"$turns_out")"
assert_eq "reviewer/m2: one sample, mean and median both 3" \
  '{"mean_turns":3,"median_turns":3,"model":"m2","n":1,"stage":"reviewer"}' \
  "$(jq -Sc '.by_stage_model[] | select(.stage=="reviewer")' <<<"$turns_out")"
assert_eq "names the decision it informs (the lever rule, D21)" \
  "true" "$(jq -r '.lever | test("D22")' <<<"$turns_out")"

assert_eq "a missing lifecycle file reports the outage shape, never a quiet zero" \
  "null" "$(jq -c '.n_landed_total' <<<"$(fleet_pricing_turns_per_landed_item "$tmp_dir/does-not-exist.json")")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
