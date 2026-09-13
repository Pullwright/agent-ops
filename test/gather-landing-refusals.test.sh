#!/usr/bin/env bash
#
# test/gather-landing-refusals.test.sh — regression test for the candidate
# rule of scripts/gather-landing-refusals.sh (requirement 53, issue #979).
#
# The rule decides which of *our own* Ready pull requests the Script's own
# landing gate (gate 4 of `_landing_stage_attempt`, `lib/landing.sh`) keeps
# refusing to arm over a comment-reconciliation problem, and it has the same
# two dangerous directions every finishing source does:
#   - too eager, and it offers a pull request whose refusal is some other
#     class entirely (a human `CHANGES_REQUESTED`, already `review-feedback`'s
#     own candidate) or one already answered, wasting an Implementer round on
#     nothing to do;
#   - too shy, and a pull request genuinely stuck behind an unanswered comment
#     sits forever looking Ready to every other source, with nobody ever
#     asked to answer it.
# The `reconciliation-unanswered:`/`reconciliation-unreadable:` class filter on
# the logged refusal, and the live re-check via
# `reconciliation_unreconciled_comments`, are what hold the line. Keep this in
# step with the filters in the script.
#
# Exercised for real, through LANDING_REFUSALS_GH, against a stub `gh`
# combining a `pr list` fixture (the "ours" listing) and the `issues/…
# /timeline`, `pulls/<n>` and `issues/…/comments` fixtures
# test/reconciliation-gate.test.sh's own stub already establishes the shape
# of — `lib/reconciliation-gate.sh`'s own functions are exercised for real
# here too, not re-proven (see that file's own dedicated test).
#
# Run directly:
#
#   ./test/gather-landing-refusals.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# --- The "ours" filter: which open, Ready PRs might even be in scope? -------
prs='[
  {"number": 90, "isDraft": false, "headRefName": "agent/td1-fix"},
  {"number": 91, "isDraft": true,  "headRefName": "agent/td2-fix"},
  {"number": 92, "isDraft": false, "headRefName": "feature/a-humans-branch"},
  {"number": 93, "isDraft": false, "headRefName": "td/TD26072001"}
]'

candidate_filter() {
  jq -c '[.[] | select(.isDraft | not)
              | select((.headRefName | startswith("agent/"))
                       or (.headRefName | startswith("td/")))
              | .number]' <<<"$prs"
}

assert_eq "only open, non-draft, ours-by-branch PRs pass the ours filter" \
  "[90,93]" "$(candidate_filter)"
assert_eq "a draft PR is never a candidate — gate 4 never runs against one" \
  "0" "$(jq '[.[] | select(.number == 91) | select(.isDraft | not)] | length' <<<"$prs")"
assert_eq "a human's own branch is never ours to answer" \
  "0" "$(jq '[.[] | select(.number == 92) | select((.headRefName | startswith("agent/")) or (.headRefName | startswith("td/")))] | length' <<<"$prs")"
assert_eq "a tech-debt td/ claim branch counts as ours" \
  "1" "$(jq '[.[] | select(.number == 93) | select(.headRefName | startswith("td/"))] | length' <<<"$prs")"

# --- The ref: scoped to the sorted, joined unreconciled comment ids ---------
ref_of() { jq -r '"pr-\(.number)-landing-refusal-\(.ids | join("-"))"' <<<"$1"; }
assert_eq "the ref pins to the PR number and the unreconciled ids, sorted" \
  "pr-90-landing-refusal-111-222" \
  "$(ref_of '{"number": 90, "ids": ["111","222"]}')"
assert_eq "answering one comment (a smaller set) yields a different ref" \
  "pr-90-landing-refusal-222" \
  "$(ref_of '{"number": 90, "ids": ["222"]}')"

# --- Exercised for real: the script against a combined stub gh -------------
#
# $tmp_dir/prlist.json    the `gh pr list --json ...` payload
# $tmp_dir/timeline.json  {"<number>": [ {event, created_at}, … ]} — the
#                         reconciliation anchor's own timeline read. A number
#                         absent here makes that read fail (unreadable).
# $tmp_dir/pr-created.json {"<number>": {created_at}} — the anchor's
#                         creation-time fallback (unused once the timeline
#                         read succeeds).
# $tmp_dir/comments.json {"<number>": [ {id, created_at, body, user}, … ]} —
#                         the general PR comments. A number absent here makes
#                         that read fail too.
# $tmp_dir/union-log.jsonl  the fleet-wide union log `landing_latest_refusal_
#                         reason` reads directly (never through `gh`).
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"

