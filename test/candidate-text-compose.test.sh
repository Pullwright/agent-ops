#!/usr/bin/env bash
#
# test/candidate-text-compose.test.sh — regression test for `item_live_entry`
# and `compose_selected_candidate_text` (requirement 17h, agent-ops#769,
# resolving agent-ops#844 option (b)).
#
# The owner decision on #844 chose option (b): the Script composes
# `context`/`acceptance`/`title` for the one item the Co-Ordinator (or the
# mechanical fallback, requirement 3v) selects, rather than trusting a model
# running on the fleet's cheapest tier to paste kilobytes of text its own
# input trimming may already have removed. `compose_selected_candidate_text`
# is where that happens: a live fetch for `issues`/`tech-debt` (the only two
# bands the fit ladder — lib/coordinator-input.sh — ever trims), the
# never-trimmed pre-fetched band entry for every other source the Script
# already gathers as structured data, and nothing at all — a deliberate
# no-op — for the three sources the Co-Ordinator still derives itself live
# (`project-review`, `failed-runs`, `implementation-plan`), which have no
# band entry to compose from in the first place.
#
# The functions are lifted verbatim out of lib/candidate-select.sh, the way
# test/refinement-traceability.test.sh lifts its own, so the assertions are
# about the shipped code rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/candidate-text-compose.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_CYCLE="$SCRIPT_DIR/agent-cycle.sh"
CANDIDATE_SELECT="$SCRIPT_DIR/lib/candidate-select.sh"

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
assert_empty() { assert_eq "$1" "" "$2"; }
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:              %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

extract_block() {
  local start_re="$1" end_re="$2" file="$3"
  BLOCK_START_RE="$start_re" BLOCK_END_RE="$end_re" awk '
    $0 ~ ENVIRON["BLOCK_START_RE"] { on = 1 }
    on                             { print }
    on && $0 ~ ENVIRON["BLOCK_END_RE"] { exit }
  ' "$file"
}

