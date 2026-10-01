#!/usr/bin/env bash
#
# lib/pipeline-marker.sh — the whole envelope every pull-request or issue
# comment this system posts wraps its own prose in: a visible header naming
# which Actor wrote it and from which node (requirement 3f), and an invisible
# marker proving to gather-abandoned-drafts.sh that the write was the
# pipeline's own (requirement 3e; TD26072605).
#
# The header exists because every pipeline write lands under `warwickallen`,
# the human's own GitHub account — filtering by comment author cannot tell a
# human's comment from the pipeline's, so a human scanning a PR or issue
# thread has no other way to tell who said what, including which comments are
# their own. `pipeline_comment_header` prints that leading line; a prompt
# cannot source it (a model reads prose, not shell), so it is one of the three
# places that spell its literal form out — see test/comment-identity.test.sh.
#
# `updatedAt` on a pull request moves for anything at all — a push, a comment,
# a label edit — and gather-abandoned-drafts.sh used to trust it wholesale as
# "somebody is on this". But when *this system* is the one touching the PR,
# that is usually evidence the opposite just happened: a stage gave up and
# left a note, or an Enabler diagnosed a stall and said so. Filtering by
# comment author cannot separate the two cases — every write happens under the
# same GitHub account this system runs as — so the marker stamps *what the
# pipeline itself wrote*, the way the Vercel bot marks its own comments
# idempotent. gather-abandoned-drafts.sh discounts marker-carrying comments
# when computing a PR's last real activity; label edits are discounted
# unconditionally there; a human's comment carries no marker and always
# counts.
#
# One definition (requirement 34a): agent-cycle.sh and review-cycle.sh stamp
# their own PR comments by calling pipeline_comment_marker and
# pipeline_comment_header, and scripts/gather-abandoned-drafts.sh sources this
# same file and matches on PIPELINE_COMMENT_MARKER_PREFIX, so that write side
# and the read side cannot drift apart. The Implementer's, Enabler's,
# Reviewer's and Refiner's comment instructions (prompts/implementer.md,
# prompts/enabler.md, prompts/reviewer.md, prompts/refiner.md) are the one
# place the strings have to be spelled out rather than sourced, so
# test/abandoned-drafts.test.sh and test/comment-identity.test.sh assert all
# four prompts still carry the forms defined here, which is what stops a change
# to them silently un-marking (or un-attributing) every comment those four
# stages write.
#
# An HTML comment renders invisibly on GitHub; the header is deliberately the
# opposite — GitHub always renders the top of a comment and truncates the
# middle of a long one, so leading with it is the only placement reliably
# visible without expanding anything.

# The fixed, greppable prefix every marker starts with. Match on this
# substring, never on the full pipeline_comment_marker output (which also
# carries a cycle id and an actor) — a fresh cycle id must not stop a comment
# being recognised as the pipeline's own, and neither must an actor token this
# file's own map has not learned about yet.
PIPELINE_COMMENT_MARKER_PREFIX='<!-- agent-ops:pipeline-comment'

# pipeline_actor_label TOKEN
# The display name for an Actor token, matching the two specs' *Actors*
# sections and the vocabulary dashboard/index.html's ACTOR map already uses.
# Fails open on an unknown token — prints it raw — the same convention
# dashboard/index.html documents for its own actor map, so an Actor added
# later degrades to its bare token rather than vanishing from a comment.
pipeline_actor_label() {
  case "$1" in
    script) printf 'Script' ;;
    coordinator) printf 'Co-Ordinator' ;;
    implementer) printf 'Implementer' ;;
    reviewer) printf 'Reviewer' ;;
    enabler) printf 'Enabler' ;;
    refiner) printf 'Refiner' ;;
    review-script) printf 'Review Script' ;;
    project-reviewer) printf 'Project Reviewer' ;;
    monitor) printf 'Pipeline Monitor' ;;
    approver-adjudicate-open-question) printf 'Approver (adjudication)' ;;
    enabler-decide) printf 'Enabler (decide-tactical)' ;;
    *) printf '%s' "$1" ;;
  esac
}

