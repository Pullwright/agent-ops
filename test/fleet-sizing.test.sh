#!/usr/bin/env bash
#
# test/fleet-sizing.test.sh — regression test for lib/fleet-sizing.sh
# (docs/ROADMAP.md D21/D14 "Price the fleet and the tokens", issue #612).
#
# What matters here, one section per function:
#
#   fleet_sizing_contention_by_node   the identical selection/contended-
#                                     claim-lost population
#                                     scripts/pickup-metrics.sh already
#                                     counts, grouped by node instead of by
#                                     adoption era.
#   fleet_sizing_exclusive_landings_by_node
#                                     a landed item with no competing
#                                     claim-lost from another node is
#                                     exclusive to its landing node; one
#                                     contested by a peer is not, however
#                                     many nodes eventually claimed it.
#   fleet_sizing_classify             the demonstration this issue's own
#                                     acceptance criterion asks for: one
#                                     over-provisioned node (high idle time,
#                                     high contended-loss share, no exclusive
#                                     landings) and one healthy node, and the
#                                     fold must be willing to recommend
#                                     shrinking the fleet by naming the first
#                                     one — plus the insufficient-evidence
#                                     gates on the same terms
#                                     constraint_classify already keeps.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/fleet-sizing.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/item-lifecycle.sh
. "$SCRIPT_DIR/lib/item-lifecycle.sh"
# shellcheck source=lib/fleet-sizing.sh
. "$SCRIPT_DIR/lib/fleet-sizing.sh"

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
# fleet_sizing_contention_by_node
# =============================================================================

contention_log="$tmp_dir/contention.jsonl"
cat > "$contention_log" <<'EOF'
{"ts":"2026-01-01T00:00:01Z","node":"n1","event":"selection","repo":"r","item":"1"}
{"ts":"2026-01-01T00:00:02Z","node":"n2","event":"selection","repo":"r","item":"2"}
{"ts":"2026-01-01T00:00:03Z","node":"n1","event":"claim-lost","cause":"held","repo":"r","item":"2"}
{"ts":"2026-01-01T00:00:04Z","node":"n2","event":"claim-lost","cause":"unreachable","repo":"r","item":"3"}
{"ts":"2026-01-01T00:00:05Z","node":"n2","event":"claim-lost","cause":"pr-held","repo":"r","item":"4"}
not valid json at all
EOF

cont_out="$(fleet_sizing_contention_by_node "$contention_log")"
assert_eq "fleet selections: n1's one, n2's one" "2" "$(jq -r '.fleet.selections' <<<"$cont_out")"
assert_eq "fleet contended_losses: n1's held, n2's pr-held (unreachable excluded)" \
  "2" "$(jq -r '.fleet.contended_losses' <<<"$cont_out")"
assert_eq "n1: 1 selection, 1 contended loss (held)" \
  '{"contended_losses":1,"ratio":1,"selections":1}' \
  "$(jq -Sc '.by_node.n1' <<<"$cont_out")"
assert_eq "n2: 1 selection, 1 contended loss (pr-held; unreachable excluded)" \
  '{"contended_losses":1,"ratio":1,"selections":1}' \
  "$(jq -Sc '.by_node.n2' <<<"$cont_out")"
assert_eq "a missing log reports the all-empty shape, not a crash" \
  '{"contended_losses":0,"ratio":null,"selections":0}' \
  "$(jq -Sc '.fleet' <<<"$(fleet_sizing_contention_by_node "$tmp_dir/does-not-exist.jsonl")")"

since_out="$(fleet_sizing_contention_by_node "$contention_log" "2026-01-01T00:00:02Z")"
assert_eq "since bound excludes n1's earlier selection, keeps n2's" \
  "1" "$(jq -r '.fleet.selections' <<<"$since_out")"

# =============================================================================
# fleet_sizing_exclusive_landings_by_node
# =============================================================================
#
# item 1: n1 claims and lands it, no other node ever contends — exclusive.
# item 2: n2 lands it, but n1 logged a claim-lost on the same item —
#         contested, not exclusive, however many nodes eventually landed it.
# item 3: n1 claims it, abandoned draft resumed later by n1 again (two
#         selection events, same node) and lands — the last selection's own
#         node is what counts, and it is still exclusive since no peer ever
#         contended for it.
# item 4: open (no merge-observed at all) — excluded from both landed counts
#         entirely, on the same "population, never fate" terms
#         item_lifecycle_fold's own header already documents.

