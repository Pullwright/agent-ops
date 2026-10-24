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
# shellcheck source=lib/lane.sh
# lane_effective_open, `stage_lane_draw`'s own open/closed rule (below) —
# self-sourced for the same reason the two substrate adapters above are: a
# caller of this file alone must not have to know it also needs lib/model-id.sh
# or lib/lane.sh loaded first.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lane.sh"

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
# lib/model-id.sh's own map (issue #2240, D30): a provider's `api`/`subscription`
# weights and `enabled` flags, read by `stage_lane_draw` below. Guarded the
# same way and for the same reason — several of this file's own tests source
# it alone, never lib/model-id.sh, and a bare reference under `set -u` would
# abort them rather than read empty.
declare -p PROVIDER_LANES >/dev/null 2>&1 || declare -gA PROVIDER_LANES=()

# The lanes object `stage_lane_draw` reads when PROVIDER_LANES holds nothing
# for a run's own provider — every caller that never called
# lib/model-id.sh's `providers_load` (most of this file's own tests) and
# every provider `providers_load` itself has not been told about. Mirrors
# that function's own all-default `anthropic` synthesis (weight 1 for `api`,
# 0 for `subscription`, both `enabled: null`) without the spend fields
# `stage_lane_draw` never reads.
STAGE_LANE_DEFAULT_JSON='{"api":{"weight":1,"enabled":null},"subscription":{"weight":0,"enabled":null}}'

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

# The lane the most recent run was launched on (issue #2241, D30) — "api" or
# "subscription" when `stage_provider`'s substrate manages lanes at all (only
# `claude-code` does today) and at least one of that provider's two lanes has
# a credential present on this node, empty otherwise (every other substrate,
# and a claude-code run on a node with neither credential, which is simply
# unmanaged — see `run_model_stage`'s own "Presence" handling). Distinct from
# `stage_lane_json`, which is what the stream *observed*: this is what the
# launcher *forced*, sits beside `stage_provider` for `detect_and_log_limit_hit`'s
# three copies to read (#2242), and is what the live-stream watch below
# verifies the observed lane against.
stage_lane=""

# `{forced, observed}` when the most recent run was stopped for
# `kill_reason: "lane-mismatch"`, read by `stage_watchdog_warning`'s own
# warning text; empty otherwise.
stage_lane_mismatch_json=""

# `{api: {present, weight, enabled}, subscription: {...}}` when the most
# recent run was refused for `kill_reason: "no-open-lane"`, read the same
# way; empty otherwise.
stage_lane_states_json=""

# Set to 1 for exactly the run whose `init` event first revealed a forced
# subscription login as a managed (Console) key — see
# SUBSTRATE_CLAUDE_CODE_SUBSCRIPTION_MANAGED_KEY in
# lib/substrate-claude-code.sh. `stage_watchdog_warning` reads this once and
# clears it, so the warning it earns reaches the caller exactly once per
# cycle rather than once per run for the rest of it.
stage_lane_managed_key_detected=""

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

