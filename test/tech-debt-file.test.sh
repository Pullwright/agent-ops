#!/usr/bin/env bash
#
# test/tech-debt-file.test.sh — regression tests for lib/tech-debt-file.sh
# (agent-ops#631, revised agent-ops#874): filing a tech-debt or plain GitHub
# issue on the Script's own behalf, for the Approver and Enabler stages,
# which must never write to GitHub or a branch themselves.
#
# Behaviours asserted:
#
#   - **techdebt_file_debt dedups by normalised title** against REPO's own
#     open `pw::type:tech-debt` issues before filing: an exact or (both
#     titles at least eight normalized characters) containing match gets the
#     new BODY/PROVENANCE as a comment instead of a second filing, and the
#     matched issue's own number/url are returned. No dedup hit creates a
#     fresh issue labelled `pw::type:tech-debt`.
#   - **... or dedups by "same PR"** (agent-ops#2576): when PROVENANCE
#     embeds a pull-request URL (as every Approver/Reviewer-filed finding's
#     own PROVENANCE does), a candidate whose body already contains that
#     same URL counts as a duplicate even when its title reads nothing
#     alike — the #2573/#2574 scenario, two findings worded differently
#     against the same PR. A provenance naming no PR at all (the Enabler's
#     own wording) never matches by this path, and neither does a PR number
#     that is merely a digit prefix of one the body names (`#25` against a
#     body naming only `#2567`).
#   - **PROVENANCE naming a pull request earns the filed/commented body a
#     `Blocked-by: <owner/repo>#<n>` line** naming that same pull request
#     (agent-ops#2721), so requirement 34j's existing live check holds the
#     record out of the band while it stays open. A provenance naming no PR
#     (the Enabler's own wording) adds no such line.
#   - **A TOKEN, given, is used for every gh call** (issue list, comment,
#     create) — never the ordinary login.
#   - **A labelled create that fails is retried once unlabelled** (a
#     repository whose `pw::type:tech-debt` label the ensure pass has not
#     reached yet), exactly as techdebt_file_issue's own
#     `pw::owner-decision` retry already does.
#   - **DEFAULT_FIX/OWNER_DECISION (agent-ops#938)** land in the filed body
#     (or the dedup comment) via techdebt_default_section, identically to
#     techdebt_file_issue.
#   - **The dedup search states its own page cap** (`--limit
#     TECHDEBT_DEDUP_LIST_LIMIT`) rather than inheriting `gh issue list`'s
#     undeclared default of 30, which would dedup against only the newest
#     page of a repository's open debt and file duplicates against the rest.
#   - **No id reservation, no branch, no pull request** — filing (or the
#     dedup comment) is the only GitHub write techdebt_file_debt makes;
#     there is nothing left to half-finish, so a failed create simply
#     returns 1 with no cleanup step to assert.
#   - **techdebt_file_issue returns an existing issue that already covers
#     ITEM_REF** rather than filing a duplicate, and creates one when none
#     exists; a failed create returns 1 and prints nothing. (Unchanged by
#     agent-ops#874 — kept here as a regression guard since both functions
#     share this file.)
#   - **_techdebt_gh refuses a tokenless call under GITHUB_ACTIONS=true**
#     (agent-ops#2722): a GitHub Actions caller has no stored `gh auth
#     login` identity to fall back to, so stripping its only credential
#     (GH_TOKEN) and running anyway would just fail unauthenticated with no
#     clue why. Caught before `gh` is ever invoked. Unset or not "true",
#     the tokenless path is unchanged; a non-empty TOKEN is unaffected
#     either way.
#
# `gh` is stubbed through a fake executable on PATH, recording every
# invocation to a file for assertions — the technique
# test/merge-queue.test.sh's stub uses for its own `gh api` calls.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/tech-debt-file.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/tech-debt-file.sh
. "$SCRIPT_DIR/lib/tech-debt-file.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
cycle_dir="$tmp_dir/cycle"
mkdir -p "$cycle_dir"

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

# --- The stub gh -------------------------------------------------------------
# $tmp_dir/calls               every invocation's argv, one per line
# $tmp_dir/issue-url            printed by `issue create` (empty -> fails)
# $tmp_dir/issue-list-response  printed by `issue list --json ...`
# $tmp_dir/last-issue-body      the last `issue create`/`issue comment`
#                                --body-file's own content, captured before
#                                the caller deletes the temp file
# $tmp_dir/fail-labelled-issue-create
#                               present -> an `issue create` carrying --label
#                                fails, as `gh` does where the label does not
#                                exist in the repository; an unlabelled create
#                                still succeeds
# $tmp_dir/fail-comment         present -> `issue comment` fails
cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
printf '%s %s\n' "${GH_TOKEN:-<none>}" "$*" >> "$d/calls"

