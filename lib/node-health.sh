#!/usr/bin/env bash
#
# lib/node-health.sh — the computation behind `scripts/node-health.sh`'s
# three verdicts (live/ready/health), and the only place any of them is
# decided (issue #608, Phase 2). Same contract `lib/updater-health.sh` and
# `lib/image-drift.sh` already hold: every function here reads what its
# caller hands it (never a file, never the network, never `config.json`
# itself), returns one compact JSON object, and never returns non-zero and
# never asserts a verdict its input cannot support. `scripts/node-health.sh`
# is the one place that gathers those inputs — from disk, from a cached
# probe, from config — and hands them in; this file makes no decision about
# how anything is served, gathered, or cached.
#
# ## Why three verdicts, not one
#
# A node can be live, not ready, and unhealthy all at once, and each answer
# has to stay correct on its own:
#
#   - live    — supercronic is still firing this node's jobs at all. The
#               weakest claim, and the only one nearly free to compute:
#               evidence is a marker file a dedicated crontab line touches
#               every minute, aged against a threshold. Deliberately never
#               the cycle lock — a lock held by an Implementer stage doing
#               its job would otherwise read as "not live" to a liveness
#               probe, and a probe that restarts a node mid-cycle over that
#               misreading is the graceful-drain failure arriving by another
#               route.
#   - ready   — a cycle could start now: credentials present, `gh`
#               authenticated, disk and the two GitHub budgets above their
#               floors, neither the node nor the fleet switch disabling it,
#               no usage-limit freeze in force. Names the specific failed
#               condition(s), never a bare boolean.
#   - health  — is the node doing its job over time, composed from named
#               components rather than restating liveness: `outbound` (is
#               this node's own state actually reaching the shared state —
#               agent-ops#602's `fleet_publication_status`) and `converged`
#               (is the node running, or on its way to running, the version
#               the installation intends — agent-ops#603's `updater_status`
#               alongside `lib/image-drift.sh`'s own drift verdict). A
#               component whose source does not exist yet reads `unknown`,
#               never `ok` — a green health endpoint that means nothing is
#               the 2026-08-08 failure this whole item exists to close.
#
# ## The fold
#
# Both `converged` (folding updater + image) and the top-level `health`
# (folding outbound + converged) apply the same rule, `node_health_fold`:
# `fail` if anything folded is `fail`; `unknown` if anything is `unknown` and
# nothing is `fail`; `ok` only when everything folded is `ok`. One function,
# used at both levels, so the two can never drift apart.

set -uo pipefail

# _node_health_json_or_null VALUE
# Every component below is handed a field somebody else read out of a
# heartbeat, a cache or a fixture, and "somebody else" includes a container
# killed mid-write: a truncated `heartbeat.json` hands a half-object down
# here as readily as a whole one. Anything that is not exactly one JSON
# value becomes `null` — which every component already reads as "no
# evidence", the one answer that is always supportable — rather than
# reaching `jq --argjson`, which would fail the interpolation, print
# nothing, and return non-zero out of a function whose whole contract
# (see the header) is that it never does either. `lib/metering.sh`'s own
# header records the same rule for the same reason: these objects are
# interpolated into `jq` at their call sites, so a helper that dies on odd
# input costs its caller more than its own field.
_node_health_json_or_null() {
  local v="${1:-null}" out
  out="$(jq -c '.' <<<"$v" 2>/dev/null)" || { printf 'null'; return 0; }
  # Empty (no JSON value at all) or multi-line (more than one) is no more
  # interpolatable than a parse error is.
  [[ -n "$out" && "$out" != *$'\n'* ]] || { printf 'null'; return 0; }
  printf '%s' "$out"
}

