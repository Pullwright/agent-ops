#!/usr/bin/env bash
#
# lib/refile.sh — requirement 36f's reach (c): re-filing a misfiled item into
# the pipeline's own repository (`act: {"kind": "refile-to-pipeline-repo",
# "paths": [...]}`), and the corroboration the Script performs itself before
# it trusts that act. Sourced by agent-cycle.sh. `run_enabler_decide`
# (lib/enabler.sh) calls `refile_act_check` when the decide pass proposes the
# act; `run_pending_decision_acts` (lib/decision-veto.sh) calls `refile_act`
# once the veto window has passed, which re-checks and then performs it.
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
# neither a success nor a 404 — is never taken for either answer: at verdict
# time it refuses the act, since no decision exists yet to lose, and at act
# time it leaves the act waiting for a cycle that can read, since a decision
# that stood through its whole window is not retired over a read that failed.
#
# Environment: `pager_repo`/`crash_loop_repo` are agent-cycle.sh's own
# config reads (`decision_pipeline_repo` below); `cycle_dir`, `node_name` and
# `cycle_id` are the cycle's globals, read where present. REFILE_PATHS_MAX
# bounds how many paths one act may name (tests lower it).

# The reasons this file prints are Markdown for an escalation or a comment,
# and the backticks in them are literal.
# shellcheck disable=SC2016

# The filing and the search for an earlier filing are lib/issue-file.sh's,
# shared with every other filer here; sourced relative to this file so a
# test that sources lib/refile.sh alone gets them too.
if ! declare -F issue_create_with_retry >/dev/null 2>&1; then
  # shellcheck source=lib/issue-file.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/issue-file.sh"
fi

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

# refile_marker REPO ITEM
# The machine marker a copy's body carries, naming the original it was
# re-filed from: what a later cycle searches the pipeline's repository for.
refile_marker() {
  printf '<!-- agent-ops:refiled-from repo=%s item=%s -->' "$1" "$2"
}

# refile_paths_normalise PATHS_JSON
# The act's `paths`, checked for shape before anything reads them: a
# non-empty array of at most REFILE_PATHS_MAX strings, each a plain
# repository-relative path — no leading `/` or `-`, no `.` or `..` segment,
# no empty segment, no trailing `/`, nothing outside `[A-Za-z0-9._/-]` (a
# newline least of all: a path read line by line would be checked as two
# and carried as one) — since each one is spliced into a `gh api` URL and
# the pass that wrote it read untrusted text to get there. A leading `.` is
# allowed, so `.github/workflows/build.yml` and `.shellcheckrc` — a misfiled
# CI defect is a likely shape — pass. The check runs inside jq, on the array
# as carried, so what is checked is exactly what is carried. Prints the
# array, de-duplicated and sorted, and returns 0; or prints the first reason
# and returns 1.
refile_paths_normalise() {
  local paths_json="$1" verdict
  verdict="$(jq -r --argjson max "$REFILE_PATHS_MAX" '
    if type != "array" or length == 0 then "shape"
    elif length > $max then "count\t\(length)"
    else (first(.[] | select(type != "string"
                  or (test("\\A[A-Za-z0-9._][A-Za-z0-9._/-]*\\z") | not)
                  or test("//") or endswith("/")
                  or test("(^|/)\\.\\.?(/|$)"))) // null) as $bad
      | if $bad == null then "ok" else "bad\t\($bad | tojson)" end
    end' <<<"$paths_json" 2>/dev/null || printf 'shape')"
  case "$verdict" in
    ok) jq -c 'unique' <<<"$paths_json" ;;
    count*)
      printf 'the act names %s paths, more than the %s this check will read' \
        "${verdict#count$'\t'}" "$REFILE_PATHS_MAX"
      return 1 ;;
    bad*)
      printf 'the path %s is not a plain repository-relative path' "${verdict#bad$'\t'}"
      return 1 ;;
    *)
      printf 'the act names no paths — `paths` must be a non-empty array of repository-relative paths'
      return 1 ;;
  esac
}

