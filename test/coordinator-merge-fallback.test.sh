#!/usr/bin/env bash
#
# test/coordinator-merge-fallback.test.sh — regression test for requirements
# 15z (issue #587) and 3v (issue #321): once every configured repository's
# own Co-Ordinator engagement has answered, the Script reconciles their
# candidates itself (`coordinator_merge_candidates`) and, only when the
# merged list is empty, corroborates the repositories that said no and, if
# that finds an unaccounted eligible item, falls back to a mechanical pick
# (`coordinator_corroborate_and_fallback`) — never a model retry, since one
# repository's own confabulation now costs only that repository's own
# opportunity this cycle, not the whole cycle's (every other configured
# repository still got its own independent engagement).
#
# `run_coordinator_stage_attempt`, `fallback_select_candidate`,
# `coordinator_merge_candidates` and `coordinator_corroborate_and_fallback`
# are lifted verbatim out of lib/stage-attempt.sh with awk, the same
# technique test/enabler-verdicts.test.sh uses for `maybe_run_enabler` — this
# cannot pass against a copy the library has since moved on from.
# `unaccounted_items`, `log_needs_refinement_items`, `log_voided_items`,
# `log_unblocked_items` and `log_recheck_clean_items` are lifted the same
# way, real, so the corroboration math under test is the genuine accounting
# rather than a paraphrase of it (test/verdict-corroboration.test.sh already
# covers those five in isolation; this file's job is the merge/fallback
# orchestration built on top of them). `run_claude_stage` is stubbed to
# answer a queued sequence of canned verdicts — one per call — so a
# scenario's several repositories can answer differently, the way genuinely
# separate engagements do.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/coordinator-merge-fallback.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/handoff.sh
. "$SCRIPT_DIR/lib/handoff.sh"

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

# --- Lift the functions under test verbatim out of lib/stage-attempt.sh ----
extract_fn() {
  local start_pat="$1" file="$2"
  awk -v start="$start_pat" '
    $0 == start { on = 1 }
    on          { print }
    on && /^}$/ { exit }
  ' "$file"
}

unaccounted_items_fn="$(extract_fn 'unaccounted_items() {  # <recorded-json> <eligible-json> <refinement-policy-json> [trimmed-json]' "$SCRIPT_DIR/lib/candidate-select.sh")"
log_unblocked_items_fn="$(extract_fn 'log_unblocked_items() {' "$SCRIPT_DIR/lib/candidate-select.sh")"
log_recheck_clean_items_fn="$(extract_fn 'log_recheck_clean_items() {' "$SCRIPT_DIR/lib/candidate-select.sh")"
log_needs_refinement_items_fn="$(extract_fn 'log_needs_refinement_items() {' "$SCRIPT_DIR/lib/candidate-select.sh")"
log_voided_items_fn="$(extract_fn 'log_voided_items() {' "$SCRIPT_DIR/lib/candidate-select.sh")"
extract_json_result_fn="$(extract_fn 'extract_json_result() {' "$SCRIPT_DIR/lib/stage-attempt.sh")"
run_coordinator_stage_attempt_fn="$(extract_fn 'run_coordinator_stage_attempt() {  # <attempt-out-file> <prompt> [extra-budget-json]' "$SCRIPT_DIR/lib/stage-attempt.sh")"
fallback_select_candidate_fn="$(extract_fn 'fallback_select_candidate() {  # <ordered-repos-json> <default-model> <refinements-json> <refinement-policy-json> <pr-label>' "$SCRIPT_DIR/lib/stage-attempt.sh")"
coordinator_merge_candidates_fn="$(extract_fn 'coordinator_merge_candidates() {  # <candidates-json> <ordered-repos-json> <candidates-max>' "$SCRIPT_DIR/lib/stage-attempt.sh")"
coordinator_corroborate_and_fallback_fn="$(extract_fn 'coordinator_corroborate_and_fallback() {  # <false-repos-json> <reason> <recorded-refinement-json> <recorded-voided-json>' "$SCRIPT_DIR/lib/stage-attempt.sh")"

for pair in \
  "unaccounted_items_fn:\$eligible" \
  "log_unblocked_items_fn:release_refinement_label" \
  "log_recheck_clean_items_fn:recheck-clean" \
  "log_needs_refinement_items_fn:coord_recorded_refinement_json" \
  "log_voided_items_fn:coord_recorded_voided_json" \
  "extract_json_result_fn:awk" \
  "run_coordinator_stage_attempt_fn:coord_attempt_result_json" \
  "fallback_select_candidate_fn:script-fallback" \
  "coordinator_merge_candidates_fn:_repo_order" \
  "coordinator_corroborate_and_fallback_fn:fallback_select_candidate"; do
  name="${pair%%:*}"
  needle="${pair#*:}"
  val="${!name}"
  if [[ "$val" != *"$needle"* ]]; then
    printf 'FAIL - %s could not be extracted from lib/stage-attempt.sh (renamed or moved?)\n' "$name"
    exit 1
  fi
done