# node_health_fold STATUS...
# The one composition rule both `converged` and `health` use. Never returns
# non-zero: an empty argument list (nothing to fold) reads `unknown`, on the
# same "no evidence" reasoning every other reader in this codebase gives an
# absent input, rather than asserting `ok` for nothing at all.
node_health_fold() {
  local s has_unknown=0 seen=0
  for s in "$@"; do
    seen=1
    case "$s" in
      fail) printf 'fail'; return 0 ;;
      ok) ;;
      *) has_unknown=1 ;;
    esac
  done
  if (( ! seen )) || (( has_unknown )); then
    printf 'unknown'
  else
    printf 'ok'
  fi
}

# node_health_liveness MARKER-MTIME-EPOCH STALE-AFTER-SECONDS NOW-EPOCH
#
# MARKER-MTIME-EPOCH is the liveness marker's own mtime, in epoch seconds —
# read by the caller (`stat -c %Y`), never by this file, which touches no
# filesystem. Empty (the marker has never been touched — a container in its
# first minute, or a marker file lost with a volume) reads `live: false`,
# `reason: "no liveness marker yet"`: a fresh container is honestly not yet
# proven live, not `unknown` — nothing here is unanswerable, there is simply
# no evidence yet, and an orchestrator polling this before the first minute
# has elapsed should see exactly that.
#
# Never reads the cycle lock (see the header): this function is handed a
# marker age and nothing else, so there is no lock state it could
# accidentally fold in even if a caller tried.
node_health_liveness() {
  local mtime_epoch="${1:-}" stale_after="${2:-180}" now_epoch="${3:-}"
  [[ -n "$now_epoch" ]] || now_epoch="$(date -u +%s)"
  [[ "$stale_after" =~ ^[0-9]+$ ]] || stale_after=180
  if [[ -z "$mtime_epoch" ]] || ! [[ "$mtime_epoch" =~ ^[0-9]+$ ]]; then
    printf '{"live":false,"age_s":null,"reason":"no liveness marker yet"}'
    return 0
  fi
  local age=$(( now_epoch - mtime_epoch ))
  (( age >= 0 )) || age=0
  if (( age > stale_after )); then
    jq -nc --argjson a "$age" --argjson t "$stale_after" \
      '{live:false, age_s:$a, reason:("liveness marker is " + ($a|tostring) + "s old, over the " + ($t|tostring) + "s threshold")}'
  else
    jq -nc --argjson a "$age" '{live:true, age_s:$a, reason:null}'
  fi
}

# node_health_outbound_component PUBLICATION-STATUS-JSON
# PUBLICATION-STATUS-JSON is `lib/fleet.sh`'s `fleet_publication_status`
# output for this node's own last-fetched-back publication. Maps its
# verdict onto the ok/fail/unknown vocabulary every health component shares:
# "fresh" -> ok, "stale" -> fail, "unknown" -> unknown (no publication has
# ever been read back for this node — the short window before a node's
# first successful push has been fetched back at all, or #602's own
# machinery predates this heartbeat — never read as healthy).
node_health_outbound_component() {
  local pub verdict
  pub="$(_node_health_json_or_null "${1:-null}")"
  verdict="$(jq -r 'if type == "object" then (.verdict // "unknown") else "unknown" end' <<<"$pub" 2>/dev/null || echo unknown)"
  case "$verdict" in
    fresh) jq -nc --argjson p "$pub" '{status:"ok", publication:$p}' ;;
    stale) jq -nc --argjson p "$pub" '{status:"fail", publication:$p}' ;;
    *)     jq -nc --argjson p "$pub" '{status:"unknown", publication:$p}' ;;
  esac
}

# node_health_updater_component UPDATER-STATUS-JSON
# UPDATER-STATUS-JSON is `lib/updater-health.sh`'s `updater_status` output,
# read back from this node's own last-published heartbeat (never recomputed
# here — this file makes no filesystem or ledger read of its own). `null`
# (no ledger evidence yet) -> unknown; `stuck` -> fail (a fault only a human
# clears); `rolled`/`deferring` -> ok, both ordinary and self-resolving.
node_health_updater_component() {
  local upd status
  upd="$(_node_health_json_or_null "${1:-null}")"
  status="$(jq -r 'if type == "object" then (.status // "unknown") else "absent" end' <<<"$upd" 2>/dev/null || echo absent)"
  case "$status" in
    stuck)               jq -nc --argjson u "$upd" '{status:"fail", updater:$u}' ;;
    rolled|deferring)    jq -nc --argjson u "$upd" '{status:"ok", updater:$u}' ;;
    *)                   jq -nc --argjson u "$upd" '{status:"unknown", updater:$u}' ;;
  esac
}

