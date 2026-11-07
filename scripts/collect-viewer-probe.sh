#!/usr/bin/env bash
#
# scripts/collect-viewer-probe.sh — the viewer-probe sidecar (owner decision
# #1358, agent-ops#2788): the tailnet-only half of the viewer-vantage probe
# `lib/host-facts.sh` already runs, moved into its own container because the
# `collector` service (every node, every profile) carries no tailnet route of
# its own. Shares the `tailscale` sidecar's network namespace
# (`deploy/docker/compose.yaml`'s `viewer-probe` service, `profiles:
# [tailnet]`), the same way `dashboard` does, so it reaches a peer's
# `data.js` with no credential of its own.
#
# Run this from the sidecar's own container, on the collector's own cadence
# (AGENT_OPS_COLLECTOR_INTERVAL_SECONDS — see that service's own loop in
# compose.yaml). It writes state_dir/viewer-probe/<node>.json atomically
# (temp file, then `mv`); scripts/collect-host-facts.sh folds that file into
# its own `viewer_probe` section when it is present and fresh
# (lib/host-facts.sh's host_facts_viewer_probe_fold_json), falling back to
# its own direct probe otherwise (docs/reference/host-facts-schema.md).
#
# Never returns non-zero for a degraded probe entry — the same "null, never
# fabricated" contract lib/host-facts.sh's own header states — but does exit
# non-zero when the record could not be written at all, since that is this
# script's own job failing outright rather than one entry within it
# degrading.
#
# Exit: 0 the record was collected (and written, unless --print) · 2 usage
#         error, or the record could not be written.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/config-access.sh
. "$SCRIPT_DIR/lib/config-access.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/host-facts.sh
. "$SCRIPT_DIR/lib/host-facts.sh"

usage() {
  cat >&2 <<'USAGE'
usage: collect-viewer-probe.sh [--print]

Run the viewer-vantage probe (docs/reference/host-facts-schema.md's
`viewer_probe`) from inside the tailscale sidecar's own network namespace,
and write the result to state_dir/viewer-probe/<node>.json, atomically.
scripts/collect-host-facts.sh folds it into its own record when present and
fresh.

  --print    write the record to stdout instead of the file (manual/CI use)

Exit 0 collected (and written, unless --print); 2 usage error, or the record
could not be written.
USAGE
}

print_only=0
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --print) print_only=1; shift ;;
    *) echo "collect-viewer-probe: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)" || {
  echo "collect-viewer-probe: could not read $CONFIG_FILE against $SCHEMA_FILE" >&2
  exit 2
}
# `cfg` and `expand_home` come from lib/config-access.sh, sourced above —
# the same two helpers scripts/collect-host-facts.sh reads its own config
# through.
state_dir="$(expand_home "$(cfg '.state_dir')")"
workspace_root="$(expand_home "$(cfg '.workspace_root')")"

node="$(host_facts_node_name)"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Every peer this node's own state-sync fetch has ever materialised, plus
# itself — the same enumeration scripts/collect-host-facts.sh's own
# direct-probe fallback uses, so the two can never disagree about who is a
# target (agent-ops#1286).
peers_dir="$(fleet_peers_dir "$workspace_root")"
node_list="$node"
if [[ -d "$peers_dir" ]]; then
  for d in "$peers_dir"/*/; do
    [[ -d "$d" ]] || continue
    peer="$(basename "$d")"
    [[ "$peer" == "$node" ]] || node_list="$node_list"$'\n'"$peer"
  done
fi

url_template="$(host_facts_viewer_url_template)"
viewer_probe_json="$(host_facts_viewer_probe_json "$node_list" "$url_template")"

record="$(jq -nc --arg generated_at "$generated_at" --argjson viewer_probe "$viewer_probe_json" \
  '{generated_at:$generated_at, viewer_probe:$viewer_probe}')"

if (( print_only )); then
  printf '%s\n' "$record"
  exit 0
fi

out_dir="$state_dir/viewer-probe"
mkdir -p "$out_dir" 2>/dev/null || {
  echo "collect-viewer-probe: cannot create $out_dir" >&2
  exit 2
}
out_file="$out_dir/$node.json"
if printf '%s\n' "$record" > "$out_file.tmp.$$" 2>/dev/null; then
  mv -f "$out_file.tmp.$$" "$out_file"
else
  echo "collect-viewer-probe: could not write $out_file" >&2
  rm -f "$out_file.tmp.$$" 2>/dev/null
  exit 2
fi
