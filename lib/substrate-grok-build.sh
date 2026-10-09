#!/usr/bin/env bash
#
# lib/substrate-grok-build.sh — the `grok-build` substrate adapter (issue
# #2134, docs/reviews/2026-10-06-grok-build-evaluation.md's adapter
# specification), the second sibling of lib/substrate-claude-code.sh behind
# the seam issue #2133 cut. Supplies the same five operations, plus one more
# this substrate alone needs:
#
#   substrate_grok_build_binary               the executable's name on PATH
#   substrate_grok_build_version               its own reported version
#   substrate_grok_build_exec                  build the argv, choose the
#                                               prompt-delivery method, and
#                                               become the process
#   substrate_grok_build_result_line           find the terminal `result`
#                                               event in a finished stream,
#                                               normalised onto Claude Code's
#                                               own envelope vocabulary
#   substrate_grok_build_rejected_rate_limit    recognise a structured
#                                               rate-limit refusal in a live
#                                               stream — Grok emits none, so
#                                               this always returns nothing
#   substrate_grok_build_verdict_rc            fold a run's own `is_error`
#                                               into its exit status, since
#                                               Grok's exit code is not
#                                               always a verdict (below)
#
# This file is sourced by lib/stage-run.sh alongside lib/substrate-claude-code.sh.

# substrate_grok_build_binary
# The executable `run_model_stage` looks for on PATH — resolved through the
# `grok` shim (deploy/docker/grok-shim.sh), the same boundary
# deploy/docker/claude-shim.sh gives Claude Code (requirement 45e).
substrate_grok_build_binary() {
  printf 'grok\n'
}

# substrate_grok_build_version
# This substrate's own reported version. Prints nothing and returns 1 when
# the binary itself is not on PATH.
substrate_grok_build_version() {
  command -v grok >/dev/null 2>&1 || return 1
  grok --version 2>/dev/null | head -1
}

# The child-subreaper wrapper (below). An absolute path, installed root-owned
# outside /app, exactly like the stage-exec/claude-shim boundary pieces it
# sits beside — overridable only for test/substrate-grok-build.test.sh, which
# has no root and points this at a fixture script instead.
: "${SUBSTRATE_GROK_BUILD_SUBREAPER:=/usr/local/libexec/agent-ops/grok-subreaper}"

# substrate_grok_build_exec MODEL RESUME_SESSION_ID
# Becomes the contained Grok Build process — via `exec`, so the backgrounded
# subshell `run_model_stage` launches this inside keeps its own pid and
# process group (requirement 9c), same as lib/substrate-claude-code.sh's own
# copy. Always passes `-m`: the default model differs by credential path
# (docs/reviews/2026-10-06-grok-build-evaluation.md §9), so a caller that
# left it off would get whichever model Grok defaults to on the day, not the
# one `run_model_stage` was asked for.
#
# `--permission-mode bypassPermissions` is Grok's `--dangerously-skip-permissions`
# (§5 of the same record: `--yolo` is an alias 1.0.46's own `--help` does not
# list, so this is the explicit form). `--include-partial-messages` keeps one
# silence to one command rather than one whole message ("Stream timing" in
# the adapter specification) — without it the liveness watchdog could kill a
# stage still working through a message that ran several commands in a row.
#
# The prompt is read off this function's own inherited stdin — the split
# between "that the prompt arrives on stdin" and "which file descriptor
# stdin already is" is lib/substrate-claude-code.sh's own, unchanged here —
# but, unlike Claude Code, never handed to Grok as `/dev/stdin` itself.
# Measured directly against the image: Grok's `--prompt-file` always opens
# the path it is given by name, even when that name is `/dev/stdin`, and
# re-opening a process's own stdin by path is a fresh `open()` the kernel
# checks against the *original* file's permission bits — which this
# launcher's here-string sets restrictively, readable only by the process
# that created it. Every `grok` this image runs crosses exactly that
# boundary (requirement 45e: `grok`, like `claude`, runs as the `stage`
# user, a different one from the Script's own that opened the here-string),
# so this never works, the one respect in which Grok's "read stdin" claim
# (docs/reviews/2026-10-06-grok-build-evaluation.md §2) does not carry over
# unchanged — only tested there as the same user throughout. The adapter
# instead drains its own stdin into a real file this invocation owns,
# group-readable by `stage` (`chgrp`+`chmod`, the same group `claude-config`
# already shares between `agent` and `stage`), and passes that path instead;
# the subreaper wrapper removes it once Grok has exited, since this
# function's own `exec` below never returns to do so itself.
#
# Launched under the child-subreaper wrapper, not directly: Grok starts every
# `run_terminal_command` in its own session, so `run_model_stage`'s own
# process-group kill (`kill -TERM -$pid`) ends Grok but leaves its last
# command running, reparented to PID 1 ("Beyond the ten questions" section,
# "Containing them", in the record). The wrapper calls
# `prctl(PR_SET_CHILD_SUBREAPER)` before forking Grok, so anything Grok
# leaves behind reparents to the wrapper instead and is swept — see
# deploy/docker/grok-subreaper.py's own header for the mechanism. `exec`
# still applies to the *wrapper*, so it, not a shell, is what keeps this
# backgrounded job's pid and process group; the wrapper's own fork for Grok
# is one level the group-kill does not need to see, because the wrapper
# itself forwards the signal and waits for the sweep.
substrate_grok_build_exec() {
  local model="$1" resume_session_id="$2" prompt_file
  prompt_file="$(mktemp "${TMPDIR:-/tmp}/grok-prompt.XXXXXX")"
  cat >"$prompt_file"
  chgrp stage "$prompt_file" 2>/dev/null || true
  chmod 640 "$prompt_file"
  local -a args=(-m "$model" --permission-mode bypassPermissions \
    --output-format streaming-messages-json --include-partial-messages \
    --prompt-file "$prompt_file")
  [[ -n "$resume_session_id" ]] && args+=(-r "$resume_session_id")
  exec "$SUBSTRATE_GROK_BUILD_SUBREAPER" --cleanup "$prompt_file" -- grok "${args[@]}"
}