# node_health_image_component IMAGE-STATUS-JSON GRACE-HOURS NOW-EPOCH
# IMAGE-STATUS-JSON is `lib/image-drift.sh`'s `image_drift_status` output,
# read back from the heartbeat on the same terms as the updater component
# above. Mirrors `dashboard/index.html`'s own `imageLine` colouring exactly.
# so the endpoint and the page can never disagree about what "behind" means
# (`image_behind_grace_hours`, config.schema.json): "current" -> ok;
# "unverified" (registry unreadable, or an image with no revision label) ->
# unknown; "behind" -> ok while the registry's newest image is younger than
# the grace period (a roll waits for a cycle in flight, so this is routine),
# fail once it is older, or once `registry_created_at` cannot be read at
# all (dashboard treats an unreadable age the same as "past grace", never
# as "just happened"); `null` (this node runs no CI-stamped image, or the
# heartbeat predates this field) -> unknown.
node_health_image_component() {
  local img grace_hours="${2:-3}" now_epoch="${3:-}" status
  img="$(_node_health_json_or_null "${1:-null}")"
  [[ -n "$now_epoch" ]] || now_epoch="$(date -u +%s)"
  [[ "$grace_hours" =~ ^[0-9]+$ ]] || grace_hours=3
  (( grace_hours >= 1 )) || grace_hours=1
  status="$(jq -r 'if type == "object" then (.status // "unknown") else "absent" end' <<<"$img" 2>/dev/null || echo absent)"
  case "$status" in
    current) jq -nc --argjson i "$img" '{status:"ok", image:$i}' ;;
    behind)
      local created age_h stuck=1
      created="$(jq -r '.registry_created_at // empty' <<<"$img" 2>/dev/null)"
      if [[ -n "$created" ]]; then
        local created_epoch
        if created_epoch="$(date -u -d "$created" +%s 2>/dev/null)"; then
          age_h=$(( (now_epoch - created_epoch) / 3600 ))
          (( age_h <= grace_hours )) && stuck=0
        fi
      fi
      if (( stuck )); then
        jq -nc --argjson i "$img" --argjson g "$grace_hours" \
          '{status:"fail", image:$i, grace_hours:$g}'
      else
        jq -nc --argjson i "$img" --argjson g "$grace_hours" \
          '{status:"ok", image:$i, grace_hours:$g}'
      fi
      ;;
    *) jq -nc --argjson i "$img" '{status:"unknown", image:$i}' ;;
  esac
}

# node_health_converged UPDATER-STATUS-JSON IMAGE-STATUS-JSON GRACE-HOURS NOW-EPOCH
# The `converged` health component: is this node running, or genuinely on
# its way to running, the version the installation intends. Folds the
# updater and image components above with `node_health_fold`.
node_health_converged() {
  local upd="${1:-null}" img="${2:-null}" grace_hours="${3:-3}" now_epoch="${4:-}"
  local updater_c image_c folded
  updater_c="$(node_health_updater_component "$upd")"
  image_c="$(node_health_image_component "$img" "$grace_hours" "$now_epoch")"
  folded="$(node_health_fold "$(jq -r '.status' <<<"$updater_c")" "$(jq -r '.status' <<<"$image_c")")"
  jq -nc --argjson u "$updater_c" --argjson i "$image_c" --arg s "$folded" \
    '{status:$s, components:{updater:$u, image:$i}}'
}

