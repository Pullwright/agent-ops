#!/usr/bin/env bash
#
# lib/resource-usage.sh — this container's own CPU, memory and network
# counters, plus a volume's own disk usage, and the derivation that turns a
# window of samples into the per-container/per-volume report requirement 55
# publishes (D14, issue #606).
#
# ## Why self-measurement, not the host-facts collector's vantage
#
# `scripts/collect-host-facts.sh` already reads `memory.current`/
# `cpu.limit_nanos` for every container on the host, but only from the
# `collector` service's own Docker-socket vantage (agent-ops#603 keeps that
# socket out of every other container). Extending that path to cumulative
# CPU usage, disk and bandwidth would still leave `tailscale` and
# `watchtower` unmeasurable — neither carries this repository's own scripts
# — so the same gap remains either way. `scheduler`, `dashboard` and
# `dashboard-local` run this image and can read their own cgroup and
# `/proc/net/dev` directly, needing no socket and no cross-container path
# resolution at all; that is what every function below does. Reaching
# `tailscale`/`watchtower` — and `egress-proxy`/`collector`/`reconciler`,
# which run this image but have no analogous hook — is deferred
# (agent-ops#1563).
#
# ## Both cgroup layouts, because the fleet is not uniform
#
# One node in this fleet presents cgroup v1 (`/sys/fs/cgroup/memory/
# memory.usage_in_bytes`, `/sys/fs/cgroup/cpuacct/cpuacct.usage`); others
# present v2 (`/sys/fs/cgroup/memory.current`, `/sys/fs/cgroup/cpu.stat`).
# `lib/memory.sh`'s own cgroup reads are v2-only, which is fine for a check
# that is advisory and already degrades to `unknown` off v2 — but a
# collector that only ever reports zero-or-nothing for half the fleet would
# read as "these containers use no memory," a false floor rather than an
# honest unknown. Every read below takes the layout as an argument
# (`resource_cgroup_version`'s own output) rather than assuming one, and
# returns empty — never `0` — when the layout is `unknown` or the expected
# file is missing.
#
# ## Cumulative counters, and the delta discipline
#
# CPU usage and network byte counts are cumulative since the cgroup/
# interface was created — they reset to zero on every container recreation.
# `resource_cpu_cores`/`resource_rate_per_hour` below both take two samples
# and refuse to report a rate when the later value is smaller than the
# earlier one (a recreation happened in between): reporting the negative
# delta a naive subtraction would produce is worse than reporting nothing,
# the same "no evidence is not evidence" discipline `lib/host-budget.sh`
# already holds for an unmeasured ceiling.

# --- cgroup layout detection -------------------------------------------------

# resource_cgroup_version ROOT
# "v2" when ROOT/cgroup.controllers exists (the unified hierarchy's own
# marker file), "v1" when ROOT/memory/memory.usage_in_bytes exists (the
# legacy per-controller layout), else "unknown". ROOT defaults to
# /sys/fs/cgroup; overridable so tests can point it at a fixture tree
# instead of the live one.
resource_cgroup_version() {
  local root="${1:-/sys/fs/cgroup}"
  if [[ -f "$root/cgroup.controllers" ]]; then
    printf 'v2'
  elif [[ -f "$root/memory/memory.usage_in_bytes" ]]; then
    printf 'v1'
  else
    printf 'unknown'
  fi
}

# --- instantaneous / cumulative reads ---------------------------------------

# resource_memory_current_bytes ROOT VERSION
# This cgroup's current memory usage in bytes, or empty when VERSION is
# "unknown" or the expected file cannot be read.
resource_memory_current_bytes() {
  local root="${1:-/sys/fs/cgroup}" version="${2:-}" value
  case "$version" in
    v2) value="$(cat "$root/memory.current" 2>/dev/null)" ;;
    v1) value="$(cat "$root/memory/memory.usage_in_bytes" 2>/dev/null)" ;;
    *) return 0 ;;
  esac
  [[ "$value" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$value"
}

# resource_cpu_usage_nanos ROOT VERSION
# This cgroup's cumulative CPU time in nanoseconds since it was created —
# v2's cpu.stat `usage_usec` field (microseconds, scaled up to match v1's
# own unit), v1's cpuacct.usage (already nanoseconds) — or empty when
# VERSION is "unknown" or the expected file cannot be read. Cumulative:
# see this file's own header on why a caller takes a delta, never the
# absolute value.
resource_cpu_usage_nanos() {
  local root="${1:-/sys/fs/cgroup}" version="${2:-}" value
  case "$version" in
    v2)
      value="$(awk '$1 == "usage_usec" {print $2; exit}' "$root/cpu.stat" 2>/dev/null)"
      [[ "$value" =~ ^[0-9]+$ ]] || return 0
      printf '%s' $(( value * 1000 ))
      ;;
    v1)
      value="$(cat "$root/cpuacct/cpuacct.usage" 2>/dev/null)"
      [[ "$value" =~ ^[0-9]+$ ]] || return 0
      printf '%s' "$value"
      ;;
    *) return 0 ;;
  esac
}

