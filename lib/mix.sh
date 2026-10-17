#!/usr/bin/env bash
#
# lib/mix.sh — the credit mix's live lever (issue #2244, D30):
# `agent-cycle.sh --mix` moves a provider's lane weights and openings while
# the fleet runs, through `fleet/mix.json`, outranking `config.json`'s own
# `providers.<name>.lanes` for the keys it names.
#
# `fleet/mix.json` is a fifth member of `lib/toggle.sh`'s fleet-flag family
# (`disabled`, `limit`, `merge-autonomy-kill`, `merge-budget-freeze-<slug>`),
# reusing its `fleet_flag_write`/
# `fleet_flag_fetch`/`fleet_flag_delete` outright under its own flag name
# `mix`, with the same `by`/`actor`/`ts` provenance `fleet/disabled.json`
# carries. Its own shape:
#
#   {
#     "providers": {
#       "anthropic": {
#         "lanes": {
#           "api": {"weight": 70},
#           "subscription": {"weight": 30, "enabled": true,
#                             "balance_usd": 40, "balance_as_of": "2026-…Z"}
#         }
#       }
#     },
#     "by": "wallen@host pid 4242",
#     "actor": "wallen@host",
#     "ts": "2026-…Z"
#   }
#
# Unlike the switch and the limit flag, this one carries openings and
# preferences only — weights, `enabled: true`, and a restated balance — and
# never a closure, a cap or a floor: those are a configuration change (in the
# file the image carries) or `--close-lane`'s own manual record on
# `fleet/limit.json` (#2242), never this lever. `mix_build_overlay` below is
# what refuses `enabled: false` outright, naming `--close-lane` instead of
# silently reinterpreting it.
#
# `providers_apply_mix` overlays this flag onto `lib/model-id.sh`'s own
# `PROVIDER_LANES` — populated by `providers_load` from `config.json` — so
# every later reader (the stage launcher's `stage_lane_draw`, `--status`,
# `scripts/node-health.sh --metrics`) sees one effective set of lanes without
# re-deriving it (requirement 34a). It must be called once, after
# `providers_load`, before any of those readers run.
#
# Sourced by agent-cycle.sh, review-cycle.sh, monitor-cycle.sh and
# scripts/node-health.sh — after lib/model-id.sh (PROVIDER_LANES,
# PROVIDER_SUBSTRATE) and lib/toggle.sh (the fleet-flag primitives this file
# is built on); lib/lane.sh (lane_effective_open) is self-sourced below.

set -uo pipefail

# shellcheck source=lib/lane.sh
# lane_effective_open — self-sourced, the same idiom lib/stage-run.sh uses for
# its own substrate adapters, so a caller of this file (scripts/node-health.sh
# stays deliberately free of lib/stage-run.sh's heavier dependencies) need not
# separately know to load it.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lane.sh"

# Populated by providers_apply_mix: PROVIDER_NAME -> a compact JSON object
# naming, per lane per field, which side supplied the effective value —
# `{ts, by, api:{weight,enabled,balance}, subscription:{weight,enabled,balance}}`,
# each of the six leaves "config" or "fleet". `ts`/`by` are the flag's own
# provenance, empty when every field for that provider is "config" (no flag,
# or the flag does not name this provider). Read by `mix_provider_status_json`
# below; never written anywhere but here.
declare -gA MIX_SOURCE=()

# mix_lane_present PROVIDER LANE
# Prints "true"/"false" when PROVIDER's substrate (PROVIDER_SUBSTRATE,
# lib/model-id.sh) has an adapter-level presence check for LANE — the same
# `substrate_<name>_lane_present` `lib/stage-run.sh`'s `stage_lane_any_present`
# calls — or nothing at all (and returns 1) when the substrate is unknown or
# ships no such check yet (every substrate but `claude-code` today, #2246).
# A thin wrapper rather than a call through lib/stage-run.sh, so a caller that
# wants presence without the whole launcher (scripts/node-health.sh, which
# stays read-only and claude-invocation-free by design) can have it by
# sourcing only the adapter files this needs.
mix_lane_present() {
  local provider="$1" lane="$2" substrate fn
  substrate="${PROVIDER_SUBSTRATE[$provider]:-}"
  [[ -n "$substrate" ]] || return 1
  fn="substrate_${substrate//-/_}_lane_present"
  declare -F "$fn" >/dev/null 2>&1 || return 1
  if "$fn" "$lane"; then printf 'true'; else printf 'false'; fi
}

