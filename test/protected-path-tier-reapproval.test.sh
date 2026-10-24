#!/usr/bin/env bash
#
# test/protected-path-tier-reapproval.test.sh — regression test for
# requirement 8w's own reapproval ladder behind gate 4.5's protected-path-tier
# sub-case (issue #2514): `_landing_protected_path_tier_resolve` and
# `protected_path_tier_reapproval_attempted_before`, both in lib/landing.sh.
#
# `test/landing-wiring.test.sh` covers the gate itself (does gate 4.5 call the
# resolver only on a retry, only for the tier/no-timestamp sub-case, and does
# it reclassify whatever verdict comes back), with `_landing_protected_path_
# tier_resolve` stubbed as a black box — the same relationship that file
# already has with `_landing_open_question_resolve`. This file is the other
# half: what the resolver itself does once called, with `run_protected_path_
# tier_reapproval` stubbed as its own black box for Part A, exactly as
# test/open-question-adjudication.test.sh treats `run_open_question_
# adjudication` (a live nested Claude launch has no place in a wiring test) —
# and, in Part C below (after Part B's own coverage of `protected_path_tier_
# reapproval_attempted_before`), `run_protected_path_tier_reapproval`'s own
# post/log/return tail tested directly, with `approver_post_or_warn` stubbed
# instead, mirroring that same file's own Part C.
#
# The axes a stubbed-whole resolver leaves uncovered, and which Part A exists
# for, are the ones that are pure control flow over stubbable collaborators:
#
#   - *when it escalates*. The escalation is for the sub-case the pass exists
#     to clear, still standing after the pass — never for whatever else the
#     recomputed verdict turns out to be. A successful reapproval almost
#     always lands on a brand-new cool-off wait, which clears itself
#     unattended; escalating there files a human-assigned issue asserting
#     that a critical-tier approval "could not be established" moments after
#     the resolver established one. The same holds when the resolver's own
#     live recheck of that approval fails to read at all (a transient `gh`
#     hiccup, not a control that is unmet) — that reads back `unknown:`,
#     never the stale triggering text, so this file's stub of the recheck
#     collaborators can force that path too.
#   - *where it reads the one-pass cap*. Fleet-wide (`union_log`), like
#     requirement 8f's own `open_question_pass_available`, never this node's
#     own stream alone — acceptance check 8u's sweep runs on every node, so a
#     node-local cap lets each node spend its own pass over one unchanged
#     head commit.
#
# Part C exists because a stubbed-whole `run_protected_path_tier_reapproval`
# cannot see its own failure mode: a reapproval that approves and attempts to
# post, where the post itself does not reach GitHub. `approver_post_or_warn`
# always returns 0 regardless of the write's own outcome (lib/approver.sh),
# so that failure is only visible through `approver_last_post_ok` — and a
# function that logged `approver-verdict` on that path anyway would hand
# `landing_retry_tier` a tier record for a review that was never actually
# written (agent-ops#2519's own review of this file's companion pull
# request).
#
# Every function here is lifted verbatim out of lib/landing.sh, so the
# assertions are about the shipped code rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/protected-path-tier-reapproval.test.sh
#
# Exit status is 0 iff every assertion passed.
#
# shellcheck disable=SC2016
# This file assembles a harness script whose `$`-expressions must reach the
# assembled file unexpanded; the single-quoted here-doc and `printf` lines
# below are deliberate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/lib/landing.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:             %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

extract() {  # <function name> [source file, default $CYCLE]
  awk -v fn="^$1\\\\(\\\\) \\\\{" '$0 ~ fn { on = 1 } on { print } on && /^\}$/ { exit }' "${2:-$CYCLE}"
}

# extract_tail <start-line regex> [source file, default $CYCLE] — like
# extract() above, but anchored on an arbitrary line inside a function
# rather than its own `name() {` opening, and stopping *before* the
# function's own closing `}` rather than including it: the result is a bare
# sequence of statements (with a bare `return`, valid only inside a
# function), meant to be pasted into a harness function of the test's own
# naming, not called on its own.
extract_tail() {
  awk -v re="$1" '$0 ~ re { on = 1 } on && /^\}$/ { exit } on { print }' "${2:-$CYCLE}"
}

