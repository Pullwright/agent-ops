#!/usr/bin/env bash
#
# lib/tech-debt-file.sh — file deferred work on the Script's own behalf
# (agent-ops#631), for a stage that must never write to GitHub or a branch
# itself: the Approver ("What you must never do": never write code, push,
# amend the branch, or write to GitHub at all) and the Enabler (same rule,
# and it runs with no clone of any repo at all). Both may set `file_debt` or
# `file_issue` in their final JSON; the Script is what actually files it,
# under the calling stage's own identity where one applies.
#
# A tokenless call (TOKEN omitted) strips any inherited GH_TOKEN so a
# pipeline-host caller always uses the ordinary `gh auth login` identity —
# see _techdebt_gh below. A caller running under GitHub Actions
# (GITHUB_ACTIONS=true) has no such stored login — GH_TOKEN is its only
# credential — so it MUST pass TOKEN; _techdebt_gh fails loudly rather than
# running unauthenticated when it doesn't (agent-ops#2722). The strip happens
# in a subshell (`( unset GH_TOKEN; gh "$@" )`), never via `env -u`, so the
# bare `gh` word still resolves to lib/github-limit.sh's own `gh` shell-function
# shadow where that library has been sourced ahead of this one, and a
# tokenless call keeps that library's rate-limit wait (agent-ops#2732) — `env`
# is an external binary and would exec the `gh` binary directly, losing it.
#
# techdebt_file_issue REPO ITEM_REF TITLE BODY_FILE [TOKEN] [DEFAULT_FIX] \
#                      [OWNER_DECISION]
#   Files one plain GitHub issue, or returns an existing one that already
#   covers ITEM_REF. No label or assignee — unlike an escalation
#   (create_escalation_issue) this is not addressed at a specific human and
#   is legitimate autonomous work for a later cycle to pick up, not a
#   request excluded from the `issues` source. Prints "<number>\t<url>" on
#   success; prints nothing and returns 1 otherwise.
#
#   A caller running under GitHub Actions (GITHUB_ACTIONS=true) MUST pass
#   TOKEN — see _techdebt_gh below for why an omitted TOKEN fails loudly
#   there instead of running unauthenticated.
#
#   DEFAULT_FIX/OWNER_DECISION (agent-ops#938): see techdebt_default_section
#   below for what they add to the filed body, and pw::owner-decision for
#   what OWNER_DECISION additionally applies here — a fresh issue only; the
#   dedup hit above returns the existing issue untouched, label included. A
#   refused labelled create is retried once without the label, so a repository
#   that has not had `pw::owner-decision` ensured yet still gets its issue.
#   The dedup search and that create are lib/issue-file.sh's
#   `issue_find_by_body`/`issue_create_with_retry`, shared with every other
#   filer; a dedup search that fails outright files anyway, noted on the
#   error log, because this filing is a stage verdict's one chance (below).
#
# techdebt_file_debt REPO TITLE BODY PROVENANCE [TOKEN] [DEFAULT_FIX] \
#                     [OWNER_DECISION]
#   Files TITLE/BODY as a GitHub issue in REPO labelled `pw::type:tech-debt`
#   (D15 as revised, agent-ops#869/#872/#874) — the same trust anchor
#   scripts/gather-tech-debt.sh reads to serve the band, and the one
#   `lib/labels.sh` ensures exists in every target repository. Deduped first
#   against REPO's own open `pw::type:tech-debt` issues by normalised title
#   (_techdebt_title_dedup_match, below) or by PROVENANCE naming the same
#   pull request as an existing issue's own body (_techdebt_pr_dedup_match,
#   agent-ops#2576 — catches two findings worded differently against the
#   same PR, which the title check alone misses): either hit gets
#   BODY/PROVENANCE as a comment instead of a second filing, the "don't file
#   a duplicate" outcome applied automatically here. That search states its
#   own page cap (TECHDEBT_DEDUP_LIST_LIMIT, below) rather than inheriting
#   `gh`'s default of 30. Prints "<number>\t<url>" on
#   success — the new issue's, or the matched one's — and prints nothing and
#   returns 1 otherwise.
#
#   A caller running under GitHub Actions (GITHUB_ACTIONS=true) MUST pass
#   TOKEN — see _techdebt_gh below for why an omitted TOKEN fails loudly
#   there instead of running unauthenticated.
#
#   Retired by this move (agent-ops#874): the `td/<id>` reservation
#   (scripts/reserve-tech-debt-id.pl), the `td-record/<id>` filing branch,
#   the filing pull request, and `_techdebt_unfile`'s rollback of both —
#   filing is now the one API call techdebt_file_issue already makes for a
#   plain issue, plus the label and the dedup rule above. There is no
#   multi-step write left to half-finish, so there is no cleanup path either:
#   a create either succeeds or it doesn't, and a repository that does not
#   yet carry `pw::type:tech-debt` (the label-ensure pass has not reached it
#   yet) gets one retry without the label rather than a lost filing — logged
#   to errlog, the same shape techdebt_file_issue's own `pw::owner-decision`
#   retry already has. Nothing reconciles the result: the unlabelled issue is
#   invisible by construction to every label-based reader of this band,
#   including the archive mirror's own audits (agent-ops#1223).
#
# TECHDEBT_RECORD_BRANCH_PREFIX — no longer minted by this file
# (agent-ops#874 retired techdebt_file_debt's own td-record/<id> branch), but
# kept here as a constant rather than deleted: scripts/sweep-orphan-branches.sh
# and scripts/publish-tech-debt-archive.sh both source this file for it, to
# sweep and audit any td-record/<id> branch/pull request a pre-#874 filing
# already left behind, in a target repository this pipeline still gathers
# from. Deleting the constant would break both scripts' own sourcing rather
# than the (now dormant) minting it used to name.
# shellcheck disable=SC2034  # read by scripts/sweep-orphan-branches.sh and scripts/publish-tech-debt-archive.sh, which source this file for it
readonly TECHDEBT_RECORD_BRANCH_PREFIX="td-record/"