eval "$unaccounted_items_fn"
eval "$log_unblocked_items_fn"
eval "$log_recheck_clean_items_fn"
eval "$log_needs_refinement_items_fn"
eval "$log_voided_items_fn"
eval "$extract_json_result_fn"
eval "$run_coordinator_stage_attempt_fn"
eval "$fallback_select_candidate_fn"
eval "$coordinator_merge_candidates_fn"
eval "$coordinator_corroborate_and_fallback_fn"

# --- Stubs for every dependency whose own correctness is not this test's job ---
#
# record_needs_refinement_block/void_guard_reason: the bar each guards is
# tested in depth elsewhere (test/tech-debt-eligibility.test.sh,
# test/void-guard.test.sh); here they always accept, so this file's own
# assertions are about *which* items reach them and how many times, not
# about the guards' own judgement.
calls_log=""
record() { printf '%s\n' "$*" >> "$calls_log"; }

log_event() { record "event $1 $2"; }
# docs/FLOW-SCHEMA.md, requirement 47, issue #596: the extracted coordinator
# stage-end site calls lib/rework.sh's rework_stage_rerun_maybe — out of this
# file's own scope (test/rework-record.test.sh covers it directly).
rework_stage_rerun_maybe() { :; }
# docs/FLOW-SCHEMA.md, requirement 50, issue #597: the same stage-end site,
# and every none-selected site this file's own corroborate/fallback ladder
# exercises, call lib/node-time-state.sh's log_node_state_transition/
# set_node_state_terminal/node_time_state_idle_split. Sourced for real (pure
# and cheap, and log_node_state_transition's own log_event call reaches the
# stub above, same as every other event this harness records) rather than
# stubbed, so this file keeps verifying the shipped wiring.
# shellcheck source=lib/node-time-state.sh
. "$SCRIPT_DIR/lib/node-time-state.sh"
record_needs_refinement_block() { record "record_needs_refinement_block $(jq -r '.item' <<<"$1")"; return 0; }
void_guard_reason() { record "void_guard_reason $(jq -r '.item' <<<"$1")"; return 0; }
# The machine `obsolete` alternative's ctx (issue #413, WI-10) is lib/merge-
# autonomy.sh/config territory, neither of which this file wires in; the
# stubbed void_guard_reason above ignores it regardless, so an empty ctx is
# enough — this just keeps the call from failing loudly with "command not
# found" for a function log_voided_items now calls unconditionally.
void_obsolete_ctx_json() { printf '{}'; }
# log_voided_items (issue #508) now reads this once per invocation, ahead of
# the loop the two stubs above already cover — stubbed for the same "command
# not found" reason, since this file never sources lib/cycle-state.sh.
draft_obsolete_flags() { printf '[]'; }
# The stub above only covers the call once made; log_voided_items resolves
# its LOG_FILE argument — `${union_log:-$log_file}` — before the call, so
# $log_file itself must be defined under `set -u` even though the stub never
# reads it.
# shellcheck disable=SC2034
log_file="$tmp_dir/log.jsonl"
void_entry_evidence() { printf 'stub evidence'; }
item_event_fields() { printf '{}'; }
release_refinement_label() { record "release-refinement-label $1 ${2:-}"; }
stage_watchdog_warning() { printf ''; }
dump_stage_output() { :; }
detect_and_log_limit_hit() { return 1; }
stage_salvage_result() { return 1; }
handle_stage_failure() { record "handle_stage_failure $1 $2"; }
metering_fields() { printf '{"cost_usd":0.05,"duration_ms":1234}'; }
stage_budget_apply() {
  record "stage_budget_apply $1 $2 $3 ${4:-{\}}"
  # shellcheck disable=SC2034  # read only by the eval'd run_coordinator_stage_attempt
  stage_backstop_min=1
  # shellcheck disable=SC2034
  stage_inactivity_min=1
}

# run_claude_stage's stand-in: answers a queued sequence of canned verdicts,
# one per call (STUB_QUEUE_RC_<n>/STUB_QUEUE_JSON_<n>), so several
# repositories' own engagements can answer differently within one cycle —
# the way genuinely separate engagements do. Writes the envelope shape
# extract_json_result parses a real transcript's final message out of.
STUB_CALL_N=0
run_claude_stage() {
  local out_file="$5"
  STUB_CALL_N=$(( STUB_CALL_N + 1 ))
  record "run_claude_stage call=$STUB_CALL_N out=$(basename "$out_file")"
  local rc_var="STUB_QUEUE_RC_$STUB_CALL_N" json_var="STUB_QUEUE_JSON_$STUB_CALL_N"
  local rc="${!rc_var:-0}" body="${!json_var:-}"
  if [[ "$rc" == "0" && -n "$body" ]]; then
    jq -nc --arg r "$body" '{result: $r, session_id: "stub-session"}' > "$out_file"
  else
    : > "$out_file"
  fi
  # shellcheck disable=SC2034  # read by the eval'd functions, not visible here
  stage_gaps_json="null"
  # shellcheck disable=SC2034
  stage_kill_reason=""
  return "$rc"
}

