#!/usr/bin/env bash
#
# lib/stage-run.sh — the one implementation of "run a headless model stage"
# (requirement 4d of docs/spec/implementation/README.md).
#
# Sourced by agent-cycle.sh and review-cycle.sh so both pipelines launch, cap
# and kill a stage the same way, rather than each keeping its own copy of the
# mechanism — the same reason lib/metering.sh exists. The two copies this
# replaces were byte-identical apart from their comments, and both specs
# already said in as many words that they must not diverge; a shared file is
# the only form of that promise a reviewer does not have to check by eye.
#
# `run_model_stage` is provider-neutral: everything in this file is what
# docs/PROVIDER-SEAM-AUDIT.md §1 calls the substrate contract — the process
# group and the two caps, the stream/`.out`/`.out.stderr` files, the gap
# clock, the metering hand-off — identical whichever provider a stage's model
# resolves to. What is *not* neutral (the binary, its argv, its prompt
# delivery, its own result-line and rate-limit shapes) lives one call away,
# in a `lib/substrate-<name>.sh` adapter — `lib/substrate-claude-code.sh`
# (issue #2133: the Claude adapter extracted from this file unchanged) and
# `lib/substrate-grok-build.sh` (issue #2134), both sourced below — resolved
# per invocation by `stage_model_substrate` from the model it was asked to
# run.
#
# shellcheck source=lib/substrate-claude-code.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/substrate-claude-code.sh"
# shellcheck source=lib/substrate-grok-build.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/substrate-grok-build.sh"

# PROVIDER_SUBSTRATE/MODEL_PROVIDER are lib/model-id.sh's: the provider each
# model resolves to (requirement 1a), and — populated as a side effect of
# every `resolve_model_id_into` call, and only of the assigning form, since a
# command substitution discards the recording with its subshell — the
# provider each bare model id last resolved from. A new call site whose
# resolved model reaches the launcher below therefore has to use
# `resolve_model_id_into`; the printing `resolve_model_id` leaves this map
# empty and the lookup silently falls back. Declared defensively here, rather
# than assumed, because
# several of this file's own tests source this file alone, never
# lib/model-id.sh: a bare reference to an undeclared associative array is a
# hard "unbound variable" under the `set -u` those tests (and every caller)
# run under, not a convenient empty read. Guarded so as never to clobber a
# map lib/model-id.sh already populated, whichever of the two is sourced
# first.
declare -p PROVIDER_SUBSTRATE >/dev/null 2>&1 || declare -gA PROVIDER_SUBSTRATE=()
declare -p MODEL_PROVIDER >/dev/null 2>&1 || declare -gA MODEL_PROVIDER=()

# stage_model_substrate MODEL
# The installed substrate MODEL's provider resolves to: look up the provider
# MODEL_PROVIDER last recorded for MODEL, then that provider's substrate in
# PROVIDER_SUBSTRATE — falling back to `claude-code` at either step when
# MODEL is unknown but non-empty, which is every caller that never loaded
# lib/model-id.sh (most of this file's own tests, by design — see
# lib/substrate-claude-code.sh's header) and every model this image has ever
# run before #2133, since `anthropic`/`claude-code` is the only provider that
# has ever existed to record. An empty MODEL is handled separately, below:
# bash makes an empty subscript on an associative array a hard "bad array
# subscript" error rather than an empty read, so `:-anthropic` never gets a
# chance to apply.
stage_model_substrate() {
  local model="${1:-}" provider substrate
  if [[ -n "$model" ]]; then
    provider="${MODEL_PROVIDER[$model]:-anthropic}"
  else
    provider="anthropic"
  fi
  substrate="${PROVIDER_SUBSTRATE[$provider]:-claude-code}"
  printf '%s\n' "$substrate"
}

# What a stage leaves behind, per invocation:
#
#   <stage>.stream.jsonl  every event the run emitted, newline-delimited JSON,
#                         written as it happens rather than at the end. Local
#                         forensics for a stage that did not finish, and the
#                         observable record of a stage's progress while it is
#                         still in flight.
#   <stage>.out           the run's final `result` event and nothing else —
#                         the same envelope `--output-format json` used to
#                         write, so every reader downstream of this function
#                         is unchanged by the switch to streaming.
#   <stage>.out.stderr    the invocation's diagnostics, kept apart from the
#                         envelope for the reason given at the redirect.
#
# And two things it leaves in variables rather than files:
#
#   stage_gaps_json       the run's inter-event gap statistics (requirement
#                         33a), measured by watching the stream grow. See
#                         `stage_gap_stats`, and the note in the poll loop on
#                         why growth — not a beat, not a timestamp inside the
#                         events — is what is measured.
#   stage_kill_reason     which of the two caps ended the run, if either
#                         (requirement 4e).

# The gap statistics of the most recent run, for the caller's `stage-end`
# event. A stage that has not run yet, or that produced no output at all,
# reports `null`.
stage_gaps_json="null"

