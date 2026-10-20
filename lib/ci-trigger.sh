#!/usr/bin/env bash
#
# lib/ci-trigger.sh — detects and repairs a push whose CI trigger GitHub
# never delivered (issue #2560): a head commit left with zero check runs at
# all — not failing, simply absent — which looks indistinguishable from "CI
# still queued" to a casual reader, but can conceal a head that actually
# fails (agent-ops#2506: ~7 hours with no check runs at all, the head
# genuinely failing `scripts/spec.sh check`). The same branch had already
# needed one manual nudge (`6c379e10a9`, "chore(ci): nudge a missed
# synchronize event for the previous push"), so this is recurring, not a
# one-off.
#
# `lib/review-gate.sh` already has half of this gap closed:
# `_review_gate_missing_required_contexts` (the issue #1543 backstop) and
# `_review_gate_repair_duplicate_runs` (the issue #1978 repair). Neither
# covers a genuinely zero check-run count: both run only at a Reviewer
# handoff — potentially hours after the push — and neither has a run id for
# `gh run rerun` to act on when the count is zero. This file runs
# immediately after the Implementer stage's own push instead, polling for up
# to `CI_TRIGGER_POLL_ATTEMPTS` x `CI_TRIGGER_POLL_INTERVAL` seconds
# (default 10 x 30s = 5 minutes — the conservative end of a threshold the
# issue left open) and, where the check-runs list is still completely empty
# at the end of that window, retriggers with an empty commit — the one
# mechanism this repository's own history already proves works — rather
# than `gh run rerun`/`workflow_dispatch`: there is no run id to rerun when
# the count is zero, and `workflow_dispatch` is not a trigger every relevant
# workflow declares.
#
# At most one retrigger per head commit (the issue's own scope): if the
# nudge push itself produces zero runs again, this stops and lets it surface
# exactly as any other dirty/escalation path already does (the #1543/#1978
# backstops above, at the next Reviewer handoff), rather than looping.
#
# Never computed in a stage's own clone. `lib/rebase-only.sh`'s header
# already gives the reason this file shares: that clone is the Implementer's
# to rewrite (requirement 45e), so a commit authored there would both answer
# whatever the stage arranged and run the stage's own commands — hooks,
# filters, an fsmonitor — as the Script. The nudge commit is made instead in
# a disposable repository this file creates and discards, fetching and
# pushing only the one branch by name — the same shape
# `rebase_only_forge_capture` already uses for the identical reason.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller (agent-cycle.sh runs under `set -euo pipefail`;
# a test, `set -uo pipefail`) owns those.
#
# Environment:
#   CI_TRIGGER_GH              override `gh` (tests stub it).
#   CI_TRIGGER_POLL_ATTEMPTS   how many times to re-read check runs before
#                              giving up (default 10; a test sets this low).
#   CI_TRIGGER_POLL_INTERVAL   seconds between reads (default 30; a test
#                              sets this to 0).

# _ci_trigger_check_runs_state SLUG NUMBER
# Exit 0 when `gh pr checks NUMBER -R SLUG --json name,bucket` reports at
# least one check run at all (any bucket) against NUMBER's current head;
# exit 1 when it reports a confirmed-empty array; exit 2 when the read
# itself could not be trusted — a non-array answer, or `gh` failing
# outright (a 502, a transient auth failure, a rate limit). Unfiltered —
# `--required` would narrow to the required subset, and this asks "did
# anything run at all", the same distinction `review_gate_required_checks`
# draws between a required check that is absent and one that ran and
# failed, applied here one level further back: whether anything ran at
# all. A caller must never treat exit 2 as exit 1 — an unreadable list is
# "could not tell", never "confirmed empty", so it must not count toward
# the nudge threshold below.
_ci_trigger_check_runs_state() {
  local slug="$1" number="$2" gh_bin="${CI_TRIGGER_GH:-gh}" raw
  raw="$("$gh_bin" pr checks "$number" -R "$slug" --json name,bucket 2>/dev/null)" || return 2
  jq -e 'type == "array"' <<<"$raw" >/dev/null 2>&1 || return 2
  jq -e 'length > 0' <<<"$raw" >/dev/null 2>&1 && return 0
  return 1
}

