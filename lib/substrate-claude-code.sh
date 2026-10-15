#!/usr/bin/env bash
#
# lib/substrate-claude-code.sh — the `claude-code` substrate adapter
# (docs/spec/implementation/README.md requirement 4d, issue #2133).
#
# `lib/stage-run.sh`'s `run_model_stage` is the one provider-neutral stage
# launcher; everything in this file is what it is neutral *of* — the one
# piece behind the seam that is Anthropic's own CLI and account model rather
# than something every agentic CLI shares. A second provider lands as a
# sibling file, `lib/substrate-<name>.sh`, supplying the same six operations:
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
#   substrate_claude_code_lane_of                read the credential lane a
#                                                run actually used off its
#                                                own `init` event
#   substrate_claude_code_lane_present            whether a named lane's
#                                                credential is present on
#                                                this node at all (issue
#                                                #2241, D30)
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
# This substrate's own reported version. Prints nothing and returns 1 when the
# binary itself is not on PATH. This operation and `_binary` above are the two
# the adapter contract declares but nothing calls yet: scripts/doctor.sh and
# lib/node-health.sh still read `claude` directly, and routing them through
# here is #2200.
substrate_claude_code_version() {
  command -v claude >/dev/null 2>&1 || return 1
  claude --version 2>/dev/null | head -1
}

# substrate_claude_code_exec MODEL RESUME_SESSION_ID [LANE]
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
#
# LANE (issue #2241, D30), when `subscription`, forces the login path by
# unsetting `ANTHROPIC_API_KEY` from this process's own environment before
# `exec` — Claude Code's documented precedence otherwise prefers the key
# whenever it is present. Anything else (`api`, or empty for a caller that
# never drew a lane at all — `run_model_stage` only does this when at least
# one credential is present, D30's own "Presence" rule) leaves
# `ANTHROPIC_API_KEY` exactly as it already is. The workspace header
# (`substrate_claude_code_compose_workspace_header`) is composed only on that
# second path: issue #2309's own header never belongs on a request a forced
# subscription launch carries no API key behind.
substrate_claude_code_exec() {
  local model="$1" resume_session_id="$2" lane="${3:-}"
  local -a args=(-p --model "$model" --dangerously-skip-permissions \
    --output-format stream-json --verbose)
  [[ -n "$resume_session_id" ]] && args+=(--resume "$resume_session_id")
  if [[ "$lane" == "subscription" ]]; then
    exec env -u ANTHROPIC_API_KEY claude "${args[@]}"
  fi
  substrate_claude_code_compose_workspace_header
  exec claude "${args[@]}"
}

# SUBSTRATE_CLAUDE_CODE_WORKSPACE_ID_RE
# The shape of a workspace id as Anthropic's Console prints one (Settings →
# Workspaces): `wrkspc_` followed by its own opaque suffix. Shared by
# substrate_claude_code_compose_workspace_header below and by
# scripts/doctor.sh's Claude section, so the two never drift on what counts
# as a real id versus a copy-paste error.
SUBSTRATE_CLAUDE_CODE_WORKSPACE_ID_RE='^wrkspc_[0-9A-Za-z]+$'