# Why the most recent run was stopped, for the same event: `inactivity` when
# the watchdog fired, `backstop` when the outer wall-clock cap did,
# `rate-limit` when the stream reported the account rejected, and empty when
# the stage ended on its own — including when it ended badly. All three are
# indistinguishable from `exit_code` alone, which is 124 for every one of
# them, and they are not the same event.
stage_kill_reason=""

# The `rate_limit_info` object of the event that stopped the run, when
# `stage_kill_reason` is `rate-limit`; empty otherwise. It carries a real
# reset time (`resetsAt`) and the limit's own kind (`rateLimitType`), which is
# strictly better evidence than the prose the phrase matcher reads — see
# `limit_decide_structured` in lib/limit-detect.sh.
stage_rate_limit_json=""

# The provider the most recent run's model resolved to (`stage_model_substrate`'s
# own input, not its output) — read by `detect_and_log_limit_hit`'s three
# copies so a `limit-hit` event and `fleet/limit.json` record both name which
# provider's account hit the limit, even though the stand-down itself still
# covers the whole fleet regardless of provider (issue #2133; scoping it
# per-provider is #2135). Defaults to `anthropic`, same as `stage_model_substrate`.
stage_provider="anthropic"

# Requirement 4k: the Claude Code project settings a stage will load from the
# directory it runs in. Headless `claude -p` treats its working directory as
# trusted, and a project's `.claude/settings.json` or `settings.local.json` is
# not only preferences: `env` sets variables in the runner's own process and
# in every command it runs (`BASH_ENV` among them), and `apiKeyHelper`,
# `awsAuthRefresh`, `awsCredentialExport`, `gcpAuthRefresh`,
# `otelHeadersHelper`, `proxyAuthHelper` and `processWrapper` name commands it
# runs itself, while `enabledPlugins` and `extraKnownMarketplaces` fetch code.
# A stage runs in a checkout of a pull-request head as often as of `main`, so
# any of these would run whatever the head says, before the stage's prompt
# is read and with the stage's credentials. Measured against 2.1.267 with
# every one planted in a checkout: `apiKeyHelper` and the AWS helpers ran
# commands, and `env` switched the runner onto another provider.
#
# The image's managed policy (`deploy/docker/claude-managed-settings.json`,
# installed root-owned at /etc/claude-code/managed-settings.json) switches off
# hooks, MCP servers and inline shell in skills and commands wherever they
# come from, but no managed key can switch off a project's `env`, and a list
# of forbidden keys would be one new key away from failing open. So this is an
# allowlist: keys that cannot run anything, change the environment or change
# what the stage may do, plus the hook and MCP-approval keys only when the
# managed policy is present and pins the control that makes them inert. A
# file holding anything else, or one that is not a JSON object `jq` can read,
# means the stage is not launched.
#
# `permissions` is allowed for its `allow` list and nothing else. Measured
# against 2.1.267 under `--dangerously-skip-permissions`: `allow` is ignored
# in a workspace nobody has trusted interactively, which no stage's is;
# `deny` takes the named tool away from the stage, so a head could narrow
# what its own Reviewer can see; and `disableBypassPermissionsMode` silently
# drops the run into the default permission mode. `ask`, `defaultMode` and
# `additionalDirectories` set what the stage may do as well, so they are
# refused with them.
#
# Only the working directory matters: Claude reads project settings from
# there and not from a parent or the repository root (measured likewise).
#
# The directory is often a workspace an earlier stage has had (the Reviewer
# and the Approver run in the Implementer's clone), and then everything in it
# is the stage user's to arrange (requirement 45e). So the Script neither
# opens these files nor runs `git` there itself: each file is read as the
# stage user reads it, which is also exactly what Claude, running as that
# user, would load, and the comparison with the commit runs as that user too,
# both bounded in time and size (lib/stage-boundary.sh). A file that cannot
# be read that way — a FIFO, one larger than
# `STAGE_PROJECT_SETTINGS_MAX_BYTES` — is refused like one that is not JSON.
# Sourced here unless its functions are already defined, as they are in each
# cycle script (lib/cycle-state.sh sources it) and in a test that assembles
# this file into a script of its own.
if ! declare -F stage_boundary_read >/dev/null; then
  # shellcheck source=lib/stage-boundary.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stage-boundary.sh"
fi
STAGE_PROJECT_SETTINGS_MAX_BYTES=1048576
# shellcheck disable=SC2016  # "$schema" is a JSON key, not a variable
STAGE_PROJECT_SETTINGS_INERT_KEYS='["$schema","permissions","includeCoAuthoredBy","includeGitInstructions","cleanupPeriodDays","respectGitignore"]'
STAGE_PROJECT_SETTINGS_INERT_PERMISSIONS='["allow"]'
STAGE_CLAUDE_MANAGED_SETTINGS="${STAGE_CLAUDE_MANAGED_SETTINGS:-/etc/claude-code/managed-settings.json}"
# The one extra key the user-level file legitimately holds that no project
# settings file would: deploy/docker/claude-settings.json, the image's own
# seed, sets `effortLevel` alongside `includeCoAuthoredBy` (already inert
# above).
STAGE_USER_SETTINGS_EXTRA_ALLOWED_KEYS='["effortLevel"]'