if [[ "$1" == "issue" && "$2" == "create" ]]; then
  shift 2
  labelled=0
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--body-file" ]]; then
      cat "$2" > "$d/last-issue-body" 2>/dev/null
      shift 2
      continue
    fi
    [[ "$1" == "--label" ]] && labelled=1
    shift
  done
  # `gh` resolves a label name to an id as part of the create, so a repository
  # that does not carry the label fails the whole create rather than merely
  # dropping the label: this fixture reproduces exactly that, and only for a
  # create that actually asked for one.
  [[ -f "$d/fail-labelled-issue-create" && "$labelled" == "1" ]] && exit 1
  [[ -s "$d/issue-url" ]] || exit 1
  cat "$d/issue-url"
  exit 0
fi
if [[ "$1" == "issue" && "$2" == "list" ]]; then
  cat "$d/issue-list-response" 2>/dev/null || echo '[]'
  exit 0
fi
if [[ "$1" == "issue" && "$2" == "comment" ]]; then
  shift 2
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--body-file" ]]; then
      cat "$2" > "$d/last-issue-body" 2>/dev/null
      shift 2
      continue
    fi
    shift
  done
  [[ -f "$d/fail-comment" ]] && exit 1
  exit 0
fi
exit 1
STUB
chmod +x "$tmp_dir/gh"
export PATH="$tmp_dir:$PATH"

reset_stub() {
  : > "$tmp_dir/calls"
  rm -f "$tmp_dir/fail-labelled-issue-create" "$tmp_dir/fail-comment" "$tmp_dir/last-issue-body"
  echo "https://github.com/o/r/issues/77" > "$tmp_dir/issue-url"
  echo '[]' > "$tmp_dir/issue-list-response"
}

last_issue_body() {
  cat "$tmp_dir/last-issue-body" 2>/dev/null || true
}

# ============================================================================
# _techdebt_gh
# ============================================================================

# --- Tokenless under GITHUB_ACTIONS=true -> refuses, never calls gh --------
reset_stub
out="$(GITHUB_ACTIONS=true _techdebt_gh "" issue list -R o/r 2>"$tmp_dir/stderr")"
rc=$?
assert_eq "_techdebt_gh: tokenless under GITHUB_ACTIONS=true -> exit 1" "1" "$rc"
assert_eq "  ... no output" "" "$out"
assert_eq "  ... gh is never invoked" "0" "$(wc -l < "$tmp_dir/calls")"
assert_eq "  ... stderr names the missing-TOKEN-under-Actions condition" "1" \
  "$(grep -c 'GITHUB_ACTIONS=true' "$tmp_dir/stderr")"

# --- Tokenless with GITHUB_ACTIONS unset -> unchanged, still calls gh ------
reset_stub
out="$(_techdebt_gh "" issue list -R o/r)"
rc=$?
assert_eq "_techdebt_gh: tokenless, GITHUB_ACTIONS unset -> exit 0" "0" "$rc"
assert_eq "  ... gh was invoked" "1" "$(grep -c '^<none> issue list -R o/r$' "$tmp_dir/calls")"

# --- Tokenless with GITHUB_ACTIONS set to something other than "true" ------
reset_stub
out="$(GITHUB_ACTIONS=false _techdebt_gh "" issue list -R o/r)"
rc=$?
assert_eq "_techdebt_gh: tokenless, GITHUB_ACTIONS=false -> exit 0" "0" "$rc"
assert_eq "  ... gh was invoked" "1" "$(grep -c '^<none> issue list -R o/r$' "$tmp_dir/calls")"

# --- A non-empty TOKEN is unaffected by GITHUB_ACTIONS ----------------------
reset_stub
out="$(GITHUB_ACTIONS=true _techdebt_gh "app-token-123" issue list -R o/r)"
rc=$?
assert_eq "_techdebt_gh: token given under GITHUB_ACTIONS=true -> exit 0" "0" "$rc"
assert_eq "  ... gh was invoked under that token" "1" \
  "$(grep -c '^app-token-123 issue list -R o/r$' "$tmp_dir/calls")"

