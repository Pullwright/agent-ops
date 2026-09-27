#!/usr/bin/env bash
#
# test/report-directory.test.sh — regression test for lib/report-directory.sh
# (issue #761): resolving a configurable `report_directory` — a GNU date(1)
# format string — into today's write path, and discovering which of its past
# instances already exist on a repository's default branch.
#
# Behaviours asserted:
#
#   - `report_directory_regex` turns a format string into an ERE matching any
#     string `date` could produce from it, escaping literal regex
#     metacharacters (including a literal backslash) and degrading an
#     unrecognised specifier to a wildcard rather than failing.
#   - `report_directory_find_dirs` discovers existing directories matching a
#     format's shape: the common case (the whole dynamic part is the format's
#     final segment, as the shipped default and every example in the issue
#     are shaped) costs exactly one directory listing; a format with a
#     dynamic segment in the middle and a static leaf after it still
#     resolves, at the cost of one further listing per level.
#   - `report_directory_most_recent` finds the latest existing instance and
#     its own date, and prints nothing when none exist within the lookback
#     window.
#   - A listing that fails for a reason other than the queried path not
#     existing (issue #1024) is signalled through `report_directory_find_dirs`'s
#     and `report_directory_most_recent`'s own exit status — distinct from a
#     genuinely empty listing (nothing matched, or a clean 404), which exits 0
#     printing nothing, the same as before this distinction existed.
#   - That exit status is the *whole* of the signal: a multi-segment format's
#     walk that degrades partway still prints the candidates it did find, so a
#     caller ignoring the status sees byte-identically what it always saw.
#   - The shape both silent-degrade callers use (`… | cut -f<n>` under
#     `set -euo pipefail`, from an errexit-live context) degrades its own value
#     to empty on a failed walk rather than aborting the calling cycle.
#
# `gh` is stubbed the same shape test/gather-project-review.test.sh uses.
# Fixture dates are computed relative to the real clock at run time (10/20/45
# days ago), never hardcoded to a calendar year, because
# report_directory_most_recent's own search runs backward from today — a
# fixture pinned to "2026" would go stale (silently start failing) the day
# that year is more than the default 400-day lookback in the past.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/report-directory.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$SCRIPT_DIR/lib/report-directory.sh"

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

# shellcheck source=lib/report-directory.sh
. "$LIB"

# --- report_directory_regex -------------------------------------------------

assert_eq "the shipped default format" \
  'project-review-[0-9]{4}-[0-9]{2}-[0-9]{2}' \
  "$(report_directory_regex 'project-review-%Y-%m-%d')"
assert_eq "a docs/ prefix is copied through literally" \
  'docs/reviews/project-review-[0-9]{4}-[0-9]{2}-[0-9]{2}' \
  "$(report_directory_regex 'docs/reviews/project-review-%Y-%m-%d')"
# shellcheck disable=SC2016  # both single-quoted arguments are literal test data — $ and the rest are not meant to expand
assert_eq "regex metacharacters in the literal text are escaped" \
  'a\.b\*c\+d\?e\(f\)g\[h\]i\{j\}k\^l\$m\|n\\o' \
  "$(report_directory_regex 'a.b*c+d?e(f)g[h]i{j}k^l$m|n\o')"
assert_eq "an unrecognised specifier degrades to a wildcard, not a failure" \
  'x.*y' \
  "$(report_directory_regex 'x%Zy')"
assert_eq "a literal percent (%%) is a literal percent" \
  '100%' \
  "$(report_directory_regex '100%%')"

# --- Fixture dates, relative to the real clock (see file header) -----------
old_date="$(date -u -d '-45 day' +%Y-%m-%d)"
mid_date="$(date -u -d '-20 day' +%Y-%m-%d)"
recent_date="$(date -u -d '-10 day' +%Y-%m-%d)"