# stage_project_settings_allowed_keys
# The allowlist as a JSON array: the inert keys, plus `hooks` when the managed
# policy sets `allowManagedHooksOnly`, plus the project MCP-approval keys when
# it sets `allowedMcpServers` to the empty list.
stage_project_settings_allowed_keys() {
  local policy
  policy="$(jq -c 'if type == "object" then . else {} end' "$STAGE_CLAUDE_MANAGED_SETTINGS" 2>/dev/null)" \
    || policy='{}'
  [[ -n "$policy" ]] || policy='{}'
  jq -cn --argjson inert "$STAGE_PROJECT_SETTINGS_INERT_KEYS" --argjson m "$policy" '
    $inert
    + (if $m.allowManagedHooksOnly == true then ["hooks"] else [] end)
    + (if $m.allowedMcpServers == [] then
         ["enableAllProjectMcpServers", "enabledMcpjsonServers", "disabledMcpjsonServers"]
       else [] end)'
}

# stage_project_settings_origin DIR PATH
# Whether the commit DIR has checked out carries the settings file PATH
# (relative to DIR) exactly as the working tree does, as a clause for the
# refusal. Claude loads the working tree, so the working tree is what is
# vetted; this says only whether the pull request shows the file too. One that
# is not as committed was written or changed after the commit, which is how a
# file an earlier stage left in a clone the next stage reuses looks.
#
# The comparison runs as the stage user (`stage_boundary_capture`), since the
# repository's own configuration can name commands that `git diff` runs, and
# what it reports is accepted only in one of three fixed forms.
stage_project_settings_origin() {
  local dir="$1" path="$2" answer
  # shellcheck disable=SC2016  # the script is the stage user's bash's to expand
  answer="$(stage_boundary_capture 30 128 bash -c '
    head="$(git -C "$1" rev-parse --short HEAD 2>/dev/null)" || { echo none; exit 0; }
    if git -C "$1" cat-file -e "HEAD:./$2" 2>/dev/null \
       && git -C "$1" diff --quiet HEAD -- "$2" 2>/dev/null; then
      echo "same $head"
    else
      echo "changed $head"
    fi' _ "$dir" "$path")"
  if [[ "$answer" == none ]]; then
    printf 'the file is in the working tree, and there is no commit to compare it with'
  elif [[ "$answer" =~ ^same\ ([0-9a-f]{4,40})$ ]]; then
    printf 'the file is as committed at %s' "${BASH_REMATCH[1]}"
  elif [[ "$answer" =~ ^changed\ ([0-9a-f]{4,40})$ ]]; then
    printf 'the file is in the working tree but not as committed at %s' "${BASH_REMATCH[1]}"
  else
    printf 'the file is in the working tree, and it could not be compared with the commit'
  fi
}

# _stage_byte_length STRING
# STRING's length in bytes, whatever the locale.
_stage_byte_length() {
  local LC_ALL=C
  printf '%s' "${#1}"
}

# STAGE_GROK_CONFIG_ALLOWED_SECTIONS: the only `.grok/config.toml` top-level
# sections a Grok stage may carry (requirement 4k's Grok counterpart, issue
# #2134's own probe of "what a checkout supplies" — see
# docs/reviews/2026-10-06-grok-build-evaluation.md and the issue body's
# extension of it). `[permission]` and `[mcp]` are themselves inert the same
# way Claude Code's own `permissions`/MCP-approval keys are (allowed for the
# same reason those are allowed in STAGE_PROJECT_SETTINGS_INERT_KEYS);
# `[mcp_servers]` is allowed only while the image's own
# `/etc/grok/requirements.toml` pins `allowed_mcp_servers = []`, which this
# repository always ships — there is no configuration that lifts that pin.
# `[plugins]` is refused: a plugin stays untrusted under folder trust, but
# only while nothing else grants it the run, and "inert today" is not a
# guarantee this file can keep.
STAGE_GROK_CONFIG_ALLOWED_SECTIONS='permission mcp mcp_servers'

# _stage_toml_top_level_sections FILE
# The top-level `[section]` header names TOML FILE declares, one per line —
# a grep, not a parser: this reads only what a section-header *line* says,
# which is all requirement 4k's Grok guard needs to ask ("does this file
# touch any section beyond the allowed three"), never what a section's own
# keys hold. An array-of-tables header (`[[name]]`) is intentionally not
# matched by this pattern and so refused by the caller's own "every section
# must be on the allowlist" reading of its output, the same safe-by-default
# stance the JSON checks below take toward anything they cannot parse.
_stage_toml_top_level_sections() {
  grep -oE '^[[:space:]]*\[[A-Za-z0-9_.-]+\][[:space:]]*(#.*)?$' "$1" 2>/dev/null \
    | sed -E 's/^[[:space:]]*\[([A-Za-z0-9_.-]+)\].*/\1/'
}