# substrate_claude_code_custom_headers_has_name HEADERS NAME
# Whether HEADERS — ANTHROPIC_CUSTOM_HEADERS' own "Name: Value" newline-
# separated shape — already names NAME, compared case-insensitively the same
# way an HTTP header name itself is. Lets
# substrate_claude_code_compose_workspace_header leave an operator's own
# `anthropic-workspace-id` line alone rather than appending a second one.
substrate_claude_code_custom_headers_has_name() {
  local headers="$1" name="$2" line header_name
  local lower_name
  lower_name="$(tr '[:upper:]' '[:lower:]' <<<"$name")"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    header_name="${line%%:*}"
    header_name="$(tr '[:upper:]' '[:lower:]' <<<"$header_name")"
    header_name="${header_name#"${header_name%%[![:space:]]*}"}"
    header_name="${header_name%"${header_name##*[![:space:]]}"}"
    [[ "$header_name" == "$lower_name" ]] && return 0
  done <<<"$headers"
  return 1
}

# substrate_claude_code_compose_workspace_header
# Appends an `anthropic-workspace-id` line to ANTHROPIC_CUSTOM_HEADERS, built
# from ANTHROPIC_WORKSPACE_ID, and exports the result — so it survives the
# `exec claude` this runs ahead of and, in the image, the sudo environment
# reset `deploy/docker/claude-shim.sh` calls through next, since sudo keeps
# whatever `env_keep` names from *this* process's own environment, never from
# a config file (issue #2309: ANTHROPIC_WORKSPACE_ID and
# ANTHROPIC_CUSTOM_HEADERS are both named in
# deploy/docker/sudoers-agent-ops' own `env_keep` for exactly this).
#
# A key scoped at creation to a single workspace, and the subscription-OAuth
# path, need no header at all, so an unset ANTHROPIC_WORKSPACE_ID leaves the
# environment exactly as it already was. A malformed one composes nothing —
# the request is what should refuse a bad id, not this launcher — and is
# reported to this stage's own `.out.stderr` instead: `run_model_stage`
# redirects this function's stderr there before it ever calls this, so a
# warning here lands exactly where requirement 4k's own refusals already do.
# An operator-supplied ANTHROPIC_CUSTOM_HEADERS, or one that already names
# this header itself, is kept rather than clobbered.
substrate_claude_code_compose_workspace_header() {
  local workspace_id="${ANTHROPIC_WORKSPACE_ID:-}"
  [[ -n "$workspace_id" ]] || return 0
  if [[ ! "$workspace_id" =~ $SUBSTRATE_CLAUDE_CODE_WORKSPACE_ID_RE ]]; then
    printf 'substrate-claude-code: ANTHROPIC_WORKSPACE_ID "%s" is not shaped like a workspace id (expected a "wrkspc_" prefix) — not composing the anthropic-workspace-id header; check for a copy-paste error\n' \
      "$workspace_id" >&2
    return 0
  fi
  substrate_claude_code_custom_headers_has_name "${ANTHROPIC_CUSTOM_HEADERS:-}" anthropic-workspace-id && return 0
  if [[ -n "${ANTHROPIC_CUSTOM_HEADERS:-}" ]]; then
    export ANTHROPIC_CUSTOM_HEADERS="${ANTHROPIC_CUSTOM_HEADERS}
anthropic-workspace-id: ${workspace_id}"
  else
    export ANTHROPIC_CUSTOM_HEADERS="anthropic-workspace-id: ${workspace_id}"
  fi
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

# substrate_claude_code_init_api_key_source STREAM_FILE
# Print the stream's own first `system`/`init` event's `apiKeySource`, raw —
# or nothing (returning 1) when the stream carries no readable answer (a
# stage killed before its first byte, or one this test harness never asked
# to emit one). The shared read behind `_lane_of` below (the post-run,
# mapped-to-a-lane reading) and `run_model_stage`'s own live-stream lane
# verification (issue #2241, D30), which needs the raw string rather than
# the mapped lane to tell a forced subscription run's managed-key login
# (D30's own softened case) apart from a genuine mismatch.
substrate_claude_code_init_api_key_source() {
  local stream_file="$1" source
  [[ -s "$stream_file" ]] || return 1
  source="$(jq -r 'select(type == "object" and .type == "system" and .subtype == "init")
                    | .apiKeySource // empty' "$stream_file" 2>/dev/null | head -n 1)" || true
  [[ -n "$source" ]] || return 1
  printf '%s\n' "$source"
}

# substrate_claude_code_lane_of STREAM_FILE
# Print the credential lane this run actually used — `api` or `subscription`
# — or nothing (returning 1) when the stream carries no readable answer.
# Issue #2239 (D30): the lane is *observed*, off the stream's own first
# `system`/`init` event's `apiKeySource` (`substrate_claude_code_init_api_key_source`
# above), rather than assumed from what the Script intended — the one fact
# this adapter alone can read, since only the CLI that actually ran knows
# which credential it resolved to. `none` is a subscription login;
# `ANTHROPIC_API_KEY`, `apiKeyHelper` and `/login managed key` each bill a
# Console account, so all three are the `api` lane (docs/ROADMAP.md's D30
# row). Anything else — a vocabulary this adapter does not recognise — is
# left to the caller's own `null` degradation, same as every other
# envelope-derived field this pipeline cannot read.
substrate_claude_code_lane_of() {
  local stream_file="$1" source
  source="$(substrate_claude_code_init_api_key_source "$stream_file")" || return 1
  case "$source" in
    none) printf 'subscription\n' ;;
    ANTHROPIC_API_KEY|apiKeyHelper|"/login managed key") printf 'api\n' ;;
    *) return 1 ;;
  esac
}