resolve_block="$(extract _landing_protected_path_tier_resolve)"
attempted_before_block="$(extract protected_path_tier_reapproval_attempted_before)"
reapproval_tail_block="$(extract_tail 'approver_post_or_warn "\$pr_url" APPROVE')"
if [[ -z "$reapproval_tail_block" ]]; then
  echo "FAIL - could not extract run_protected_path_tier_reapproval's post/log/return tail from lib/landing.sh — has it moved?" >&2
  exit 1
fi

for pair in "resolve_block:_landing_protected_path_tier_resolve" \
            "attempted_before_block:protected_path_tier_reapproval_attempted_before"; do
  var="${pair%%:*}" name="${pair#*:}"
  if [[ -z "${!var}" ]]; then
    echo "FAIL - could not extract $name from lib/landing.sh — has it moved?" >&2
    exit 1
  fi
done

# The two literal `ineligible:` shapes `landing_protected_path_controls_ok`
# itself prints for this sub-case, and the one the ordinary cool-off prints —
# grepped from lib/landing.sh rather than retyped, so a reworded message in
# that function fails this test loudly instead of letting the case patterns in
# `_landing_protected_path_tier_resolve` quietly stop matching (the same
# drift-exposure discipline test/landing.test.sh applies to the cool-off
# printf).
TIER_MSG='ineligible:touches a protected path at agent-merges-all but the approving engagement did not run at the critical tier (tier: standard)'
NO_TS_MSG='ineligible:touches a protected path at agent-merges-all but no approval timestamp could be established for the cool-off'
COOLOFF_MSG='ineligible:protected-path cool-off has 24.0h remaining (approved 2026-10-18T16:00:00Z, landing_cool_off_hours=24)'
for pair in "did not run at the critical tier:TIER_MSG" \
            "no approval timestamp could be established:NO_TS_MSG" \
            "protected-path cool-off has:COOLOFF_MSG"; do
  needle="${pair%%:*}" name="${pair#*:}"
  if ! grep -qF "$needle" "$CYCLE"; then
    echo "FAIL - lib/landing.sh no longer prints '$needle' — $name is stale" >&2
    exit 1
  fi
done

# ============================================================================
# Part A: `_landing_protected_path_tier_resolve` — the ladder, with
# `run_protected_path_tier_reapproval` and `protected_path_tier_escalate`
# stubbed as black boxes, and the real `protected_path_tier_reapproval_
# attempted_before` reading two real synthetic logs (this node's own and the
# fleet's) so the cap's own source is observable.
# ============================================================================

cat >"$tmp_dir/harness_a.sh" <<'HARNESS'
set -euo pipefail

enabler_escalation_label="agent-escalation"
node_name="test-node"
cycle_id="20261018T000000Z-test-1"
cycle_dir="$T/cycle"
union_log="$T/union.jsonl"
log_file="$T/log.jsonl"
DEFAULTED_CONFIG='{}'
mkdir -p "$cycle_dir"
: >"$union_log"
: >"$log_file"
if [[ -n "${UNION_SEED:-}" ]]; then printf '%s\n' "$UNION_SEED" >>"$union_log"; fi
if [[ -n "${NODE_LOG_SEED:-}" ]]; then printf '%s\n' "$NODE_LOG_SEED" >>"$log_file"; fi

log_event() { printf '%s\t%s\n' "$1" "$2" >>"$T/events"; }

gh() {
  printf '%s\n' "$*" >>"$T/gh_calls"
  if [[ "$1" == "pr" && "$2" == "view" ]]; then
    printf '%s' "${HEAD_SHA:-}"
    return 0
  fi
  return 1
}

run_protected_path_tier_reapproval() {
  printf '%s\n' "$*" >>"$T/reapproval_args"
  printf '%s' "$REAPPROVAL_JSON"
}

protected_path_tier_escalate() {
  printf '%s\n' "$*" >>"$T/escalate_calls"
}

approver_token_identity_login() { printf '%s' "${APP_LOGIN:-pullwright-approver[bot]}"; }

landing_approver_standing_review_at() {
  printf '%s\n' "$*" >>"$T/standing_args"
  if [[ -z "${STANDING:-}" ]]; then return 1; fi
  printf '%b' "$STANDING"
}

landing_retry_tier() {
  printf '%s\n' "$*" >>"$T/retry_tier_args"
  printf '%s' "${RECHECK_TIER:-critical}"
}