# stage_project_settings_refusal DIR [SUBSTRATE]
# Prints why a stage must not be launched in DIR and returns 0 when a
# project settings file it would load carries something outside the
# allowlist, or cannot be read as it needs to be to vet; returns 1, printing
# nothing, when there is no such file or every one found is allowed. The
# reason names the file and what is wrong with it, then says where the file
# came from.
#
# The `.claude/settings.json`/`settings.local.json` checks below run for
# every SUBSTRATE, not only `claude-code`: Grok Build reads the same file's
# `hooks` under its own Claude-compatibility layer when `GROK_FOLDER_TRUST=0`
# trusts a checkout (issue #2134's probe), so the one guard already protects
# both substrates' own stages against it, with nothing to dispatch. What
# *is* substrate-specific is the second block, below the loop: Grok's own
# `.grok/lsp.json` and `.grok/config.toml`, which Claude Code never reads and
# so never needs vetted.
stage_project_settings_refusal() {
  local dir="$1" substrate="${2:-claude-code}" allowed name file content disallowed s
  allowed="$(stage_project_settings_allowed_keys)"
  for name in settings.json settings.local.json; do
    file="$dir/.claude/$name"
    [[ -e "$file" || -L "$file" ]] || continue
    # The `x` keeps a trailing newline from being stripped, so that the
    # length compared is the length read.
    if ! content="$(stage_boundary_read "$file" "$((STAGE_PROJECT_SETTINGS_MAX_BYTES + 1))" && printf x)" \
       || (( $(_stage_byte_length "${content%x}") > STAGE_PROJECT_SETTINGS_MAX_BYTES )); then
      printf '.claude/%s cannot be read as a file of at most %s bytes, so it cannot be vetted; %s' \
        "$name" "$STAGE_PROJECT_SETTINGS_MAX_BYTES" "$(stage_project_settings_origin "$dir" ".claude/$name")"
      return 0
    fi
    if ! disallowed="$(jq -r --argjson allowed "$allowed" \
           --argjson permissions "$STAGE_PROJECT_SETTINGS_INERT_PERMISSIONS" '
           if type != "object" then error("not an object") else
             [ (keys_unsorted[] | select(IN($allowed[]) | not)),
               (.permissions // {}
                | if type == "object" then
                    keys_unsorted[] | select(IN($permissions[]) | not) | "permissions.\(.)"
                  else "permissions" end) ]
             | join(", ")
           end' <<<"${content%x}" 2>/dev/null)"; then
      printf '.claude/%s cannot be read as a JSON object, so it cannot be vetted; %s' \
        "$name" "$(stage_project_settings_origin "$dir" ".claude/$name")"
      return 0
    fi
    if [[ -n "$disallowed" ]]; then
      printf '.claude/%s sets %s, which no stage loads from the checkout it runs in; %s' \
        "$name" "$disallowed" "$(stage_project_settings_origin "$dir" ".claude/$name")"
      return 0
    fi
  done

  if [[ "$substrate" == "grok-build" ]]; then
    file="$dir/.grok/lsp.json"
    if [[ -e "$file" || -L "$file" ]]; then
      printf '.grok/lsp.json is present, and no stage runs a project LSP server from the checkout it runs in; %s' \
        "$(stage_project_settings_origin "$dir" ".grok/lsp.json")"
      return 0
    fi
    file="$dir/.grok/config.toml"
    if [[ -e "$file" || -L "$file" ]]; then
      disallowed=""
      while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        case " $STAGE_GROK_CONFIG_ALLOWED_SECTIONS " in
          *" $s "*) ;;
          *) disallowed+="${disallowed:+, }$s" ;;
        esac
      done < <(_stage_toml_top_level_sections "$file")
      if [[ -n "$disallowed" ]]; then
        printf '.grok/config.toml sets section(s) %s, which no stage loads from the checkout it runs in; %s' \
          "$disallowed" "$(stage_project_settings_origin "$dir" ".grok/config.toml")"
        return 0
      fi
    fi
  fi

  return 1
}