# --- Fixed globals every call needs ---------------------------------------
# shellcheck disable=SC2034
coordinator_model="claude-test-model"
# shellcheck disable=SC2034
cycle_dir="$tmp_dir/cycle"
mkdir -p "$cycle_dir"
# shellcheck disable=SC2034
ONCE=0
# shellcheck disable=SC2034
DRY_RUN=0
# shellcheck disable=SC2034
implementer_model_default="claude-fallback-model"
# shellcheck disable=SC2034
refinement_policy_json='{}'
# shellcheck disable=SC2034  # read by the eval'd fallback_select_candidate call
refinements_json='{}'
# shellcheck disable=SC2034  # read by the eval'd fallback_select_candidate call
pr_label="autonomous-agent"
# shellcheck disable=SC2034
noop_fingerprint_value="fp-abc123"
# shellcheck disable=SC2034  # read only by the eval'd coordinator_corroborate_and_fallback
coordinator_fit_trimmed_json="[]"

events_named() {  # events_named LOG NAME -> each matching event's JSON payload, one per line
  grep -E "^event $2 " <<<"$1" | sed -E "s/^event $2 //"
}

# eligible: two open tech-debt items this cycle, both unclaimed/unblocked/not void
eligible='[{"repo":"acme/widgets","item":"TD1","source":"tech-debt"},{"repo":"acme/widgets","item":"TD2","source":"tech-debt"}]'

# ordered_repos_json: one repo, a tech-debt band carrying both eligible items
# plus a security finding that outranks them, for the fallback band-order
# assertions below.
repos_with_security='[{"slug":"acme/widgets","default_branch":"main",
  "sources":["security","issues:urgent","review-feedback","merge-conflicts","human-visibility","abandoned-drafts","issues:high","tech-debt","issues:medium","issues:low","code-quality"],
  "findings":[{"source":"security","kind":"dependabot","severity":"high","ref":"dependabot-alert-1","title":"bump foo","package":"foo","url":"https://x/1"}],
  "review_feedback":[],"merge_conflicts":[],"abandoned_drafts":[],"human_visibility":[],"issues":[],
  "tech_debt":[{"source":"tech-debt","ref":"TD1","id":"TD1","title":"fix TD1","filed":"2026-08-01","url":"https://x/TD1.md","body":"TD1 body"},
               {"source":"tech-debt","ref":"TD2","id":"TD2","title":"fix TD2","filed":"2026-08-01","url":"https://x/TD2.md","body":"TD2 body"}]}]'
repos_tech_debt_only='[{"slug":"acme/widgets","default_branch":"main",
  "sources":["security","issues:urgent","review-feedback","merge-conflicts","human-visibility","abandoned-drafts","issues:high","tech-debt","issues:medium","issues:low","code-quality"],
  "findings":[],"review_feedback":[],"merge_conflicts":[],"abandoned_drafts":[],"human_visibility":[],"issues":[],
  "tech_debt":[{"source":"tech-debt","ref":"TD1","id":"TD1","title":"fix TD1","filed":"2026-08-01","url":"https://x/TD1.md","body":"TD1 body"},
               {"source":"tech-debt","ref":"TD2","id":"TD2","title":"fix TD2","filed":"2026-08-01","url":"https://x/TD2.md","body":"TD2 body"}]}]'

# ============================================================================
# fallback_select_candidate: band order and per-source shapes (unchanged by
# issue #587 — still the fleet-wide, no-model-call last resort)
# ============================================================================
sec_pick="$(fallback_select_candidate "$repos_with_security" "claude-fallback-model")"
assert_eq "security outranks tech-debt in the same repo" "security" "$(jq -r '.source' <<<"$sec_pick")"
assert_eq "security pick names the finding's own ref" "dependabot-alert-1" "$(jq -r '.item' <<<"$sec_pick")"

td_pick="$(fallback_select_candidate "$repos_tech_debt_only" "claude-fallback-model" '{}' '{}' "house-label")"
assert_eq "tech-debt is the fallback when no higher band has anything" "tech-debt" "$(jq -r '.source' <<<"$td_pick")"
assert_eq "tech-debt pick is the first eligible ref (id order)" "TD1" "$(jq -r '.item' <<<"$td_pick")"
assert_eq "a mechanical pick names its own model" "claude-fallback-model" "$(jq -r '.model' <<<"$td_pick")"
assert_contains "a mechanical pick's context pastes the item's own body" "TD1 body" "$(jq -r '.context' <<<"$td_pick")"
assert_eq "a mechanical pick carries the configured pr_label" "house-label" \
  "$(jq -r '.pr_label' <<<"$td_pick")"

lr_repos='[{"slug":"acme/widgets","default_branch":"main",
  "sources":["security","issues:urgent","review-feedback","merge-conflicts","dequeued","landing-refusals","human-visibility","abandoned-drafts","issues:high","tech-debt","issues:medium","issues:low","code-quality"],
  "findings":[],"review_feedback":[],"merge_conflicts":[],"dequeued":[],
  "landing_refusals":[{"ref":"pr-61-landing-refusal-4718691960","pr_number":61,"pr_url":"https://x/pull/61","title":"fix(cache): drop the stale key","branch":"agent/td26082401","body":"── human comment by warwickallen at 2026-08-24T01:00:00Z (id 4718691960)\nThis needs a note in the gotchas section."}],
  "abandoned_drafts":[],"human_visibility":[],"issues":[],
  "tech_debt":[{"source":"tech-debt","ref":"TD1","id":"TD1","title":"fix TD1","filed":"2026-08-01","url":"https://x/TD1.md","body":"TD1 body"}]}]'
