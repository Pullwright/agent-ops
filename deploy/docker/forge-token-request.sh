#!/bin/bash
#
# deploy/docker/forge-token-request.sh — installed root-owned, by the
# Dockerfile, as /usr/local/libexec/agent-ops/forge-token-request, and named
# by `PW_GH_TOKEN_BROKER` in every stage's environment
# (deploy/docker/stage-exec.sh). lib/gh-shim.sh runs it, as the stage user,
# in place of minting a token itself, which a stage cannot do because it
# cannot read the App's key (requirement 45e). It asks for one through the
# sudoers rule that lets the stage user run deploy/docker/forge-token.sh as
# the Script's user, and prints whatever that prints.
#
# Usage: forge-token-request [OWNER]

exec sudo -n -u agent /usr/local/libexec/agent-ops/forge-token "$@"