# stage_user_settings_refusal
# The user-level counterpart to stage_project_settings_refusal: prints why a
# stage must not be launched because $CLAUDE_CONFIG_DIR/settings.json (the
# Claude configuration volume's own file, defaulted the same way
# entrypoint.sh defaults it) carries a key outside the allowlist, or cannot be
# read as a JSON object; returns 1, printing nothing, when the file is absent
# or every key in it is allowed. Unlike the project files, this one is never
# part of a commit a stage's checkout holds, so there is no origin clause to
# add.
#
# This file ought never to hold anything else in the first place —
# deploy/docker/entrypoint.sh seeds it `agent`-owned and excludes it from the
# reshaping that gives the stage user everything else in the directory
# (requirement 45e) — so this check is the backstop for whatever reaches here
# anyway: an older volume this node has not yet restarted onto the fixed
# entrypoint, or a gap neither control anticipated. The allowlist is the
# project one plus `STAGE_USER_SETTINGS_EXTRA_ALLOWED_KEYS`, the one key the
# image's own seed holds that no project settings file would.
stage_user_settings_refusal() {
  local dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" allowed file content disallowed
  file="$dir/settings.json"
  [[ -e "$file" || -L "$file" ]] || return 1
  allowed="$(stage_project_settings_allowed_keys | jq -c \
    --argjson extra "$STAGE_USER_SETTINGS_EXTRA_ALLOWED_KEYS" '. + $extra')"
  # The `x` keeps a trailing newline from being stripped, so that the length
  # compared is the length read.
  if ! content="$(stage_boundary_read "$file" "$((STAGE_PROJECT_SETTINGS_MAX_BYTES + 1))" && printf x)" \
     || (( $(_stage_byte_length "${content%x}") > STAGE_PROJECT_SETTINGS_MAX_BYTES )); then
    printf '%s cannot be read as a file of at most %s bytes, so it cannot be vetted' \
      "$file" "$STAGE_PROJECT_SETTINGS_MAX_BYTES"
    return 0
  fi
  if ! disallowed="$(jq -r --argjson allowed "$allowed" \
         --argjson permissions "$STAGE_PROJECT_SETTINGS_INERT_PERMISSIONS" '
         if type != "object" then error("not an object") else
           [ (keys_unsorted[] | select(IN($allowed[]) | not)),
             (.permissions // {}
              | if type == "object" then
                  keys_unsorted[] | select(IN($permissions[]) | not) | "permissions.\(.)"
                else "permissions" end) ]
           | join(", ")
         end' <<<"${content%x}" 2>/dev/null)"; then
    printf '%s cannot be read as a JSON object, so it cannot be vetted' "$file"
    return 0
  fi
  if [[ -n "$disallowed" ]]; then
    printf '%s sets %s, which no stage loads from the Claude configuration volume' \
      "$file" "$disallowed"
    return 0
  fi
  return 1
}

# stage_stream_file OUT_FILE
# The progress stream that accompanies a stage's `.out`. Derived rather than
# passed so that every caller — and every reader, in this repository and in
# the state mirror's exclude list — names the same file by the same rule.
stage_stream_file() {
  printf '%s.stream.jsonl' "${1%.out}"
}

# stage_result_line STREAM_FILE [SUBSTRATE]
# Print the run's final `result` event, or nothing (returning 1) when the
# stream carries none. Dispatches to SUBSTRATE's own
# `substrate_<name>_result_line` (default `claude-code`, since that is the
# only substrate every existing caller — direct, in a test, or via
# `run_model_stage` with no model-id map populated — has ever meant). The
# shape itself (a killed run's torn tail yielding an earlier complete event
# rather than an error; `tail -n 1` over `head` in case a future CLI version
# ever emits more than one `result`) is each adapter's own business now —
# see lib/substrate-claude-code.sh's copy for the reasoning, unchanged from
# when it lived here.
stage_result_line() {
  local stream_file="$1" substrate="${2:-claude-code}"
  "substrate_${substrate//-/_}_result_line" "$stream_file"
}

# stage_gap_stats SECONDS...
# Summarise a run's inter-event gaps as the object requirement 33a documents:
# `{n, p50, p95, p99, max}`, seconds. Prints `null` given no readable
# observation at all — which no real run produces, since `run_model_stage`
# always records the silence that ended it, so `null` on a stage-end event
# means the record was not measured rather than that the run was never quiet.
#
# Nearest-rank percentiles over the sorted sample: the p-th percentile is the
# `ceil(p·n)`-th smallest value. No interpolation, so every figure printed is
# an observation that really happened — which matters because these numbers
# exist to size a threshold against real silences, and an interpolated p99
# between 40 s and 900 s describes neither.
stage_gap_stats() {
  local gaps
  # `try … catch empty` per line, not around the program: a single unreadable
  # observation must cost that observation and nothing else. This is metering,
  # and requirement 33a is explicit that a metering failure may never take the
  # `stage` and `exit_code` of the event it is merged into down with it.
  gaps="$(printf '%s\n' "$@" \
    | jq -Rc 'select(length > 0) | (try tonumber catch empty)' 2>/dev/null \
    | jq -sc '.' 2>/dev/null)" || gaps="[]"
  [[ -n "$gaps" ]] || gaps="[]"
  jq -nc --argjson g "$gaps" '
    ($g | sort) as $s
    | ($s | length) as $n
    | def pct($q): $s[ ((($n * $q) | ceil) - 1) | if . < 0 then 0 else . end ];
      if $n == 0 then null
      else {n: $n, p50: pct(0.5), p95: pct(0.95), p99: pct(0.99), max: $s[$n - 1]}
      end' 2>/dev/null || printf 'null'
}