# _stage_toml_top_level_sections  < TOML on stdin
# One line per table header the TOML on stdin declares: the section's own
# name where the header is a plain `[name]` that can be compared against an
# allowlist, and the header line itself, verbatim, where it is any other
# shape. A line reader, not a parser: this reads only what a header *line*
# says, which is all requirement 4k's Grok guard needs to ask ("does this
# file touch any section beyond the allowed three"), never what a section's
# own keys hold.
#
# That second case is why this is not one regular expression. An
# array-of-tables header (`[[plugins]]`), a quoted one (`["hooks"]`) and a
# whitespaced one (`[ hooks ]`) are all valid TOML, and each declares a
# section as surely as `[hooks]` does; a pattern matching only `[name]`
# reports none of them, and a header this function does not report is one
# the caller cannot refuse, since it refuses a file only for the sections it
# is told about. So anything header-shaped this cannot read as a bare name
# is printed as itself, which no allowlist entry matches — the same
# safe-by-default stance the JSON checks below take toward a file they
# cannot parse. A line that opens with `[` without closing on the same line
# (an array value spilling over several) is not header-shaped and is
# skipped; so is a blank or indented-value line, since a header is the only
# thing whose first non-blank character is `[`.
_stage_toml_top_level_sections() {
  local line stripped
  while IFS= read -r line || [[ -n "$line" ]]; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    [[ "$stripped" == '['* ]] || continue
    [[ "$stripped" =~ \][[:space:]]*(#.*)?$ ]] || continue
    if [[ "$stripped" =~ ^\[([A-Za-z0-9_.-]+)\][[:space:]]*(#.*)?$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    else
      printf '%s\n' "$stripped"
    fi
  done
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
# so never needs vetted. `.grok/config.toml` is read through
# `stage_boundary_read`, on the same terms and for the same reason the
# `.claude` files are; `.grok/lsp.json` is refused on sight, so its content
# is never opened at all.
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
      # Read as the stage user reads it, bounded in time and size, for the
      # same reason the `.claude` files above are (lib/stage-boundary.sh's
      # second rule): this directory is often a workspace an earlier stage
      # has had, so the path can be a link to a file only the Script can
      # read, or a FIFO that never answers whoever opens it. Refused rather
      # than skipped when it cannot be read that way — a file this guard
      # cannot see is a file it cannot vet.
      if ! content="$(stage_boundary_read "$file" "$((STAGE_PROJECT_SETTINGS_MAX_BYTES + 1))" && printf x)" \
         || (( $(_stage_byte_length "${content%x}") > STAGE_PROJECT_SETTINGS_MAX_BYTES )); then
        printf '.grok/config.toml cannot be read as a file of at most %s bytes, so it cannot be vetted; %s' \
          "$STAGE_PROJECT_SETTINGS_MAX_BYTES" "$(stage_project_settings_origin "$dir" ".grok/config.toml")"
        return 0
      fi
      disallowed=""
      while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        case " $STAGE_GROK_CONFIG_ALLOWED_SECTIONS " in
          *" $s "*) ;;
          *) disallowed+="${disallowed:+, }$s" ;;
        esac
      done < <(_stage_toml_top_level_sections <<<"${content%x}")
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

# stage_lane_of STREAM_FILE [SUBSTRATE]
# Print the credential lane the run actually used — "api" or "subscription"
# — or nothing (returning 1) when the stream carries no readable answer.
# Dispatches to SUBSTRATE's own `substrate_<name>_lane_of` (default
# `claude-code`, same reasoning as `stage_result_line` above). The vocabulary
# itself (which `apiKeySource` strings mean which lane) is each adapter's own
# business now — see lib/substrate-claude-code.sh's copy.
stage_lane_of() {
  local stream_file="$1" substrate="${2:-claude-code}"
  "substrate_${substrate//-/_}_lane_of" "$stream_file"
}

# stage_lane_any_present SUBSTRATE
# True (exit 0) iff SUBSTRATE manages lanes at all (defines its own
# `substrate_<name>_lane_present`, today only `claude-code` — #2246 is
# Grok Build's own) *and* at least one of its two lanes' credentials is
# present on this node right now. False for every other substrate (no lane
# management: `run_model_stage` launches exactly as it did before #2241) and
# for a claude-code run with neither credential present (also unmanaged
# — see `run_model_stage`'s own "Presence" handling for why that is the
# right default rather than refusing to launch at all).
stage_lane_any_present() {
  local substrate="$1" fn
  fn="substrate_${substrate//-/_}_lane_present"
  declare -F "$fn" >/dev/null 2>&1 || return 1
  "$fn" api && return 0
  "$fn" subscription && return 0
  return 1
}

# stage_lane_draw PROVIDER SUBSTRATE SEED
# Draws a lane ("api" or "subscription") for PROVIDER on SUBSTRATE among its
# open lanes, by weight (issue #2241, D30, docs/ROADMAP.md's D30 row) — only
# ever called once `stage_lane_any_present` has already confirmed at least
# one of the two is present.
#
# A lane is open when it is present (SUBSTRATE's own
# `substrate_<name>_lane_present`) and `enabled`: true opens it outright,
# false closes it outright, and unset (the common case: PROVIDER_LANES'
# own default, and every lane config.json's `lanes` block does not mention)
# opens it only when it is the lane the CLI would use unaided — `api`
# whenever it is present, `subscription` only when it is present and `api`
# is not (D4's own precedence; the same rule `scripts/doctor.sh`'s
# `lane_enabled_desc` reports against).
#
# Among the open lanes of positive weight, one is drawn with probability
# proportional to its weight; with none, the open lane of weight zero (there
# is normally at most one); with neither, nothing is printed and the exit
# status is 1 — the caller's own business how to read that (see
# `run_model_stage`'s "no open lane" handling).
#
# The draw itself is `cksum SEED mod (the open weighted lanes' total
# weight)`, bucketed by each candidate's own share of that total — never
# `$RANDOM`, which is unseeded by design (`lib/expensive-gather-cache.sh`'s
# `_expensive_gather_node_offset` is the same pattern, for the same reason):
# the same SEED always draws the same lane, so a record explains a draw
# after the fact and a test reproduces it rather than merely sampling it.
# `run_model_stage` seeds this on the launch's own identifier — the cycle id,
# the stage name, and (when given) a caller's own seed suffix distinguishing
# this launch from a sibling launch of the same stage in the same cycle — so
# a draw is reproducible without being predictable far enough ahead to game.
stage_lane_draw() {
  local provider="$1" substrate="$2" seed="$3" fn lanes_json
  fn="substrate_${substrate//-/_}_lane_present"
  lanes_json="${PROVIDER_LANES[$provider]:-$STAGE_LANE_DEFAULT_JSON}"
  [[ -n "$lanes_json" ]] || lanes_json="$STAGE_LANE_DEFAULT_JSON"

  local present_api=0 present_sub=0
  "$fn" api && present_api=1
  "$fn" subscription && present_sub=1

  local w_api w_sub
  w_api="$(jq -r '.api.weight // 1' <<<"$lanes_json" 2>/dev/null)"
  [[ "$w_api" =~ ^[0-9]+$ ]] || w_api=1
  w_sub="$(jq -r '.subscription.weight // 0' <<<"$lanes_json" 2>/dev/null)"
  [[ "$w_sub" =~ ^[0-9]+$ ]] || w_sub=0

  # Open/closed is `lane_effective_open`'s own call (lib/lane.sh) — shared
  # with `lib/mix.sh`'s status report, so a live `--mix` weight is drawn from
  # exactly the lanes `--status` describes as open (requirement 34a).
  local open_api=0 open_sub=0
  lane_effective_open "$lanes_json" api "$present_api" "$present_sub" && open_api=1
  lane_effective_open "$lanes_json" subscription "$present_api" "$present_sub" && open_sub=1

  local -a weighted=() fallback=()
  (( open_api )) && (( w_api > 0 )) && weighted+=(api)
  (( open_sub )) && (( w_sub > 0 )) && weighted+=(subscription)
  (( open_api )) && (( w_api == 0 )) && fallback+=(api)
  (( open_sub )) && (( w_sub == 0 )) && fallback+=(subscription)

  local hash
  hash="$(cksum <<<"$seed" | cut -d' ' -f1)"
  [[ "$hash" =~ ^[0-9]+$ ]] || hash=0

  if (( ${#weighted[@]} > 0 )); then
    local total=0 name w pick cum=0
    for name in "${weighted[@]}"; do
      case "$name" in api) w=$w_api ;; subscription) w=$w_sub ;; esac
      total=$(( total + w ))
    done
    (( total > 0 )) || total=1
    pick=$(( hash % total ))
    for name in "${weighted[@]}"; do
      case "$name" in api) w=$w_api ;; subscription) w=$w_sub ;; esac
      cum=$(( cum + w ))
      if (( pick < cum )); then
        printf '%s\n' "$name"
        return 0
      fi
    done
    printf '%s\n' "${weighted[$(( ${#weighted[@]} - 1 ))]}"
    return 0
  fi

  if (( ${#fallback[@]} > 0 )); then
    printf '%s\n' "${fallback[$(( hash % ${#fallback[@]} ))]}"
    return 0
  fi

  return 1
}

# stage_model_draw_into VAR SET_KEY SEED
# Draws one member of `lib/model-id.sh`'s MODEL_SET_JSON[SET_KEY] by weight
# (issue #2247) — the same seeded `cksum`-mod-total-weight-then-bucket draw
# `stage_lane_draw` above already uses for lanes, reused here rather than
# duplicated with a different rule, since "drawn by the same weighted rule"
# is the set's own contract. Sets VAR to the chosen member's bare model id.
#
# The assigning form, never a printing one: this function's own
# STAGE_MODEL_DRAWN_QUALIFIED side effect below needs a caller that invokes
# it directly, not through a command substitution — a subshell would take
# that recording with it when it exits, the identical trap
# `resolve_model_id_into`'s own header warns about for MODEL_PROVIDER.
#
# A member whose provider has no credential lane open right now is skipped
# in favour of a sibling's draw — the identical `stage_lane_any_present`-then-
# `stage_lane_draw` check `run_model_stage`'s own launch repeats for
# whichever model this settles on, so a model is never handed to it only to
# fail there for a lane reason this draw could have avoided. SEED is reused
# unchanged across every skip: the live candidate pool shrinks (and its
# total weight is recomputed over just what remains) rather than the hash
# being redrawn, so a set with one closed-lane member still draws its
# siblings deterministically from the one seed, the same way the lane draw
# itself is deterministic from one seed over whichever lanes are open.
#
# If every member's provider turns out shut, this gives up skipping and
# settles on the very first (unscreened) draw: `run_model_stage`'s own
# "no open lane" refusal, naming that provider, is the correct outcome for
# a set with nothing open anywhere, not a special case this draw needs to
# pre-empt.
#
# Side effect: STAGE_MODEL_DRAWN_QUALIFIED, the chosen member's own
# qualified id — reset on every call, the same convention `stage_lane`
# (set by `run_model_stage` itself) already uses for its own draw — read by
# `stage_model_resolve_into` below to report which member a set's handle
# drew.
stage_model_draw_into() {
  local __smd_var="$1" set_key="$2" seed="$3" hash members_json
  STAGE_MODEL_DRAWN_QUALIFIED=""
  members_json="${MODEL_SET_JSON[$set_key]:-[]}"

  local -a ids=() weights=()
  while IFS=$'\t' read -r id weight; do
    [[ -n "$id" ]] || continue
    ids+=("$id")
    weights+=("$weight")
  done < <(jq -r '.[] | [.id, .weight] | @tsv' <<<"$members_json" 2>/dev/null)
  local n=${#ids[@]}
  (( n > 0 )) || { printf -v "$__smd_var" '%s' ""; return 1; }

  hash="$(cksum <<<"$seed" | cut -d' ' -f1)"
  [[ "$hash" =~ ^[0-9]+$ ]] || hash=0

  local -a live=()
  local i
  for ((i = 0; i < n; i++)); do live+=("$i"); done

  local chosen="" first=""
  while true; do
    if (( ${#live[@]} == 0 )); then
      chosen="$first"
      break
    fi
    local total=0
    for i in "${live[@]}"; do total=$(( total + weights[i] )); done
    (( total > 0 )) || total=1
    local pick=$(( hash % total )) cum=0
    chosen=""
    for i in "${live[@]}"; do
      cum=$(( cum + weights[i] ))
      if (( pick < cum )); then
        chosen="$i"
        break
      fi
    done
    [[ -n "$chosen" ]] || chosen="${live[-1]}"
    [[ -n "$first" ]] || first="$chosen"

    local cand_bare cand_substrate cand_provider
    cand_bare="${ids[$chosen]#*/}"
    cand_substrate="$(stage_model_substrate "$cand_bare")"
    if ! declare -F "substrate_${cand_substrate//-/_}_lane_present" >/dev/null 2>&1; then
      break
    fi
    cand_provider="${MODEL_PROVIDER[$cand_bare]:-anthropic}"
    if stage_lane_any_present "$cand_substrate" \
        && stage_lane_draw "$cand_provider" "$cand_substrate" "$seed" >/dev/null 2>&1; then
      break
    fi
    local -a next_live=()
    for i in "${live[@]}"; do
      (( i == chosen )) || next_live+=("$i")
    done
    live=("${next_live[@]}")
  done

  STAGE_MODEL_DRAWN_QUALIFIED="${ids[$chosen]}"
  printf -v "$__smd_var" '%s' "${ids[$chosen]#*/}"
}

# stage_model_resolve_into VAR MODEL_VALUE SEED
# Sets VAR to the concrete bare model id to launch: MODEL_VALUE unchanged
# when it is not a weighted set (`lib/model-id.sh`'s `model_key_is_set`), or
# the member `stage_model_draw_into` settles on when it is. Every call site
# that launches a stage calls this once, with the exact seed its own
# `run_model_stage` call below will reuse for the lane draw
# (`"${cycle_id:-}:$stage${seed_suffix:+:$seed_suffix}"`) — so the model is
# chosen before the lane, as the set's own contract requires, and the two
# draws agree on what "this launch" means.
#
# Side effect: STAGE_MODEL_SET_EXTRA_JSON, a compact JSON object ready to
# fold into `stage_budget_apply`'s own EXTRA parameter (`lib/stage-budget.sh`)
# so the `stage-start` event names the set key and the member drawn —
# `{"model_set": KEY, "model_set_member": QUALIFIED_ID}` when MODEL_VALUE
# named a set, `{}` otherwise. Reset on every call, the same convention
# `stage_model_draw_into`'s own STAGE_MODEL_DRAWN_QUALIFIED already uses.
stage_model_resolve_into() {
  local __smr_var="$1" __smr_value="$2" __smr_seed="$3" __smr_drawn
  STAGE_MODEL_SET_EXTRA_JSON='{}'
  if model_key_is_set "$__smr_value"; then
    stage_model_draw_into __smr_drawn "$__smr_value" "$__smr_seed"
    STAGE_MODEL_SET_EXTRA_JSON="$(jq -nc --arg k "$__smr_value" \
      --arg m "${STAGE_MODEL_DRAWN_QUALIFIED:-}" '{model_set: $k, model_set_member: $m}')"
    printf -v "$__smr_var" '%s' "$__smr_drawn"
  else
    printf -v "$__smr_var" '%s' "$__smr_value"
  fi
}

# stage_watchdog_warning STAGE
# The body of the `warning` event a watchdog kill, a lane mismatch, or an
# exhausted lane set earns, or nothing (returning 1) when the last run ended
# any other way and reported no managed-key login either. Every one of this
# function's own 8 call sites already calls it unconditionally after every
# run and logs a `warning` event iff it printed something, so each new
# condition below reaches every caller for free.
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
#
# The managed-key notice (issue #2241, D30) is not keyed on `stage_kill_reason`
# at all — that run did not fail, it simply billed differently than the draw
# intended — so it is checked first, against `stage_lane_managed_key_detected`,
# which `run_model_stage` itself resets at the top of every call and sets only
# for the one run that first flips SUBSTRATE_CLAUDE_CODE_SUBSCRIPTION_MANAGED_KEY.
# So this notice fires for exactly the run that discovered the managed key,
# not for every run afterwards — see that reset's own comment for why this
# function cannot clear the flag itself (every call site reads it through a
# command substitution).
stage_watchdog_warning() {
  local stage="$1"
  if [[ -n "${stage_lane_managed_key_detected:-}" ]]; then
    jq -nc --arg s "$stage" \
      '{detail: ($s + "'"'"'s forced subscription lane reported a Console login (\"/login managed key\"), which bills an API account rather than opening a subscription lane; the subscription lane is treated as absent for the rest of this cycle.")}'
    return 0
  fi
  case "$stage_kill_reason" in
    inactivity)
      jq -nc --arg s "$1" \
        '{detail: ($s + " was stopped by the liveness watchdog: it produced no output at all for its whole inactivity threshold. Either it was wedged, which is what the watchdog is for, or the threshold is too tight for what it was doing — check the stage stream before assuming the first.")}'
      ;;
    lane-mismatch)
      jq -nc --arg s "$stage" --argjson m "${stage_lane_mismatch_json:-null}" \
        '{detail: ($s + " was stopped: the lane its stream reported does not match the lane it was launched on."), lane: $m}'
      ;;
    no-open-lane)
      jq -nc --arg s "$stage" --arg p "$stage_provider" --argjson l "${stage_lane_states_json:-null}" \
        '{detail: ($s + " was not launched: no lane is open for provider " + $p + " — check config.json'\''s providers." + $p + ".lanes."), provider: $p, lanes: $l}'
      ;;
    *) return 1 ;;
  esac
}

# stage_lane_mismatch_standdown STATE_DIR STAGE
# Writes the local switch (`lib/toggle.sh`'s `toggle_disable`,
# `state_dir/disabled.json`, `kind: "auto"`) iff the most recent run's own
# `stage_kill_reason` is `lane-mismatch` (issue #2241, D30) — a no-op,
# returning 1, for every other kill reason, so every call site can call this
# unconditionally, the same convention `stage_watchdog_warning` already is.
#
# A lane mismatch means this node's own configuration — `ANTHROPIC_API_KEY`,
# a project or user settings file, an environment override — no longer
# matches what the Script forced, which is a fault in the node rather than
# in the item the stage was working: every further cycle on this node would
# re-force the same lane and mismatch again. So the whole node stops taking
# further cycles until a human clears it (`agent-cycle.sh --enable`, having
# fixed whatever drifted), `kind: "auto"` and `scope: "node"` because this is
# a detector's own inference about this one node, never an operator's
# deliberate choice and never the fleet's. `forever`: nothing here can know
# how long the drift will take to notice and fix, so there is no TTL to
# derive one from — the other automatic stand-downs this pipeline writes
# (a usage limit, a disk threshold) all carry their own natural clock to
# expire against; a lane mismatch has none.
#
# Escalating this the way the credential-refused preflight does
# (`lib/standdown.sh`, `create_escalation_issue`) is deferred (filed as its
# own tech-debt item): that helper's own context
# (`crash_loop_repo`/`enabler_assignee`, `lib/enabler.sh`) exists only in
# `agent-cycle.sh`'s own process, not `review-cycle.sh`'s or
# `monitor-cycle.sh`'s, so filing correctly from all three needs its own
# design rather than reusing this one in place. The switch itself already
# stops this node outright: a human reading the dashboard or `--status`
# finds it disabled, the same as any other automatic stand-down, just not
# yet paged for one proactively.
stage_lane_mismatch_standdown() {
  local state_dir="$1" stage="$2" reason detail
  [[ "$stage_kill_reason" == "lane-mismatch" ]] || return 1
  detail="$(jq -r '"forced " + .forced + ", observed " + .observed' \
    <<<"${stage_lane_mismatch_json:-null}" 2>/dev/null)"
  [[ -n "$detail" && "$detail" != "forced , observed " ]] || detail="see the stage-end event"
  reason="the ${stage} stage's forced credential lane did not match what it actually used ($detail) — issue #2241, D30: this node's own configuration no longer matches what the Script forced"
  toggle_disable "$state_dir" "$reason" forever 0 "agent-ops" "lane-mismatch:$stage" auto node stop \
    >/dev/null 2>&1
}

# _stage_snapshot_and_push CWD
# Best-effort recovery net for a stage this function's caller is about to
# kill (issue #2186): before the final `kill -KILL`, commit and push whatever
# CWD's working tree holds, so a run stopped mid verification — a build, a
# full test suite — after real work was done leaves that work on the claimed
# branch rather than only in the clone, which is gone the moment this stage's
# workspace is removed. Without this, recovery depends entirely on the stage
# itself having committed and pushed before the cap fired — exactly the step
# a stage mid-verification has by definition not reached yet.
#
# Runs through `stage_boundary_capture` rather than a plain `git` call: CWD
# is the stage's own workspace (requirement 45e of
# docs/spec/implementation/requirements/every-stage.md), and on an
# installation with the boundary present, this is what keeps the commit and
# push running as the stage user, never as this far more privileged process —
# running git there as this user would run whatever a stage's own
# `.git/config` names (`core.fsmonitor`, hooks, diff/filter drivers) with that
# far greater privilege. Where there is no boundary at all — a developer's
# checkout, this file's own test — `stage_boundary_capture` runs the same
# commands as this user instead, on the terms `lib/stage-boundary.sh` already
# documents for every other boundary crossing: there is no privileged user on
# this side of a boundary that does not exist to protect. Bounded in time for
# the same reason every other boundary crossing here is: a wedged `git push`
# must not hold up the kill it is meant to precede.
#
# Never the default branch, and that check comes before the commit rather
# than after it. The clone the Script hands a stage arrives on the
# repository's default branch (`clone_repo`, lib/repo-clone.sh) — it is the
# stage itself that checks its own branch out (requirement 23a's step 1, and
# the review pipeline's own first step) — so a stage killed before it got
# that far is still standing there, and a push would carry unreviewed work
# straight at `refs/heads/<default_branch>`. The remote's own protection
# would refuse it on every repository worked here, but the one thing this net
# must never attempt cannot rest on a setting on the far side of it. The
# default branch is read from `refs/remotes/origin/HEAD`, which a plain
# `git clone` always sets, and a clone that names none at all is refused
# rather than guessed about: fail closed, since "which branch must not be
# pushed to" is exactly the question a silent fallback would get wrong.
#
# A no-op — never a warning, never a failure this function reports — when
# there is no `.git`, nothing uncommitted, the branch is the default one or
# unknowable, or the commit/push itself fails (a moved branch, a network
# blip, no upstream remote): this is a safety net for the common case, not a
# guarantee, and its own failure must never change whether or how the stage
# is killed. A branch genuinely untouched when the stage is killed
# stays genuinely untouched — there is nothing for `git status --porcelain`
# to report, so this prints nothing and `release_branch_if_untouched`
# (lib/claim.sh) still reaps it exactly as before.
_stage_snapshot_and_push() {
  local cwd="$1"
  [[ -d "$cwd/.git" ]] || return 0
  # shellcheck disable=SC2016  # the script is the stage user's bash's to expand
  stage_boundary_capture 25 1 bash -c '
    cd "$1" || exit 0
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || exit 0
    [[ -n "$branch" && "$branch" != "HEAD" ]] || exit 0
    default="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || default=""
    default="${default#origin/}"
    [[ -n "$default" && "$branch" != "$default" ]] || exit 0
    [[ -n "$(git status --porcelain 2>/dev/null)" ]] || exit 0
    git add -A >/dev/null 2>&1 || exit 0
    git commit -q -m "chore: snapshot work in progress before a stage cap stopped the run" \
      >/dev/null 2>&1 || exit 0
    git push -q origin "HEAD:refs/heads/$branch" >/dev/null 2>&1
  ' _ "$cwd" >/dev/null 2>&1 || true
  return 0
}

# _stage_kill PID CWD
# The one kill sequence every cap below uses: TERM, a grace period, the
# snapshot above (while the process is (hopefully) no longer touching CWD but
# before its group is gone for good), then KILL and a reap. Shared so the
# three caps cannot drift into killing differently, and so the snapshot is
# never a line a future cap forgets to add.
_stage_kill() {
  local pid="$1" cwd="$2"
  kill -TERM "-$pid" 2>/dev/null || true
  sleep 5
  _stage_snapshot_and_push "$cwd"
  kill -KILL "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# --- Run a headless model-stage invocation with a wall-clock timeout, killing
#     its whole process group on timeout. `set -m` gives the backgrounded job
#     its own process group so `kill -TERM -$pid` reaches every descendant. ---
#
# run_model_stage STAGE TIMEOUT_SEC MODEL PROMPT OUT_FILE CWD [INACTIVITY_SEC] [RESUME_SESSION_ID] [LANE] [SEED_SUFFIX]
# Returns the invocation's own exit status, or 124 when either cap fired.
# Sets the caller-visible `stage_pid`/`stage_name` for the duration (see the
# note at each pipeline's signal handler) and clears them on the way out,
# `stage_kill_reason` to say which cap fired, if either, `stage_provider`
# to the provider MODEL resolved to (`stage_model_substrate`'s own input),
# and `stage_lane` to the lane it was launched on (issue #2241, D30; see
# "Presence" below).
#
# LANE, when given, bypasses the draw and forces that lane outright —
# requirement 2.1b's own limit probe (#2242), `doctor`'s per-lane check, and
# requirement 9e's salvage retry (issue #2436; it pins LANE to the run it
# resumes rather than letting the retry draw again) are the callers that
# need this; presence is still required, so a LANE this node holds no
# credential for fails exactly like "no open lane" below.
#
# SEED_SUFFIX, when given, is folded into the lane draw's own seed alongside
# the cycle id and STAGE (issue #2436): a caller that can launch the same
# STAGE more than once within one cycle — the Co-Ordinator's per-repository
# loop, the Approver's per-pull-request loop — passes whatever distinguishes
# this launch from a sibling one (a repository slug, a pull request url) so
# each draws independently rather than sharing the one cycle-and-stage seed.
# Omitted (the default, every call site but those two), the seed is exactly
# `"${cycle_id:-}:$stage"`, byte-for-byte what it has always been.
#
# **Presence.** Lane management (the draw, the forcing, the live-stream
# verification, all below) runs only when SUBSTRATE manages lanes at all —
# today only `claude-code` does — *and* at least one of its provider's two
# lanes has a credential present on this node right now
# (`stage_lane_any_present`). Every other case — a provider whose substrate
# does not manage lanes, or a claude-code run where neither credential is
# present at all — launches exactly as this function always has, with
# `stage_lane` left empty: a node with no credential at all is already a
# `scripts/doctor.sh` failure, so this is dead in a correctly provisioned
# installation, but it is what keeps every caller that launches a stage
# without first arranging a credential (most of this file's own tests)
# launching exactly as before rather than being refused by a gate they never
# asked for.
#
# Once lane management is running, "no open lane" — every lane either absent
# or closed by its own `enabled`/weight (`stage_lane_draw` returning 1) — is
# the one case this function refuses to launch at all, the same way
# requirement 4k's settings refusal does: both `.stream.jsonl`/`.out` are
# left empty, the reason lands on `.out.stderr`, and `stage_kill_reason` is
# set to `no-open-lane` so `stage-end` and `stage_watchdog_warning`'s own
# warning both name it (the cycle's own stand-down logic for a provider with
# no open lane is #2135's business, still unimplemented; this is simply what
# it will have to read).
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
  local inactivity_sec="${7:-0}" resume_session_id="${8:-}" lane_override="${9:-}"
  local seed_suffix="${10:-}"
  local pid waited=0 rc stream_file rate_limit_info substrate
  local seen_bytes=0 now size last_growth gaps=()
  local forced_lane="" lane_verified=0 raw_source no_open_lane
  substrate="$(stage_model_substrate "$model")"
  stream_file="$(stage_stream_file "$out_file")"
  stage_gaps_json="null"
  stage_lane_json="null"
  stage_kill_reason=""
  stage_rate_limit_json=""
  # shellcheck disable=SC2034
  stage_lane=""
  # Reset every call, never cleared by `stage_watchdog_warning` itself: every
  # one of that function's own 8 call sites reads it through a command
  # substitution, whose subshell would take a clear-on-read with it rather
  # than ever letting it reach the caller — the same "a command substitution
  # discards the recording" trap `lib/model-id.sh`'s own header warns about.
  # Resetting here instead means the flag answers exactly one question, "did
  # *this* run just reveal the managed-key login", so it is true for the one
  # run that detects the transition and false for every run before or after.
  # shellcheck disable=SC2034
  stage_lane_managed_key_detected=""
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

  # Issue #2241, D30: draw (or accept a forced override of) a lane, only when
  # SUBSTRATE manages lanes at all — see this function's own "Presence"
  # paragraph above for why every other case leaves `forced_lane` empty and
  # launches unmanaged, exactly as before this issue.
  #
  # LANE_OVERRIDE is checked *before* the "is anything present at all" gate,
  # never behind it: an explicit override is a request to force a specific
  # lane outright, and a caller that named one wants either that lane or a
  # clear refusal — never to have the request silently ignored because
  # neither credential happened to be present. The ordinary (undrawn) path
  # stays behind that gate, so a node with neither credential and nothing
  # forcing it keeps launching unmanaged exactly as it always has.
  no_open_lane=0
  if declare -F "substrate_${substrate//-/_}_lane_present" >/dev/null 2>&1; then
    if [[ -n "$lane_override" ]]; then
      if "substrate_${substrate//-/_}_lane_present" "$lane_override"; then
        forced_lane="$lane_override"
      else
        no_open_lane=1
      fi
    elif stage_lane_any_present "$substrate"; then
      forced_lane="$(stage_lane_draw "$stage_provider" "$substrate" \
          "${cycle_id:-}:$stage${seed_suffix:+:$seed_suffix}")" \
        || no_open_lane=1
    fi
    if (( no_open_lane )); then
      local present_api=0 present_sub=0
      "substrate_${substrate//-/_}_lane_present" api && present_api=1
      "substrate_${substrate//-/_}_lane_present" subscription && present_sub=1
      # shellcheck disable=SC2034  # read by stage_watchdog_warning
      stage_lane_states_json="$(jq -nc --argjson pa "$present_api" --argjson ps "$present_sub" \
        --argjson lanes "${PROVIDER_LANES[$stage_provider]:-$STAGE_LANE_DEFAULT_JSON}" \
        '{api: ({present: ($pa == 1)} + ($lanes.api // {})),
          subscription: ({present: ($ps == 1)} + ($lanes.subscription // {}))}')"
      : >"$stream_file"
      : >"$out_file"
      printf 'run_model_stage: the %s stage was not launched: no lane is open for provider %s (requirement 4d, D30) — present api=%s subscription=%s; check config.json'\''s providers.%s.lanes\n' \
        "$stage" "$stage_provider" "$present_api" "$present_sub" "$stage_provider" >"$out_file.stderr"
      stage_kill_reason="no-open-lane"
      return 1
    fi
  fi
  # shellcheck disable=SC2034
  stage_lane="$forced_lane"

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
  ( cd "$cwd" && "substrate_${substrate//-/_}_exec" "$model" "$resume_session_id" "$forced_lane" <<<"$prompt" ) \
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
      _stage_kill "$pid" "$cwd"
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
        _stage_kill "$pid" "$cwd"
        rc=124
        break
      fi
      # Issue #2241, D30: a lane choice is verified, never assumed. Checked
      # only once, the moment the stream's own `init` event first appears —
      # same "only when the stream grew" gate as the rate-limit check above,
      # since that is the only moment a new event can have arrived, and there
      # is nothing left to verify once it has been read once.
      if [[ -n "$forced_lane" && "$substrate" == "claude-code" && $lane_verified -eq 0 ]] \
         && raw_source="$(substrate_claude_code_init_api_key_source "$stream_file" 2>/dev/null)"; then
        lane_verified=1
        local observed_lane=""
        case "$raw_source" in
          none) observed_lane="subscription" ;;
          ANTHROPIC_API_KEY|apiKeyHelper) observed_lane="api" ;;
          "/login managed key")
            # A Console login bills an API account: this is not the mismatch
            # this check exists to catch, it is the one case D30 itself
            # documents as expected — a forced subscription run whose login
            # turns out not to be a subscription at all. Latched once, for
            # the rest of this process's life (SUBSTRATE_CLAUDE_CODE_SUBSCRIPTION_MANAGED_KEY),
            # so the very next draw that would otherwise have forced it again
            # lands on `api` instead; `stage_lane_managed_key_detected` names
            # only this one run as the one `stage_watchdog_warning` should
            # report it for (its own header explains why that flag, unlike
            # this one, is reset on every call rather than latched).
            if [[ "$forced_lane" == "subscription" ]]; then
              if [[ "$SUBSTRATE_CLAUDE_CODE_SUBSCRIPTION_MANAGED_KEY" != "1" ]]; then
                SUBSTRATE_CLAUDE_CODE_SUBSCRIPTION_MANAGED_KEY=1
                # shellcheck disable=SC2034  # read by stage_watchdog_warning
                stage_lane_managed_key_detected=1
              fi
              observed_lane="subscription"
            else
              observed_lane="api"
            fi
            ;;
          *) observed_lane="" ;;
        esac
        if [[ -n "$observed_lane" && "$observed_lane" != "$forced_lane" ]]; then
          # shellcheck disable=SC2034  # read by stage_watchdog_warning
          stage_lane_mismatch_json="$(jq -nc --arg f "$forced_lane" --arg o "$observed_lane" \
            '{forced: $f, observed: $o}')"
          stage_kill_reason="lane-mismatch"
          kill -TERM "-$pid" 2>/dev/null || true
          sleep 5
          kill -KILL "-$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
          rc=124
          break
        fi
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
      _stage_kill "$pid" "$cwd"
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

  # The lane this run actually used (issue #2239, D30) — observed off the
  # stream's own `init` event, read before `stage_result_line` below
  # truncates it away, so a killed stage's torn tail is read past exactly as
  # that call reads past it. `null` for a run whose stream carries no
  # readable answer (killed before its first byte, or an adapter — or test
  # fixture — that never emits one), the same degradation every other
  # `metering_fields` input gets when it cannot be read.
  local stage_lane
  if stage_lane="$(stage_lane_of "$stream_file" "$substrate")"; then
    stage_lane_json="$(jq -nc --arg l "$stage_lane" '$l')"
  else
    # shellcheck disable=SC2034
    stage_lane_json="null"
  fi

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
