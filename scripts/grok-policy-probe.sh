#!/usr/bin/env bash
#
# scripts/grok-policy-probe.sh — does this machine's `grok` run what a
# checkout plants for it (issue #2134, requirement 4k's Grok counterpart)?
#
# Builds a scratch checkout holding the things a pull-request head could use
# to make a headless Grok stage run something at start-up, under
# `GROK_FOLDER_TRUST=0` — a `.grok/hooks/start.json` hook; a `.claude/settings.json`
# hook, which Grok also runs under its own Claude-compatibility layer; and an
# MCP server each in `.grok/config.toml` and `.mcp.json` — then runs
# `grok inspect` in it, the same command
# docs/reviews/2026-10-06-grok-build-evaluation.md §7/"Project-supplied hooks
# and MCP servers" reads this policy from directly. Unlike `-p`, `inspect`
# needs no credential and reaches no model at all, so this needs no network
# and no stand-in for one: it is Grok's own CLI reporting what its policy
# currently blocks, the most direct reading there is.
#
# Reports whether the project's own instructions and skill still show as
# loaded (which the policy must never block), whether the hooks section
# reports every hook outside managed policy disabled, and whether each
# planted MCP server shows as blocked by policy — the three things
# `requirements.toml`'s own two pins (`allow_managed_hooks_only`,
# `allowed_mcp_servers`) exist to guarantee. `.envrc` is planted alongside
# them for parity with the full set of vectors issue #2134's own
# "What a checkout supplies" section names, but `inspect` reports nothing
# about it one way or the other; that pin (`[session] load_envrc = false`)
# is the one piece of this policy the evaluation record verified directly
# against a real headless run rather than this probe.
#
# In the node image `grok` is the stage shim (deploy/docker/grok-shim.sh), so
# the CLI runs as the stage user, as a stage's does. The scratch checkout is
# therefore shared with that user (`stage_workspace_share`, requirement 45e),
# as the Script shares the Implementer's clone, and removed with
# `stage_workspace_remove`; outside the image both degrade to what they were.
#
# Usage: scripts/grok-policy-probe.sh [--expect blocked|ran]
#   --expect blocked (the default): exit 0 iff both planted MCP servers
#     report blocked, the hooks section reports disabled, and the project
#     instructions and skill still show as loaded — the policy is in force.
#   --expect ran: exit 0 iff neither MCP server reports blocked and the
#     hooks section does not report disabled — the control that shows the
#     probe can see what it is looking for.

set -uo pipefail

expect="blocked"
case "${1:-}" in
  "") ;;
  --expect)
    expect="${2:-}"
    [[ "$expect" == "blocked" || "$expect" == "ran" ]] \
      || { printf 'usage: %s [--expect blocked|ran]\n' "$0" >&2; exit 2; }
    ;;
  *) printf 'usage: %s [--expect blocked|ran]\n' "$0" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/stage-boundary.sh
source "$SCRIPT_DIR/lib/stage-boundary.sh"

probe="$(mktemp -d)"
trap 'stage_workspace_remove "$probe"' EXIT
marks="$probe/marks"
work="$probe/checkout"
mkdir -p "$marks" "$work/.grok/hooks" "$work/.claude/skills/policy-probe"

git -C "$work" init -q
printf '# Policy probe\nReply with the single word: ok\n' >"$work/AGENTS.md"
printf -- '---\nname: policy-probe\ndescription: A skill the probe checks still loads.\n---\n# Policy probe\n' \
  >"$work/.claude/skills/policy-probe/SKILL.md"
jq -n --arg m "$marks" \
  '{hooks: [{event: "SessionStart", command: "touch \($m)/grok-hook"}]}' \
  >"$work/.grok/hooks/start.json"
jq -n --arg m "$marks" \
  '{hooks: {SessionStart: [{hooks: [{type: "command", command: "touch \($m)/claude-settings-hook"}]}]}}' \
  >"$work/.claude/settings.json"
# Grok reads TOML here, not JSON, so this fixture is written directly
# rather than through jq, which the rest of this script uses only where the
# target format is itself JSON.
printf '[mcp_servers.policy-probe]\ncommand = "sh"\nargs = ["-c", "touch %s/grok-config-mcp; exec cat"]\n' \
  "$marks" >"$work/.grok/config.toml"
jq -n --arg m "$marks" \
  '{mcpServers: {"policy-probe-json": {command: "sh", args: ["-c", "touch \($m)/mcpjson-mcp; exec cat"]}}}' \
  >"$work/.mcp.json"
printf 'touch %s/envrc\n' "$marks" >"$work/.envrc"

stage_workspace_share "$probe" \
  || { printf 'grok-policy-probe: cannot share %s with the stage user\n' "$probe" >&2; exit 1; }

(
  cd "$work" || exit 1
  timeout 30 env GROK_FOLDER_TRUST=0 GROK_DISABLE_AUTOUPDATER=1 GROK_TELEMETRY_ENABLED=0 \
    grok inspect
) >"$probe/inspect.out" 2>"$probe/inspect.stderr"
inspect_rc=$?
printf 'grok inspect exit status: %s\n' "$inspect_rc"
cat "$probe/inspect.out"
if [[ -s "$probe/inspect.stderr" ]]; then
  printf 'stderr (first 1000 bytes):\n%s\n' "$(head -c 1000 "$probe/inspect.stderr")"
fi

out="$(cat "$probe/inspect.out" 2>/dev/null)"
trusted="$([[ "$out" == *"Project trusted: yes"* ]] && echo yes || echo no)"
instructions_loaded="$([[ "$out" == *"Project Instructions (0)"* ]] && echo no || echo yes)"
skill_loaded="$([[ "$out" == *"Skills (0)"* ]] && echo no || echo yes)"
hooks_disabled="$([[ "$out" == *"Hooks outside managed policy disabled"* ]] && echo yes || echo no)"
mcp_blocked_count="$(grep -c 'BLOCKED' <<<"$out" || true)"

printf 'trusted: %s\n' "$trusted"
printf 'instructions loaded: %s\n' "$instructions_loaded"
printf 'skill loaded: %s\n' "$skill_loaded"
printf 'hooks reported disabled: %s\n' "$hooks_disabled"
printf 'MCP servers reported blocked: %s\n' "$mcp_blocked_count"

if [[ "$expect" == "blocked" ]]; then
  [[ "$trusted" == yes && "$instructions_loaded" == yes && "$skill_loaded" == yes \
     && "$hooks_disabled" == yes && "$mcp_blocked_count" == 2 ]]
else
  [[ "$trusted" == yes && "$hooks_disabled" == no && "$mcp_blocked_count" == 0 ]]
fi
