#!/usr/bin/env bash
#
# test/closing-keyword-wiring.test.sh — regression test for the two blocks in
# agent-cycle.sh that decide what requirement 25a's script-side gate
# (lib/closing-keyword-gate.sh) and requirement 25c's script-side gate
# (lib/changelog-section-gate.sh, agent-ops#1808, on the closing-keyword
# gate's own pattern) actually *do* with their verdicts at the
# Implementer→Reviewer handoff. Both gates sit in the same two blocks and are
# asserted together here rather than in a sibling file, since the wiring is
# one shared shape, not two.
#
# test/closing-keyword-gate.test.sh and test/changelog-section-gate.test.sh
# cover each gate's own verdict, and test/check-closing-keyword.test.sh and
# test/check-changelog-section.test.sh the rules underneath them. Both pass
# with the consequence wired either way round, and the consequence is the
# whole question this file exists for:
#
#   - **A `dirty` verdict here is feedback, not a refusal.** What the gate
#     finds is a pull-request *body* edit, the class of defect the Reviewer's
#     own step 4 fixes and pushes in the same cycle. Refusing the handoff
#     would record the item `attempt-failed` and block it pending an Enabler
#     engagement — a self-healing case turned into a stuck one — and buy no
#     safety, since the same gate is asked again at the Reviewer's `ready`
#     handoff, which is the only way a pull request reaches a human or a
#     merge. So the block must set the finding and *carry on*; the shipped
#     first cut of this gate exited here instead.
#   - **The finding has to actually reach the Reviewer.** It cannot see the
#     later gate's verdict from inside its own session, so a finding recorded
#     in the log and left out of the prompt is a review that hands off and is
#     handed back — the review spent and the item lost anyway. The prompt
#     section is therefore asserted, in both directions: present and naming
#     the fault when there is one, and wholly absent (not an empty heading)
#     when there is not.
#   - **`unknown` is neither.** A `gh` that could not answer says something
#     about this node, not this pull request; it warns, and nothing is handed
#     to the Reviewer to "fix".
#
# Both blocks are lifted verbatim out of agent-cycle.sh, the same way
# test/human-visibility-wiring.test.sh lifts its block, so the assertions are
# about the shipped code rather than a copy of its logic. Their callees are
# stubbed: `closing_keyword_gate` and `changelog_section_gate` (each covered
# by its own test), `log_event`, `release_claim` and `stage_prompt_text`.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/closing-keyword-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/agent-cycle.sh"

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

assert_lacks() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:                 %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- Extraction ---------------------------------------------------------------
# Block 1: the `closing_keyword_finding` initialiser through the `fi` closing
# the `if [[ -n "$impl_pr_url" ]]` the gate call sits in.
gate_block="$(awk '
  /^closing_keyword_finding=""$/ { on = 1 }
  on                             { print }
  on && /^fi$/                   { exit }
' "$CYCLE")"

# Block 2: the `## Script findings` section builder and the reviewer prompt
# assembly it feeds, up to (not including) the line after it.
prompt_block="$(awk '
  /^script_findings_section=""$/ { on = 1 }
  on && /^rev_out=/              { exit }
  on                             { print }
' "$CYCLE")"

for pair in "gate:$gate_block" "prompt:$prompt_block"; do
  if [[ -z "${pair#*:}" ]]; then
    echo "FAIL - could not extract the ${pair%%:*} block from agent-cycle.sh — has it moved?" >&2
    exit 1
  fi
done

