#!/usr/bin/env bash
#
# lib/issue-file.sh — the two halves every issue filer in this codebase
# shares, written once: finding the issue an earlier filing already made,
# by a needle in its body, and creating one with the retry-without-label
# each filer performs. `_pager_create_issue` (lib/pager.sh),
# `techdebt_file_issue` (lib/tech-debt-file.sh), `monitor_create_issue`
# (monitor-cycle.sh) and `refile_perform` (lib/refile.sh) each carried its
# own copy of both before this file, and the copies had already diverged —
# one search capped at 20 and one at 200, one create validating the number
# it parsed and one not — so a fix to any of them reached only that one
# (review of PR #2344). What stays with each caller is what genuinely
# differs between them: which label the search narrows to and which the
# create applies, which state the search covers, and what to do when the
# search itself fails.
#
# Each of the three library files that use this one sources it itself,
# relative to its own location and guarded by `declare -F`, so each stays
# sourceable alone — test/pager.test.sh sources lib/pager.sh against a
# plain fixture, and lib/pager.sh's own header explains why that matters.
#
# Two variables carry a caller's context, declared `local` in the caller so
# they reach these functions and nothing after them:
#
#   ISSUE_FILE_GH      an array naming the command `gh` is run through —
#                      `(gh)` when unset; `(_techdebt_gh "$token")` in
#                      lib/tech-debt-file.sh, so the Approver's own App
#                      identity files its issues; `("$(_pager_gh)")` in
#                      lib/pager.sh, whose tests point PAGER_GH at a stub.
#   ISSUE_FILE_ERRLOG  where `gh`'s stderr and this file's own notes land —
#                      /dev/null when unset.

issue_file_gh() {
  "${ISSUE_FILE_GH[@]-gh}" "$@"
}

issue_file_err_log() {
  printf '%s' "${ISSUE_FILE_ERRLOG:-/dev/null}"
}

# issue_find_by_body REPO SEARCH NEEDLE [STATE] [LABEL] [LIMIT]
# One `gh issue list` in REPO — STATE (`open` unless given), narrowed to
# LABEL where one is given, `--search SEARCH`, and LIMIT (200 unless given:
# stated, never inherited, for the reason lib/tech-debt-file.sh's
# TECHDEBT_DEDUP_LIST_LIMIT states) — and the first issue it returns whose
# body contains NEEDLE. Prints "<number>\t<url>" and returns 0 when one is
# found; prints nothing and returns 1 when the listing came back and
# nothing in it matched; prints nothing and returns 2 when the listing
# itself failed — `gh` exiting non-zero, or answering anything but an
# array. The last is not "nothing found", and a caller that files on it
# files the very duplicate the search exists to prevent: whether that is
# the lesser harm is the caller's call, and each says which it chose.
issue_find_by_body() {
  local repo="$1" search="$2" needle="$3" state="${4:-open}" label="${5:-}" limit="${6:-200}"
  local list found
  local -a args=(issue list -R "$repo" --state "$state")
  [[ -n "$label" ]] && args+=(--label "$label")
  args+=(--search "$search" --limit "$limit" --json "number,url,body")
  list="$(issue_file_gh "${args[@]}" 2>>"$(issue_file_err_log)")" || return 2
  jq -e 'type == "array"' <<<"$list" >/dev/null 2>&1 || return 2
  found="$(jq -r --arg n "$needle" \
             'map(select((.body // "") | contains($n))) | first
              | if . == null then empty else "\(.number)\t\(.url)" end' <<<"$list" 2>/dev/null || true)"
  [[ -n "$found" ]] || return 1
  printf '%s' "$found"
}

# issue_create_with_retry REPO TITLE BODY_FILE [LABEL] [ASSIGNEE]
# One `gh issue create` in REPO, with LABEL and ASSIGNEE where given, and
# one retry without the label when the labelled create fails: `gh` resolves
# a label name to an id as part of the create, so a repository whose label
# catalogue the ensure pass (lib/labels.sh) has not reached yet fails the
# whole create, and the filing would otherwise be lost — the one outcome
# agent-ops#938 exists to prevent (agent-ops#1009 records the failure
# class). The retry is noted on the error log, since the unlabelled issue
# it leaves is invisible to every label-based reader and should at least be
# explicable afterwards. Prints "<number>\t<url>", parsed from `gh`'s own
# output, and returns 0; prints nothing and returns 1 when neither create
# produced an issue URL whose number parses.
issue_create_with_retry() {
  local repo="$1" title="$2" body_file="$3" label="${4:-}" assignee="${5:-}"
  local errlog raw url number
  local -a args=(issue create -R "$repo" --title "$title" --body-file "$body_file")
  errlog="$(issue_file_err_log)"
  [[ -n "$assignee" ]] && args+=(--assignee "$assignee")
  if [[ -n "$label" ]]; then
    raw="$(issue_file_gh "${args[@]}" --label "$label" 2>>"$errlog" || true)"
    if [[ -z "$raw" ]]; then
      printf 'issue_create_with_retry: labelled issue create failed for %s -- retrying unlabelled\n' \
        "$repo" >>"$errlog"
      raw="$(issue_file_gh "${args[@]}" 2>>"$errlog" || true)"
    fi
  else
    raw="$(issue_file_gh "${args[@]}" 2>>"$errlog" || true)"
  fi
  url="$(grep -oE 'https://github\.com/[A-Za-z0-9_./-]+/issues/[0-9]+' <<<"$raw" | tail -n1 || true)"
  [[ -n "$url" ]] || return 1
  number="${url##*/}"
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  printf '%s\t%s' "$number" "$url"
}
