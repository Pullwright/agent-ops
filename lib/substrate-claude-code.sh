#!/usr/bin/env bash
#
# lib/substrate-claude-code.sh — the `claude-code` substrate adapter
# (docs/spec/implementation/README.md requirement 4d, issue #2133).
#
# `lib/stage-run.sh`'s `run_model_stage` is the one provider-neutral stage
# launcher; everything in this file is what it is neutral *of* — the one
# piece behind the seam that is Anthropic's own CLI and account model rather
# than something every agentic CLI shares. A second provider lands as a
# sibling file, `lib/substrate-<name>.sh`, supplying the same five operations:
#
#   substrate_claude_code_binary               the executable's name on PATH
#   substrate_claude_code_version               its own reported version
#   substrate_claude_code_exec                  build the argv, choose the
#                                                prompt-delivery method, and
#                                                become the process
#   substrate_claude_code_result_line           find the terminal `result`
#                                                event in a finished stream
#   substrate_claude_code_rejected_rate_limit    recognise a structured
#                                                rate-limit refusal in a
#                                                live stream
#
# This file is the extraction of what `lib/stage-run.sh` always did for
# Claude Code, unchanged in behaviour (docs/PROVIDER-SEAM-AUDIT.md §1): the
# same `-p --model … --dangerously-skip-permissions --output-format
# stream-json --verbose`, the prompt on stdin via a here-string, `--resume`,
# and the same `rate_limit_event`/`rate_limit_info.status` reading. It is
# sourced by `lib/stage-run.sh` itself, so every caller that already sources
# that file gets this one for free, exactly as `lib/limit-detect.sh` sources
# `lib/union-stream.sh` for itself.

# substrate_claude_code_binary
# The executable `run_model_stage` looks for on PATH.
substrate_claude_code_binary() {
  printf 'claude\n'
}

# substrate_claude_code_version
# This substrate's own reported version, for scripts/doctor.sh's PATH check.
# Prints nothing and returns 1 when the binary itself is not on PATH.
substrate_claude_code_version() {
  command -v claude >/dev/null 2>&1 || return 1
  claude --version 2>/dev/null | head -1
}

# substrate_claude_code_exec MODEL RESUME_SESSION_ID
# Becomes the `claude` process — via `exec`, so the backgrounded subshell
# `run_model_stage` launches this inside keeps its own pid and process group
# (requirement 9c) rather than gaining a child. The prompt is never a
# parameter here: `run_model_stage` opens the stdin redirection on the
# subshell this function execs inside (`<<<"$prompt"`), and `exec` carries an
# inherited stdin across unchanged, same as it carries the stdout/stderr
# redirections that subshell already has open onto the stream and `.stderr`
# files.
#
# That split — this function decides *that* the prompt arrives on stdin at
# all, `run_model_stage` decides *which* file descriptor stdin already is —
# is what lets a different provider's adapter choose a different delivery
# method without `run_model_stage` itself knowing or caring which: stdin
# versus a provider's own `--prompt-file`-shaped flag is exactly what
# docs/PROVIDER-SEAM-AUDIT.md §2 found differs by provider. An adapter for a
# CLI that does not read stdin at all would instead write the inherited
# stdin to a temp file itself and pass `--prompt-file <path>` — a different
# function body, never a different caller.
#
# RESUME_SESSION_ID, when non-empty, is passed as `--resume`: the prompt then
# continues that session instead of starting a fresh one (requirement 9e's
# salvage is the one caller that ever supplies it).
substrate_claude_code_exec() {
  local model="$1" resume_session_id="$2"
  local -a args=(-p --model "$model" --dangerously-skip-permissions \
    --output-format stream-json --verbose)
  [[ -n "$resume_session_id" ]] && args+=(--resume "$resume_session_id")
  exec claude "${args[@]}"
}

# substrate_claude_code_result_line STREAM_FILE
# Print the run's final `result` event, or nothing (returning 1) when the
# stream carries none — the extraction of what `lib/stage-run.sh` always did
# as `stage_result_line` (requirement 4d), unchanged. Tolerant in both
# directions a stream can be damaged: a killed run's torn tail is read past
# rather than failing the whole parse, and `tail -n 1` takes the last match
# in case a future CLI version ever emits more than one.
substrate_claude_code_result_line() {
  local stream_file="$1" line
  [[ -s "$stream_file" ]] || return 1
  line="$(jq -c 'select(type == "object" and .type == "result")' "$stream_file" 2>/dev/null | tail -n 1)" || true
  [[ -n "$line" ]] || return 1
  printf '%s\n' "$line"
}

# substrate_claude_code_rejected_rate_limit STREAM_FILE
# Print the `rate_limit_info` of a `rate_limit_event` in the stream that says
# the account was refused, or nothing (returning 1) when there is none — the
# extraction of what `lib/stage-run.sh` always did as `stage_rejected_rate_limit`
# (requirement 4e's third stop condition), unchanged. Only `rejected` stops a
# stage; `allowed`/`allowed_warning` and anything unrecognised are left alone.
# The `grep` is a pre-filter, not the decision: `jq` confirms the string came
# from a top-level `rate_limit_event` rather than from inside a tool result.
substrate_claude_code_rejected_rate_limit() {
  local stream_file="$1" info
  [[ -s "$stream_file" ]] || return 1
  grep -aqF '"status":"rejected"' "$stream_file" 2>/dev/null || return 1
  info="$(jq -c 'select(type == "object" and .type == "rate_limit_event")
                 | .rate_limit_info
                 | select(type == "object" and .status == "rejected")' \
            "$stream_file" 2>/dev/null | tail -n 1)" || true
  [[ -n "$info" ]] || return 1
  printf '%s\n' "$info"
}
