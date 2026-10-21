#!/usr/bin/env bash
#
# scripts/render-labels-table.sh — render the labels table docs/reference/labels.md
# carries (issue #2097) from lib/labels.sh's own catalogue, between its
# generated region's marker pair.
#
# `lib/labels.sh`'s `labels_catalogue` is the one function this reads: it
# already enumerates every label a repository in a given role (`target`,
# `review`, `escalation`) needs, with the colour and description a fresh
# installation gets, resolved through `config_defaults` so a configurable
# label's catalogue entry already reflects a config.json override. This
# script calls it three times — once per role — against a config file that
# carries nothing but the two illustrative overrides the catalogue cannot
# resolve on its own (`pr_label` and `repository_review.defaults.pr_label`
# are both required, with no product default; `config.schema.json`'s own
# documented example, `x-docs.value`, is what fills them here, the same
# convention render-config-table.sh uses for the main config tables) —
# then unions the three roles' rows by name, so a label used by more than
# one role (`pw::decision`, applied by both the Enabler under `target` and
# listed for `escalation`) appears once.
#
# "Applied by" and "removing it does" are not in the catalogue — it only
# ever carried name/colour/description, enough to create a label, not to
# explain it to a reader — so METADATA_JSON below supplies them by hand,
# keyed on the catalogue's own resolved name. A name the catalogue returns
# with no entry in METADATA_JSON is a hard failure, never a silently blank
# cell: the catalogue is what changes (a new label added to lib/labels.sh),
# and this script's metadata is what must be kept in step with it, the same
# relationship render-config-table.sh's `x-docs` has with config.schema.json.
#
# With no arguments, regenerate the table. `--check` verifies the region is
# current (exit non-zero if stale), mirroring render-toc.sh's and
# render-config-table.sh's own contract.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

schema_file="config.schema.json"

usage() {
  echo "usage: $(basename "$0") [--check]" >&2
  exit 2
}

check_mode=0
case "${1:-}" in
  --check) check_mode=1; shift ;;
  "") ;;
  *) usage ;;
