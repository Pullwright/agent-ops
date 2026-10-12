#!/usr/bin/env bash
#
# lib/refile.sh — requirement 36f's reach (c): re-filing a misfiled item into
# the pipeline's own repository (`act: {"kind": "refile-to-pipeline-repo",
# "paths": [...]}`), and the corroboration the Script performs itself before
# it trusts that act. Sourced by agent-cycle.sh. `run_enabler_decide`
# (lib/enabler.sh) calls `refile_act_check` when the decide pass proposes the
# act; `run_pending_decision_acts` (lib/decision-veto.sh) calls it again once
# the veto window has passed, then `refile_perform`.
#
# The shape this exists for (poetic-fiddle#445, #480 and #516; the
# filing-side fix is agent-ops#2031): an Enabler examining a product
# repository's item notices a defect in the pipeline's own code and can only
# file it into that product repository, where no Implementer can reach the
# files it names. The item is then refined, selected, blocked ("no such files
# here"), examined and escalated to a person, whose whole act is to re-file
# it where it belongs and close the original with a pointer — GitHub refuses
# to transfer an issue between organisations. That act is mechanical, and
# both halves of it reverse (a copy can be closed, an original reopened),
# which is why it sits behind the veto window rather than in front of the
# owner (docs/STANDING-DECISIONS.md, 2026-10-12).
#
# What makes the act safe is that the Script, not the pass, establishes the
# one fact it rests on: every path the pass names is absent from the item's
# repository at its default branch and present in the pipeline's. The pass
# proposes; `gh api repos/<repo>/contents/<path>` decides. Anything the API
# cannot establish — a rate limit, a network failure, an answer that is
# neither a success nor a 404 — refuses the act rather than taking it, at
# verdict time and again at act time, because the window between the two is
# hours long and either repository may have moved meanwhile.
#
# Environment: `pager_repo`/`crash_loop_repo` are agent-cycle.sh's own
# config reads (`decision_pipeline_repo` below); `cycle_dir`, `node_name` and
# `cycle_id` are the cycle's globals, read where present. REFILE_PATHS_MAX
# bounds how many paths one act may name (tests lower it).

# The reasons this file prints are Markdown for an escalation or a comment,
# and the backticks in them are literal.
# shellcheck disable=SC2016

REFILE_ACT_KIND="refile-to-pipeline-repo"
REFILE_PATHS_MAX="${REFILE_PATHS_MAX:-20}"

# decision_pipeline_repo
# "The pipeline's own repository", resolved exactly as lib/pager.sh and
# monitor-cycle.sh resolve it: `pager_repo`, falling back to
# `crash_loop_repo`. Empty when neither is configured — which closes reach
# (c) outright, since there is nowhere to re-file into.
decision_pipeline_repo() {
  local r="${pager_repo:-}"
  [[ -n "$r" && "$r" != "null" ]] || r="${crash_loop_repo:-}"
  [[ "$r" != "null" ]] || r=""
  printf '%s' "$r"
}

# refile_paths_normalise PATHS_JSON
# The act's `paths`, checked for shape before anything reads them: a
# non-empty array of at most REFILE_PATHS_MAX strings, each a plain
# repository-relative path — no leading `/`, no `.` or `..` segment, no empty
# segment, no trailing `/` — since each one is spliced into a `gh api` URL
# and the pass that wrote it read untrusted text to get there. Prints the
# array, de-duplicated and sorted, and returns 0; or prints the first reason
# and returns 1.
refile_paths_normalise() {
  local paths_json="$1" n p
  if ! jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' \
         <<<"$paths_json" >/dev/null 2>&1; then
    printf 'the act names no paths — `paths` must be a non-empty array of repository-relative paths'
    return 1
  fi
  n="$(jq 'length' <<<"$paths_json" 2>/dev/null || printf '0')"
  if (( n > REFILE_PATHS_MAX )); then
    printf 'the act names %s paths, more than the %s this check will read' "$n" "$REFILE_PATHS_MAX"
    return 1
  fi
  while IFS= read -r p; do
    if [[ ! "$p" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ || "$p" == */ || "/$p/" == *//* \
          || "/$p/" == *"/../"* || "/$p/" == *"/./"* ]]; then
      printf 'the path "%s" is not a plain repository-relative path' "$p"
      return 1
    fi
  done < <(jq -r '.[]' <<<"$paths_json" 2>/dev/null)
  jq -c 'unique' <<<"$paths_json"
}

# refile_path_state REPO PATH -> present | absent | unknown
# One contents read at REPO's default branch. `gh api` exits non-zero on any
# HTTP error and names the status on stderr; only a 404 is "absent".
# Everything else — a 403 from a rate limit, a 5xx, no network, a token the
# forge rejects — is "unknown", and unknown refuses the act whichever
# direction it was checking: the fact is established or it is not.
refile_path_state() {
  local repo="$1" path="$2" err
  if err="$(gh api "repos/$repo/contents/$path" --silent 2>&1 >/dev/null)"; then
    printf 'present'
  elif grep -q 'HTTP 404' <<<"$err"; then
    printf 'absent'
  else
    printf 'unknown'
  fi
}

