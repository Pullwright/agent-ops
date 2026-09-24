#!/usr/bin/env bash
#
# scripts/roll-changelog.sh — the scheduled roll requirement 25d's own text
# names for a repository that cuts no releases (agent-ops#1809): this
# repository's `CHANGELOG.md` has no release pull request to run
# scripts/assemble-changelog.sh from, so this script runs it on a cadence
# instead, renames the assembled `## [Unreleased]` heading to a dated one
# (Keep a Changelog's version slot; this repository has no version numbers)
# and opens a fresh, empty `## [Unreleased]` above it.
#
# Usage: roll-changelog.sh [<owner/repo>]
#
#   <owner/repo>  defaults to this script's own `git remote get-url origin`,
#                 parsed to `owner/name` — the repository this script has
#                 been synced into, mirroring scripts/assemble-changelog.sh's
#                 own "wherever it has been synced" default.
#
# Environment: ROLL_GH overrides `gh` (tests stub it); CLONE_GIT (see
# lib/repo-clone.sh) overrides `git clone`.
#
# --- The migration -------------------------------------------------------------
# A `CHANGELOG.md` carrying no `<!-- changelog:assembled-through -->` marker
# at all is the one-time migration this repository's own file needed at
# adoption of roadmap decision D27 (agent-ops#1804, #1810): rather than
# running the assembler over the hand-written `[Unreleased]` section that
# predates the convention, this renames that section, unchanged, to a fixed
# `## [<MIGRATION_DATE>]` heading — #1810's own merge date — opens a fresh
# empty `[Unreleased]` above it, and sets the marker to #1810's own
# squash-merge commit (`MIGRATION_SHA`), so only a description merged after
# D27 landed is ever assembled. This path runs exactly once, the run after
# which the marker exists; every later run takes the ordinary path below.
#
# --- The ordinary roll -----------------------------------------------------
# A marker already present means counting the first-parent commits since it
# (`git log --first-parent <marker>..HEAD`): none at all is a no-op — no
# commit, no branch push, no pull request, since nothing has merged since
# the last roll. Otherwise this runs scripts/assemble-changelog.sh (which may
# still find no bullet-bearing description among the commits in range, e.g.
# a run of `chore`/`test`-only merges — the marker still advances and the
# section is still rolled, empty, exactly as the assembler's own idempotence
# contract already allows), renames the assembled `[Unreleased]` heading to
# today's UTC date, and opens a fresh empty one above it.
#
# --- The pull request -------------------------------------------------------
# Either path commits `CHANGELOG.md` and opens or updates one
# `docs(changelog): roll <date>` pull request on the fixed `changelog-roll`
# branch: a second run while an earlier one's pull request is still open
# force-pushes the same transform, freshly re-applied over the current
# default branch, over that branch rather than opening a second one — first
# checking, via `lib/merge-queue.sh`'s `merge_queue_probe`, that the existing
# pull request is not currently in the merge queue, the same "never push
# under a queued pull request" rule every other pushing stage in this
# pipeline already observes; an unreadable queue state is treated the same
# as "queued" (skip), never as "safe to push". A fresh pull request is opened
# ready for review, not draft, carrying this repository's own `pr_label` and
# a `complexity:low` label (created first if the repository lacks it,
# best-effort) — the same pair every other stage's autonomous-agent pull
# request needs to sit in the ordinary open-pull-request queue a human
# already watches, since this branch's fixed name (`changelog-roll`, never
# `branch_prefix`-prefixed) is invisible to every gathering script that reads
# a cycle's own claim on a branch: it carries no `selection` event in the
# fleet log, so the automatic landing-retry sweep (`lib/landing.sh`) can
# never arm it, and `gather-review-feedback.sh`/`gather-dequeued.sh`/
# `gather-landing-refusals.sh` can never hand a human's follow-up comment on
# it back to an Implementer. Landing this pull request — the first run and
# every force-pushed update after it — is always a human's own review and
# merge, the same as this repository's every other pull request at
# `merge_autonomy: human`; it is the one pull request D27 (requirement 25c)
# permits to edit `CHANGELOG.md`.
#
# `git`/`gh` credentials resolve through the same on-demand shim
# (`lib/gh-shim.sh`) every other Script-side duty already uses, so no
# separate authoring identity needs wiring up here.
#
# Cadence: `schedule.changelog_roll_hour`/`_offset_minutes`/`_day_of_week`
# render one weekly crontab line (deploy/docker/render-crontab.sh,
# deploy/docker/crontab.tmpl). A human or an operator's own shell can also
# just run this script directly for an on-demand roll — a Script-side duty
# needs no separate dispatch mechanism the way a GitHub Actions workflow's
# `workflow_dispatch` would.