# ============================================================================
# techdebt_file_debt
# ============================================================================

# --- No dedup hit -> creates a labelled issue --------------------------------
reset_stub
out="$(techdebt_file_debt "o/r" "A finding worth filing" "The body." "while reviewing PR #618" "")"
rc=$?
assert_eq "file_debt: no dedup hit, exit 0" "0" "$rc"
assert_eq "  ... number/url returned" "77	https://github.com/o/r/issues/77" "$out"
assert_eq "  ... exactly one issue list (the dedup search)" "1" \
  "$(grep -c '^<none> issue list -R o/r --label pw::type:tech-debt --state open' "$tmp_dir/calls")"
# The page cap is stated, never inherited: `gh issue list`'s own undeclared
# default is 30, and a repository carrying more open debt than that would
# dedup against only its newest page — filing duplicates against the oldest
# records, silently, which is the one failure a passing suite could otherwise
# hide entirely.
assert_eq "  ... and it states its own --limit rather than inheriting gh's 30" "1" \
  "$(grep -c -- "--state open --limit $TECHDEBT_DEDUP_LIST_LIMIT --json number,url,title,body" "$tmp_dir/calls")"
assert_eq "  ... exactly one issue create, labelled" "1" \
  "$(grep -c -- '^<none> issue create -R o/r --title A finding worth filing .*--label pw::type:tech-debt$' "$tmp_dir/calls")"
assert_eq "  ... no issue comment attempted" "0" "$(grep -c 'issue comment' "$tmp_dir/calls")"
assert_eq "  ... the filed body carries BODY" "1" "$(last_issue_body | grep -c '^The body\.$')"
assert_eq "  ... and the provenance line" "1" "$(last_issue_body | grep -c '^while reviewing PR #618$')"
# No DEFAULT_FIX/OWNER_DECISION -> the body still carries a `## Default`
# heading, filed as "not stated" rather than left out (agent-ops#938: a
# malformed verdict is filed anyway, never lost).
assert_eq "  ... no DEFAULT_FIX/OWNER_DECISION -> '## Default: not stated'" "1" \
  "$(last_issue_body | grep -c '^## Default: not stated$')"
assert_eq "  ... and no 'Owner decision:' line" "0" "$(last_issue_body | grep -c '^Owner decision:')"

# --- DEFAULT_FIX/OWNER_DECISION (agent-ops#938) -----------------------------
reset_stub
techdebt_file_debt "o/r" "A finding with a default" "The body." "while reviewing PR #618" "" \
  "Do the smaller of the two fixes because it needs no schema change" >/dev/null
assert_eq "file_debt: DEFAULT_FIX alone -> heading carries it, no owner line" "1" \
  "$(last_issue_body | grep -c '^## Default: Do the smaller of the two fixes because it needs no schema change$')"
assert_eq "  ... no 'Owner decision:' line" "0" "$(last_issue_body | grep -c '^Owner decision:')"

reset_stub
techdebt_file_debt "o/r" "A finding that is an owner call" "The body." "while reviewing PR #618" \
  "" "Pick the vendor-locked option" "true" >/dev/null
assert_eq "file_debt: OWNER_DECISION true -> heading and 'Owner decision: yes' both present" "1" \
  "$(last_issue_body | grep -c '^## Default: Pick the vendor-locked option$')"
assert_eq "  ... 'Owner decision: yes' beside it" "1" "$(last_issue_body | grep -c '^Owner decision: yes$')"

reset_stub
techdebt_file_debt "o/r" "An owner call with no stated default" "The body." "while reviewing PR #618" \
  "" "" "true" >/dev/null
assert_eq "file_debt: OWNER_DECISION true alone -> still '## Default: not stated'" "1" \
  "$(last_issue_body | grep -c '^## Default: not stated$')"
assert_eq "  ... but 'Owner decision: yes' still present (verdict is not malformed)" "1" \
  "$(last_issue_body | grep -c '^Owner decision: yes$')"

# --- A token is used for every gh call --------------------------------------
reset_stub
techdebt_file_debt "o/r" "Another finding" "Body." "while approving PR #7" "app-token-123" >/dev/null
assert_eq "file_debt with token: every call carries it" "0" \
  "$(grep -vc '^app-token-123 ' "$tmp_dir/calls")"

# --- Exact-title dedup hit -> comments on the existing issue, no create -----
reset_stub
jq -nc '[{number: 42, url: "https://github.com/o/r/issues/42", title: "A finding worth filing"}]' \
  > "$tmp_dir/issue-list-response"