lr_pick="$(fallback_select_candidate "$lr_repos" "m")"
assert_eq "landing-refusals outranks tech-debt in the mechanical walk" "landing-refusals" "$(jq -r '.source' <<<"$lr_pick")"
assert_eq "…and names the entry's own ref" "pr-61-landing-refusal-4718691960" "$(jq -r '.item' <<<"$lr_pick")"

empty_repos='[{"slug":"acme/widgets","default_branch":"main",
  "sources":["security","issues:urgent","review-feedback","merge-conflicts","human-visibility","abandoned-drafts","issues:high","tech-debt","issues:medium","issues:low","code-quality"],"findings":[],"review_feedback":[],"merge_conflicts":[],"abandoned_drafts":[],"human_visibility":[],"issues":[],"tech_debt":[]}]'
assert_eq "every band empty prints null, not a crash" "null" "$(fallback_select_candidate "$empty_repos" "m")"

# --- refinement_policy binds the mechanical pick as it binds the Co-Ordinator ---
td_and_hygiene='[{"slug":"acme/widgets","default_branch":"main",
  "sources":["security","issues:urgent","review-feedback","merge-conflicts","human-visibility","abandoned-drafts","issues:high","tech-debt","issues:medium","issues:low","code-quality"],
  "findings":[{"source":"code-quality","ref":"cq-1","kind":"lint","rule":"no-unused","location":"a.js:1","url":"https://x/cq","title":"unused var"}],
  "review_feedback":[],"merge_conflicts":[],"abandoned_drafts":[],"human_visibility":[],"issues":[],
  "tech_debt":[{"source":"tech-debt","ref":"TD1","id":"TD1","title":"fix TD1","filed":"2026-08-01","url":"https://x/TD1.md","body":"TD1 body"}]}]'
assert_eq "an unrefined item from a required source is skipped, and a lower band wins" \
  "code-quality" \
  "$(jq -r '.source' <<<"$(fallback_select_candidate "$td_and_hygiene" "m" '{}' '{"tech-debt":"required"}')")"

# --- `sources` bounds the mechanical pick exactly as it bounds the model ----
bp_repos="$(jq -c 'map(.issues = [] | .tech_debt = [])' \
  <<<"$(handoff_narrow_repos_to_finishing_sources "$repos_with_security")")"
assert_eq "a band narrowed out of sources is not a band the fallback may pick from" "null" \
  "$(fallback_select_candidate "$bp_repos" "m")"
assert_eq "…and the same repo with the token restored picks it again" "security" \
  "$(jq -r '.source' <<<"$(fallback_select_candidate "$repos_with_security" "m")")"

# ============================================================================
# run_coordinator_stage_attempt: launch, parse, and per-repo tagging mechanics
# ============================================================================
calls_log="$tmp_dir/calls-attempt.log"
: > "$calls_log"
STUB_CALL_N=0
STUB_QUEUE_RC_1=0
STUB_QUEUE_JSON_1='{"selected":false,"reason":"nothing here"}'
run_coordinator_stage_attempt "$cycle_dir/a1.out" "prompt one"
assert_eq "a call with no extra tag's stage_budget_apply carries the empty default" "1" \
  "$(grep -cE 'stage_budget_apply coordinator \* claude-test-model \{\}' "$calls_log")"
assert_eq "its stage-end is stage:coordinator, no repo field" "1" \
  "$(events_named "$(cat "$calls_log")" stage-end | jq -s '[.[] | select(.repo == null)] | length')"

: > "$calls_log"
STUB_CALL_N=0
STUB_QUEUE_RC_1=0
STUB_QUEUE_JSON_1='{"selected":true}'
run_coordinator_stage_attempt "$cycle_dir/a2.out" "prompt two" '{"repo": "acme/widgets"}'
assert_contains "a per-repo call's stage_budget_apply still carries the fleet-wide budget key" \
  'stage_budget_apply coordinator * claude-test-model {"repo": "acme/widgets"}' "$(cat "$calls_log")"
se_evt="$(events_named "$(cat "$calls_log")" stage-end | head -n1)"
assert_eq "its stage-end carries the repo tag" "acme/widgets" "$(jq -r '.repo' <<<"$se_evt")"
assert_eq "…and this attempt's own cost fields" "0.05" "$(jq -r '.cost_usd' <<<"$se_evt")"

: > "$calls_log"
STUB_CALL_N=0
STUB_QUEUE_RC_1=1
if run_coordinator_stage_attempt "$cycle_dir/a3.out" "prompt three"; then
  fn_rc=0
else
  fn_rc=1
fi
assert_eq "a launch failure returns non-zero" "1" "$fn_rc"
assert_contains "…and calls handle_stage_failure" "handle_stage_failure coordinator 1" "$(cat "$calls_log")"