# `-e`: an unreadable commit range, a failed clone, commit or push must abort
# rather than run the next step against a half-updated file or a stale repo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/repo-clone.sh
. "$SCRIPT_DIR/lib/repo-clone.sh"
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
# shellcheck source=lib/merge-queue.sh
. "$SCRIPT_DIR/lib/merge-queue.sh"
# shellcheck source=lib/git-identity.sh
. "$SCRIPT_DIR/lib/git-identity.sh"
# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"

ROLL_GH="${ROLL_GH:-gh}"
export MERGE_QUEUE_GH="${MERGE_QUEUE_GH:-$ROLL_GH}"

BRANCH="changelog-roll"
# #1810's own squash-merge commit on `main` (D27, agent-ops#1804) and the UTC
# date it merged — the migration's fixed starting point. Never advanced by a
# later change: this is what "the migration runs exactly once" means.
MIGRATION_SHA="5e78f991c282a0f858942fcd10066a39c102e365"
MIGRATION_DATE="2026-09-23"

MARKER_PREFIX='<!-- changelog:assembled-through sha='
marker_line_regex='^<!-- changelog:assembled-through sha=([0-9a-f]{40}) -->[[:space:]]*$'
unreleased_heading_regex='^##[[:space:]]+\[Unreleased\][[:space:]]*$'

say() { printf 'roll-changelog: %s\n' "$*" >&2; }

