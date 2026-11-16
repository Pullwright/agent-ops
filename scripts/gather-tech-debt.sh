#!/usr/bin/env bash
#
# gather-tech-debt.sh — deterministically pre-fetch one repo's open
# `pw::type:tech-debt`-labelled issues for the Co-Ordinator's runtime input
# (docs/spec/implementation/requirements, requirement 3t).
#
# Usage: gather-tech-debt.sh <owner/repo>
#
# Prints one JSON object, `{"candidates": […], "excluded": […]|null}` — the
# same shape scripts/gather-issues.sh prints (agent-ops#2603), since both
# scripts share the identical deterministic drops via lib/issue-prefetch.sh
# and a drop here is exactly as unreported-elsewhere as one there was before
# agent-ops#447 fixed it:
#
# `candidates` — one entry per candidate tech-debt item, issue-shaped exactly
# like a scripts/gather-issues.sh candidate but tagged `tech-debt`:
#
#   {
#     "source": "tech-debt",
#     "ref": "42",                    // the bare issue number — the item ref
#     "number": 42,
#     "url": "https://github.com/…/issues/42",
#     "title": "…",
#     "priority": "Medium",           // the Priority band, default Medium (agent-ops#2422)
#     "priority_set": false,          // true iff any option is set on the field, even one
#                                      // outside the four recognised names — see
#                                      // scripts/gather-issues.sh's own header
#     "labels": ["pw::type:tech-debt", "…"],
#     "author": "…",
#     "created_at": "…", "updated_at": "…",
#     "body": "…verbatim…",
#     "comments": [{"author": "…", "created_at": "…", "body": "…verbatim…"}]
#   }
#
# `excluded` — one entry per issue the deterministic filter below dropped,
# `{"number": 42, "reason": "assigned" | "blocked-label" | "pager" |
# "blocked-by: <ref>"}`, `null` rather than `[]` when the deterministic
# filter did not run to completion — see scripts/gather-issues.sh's own
# header for why that distinction matters. An issue dropped for one of the
# first three reasons whose own thread *also* names a still-open
# `Blocked-by:` reference contributes a second entry under the same number,
# one `reason` each (issue #2607, mirroring scripts/gather-issues.sh's own
# fix) — `issue_exclude_reason`'s own precedence decides which single one of
# the first three is reported, never whether the fourth, independently-
# checked ground applies too. An issue the label-scoped listing
# itself never returned (it never carried `pw::type:tech-debt`) is not this
# script's own candidacy drop to report, and is simply absent from both
# arrays, the same way a pull request is absent from scripts/gather-issues.sh's
# own `excluded`.
#
# `candidates` is sorted by Priority, then by the freshest thread
# (agent-ops#2422, requirement 4 — before this, lowest-issue-number-first, the
# same "lowest-id-first" rule the register-backed gatherer this replaces
# always applied, restated over issue numbers instead of register ids).
# `keep_order_tech_debt` (lib/coordinator-input.sh) keeps the identical order
# when requirement 4i's entry caps do drop entries (agent-ops#1379) — the
# gatherer's own order and the fit ladder's trim order are now one definition,
# not two that happened to agree on "freshest first" alone.
#
# ## Why `excluded` is reported at all (agent-ops#2603)
#
# Before this, a tech-debt candidate this script's own deterministic filter
# dropped — assigned, `blocked`-labelled, `pw::pager`-labelled, or naming a
# still-open `Blocked-by:` reference — left no trace anywhere a later reader
# could see: not on stdout, not in the shared log. That silence is exactly
# what broke `lib/eligibility.sh`'s own open-`Blocked-by:`-reference Enabler
# filter (requirement 35f, issue #2593) the first time it shipped: the filter
# read each eligible candidate's own thread out of `ordered_repos_json`'s
# `issues`/`tech_debt` bands, but a candidate this script (or
# scripts/gather-issues.sh) had already dropped for naming a still-open
# `Blocked-by:` reference is, by construction, never present in either band —
# the filter could never fire on its own target class. Reporting the drop and
# its reason here, the same way scripts/gather-issues.sh already does, is what
# lets that filter (and any other reader) learn "candidate N was excluded,
# and why" from data this gather already produced, with no second `gh` call.
#
# ## The store moved from the register to labelled issues (D15 as revised, #869)
#
# Debt used to live as one `tech-debt/<id>.md` file per record; this gatherer
# used to read the register tarball and pick out every `status: open` row.
# D15 as revised (issue #875) moves the store to GitHub Issues carrying the
# product-managed label `pw::type:tech-debt` — the D24 trust anchor: only a
# collaborator with triage can apply it, so an issue's membership of this band
# is trustable even though its body stays framed as untrusted data, exactly
# like an `issues` source entry. Selection is on the label alone; nothing here
# re-derives whether an issue "looks like" debt.
#
# This gatherer now shares its deterministic filter and its `Blocked-by:`
# live-check with scripts/gather-issues.sh, via lib/issue-prefetch.sh: an
# issue that is assigned, labelled `blocked`, labelled `pw::pager`
# (agent-ops#2564 — a Pager tracking issue is pager-owned, never ordinary
# selectable work), or names a still-open `Blocked-by:` reference
# (requirement 34j) is dropped here on the same terms `issues` drops it,
# rather than by a second copy of that logic. A pull request never carries
# this label in practice, but is dropped anyway, the same defensive way
# `issues` drops one.
#
# **Transition note, accepted deliberately (issue #875):** between this
# landing and a repo's own register migration, that repo's unmigrated
# register items are invisible to this band — this gatherer never reads a
# register file, only the label. The migrations follow immediately in the
# dependency chain (#880 and the sibling issues in other repos), and debt is
# a low-urgency band, so a repo with no `pw::type:tech-debt` issues yet simply
# contributes `[]`, indistinguishable from a repo with no open debt at all.
#
# ## Why this source is pre-fetched at all (issue #310)
#
# The tech-debt band used to be the Co-Ordinator's own read: the prompt told it
# to unpack the register tarball itself and `grep -l '^status: open'` for the
# candidate set, then cross-reference each one against `blocked`/`void`/`claimed`
# by its own judgement. That contract failed exactly the way every other
# self-read source failed before it (issues, findings, review-feedback,
# merge-conflicts, abandoned-drafts, register-hygiene): between 2026-08-10 and
# 2026-08-12, with ~30 eligible open items sitting in the register, the
# Co-Ordinator returned `none-selected` with reasons like "remaining tech-debt
# candidates require per-item evaluation against blocked/void/claimed records"
# and "open tech-debt heavily voided or blocked" — neither true, and the second
# one factually contradicted by the register it was describing. A `none-selected`
# fingerprint then froze the fleet on that wrong answer for a full day. Handing
# the candidates over pre-fetched, exactly as every drifted source before it got,
# removes the judgement step that kept getting reasoned past — an item filtered
# out (or simply listed) before the model sees it cannot be misdescribed.
#
# Claimed/blocked/void exclusion is deliberately **not** done here: like
# `exclude_claimed_items` for every other pre-fetched array, that is applied by
# agent-cycle.sh once this repo's fresh `claimed`/`blocked`/`void` extracts are
# in hand, so there is one definition of each exclusion rather than one per
# gatherer.
#
# Degrades to `{"candidates":[],"excluded":null}` (exit 0) on any failure, the
# identical contract scripts/gather-issues.sh's own degrade() follows and for
# the identical reason: this output *is* the Co-Ordinator's input, so an empty
# `candidates` faithfully records what it saw, and a repo's `head_sha` (already
# in the no-op fingerprint) still busts the fingerprint when a real commit
# changes the candidate set out from under a transient failure. `excluded`
# degrades to `null`, not `[]` — the deterministic filter did not run to
# completion, so the exclusion set is unknown, not known-empty (the same
# review decision on agent-ops#452 concern 3 scripts/gather-issues.sh already
# follows). Failures are loud on stderr.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dependency-gate.sh
. "$SCRIPT_DIR/lib/dependency-gate.sh"
# The deterministic filter and the Blocked-by live-check, shared with
# scripts/gather-issues.sh — see lib/issue-prefetch.sh.
# shellcheck source=lib/issue-prefetch.sh
. "$SCRIPT_DIR/lib/issue-prefetch.sh"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"

