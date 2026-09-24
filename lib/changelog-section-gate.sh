#!/usr/bin/env bash
#
# lib/changelog-section-gate.sh — pipeline-side enforcement of requirement 25c
# for every target repository, not only the one that carries a workflow file,
# on `lib/closing-keyword-gate.sh`'s own pattern (agent-ops#1808).
#
# `.github/workflows/changelog-section.yml` runs
# `scripts/check-changelog-section.sh` on every `pull_request` event, but a
# workflow file only guards the repository that ships it, and only agent-ops
# does. For poetic and poetic-fiddle — the other two repositories this
# pipeline raises pull requests in — a `feat`/`fix`/`perf` (or breaking-change)
# pull request there could still merge without its owed `## Changelog`
# section on prompt instruction alone: the same shape TD-PPagop-26080803
# closed for the closing keyword.
#
# This file runs the exact same check the workflow does, script-side, so it
# applies everywhere the Script itself acts, regardless of which repository's
# CI does or does not carry the workflow. It reuses
# `scripts/check-changelog-section.sh` unmodified — that script already takes
# `<pr-body> [<pr-title>]` and needs nothing from the caller but the two
# facts `gh pr view` already knows.
#
# "Could not ask" is `unknown`, not `dirty`, for exactly the reasons
# `lib/closing-keyword-gate.sh`'s own header gives — an unreadable `gh pr
# view` says something about this node, not about the pull request, and
# blocking every handoff on a degraded `gh` forever would trade one hazard
# for a worse one.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller (agent-cycle.sh runs under `set -euo pipefail`;
# a test, `set -uo pipefail`) owns those.
#
# Environment:
#   CHANGELOG_SECTION_GATE_GH     override `gh` (tests stub it).
#   CHANGELOG_SECTION_GATE_CHECK  override the checker script's path (tests
#     point it at a fixture; defaults to the real
#     scripts/check-changelog-section.sh next to this file's own repository).

# changelog_section_gate PR_URL
# Print `clean`, `dirty<TAB>reason`, or `unknown<TAB>reason`. Exit 0 for clean
# or unknown, 1 for dirty — the same shape `closing_keyword_gate` reports, so
# a caller can fold both into one handoff gate.
#   clean    the pull request's description carries a `## Changelog` section
#            of the shape requirement 25c states wherever its title owes one,
#            or owes none at all.
#   dirty    it owes a section and does not carry one, or carries one the
#            grammar faults — a fact about this pull request, and a
#            description edit away from clean.
#   unknown  the question could not be put: `gh pr view` failed or answered
#            with something that is not a pull request, or the checker itself
#            could not be run. See the header for why that is not `dirty`.
changelog_section_gate() {
  local url="${1:-}" gh_bin="${CHANGELOG_SECTION_GATE_GH:-gh}"
  local checker="${CHANGELOG_SECTION_GATE_CHECK:-}"
  local pr_json body title reason rc

  [[ -n "$checker" ]] || checker="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/check-changelog-section.sh"

  # No URL at all is the one unanswerable case that stays `dirty`: it is a
  # caller asking about nothing, a bug in this file's caller rather than a
  # degraded node — the same exception `closing_keyword_gate` carries.
  if [[ -z "$url" ]]; then
    printf 'dirty\tno pull request URL to check'
    return 1
  fi

  # `title` non-empty, not merely "the call exited 0": every real pull
  # request carries a title, so an empty one is a truncated or otherwise
  # unexpected answer — and an empty title reads to the checker as "owes
  # nothing", which would let a genuinely unreadable pull request pass as
  # silently as an empty body on an empty head branch would for the
  # closing-keyword gate. Silence must not read as a pass here either.
  if ! pr_json="$("$gh_bin" pr view "$url" --json body,title 2>/dev/null)" \
     || ! jq -e '(type == "object") and (.title | type == "string") and (.title != "")' \
          <<<"$pr_json" >/dev/null 2>&1; then
    printf 'unknown\tcould not read %s'\''s body and title' "$url"
    return 0
  fi
  body="$(jq -r '.body // ""' <<<"$pr_json")"
  title="$(jq -r '.title' <<<"$pr_json")"

  reason="$("$checker" "$body" "$title" 2>&1 >/dev/null)"
  rc=$?
  if (( rc == 0 )); then
    printf 'clean'
    return 0
  fi
  # One line, always. The checker writes one `::error::`-prefixed line per
  # fault it finds, and every caller reads this verdict with
  # `IFS=$'\t' read -r word reason`, which keeps the first line and silently
  # discards the rest. Flatten here, where the whole reason is still in
  # hand, rather than let it be truncated there. The `::error::` prefix is a
  # GitHub Actions workflow command and means nothing in any of the three
  # places this reason actually lands — a `## Script findings` line a
  # Reviewer is asked to act on, a warning on the cycle log, and the
  # `attempt-failed` record the Enabler reads — so it goes with it.
  reason="${reason//::error::/}"
  reason="${reason//$'\n'/; }"
  # 126 (not executable), 127 (not found), 128+n (killed): the checker never
  # reached a verdict, so neither did this gate. Same reasoning as the
  # unreadable pull request above — a broken or missing checker is a fact
  # about this node's checkout, not about the pull request.
  if (( rc >= 126 )); then
    printf 'unknown\tcould not run %s (exit %d): %s' "$checker" "$rc" "${reason:-no output}"
    return 0
  fi
  printf 'dirty\t%s' "${reason:-check-changelog-section.sh failed with no output}"
  return 1
}
