#!/usr/bin/env bash
#
# test/coordinator-refinements.test.sh — regression test for requirement 4j's
# `coordinator_refinements_view` (agent-ops#643).
#
# `refinements` is a ledger that is never retired. Most of its entries are a
# line — `ts`, `cycle`, a `comment_url` — but an entry for an item with no
# thread to hold it carries the whole specification in markdown, and by
# 2026-08-21 those had grown to 219175 bytes of a 237339-byte band. That band
# sits in the *unsheddable* half of the Co-Ordinator's input: requirement 4i's
# ladder trims `issues` and `tech_debt` and cannot touch it. The allowance came
# out negative, the ladder was never walked, and the API refused the stage on
# every node of the fleet for eleven consecutive cycles.
#
# The view's rule is candidacy, and it comes from `prompts/coordinator.md`
# rather than from a byte count. By 2026-09-23 the specs were already gone
# from the view and the ledger itself was the weight — 848 entries, 167 KB of
# `ts`, `cycle` and `comment_url`, 384 of them under a slug the fleet no
# longer configures — so agent-ops#1379 narrowed the view to what a selection
# this cycle could actually read: an entry only for an item some pre-fetched
# band offers, or one from a source the Co-Ordinator derives itself (a ref no
# pre-fetched band constructs), each reduced to `{comment_url}`, `{spec}`
# (self-derived only) or `{}`. What is asserted here is that the rule keeps
# exactly those entries — presence is what the under-specification check and
# the `refinement_policy` gate read, so losing a live entry would change
# selection, and keeping a dead one costs every engagement bytes.
#
# The function is lifted verbatim out of agent-cycle.sh, the way
# test/coordinator-input-wiring.test.sh lifts its own, so the assertions are
# about the shipped code rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
# ./test/coordinator-refinements.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_CYCLE="$SCRIPT_DIR/lib/candidate-select.sh"

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
assert_true() { assert_eq "$1" "true" "$2"; }
assert_ok() { assert_eq "$1" "1" "$2"; }

extract_block() {
  local start_re="$1" end_re="$2" file="$3"
  BLOCK_START_RE="$start_re" BLOCK_END_RE="$end_re" awk '
    $0 ~ ENVIRON["BLOCK_START_RE"] { on = 1 }
    on                             { print }
    on && $0 ~ ENVIRON["BLOCK_END_RE"] { exit }
  ' "$file"
}

view_block="$(extract_block '^coordinator_refinements_view\(\) \{' '^\}$' "$AGENT_CYCLE")"
if [[ -z "$view_block" || "$view_block" != *'jq'* ]]; then
  echo "FAIL - could not extract coordinator_refinements_view from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
eval "$view_block"

# --- Fixtures -----------------------------------------------------------------

# Two engaged repos and one the cycle does not engage. `o/r` offers five
# candidates across four bands; its ledger holds pointer entries for two of
# them and for one issue no band offers, specs for a live tech-debt issue, a
# live review-feedback ref, a frozen register id and a closed pull-request ref
# that no band offers, an old pointer-and-spec pair, and two self-derived
# refinements (a project-review recommendation and a plan task) that no band
# could ever offer.
repos='[
  {"slug": "o/r",
   "issues":     [{"source": "issues",     "ref": "52", "number": 52}],
   "tech_debt":  [{"source": "tech-debt",  "ref": "77", "number": 77},
                  {"source": "tech-debt",  "ref": "78", "number": 78}],
   "review_feedback": [{"source": "review-feedback", "ref": "pr-9-review-1"}],
   "merge_conflicts": [{"source": "merge-conflicts", "ref": "pr-4-conflict-a"}]},
  {"slug": "o/other", "tech_debt": [{"source": "tech-debt", "ref": "90", "number": 90}]}
]'
refinements='{
  "o/r": {
    "52":            {"ts": "t", "cycle": "c", "comment_url": "https://example/52"},
    "61":            {"ts": "t", "cycle": "c", "comment_url": "https://example/61"},
    "77":            {"ts": "t", "cycle": "c", "spec": "SPEC-HELD-live-td"},
    "78":            {"ts": "t", "cycle": "c", "comment_url": "https://example/78", "spec": "SPEC-DROPPED-both"},
    "pr-9-review-1": {"ts": "t", "cycle": "c", "spec": "SPEC-HELD-review"},
    "pr-4-conflict-a": {"ts": "t", "cycle": "c", "comment_url": "https://example/pr4"},
    "pr-2-abandoned-deadbeef": {"ts": "t", "cycle": "c", "spec": "SPEC-DROPPED-closed-pr"},
    "TD-PPagop-26080807": {"ts": "t", "cycle": "c", "spec": "SPEC-DROPPED-register"},
    "dependabot-alert-3": {"ts": "t", "cycle": "c", "comment_url": "https://example/dep3"},
    "review-2026-09-01-R-04": {"ts": "t", "cycle": "c", "spec": "SPEC-KEPT-review-rec"},
    "plan-task-2.3":  {"ts": "t", "cycle": "c", "spec": "SPEC-KEPT-plan-task"}
  },
  "o/other": {
    "90":            {"ts": "t", "cycle": "c", "comment_url": "https://example/90"},
    "TD-elsewhere":  {"ts": "t", "cycle": "c", "spec": "SPEC-DROPPED-otherrepo"}
  },
  "o/unengaged": {
    "5":             {"ts": "t", "cycle": "c", "comment_url": "https://example/5"},
    "review-2026-08-01-R-01": {"ts": "t", "cycle": "c", "spec": "SPEC-DROPPED-unengaged"}
  }
}'