usage() {
  awk 'NR >= 2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}
[[ "${1:-}" != "--help" && "${1:-}" != "-h" ]] || usage 0

repo_slug="${1:-}"
if [[ -z "$repo_slug" ]]; then
  origin_url="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null)" || {
    say "cannot resolve this checkout's own origin remote, and no <owner/repo> was given"
    exit 2
  }
  repo_slug="$(sed -E 's#^(git@|https://)([^:/]+)[:/]+(.+?)(\.git)?$#\3#' <<<"$origin_url")"
fi
if [[ ! "$repo_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  say "cannot resolve '$repo_slug' to an owner/repo slug"
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/changelog-roll.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

clone_dir="$work_dir/repo"
if ! clone_repo "$repo_slug" "$clone_dir" 2>"$work_dir/clone.err"; then
  say "clone of $repo_slug failed: $(cat "$work_dir/clone.err")"
  exit 1
fi

changelog="$clone_dir/CHANGELOG.md"
if [[ ! -f "$changelog" ]]; then
  say "$repo_slug carries no CHANGELOG.md — nothing to roll"
  exit 0
fi

default_branch="$(git -C "$clone_dir" rev-parse --abbrev-ref HEAD)"

existing_marker_sha=""
while IFS= read -r l; do
  if [[ "$l" =~ $marker_line_regex ]]; then
    existing_marker_sha="${BASH_REMATCH[1]}"
    break
  fi
done < "$changelog"

today="$(date -u +%Y-%m-%d)"

# find_unreleased_idx ARRAY_NAME — the index of the first line matching the
# `## [Unreleased]` heading regex in the named array, or -1.
find_unreleased_idx() {
  local -n _fui="$1"
  local i
  for i in "${!_fui[@]}"; do
    if [[ "${_fui[$i]}" =~ $unreleased_heading_regex ]]; then
      printf '%s' "$i"
      return 0
    fi
  done
  printf '%s' "-1"
}

if [[ -z "$existing_marker_sha" ]]; then
  # --- Migration: rename the pre-convention section unchanged, open a fresh
  # one, and set the marker to the fixed migration commit. The assembler
  # never runs over this content.
  mapfile -t lines < "$changelog"
  unreleased_idx="$(find_unreleased_idx lines)"
  if (( unreleased_idx < 0 )); then
    say "$repo_slug's CHANGELOG.md carries no marker and no ## [Unreleased] heading — nothing to migrate"
    exit 0
  fi
  out=()
  for (( i = 0; i < unreleased_idx; i++ )); do out+=("${lines[$i]}"); done
  while (( ${#out[@]} > 0 )) && [[ -z "${out[-1]}" ]]; do unset 'out[-1]'; done
  out+=("" "${MARKER_PREFIX}${MIGRATION_SHA} -->" "" "## [Unreleased]" "" "## [${MIGRATION_DATE}]")
  for (( i = unreleased_idx + 1; i < ${#lines[@]}; i++ )); do out+=("${lines[$i]}"); done
  printf '%s\n' "${out[@]}" > "$changelog"
  roll_date="$MIGRATION_DATE"
else
  since_count="$(git -C "$clone_dir" log --first-parent --oneline "${existing_marker_sha}..HEAD" | wc -l | tr -d '[:space:]')"
  if [[ "$since_count" == "0" ]]; then
    say "$repo_slug: nothing merged since ${existing_marker_sha:0:12} — no-op"
    exit 0
  fi

  "$clone_dir/scripts/assemble-changelog.sh" "$changelog"

  mapfile -t lines < "$changelog"
  unreleased_idx="$(find_unreleased_idx lines)"
  if (( unreleased_idx < 0 )); then
    say "$repo_slug: assemble-changelog.sh left no ## [Unreleased] heading — refusing to roll"
    exit 1
  fi
  lines[unreleased_idx]="## [${today}]"
  out=()
  for (( i = 0; i < unreleased_idx; i++ )); do out+=("${lines[$i]}"); done
  while (( ${#out[@]} > 0 )) && [[ -z "${out[-1]}" ]]; do unset 'out[-1]'; done
  out+=("" "## [Unreleased]" "")
  for (( i = unreleased_idx; i < ${#lines[@]}; i++ )); do out+=("${lines[$i]}"); done
  printf '%s\n' "${out[@]}" > "$changelog"
  roll_date="$today"
fi

if git -C "$clone_dir" diff --quiet -- CHANGELOG.md; then
  say "$repo_slug: the roll produced no change — no-op"
  exit 0
fi

# --- Merge-queue awareness: never push under a pull request mid-merge --------
existing_pr_number="$("$ROLL_GH" pr list -R "$repo_slug" --head "$BRANCH" --state open \
  --json number --jq '.[0].number // empty' 2>/dev/null || true)"
if [[ -n "$existing_pr_number" ]]; then
  probe="$(merge_queue_probe "$repo_slug" "$existing_pr_number" 2>/dev/null || true)"
  queued="$(jq -r '.queued' <<<"$probe" 2>/dev/null || true)"
  if [[ "$queued" != "false" ]]; then
    say "$repo_slug#$existing_pr_number is queued (or its state could not be confirmed) — skipping this roll"
    exit 0
  fi
fi

require_git_identity "roll-changelog"
git -C "$clone_dir" add CHANGELOG.md
git -C "$clone_dir" commit -q -m "docs(changelog): roll ${roll_date}"
git -C "$clone_dir" push --force-with-lease origin "HEAD:refs/heads/$BRANCH"

if [[ -n "$existing_pr_number" ]]; then
  "$ROLL_GH" pr edit "$existing_pr_number" -R "$repo_slug" --title "docs(changelog): roll ${roll_date}" >/dev/null
  say "updated $repo_slug#$existing_pr_number"
else
  defaulted_config="$(config_defaults "$SCRIPT_DIR/config.json" "$SCRIPT_DIR/config.schema.json" 2>/dev/null || echo '{}')"
  pr_label="$(jq -r '.pr_label // "autonomous-agent"' <<<"$defaulted_config")"
  # Best-effort: a repository already worked by the ordinary pipeline has
  # this label already (lib/labels.sh's own periodic ensure); a fresh
  # installation may not, and this pull request opens ready rather than
  # draft, so it needs one now rather than waiting for that ensure to run.
  "$ROLL_GH" label create "complexity:low" -R "$repo_slug" --color c2e0c6 \
    --description "Graded by the Implementer; picks the Reviewer tier" >/dev/null 2>&1 || true
  # shellcheck disable=SC2016  # markdown backticks in the format string, not command substitution
  pr_body="$(printf 'Rolls the `[Unreleased]` CHANGELOG.md section to `## [%s]` and opens a fresh, empty `[Unreleased]` above it (agent-ops#1809).\n' "$roll_date")"
  pr_url="$("$ROLL_GH" pr create -R "$repo_slug" --base "$default_branch" --head "$BRANCH" \
    --title "docs(changelog): roll ${roll_date}" --body "$pr_body" \
    --label "$pr_label" --label "complexity:low")"
  say "opened $pr_url"
fi