# stage_rejected_rate_limit STREAM_FILE [SUBSTRATE]
# Print the `rate_limit_info` of a `rate_limit_event` in the stream that says
# the account was refused, or nothing (returning 1) when there is none.
# Dispatches to SUBSTRATE's own `substrate_<name>_rejected_rate_limit`
# (default `claude-code`, same reasoning as `stage_result_line` above). The
# vocabulary itself (`allowed`/`allowed_warning`/`rejected`, and the
# asymmetry in what each means for a stage in flight) is each adapter's own
# business now — see lib/substrate-claude-code.sh's copy, unchanged from when
# it lived here.
stage_rejected_rate_limit() {
  local stream_file="$1" substrate="${2:-claude-code}"
  "substrate_${substrate//-/_}_rejected_rate_limit" "$stream_file"
}

# stage_verdict_rc RC OUT_FILE [SUBSTRATE]
# RC, corrected by SUBSTRATE's own `substrate_<name>_verdict_rc` when it
# defines one, or RC unchanged otherwise (every substrate but `grok-build`
# today). Exists because a provider's own exit status is not guaranteed to
# be a verdict — Grok Build's can be 0 with `is_error: true` (issue #2134,
# docs/reviews/2026-10-06-grok-build-evaluation.md's "Beyond the ten
# questions" section, "Exit status") — and `run_model_stage`'s own callers branch on
# the return value alone, never on `.out`'s content, to decide whether a
# stage succeeded.
stage_verdict_rc() {
  local rc="$1" out_file="$2" substrate="${3:-claude-code}"
  if declare -F "substrate_${substrate//-/_}_verdict_rc" >/dev/null 2>&1; then
    "substrate_${substrate//-/_}_verdict_rc" "$rc" "$out_file"
  else
    printf '%s\n' "$rc"
  fi
}

# stage_watchdog_warning STAGE
# The body of the `warning` event a watchdog kill earns, or nothing (returning
# 1) when the last run ended any other way.
#
# A separate event from the `stage-end` that records `kill_reason`, and
# deliberately so. The watchdog's kill path had fired zero times in the whole
# recorded history when it was written: every stage this pipeline has ever
# killed was emitting steadily at the moment the wall reached it. So the first
# time it does fire, one of two things is true and both are news — either a
# genuinely wedged actor has been caught, which is what it is for, or the
# threshold is too tight for something a stage legitimately does, which is the
# failure this whole mechanism exists to end arriving from the other side. The
# rate is the thing to watch, and a rate nobody is told about is not watched.
stage_watchdog_warning() {
  [[ "$stage_kill_reason" == "inactivity" ]] || return 1
  jq -nc --arg s "$1" \
    '{detail: ($s + " was stopped by the liveness watchdog: it produced no output at all for its whole inactivity threshold. Either it was wedged, which is what the watchdog is for, or the threshold is too tight for what it was doing — check the stage stream before assuming the first.")}'
}

