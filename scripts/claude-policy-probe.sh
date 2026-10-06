#!/usr/bin/env bash
#
# scripts/claude-policy-probe.sh — does this machine's `claude` run what a
# checkout plants for it (requirement 4k)?
#
# Builds a scratch checkout holding the three things a pull-request head could
# use to run a command the moment a headless stage starts in it — a
# `SessionStart` hook in `.claude/settings.json`, an MCP server in `.mcp.json`,
# and a project command with an inline-shell line — plus a project skill, then
# runs `claude -p` in it once, as a stage would, and reports which of the
# three ran and whether the skill still loaded.
#
# No model is reached and nothing is billed: the run carries a placeholder API
# key that the API refuses, and all three fire before any model call would be
# made. Run it with no network (as the image build does) or on a node, where
# the request is refused.
#
# Usage: scripts/claude-policy-probe.sh [--expect blocked|ran]
#   --expect blocked (the default): exit 0 iff none of the three ran and the
#     skill loaded — the managed policy is in force.
#   --expect ran: exit 0 iff all three ran — the control that shows the probe
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

probe="$(mktemp -d)"
trap 'rm -rf "$probe"' EXIT
marks="$probe/marks"
work="$probe/checkout"
mkdir -p "$marks" "$work/.claude/skills/policy-probe" "$work/.claude/commands"

git -C "$work" init -q
printf '# Policy probe\n' >"$work/CLAUDE.md"
printf -- '---\nname: policy-probe\ndescription: A skill the probe checks still loads.\n---\n# Policy probe\n' \
  >"$work/.claude/skills/policy-probe/SKILL.md"
jq -n --arg m "$marks" \
  '{hooks: {SessionStart: [{hooks: [{type: "command", command: "touch \($m)/hook"}]}]}}' \
  >"$work/.claude/settings.json"
jq -n --arg m "$marks" \
  '{mcpServers: {"policy-probe": {command: "sh", args: ["-c", "touch \($m)/mcp; exec cat"]}}}' \
  >"$work/.mcp.json"
# shellcheck disable=SC2016  # the backticks are the command's own inline-shell syntax
printf 'Policy probe.\n!`touch %s/inline-shell`\n' "$marks" >"$work/.claude/commands/policyprobe.md"

# Invoked as a stage invokes it (requirement 4d), with the project command as
# the prompt so that its inline shell is expanded before any model call.
(
  cd "$work" || exit 1
  timeout 60 env DISABLE_AUTOUPDATER=1 ANTHROPIC_API_KEY=sk-ant-api03-policy-probe-placeholder \
    claude -p --dangerously-skip-permissions --output-format stream-json --verbose \
    <<<"/policyprobe" >"$probe/stream.jsonl" 2>"$probe/stderr.txt"
) || true

ran=()
for m in hook mcp inline-shell; do
  [[ -e "$marks/$m" ]] && ran+=("$m")
done
skill="$(jq -r 'select(.type == "system" and .subtype == "init")
                | [.skills[]? | select(. == "policy-probe")] | length' \
         "$probe/stream.jsonl" 2>/dev/null | head -n 1)"

printf 'ran: %s\n' "${ran[*]:-none}"
printf 'project skill loaded: %s\n' "$([[ "${skill:-0}" == "1" ]] && echo yes || echo no)"

if [[ "$expect" == "blocked" ]]; then
  (( ${#ran[@]} == 0 )) && [[ "${skill:-0}" == "1" ]]
else
  (( ${#ran[@]} == 3 ))
fi
