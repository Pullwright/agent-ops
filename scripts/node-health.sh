#!/usr/bin/env bash
#
# scripts/node-health.sh — the CLI surface over lib/node-health.sh (issue
# #608, Phase 2): the container-runtime healthcheck runs this directly, and
# scripts/node-health-server.py shells out to it for the HTTP surface.
#
# usage: node-health.sh [--live|--ready|--health|--metrics] [--json]
#                        [--config FILE] [--state-dir DIR] [--peers-dir DIR]
#
# Read-only throughout: touches no lock, writes no event, publishes nothing,
# and makes no network call except the single cached `/rate_limit` read
# `--ready` needs for the GitHub budget (see `_node_health_rate_limit`
# below). Never triggers a state-sync push, a gather, a dashboard publish or
# a `claude` invocation — these compute on demand from what cron already
# wrote, so an orchestrator polling this every few seconds costs nothing
# beyond that one cached forge read.
#
# `--json` is accepted for clarity in scripts that spell it out explicitly;
# output is always the one compact JSON object either way (this CLI has no
# other rendering).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/limit-detect.sh
. "$SCRIPT_DIR/lib/limit-detect.sh"
# shellcheck source=lib/disk-space.sh
. "$SCRIPT_DIR/lib/disk-space.sh"
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
# shellcheck source=lib/version.sh
. "$SCRIPT_DIR/lib/version.sh"
# shellcheck source=lib/node-health.sh
. "$SCRIPT_DIR/lib/node-health.sh"

usage() {
  cat <<'EOF'
usage: node-health.sh [--live|--ready|--health|--metrics] [--json]

Read-only. Prints one compact JSON object on stdout and exits:

  --live      is supercronic still firing this node's jobs.
              exit 0 live, 1 not live.
  --ready     could a cycle start now (credentials, gh auth, disk, GitHub
              budgets, the node/fleet switches, a usage-limit freeze).
              exit 0 ready, 1 not ready.
  --health    is this node's own published state reaching the fleet
              (outbound) and running the version the installation intends
              (converged). exit 0 ok, 1 fail, 2 unknown.
  --metrics   node identity, version, all three verdicts and their
              components, and cycle/container counters, documented under
              docs/METERING-SCHEMA.md's stability policy.
              exit 0 always (not a verdict).

  --json      accepted for clarity; output is always JSON.

  --config FILE      config.json to read (default: this repo's own).
  --state-dir DIR    override state_dir (default: the config's own).
  --peers-dir DIR    override the peers directory (default: derived from
                     workspace_root, same as every other reader).

No argument prints --health. Makes no network call except one cached
`/rate_limit` read for --ready's GitHub budget check (cached in state_dir
with a short TTL, so polling this cannot itself become a load source).
Triggers no state-sync push, gather, dashboard publish or `claude`
invocation.
EOF
}

expand_home() { local p="$1"; [[ "$p" == "~"* ]] && p="$HOME${p:1}"; printf '%s\n' "$p"; }

mode="health"
json_flag=0
state_dir_override=""
peers_dir_override=""
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --live) mode="live"; shift ;;
    --ready) mode="ready"; shift ;;
    --health) mode="health"; shift ;;
    --metrics) mode="metrics"; shift ;;
    --json) json_flag=1; shift ;;
    --config) CONFIG_FILE="${2:-}"; shift 2 ;;
    --state-dir) state_dir_override="${2:-}"; shift 2 ;;
    --peers-dir) peers_dir_override="${2:-}"; shift 2 ;;
    *) echo "node-health: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
: "$json_flag"  # accepted, never changes the output shape (see usage)

DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)" || {
  # A node-health check must never crash on a config it cannot read — that is
  # exactly the "unknown" a probe needs to be able to say. `--live` needs no
  # config at all (a pure marker-age read), so it still answers; every other
  # mode reports unknown/not-ready rather than dying.
  DEFAULTED_CONFIG='{}'
}
cfg() { jq -r "$1 // empty" <<<"$DEFAULTED_CONFIG" 2>/dev/null; }

if [[ -n "$state_dir_override" ]]; then
  state_dir="$state_dir_override"
else
  state_dir="$(expand_home "$(cfg '.state_dir')")"
  [[ -n "$state_dir" ]] || state_dir="$HOME/.local/state/poetic-agents"
fi
workspace_root="$(expand_home "$(cfg '.workspace_root')")"
[[ -n "$workspace_root" ]] || workspace_root="$HOME/.cache/poetic-agents/workspaces"
node_name="${NODE_NAME:-$(hostname 2>/dev/null || echo node)}"
role="${AGENT_OPS_ROLE:-standby}"
mirror="$workspace_root/.agent-ops-state"
if [[ -n "$peers_dir_override" ]]; then
  peers_dir="$peers_dir_override"