# --- A stub `gh`, the same shape test/gather-project-review.test.sh uses ---
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
[[ "\${1:-}" == "api" ]] || { echo "stub gh: unexpected call: \$*" >&2; exit 1; }
path="\${2:-}"
case "\$path" in
  repos/o/r/contents/reviews\\?ref=*)
    echo '[{"name":"project-review-$old_date","type":"dir"},{"name":"project-review-$recent_date","type":"dir"},{"name":"$mid_date","type":"dir"},{"name":"README.md","type":"file"}]'
    ;;
  repos/o/r/contents/docs/reviews\\?ref=*)
    echo '[{"name":"project-review-$recent_date","type":"dir"}]'
    ;;
  repos/o/r/contents\\?ref=*)
    echo '[{"name":"reviews","type":"dir"},{"name":"README.md","type":"file"}]'
    ;;
  repos/o/r/contents/reviews/$mid_date\\?ref=*)
    echo '[{"name":"my-repo-review","type":"dir"}]'
    ;;
  repos/o/empty/contents/reviews\\?ref=*)
    echo '[{"name":"README.md","type":"file"}]'
    ;;
  repos/o/nodir/contents/reviews\\?ref=*)
    echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
    ;;
  repos/o/fail/contents/reviews\\?ref=*)
    echo "gh: error connecting to api.github.com" >&2
    exit 1
    ;;
  # o/partial: a multi-segment dynamic format whose first level lists fine and
  # whose second level succeeds for one date and fails for another — the only
  # shape where "the walk degraded" and "the walk found something" are both
  # true at once.
  repos/o/partial/contents/reviews\\?ref=*)
    echo '[{"name":"$mid_date","type":"dir"},{"name":"$old_date","type":"dir"}]'
    ;;
  repos/o/partial/contents/reviews/$mid_date\\?ref=*)
    echo '[{"name":"my-repo-review","type":"dir"}]'
    ;;
  repos/o/partial/contents/reviews/$old_date\\?ref=*)
    echo "gh: error connecting to api.github.com" >&2
    exit 1
    ;;
  *)
    echo "stub gh: unexpected call: \$*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

# --- report_directory_find_dirs ---------------------------------------------

assert_eq "the default format's whole dynamic part is its final segment — every match found" \
  "reviews/project-review-$old_date
reviews/project-review-$recent_date" \
  "$(report_directory_find_dirs o/r main 'reviews/project-review-%Y-%m-%d')"
assert_eq "a leading static segment (docs/) is folded into the listing path" \
  "docs/reviews/project-review-$recent_date" \
  "$(report_directory_find_dirs o/r main 'docs/reviews/project-review-%Y-%m-%d')"
assert_eq "a dynamic segment in the middle, with a static leaf after it, still resolves" \
  "reviews/$mid_date/my-repo-review" \
  "$(report_directory_find_dirs o/r main 'reviews/%Y-%m-%d/my-repo-review')"
assert_eq "no report directory ever written degrades to nothing, not a failure" \
  "" \
  "$(report_directory_find_dirs o/empty main 'reviews/project-review-%Y-%m-%d')"

# --- report_directory_most_recent -------------------------------------------

assert_eq "the most recent of several candidates, by date rather than listing order" \
  "$(printf '%s\treviews/project-review-%s' "$recent_date" "$recent_date")" \
  "$(report_directory_most_recent o/r main 'reviews/project-review-%Y-%m-%d')"
assert_eq "the resolved directory for a custom format" \
  "$(printf '%s\tdocs/reviews/project-review-%s' "$recent_date" "$recent_date")" \
  "$(report_directory_most_recent o/r main 'docs/reviews/project-review-%Y-%m-%d')"
assert_eq "a dynamic-middle format's own date and full path" \
  "$(printf '%s\treviews/%s/my-repo-review' "$mid_date" "$mid_date")" \
  "$(report_directory_most_recent o/r main 'reviews/%Y-%m-%d/my-repo-review')"
assert_eq "nothing to discover prints nothing" \
  "" \
  "$(report_directory_most_recent o/empty main 'reviews/project-review-%Y-%m-%d')"

# --- A failed listing is signalled distinctly from a genuine empty (issue --
# --- #1024) --------------------------------------------------------------

out="$(report_directory_find_dirs o/fail main 'reviews/project-review-%Y-%m-%d' 2>/dev/null)"; rc=$?
assert_eq "a failed listing prints nothing" "" "$out"
assert_eq "  ...but exits nonzero, unlike a genuine empty" "1" "$rc"

out="$(report_directory_find_dirs o/empty main 'reviews/project-review-%Y-%m-%d' 2>/dev/null)"; rc=$?
assert_eq "a genuinely empty listing still prints nothing" "" "$out"
assert_eq "  ...and exits 0" "0" "$rc"

out="$(report_directory_find_dirs o/nodir main 'reviews/project-review-%Y-%m-%d' 2>/dev/null)"; rc=$?
assert_eq "a clean 404 (no reviews/ directory at all) prints nothing" "" "$out"
assert_eq "  ...and is a definite empty, not a failure" "0" "$rc"

out="$(report_directory_most_recent o/fail main 'reviews/project-review-%Y-%m-%d' 2>/dev/null)"; rc=$?
assert_eq "most_recent also prints nothing on a failed listing" "" "$out"
assert_eq "  ...and exits nonzero, distinct from nothing-to-discover" "1" "$rc"

