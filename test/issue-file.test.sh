#!/usr/bin/env bash
#
# test/issue-file.test.sh — regression test for lib/issue-file.sh, the two
# halves every issue filer shares: `issue_find_by_body` (the dedup search by
# a needle in the body, with its three answers — found, none, and a search
# that failed, which is never "none") and `issue_create_with_retry` (one
# labelled create, retried once unlabelled, the number parsed and checked),
# plus the two context variables a caller sets to route them: the command
# `gh` runs through and where stderr lands.
#
# `gh` is a function, shadowing the binary, recording every call. Runs under
# `set -euo pipefail`, the options the Script runs the real callers under,
# so a helper that failed in a way `set -e` would turn into an abort fails
# here too.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/issue-file.test.sh
#
# Exit status is 0 iff every assertion passed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/issue-file.sh
. "$REPO_ROOT/lib/issue-file.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:             %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- gh stub ---------------------------------------------------------------
GH_CALLS="$tmp_dir/gh_calls"
GH_LIST='[]'
GH_LIST_FAIL=""
GH_CREATE_OUT="https://github.com/o/r/issues/77"
GH_CREATE_FAIL=""
GH_CREATE_FAIL_LABELLED=""
reset_gh() {
  : > "$GH_CALLS"
  GH_LIST='[]'; GH_LIST_FAIL=""
  GH_CREATE_OUT="https://github.com/o/r/issues/77"; GH_CREATE_FAIL=""; GH_CREATE_FAIL_LABELLED=""
}
# shellcheck disable=SC2317  # invoked only through lib/issue-file.sh
gh() {
  printf '%s\n' "$*" >> "$GH_CALLS"
  case "$1 $2" in
    "issue list")
      if [[ -n "$GH_LIST_FAIL" ]]; then printf 'gh: API rate limit exceeded (HTTP 403)\n' >&2; return 1; fi
      printf '%s' "$GH_LIST" ;;
    "issue create")
      [[ -z "$GH_CREATE_FAIL" ]] || { printf 'gh: boom\n' >&2; return 1; }
      if [[ -n "$GH_CREATE_FAIL_LABELLED" && "$*" == *"--label"* ]]; then
        printf 'gh: could not add label\n' >&2; return 1
      fi
      printf '%s\n' "$GH_CREATE_OUT" ;;
    *) return 1 ;;
  esac
}

# ============================================================================
# issue_find_by_body: found, none, failed
# ============================================================================
reset_gh
GH_LIST='[{"number":5,"url":"https://github.com/o/r/issues/5","body":"other"},
          {"number":9,"url":"https://github.com/o/r/issues/9","body":"ref: o/x#12 here"}]'
rc=0; out="$(issue_find_by_body o/r "o/x#12" "o/x#12")" || rc=$?
assert_eq "find: the first issue whose body contains the needle is found" "0" "$rc"
assert_eq "find: ...printed as number and url" $'9\thttps://github.com/o/r/issues/9' "$out"
assert_eq "find: one listing, open, searched, at a stated page of 200" \
  'issue list -R o/r --state open --search o/x#12 --limit 200 --json number,url,body' "$(cat "$GH_CALLS")"

: > "$GH_CALLS"
rc=0; out="$(issue_find_by_body o/r "o/x#12" "o/x#12" all pw::pager 20)" || rc=$?
assert_eq "find: state, label and limit are honoured as given" \
  'issue list -R o/r --state all --label pw::pager --search o/x#12 --limit 20 --json number,url,body' "$(cat "$GH_CALLS")"

rc=0; out="$(issue_find_by_body o/r "o/x#12" "o/x#99")" || rc=$?
assert_eq "find: a listing with no match is 1" "1" "$rc"
assert_eq "find: ...printing nothing" "" "$out"

GH_LIST_FAIL=1
rc=0; out="$(issue_find_by_body o/r "o/x#12" "o/x#12")" || rc=$?
assert_eq "find: a listing that fails is 2, not none" "2" "$rc"
assert_eq "find: ...printing nothing" "" "$out"
GH_LIST_FAIL=""
GH_LIST='not json'
rc=0; out="$(issue_find_by_body o/r "o/x#12" "o/x#12")" || rc=$?
assert_eq "find: a listing that is not an array is 2 too" "2" "$rc"
GH_LIST='{"number":9}'
rc=0; out="$(issue_find_by_body o/r "o/x#12" "o/x#12")" || rc=$?
assert_eq "find: ...an object included" "2" "$rc"

