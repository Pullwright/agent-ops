#!/bin/bash
#
# deploy/docker/grok-shim.sh — installed root-owned, by the Dockerfile, as
# /usr/local/bin/grok, ahead of the real CLI (/usr/bin/grok) on PATH, the
# same way deploy/docker/claude-shim.sh stands in front of `claude` (issue
# #2134's own counterpart of requirement 45e, for the `grok-build` substrate).
#
# Every `grok` this image runs therefore runs as the stage user: each
# Grok-Build stage lib/substrate-grok-build.sh launches (through the
# child-subreaper wrapper, deploy/docker/grok-subreaper.py), and `doctor.sh`'s
# own version check. That user owns nothing of the Script's own — no App
# key, no token cache, no Script code — the same boundary Claude Code's
# stages already run inside.
#
# Run as the stage user already, it runs the CLI directly.

real=/usr/bin/grok

if [[ "$(id -un)" == stage ]]; then
  exec "$real" "$@"
fi
exec sudo -n -u stage /usr/local/libexec/agent-ops/stage-exec "$real" "$@"
