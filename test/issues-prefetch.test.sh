#!/usr/bin/env bash
#
# test/issues-prefetch.test.sh — regression test for the pre-fetched issues
# source (docs/spec/implementation/requirements, requirement 3j).
#
# The issues source used to be the Co-Ordinator's own `gh` read, and a cycle
# was observed skipping the entire walk on a "no issue data provided in
# input" misreading (20260727T145500Z-poetic-1-1431114). The fix hands the
# candidates over pre-fetched, and three halves of that have to hold outside
# the model, each failing silently if broken:
#
#   - **The deterministic filter.** Assigned issues, `blocked`-labelled
#     issues (whatever the case), `pw::pager`-labelled issues
#     (agent-ops#2564) and the pull requests the issues endpoint interleaves
#     must be dropped by the gatherer — requirement 16.4's deterministic
#     half — while everything else arrives whole-thread, with its `Priority`
#     band read exactly as the source-state digest reads it.
#   - **The exclusion report.** Every issue the deterministic filter drops
#     (never a pull request, which was never a candidate) must reappear in
#     the sibling `excluded` array with its number and why — agent-ops#447:
#     before this, a drop here left no trace anywhere a human or the
#     dashboard could read. An issue dropped under `issue_exclude_reason`'s
#     own single-reason precedence (assigned > blocked-label > pager) whose
#     own thread *also* names a still-open `Blocked-by:` reference must
#     report both: that second ground is independently checked, not a fourth
#     arm of the same precedence, so the one already reported must never
#     hide it (issue #2607) — otherwise such an issue stays eligible for
#     `lib/eligibility.sh`'s own open-`Blocked-by:`-reference Enabler filter
#     (requirement 35f) forever, since that filter only ever sees what this
#     array reports.
#   - **Degrading.** An API failure must yield `{"candidates":[],
#     "excluded":null}` (exit 0) with the failure on stderr: the output is
#     *given to* the Co-Ordinator, so an empty `candidates` is a faithful
#     record of its input, and aborting the cycle would make cost control a
#     reliability risk. `excluded` degrades to `null`, not `[]` — the
#     deterministic filter did not run to completion, so the exclusion set
#     is unknown, not known-empty (review decision on agent-ops#452
#     concern 3).
#   - **The fingerprint.** An *edit* to an existing comment moves no field the
#     issues digest samples — not even `updated_at`, which GitHub moves for
#     new comments but not edits — while the Co-Ordinator reads the thread
#     from this array. Hashing the array verbatim is the only thing that
#     wakes the cycle for it; if the fingerprint holds still across a comment
#     edit, a re-scoped instruction waits for an unrelated commit. That is
#     this system's signature failure (see the Gotchas table).
#
# `scripts/gather-issues.sh` is run for real here against a stubbed `gh`, so
# the assertions are about the shipped filter rather than a copy of it. Since
# agent-ops#1085 the listing-plus-comments read is one paginated GraphQL walk
# (`issue_prefetch_open_issues`, lib/issue-prefetch.sh); the stub answers it
# with a fixture in that function's own node shape, applying the caller's own
# `--jq` filter for real, the same technique test/issue-prefetch.test.sh's own
# stub uses.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/issues-prefetch.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/noop-skip.sh
. "$SCRIPT_DIR/lib/noop-skip.sh"

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

# --- A stub `gh`, so the real gatherer runs offline ---
#
# `api graphql` (the listing-plus-comments walk) applies the caller's own
# `--jq` filter to $STUB_ISSUES, a single-page GraphQL response fixture.
# `api repos/…/issues/<n>` (the `Blocked-by:` live-check, `issue_blocked_by_ref`)
# answers from $STUB_REFS_DIR, exactly as test/gather-tech-debt.test.sh's own
# stub does — needed since issue #2607's fix runs that same live check
# against a deterministically-dropped-but-labelled issue's own thread too.
mkdir -p "$tmp_dir/bin"
export STUB_REFS_DIR="$tmp_dir/refs"
mkdir -p "$STUB_REFS_DIR"
cat >"$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == "api" ]] || { echo "stub gh: unexpected command: $*" >&2; exit 1; }
if [[ "${2:-}" == "graphql" ]]; then
  shift 2
  filter='.'
  while [[ $# -gt 0 ]]; do
    case "$1" in --jq) filter="$2"; shift 2;; *) shift;; esac
  done
  jq -c "$filter" "$STUB_ISSUES"
  exit 0