exclusive_log="$tmp_dir/exclusive.jsonl"
cat > "$exclusive_log" <<'EOF'
{"ts":"2026-01-01T00:00:01Z","node":"n1","event":"selection","repo":"r","item":"1"}
{"ts":"2026-01-01T00:00:02Z","node":"n1","event":"merge-observed","repo":"r","item":"1"}
{"ts":"2026-01-02T00:00:01Z","node":"n2","event":"selection","repo":"r","item":"2"}
{"ts":"2026-01-02T00:00:02Z","node":"n1","event":"claim-lost","cause":"held","repo":"r","item":"2"}
{"ts":"2026-01-02T00:00:03Z","node":"n2","event":"merge-observed","repo":"r","item":"2"}
{"ts":"2026-01-03T00:00:01Z","node":"n1","event":"selection","repo":"r","item":"3"}
{"ts":"2026-01-03T00:00:02Z","node":"n1","event":"selection","repo":"r","item":"3"}
{"ts":"2026-01-03T00:00:03Z","node":"n1","event":"merge-observed","repo":"r","item":"3"}
{"ts":"2026-01-04T00:00:01Z","node":"n2","event":"selection","repo":"r","item":"4"}
EOF

lifecycle_file="$tmp_dir/lifecycle.json"
item_lifecycle_fold "$exclusive_log" "" > "$lifecycle_file"

excl_out="$(fleet_sizing_exclusive_landings_by_node "$lifecycle_file")"
assert_eq "n1: 2 landed (items 1, 3), both exclusive" \
  '{"exclusive":2,"landed":2}' "$(jq -Sc '.n1' <<<"$excl_out")"
assert_eq "n2: 1 landed (item 2), not exclusive (n1 contended for it)" \
  '{"exclusive":0,"landed":1}' "$(jq -Sc '.n2' <<<"$excl_out")"
assert_eq "a missing lifecycle file reports {}, never a crash" \
  '{}' "$(fleet_sizing_exclusive_landings_by_node "$tmp_dir/does-not-exist.json")"

# =============================================================================
# fleet_sizing_classify — the demonstration this issue's acceptance
# criterion asks for: one over-provisioned node, one healthy node
# =============================================================================

time_account='{
  "window": {"from": "2026-01-01T00:00:00Z", "to": "2026-01-08T00:00:00Z", "seconds": 604800},
  "nodes": ["over", "healthy"],
  "by_node": {
    "over":    {"idle-without-demand": 500000},
    "healthy": {"idle-without-demand": 1000}
  }
}'
contention='{
  "fleet": {"contended_losses": 100},
  "by_node": {
    "over":    {"selections": 10,  "contended_losses": 80},
    "healthy": {"selections": 200, "contended_losses": 20}
  }
}'
exclusive='{
  "over":    {"landed": 1,  "exclusive": 0},
  "healthy": {"landed": 50, "exclusive": 30}
}'

out="$(fleet_sizing_classify "$time_account" "$contention" "$exclusive")"
assert_eq "status is ok (sufficient window, at least two nodes)" \
  "ok" "$(jq -r '.status' <<<"$out")"
assert_eq "shrink_candidates names exactly the over-provisioned node" \
  '["over"]' "$(jq -c '.shrink_candidates' <<<"$out")"
assert_eq "over: verdict is shrink-candidate" \
  "shrink-candidate" "$(jq -r '.by_node[] | select(.node=="over") | .verdict' <<<"$out")"
assert_eq "over: idle_share is 500000/604800, rounded to 3 places" \
  "0.827" "$(jq -r '.by_node[] | select(.node=="over") | .idle_share' <<<"$out")"
assert_eq "over: claim_lost_share is 80/100 (its share of the fleet-wide pool)" \
  "0.8" "$(jq -r '.by_node[] | select(.node=="over") | .claim_lost_share' <<<"$out")"
assert_eq "over: the recommendation names the node" \
  "true" "$(jq -r '.by_node[] | select(.node=="over") | .recommendation | test("over")' <<<"$out")"
assert_eq "over: the lever is node count / run fewer nodes, in as many words" \
  "true" "$(jq -r '.by_node[] | select(.node=="over") | .lever | test("fewer nodes")' <<<"$out")"
