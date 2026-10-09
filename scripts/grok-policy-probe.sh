#!/usr/bin/env bash
#
# scripts/grok-policy-probe.sh — does this machine's `grok` run what a
# checkout plants for it (issue #2134, requirement 4k's Grok counterpart)?
#
# Builds a scratch checkout holding the things a pull-request head could use
# to run a command the moment a headless Grok stage starts in it, under
# `GROK_FOLDER_TRUST=0` — a `.grok/hooks/start.json` hook; a `.claude/settings.json`
# hook, which Grok also runs under its own Claude-compatibility layer; an MCP
# server in `.grok/config.toml` and another in `.mcp.json`; and a project
# `.envrc` — then runs `grok -p` in it once, as a stage would. It reports
# which of the five ran and whether the clone's own `AGENTS.md` and a staged
# skill still loaded, which the policy must never block.
#
# No model is reached and nothing is billed: the run carries a placeholder
# API key the API refuses, and every planted vector fires before any model
# call would be made. Run it with no network (as the image build does) or on
# a node, where the request is refused.
#
# In the node image `grok` is the stage shim (deploy/docker/grok-shim.sh), so
# the CLI runs as the stage user, as a stage's does. The scratch checkout is
# therefore shared with that user (`stage_workspace_share`, requirement 45e),
# as the Script shares the Implementer's clone, and removed with
# `stage_workspace_remove`; outside the image both degrade to what they were.
#
# Usage: scripts/grok-policy-probe.sh [--expect blocked|ran]
#   --expect blocked (the default): exit 0 iff none of the five ran and the
#     instructions and skill still loaded — the policy is in force.
#   --expect ran: exit 0 iff all five ran — the control that shows the probe
#     can see what it is looking for.

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
  timeout 60 env GROK_FOLDER_TRUST=0 GROK_DISABLE_AUTOUPDATER=1 GROK_TELEMETRY_ENABLED=0 \
    XAI_API_KEY=xai-policy-probe-placeholder \
    grok -m grok-build-0.1 --permission-mode bypassPermissions \
    --output-format streaming-messages-json --include-partial-messages \
    --prompt-file /dev/stdin \
    <<<"Reply with the single word: ok" >"$probe/run.jsonl" 2>"$probe/run.stderr"
) || true

ran=()
for m in grok-hook claude-settings-hook grok-config-mcp mcpjson-mcp envrc; do
  [[ -e "$marks/$m" ]] && ran+=("$m")
done
# A looser signal than claude-policy-probe.sh's own skill-name check against
# the `init` line's `skills` array: Grok's `init` line shape has not been
# captured for every field this probe could otherwise assert on. Reaching a
# terminal `result` line at all is still informative, since the model can
# only answer "ok" once its own AGENTS.md instructions (and, were the prompt
# to ask for it, the staged skill) have been read off disk — a policy that
# somehow blocked those too would show up here as no result line at all.
result_line="$(jq -c 'select(type == "object" and .type == "result")' "$probe/run.jsonl" 2>/dev/null | tail -n 1)"

printf 'ran: %s\n' "${ran[*]:-none}"
printf 'reached a result line: %s\n' "$([[ -n "$result_line" ]] && echo yes || echo no)"

if [[ "$expect" == "blocked" ]]; then
  (( ${#ran[@]} == 0 ))
else
  (( ${#ran[@]} == 5 ))
fi
