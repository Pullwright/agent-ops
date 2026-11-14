#!/usr/bin/env bash
#
# scripts/background-wait-guard.sh — the executable Claude Code's managed
# `PreToolUse` hook (`deploy/docker/claude-managed-settings.json`) invokes.
# All of the logic lives in lib/background-wait-guard.sh, which this only
# sources and calls; see that file's own header for what it denies and why.
#
# Installed root-owned, outside /app (which `agent` owns), at the fixed path
# /etc/claude-code/background-wait-guard/scripts/background-wait-guard.sh
# (deploy/docker/Dockerfile's managed-policy RUN block, alongside the policy
# itself), which is what the managed policy's hooks.PreToolUse command names
# — independent of whatever repository a stage's own working directory
# happens to be a checkout of, and not rewritable by a stage the way the
# /app checkout it came from is (issue #2801).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=lib/background-wait-guard.sh
. "$SCRIPT_DIR/lib/background-wait-guard.sh"

background_wait_guard_main
exit $?