: > "$calls_log"
STUB_CALL_N=0
# shellcheck disable=SC2034  # read only by the stubbed run_claude_stage
STUB_QUEUE_RC_1=0
# shellcheck disable=SC2034
STUB_QUEUE_JSON_1=""
if run_coordinator_stage_attempt "$cycle_dir/a4.out" "prompt four"; then
  fn_rc=0
else
  fn_rc=1
fi
assert_eq "an unparseable message returns non-zero" "1" "$fn_rc"
assert_contains "…and logs attempt-failed naming it" "unparseable final message" "$(cat "$calls_log")"

# ============================================================================
# coordinator_merge_candidates: requirement 15z — the Script's own
# cross-repository reconciliation, in place of the single completion that
# used to see every repo at once
# ============================================================================
# Two repos, walk order 0 (acme/a, most overdue) then 1 (acme/b): a's own
# issues array marks item "9" Urgent, everything else Medium/unbanded.
merge_repos='[
  {"slug":"acme/a","issues":[{"ref":"9","priority":"Urgent"},{"ref":"5","priority":"Medium"}]},
  {"slug":"acme/b","issues":[{"ref":"9","priority":"Medium"}]}
]'

# --- Security always wins, regardless of repo order or rank -----------------
sec_over_tier="$(jq -c --null-input '[
  {"repo":"acme/b","source":"tech-debt","item":"TD1","_repo_order":1,"_rank":0},
  {"repo":"acme/a","source":"security","item":"dependabot-1","_repo_order":0,"_rank":5}
]')"
assert_eq "security tier wins even ranked last within its own repo" "dependabot-1" \
  "$(jq -r '.[0].item' <<<"$(coordinator_merge_candidates "$sec_over_tier" "$merge_repos" 3)")"

# --- Urgent issues (tier 1) outrank the finishing sources (tiers 2-5) -------
urgent_over_finishing="$(jq -c --null-input '[
  {"repo":"acme/b","source":"review-feedback","item":"pr-1","_repo_order":1,"_rank":0},
  {"repo":"acme/a","source":"issues","item":"9","_repo_order":0,"_rank":0}
]')"
assert_eq "an Urgent issue outranks review-feedback from a later-walk-order repo" "9" \
  "$(jq -r '.[0].item' <<<"$(coordinator_merge_candidates "$urgent_over_finishing" "$merge_repos" 3)")"
# The same item ref, "9", is Medium in acme/b — proving the tier lookup reads
# the *candidate's own repository's* issues array, never the other one's.
medium_in_b="$(jq -c --null-input '[{"repo":"acme/b","source":"issues","item":"9","_repo_order":1,"_rank":0}]')"
assert_eq "the identical ref is not Urgent in the repo where it is not" "1" \
  "$(jq '.[0]._repo_order // 999' <<<"$medium_in_b")"

# --- The six named tiers, in the prompt's own order -------------------------
all_tiers="$(jq -c --null-input '[
  {"repo":"acme/b","source":"abandoned-drafts","item":"ad","_repo_order":1,"_rank":0},
  {"repo":"acme/b","source":"dequeued","item":"dq","_repo_order":1,"_rank":0},
  {"repo":"acme/b","source":"merge-conflicts","item":"mc","_repo_order":1,"_rank":0},
  {"repo":"acme/b","source":"review-feedback","item":"rf","_repo_order":1,"_rank":0},
  {"repo":"acme/a","source":"issues","item":"9","_repo_order":0,"_rank":0},
  {"repo":"acme/b","source":"security","item":"sec","_repo_order":1,"_rank":0}
]')"
assert_eq "the six cross-repository tiers sort in the prompt's own order" \
  "sec 9 rf mc dq ad" \
  "$(jq -r '[.[].item] | join(" ")' <<<"$(coordinator_merge_candidates "$all_tiers" "$merge_repos" 6)")"

# --- The residual tier: repo order alone decides, whichever source either candidate is ---
residual="$(jq -c --null-input '[
  {"repo":"acme/b","source":"tech-debt","item":"TD-b","_repo_order":1,"_rank":0},
  {"repo":"acme/a","source":"human-visibility","item":"hv-a","_repo_order":0,"_rank":0}
]')"
assert_eq "residual-tier candidates order by repository walk order alone" "hv-a TD-b" \
  "$(jq -r '[.[].item] | join(" ")' <<<"$(coordinator_merge_candidates "$residual" "$merge_repos" 3)")"

# --- Same tier, different repos: repository walk order breaks the tie ------
sec_tie="$(jq -c --null-input '[
  {"repo":"acme/b","source":"security","item":"sec-b","_repo_order":1,"_rank":0},
  {"repo":"acme/a","source":"security","item":"sec-a","_repo_order":0,"_rank":0}
]')"
assert_eq "two same-tier candidates from different repos: the more-overdue repo wins" "sec-a" \
  "$(jq -r '.[0].item' <<<"$(coordinator_merge_candidates "$sec_tie" "$merge_repos" 3)")"