fi
# `dependencies/blocked_by` (native Issue Dependencies, agent-ops#2422):
# empty for every issue unless STUB_NATIVE_DEPS names one, so the ordinary
# fixtures below never pay for the native check they never asked for. Every
# such read is also logged to STUB_NATIVE_CALL_LOG where that is set — the
# pre-filter section below asserts on *which* issues were asked about, which
# no return value can show.
if [[ "${2:-}" =~ ^repos/o/r/issues/([0-9]+)/dependencies/blocked_by$ ]]; then
  n="${BASH_REMATCH[1]}"
  [[ -n "${STUB_NATIVE_CALL_LOG:-}" ]] && echo "$n" >> "$STUB_NATIVE_CALL_LOG"
  if [[ -n "${STUB_NATIVE_DEPS:-}" && -f "${STUB_NATIVE_DEPS}/$n.json" ]]; then
    cat "${STUB_NATIVE_DEPS}/$n.json"
  else
    echo '[]'
  fi
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
# #5 is clean with an explicit High band, labels and a two-comment thread;
# #6 is assigned; #7 is labelled `Blocked` (upper case, so the drop is proven
# case-insensitive); #8, a pull request, is simply absent — GraphQL's
# `issues` connection never returns one to begin with, unlike the REST
# listing this replaced, so there is nothing to fixture for it; #9 is clean,
# untriaged (no `Priority` — the Medium default) and commentless; #16 is
# labelled `pw::pager`, unassigned and not `Blocked`-labelled, proving the
# pager drop fires on its own (agent-ops#2564); #30 is labelled `Blocked`
# (the same single-reason drop #7 gets) and *also* names a still-open
# `Blocked-by: #31` in its own body, proving issue #2607's fix: a
# deterministically-dropped issue's own thread is checked for a
# co-occurring Blocked-by reference too, reported as a second `excluded`
# entry rather than the one reason hiding the other.
export STUB_ISSUES="$tmp_dir/issues.json"
cat >"$STUB_ISSUES" <<'EOF'
{"data": {"repository": {"issues": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [
  {"number": 5, "url": "https://github.com/o/r/issues/5", "title": "Add the frobnicator",
   "author": {"login": "warwick"},
   "labels": {"nodes": [{"name": "enhancement"}, {"name": "backend"}]},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": [
     {"__typename": "IssueFieldSingleSelectValue", "name": "High",
      "field": {"__typename": "IssueFieldSingleSelect", "name": "Priority"}}]},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "The body of five.",
   "comments": {"nodes": [
     {"author": {"login": "warwick"}, "createdAt": "2026-07-19T10:00:00Z", "body": "Acceptance: it frobnicates."},
     {"author": {"login": "reviewer"}, "createdAt": "2026-07-20T09:00:00Z", "body": "Scope cut: skip the UI."}
   ]}},
  {"number": 6, "url": "https://github.com/o/r/issues/6", "title": "Assigned work",
   "author": {"login": "warwick"},
   "labels": {"nodes": []},
   "assignees": {"totalCount": 1},
   "issueFieldValues": {"nodes": [
     {"__typename": "IssueFieldSingleSelectValue", "name": "Urgent",
      "field": {"__typename": "IssueFieldSingleSelect", "name": "Priority"}}]},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Assigned, so not a candidate.", "comments": {"nodes": []}},
  {"number": 7, "url": "https://github.com/o/r/issues/7", "title": "Blocked work",
   "author": {"login": "warwick"},
   "labels": {"nodes": [{"name": "Blocked"}]},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Labelled Blocked, so not a candidate.", "comments": {"nodes": []}},
  {"number": 9, "url": "https://github.com/o/r/issues/9", "title": "Untriaged work",
   "author": {"login": "warwick"},
   "labels": {"nodes": []},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "No Priority field set.", "comments": {"nodes": []}},
  {"number": 11, "url": "https://github.com/o/r/issues/11", "title": "An org-added fifth band",
   "author": {"login": "warwick"},
   "labels": {"nodes": []},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": [
     {"__typename": "IssueFieldSingleSelectValue", "name": "Critical",
      "field": {"__typename": "IssueFieldSingleSelect", "name": "Priority"}}]},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Banded Critical, an option this pipeline does not rank.", "comments": {"nodes": []}},
  {"number": 12, "url": "https://github.com/o/r/issues/12", "title": "Priority retyped to a text field",
   "author": {"login": "warwick"},
   "labels": {"nodes": []},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": [{"__typename": "IssueFieldTextValue"}]},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "A valid Priority field value carrying no single-select shape at all.",
   "comments": {"nodes": []}},
  {"number": 13, "url": "https://github.com/o/r/issues/13", "title": "Priority with no evidence at all",
   "author": {"login": "warwick"},
   "labels": {"nodes": []},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "REST could carry a malformed explicit-null single_select_option here (agent-ops#527); GraphQL's IssueFieldSingleSelectValue.name is non-null by schema, so that shape cannot occur — this is the same unset reading as #9, kept as its own numbered fixture so the assertion below still names its own issue.",
   "comments": {"nodes": []}},
  {"number": 14, "url": "https://github.com/o/r/issues/14", "title": "Debt mislabelled into this band",
   "author": {"login": "warwick"},
   "labels": {"nodes": [{"name": "pw::type:tech-debt"}]},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": [
     {"__typename": "IssueFieldSingleSelectValue", "name": "High",
      "field": {"__typename": "IssueFieldSingleSelect", "name": "Priority"}}]},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "This belongs to the tech-debt band instead (issue #875).", "comments": {"nodes": []}},
  {"number": 16, "url": "https://github.com/o/r/issues/16", "title": "Pager: blocked-label-orphaned",
   "author": {"login": "warwick"},
   "labels": {"nodes": [{"name": "pw::pager"}]},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "A pager tracking issue, never ordinary selectable work (agent-ops#2564).",
   "comments": {"nodes": []}},
  {"number": 30, "url": "https://github.com/o/r/issues/30", "title": "Blocked-labelled, and also Blocked-by",
   "author": {"login": "warwick"},
   "labels": {"nodes": [{"name": "Blocked"}]},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Labelled Blocked, so dropped for that reason alone under issue_exclude_reason's own precedence.\n\nBlocked-by: #31",
   "comments": {"nodes": []}}
]}}}}
EOF
cat >"$STUB_REFS_DIR/31.json" <<'EOF'
{"state": "open"}
EOF