out="$(techdebt_file_debt "o/r" "A finding worth filing" "New evidence." "while reviewing PR #900" "")"
rc=$?
assert_eq "file_debt: exact-title dedup hit, exit 0" "0" "$rc"
assert_eq "  ... existing number/url returned" "42	https://github.com/o/r/issues/42" "$out"
assert_eq "  ... no issue create attempted" "0" "$(grep -c 'issue create' "$tmp_dir/calls")"
assert_eq "  ... exactly one issue comment, on #42" "1" \
  "$(grep -c '^<none> issue comment 42 -R o/r' "$tmp_dir/calls")"
assert_eq "  ... the comment carries the new evidence" "1" "$(last_issue_body | grep -c '^New evidence\.$')"
assert_eq "  ... and the new provenance line" "1" "$(last_issue_body | grep -c '^while reviewing PR #900$')"

# --- Case/punctuation-insensitive title match still dedups ------------------
reset_stub
jq -nc '[{number: 43, url: "https://github.com/o/r/issues/43", title: "A Finding: Worth Filing!!"}]' \
  > "$tmp_dir/issue-list-response"
out="$(techdebt_file_debt "o/r" "a finding worth filing" "New evidence." "prov" "")"
assert_eq "file_debt: normalised-title dedup hit (case/punctuation differ)" \
  "43	https://github.com/o/r/issues/43" "$out"

# --- Containment dedup, both titles >= 8 normalized characters -------------
reset_stub
jq -nc '[{number: 44, url: "https://github.com/o/r/issues/44", title: "lib/foo.sh leaks a file descriptor on the error path"}]' \
  > "$tmp_dir/issue-list-response"
out="$(techdebt_file_debt "o/r" "lib/foo.sh leaks a file descriptor" "New evidence." "prov" "")"
assert_eq "file_debt: containment dedup hit (needle contained in existing title)" \
  "44	https://github.com/o/r/issues/44" "$out"

# --- Short titles never match by containment, only by exact equality -------
reset_stub
jq -nc '[{number: 45, url: "https://github.com/o/r/issues/45", title: "fix bug in the enormous legacy subsystem module"}]' \
  > "$tmp_dir/issue-list-response"
out="$(techdebt_file_debt "o/r" "fix bug" "New evidence." "prov" "")"
rc=$?
assert_eq "file_debt: a short needle does not match by containment, exit 0" "0" "$rc"
assert_eq "  ... a fresh issue is filed instead (not the long unrelated one)" \
  "77	https://github.com/o/r/issues/77" "$out"
assert_eq "  ... no comment attempted" "0" "$(grep -c 'issue comment' "$tmp_dir/calls")"

# --- Same-PR dedup: unrelated titles, same PR named in provenance (#2573/ --
# #2574's own scenario) ------------------------------------------------------
reset_stub
jq -nc '[{number: 47, url: "https://github.com/o/r/issues/47", title: "Unbounded credential re-probe risks a closed-gate regression",
          body: "Default: reject a re-probe cap/backoff.\n\nwhile the Approver was judging https://github.com/o/r/pull/2567"}]' \
  > "$tmp_dir/issue-list-response"
out="$(techdebt_file_debt "o/r" "Approver filed conflicting defaults for the same standdown finding" \
        "New evidence." "while the Approver was judging https://github.com/o/r/pull/2567" "")"
rc=$?
assert_eq "file_debt: same-PR dedup hit, exit 0" "0" "$rc"
assert_eq "  ... existing number/url returned despite the unrelated title" \
  "47	https://github.com/o/r/issues/47" "$out"
assert_eq "  ... no issue create attempted" "0" "$(grep -c 'issue create' "$tmp_dir/calls")"
assert_eq "  ... exactly one issue comment, on #47" "1" \
  "$(grep -c '^<none> issue comment 47 -R o/r' "$tmp_dir/calls")"
assert_eq "  ... the comment carries the new evidence" "1" "$(last_issue_body | grep -c '^New evidence\.$')"

# --- Same-PR dedup does not fire for a provenance naming no PR (the --------
# Enabler's own wording) -----------------------------------------------------
reset_stub
jq -nc '[{number: 48, url: "https://github.com/o/r/issues/48", title: "Some unrelated finding",
          body: "while the Approver was judging https://github.com/o/r/pull/2567"}]' \
  > "$tmp_dir/issue-list-response"
