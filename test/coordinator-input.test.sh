#!/usr/bin/env bash
#
# test/coordinator-input.test.sh — self-contained regression test for
# lib/coordinator-input.sh (agent-ops#641,
# docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 4i).
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/coordinator-input.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/coordinator-input.sh
. "$SCRIPT_DIR/lib/coordinator-input.sh"

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
assert_true() { assert_eq "$1" "true" "$2"; }

# A repo array with NUM issues, each carrying a BODY-byte body and NCOMMENTS
# comments of CBYTES each. Priority cycles through the four bands and
# `updated_at` through the month, so the last rung's keep-order has something
# to order by.
mk_repos() {  # <num> <body-bytes> <ncomments> <comment-bytes>
  python3 -c '
import json, sys
n, b, c, cb = (int(x) for x in sys.argv[1:5])
issues = [{
  "source": "issues", "ref": str(i), "number": i,
  "url": "https://github.com/o/r/issues/%d" % i, "title": "issue %d" % i,
  "priority": ["Low", "Medium", "High", "Urgent"][i % 4], "priority_set": True,
  "labels": ["enhancement"], "author": "someone",
  "created_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-08-%02dT00:00:00Z" % (i % 28 + 1),
  "body": "B" * b,
  "comments": [{"author": "someone", "created_at": "2026-08-01T00:00:00Z",
                "body": "C" * cb} for _ in range(c)],
} for i in range(1, n + 1)]
print(json.dumps([{"slug": "o/r", "sources": ["issues"], "issues": issues, "tech_debt": []}]))
' "$@"
}

fit() { coordinator_fit_bands "$1"; }   # repos on stdin, {repos, fit} on stdout

# --- An input already inside its allowance is handed back untouched, and
#     says so. This is the ordinary cycle and it must cost one measurement,
#     not a rung. ---
small="$(mk_repos 3 200 1 200)"
out="$(fit 5000000 <<<"$small")"
assert_eq "an input inside the allowance reports applied: false" \
  "false" "$(jq -r '.fit.applied' <<<"$out")"
assert_eq "an input inside the allowance is returned byte-identical" \
  "$(jq -S . <<<"$small")" "$(jq -S '.repos' <<<"$out")"

# --- The bound off (0) and a malformed budget both mean "change nothing".
#     A misread budget that stripped a cycle's candidates would be a worse
#     failure than the overflow this module exists to catch. ---
big="$(mk_repos 20 4000 4 4000)"
assert_eq "a budget of 0 disables the fit entirely" \
  "false" "$(fit 0 <<<"$big" | jq -r '.fit.applied')"
assert_eq "a non-numeric budget disables the fit entirely" \
  "false" "$(fit "not-a-number" <<<"$big" | jq -r '.fit.applied')"
assert_eq "a stdin document that is not an array answers with an empty array" \
  "[]" "$(fit 100 <<<'{"not": "an array"}' | jq -c '.repos')"

# --- Over the allowance: the result actually fits, and it fits because prose
#     was shed rather than candidates. Every entry is still selectable. ---
out="$(fit 60000 <<<"$big")"
assert_true "an oversized input is trimmed to inside its allowance" \
  "$(jq '.fit.bytes_after <= .fit.budget' <<<"$out")"
assert_eq "trimming to fit drops no entries" \
  "0" "$(jq -r '.fit.entries_dropped' <<<"$out")"
assert_eq "every candidate survives the trim" \
  "20" "$(jq -r '.repos[0].issues | length' <<<"$out")"
assert_eq "the identity fields selection runs on are never shed" \
  "1 1 https://github.com/o/r/issues/1 issue 1 Medium 2026-08-02T00:00:00Z" \
  "$(jq -r '.repos[0].issues[0] | "\(.ref) \(.number) \(.url) \(.title) \(.priority) \(.updated_at)"' <<<"$out")"

