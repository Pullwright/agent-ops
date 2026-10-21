#!/usr/bin/env bash
#
# test/gather-tech-debt.test.sh — regression test for
# scripts/gather-tech-debt.sh (requirement 3t, issue #310; store moved to
# labelled issues by D15 as revised, #869/#875): the source that hands the
# Co-Ordinator every open `pw::type:tech-debt`-labelled issue pre-fetched,
# whole thread included.
#
# Behaviours asserted, each of which fails silently if broken:
#
#   - **Only issues carrying `pw::type:tech-debt` are candidates.** The
#     labels-scoped listing call is trusted to have done that filtering; this
#     test asserts the gatherer does not additionally require anything else.
#   - **The deterministic filter, shared with scripts/gather-issues.sh via
#     lib/issue-prefetch.sh, still applies**: an assigned issue, an issue
#     labelled `blocked`, an issue labelled `pw::pager` (agent-ops#2564), and
#     an issue naming a still-open `Blocked-by:` reference (requirement 34j)
#     are all dropped.
#   - **The exclusion report** (agent-ops#2603, mirroring scripts/
#     gather-issues.sh's own since agent-ops#447): every issue the
#     deterministic filter drops reappears in the sibling `excluded` array
#     with its number and why, `reason` one of `"assigned"`,
#     `"blocked-label"`, `"pager"`, `"blocked-by: <ref>"` — this is the record
#     `lib/eligibility.sh`'s own open-`Blocked-by:`-reference Enabler filter
#     (requirement 35f) reads, so a drop that left no trace here would make
#     that filter unable to fire on its own target class again. An issue
#     dropped under `issue_exclude_reason`'s own single-reason precedence
#     whose own thread *also* names a still-open `Blocked-by:` reference
#     contributes a second entry under the same number, one `reason` each
#     (issue #2607) — that second ground is independently checked, not a
#     fourth arm of the same precedence, so the one already reported must
#     never hide it.
#   - **Each candidate carries the whole issue thread verbatim** — `body` and
#     every comment — plus `source`, `ref` (the bare issue number, as a
#     string), `number`, `url`, `title`, `labels`, `author`, `created_at` and
#     `updated_at`.
#   - **Sorted by issue number ascending** — "the oldest item is kept first"
#     (lib/coordinator-input.sh's own `keep_order_tech_debt`).
#   - **Degrades to `{"candidates":[],"excluded":null}` (exit 0) on any
#     failure**, silently for none of the old register-specific cases (there
#     is no register left to read) but always loudly on stderr for a genuine
#     API failure — the identical contract scripts/gather-issues.sh's own
#     degrade() follows.
#
# The gatherer is run for real against a stubbed `gh`, so the assertions are
# about the shipped script rather than a copy of its logic. Since
# agent-ops#1085 the listing-plus-comments read is one GraphQL call
# (`issue_prefetch_open_issues`, lib/issue-prefetch.sh); the stub answers it
# with a fixture in that function's own node shape, applying the caller's own
# `--jq` filter for real, the same technique test/issue-prefetch.test.sh's own
# stub uses. The `Blocked-by:` live-check (`issue_blocked_by_ref`) is
# unaffected by that migration — it stays a REST read of one referenced
# issue's state — so the stub still answers that separately.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/gather-tech-debt.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATHER="$SCRIPT_DIR/scripts/gather-tech-debt.sh"

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

# --- A stub `gh`: `api graphql` (the listing-plus-comments walk) applies the
#     caller's own `--jq` filter to $STUB_ISSUES, a single-page GraphQL
#     response fixture; `api repos/…/issues/<n>` (the Blocked-by live-check,
#     unaffected by agent-ops#1085) answers from $STUB_REFS_DIR. ---
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == "api" ]] || { echo "stub gh: unexpected command: $*" >&2; exit 1; }
if [[ "$2" == "graphql" ]]; then
  shift 2
  filter='.'
  while [[ $# -gt 0 ]]; do
    case "$1" in --jq) filter="$2"; shift 2;; *) shift;; esac
  done
  jq -c "$filter" "$STUB_ISSUES"
  exit 0
fi
path="$2"
case "$path" in
  repos/*/issues/*)
    n="${path##*/issues/}"
    if [[ -f "$STUB_REFS_DIR/$n.json" ]]; then
      body="$(cat "$STUB_REFS_DIR/$n.json")"
    else
      body='{"state":"open"}'
    fi
    ;;
  *) echo "stub gh: unexpected path: $path" >&2; exit 1;;
