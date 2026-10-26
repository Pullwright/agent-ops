#!/usr/bin/env bash
#
# lib/escalation-dedup.sh — the duplicate-guard predicate shared by every
# escalation filer: does an open issue in a repo already represent a given
# item reference, so a second filing would ask the same human twice
# (agent-ops#2669).
#
# Pure: `gh` and `jq` only, no cycle-scoped globals (`cycle_dir`,
# `enabler_assignee`, …) — unlike `lib/enabler.sh`'s `create_escalation_issue`
# and `escalation_open_existing`, which this file's one function now backs.
# `lib/merge-budget.sh` cannot source `lib/enabler.sh` to reach those
# directly (its own callers — `scripts/doctor.sh`, `scripts/publish-
# dashboard.sh`, its own regression test — run with no cycle to supply those
# globals), which is why its freeze escalation used to inline its own copy of
# this guard rather than skip it. That copy drifted from the real one instead
# of staying identical, which is what this file exists to stop: one
# implementation, sourced by every caller that needs it, rather than several
# that only start out identical.
#
# Self-sourced by both `lib/enabler.sh` and `lib/merge-budget.sh` (each adds
# its own `. "$SCRIPT_DIR/lib/escalation-dedup.sh"`, the same way
# `lib/claim.sh` self-sources its own leaf dependencies) rather than left for
# every caller of either file to source alongside it — this keeps the two
# files independent of each other's caller lists, which is the property that
# matters here: `lib/merge-budget.sh` must still never need anything
# `lib/enabler.sh` only has because of its cycle.

# escalation_dedup_match REPO ITEM_REF LABEL [STATE]
# Prints "<number>\t<url>" for the first issue in REPO, in STATE (default
# "open"), that already represents ITEM_REF as an escalation; prints nothing
# if there is none or the read fails — "no existing issue" is the safe
# reading of an unreadable state, same as every other duplicate guard in
# this codebase. Two stages:
#
#   1. Label-scoped: an open issue carrying LABEL whose body quotes the
#      backtick-delimited token `` `ITEM_REF` ``. The backtick delimiting is
#      load-bearing (agent-ops#1694) — a bare substring match would also hit
#      an unrelated issue that merely mentions ITEM_REF in prose, or one
#      whose own item ref is a *prefix* of this one (e.g.
#      `crash-loop:coordinator` inside `crash-loop:coordinator:<owner>/
#      <name>`).
#   2. Label-less fallback (agent-ops#2657): an escalation filed via a
#      retry-without-label path must still be found here. Keyed on the
#      escalation footer's `` Item: `ITEM_REF` `` form rather than the bare
#      token (agent-ops#2666), and excluding any body carrying
#      `<!-- agent-ops:decision-log` — otherwise a `pw::decision`
#      decision-log veto or an unlabelled `techdebt_file_issue` question
#      issue quoting the same ref would be mistaken for the escalation,
#      which files none and asks nobody.
escalation_dedup_match() {
  local repo="$1" item_ref="$2" label="$3" state="${4:-open}"
  local existing
  existing="$(gh issue list -R "$repo" --label "$label" --state "$state" \
                --search "$item_ref" --json number,url,body 2>/dev/null \
              | jq -r --arg it "$item_ref" \
                  'map(select(((.body // "") | contains("`" + $it + "`")))) | first
                   | if . == null then empty else "\(.number)\t\(.url)" end' 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    printf '%s' "$existing"
    return 0
  fi
  gh issue list -R "$repo" --state "$state" --search "$item_ref" \
      --json number,url,body 2>/dev/null \
    | jq -r --arg it "$item_ref" \
        'map(select(((.body // "") | contains("Item: `" + $it + "`"))
                     and ((.body // "") | contains("<!-- agent-ops:decision-log") | not)))
         | first
         | if . == null then empty else "\(.number)\t\(.url)" end' 2>/dev/null || true
}