# --- Same repo, same tier: that repo's own rank breaks the tie --------------
rank_tie="$(jq -c --null-input '[
  {"repo":"acme/a","source":"tech-debt","item":"TD-second","_repo_order":0,"_rank":1},
  {"repo":"acme/a","source":"tech-debt","item":"TD-first","_repo_order":0,"_rank":0}
]')"
assert_eq "within one repo's own tier, its own rank decides" "TD-first" \
  "$(jq -r '.[0].item' <<<"$(coordinator_merge_candidates "$rank_tie" "$merge_repos" 3)")"

# --- candidates_max caps the merged result, not each repo's own return -----
many="$(jq -c --null-input '[
  {"repo":"acme/a","source":"tech-debt","item":"a1","_repo_order":0,"_rank":0},
  {"repo":"acme/a","source":"tech-debt","item":"a2","_repo_order":0,"_rank":1},
  {"repo":"acme/b","source":"tech-debt","item":"b1","_repo_order":1,"_rank":0},
  {"repo":"acme/b","source":"tech-debt","item":"b2","_repo_order":1,"_rank":1}
]')"
assert_eq "four raw candidates across two repos, capped to candidates_max=2" "2" \
  "$(jq 'length' <<<"$(coordinator_merge_candidates "$many" "$merge_repos" 2)")"
assert_eq "…keeping the more-overdue repo's own two, not one from each" "a1 a2" \
  "$(jq -r '[.[].item] | join(" ")' <<<"$(coordinator_merge_candidates "$many" "$merge_repos" 2)")"

# --- Internal tags never leak onto the merged result ------------------------
assert_eq "no internal ranking key leaks onto a merged candidate" "null null null" \
  "$(jq -r '.[0] | [(._tier // "null"), (._repo_order // "null"), (._rank // "null")] | join(" ")' \
     <<<"$(coordinator_merge_candidates "$rank_tie" "$merge_repos" 3)")"

# --- Malformed input degrades safely, never a crash -------------------------
assert_eq "a non-array candidates argument degrades to an empty result" "0" \
  "$(jq 'length' <<<"$(coordinator_merge_candidates 'not json' "$merge_repos" 3)")"
assert_eq "a non-array repos argument still merges by tier/rank alone" "TD-first" \
  "$(jq -r '.[0].item' <<<"$(coordinator_merge_candidates "$rank_tie" 'not json' 3)")"
assert_eq "a non-numeric candidates_max degrades to the documented default (3)" "3" \
  "$(jq 'length' <<<"$(coordinator_merge_candidates "$many" "$merge_repos" 'not-a-number')")"

# ============================================================================
# coordinator_corroborate_and_fallback: corroboration scoped to the
# repositories that said no, then mechanical fallback (requirements 3v/3t/3x)
# ============================================================================

# run_corroborate DESC FALSE_REPOS REASON RECORDED_REFINEMENT RECORDED_VOIDED \
#                  ELIGIBLE_JSON ELIGIBLE_TOTAL ORDERED_REPOS_JSON
# Sets `fn_rc` and prints the accumulated calls log.
run_corroborate() {
  calls_log="$tmp_dir/calls-$RANDOM.log"
  : > "$calls_log"
  # shellcheck disable=SC2034  # read only by the eval'd function
  eligible_items_json="$6"
  # shellcheck disable=SC2034
  eligible_items_total="$7"
  # shellcheck disable=SC2034
  ordered_repos_json="$8"
  if coordinator_corroborate_and_fallback "$2" "$3" "$4" "$5"; then
    fn_rc=0
  else
    fn_rc=1
  fi
  cat "$calls_log"
}

# --- A repo that selected needs no corroboration: its own eligible items,
#     unaccounted, must not trigger a rejection --------------------------
# Two repos' worth of eligible items; acme/a (which selected) left TD1
# unaccounted, but acme/a is *not* in the false-repos list, so this must not
# be flagged. acme/b (the only false repo) has nothing eligible at all.
scoped_eligible='[{"repo":"acme/a","item":"TD1","source":"tech-debt"}]'
run_corroborate "selected repo excluded" '["acme/b"]' "acme/b: nothing here" '[]' '[]' \
  "$scoped_eligible" 1 "$repos_tech_debt_only" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"
assert_eq "a selected repository's own unaccounted item is not corroborated against" "0" \
  "$(grep -cE '^event corroboration ' <<<"$calls")"
assert_eq "…so the cycle stands down clean, with a fingerprint" "1" \
  "$(events_named "$calls" none-selected | jq -s '[.[] | select(.fingerprint == "fp-abc123")] | length')"
assert_eq "…and function returns 1 (caller should exit)" "1" "$fn_rc"

# --- The false repo's own unaccounted item is rejected, and the mechanical
#     fallback fires and finds it -----------------------------------------
run_corroborate "false repo rejected, fallback fires" '["acme/widgets"]' "acme/widgets: nothing here" \
  '[]' '[]' "$eligible" 2 "$repos_tech_debt_only" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"
assert_eq "false repo rejected: one corroboration event, rejected" "rejected" \
  "$(events_named "$calls" corroboration | head -n1 | jq -r '.verdict')"
assert_eq "…attempt is always 1 now — there is no retry to distinguish it from" "1" \
  "$(events_named "$calls" corroboration | head -n1 | jq -r '.attempt')"