# resource_net_bytes DEV_FILE
# {"rx":N,"tx":N} — cumulative bytes summed across every interface DEV_FILE
# lists except loopback (/proc/net/dev's own format; DEV_FILE defaults to
# /proc/net/dev and is overridable for tests), or the JSON `null` when the
# file cannot be read at all. Cumulative, like resource_cpu_usage_nanos —
# a caller takes a delta.
resource_net_bytes() {
  local dev_file="${1:-/proc/net/dev}"
  [[ -r "$dev_file" ]] || { printf 'null'; return 0; }
  awk '
    NR > 2 {
      line = $0
      # /proc/net/dev glues the interface name to the following colon with
      # no space ("  eth0:1234 ..."), so the field count a plain split()
      # would see is off by one versus every data line after it — stripped
      # here, along with the whitespace it leaves behind (the regex form of
      # split, unlike the default single-space FS, does not trim a leading
      # separator, which would otherwise shift every index below by one),
      # rather than relied on as $1/$2.
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", line)
      n = split(line, f, /[[:space:]]+/)
      if (n < 9) next
      iface = $1; sub(/:.*/, "", iface)
      if (iface == "lo") next
      rx += f[1] + 0
      tx += f[9] + 0
      seen = 1
    }
    END { if (seen) printf "{\"rx\":%d,\"tx\":%d}", rx, tx; else print "null" }
  ' "$dev_file" 2>/dev/null || printf 'null'
}