# --- A cut names itself: how many bytes went, and where the whole of it is.
#     Without the URL the Co-Ordinator cannot honour the prompt's duty to read
#     a trimmed entry live before selecting it. ---
assert_true "a truncated body ends in an elision marker naming the byte counts" \
  "$(jq -r '.repos[0].issues[0].body | test("…\\[Script: elided [0-9]+ of [0-9]+ bytes")' <<<"$out")"
assert_true "the elision marker names the entry's own url" \
  "$(jq -r '.repos[0].issues[0].body | test("read it whole at https://github.com/o/r/issues/1\\]")' <<<"$out")"
assert_true "a truncated body keeps its opening, not its end" \
  "$(jq -r '.repos[0].issues[0].body | startswith("BBBB")' <<<"$out")"

# --- Dropped comments are counted on the entry rather than vanishing, and it
#     is the *newest* that are kept: the prompt treats the latest comment that
#     contradicts the body as the current instruction. ---
threads="$(python3 -c '
import json
cs = [{"author": "a", "created_at": "2026-08-%02dT00:00:00Z" % (i + 1),
       "body": "comment-%d " % i + "x" * 3000} for i in range(10)]
print(json.dumps([{"slug": "o/r", "sources": ["issues"], "tech_debt": [], "issues": [
  {"source": "issues", "ref": "1", "number": 1, "url": "https://github.com/o/r/issues/1",
   "title": "t", "priority": "High", "updated_at": "2026-08-10T00:00:00Z",
   "body": "b", "comments": cs}]}]))')"
out="$(fit 12000 <<<"$threads")"
kept="$(jq -r '.repos[0].issues[0].comments | length' <<<"$out")"
elided="$(jq -r '.repos[0].issues[0].comments_elided' <<<"$out")"
assert_eq "dropped comments are counted, not silently lost" "10" "$(( kept + elided ))"
assert_true "the comments kept are the newest ones" \
  "$(jq -r '.repos[0].issues[0].comments[-1].body | startswith("comment-9")' <<<"$out")"

# --- The last rung, and only the last rung, drops entries — keeping the
#     highest Priority band first and the freshest thread within a band, and
#     recording the count on the repo entry the Co-Ordinator reads. ---
many="$(mk_repos 12 100 0 0)"
out="$(fit 1500 <<<"$many")"
assert_true "an allowance no amount of prose-shedding can meet drops entries" \
  "$(jq '.fit.entries_dropped > 0' <<<"$out")"
assert_eq "the entries kept are the highest-priority ones" \
  "Urgent" "$(jq -r '[.repos[0].issues[].priority] | unique | join(",")' <<<"$out")"
assert_true "within a band the freshest thread is kept first" \
  "$(jq '[.repos[0].issues[].updated_at] | . == (sort | reverse)' <<<"$out")"
assert_eq "dropped entries are counted on the repo entry" \
  "12" "$(jq -r '(.repos[0].issues | length) + .repos[0].issues_elided' <<<"$out")"

# --- Tech-debt is kept freshest-first when capped (agent-ops#1379). The band
#     carries no Priority field, and the ascending-by-number order the cap
#     used to keep meant the ~90 newest `pw::type:tech-debt` issues — the
#     fresh defects — were the ones dropped on every capped cycle. The fixture
#     is built so that number order and freshness order disagree: the
#     lowest-numbered issues are the stalest. ---
td_many="$(python3 -c '
import json
td = [{"source": "tech-debt", "ref": str(i), "number": i,
       "url": "https://github.com/o/r/issues/%d" % i, "title": "td %d" % i,
       "labels": ["pw::type:tech-debt"],
       "updated_at": "2026-09-%02dT00:00:00Z" % (12 + i),
       "body": "B" * 100, "comments": []} for i in range(1, 13)]
print(json.dumps([{"slug": "o/r", "sources": ["tech-debt"], "issues": [], "tech_debt": td}]))')"
out="$(fit 1500 <<<"$td_many")"
assert_true "a capped tech-debt band drops entries" "$(jq '.fit.entries_dropped > 0' <<<"$out")"
assert_true "the tech-debt entries kept are the freshest threads, not the lowest-numbered" \
  "$(jq '[.repos[0].tech_debt[].updated_at] | . == (sort | reverse) and (.[0] == "2026-09-24T00:00:00Z")' <<<"$out")"
assert_eq "…which here means the highest-numbered issues survive the cap" \
  "12" "$(jq -r '[.repos[0].tech_debt[].number] | max' <<<"$out")"
assert_eq "dropped tech-debt entries are counted on the repo entry" \
  "12" "$(jq -r '(.repos[0].tech_debt | length) + .repos[0].tech_debt_elided' <<<"$out")"

# --- Order is only ever disturbed when entries are actually dropped: a
#     trimmed cycle must differ from an untrimmed one in prose and nothing
#     else, or a reader comparing two cycles' inputs cannot tell what moved. ---
out="$(fit 60000 <<<"$big")"
assert_eq "a prose-only trim leaves the gatherer's own entry order alone" \
  "$(jq -c '[.[0].issues[].ref]' <<<"$big")" \
  "$(jq -c '[.repos[0].issues[].ref]' <<<"$out")"

# --- The tail of the prose ladder (agent-ops#1379): beneath `0:0:1000` sit a
#     short-opening rung (`0:0:300`) and an identity-only rung (`0:0:0`), and
#     the entry caps begin only past them — so a backlog whose identities fit
#     is never capped. Pinned by position, because `lib/pager-invariants.sh`
#     hard-codes the first cap's rung (11) as a constant of this ladder. ---
assert_eq "the ladder has ten prose rungs" "10" "${#COORDINATOR_INPUT_TIERS[@]}"
assert_eq "rung 9 is the short-opening rung" "0:0:300" "${COORDINATOR_INPUT_TIERS[8]}"
assert_eq "rung 10 is the identity-only rung" "0:0:0" "${COORDINATOR_INPUT_TIERS[9]}"
# 12 entries of 400-byte bodies: rung 8 leaves the bodies whole, rung 9 keeps
# 300 bytes of each, and only rung 10 replaces each body with its own marker —
# so an allowance only the identities fit lands exactly on rung 10 with
# nothing dropped, where the old ladder would have gone straight to a cap.
# (A body shorter than the ~120-byte marker is *not* made smaller by the
# marker, which is why the bodies here are longer than one: the ladder is
# re-measured at every rung, so that edge costs a tiny-body input nothing
# but a rung it would not have fitted on anyway.)
bodies="$(mk_repos 12 400 0 0)"
r8="$(coordinator_apply_rung 0 0 1000 <<<"$bodies" | coordinator_rendered_bytes)"
r10="$(coordinator_apply_rung 0 0 0 <<<"$bodies" | coordinator_rendered_bytes)"
assert_true "the identity-only rung renders smaller than the title-paragraph rung" \
  "$( (( r10 < r8 )) && echo true || echo false )"
out="$(fit "$(( r10 + 10 ))" <<<"$bodies")"
assert_eq "an allowance only identities fit lands on rung 10, dropping nothing" \
  "10 0 null" "$(jq -r '"\(.fit.rung) \(.fit.entries_dropped) \(.fit.entries_max)"' <<<"$out")"
assert_eq "every entry survives the identity-only rung" "12" "$(jq -r '.repos[0].issues | length' <<<"$out")"
assert_true "an identity-only entry's body is its own elision marker naming its url" \
  "$(jq -r '.repos[0].issues[0].body | test("^…\\[Script: elided all [0-9]+ bytes .* read it whole at https://github.com/o/r/issues/1\\]$")' <<<"$out")"
assert_eq "…and its identity fields are intact" \
  "1 1 https://github.com/o/r/issues/1 issue 1 Medium 2026-08-02T00:00:00Z" \
  "$(jq -r '.repos[0].issues[0] | "\(.ref) \(.number) \(.url) \(.title) \(.priority) \(.updated_at)"' <<<"$out")"
# More entries than the loosest cap keeps, so that the cap actually removes
# some and the first rung past the trims is the one that fits.
crowd="$(mk_repos 70 400 0 0)"
r10="$(coordinator_apply_rung 0 0 0 <<<"$crowd" | coordinator_rendered_bytes)"
out="$(fit "$(( r10 - 10 ))" <<<"$crowd")"
assert_eq "a few bytes short of the identities is the first entry cap, rung 11, and it drops" \
  "11 64 6" "$(jq -r '"\(.fit.rung) \(.fit.entries_max) \(.fit.entries_dropped)"' <<<"$out")"
opening="$(python3 -c '
import json
issues = [{"source": "issues", "ref": "1", "number": 1, "url": "https://github.com/o/r/issues/1",
           "title": "t", "priority": "Medium", "updated_at": "2026-08-01T00:00:00Z",
           "body": "O" * 2000, "comments": []}]
print(json.dumps([{"slug": "o/r", "sources": ["issues"], "issues": issues, "tech_debt": []}]))')"
r9="$(coordinator_apply_rung 0 0 300 <<<"$opening" | coordinator_rendered_bytes)"
out="$(fit "$r9" <<<"$opening")"
assert_eq "an allowance a 300-byte opening fits lands on rung 9" "9 300" \
  "$(jq -r '"\(.fit.rung) \(.fit.body_bytes)"' <<<"$out")"
assert_true "…and the body keeps a 300-byte opening ahead of its marker" \
  "$(jq -r '.repos[0].issues[0].body | startswith("O" * 300) and (startswith("O" * 301) | not)' <<<"$out")"

# --- The fleet's own 2026-09-23 shape (agent-ops#1379): 317 entries — 310 in
#     one repo, 251 of them tech-debt — with the titles, labels, bodies and
#     threads the gather actually carried, against the allowance the fitted
#     terms leave once the refinements and blocked bands are identities. The
#     old ladder landed at rung 10–11 dropping 246–278 entries every cycle.
#     Built as a fixture rather than replayed, so the test needs no live
#     data; its per-entry byte cost matches the measured ~875 bytes at
#     identity and ~1190 at a 300-byte opening. ---
live_shape="$(python3 -c '
import json
def entry(src, i, nc):
    return {"source": src, "ref": str(i), "number": i,
            "url": "https://github.com/Pullwright/agent-ops/issues/%d" % i,
            "title": ("issue %d: " % i) + "a title of the length the fleet actually files, naming the defect and its symptom",
            "labels": (["pw::type:tech-debt", "refined"] if src == "tech-debt" else ["refined"]),
            "author": "pullwright-author", "created_at": "2026-09-%02dT00:00:00Z" % (i % 23 + 1),
            "updated_at": "2026-09-%02dT%02d:00:00Z" % (i % 23 + 1, i % 24),
            "body": ("B" * 80 + "\n") * 40,
            "comments": [{"author": "warwickallen", "created_at": "2026-09-11T00:00:00Z", "body": ("C" * 80 + "\n") * 30} for _ in range(nc)],
            "expensive_gather": {"fresh": True, "gathered_at": "2026-09-23T17:19:25Z"}}
agent_ops = {"slug": "Pullwright/agent-ops", "sources": ["issues", "tech-debt"],
             "issues": [dict(entry("issues", i, 2), priority=["Low", "Medium", "High"][i % 3], priority_set=True) for i in range(1000, 1059)],
             "tech_debt": [entry("tech-debt", i, 1) for i in range(1100, 1351)]}
poetic = {"slug": "Poetic-Poems/poetic", "sources": ["issues", "tech-debt"],
          "issues": [dict(entry("issues", i, 1), priority="Medium", priority_set=False) for i in range(200, 202)],
          "tech_debt": [entry("tech-debt", i, 1) for i in range(300, 305)]}
print(json.dumps([agent_ops, poetic]))')"
assert_eq "the fixture is the fleet's 317-entry shape" "317" \
  "$(jq '[.[] | (.issues | length) + (.tech_debt | length)] | add' <<<"$live_shape")"
# 500,000 less the fitted event's own prompt (119,483), scaffold (9,920) and
# claimed (3) terms, less the two bands as this change leaves them on that
# day's ledger (refinements 37,025; blocked 22,936).
live_allowance=$(( 500000 - 119483 - 9920 - 3 - 37025 - 22936 ))
out="$(fit "$live_allowance" <<<"$live_shape")"
assert_eq "the 2026-09-23 shape settles on a trim rung, not a cap" "10 0 null" \
  "$(jq -r '"\(.fit.rung) \(.fit.entries_dropped) \(.fit.entries_max)"' <<<"$out")"
assert_true "…inside its allowance" "$(jq '.fit.bytes_after <= .fit.budget' <<<"$out")"
assert_eq "…with every one of the 251 tech-debt issues still a candidate" "251" \
  "$(jq '.repos[0].tech_debt | length' <<<"$out")"
two_hundred="$(jq -c '.[0].tech_debt |= .[0:140]' <<<"$live_shape")"
out="$(fit "$live_allowance" <<<"$two_hundred")"
assert_eq "the issue's own ~200-entry shape settles on the short-opening rung" "9 0" \
  "$(jq -r '"\(.fit.rung) \(.fit.entries_dropped)"' <<<"$out")"

# --- An allowance even one entry cannot meet is reported, not hidden. The
#     stage will be refused by the API this cycle; the union log has to carry
#     the cause rather than an exit code (agent-ops#641). ---
out="$(fit 200 <<<"$many")"
assert_eq "an unmeetable allowance reports fits: false" \
  "false" "$(jq -r '.fit.fits' <<<"$out")"
assert_true "an unmeetable allowance still hands back a usable array" \
  "$(jq '(.repos[0].issues | length) > 0' <<<"$out")"

# --- Requirement 4g: the repo array is fleet state and unbounded, so it must
#     never travel in argv. The first draft of coordinator_fit_report bound it
#     as `--argjson`, and this input — genuinely past MAX_ARG_STRLEN (131072)
#     — is what caught it: `jq: Argument list too long`, an empty result, and
#     a caller that would have fallen back to the unfitted array and died on
#     the window anyway. ---
past_cap="$(mk_repos 60 3000 0 0)"
if (( $(printf '%s' "$past_cap" | wc -c) <= 131072 )); then
  printf 'FAIL - the argv-cap pin is no longer past MAX_ARG_STRLEN (%s bytes)\n' \
    "$(printf '%s' "$past_cap" | wc -c)"
  failures=$(( failures + 1 ))
else
  printf 'ok   - the argv-cap pin is genuinely past MAX_ARG_STRLEN (%s bytes)\n' \
    "$(printf '%s' "$past_cap" | wc -c)"
fi
err="$(fit 5000000 <<<"$past_cap" 2>&1 >/dev/null)"
assert_eq "an over-cap array that already fits reaches jq on stdin, not argv" \
  "" "$err"
out="$(fit 5000000 <<<"$past_cap" 2>/dev/null)"
assert_eq "…and comes back whole" \
  "60" "$(jq -r '.repos[0].issues | length' <<<"$out")"
err="$(fit 100000 <<<"$past_cap" 2>&1 >/dev/null)"
assert_eq "an over-cap array that must be trimmed reaches jq on stdin too" \
  "" "$err"
out="$(fit 100000 <<<"$past_cap" 2>/dev/null)"
assert_true "…and the trimmed result is inside its allowance" \
  "$(jq '.fit.bytes_after <= .fit.budget' <<<"$out")"

# --- The tech-debt band is trimmed on the same terms as issues: since
#     agent-ops#875 it is the other array carrying a whole *issue thread* per
#     entry — body and comments both — so the comment rungs must reach it too,
#     not only the body ones. ---
td="$(python3 -c '
import json
print(json.dumps([{"slug": "o/r", "sources": ["tech-debt"], "issues": [], "tech_debt": [
  {"source": "tech-debt", "ref": "42", "number": 42,
   "title": "t", "url": "https://github.com/o/r/issues/42",
   "body": "F" * 40000,
   "comments": [{"author": "a", "created_at": "2026-08-08T00:00:00Z", "body": "C" * 20000}
                for _ in range(8)]}]}]))')"
out="$(fit 9000 <<<"$td")"
assert_true "an oversized tech-debt body is trimmed" \
  "$(jq '.fit.bytes_after <= .fit.budget' <<<"$out")"
assert_true "a trimmed tech-debt body names its own issue url" \
  "$(jq -r '.repos[0].tech_debt[0].body | test("read it whole at https://github.com/o/r/issues/42\\]")' <<<"$out")"
assert_eq "a trimmed tech-debt entry keeps its ref" \
  "42" "$(jq -r '.repos[0].tech_debt[0].ref' <<<"$out")"
assert_true "a tech-debt entry's comment thread is trimmed too, like an issue's" \
  "$(jq '(.repos[0].tech_debt[0].comments | length) < 8
         or ((.repos[0].tech_debt[0].comments[0].body | length) < 20000)' <<<"$out")"

# --- The other bands are left alone. Their bodies are what the prompt
#     requires pasted verbatim into a work order, they are bounded by the
#     number of open pull requests rather than by history, and trimming them
#     would buy a few kilobytes at the cost of the Implementer's context. ---
others="$(python3 -c '
import json
big = "R" * 40000
print(json.dumps([{"slug": "o/r", "sources": ["review-feedback"], "issues": [], "tech_debt": [],
  "review_feedback": [{"source": "review-feedback", "ref": "pr-1-review-1",
                       "url": "https://github.com/o/r/pull/1", "body": big}],
  "merge_conflicts": [{"source": "merge-conflicts", "ref": "pr-2-conflict-a",
                       "url": "https://github.com/o/r/pull/2", "body": big}]}]))')"
out="$(fit 1000 <<<"$others")"
assert_eq "a review-feedback body is never trimmed" \
  "40000" "$(jq -r '.repos[0].review_feedback[0].body | length' <<<"$out")"
assert_eq "a merge-conflicts body is never trimmed" \
  "40000" "$(jq -r '.repos[0].merge_conflicts[0].body | length' <<<"$out")"

# --- The detail line a reader gets off the union log says what was done, in
#     words, without them having to open this file to decode a rung number. ---
out="$(fit 60000 <<<"$big")"
detail="$(coordinator_fit_detail "$(jq -c '.fit' <<<"$out")")"
assert_true "the log detail names the allowance it fitted into" \
  "$(grep -qF -- "-byte allowance" <<<"$detail" && echo true || echo false)"
assert_true "the log detail spells out what the rung trimmed" \
  "$(grep -qE 'newest [0-9]+ comment\(s\) at [0-9]+ bytes each, bodies at [0-9]+ bytes' <<<"$detail" && echo true || echo false)"
assert_eq "an untrimmed cycle produces no detail line at all" \
  "" "$(coordinator_fit_detail "$(fit 5000000 <<<"$small" | jq -c '.fit')")"
assert_true "a cycle that could not be fitted says so in the detail" \
  "$(grep -qF "still does not fit" <<<"$(coordinator_fit_detail "$(fit 200 <<<"$many" | jq -c '.fit')")" && echo true || echo false)"

# --- coordinator_fit_trimmed_items / coordinator_fit_trim_refusal_reason
#     (agent-ops#683): the exemption set behind requirement 34e's fourth
#     refusal and requirement 3x's matching completeness exception. ---

# The mass-flag shape: the title-paragraph rung cuts every candidate's body to
# a title-level fragment, and every one of them is now trimmed — with every
# entry still present (budget 5000 lands on rung 8, `0:0:1000`, without
# forcing the rungs below it, none of which drops a candidate either).
many_small="$(mk_repos 3 5000 2 5000)"
bottom="$(fit 5000 <<<"$many_small")"
assert_eq "the fixture actually reaches the title-paragraph rung with no entries dropped" \
  "8 0" "$(jq -r '"\(.fit.rung) \(.fit.entries_dropped)"' <<<"$bottom")"
trimmed="$(coordinator_fit_trimmed_items <<<"$(jq -c '.repos' <<<"$bottom")")"
assert_eq "the title-paragraph rung marks every candidate trimmed" "3" "$(jq 'length' <<<"$trimmed")"
identity="$(fit "$(( $(coordinator_apply_rung 0 0 0 <<<"$many_small" | coordinator_rendered_bytes) + 5 ))" <<<"$many_small")"
assert_eq "the identity-only rung is reached with no entries dropped either" \
  "10 0" "$(jq -r '"\(.fit.rung) \(.fit.entries_dropped)"' <<<"$identity")"
assert_eq "…and it too marks every candidate trimmed, so 34e's refusal still covers it" "3" \
  "$(jq 'length' <<<"$(coordinator_fit_trimmed_items <<<"$(jq -c '.repos' <<<"$identity")")")"
assert_eq "each mark carries the item's own repo, ref and source" \
  "$(jq -cS 'sort_by(.item)' <<<'[{"repo":"o/r","item":"1","source":"issues"},{"repo":"o/r","item":"2","source":"issues"},{"repo":"o/r","item":"3","source":"issues"}]')" \
  "$(jq -cS 'sort_by(.item)' <<<"$trimmed")"

# An input the fit never touches (inside its allowance) marks nothing.
untouched="$(fit 5000000 <<<"$small")"
assert_eq "an untrimmed cycle's fitted array marks nothing trimmed" "0" \
  "$(jq 'length' <<<"$(coordinator_fit_trimmed_items <<<"$(jq -c '.repos' <<<"$untouched")")")"

# A cycle trimmed only a little (a middle rung) marks only the entries that
# actually exceeded that rung's caps — not every entry in the band.
mixed="$(python3 -c '
import json
issues = [
  {"source": "issues", "ref": "1", "url": "https://github.com/o/r/issues/1",
   "title": "t", "priority": "Medium", "updated_at": "2026-08-01T00:00:00Z",
   "body": "tiny", "comments": []},
  {"source": "issues", "ref": "2", "url": "https://github.com/o/r/issues/2",
   "title": "t", "priority": "Medium", "updated_at": "2026-08-02T00:00:00Z",
   "body": "B" * 30000, "comments": []},
]
print(json.dumps([{"slug": "o/r", "sources": ["issues"], "issues": issues, "tech_debt": []}]))')"
mixed_out="$(fit 3000 <<<"$mixed")"
mixed_trimmed="$(coordinator_fit_trimmed_items <<<"$(jq -c '.repos' <<<"$mixed_out")")"
assert_eq "only the entry that actually exceeded the rung is marked trimmed" \
  '["2"]' "$(jq -c '[.[].item]' <<<"$mixed_trimmed")"

# The ordinary shape in this repository: a two-line issue body whose
# acceptance criteria live in a Refiner's comment. A middle rung clips that
# comment and leaves the body alone, so neither the body marker nor
# `comments_elided` (the comment was kept, only shortened) is what says the
# entry was trimmed — the marker inside the comment's own body is.
comment_only="$(python3 -c '
import json
issues = [
  {"source": "issues", "ref": "5", "url": "https://github.com/o/r/issues/5",
   "title": "t", "priority": "Medium", "updated_at": "2026-08-01T00:00:00Z",
   "body": "two lines, no criteria",
   "comments": [{"author": "refiner", "created_at": "2026-08-02T00:00:00Z",
                 "body": "C" * 9000}]},
]
print(json.dumps([{"slug": "o/r", "sources": ["issues"], "issues": issues, "tech_debt": []}]))')"
comment_only_out="$(fit 3000 <<<"$comment_only")"
assert_eq "the fixture clips the comment while leaving the body alone" \
  "false false" \
  "$(jq -r '.repos[0].issues[0] | "\(.body | contains("[Script: elided")) \(has("comments_elided"))"' <<<"$comment_only_out")"
assert_eq "an entry whose comment prose alone was clipped is still marked trimmed" \
  '["5"]' \
  "$(jq -c '[.[].item]' <<<"$(coordinator_fit_trimmed_items <<<"$(jq -c '.repos' <<<"$comment_only_out")")")"

# The refusal function itself: refuses only an entry naming a repo+item the
# trimmed set carries, regardless of source, and names the rung.
entry_trimmed='{"repo":"o/r","item":"2","source":"issues","reason":"x","missing":"y","evidence":"z"}'
reason="$(coordinator_fit_trim_refusal_reason "$entry_trimmed" "$mixed_trimmed" "3")"
rc=$?
assert_eq "a report naming a trimmed item is refused" "1" "$rc"
assert_true "the refusal names the rung" "$(grep -qF 'rung 3' <<<"$reason" && echo true || echo false)"

entry_untouched='{"repo":"o/r","item":"1","source":"issues","reason":"x","missing":"y","evidence":"z"}'
coordinator_fit_trim_refusal_reason "$entry_untouched" "$mixed_trimmed" "3"
assert_eq "a report naming an untrimmed item is not refused" "0" "$?"

assert_eq "an entry naming no repo/item is never refused" "0" \
  "$(coordinator_fit_trim_refusal_reason '{}' "$mixed_trimmed" "3" >/dev/null 2>&1; echo $?)"
assert_eq "an empty trimmed set refuses nothing" "0" \
  "$(coordinator_fit_trim_refusal_reason "$entry_trimmed" '[]' "3" >/dev/null 2>&1; echo $?)"
assert_eq "malformed trimmed JSON degrades to refusing nothing" "0" \
  "$(coordinator_fit_trim_refusal_reason "$entry_trimmed" "not json" "3" >/dev/null 2>&1; echo $?)"

echo
if (( failures == 0 )); then
  echo "All coordinator-input assertions passed."
  exit 0
else
  echo "$failures coordinator-input assertion(s) FAILED."
  exit 1
fi
