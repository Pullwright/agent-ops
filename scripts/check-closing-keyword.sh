#!/usr/bin/env bash
#
# scripts/check-closing-keyword.sh — deterministic check that an issue-sourced
# agent PR actually links its issue (requirement 25a).
#
# PR #206 wrote "Implements #198" in its body instead of a GitHub closing
# keyword. GitHub only auto-closes an issue on merge for a recognised keyword
# (close(s|d), fix(es|ed), resolve(s|d)) immediately followed by "#N", so
# #198 stayed open for three days after its own fix merged, and was
# re-selected and re-voided twice in the meantime — prose describing the same
# intent is invisible to GitHub and to this check alike. Prompt instruction
# alone had already asked for this and been silently skipped, so this cannot
# be enforced by prompt alone (issue #240) — it has to be a fact CI checks.
#
# The Implementer stamps an issue-sourced PR body with an invisible marker
# naming which issue it claims to close:
#
#   <!-- agent-ops:closes-issue item=198 -->
#
# (`prompts/implementer.md`'s Procedure step 2). This script fails when that
# marker is present without a matching closing keyword for the same number.
#
# The marker alone would leave the check anchored to a prompt instruction —
# an Implementer that forgets the marker entirely produces a PR this check
# passes trivially, which is the same silent skip that motivated issue #240
# in the first place. So the check has a second anchor no model writes: the
# head branch. The Script names a work order whose item is a bare issue
# number `agent/<N>` (`claim_branch_for`, agent-cycle.sh) — the `issues` and
# `tech-debt` sources alike, since D15 as revised (#869/#875/#879) moved debt
# onto `pw::type:tech-debt` issues and its item ref onto the issue number —
# and no other source ever yields a purely numeric item (`lib/work-gone.sh`);
# a head branch matching `agent/<N>` therefore *requires* both the marker for
# `N` (which the post-merge sweep keys on, requirement 17c) and a closing
# keyword for `N`. A PR with no marker and a non-numeric branch covers every
# source with nothing to close (register-hygiene, security, project-review,
# …), and passes.
#
# A second, independent gap (issue #1363): a `pw::type:tech-debt` issue
# migrated by #1039 (or filed directly) can name a permanent register file in
# its own body — a final line reading "Filed as `tech-debt/<id>.md`, <date>."
# (`scripts/migrate-tech-debt-register.sh`, `TECH-DEBT.md` "Resolution and
# history"). The pull request that closes such an issue must, in the same
# diff, flip that file's frontmatter to a terminal state — `status: resolved`
# (`prompts/implementer.md`/`prompts/reviewer.md`, TECH-DEBT.md "Claiming an
# item" step 6), or `status: not-debt` for an item the resolution concludes
# was never debt (TECH-DEBT.md "Resolution and history"; issue #1437) — but
# nothing before this checked it mechanically. PR #1355's
# first round is the concrete miss: issue closed, `status: open` left behind,
# wrong on `main` until a later round caught it by hand. Given a repo slug
# and this PR's own number (both optional — omitting either just skips this
# half, preserving every caller that predates it), this fetches each closed
# issue named by the marker/keyword resolution above **or by a bare closing
# keyword alone** — issue #1438: a PR that closes a tech-debt issue with a
# plain `Fixes #N` and no marker, on a branch that is not `agent/N` (a
# human's PR, or an interactive agent's), never touches `items` above, so the
# record-flip loop re-extracts every issue number the body cites via a
# closing keyword and checks each of those too, not only the marker/branch
# survivors. Where a resolved number's body's last non-blank line has that
# "Filed as" shape and it carries `pw::type:tech-debt`, this requires this
# PR's own diff (`gh api …/pulls/<n>/files`) to add a line setting the named
# record file's `status:` to one of the register's two terminal states,
# `resolved` or `not-debt` — both are equally terminal to `td-check.pl`,
# `lib/work-gone.sh` and `lib/candidate-gather.sh`, and `td-check.pl` still
# requires a `not-debt` row to carry its `ref:` (issue #1437).
#
# A `gh` call that fails outright (the token, a transient outage) is not
# turned into a failure of this check — the existing marker/keyword logic
# above never depended on the network, and making the record-flip half do so
# risks failing a PR over GitHub's own availability rather than over anything
# it did wrong. It warns to stderr and moves on; only a positive reading of
# the issue and the diff decides pass or fail here.
#
# Usage: check-closing-keyword.sh <pr-body-text> [<head-branch>] [<repo-slug>] [<pr-number>]
# Exit 0: nothing claims an issue, or every claim has its closing keyword and
#   (where applicable) its tech-debt record correctly flipped.
# Exit 1: a marker with no matching closing keyword, an `agent/<N>` branch
#   missing the marker or the keyword, or a named tech-debt record this PR's
#   diff does not flip to a terminal `status:` (`resolved`/`not-debt`) —
#   printing why in each case.
#
# GH overrides the `gh` binary, for tests.