# --- Block 1: what the verdict costs ------------------------------------------
# run_gate_block CK_VERDICT [CS_VERDICT]
# Runs the block with `closing_keyword_gate` stubbed to CK_VERDICT and
# `changelog_section_gate` stubbed to CS_VERDICT (each a literal `clean` /
# `dirty<TAB>reason` / `unknown<TAB>reason`; CS_VERDICT defaults to `clean` so
# every existing closing-keyword-only case below stays unchanged), under the
# same `set -euo pipefail` agent-cycle.sh runs under. Prints the resulting
# `closing_keyword_finding`, then `changelog_section_finding`, each on its own
# line, then a `--` line, then every `log_event` call as `<kind><TAB><detail>`.
# A block that exits early — the behaviour this file exists to catch — prints
# no `--` at all, so `reached_end` can assert it.
# shellcheck disable=SC2016  # The harness's own `$1`/`$2`/`$closing_keyword_finding`/`$changelog_section_finding`, written out literally for it to expand, not this shell's.
run_gate_block() {
  local ck_verdict="$1" cs_verdict="${2:-clean}" harness="$tmp_dir/gate-harness.sh"
  {
    printf '%s\n' 'set -euo pipefail'
    printf 'impl_pr_url=%q\n' "https://github.com/Poetic-Poems/poetic-fiddle/pull/198"
    printf 'repo_slug=%q\n' "Poetic-Poems/poetic-fiddle"
    printf 'selected_item=%q\n' "198"
    printf 'selected_default_branch=%q\n' "main"
    printf 'node_name=%q\n' "n"
    printf 'cycle_id=%q\n' "c"
    printf '%s\n' 'log_event() { printf "%s\t%s\n" "$1" "$(jq -r ".detail // \"\"" <<<"$2")" >>'"$(printf '%q' "$tmp_dir/events")"'; }'
    printf '%s\n' 'release_claim() { :; }'
    # required_check_preflight_findings/escalate (issue #1543) are this
    # file's own tested unit elsewhere (test/required-check-preflight.test.sh)
    # — stubbed here to a no-finding no-op so this file's own assertions stay
    # about the closing-keyword/changelog-section consequence alone.
    printf '%s\n' 'required_check_preflight_findings() { :; }'
    printf '%s\n' 'required_check_preflight_escalate() { :; }'
    printf 'closing_keyword_gate() { printf %%s %q; [[ %q == dirty* ]] && return 1; return 0; }\n' \
      "$ck_verdict" "$ck_verdict"
    printf 'changelog_section_gate() { printf %%s %q; [[ %q == dirty* ]] && return 1; return 0; }\n' \
      "$cs_verdict" "$cs_verdict"
    printf '%s\n' "$gate_block"
    printf '%s\n' 'printf "%s\n" "$closing_keyword_finding"'
    printf '%s\n' 'printf "%s\n" "$changelog_section_finding"'
    printf '%s\n' 'printf -- "--\n"'
  } > "$harness"
  : > "$tmp_dir/events"
  bash "$harness" 2>/dev/null
  printf '%s' "$(cat "$tmp_dir/events" 2>/dev/null || true)"
}

reached_end() { [[ "$1" == *$'--\n'* || "$1" == *$'--' ]] && echo yes || echo no; }
ck_finding_of() { head -n1 <<<"$1"; }
cs_finding_of() { sed -n '2p' <<<"$1"; }

DIRTY_REASON='PR body names issue #198 (agent-ops:closes-issue marker) but has no closing keyword (Closes/Fixes/Resolves #198) for it'

out="$(run_gate_block "dirty	$DIRTY_REASON")"
assert_eq "a dirty verdict does not end the cycle — the Reviewer still runs" \
  "yes" "$(reached_end "$out")"
assert_eq "  ... and the fault is held for the Reviewer, reason intact" \
  "$DIRTY_REASON" "$(ck_finding_of "$out")"
assert_contains "  ... with a warning logged naming the pull request" \
  "pull/198 fails the closing-keyword check" "$out"
# The regression: recording the item `attempt-failed` here is what turned a
# one-line body edit into an item blocked pending an Enabler engagement.
assert_lacks "  ... and nothing recorded against the item as a failed attempt" \
  "attempt-failed" "$out"

out="$(run_gate_block "unknown	could not read https://github.com/o/r/pull/1's body and head branch")"
assert_eq "an unknown verdict does not end the cycle either" \
  "yes" "$(reached_end "$out")"
assert_eq "  ... and hands the Reviewer nothing to fix" "" "$(ck_finding_of "$out")"
assert_contains "  ... but warns that the check could not be made" \
  "could not check whether" "$out"

out="$(run_gate_block "clean")"
assert_eq "a clean verdict hands the Reviewer nothing" "" "$(ck_finding_of "$out")"
assert_lacks "  ... and logs no warning" "warning" "$out"

# --- requirement 25c's changelog-section gate, the same three ways ----------
# CK_VERDICT is clean throughout this group, so any finding or warning below
# comes from the changelog-section gate alone.

CS_DIRTY_REASON='a feat, fix or perf title, or a breaking change, owes a ## Changelog section in the pull-request description'

out="$(run_gate_block "clean" "dirty	$CS_DIRTY_REASON")"
assert_eq "a dirty changelog-section verdict does not end the cycle either" \
  "yes" "$(reached_end "$out")"
assert_eq "  ... closing-keyword finding stays empty — that gate was clean" \
  "" "$(ck_finding_of "$out")"
assert_eq "  ... and the changelog-section fault is held for the Reviewer, reason intact" \
  "$CS_DIRTY_REASON" "$(cs_finding_of "$out")"
assert_contains "  ... with a warning logged naming the pull request" \
  "pull/198 fails the changelog-section check" "$out"
assert_lacks "  ... and nothing recorded against the item as a failed attempt" \
  "attempt-failed" "$out"