# pipeline_comment_header ACTOR NODE
# Print the leading, visible line every comment this system posts opens with.
# shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
pipeline_comment_header() {
  printf '**%s** · autonomous pipeline · node `%s`' "$(pipeline_actor_label "$1")" "$2"
}

# pipeline_comment_marker CYCLE_ID ACTOR
# Print the invisible marker to append to a comment body this system posts.
# The cycle id travels for traceability only — which cycle wrote this — and
# the actor for the same reason the header carries it visibly: detection
# needs nothing but PIPELINE_COMMENT_MARKER_PREFIX above, so an older marker
# carrying no actor= field still matches.
pipeline_comment_marker() {
  printf '%s cycle=%s actor=%s -->' "$PIPELINE_COMMENT_MARKER_PREFIX" "$1" "$2"
}

# The fixed, greppable prefix a reconciliation citation starts with (the one
# new convention requirement 31c, agent-ops#533, adds, on the Reviewer's
# side): before flipping a draft pull request ready, the Reviewer answers
# every standing human comment and cites it with a
# `pipeline_reconciles_marker`-shaped line in its completion comment.
# lib/reconciliation-gate.sh is the reader; match on this prefix, never on
# the whole line, same rule PIPELINE_COMMENT_MARKER_PREFIX already gives.
PIPELINE_RECONCILES_MARKER_PREFIX='<!-- agent-ops:reconciles'

# pipeline_reconciles_marker COMMENT_ID
# Print the citation line a pipeline comment carries to mark a standing human
# comment (by its own issue-comment id) as reconciled — implemented or
# explicitly contested, never silently dropped.
pipeline_reconciles_marker() {
  printf '%s comment=%s -->' "$PIPELINE_RECONCILES_MARKER_PREFIX" "$1"
}

# The fixed, greppable prefix a landing-refusal notice comment carries
# (issue #1979, requirement 62): the invisible stamp
# `_landing_notice_upsert`/`_landing_notice_clear` (`lib/landing.sh`) use to
# find their own prior notice on a pull request and edit it in place, rather
# than matching on prose that is free to change between releases — the same
# reason `PIPELINE_RECONCILES_MARKER_PREFIX` exists beside the plainer
# `PIPELINE_COMMENT_MARKER_PREFIX` above. Match on this substring alone,
# never on the whole `pipeline_landing_notice_marker` line.
PIPELINE_LANDING_NOTICE_MARKER_PREFIX='<!-- agent-ops:landing-notice'

# pipeline_landing_notice_marker
# Print the invisible marker a landing-refusal notice comment carries,
# alongside the ordinary `pipeline_comment_header`/`pipeline_comment_marker`
# envelope every pipeline comment also carries. Takes no argument: unlike
# `pipeline_comment_marker`, this marker's whole purpose is to be found again
# regardless of which cycle or class last wrote it.
pipeline_landing_notice_marker() {
  printf '%s -->' "$PIPELINE_LANDING_NOTICE_MARKER_PREFIX"
}

