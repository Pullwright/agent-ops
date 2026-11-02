#!/usr/bin/env bash
#
# scripts/background-wait-guard.sh — the executable Claude Code's managed
# `PreToolUse` hook (`deploy/docker/claude-managed-settings.json`) invokes.
# All of the logic lives in lib/background-wait-guard.sh, which this only
# sources and calls; see that file's own header for what it denies and why.
#
# Installed in the image at the fixed path /app/scripts/background-wait-guard.sh
# (deploy/docker/Dockerfile's COPY --chown=agent:agent . /app), which is what
# the managed policy's hooks.PreToolUse command names — independent of
# whatever repository a stage's own working directory happens to be a
# checkout of.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=lib/background-wait-guard.sh
. "$SCRIPT_DIR/lib/background-wait-guard.sh"

background_wait_guard_main
exit $?