issues_json="$("$SCRIPT_DIR/scripts/gather-issues.sh" o/r)"
candidates_json="$(jq -c '.candidates' <<<"$issues_json")"
excluded_json="$(jq -c '.excluded' <<<"$issues_json")"

# --- The filter: what arrives, and what never does ---
assert_eq "exactly the five clean issues arrive" \
  "5" "$(jq 'length' <<<"$candidates_json")"
assert_eq "the assigned issue is dropped" \
  "false" "$(jq 'any(.[]; .number == 6)' <<<"$candidates_json")"
assert_eq "the Blocked-labelled issue is dropped, case notwithstanding" \
  "false" "$(jq 'any(.[]; .number == 7)' <<<"$candidates_json")"
assert_eq "the pull request is dropped" \
  "false" "$(jq 'any(.[]; .number == 8)' <<<"$candidates_json")"
assert_eq "a pw::type:tech-debt-labelled issue is dropped (issue #875)" \
  "false" "$(jq 'any(.[]; .number == 14)' <<<"$candidates_json")"
assert_eq "  ... and never reported as excluded either — it belongs to the other band" \
  "false" "$(jq 'any(.[]; .number == 14)' <<<"$excluded_json")"
assert_eq "the pw::pager-labelled issue is dropped (agent-ops#2564)" \
  "false" "$(jq 'any(.[]; .number == 16)' <<<"$candidates_json")"