esac
if (( $# > 0 )); then
  usage
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "render-labels-table: jq is required" >&2
  exit 1
fi

# The file this renders (LABELS_TABLE_FILES) and the markers that delimit
# its region come from lib/markdown-scan.sh, which scripts/check-docs.sh
# reads to leave exactly this region out of the size budget.
# shellcheck source=lib/markdown-scan.sh
. "$repo_root/lib/markdown-scan.sh"
# shellcheck source=lib/config-schema.sh
. "$repo_root/lib/config-schema.sh"
# shellcheck source=lib/labels.sh
. "$repo_root/lib/labels.sh"

# The one illustrative config this renders against: both `pr_label` keys
# are required with no product default, so labels_catalogue would otherwise
# skip them entirely (an empty name renders no row). Each schema's own
# `x-docs.value` is the documented example already used for the same
# purpose in docs/reference/configuration.md's own tables.
illustrative_config="$(mktemp)"
trap 'rm -f "$illustrative_config"' EXIT
jq -n \
  --arg pr_label "$(jq -r '.properties.pr_label["x-docs"].value' "$schema_file" | tr -d '`')" \
  --arg review_pr_label "$(jq -r '.["$defs"].reviewPipelineConfig.properties.defaults.properties.pr_label["x-docs"].value' "$schema_file" | tr -d '`')" \
  '{pr_label: $pr_label, repository_review: {defaults: {pr_label: $review_pr_label}}}' \
  > "$illustrative_config"

review_pr_label="$(jq -r '.repository_review.defaults.pr_label' "$illustrative_config")"

# Hand-authored, keyed on each label's own catalogue name (the resolved
# name under the illustrative config above, for the five configurable
# ones) — see this script's own header for why this lives here rather
# than in the catalogue itself.
# shellcheck disable=SC2016 # backticks here are literal Markdown, not command substitution
METADATA_JSON='
{
  "pw::agent": {
    "applied_by": "The Implementer, onto the pull request it raises, from the `pr_label` field the claim loop stamped onto its work order; the Script'"'"'s own `pr_label_ensure` (lib/labels.sh) backstops it where that did not take.",
    "removing": "Every gatherer, and the `max_open_agent_prs` back-pressure limit, stop counting that pull request as the pipeline'"'"'s own."
  },
  "project-review": {
    "applied_by": "The project-review pipeline, onto every review pull request it raises.",
    "removing": "That pull request stops being distinguished from an implementation one, and starts counting against `max_open_agent_prs`."
  },
  "pw::enabler-escalation": {
    "applied_by": "The Enabler, onto every issue it files escalating a blocked item; also usable as `crash_loop_repo`/`pager_repo`'"'"'s own escalation label.",
    "removing": "The Enabler'"'"'s own duplicate guard stops finding the issue as an existing escalation, and may file a second one for the same block."
  },
  "pw::needs-refinement": {
    "applied_by": "The Script, projected while an issue'"'"'s refinement block is open; a human may also apply it by hand to flag an item themselves.",
    "removing": "The issue becomes selectable again once any other hold (e.g. `blocked`) also lifts."
  },
  "pw::refined": {
    "applied_by": "The Script, once the Refiner has written the issue a specification.",
    "removing": "Nothing re-applies it until the Refiner runs on that issue again; the specification already written stays in the issue regardless."
  },
  "pw::unvoided": {
    "applied_by": "A human, by hand on GitHub — no pipeline stage ever applies this one.",
    "removing": "The request to reconsider the void is withdrawn; removing it only ever undoes a human'"'"'s own ask."
  },
  "blocked": {
    "applied_by": "Hand-applied, or Script-projected under requirement 38b.",
    "removing": "The issue becomes selectable by scripts/gather-issues.sh again, unless another hold still applies."
  },
  "blocked:needs-refinement": {
    "applied_by": "Script-projected alongside `blocked`, naming why.",
    "removing": "Nothing reads this label on its own; remove `blocked` itself to make the issue selectable again."
  },
  "obsolete": {
    "applied_by": "A human only; no pipeline stage ever applies it.",
    "removing": "lib/void-guard.sh'"'"'s corroboration for voiding that draft pull request goes with it; nothing re-applies it automatically."
  },
  "pw::type:tech-debt": {
    "applied_by": "Whichever stage files the tech-debt issue (`gh issue create`, per AGENTS.md'"'"'s \"Tech debt\" workflow).",
    "removing": "The issue stops being found by scripts/gather-tech-debt.sh and by the `/td` skill'"'"'s dedup search, and D24'"'"'s trust anchor for treating its body as tech debt rather than untrusted content is withdrawn."
  },
  "pw::owner-decision": {
    "applied_by": "The Approver or Enabler, via lib/tech-debt-file.sh'"'"'s `techdebt_file_issue`.",
    "removing": "The Refiner stops treating the issue as owner-only, and may specify it to a stated default instead of declining with needs-refinement."
  },
  "pw::decision": {
    "applied_by": "The Enabler, when it takes a tactical decision under decide-tactical.",
    "removing": "scripts/sweep-decision-vetoes.sh stops finding the issue as a decision log to check for a veto."
  },
  "pw::pager": {
    "applied_by": "lib/pager.sh, when a fleet-level invariant fires.",
    "removing": "lib/pager.sh'"'"'s own dedup search and monitor-cycle.sh'"'"'s `--label pw::pager` listing stop finding the issue, and the pager'"'"'s own auto-close has no label left to clear."
  },
  "open-question": {
    "applied_by": "The Script'"'"'s landing gate (`landing_open_question_label_project`, lib/landing.sh), when a Reviewer round raises an open question (requirement 8f) — never the Reviewer itself; released the same way once the question is adjudicated.",
    "removing": "The landing gate stops treating the pull request as blocked by an open question."
  },
  "complexity:low": {
    "applied_by": "The Implementer, grading the work order it just finished.",
    "removing": "The Script falls back to its own default Reviewer-tier choice, since no grade is recorded."
  },
  "complexity:medium": {
    "applied_by": "The Implementer, grading the work order it just finished.",
    "removing": "The Script falls back to its own default Reviewer-tier choice, since no grade is recorded."
  },
  "complexity:high": {
    "applied_by": "The Implementer, grading the work order it just finished.",
    "removing": "The Script falls back to its own default Reviewer-tier choice, since no grade is recorded."
  }
}
'

if ! jq -e . >/dev/null 2>&1 <<<"$METADATA_JSON"; then
  echo "render-labels-table: METADATA_JSON is not valid JSON" >&2
  exit 1
fi

# render_rows ROLE [REVIEW_PR_LABEL]
render_rows() {
  labels_catalogue "$illustrative_config" "$schema_file" "$@"
}

all_rows="$( { render_rows target
               render_rows review "$review_pr_label"
               render_rows escalation
             } | awk -F'\t' '!seen[$1]++' | sort -t$'\t' -k1,1 )"