set -uo pipefail

GH="${GH:-gh}"

body="${1:-}"
head_branch="${2:-}"
repo_slug="${3:-}"
pr_number="${4:-}"

# Every marker this PR body carries, one item number per line. A PR could in
# principle carry more than one (unusual, but the check must not silently
# check only the first).
mapfile -t items < <(grep -oE '<!-- agent-ops:closes-issue item=[0-9]+ -->' <<<"$body" \
  | grep -oE '[0-9]+')

status=0

# The keyword part of a closing reference — GitHub's own closing-keyword
# list, case-insensitive, optionally colon-separated from the issue
# reference that follows. Factored out so the marker check below and the
# record-flip harvest further down share one definition rather than drifting
# apart (issue #1460) — what counts as a keyword is the same question in both
# halves, even though what counts as a reference is not (see `harvest_ref_re`).
keyword_re='(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+'

# The issue-reference part: GitHub honours three spellings for the same
# issue — "#N", "GH-N", and "owner/repo#N" — and closes the referenced issue
# on merge for all three (issue #1460). The marker check below asks only
# "does some closing keyword exist for this item", not "in which repo" — it
# runs whether or not a repo slug was even passed, since
# lib/closing-keyword-gate.sh never passes one — so it accepts any
# owner/repo here rather than filtering to a specific one. The record-flip
# harvest is asked the other question and uses its own `harvest_ref_re`
# instead; issue #1468 tracks the gap the any-owner reading leaves here.
issue_ref_re='(#|GH-|[[:alnum:]_.-]+/[[:alnum:]_.-]+#)'

# The branch anchor: `agent/<N>` is minted by the Script only for a work
# order whose item is a bare issue number — one there is therefore always
# something to close — so it demands the marker's *presence*, the one thing the
# marker cannot demand of itself. The number joins the keyword loop below
# whether or not the marker was there, so a branch-anchored PR missing both
# gets both told to it.
if [[ "$head_branch" =~ ^agent/([0-9]+)$ ]]; then
  branch_item="${BASH_REMATCH[1]}"
  if ! printf '%s\n' "${items[@]:-}" | grep -qx "$branch_item"; then
    echo "::error::head branch $head_branch is an issue-sourced work order, but the PR body has no <!-- agent-ops:closes-issue item=${branch_item} --> marker (the post-merge sweep keys on it)" >&2
    status=1
    items+=("$branch_item")
  fi
fi

for item in "${items[@]:-}"; do
  [[ -n "$item" ]] || continue
  # GitHub's own closing-keyword list: close(s|d), fix(es|ed), resolve(s|d),
  # case-insensitive, immediately followed by "#N", "GH-N" or "owner/repo#N"
  # (optionally ": #N" etc.) for the same number the marker names.
  #
  # The keyword has to be a word of its own, as it is to GitHub's own parser —
  # "unclosed #198" and "discloses #198" contain "closed" and "closes" but
  # close nothing, and a check that accepted them would pass exactly the PR
  # it exists to fail. Markdown emphasis, backticks and hyphens are all
  # non-alphanumeric, so "**Closes #198**" still passes.
  if ! grep -qiE "(^|[^[:alnum:]])${keyword_re}${issue_ref_re}${item}([^0-9]|\$)" <<<"$body"; then
    echo "::error::PR body names issue #${item} (agent-ops:closes-issue marker) but has no closing keyword (Closes/Fixes/Resolves #${item}, GH-${item}, or owner/repo#${item}) for it" >&2
    status=1
  fi
done