# refile_paths_verify ITEM_REPO PIPELINE_REPO PATHS_JSON
# The fact the act rests on, established per path and in both directions:
# absent from ITEM_REPO, present in PIPELINE_REPO. Prints nothing and returns
# 0 when every path holds; prints the first failing path's reason and
# returns 1. Two reads per path, item repository first, so an item that is
# not misfiled at all is refused on its first path without a read of the
# pipeline's repository.
refile_paths_verify() {
  local item_repo="$1" pipeline_repo="$2" paths_json="$3" p state
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    state="$(refile_path_state "$item_repo" "$p")"
    case "$state" in
      absent) : ;;
      present)
        printf '`%s` exists in %s, so the item is not misfiled on that path' "$p" "$item_repo"
        return 1 ;;
      *)
        printf 'could not establish whether `%s` exists in %s' "$p" "$item_repo"
        return 1 ;;
    esac
    state="$(refile_path_state "$pipeline_repo" "$p")"
    case "$state" in
      present) : ;;
      absent)
        printf '`%s` is absent from %s too, so there is nowhere the item belongs' "$p" "$pipeline_repo"
        return 1 ;;
      *)
        printf 'could not establish whether `%s` exists in %s' "$p" "$pipeline_repo"
        return 1 ;;
    esac
  done < <(jq -r '.[]' <<<"$paths_json" 2>/dev/null)
  return 0
}

# refile_act_check REPO ITEM ACT_JSON
# Everything a `refile-to-pipeline-repo` act must satisfy before it may
# stand, run at verdict time by run_enabler_decide and again at act time by
# run_pending_decision_acts: an issue-shaped item (a thread to copy and to
# close — a register id or a pull-request void shape has neither), a
# pipeline repository that is configured and is not the item's own, paths
# that pass `refile_paths_normalise`, and `refile_paths_verify` holding for
# every one of them. Prints the normalised act (`{kind, paths}`, the paths
# as verified) and returns 0, or prints the reason and returns 1. The reason
# is written for the escalation a person then receives, naming the path and
# the repository that failed.
refile_act_check() {
  local repo="$1" item="$2" act="$3" pipeline_repo paths reason
  if [[ ! "$item" =~ ^[0-9]+$ ]]; then
    printf 'item "%s" is not an issue — only an issue-shaped item has a thread to copy and to close' "$item"
    return 1
  fi
  pipeline_repo="$(decision_pipeline_repo)"
  if [[ -z "$pipeline_repo" ]]; then
    printf 'no pipeline repository is configured (pager_repo, falling back to crash_loop_repo), so there is nowhere to re-file into'
    return 1
  fi
  if [[ "$pipeline_repo" == "$repo" ]]; then
    printf '%s is the pipeline'"'"'s own repository, so the item is already where it belongs' "$repo"
    return 1
  fi
  if ! paths="$(refile_paths_normalise "$(jq -c '.paths // null' <<<"$act" 2>/dev/null || printf 'null')")"; then
    printf '%s' "$paths"
    return 1
  fi
  if ! reason="$(refile_paths_verify "$repo" "$pipeline_repo" "$paths")"; then
    printf '%s' "$reason"
    return 1
  fi
  jq -nc --arg k "$REFILE_ACT_KIND" --argjson p "$paths" '{kind: $k, paths: $p}'
}

