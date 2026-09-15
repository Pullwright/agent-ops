#!/usr/bin/env bash
#
# test/node-health-cli.test.sh — scripts/node-health.sh (issue #608):
# properties the pure lib/node-health.sh tests (test/node-health.test.sh)
# cannot exercise, because they live in what the CLI gathers rather than in
# how it composes a verdict:
#
#   - it is genuinely read-only (acceptance 2): a fixture state dir is
#     unchanged, byte for byte, by every mode except the one cache file the
#     header itself documents.
#   - the three verdicts really are independent end to end (acceptance 3):
#     a fixture built to be live, not-ready and unhealthy all at once
#     answers all three correctly from one CLI, not just from the library
#     call the other test drives directly.
#   - liveness never reads the cycle lock (acceptance 6): live while a lock
#     file is present and held.
#   - exit codes match each verdict.
#
# Never reaches the network: HOME/CLAUDE_CONFIG_DIR point at a fixture
# directory with no credentials, and GH_TOKEN/GITHUB_TOKEN are cleared so
# `gh` refuses locally (github_auth_probe's own "no token present" path)
# rather than making a real call.
#
# Run directly: ./test/node-health-cli.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$SCRIPT_DIR/scripts/node-health.sh"

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

state_dir="$tmp_dir/state"
ws="$tmp_dir/ws"
mkdir -p "$state_dir" "$ws/.agent-ops-state"
config="$tmp_dir/config.json"
jq -nc --arg sd "$state_dir" --arg wr "$ws" '{state_dir:$sd, workspace_root:$wr}' > "$config"

# No credentials, no gh token: every call this suite makes must resolve
# without ever reaching the network.
export HOME="$tmp_dir/home"
mkdir -p "$HOME"
export CLAUDE_CONFIG_DIR="$tmp_dir/claude-config"
unset GH_TOKEN GITHUB_TOKEN 2>/dev/null || true

run() { "$CLI" --config "$config" --state-dir "$state_dir" "$@"; }

# --- Read-only (acceptance 2) --------------------------------------------

snapshot() { find "$state_dir" "$ws" -type f -not -name '.node-health-ratelimit-cache.json' \
  -exec sh -c 'printf "%s " "$1"; md5sum < "$1"' _ {} \; | sort; }

before="$(snapshot)"
run --live  >/dev/null
run --ready >/dev/null
run --health >/dev/null
run --metrics >/dev/null
after="$(snapshot)"
assert_eq "the CLI writes nothing under state_dir/workspace_root except its own rate-limit cache" \
  "$before" "$after"

# --- live/ready/health diverge independently from one CLI (acceptance 3) --

touch "$state_dir/.node-alive"
echo '{"reason":"maintenance test","expires_at":null,"by":"test","disabled_at":"2026-09-01T00:00:00Z"}' \
  > "$state_dir/disabled.json"
cat > "$ws/.agent-ops-state/heartbeat.json" <<'EOF'
{"updater":{"status":"stuck","at":"2026-09-01T00:00:00Z","seconds":90000,"reason":"allow"},
 "image":{"status":"current","checked_at":"2026-09-15T00:00:00Z"}}
EOF
echo '{"ts":"2026-08-01T00:00:00Z"}' > "$state_dir/.state-sync-published.json"

live_out="$(run --live)";     live_rc=$?
ready_out="$(run --ready)";   ready_rc=$?
health_out="$(run --health)"; health_rc=$?

assert_eq "live is true"    "true"  "$(jq -r '.live'   <<<"$live_out")"
assert_eq "live exit is 0"  "0"     "$live_rc"
assert_eq "ready is false"  "false" "$(jq -r '.ready'  <<<"$ready_out")"
assert_eq "ready exit is 1" "1"     "$ready_rc"
assert_eq "ready names node-disabled" "true" \
  "$(jq '[.unmet[].code] | index("node-disabled") != null' <<<"$ready_out")"
assert_eq "health is fail"  "fail"  "$(jq -r '.status'  <<<"$health_out")"
assert_eq "health exit is 1" "1"    "$health_rc"

rm -f "$state_dir/disabled.json"

# --- Liveness never reads the cycle lock (acceptance 6) -------------------

echo "{\"pid\":$$,\"started_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"host\":\"$(hostname 2>/dev/null || echo h)\"}" \
  > "$state_dir/lock.json"