out="$(run_gate_block "clean" "unknown	could not read https://github.com/o/r/pull/1's body and title")"
assert_eq "an unknown changelog-section verdict does not end the cycle either" \
  "yes" "$(reached_end "$out")"
assert_eq "  ... and hands the Reviewer nothing to fix" "" "$(cs_finding_of "$out")"
assert_contains "  ... but warns that the check could not be made" \
  "could not check whether" "$out"

out="$(run_gate_block "clean" "clean")"
assert_eq "both gates clean hands the Reviewer nothing" "" "$(ck_finding_of "$out")"
assert_eq "  ... from either gate" "" "$(cs_finding_of "$out")"
assert_lacks "  ... and logs no warning" "warning" "$out"

# --- both gates dirty at once: both findings survive -------------------------

out="$(run_gate_block "dirty	$DIRTY_REASON" "dirty	$CS_DIRTY_REASON")"
assert_eq "both dirty: the closing-keyword fault survives" \
  "$DIRTY_REASON" "$(ck_finding_of "$out")"
assert_eq "  ... and the changelog-section fault survives alongside it" \
  "$CS_DIRTY_REASON" "$(cs_finding_of "$out")"

# --- Block 2: the finding reaches the Reviewer's prompt -----------------------
# run_prompt_block CK_FINDING [CS_FINDING] — prints the assembled reviewer
# prompt.
# shellcheck disable=SC2016  # The harness's own `$reviewer_prompt`, written out literally for it to expand, not this shell's.
run_prompt_block() {
  local ck_finding="$1" cs_finding="${2:-}" harness="$tmp_dir/prompt-harness.sh"
  {
    printf '%s\n' 'set -euo pipefail'
    printf 'closing_keyword_finding=%q\n' "$ck_finding"
    printf 'changelog_section_finding=%q\n' "$cs_finding"
    printf '%s\n' 'stage_prompt_text() { printf "%s" "<<reviewer prompt>>"; }'
    printf '%s\n' 'PROMPTS_DIR=""; state_dir=""; prompt_overrides_json="{}"'
    printf '%s\n' 'work_order_json='"'"'{"item":"198"}'"'"'; impl_status_json='"'"'{"status":"complete"}'"'"''
    printf '%s\n' 'cycle_id="20260813T045756Z-ockham-2-5031"; node_name="ockham-2"'
    printf '%s\n' "$prompt_block"
    printf '%s\n' 'printf "%s" "$reviewer_prompt"'
  } > "$harness"
  bash "$harness" 2>/dev/null
}

with="$(run_prompt_block "$DIRTY_REASON")"
assert_contains "a held finding reaches the Reviewer as a Script findings section" \
  $'\n## Script findings\n' "$with"
assert_contains "  ... naming the requirement it came from" \
  "Closing keyword (requirement 25a)" "$with"
assert_contains "  ... and the fault itself, verbatim" "$DIRTY_REASON" "$with"
assert_contains "  ... ahead of the Cycle section, not appended past it" \
  $'## Script findings' "$(sed -n '1,/^## Cycle$/p' <<<"$with")"
assert_lacks "  ... and no changelog-section bullet when that gate found nothing" \
  "Changelog section" "$with"

without="$(run_prompt_block "")"
assert_lacks "no finding leaves no heading at all — not an empty one" \
  "Script findings" "$without"
# An always-present section variable that merely expands to nothing would
# still shift the spacing every prompt around it; the Reviewer's prompt is
# unchanged when the gate found nothing.
assert_contains "  ... and the sections either side keep their usual spacing" \
  $'```\n\n## Cycle\n' "$without"

cs_with="$(run_prompt_block "" "$CS_DIRTY_REASON")"
assert_contains "a changelog-section-only finding reaches the Reviewer too" \
  $'\n## Script findings\n' "$cs_with"
assert_contains "  ... naming the requirement it came from" \
  "Changelog section (requirement 25c)" "$cs_with"
assert_contains "  ... and the fault itself, verbatim" "$CS_DIRTY_REASON" "$cs_with"
assert_lacks "  ... with no closing-keyword bullet, that gate found nothing" \
  "Closing keyword" "$cs_with"

both="$(run_prompt_block "$DIRTY_REASON" "$CS_DIRTY_REASON")"
assert_contains "both findings reach the Reviewer as two bullets in one section" \
  "Closing keyword (requirement 25a)" "$both"
assert_contains "  ... the closing-keyword fault, verbatim" "$DIRTY_REASON" "$both"
assert_contains "  ... the changelog-section fault too" \
  "Changelog section (requirement 25c)" "$both"
assert_contains "  ... verbatim" "$CS_DIRTY_REASON" "$both"
assert_eq "  ... under a single Script findings heading, not two" \
  "1" "$(grep -c '^## Script findings$' <<<"$both")"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