assert_eq "the Blocked-labelled-and-also-Blocked-by issue is dropped too" \
  "false" "$(jq 'any(.[]; .number == 30)' <<<"$candidates_json")"

# --- The exclusion report: what was dropped, and why (agent-ops#447) ---
assert_eq "exactly the three single-reason drops, plus #30's own two, are reported" \
  "5" "$(jq 'length' <<<"$excluded_json")"
assert_eq "the assigned issue is reported, tagged assigned" \
  '{"number":6,"reason":"assigned"}' "$(jq -c '.[] | select(.number == 6)' <<<"$excluded_json")"
assert_eq "the Blocked-labelled issue (no co-occurring Blocked-by) is reported once, tagged blocked-label only (issue #2607: unchanged single-reason behavior)" \
  '[{"number":7,"reason":"blocked-label"}]' "$(jq -c '[.[] | select(.number == 7)]' <<<"$excluded_json")"
assert_eq "the pw::pager-labelled issue is reported, tagged pager" \
  '{"number":16,"reason":"pager"}' "$(jq -c '.[] | select(.number == 16)' <<<"$excluded_json")"
assert_eq "issue #2607: the Blocked-labelled issue that ALSO names an open Blocked-by reports both reasons" \
  '[{"number":30,"reason":"blocked-by: #31"},{"number":30,"reason":"blocked-label"}]' \
  "$(jq -c '[.[] | select(.number == 30)] | sort_by(.reason)' <<<"$excluded_json")"
assert_eq "  ... and it is excluded from the Enabler-eligible set too, same as any other blocked-by drop (requirement 35f)" \
  "true" "$(jq '[.[] | select(.number == 30 and (.reason | startswith("blocked-by: ")))] | length == 1' <<<"$excluded_json")"
assert_eq "the pull request is never reported as excluded" \
  "false" "$(jq 'any(.[]; .number == 8)' <<<"$excluded_json")"

# --- The entry shape: everything the Co-Ordinator selects on ---
entry5="$(jq -c '.[] | select(.number == 5)' <<<"$candidates_json")"
assert_eq "the entry's source is issues" "issues" "$(jq -r '.source' <<<"$entry5")"
assert_eq "the ref is the bare issue number, as a string" "5" "$(jq -r '.ref' <<<"$entry5")"
assert_eq "the Priority band arrives as priority" "High" "$(jq -r '.priority' <<<"$entry5")"
assert_eq "a real band arrives with priority_set true (requirement 39g)" \
  "true" "$(jq -r '.priority_set' <<<"$entry5")"
assert_eq "labels arrive sorted" '["backend","enhancement"]' "$(jq -c '.labels' <<<"$entry5")"
assert_eq "the body arrives verbatim" "The body of five." "$(jq -r '.body' <<<"$entry5")"
assert_eq "the whole thread arrives" "2" "$(jq '.comments | length' <<<"$entry5")"
assert_eq "a comment keeps its author, timestamp and body" \
  '{"author":"reviewer","created_at":"2026-07-20T09:00:00Z","body":"Scope cut: skip the UI."}' \
  "$(jq -c '.comments[1]' <<<"$entry5")"

entry9="$(jq -c '.[] | select(.number == 9)' <<<"$candidates_json")"
assert_eq "an untriaged issue defaults to Medium, not lowest" \
  "Medium" "$(jq -r '.priority' <<<"$entry9")"
