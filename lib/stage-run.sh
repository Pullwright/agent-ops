#!/usr/bin/env bash
#
# lib/stage-run.sh — the one implementation of "run a headless `claude` stage"
# (requirement 4d of docs/spec/implementation/README.md).
#
# Sourced by agent-cycle.sh and review-cycle.sh so both pipelines launch, cap
# and kill a stage the same way, rather than each keeping its own copy of the
# mechanism — the same reason lib/metering.sh exists. The two copies this
# replaces were byte-identical apart from their comments, and both specs
# already said in as many words that they must not diverge; a shared file is
# the only form of that promise a reviewer does not have to check by eye.
#
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
# shellcheck source=lib/stage-boundary.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stage-boundary.sh"
STAGE_PROJECT_SETTINGS_MAX_BYTES=1048576
# shellcheck disable=SC2016  # "$schema" is a JSON key, not a variable
STAGE_PROJECT_SETTINGS_INERT_KEYS='["$schema","permissions","includeCoAuthoredBy","includeGitInstructions","cleanupPeriodDays","respectGitignore"]'
STAGE_PROJECT_SETTINGS_INERT_PERMISSIONS='["allow"]'
STAGE_CLAUDE_MANAGED_SETTINGS="${STAGE_CLAUDE_MANAGED_SETTINGS:-/etc/claude-code/managed-settings.json}"

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

# stage_project_settings_refusal DIR
# Prints why a stage must not be launched in DIR and returns 0 when either of
# its Claude Code project settings files carries a key outside the allowlist
# or cannot be read as a JSON object; returns 1, printing nothing, when there
# is no such file or every key in it is allowed. The reason names the file and
# what is wrong with it, then says where the file came from.
stage_project_settings_refusal() {
  local dir="$1" allowed name file content disallowed
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
  return 1
}

# stage_stream_file OUT_FILE
# The progress stream that accompanies a stage's `.out`. Derived rather than
# passed so that every caller — and every reader, in this repository and in
# the state mirror's exclude list — names the same file by the same rule.
stage_stream_file() {
  printf '%s.stream.jsonl' "${1%.out}"
}

# stage_result_line STREAM_FILE
# Print the run's final `result` event, or nothing (returning 1) when the
# stream carries none. Reading is deliberately tolerant in both directions a
# stream can be damaged:
#
#   - a killed run's stream ends mid-line, and jq reports a parse error at
#     EOF *after* emitting everything it had already parsed. Its status and
#     its stderr are therefore both discarded: the question here is "was a
#     complete result event written", and a torn tail is the normal shape of
#     a stage that was killed, not an error to propagate.
#   - a line that is valid JSON but not an object would make `.type` a hard
#     jq error, taking the whole program — and with it a perfectly readable
#     result line — down with it. jq's `and` short-circuits, so the type
#     guard ahead of the field test is what keeps such a line merely skipped.
#
# `tail -n 1` rather than `head`: the result event is the last thing a run
# emits, and taking the last match keeps this correct if a future CLI version
# ever emits more than one.
stage_result_line() {
  local stream_file="$1" line
  [[ -s "$stream_file" ]] || return 1
  line="$(jq -c 'select(type == "object" and .type == "result")' "$stream_file" 2>/dev/null | tail -n 1)" || true
  [[ -n "$line" ]] || return 1
  printf '%s\n' "$line"
}

# stage_gap_stats SECONDS...
# Summarise a run's inter-event gaps as the object requirement 33a documents:
# `{n, p50, p95, p99, max}`, seconds. Prints `null` given no readable
# observation at all — which no real run produces, since `run_claude_stage`
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

# stage_rejected_rate_limit STREAM_FILE
# Print the `rate_limit_info` of a `rate_limit_event` in the stream that says
# the account was refused, or nothing (returning 1) when there is none.
#
# `rejected` and nothing else. The runner's own vocabulary for this field is
# `allowed`, `allowed_warning` and `rejected`, and only the last is a refusal:
# `allowed_warning` is "you are close", which a stage should be allowed to run
# through. Anything unrecognised is likewise left alone, so a value added
# upstream later cannot start killing stages before anyone has looked at it —
# it simply falls through to the phrase matcher that has always handled this,
# after the stage ends. That asymmetry is deliberate: failing to abort early
# costs the rest of a wall-clock cap, while aborting a healthy stage throws
# away everything it had done.
#
# The `grep` is a pre-filter, not the decision. It runs every poll over the
# whole stream, which is cheap even at megabytes, and only when it hits does
# jq confirm the string came from a top-level `rate_limit_event` rather than
# from inside a tool result — an Implementer working on limit detection would
# otherwise abort itself for reading its own test fixtures.
stage_rejected_rate_limit() {
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

# --- Run a headless claude invocation with a wall-clock timeout, killing its
#     whole process group on timeout. `set -m` gives the backgrounded job its
#     own process group so `kill -TERM -$pid` reaches every descendant. ---
#
# run_claude_stage STAGE TIMEOUT_SEC MODEL PROMPT OUT_FILE CWD [INACTIVITY_SEC] [RESUME_SESSION_ID]
# Returns the invocation's own exit status, or 124 when either cap fired.
# Sets the caller-visible `stage_pid`/`stage_name` for the duration (see the
# note at each pipeline's signal handler) and clears them on the way out, and
# `stage_kill_reason` to say which cap fired, if either.
#
# RESUME_SESSION_ID, when given, is passed to `claude` as `--resume`: PROMPT
# then continues that session instead of starting a fresh one. This is the one
# mechanism a salvage attempt needs (issue #237) — the model that already did
# the work is asked to restate its verdict, not to redo the work from nothing.
# Every other cap, kill and metering path is identical to a fresh run; a
# caller distinguishes a salvage's own record by the `stage` name it passes.
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
run_claude_stage() {
  local stage="$1" timeout_sec="$2" model="$3" prompt="$4" out_file="$5" cwd="$6"
  local inactivity_sec="${7:-0}" resume_session_id="${8:-}"
  local pid waited=0 rc stream_file rate_limit_info
  local -a claude_args=(-p --model "$model" --dangerously-skip-permissions \
    --output-format stream-json --verbose)
  [[ -n "$resume_session_id" ]] && claude_args+=(--resume "$resume_session_id")
  local seen_bytes=0 now size last_growth gaps=()
  stream_file="$(stage_stream_file "$out_file")"
  stage_gaps_json="null"
  stage_kill_reason=""
  stage_rate_limit_json=""

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
  if settings_refusal="$(stage_project_settings_refusal "$cwd")"; then
    : >"$stream_file"
    : >"$out_file"
    printf 'run_claude_stage: the %s stage was not launched: %s (requirement 4k)\n' \
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
  # it as `claude -p "$prompt"` puts the pipeline one paragraph away from an
  # exec that fails with E2BIG before the model is ever reached. A here-string
  # (rather than a pipe) keeps the invocation a single process whose status is
  # the stage's own: under `pipefail` a `printf | claude` would report
  # printf's SIGPIPE, 141, whenever a stage exited without draining stdin.
  #
  # This pipeline's own prompts have room to spare in the review cycle and
  # none to spare in the implementation cycle; they share this function
  # precisely so the one with room cannot quietly stop being covered.
  set -m
  ( cd "$cwd" && claude "${claude_args[@]}" <<<"$prompt" ) \
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
      if rate_limit_info="$(stage_rejected_rate_limit "$stream_file")"; then
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
  stage_result_line "$stream_file" >"$out_file" 2>/dev/null || : >"$out_file"

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