out="$(techdebt_file_debt "o/r" "A finding from the Enabler" "New evidence." \
        "during an Enabler engagement on 2576 (cycle c1)" "")"
rc=$?
assert_eq "file_debt: no PR in provenance -> same-PR check never fires, exit 0" "0" "$rc"
assert_eq "  ... a fresh issue is filed instead" "77	https://github.com/o/r/issues/77" "$out"
assert_eq "  ... no comment attempted" "0" "$(grep -c 'issue comment' "$tmp_dir/calls")"

# --- Same-PR dedup never fires on a PR number that is merely a digit -------
# prefix of one the body names -----------------------------------------------
# `.../pull/25` is a plain substring of `.../pull/2567`, so an unguarded
# substring test deduped a filing raised against #25 into an issue naming
# only #2567 — silently, as a comment on an unrelated issue. Both directions
# are asserted together: the prefix must miss, and the PR the body actually
# names must still hit.
reset_stub
jq -nc '[{number: 50, url: "https://github.com/o/r/issues/50", title: "Some unrelated finding",
          body: "while the Approver was judging https://github.com/o/r/pull/2567"}]' \
  > "$tmp_dir/issue-list-response"
out="$(techdebt_file_debt "o/r" "A finding against a different PR" "New evidence." \
        "while the Approver was judging https://github.com/o/r/pull/25" "")"
assert_eq "file_debt: a PR number that is only a digit prefix is not a same-PR hit" \
  "77	https://github.com/o/r/issues/77" "$out"
assert_eq "  ... no comment attempted" "0" "$(grep -c 'issue comment' "$tmp_dir/calls")"

reset_stub
jq -nc '[{number: 51, url: "https://github.com/o/r/issues/51", title: "Some unrelated finding",
          body: "while the Approver was judging https://github.com/o/r/pull/2567/files"}]' \
  > "$tmp_dir/issue-list-response"
out="$(techdebt_file_debt "o/r" "A finding worded differently" "New evidence." \
        "while the Approver was judging https://github.com/o/r/pull/2567" "")"
assert_eq "  ... but the PR the body names still hits, trailing path and all" \
  "51	https://github.com/o/r/issues/51" "$out"

# --- A title match is still found even when it would precede a same-PR -----
# check (title match wins first, same result either way) --------------------
reset_stub
jq -nc '[{number: 49, url: "https://github.com/o/r/issues/49", title: "A finding worth filing",
          body: "while reviewing https://github.com/o/r/pull/1"}]' \
  > "$tmp_dir/issue-list-response"
out="$(techdebt_file_debt "o/r" "A finding worth filing" "New evidence." \
        "while the Approver was judging https://github.com/o/r/pull/999" "")"
assert_eq "file_debt: title match still hits even when the PR differs" \
  "49	https://github.com/o/r/issues/49" "$out"

# --- PROVENANCE naming a pull request -> the filed body also carries a ----
# `Blocked-by:` line naming that same pull request (agent-ops#2721), so the
# record is held out of the tech-debt band by requirement 34j's existing live
# check for as long as that pull request stays open.
reset_stub
out="$(techdebt_file_debt "o/r" "A finding against an open PR" "The body." \
        "while the Approver was judging https://github.com/o/r/pull/2652" "")"
rc=$?
assert_eq "file_debt: PR named in provenance, exit 0" "0" "$rc"
assert_eq "  ... fresh issue filed" "77	https://github.com/o/r/issues/77" "$out"
assert_eq "  ... the filed body carries a Blocked-by: line naming that PR" "1" \
  "$(last_issue_body | grep -c '^Blocked-by: o/r#2652$')"

# --- ... and the same line lands in the dedup comment, not just a fresh ----
# filing -----------------------------------------------------------------
reset_stub
jq -nc '[{number: 52, url: "https://github.com/o/r/issues/52", title: "A finding worth filing"}]' \
  > "$tmp_dir/issue-list-response"
techdebt_file_debt "o/r" "A finding worth filing" "New evidence." \
  "while the Approver was judging https://github.com/o/r/pull/2652" "" >/dev/null
assert_eq "file_debt: dedup comment also carries the Blocked-by: line" "1" \
  "$(last_issue_body | grep -c '^Blocked-by: o/r#2652$')"