# --- the tech-debt record-flip check (issue #1363, extended by #1438) -------
if [[ -n "$repo_slug" && -n "$pr_number" ]]; then
  # Every issue number the body cites via a bare closing keyword, independent
  # of the marker/branch anchors above — this is what lets the record-flip
  # loop below catch a markerless `Fixes #N` PR (issue #1438): a human's PR,
  # or an interactive agent's, that closes a tech-debt issue with nothing this
  # script's marker/branch resolution would otherwise notice. The
  # marker-requires-keyword loop above is unrelated and stays anchored to
  # `items` alone.
  #
  # Same word-of-its-own guard the per-item check above carries, and for the
  # same reason: "discloses #240" and "unfixed #240" contain a keyword and
  # close nothing, to GitHub's own parser as to this script — so harvesting a
  # number out of one would demand a record flip from a pull request that
  # closes no such issue, failing a required check over a word in prose. Hence
  # the shared `keyword_re`: one definition, so the two halves cannot drift on
  # what counts as a keyword.
  #
  # The issue *reference* is where the two halves legitimately differ (issue
  # #1460). Both accept "#N" and "GH-N", but this half accepts the
  # repo-qualified "owner/repo#N" only when the slug is this repository's own:
  # the marker check is asked whether a closing keyword for a number exists at
  # all, whereas this half is asked which of *our* issues merging will close,
  # and `Fixes otherowner/otherrepo#5` closes someone else's #5 — harvesting it
  # would demand a flip of our own `tech-debt/<id>.md` over a record this pull
  # request has no business touching. `$repo_slug` is always non-empty here,
  # and `.` is the only ERE metacharacter a GitHub owner or repository name can
  # contain, so escaping it is the whole of what interpolating one safely needs.
  harvest_ref_re="(#|GH-|${repo_slug//./\\.}#)"
  # The number is taken from the end of each match, not from the first digit
  # run in it: the leading boundary character is never a digit, but a repo
  # slug of its own can carry one ("acme/widgets2#198"), and an unanchored
  # extraction would harvest that 2 as though it were an issue.
  mapfile -t keyword_items < <(grep -oiE "(^|[^[:alnum:]])${keyword_re}${harvest_ref_re}[0-9]+" <<<"$body" \
    | grep -oE '[0-9]+$')
  mapfile -t unique_items < <(printf '%s\n' "${items[@]}" "${keyword_items[@]}" | grep -v '^$' | sort -un)
  for item in "${unique_items[@]:-}"; do
    [[ -n "$item" ]] || continue

    issue_json="$("$GH" issue view "$item" -R "$repo_slug" --json body,labels 2>/dev/null)" || issue_json=""
    if [[ -z "$issue_json" ]]; then
      echo "::warning::could not read issue #${item} to check for a tech-debt \"Filed as\" record — skipping the record-flip check for it" >&2
      continue
    fi

    is_tech_debt="$(jq -r '(.labels // []) | any(.name == "pw::type:tech-debt")' <<<"$issue_json" 2>/dev/null)"
    [[ "$is_tech_debt" == "true" ]] || continue

    issue_body="$(jq -r '.body // ""' <<<"$issue_json" 2>/dev/null)"
    # The last non-blank line, ignoring any trailing blank lines the body ends
    # with — the same "final line" #1039's migration and TECH-DEBT.md mean.
    last_line="$(awk 'NF{line=$0} END{print line}' <<<"$issue_body")"
    [[ "$last_line" =~ ^Filed\ as\ \`(tech-debt/[^\`]+\.md)\`,\  ]] || continue
    record_path="${BASH_REMATCH[1]}"

    # The call's own exit status has to be read separately from the `jq` that
    # shapes its output: an empty changed-files listing and a `gh` that never
    # answered look identical downstream, and treating the second as the first
    # is precisely the "fail a PR over GitHub's availability" this half is
    # written not to do — with the worst possible message, telling the author
    # their diff does not touch a file it may well touch.
    if ! files_raw="$("$GH" api "repos/$repo_slug/pulls/$pr_number/files" --paginate --slurp 2>/dev/null)" \
      || ! files_json="$(jq -c 'add // []' <<<"$files_raw" 2>/dev/null)"; then
      echo "::warning::could not read this pull request's changed files to check ${record_path} — skipping the record-flip check for issue #${item}" >&2
      continue
    fi
    patch="$(jq -r --arg p "$record_path" \
      'map(select(.filename == $p)) | (.[0].patch // "")' <<<"$files_json" 2>/dev/null)"

    if [[ -z "$patch" ]]; then
      echo "::error::issue #${item} names ${record_path} (its body's \"Filed as\" line) but this pull request's diff does not touch that file — closing the issue must also flip its frontmatter to a terminal status: — resolved (TECH-DEBT.md \"Claiming an item\" step 6) or not-debt (\"Resolution and history\")" >&2
      status=1
    elif ! grep -qE '^\+status:[[:space:]]*(resolved|not-debt)[[:space:]]*$' <<<"$patch"; then
      echo "::error::issue #${item} names ${record_path} (its body's \"Filed as\" line) but this pull request's diff does not set its frontmatter status: to a terminal state (resolved, or not-debt for an item that turns out not to be debt)" >&2
      status=1
    fi
  done
fi

exit "$status"