else
  peers_dir="$(fleet_peers_dir "$workspace_root")"
fi

marker_file="$state_dir/.node-alive"
live_stale_minutes="$(cfg '.node_health_live_stale_after_minutes')"
[[ "$live_stale_minutes" =~ ^[0-9]+$ ]] || live_stale_minutes=3
live_stale_seconds=$(( live_stale_minutes * 60 ))

now_epoch="$(date -u +%s)"

# --- live -------------------------------------------------------------

cmd_live() {
  local mtime_epoch=""
  mtime_epoch="$(stat -c %Y "$marker_file" 2>/dev/null || true)"
  node_health_liveness "$mtime_epoch" "$live_stale_seconds" "$now_epoch"
}

# --- ready --------------------------------------------------------------

# _node_health_rate_limit STATE_DIR TTL-SECONDS
# The one network call this whole CLI ever makes: `gh api rate_limit`,
# cached in state_dir so a polling caller cannot turn readiness into a load
# source (see the header, and issue #608's own pitfall: "do not spend the
# budget you are reporting on"). Prints — and caches — one compact JSON
# object, `{verdict, detail, core, graphql}`: verdict is github_auth_probe's
# own vocabulary (ok/unauthorized/unreachable), core/graphql are
# `.resources.{core,graphql}.remaining` from the same response and `null`
# when unavailable.
#
# JSON rather than the tab-separated line this first carried, because a
# delimited line cannot survive an empty field here: tab is an IFS
# *whitespace* character, so `IFS=$'\t' read` folds a run of them into one
# separator and drops empties entirely — and `detail` is empty on precisely
# the path that has budget figures to report (`verdict: ok`), so every
# healthy read shifted `core` into `detail` and `graphql` into `core`, and
# readiness compared the graphql pool against `github_min_core_budget` while
# `github_min_graphql_budget` was never checked at all. A cached object read
# back with `jq` cannot mis-associate a field, whatever any of them holds.
#
# Read from `/rate_limit`'s body
# rather than a metered call's headers, deliberately: this endpoint is
# exempt from the limits it reports (config.schema.json's own note on
# github_min_core_budget), which is what lets an orchestrator poll readiness
# without spending the very budget it asks about — at the cost of the body
# occasionally reading as an empty window rather than a true aggregate
# (lib/github-limit.sh's own header explains why the cycle-start budget gate
# reads headers instead). Readiness is a coarser, cheaper signal than that
# gate on purpose; the precise figure remains agent-cycle.sh's own.
_node_health_rate_limit() {
  local state_dir="$1" ttl="${2:-30}"
  local cache="$state_dir/.node-health-ratelimit-cache.json" age
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=30
  if [[ -s "$cache" ]]; then
    age=$(( now_epoch - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    # A cache that will not parse is no cache at all — re-read rather than
    # hand a caller something it would have to guess at.
    if (( age >= 0 && age <= ttl )) \
       && jq -e 'type == "object" and has("verdict")' "$cache" >/dev/null 2>&1; then
      jq -c '.' "$cache" 2>/dev/null && return 0
    fi
  fi
  # One call, not two (requirement 58a): `github_auth_probe` *is* this same
  # free `/rate_limit` request, and it returns only its verdict — so asking
  # it first and then reading the body would make two identical requests of
  # the forge every time the cache expires, which is precisely what the
  # requirement's "exactly one network call" exists to prevent. Make the
  # call here, classify its own response the way the probe classifies its
  # own, and fall back to the probe only when that call did not come back
  # usable: there it buys the one thing this response cannot, which is *why*
  # (a rejected token, no token at all, an unreachable forge), and there is
  # no budget figure to be had on that path in any case.
  local verdict detail="" body="" core="" graphql=""
  body="$(command gh api rate_limit 2>/dev/null)" || body=""
  if jq -e 'type == "object" and has("resources")' <<<"$body" >/dev/null 2>&1; then
    verdict="ok"
    core="$(jq -r '.resources.core.remaining // empty' <<<"$body" 2>/dev/null)"
    graphql="$(jq -r '.resources.graphql.remaining // empty' <<<"$body" 2>/dev/null)"
  else
    read -r verdict detail < <(github_auth_probe) || true
  fi
  local record
  [[ "$core" =~ ^[0-9]+$ ]] || core=""
  [[ "$graphql" =~ ^[0-9]+$ ]] || graphql=""
  record="$(jq -nc --arg v "$verdict" --arg d "$detail" \
    --argjson c "${core:-null}" --argjson g "${graphql:-null}" \
    '{verdict:$v, detail:$d, core:$c, graphql:$g}')" \
    || record='{"verdict":"unreachable","detail":"","core":null,"graphql":null}'
  mkdir -p "$state_dir" 2>/dev/null || true
  if printf '%s' "$record" > "$cache.$$" 2>/dev/null; then
    mv -f "$cache.$$" "$cache" 2>/dev/null || rm -f "$cache.$$" 2>/dev/null
  fi
  printf '%s' "$record"
}

cmd_ready() {
  local credentials_present=false
  local claude_config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  [[ -f "$claude_config_dir/.credentials.json" ]] && credentials_present=true

  local ttl
  ttl="$(cfg '.node_health_forge_check_cache_seconds')"
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=30
  local probe gh_verdict gh_detail core_remaining graphql_remaining
  probe="$(_node_health_rate_limit "$state_dir" "$ttl")"
  gh_verdict="$(jq -r '.verdict // "unreachable"' <<<"$probe" 2>/dev/null)"
  [[ -n "$gh_verdict" ]] || gh_verdict="unreachable"
  gh_detail="$(jq -r '.detail // ""' <<<"$probe" 2>/dev/null)"
  core_remaining="$(jq -r '.core // empty' <<<"$probe" 2>/dev/null)"
  graphql_remaining="$(jq -r '.graphql // empty' <<<"$probe" 2>/dev/null)"

  local disk_free_kb min_free_bytes
  disk_free_kb="$(disk_space_free_kb "$state_dir")"
  min_free_bytes="$(cfg '.min_free_workspace_bytes')"
  [[ "$min_free_bytes" =~ ^[0-9]+$ ]] || min_free_bytes=$(( 2 * 1024 * 1024 * 1024 ))

  local core_floor graphql_floor
  core_floor="$(cfg '.github_min_core_budget')"; [[ "$core_floor" =~ ^[0-9]+$ ]] || core_floor=0
  graphql_floor="$(cfg '.github_min_graphql_budget')"; [[ "$graphql_floor" =~ ^[0-9]+$ ]] || graphql_floor=0

  # The node/fleet switches and the usage-limit freeze, all read from local
  # evidence only — never a live fetch (see the header). A stale local copy
  # costs at most one wrongly-answered poll between fetches, the same trade
  # every other local-cache reader in this codebase already makes.
  local node_switch fleet_switch node_disabled=false fleet_disabled=false
  node_switch="$(toggle_state "$state_dir")"
  if [[ "$(jq -r '.state' <<<"$node_switch")" == "disabled" ]] \
     && [[ "$(toggle_mode "$(jq -c '.record' <<<"$node_switch")")" != "drain" ]]; then
    node_disabled=true
  fi
  fleet_switch="$(fleet_disabled_state_cached "" "$state_dir")"
  if [[ "$(jq -r '.state' <<<"$fleet_switch")" == "disabled" ]] \
     && [[ "$(toggle_mode "$(jq -c '.record' <<<"$fleet_switch")")" != "drain" ]]; then
    fleet_disabled=true
  fi

  local limit_freeze=false governing resume_at resume_epoch=0
  governing="$(fleet_logs "$state_dir" "$peers_dir" | limit_union_record)"
  governing="$(limit_later_record "$governing" \
    "$(cat "$(fleet_cache_file "$state_dir" limit)" 2>/dev/null || true)")"
  if [[ -n "$governing" ]]; then
    resume_at="$(jq -r '.resume_at // empty' <<<"$governing" 2>/dev/null)"
    [[ -n "$resume_at" ]] && resume_epoch="$(date -u -d "$resume_at" +%s 2>/dev/null || echo 0)"
    (( resume_epoch > now_epoch )) && limit_freeze=true
  fi

  local facts
  facts="$(jq -nc \
    --argjson credentials_present "$credentials_present" \
    --arg gh_auth "$gh_verdict" --arg gh_auth_detail "$gh_detail" \
    --argjson disk_free_kb "${disk_free_kb:-null}" --argjson disk_floor_bytes "$min_free_bytes" \
    --argjson core_remaining "${core_remaining:-null}" --argjson core_floor "$core_floor" \
    --argjson graphql_remaining "${graphql_remaining:-null}" --argjson graphql_floor "$graphql_floor" \
    --argjson node_disabled "$node_disabled" --argjson fleet_disabled "$fleet_disabled" \
    --argjson limit_freeze "$limit_freeze" \
    '{credentials_present:$credentials_present, gh_auth:$gh_auth, gh_auth_detail:$gh_auth_detail,
      disk_free_kb:$disk_free_kb, disk_floor_bytes:$disk_floor_bytes,
      core_remaining:$core_remaining, core_floor:$core_floor,
      graphql_remaining:$graphql_remaining, graphql_floor:$graphql_floor,
      node_disabled:$node_disabled, fleet_disabled:$fleet_disabled, limit_freeze:$limit_freeze}')"
  node_health_readiness "$facts"
}

# --- health ---------------------------------------------------------------

# Self's own last-published heartbeat — the same file scripts/state-sync.sh
# writes into its mirror on every push (do_push), read here rather than
# recomputed: this CLI makes no state-sync call of its own (see the header).
# Missing, or predating a field, reads as no evidence for that field, never
# as healthy (issue #608's own pitfall, and #602/#603's own heartbeat
# convention).
_node_health_heartbeat() {
  jq -c '.' "$mirror/heartbeat.json" 2>/dev/null || echo 'null'
}

cmd_health() {
  local heartbeat pub_ts pub_status updater image grace_hours
  heartbeat="$(_node_health_heartbeat)"
  pub_ts="$(jq -r '.ts // empty' "$state_dir/.state-sync-published.json" 2>/dev/null || true)"
  local node_stale_minutes threshold_s
  node_stale_minutes="$(cfg '.node_stale_after_minutes')"
  [[ "$node_stale_minutes" =~ ^[0-9]+$ ]] || node_stale_minutes=30
  threshold_s=$(( node_stale_minutes * 60 ))
  pub_status="$(fleet_publication_status "$pub_ts" "$threshold_s" "$now_epoch")"

  updater="$(jq -c '.updater // null' <<<"$heartbeat" 2>/dev/null || echo null)"
  image="$(jq -c '.image // null' <<<"$heartbeat" 2>/dev/null || echo null)"
  grace_hours="$(cfg '.image_behind_grace_hours')"
  [[ "$grace_hours" =~ ^[0-9]+$ ]] || grace_hours=3

  node_health_health "$pub_status" "$updater" "$image" "$grace_hours" "$now_epoch"
}

# --- metrics ----------------------------------------------------------------

cmd_metrics() {
  local version heartbeat live ready health containers
  version="$(agent_ops_version "$SCRIPT_DIR")"
  live="$(cmd_live)"
  ready="$(cmd_ready)"
  health="$(cmd_health)"
  heartbeat="$(_node_health_heartbeat)"

  # Cycle counters over this node's own retained log only (never the fleet
  # union — metrics answers for this node, and folding peers in here would
  # double-count against whatever also asks each of them). Counted, not
  # merely present/absent, since a metrics consumer wants magnitude.
  local selections=0 attempts_failed=0
  if [[ -s "$state_dir/log.jsonl" ]]; then
    selections="$(jq -c 'select(.event == "selection")' "$state_dir/log.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
    attempts_failed="$(jq -c 'select(.event == "attempt-failed")' "$state_dir/log.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
  fi

  # Per-container resource actuals-against-budget, where #606's collector has
  # produced them (host-facts/<node>.json) — null otherwise, never fabricated
  # (issue #608 scope: "/metrics reports those figures where they exist; it
  # does not produce them").
  containers="$(jq -c '.budget // null' "$state_dir/host-facts/$node_name.json" 2>/dev/null || echo null)"

  jq -nc \
    --arg node "$node_name" --arg role "$role" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson version "$version" \
    --argjson live "$live" --argjson ready "$ready" --argjson health "$health" \
    --argjson selections "${selections:-0}" --argjson attempts_failed "${attempts_failed:-0}" \
    --argjson containers "$containers" \
    '{node:$node, role:$role, ts:$ts, version:$version,
      live:$live, ready:$ready, health:$health,
      cycles:{log_selections:$selections, log_attempts_failed:$attempts_failed},
      containers:$containers}'
}

# --- dispatch ---------------------------------------------------------------

out=""
rc=0
case "$mode" in
  live)
    out="$(cmd_live)"
    [[ "$(jq -r '.live' <<<"$out")" == "true" ]] || rc=1
    ;;
  ready)
    out="$(cmd_ready)"
    [[ "$(jq -r '.ready' <<<"$out")" == "true" ]] || rc=1
    ;;
  health)
    out="$(cmd_health)"
    case "$(jq -r '.status' <<<"$out")" in
      ok) rc=0 ;;
      fail) rc=1 ;;
      *) rc=2 ;;
    esac
    ;;
  metrics)
    out="$(cmd_metrics)"
    rc=0
    ;;
esac

printf '%s\n' "$out"
exit "$rc"