# refile_path_state REPO PATH -> present | absent | unknown
# One contents read at REPO's default branch, asking for the `object` media
# type: with the default one the API answers 403 for a file between 1 MB
# and 100 MB, which would read as unknown here for a file that exists;
# `object` answers for every size the endpoint serves at all, with the
# content left out, and a directory answers the same way. `gh api` exits
# non-zero on any HTTP error and names the status on stderr; only a 404 is
# "absent". Everything else — a 403 from a rate limit, a 5xx, no network, a
# token the forge rejects — is "unknown": the fact is established or it is
# not, and the callers below say what each does with that.
refile_path_state() {
  local repo="$1" path="$2" err
  if err="$(gh api "repos/$repo/contents/$path" -H 'Accept: application/vnd.github.object+json' \
              --silent 2>&1 >/dev/null)"; then
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
# returns 1 where the fact is established and false (a path that exists
# where the item was filed, or is absent from the pipeline's repository
# too), or 3 where it could not be established at all. Two reads per path,
# item repository first, so an item that is not misfiled at all is refused
# on its first path without a read of the pipeline's repository.
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
        return 3 ;;
    esac
    state="$(refile_path_state "$pipeline_repo" "$p")"
    case "$state" in
      present) : ;;
      absent)
        printf '`%s` is absent from %s too, so there is nowhere the item belongs' "$p" "$pipeline_repo"
        return 1 ;;
      *)
        printf 'could not establish whether `%s` exists in %s' "$p" "$pipeline_repo"
        return 3 ;;
    esac
  done < <(jq -r '.[]' <<<"$paths_json" 2>/dev/null)
  return 0
}

# refile_act_shape REPO ITEM ACT_JSON
# The part of the check that costs no read: an issue-shaped item (a thread
# to copy and to close — a register id or a pull-request void shape has
# neither), a pipeline repository that is configured and is not the item's
# own, and paths that pass `refile_paths_normalise`. Prints the normalised
# paths and returns 0, or prints the reason and returns 1.
refile_act_shape() {
  local repo="$1" item="$2" act="$3" pipeline_repo paths
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
  printf '%s' "$paths"
}

# refile_act_check REPO ITEM ACT_JSON
# Everything a `refile-to-pipeline-repo` act must satisfy before it may
# stand: `refile_act_shape`, then `refile_paths_verify` holding for every
# path. Run at verdict time by run_enabler_decide, where any failure
# escalates, and again at act time through `refile_act` below, where the
# two kinds of failure part ways. Prints the normalised act (`{kind,
# paths}`, the paths as verified) and returns 0; or prints the reason and
# returns 1 where the act must not stand, or 3 where a read failed and
# nothing is established either way. The reason is written for the
# escalation a person then receives, naming the path and the repository
# that failed.
refile_act_check() {
  local repo="$1" item="$2" act="$3" paths reason rc=0
  if ! paths="$(refile_act_shape "$repo" "$item" "$act")"; then
    printf '%s' "$paths"
    return 1
  fi
  reason="$(refile_paths_verify "$repo" "$(decision_pipeline_repo)" "$paths")" || rc=$?
  if (( rc != 0 )); then
    printf '%s' "$reason"
    return "$rc"
  fi
  jq -nc --arg k "$REFILE_ACT_KIND" --argjson p "$paths" '{kind: $k, paths: $p}'
}

# refile_read_original REPO ITEM
# The original issue — title, body, state, labels, url — as one JSON object
# on stdout, returning 0; or nothing and 1 when it cannot be read (deleted,
# a transferred number, a read that failed). One read, and the cheapest
# refusal there is when the original turns out to be closed, so `refile_act`
# makes it before any contents read.
refile_read_original() {
  local repo="$1" item="$2" orig
  orig="$(gh issue view "$item" -R "$repo" --json title,body,state,labels,url \
            2>>"${cycle_dir:-/tmp}/refile.err")" || return 1
  jq -e 'type == "object" and (.title // "") != ""' <<<"$orig" >/dev/null 2>&1 || return 1
  printf '%s' "$orig"
}