out="$(coordinator_refinements_view "$refinements" "$repos")"

# --- Each entry is an identity, never a payload ------------------------------

assert_eq "a pointer entry for an offered issue keeps its comment_url and nothing else" \
  '{"comment_url":"https://example/52"}' "$(jq -c '."o/r"."52"' <<<"$out")"
assert_eq "a pointer entry for an offered pull-request ref keeps its comment_url and nothing else" \
  '{"comment_url":"https://example/pr4"}' "$(jq -c '."o/r"."pr-4-conflict-a"' <<<"$out")"
assert_eq "a spec for an offered tech-debt issue is reduced to presence — the Script splices it" \
  '{}' "$(jq -c '."o/r"."77"' <<<"$out")"
assert_eq "a spec for an offered review-feedback ref is reduced to presence — the Script composes it" \
  '{}' "$(jq -c '."o/r"."pr-9-review-1"' <<<"$out")"
assert_eq "a spec beside a comment_url is shed whatever the candidacy (agent-ops#1128)" \
  '{"comment_url":"https://example/78"}' "$(jq -c '."o/r"."78"' <<<"$out")"
assert_true "ts and cycle survive on no entry at all" \
  "$(jq -e '[.[] | to_entries[] | .value | has("ts") or has("cycle")] | any | not' <<<"$out" >/dev/null && echo true || echo false)"

# --- Only what a selection this cycle could read is kept ---------------------

assert_true "a pointer entry for an issue no band offers is dropped" \
  "$(jq -e '."o/r" | has("61") | not' <<<"$out" >/dev/null && echo true || echo false)"
assert_true "a spec for a closed pull-request ref no band offers is dropped" \
  "$(jq -e '."o/r" | has("pr-2-abandoned-deadbeef") | not' <<<"$out" >/dev/null && echo true || echo false)"
assert_true "a spec for a frozen register id is dropped" \
  "$(jq -e '."o/r" | has("TD-PPagop-26080807") | not' <<<"$out" >/dev/null && echo true || echo false)"
assert_true "a pointer for a finding no band offers is dropped" \
  "$(jq -e '."o/r" | has("dependabot-alert-3") | not' <<<"$out" >/dev/null && echo true || echo false)"
assert_true "a repository the cycle does not engage is dropped whole" \
  "$(jq -e 'has("o/unengaged") | not' <<<"$out" >/dev/null && echo true || echo false)"
assert_eq "the engaged repos survive, in the ledger's own order" \
  '["o/other","o/r"]' "$(jq -c 'keys' <<<"$out")"

# --- A self-derived source's refinement is kept, spec and all -----------------
# `project-review` and `implementation-plan` candidates are derived live by the
# Co-Ordinator, so no band can vouch for them; their refs match no pre-fetched
# band's shape, and the spec is the one thing the prompt has the model paste.

assert_eq "a project-review recommendation's spec is kept for the model to paste" \
  '{"spec":"SPEC-KEPT-review-rec"}' "$(jq -c '."o/r"."review-2026-09-01-R-04"' <<<"$out")"