live_with_lock="$(run --live)"
assert_eq "live stays true while a cycle holds the lock" "true" "$(jq -r '.live' <<<"$live_with_lock")"
rm -f "$state_dir/lock.json"

rm -f "$state_dir/.node-alive"
live_without_marker="$(run --live)"; live_without_marker_rc=$?
assert_eq "an aged-out marker (removed here) is not live" "false" "$(jq -r '.live' <<<"$live_without_marker")"
assert_eq "not-live exit is 1" "1" "$live_without_marker_rc"

# --- health exit 2 for unknown, distinct from fail/ok ----------------------

rm -f "$ws/.agent-ops-state/heartbeat.json" "$state_dir/.state-sync-published.json"
unknown_out="$(run --health)"; unknown_rc=$?
assert_eq "no published evidence at all reads unknown, never ok" "unknown" "$(jq -r '.status' <<<"$unknown_out")"
assert_eq "unknown exit is 2, distinct from fail's 1 and ok's 0" "2" "$unknown_rc"

# --- metrics carries the documented top-level shape (acceptance 9) --------

metrics_out="$(run --metrics)"; metrics_rc=$?
assert_eq "metrics always exits 0" "0" "$metrics_rc"
for field in node role ts version live ready health cycles containers; do
  assert_eq "metrics carries top-level field '$field'" "true" \
    "$(jq --arg f "$field" 'has($f)' <<<"$metrics_out")"
done
assert_eq "metrics.cycles carries log_selections" "true" \
  "$(jq 'has("log_selections")' <<<"$(jq -c '.cycles' <<<"$metrics_out")")"
assert_eq "metrics.cycles carries log_attempts_failed" "true" \
  "$(jq 'has("log_attempts_failed")' <<<"$(jq -c '.cycles' <<<"$metrics_out")")"

# --- One forge read per TTL window, and the body is what readiness reads ---
# Requirement 56a: `--ready` makes exactly one `/rate_limit` call on the
# ordinary path, and caches it for node_health_forge_check_cache_seconds so a
# polling orchestrator cannot turn readiness into a load source. A `gh` stub
# on PATH counts the calls and hands back a budget below the fixture's own
# floor, which is also what proves the response body actually reaches the
# verdict rather than only its verdict word.
stub_dir="$tmp_dir/stub"
mkdir -p "$stub_dir"
calls="$tmp_dir/gh-calls"
: > "$calls"
cat > "$stub_dir/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$calls"
if [[ "\$*" == "api rate_limit" ]]; then
  printf '%s' '{"resources":{"core":{"remaining":17,"limit":5000},"graphql":{"remaining":9,"limit":5000}}}'
  exit 0
fi
exit 1
STUB
chmod +x "$stub_dir/gh"

budget_state="$tmp_dir/state-budget"
mkdir -p "$budget_state"
budget_config="$tmp_dir/config-budget.json"
jq -nc --arg sd "$budget_state" --arg wr "$ws" \
  '{state_dir:$sd, workspace_root:$wr, github_min_core_budget:1000,
    github_min_graphql_budget:500, node_health_forge_check_cache_seconds:300}' > "$budget_config"

budget_out="$(PATH="$stub_dir:$PATH" "$CLI" --config "$budget_config" --state-dir "$budget_state" --ready)"
assert_eq "readiness reads the forge response body, not just its verdict (core)" "true" \
  "$(jq '[.unmet[].code] | index("github-core-budget-low") != null' <<<"$budget_out")"
assert_eq "readiness reads the forge response body, not just its verdict (graphql)" "true" \
  "$(jq '[.unmet[].code] | index("github-graphql-budget-low") != null' <<<"$budget_out")"
assert_eq "readiness does not also report the forge unreachable or unauthenticated" "0" \
  "$(jq '[.unmet[].code | select(startswith("gh-"))] | length' <<<"$budget_out")"
assert_eq "exactly one forge call, never the probe's own read as well" "1" \
  "$(grep -c . "$calls")"

PATH="$stub_dir:$PATH" "$CLI" --config "$budget_config" --state-dir "$budget_state" --ready >/dev/null
assert_eq "a second poll inside the TTL makes no further call at all" "1" \
  "$(grep -c . "$calls")"

echo
if (( failures > 0 )); then
  printf '%d failure(s)\n' "$failures"
  exit 1
fi
echo "all passed"