out="$(report_directory_most_recent o/nodir main 'reviews/project-review-%Y-%m-%d' 2>/dev/null)"; rc=$?
assert_eq "most_recent on a clean 404 still prints nothing" "" "$out"
assert_eq "  ...but exits 0, the same as any other confirmed empty" "0" "$rc"

# The exit status is the whole of the signal: a walk that degraded *and* found
# something still prints what it found, so a caller ignoring the status sees
# byte-identically what it saw before this distinction existed. Only a
# multi-segment format can reach this state — see the o/partial stub above.
out="$(report_directory_find_dirs o/partial main 'reviews/%Y-%m-%d/my-repo-review' 2>/dev/null)"; rc=$?
assert_eq "a partly-degraded walk still prints the candidates it did find" \
  "reviews/$mid_date/my-repo-review" "$out"
assert_eq "  ...and signals the degradation only through its exit status" "1" "$rc"

out="$(report_directory_most_recent o/partial main 'reviews/%Y-%m-%d/my-repo-review' 2>/dev/null)"; rc=$?
assert_eq "most_recent resolves the most recent of a partly-degraded walk's finds" \
  "$(printf '%s\treviews/%s/my-repo-review' "$mid_date" "$mid_date")" "$out"
assert_eq "  ...and likewise signals the degradation only through its exit status" "1" "$rc"

# The two silent-degrade callers pipe this through `cut` under
# `set -euo pipefail` and reach it from an errexit-live context —
# review-cycle.sh's most_recent_review_date (via skip_reason) and
# lib/candidate-gather.sh's report_directory_resolved (via a bare
# gather_ordered_repos). `pipefail` carries the walk's nonzero status to the
# pipeline and errexit then acts on the assignment, so declining the signal is
# something each has to do explicitly rather than by not asking for it. Both
# halves are asserted: that an unguarded caller of this shape really does die
# (so the guards are load-bearing, not decoration) and that a guarded one
# degrades its own value to empty instead.
#
# The probe runs as its own `bash` *process*, not a subshell: bash stops
# honouring errexit inside a command substitution, and re-issuing
# `set -e` there does not bring it back — so a probe wrapped in `$(…)` would
# report every caller as surviving, including the unguarded one this asserts
# does not. agent-cycle.sh and review-cycle.sh are processes; so is this.
probe_errexit_shape() {  # probe_errexit_shape SLUG GUARD -> "survived:<value>" | "aborted"
  local slug="$1" guard="$2" tail_guard="" out
  [[ "$guard" == guarded ]] && tail_guard=" || true"
  cat >"$tmp_dir/errexit-probe.sh" <<PROBE
#!/usr/bin/env bash
set -euo pipefail
. "$LIB"
caller_shape() {
  local resolved
  if true; then
    resolved="\$(report_directory_most_recent "$slug" main 'reviews/project-review-%Y-%m-%d' 2>/dev/null | cut -f2)"$tail_guard
  fi
  printf 'survived:%s' "\$resolved"
}
caller_shape
PROBE
  out="$(bash "$tmp_dir/errexit-probe.sh" 2>/dev/null)" || out="aborted"
  printf '%s' "$out"
}
assert_eq "an unguarded caller of this shape is killed by errexit on a failed walk" \
  "aborted" "$(probe_errexit_shape o/fail unguarded)"
assert_eq "a guarded one degrades its own value to empty instead" \
  "survived:" "$(probe_errexit_shape o/fail guarded)"
assert_eq "  ...and still resolves a value when the walk succeeds" \
  "survived:reviews/project-review-$recent_date" "$(probe_errexit_shape o/r guarded)"

# …and that each real call site is the guarded form, since neither script
# exposes a unit boundary the probe above could drive directly. Same
# source-level assertion style test/repo-entry-build.test.sh uses.
assert_call_site_guarded() {  # assert_call_site_guarded FILE
  local file="$1" line
  line="$(grep -n 'report_directory_most_recent' "$SCRIPT_DIR/$file" \
    | grep -v '^[0-9]*:#' | grep 'cut -f' || true)"
  if [[ -n "$line" && "$line" == *'|| true'* ]]; then
    printf 'ok   - %s declines the degraded-read signal at its call site\n' "$file"
  else
    printf 'FAIL - %s must decline the degraded-read signal with a trailing "|| true" — it calls\n' "$file"
    printf '     report_directory_most_recent under set -euo pipefail from an errexit-live\n'
    printf '     context, where a failed walk would otherwise abort the cycle.\n'
    printf '     found: %s\n' "${line:-<no piped call site found>}"
    failures=$(( failures + 1 ))
  fi
}
assert_call_site_guarded review-cycle.sh
assert_call_site_guarded lib/candidate-gather.sh

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
