#!/usr/bin/env bash
#
# lib/union-log-scan.sh — a one-pass-per-repository reader of the fleet's
# union event log, for a fact more than one caller in the same cycle needs
# about the same repository (#1050).
#
# A pull request's originating `source`/`item` is fixed at claim time and
# never mutates — GitHub carries no field for either at all — so both are
# read back from the `selection` event `agent-cycle.sh` logs once per work
# order, `{repo, item, source, model, title, branch}`, verbatim regardless of
# which source it came from. Two callers need that fact for a repository/
# branch their own process never claimed: `lib/standdown.sh`'s back-pressure
# count (requirement 2.2's level-aware "otherwise-eligible" narrowing, #946)
# once per ready, non-CHANGES_REQUESTED pull request, per repository, on
# every cycle — before the cycle has decided to do any work at all — and
# `_landing_retry_sweep_repo` (lib/landing.sh) once per candidate in its own
# 2.1e retry sweep. Both costs grow with exactly what back-pressure exists to
# watch: fleet activity swells the log, and an open-PR backlog swells the
# candidate count.
#
# `landing_retry_source_map` answers both in one pass: one scan of the log's
# `selection` events for one repository, building one JSON object callers
# look every one of that repository's branches up in — a `jq` query against a
# string already in memory, not a re-parse of the file per candidate. Reads
# the log with the streaming `-R -n` + `inputs` idiom #791/#792 established in
# place of the quadratic whole-input regex-split shape it replaced
# (test/union-log-scan.test.sh guards that shape fleet-wide), tolerant of a
# NUL-corrupted record from an unclean stop (`fromjson? // empty`) exactly as
# every other union-log reader in this codebase already is.
#
# Sourced, never executed — matching every other lib/*.sh. Sourced by every
# caller ahead of lib/landing.sh, which does not source this file itself (no
# lib/*.sh file sources another; see lib/landing.sh's own header).

# landing_retry_source_map REPO [LOG_FILE]
# One pass over LOG_FILE's (or stdin's, "-" or omitted) `selection` events for
# REPO, printing a compact JSON object `{branch: {source, item}}` — the most
# recent matching event per branch wins (`sort_by(.ts) | last`), a branch this
# system reuses (an item retried under a fresh claim) still resolves to its
# current claim, never a stale one. A branch absent from the log, or present
# only under `event`s other than `selection`, or under a different `repo`, is
# simply absent from the returned object — a caller reads a missing key with
# an ordinary `// empty` lookup.
#
# Prints `{}` — never a bare empty string — on a missing, empty or unreadable
# LOG_FILE, or when REPO has no `selection` events in it at all, so a caller
# can always pipe the result straight into a `jq` lookup with no fallback of
# its own.
landing_retry_source_map() {
  local repo="$1" src="${2:--}" out=""
  # shellcheck disable=SC2016  # $repo is jq's own --arg variable, not the shell's.
  local jq_prog='
    [ inputs | select(length > 0) | (fromjson? // empty)
      | select(.event == "selection" and (.repo // "") == $repo
               and (.branch // "") != "") ]
    | group_by(.branch)
    | map({key: (.[0].branch), value: (sort_by(.ts) | last | {source: (.source // ""), item: (.item // "")})})
    | from_entries'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R -n --arg repo "$repo" "$jq_prog" 2>/dev/null)" || out=""
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R -n --arg repo "$repo" "$jq_prog" "$src" 2>/dev/null)" || out=""
  fi
  [[ -n "$out" ]] && printf '%s' "$out" || printf '{}'
}
