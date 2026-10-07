#!/bin/bash
#
# deploy/docker/forge-token.sh — installed root-owned, by the Dockerfile, as
# /usr/local/libexec/agent-ops/forge-token. The stage user runs it as the
# Script's user through the one sudoers rule that allows it
# (deploy/docker/sudoers-agent-ops), to obtain the forge authoring token a
# stage may author with (requirement 45e). Everything it does is in
# lib/forge-token-broker.sh; this file fixes the two things a caller must not
# choose: where the App's identity is read from, and which code reads it.
#
# Usage (as the stage user): sudo -n -u agent /usr/local/libexec/agent-ops/forge-token [OWNER]

set -uo pipefail

if (( $# > 1 )); then
  printf 'forge-token: takes at most one argument, an owner\n' >&2
  exit 2
fi

# shellcheck source=lib/forge-token-broker.sh
. /app/lib/forge-token-broker.sh

forge_token_broker_main /proc/1/environ "${1:-}"
exit $?