assert_eq "...but the Medium default carries priority_set false, distinguishing it from a real band" \
  "false" "$(jq -r '.priority_set' <<<"$entry9")"
assert_eq "a commentless issue carries an empty comments array, not null" \
  "[]" "$(jq -c '.comments' <<<"$entry9")"

# An org-added fifth band (agent-ops#509): the recognised-only `priority`
# still reads Medium — it must agree with the Co-Ordinator's own default,
# same as an unset field — but `priority_set` is true, since a human (or
# agent) did choose something on the field. Conflating the two would leave
# this issue looking untriaged to the Refiner's triage rule forever, even
# once someone has banded it.
entry11="$(jq -c '.[] | select(.number == 11)' <<<"$candidates_json")"
assert_eq "a band outside the four names still reads Medium, not its own name" \
  "Medium" "$(jq -r '.priority' <<<"$entry11")"
assert_eq "...but priority_set is true — something was chosen, even if unrankable" \
  "true" "$(jq -r '.priority_set' <<<"$entry11")"

# --- agent-ops#527: a Priority field value with no single_select_option must
#     read as unset, not set — the null it contributes to $priority_names has
#     to be dropped, not counted. Three shapes: a valid field value of a
#     different type (empty option list, #9, already asserted above), a
#     field retyped to text (#12), and a malformed explicit null (#13).
assert_eq "an unset Priority (empty option list) still carries priority_set false" \
  "false" "$(jq -r '.priority_set' <<<"$entry9")"

entry12="$(jq -c '.[] | select(.number == 12)' <<<"$candidates_json")"
assert_eq "a Priority value with no single_select_option reads Medium" \
  "Medium" "$(jq -r '.priority' <<<"$entry12")"
assert_eq "...and priority_set false, not true (agent-ops#527)" \
  "false" "$(jq -r '.priority_set' <<<"$entry12")"

entry13="$(jq -c '.[] | select(.number == 13)' <<<"$candidates_json")"
assert_eq "a Priority value with single_select_option explicitly null reads Medium" \
  "Medium" "$(jq -r '.priority' <<<"$entry13")"
assert_eq "...and priority_set false, not true (agent-ops#527)" \
  "false" "$(jq -r '.priority_set' <<<"$entry13")"

# --- The fingerprint moves when only a comment's text moves ---
#
# Two runtime inputs identical but for the body of one comment — the
# transition no digest field carries, because editing a comment in place does
# not move the issue's `updated_at`. If these fingerprint the same, a
# re-scoped instruction edited into a thread never wakes the Co-Ordinator.
fp_input() {
  jq -nc --argjson issues "$1" '
    {repos: [{slug: "o/r", default_branch: "main", sources: ["issues:medium"],
              findings: [], review_feedback: [], issues: $issues,
              state: {ok: true, head_sha: "aaa111", issues: [], workflows: [], open_prs: []}}],
     blocked: [], void: [], enabler_eligible: [],
     selection_config: {}, coordinator_prompt_sha: "deadbeef",
     enabler_config: {}, enabler_prompt_sha: "cafebabe"}'
}

fp_before="$(fp_input "$candidates_json" | noop_fingerprint)"
assert_eq "the sample is fingerprintable" "64" "${#fp_before}"

issues_edited="$(jq -c '(.[] | select(.number == 5) | .comments[1].body) = "Scope restored: include the UI."' \
  <<<"$candidates_json")"
fp_after="$(fp_input "$issues_edited" | noop_fingerprint)"
if [[ "$fp_before" != "$fp_after" ]]; then
  printf 'ok   - %s\n' "editing a comment's text busts the no-op fingerprint"
else
  printf 'FAIL - %s\n     both cycles fingerprinted: %s\n' \
    "editing a comment's text busts the no-op fingerprint" "$fp_before"
  failures=$(( failures + 1 ))
fi

