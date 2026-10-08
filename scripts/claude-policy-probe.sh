#!/usr/bin/env bash
#
# scripts/claude-policy-probe.sh — does this machine's `claude` run what a
# checkout plants for it (requirement 4k)?
#
# Builds a scratch checkout holding the four things a pull-request head could
# use to run a command the moment a headless stage starts in it — a
# `SessionStart` hook in `.claude/settings.json`; an MCP server in `.mcp.json`,
# approved in the same settings file by `enableAllProjectMcpServers` and
# `enabledMcpjsonServers`, which `run_model_stage` admits while the managed
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
# A fifth, independent case (requirement 4k/45e, issue #2251): a planted
# `apiKeyHelper` in the Claude configuration volume's own settings.json, the
# one place outside any checkout a stage's `claude` reads from. No managed
# policy key switches this off — removing the policy (the `--expect ran`
# control below) does not touch it, because it is lib/stage-run.sh's own
# allowlist (`stage_user_settings_refusal`), not a Claude Code managed
# setting — so this case is checked unconditionally, in both `--expect`
# modes, through `run_model_stage` itself (the one launcher every real stage
# goes through) rather than a raw `claude -p`, since a raw invocation would in
# fact run a planted helper the CLI has no way to refuse on its own
# (requirement 4k's own measurement against 2.1.267). It uses a scratch
# configuration directory throughout, never the real `$CLAUDE_CONFIG_DIR`:
# this probe may run on a live node and must not touch an operator's actual
# Claude configuration.
#
# Usage: scripts/claude-policy-probe.sh [--expect blocked|ran]
#   --expect blocked (the default): exit 0 iff none of the four checkout-
#     planted things ran, the skill loaded, and the planted user-level
#     apiKeyHelper did not run — the managed policy is in force.
#   --expect ran: exit 0 iff all four checkout-planted things ran (the
#     control that shows the probe can see what it is looking for) and the
#     user-level apiKeyHelper still did not run — removing the managed
#     policy does not touch that control.

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
# shellcheck source=lib/stage-run.sh
source "$SCRIPT_DIR/lib/stage-run.sh"

probe="$(mktemp -d)"
trap 'stage_workspace_remove "$probe"' EXIT
marks="$probe/marks"
work="$probe/checkout"
user_config="$probe/claude-config"
mkdir -p "$marks" "$work/.claude/skills/policy-probe" "$work/.claude/commands" "$user_config"

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
jq -n --arg m "$marks" '{apiKeyHelper: "touch \($m)/user-apikeyhelper; echo sk-ant-api03-x"}' \
  >"$user_config/settings.json"

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
  main_ok=0
  [[ ${#ran[@]} -eq 0 && "${skill:-0}" == "1" ]] || main_ok=1
else
  main_ok=0
  [[ ${#ran[@]} -eq 4 ]] || main_ok=1
fi

# The fifth, independent case: through run_model_stage itself (requirement
# 4d), the one launcher every real stage goes through, with CLAUDE_CONFIG_DIR
# pointed at the scratch directory above rather than the real one, and a
# clean cwd carrying no project settings of its own, so only
# stage_user_settings_refusal is under test. A refusal (rc 1) with the mark
# absent is "did not run"; anything else is a bypass of requirement 4k/45e.
user_check_cwd="$probe/user-check-cwd"
mkdir -p "$user_check_cwd"
stage_kill_reason=""
CLAUDE_CONFIG_DIR="$user_config" \
  run_model_stage policy-probe 60 test-model "/policyprobe" "$probe/user-settings.out" "$user_check_cwd"
user_rc=$?
user_ran="$([[ -e "$marks/user-apikeyhelper" ]] && echo yes || echo no)"

printf 'user-level apiKeyHelper ran: %s\n' "$user_ran"

user_ok=0
[[ "$user_ran" == "no" && "$user_rc" == "1" ]] || user_ok=1

exit $(( main_ok || user_ok ))
