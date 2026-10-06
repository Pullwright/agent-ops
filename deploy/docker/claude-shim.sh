#!/bin/bash
#
# deploy/docker/claude-shim.sh — installed root-owned, by the Dockerfile, as
# /usr/local/bin/claude, ahead of the real CLI (/usr/bin/claude) on PATH, the
# same way scripts/gh-shim.sh stands in front of `gh`.
#
# Every `claude` this image runs therefore runs as the stage user
# (requirement 45e of docs/IMPLEMENTATION-PIPELINE-SPEC.md): each stage
# lib/stage-run.sh launches, the limit probe, `doctor.sh`'s version and
# authentication checks, and an operator's interactive
# `docker compose exec scheduler claude`. That user owns the Claude
# configuration, and it cannot read the GitHub Apps' keys, the Script's
# environment or the token cache, or write the Script's code or state.
#
# Run as the stage user already, it runs the CLI directly.

real=/usr/bin/claude

if [[ "$(id -un)" == stage ]]; then
  exec "$real" "$@"
fi
exec sudo -n -u stage /usr/local/libexec/agent-ops/stage-exec "$real" "$@"
