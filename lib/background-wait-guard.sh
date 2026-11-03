#!/usr/bin/env bash
#
# lib/background-wait-guard.sh — the logic behind
# `scripts/background-wait-guard.sh`, the managed `PreToolUse` hook
# (`deploy/docker/claude-managed-settings.json`, requirement 4m) that makes
# the "never end a turn with a backgrounded wait pending" rule every stage
# prompt already states in prose mechanical rather than advisory (issue
# #2778). `allowManagedHooksOnly` (requirement 4k) is what makes this the
# only `PreToolUse` hook that can ever fire: a project's own
# `.claude/settings.json` hooks key is loaded but inert once that policy bit
# is set, so a checkout under review cannot add, remove or shadow this one.
#
# Denies a `Bash` call carrying `run_in_background: true`; an `Agent` call
# carrying `run_in_background` true or absent (the Agent tool backgrounds by
# default when the key is omitted) or carrying `isolation: "remote"`
# (`isolation: "remote"` always backgrounds regardless of `run_in_background`
# — issue #2800); and every `Workflow` call (that tool backgrounds by
# construction, with no `run_in_background` key to set at all) — the shapes
# this single-invocation harness can never be woken back up from: there is no
# later turn here to receive the background completion notification an
# interactive session would deliver. Every other call is let through
# unexamined.
#
# Sets no shell options of its own: scripts/background-wait-guard.sh, the
# only caller, sets what it needs before sourcing this.

# background_wait_guard_reason TOOL_NAME
# The message a PreToolUse hook's exit code 2 shows to the model (Claude
# Code's own documented contract: "show stderr to model and block tool
# call") when it denies TOOL_NAME. Phrased as an instruction to retry, not
# just a refusal, since the stage has no other way to learn what to do
# differently and no later turn to ask.
background_wait_guard_reason() {
  local tool_name="$1"
  case "$tool_name" in
    Bash)
      printf '%s\n' \
        "Denied: run_in_background is not permitted. This harness gives a stage one turn and no later turn to receive a background command's completion notification, so a backgrounded Bash call would idle until the inactivity watchdog kills the stage with nothing recorded. Re-run this exact command with run_in_background omitted (or false) and an adequate foreground timeout instead."
      ;;
    Agent)
      printf '%s\n' \
        "Denied: this harness has no later turn to receive an Agent call's background completion notification, so a backgrounded one would idle until the inactivity watchdog kills the stage with nothing recorded — the Agent tool backgrounds by default when run_in_background is omitted, and isolation: \"remote\" always backgrounds regardless of run_in_background, which is exactly the trap. Re-run this exact Agent call with run_in_background: false and isolation omitted (or set to a non-remote value), and wait for it to finish in this same turn."
      ;;
    Workflow)
      printf '%s\n' \
        "Denied: the Workflow tool always runs in the background by construction, with no run_in_background key to set, and this harness has no later turn to receive its completion notification. Do not use the Workflow tool here; use Agent with run_in_background: false (or direct tool calls) and wait for it to finish in this same turn instead."
      ;;
    *)
      printf '%s\n' \
        "Denied: run_in_background is not permitted in this harness — re-run in the foreground with an adequate timeout."
      ;;
  esac
}

# background_wait_guard_should_deny TOOL_NAME TOOL_INPUT_JSON
# Exit 0 (deny) or 1 (allow). TOOL_INPUT_JSON is the tool call's own
# `tool_input` object, as a jq-readable JSON document. A TOOL_INPUT_JSON jq
# cannot parse is treated as absent (Bash: allow; Agent: deny), since a
# malformed payload is never evidence that the call is safe to let through.
background_wait_guard_should_deny() {
  local tool_name="$1" tool_input_json="$2" rib isolation
  case "$tool_name" in
    Bash)
      rib="$(jq -r '.run_in_background == true' <<<"$tool_input_json" 2>/dev/null)" || rib=false
      [[ "$rib" == "true" ]]
      ;;
    Agent)
      # isolation: "remote" always backgrounds regardless of
      # run_in_background (issue #2800) — checked first since it denies
      # even an explicit run_in_background: false.
      isolation="$(jq -r '.isolation // ""' <<<"$tool_input_json" 2>/dev/null)" || isolation=""
      if [[ "$isolation" == "remote" ]]; then
        return 0
      fi
      # `//` cannot tell "false" from "absent" (jq treats `false` itself as
      # the falsy side), so this is spelled as an explicit `if`: deny unless
      # the field is literally `false`.
      rib="$(jq -r 'if .run_in_background == false then false else true end' <<<"$tool_input_json" 2>/dev/null)" || rib=true
      [[ "$rib" == "true" ]]
      ;;
    Workflow)
      # Always backgrounds, by construction, with no run_in_background key
      # to set — there is no foreground shape to allow.
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# background_wait_guard_main
# Reads a PreToolUse hook payload from stdin (Claude Code's own documented
# shape: a JSON object carrying at least `tool_name` and `tool_input`) and
# either returns 0 silently (allow) or writes a deny reason to stderr and
# returns 2 — Claude Code's own documented PreToolUse "show stderr to model
# and block tool call" exit code.
background_wait_guard_main() {
  local payload tool_name tool_input_json
  payload="$(cat)"
  tool_name="$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null)" || tool_name=""
  tool_input_json="$(jq -c '.tool_input // {}' <<<"$payload" 2>/dev/null)" || tool_input_json="{}"

  case "$tool_name" in
    Bash|Agent|Workflow) ;;
    *) return 0 ;;
  esac

  if background_wait_guard_should_deny "$tool_name" "$tool_input_json"; then
    background_wait_guard_reason "$tool_name" >&2
    return 2
  fi
  return 0
}