slug="${1:-}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-tech-debt.sh <owner/repo>" >&2
  exit 64
fi

degrade() {
  echo "gather-tech-debt: $slug: $*" >&2
  printf '{"candidates":[],"excluded":null}\n'
  exit 0
}

# issue_prefetch_open_issues (lib/issue-prefetch.sh, agent-ops#1085) is one
# paginated GraphQL walk fetching every open issue's whole comment thread
# alongside it — every open issue, not only `pw::type:tech-debt`-labelled
# ones, unlike this script's own former REST listing (`labels=pw::type:
# tech-debt` was a server-side filter that call could apply and this shared
# walk cannot, since scripts/gather-issues.sh needs the unfiltered set too);
# the label filter below is now this script's own `select`, the one thing
# lib/issue-prefetch.sh's own header already says is left to each caller.
# See that function's own header for the point-cost measurement. Exit 2 means
# its own page cap was reached before the repository's own open-issue count
# was: the array it still printed is used rather than discarded, the same
# "a truncated set is still useful" judgement gather-issues.sh's own call
# site makes explicit.
issues_raw="$(issue_prefetch_open_issues "$slug")"; issues_raw_rc=$?
if (( issues_raw_rc == 1 )); then
  degrade "issues list fetch failed"
elif (( issues_raw_rc == 2 )); then
  echo "gather-tech-debt: $slug: issue_prefetch_open_issues hit its own page cap — some open tech-debt issues may be missing this cycle" >&2