# _traceability_normalize and refinement_traceability_repair are called
# directly by compose_selected_candidate_text, so both must be lifted too.
for fn in _traceability_normalize refinement_traceability_repair; do
  block="$(extract_block "^${fn}\\(\\) \\{" '^\}$' "$CANDIDATE_SELECT")"
  if [[ -z "$block" ]]; then
    echo "FAIL - could not extract $fn from lib/candidate-select.sh — has it moved?" >&2
    exit 1
  fi
  eval "$block"
done

for fn in item_live_entry compose_selected_candidate_text; do
  block="$(extract_block "^${fn}\\(\\) \\{" '^\}$' "$CANDIDATE_SELECT")"
  if [[ -z "$block" ]]; then
    echo "FAIL - could not extract $fn from lib/candidate-select.sh — has it moved?" >&2
    exit 1
  fi
  eval "$block"
done

for var in CANDIDATE_ENTRY_LOOKUP_JQ CANDIDATE_TEMPLATE_JQ; do
  block="$(extract_block "^${var}='" "^'\$" "$CANDIDATE_SELECT")"
  if [[ -z "$block" ]]; then
    echo "FAIL - could not extract $var from lib/candidate-select.sh — has it moved?" >&2
    exit 1
  fi
  eval "$block"
done

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

GH_CALLS_FILE="$T/gh_calls"
GH_API_ARGS_FILE="$T/gh_api_args"
# item_live_entry makes two gh calls: `gh issue view --json title,body` for
# GH_META_JSON, and `gh api …/comments --paginate --jq …` for the thread —
# the shape agent-ops#1012 moved comments onto, off the unpaginated
# `gh issue view --json comments` GraphQL field.
#
# GH_COMMENT_PAGES holds *raw* REST comment objects, one compact page array
# per line, exactly as `repos/<o>/<r>/issues/<n>/comments` returns them; the
# mock applies the caller's own `--jq` filter to each page in turn and prints
# its elements one per line, which is what `gh api --paginate --jq` does. The
# filter is therefore exercised rather than stood in for, so the REST field
# mapping the migration turns on (`.user.login` → `author`, `.created_at` —
# not GraphQL's `.author.login`/`.createdAt`) is what the assertions below
# actually pin, and multiple pages are concatenated for real.
GH_META_JSON=""
GH_COMMENT_PAGES=""
GH_RC=0      # `gh issue view` — the title/body read
GH_API_RC=0  # `gh api …/comments` — the paginated thread read
# shellcheck disable=SC2317  # reached only from the lifted item_live_entry block.
gh() {
  printf 'x' >>"$GH_CALLS_FILE"
  if [[ "$1" == "api" ]]; then
    printf '%s\n' "$*" >>"$GH_API_ARGS_FILE"
    [[ "$GH_API_RC" == "0" ]] || return "$GH_API_RC"
    local arg prev="" filter="" page
    for arg in "$@"; do
      [[ "$prev" == "--jq" ]] && filter="$arg"
      prev="$arg"
    done
    while IFS= read -r page; do
      [[ -n "$page" ]] || continue
      jq -c "$filter" <<<"$page" || return 1
    done <<<"$GH_COMMENT_PAGES"
    return 0
  fi
  [[ "$GH_RC" == "0" ]] || return "$GH_RC"
  printf '%s' "$GH_META_JSON"
}
gh_calls() { [[ -f "$GH_CALLS_FILE" ]] && wc -c <"$GH_CALLS_FILE" | tr -d ' ' || printf '0'; }
reset_gh_calls() { rm -f "$GH_CALLS_FILE" "$GH_API_ARGS_FILE"; }
gh_api_args() { [[ -f "$GH_API_ARGS_FILE" ]] || return 0; cat "$GH_API_ARGS_FILE"; }

GUARD_WARN_CALLS_FILE="$T/guard_warn_calls"
# shellcheck disable=SC2317  # reached only from the lifted compose block.
guard_warn() { printf '%s\t%s\n' "$1" "$2" >>"$GUARD_WARN_CALLS_FILE"; }
guard_warn_calls() { [[ -f "$GUARD_WARN_CALLS_FILE" ]] && wc -l <"$GUARD_WARN_CALLS_FILE" | tr -d ' ' || printf '0'; }

# --- item_live_entry ----------------------------------------------------------

reset_gh_calls
GH_RC=0; GH_API_RC=0
GH_META_JSON='{"title":"Live title","body":"Live body, fetched fresh"}'
GH_COMMENT_PAGES='[{"id":1,"user":{"login":"alice"},"created_at":"2026-08-01T00:00:00Z","body":"first comment"}]'
live_out="$(item_live_entry "o/r" "issues" "42")"
assert_eq "item_live_entry (issues) prints the fetched title" "Live title" "$(jq -r '.title' <<<"$live_out")"
assert_eq "…and body" "Live body, fetched fresh" "$(jq -r '.body' <<<"$live_out")"
assert_eq "…and each comment's author/created_at/body, mapped off the REST fields" \
  "alice/2026-08-01T00:00:00Z/first comment" \
  "$(jq -r '[.comments[0].author, .comments[0].created_at, .comments[0].body] | join("/")' <<<"$live_out")"
assert_eq "…exactly two gh calls: gh issue view (title/body), gh api …/comments (paginated)" "2" "$(gh_calls)"
assert_contains "…the comments call is the paginated REST endpoint, not gh issue view --json comments" \
  "$(gh_api_args)" "repos/o/r/issues/42/comments --paginate"

live_out_td="$(item_live_entry "o/r" "tech-debt" "42")"
assert_eq "item_live_entry (tech-debt) fetches identically to issues — both are GitHub issues since D15" \
  "$live_out" "$live_out_td"

assert_eq "item_live_entry refuses an unrecognised source" "1" \
  "$(item_live_entry "o/r" "review-feedback" "42" >/dev/null 2>&1; echo $?)"

# --- item_live_entry: a thread past gh's ~100-comment --json ceiling is not --
# --- silently truncated (agent-ops#1012, TD-PPagop-26082808) ----------------
#
# `gh issue view --json comments` fetches only the first ~100 comments via
# GraphQL and does not paginate; the paginated REST endpoint this function
# now uses has no such ceiling. 150 mocked comments, split across two pages
# the way the real endpoint's own 100-per-page maximum would split them,
# stands in for "more than the old ceiling" without needing a real
# >100-comment thread — the second page is entirely past where the GraphQL
# field would have stopped.

reset_gh_calls
GH_RC=0; GH_API_RC=0
GH_META_JSON='{"title":"Long-running thread","body":"Original body"}'
GH_COMMENT_PAGES="$(jq -nc '
  def c: {id: ., user: {login: "bot"}, created_at: "2026-01-01T00:00:00Z",
          body: ("comment " + (. | tostring))};
  [range(0; 100) | c], [range(100; 150) | c]')"
live_out_long="$(item_live_entry "o/r" "issues" "99")"
assert_eq "item_live_entry returns every comment past the old ~100-comment ceiling" "150" \
  "$(jq -r '.comments | length' <<<"$live_out_long")"
assert_eq "…in thread order, page boundary included" "comment 99 comment 100" \
  "$(jq -r '.comments[99].body + " " + .comments[100].body' <<<"$live_out_long")"
assert_eq "…including the last one, which a truncated fetch would have dropped" "comment 149" \
  "$(jq -r '.comments[-1].body' <<<"$live_out_long")"

# --- item_live_entry: the two edges either side of the happy path ------------
#
# An issue with no comments at all is by far the commonest real shape, and it
# is the one the `--paginate --jq` stream expresses as *no output whatsoever*
# rather than an empty array — so it is the slurp, not the endpoint, that has
# to turn it back into `comments: []`. And a comments fetch that fails once
# the title/body read has already succeeded is the error path the split call
# added: it must fail the whole function, never return a plausible entry
# carrying a silently empty thread, which is the very truncation this change
# exists to remove.

reset_gh_calls
GH_RC=0; GH_API_RC=0
GH_META_JSON='{"title":"Freshly filed","body":"Nobody has replied yet"}'
GH_COMMENT_PAGES='[]'
live_out_none="$(item_live_entry "o/r" "issues" "7")"
assert_eq "item_live_entry on a comment-less issue succeeds" "0" "$?"
assert_eq "…with comments an empty array, not absent or null" "[]" \
  "$(jq -c '.comments' <<<"$live_out_none")"
assert_eq "…and the body still intact" "Nobody has replied yet" "$(jq -r '.body' <<<"$live_out_none")"

reset_gh_calls
GH_RC=0; GH_API_RC=1
assert_eq "item_live_entry fails when the comments fetch fails, though title/body succeeded" "1" \
  "$(item_live_entry "o/r" "issues" "42" >/dev/null 2>&1; echo $?)"
reset_gh_calls
GH_RC=0; GH_API_RC=1
assert_empty "…printing nothing — never an entry with a silently empty thread" \
  "$(item_live_entry "o/r" "issues" "42" 2>/dev/null)"
GH_API_RC=0

# --- compose_selected_candidate_text: the three self-derived sources are a --
# --- deliberate no-op, never a fault -----------------------------------------

reset_gh_calls
for src in project-review failed-runs implementation-plan; do
  cand="$(jq -nc --arg s "$src" '{repo:"o/r", item:"R-01", source:$s, context:"model wrote this", acceptance:"model wrote this too"}')"
  compose_selected_candidate_text "$cand" '[]' '{}' >/dev/null
  rc=$?
  assert_eq "compose_selected_candidate_text no-ops for self-derived source $src" "2" "$rc"
done
assert_eq "…and none of them cost a gh call" "0" "$(gh_calls)"

# --- compose_selected_candidate_text: issues, live fetch succeeds -----------

repos='[{"slug":"o/r","issues":[{"number":42,"ref":"42","title":"Trimmed title","body":"…[Script: elided 900 of 1000 bytes to fit the context window — read it whole at https://x]","comments":[]}]}]'
refinements='{}'
cand='{"repo":"o/r","default_branch":"main","pr_label":"autonomous-agent","source":"issues","item":"42","model":"claude-sonnet-5","model_reason":"stub","context":"model-authored, and possibly wrong","acceptance":"model-authored too"}'

reset_gh_calls
GH_RC=0
GH_META_JSON='{"title":"The real, untrimmed title","body":"The real, untrimmed body"}'
GH_COMMENT_PAGES='[{"id":1,"user":{"login":"bob"},"created_at":"2026-08-02T00:00:00Z","body":"a real comment"}]'
out="$(compose_selected_candidate_text "$cand" "$repos" "$refinements")"
rc=$?
assert_eq "compose_selected_candidate_text (issues) succeeds" "0" "$rc"
assert_eq "…exactly two gh calls (the live fetch: title/body, then paginated comments)" "2" "$(gh_calls)"
assert_contains "…context carries the live, untrimmed body" "$(jq -r '.context' <<<"$out")" "The real, untrimmed body"
assert_contains "…and the live comment, attributed" "$(jq -r '.context' <<<"$out")" "bob (2026-08-02T00:00:00Z):
a real comment"
assert_eq "…never the trimmed band entry's elision marker" "" \
  "$(jq -r '.context' <<<"$out" | grep -o 'Script: elided' || true)"
assert_eq "…title is rebuilt from the live read" "Issue #42: The real, untrimmed title" "$(jq -r '.title' <<<"$out")"
assert_eq "…acceptance is the deterministic per-source instruction, not the model's own" \
  "Resolve per the current state of the issue thread above (body and every comment), not just the opening post." \
  "$(jq -r '.acceptance' <<<"$out")"
assert_eq "…every structural field survives unchanged" "o/r main autonomous-agent issues 42 claude-sonnet-5 stub" \
  "$(jq -r '[.repo, .default_branch, .pr_label, .source, .item, .model, .model_reason] | join(" ")' <<<"$out")"

# --- compose_selected_candidate_text: the recorded refinement is spliced in,
# --- unconditionally, generalising #767 rather than checking for it --------

reset_gh_calls
refinements_with_spec='{"o/r":{"42":{"spec":"The Refiner'"'"'s own specification for this item."}}}'
out_spec="$(compose_selected_candidate_text "$cand" "$repos" "$refinements_with_spec")"
assert_contains "the recorded refinement spec is spliced into the freshly composed context" \
  "$(jq -r '.context' <<<"$out_spec")" "The Refiner's own specification for this item."

# --- compose_selected_candidate_text: tech-debt is composed from the whole ---
# --- live thread, not the body alone -----------------------------------------
#
# A tech-debt item has been a GitHub issue since the register's D15 migration,
# so a clarification or scope cut left in one of its comments is exactly the
# text agent-ops#769 exists to stop losing. `fallback_select_candidate`'s own
# `td_cands` reduces the entry to its `body`, because it has only the band
# entry to compose from; this path holds the whole thread and must use it.

repos_td='[{"slug":"o/r","tech_debt":[{"number":42,"ref":"42","title":"TD title","body":"…[Script: elided 900 of 1000 bytes to fit the context window — read it whole at https://x]","comments":[]}]}]'
cand_td='{"repo":"o/r","default_branch":"main","pr_label":"autonomous-agent","source":"tech-debt","item":"42","model":"claude-sonnet-5","model_reason":"stub"}'

reset_gh_calls
GH_RC=0
GH_META_JSON='{"title":"The real record title","body":"The real record body"}'
GH_COMMENT_PAGES='[{"id":1,"user":{"login":"carol"},"created_at":"2026-08-03T00:00:00Z","body":"on reflection, only fix the first half"}]'
out_td="$(compose_selected_candidate_text "$cand_td" "$repos_td" "$refinements")"
rc=$?
assert_eq "compose_selected_candidate_text (tech-debt) succeeds" "0" "$rc"
assert_eq "…exactly two gh calls (the live fetch: title/body, then paginated comments)" "2" "$(gh_calls)"
assert_contains "…context carries the live, untrimmed body" "$(jq -r '.context' <<<"$out_td")" "The real record body"
assert_contains "…and every comment, attributed — a scope cut left in one is not dropped" \
  "$(jq -r '.context' <<<"$out_td")" "carol (2026-08-03T00:00:00Z):
on reflection, only fix the first half"
assert_eq "…never the trimmed band entry's elision marker" "" \
  "$(jq -r '.context' <<<"$out_td" | grep -o 'Script: elided' || true)"
assert_eq "…title is the record's own, unprefixed" "The real record title" "$(jq -r '.title' <<<"$out_td")"
assert_contains "…acceptance names the current state of the thread, not the record as filed" \
  "$(jq -r '.acceptance' <<<"$out_td")" "body and every comment"

# --- compose_selected_candidate_text: a failed live fetch is fail-closed ---

reset_gh_calls
GH_RC=1
out_fail="$(compose_selected_candidate_text "$cand" "$repos" "$refinements")"
rc=$?
assert_eq "a failed live fetch is a hard, fail-closed failure — never a fallback to the trimmed entry" "1" "$rc"
assert_empty "…and nothing is printed" "$out_fail"
assert_eq "…and the failure is reported via guard_warn" "1" "$(guard_warn_calls)"

# --- compose_selected_candidate_text: the item is missing from this cycle's
# --- own gather (a stale or nonexistent candidate) --------------------------

reset_gh_calls
GH_RC=0
cand_missing='{"repo":"o/r","source":"issues","item":"999"}'
out_missing="$(compose_selected_candidate_text "$cand_missing" "$repos" "$refinements")"
rc=$?
assert_eq "an item absent from ordered_repos_json fails closed" "1" "$rc"
assert_empty "…and nothing is printed" "$out_missing"
assert_eq "…without ever attempting a gh call" "0" "$(gh_calls)"

# --- compose_selected_candidate_text: a never-trimmed source (no live fetch
# --- needed) uses the pre-fetched band entry directly -----------------------

repos_rf='[{"slug":"o/r","review_feedback":[{"ref":"pr-57-review-1","title":"pr-57-review-1","body":"A human'"'"'s specific, considered request.","branch":"agent/57","pr_url":"https://github.com/o/r/pull/57","pr_number":57}]}]'
cand_rf='{"repo":"o/r","default_branch":"main","pr_label":"autonomous-agent","source":"review-feedback","item":"pr-57-review-1","model":"claude-sonnet-5","model_reason":"stub","branch":"agent/57","pr_url":"https://github.com/o/r/pull/57","pr_number":57}'

reset_gh_calls
out_rf="$(compose_selected_candidate_text "$cand_rf" "$repos_rf" "$refinements")"
rc=$?
assert_eq "compose_selected_candidate_text (review-feedback) succeeds without any live fetch" "0" "$rc"
assert_eq "…no gh call at all — the band entry is never trimmed" "0" "$(gh_calls)"
assert_eq "…context is the entry's own body, verbatim" "A human's specific, considered request." "$(jq -r '.context' <<<"$out_rf")"
assert_eq "…acceptance is the deterministic per-source instruction" \
  "Address the review feedback above and push to the existing pull request." "$(jq -r '.acceptance' <<<"$out_rf")"
assert_eq "…branch/pr_url/pr_number survive unchanged" "agent/57 https://github.com/o/r/pull/57 57" \
  "$(jq -r '[.branch, .pr_url, (.pr_number|tostring)] | join(" ")' <<<"$out_rf")"

# --- compose_selected_candidate_text: landing-refusals (requirement 53,
# --- issue #979) — the band is pre-fetched like review-feedback, so a
# --- selected candidate must compose from its own entry rather than fail
# --- closed into the "untraceable" cause the claim loop gives rc 1 ---------

repos_lr='[{"slug":"o/r","landing_refusals":[{"ref":"pr-61-landing-refusal-4718691960","title":"fix(cache): drop the stale key","body":"── human comment by warwickallen at 2026-08-24T01:00:00Z (id 4718691960)\nThis needs a note in the gotchas section.","branch":"agent/td26082401","pr_url":"https://github.com/o/r/pull/61","pr_number":61}]}]'
cand_lr='{"repo":"o/r","default_branch":"main","pr_label":"autonomous-agent","source":"landing-refusals","item":"pr-61-landing-refusal-4718691960","model":"claude-sonnet-5","model_reason":"stub","branch":"agent/td26082401","pr_url":"https://github.com/o/r/pull/61","pr_number":61}'

reset_gh_calls
out_lr="$(compose_selected_candidate_text "$cand_lr" "$repos_lr" "$refinements")"
rc=$?
assert_eq "compose_selected_candidate_text (landing-refusals) succeeds without any live fetch" "0" "$rc"
assert_eq "…no gh call at all — the band entry is never trimmed" "0" "$(gh_calls)"
assert_contains "…context is the entry's own body: the unreconciled comment, verbatim" \
  "$(jq -r '.context' <<<"$out_lr")" "This needs a note in the gotchas section."
assert_contains "…acceptance names the reconciles citation that is the only thing clearing gate 4" \
  "$(jq -r '.acceptance' <<<"$out_lr")" "<!-- agent-ops:reconciles comment=<id> -->"
assert_eq "…title is the pull request's own" "fix(cache): drop the stale key" "$(jq -r '.title' <<<"$out_lr")"
assert_eq "…branch/pr_url/pr_number survive unchanged" "agent/td26082401 https://github.com/o/r/pull/61 61" \
  "$(jq -r '[.branch, .pr_url, (.pr_number|tostring)] | join(" ")' <<<"$out_lr")"

# --- compose_selected_candidate_text: a Dependabot takeover gets its own ----
# --- acceptance, never the ordinary "rebase" instruction (agent-ops#250) ---

repos_mc='[{"slug":"o/r","merge_conflicts":[{"ref":"pr-9-conflict-abc","title":"pr-9-conflict-abc","body":"Bumps foo from 1.0.0 to 1.1.0.","bot":true,"rebase_requested":true,"superseded_by":null,"pr_url":"https://github.com/o/r/pull/9","pr_number":9}]}]'
cand_mc='{"repo":"o/r","default_branch":"main","pr_label":"autonomous-agent","source":"merge-conflicts","item":"pr-9-conflict-abc","model":"claude-sonnet-5","model_reason":"stub","takeover":true,"pr_url":"https://github.com/o/r/pull/9","pr_number":9}'

reset_gh_calls
out_mc="$(compose_selected_candidate_text "$cand_mc" "$repos_mc" "$refinements")"
assert_contains "a Dependabot takeover's acceptance names the replacement pull request, never the ordinary rebase instruction" \
  "$(jq -r '.acceptance' <<<"$out_mc")" "Dependabot's own pull request is closed referencing the replacement"
assert_eq "…and takeover/pr_url/pr_number still survive unchanged" "true https://github.com/o/r/pull/9 9" \
  "$(jq -r '[(.takeover|tostring), .pr_url, (.pr_number|tostring)] | join(" ")' <<<"$out_mc")"

repos_mc_ord='[{"slug":"o/r","merge_conflicts":[{"ref":"pr-57-conflict-def","title":"pr-57-conflict-def","body":"The PR'"'"'s own description.","branch":"agent/57","pr_url":"https://github.com/o/r/pull/57","pr_number":57}]}]'
cand_mc_ord='{"repo":"o/r","default_branch":"main","pr_label":"autonomous-agent","source":"merge-conflicts","item":"pr-57-conflict-def","model":"claude-sonnet-5","model_reason":"stub","branch":"agent/57","pr_url":"https://github.com/o/r/pull/57","pr_number":57}'
out_mc_ord="$(compose_selected_candidate_text "$cand_mc_ord" "$repos_mc_ord" "$refinements")"
assert_eq "an ordinary (non-takeover) merge-conflicts candidate keeps the rebase acceptance" \
  "Rebase the existing pull request onto its base and resolve the conflict." "$(jq -r '.acceptance' <<<"$out_mc_ord")"

# --- The claim loop wires this in before requirement 17f, and folds a ------
# --- compose failure into the existing "untraceable" cause ------------------

loop_src="$(extract_block '^  c_composed=0' '^  # Requirement 17f ' "$AGENT_CYCLE")"
# shellcheck disable=SC2016  # the literal source text is what is being matched
if [[ -n "$loop_src" && "$loop_src" == *'compose_selected_candidate_text'* \
      && "$loop_src" == *'cause: "untraceable"'* && "$loop_src" == *'trace_faults=$(( trace_faults + 1 ))'* ]]; then
  printf 'ok   - %s\n' "the claim loop calls compose_selected_candidate_text and folds a compose failure into the untraceable cause"
else
  printf 'FAIL - %s\n' "the claim loop does not wire compose_selected_candidate_text the way this test expects — has it moved or changed shape?"
  failures=$(( failures + 1 ))
fi

trace_block="$(extract_block '^  c_trace_fault=' '^  if \[\[ -n ' "$AGENT_CYCLE")"
if [[ -n "$trace_block" && "$trace_block" == *'c_composed'* ]]; then
  printf 'ok   - %s\n' "requirement 17f's own fault check is exempted for a requirement 17h compose, same as a fallback pick"
else
  printf 'FAIL - %s\n' "requirement 17f's fault check no longer names c_composed — has the guard moved?"
  failures=$(( failures + 1 ))
fi

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) FAILED"
  exit 1
else
  echo "All assertions passed."
  exit 0
fi
