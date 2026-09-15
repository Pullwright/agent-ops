#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/stage-attempt.sh — one Co-Ordinator stage attempt end to end: launch,
# parse the final message (with the prose/fence/bare-object salvage models
# occasionally need), and the shared failure handling — a refused API
# request, a wedged or timed-out run, an unparseable message — that every
# stage this pipeline runs eventually hits.
#
# Split out of agent-cycle.sh (#771) as the "stage orchestration and prompt
# assembly" seam docs/IMPLEMENTATION-PIPELINE-SPEC.md's requirements name:
# `run_coordinator_stage_attempt` is the one launch/parse/salvage sequence the
# Co-Ordinator's first attempt and its corroboration retry both run through,
# `fallback_select_candidate` and `coordinator_corroborate_retry_or_fallback`
# are the requirement-3v ladder built on top of it once a `none-selected`
# verdict fails corroboration, and `extract_json_result`/`stage_salvage_result`/
# `dump_stage_output`/`stage_api_refusal`/`stage_api_refusal_message`/
# `handle_stage_failure` are what every stage — Co-Ordinator, Approver,
# Enabler, Refiner, Implementer, Reviewer — shares to turn a stage's raw
# output into a parsed verdict or a recorded, claim-releasing failure.
#
# Sourced by agent-cycle.sh only; reads and writes the cycle's own globals
# (`cycle_dir`, `ONCE`, `ordered_repos_json`, `selected_repo`/`selected_item`,
# `claim_active`, …) exactly as it did inline, and calls lib/stage-run.sh's
# `run_claude_stage` and lib/stage-budget.sh's `stage_budget_apply`.

