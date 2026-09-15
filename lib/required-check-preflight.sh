#!/usr/bin/env bash
# shellcheck disable=SC2154  # `required_check_preflight_escalate` reads the cycle's own globals (`cycle_id`, `node_name`, `enabler_escalation_label`) — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally.
#
# lib/required-check-preflight.sh — the deterministic pre-flight half of
# issue #1543: name the owner-act prerequisite the moment a pull request's
# own diff deletes, or edits away, the workflow job that produces one of the
# base branch's required status checks — before or at pull-request time, not
# only once a downstream item happens to block on it.
#
# The motivating instance (PR #1503, retiring the register machinery):
# deleting `.github/workflows/tech-debt-register.yml` removed the `register`
# job, a required context on ruleset 18857310. GitHub evaluates a
# `pull_request` workflow from the head commit, so once the file is gone the
# context can never report again — every check that did run was green,
# `mergeStateStatus` sat `BLOCKED`, and nothing named the ruleset edit as a
# prerequisite until an unrelated item (#1529) happened to block on this one
# 6+ hours later, and #1540 escalated it only then. This file runs the same
# comparison at the one point the diff and the pull request both already
# exist — right after the Implementer's pull request is raised
# (agent-cycle.sh, the same moment `closing_keyword_gate` already runs) —
# instead of waiting for that.
#
# `lib/review-gate.sh`'s own backstop
# (`_review_gate_missing_required_contexts`) catches the same fact again at
# the Reviewer's `ready` handoff, as a safety net for a finding this file
# missed or a workflow edited after the Implementer's own pass — the two
# seams the issue asks for.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller (agent-cycle.sh runs under `set -euo pipefail`;
# a test, `set -uo pipefail`) owns those.
#
# Environment:
#   REQUIRED_CHECK_PREFLIGHT_GH  override `gh` (tests stub it).

# _required_check_preflight_job_ids
# Read a GitHub Actions workflow file on stdin, print one job id per line —
# the direct keys of a top-level `jobs:` map (each at 2-space indent,
# directly under a 0-indent `jobs:` line). A heuristic over the literal YAML
# text, not a parser: it recognises the ordinary shape — the one PR #1503's
# own `register` job was — and says nothing for a workflow whose `jobs:` is
# an inline flow mapping or otherwise indented differently, rather than
# guessing wrong. A job's context on a required-checks list is ordinarily its
# id (unless the job sets its own `name:`, a matrix expands it, or a
# workflow name is prefixed to disambiguate) — id matching covers the common
# case this issue's own precedent is; a mismatch on a rarer shape costs one
# missed finding, never a false escalation.
_required_check_preflight_job_ids() {
  awk '
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    in_jobs && /^[^[:space:]]/ { in_jobs = 0 }
    in_jobs && /^  [A-Za-z0-9_.-]+:/ {
      line = $0
      sub(/^  /, "", line)
      sub(/:.*/, "", line)
      print line
    }
  '
}

# _required_check_preflight_content SLUG PATH REF
# Print PATH's raw content at REF, or nothing on any failure — a path that
# did not exist at REF (the "new" side of a deletion) and an unreadable API
# are the same "nothing to extract" case to every caller here.
_required_check_preflight_content() {
  local slug="$1" path="$2" ref="$3" gh_bin="${REQUIRED_CHECK_PREFLIGHT_GH:-gh}"
  "$gh_bin" api "repos/$slug/contents/$path?ref=$ref" \
    --jq '.content | gsub("\n"; "") | @base64d' 2>/dev/null
}