assert_eq "…no none-selected — the cycle selected something via fallback" "0" \
  "$(grep -cE '^event none-selected ' <<<"$calls")"
assert_eq "…function returns 0 (candidates_json ready)" "0" "$fn_rc"
# shellcheck disable=SC2154  # candidates_json: set by the eval'd coordinator_corroborate_and_fallback
assert_eq "…candidates_json is the mechanical pick" "TD1" "$(jq -r '.[0].item' <<<"$candidates_json")"
# shellcheck disable=SC2154  # set by the eval'd coordinator_corroborate_and_fallback
assert_eq "…selected_by_fallback is armed" "1" "$selected_by_fallback"

# --- The false repo's own report fully accounts for its band: clean stand-down ---
accounted_recorded='[{"repo":"acme/widgets","item":"TD1","source":"tech-debt","reason":"r","missing":"m","evidence":"e"},
  {"repo":"acme/widgets","item":"TD2","source":"tech-debt","reason":"r","missing":"m","evidence":"e"}]'
run_corroborate "false repo fully accounted" '["acme/widgets"]' "acme/widgets: all reported" \
  "$accounted_recorded" '[]' "$eligible" 2 "$repos_tech_debt_only" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"
assert_eq "fully accounted: corroboration accepted" "accepted" \
  "$(events_named "$calls" corroboration | head -n1 | jq -r '.verdict')"
assert_eq "…no fallback call (fallback_select_candidate never reached)" "0" \
  "$(grep -cE '^run_claude_stage ' <<<"$calls")"
assert_eq "…one none-selected, carrying the fingerprint" "fp-abc123" \
  "$(events_named "$calls" none-selected | head -n1 | jq -r '.fingerprint')"
assert_eq "…and no td_verdict_rejected on a cleanly-accepted stand-down" "null" \
  "$(events_named "$calls" none-selected | head -n1 | jq -r '.td_verdict_rejected // null')"
assert_eq "…function returns 1 (caller should exit)" "1" "$fn_rc"

# --- Fallback finds nothing: the branch that carries td_verdict_rejected ---
run_corroborate "fallback finds nothing" '["acme/widgets"]' "acme/widgets: nothing here" \
  '[]' '[]' "$eligible" 2 "$empty_repos" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"
assert_eq "fallback finds nothing: function returns 1 (caller should exit)" "1" "$fn_rc"
ns_evt="$(events_named "$calls" none-selected | head -n1)"
assert_eq "…td_verdict_rejected:true" "true" "$(jq -r '.td_verdict_rejected' <<<"$ns_evt")"
assert_eq "…carries the unaccounted bands tally" '{"tech-debt":2}' "$(jq -c '.bands' <<<"$ns_evt")"
assert_eq "…and no fingerprint, so the next cycle asks again" "null" \
  "$(jq -r '.fingerprint // null' <<<"$ns_evt")"

# --- Every configured repository said no, and every one of their own bands
#     is genuinely empty: no corroboration event fires at all -------------
run_corroborate "genuinely nothing eligible" '["acme/widgets"]' "acme/widgets: nothing here" \
  '[]' '[]' '[]' 0 "$empty_repos" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"
assert_eq "nothing eligible: no corroboration event (nothing to corroborate)" "0" \
  "$(grep -cE '^event corroboration ' <<<"$calls")"
assert_eq "…one none-selected, no td_verdict_rejected" "null" \
  "$(events_named "$calls" none-selected | head -n1 | jq -r '.td_verdict_rejected // null')"

# ============================================================================
# The gate is no longer tech-debt-only (requirement 3x, issue #322),
# now scoped to the repositories that said no (issue #587)
# ============================================================================
issues_repos='[{"slug":"acme/widgets","default_branch":"main","sources":["issues:high","review-feedback"],
  "findings":[],
  "review_feedback":[{"source":"review-feedback","ref":"pr-57-review-1","pr_number":57,"pr_url":"https://x/pull/57","title":"fix x","branch":"agent/x","body":"review body"}],
  "merge_conflicts":[],"abandoned_drafts":[],"human_visibility":[],
  "issues":[{"source":"issues","ref":"11","number":11,"priority":"High","title":"an issue","body":"b","comments":[]}],
  "tech_debt":[]}]'
mixed_eligible='[{"repo":"acme/widgets","item":"11","source":"issues"},
                 {"repo":"acme/widgets","item":"pr-57-review-1","source":"review-feedback"}]'

run_corroborate "issues band confabulated away" '["acme/widgets"]' "acme/widgets: no candidates in any source" \
  '[]' '[]' "$mixed_eligible" 2 "$issues_repos" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"
c1="$(events_named "$calls" corroboration | head -n1)"
assert_eq "a silent verdict over a non-empty issues band is rejected" "rejected" "$(jq -r '.verdict' <<<"$c1")"
assert_eq "…counting both bands in eligible_total" "2" "$(jq -r '.eligible_total' <<<"$c1")"
assert_eq "…and tagging the rejection with each band's own share" '{"issues":1,"review-feedback":1}' \
  "$(jq -c '.bands' <<<"$c1")"