# --- PROVENANCE naming no pull request (the Enabler's own wording) -> no ---
# Blocked-by: line at all -- the scope note's no-op stays a no-op -----------
reset_stub
techdebt_file_debt "o/r" "A finding from the Enabler" "The body." \
  "during an Enabler engagement on 2721 (cycle c1)" "" >/dev/null
assert_eq "file_debt: no PR in provenance -> no Blocked-by: line" "0" \
  "$(last_issue_body | grep -c '^Blocked-by:')"

# --- A dedup hit still carries DEFAULT_FIX/OWNER_DECISION into the comment --
reset_stub
jq -nc '[{number: 46, url: "https://github.com/o/r/issues/46", title: "A repeatedly noticed gap"}]' \
  > "$tmp_dir/issue-list-response"
techdebt_file_debt "o/r" "A repeatedly noticed gap" "More evidence." "prov" "" \
  "Pick the vendor-locked option" "true" >/dev/null
assert_eq "file_debt: dedup comment carries the '## Default' heading" "1" \
  "$(last_issue_body | grep -c '^## Default: Pick the vendor-locked option$')"
assert_eq "  ... and 'Owner decision: yes'" "1" "$(last_issue_body | grep -c '^Owner decision: yes$')"

# --- issue list fails (not an array) -> dedup skipped, files fresh ----------
reset_stub
printf 'not json' > "$tmp_dir/issue-list-response"
out="$(techdebt_file_debt "o/r" "A finding" "Body." "prov" "")"
rc=$?
assert_eq "file_debt: dedup search unusable -> still files, exit 0" "0" "$rc"
assert_eq "  ... number/url returned" "77	https://github.com/o/r/issues/77" "$out"

# --- A repository with no pw::type:tech-debt label yet: labelled create ----
# fails, retried unlabelled, exactly as techdebt_file_issue's own
# pw::owner-decision retry (agent-ops#938/#1009).
reset_stub
: > "$tmp_dir/fail-labelled-issue-create"
out="$(techdebt_file_debt "o/r" "A finding" "Body." "prov" "")"
rc=$?
assert_eq "file_debt: a refused labelled create is retried unlabelled, exit 0" "0" "$rc"
assert_eq "  ... and the issue is still filed" "77	https://github.com/o/r/issues/77" "$out"
assert_eq "  ... the labelled create was attempted first" "1" \
  "$(grep -c -- '^<none> issue create .*--label pw::type:tech-debt' "$tmp_dir/calls")"
assert_eq "  ... and the retry carried no label" "1" \
  "$(grep -cE '^<none> issue create -R o/r --title A finding --body-file [^ ]+$' "$tmp_dir/calls")"

# --- An unlabelled create that fails is not retried -> returns 1 -----------
reset_stub
: > "$tmp_dir/issue-url"
out="$(techdebt_file_debt "o/r" "A finding" "Body." "prov" "")"
rc=$?
assert_eq "file_debt: create fails outright -> exit 1" "1" "$rc"
assert_eq "  ... no output" "" "$out"

# --- No id reservation, no branch, no pull request are ever created --------
reset_stub
techdebt_file_debt "o/r" "A finding" "Body." "prov" "" >/dev/null
assert_eq "file_debt: never touches git/refs" "0" "$(grep -c 'git/refs' "$tmp_dir/calls")"
assert_eq "  ... never calls pr create" "0" "$(grep -c 'pr create' "$tmp_dir/calls")"

# ============================================================================
# techdebt_file_issue
# ============================================================================

# --- No existing issue -> creates one ---------------------------------------
reset_stub
out="$(techdebt_file_issue "o/r" "TD26082201" "A gap worth noting" \
        <(echo "body") "")"
rc=$?
assert_eq "file_issue: created, exit 0" "0" "$rc"
assert_eq "  ... number/url" "77	https://github.com/o/r/issues/77" "$out"

# --- Existing issue already covers the item ref -> returned, no create -----
reset_stub
jq -nc --arg item "TD26082201" \
  '[{number: 42, url: "https://github.com/o/r/issues/42", body: ("covers " + $item)}]' \
  > "$tmp_dir/issue-list-response"
out="$(techdebt_file_issue "o/r" "TD26082201" "A gap worth noting" <(echo "body") "")"
rc=$?
assert_eq "file_issue: dedup hit, exit 0" "0" "$rc"
assert_eq "  ... existing number/url returned" "42	https://github.com/o/r/issues/42" "$out"
assert_eq "  ... no create attempted" "0" "$(grep -c 'issue create' "$tmp_dir/calls")"