landing_protected_path_controls_ok() {
  printf '%s\n' "$*" >>"$T/pp_ctl_args"
  printf '%s' "${RECHECK_PP_CTL:-ok}"
}

HARNESS

SLUG="Poetic-Poems/agent-ops"
URL="https://github.com/Poetic-Poems/agent-ops/pull/2501"
HEAD="sha-current-head"

{
  printf '%s\n' "$attempted_before_block"
  printf '%s\n' "$resolve_block"
  printf '_landing_protected_path_tier_resolve "%s" "%s" "2501" "$PP_CTL" "2514"\n' "$SLUG" "$URL"
} >>"$tmp_dir/harness_a.sh"

# run_case_a [KEY=VALUE ...] — prints the resolver's own stdout. Its exit
# status is not asserted on: `_landing_protected_path_tier_resolve` always
# returns 0, handing its verdict to gate 4.5 as the string it prints (see its
# header on why the caller needs the live value rather than a boolean), so
# there is no pass/fail status here for a case to turn on.
run_case_a() {
  : >"$tmp_dir/events"; : >"$tmp_dir/gh_calls"; : >"$tmp_dir/reapproval_args"
  : >"$tmp_dir/escalate_calls"; : >"$tmp_dir/standing_args"
  : >"$tmp_dir/retry_tier_args"; : >"$tmp_dir/pp_ctl_args"
  env -i PATH="$PATH" HOME="$HOME" \
    T="$tmp_dir" HEAD_SHA="$HEAD" \
    PP_CTL="$TIER_MSG" \
    REAPPROVAL_JSON='{"verdict":"approve","evidence":"the diff holds up at the critical tier"}' \
    STANDING="APPROVED\t2026-10-18T16:00:00Z\t$HEAD" \
    RECHECK_TIER="critical" RECHECK_PP_CTL="ok" \
    UNION_SEED="" NODE_LOG_SEED="" \
    "$@" \
    bash "$tmp_dir/harness_a.sh" >"$tmp_dir/stdout_a" 2>"$tmp_dir/stderr_a" || true
  cat "$tmp_dir/stdout_a"
}

count_a() { wc -l <"$tmp_dir/$1" | tr -d ' '; }
event_of_a() { awk -F'\t' -v e="$1" '$1==e{print $2}' "$tmp_dir/events" | tail -1; }

# --- the ordinary success: a reapproval that approves, leaving the pull
#     request on its own fresh cool-off, escalates nothing -----------------
# The dominant path, and the one unconditional "escalate unless ok" got wrong:
# the recomputed verdict here is a brand-new cool-off wait (the fresh
# approval's own submitted_at is "now"), which is gate 4.5 working as designed
# and clears itself with no human involved.

out="$(run_case_a RECHECK_PP_CTL="$COOLOFF_MSG")"
assert_eq "a reapproval that approves runs exactly one pass" "1" "$(count_a reapproval_args)"
assert_contains "  ... called with the slug, URL, number and item" \
  "$SLUG $URL 2501 2514" "$(cat "$tmp_dir/reapproval_args")"
assert_contains "  ... logging protected-path-tier-reapproval with verdict approve" \
  '"verdict":"approve"' "$(event_of_a protected-path-tier-reapproval)"
assert_contains "  ... stamped with the head commit the cap is keyed to" \
  "\"head_sha\":\"$HEAD\"" "$(event_of_a protected-path-tier-reapproval)"
assert_eq "  ... and hands the caller the recomputed cool-off, never the stale tier text" \
  "$COOLOFF_MSG" "$out"
assert_eq "  ... escalating nothing — a fresh cool-off is this gate working, not a human's problem" \
  "" "$(cat "$tmp_dir/escalate_calls")"

# --- a reapproval that approves and posts, but whose own live recheck then
#     fails to read: held back as unknown, never escalated on the strength
#     of a read failure moments after a critical-tier approval was
#     established (the gap the review that reopened issue #2514 found).

out="$(run_case_a REAPPROVAL_JSON='{"verdict":"approve","evidence":"e"}' STANDING="")"
assert_contains "a posted approval whose live recheck read fails hands back unknown, never the stale tier text" \
  "unknown:" "$out"