# Stage prompts require the final message to be pure JSON, but a model will
# sometimes prepend analysis prose anyway and put the real object in a
# trailing fenced ```json block — or leave it bare after the prose. Try a
# straight parse first; then the last fenced block; then the earliest line
# opening a brace whose text from there to the end of the message parses as
# exactly one JSON value.
#
# The third salvage earns its place by what its absence cost. On 2026-08-03
# an Enabler engagement examined three refinement items, reached a correct
# `escalate` verdict on each and drafted every escalation issue — then ended
# with a summary paragraph, a blank line, and the verdict object, bare. The
# fence fallback could not touch it (the prompts *forbid* the fence, so the
# one deviation this function could rescue was the one the prompts rule
# out), the engagement was discarded whole under requirement 37, and the
# items sat behind its never-released claims for the rest of claim_ttl_hours
# — six further hours — waiting for a retry that could only re-derive what
# the discarded message already said. Prose-then-bare-object is the shape
# models actually produce when they slip; it must not be the one fatal case.
#
# It is deliberately a *suffix* parse: only an object that runs to the end
# of the message is taken, and an object with trailing prose still fails,
# because "which of these is the verdict" is not a question this function
# should answer. `jq -es 'length == 1'` is the single-value check — `jq
# empty` accepts a stream of several values, and a salvage should never be
# looser than the straight parse it backs up.
#
# The fenced-block fallback matches a closing ``` regardless of what info
# string the *opening* fence carried, or whether it carried one at all
# (issue #237): the state machine toggles solely on "is this a fence line",
# not on the literal text `json` following it. A verdict a model fences
# bare — ``` … ``` with no language tag — is not an ambiguous case; only a
# straight parse or a suffix match, not the fence's tag, was ever what told
# a verdict apart from prose. Before this, poetic-2's completed conflict
# resolution of PR #205 (2026-08-07T04:40Z) was discarded for exactly this
# reason — a bare fence the parser could not see — erasing pipeline memory
# that the conflict was fixed and triggering a three-node duplicate-work
# cascade on the same PR.
#
# scripts/publish-dashboard.sh's `extract_status` is a jq port of this
# algorithm and review-cycle.sh carries a bash copy; the three move together
# (docs/DASHBOARD-SPEC.md), and test/extract-json-result.test.sh holds them
# to it.
#
# An empty-or-whitespace-only $text is checked explicitly and fails outright
# (TD26072802, for symmetry with publish-dashboard.sh's extract_status,
# which shares this algorithm per DASHBOARD-SPEC.md): `jq empty` on
# whitespace input succeeds trivially with no output, so without this check
# the function would return 0 — success — while printing nothing. Every call
# site already treats empty output as failure regardless of the exit code, so
# this changes no observable behaviour; it just stops the exit code lying
# about what happened.
extract_json_result() {
  local text="$1" block line_no suffix
  [[ "$text" =~ ^[[:space:]]*$ ]] && return 1
  if jq empty <<<"$text" >/dev/null 2>&1; then
    jq -c '.' <<<"$text"
    return 0
  fi
  block="$(awk '
    /^```[A-Za-z0-9_-]*[[:space:]]*$/ {
      if (in_block) { last=capture; in_block=0 } else { capture=""; in_block=1 }
      next
    }
    in_block { capture = capture $0 "\n" }
    END { printf "%s", last }
  ' <<<"$text")"
  if [[ -n "$block" ]] && jq empty <<<"$block" >/dev/null 2>&1; then
    jq -c '.' <<<"$block"
    return 0
  fi
  while IFS=: read -r line_no _; do
    suffix="$(tail -n "+$line_no" <<<"$text")"
    if jq -es 'length == 1' <<<"$suffix" >/dev/null 2>&1; then
      jq -c '.' <<<"$suffix"
      return 0
    fi
  done < <(grep -n '^[[:space:]]*{' <<<"$text" || true)
  return 1
}

# A salvage resume is a single short turn — "state the verdict you already
# reached, nothing else" — so it earns none of the adaptive budgeting a real
# stage's own caps get from lib/stage-budget.sh (requirement 4e): a fixed,
# conservative bound is safer than one that could grow to a whole stage's own
# backstop over time. Five minutes is generous for a turn with no tool calls;
# the ninety-second watchdog catches a resume that never starts producing at
# all.
stage_salvage_backstop_sec=300
stage_salvage_inactivity_sec=90

# stage_salvage_result STAGE OUT_FILE MODEL CWD
# The bounded rescue of requirement 37's discard rule (issue #237): before an
# engagement whose final message failed extract_json_result is discarded
# whole, resume the exact session that produced it — not a fresh one, which
# would pay to re-derive work already done — with nothing but "return the
# verdict object". Prints the recovered JSON on stdout and returns 0 when
# that resume's own final message parses; returns 1 and prints nothing
# otherwise, including when the original run left no `session_id` to resume
# (a killed run's stream can end before the CLI's init event ever landed).
#
# Deliberately silent about *why* the first attempt failed — a timeout, a
# crash, an unparseable message are all the same fact from here: the session
# is worth one more ask before its work is written off. The caller decides
# what "worth trying" means for its own stage (an Enabler with a `rc != 0`
# has no living session to resume in the first place, since the process that
# would hold one is the one that never exited).
stage_salvage_result() {
  local stage="$1" out_file="$2" model="$3" cwd="$4"
  local session_id salvage_out salvage_rc salvage_result parsed
  # run_claude_stage sets its caller-visible globals for whichever run is
  # most recent; the original run's metering is already logged by the time
  # this is called, but detect_and_log_limit_hit is not — it reads
  # $stage_rate_limit_json at the call sites' own discretion, later, against
  # $out_file. Left alone, a salvage attempt would overwrite it with the
  # resume's own (almost always empty) limit info before that read happens.
  # Saving and restoring here keeps this function's globals side effect
  # entirely local, which is what every caller of it is entitled to assume.
  local saved_gaps="$stage_gaps_json" saved_kill="$stage_kill_reason" \
        saved_limit="$stage_rate_limit_json"
  session_id="$(jq -r '.session_id // empty' "$out_file" 2>/dev/null || true)"
  if [[ -z "$session_id" ]]; then
    stage_gaps_json="$saved_gaps"; stage_kill_reason="$saved_kill"; stage_rate_limit_json="$saved_limit"
    return 1
  fi
  salvage_out="${out_file%.out}.salvage.out"
  log_event "salvage" "$(jq -nc --arg s "$stage" '{stage: $s, outcome: "attempted"}')"
  if run_claude_stage "$stage-salvage" "$stage_salvage_backstop_sec" "$model" \
       "Return only the verdict JSON object, nothing else." \
       "$salvage_out" "$cwd" "$stage_salvage_inactivity_sec" "$session_id"; then
    salvage_rc=0
  else
    salvage_rc=$?
  fi
  stage_gaps_json="$saved_gaps"; stage_kill_reason="$saved_kill"; stage_rate_limit_json="$saved_limit"
  if (( salvage_rc != 0 )); then
    log_event "salvage" "$(jq -nc --arg s "$stage" --argjson rc "$salvage_rc" \
      '{stage: $s, outcome: "failed", exit_code: $rc}')"
    return 1
  fi
  salvage_result="$(jq -r '.result // empty' "$salvage_out" 2>/dev/null || true)"
  parsed="$(extract_json_result "$salvage_result" 2>/dev/null || true)"
  if [[ -z "$parsed" ]]; then
    log_event "salvage" "$(jq -nc --arg s "$stage" '{stage: $s, outcome: "failed"}')"
    return 1
  fi
  log_event "salvage" "$(jq -nc --arg s "$stage" '{stage: $s, outcome: "recovered"}')"
  printf '%s' "$parsed"
  return 0
}

dump_stage_output() {
  local out_file="$1"
  cat "$out_file"
  [[ -s "$out_file.stderr" ]] && cat "$out_file.stderr" >&2
  # An empty stderr file must not become this function's return value: the
  # call sites are `(( ONCE )) && dump_stage_output …`, and the command after
  # a final `&&` is exactly where `set -e` applies — a stage whose stderr was
  # empty killed a --once cycle here, after the stage ended and before its
  # failure handling (limit detection, attempt-failed, claim release) ran.
  return 0
}

# Requirement 4i (agent-ops#641): the terminal reason a headless `claude` run
# records for itself when the API refused the request outright, and the message
# it came with. Empty for every ordinary failure, so the caller's own ladder is
# untouched by stages that failed some other way.
#
# The two halves are deliberately separate. `stage_api_refusal` is the *stable*
# token (`prompt_too_long`, `invalid_request_error`, …) and is what goes in the
# `detail` a crash-loop verdict groups on — requirement 2.7 counts consecutive
# failures carrying the *same* detail, and on 2026-08-21 the accompanying
# message named a token count that moved every cycle, so a detail built from it
# would have been four distinct failures and the ladder would never have fired
# on the very outage it was needed for. The message travels beside it, on the
# event, where a reader gets the numbers and nothing groups on them.
# The test is `api_error_status` being a number, not merely `is_error` being
# true: `is_error` covers every way a stage can end badly, including ones that
# ran and then failed, and calling those "refused by the API before it could
# run" would put a confident falsehood where an honest exit code used to be.
# An HTTP status on the record is the API itself saying it declined the
# request. `terminal_reason` names which refusal when the runner recorded one
# (`prompt_too_long`); the status stands in when it did not.
#
# One refusal carries no status at all, and is recognised by its shape
# instead (2026-09-15, ockham-2): a node whose subscription OAuth credential
# has lapsed — re-enabled after days on Standby, its refresh token expired
# with nothing having used it — records `terminal_reason: "api_error"`,
# `api_error_status: null` and `result: "Failed to authenticate: OAuth
# session expired and could not be refreshed"`, because the runner refused
# the request itself, having no credential to make it with, before any API
# call could return a status. Six consecutive cycles on that node read
# `coordinator exited 1`, `enabler exited 1`, `refiner exited 1` — the same
# useless account of an outage that #641 fixed for the status-bearing kind —
# and the stage-health record could not tell it from any other failure. It
# is named `authentication_failed`: a stable token, no moving part, and the
# text the runner emits is fixed. The gate is deliberately narrow — the
# runner's own `api_error` reason *and* an authentication message — so a
# stage that ran and then failed, or an `api_error` of some other statusless
# kind, still gets its honest exit code rather than a confident falsehood.
stage_api_refusal() {  # <out-file> -> terminal reason, or empty
  local out_file="$1"
  [[ -s "$out_file" ]] || return 0
  jq -r 'select((.is_error // false) == true)
         | (((.terminal_reason // "") == "api_error")
            and ((.result // "") | test("authenticat|oauth|unauthori[sz]ed"; "i"))) as $auth
         | select($auth or ((.api_error_status // null) | type == "number"))
         | if $auth then "authentication_failed"
           else ((.terminal_reason // "") as $r
                 | if $r == "" or $r == "completed" then "api_error_\(.api_error_status)" else $r end)
           end' \
    "$out_file" 2>/dev/null | head -1
}

stage_api_refusal_message() {  # <out-file> -> the API's own words, truncated
  local out_file="$1"
  [[ -s "$out_file" ]] || return 0
  jq -r 'select((.is_error // false) == true)
         | (((.terminal_reason // "") == "api_error")
            and ((.result // "") | test("authenticat|oauth|unauthori[sz]ed"; "i"))) as $auth
         | select($auth or ((.api_error_status // null) | type == "number"))
         | (.result // "") | .[0:600]' \
    "$out_file" 2>/dev/null | head -1
}

# Issue #1073 (agent-ops#1073): a refusal's stable token cannot carry the one
# fact that decides how to react to it, because requirement 4i's own grouping
# discipline forbids folding a moving number into `detail` — so it is read
# separately, from the same `api_error_status` `stage_api_refusal` already
# reads but never returns. On 2026-08-29/30 the Ockham host lost outbound
# network for four hours; every refusal recorded `terminal_reason: "api_error"`
# with `api_error_status: 503` — "This is a server-side issue, usually
# temporary — try again in a moment" — and the crash-loop ladder escalated it
# as "almost certainly deterministic … no amount of retrying will clear it",
# which was false on its own evidence and cleared itself the moment the
# network came back.
#
# `refused` — the API looked at the request and declined it: a named
# deterministic reason (`prompt_too_long`, `invalid_request_error`, the class
# requirement 2.7's escalation was built for), or any other 4xx. This will not
# clear by retrying; something in the image or the assembled prompt is wrong.
# `transient` — the request never reached a considered answer: a 5xx, or a
# `terminal_reason` naming a connection-level fault (a proxy error page, a
# dropped connection, an overload) whatever status rides with it. This is
# external and clears on its own; no code in this repository can fix it.
# Empty — `stage_api_refusal` itself found nothing to classify (no refusal on
# this record), or a genuinely unrecognised 1xx/2xx/3xx status; the ladder
# below defaults an unrecognised case to `refused` rather than guessing
# `transient`, since escalating a puzzle for a human to read is the safe
# failure and silently swallowing a real deterministic loop is not.
# `authentication_failed` (stage_api_refusal above) is `refused`: no retry
# clears a lapsed login, only a person completing one.
stage_api_refusal_class() {  # <out-file> -> "transient", "refused", or empty
  local out_file="$1"
  [[ -s "$out_file" ]] || return 0
  jq -r 'select((.is_error // false) == true)
         | (((.terminal_reason // "") == "api_error")
            and ((.result // "") | test("authenticat|oauth|unauthori[sz]ed"; "i"))) as $auth
         | select($auth or ((.api_error_status // null) | type == "number"))
         | (.terminal_reason // "") as $r
         | (.api_error_status // 0) as $status
         | if $auth then "refused"
           elif ($r == "prompt_too_long" or $r == "invalid_request_error") then "refused"
           elif ($r | test("connection|network|overload"; "i")) then "transient"
           elif ($status >= 500) then "transient"
           else "refused"
           end' \
    "$out_file" 2>/dev/null | head -1
}

handle_stage_failure() {
  local stage="$1" rc="$2" out_file="$3" pr_url="${4:-}" detail refusal refusal_msg refusal_class
  # 124 is now both caps, and they are not the same news to whoever reads this
  # next — the Enabler, or a human asking why an item is blocked. "Ran to its
  # wall-clock cap while still working" argues for a longer cap; "produced
  # nothing at all for ten minutes" argues for looking at what it was waiting
  # on. So the reason is stated rather than left to be inferred from an exit
  # code that cannot carry it.
  refusal="$(stage_api_refusal "$out_file")"
  if [[ -n "$refusal" ]]; then
    # An API refusal is not a crash, and "coordinator exited 1" is a true but
    # useless account of one: on 2026-08-21 that was every record the fleet
    # kept of four cycles it lost to a prompt past the context window, and the
    # escalation it raised sent its reader to `coordinator.out.stderr`, which
    # an API refusal leaves empty because the refusal is in `coordinator.out`.
    detail="$stage was refused by the API before it could run: $refusal"
  elif [[ "$rc" == "124" && "$stage_kill_reason" == "inactivity" ]]; then
    detail="$stage produced no output at all for its inactivity threshold and was stopped as wedged"
  elif [[ "$rc" == "124" && "$stage_kill_reason" == "rate-limit" ]]; then
    detail="$stage was stopped the moment the account reported a usage limit — nothing it did after that could have succeeded"
  elif [[ "$rc" == "124" ]]; then
    detail="$stage timed out"
  else
    detail="$stage exited $rc"
  fi
  detect_and_log_limit_hit "$out_file" || true
  # The PR travels on the event (requirement 32a) so the Enabler can open it
  # without re-deriving it from the item id — for a finishing source the item
  # may not name the PR at all. So does the API's own refusal message, which
  # carries the numbers `detail` deliberately leaves out. So does the refusal's
  # class (issue #1073) — `transient` or `refused` — which is what lets
  # `crash_loop_verdict` tell an outage from a deterministic fault without
  # folding either into `detail`, the field requirement 2.7 groups on.
  refusal_msg=""
  refusal_class=""
  if [[ -n "$refusal" ]]; then
    refusal_msg="$(stage_api_refusal_message "$out_file")"
    refusal_class="$(stage_api_refusal_class "$out_file")"
  fi
  log_attempt_failed "$stage" "$detail" \
    "$(jq -nc --arg u "$pr_url" --arg r "$refusal" --arg m "$refusal_msg" --arg c "$refusal_class" \
       '{stage_failure: true}
        + (if $u == "" then {} else {pr_url: $u} end)
        + (if $r == "" then {} else {api_refusal: $r} end)
        + (if $m == "" then {} else {api_message: $m} end)
        + (if $c == "" then {} else {api_refusal_class: $c} end)')"
  if [[ -n "$pr_url" ]]; then
    gh pr comment "$pr_url" --body "$(pipeline_comment_header script "$node_name")

The $(pipeline_actor_label "$stage") stopped on this PR: $detail. Recorded blocked; the pipeline's Enabler will re-examine it, and will raise an issue if a human is needed.

$(pipeline_comment_marker "$cycle_id" script)" >/dev/null 2>&1 || true
    release_claim have-pr
  else
    release_claim no-pr
  fi
}

# Issue #587: one Co-Ordinator engagement, launched, parsed, and its own
# failure paths handled — factored out of the "4. Co-Ordinator stage" flow
# below so the per-repository loop can call it once per configured
# repository without duplicating the launch/parse/salvage machinery. Sets
# `coord_attempt_result_json` to the parsed work order on success (empty on
# any failure — a launch failure, an unparseable final message even after
# salvage) and `coord_attempt_metering_json` to this attempt's own cost/time
# fields (lib/metering.sh) every time, success or failure, so a caller can
# report what the attempt cost regardless of its outcome. Returns 1 on any
# failure, after this attempt's own `attempt-failed`/`stage-end` logging and
# (for a launch failure) `handle_stage_failure`'s claim release.
#
# `extra` (default `{}`) is spliced into both `stage_budget_apply`'s own
# `stage-start` event and this attempt's `stage-end`/`attempt-failed` events.
# The per-repository loop below passes `{"repo": "<slug>"}` on every call —
# the one place left that says which repository a given engagement's cost
# and outcome belong to, now that there is no longer exactly one Co-Ordinator
# engagement per cycle to assume it of.
run_coordinator_stage_attempt() {  # <attempt-out-file> <prompt> [extra-budget-json]
  local out_file="$1" prompt="$2" extra="${3:-{\}}" rc=0 watchdog_warning result
  jq -e 'type == "object"' <<<"$extra" >/dev/null 2>&1 || extra='{}'

  # The budget key stays the fleet-wide "*", not the repo `extra` carries:
  # `lib/stage-budget.sh`'s per-actor/per-repo/per-model self-tuning has no
  # history for a repo-scoped Co-Ordinator cell yet, and starting one cold on
  # the day this ships would derive a backstop from zero history rather than
  # the fleet-wide history already accumulated under "*". Keying it per repo
  # is a genuine future improvement (each repo's own backlog could earn its
  # own tuned backstop) but is not something this change preserves, so it is
  # left for a follow-up rather than bundled in here.
  stage_budget_apply coordinator "*" "$coordinator_model" "$extra"
  if run_claude_stage coordinator "$(( stage_backstop_min * 60 ))" "$coordinator_model" "$prompt" "$out_file" "$cycle_dir" "$(( stage_inactivity_min * 60 ))"; then
    rc=0
  else
    rc=$?
  fi
  coord_attempt_metering_json="$(metering_fields "$coordinator_model" "$out_file" "$stage_gaps_json")"
  log_event "stage-end" "$(jq -nc --argjson rc "$rc" --arg kr "$stage_kill_reason" \
    --argjson m "$coord_attempt_metering_json" --argjson e "$extra" \
    '{stage: "coordinator", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m + $e')"
  # Still no repo/item passed to rework_stage_rerun_maybe: that function's
  # third/fourth positional arguments feed the crash-loop machinery's own
  # per-repo grouping, which issue #587 leaves fleet-wide (unchanged, see
  # docs/IMPLEMENTATION-PIPELINE-SPEC.md's updated requirement 15) rather than
  # splitting further in the same change that split selection itself.
  rework_stage_rerun_maybe "coordinator" "$stage_kill_reason"
  log_node_state_transition overhead
  # `if`, not `&&` — see the identical comment at the original call site below.
  watchdog_warning="$(stage_watchdog_warning coordinator || true)"
  if [[ -n "$watchdog_warning" ]]; then
    log_event "warning" "$watchdog_warning"
  fi
  (( ONCE )) && dump_stage_output "$out_file"

  if (( rc != 0 )); then
    handle_stage_failure "coordinator" "$rc" "$out_file" ""
    coord_attempt_result_json=""
    return 1
  fi

  result="$(jq -r '.result // empty' "$out_file" 2>/dev/null || true)"
  coord_attempt_result_json="$(extract_json_result "$result" 2>/dev/null || true)"
  if [[ -z "$coord_attempt_result_json" ]]; then
    coord_attempt_result_json="$(stage_salvage_result coordinator "$out_file" "$coordinator_model" "$cycle_dir" || true)"
  fi
  if [[ -z "$coord_attempt_result_json" ]]; then
    detect_and_log_limit_hit "$out_file" || true
    log_event "attempt-failed" "$(jq -nc --argjson e "$extra" \
      '{stage: "coordinator", detail: "unparseable final message", stage_failure: true} + $e')"
    return 1
  fi
  return 0
}

# Requirement 3v (issue #321): the mechanical last resort once a `none-selected`
# verdict has failed corroboration twice in the same cycle (the original
# engagement and its one retry — see "5. Nothing selected" below). At that
# point liveness must stop depending on the model getting it right at all, so
# the Script itself picks: the highest-priority non-empty source band, its
# first item in repo order, with no per-item judgement applied.
#
# The band order approximates `prompts/coordinator.md`'s own "Selection
# algorithm" — the five cross-repo overrides (security, urgent issues,
# review-feedback, merge-conflicts, abandoned-drafts) ahead of the residual
# bands (human-visibility, high issues, tech-debt, medium issues, low issues,
# code-quality) — restricted to the bands the Script has a
# pre-fetched array for. Approximates, not mirrors, in two respects a
# mechanical pick can afford: the walk is band-major across the whole fleet
# rather than the Co-Ordinator's repo-then-source walk. `failed-runs`,
# `implementation-plan` and
# `project-review` have no pre-fetched array — enumerating their candidates means a live `gh`
# read or a tree fetch the Co-Ordinator does for itself, which this mechanical
# fallback does not perform — so those three ranks are skipped rather than
# approximated. This is a known, deliberate narrowing: this path exists to
# keep the fleet selecting *something* once the model has twice failed to
# corroborate a `none-selected` against the bands requirement 3x's gate does
# check, so those three sitting
# unreached by fallback costs nothing on the failure mode this exists for —
# `eligible_items_json` is non-empty exactly when the gate can reject a
# verdict at all, and every band it counts has a rank below, so there is
# always something to fall to.
#
# It reads each repo's configured `sources` list as well as its pre-fetched
# arrays, and that is load-bearing rather than tidiness (requirement 3x): the
# arrays alone stopped being the authority on what a cycle may select once
# requirement 2.2a's back-pressure began narrowing the *list* while leaving
# `findings` and `human_visibility` populated. Before 3x
# the point could not arise — back-pressure emptied `tech_debt`, so the
# tech-debt-only gate could never reject during a restricted cycle and this
# function was never reached — but a gate that now counts the finishing
# sources can, and a fallback blind to `sources` would answer it by starting
# fresh work through a full landing gate. The one place the list is coarser
# than the array is `findings`, whose two kinds are separate source tokens
# (`security`, `code-quality`) and are matched as such here.
#
# The one band the gate counts that this walk can still decline is a
# superseded Dependabot merge-conflict entry: the prompt requires it in
# `voided` (so it is eligible, and owed an account) but it is not selectable
# work, so `mc_cands` skips it exactly as the prompt does. A cycle whose only
# unaccounted item is one of those reaches the empty-pick branch below, which
# stands down rather than assuming the guarantee.
#
# Each candidate is built straight from its own pre-fetched entry — the same
# fields the Co-Ordinator's own contract in `prompts/coordinator.md`'s
# "Output" section requires (`item`, `branch`/`pr_url`/`pr_number` for the
# five sources whose branch and pull request predate the claim — the
# `PREFLIGHT_EXISTING_BRANCH_SOURCES` set, `landing-refusals` included — the
# Dependabot `takeover` shape for merge-conflicts) — with `context` a verbatim paste of the entry's own body
# text and `acceptance` a generic instruction naming the source's standard
# procedure, since there is no model here to compose a bespoke one.
# `model`/`model_reason` are supplied by the caller (ordinarily
# `implementer_model_default`) since a mechanical pick makes no model
# judgement to report — cheap to spot on the eventual Implementer work order,
# rather than silently reusing whatever the last attempt happened to prefer.
# `pr_label` is supplied by the caller for the same reason the Co-Ordinator is
# handed it on its runtime input and copies it into every candidate
# (requirement 20): the Implementer labels its draft pull request with the
# work order's own field, and a candidate built here without one would raise
# the unlabelled pull request that no gatherer — nor the back-pressure count —
# can find again.
#
# `refinement_policy` (requirement 39a) binds this path exactly as it binds
# the Co-Ordinator, and for the same reason: a `"required"` source's unrefined
# item is not a lower-ranked candidate, it is one nobody has written a
# specification for yet, and handing it to an Implementer under a generic
# `acceptance` string is precisely the outcome that policy exists to prevent.
# A mechanical picker that ignored it could select what no Co-Ordinator
# engagement was allowed to. So an unrefined item from a `"required"` source
# is dropped here (`mk` yields nothing for it), and a `"preferred"` source's
# refined items are ranked ahead of its unrefined ones within their band —
# the same thumb on the scale `prompts/coordinator.md`'s "Per-source
# refinement policy" section describes, applied by a stable sort so the band's
# own order still decides everything else. `"exempt"` sources, which is every
# source an installation has not opted in, are unaffected.
#
# This costs the guarantee above nothing, band by band: `unaccounted_items`
# drops an eligible entry whose own source is `"required"` before it can ever
# make the gate reject, so a band that could send the cycle here is by
# construction a band this exclusion does not empty.
#
# Prints the single winning candidate object, or `null` if every reachable
# band was empty (never observed in practice, per the guarantee above, but
# handled rather than assumed).
fallback_select_candidate() {  # <ordered-repos-json> <default-model> <refinements-json> <refinement-policy-json> <pr-label>
  local repos="$1" model="$2" refinements="${3:-{\}}" policy="${4:-{\}}" label="${5:-}"
  jq -e 'type == "object"' <<<"$refinements" >/dev/null 2>&1 || refinements='{}'
  jq -e 'type == "object"' <<<"$policy" >/dev/null 2>&1 || policy='{}'
  jq -c --arg model "$model" --arg label "$label" --argjson refinements "$refinements" --argjson policy "$policy" \
    --arg model_reason "script-fallback: deterministic band-priority pick after two rejected corroboration verdicts; no model judgement applied" '
    def policy_of($src): (($policy // {})[$src] // "exempt");
    def is_refined($r; $item): ((($refinements // {})[$r] // {})[($item | tostring)] // null) != null;
    # Requirement 3x: the repo entry keeps its own `sources` list, and a band
    # this cycle narrowed away (back-pressure, or a repo that never listed the
    # source) is not a band a mechanical pick may reach into. Applied to the
    # repo, before its array is walked, so it costs one test per repo per band
    # rather than one per candidate.
    def lists($src): (((.sources // []) | index($src)) != null);
    # An issue is banded per entry (requirement 15e), so its rank token is
    # too: `issues` alone means every band, `issues:high` means only that one.
    def lists_issue_band($p): (lists("issues") or lists("issues:" + ($p | ascii_downcase)));

    # `_rank` is stripped from the winner below; it exists only to order the
    # band of a "preferred" source, and is 0 under every other policy so those
    # bands keep the order they are built in.
    def mk($r; $db; $src; $item; $title; $ctx; $acc; $extra):
      if policy_of($src) == "required" and (is_refined($r; $item) | not) then empty
      else
        {repo: $r, default_branch: $db, pr_label: $label, source: $src, item: $item, title: $title,
         model: $model, model_reason: $model_reason, context: $ctx, acceptance: $acc,
         _rank: (if policy_of($src) == "preferred" and (is_refined($r; $item) | not)
                 then 1 else 0 end)} + $extra
      end;

    def issue_ctx: "Issue #" + (.number | tostring) + ": " + (.title // "") + "\n\n"
      + (.body // "") + "\n\nComments:\n"
      + ([(.comments // [])[] | (.author // "") + " (" + (.created_at // "") + "):\n" + (.body // "")] | join("\n\n"));

    def sec_cands: [.[] | select(lists("security")) | .slug as $r | .default_branch as $db | (.findings // [])[] | select(.source == "security")
      | mk($r; $db; "security"; .ref; .title;
          ("Security finding (script-fallback selection).\nkind: " + (.kind // "") + "\nseverity: " + (.severity // "")
           + "\npackage: " + (.package // "") + "\nrule: " + (.rule // "") + "\nlocation: " + (.location // "")
           + "\nurl: " + (.url // "") + "\ntitle: " + (.title // ""));
          "Resolve the finding per its own record above, following this repo'"'"'s standard security-finding handling.";
          {})];

    def issue_band($p): [.[] | select(lists_issue_band($p)) | .slug as $r | .default_branch as $db | (.issues // [])[]
      | select((.priority // "Medium") == $p)
      | mk($r; $db; "issues"; ((.ref // (.number | tostring))); .title; issue_ctx;
          "Resolve per the current state of the issue thread above (body and every comment), not just the opening post.";
          {})];

    def rf_cands: [.[] | select(lists("review-feedback")) | .slug as $r | .default_branch as $db | (.review_feedback // [])[]
      | mk($r; $db; "review-feedback"; .ref; .title; (.body // "");
          "Address the review feedback above and push to the existing pull request.";
          {branch: .branch, pr_url: .pr_url, pr_number: .pr_number})];

    def mc_cands: [.[] | select(lists("merge-conflicts")) | .slug as $r | .default_branch as $db | (.merge_conflicts // [])[]
      | select((.superseded_by // null) == null)
      | select(((.bot // false) | not) or (.rebase_requested // false))
      | (((.bot // false) and (.rebase_requested // false)) as $takeover
         | mk($r; $db; "merge-conflicts"; .ref; .title; (.body // "");
             "Rebase the existing pull request onto its base and resolve the conflict.";
             ({pr_url: .pr_url, pr_number: .pr_number} + (if $takeover then {takeover: true} else {branch: .branch} end))))];

    def dq_cands: [.[] | select(lists("dequeued")) | .slug as $r | .default_branch as $db | (.dequeued // [])[]
      | mk($r; $db; "dequeued"; .ref; .title; (.body // "");
          "Diagnose and fix the merge-group checks failure that got this pull request dequeued, then push to the existing branch.";
          {branch: .branch, pr_url: .pr_url, pr_number: .pr_number, base: .base})];

    def lr_cands: [.[] | select(lists("landing-refusals")) | .slug as $r | .default_branch as $db | (.landing_refusals // [])[]
      | mk($r; $db; "landing-refusals"; .ref; .title; (.body // "");
          "Answer every unreconciled comment above on the existing pull request — implementing what it asks or replying to contest it — and cite each one with its own <!-- agent-ops:reconciles comment=<id> --> line; leave the pull request ready.";
          {branch: .branch, pr_url: .pr_url, pr_number: .pr_number})];

    def ad_cands: [.[] | select(lists("abandoned-drafts")) | .slug as $r | .default_branch as $db | (.abandoned_drafts // [])[]
      | mk($r; $db; "abandoned-drafts"; .ref; .title; (.body // "");
          "Finish the existing draft pull request to the item'"'"'s own acceptance.";
          {branch: .branch, pr_url: .pr_url, pr_number: .pr_number})];

    def hv_cands: [.[] | select(lists("human-visibility")) | .slug as $r | .default_branch as $db | (.human_visibility // [])[]
      | mk($r; $db; "human-visibility"; .ref; ("human-visibility: " + .ref);
          ((.body // "") + "\n\nurl: " + (.url // ""));
          "Diagnose and fix the named human-visibility failure per its own record above; report blocked if the cause is outside this repository.";
          {})];

    def td_cands: [.[] | select(lists("tech-debt")) | .slug as $r | .default_branch as $db | (.tech_debt // [])[]
      | mk($r; $db; "tech-debt"; .ref; .title; (.body // "");
          "Resolve per the tech-debt record verbatim above; standard tech-debt closing procedure applies.";
          {})];

    def cq_cands: [.[] | select(lists("code-quality")) | .slug as $r | .default_branch as $db | (.findings // [])[] | select(.source == "code-quality")
      | mk($r; $db; "code-quality"; .ref; .title;
          ("Code-quality finding (script-fallback selection).\nkind: " + (.kind // "") + "\nrule: " + (.rule // "")
           + "\nlocation: " + (.location // "") + "\nurl: " + (.url // "") + "\ntitle: " + (.title // ""));
          "Resolve the finding per its own record above, following this repo'"'"'s standard code-quality handling.";
          {})];

    [ sec_cands, issue_band("Urgent"), rf_cands, mc_cands, dq_cands, lr_cands, ad_cands, hv_cands,
      issue_band("High"), td_cands, issue_band("Medium"), issue_band("Low"), cq_cands ]
    | map(select(length > 0))
    | if length > 0 then (.[0] | sort_by(._rank) | .[0] | del(._rank)) else null end
  ' <<<"$repos"
}

# Issue #587: the Script-side reconciliation the split invocation model needs
# now that no single Co-Ordinator completion ever sees more than one repo's
# candidates. `prompts/coordinator.md`'s "Selection algorithm" states six
# tiers that override the plain repo-then-source walk fleet-wide — security,
# urgent issues, review-feedback, merge-conflicts, dequeued, abandoned-drafts,
# in that order — and everything else (landing-refusals, human-visibility,
# tech-debt, the remaining issue bands, code-quality, and the three sources
# with no pre-fetched array) has *no* cross-repo tier of its own: two
# candidates from that residual set are ordered by repo order alone, exactly
# as they would be if one engagement had reached them in its own repo-then-
# source walk. This mirrors the prompt's own rule precisely (unlike
# `fallback_select_candidate`'s deliberately looser approximation, which
# never had a merge step to get right — see that function's own comment) and
# is a *separate* table from it: the two do not share code, so a
# `fallback_select_candidate` band-order edit does not silently move this
# one, and vice versa.
#
# CANDS is the concatenation of every repo's own returned `candidates` array,
# each entry pre-tagged by the caller with `_repo_order` (that repo's index
# in `ordered_repos_json`, the walk order requirement 3 already computes) and
# `_rank` (its 0-based position in that repo's own ranked list). REPOS is
# `ordered_repos_json`, read only to look up an `issues`-source candidate's
# own `priority` (the tag that decides whether it is the second, global
# "urgent issues" tier or an ordinary residual-tier issue) — a Co-Ordinator's
# returned candidate object never carries `priority` itself.
#
# Sorts by (tier, repo order, that repo's own rank), then keeps the first
# CMAX — the fleet-wide cap requirement 17a's `candidates_max` names, applied
# here because no single engagement can enforce it across repos it never
# saw. Every `_repo_order`/`_rank` tag is stripped from what is returned, so
# the result is exactly the shape the pre-split single invocation returned in
# its own `candidates` array.
coordinator_merge_candidates() {  # <candidates-json> <ordered-repos-json> <candidates-max>
  local cands="${1:-[]}" repos="${2:-[]}" cmax="${3:-3}"
  jq -e 'type == "array"' <<<"$cands" >/dev/null 2>&1 || cands='[]'
  jq -e 'type == "array"' <<<"$repos" >/dev/null 2>&1 || repos='[]'
  [[ "$cmax" =~ ^[0-9]+$ ]] || cmax=3
  jq -nc --argjson cmax "$cmax" '
    input as $cands | input as $repos
    | ( [ $repos[] | {key: (.slug // ""), value: .} ] | from_entries ) as $by_slug
    | def issue_priority($repo; $item):
        ( ($by_slug[$repo].issues // [])
          | map(select(((.ref // (.number | tostring)) | tostring) == ($item | tostring)))
          | (.[0].priority // "Medium") );
    def tier($c):
        if $c.source == "security" then 0
        elif ($c.source == "issues" and issue_priority($c.repo; $c.item) == "Urgent") then 1
        elif $c.source == "review-feedback" then 2
        elif $c.source == "merge-conflicts" then 3
        elif $c.source == "dequeued" then 4
        elif $c.source == "abandoned-drafts" then 5
        else 6
        end;
    $cands
      | map(. + {_tier: tier(.)})
      | sort_by([._tier, ._repo_order, ._rank])
      | .[0:$cmax]
      | map(del(._tier, ._repo_order, ._rank))
  ' <<<"$(printf '%s\n%s\n' "$cands" "$repos")"
}

# Issue #587: corroboration and mechanical fallback, run once per cycle after
# every configured repository's own Co-Ordinator engagement has answered and
# `coordinator_merge_candidates` above has still come back empty — the
# narrowed remainder of what `coordinator_corroborate_retry_or_fallback` did
# before this change (see requirement 3v). There is no model retry here: a
# repository's own confabulated `"selected": false` now costs only that
# repository's own opportunity this cycle (every other configured repository
# still got its own independent engagement), so the model retry a fleet-wide
# `none-selected` used to buy itself was judged not worth its own added
# cost once N engagements already exist instead of one (D14, priced in the
# pull request that made this change).
#
# FALSE_REPOS is the JSON array of repository slugs whose own engagement
# returned `"selected": false` this cycle — the only repositories that can
# have left something eligible unaccounted for, since a repository that
# selected already accounted for its own eligible work by returning it.
# REASON is those repositories' own reasons, already joined by the caller.
# RECORDED_REFINEMENT/RECORDED_VOIDED are the fleet-wide `needs_refinement`/
# `voided` totals accumulated across every repository's own engagement this
# cycle (every repository's own entries, not only the false ones — a
# selected repository can still report one alongside its candidates).
#
# Reads the cycle's own globals exactly as the function it replaces did:
# `eligible_items_json`, `refinement_policy_json`, `coordinator_fit_trimmed_json`,
# `ordered_repos_json`, `implementer_model_default`, `refinements_json`,
# `pr_label`, `coordinator_model`, `noop_fingerprint_value`,
# `eligible_items_total`. Sets `candidates_json` (the fallback's one-candidate
# list) and `selected_by_fallback=1` and returns 0 when the fallback found
# something to claim; otherwise logs `none-selected` itself (`td_verdict_rejected`/
# `bands` present only when corroboration rejected a verdict and the fallback
# then found nothing either — `scripts/publish-dashboard.sh`'s corroboration-
# rate panel reads those two fields by name) and returns 1 for the caller to
# `exit 0`.
coordinator_corroborate_and_fallback() {  # <false-repos-json> <reason> <recorded-refinement-json> <recorded-voided-json>
  local false_repos="${1:-[]}" reason="${2:-no repository reported a verdict this cycle}" \
        recorded_refinement="${3:-[]}" recorded_voided="${4:-[]}" \
        eligible_false_json eligible_false_total unaccounted_json unaccounted_n \
        unaccounted_bands_json fallback_candidate_json fallback_empty=0

  # --- Verdict corroboration, scoped to the repositories that said no
  #     (requirements 3t/3x) ---
  eligible_false_json="$(jq -c --argjson repos "$false_repos" \
    '[.[] | select(.repo as $r | $repos | index($r) != null)]' <<<"$eligible_items_json")"
  eligible_false_total="$(jq 'length' <<<"$eligible_false_json" 2>/dev/null || echo 0)"
  unaccounted_json='[]'
  if (( eligible_false_total > 0 )); then
    unaccounted_json="$(unaccounted_items \
      "$(jq -nc 'input as $nr | input as $v | {needs_refinement: $nr, voided: $v}' \
          <<<"$recorded_refinement"$'\n'"$recorded_voided")" \
      "$eligible_false_json" "$refinement_policy_json" "${coordinator_fit_trimmed_json:-[]}")"
  fi
  unaccounted_n="$(jq 'length' <<<"$unaccounted_json" 2>/dev/null || echo 0)"
  unaccounted_bands_json='{}'

  if (( unaccounted_n > 0 )); then
    unaccounted_bands_json="$(jq -c 'group_by(.source)
      | map({key: (.[0].source // ""), value: length}) | from_entries' \
      <<<"$unaccounted_json" 2>/dev/null || echo '{}')"
    log_event "warning" "$(jq -nc --argjson n "$unaccounted_n" --argjson total "$eligible_false_total" \
      --argjson bands "$unaccounted_bands_json" --arg r "$reason" \
      'input as $items | {detail: ("verdict contradiction: the Script found " + ($total | tostring)
                 + " eligible item(s) across the repo(s) that reported selected:false, but "
                 + ($n | tostring)
                 + " of them — " + (($bands | to_entries | map(.key + " " + (.value | tostring)) | join(", ")))
                 + " — were neither selected, covered by a needs_refinement report, nor voided this cycle"
                 + " — the reported reason(s) (\"" + $r + "\") do not account for them"),
        eligible_total: $total, bands: $bands, unaccounted: $items}' <<<"$unaccounted_json")"
    log_event "corroboration" "$(jq -nc --argjson a 1 --arg v "rejected" --argjson total "$eligible_false_total" \
      --argjson n "$unaccounted_n" --arg r "$reason" --argjson bands "$unaccounted_bands_json" \
      --arg m "$coordinator_model" \
      'input as $items | {attempt: $a, verdict: $v, eligible_total: $total, unaccounted_total: $n,
        bands: $bands, unaccounted: $items, reason: $r, coordinator_model: $m}' <<<"$unaccounted_json")"

    # --- Deterministic selection (requirement 3v) ---
    # No per-repo retry — see this function's own header. Straight to the
    # same mechanical, fleet-wide, no-model-call picker a fleet-wide
    # `none-selected` used to fall back to only after its own one retry had
    # also failed corroboration; unchanged, and still the backstop that
    # keeps the fleet moving when nothing selectable was actually reported.
    fallback_candidate_json="$(fallback_select_candidate "$ordered_repos_json" \
      "$implementer_model_default" "$refinements_json" "$refinement_policy_json" "$pr_label")"
    if [[ -n "$fallback_candidate_json" && "$fallback_candidate_json" != "null" ]]; then
      candidates_json="$(jq -c '[.]' <<<"$fallback_candidate_json")"
      selected_by_fallback=1
      return 0
    fi
    # Not observed in practice (see fallback_select_candidate's own comment
    # for the guarantee this would defy), but fail closed rather than assume
    # it away.
    fallback_empty=1
  elif (( eligible_false_total > 0 )); then
    log_event "corroboration" "$(jq -nc --argjson a 1 --arg v "accepted" --argjson total "$eligible_false_total" \
      --arg m "$coordinator_model" \
      '{attempt: $a, verdict: $v, eligible_total: $total, unaccounted_total: 0, coordinator_model: $m}')"
  fi

  # `eligible_total` here is the fleet-wide count (every repo, not just the
  # ones that said no), matching what the single fleet-wide invocation's own
  # `none-selected` always carried. `td_verdict_rejected`/`bands` are added,
  # and the fingerprint omitted (requirement 3t: a rejected verdict must
  # never arm the no-op short-circuit), only on the one branch reachable
  # here where corroboration rejected a verdict and the mechanical fallback
  # above then found nothing either — the same two fields (and the same
  # name) the pre-split single invocation's own twice-rejected
  # `none-selected` carried. `fallback_empty` is set on no other branch, so
  # reusing it for both is exact, not a shortcut.
  log_event "none-selected" "$(jq -nc --arg r "$reason" --arg f "$noop_fingerprint_value" \
    --argjson total "$eligible_items_total" --arg m "$coordinator_model" \
    --argjson rejected "$fallback_empty" --argjson bands "$unaccounted_bands_json" \
    '{reason: $r} + (if $rejected == 1 or $f == "" then {} else {fingerprint: $f} end)
     + {eligible_total: $total, coordinator_model: $m}
     + (if $rejected == 1 then {td_verdict_rejected: true, bands: $bands} else {} end)')"
  local nts_state="" nts_cause=""
  IFS=$'\t' read -r nts_state nts_cause < <(node_time_state_idle_split "$eligible_items_total" coordinator-declined)
  set_node_state_terminal "$nts_state" "$nts_cause"
  return 1
}