# node_health_health PUBLICATION-STATUS-JSON UPDATER-STATUS-JSON IMAGE-STATUS-JSON GRACE-HOURS NOW-EPOCH
# The top-level `health` verdict: folds `outbound` and `converged`.
node_health_health() {
  local pub="${1:-null}" upd="${2:-null}" img="${3:-null}" grace_hours="${4:-3}" now_epoch="${5:-}"
  local outbound_c converged_c folded
  outbound_c="$(node_health_outbound_component "$pub")"
  converged_c="$(node_health_converged "$upd" "$img" "$grace_hours" "$now_epoch")"
  folded="$(node_health_fold "$(jq -r '.status' <<<"$outbound_c")" "$(jq -r '.status' <<<"$converged_c")")"
  jq -nc --argjson o "$outbound_c" --argjson c "$converged_c" --arg s "$folded" \
    '{status:$s, components:{outbound:$o, converged:$c}}'
}

# node_health_readiness FACTS-JSON
#
# FACTS-JSON, entirely gathered by the caller (this function touches no
# file, no lock, and makes no network call of its own):
#
#   {
#     "credentials_present": bool,
#     "gh_auth": "ok"|"unauthorized"|"unreachable",
#     "gh_auth_detail": string,
#     "disk_free_kb": int|null, "disk_floor_bytes": int,
#     "core_remaining": int|null, "core_floor": int,
#     "graphql_remaining": int|null, "graphql_floor": int,
#     "node_disabled": bool, "fleet_disabled": bool, "limit_freeze": bool
#   }
#
# Prints `{"ready":bool,"unmet":[{"code":..., "detail":...}, ...]}` — every
# failed condition, not just the first, because an orchestrator deciding
# whether to route traffic here needs the whole picture and a test asserting
# one condition must not have its signal hidden behind an unrelated one that
# also happens to be failing in the same fixture. `unmet` is empty (not
# merely `ready:true`) when every condition passes.
node_health_readiness() {
  local facts="${1:-{\}}"
  jq -c '
    def check(cond; code; detail):
      if cond then {code:code, detail:detail} else empty end;
    [
      check(.credentials_present != true;
        "credentials-missing"; "no Claude credentials at $CLAUDE_CONFIG_DIR/.credentials.json"),
      check(.gh_auth == "unauthorized";
        "gh-unauthenticated"; ("gh is not authenticated: " + (.gh_auth_detail // "unknown"))),
      # A forge that cannot be reached at all is honestly "not ready", never
      # folded into "unknown": the pitfall this distinguishes is a network
      # blip (not-ready, real and transient) against an unreadable *local*
      # signal (unknown, see the disk/budget checks own "!= null" guards
      # below, which never fire this readiness-blocking on an unreadable
      # meter alone).
      check(.gh_auth == "unreachable";
        "gh-forge-unreachable"; ("the forge could not be reached: " + (.gh_auth_detail // "unknown"))),
      check((.disk_floor_bytes // 0) > 0
            and (.disk_free_kb != null)
            and ((.disk_free_kb * 1024) < .disk_floor_bytes);
        "disk-low"; "state_dir free space is below the configured floor"),
      check((.core_floor // 0) > 0 and (.core_remaining != null) and (.core_remaining < .core_floor);
        "github-core-budget-low"; "GitHub core budget remaining is below the configured floor"),
      check((.graphql_floor // 0) > 0 and (.graphql_remaining != null) and (.graphql_remaining < .graphql_floor);
        "github-graphql-budget-low"; "GitHub graphql budget remaining is below the configured floor"),
      check(.node_disabled == true;
        "node-disabled"; "this node is disabled"),
      check(.fleet_disabled == true;
        "fleet-disabled"; "the fleet switch is set"),
      check(.limit_freeze == true;
        "usage-limit-freeze"; "a usage-limit stand-down is in force")
    ] as $unmet
    | {ready: ($unmet | length == 0), unmet: $unmet}
  ' <<<"$facts" 2>/dev/null || printf '{"ready":false,"unmet":[{"code":"unreadable-facts","detail":"readiness facts could not be parsed"}]}'
}