# TECHDEBT_DEDUP_LIST_LIMIT — the page cap techdebt_file_debt's dedup search
# states rather than inherits, for the reason lib/candidate-gather.sh's own
# `gh issue list` states its: `gh`'s undeclared default of 30 truncates the
# listing silently, and a truncated listing is indistinguishable from a
# complete one. The direction of harm here is not mild — a dedup that cannot
# see an issue files a duplicate against it, the one outcome the dedup exists
# to prevent — and it does not self-heal, because the listing is newest-first
# and the debt most likely to be re-noticed is the oldest. agent-ops alone
# carries well over a hundred open `pw::type:tech-debt` issues, so the
# inherited cap would have hidden most of its own register from every filing.
# A listing that comes back *at* the cap is logged to the error log rather
# than passed off as complete.
TECHDEBT_DEDUP_LIST_LIMIT="${TECHDEBT_DEDUP_LIST_LIMIT:-500}"

# TOKEN, given to either function, files under that identity
# (GH_TOKEN="$TOKEN") rather than the ordinary pipeline login — the
# Approver's own posture never writes to GitHub under the pipeline's own
# account, so its calls always pass the Approver App token already minted
# for posting its review (lib/approver-token.sh). The Enabler has no
# App identity of its own and always omits TOKEN, filing under the ordinary
# pipeline login exactly as create_escalation_issue already does.

# The dedup search and the create-with-retry both functions make are
# lib/issue-file.sh's, shared with every other filer; sourced relative to
# this file so a script that sources lib/tech-debt-file.sh alone gets them,
# and guarded so a caller that sourced lib/issue-file.sh first is left alone.
if ! declare -F issue_create_with_retry >/dev/null 2>&1; then
  # shellcheck source=lib/issue-file.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/issue-file.sh"