# mix_build_overlay PROVIDER TOKEN...
# Validates `--mix`'s own trailing tokens — `<lane>=<weight>`,
# `<lane>.enabled=true` or `<lane>.balance_usd=<n>` — and prints the compact
# JSON overlay `mix_write` merges onto the provider's existing entry, e.g.
# `{"subscription":{"weight":30,"enabled":true}}`. A `<lane>.balance_usd`
# assignment stamps `balance_as_of` at the same instant, as the issue's own
# shape requires — the flag's one implicit field no token names directly.
#
# Every fault prints one line to stderr, prefixed the same way
# `config_provider_errors` (lib/config-schema.sh) prefixes a config fault —
# `providers.<name>.lanes.<lane>: <message>` — reusing its own message text
# for `weight`/`enabled`/`balance_usd` (the issue's own "the same validation
# as the config block, with the same messages"), and returns 64 (EX_USAGE),
# the same code every other CLI usage fault in agent-cycle.sh returns. Stops
# at the first fault rather than collecting every one: unlike config.json,
# which a human edits once and wants every fault from in one pass, a `--mix`
# invocation is a single command line a human can simply re-run corrected.
#
# `<lane>.enabled=false` is refused outright, naming `--close-lane` (#2242)
# as the way to actually close a lane (issue #2244's own scope note: this
# lever carries openings and preferences, never a closure) — this is the one
# fault whose message does not mirror a config.json one, since config.json's
# own `enabled: false` is not a fault there at all.
mix_build_overlay() {
  local provider="$1"; shift
  local -a sets=()
  local tok left right lane key now
  now="$(_toggle_iso)"
  for tok in "$@"; do
    if [[ "$tok" != *=* ]]; then
      echo "agent-cycle: --mix: '$tok' is not <lane>=<weight>, <lane>.enabled=true or <lane>.balance_usd=<n>" >&2
      return 64
    fi
    left="${tok%%=*}"
    right="${tok#*=}"
    if [[ "$left" == *.* ]]; then
      lane="${left%%.*}"
      key="${left#*.}"
    else
      lane="$left"
      key="weight"
    fi
    case "$lane" in
      api|subscription) ;;
      *)
        echo "agent-cycle: --mix: unknown lane \"$lane\" (want api or subscription)" >&2
        return 64
        ;;
    esac
    case "$key" in
      weight)
        if ! [[ "$right" =~ ^[0-9]+$ ]]; then
          echo "agent-cycle: --mix: providers.$provider.lanes.$lane: weight must be an integer >= 0" >&2
          return 64
        fi
        sets+=(".${lane}.weight = ${right}")
        ;;
      enabled)
        case "$right" in
          true)
            sets+=(".${lane}.enabled = true")
            ;;
          false)
            echo "agent-cycle: --mix: $provider.$lane.enabled=false is refused — this lever only ever opens a lane or restates a preference, never closes one; use --close-lane to close $provider/$lane by hand (#2242)" >&2
            return 64
            ;;
          *)
            echo "agent-cycle: --mix: providers.$provider.lanes.$lane: enabled must be a boolean" >&2
            return 64
            ;;
        esac
        ;;
      balance_usd)
        if ! [[ "$right" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
          echo "agent-cycle: --mix: providers.$provider.lanes.$lane: balance_usd must be a number" >&2
          return 64
        fi
        sets+=(".${lane}.balance_usd = ${right}" ".${lane}.balance_as_of = \"${now}\"")
        ;;
      *)
        echo "agent-cycle: --mix: unknown key \"$key\" for $provider.$lane (want weight, enabled or balance_usd)" >&2
        return 64
        ;;
    esac
  done
  if (( ${#sets[@]} == 0 )); then
    echo "agent-cycle: --mix $provider needs at least one <lane>=<weight>, <lane>.enabled=true or <lane>.balance_usd=<n>, or --reset" >&2
    return 64
  fi
  local filter="{}" s
  for s in "${sets[@]}"; do filter+=" | $s"; done
  jq -nc "$filter"
}

# mix_write STATE_REPO STATE_DIR PROVIDER OVERLAY_JSON BY [ACTOR]
# Merges OVERLAY_JSON (mix_build_overlay's own output) onto PROVIDER's
# existing lanes entry in fleet/mix.json — field by field, via jq's own `*`,
# the identical recursive-merge operator `providers_load` already uses to
# overlay a lane's config onto its defaults — and writes the result back.
# Every other provider's entry, and every field of this provider's own lanes
# this OVERLAY_JSON does not name, survives untouched: the lever restates
# preferences incrementally across repeated calls, never replaces the whole
# record. Two attempts, re-reading between them, the same shape
# `fleet_limit_publish` (lib/toggle.sh) uses: losing the CAS to a peer's
# concurrent `--mix` converges onto this process's own edit applied after
# theirs, rather than failing outright. Returns non-zero only once both
# attempts fail to write at all.
mix_write() {
  local repo="$1" state_dir="$2" provider="$3" overlay_json="$4" by="$5" actor="${6:-}"
  local cur body
  [[ -n "$actor" ]] || actor="$(toggle_actor)"
  for _ in 1 2; do
    cur="$(fleet_flag_fetch "$repo" "$state_dir" mix)"
    jq -e . >/dev/null 2>&1 <<<"${cur:-{\}}" || cur='{}'
    body="$(jq -nc --argjson cur "${cur:-{\}}" --arg p "$provider" --argjson overlay "$overlay_json" \
      --arg by "$by" --arg actor "$actor" --arg ts "$(_toggle_iso)" '
      (($cur.providers // {})) as $providers |
      ((($providers[$p].lanes) // {}) * $overlay) as $merged |
      {providers: ($providers + {($p): {lanes: $merged}}), by: $by, actor: $actor, ts: $ts}
    ')"
    if fleet_flag_write "$repo" mix "$body" "fleet: mix set for $provider by $by" "$state_dir"; then
      printf '%s' "$body"
      return 0
    fi
  done
  return 1
}

# mix_reset STATE_REPO STATE_DIR PROVIDER BY [ACTOR]
# `--mix <provider> --reset`: removes PROVIDER's own entry, leaving every
# other provider's untouched, and deletes the flag outright once PROVIDER was
# the last one left — `config.json`'s own `providers.<name>.lanes` (or its
# defaults) then governs that provider again, exactly as if the lever had
# never been touched. Prints one of `absent` (there was nothing to reset),
# `deleted` (the whole flag is gone) or `written` (another provider's entry
# still stands). An unparseable flag is reset by deleting it outright rather
# than edited around — this command's whole job is to return to config, and a
# body this cannot parse is not a body it can safely edit one provider out
# of. Two attempts, re-reading between them, the same shape mix_write above
# uses.
mix_reset() {
  local repo="$1" state_dir="$2" provider="$3" by="$4" actor="${5:-}"
  local cur remaining body
  [[ -n "$actor" ]] || actor="$(toggle_actor)"
  for _ in 1 2; do
    cur="$(fleet_flag_fetch "$repo" "$state_dir" mix)"
    if [[ -z "$cur" ]]; then
      printf 'absent'
      return 0
    fi
    if ! jq -e . >/dev/null 2>&1 <<<"$cur"; then
      if fleet_flag_delete "$repo" "$state_dir" mix >/dev/null 2>&1; then
        printf 'deleted'
        return 0
      fi
      continue
    fi
    remaining="$(jq -c --arg p "$provider" '(.providers // {}) | del(.[$p])' <<<"$cur")"
    if [[ "$remaining" == "{}" ]]; then
      if fleet_flag_delete "$repo" "$state_dir" mix >/dev/null 2>&1; then
        printf 'deleted'
        return 0
      fi
    else
      body="$(jq -nc --argjson r "$remaining" --arg by "$by" --arg actor "$actor" --arg ts "$(_toggle_iso)" \
        '{providers: $r, by: $by, actor: $actor, ts: $ts}')"
      if fleet_flag_write "$repo" mix "$body" "fleet: mix reset for $provider by $by" "$state_dir"; then
        printf 'written'
        return 0
      fi
    fi
  done
  return 1
}

# providers_apply_mix STATE_REPO STATE_DIR
# Overlays fleet/mix.json onto PROVIDER_LANES (lib/model-id.sh, already
# populated by providers_load) in place, and populates MIX_SOURCE above.
# Call once, right after providers_load, before anything reads either map.
#
# Follows the fleet-flag family's three failure directions (lib/toggle.sh's
# own header): a 404 (fleet_flag_fetch prints nothing) or an unreachable flag
# with no cache leave PROVIDER_LANES exactly as config resolved it — this
# function is a no-op; an unreachable flag *with* a cache is handled already,
# inside fleet_flag_fetch itself, which hands back the cached bytes
# indistinguishably from a live fetch; and a flag present but too mangled to
# parse as JSON at all also leaves PROVIDER_LANES untouched — but returns 1 so
# the caller can log the `warning` event the issue's own acceptance criteria
# ask for (a silent fallback to config is correct; a silent failure to read
# the operator's own last `--mix` is not). Every other outcome returns 0.
#
# A provider the flag names that config.json's own `providers` (and hence
# PROVIDER_LANES) does not configure at all is skipped outright: there is no
# base lanes object to overlay onto, and restating preferences for a provider
# this node cannot run anyway would only misreport one that was never open to
# begin with.
providers_apply_mix() {
  local repo="$1" state_dir="$2" raw ts by name overlay merged src
  MIX_SOURCE=()
  raw="$(fleet_flag_fetch "$repo" "$state_dir" mix)"
  [[ -n "$raw" ]] || return 0
  if ! jq -e . >/dev/null 2>&1 <<<"$raw"; then
    return 1
  fi
  ts="$(jq -r '.ts // ""' <<<"$raw" 2>/dev/null)"
  by="$(jq -r '.by // ""' <<<"$raw" 2>/dev/null)"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ -n "${PROVIDER_LANES[$name]+set}" ]] || continue
    overlay="$(jq -c --arg p "$name" '.providers[$p].lanes // {}' <<<"$raw" 2>/dev/null)"
    [[ -n "$overlay" && "$overlay" != "null" ]] || continue
    merged="$(jq -nc --argjson base "${PROVIDER_LANES[$name]}" --argjson ov "$overlay" '$base * $ov' 2>/dev/null)"
    [[ -n "$merged" ]] || continue
    PROVIDER_LANES["$name"]="$merged"
    src="$(jq -nc --argjson ov "$overlay" --arg ts "$ts" --arg by "$by" '
      {ts: $ts, by: $by} + (
        reduce (["api","subscription"][]) as $l ({};
          . + {($l): {
            weight:  (if (($ov[$l].weight)  != null) then "fleet" else "config" end),
            enabled: (if (($ov[$l].enabled) != null) then "fleet" else "config" end),
            balance: (if (($ov[$l].balance_usd) != null) then "fleet" else "config" end)
          }}
        )
      )')"
    MIX_SOURCE["$name"]="$src"
  done < <(jq -r '.providers // {} | keys[]' <<<"$raw" 2>/dev/null)
  return 0
}

# mix_provider_status_json PROVIDER
# The one object both `--status` (lib/manage.sh's mix_status_report) and
# `scripts/node-health.sh --metrics` render PROVIDER's effective mix from
# (requirement 34a) — built from PROVIDER_LANES/MIX_SOURCE as
# providers_apply_mix above left them:
#
#   {
#     "api":          {"weight": 1, "enabled": null, "present": true,  "state": "open"},
#     "subscription": {"weight": 0, "enabled": null, "present": false, "state": "closed"},
#     "source": {"ts": "...", "by": "...",
#                "api": {"weight": "config", "enabled": "config", "balance": "config"},
#                "subscription": {...}}
#   }
#
# `present` is `null` (not `true`/`false`) when PROVIDER's substrate ships no
# presence check at all (mix_lane_present above) — never fabricated as
# closed. `source` is omitted entirely when every field for PROVIDER reads
# "config" (MIX_SOURCE carries no entry, or providers_apply_mix was never
# called) — the common case, and the one `--status` renders most plainly.
mix_provider_status_json() {
  local provider="$1" lanes_json api_p=0 sub_p=0 api_present sub_present api_open=false sub_open=false
  lanes_json="${PROVIDER_LANES[$provider]:-$STAGE_LANE_DEFAULT_JSON}"
  api_present="$(mix_lane_present "$provider" api)"
  [[ "$api_present" == "true" ]] && api_p=1
  sub_present="$(mix_lane_present "$provider" subscription)"
  [[ "$sub_present" == "true" ]] && sub_p=1
  lane_effective_open "$lanes_json" api "$api_p" "$sub_p" && api_open=true
  lane_effective_open "$lanes_json" subscription "$api_p" "$sub_p" && sub_open=true
  jq -nc --argjson lanes "$lanes_json" \
    --arg api_present "$api_present" --arg sub_present "$sub_present" \
    --argjson api_open "$api_open" --argjson sub_open "$sub_open" \
    --argjson source "${MIX_SOURCE[$provider]:-null}" '
    def pbool(s): if s == "true" then true elif s == "false" then false else null end;
    {
      api: {weight: ($lanes.api.weight // 1), enabled: ($lanes.api.enabled // null),
            present: pbool($api_present), state: (if $api_open then "open" else "closed" end)},
      subscription: {weight: ($lanes.subscription.weight // 0), enabled: ($lanes.subscription.enabled // null),
            present: pbool($sub_present), state: (if $sub_open then "open" else "closed" end)}
    } + (if $source != null then {source: $source} else {} end)
  '
}

# mix_status_text
# The human-facing report both `agent-cycle.sh --mix` (no arguments) and
# `--status` (lib/manage.sh's mix_status_report) print: one line per lane,
# per provider, naming its weight, its resolved `enabled` ("yes"/"no"/
# "default" — D4's own unset-means-the-CLI's-own-default reading,
# `scripts/doctor.sh`'s `lane_enabled_desc` vocabulary), whether its
# credential is present on this node, its effective open/closed state, and
# which side supplied it — "config" or "fleet/mix.json, set <ts> by <actor>"
# — resolved per lane, per field, from `mix_provider_status_json`'s own
# `source` object, since one provider's two lanes (or one lane's weight
# against its own `enabled`) can easily be governed by different sides at
# once. No provider at all (providers_load found none, which never actually
# happens — `anthropic` always synthesizes) prints a one-line fallback rather
# than an empty block.
mix_status_text() {
  local fleet_json name
  fleet_json="$(mix_fleet_status_json)"
  if [[ "$fleet_json" == "{}" ]]; then
    printf 'no provider configured\n'
    return 0
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    jq -r --arg n "$name" '
      .[$n] as $p |
      ($p.source // null) as $src |
      # `enabled: null` means "D4'\''s own unset default applies" — reported
      # "default", never "unknown": this value is always resolved, config
      # simply did not name it explicitly. `present: null`, in contrast,
      # means this node'\''s substrate ships no presence check at all
      # (mix_lane_present) — genuinely unanswerable, so "unknown" rather than
      # a guessed default.
      def enabled_desc(v): if v == true then "yes" elif v == false then "no" else "default" end;
      def present_desc(v): if v == true then "yes" elif v == false then "no" else "unknown" end;
      def source_of($lane; $field):
        if $src == null then "config"
        elif ($src[$lane][$field] // "config") == "fleet"
        then "fleet/mix.json, set " + ($src.ts // "?") + " by " + ($src.by // "?")
        else "config" end;
      ["api","subscription"][] as $lane |
      $p[$lane] as $l |
      "  \($n) \($lane): weight=\($l.weight) (\(source_of($lane; "weight"))) enabled=\(enabled_desc($l.enabled)) (\(source_of($lane; "enabled"))) present=\(present_desc($l.present)) state=\($l.state)"
    ' <<<"$fleet_json"
  done < <(jq -r 'keys[]' <<<"$fleet_json" | sort)
}

# mix_fleet_status_json
# `{<provider>: mix_provider_status_json(<provider>), ...}` for every
# provider `providers_load` populated — the whole-fleet object
# `scripts/node-health.sh --metrics` embeds verbatim as its own `mix` field.
mix_fleet_status_json() {
  local name
  local -a parts=()
  for name in "${!PROVIDER_LANES[@]}"; do
    parts+=("$(jq -nc --arg n "$name" --argjson v "$(mix_provider_status_json "$name")" '{($n): $v}')")
  done
  if (( ${#parts[@]} == 0 )); then
    printf '{}'
    return 0
  fi
  jq -nc --argjson parts "$(printf '%s\n' "${parts[@]}" | jq -s '.')" 'reduce $parts[] as $p ({}; . + $p)'
}
