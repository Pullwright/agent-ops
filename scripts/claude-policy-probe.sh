#!/usr/bin/env bash
#
# scripts/claude-policy-probe.sh — does this machine's `claude` run what a
# checkout plants for it (requirement 4k)?
#
# Builds a scratch checkout holding the four things a pull-request head could
# use to run a command the moment a headless stage starts in it — a
# `SessionStart` hook in `.claude/settings.json`; an MCP server in `.mcp.json`,
# approved in the same settings file by `enableAllProjectMcpServers` and
# `enabledMcpjsonServers`, which `run_claude_stage` admits while the managed
# policy is in force; and an inline-shell line in a project command and in a
# project skill — then runs `claude -p` in it twice, as a stage would, once
# invoking the command and once the skill. It reports which of the four ran
# and whether the skill still loaded.
#
# No model is reached and nothing is billed: each run carries a placeholder
# API key that the API refuses, and all four fire before any model call would
# be made. Run it with no network (as the image build does) or on a node,
# where the request is refused. `CLAUDE_CODE_MAX_RETRIES=0` ends a run at its
# first failed request; with no network the client's own back-off would
# otherwise hold each run to the 60-second timeout.
#
# In the node image `claude` is the stage shim (deploy/docker/claude-shim.sh),
# so the CLI runs as the stage user, as a stage's does. The scratch checkout is
# therefore shared with that user (`stage_workspace_share`, requirement 45e),
# as the Script shares the Implementer's clone, and removed with
# `stage_workspace_remove`; outside the image both degrade to what they were.
#
# Usage: scripts/claude-policy-probe.sh [--expect blocked|ran]
#   --expect blocked (the default): exit 0 iff none of the four ran and the
#     skill loaded — the managed policy is in force.
#   --expect ran: exit 0 iff all four ran — the control that shows the probe
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
mkdir -p "$marks" "$work/.claude/skills/policy-probe" "$work/.claude/commands"

git -C "$work" init -q
printf '# Policy probe\n' >"$work/CLAUDE.md"
# shellcheck disable=SC2016  # the backticks are the skill's own inline-shell syntax
printf -- '---\nname: policy-probe\ndescription: A skill the probe checks still loads.\n---\n# Policy probe\n!`touch %s/inline-skill`\n' \
  "$marks" >"$work/.claude/skills/policy-probe/SKILL.md"
jq -n --arg m "$marks" \
  '{hooks: {SessionStart: [{hooks: [{type: "command", command: "touch \($m)/hook"}]}]},
    enableAllProjectMcpServers: true, enabledMcpjsonServers: ["policy-probe"]}' \
  >"$work/.claude/settings.json"
jq -n --arg m "$marks" \
  '{mcpServers: {"policy-probe": {command: "sh", args: ["-c", "touch \($m)/mcp; exec cat"]}}}' \
  >"$work/.mcp.json"
# shellcheck disable=SC2016  # the backticks are the command's own inline-shell syntax
printf 'Policy probe.\n!`touch %s/inline-command`\n' "$marks" >"$work/.claude/commands/policyprobe.md"

stage_workspace_share "$probe" \
  || { printf 'claude-policy-probe: cannot share %s with the stage user\n' "$probe" >&2; exit 1; }

# Invoked as a stage invokes it (requirement 4d), with the project command,
# then the project skill, as the prompt, so that each one's inline shell is
# expanded before any model call. One prompt invokes one of them.
for invoke in policyprobe policy-probe; do
  (
    cd "$work" || exit 1
    timeout 60 env DISABLE_AUTOUPDATER=1 CLAUDE_CODE_MAX_RETRIES=0 ANTHROPIC_API_KEY=sk-ant-api03-policy-probe-placeholder \
      claude -p --dangerously-skip-permissions --output-format stream-json --verbose \
      <<<"/$invoke" >"$probe/$invoke.jsonl" 2>"$probe/$invoke.stderr"
  ) || true
done

ran=()
for m in hook mcp inline-command inline-skill; do
  [[ -e "$marks/$m" ]] && ran+=("$m")
done
skill="$(jq -r 'select(.type == "system" and .subtype == "init")
                | [.skills[]? | select(. == "policy-probe")] | length' \
         "$probe/policyprobe.jsonl" 2>/dev/null | head -n 1)"

printf 'ran: %s\n' "${ran[*]:-none}"
printf 'project skill loaded: %s\n' "$([[ "${skill:-0}" == "1" ]] && echo yes || echo no)"

if [[ "$expect" == "blocked" ]]; then
  (( ${#ran[@]} == 0 )) && [[ "${skill:-0}" == "1" ]]
else
  (( ${#ran[@]} == 4 ))
fi
