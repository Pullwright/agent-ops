#!/usr/bin/env bash
# shellcheck disable=SC2154  # enabler_escalation_label is assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally.
#
# lib/escalation-lookup.sh — the two-step (labelled-first, label-less-
# fallback) GitHub read behind every escalation-issue lookup in this
# pipeline (agent-ops#2657, agent-ops#2666, agent-ops#2670).
#
# `create_escalation_issue`'s own duplicate guard and `escalation_open_
# existing` (both lib/enabler.sh) introduced this read for the one case a
# plain `--label` search misses: an escalation `gh issue create`'s own retry
# can file without the label when the label does not exist and `labels_
# reconcile_role` could not create it (agent-ops#2657). A bare backtick-
# delimited body match is not a safe stand-in for the label on that
# label-less read, though (agent-ops#2666): it would also catch a
# `pw::decision` decision-log issue (`enabler_decision_log_body`) and an
# unlabelled `techdebt_file_issue` question issue, both of which quote the
# same item ref for the same repo/item pair without being an escalation —
# returning either as "the escalation" files none and asks no human. The
# label-less fallback therefore keys on the escalation footer's own
# `` Item: `<ref>` `` form rather than the bare token, and excludes any body
# carrying the `<!-- agent-ops:decision-log` marker.
#
# `escalation_issue_lookup` below is that same two-step read, factored out
# once rather than copied per caller (agent-ops#2670), documented as a
# dependency of each caller's own file (lib/enabler.sh, lib/landing.sh,
# lib/approver.sh) the same way those files already document every other
# library they rely on their own caller having sourced first.
# `create_escalation_issue`/`escalation_open_existing` keep their own
# inlined copies (out of scope for #2670); every other escalation reader in
# this pipeline calls this one instead.

# escalation_issue_lookup REPO STATE ITEM_REF [JSON_FIELDS [GH_BIN]]
# Prints a JSON array (on stdout) of the open/closed issues in REPO whose
# body matches ITEM_REF — each object carrying JSON_FIELDS (default
# "number,url,body") — and returns 0, regardless of whether any issue
# matched (an empty array `[]` is still success). Tries `--label
# "$enabler_escalation_label"` first, filtering on the backtick-delimited
# `` `<ref>` `` token `create_escalation_issue`'s own duplicate guard uses;
# only when that comes back empty does it fall back to a label-less read
# across every open/closed issue STATE names, filtering on the escalation
# footer's `` Item: `<ref>` `` form and excluding any body carrying
# `<!-- agent-ops:decision-log`. GH_BIN (default "gh") lets a caller that
# already takes its own `gh` override — `approver_escalation_retire`'s own
# `APPROVER_GH` — pass it through rather than this function reaching for the
# unoverridden binary underneath it.
#
# Returns 1 if either `gh issue list` call itself errors, and 2 if a call
# that succeeded returned a payload `jq` could not parse — "no match" and
# "could not tell" are never conflated (agent-ops#2554's own reasoning,
# applied here once for every caller). A caller that treats any failure as
# "nothing found" (most of them: a live GitHub read failing is not reason
# enough to block on) gets that for free from the usual `2>/dev/null ||
# true` wrapping its own call already does; a caller that must distinguish
# — `credential_refused_retire_resolved`, `memory_throttle_retire_resolved`
# (lib/enabler.sh), both of which retry next cycle rather than risk
# forfeiting a close — reads this function's own exit status instead.
escalation_issue_lookup() {
  local repo="$1" state="$2" item_ref="$3" fields="${4:-number,url,body}" gh_bin="${5:-gh}"
  local raw matched

  raw="$("$gh_bin" issue list -R "$repo" --label "$enabler_escalation_label" --state "$state" \
           --search "$item_ref" --json "$fields")" || return 1
  matched="$(jq -c --arg it "$item_ref" \
    'map(select((.body // "") | contains("`" + $it + "`")))' <<<"$raw")" || return 2
  if [[ "$matched" != "[]" ]]; then
    printf '%s' "$matched"
    return 0
  fi

  raw="$("$gh_bin" issue list -R "$repo" --state "$state" --search "$item_ref" --json "$fields")" || return 1
  jq -c --arg it "$item_ref" \
    'map(select(((.body // "") | contains("Item: `" + $it + "`"))
                 and ((.body // "") | contains("<!-- agent-ops:decision-log") | not)))' \
    <<<"$raw" || return 2
}