fp_same="$(fp_input "$candidates_json" | noop_fingerprint)"
assert_eq "an unchanged array fingerprints identically" "$fp_before" "$fp_same"

# --- Priority inheritance, end to end (agent-ops#2422, requirement 4): a Low
#     item (#20) that a High item (#21) names as its own `Blocked-by:`
#     dependency ranks as High in the Co-Ordinator's own input — the array
#     scripts/gather-issues.sh actually hands it — not merely in the pure
#     function test/dependency-gate.test.sh already covers. #21 itself is
#     excluded (#20 is open, so the dependency is unresolved) — expected, and
#     exactly how requirement 34j's own holding already behaves — while #20
#     survives as an ordinary candidate, its own band raised. ---
export STUB_ISSUES="$tmp_dir/issues-inherit.json"
cat >"$STUB_ISSUES" <<'EOF'
{"data": {"repository": {"issues": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [
  {"number": 20, "url": "https://github.com/o/r/issues/20", "title": "the blocker, banded Low",
   "author": {"login": "warwick"},
   "labels": {"nodes": []},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": [
     {"__typename": "IssueFieldSingleSelectValue", "name": "Low",
      "field": {"__typename": "IssueFieldSingleSelect", "name": "Priority"}}]},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Nothing blocks this one.", "comments": {"nodes": []}},
  {"number": 21, "url": "https://github.com/o/r/issues/21", "title": "the blocked item, banded High",
   "author": {"login": "warwick"},
   "labels": {"nodes": []},
   "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": [
     {"__typename": "IssueFieldSingleSelectValue", "name": "High",
      "field": {"__typename": "IssueFieldSingleSelect", "name": "Priority"}}]},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Needs #20 first.\n\nBlocked-by: #20", "comments": {"nodes": []}}
]}}}}
EOF
inherit_json="$("$SCRIPT_DIR/scripts/gather-issues.sh" o/r)"
inherit_candidates="$(jq -c '.candidates' <<<"$inherit_json")"
assert_eq "the blocked item (#21) is held out, unresolved" \
  "false" "$(jq '[.[] | select(.number == 21)] | length > 0' <<<"$inherit_candidates")"
assert_eq "the blocker (#20) survives as an ordinary candidate" \
  "true" "$(jq '[.[] | select(.number == 20)] | length > 0' <<<"$inherit_candidates")"
assert_eq "...ranked High, not its own triaged Low" \
  "High" "$(jq -r '.[] | select(.number == 20) | .priority' <<<"$inherit_candidates")"
assert_eq "...naming the blocked item that raised it" \
  '["#21"]' "$(jq -c '.[] | select(.number == 20) | .priority_raised_by' <<<"$inherit_candidates")"
assert_eq "...priority_set still reflects #20's own triage, untouched by inheritance" \
  "true" "$(jq -r '.[] | select(.number == 20) | .priority_set' <<<"$inherit_candidates")"
assert_eq "#21 is reported excluded, naming the unresolved reference" \
  "blocked-by: #20" "$(jq -r '.excluded[] | select(.number == 21) | .reason' <<<"$inherit_json")"