assert_eq "healthy: verdict is healthy" \
  "healthy" "$(jq -r '.by_node[] | select(.node=="healthy") | .verdict' <<<"$out")"
assert_eq "healthy: no recommendation" \
  "null" "$(jq -c '.by_node[] | select(.node=="healthy") | .recommendation' <<<"$out")"
assert_eq "the sentence names the shrink candidate" \
  "true" "$(jq -r '.sentence | test("over")' <<<"$out")"

# --- A node with high idle and high contention but real exclusive delivery
#     must not be recommended for removal ------------------------------------

exclusive_but_busy='{
  "over":    {"landed": 5,  "exclusive": 3},
  "healthy": {"landed": 50, "exclusive": 30}
}'
out_busy="$(fleet_sizing_classify "$time_account" "$contention" "$exclusive_but_busy" 0.3 0.3 0)"
assert_eq "with 3 exclusive landings and max_exclusive 0, over is no longer a candidate" \
  '[]' "$(jq -c '.shrink_candidates' <<<"$out_busy")"
out_relaxed="$(fleet_sizing_classify "$time_account" "$contention" "$exclusive_but_busy" 0.3 0.3 3)"
assert_eq "raising max_exclusive to 3 makes it a candidate again" \
  '["over"]' "$(jq -c '.shrink_candidates' <<<"$out_relaxed")"

# --- No shrink candidate: idle time is low on both nodes, however contended
#     the fleet is — idle share and contention share must both clear their
#     threshold, neither alone is enough ------------------------------------

low_idle_account='{
  "window": {"from": "2026-01-01T00:00:00Z", "to": "2026-01-08T00:00:00Z", "seconds": 604800},
  "nodes": ["over", "healthy"],
  "by_node": {
    "over":    {"idle-without-demand": 1000},
    "healthy": {"idle-without-demand": 500}
  }
}'
out_none="$(fleet_sizing_classify "$low_idle_account" "$contention" "$exclusive")"
assert_eq "no shrink candidate when idle time is low on every node" \
  '[]' "$(jq -c '.shrink_candidates' <<<"$out_none")"
assert_eq "status is still ok — no candidate is a real verdict, not a missing one" \
  "ok" "$(jq -r '.status' <<<"$out_none")"
assert_eq "the sentence says so in as many words" \
  "true" "$(jq -r '.sentence | test("not indicated as excessive")' <<<"$out_none")"

# =============================================================================
# Insufficient-evidence gates
# =============================================================================

no_account='{"window":{"from":null,"to":null,"seconds":0},"nodes":[],"by_node":{}}'
out_no_account="$(fleet_sizing_classify "$no_account" '{}' '{}')"
assert_eq "no time account: status is insufficient-evidence" \
  "insufficient-evidence" "$(jq -r '.status' <<<"$out_no_account")"
assert_eq "  ... reason is no-time-account-data" \
  "no-time-account-data" "$(jq -r '.insufficient_reason' <<<"$out_no_account")"

thin_account='{"window":{"from":"2026-01-01T00:00:00Z","to":"2026-01-01T00:05:00Z","seconds":300},"nodes":["over","healthy"],"by_node":{}}'
out_thin="$(fleet_sizing_classify "$thin_account" "$contention" "$exclusive" 0.3 0.3 0 14400)"
assert_eq "window below minimum sample: insufficient-evidence" \
  "insufficient-evidence" "$(jq -r '.status' <<<"$out_thin")"
assert_eq "  ... reason is window-below-minimum-sample" \
  "window-below-minimum-sample" "$(jq -r '.insufficient_reason' <<<"$out_thin")"

one_node_account='{"window":{"from":"2026-01-01T00:00:00Z","to":"2026-01-08T00:00:00Z","seconds":604800},"nodes":["solo"],"by_node":{"solo":{"idle-without-demand":500000}}}'
out_one="$(fleet_sizing_classify "$one_node_account" '{"fleet":{"contended_losses":0},"by_node":{}}' '{}')"
assert_eq "a single node: insufficient-evidence (no peer to contend with)" \
  "insufficient-evidence" "$(jq -r '.status' <<<"$out_one")"
assert_eq "  ... reason is too-few-nodes" \
  "too-few-nodes" "$(jq -r '.insufficient_reason' <<<"$out_one")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