if [[ "$1 $2" == "pr list" ]]; then
  cat "$d/prlist.json"
  exit 0
fi

[[ "${1:-}" == "api" ]] || exit 1
path="$2"
jqfilter="." prev=""
for a in "$@"; do
  [[ "$prev" == "--jq" ]] && jqfilter="$a"
  prev="$a"
done

case "$path" in
  repos/*/issues/*/timeline)
    number="${path#repos/*/issues/}"; number="${number%/timeline}"
    entries="$(jq -c --arg n "$number" '.[$n] // empty' "$d/timeline.json" 2>/dev/null)"
    [[ -n "$entries" ]] || exit 1
    jq -c "$jqfilter" <<<"$entries"
    ;;
  repos/*/issues/*/comments)
    number="${path#repos/*/issues/}"; number="${number%/comments}"
    entries="$(jq -c --arg n "$number" '.[$n] // empty' "$d/comments.json" 2>/dev/null)"
    [[ -n "$entries" ]] || exit 1
    jq -c "$jqfilter" <<<"$entries"
    ;;
  repos/*/pulls/*)
    number="${path##*/pulls/}"
    entry="$(jq -c --arg n "$number" '.[$n] // empty' "$d/pr-created.json" 2>/dev/null)"
    [[ -n "$entry" ]] || exit 1
    jq -c "$jqfilter" <<<"$entry"
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp_dir/gh"

pr_entry() {  # <number> <headRefName> [isDraft]
  jq -nc --argjson n "$1" --arg h "$2" --argjson d "${3:-false}" --arg sha "sha${1}00000000" \
    '{number: $n, title: ("fix " + ($n|tostring)), headRefName: $h, headRefOid: $sha,
      isDraft: $d, url: ("https://github.com/o/r/pull/" + ($n|tostring)),
      body: "body"}'
}

marker() { printf '<!-- agent-ops:pipeline-comment cycle=c1 actor=%s -->' "$1"; }

union_log_add() {  # <pr_url> <reason> [ts]
  jq -nc --arg u "$1" --arg r "$2" --arg ts "${3:-2026-08-24T01:00:00Z}" \
    '{ts: $ts, event: "landing-refused", pr_url: $u, reason: $r}' >> "$tmp_dir/union-log.jsonl"
}

# Fixture: seven PRs exercising every gate at once.
#   201 reconciliation-unanswered, one comment still genuinely unreconciled -> candidate
#   202 draft                                                               -> not a candidate (ours filter)
#   203 a human's own branch                                                -> not a candidate (ours filter)
#   204 no landing-refused event logged at all                              -> not a candidate
#   205 landing-refused logged, but a different refusal class               -> not a candidate
#   206 reconciliation-unanswered, but already reconciled on a live check   -> not a candidate (answered clause)
#   207 reconciliation-unreadable                                          -> candidate too (both classes)
#   208 reconciliation-unanswered, but the live check itself fails         -> not a candidate (fail closed)
jq -nc \
  --argjson p201 "$(pr_entry 201 agent/td201)" \
  --argjson p202 "$(pr_entry 202 agent/td202 true)" \
  --argjson p203 "$(pr_entry 203 feature/a-humans-branch)" \
  --argjson p204 "$(pr_entry 204 agent/td204)" \
  --argjson p205 "$(pr_entry 205 agent/td205)" \
  --argjson p206 "$(pr_entry 206 agent/td206)" \
  --argjson p207 "$(pr_entry 207 agent/td207)" \
  --argjson p208 "$(pr_entry 208 agent/td208)" \
  '[$p201, $p202, $p203, $p204, $p205, $p206, $p207, $p208]' > "$tmp_dir/prlist.json"

