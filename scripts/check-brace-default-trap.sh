#!/usr/bin/env bash
#
# scripts/check-brace-default-trap.sh — permanent CI guard against the bash
# `${var:-word}` brace-default trap (issue #1035, TD-PPagop-26082922).
#
# `${parameter:-word}` closes on the FIRST unquoted closing brace it finds in
# `word`, not on the one the author meant. A `word` that opens with an
# unescaped brace or bracket — the shape a hand-written JSON/array default
# takes, e.g. an object literal or an empty-array literal placed straight
# after `:-` — therefore leaves a stray closing character sitting just
# outside the substitution: silently composing the intended default on the
# one path most fixtures exercise (the variable empty or unset), and
# silently corrupting every other value with an extra trailing
# brace/bracket. agent-ops#933/TD-PPagop-26082816 is the one instance found
# so far: an empty-object default on `coordinator_fit_report_json` written
# in exactly this shape (docs/spec/implementation/gotchas.md's Gotchas
# table has the literal syntax) disarmed requirements 34e, 3x and 17g for a
# month, because the empty/unset path (the only one any fixture drove)
# happened to compose the correct default by accident.
#
# This shape is not flagged by shellcheck — the buggy line lived under a
# green shellcheck run from the day it shipped — so PR #940 fixed the one known
# instance with a one-off manual grep sweep, documented the trap in
# docs/spec/implementation/gotchas.md's Gotchas table, and nothing stopped
# the shape from being reintroduced. This script is that sweep, made
# permanent, run as an additional step in the `shellcheck` CI job
# (.github/workflows/shellcheck.yml) alongside shellcheck itself, never in
# place of it.
#
# THE PATTERN is PR #940's own baseline, shipped literally rather than
# generalised: a `:-` default word starting with `{}` immediately followed by
# another `}`, or `[]` immediately followed by another `]`. A broader pattern
# — any unescaped `{`/`[` anywhere before a default word's real closing
# character — was considered and dropped: bash's own `${parameter:-word}`
# parsing does not track nested plain `{`/`[` the way it tracks nested
# `${`/`$(`, so a safe general rule would have to reason about what comes
# after the apparent close too, and a regex sweep is the wrong tool for that
# — it would either miss shapes it should not or flag legitimate defaults
# (a brace-expansion default such as `${var:-$(echo {1,2,3})}`) that are not
# this trap at all. The literal shape is exactly what bit this codebase once
# and it costs nothing to keep checking for verbatim.
#
# THE FILE SET matches PR #940's own sweep: agent-cycle.sh, review-cycle.sh,
# and everything tracked under lib/, scripts/ and test/ — read via
# `git ls-files`, so an untracked scratch file never fails the run and a
# file renamed or deleted since PR #940 is never stale-checked.
#
# Exit 0 iff no tracked file in that set contains the pattern.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "check-brace-default-trap: not a git repository — the file set comes from git ls-files." >&2
  exit 1
fi

# Two closing characters of the same kind, immediately after an opening one,
# right after a `:-` — see this file's own header for why this stays literal
# rather than generalising.
pattern=':-\{\}\}|:-\[\]\]'

files=()
for f in agent-cycle.sh review-cycle.sh; do
  [[ -f "$f" ]] && files+=("$f")
done
while IFS= read -r -d '' f; do
  [[ -f "$f" ]] || continue
  files+=("$f")
done < <(git ls-files -z -- lib scripts test)

if (( ${#files[@]} == 0 )); then
  echo "check-brace-default-trap: found no files to check — that cannot be right." >&2
  exit 1
fi

matches="$(grep -nE "$pattern" "${files[@]}" 2>/dev/null)"

if [[ -n "$matches" ]]; then
  {
    echo "check-brace-default-trap: found the bash \${var:-word} brace-default trap:"
    echo "$matches"
    echo
    echo "check-brace-default-trap: \${parameter:-word} closes on the FIRST unquoted"
    echo "  closing character it finds in word, not the one you meant — an unescaped"
    echo "  opening brace/bracket right after :- leaves a stray closing one just"
    echo "  outside the substitution, corrupting every non-empty value while the"
    echo "  empty/unset path looks fine. See the Gotchas table in"
    echo "  docs/spec/implementation/gotchas.md (the row on agent-ops#933/TD-PPagop-26082816) for the fix:"
    echo "  initialise the variable ahead of the guard instead of defaulting it."
  } >&2
  exit 1
fi

echo "check-brace-default-trap: clean"
exit 0