fi
jq -e 'type == "array"' <<<"$issues_raw" >/dev/null 2>&1 \
  || degrade "issues list payload is not an array"

# Every open issue's `priority`/`priority_set` (requirement 1/2,
# agent-ops#2422 — tech-debt now carries a band, the same field and the same
# way `scripts/gather-issues.sh` reads it), then priority inheritance over
# the whole open-issue set, `issues` and `tech-debt` alike (requirement 4's
# "what it needs", point 4): an item that blocks another ranks at least as
# high as the highest band among what it blocks, whichever band either one
# is in. Both are pure passes over data already in hand; neither issues a
# further `gh` call. See scripts/gather-issues.sh's own header for the parse
# itself.
issues_raw="$(issue_prefetch_annotate_priority "$issues_raw")"
issues_raw="$(issue_priority_inherit "$issues_raw")"

# Which issues the holding check below may skip the native Issue Dependencies
# read for — exactly as scripts/gather-issues.sh computes it, and for the
# same reason: see `issue_prefetch_native_dep_skip_set`'s own header
# (lib/issue-prefetch.sh). This band is the larger of the two on this
# repository's own backlog, so it is the one that paid most for a read per
# candidate.
native_dep_skip_set="$(issue_prefetch_native_dep_skip_set "$issues_raw")"