# pipeline_find_marked_comment REPO NUMBER MARKER
# Print `{"id": …, "body": …}` for the most recent comment on REPO's issue or
# pull request NUMBER whose body contains the literal substring MARKER, or
# nothing at all when none exists or the read fails. The one generic "find
# the pipeline's own prior comment" primitive this system did not have before
# issue #1979 — `lib/landing.sh`'s landing-refusal notice is its first
# caller, but nothing here is landing-specific, so a later stage wanting the
# same "post once, then edit in place" shape has this to call rather than a
# second copy of the lookup.
#
# Fails open — prints nothing, non-zero exit — on any `gh` or `jq` failure, so
# a forge hiccup costs the caller a possible duplicate comment, never a stuck
# pipeline. Mirrors the exact `gh api … --paginate --jq '.[] | {…}'` then
# `jq -s` idiom `lib/enabler.sh`'s `escalation_thread_failed_already_posted`
# already uses to flatten a paginated comment list, so pagination here is
# proven, not newly invented.
pipeline_find_marked_comment() {
  local repo="$1" number="$2" marker="$3"
  local lines
  lines="$(gh api "repos/$repo/issues/$number/comments" --paginate \
             --jq '.[] | {id, body: (.body // "")}' 2>/dev/null)" || return 1
  [[ -n "$lines" ]] || return 1
  jq -s -c --arg m "$marker" \
    '[.[] | select(.body | contains($m))] | last // empty' <<<"$lines" 2>/dev/null
}

# pipeline_comment_upsert REPO NUMBER MARKER BODY
# Create the one comment on REPO's issue or pull request NUMBER carrying
# MARKER, or edit it in place if one already stands — never a second comment
# for the same MARKER. A no-op (exit 0, no write at all) when the standing
# comment's body already equals BODY byte-for-byte, the same idempotent
# convention this file's own header already documents for every comment this
# system posts (the Vercel-bot comparison). Returns non-zero only when the
# write itself (POST or PATCH) fails; a caller that wants to continue
# regardless should treat that like any other best-effort `gh` write failure
# in this system — a `warning` event, never an abort.
pipeline_comment_upsert() {
  local repo="$1" number="$2" marker="$3" body="$4"
  local existing existing_id existing_body
  # `|| existing=""`, never a bare assignment: a caller running under
  # `errexit` (every production call site does) must not have
  # `pipeline_find_marked_comment`'s own non-zero exit — an unreadable
  # comment list, same as any other forge read in this system — abort the
  # whole cycle. Treated as "no standing comment", which falls through to an
  # ordinary POST; the worst case is one extra comment on a `gh` hiccup,
  # never a stuck pipeline.
  existing="$(pipeline_find_marked_comment "$repo" "$number" "$marker")" || existing=""
  if [[ -n "$existing" ]]; then
    existing_id="$(jq -r '.id' <<<"$existing" 2>/dev/null)"
    existing_body="$(jq -r '.body' <<<"$existing" 2>/dev/null)"
    [[ "$existing_body" == "$body" ]] && return 0
    gh api -X PATCH "repos/$repo/issues/comments/$existing_id" -f body="$body" >/dev/null 2>&1
    return $?
  fi
  gh api "repos/$repo/issues/$number/comments" -f body="$body" >/dev/null 2>&1
}

# pipeline_comment_edit_if_present REPO NUMBER MARKER BODY
# Like `pipeline_comment_upsert`, but never creates a comment that does not
# already exist — the "say a hold has cleared" half of a notice/clear pair,
# where posting a brand-new comment announcing a hold that was never actually
# posted would be announcing nothing. A no-op (exit 0) when no comment
# carrying MARKER stands, or the standing one's body already equals BODY.
pipeline_comment_edit_if_present() {
  local repo="$1" number="$2" marker="$3" body="$4"
  local existing existing_id existing_body
  # `|| existing=""` — see `pipeline_comment_upsert`'s identical guard above.
  # An unreadable comment list here falls through to "nothing to clear",
  # never an abort: the standing notice (if any) simply waits for the next
  # cycle's read to succeed.
  existing="$(pipeline_find_marked_comment "$repo" "$number" "$marker")" || existing=""
  [[ -n "$existing" ]] || return 0
  existing_id="$(jq -r '.id' <<<"$existing" 2>/dev/null)"
  existing_body="$(jq -r '.body' <<<"$existing" 2>/dev/null)"
  [[ "$existing_body" == "$body" ]] && return 0
  gh api -X PATCH "repos/$repo/issues/comments/$existing_id" -f body="$body" >/dev/null 2>&1
}