# required_check_preflight_findings SLUG BASE_BRANCH NUMBER
# Print "<context>\t<file>" once per required status-check context on
# BASE_BRANCH whose only producing workflow job pull request NUMBER's diff
# removes — deletes the file outright, or edits it (or a rename target) to
# drop the job. Prints nothing when there is no such finding, or when the
# ruleset, the changed-file list, or a file's content could not be read: a
# fact about this node or GitHub's availability, not the pull request, the
# same non-blocking convention `review_gate_security_alerts` and this file's
# own ready-gate backstop (`lib/review-gate.sh`) already apply to an API they
# cannot ask.
#
# Everything this function has to say travels on stdout; its exit status is
# always 0, including — especially — on the path that actually finds
# something. Without the explicit `return 0` closing it, the status would be
# the inner per-context loop's last `grep … && printf …`, which is false
# whenever the removed job id does not happen to sort last among the
# `unique`-sorted required contexts. agent-cycle.sh assigns this function's
# output under `set -euo pipefail`, so that stray 1 aborted the Implementer
# stage in exactly the case requirement 56 exists for — findings printed,
# cycle killed before the escalation could be filed.
required_check_preflight_findings() {
  local slug="$1" base="$2" number="$3" gh_bin="${REQUIRED_CHECK_PREFLIGHT_GH:-gh}"
  local rules required files_json base_sha head_sha
  local status filename previous_filename old_path
  local old_content new_content old_ids new_ids removed_ids ctx

  [[ -n "$slug" && -n "$base" && "$number" =~ ^[0-9]+$ ]] || return 0

  rules="$("$gh_bin" api "repos/$slug/rules/branches/$base" 2>/dev/null)" || return 0
  jq -e 'type == "array"' <<<"$rules" >/dev/null 2>&1 || return 0
  required="$(jq -r '[.[] | select(.type == "required_status_checks")
                        | .parameters.required_status_checks[]?.context]
                      | unique[]' <<<"$rules" 2>/dev/null)"
  [[ -n "$required" ]] || return 0

  base_sha="$("$gh_bin" api "repos/$slug/pulls/$number" --jq '.base.sha' 2>/dev/null)" || return 0
  head_sha="$("$gh_bin" api "repos/$slug/pulls/$number" --jq '.head.sha' 2>/dev/null)" || return 0
  [[ -n "$base_sha" && -n "$head_sha" ]] || return 0

  files_json="$("$gh_bin" api --method GET "repos/$slug/pulls/$number/files" \
    --paginate -F per_page=100 2>/dev/null)" || return 0
  jq -e 'type == "array"' <<<"$files_json" >/dev/null 2>&1 || return 0

  while IFS=$'\t' read -r status filename previous_filename; do
    [[ "$filename" == .github/workflows/*.yml || "$filename" == .github/workflows/*.yaml ]] || continue
    case "$status" in
      removed|modified|renamed) ;;
      *) continue ;;
    esac

    old_path="$filename"
    if [[ "$status" == "renamed" && -n "$previous_filename" && "$previous_filename" != "null" ]]; then
      old_path="$previous_filename"
    fi

    old_content="$(_required_check_preflight_content "$slug" "$old_path" "$base_sha")"
    [[ -n "$old_content" ]] || continue
    old_ids="$(_required_check_preflight_job_ids <<<"$old_content")"
    [[ -n "$old_ids" ]] || continue

    if [[ "$status" == "removed" ]]; then
      new_ids=""
    else
      new_content="$(_required_check_preflight_content "$slug" "$filename" "$head_sha")"
      new_ids="$(_required_check_preflight_job_ids <<<"$new_content")"
    fi

    removed_ids="$(comm -23 <(sort -u <<<"$old_ids") <(sort -u <<<"$new_ids") 2>/dev/null)"
    [[ -n "$removed_ids" ]] || continue

    while IFS= read -r ctx; do
      [[ -n "$ctx" ]] || continue
      grep -qxF "$ctx" <<<"$removed_ids" && printf '%s\t%s\n' "$ctx" "$filename"
    done <<<"$required"
  done < <(jq -r '.[] | [.status, .filename, (.previous_filename // "")] | @tsv' <<<"$files_json" 2>/dev/null)

  # Not decoration — see the header. The loops above end on whatever their
  # last `grep` said, which is a fact about the last required context
  # inspected and never about whether this call succeeded.
  return 0
}

# required_check_preflight_escalate SLUG ITEM PR_URL BASE_BRANCH FINDINGS
# File (or find already-filed, via `create_escalation_issue`'s own dedup) the
# owner-act escalation for issue #1543's own precedent: PR_URL's diff deletes
# or edits away the workflow job producing a required status check, and only
# an owner can amend the ruleset to drop it. FINDINGS is
# `required_check_preflight_findings`'s own output, one "<context>\t<file>"
# per line; prints "<number>\t<url>" on success (or the existing escalation's,
# via the dedup), nothing on failure or when FINDINGS is empty.
#
# This is a thin body-composition wrapper around `create_escalation_issue`
# (lib/enabler.sh), not a new escalation route: that function is already
# called directly by several Script-side gates ahead of any Enabler
# engagement — lib/landing.sh's open-question escalation, lib/approver.sh's
# stale-review and re-staling escalations, lib/standdown.sh's auth-failure
# and freeze escalations — so raising one here, at pull-request time, follows
# the pipeline's own existing convention rather than inventing a second one.
required_check_preflight_escalate() {
  local slug="$1" item="$2" pr_url="$3" base="$4" findings="$5"
  local body_file title contexts

  [[ -n "$findings" ]] || return 1

  contexts="$(cut -f1 <<<"$findings" | sort -u | paste -sd, -)"
  body_file="$(mktemp)"
  {
    printf '## What the autonomous pipeline needs from you\n\n'
    # shellcheck disable=SC2016  # the backticks around %s/literal words are Markdown code spans, not command substitution.
    printf '%s deletes, or edits away, the workflow job producing a required status check on `%s`. GitHub evaluates a `pull_request` workflow from the head commit, so once this merges the context below can never report again and the merge queue holds it on "Expected — waiting for status to be reported" forever. Doing the ruleset edit now is harmless — this pull request, and every other one still carrying the workflow, keeps running it, only without gating — so the safe ordering never wedges the repository (standing decision, `docs/STANDING-DECISIONS.md`).\n\n' \
      "$pr_url" "$base"
    printf '## Required context(s) with no producing job left\n\n'
    while IFS=$'\t' read -r ctx file; do
      [[ -n "$ctx" ]] || continue
      # shellcheck disable=SC2016  # the backticks around %s are Markdown code spans, not command substitution.
      printf -- '- `%s` — was produced by `%s`\n' "$ctx" "$file"
    done <<<"$findings"
    printf '\n## What to do\n\n'
    # shellcheck disable=SC2016  # the backticks around %s/literal words are Markdown code spans, not command substitution.
    printf 'Drop the context(s) above from `%s`'"'"'s branch ruleset — the `required_status_checks` rule — before %s merges (issue #1543; #1540 is the precedent this generalises).\n' \
      "$base" "$pr_url"
    # shellcheck disable=SC2016  # the backticks around %s are Markdown code spans, not command substitution.
    printf '\n---\nItem: `%s` · pull request %s\nRaised by the Implementer stage (issue #1543) · cycle `%s` · node `%s`\n' \
      "$item" "$pr_url" "${cycle_id:-}" "${node_name:-}"
  } > "$body_file"

  title="Drop $contexts from $base's required status checks — $pr_url retires the producing workflow"
  create_escalation_issue "$slug" "$item" "$enabler_escalation_label" "$title" "$body_file"
}