generate_table() {
  echo "| Label | Applied by | Meaning | Removing it does |"
  echo "|-------|------------|---------|-------------------|"
  while IFS=$'\t' read -r name _colour description; do
    [[ -z "$name" ]] && continue
    local meta applied_by removing
    meta="$(jq -c --arg name "$name" '.[$name] // null' <<<"$METADATA_JSON")"
    if [[ "$meta" == "null" ]]; then
      echo "render-labels-table: no metadata for label \`$name\` — add it to METADATA_JSON" >&2
      exit 1
    fi
    applied_by="$(jq -r '.applied_by' <<<"$meta")"
    removing="$(jq -r '.removing' <<<"$meta")"
    echo "| \`$name\` | $applied_by | $description | $removing |"
  done <<< "$all_rows"
}

render_file() {
  local file="$1"
  local temp_file="${file}.labels-table.tmp"

  local start_count end_count
  start_count=$(grep -cE "$(labels_table_start_re)" "$file" || true)
  end_count=$(grep -cE "$(labels_table_end_re)" "$file" || true)
  if (( start_count != 1 || end_count != 1 )); then
    echo "render-labels-table: $file does not contain exactly one <!-- labels-table:start --> / <!-- labels-table:end --> marker pair" >&2
    return 1
  fi

  # Explicit rc check, not reliance on `set -e`: this function is called as
  # `if ! render_file ...`, and set -e does not apply to a command whose
  # exit status a conditional is testing — so a failure inside
  # generate_table's subshell (a label with no METADATA_JSON entry,
  # surfaced by its own `exit 1`) would otherwise pass unnoticed here.
  local table_content
  if ! table_content="$(generate_table)"; then
    return 1
  fi

  awk -v content="$table_content" -v start="$(labels_table_start_re)" -v end="$(labels_table_end_re)" '
    $0 ~ start {
      print "<!-- labels-table:start -->"
      print content
      while (getline && $0 !~ end) {}
      print "<!-- labels-table:end -->"
      next
    }
    { print }
  ' "$file" > "$temp_file"

  if (( check_mode )); then
    if ! diff -q "$file" "$temp_file" >/dev/null 2>&1; then
      echo "render-labels-table: $file is stale" >&2
      rm "$temp_file"
      return 1
    fi
    rm "$temp_file"
  else
    mv "$temp_file" "$file"
  fi

  return 0
}

failed=0
for file in "${LABELS_TABLE_FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "render-labels-table: $file does not exist" >&2
    exit 1
  fi
  if ! render_file "$file"; then
    failed=1
  fi
done

if (( failed )); then
  exit 1
fi
if (( check_mode )); then
  echo "render-labels-table: all regions match lib/labels.sh"
fi