# refile_find_copy PIPELINE_REPO REPO ITEM
# The copy an earlier cycle already filed for REPO#ITEM, if any, found by
# its marker: the search term is the visible `owner/repo#n` the provenance
# section carries, the marker itself (an HTML comment) is matched on the
# bodies that come back, and the search covers every state and a stated
# page of 200 — the pipeline's own repository cites items in exactly that
# form in escalations and decision logs, so a short page could push the
# copy off it. Prints "<number>\t<url>" and returns 0 when found; 1 when
# the search ran and found none; 2 when the search itself failed, which no
# caller here takes as "none" — filing on it is the second copy this
# function exists to prevent.
refile_find_copy() {
  local pipeline_repo="$1" repo="$2" item="$3"
  local ISSUE_FILE_ERRLOG="${cycle_dir:-/tmp}/refile.err"
  issue_find_by_body "$pipeline_repo" "\"$repo#$item\" in:body" "$(refile_marker "$repo" "$item")" all "" 200
}

# refile_perform REPO ITEM PIPELINE_REPO PATHS_JSON DECISION_URL [ORIG_JSON]
# The act itself, in two halves that must both hold before it counts as
# performed: file the copy in PIPELINE_REPO, then close the original with a
# pointer. ORIG_JSON is the original as `refile_read_original` printed it;
# omitted, it is read here. Prints `<number>\t<url>` of the copy and
# returns 0 once both halves have happened. Returns 1 with a reason on
# stdout where the act should wait for a later cycle — a read, a search or
# a write that failed; the next cycle re-checks the paths, finds any copy
# this one already filed through the marker, and retries only the half
# still owed — and 2 with a reason where it must never be taken: the
# original is already closed and no copy carries the marker, so someone
# acted first, and a second copy is the very duplicate this act exists to
# avoid. An original already closed *with* a marked copy in the pipeline's
# repository is the act itself, performed by a cycle that died between its
# close and its record, and counts as performed: the copy is printed and 0
# returned, so the record is written at last.
#
# What the copy carries, and what it does not: the original's title; its
# body with every `Blocked-by:` line dropped (those name the original
# repository's own issues and would point at the wrong ones here — the
# owner's own re-files dropped them too, poetic-fiddle#445) and every other
# bare `#n` reference qualified to `owner/repo#n`, so "see #445" still
# names the issue it meant and a `Fixes #n` the original carried is never a
# live closing keyword against this repository's issues; a trailing
# provenance section carrying the marker, the original's URL, the verified
# paths, the instant they were verified and the decision-log issue; and
# `pw::type:tech-debt` where the original carried it, retried once
# unlabelled where the labelled create fails (`issue_create_with_retry`,
# lib/issue-file.sh, the retry every filer here makes). No `refined` label
# and no block label: a fresh Refiner pass in the right repository is cheap
# insurance, and the original's own specification stays one link away.
refile_perform() {
  local repo="$1" item="$2" pipeline_repo="$3" paths_json="$4" decision_url="$5" orig="${6:-}"
  local ISSUE_FILE_ERRLOG="${cycle_dir:-/tmp}/refile.err"
  local state title url marker existing number copy_url paths_md body_file label comment ts rc=0

  if [[ -z "$orig" ]] && ! orig="$(refile_read_original "$repo" "$item")"; then
    printf 'could not read %s#%s to copy it' "$repo" "$item"
    return 1
  fi
  state="$(jq -r '.state // ""' <<<"$orig" 2>/dev/null || true)"
  existing="$(refile_find_copy "$pipeline_repo" "$repo" "$item")" || rc=$?
  if [[ "$state" != "OPEN" ]]; then
    case "$rc" in
      0) printf '%s' "$existing"; return 0 ;;
      2)
        printf 'could not search %s for an earlier copy of %s#%s, which is already closed' \
          "$pipeline_repo" "$repo" "$item"
        return 1 ;;
      *)
        printf '%s#%s is already closed and no copy of it in %s carries the marker, so someone acted first and there is nothing left to relocate' \
          "$repo" "$item" "$pipeline_repo"
        return 2 ;;
    esac
  fi
  if (( rc == 2 )); then
    printf 'could not search %s for an earlier copy of %s#%s, so filing now might file it twice' \
      "$pipeline_repo" "$repo" "$item"
    return 1
  fi
  title="$(jq -r '.title' <<<"$orig")"
  url="$(jq -r '.url // ""' <<<"$orig")"
  [[ -n "$url" ]] || url="https://github.com/$repo/issues/$item"
  marker="$(refile_marker "$repo" "$item")"
  paths_md="$(jq -r 'map("`" + . + "`") | join(", ")' <<<"$paths_json" 2>/dev/null || true)"

  if (( rc == 0 )); then
    IFS=$'\t' read -r number copy_url <<<"$existing"
  else
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    body_file="$(mktemp)"
    {
      jq -r '.body // ""' <<<"$orig" | grep -v -E '^[[:space:]]*Blocked-by:' \
        | sed -E "s,(^|[^A-Za-z0-9/#])#([0-9]+),\\1$repo#\\2,g" || true
      printf '\n---\n\n%s\n' "$marker"
      printf 'Re-filed by the autonomous pipeline from %s#%s (%s), where it was misfiled: every file it names (%s) is absent from `%s` and present in this repository, verified at %s. Decision of record: %s (requirement 36f'"'"'s delegate mandate, unvetoed through its veto window). Any `Blocked-by:` line of the original was dropped, since it named that repository'"'"'s issues, and every other bare `#n` reference in it now reads `%s#n`.\n' \
        "$repo" "$item" "$url" "$paths_md" "$repo" "$ts" "$decision_url" "$repo"
    } > "$body_file"
    label=""
    if jq -e '[.labels[]?.name] | index("pw::type:tech-debt") != null' <<<"$orig" >/dev/null 2>&1; then
      label="pw::type:tech-debt"
    fi
    existing="$(issue_create_with_retry "$pipeline_repo" "$title" "$body_file" "$label")" || existing=""
    rm -f "$body_file"
    if [[ -z "$existing" ]]; then
      printf 'could not file the copy in %s (see refile.err)' "$pipeline_repo"
      return 1
    fi
    IFS=$'\t' read -r number copy_url <<<"$existing"
  fi

  comment="$(pipeline_comment_header enabler-decide "${node_name:-}")