# --- Run a headless model-stage invocation with a wall-clock timeout, killing
#     its whole process group on timeout. `set -m` gives the backgrounded job
#     its own process group so `kill -TERM -$pid` reaches every descendant. ---
#
# run_model_stage STAGE TIMEOUT_SEC MODEL PROMPT OUT_FILE CWD [INACTIVITY_SEC] [RESUME_SESSION_ID]
# Returns the invocation's own exit status, or 124 when either cap fired.
# Sets the caller-visible `stage_pid`/`stage_name` for the duration (see the
# note at each pipeline's signal handler) and clears them on the way out,
# `stage_kill_reason` to say which cap fired, if either, and `stage_provider`
# to the provider MODEL resolved to (`stage_model_substrate`'s own input).
#
# RESUME_SESSION_ID, when given, is passed through as a session to resume:
# PROMPT then continues that session instead of starting a fresh one. This is
# the one mechanism a salvage attempt needs (issue #237) — the model that
# already did the work is asked to restate its verdict, not to redo the work
# from nothing. Every other cap, kill and metering path is identical to a
# fresh run; a caller distinguishes a salvage's own record by the `stage` name
# it passes.
#
# TIMEOUT_SEC is the **backstop**: the outer bound on a stage, there for the
# one failure the watchdog cannot see — a session looping productively,
# emitting events forever without converging. INACTIVITY_SEC is the
# **watchdog**: how long a stage may produce nothing at all before it is
# treated as wedged. Zero or absent disables the watchdog and leaves the
# backstop as the only cap, which is what this function did before either
# existed.
#
# The two exist because they answer different questions and are estimated
# from wildly different amounts of evidence (requirement 4e). A wall-clock
# cap alone conflates "this is taking a long time" with "this has stopped",
# and the record says the pipeline only ever killed the first: across 456
# stage runs, every killed run was emitting steadily when the wall reached
# it, and not one genuinely hung actor was found.
run_model_stage() {
  local stage="$1" timeout_sec="$2" model="$3" prompt="$4" out_file="$5" cwd="$6"
  local inactivity_sec="${7:-0}" resume_session_id="${8:-}"
  local pid waited=0 rc stream_file rate_limit_info substrate
  local seen_bytes=0 now size last_growth gaps=()
  substrate="$(stage_model_substrate "$model")"
  stream_file="$(stage_stream_file "$out_file")"
  stage_gaps_json="null"
  stage_kill_reason=""
  stage_rate_limit_json=""
  # Read by detect_and_log_limit_hit's three copies (agent-cycle.sh,
  # review-cycle.sh, monitor-cycle.sh), which shellcheck cannot see from here.
  # Falls back to `anthropic` for a MODEL the map holds nothing for; an empty
  # MODEL is handled separately, since bash makes an empty subscript on an
  # associative array a hard "bad array subscript" error rather than an empty
  # read, as stage_model_substrate's own header above explains.
  # shellcheck disable=SC2034
  if [[ -n "$model" ]]; then
    stage_provider="${MODEL_PROVIDER[$model]:-anthropic}"
  else
    stage_provider="anthropic"
  fi

  # Requirement 4k: never start the runner in a directory whose project
  # settings could make it run something. The three files are left as a stage
  # that never ran leaves them, with the reason on stderr, where an operator
  # reading `<stage>.out.stderr` will look first and where
  # `handle_stage_failure` reads it. No variable carries it: one would outlive
  # this call, and a later failure in the same cycle would inherit it.
  # `stage_kill_reason` stays empty, because the stage-budget controller reads
  # a kill reason as a cap kill and the rework ledger as a re-run, and a stage
  # that never started is neither.
  local settings_refusal
  if settings_refusal="$(stage_project_settings_refusal "$cwd" "$substrate")"; then
    : >"$stream_file"
    : >"$out_file"
    printf 'run_model_stage: the %s stage was not launched: %s (requirement 4k)\n' \
      "$stage" "$settings_refusal" >"$out_file.stderr"
    return 1
  fi
  if settings_refusal="$(stage_user_settings_refusal)"; then
    : >"$stream_file"
    : >"$out_file"
    printf 'run_model_stage: the %s stage was not launched: %s (requirement 4k)\n' \
      "$stage" "$settings_refusal" >"$out_file.stderr"
    return 1
  fi

  # stdout (the event stream) and stderr (diagnostics) are kept in separate
  # files — merging them would let stray stderr output break the JSON parse
  # of the events.
  #
  # `--output-format stream-json --verbose` rather than `--output-format
  # json`, and the difference is not the shape of the answer but *when* it
  # arrives: the JSON form writes one object at the very end, so a stage
  # killed at its cap leaves an empty file and nothing at all is known about
  # what it had done. The stream form flushes an event per line as the run
  # proceeds, so a stage's progress is observable while it is still running
  # and survives a kill. The final line of a completed stream is the same
  # envelope the JSON form produced, and it is what lands in `.out` below, so
  # nothing downstream of here can tell the difference.
  #
  # The prompt goes in on stdin, never as an argument (requirement 4c). Linux
  # caps a *single* argv entry at MAX_ARG_STRLEN — 32 pages, 131072 bytes,
  # fixed at compile time and unaffected by `ulimit`, so `getconf ARG_MAX`'s
  # far larger total is no guide to it. An assembled stage prompt is already
  # the same order of magnitude and grows with every prompt edit, so passing
  # it as an argument puts the pipeline one paragraph away from an exec that
  # fails with E2BIG before the model is ever reached. A here-string (rather
  # than a pipe) keeps the invocation a single process whose status is the
  # stage's own: under `pipefail` a `printf | claude` would report printf's
  # SIGPIPE, 141, whenever a stage exited without draining stdin.
  #
  # This pipeline's own prompts have room to spare in the review cycle and
  # none to spare in the implementation cycle; they share this function
  # precisely so the one with room cannot quietly stop being covered.
  #
  # The substrate adapter's own `_exec` becomes this subshell via `exec`
  # (lib/substrate-claude-code.sh), so it is still this backgrounded job's
  # pid and process group that `$!` captures below and that the caps below
  # kill — never a child of it.
  set -m
  ( cd "$cwd" && "substrate_${substrate//-/_}_exec" "$model" "$resume_session_id" <<<"$prompt" ) \
    >"$stream_file" 2>"$out_file.stderr" &
  pid=$!
  set +m
  # Advertised for the signal handler (requirement 9c): the job's own process
  # group is beyond any signal sent to ours, so a handler that does not know
  # this pid cannot stop the model this cycle is paying for.
  stage_pid="$pid"
  stage_name="$stage"

  # The gap clock starts at the launch, so the first gap recorded is the wait
  # for the run's very first byte — model start-up, which is a real silence
  # and one of the longer ones. Wall-clock rather than the poll counter
  # below: `waited` advances two per iteration regardless of what the
  # iteration cost, so under contention — precisely when gaps stretch — it
  # would under-report the silence it is there to measure. The counter still
  # drives the timeout, unchanged, so nothing about when a stage is killed
  # moves with this.
  last_growth="${EPOCHSECONDS:-$(date +%s)}"

  rc=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= timeout_sec )); then
      stage_kill_reason="backstop"
      kill -TERM "-$pid" 2>/dev/null || true
      sleep 5
      kill -KILL "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rc=124
      break
    fi
    sleep 2
    waited=$(( waited + 2 ))
    # Liveness is monotonic growth of the stream file, not a beat count and
    # not anything the stage cooperates in: the actor emits nothing for this,
    # cannot fake it, and needs no cadence to keep. `stat` on a file the
    # kernel already has open is as cheap as this loop's own `kill -0`.
    size="$(stat -c %s "$stream_file" 2>/dev/null || printf '0')"
    now="${EPOCHSECONDS:-$(date +%s)}"
    if (( size > seen_bytes )); then
      gaps+=( "$(( now - last_growth ))" )
      seen_bytes="$size"
      last_growth="$now"
      # The account has said no. Nothing this stage does from here can
      # succeed, so every second it goes on holding the node is spent on a
      # foregone conclusion: limit detection has always run on the transcript
      # *after* the stage ended, which meant a stage that hit a limit early
      # burned the rest of its wall-clock cap first. Checked only when the
      # stream grew, because that is the only moment a new event can have
      # arrived.
      if rate_limit_info="$(stage_rejected_rate_limit "$stream_file" "$substrate")"; then
        # shellcheck disable=SC2034  # read by each pipeline's limit detection
        stage_rate_limit_json="$rate_limit_info"
        stage_kill_reason="rate-limit"
        kill -TERM "-$pid" 2>/dev/null || true
        sleep 5
        kill -KILL "-$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rc=124
        break
      fi
    elif (( inactivity_sec > 0 && now - last_growth >= inactivity_sec )); then
      # Nothing has been written for the whole threshold. The kill is the same
      # sequence as the backstop's — same process group, same TERM-then-KILL
      # grace — because there is only one way to stop a stage; what differs is
      # the reason, which the caller records so the two are told apart
      # afterwards. `exit_code: 124` alone cannot: it conflates "hung" with
      # "ran too long", and those imply opposite corrections. (Read by each
      # pipeline's failure handling, which shellcheck cannot see from here.)
      # shellcheck disable=SC2034
      stage_kill_reason="inactivity"
      kill -TERM "-$pid" 2>/dev/null || true
      sleep 5
      kill -KILL "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rc=124
      break
    fi
  done

  # The interval since the last growth is a gap too, and on a stage that was
  # killed it is the one that matters most — a run that fell silent and was
  # cut off has its longest silence at the end, unterminated by any event.
  # Dropping it would leave exactly the population this measurement exists to
  # find missing from the sample.
  #
  # Recorded unconditionally, even when it is zero, so that every run that
  # happened has at least one observation and `null` means one thing only:
  # this record was not measured. A stage that emitted nothing whatever is
  # then a run with a single gap spanning the whole of it, which is both true
  # and the case a liveness threshold most needs in its sample.
  now="${EPOCHSECONDS:-$(date +%s)}"
  gaps+=( "$(( now - last_growth ))" )

  if (( rc != 124 )); then
    wait "$pid"
    rc=$?
  fi
  # Cleared for the signal handler, which reads these to decide whether to
  # blame a stage or the cycle. shellcheck cannot see that reader from here —
  # it lives in whichever script sourced this file.
  # shellcheck disable=SC2034
  stage_pid=""
  # shellcheck disable=SC2034
  stage_name=""

  # Read by each pipeline's `stage-end` site, which shellcheck cannot see from
  # inside this library.
  # shellcheck disable=SC2034
  stage_gaps_json="$(stage_gap_stats "${gaps[@]+"${gaps[@]}"}")"

  # `.out` is written on every path, including the killed one, so a reader
  # never has to distinguish "no envelope" from "no file": the callers'
  # `jq -r '.result // empty'` and `metering_fields` both already degrade to
  # nothing on an empty file, which is exactly what a killed stage leaves.
  # Truncating the stream to its result event here — rather than publishing
  # the stream as `.out` — is also what keeps the state mirror's size where
  # it was: see scripts/state-sync.sh on why a stream is never replicated.
  stage_result_line "$stream_file" "$substrate" >"$out_file" 2>/dev/null || : >"$out_file"

  # A cap kill's own 124 is already the verdict (requirement 4e) — never
  # corrected, since it did not come from the provider at all. Every other
  # path asks the substrate whether its own exit status needs folding
  # against what `.out` actually says (lib/substrate-grok-build.sh's
  # `_verdict_rc`; every other substrate today leaves RC exactly as given).
  if (( rc != 124 )); then
    rc="$(stage_verdict_rc "$rc" "$out_file" "$substrate")"
  fi

  # The GitHub budget reading after the model's own run, attributed to this
  # stage (requirement 2.0d, lib/github-limit.sh's `github_budget_record`).
  # Guarded rather than assumed: a caller that sources this file without the
  # recorder simply gets no record, and a reading that fails never costs the
  # stage its exit status.
  if declare -F github_budget_record >/dev/null 2>&1; then
    github_budget_record stage "$stage" || true
  fi

  return "$rc"
}