# The deterministic filter — see lib/issue-prefetch.sh's own comment. A pull
# request never carries this label in practice, so `issue_deterministic_ok`'s
# PR check is defensive rather than load-bearing here.
#
# Sorted by Priority, then by the freshest thread (agent-ops#2422, requirement
# 4) — the same total order `keep_order_tech_debt` (lib/coordinator-input.sh)
# already applies when the fit ladder's own entry caps trim this band
# (agent-ops#1379); giving the gatherer's own order the identical shape means
# an uncapped cycle's walk order already ranks this way too, not only a capped
# one's surviving set.
candidates="$(jq -c "$ISSUE_DETERMINISTIC_FILTER_JQ"'
  def issue_rank: {Urgent: 4, High: 3, Medium: 2, Low: 1}[(.priority // "Medium") | tostring] // 2;
  [.[]
   | select(issue_deterministic_ok)
   | select(([.labels[]?.name] | index("pw::type:tech-debt")) != null)
   | {number: .number,
      url: .html_url,
      title: .title,
      priority: (.priority // "Medium"),
      priority_set: (.priority_set // false),
      labels: ([.labels[]?.name] | sort),
      author: (.user.login // ""),
      created_at: .created_at,
      updated_at: .updated_at,
      body: (.body // ""),
      comments: [(.comments // [])[] | {author: (.user.login // ""), created_at: .created_at, body: (.body // "")}]}
     + (if (.priority_raised_by // null) == null then {} else {priority_raised_by: .priority_raised_by} end)]
  | sort_by([issue_rank, ((.updated_at // "") | tostring)]) | reverse' <<<"$issues_raw" 2>/dev/null)" \
  || degrade "issues filter failed"

# `excluded` mirrors scripts/gather-issues.sh's own (agent-ops#2603): scoped to
# issues that actually carry `pw::type:tech-debt` — an issue without the label
# was never a tech-debt candidate to begin with, the same "never a candidate"
# reasoning that already keeps a pull request off this array — tagged with the
# assigned/blocked-label/pager reason `issue_exclude_reason` reports. The
# fourth, structured reason (`blocked-by: <ref>`) is appended below, both for
# a surviving candidate whose whole thread names an unresolved reference
# (the loop further down) and, as a second entry under the same number, for
# one of these deterministically-dropped issues whose thread does too (issue
# #2607, just below).
excluded="$(jq -c "$ISSUE_DETERMINISTIC_FILTER_JQ"'
  [.[]
   | select(has("pull_request") | not)
   | select(([.labels[]?.name] | index("pw::type:tech-debt")) != null)
   | select(issue_exclude_reason != null)
   | {number: .number, reason: issue_exclude_reason}]
  | sort_by(.number)' <<<"$issues_raw" 2>/dev/null)" \
  || degrade "issues excluded-filter failed"

# Issue #2607: `issue_exclude_reason`'s single-reason precedence (assigned >
# blocked-label > pager) reports only the highest-precedence ground above,
# even when a dropped issue's own thread *also* names a still-open
# `Blocked-by:` reference — which would otherwise never earn the
# `"blocked-by: "`-prefixed entry requirement 35f's own
# `compute_enabler_eligible_set` (lib/eligibility.sh) subtraction matches on,
# leaving it Enabler-eligible across every recheck window regardless.
# `issue_prefetch_blocked_by_additions` (lib/issue-prefetch.sh, shared with
# scripts/gather-issues.sh) re-tests just the issues already excluded above,
# and reports a second entry alongside — never replacing — the one already
# there.
blocked_by_additions="$(issue_prefetch_blocked_by_additions "$slug" "$issues_raw" "$excluded" "$native_dep_skip_set")" \
  || degrade "blocked-by additions check failed"
excluded="$(jq -nc 'input as $a | input as $b | $a + $b' <<<"$excluded"$'\n'"$blocked_by_additions")" \
  || degrade "excluded merge with blocked-by additions failed"

out='[]'
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] || continue
  n="$(jq -r '.number' <<<"$candidate")"

  # Requirement 34j, exactly as gather-issues.sh applies it: a `Blocked-by:`
  # reference still open anywhere in the thread holds this candidate back.
  # `$candidate` already carries its own thread (`issue_prefetch_open_issues`
  # fetched it alongside the listing itself, agent-ops#1085), so no further
  # `gh` call is made to get it. Reported into `excluded`, with the reference's
  # own display form, the same way scripts/gather-issues.sh already reports it
  # (agent-ops#2603) — this is the one record `lib/eligibility.sh`'s own
  # open-`Blocked-by:`-reference Enabler filter (requirement 35f) reads,
  # rather than re-deriving the same live check from a thread this drop
  # already removed from the `tech_debt` band.
  thread_text="$(jq -r '.body' <<<"$candidate")
$(jq -r '[.comments[].body] | join("\n")' <<<"$candidate")"
  # The empty string where the walk already reported no native dependency —
  # see scripts/gather-issues.sh's own copy of this two-liner.
  native_n="$n"
  [[ "$native_dep_skip_set" == *" $n "* ]] && native_n=""
  ref_display="$(issue_blocked_by_ref "$slug" "$native_n" "$thread_text")"
  if [[ -n "$ref_display" ]]; then
    excl_entry="$(jq -nc --argjson n "$n" --arg ref "$ref_display" \
      '{number: $n, reason: ("blocked-by: " + $ref)}')" || degrade "excluded entry assembly failed for issue #$n"
    excluded="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' <<<"$excluded"$'\n'"$excl_entry")" \
      || degrade "excluded array assembly failed at issue #$n"
    continue
  fi

  # $candidate already carries its own whole issue thread (requirement 4g) —
  # unbounded past this call — so it arrives on stdin, never in argv: a
  # single issue thread past MAX_ARG_STRLEN must not degrade this repo's
  # whole tech_debt array to `[]`.
  entry="$(jq -c '{source: "tech-debt", ref: (.number | tostring)} + .' \
    <<<"$candidate")" || degrade "entry assembly failed for issue #$n"
  out="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' <<<"$out"$'\n'"$entry")" \
    || degrade "array assembly failed at issue #$n"
done < <(jq -c '.[]' <<<"$candidates")

# $out and $excluded both arrive on stdin, never as --argjson: both are
# unbounded past this call the same way requirement 4g already treats every
# other aggregate this script builds.
printf '%s\n' "$out" "$excluded" \
  | jq -nc 'input as $c | input as $e | {candidates: $c, excluded: ($e | sort_by(.number))}'