assert_eq "  ... escalating nothing — a read failure is not a control that is unmet" \
  "" "$(cat "$tmp_dir/escalate_calls")"

# --- a reapproval that clears every control outright ----------------------

out="$(run_case_a RECHECK_PP_CTL="ok")"
assert_eq "a reapproval whose recomputed verdict is ok hands back ok" "ok" "$out"
assert_eq "  ... and escalates nothing" "" "$(cat "$tmp_dir/escalate_calls")"
assert_contains "  ... having re-read the tier from this node's own stream, where the fresh approver-verdict was just written" \
  "$tmp_dir/log.jsonl" "$(cat "$tmp_dir/retry_tier_args")"
assert_contains "  ... and recomputed the controls against the live standing review" \
  "critical 2026-10-18T16:00:00Z $HEAD" "$(cat "$tmp_dir/pp_ctl_args")"

# --- a reapproval that could not establish the critical tier: the sub-case
#     still stands, so this one does escalate ---------------------------

out="$(run_case_a REAPPROVAL_JSON='{"verdict":"escalate","evidence":"the diff loosens a control its description does not mention"}' \
  STANDING="" )"
assert_contains "a reapproval that escalates is logged as escalate" \
  '"verdict":"escalate"' "$(event_of_a protected-path-tier-reapproval)"
assert_eq "  ... and escalates exactly once, the sub-case still standing" \
  "1" "$(count_a escalate_calls)"
assert_contains "  ... naming the synthetic per-pull-request item ref" \
  "pr-2501-protected-path-tier" "$(cat "$tmp_dir/escalate_calls")"
assert_eq "  ... handing the caller the unchanged triggering verdict" "$TIER_MSG" "$out"

# --- an unrecognised verdict reads as escalate, never as approve ----------

out="$(run_case_a REAPPROVAL_JSON='{"verdict":"something-else","evidence":"e"}' STANDING="")"
assert_contains "an unrecognised reapproval verdict is logged as escalate" \
  '"verdict":"escalate"' "$(event_of_a protected-path-tier-reapproval)"

# --- the missing-timestamp sub-case escalates on the same terms -----------

out="$(run_case_a PP_CTL="$NO_TS_MSG" \
  REAPPROVAL_JSON='{"verdict":"escalate","evidence":"e"}' STANDING="")"
assert_eq "the missing-timestamp sub-case, still standing, escalates too" \
  "1" "$(count_a escalate_calls)"
assert_eq "  ... handing back its own wording" "$NO_TS_MSG" "$out"

# --- an unreadable control is never a human's problem --------------------
# `unknown:*` means the gate could not ask, not that a control is unmet, so
# the next retry asks again rather than a human being asked instead.

out="$(run_case_a RECHECK_PP_CTL="unknown:could not re-establish $SLUG#2501's current head commit for the protected-path cool-off")"
assert_contains "an unknown recomputed verdict is handed back verbatim" "unknown:" "$out"
assert_eq "  ... and escalates nothing — the gate could not ask, so the next retry asks again" \
  "" "$(cat "$tmp_dir/escalate_calls")"

# --- a head commit that could not be read at all -------------------------

out="$(run_case_a HEAD_SHA="")"
assert_eq "an unreadable head commit hands the triggering verdict straight back" "$TIER_MSG" "$out"
assert_eq "  ... never running a reapproval pass" "" "$(cat "$tmp_dir/reapproval_args")"
assert_eq "  ... and never escalating" "" "$(cat "$tmp_dir/escalate_calls")"

# --- the cap: one pass per head commit, read fleet-wide ------------------
# Requirement 8w. The event below is one a *peer* node logged, present only in
# the fleet union snapshot and not in this node's own stream — exactly the
# shape a node-local cap cannot see, and a second pass over one unchanged head
# commit is a second critical-tier model engagement and a second App review
# write.

peer_event="{\"event\":\"protected-path-tier-reapproval\",\"ts\":\"2026-10-18T15:00:00Z\",\"pr_url\":\"$URL\",\"head_sha\":\"$HEAD\",\"verdict\":\"escalate\"}"

out="$(run_case_a UNION_SEED="$peer_event" REAPPROVAL_JSON='{"verdict":"approve","evidence":"e"}')"
assert_eq "a pass a peer already spent on this head is seen — the cap is read fleet-wide" \
  "" "$(cat "$tmp_dir/reapproval_args")"