fi

# _techdebt_gh TOKEN ARGS...
# Run `gh` ARGS..., under TOKEN's identity if non-empty, the ordinary
# pipeline login otherwise — explicitly unset for that call, in a subshell
# (`( unset GH_TOKEN; gh "$@" )`), never merely left alone, so a GH_TOKEN this
# process happened to inherit from its own environment can never leak into a
# call this function was asked to make under the ordinary login. The subshell
# form, not `env -u GH_TOKEN`, is deliberate: `env` is an external binary and
# would exec the `gh` binary straight from PATH, never lib/github-limit.sh's
# own `gh` shell-function shadow, losing that library's rate-limit wait
# (agent-ops#2732). The subshell keeps the bare `gh` word resolving to
# whichever `gh` — function or binary — is in scope where this function is
# sourced, exactly as the token branch above already does.
#
# Under GitHub Actions (GITHUB_ACTIONS=true) there is no stored `gh auth
# login` identity to fall back to — GH_TOKEN is the only credential a
# workflow run has — so a tokenless call there would strip the one
# credential available and fail unauthenticated with no clue why
# (agent-ops#2722). Caught here instead: fail fast and loudly, before `gh`
# is ever invoked, rather than let that happen silently. This does not apply
# outside Actions, where the tokenless path's strip-and-use-the-stored-login
# contract is the one it's meant to have.
_techdebt_gh() {
  local token="$1"; shift
  if [[ -n "$token" ]]; then
    GH_TOKEN="$token" gh "$@"
  elif [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf '_techdebt_gh: no TOKEN given under GITHUB_ACTIONS=true -- refusing to strip the only credential (GH_TOKEN) available here\n' >&2
    return 1
  else
    ( unset GH_TOKEN; gh "$@" )
  fi
}

# _techdebt_err_log
# Where diagnostics from either function land — cycle_dir when the caller
# has one (both stages do by the time either function is ever called), /tmp
# as a last resort so a stray call from a test or a future caller with no
# cycle_dir still has somewhere to put stderr rather than losing it.
_techdebt_err_log() {
  printf '%s' "${cycle_dir:-/tmp}/tech-debt-file.err"
}

# techdebt_default_section DEFAULT_FIX [OWNER_DECISION]
# The `## Default` section every filed body carries (agent-ops#938): the
# option the filer would take (DEFAULT_FIX, one sentence), or `not stated`
# when the filer's verdict carried neither DEFAULT_FIX nor an OWNER_DECISION
# of exactly "true" — a malformed verdict is filed anyway rather than lost,
# so the caller (lib/approver.sh, lib/enabler.sh) logs the warning that
# distinguishes this fallback from a genuine, single-option filing that never
# needed a default at all. OWNER_DECISION "true" adds `Owner decision: yes`
# on its own line beside the heading — techdebt_file_issue applies the
# `pw::owner-decision` label instead, since a label, not body text, is what a
# later gatherer can trust (lib/labels.sh's own comment on why
# `pw::type:tech-debt` is a label and not a body convention applies here
# identically). Ends with a trailing newline so a caller can concatenate it
# straight onto a body that may or may not already end with one.
techdebt_default_section() {
  local default_fix="$1" owner_decision="${2:-false}" heading
  if [[ -n "$default_fix" ]]; then
    heading="## Default: $default_fix"
  else
    heading="## Default: not stated"
  fi
  if [[ "$owner_decision" == "true" ]]; then
    printf '%s\nOwner decision: yes\n' "$heading"
  else
    printf '%s\n' "$heading"
  fi
}

# techdebt_file_issue REPO ITEM_REF TITLE BODY_FILE [TOKEN] [DEFAULT_FIX] \
#                      [OWNER_DECISION]
techdebt_file_issue() {
  local repo="$1" item_ref="$2" title="$3" body_file="$4" token="${5:-}" \
        default_fix="${6:-}" owner_decision="${7:-false}"
  local existing rc=0 body_content combined_file label="" result
  local ISSUE_FILE_GH=(_techdebt_gh "$token") ISSUE_FILE_ERRLOG
  ISSUE_FILE_ERRLOG="$(_techdebt_err_log)"
  existing="$(issue_find_by_body "$repo" "$item_ref" "$item_ref" open "" 200)" || rc=$?
  if (( rc == 0 )); then
    printf '%s' "$existing"
    return 0
  fi
  # A dedup search that failed outright (not "none found": `gh` exited
  # non-zero, or answered something other than an array) files anyway, noted
  # on the error log. This filing is a stage verdict's one chance — the
  # verdict is consumed with its cycle and nothing retries a `file_issue` —
  # so a possible duplicate, which the body-reference convention keeps
  # visible, is the lesser harm against a filing lost in silence.
  # lib/pager.sh and lib/refile.sh make the opposite choice for the same
  # helper, because each of them is retried on a later pass.
  if (( rc == 2 )); then
    printf 'techdebt_file_issue: %s dedup search failed -- filing without it\n' "$repo" >>"$ISSUE_FILE_ERRLOG"
  fi
  body_content="$(cat "$body_file" 2>/dev/null || true)"
  combined_file="$(mktemp)"
  # OWNER_DECISION omitted from techdebt_default_section here, deliberately:
  # for an issue, the `pw::owner-decision` label below is what a later
  # gatherer trusts, the same reason `pw::type:tech-debt` is a label and not
  # a body convention — the body stays untrusted data even though this
  # filing call is itself trusted (lib/labels.sh's own comment).
  printf '%s\n\n%s' "$body_content" "$(techdebt_default_section "$default_fix")" \
    > "$combined_file"
  [[ "$owner_decision" == "true" ]] && label="pw::owner-decision"
  # One retry without the label (`issue_create_with_retry`), exactly as
  # requirement 36a's escalation contract and create_escalation_issue
  # (lib/enabler.sh) already do: `gh` resolves a label name to an id as part
  # of the create, so a repository that has not had `pw::owner-decision`
  # ensured yet fails the whole create and the filing is lost — the one
  # outcome agent-ops#938 exists to prevent, and the failure class
  # agent-ops#1009 already records for this file's own `gh pr create
  # --label`. Losing the label costs the Refiner its marker (the issue reads
  # to a later pass as a legacy no-marker item); losing the create costs the
  # filing itself.
  result="$(issue_create_with_retry "$repo" "$title" "$combined_file" "$label")" || result=""
  rm -f "$combined_file"
  [[ -n "$result" ]] || return 1
  printf '%s' "$result"
}

# _techdebt_normalize_title TITLE
# Lower-cased, punctuation folded to spaces, runs of whitespace collapsed.
# Title normalisation is the whole of the dedup test here, so it is spelled
# out in this file rather than shared: the only "is this title already
# tracked" question the pipeline still asks is this one, against REPO's live
# `pw::type:tech-debt` issues.
_techdebt_normalize_title() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

# _techdebt_extract_pr_url PROVENANCE
# Every techdebt_file_debt caller's own PROVENANCE sentence embeds the
# literal pull-request URL the finding was raised against (lib/approver.sh:
# "while the Approver was judging $pr_url"; lib/merge-observed.sh: "while
# the Reviewer was examining $pr_url, whose subject merged mid-pass") except
# the Enabler's (lib/enabler.sh: "during an Enabler engagement on $e_item
# (cycle $cycle_id)"), which names an item reference, not a PR. Printing the
# URL substring rather than matching the whole sentence keeps this robust to
# either caller's own wording; printing nothing when none is present (the
# Enabler's case) leaves the PR-match check below a no-op for it, same as
# before this existed.
_techdebt_extract_pr_url() {
  local provenance="$1"
  if [[ "$provenance" =~ (https://github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# _techdebt_pr_dedup_match PR_URL LIST_JSON
# PR_URL is a pull-request URL as _techdebt_extract_pr_url prints it;
# LIST_JSON is a JSON array of `{number, url, title, body}`. Prints the
# `number` of the first entry whose own body names that same pull
# request — every filed body carries its PROVENANCE line verbatim
# (techdebt_file_debt's own combined_file below), so a prior filing against
# the same pull request always carries that same URL somewhere in its body,
# regardless of how differently the two findings are titled (agent-ops#2576:
# #2573/#2574 described the same fault against the same PR in unrelated
# words). Prints nothing on no match.
#
# This same-PR key alone is deliberate, not a narrower "same PR, same
# gate/file" match: two genuinely distinct findings an Approver raises
# against the same pull request across different Reviewer rounds still
# collapse into one issue's comment thread rather than two, an accepted,
# rare tradeoff rather than a defect (agent-ops#2590) — it keeps this
# function symmetric with techdebt_file_issue's own unconditional
# per-pull-request dedup.
#
# The comparison is boundary-guarded on its right, never a bare substring
# test: `.../pull/25` is a plain substring of `.../pull/2567`, so a bare
# test would dedup a filing raised against #25 into an issue naming only
# #2567 — silently, as a comment on an unrelated issue, with
# `tech-debt-filed` logging that issue's number as though it were the
# match. A left guard is not needed, because PR_URL begins at the scheme
# and so can only ever occur at a URL's own start. Trailing path or
# fragment (`/files`, `#issuecomment-…`) still matches: that is the same
# pull request.
_techdebt_pr_dedup_match() {
  local pr_url="$1" list_json="$2" number body
  while IFS=$'\t' read -r number body; do
    [[ -n "$number" ]] || continue
    case "$body" in
      *"$pr_url") printf '%s' "$number"; return 0 ;;
      *"$pr_url"[!0-9]*) printf '%s' "$number"; return 0 ;;
    esac
  done < <(jq -r '.[] | [.number, (.body // "")] | @tsv' <<<"$list_json" 2>/dev/null)
}

# _techdebt_title_dedup_match NEEDLE LIST_JSON
# NEEDLE is an already-normalized title; LIST_JSON is a JSON array of
# `{number, url, title}`. Prints the `number` of the first entry whose own
# normalized title equals NEEDLE, or — both at least eight normalized
# characters, a containment floor so a short, generic title cannot match by
# containment inside an unrelated long one — contains it or is contained by
# it. Prints nothing on no match.
_techdebt_title_dedup_match() {
  local needle="$1" list_json="$2" allow_contains=0 hay number title
  [[ ${#needle} -ge 8 ]] && allow_contains=1
  while IFS=$'\t' read -r number title; do
    [[ -n "$number" ]] || continue
    hay="$(_techdebt_normalize_title "$title")"
    [[ -n "$hay" ]] || continue
    if [[ "$hay" == "$needle" ]]; then
      printf '%s' "$number"
      return 0
    fi
    if (( allow_contains )) && [[ ${#hay} -ge 8 ]] \
       && [[ "$hay" == *"$needle"* || "$needle" == *"$hay"* ]]; then
      printf '%s' "$number"
      return 0
    fi
  done < <(jq -r '.[] | [.number, .title] | @tsv' <<<"$list_json" 2>/dev/null)
}

# techdebt_file_debt REPO TITLE BODY PROVENANCE [TOKEN] [DEFAULT_FIX] \
#                     [OWNER_DECISION]
techdebt_file_debt() {
  local repo="$1" title="$2" body="$3" provenance="$4" token="${5:-}" \
        default_fix="${6:-}" owner_decision="${7:-false}"
  local errlog needle pr_url_needle list list_n match_number match_reason match_url
  local combined_file result
  local ISSUE_FILE_GH=(_techdebt_gh "$token") ISSUE_FILE_ERRLOG
  errlog="$(_techdebt_err_log)"
  ISSUE_FILE_ERRLOG="$errlog"

  needle="$(_techdebt_normalize_title "$title")"
  pr_url_needle="$(_techdebt_extract_pr_url "$provenance")"
  if [[ -n "$needle" || -n "$pr_url_needle" ]]; then
    list="$(_techdebt_gh "$token" issue list -R "$repo" --label pw::type:tech-debt \
              --state open --limit "$TECHDEBT_DEDUP_LIST_LIMIT" --json number,url,title,body \
              2>>"$errlog" || true)"
    if jq -e 'type == "array"' <<<"$list" >/dev/null 2>&1; then
      list_n="$(jq 'length' <<<"$list" 2>/dev/null || printf '0')"
      # Never a silent cap: a listing at the limit is one this search cannot
      # prove complete, so a duplicate filed past it is at least explicable
      # afterwards rather than invisible.
      if [[ "$list_n" =~ ^[0-9]+$ ]] && (( list_n >= TECHDEBT_DEDUP_LIST_LIMIT )); then
        printf 'techdebt_file_debt: %s dedup search came back at the %s cap -- an older open issue past it is not deduped against\n' \
          "$repo" "$TECHDEBT_DEDUP_LIST_LIMIT" >>"$errlog"
      fi
      match_number="" match_reason=""
      if [[ -n "$needle" ]]; then
        match_number="$(_techdebt_title_dedup_match "$needle" "$list")"
        [[ -n "$match_number" ]] && match_reason="title matches"
      fi
      # A title match and a PR match are each sufficient on their own
      # (agent-ops#2576) -- only fall back to the PR check once the title
      # check has already missed, since either hit is treated identically
      # from here on.
      if [[ -z "$match_number" && -n "$pr_url_needle" ]]; then
        match_number="$(_techdebt_pr_dedup_match "$pr_url_needle" "$list")"
        [[ -n "$match_number" ]] && match_reason="same PR"
      fi
      if [[ -n "$match_number" ]]; then
        match_url="$(jq -r --argjson n "$match_number" \
          'map(select(.number == $n)) | first | .url // empty' <<<"$list" 2>/dev/null || true)"
        combined_file="$(mktemp)"
        printf '%s\n\n%s\n%s\n' "$body" "$(techdebt_default_section "$default_fix" "$owner_decision")" \
          "$provenance" > "$combined_file"
        _techdebt_gh "$token" issue comment "$match_number" -R "$repo" \
          --body-file "$combined_file" >/dev/null 2>>"$errlog" || true
        rm -f "$combined_file"
        printf 'techdebt_file_debt: %s %s open issue #%s -- commented instead of filing\n' \
          "$repo" "$match_reason" "$match_number" >>"$errlog"
        printf '%s\t%s' "$match_number" "$match_url"
        return 0
      fi
    fi
  fi

  combined_file="$(mktemp)"
  printf '%s\n\n%s\n%s\n' "$body" "$(techdebt_default_section "$default_fix" "$owner_decision")" \
    "$provenance" > "$combined_file"
  # A repository whose `pw::type:tech-debt` label the ensure pass (lib/labels.sh)
  # has not reached yet fails the whole labelled create -- `gh` resolves a
  # label name to an id as part of it -- so `issue_create_with_retry` retries
  # once unlabelled rather than losing the filing, exactly as
  # techdebt_file_issue's own `pw::owner-decision` retry above, and notes the
  # retry on the error log. Nothing reconciles the result: the unlabelled
  # issue stays invisible to every label-based reader of this band, including
  # the archive mirror's own audits (agent-ops#1223).
  result="$(issue_create_with_retry "$repo" "$title" "$combined_file" pw::type:tech-debt)" || result=""
  rm -f "$combined_file"
  [[ -n "$result" ]] || return 1
  printf '%s' "$result"
}
