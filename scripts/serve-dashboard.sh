#!/usr/bin/env bash
#
# serve-dashboard.sh — optional loopback-only web server for the dashboard.
# Use this only if your browser refuses to load data.js over a file:// URL;
# otherwise scripts/open-dashboard.sh (file://) needs no server at all.
#
# Usage: serve-dashboard.sh [port] [bind-address]
#
# Binds 127.0.0.1 by default: the page answers on this machine's loopback and on
# no network. The bind address is a setting only so that a container can keep
# that same guarantee — a server bound to the *container's* loopback is
# reachable from nothing, so deploy/docker/compose.yaml's `local` profile binds
# 0.0.0.0 inside the container and publishes the port on the host's loopback
# alone (127.0.0.1:<port>:8787). Widening the bind on a host is a different
# thing entirely, and is never what this script is for.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
usage: serve-dashboard.sh [port] [bind-address]

Optional loopback-only web server for the dashboard. Use this only if your
browser refuses to load data.js over a file:// URL; otherwise
scripts/open-dashboard.sh (file://) needs no server at all.

  port           TCP port to serve on (default 8787).
  bind-address   Address to bind (default 127.0.0.1). A server bound to a
                 container's own loopback is reachable from nothing, which
                 is why deploy/docker/compose.yaml's `local` profile passes
                 0.0.0.0 here and publishes the port on the host's loopback
                 alone instead. Widening the bind on a host is a different
                 thing entirely, and is never what this flag is for.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

port="${1:-8787}"
bind="${2:-127.0.0.1}"

expand_home() { local p="$1"; [[ "$p" == "~"* ]] && p="$HOME${p:1}"; printf '%s\n' "$p"; }
state_dir="$(expand_home "$(jq -r '.state_dir' "$SCRIPT_DIR/config.json")")"
dir="$state_dir/dashboard"

[[ -f "$dir/index.html" ]] || "$SCRIPT_DIR/scripts/publish-dashboard.sh" || true
[[ -d "$dir" ]] || { echo "serve-dashboard: nothing to serve at $dir" >&2; exit 1; }

# Self-measured resource sampling for `dashboard`/`dashboard-local`
# (requirement 55, D14, issue #606): unlike `scheduler`, neither profile
# runs supercronic — this script's own `exec` below replaces the container's
# PID 1 with the HTTP server directly — so there is no crontab line for
# scripts/collect-resource-usage.sh to run from in here. A small background
# loop before the exec is the substitute, on the same interval
# schedule.resource_sample_minutes gives the scheduler's own crontab line;
# it is started only when AGENT_OPS_SERVICE is set (this script running
# inside the compose container), never for a human running this on a
# laptop to browse the dashboard, where it would have no business sampling
# resource usage at all. `disown` detaches it from this shell's own job
# table so the `exec` below (which replaces this process image, not this
# job) leaves it running as an ordinary orphaned child, reparented the same
# way any backgrounded process outlives an `exec`'d parent.
#
# The loop lives exactly as long as the server it samples for, and no
# longer: `exec` keeps this shell's pid, so `$$` — which inside `( … )`
# names the invoking shell, not the subshell — is the server's own pid once
# python has replaced this image, and the loop stops the moment that pid is
# gone, polling every ten seconds rather than sleeping the whole interval
# blind. Without that, a server killed by anything other than the container
# stopping left the loop running for ever (2026-09-15: six of them on
# poetic-2's scheduler, two per run of test/dashboard-exposure.test.sh,
# which starts this script inside the scheduler where AGENT_OPS_SERVICE is
# set, kills the server and moves on), each still calling the collector
# every five minutes against a HOME the test had already removed.
if [[ -n "${AGENT_OPS_SERVICE:-}" ]]; then
  resource_sample_minutes="$(jq -r '.schedule.resource_sample_minutes // 5' "$SCRIPT_DIR/config.json" 2>/dev/null)"
  [[ "$resource_sample_minutes" =~ ^[0-9]+$ ]] && (( resource_sample_minutes > 0 )) || resource_sample_minutes=5
  (
    server_pid=$$
    while kill -0 "$server_pid" 2>/dev/null; do
      for (( waited = 0; waited < resource_sample_minutes * 60; waited += 10 )); do
        sleep 10
        kill -0 "$server_pid" 2>/dev/null || exit 0
      done
      "$SCRIPT_DIR/scripts/collect-resource-usage.sh" >> "$state_dir/resource-usage.log" 2>&1 || true
    done
  ) &
  disown
fi

echo "Serving $dir at http://$bind:$port  (Ctrl-C to stop)"
cd "$dir" && exec python3 -m http.server "$port" --bind "$bind"