assert_eq "  ... escalating directly instead, exactly once" "1" "$(count_a escalate_calls)"
assert_eq "  ... and handing the triggering verdict back unchanged" "$TIER_MSG" "$out"

# This node's own stream is read alongside the union, never only as a
# fallback for an unset one: `fleet_logs` degrades to an *empty* union
# silently (requirement 38b), and a cap read off that alone would switch
# itself off on the one node whose fleet fetch is broken.
out="$(run_case_a NODE_LOG_SEED="$peer_event" REAPPROVAL_JSON='{"verdict":"approve","evidence":"e"}')"
assert_eq "a pass in this node's own stream binds even with an empty fleet union" \
  "" "$(cat "$tmp_dir/reapproval_args")"
assert_eq "  ... escalating directly, exactly once" "1" "$(count_a escalate_calls)"

other_head_event="${peer_event/$HEAD/sha-a-push-ago}"
out="$(run_case_a UNION_SEED="$other_head_event" RECHECK_PP_CTL="ok")"
assert_eq "a pass spent on an earlier head commit does not bind this one — a push earns a fresh pass" \
  "1" "$(count_a reapproval_args)"
assert_eq "  ... and it clears" "ok" "$out"

other_pr_event="${peer_event/pull\/2501/pull\/2502}"
out="$(run_case_a UNION_SEED="$other_pr_event" RECHECK_PP_CTL="ok")"
assert_eq "a pass spent on a different pull request does not bind this one" \
  "1" "$(count_a reapproval_args)"

echo

# ============================================================================
# Part B: `protected_path_tier_reapproval_attempted_before` on its own — the
# same LOG_FILE convention `landing_retry_tier` keeps (`-` for stdin, a path,
# or nothing to read).
# ============================================================================

cat >"$tmp_dir/harness_b.sh" <<'HARNESS'
set -euo pipefail
HARNESS
{
  printf '%s\n' "$attempted_before_block"
  cat <<'HARNESS_B'
if protected_path_tier_reapproval_attempted_before "$B_URL" "$B_HEAD" "$B_SRC" "$B_SRC2"; then
  printf 'spent'
else
  printf 'available'
fi
HARNESS_B
} >>"$tmp_dir/harness_b.sh"

run_case_b() {  # <src1> <url> <head> [src2]
  env -i PATH="$PATH" HOME="$HOME" B_SRC="$1" B_URL="$2" B_HEAD="$3" B_SRC2="${4:-}" \
    bash "$tmp_dir/harness_b.sh" 2>/dev/null
}

B_LOG="$tmp_dir/part-b.jsonl"
{
  printf '%s\n' "{\"event\":\"protected-path-tier-reapproval\",\"pr_url\":\"$URL\",\"head_sha\":\"$HEAD\"}"
  printf 'not json at all\n'
  printf '%s\n' "{\"event\":\"approver-verdict\",\"pr_url\":\"$URL\",\"tier\":\"critical\"}"
} >"$B_LOG"

assert_eq "a matching pr_url/head pair reads as spent" \
  "spent" "$(run_case_b "$B_LOG" "$URL" "$HEAD")"
assert_eq "a different head commit reads as available" \
  "available" "$(run_case_b "$B_LOG" "$URL" "sha-something-else")"
assert_eq "a different pull request reads as available" \
  "available" "$(run_case_b "$B_LOG" "${URL%2501}2502" "$HEAD")"
assert_eq "an unparseable line in the stream does not derail the read" \
  "spent" "$(run_case_b "$B_LOG" "$URL" "$HEAD")"
assert_eq "a missing path reads as available, never as spent" \
  "available" "$(run_case_b "$tmp_dir/no-such-log.jsonl" "$URL" "$HEAD")"
: >"$tmp_dir/empty.jsonl"
assert_eq "an empty stream reads as available" \
  "available" "$(run_case_b "$tmp_dir/empty.jsonl" "$URL" "$HEAD")"
assert_eq "SRC2 is read even when SRC1 is empty — neither source alone is the record" \
  "spent" "$(run_case_b "$tmp_dir/empty.jsonl" "$URL" "$HEAD" "$B_LOG")"
assert_eq "  ... and when SRC1 does not exist at all" \
  "spent" "$(run_case_b "$tmp_dir/no-such-log.jsonl" "$URL" "$HEAD" "$B_LOG")"