# refile_perform REPO ITEM PIPELINE_REPO PATHS_JSON DECISION_URL
# The act itself, in two halves that must both hold before it counts as
# performed: file the copy in PIPELINE_REPO, then close the original with a
# pointer. Prints `<number>\t<url>` of the copy and returns 0 once both have
# happened. Returns 1 with a reason on stdout where the act should wait for
# a later cycle — a read or a write that failed; the next cycle re-checks the
# paths, finds any copy this one already filed through the marker below, and
# retries only the half still owed — and 2 with a reason where it must never
# be taken: the original is already closed, so someone acted first, and a
# second copy is the very duplicate this act exists to avoid.
#
# What the copy carries, and what it does not: the original's title; its
# body with every `Blocked-by:` line dropped (those name the original
# repository's own issues and would point at the wrong ones here — the
# owner's own re-files dropped them too, poetic-fiddle#445); a trailing
# provenance section carrying the marker, the original's URL, the verified
# paths, the instant they were verified and the decision-log issue; and
# `pw::type:tech-debt` where the original carried it, retried once
# unlabelled where the labelled create fails, exactly as techdebt_file_debt
# (lib/tech-debt-file.sh) does. No `refined` label and no block label: a
# fresh Refiner pass in the right repository is cheap insurance, and the
# original's own specification stays one link away.
refile_perform() {
  local repo="$1" item="$2" pipeline_repo="$3" paths_json="$4" decision_url="$5"
  local errlog="${cycle_dir:-/tmp}/refile.err"
  local orig state title url marker existing number copy_url paths_md body_file raw comment ts
  local label_args=()

  orig="$(gh issue view "$item" -R "$repo" --json title,body,state,labels,url 2>>"$errlog")" || orig=""
  if ! jq -e 'type == "object" and (.title // "") != ""' <<<"$orig" >/dev/null 2>&1; then
    printf 'could not read %s#%s to copy it' "$repo" "$item"
    return 1
  fi
  state="$(jq -r '.state // ""' <<<"$orig" 2>/dev/null || true)"
  if [[ "$state" != "OPEN" ]]; then
    printf '%s#%s is already closed, so there is nothing left to relocate — someone acted first' "$repo" "$item"
    return 2
  fi
  title="$(jq -r '.title' <<<"$orig")"
  url="$(jq -r '.url // ""' <<<"$orig")"
  [[ -n "$url" ]] || url="https://github.com/$repo/issues/$item"
  marker="<!-- agent-ops:refiled-from repo=$repo item=$item -->"
  paths_md="$(jq -r 'map("`" + . + "`") | join(", ")' <<<"$paths_json" 2>/dev/null || true)"

  # Idempotence: a copy an earlier cycle already filed, whose close half then
  # failed, is found by its marker and reused, never filed twice. The search
  # term is the visible `owner/repo#n` the provenance section carries; the
  # marker itself, an HTML comment, is matched on the bodies that come back.
  existing="$(gh issue list -R "$pipeline_repo" --state all --limit 20 \
                --search "\"$repo#$item\" in:body" --json number,url,body 2>>"$errlog" \
              | jq -r --arg m "$marker" \
                  'map(select((.body // "") | contains($m))) | first
                   | if . == null then empty else "\(.number)\t\(.url)" end' 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    IFS=$'\t' read -r number copy_url <<<"$existing"
  else
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    body_file="$(mktemp)"
    {
      jq -r '.body // ""' <<<"$orig" | grep -v -E '^[[:space:]]*Blocked-by:' || true
      printf '\n---\n\n%s\n' "$marker"
      printf 'Re-filed by the autonomous pipeline from %s#%s (%s), where it was misfiled: every file it names (%s) is absent from `%s` and present in this repository, verified at %s. Decision of record: %s (requirement 36f'"'"'s delegate mandate, unvetoed through its veto window). Any `Blocked-by:` line of the original was dropped, since it named that repository'"'"'s issues.\n' \
        "$repo" "$item" "$url" "$paths_md" "$repo" "$ts" "$decision_url"
    } > "$body_file"
    if jq -e '[.labels[]?.name] | index("pw::type:tech-debt") != null' <<<"$orig" >/dev/null 2>&1; then
      label_args=(--label pw::type:tech-debt)
    fi
    raw="$(gh issue create -R "$pipeline_repo" --title "$title" --body-file "$body_file" \
             ${label_args[@]+"${label_args[@]}"} 2>>"$errlog" || true)"
    if [[ -z "$raw" && ${#label_args[@]} -gt 0 ]]; then
      printf 'refile_perform: labelled issue create failed for %s -- retrying unlabelled\n' \
        "$pipeline_repo" >>"$errlog"
      raw="$(gh issue create -R "$pipeline_repo" --title "$title" --body-file "$body_file" \
               2>>"$errlog" || true)"
    fi
    rm -f "$body_file"
    copy_url="$(grep -oE 'https://github\.com/[A-Za-z0-9_./-]+/issues/[0-9]+' <<<"$raw" | tail -n1 || true)"
    if [[ -z "$copy_url" ]]; then
      printf 'could not file the copy in %s (see refile.err)' "$pipeline_repo"
      return 1
    fi
    number="${copy_url##*/}"
  fi

  comment="$(pipeline_comment_header enabler-decide "${node_name:-}")

Re-filed in the correct repository as $copy_url: every file this issue names ($paths_md) lives there, not here. Closed here by the pipeline's own decision $decision_url (requirement 36f's delegate mandate), which stood unvetoed through its veto window; reopening that decision's log issue is the lever if this was wrong.

$(pipeline_comment_marker "${cycle_id:-}" enabler-decide)"
  if ! gh issue close "$item" -R "$repo" --reason "not planned" --comment "$comment" \
         >/dev/null 2>>"$errlog"; then
    printf 'filed the copy as %s but could not close %s#%s — the close is retried next cycle' \
      "$copy_url" "$repo" "$item"
    return 1
  fi
  printf '%s\t%s' "$number" "$copy_url"
}