: > "$tmp_dir/union-log.jsonl"
union_log_add "https://github.com/o/r/pull/201" "reconciliation-unanswered:human comment(s) posted on … carry no … line answering them: …" "2026-08-24T02:00:00Z"
union_log_add "https://github.com/o/r/pull/205" "human-changes-requested:a human CHANGES_REQUESTED stands (warwickallen)"
union_log_add "https://github.com/o/r/pull/206" "reconciliation-unanswered:human comment(s) posted on … carry no … line answering them: …" "2026-08-24T01:00:00Z"
union_log_add "https://github.com/o/r/pull/207" "reconciliation-unreadable:could not confirm every human comment is reconciled" "2026-08-24T03:00:00Z"
union_log_add "https://github.com/o/r/pull/208" "reconciliation-unanswered:human comment(s) posted on … carry no … line answering them: …"

jq -nc '{
  "201": [{"event": "ready_for_review", "created_at": "2026-08-20T00:00:00Z"}],
  "206": [{"event": "ready_for_review", "created_at": "2026-08-20T00:00:00Z"}],
  "207": [{"event": "ready_for_review", "created_at": "2026-08-20T00:00:00Z"}]
}' > "$tmp_dir/timeline.json"
jq -nc '{}' > "$tmp_dir/pr-created.json"

jq -nc --arg impl "$(marker implementer)" '{
  "201": [{"id": 5001, "created_at": "2026-08-21T00:00:00Z",
           "body": "Please fix the widget too.",
           "user": {"login": "warwickallen", "type": "User"}}],
  "206": [{"id": 6001, "created_at": "2026-08-21T00:00:00Z",
           "body": "One more thing.",
           "user": {"login": "warwickallen", "type": "User"}},
          {"id": 6002, "created_at": "2026-08-21T01:00:00Z",
           "body": ("Answered.\n\n<!-- agent-ops:reconciles comment=6001 -->\n\n" + $impl),
           "user": {"login": "warwickallen", "type": "User"}}],
  "207": [{"id": 7001, "created_at": "2026-08-21T00:00:00Z",
           "body": "A second thing before this lands.",
           "user": {"login": "warwickallen", "type": "User"}}]
}' > "$tmp_dir/comments.json"

out="$(LANDING_REFUSALS_GH="$tmp_dir/gh" "$SCRIPT_DIR/scripts/gather-landing-refusals.sh" \
        "o/r" "autonomous-agent" "agent/" "$tmp_dir/union-log.jsonl" 2>"$tmp_dir/stderr")"

assert_eq "gather-landing-refusals.sh exits with a valid JSON array" \
  "array" "$(jq -r 'type' <<<"$out" 2>/dev/null || echo "not-json")"
assert_eq "only the reconciliation-refused, still-unreconciled, ours PRs are candidates, oldest refusal first" \
  "[201,207]" "$(jq -c '[.[].number]' <<<"$out")"

assert_eq "the candidate carries source, refused_at and reason" \
  '{"source":"landing-refusals","refused_at":"2026-08-24T02:00:00Z"}' \
  "$(jq -c '.[] | select(.number == 201) | {source, refused_at}' <<<"$out")"
assert_eq "  ... and every unreconciled comment, id/author/body" \
  '[{"id":5001,"author":"warwickallen","body":"Please fix the widget too."}]' \
  "$(jq -c '.[] | select(.number == 201) | [.comments[] | {id, author, body}]' <<<"$out")"
assert_eq "  ... assembled into body too, verbatim" "1" \
  "$(jq -r '.[] | select(.number == 201) | .body' <<<"$out" | grep -c "Please fix the widget too.")"
assert_eq "the ref is scoped to the unreconciled comment id" \
  "pr-201-landing-refusal-5001" \
  "$(jq -r '.[] | select(.number == 201) | .ref' <<<"$out")"

assert_eq "a draft PR is never a candidate" \
  "0" "$(jq '[.[] | select(.number == 202)] | length' <<<"$out")"
assert_eq "a human's own branch is never a candidate" \
  "0" "$(jq '[.[] | select(.number == 203)] | length' <<<"$out")"
assert_eq "no landing-refused event at all is never a candidate" \
  "0" "$(jq '[.[] | select(.number == 204)] | length' <<<"$out")"
assert_eq "a landing-refused event of a different class is never a candidate" \
  "0" "$(jq '[.[] | select(.number == 205)] | length' <<<"$out")"