# Over a Grok failure envelope — `is_error: true`, no `result`, its text in
# an `errors` array instead (docs/reviews/2026-10-06-grok-build-evaluation.md
# §8) — rewrites it onto the fields lib/stage-attempt.sh's `stage_api_refusal`/
# `stage_api_refusal_class` read, so a Grok refusal classifies exactly as a
# Claude Code one does, with zero changes to either classifier. Left as given
# whenever the envelope does not match that shape (a success, or anything
# this image's own readers have never seen Grok produce), so this is safe to
# run over every terminal line unconditionally.
#
#   result            the `errors` entries, joined — the API's own words,
#                      same as `terminal_reason`/`result` already carry for
#                      Claude Code.
#   api_error_status   the status Grok prints in parentheses (`(401)`) or as
#                      `"http_status": NNN`, or 429 for the two 429 texts
#                      that carry no status of their own.
#   terminal_reason    `"api_error"` for an authentication failure (so that
#                      `stage_api_refusal`'s existing `$auth` test names it
#                      `authentication_failed`), `"credit_exhausted"` for
#                      xAI's credit/spending-limit text, otherwise unset —
#                      `stage_api_refusal` falls back to `api_error_<status>`
#                      only when the reason is empty or `completed`, so
#                      setting `"api_error"` for every failure would hide the
#                      status underneath it.
#
# Run verbatim from the record's own jq program (its own §"Normalising
# failures"), checked there against all eleven captured failure envelopes.
# shellcheck disable=SC2016  # jq's own $t/$s, not the shell's.
SUBSTRATE_GROK_BUILD_NORMALIZE_JQ='
  def grok_status($t):
    first(
      ($t | match("\\(([1-5][0-9]{2})\\)|\"http_status\": *([1-5][0-9]{2})")
          | .captures[] | select(.string != null) | .string | tonumber),
      (if ($t | test("too many requests|some resource has been exhausted"; "i")) then 429 else empty end),
      null);
  if (.is_error == true) and (.result == null) and ((.errors // []) | length > 0) then
    (.errors | map(tostring) | join("\n")) as $t
    | grok_status($t) as $s
    | .result = $t
    | if ($t | test("not signed in|unauthori[sz]ed|\\(401\\)"; "i")) then
        .terminal_reason = "api_error" | (if $s == null then . else .api_error_status = $s end)
      elif ($t | test("used all available credits|spending limit"; "i")) then
        .terminal_reason = "credit_exhausted" | .api_error_status = $s
      elif $s != null then .api_error_status = $s
      else . end
  else . end
'

# substrate_grok_build_result_line STREAM_FILE
# Print the run's final `result` event, normalised (above), or nothing
# (returning 1) when the stream carries none — otherwise identical to
# lib/substrate-claude-code.sh's own copy: the shape itself (a killed run's
# torn tail; `tail -n 1` over the first match) is unchanged, since Grok's
# `streaming-messages-json` writes the same one-terminal-line-at-the-end
# shape (docs/reviews/2026-10-06-grok-build-evaluation.md §3).
substrate_grok_build_result_line() {
  local stream_file="$1" line
  [[ -s "$stream_file" ]] || return 1
  line="$(jq -c 'select(type == "object" and .type == "result")' "$stream_file" 2>/dev/null | tail -n 1)" || true
  [[ -n "$line" ]] || return 1
  jq -c "$SUBSTRATE_GROK_BUILD_NORMALIZE_JQ" <<<"$line" 2>/dev/null || printf '%s\n' "$line"
}

# substrate_grok_build_rejected_rate_limit STREAM_FILE
# Always returns 1: Grok emits no structured rate-limit event equivalent to
# Claude Code's `rate_limit_event` (the record's §8 confirms the documented
# absence). A Grok rate limit still reaches the record — through
# `stage_api_refusal`'s normalised `api_error_429`/`credit_exhausted`, not
# this early-stop path — but only once the run has ended; see
# lib/candidate-select.sh's `detect_and_log_limit_hit` for why the phrase
# matcher is also kept off a Grok stage's output before issue #2135.
substrate_grok_build_rejected_rate_limit() {
  return 1
}

# substrate_grok_build_verdict_rc RC OUT_FILE
# Grok's own exit status is not a verdict (the record's "Beyond the ten
# questions: Exit status"): a run whose tool call is cancelled exits 0 with
# `is_error: true`, and a run that wrote nothing at all also exits 0. Twelve
# of lib/stage-run.sh's thirteen callers branch on what `run_model_stage`
# returns, so an uncorrected 0 would take every one of their success
# branches and parse a refusal as a verdict. Returns 1 in either case, and
# RC unchanged otherwise — including when RC is already non-zero, which
# needs no correction at all.
substrate_grok_build_verdict_rc() {
  local rc="$1" out_file="$2"
  if (( rc == 0 )); then
    if [[ ! -s "$out_file" ]] \
       || jq -e '(.is_error // false) == true' "$out_file" >/dev/null 2>&1; then
      printf '1\n'
      return 0
    fi
  fi
  printf '%s\n' "$rc"
}