# --- The native-dependency read is made for the issues that have one, and no
#     others (agent-ops#2422, requirement 34j) ---
#
# The holding check's native half asks GitHub about one issue at a time, and
# this loop is uncapped: a read per candidate is ~529 REST calls and ~10
# minutes of wall clock on this repository's own backlog, which is the
# one-call-per-surviving-candidate shape agent-ops#1085 removed. The listing
# walk already reports each issue's own dependency counts, so
# `issue_prefetch_native_dep_skip_set` (lib/issue-prefetch.sh) keeps the live
# read for the issues that actually have a dependency.
#
# Asserted on the stub's own call log rather than on the verdict, because the
# verdict is identical either way — an issue with no dependency is kept
# whether the read was made and came back empty or was never made at all.
# #30's summary reports none, #31's reports one (and the read then names an
# open #42), and #32 carries no summary at all — the walk could not answer,
# so the read is still made, which is what keeps every fixture above (none of
# which carries the field) exercising the native path unchanged.
export STUB_NATIVE_DEPS="$tmp_dir/native-deps"
mkdir -p "$STUB_NATIVE_DEPS"
cat >"$STUB_NATIVE_DEPS/31.json" <<'EOF'
[{"number": 42, "state": "open", "repository": {"full_name": "o/r"}}]
EOF
export STUB_NATIVE_CALL_LOG="$tmp_dir/native-calls.log"
: > "$STUB_NATIVE_CALL_LOG"
export STUB_ISSUES="$tmp_dir/issues-prefilter.json"
cat >"$STUB_ISSUES" <<'EOF'
{"data": {"repository": {"issues": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [
  {"number": 30, "url": "https://github.com/o/r/issues/30", "title": "no native dependency",
   "author": {"login": "warwick"}, "labels": {"nodes": []}, "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "issueDependenciesSummary": {"blockedBy": 0, "totalBlockedBy": 0},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Nothing blocks this one.", "comments": {"nodes": []}},
  {"number": 31, "url": "https://github.com/o/r/issues/31", "title": "one native dependency",
   "author": {"login": "warwick"}, "labels": {"nodes": []}, "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "issueDependenciesSummary": {"blockedBy": 1, "totalBlockedBy": 1},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "Declared natively, with no text line anywhere.", "comments": {"nodes": []}},
  {"number": 32, "url": "https://github.com/o/r/issues/32", "title": "no summary at all",
   "author": {"login": "warwick"}, "labels": {"nodes": []}, "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "issueDependenciesSummary": null,
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "The walk could not say.", "comments": {"nodes": []}}
]}}}}
EOF
prefilter_json="$("$SCRIPT_DIR/scripts/gather-issues.sh" o/r)"
prefilter_calls="$(sort -u "$STUB_NATIVE_CALL_LOG" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the native read is made only for the issue that has a dependency, and the one the walk could not answer for" \
  "31 32" "$prefilter_calls"
assert_eq "the issue whose summary reports no dependency is kept" \
  "true" "$(jq '[.candidates[] | select(.number == 30)] | length > 0' <<<"$prefilter_json")"
assert_eq "the issue whose native dependency is open is held out" \
  "false" "$(jq '[.candidates[] | select(.number == 31)] | length > 0' <<<"$prefilter_json")"
assert_eq "  ... and reported excluded, naming the native reference" \
  "blocked-by: #42" "$(jq -r '.excluded[] | select(.number == 31) | .reason' <<<"$prefilter_json")"
assert_eq "the issue with no summary is read live and, finding none, kept" \
  "true" "$(jq '[.candidates[] | select(.number == 32)] | length > 0' <<<"$prefilter_json")"
unset STUB_NATIVE_DEPS STUB_NATIVE_CALL_LOG

# --- Degrading: a failing API yields the empty shape, exit 0, and says so
#     on stderr ---
cat >"$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "stub gh: HTTP 500" >&2
exit 1
STUB
chmod +x "$tmp_dir/bin/gh"

degraded="$("$SCRIPT_DIR/scripts/gather-issues.sh" o/r 2>"$tmp_dir/degrade.err")"
degraded_rc=$?
assert_eq "a failing API degrades to an empty candidates array" \
  "[]" "$(jq -c '.candidates' <<<"$degraded")"
assert_eq "  ... and a null (unknown, not known-empty) excluded" \
  "null" "$(jq -c '.excluded' <<<"$degraded")"
assert_eq "and still exits 0" "0" "$degraded_rc"
if [[ -s "$tmp_dir/degrade.err" ]]; then
  printf 'ok   - %s\n' "and the failure is loud on stderr"
else
  printf 'FAIL - %s\n' "and the failure is loud on stderr (stderr was empty)"
  failures=$(( failures + 1 ))
fi