# _ci_trigger_nudge_push SLUG BRANCH HEAD_SHA
# Push one empty commit onto BRANCH, in a disposable repository fetched
# fresh from the forge rather than any stage's own clone (see header). Exit
# 0 on a successful push, 1 otherwise. Confirms BRANCH's current tip still
# matches HEAD_SHA before committing — a peer's or a human's own push
# landing in the gap between the poll above and this call must never be
# overwritten by a nudge aimed at a commit that is no longer the tip — and
# refuses rather than nudging anything else when it does not.
_ci_trigger_nudge_push() {
  local slug="$1" branch="$2" head_sha="$3" gh_bin="${CI_TRIGGER_GH:-gh}"
  local repo tip rc=1
  repo="$(mktemp -d "${TMPDIR:-/tmp}/ci-trigger-nudge.XXXXXX")" || return 1
  if git init --quiet "$repo" >/dev/null 2>&1 \
     && git -C "$repo" remote add origin "https://github.com/$slug.git" \
     && git -C "$repo" fetch --quiet --depth 1 origin \
          "+refs/heads/$branch:refs/heads/$branch" >/dev/null 2>&1 \
     && tip="$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null)" \
     && [[ -n "$tip" && "$tip" == "$head_sha" ]] \
     && git -C "$repo" checkout --quiet "$branch" >/dev/null 2>&1 \
     && git -C "$repo" commit --quiet --allow-empty \
          -m "chore(ci): nudge a missed CI trigger for $head_sha" >/dev/null 2>&1 \
     && git -C "$repo" push --quiet origin "HEAD:refs/heads/$branch" >/dev/null 2>&1; then
    rc=0
  fi
  rm -rf -- "$repo"
  return $rc
}

# ci_trigger_ensure SLUG NUMBER BRANCH
# Print `triggered`, `queued`, `nudged<TAB>HEAD_SHA`, `nudge-failed<TAB>
# HEAD_SHA`, or `unknown`. Polls `_ci_trigger_check_runs_state` up to
# CI_TRIGGER_POLL_ATTEMPTS times, CI_TRIGGER_POLL_INTERVAL seconds apart,
# returning `triggered` (exit 0) the moment any poll reports at least one
# check run.
#
# If every poll in the window reports a confirmed-empty list, this reads
# NUMBER's current head (fresh — never the SHA a caller read before the
# poll began, which a push during the window would make stale) and, unless
# that pull request is currently queued in a merge group
# (`merge_queue_probe`; D17 — a push would evict it with no further signal,
# so this must never push to one, matching every other push path this
# pipeline guards the same way) pushes one empty-commit nudge
# (`_ci_trigger_nudge_push`) and prints `nudged<TAB>HEAD_SHA` (exit 0) or
# `nudge-failed<TAB>HEAD_SHA` (exit 1) depending on whether the push
# succeeded. Never polls again after the nudge — at most one retrigger per
# head commit (see header): a nudge that itself produces zero runs is left
# for the #1543/#1978 backstops at the next Reviewer handoff to find,
# rather than looped on here.
#
# Prints `unknown` (exit 1) whenever the window ends on an unreadable read
# (exit 2 above) rather than a confirmed-empty one, or when NUMBER's
# current head or its queue state cannot be read — a fact about this node
# or GitHub's availability, not evidence that the trigger was actually
# missed, so none of those ever push a nudge.
ci_trigger_ensure() {
  local slug="${1:-}" number="${2:-}" branch="${3:-}"
  local gh_bin="${CI_TRIGGER_GH:-gh}"
  local attempts interval i state=2 head_sha queued_json queued

  [[ -n "$slug" && -n "$number" && -n "$branch" ]] || { printf 'unknown'; return 1; }

  attempts="${CI_TRIGGER_POLL_ATTEMPTS:-10}"
  interval="${CI_TRIGGER_POLL_INTERVAL:-30}"

  for (( i = 0; i < attempts; i++ )); do
    _ci_trigger_check_runs_state "$slug" "$number"; state=$?
    if (( state == 0 )); then
      printf 'triggered'
      return 0
    fi
    if (( i < attempts - 1 )) && (( interval > 0 )); then
      sleep "$interval"
    fi
  done

  if (( state != 1 )); then
    printf 'unknown'
    return 1
  fi

  head_sha="$("$gh_bin" pr view "$number" -R "$slug" --json headRefOid --jq .headRefOid 2>/dev/null)"
  [[ -n "$head_sha" ]] || { printf 'unknown'; return 1; }

  queued_json="$(merge_queue_probe "$slug" "$number" 2>/dev/null)" || queued_json=""
  # `.queued // empty` is not this: jq's `//` treats `false` as falsy too,
  # so that would read a confirmed-not-queued pull request the same as an
  # unreadable one — the type check is what `merge_queue_probe`'s own header
  # uses for the identical reason, and the one this file reuses.
  if ! jq -e '.queued | type == "boolean"' <<<"$queued_json" >/dev/null 2>&1; then
    printf 'unknown'
    return 1
  fi
  queued="$(jq -r '.queued' <<<"$queued_json" 2>/dev/null)"
  if [[ "$queued" == "true" ]]; then
    printf 'queued'
    return 1
  fi

  if _ci_trigger_nudge_push "$slug" "$branch" "$head_sha"; then
    printf 'nudged\t%s' "$head_sha"
    return 0
  fi
  printf 'nudge-failed\t%s' "$head_sha"
  return 1
}