# substrate_claude_code_cloud_provider_switch
# Whether this node's environment names a cloud-provider credential path —
# Bedrock or Vertex — which Claude Code's documented precedence takes over
# both `ANTHROPIC_API_KEY` and a subscription login: such a node runs the
# API lane by that credential alone and has no subscription lane at all
# (issue #2241, D30; docs/ROADMAP.md's D30 row).
substrate_claude_code_cloud_provider_switch() {
  [[ "${CLAUDE_CODE_USE_BEDROCK:-}" == "1" || "${CLAUDE_CODE_USE_VERTEX:-}" == "1" ]]
}

# SUBSTRATE_CLAUDE_CODE_SUBSCRIPTION_MANAGED_KEY
# 0 until a forced `subscription` run's own `init` event has reported a
# Console login (`/login managed key`) — set to 1 for the rest of this
# process's life once it does (one cycle: each cycle script is its own
# process). A Console login bills an API account, so the subscription lane
# is not actually open on this node from that point on, whatever its
# credentials file says (issue #2241, D30); `run_model_stage` logs the
# warning once, the moment the flag flips, rather than once per run.
# Declared defensively, the same guard `lib/stage-run.sh` uses for its own
# maps, so a file that sources this one more than once in the same process
# (every test in this repository that sources it standalone) does not reset
# a flag a run earlier in that same process already set.
declare -p SUBSTRATE_CLAUDE_CODE_SUBSCRIPTION_MANAGED_KEY >/dev/null 2>&1 \
  || SUBSTRATE_CLAUDE_CODE_SUBSCRIPTION_MANAGED_KEY=0

# substrate_claude_code_lane_present LANE
# Whether LANE's credential is present on this node right now (issue #2241,
# D30) — asked of this adapter because only it knows its own credential
# vocabulary (a second substrate answers this in its own terms, #2246).
#
# `api`: present when `ANTHROPIC_API_KEY` is non-empty, or unconditionally on
# a Bedrock/Vertex node (`substrate_claude_code_cloud_provider_switch`) — such
# a node runs the API lane by its own cloud credential instead.
#
# `subscription`: never present on a Bedrock/Vertex node (its one lane is
# `api`, above); never present once SUBSCRIPTION_MANAGED_KEY has latched for
# this process; otherwise present iff `$CLAUDE_CONFIG_DIR/.credentials.json`
# exists. A file-existence check, not a live `claude auth status` call
# (`scripts/doctor.sh`'s own Claude section makes that live call, but
# operator-invoked, once): this is asked on every launch, and a live call
# that often would be both too slow and itself billable.
substrate_claude_code_lane_present() {
  local lane="$1" dir
  case "$lane" in
    api)
      substrate_claude_code_cloud_provider_switch && return 0
      [[ -n "${ANTHROPIC_API_KEY:-}" ]]
      ;;
    subscription)
      substrate_claude_code_cloud_provider_switch && return 1
      [[ "$SUBSTRATE_CLAUDE_CODE_SUBSCRIPTION_MANAGED_KEY" == "1" ]] && return 1
      dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
      [[ -e "$dir/.credentials.json" ]]
      ;;
    *) return 1 ;;
  esac
}