# resource_disk_usage_bytes PATH
# `du -sb PATH`'s own total, in bytes, or empty when PATH does not exist or
# `du` fails. Never a fabricated `0` for "unreadable" — the same contract
# `disk_space_free_kb` already holds.
resource_disk_usage_bytes() {
  local path="${1:-}" value
  [[ -n "$path" && -e "$path" ]] || return 0
  value="$(du -sb "$path" 2>/dev/null | awk '{print $1; exit}')"
  [[ "$value" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$value"
}

# --- delta / rate arithmetic -------------------------------------------------

# resource_cpu_cores PREV_NANOS PREV_TS CUR_NANOS CUR_TS
# Average CPU cores consumed between two resource_cpu_usage_nanos samples —
# delta CPU-nanoseconds over delta wall-clock seconds (PREV_TS/CUR_TS are
# Unix epoch seconds) — printed to 4 decimal places, or empty when any
# argument is missing/non-numeric, the elapsed time is not positive, or
# CUR_NANOS is smaller than PREV_NANOS (the container was recreated between
# samples, so there is no valid baseline yet — see this file's header).
resource_cpu_cores() {
  local prev_nanos="${1:-}" prev_ts="${2:-}" cur_nanos="${3:-}" cur_ts="${4:-}" elapsed
  [[ "$prev_nanos" =~ ^[0-9]+$ && "$prev_ts" =~ ^[0-9]+$ \
     && "$cur_nanos" =~ ^[0-9]+$ && "$cur_ts" =~ ^[0-9]+$ ]] || return 0
  elapsed=$(( cur_ts - prev_ts ))
  (( elapsed > 0 )) || return 0
  (( cur_nanos >= prev_nanos )) || return 0
  awk -v d="$(( cur_nanos - prev_nanos ))" -v e="$elapsed" \
    'BEGIN { printf "%.4f", d / (e * 1000000000) }'
}

# resource_rate_per_hour PREV_VALUE PREV_TS CUR_VALUE CUR_TS
# CUR_VALUE's own unit per hour, between two cumulative-counter samples
# (PREV_TS/CUR_TS Unix epoch seconds) — the network-bytes counterpart of
# resource_cpu_cores, identical degrade-to-empty and recreated-container
# guard.
resource_rate_per_hour() {
  local prev_value="${1:-}" prev_ts="${2:-}" cur_value="${3:-}" cur_ts="${4:-}" elapsed
  [[ "$prev_value" =~ ^[0-9]+$ && "$prev_ts" =~ ^[0-9]+$ \
     && "$cur_value" =~ ^[0-9]+$ && "$cur_ts" =~ ^[0-9]+$ ]] || return 0
  elapsed=$(( cur_ts - prev_ts ))
  (( elapsed > 0 )) || return 0
  (( cur_value >= prev_value )) || return 0
  awk -v d="$(( cur_value - prev_value ))" -v e="$elapsed" \
    'BEGIN { printf "%.0f", d * 3600 / e }'
}

# --- report derivation -------------------------------------------------------

# resource_budget_report SAMPLES_JSONL WINDOW_START_ISO
# The compact per-container/per-volume summary this feature publishes: for
# every container name any sample carries under `service`, `{latest,
# median, p95}` of `cpu_cores`, `memory_bytes`, `net_rx_bytes_per_hour` and
# `net_tx_bytes_per_hour`; for every volume name any sample carries under
# `volume`, `{latest, growth_bytes_per_day}` of `disk_bytes` — `latest` the
# newest sample's own value, `growth_bytes_per_day` a straight line between
# the window's oldest and newest disk sample (never a regression — disk is
# sampled hourly at most, so two points is the ordinary case). `median`/
# `p95` use the nearest-rank method (the value at index
# floor(p * (n-1)) of the sorted sample array), not interpolated, so a
# reader can point at the one real sample that produced the figure.
#
# SAMPLES_JSONL is newline-delimited JSON, one object per line, each
# carrying `ts` (RFC 3339) plus either `service` or `volume` and its own
# resource fields; a line that is not valid JSON, or parses to something
# other than an object, is skipped rather than failing the whole report —
# the same discipline test/pickup-metrics.test.sh already exercises for
# log.jsonl. WINDOW_START_ISO empty means no lower bound (every sample
# counts). Degrades to `{"containers":{},"volumes":{},"sample_count":0,
# "window_start":null}` on an empty or entirely-unparseable input, never a
# jq failure — a caller folding this into a heartbeat or a doctor pass must
# get one valid object every time, exactly as lib/metering.sh's own
# metering_fields does for a missing stage envelope.
resource_budget_report() {
  local samples="${1:-}" window_start="${2:-}"
  jq -Rrsc --arg ws "$window_start" '
    def nearest_rank_pctl($p):
      sort as $s
      | ($s | length) as $n
      | if $n == 0 then null else $s[(($p * ($n - 1)) | floor)] end;

    def field_stats(f):
      (map(select((.[f]? // null) | type == "number"))) as $rows
      | if ($rows | length) == 0 then null
        else {
          latest: ($rows | sort_by(.ts) | last | .[f]),
          median: ($rows | map(.[f]) | nearest_rank_pctl(0.5)),
          p95: ($rows | map(.[f]) | nearest_rank_pctl(0.95))
        }
        end;

    ( split("\n") | map(select(length > 0))
      | map(try fromjson catch null) | map(select(. != null and type == "object"))
    ) as $all
    | ( $all | map(select($ws == "" or ((.ts? // "") >= $ws))) ) as $w
    | ( $w | map(select(.service? != null)) | group_by(.service)
        | map({ key: (.[0].service), value: {
              cpu_cores: (. | field_stats("cpu_cores")),
              memory_bytes: (. | field_stats("memory_bytes")),
              net_rx_bytes_per_hour: (. | field_stats("net_rx_bytes_per_hour")),
              net_tx_bytes_per_hour: (. | field_stats("net_tx_bytes_per_hour"))
            } })
        | from_entries
      ) as $containers
    | ( $w | map(select(.volume? != null)) | group_by(.volume)
        | map({ key: (.[0].volume), value: (
              (sort_by(.ts) | map(select((.disk_bytes? // null) | type == "number"))) as $d
              | if ($d | length) == 0 then null
                else {
                  latest: ($d | last | .disk_bytes),
                  growth_bytes_per_day: (
                    if ($d | length) < 2 then null
                    else
                      ($d | first) as $f | ($d | last) as $l
                      | (($l.ts | fromdateiso8601) - ($f.ts | fromdateiso8601)) as $elapsed
                      | if $elapsed <= 0 then null
                        else ((($l.disk_bytes - $f.disk_bytes) * 86400 / $elapsed) | round)
                        end
                    end
                  )
                }
                end
            ) })
        | from_entries
      ) as $volumes
    | { containers: $containers, volumes: $volumes,
        sample_count: ($w | length),
        window_start: (if $ws == "" then null else $ws end) }
  ' <<<"$samples"
}

# resource_budget_breaches REPORT_JSON BUDGETS_JSON
# The comparison `scripts/doctor.sh`'s "Resource budgets" section and
# `dashboard/index.html`'s `resourcesLine` both make, factored out as one
# pure function so the two can never disagree about what counts as a
# breach — the same reason `lib/host-budget.sh` exists as a separate file
# from `scripts/doctor.sh`'s own host-budget section. REPORT_JSON is
# `resource_budget_report`'s own output; BUDGETS_JSON is `config.json`'s
# `resources` object (`{containers: {...}, volumes: {...}}`), already
# schema-defaulted.
#
# Prints a JSON array, one entry per breach: `{scope: "container"|"volume",
# name, resource, actual, budget}` — `resource` one of `cpu_cores`,
# `memory_bytes`, `net_rx_bytes_per_hour`, `net_tx_bytes_per_hour` (compared
# against the container's own windowed p95) or `disk_bytes` (compared
# against the volume's own latest reading, never p95 — a volume has no
# median/p95 in the report at all, only latest and a growth rate). A
# container or volume the budgets carry no entry for contributes nothing —
# an unbudgeted resource is not a breach, it is simply uncompared — and
# neither does a resource the report has no figure for yet (fewer than one
# sample in the window). Empty array, never null, when nothing breaches or
# either input is empty/malformed: a caller loops over this directly.
resource_budget_breaches() {
  local report="${1:-}" budgets="${2:-}"
  jq -c -n --argjson report "${report:-null}" --argjson budgets "${budgets:-null}" '
    ($report // {containers: {}, volumes: {}}) as $r
    | ($budgets // {containers: {}, volumes: {}}) as $b
    | [
        ( ($r.containers // {}) | to_entries[] ) as $c
        | (($b.containers // {})[$c.key] // {}) as $cb
        | (
            ( if ($cb.cpu_cores? != null) and ($c.value.cpu_cores.p95? != null)
                 and ($c.value.cpu_cores.p95 > $cb.cpu_cores)
              then {scope: "container", name: $c.key, resource: "cpu_cores",
                    actual: $c.value.cpu_cores.p95, budget: $cb.cpu_cores}
              else empty end ),
            ( if ($cb.memory_bytes? != null) and ($c.value.memory_bytes.p95? != null)
                 and ($c.value.memory_bytes.p95 > $cb.memory_bytes)
              then {scope: "container", name: $c.key, resource: "memory_bytes",
                    actual: $c.value.memory_bytes.p95, budget: $cb.memory_bytes}
              else empty end ),
            ( if ($cb.bandwidth_bytes_per_hour? != null) and ($c.value.net_rx_bytes_per_hour.p95? != null)
                 and ($c.value.net_rx_bytes_per_hour.p95 > $cb.bandwidth_bytes_per_hour)
              then {scope: "container", name: $c.key, resource: "net_rx_bytes_per_hour",
                    actual: $c.value.net_rx_bytes_per_hour.p95, budget: $cb.bandwidth_bytes_per_hour}
              else empty end ),
            ( if ($cb.bandwidth_bytes_per_hour? != null) and ($c.value.net_tx_bytes_per_hour.p95? != null)
                 and ($c.value.net_tx_bytes_per_hour.p95 > $cb.bandwidth_bytes_per_hour)
              then {scope: "container", name: $c.key, resource: "net_tx_bytes_per_hour",
                    actual: $c.value.net_tx_bytes_per_hour.p95, budget: $cb.bandwidth_bytes_per_hour}
              else empty end )
          ),
        ( ($r.volumes // {}) | to_entries[] ) as $v
        | (($b.volumes // {})[$v.key] // {}) as $vb
        | ( if ($vb.disk_bytes? != null) and ($v.value.latest? != null)
               and ($v.value.latest > $vb.disk_bytes)
            then {scope: "volume", name: $v.key, resource: "disk_bytes",
                  actual: $v.value.latest, budget: $vb.disk_bytes}
            else empty end )
      ]
  ' 2>/dev/null || printf '[]'
}