assert_eq "an unreadable SRC2 simply contributes nothing" \
  "available" "$(run_case_b "$tmp_dir/empty.jsonl" "$URL" "$HEAD" "$tmp_dir/no-such-log.jsonl")"

echo

# ============================================================================
# Part C: `run_protected_path_tier_reapproval`'s own post/log/return tail —
# the segment starting at its `approver_post_or_warn` call, lifted verbatim
# (`$reapproval_tail_block` above) rather than the whole function, since
# everything above that call (the model engagement, the verdict parse) is
# out of scope here and already covered elsewhere: requirement 45's own
# `test/prompt-untrusted-framing.test.sh` for the shipped prompt, and this
# file's own Part A, one layer up, for everything the ladder does with
# whatever this tail hands back.
#
# `approver_post_or_warn` always returns 0 regardless of the write's own
# outcome (lib/approver.sh) and reports it only through `approver_last_
# post_ok` — so the stub below sets that global directly, the same thing
# the real function does, rather than returning a value nothing downstream
# reads.
# ============================================================================

cat >"$tmp_dir/harness_c.sh" <<'HARNESS'
set -uo pipefail

approver_post_or_warn() {
  printf '%s\n' "$*" >>"$T/post_args"
  approver_last_post_ok="${POST_OK:-1}"
}

log_event() { printf '%s\t%s\n' "$1" "$2" >>"$T/events"; }

run_tail() {
  # `approver_model_critical_launch`, not the configured key itself: the tail
  # logs whichever member the model draw settled on (issue #2247).
  local pr_url="$1" slug="$2" approver_model_critical_launch="$3" item="$4" token="$5" evidence="$6"
HARNESS
{
  printf '%s\n' "$reapproval_tail_block"
  printf '}\n'
  printf 'run_tail "%s" "%s" "%s" "%s" "%s" "%s"\n' \
    "$URL" "$SLUG" "critical-model" "2514" "tok-123" "the diff holds up at the critical tier"
} >>"$tmp_dir/harness_c.sh"

run_case_c() {
  : >"$tmp_dir/events"; : >"$tmp_dir/post_args"
  env -i PATH="$PATH" HOME="$HOME" T="$tmp_dir" "$@" \
    bash "$tmp_dir/harness_c.sh" 2>"$tmp_dir/stderr_c"
}

event_of_c() { awk -F'\t' -v e="$1" '$1==e{print $2}' "$tmp_dir/events" | tail -1; }

# --- the post lands on GitHub: approve, logged, posted:true --------------

out="$(run_case_c POST_OK="1")"
assert_eq "a post that reaches GitHub reports approve with the engagement's own evidence" \
  '{"verdict":"approve","evidence":"the diff holds up at the critical tier"}' "$out"
assert_contains "  ... logging approver-verdict at the critical tier" \
  '"tier":"critical"' "$(event_of_c approver-verdict)"
assert_contains "  ... marked posted:true — the write actually reached GitHub" \
  '"posted":true' "$(event_of_c approver-verdict)"
assert_contains "  ... naming protected-path-tier-reapproval as the critical_reason" \
  '"critical_reason":"protected-path-tier-reapproval"' "$(event_of_c approver-verdict)"

# --- the post does not land on GitHub: escalate, and no approver-verdict
#     event at all — issue #2519's review of this file's companion pull
#     request. `approver_post_or_warn` always returns 0 on this path too,
#     so only `approver_last_post_ok` tells the two apart; logging the event
#     anyway would hand `landing_retry_tier` a critical-tier record for a
#     review that was never actually written to GitHub, silently clearing
#     gate 4.5's protected-path-tier sub-case on a write that failed.

out="$(run_case_c POST_OK="0")"
assert_eq "a post that does not reach GitHub escalates instead of reporting approve" \
  '{"verdict":"escalate","evidence":"the reapproval engagement approved, but the review write did not reach GitHub"}' "$out"
assert_eq "  ... and logs no approver-verdict event at all" \
  "" "$(event_of_c approver-verdict)"
assert_eq "  ... the write was still attempted" "1" "$(wc -l <"$tmp_dir/post_args" | tr -d ' ')"

echo
if (( failures )); then
  printf '%s assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'all assertions passed\n'