# ============================================================================
# issue_create_with_retry: labelled, retried, unlabelled, failed
# ============================================================================
reset_gh
printf 'body\n' > "$tmp_dir/body.md"
rc=0; out="$(issue_create_with_retry o/r "A title" "$tmp_dir/body.md" pw::type:tech-debt)" || rc=$?
assert_eq "create: a labelled create succeeds" "0" "$rc"
assert_eq "create: ...printing number and url" $'77\thttps://github.com/o/r/issues/77' "$out"
assert_eq "create: exactly one create, the label last" \
  "issue create -R o/r --title A title --body-file $tmp_dir/body.md --label pw::type:tech-debt" "$(cat "$GH_CALLS")"

reset_gh
rc=0; out="$(issue_create_with_retry o/r "A title" "$tmp_dir/body.md" pw::pager the-owner)" || rc=$?
assert_eq "create: an assignee is carried, before the label" \
  "issue create -R o/r --title A title --body-file $tmp_dir/body.md --assignee the-owner --label pw::pager" "$(cat "$GH_CALLS")"

reset_gh
GH_CREATE_FAIL_LABELLED=1
rc=0; out="$(issue_create_with_retry o/r "A title" "$tmp_dir/body.md" pw::type:tech-debt)" || rc=$?
assert_eq "create: a labelled create that fails is retried unlabelled" "0" "$rc"
assert_eq "create: ...one labelled and one unlabelled create" "2" "$(grep -c '^issue create' "$GH_CALLS")"
assert_eq "create: ...the retry carrying no label" \
  "issue create -R o/r --title A title --body-file $tmp_dir/body.md" "$(sed -n 2p "$GH_CALLS")"

reset_gh
rc=0; out="$(issue_create_with_retry o/r "A title" "$tmp_dir/body.md")" || rc=$?
assert_eq "create: no label, one create" "1" "$(grep -c '^issue create' "$GH_CALLS")"
assert_eq "create: ...with no --label at all" "0" "$(grep -c -- '--label' "$GH_CALLS" || true)"

reset_gh
GH_CREATE_FAIL=1
rc=0; out="$(issue_create_with_retry o/r "A title" "$tmp_dir/body.md" pw::type:tech-debt)" || rc=$?
assert_eq "create: both creates failing is 1" "1" "$rc"
assert_eq "create: ...printing nothing" "" "$out"
assert_eq "create: ...after exactly two attempts" "2" "$(grep -c '^issue create' "$GH_CALLS")"

reset_gh
GH_CREATE_OUT="created, but no url here"
rc=0; out="$(issue_create_with_retry o/r "A title" "$tmp_dir/body.md")" || rc=$?
assert_eq "create: output carrying no issue url is 1" "1" "$rc"
GH_CREATE_OUT="https://github.com/o/r/issues/not-a-number"
rc=0; out="$(issue_create_with_retry o/r "A title" "$tmp_dir/body.md")" || rc=$?
assert_eq "create: a url whose number does not parse is 1" "1" "$rc"

# ============================================================================
# the context: the command gh runs through, and where stderr lands
# ============================================================================
reset_gh
ROUTED_CALLS="$tmp_dir/routed"
# shellcheck disable=SC2317  # invoked only through ISSUE_FILE_GH
routed_gh() { printf '%s\n' "$*" >> "$ROUTED_CALLS"; gh "${@:2}"; }
caller() {
  local ISSUE_FILE_GH=(routed_gh with-token) ISSUE_FILE_ERRLOG="$tmp_dir/errlog"
  issue_find_by_body o/r "o/x#12" "o/x#12" || true
  issue_create_with_retry o/r "A title" "$tmp_dir/body.md" pw::type:tech-debt
}
GH_CREATE_FAIL_LABELLED=1
: > "$ROUTED_CALLS"; : > "$tmp_dir/errlog"
rc=0; out="$(caller)" || rc=$?
assert_eq "context: a caller's local ISSUE_FILE_GH routes every call" "3" "$(wc -l < "$ROUTED_CALLS" | tr -d ' ')"
assert_contains "context: ...with its leading words first" "with-token issue list -R o/r" "$(cat "$ROUTED_CALLS")"
assert_contains "context: gh's stderr lands on ISSUE_FILE_ERRLOG" "could not add label" "$(cat "$tmp_dir/errlog")"
assert_contains "context: ...and so does the note about the retry" \
  "labelled issue create failed for o/r -- retrying unlabelled" "$(cat "$tmp_dir/errlog")"
assert_eq "context: ...and the filing still succeeded" "0" "$rc"
rc=0; out="$(issue_find_by_body o/r "o/x#12" "o/x#12")" || rc=$?
assert_eq "context: outside the caller, gh is run directly again" "3" "$(wc -l < "$ROUTED_CALLS" | tr -d ' ')"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