w1="$(events_named "$calls" warning | head -n1)"
assert_contains "…and the warning names the bands rather than just a count" \
  "issues 1, review-feedback 1" "$(jq -r '.detail' <<<"$w1")"
# shellcheck disable=SC2154  # candidates_json: set by the eval'd coordinator_corroborate_and_fallback
assert_eq "rejected, so the fallback picks the highest reachable band" "review-feedback" \
  "$(jq -r '.[0].source' <<<"$candidates_json")"

# A report under the wrong `source` is not an account: the same ref, filed
# against the wrong band, leaves the band it was actually eligible in exactly
# as unaccounted as silence would.
wrong_band_recorded='[{"repo":"acme/widgets","item":"11","source":"tech-debt","reason":"r","missing":"m","evidence":"e"},
  {"repo":"acme/widgets","item":"pr-57-review-1","source":"review-feedback","reason":"r","missing":"m","evidence":"e"}]'
run_corroborate "wrong band" '["acme/widgets"]' "acme/widgets: reported" \
  "$wrong_band_recorded" '[]' "$mixed_eligible" 2 "$issues_repos" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"
c1="$(events_named "$calls" corroboration | head -n1)"
assert_eq "a report filed under the wrong source accounts for nothing" '{"issues":1}' \
  "$(jq -c '.bands' <<<"$c1")"

# Every band accounted for, across two different arrays and by two different
# routes — the clean stand-down, fingerprint armed.
accounted_recorded_ref='[{"repo":"acme/widgets","item":"11","source":"issues","reason":"r","missing":"m","evidence":"e"}]'
accounted_recorded_void='[{"repo":"acme/widgets","item":"pr-57-review-1","reason":"already answered","evidence":"e"}]'
run_corroborate "every band accounted" '["acme/widgets"]' "acme/widgets: all reported" \
  "$accounted_recorded_ref" "$accounted_recorded_void" "$mixed_eligible" 2 "$issues_repos" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"
assert_eq "a per-item verdict in each band is corroborated" "1" \
  "$(events_named "$calls" corroboration | jq -s '[.[] | select(.verdict == "accepted")] | length')"
assert_eq "…so no fallback call is bought" "0" "$(grep -cE '^run_claude_stage ' <<<"$calls")"
assert_eq "…and the none-selected carries the fingerprint" "fp-abc123" \
  "$(events_named "$calls" none-selected | head -n1 | jq -r '.fingerprint')"

# --- The argv cap (requirement 4g, TD-PPagop-26081401) ----------------------
# $unaccounted_json used to ride into jq as a second --argjson at the
# warning/corroboration call sites — an argv entry capped at MAX_ARG_STRLEN
# (131072 bytes). This is the very event the crash-loop ladder and the
# dashboard read, so losing it here is as loud as losing the void extract
# was. 3000 unclaimed tech-debt items, none of them reported back, produces
# an unaccounted array past the cap.
big_n=3000
big_eligible="$(jq -nc --argjson n "$big_n" \
  '[range(1; $n + 1) | {repo: "acme/widgets", item: ("TD" + (. | tostring)), source: "tech-debt"}]')"
assert_eq "the oversized eligible fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_eligible" | wc -c) > 131072 ))"

run_corroborate "oversized unaccounted set" '["acme/widgets"]' "acme/widgets: nothing here" \
  '[]' '[]' "$big_eligible" "$big_n" "$empty_repos" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"
w1="$(events_named "$calls" warning | head -n1)"
assert_eq "the warning still carries every one of the 3000 unaccounted items" \
  "$big_n" "$(jq '.unaccounted | length' <<<"$w1")"
c1="$(events_named "$calls" corroboration | head -n1)"
assert_eq "the corroboration event agrees, and is rejected, not silently swallowed" "$big_n" \
  "$(jq '.unaccounted | length' <<<"$c1")"
assert_eq "  ... rejected" "rejected" "$(jq -r '.verdict' <<<"$c1")"

# --- The argv cap, the recorded side (requirement 4g, TD-PPagop-26081406) ---
# The recorded-refinement/voided union built inside
# coordinator_corroborate_and_fallback feeds unaccounted_items — past
# MAX_ARG_STRLEN, an --argjson build here died at execve and unaccounted_items
# was handed "", which fail-opens to `[]` and reports zero unaccounted items
# exactly when there is the most recorded refinement to account for (the
# original incident this pins).
big_recorded_refinement="$(jq -c '[.[] | {repo, item, source,
  reason: "r", missing: "m", evidence: "e"}]' <<<"$big_eligible")"
assert_eq "the recorded-refinement fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_recorded_refinement" | wc -c) > 131072 ))"

run_corroborate "oversized recorded set, fully accounted" '["acme/widgets"]' "acme/widgets: reported every item" \
  "$big_recorded_refinement" '[]' "$big_eligible" "$big_n" "$empty_repos" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"
c1="$(events_named "$calls" corroboration | head -n1)"
assert_eq "every one of the 3000 recorded reports is read back, past the argv cap, and accounted for" \
  "0" "$(jq '.unaccounted_total' <<<"$c1")"
assert_eq "  ... so the verdict is accepted" "accepted" "$(jq -r '.verdict' <<<"$c1")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