esac
filter='.'
shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in --jq) filter="$2"; shift 2;; *) shift;; esac
done
jq -rc "$filter" <<<"$body"
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

# --- The fixture: one issue per way an entry can qualify or be dropped ---
#
# #20 is clean, labelled `pw::type:tech-debt` plus an extra label, with a
# two-comment thread; #21 is assigned; #22 is labelled `Blocked` (upper case,
# proving the drop case-insensitive); #23 names an unresolved `Blocked-by:
# #24` (still open); #19 is clean and commentless, unbanded, qualifying solely
# on the `pw::type:tech-debt` label; #18 is open but carries no
# `pw::type:tech-debt` label at all, proving the label filter (now this
# script's own `select`, since
# `issue_prefetch_open_issues` returns every open issue — agent-ops#1085)
# still excludes it; #25 is a clean tech-debt candidate triaged Low that #26,
# a plain (non-tech-debt) issue banded High, names as its own `Blocked-by:`
# dependency, proving priority inheritance (agent-ops#2422); #27 carries both
# `pw::type:tech-debt` and `pw::pager`, unassigned and not `Blocked`-labelled,
# proving the pager drop fires here too (agent-ops#2564); #28 is assigned
# (the same single-reason drop #21 gets) and *also* names a still-open
# `Blocked-by: #29` in its own body, proving issue #2607's fix: a
# deterministically-dropped issue's own thread is checked for a co-occurring
# Blocked-by reference too, reported as a second `excluded` entry rather than
# the one reason hiding the other. One page (`hasNextPage: false`) is enough
# for this fixture's ten issues.
export STUB_ISSUES="$tmp_dir/issues.json"
export STUB_REFS_DIR="$tmp_dir/refs"
mkdir -p "$STUB_REFS_DIR"
cat >"$STUB_ISSUES" <<'EOF'
{"data": {"repository": {"issues": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [
  {"number": 20, "url": "https://github.com/o/r/issues/20", "title": "Untangle the frobnicator",
   "author": {"login": "warwick"},
   "labels": {"nodes": [{"name": "pw::type:tech-debt"}, {"name": "backend"}]},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "The body of twenty.",
   "comments": {"nodes": [
     {"author": {"login": "warwick"}, "createdAt": "2026-07-19T10:00:00Z", "body": "Acceptance: it untangles."},
     {"author": {"login": "reviewer"}, "createdAt": "2026-07-20T09:00:00Z", "body": "Scope cut: skip the UI."}
   ]}},
  {"number": 21, "url": "https://github.com/o/r/issues/21", "title": "Assigned debt",
   "author": {"login": "warwick"},
   "labels": {"nodes": [{"name": "pw::type:tech-debt"}]},
   "assignees": {"totalCount": 1},
   "issueFieldValues": {"nodes": []},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Assigned, so not a candidate.", "comments": {"nodes": []}},
  {"number": 22, "url": "https://github.com/o/r/issues/22", "title": "Blocked debt",
   "author": {"login": "warwick"},
   "labels": {"nodes": [{"name": "pw::type:tech-debt"}, {"name": "Blocked"}]},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Labelled Blocked, so not a candidate.", "comments": {"nodes": []}},
  {"number": 23, "url": "https://github.com/o/r/issues/23", "title": "Debt with an open dependency",
   "author": {"login": "warwick"},
   "labels": {"nodes": [{"name": "pw::type:tech-debt"}]},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Blocked-by: #24", "comments": {"nodes": []}},
  {"number": 19, "url": "https://github.com/o/r/issues/19", "title": "The oldest debt",
   "author": {"login": "warwick"},
   "labels": {"nodes": [{"name": "pw::type:tech-debt"}]},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "createdAt": "2026-07-18T08:00:00Z", "updatedAt": "2026-07-18T08:00:00Z",
   "body": "No comments, no labels but the one that matters.", "comments": {"nodes": []}},
  {"number": 18, "url": "https://github.com/o/r/issues/18", "title": "Not tech debt at all",
   "author": {"login": "warwick"},
   "labels": {"nodes": [{"name": "backend"}]},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "createdAt": "2026-07-17T08:00:00Z", "updatedAt": "2026-07-17T08:00:00Z",
   "body": "An ordinary issue.", "comments": {"nodes": []}},
  {"number": 25, "url": "https://github.com/o/r/issues/25", "title": "The blocker, banded Low",
   "author": {"login": "warwick"},
   "labels": {"nodes": [{"name": "pw::type:tech-debt"}]},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": [
     {"__typename": "IssueFieldSingleSelectValue", "name": "Low",
      "field": {"__typename": "IssueFieldSingleSelect", "name": "Priority"}}]},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Nothing blocks this one.", "comments": {"nodes": []}},
  {"number": 26, "url": "https://github.com/o/r/issues/26", "title": "An ordinary issue, banded High, blocked on the debt item",
   "author": {"login": "warwick"},
   "labels": {"nodes": []},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": [
     {"__typename": "IssueFieldSingleSelectValue", "name": "High",
      "field": {"__typename": "IssueFieldSingleSelect", "name": "Priority"}}]},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Needs #25 first.\n\nBlocked-by: #25", "comments": {"nodes": []}},
  {"number": 27, "url": "https://github.com/o/r/issues/27", "title": "Pager-tagged debt",
   "author": {"login": "warwick"},
   "labels": {"nodes": [{"name": "pw::type:tech-debt"}, {"name": "pw::pager"}]},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Labelled pw::pager, so not a candidate (agent-ops#2564).", "comments": {"nodes": []}},
  {"number": 28, "url": "https://github.com/o/r/issues/28", "title": "Assigned debt, and also Blocked-by",
   "author": {"login": "warwick"},
   "labels": {"nodes": [{"name": "pw::type:tech-debt"}]},
   "assignees": {"totalCount": 1},
   "issueFieldValues": {"nodes": []},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Assigned, so dropped for that reason alone under issue_exclude_reason's own precedence.\n\nBlocked-by: #29",
   "comments": {"nodes": []}}
]}}}}
EOF
cat >"$STUB_REFS_DIR/24.json" <<'EOF'
{"state": "open"}
EOF
cat >"$STUB_REFS_DIR/29.json" <<'EOF'
{"state": "open"}
EOF

raw="$("$GATHER" o/r 2>"$tmp_dir/err")"; rc=$?
out="$(jq -c '.candidates' <<<"$raw")"
excl="$(jq -c '.excluded' <<<"$raw")"

# --- The filter: what arrives, and what never does ---
assert_eq "exits 0" "0" "$rc"
assert_eq "exactly the three clean labelled issues arrive" \
  "3" "$(jq 'length' <<<"$out")"
assert_eq "the assigned issue is dropped" \
  "false" "$(jq 'any(.[]; .number == 21)' <<<"$out")"
assert_eq "the Blocked-labelled issue is dropped, case notwithstanding" \
  "false" "$(jq 'any(.[]; .number == 22)' <<<"$out")"
assert_eq "the issue with an unresolved Blocked-by reference is dropped" \
  "false" "$(jq 'any(.[]; .number == 23)' <<<"$out")"
assert_eq "an issue carrying no pw::type:tech-debt label at all is never a candidate" \
  "false" "$(jq 'any(.[]; .number == 18)' <<<"$out")"
assert_eq "the pw::pager-labelled issue is dropped (agent-ops#2564)" \
  "false" "$(jq 'any(.[]; .number == 27)' <<<"$out")"
assert_eq "the assigned-and-also-Blocked-by issue is dropped too" \
  "false" "$(jq 'any(.[]; .number == 28)' <<<"$out")"
assert_eq "nothing on stderr on the success path" "" "$(cat "$tmp_dir/err")"

# --- The exclusion report (agent-ops#2603) ---
assert_eq "exactly the four single-reason drops, plus #28's own two, are reported excluded" \
  "6" "$(jq 'length' <<<"$excl")"
assert_eq "the assigned issue (no co-occurring Blocked-by) is reported once, reason assigned only (issue #2607: unchanged single-reason behavior)" \
  '[{"number":21,"reason":"assigned"}]' "$(jq -c '[.[] | select(.number == 21)]' <<<"$excl")"
assert_eq "the Blocked-labelled issue is reported, reason blocked-label" \
  "blocked-label" "$(jq -r '.[] | select(.number == 22) | .reason' <<<"$excl")"
assert_eq "the unresolved Blocked-by issue is reported, reason naming the reference" \
  "blocked-by: #24" "$(jq -r '.[] | select(.number == 23) | .reason' <<<"$excl")"
assert_eq "the pw::pager-labelled issue is reported, reason pager" \
  "pager" "$(jq -r '.[] | select(.number == 27) | .reason' <<<"$excl")"
assert_eq "issue #2607: the assigned issue that ALSO names an open Blocked-by reports both reasons" \
  '[{"number":28,"reason":"assigned"},{"number":28,"reason":"blocked-by: #29"}]' \
  "$(jq -c '[.[] | select(.number == 28)] | sort_by(.reason)' <<<"$excl")"
assert_eq "the un-labelled issue #18 is never reported — it was never a candidate" \
  "false" "$(jq 'any(.[]; .number == 18)' <<<"$excl")"
assert_eq "excluded is sorted by issue number ascending too" \
  "21 22 23 27 28 28" "$(jq -r '[.[].number] | join(" ")' <<<"$excl")"

# --- Sorted by Priority, then by the freshest thread ---
# #25 (tech-debt, triaged Low) is raised to High by inheritance — #26, a
# plain `issues`-band item banded High, names #25 as its own Blocked-by
# dependency, so it ranks first. Both #19 and #20 are unbanded (Medium,
# tied) below it: #20's own updatedAt (2026-07-20) outranks #19's
# (2026-07-18), so #20 comes next.
assert_eq "sorted by Priority then by the freshest thread, inheritance included" \
  "25 20 19" "$(jq -r '[.[].number] | join(" ")' <<<"$out")"

# --- Priority inheritance across bands (agent-ops#2422, requirement 4): a
#     tech-debt item named as the Blocked-by dependency of a *plain* issue
#     (never itself a tech-debt candidate) still inherits that issue's own
#     band — both gatherers run inheritance over the whole open-issue set,
#     not merely their own labelled slice. ---
entry25="$(jq -c '.[] | select(.number == 25)' <<<"$out")"
assert_eq "the blocker (#25) is ranked High, not its own triaged Low" \
  "High" "$(jq -r '.priority' <<<"$entry25")"
assert_eq "...naming the blocking (non-tech-debt) issue that raised it" \
  '["#26"]' "$(jq -c '.priority_raised_by' <<<"$entry25")"
assert_eq "...priority_set still reflects #25's own triage, untouched by inheritance" \
  "true" "$(jq -r '.priority_set' <<<"$entry25")"

# --- The entry shape: everything the Co-Ordinator selects on ---
entry20="$(jq -c '.[] | select(.number == 20)' <<<"$out")"
assert_eq "the entry's source is tech-debt" "tech-debt" "$(jq -r '.source' <<<"$entry20")"
assert_eq "the ref is the bare issue number, as a string" "20" "$(jq -r '.ref' <<<"$entry20")"
assert_eq "labels arrive sorted" '["backend","pw::type:tech-debt"]' "$(jq -c '.labels' <<<"$entry20")"
assert_eq "the body arrives verbatim" "The body of twenty." "$(jq -r '.body' <<<"$entry20")"
assert_eq "the whole thread arrives" "2" "$(jq '.comments | length' <<<"$entry20")"
assert_eq "a comment keeps its author, timestamp and body" \
  '{"author":"reviewer","created_at":"2026-07-20T09:00:00Z","body":"Scope cut: skip the UI."}' \
  "$(jq -c '.comments[1]' <<<"$entry20")"
assert_eq "the url is the issue's own html_url" \
  "https://github.com/o/r/issues/20" "$(jq -r '.url' <<<"$entry20")"

entry19="$(jq -c '.[] | select(.number == 19)' <<<"$out")"
assert_eq "a commentless issue carries an empty comments array, not null" \
  "[]" "$(jq -c '.comments' <<<"$entry19")"

# --- Once the dependency closes, the issue is no longer dropped ---
cat >"$STUB_REFS_DIR/24.json" <<'EOF'
{"state": "closed"}
EOF
raw_resolved="$("$GATHER" o/r 2>"$tmp_dir/err2")"
out_resolved="$(jq -c '.candidates' <<<"$raw_resolved")"
excl_resolved="$(jq -c '.excluded' <<<"$raw_resolved")"
assert_eq "a resolved Blocked-by reference stops excluding the issue" \
  "true" "$(jq 'any(.[]; .number == 23)' <<<"$out_resolved")"
assert_eq "  ... and it no longer appears in excluded either" \
  "false" "$(jq 'any(.[]; .number == 23)' <<<"$excl_resolved")"

# --- This band's own native-dependency pre-filter (agent-ops#2422) ---
#
# The same check scripts/gather-issues.sh gets in test/issues-prefetch.test.sh,
# asserted here too because the two gatherers hold their own copy of the
# two-liner that applies it: the native half of the holding check costs one
# REST read per candidate without it, and this is the larger of the two bands
# (422 of this repository's own 529 candidates). The stub below logs every
# `dependencies/blocked_by` path it is asked for, so the assertion is about
# which reads were made rather than about a verdict that looks the same
# either way. #40's summary reports no dependency and must not be read;
# #41's reports one, and the read then names an open blocker.
mkdir -p "$tmp_dir/bin-prefilter"
prefilter_log="$tmp_dir/native-calls.log"
: > "$prefilter_log"
cat >"$tmp_dir/bin-prefilter/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
if [[ "\${1:-}" == "api" && "\${2:-}" == "graphql" ]]; then
  shift 2
  filter='.'
  while [[ \$# -gt 0 ]]; do
    case "\$1" in --jq) filter="\$2"; shift 2;; *) shift;; esac
  done
  jq -c "\$filter" "\$STUB_ISSUES"
  exit 0
fi
if [[ "\${1:-}" == "api" && "\${2:-}" =~ ^repos/o/r/issues/([0-9]+)/dependencies/blocked_by\$ ]]; then
  n="\${BASH_REMATCH[1]}"
  echo "\$n" >> "$prefilter_log"
  if [[ "\$n" == "41" ]]; then
    echo '[{"number": 42, "state": "open", "repository": {"full_name": "o/r"}}]'
  else
    echo '[]'
  fi
  exit 0
fi
echo "stub gh: unexpected command: \$*" >&2
exit 1
STUB
chmod +x "$tmp_dir/bin-prefilter/gh"
export STUB_ISSUES="$tmp_dir/issues-prefilter.json"
cat >"$STUB_ISSUES" <<'EOF'
{"data": {"repository": {"issues": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [
  {"number": 40, "url": "https://github.com/o/r/issues/40", "title": "no native dependency",
   "author": {"login": "warwick"},
   "labels": {"nodes": [{"name": "pw::type:tech-debt"}]}, "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "issueDependenciesSummary": {"blockedBy": 0, "totalBlockedBy": 0},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Nothing blocks this one.", "comments": {"nodes": []}},
  {"number": 41, "url": "https://github.com/o/r/issues/41", "title": "one native dependency",
   "author": {"login": "warwick"},
   "labels": {"nodes": [{"name": "pw::type:tech-debt"}]}, "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "issueDependenciesSummary": {"blockedBy": 1, "totalBlockedBy": 1},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Declared natively, with no text line anywhere.", "comments": {"nodes": []}}
]}}}}
EOF
prefilter_out="$(PATH="$tmp_dir/bin-prefilter:${PATH#"$tmp_dir/bin:"}" "$GATHER" o/r 2>"$tmp_dir/prefilter.err")"
prefilter_candidates="$(jq -c '.candidates' <<<"$prefilter_out")"
assert_eq "the native read is made only for the tech-debt issue that has a dependency" \
  "41" "$(sort -u "$prefilter_log" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the issue whose summary reports no dependency is kept" \
  "true" "$(jq 'any(.[]; .number == 40)' <<<"$prefilter_candidates")"
assert_eq "the issue whose native dependency is open is held out" \
  "false" "$(jq 'any(.[]; .number == 41)' <<<"$prefilter_candidates")"

# The fixture and stub the sections below read, restored.
export STUB_ISSUES="$tmp_dir/issues.json"

# --- Degrading: a failing API yields {"candidates":[],"excluded":null}, ---
# --- exit 0, and is loud on stderr ---
cat >"$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "stub gh: HTTP 500" >&2
exit 1
STUB
chmod +x "$tmp_dir/bin/gh"

degraded="$("$GATHER" o/r 2>"$tmp_dir/degrade.err")"
degraded_rc=$?
assert_eq "a failing API degrades to {candidates:[],excluded:null}" \
  '{"candidates":[],"excluded":null}' "$degraded"
assert_eq "  ... and still exits 0" "0" "$degraded_rc"
if [[ -s "$tmp_dir/degrade.err" ]]; then
  printf 'ok   - %s\n' "and the failure is loud on stderr"
else
  printf 'FAIL - %s\n' "and the failure is loud on stderr (stderr was empty)"
  failures=$(( failures + 1 ))
fi

# --- The gatherer fails safe against the real API too ---
assert_eq "an unknown repo degrades the same way and exit 0, never a broken cycle" \
  '{"candidates":[],"excluded":null}' \
  "$(PATH="${PATH#"$tmp_dir/bin:"}" "$GATHER" "Poetic-Poems/does-not-exist" 2>/dev/null)"
assert_eq "  ... and exits 0" "0" "$?"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