# --- Create fails -> returns 1 ----------------------------------------------
reset_stub
: > "$tmp_dir/issue-url"
out="$(techdebt_file_issue "o/r" "TD26082201" "A gap worth noting" <(echo "body") "")"
rc=$?
assert_eq "file_issue: create fails -> exit 1" "1" "$rc"
assert_eq "  ... no output" "" "$out"

# --- DEFAULT_FIX/OWNER_DECISION (agent-ops#938) -----------------------------
# No DEFAULT_FIX/OWNER_DECISION -> filed anyway with "## Default: not stated",
# no pw::owner-decision label.
reset_stub
techdebt_file_issue "o/r" "TD26082201" "A gap worth noting" <(echo "body") "" >/dev/null
assert_eq "file_issue: neither field -> '## Default: not stated'" "1" \
  "$(grep -c '^## Default: not stated$' "$tmp_dir/last-issue-body")"
assert_eq "  ... no pw::owner-decision label requested" "0" \
  "$(grep -c -- '--label pw::owner-decision' "$tmp_dir/calls")"

# DEFAULT_FIX alone -> heading carries it, no label.
reset_stub
techdebt_file_issue "o/r" "TD26082201" "A gap worth noting" <(echo "body") "" \
  "Rename the flag rather than add a second one" >/dev/null
assert_eq "file_issue: DEFAULT_FIX alone -> heading carries it" "1" \
  "$(grep -c '^## Default: Rename the flag rather than add a second one$' "$tmp_dir/last-issue-body")"
assert_eq "  ... no pw::owner-decision label requested" "0" \
  "$(grep -c -- '--label pw::owner-decision' "$tmp_dir/calls")"

# OWNER_DECISION true -> the pw::owner-decision label is requested, alongside
# the heading; a record would write "Owner decision: yes" instead, but an
# issue is marked with a label, not body text, so a gatherer can trust it.
reset_stub
techdebt_file_issue "o/r" "TD26082201" "A gap worth noting" <(echo "body") "" \
  "Pick the vendor-locked option" "true" >/dev/null
assert_eq "file_issue: OWNER_DECISION true -> heading present" "1" \
  "$(grep -c '^## Default: Pick the vendor-locked option$' "$tmp_dir/last-issue-body")"
assert_eq "  ... no 'Owner decision:' body line (a label carries it here)" "0" \
  "$(grep -c '^Owner decision:' "$tmp_dir/last-issue-body")"
assert_eq "  ... pw::owner-decision label requested" "1" \
  "$(grep -c -- '--label pw::owner-decision' "$tmp_dir/calls")"

# A repository that has not had `pw::owner-decision` ensured yet fails the
# labelled create outright -- `gh` resolves the label to an id as part of the
# create -- so the create is retried once without it, exactly as requirement
# 36a's escalation contract does. Losing the label costs the Refiner its
# marker; losing the create would cost the filing itself, which is the one
# outcome agent-ops#938 exists to prevent.
reset_stub
: > "$tmp_dir/fail-labelled-issue-create"
out="$(techdebt_file_issue "o/r" "TD26082201" "A gap worth noting" <(echo "body") "" \
        "Pick the vendor-locked option" "true")"
rc=$?
assert_eq "file_issue: a refused labelled create is retried unlabelled, exit 0" "0" "$rc"
assert_eq "  ... and the issue is still filed" "77	https://github.com/o/r/issues/77" "$out"
assert_eq "  ... the labelled create was attempted first" "1" \
  "$(grep -c -- '--label pw::owner-decision' "$tmp_dir/calls")"
assert_eq "  ... and the retry carried no label" "1" \
  "$(grep -cE '^<none> issue create -R o/r --title A gap worth noting --body-file [^ ]+$' \
       "$tmp_dir/calls")"

# The retry is only for a labelled create: an unlabelled one that fails is
# still a failed filing, never re-attempted.
reset_stub
: > "$tmp_dir/issue-url"
out="$(techdebt_file_issue "o/r" "TD26082201" "A gap worth noting" <(echo "body") "" \
        "Rename the flag rather than add a second one")"
rc=$?
assert_eq "file_issue: an unlabelled create that fails is not retried" "1" "$rc"
assert_eq "  ... exactly one create attempted" "1" "$(grep -c 'issue create' "$tmp_dir/calls")"

echo
if [[ "$failures" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$failures test(s) failed."
  exit 1
fi