Re-filed in the correct repository as $copy_url: every file this issue names ($paths_md) lives there, not here. Closed here by the pipeline's own decision $decision_url (requirement 36f's delegate mandate), which stood unvetoed through its veto window. If this was wrong, both halves reverse by hand — close $copy_url and reopen this issue; reopening the decision's log issue does nothing now the act has run.

$(pipeline_comment_marker "${cycle_id:-}" enabler-decide)"
  if ! gh issue close "$item" -R "$repo" --reason "not planned" --comment "$comment" \
         >/dev/null 2>>"$ISSUE_FILE_ERRLOG"; then
    printf 'filed the copy as %s but could not close %s#%s — the close is retried next cycle' \
      "$copy_url" "$repo" "$item"
    return 1
  fi
  printf '%s\t%s' "$number" "$copy_url"
}

# refile_act REPO ITEM ACT_JSON DECISION_URL
# The whole of the act at act time, in the order that spends the fewest
# reads: the shape check (no read), the original (one read — an original a
# person closed during the window is the cheapest refusal there is, and it
# used to cost every contents read first), then the paths re-checked live
# (never carried from the verdict: the window between the two is hours long
# and either repository may have moved), then `refile_perform`. Prints
# `<number>\t<url>` and returns 0 when performed; prints the reason and
# returns 1 where the act waits for a later cycle (a read, a search or a
# write that failed — a path that could not be read among them) or 2 where
# it is refused for good (the shape wrong, a path that exists where the
# item was filed or is absent from the pipeline's repository, an original
# someone else closed).
refile_act() {
  local repo="$1" item="$2" act="$3" decision_url="$4" paths orig state reason rc=0
  if ! paths="$(refile_act_shape "$repo" "$item" "$act")"; then
    printf '%s' "$paths"
    return 2
  fi
  if ! orig="$(refile_read_original "$repo" "$item")"; then
    printf 'could not read %s#%s to copy it' "$repo" "$item"
    return 1
  fi
  state="$(jq -r '.state // ""' <<<"$orig" 2>/dev/null || true)"
  if [[ "$state" == "OPEN" ]]; then
    reason="$(refile_paths_verify "$repo" "$(decision_pipeline_repo)" "$paths")" || rc=$?
    case "$rc" in
      0) ;;
      3) printf '%s' "$reason"; return 1 ;;
      *) printf '%s' "$reason"; return 2 ;;
    esac
  fi
  refile_perform "$repo" "$item" "$(decision_pipeline_repo)" "$paths" "$decision_url" "$orig"
}