assert_eq "a plan task's spec is kept too, whatever its ref looks like" \
  '{"spec":"SPEC-KEPT-plan-task"}' "$(jq -c '."o/r"."plan-task-2.3"' <<<"$out")"

# --- Candidacy is per repo, not fleet-wide ------------------------------------

assert_eq "the other engaged repo keeps its own offered pointer" \
  '{"comment_url":"https://example/90"}' "$(jq -c '."o/other"."90"' <<<"$out")"
assert_true "…and drops its own frozen register spec" \
  "$(jq -e '."o/other" | has("TD-elsewhere") | not' <<<"$out" >/dev/null && echo true || echo false)"
cross="$(coordinator_refinements_view "$refinements" '[{"slug": "o/other", "tech_debt": [{"ref": "61"}]}]')"
assert_true "an id offered only by another repo does not keep this repo's entry" \
  "$(jq -e 'has("o/r") | not' <<<"$cross" >/dev/null && echo true || echo false)"
assert_eq "…and every band, not only the six the old view read, vouches for its refs" \
  '{"comment_url":"https://example/pr4"}' \
  "$(coordinator_refinements_view "$refinements" '[{"slug": "o/r", "merge_conflicts": [{"ref": "pr-4-conflict-a"}]}]' | jq -c '."o/r"."pr-4-conflict-a"')"

# --- It is worth having: the band actually shrinks ---------------------------

assert_ok "the view is smaller than the ledger it trims" \
  "$(( $(printf '%s' "$out" | wc -c) < $(printf '%s' "$refinements" | wc -c) ))"
assert_true "no dropped or held spec's text survives anywhere in the output" \
  "$(grep -qE 'SPEC-DROPPED|SPEC-HELD' <<<"$out" && echo false || echo true)"
assert_eq "what survives is exactly the eight entries a selection could read" \
  "8" "$(jq '[.[] | to_entries[]] | length' <<<"$out")"

# --- Degradation is toward the untrimmed ledger, never toward an empty one ----
# The same fail-open direction as `coordinator_blocked_view` and requirement
# 4i's own guards: a view that emptied this band on malformed input would
# silently un-refine every item in the fleet, which is worse than the overflow
# it exists to prevent.

assert_eq "a malformed repos document leaves the ledger untouched" \
  "$(jq -S . <<<"$refinements")" "$(jq -S . <<<"$(coordinator_refinements_view "$refinements" 'not json')")"
assert_eq "a repos document of the wrong type leaves the ledger untouched" \
  "$(jq -S . <<<"$refinements")" "$(jq -S . <<<"$(coordinator_refinements_view "$refinements" '{"slug": "o/r"}')")"
assert_eq "a malformed ledger is handed back as it arrived" \
  "not json" "$(coordinator_refinements_view 'not json' "$repos")"
assert_eq "an empty ledger stays empty rather than becoming an error" \
  "{}" "$(coordinator_refinements_view '{}' "$repos")"
assert_eq "an empty repos array — a cycle engaging nothing — keeps nothing rather than crashing" \
  "{}" "$(coordinator_refinements_view "$refinements" '[]')"

# --- Requirement 4g: neither document may reach jq in argv --------------------
# Both are unbounded fleet-state aggregates, and this map is the one that
# actually crossed MAX_ARG_STRLEN on the outage. An `--argjson` here would
# trade the API refusal this function exists to prevent for the execve death
# requirement 4g exists to prevent.

assert_true "the view binds neither document with --argjson" \
  "$(grep -qE 'argjson' <<<"$view_block" && echo false || echo true)"

big="$( { printf '{"o/r": {"TD-gone": {"ts": "t", "cycle": "c", "spec": "'
          head -c 200000 /dev/zero | tr '\0' 'S'
          printf '"}}}'; } )"
assert_ok "the oversized fixture really is past MAX_ARG_STRLEN" \
  "$(( $(printf '%s' "$big" | wc -c) > 131072 ))"
assert_eq "a ledger past MAX_ARG_STRLEN is trimmed rather than dying at execve" \
  '{"o/r":{}}' "$(coordinator_refinements_view "$big" "$repos")"

printf '\n%s\n' "$( (( failures == 0 )) && echo "All assertions passed." || echo "$failures assertion(s) failed." )"
exit $(( failures > 0 ))