assert_eq "a reconciliation-unreadable refusal is a candidate too, not only -unanswered" \
  "1" "$(jq '[.[] | select(.number == 207)] | length' <<<"$out")"

# --- The answered clause: the whole point --------------------------------
assert_eq "an already-reconciled refusal is not a candidate, on the strength of the live re-check" \
  "0" "$(jq '[.[] | select(.number == 206)] | length' <<<"$out")"
assert_eq "a live check that itself fails yields no candidate, never an 'unanswered' guess" \
  "0" "$(jq '[.[] | select(.number == 208)] | length' <<<"$out")"
assert_eq "…and says so on stderr rather than dropping it silently" \
  "1" "$(grep -c "could not confirm pr #208's unreconciled comments" "$tmp_dir/stderr")"

# --- tech_debt_branch_prefix: an explicit empty argument disables the td/
# namespace rather than defaulting back to it (the ${5-td/} shape) ---------
jq -nc --argjson p "$(pr_entry 300 td/TD99)" '[$p]' > "$tmp_dir/prlist.json"
: > "$tmp_dir/union-log.jsonl"
union_log_add "https://github.com/o/r/pull/300" "reconciliation-unanswered:…"
jq -nc '{"300": [{"event": "ready_for_review", "created_at": "2026-08-20T00:00:00Z"}]}' > "$tmp_dir/timeline.json"
jq -nc '{"300": [{"id": 9001, "created_at": "2026-08-21T00:00:00Z", "body": "…",
                   "user": {"login": "warwickallen", "type": "User"}}]}' > "$tmp_dir/comments.json"

default_out="$(LANDING_REFUSALS_GH="$tmp_dir/gh" "$SCRIPT_DIR/scripts/gather-landing-refusals.sh" \
  "o/r" "autonomous-agent" "agent/" "$tmp_dir/union-log.jsonl" 2>/dev/null)"
assert_eq "omitting tech_debt_branch_prefix defaults to td/, so a td/ branch is still a candidate" \
  "[300]" "$(jq -c '[.[].number]' <<<"$default_out")"

disabled_out="$(LANDING_REFUSALS_GH="$tmp_dir/gh" "$SCRIPT_DIR/scripts/gather-landing-refusals.sh" \
  "o/r" "autonomous-agent" "agent/" "$tmp_dir/union-log.jsonl" "" 2>/dev/null)"
assert_eq "an explicit empty tech_debt_branch_prefix disables the td/ namespace" \
  "[]" "$(jq -c '[.[].number]' <<<"$disabled_out")"

# --- A missing/unreadable union log yields no candidates, never a crash ----
empty_log_out="$(LANDING_REFUSALS_GH="$tmp_dir/gh" "$SCRIPT_DIR/scripts/gather-landing-refusals.sh" \
  "o/r" "autonomous-agent" "agent/" "$tmp_dir/no-such-log.jsonl" 2>/dev/null)"
assert_eq "a missing union log yields no candidates, exit 0" "[]" "$empty_log_out"

# --- Fails safe -------------------------------------------------------------
empty_out="$(LANDING_REFUSALS_GH="$tmp_dir/gh-missing" "$SCRIPT_DIR/scripts/gather-landing-refusals.sh" \
  "o/r" "autonomous-agent" "agent/" "$tmp_dir/union-log.jsonl" 2>/dev/null)"
assert_eq "an unreachable gh degrades to an empty array, exit 0" "[]" "$empty_out"

# --- Usage: slug and union-log are both required ---------------------------
usage_rc=0
"$SCRIPT_DIR/scripts/gather-landing-refusals.sh" >/dev/null 2>&1 || usage_rc=$?
assert_eq "no arguments at all is a usage error" "64" "$usage_rc"
usage_rc2=0
"$SCRIPT_DIR/scripts/gather-landing-refusals.sh" "o/r" >/dev/null 2>&1 || usage_rc2=$?
assert_eq "a repo with no union-log argument is a usage error too" "64" "$usage_rc2"

if (( failures > 0 )); then
  printf '\n%d assertion(s) FAILED\n' "$failures"
  exit 1
fi
printf '\nAll assertions passed.\n'