# --- The argv cap (requirement 4g, TD-PPagop-26081406) ---
#
# $comments (a whole issue thread — component 3d/#118 pre-fetches every
# comment) and the array-assembly append both used to ride into jq as
# --argjson: unbounded past this call, the same reasoning
# TD-PPagop-26081401 already applied elsewhere. Past MAX_ARG_STRLEN (131072
# bytes) the entry build died at execve and, guarded by `degrade`, this
# repo's whole issues band came out `[]` — loud on stderr, not silent.
# Requirement 4g moves both onto stdin; this drives the real script, via the
# same GraphQL-answering stub gh as above (restored here, since the
# degrading section just above replaced it with an always-failing one), over
# a single issue whose comment thread alone is past the cap.
cat >"$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == "api" && "${2:-}" == "graphql" ]] || { echo "stub gh: unexpected command: $*" >&2; exit 1; }
shift 2
filter='.'
while [[ $# -gt 0 ]]; do
  case "$1" in --jq) filter="$2"; shift 2;; *) shift;; esac
done
jq -c "$filter" "$STUB_ISSUES"
STUB
chmod +x "$tmp_dir/bin/gh"

oversized_comment_body="$(head -c 140000 < /dev/zero | tr '\0' 'x')"
assert_eq "the oversized comment-body fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( ${#oversized_comment_body} > 131072 ))"

# Built with `printf`, not `jq --arg`: an oversized `--arg` value would hit
# the very argv cap this section exists to prove the real code no longer
# does — $oversized_comment_body is all-`x`, so it needs no JSON escaping to
# embed literally.
printf '{"data": {"repository": {"issues": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [
  {"number": 10, "url": "https://github.com/o/r/issues/10", "title": "A thread past the argv cap",
   "author": {"login": "warwick"},
   "labels": {"nodes": []}, "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": [
     {"__typename": "IssueFieldSingleSelectValue", "name": "High",
      "field": {"__typename": "IssueFieldSingleSelect", "name": "Priority"}}]},
   "createdAt": "2026-07-19T08:00:00Z", "updatedAt": "2026-07-20T09:00:00Z",
   "body": "The oversized thread lives in the comments, not here.",
   "comments": {"nodes": [{"author": {"login": "warwick"}, "createdAt": "2026-07-19T10:00:00Z", "body": "%s"}]}}
]}}}}' "$oversized_comment_body" > "$STUB_ISSUES"

oversized_out="$("$SCRIPT_DIR/scripts/gather-issues.sh" o/r 2>"$tmp_dir/oversized.err")"
oversized_rc=$?
oversized_candidates="$(jq -c '.candidates' <<<"$oversized_out")"
assert_eq "an issue whose thread is past the argv cap still exits 0" "0" "$oversized_rc"
assert_eq "  ... and still produces the entry" "1" "$(jq 'length' <<<"$oversized_candidates")"
entry10_body="$(jq -r '.[0].comments[0].body // ""' <<<"$oversized_candidates")"
# Bash string matching, not jq --arg with the oversized string: that would
# hit the very argv cap this section exists to prove the real code no longer
# does.
assert_eq "  ... carrying the full oversized comment, not truncated or dropped" \
  "1" "$([[ "$entry10_body" == *"$oversized_comment_body"* ]] && echo 1 || echo 0)"
assert_eq "  ... and the ref is still the bare issue number" \
  "10" "$(jq -r '.[0].ref' <<<"$oversized_candidates")"
if [[ ! -s "$tmp_dir/oversized.err" ]]; then
  printf 'ok   - %s\n' "no stderr at all on the success path"
else
  printf 'FAIL - %s\n     stderr: %s\n' "no stderr at all on the success path" "$(cat "$tmp_dir/oversized.err")"
  failures=$(( failures + 1 ))
fi

echo
if (( failures == 0 )); then
  echo "All issues-prefetch assertions passed."
  exit 0
else
  echo "$failures issues-prefetch assertion(s) FAILED."
  exit 1
fi
