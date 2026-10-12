#!/usr/bin/env bash
#
# test/refile.test.sh — regression test for lib/refile.sh, requirement 36f's
# reach (c): the shape check on an act's paths, the per-path contents read
# and how its answers are classified, the two-direction verification, the
# whole-act check, the act itself — filing the copy and closing the
# original — and the act-time sequence that orders those reads, against a
# stubbed `gh`.
#
# `gh` is a function, shadowing the binary, dispatching on its first two
# words and recording every call: the contents reads answer from a table of
# present and unreadable paths, the original issue is canned, and each read,
# search and write can be made to fail on its own. Nothing else is stood in
# for.
#
# Runs under `set -euo pipefail`, the options agent-cycle.sh runs the real
# callers under (review of PR #2344): a library function that fails in a way
# `set -e` would turn into an aborted cycle fails here too, so every status
# below is read through `|| rc=$?`, never a bare `$?`.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/refile.test.sh
#
# Exit status is 0 iff every assertion passed.

# The reasons lib/refile.sh prints are Markdown, so the expected strings
# below carry literal backticks.
# shellcheck disable=SC2016

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/pipeline-marker.sh
. "$REPO_ROOT/lib/pipeline-marker.sh"
# shellcheck source=lib/refile.sh
. "$REPO_ROOT/lib/refile.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
cycle_dir="$tmp_dir"
node_name="node-1"
cycle_id="cycle-1"

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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:                 %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

count() {  # count PATTERN FILE -> matching lines, 0 included
  grep -c -E "$1" "$2" || true
}

# --- gh stub ---------------------------------------------------------------
GH_CALLS="$tmp_dir/gh_calls"
GH_PRESENT=""              # "repo path" lines that read as present
GH_UNKNOWN=""              # "repo path" lines whose read fails for a non-404 reason
GH_ORIG_STATE="OPEN"
GH_ORIG_LABELS='[{"name":"pw::type:tech-debt"},{"name":"blocked"}]'
GH_ORIG_BODY=$'## The gap\n\nBlocked-by: #516\nThe body. See #480 and acme/widgets#12, then https://github.com/x/y/issues/3#issuecomment-9.\n  Blocked-by: #2\nFixes #7\nMore.'
GH_ORIG_FAIL=""
GH_LIST_EXISTING='[]'
GH_LIST_FAIL=""
GH_CREATE_FAIL=""
GH_CREATE_FAIL_LABELLED=""
GH_CREATE_URL="https://github.com/pipe/ops/issues/900"
GH_CLOSE_FAIL=""
CREATED_BODY="$tmp_dir/created-body.md"
CLOSE_COMMENT="$tmp_dir/close-comment.txt"
reset_gh() {
  : > "$GH_CALLS"
  rm -f "$CREATED_BODY" "$CLOSE_COMMENT"
  GH_PRESENT=""; GH_UNKNOWN=""; GH_ORIG_STATE="OPEN"
  GH_ORIG_LABELS='[{"name":"pw::type:tech-debt"},{"name":"blocked"}]'
  GH_ORIG_FAIL=""; GH_LIST_EXISTING='[]'; GH_LIST_FAIL=""
  GH_CREATE_FAIL=""; GH_CREATE_FAIL_LABELLED=""; GH_CLOSE_FAIL=""
}
# shellcheck disable=SC2317  # invoked only through lib/refile.sh
gh() {
  printf '%s\n' "$*" >> "$GH_CALLS"
  local prev="" a
  case "$1 $2" in
    "api repos/"*)
      local target="${2#repos/}" repo path
      repo="${target%%/contents/*}"; path="${target#*/contents/}"
      if grep -qxF "$repo $path" <<<"$GH_UNKNOWN"; then
        printf 'gh: error connecting to api.github.com\n' >&2; return 1
      fi
      if grep -qxF "$repo $path" <<<"$GH_PRESENT"; then
        printf '{"type":"file"}'; return 0
      fi
      printf 'gh: Not Found (HTTP 404)\n' >&2; return 1 ;;
    "issue view")
      [[ -z "$GH_ORIG_FAIL" ]] || return 1
      jq -nc --arg s "$GH_ORIG_STATE" --argjson l "$GH_ORIG_LABELS" --arg b "$GH_ORIG_BODY" \
        '{title: "A misfiled title", body: $b, state: $s, labels: $l,
          url: "https://github.com/acme/widgets/issues/515"}' ;;
    "issue list")
      [[ -z "$GH_LIST_FAIL" ]] || { printf 'gh: API rate limit exceeded (HTTP 403)\n' >&2; return 1; }
      printf '%s' "$GH_LIST_EXISTING" ;;
    "issue create")
      for a in "$@"; do [[ "$prev" == "--body-file" ]] && cp "$a" "$CREATED_BODY"; prev="$a"; done
      [[ -z "$GH_CREATE_FAIL" ]] || return 1
      if [[ -n "$GH_CREATE_FAIL_LABELLED" && "$*" == *"--label"* ]]; then return 1; fi
      printf '%s\n' "$GH_CREATE_URL" ;;
    "issue close")
      for a in "$@"; do [[ "$prev" == "--comment" ]] && printf '%s' "$a" > "$CLOSE_COMMENT"; prev="$a"; done
      [[ -z "$GH_CLOSE_FAIL" ]] || return 1 ;;
    *) return 0 ;;
  esac
}

# ============================================================================
# refile_paths_normalise: shape before any read
# ============================================================================
rc=0; out="$(refile_paths_normalise '["b/x.sh","a/y.md","b/x.sh"]')" || rc=$?
assert_eq "normalise: a plain list passes" "0" "$rc"
assert_eq "normalise: ...de-duplicated and sorted" '["a/y.md","b/x.sh"]' "$out"
for bad in '[]' 'null' '"a"' '[1]' '["a",1]' '["/abs"]' '["a/../b"]' '["a/.."]' '["./a"]' '["a/./b"]' \
           '["."]' '[".."]' '["a//b"]' '["a/"]' '["a b"]' '["-x"]' '[""]' '["lib/a.sh\n"]'; do
  rc=0; out="$(refile_paths_normalise "$bad")" || rc=$?
  assert_eq "normalise: $bad is refused" "1" "$rc"
done
rc=0; out="$(refile_paths_normalise '["lib/a.sh\nlib/b.sh"]')" || rc=$?
assert_eq "normalise: a path carrying a newline is refused as one path, not checked as two" "1" "$rc"
assert_contains "normalise: ...and the reason shows it whole" '"lib/a.sh\nlib/b.sh" is not a plain' "$out"
rc=0; out="$(refile_paths_normalise '[".github/workflows/build.yml",".shellcheckrc",".claude/settings.json","a/.hidden","x.y/z-1_2"]')" || rc=$?
assert_eq "normalise: a leading dot — a dotfile or a dot-directory — is a plain path" "0" "$rc"
assert_contains "normalise: ...carried as given" '".github/workflows/build.yml"' "$out"
REFILE_PATHS_MAX=2
rc=0; out="$(refile_paths_normalise '["a","b","c"]')" || rc=$?
assert_eq "normalise: more than the cap is refused" "1" "$rc"
assert_contains "normalise: ...naming the cap" "names 3 paths, more than the 2" "$out"
REFILE_PATHS_MAX=20

# ============================================================================
# refile_path_state: one read, three answers
# ============================================================================
reset_gh
GH_PRESENT="pipe/ops lib/x.sh"
GH_UNKNOWN="pipe/ops lib/z.sh"
assert_eq "state: a success is present" "present" "$(refile_path_state pipe/ops lib/x.sh)"
assert_eq "state: an HTTP 404 is absent" "absent" "$(refile_path_state pipe/ops lib/y.sh)"
assert_eq "state: any other failure is unknown" "unknown" "$(refile_path_state pipe/ops lib/z.sh)"
assert_contains "state: the read is one contents call at the default branch, for the object media type" \
  "api repos/pipe/ops/contents/lib/x.sh -H Accept: application/vnd.github.object+json" "$(cat "$GH_CALLS")"

# ============================================================================
# refile_paths_verify: absent where filed, present in the pipeline repo
# ============================================================================
reset_gh
GH_PRESENT=$'pipe/ops lib/x.sh\npipe/ops lib/y.sh'
rc=0; out="$(refile_paths_verify acme/widgets pipe/ops '["lib/x.sh","lib/y.sh"]')" || rc=$?
assert_eq "verify: absent where filed and present in the pipeline repo holds" "0" "$rc"
assert_eq "verify: ...and says nothing" "" "$out"
assert_eq "verify: two reads per path" "4" "$(wc -l < "$GH_CALLS" | tr -d ' ')"

GH_PRESENT=$'acme/widgets lib/x.sh\npipe/ops lib/x.sh\npipe/ops lib/y.sh'
: > "$GH_CALLS"
rc=0; out="$(refile_paths_verify acme/widgets pipe/ops '["lib/x.sh","lib/y.sh"]')" || rc=$?
assert_eq "verify: a path that exists where the item was filed is established false" "1" "$rc"
assert_contains "verify: ...naming the path and that repository" \
  '`lib/x.sh` exists in acme/widgets' "$out"
assert_eq "verify: ...on its first read, with no further read made" "1" \
  "$(wc -l < "$GH_CALLS" | tr -d ' ')"

GH_PRESENT="pipe/ops lib/x.sh"
rc=0; out="$(refile_paths_verify acme/widgets pipe/ops '["lib/x.sh","lib/y.sh"]')" || rc=$?
assert_eq "verify: a path absent from the pipeline repo too is established false" "1" "$rc"
assert_contains "verify: ...naming it" '`lib/y.sh` is absent from pipe/ops' "$out"

GH_PRESENT=$'pipe/ops lib/x.sh\npipe/ops lib/y.sh'
GH_UNKNOWN="acme/widgets lib/y.sh"
rc=0; out="$(refile_paths_verify acme/widgets pipe/ops '["lib/x.sh","lib/y.sh"]')" || rc=$?
assert_eq "verify: an unknown where the item was filed is 3 — not established either way" "3" "$rc"
assert_contains "verify: ...saying it could not establish it" \
  'could not establish whether `lib/y.sh` exists in acme/widgets' "$out"
GH_UNKNOWN="pipe/ops lib/y.sh"
rc=0; out="$(refile_paths_verify acme/widgets pipe/ops '["lib/x.sh","lib/y.sh"]')" || rc=$?
assert_eq "verify: an unknown in the pipeline repo is 3 too" "3" "$rc"
assert_contains "verify: ...naming that repository" 'exists in pipe/ops' "$out"

# ============================================================================
# refile_act_check: the whole act, at verdict time
# ============================================================================
reset_gh
GH_PRESENT="pipe/ops lib/x.sh"
crash_loop_repo="pipe/ops"
pager_repo=""
act='{"kind":"refile-to-pipeline-repo","paths":["lib/x.sh","lib/x.sh"],"extra":1}'
rc=0; out="$(refile_act_check acme/widgets 515 "$act")" || rc=$?
assert_eq "act check: an issue item with verified paths stands" "0" "$rc"
assert_eq "act check: ...normalised to kind and paths alone" \
  '{"kind":"refile-to-pipeline-repo","paths":["lib/x.sh"]}' "$out"
for shape in pr-363-abandoned-aaaaaaaaaaaa pr-9-review-77 TD26080001; do
  rc=0; out="$(refile_act_check acme/widgets "$shape" "$act")" || rc=$?
  assert_eq "act check: $shape is not an issue" "1" "$rc"
  assert_contains "act check: ...and the reason says so ($shape)" "is not an issue" "$out"
done
crash_loop_repo=""
rc=0; out="$(refile_act_check acme/widgets 515 "$act")" || rc=$?
assert_eq "act check: no pipeline repository configured refuses" "1" "$rc"
assert_contains "act check: ...naming the keys" "pager_repo" "$out"
crash_loop_repo="acme/widgets"
rc=0; out="$(refile_act_check acme/widgets 515 "$act")" || rc=$?
assert_eq "act check: the item's own repository as the target refuses" "1" "$rc"
assert_contains "act check: ...saying it is already where it belongs" "already where it belongs" "$out"
pager_repo="pipe/ops"; crash_loop_repo="other/repo"
rc=0; out="$(refile_act_check acme/widgets 515 "$act")" || rc=$?
assert_eq "act check: pager_repo is read ahead of crash_loop_repo" "0" "$rc"
pager_repo="null"; crash_loop_repo="pipe/ops"
assert_eq "pipeline repo: a literal null pager_repo falls back to crash_loop_repo" \
  "pipe/ops" "$(decision_pipeline_repo)"
pager_repo=""
rc=0; out="$(refile_act_check acme/widgets 515 '{"kind":"refile-to-pipeline-repo"}')" || rc=$?
assert_eq "act check: no paths refuses" "1" "$rc"
assert_contains "act check: ...saying so" "names no paths" "$out"
GH_PRESENT=""
rc=0; out="$(refile_act_check acme/widgets 515 "$act")" || rc=$?
assert_eq "act check: a path the pipeline repo lacks refuses" "1" "$rc"
assert_contains "act check: ...naming it" '`lib/x.sh` is absent from pipe/ops' "$out"
GH_UNKNOWN="acme/widgets lib/x.sh"
rc=0; out="$(refile_act_check acme/widgets 515 "$act")" || rc=$?
assert_eq "act check: a path that cannot be read is 3, for the caller to tell from a refusal" "3" "$rc"
assert_contains "act check: ...saying so" 'could not establish whether `lib/x.sh` exists in acme/widgets' "$out"

# ============================================================================
# refile_perform: file the copy, close the original
# ============================================================================
reset_gh
rc=0; out="$(refile_perform acme/widgets 515 pipe/ops '["lib/x.sh","prompts/p.md"]' \
        https://github.com/acme/widgets/issues/702)" || rc=$?
assert_eq "perform: both halves done returns 0" "0" "$rc"
assert_eq "perform: ...printing the copy's number and url" \
  $'900\thttps://github.com/pipe/ops/issues/900' "$out"
calls="$(cat "$GH_CALLS")"
assert_contains "perform: reads the original when not handed it" \
  "issue view 515 -R acme/widgets --json title,body,state,labels,url" "$calls"
assert_contains "perform: searches the pipeline repo for an earlier copy, every state, a page of 200" \
  'issue list -R pipe/ops --state all --search "acme/widgets#515" in:body --limit 200 --json number,url,body' "$calls"
assert_contains "perform: files the copy with the original's title" \
  "issue create -R pipe/ops --title A misfiled title --body-file" "$calls"
assert_contains "perform: ...carrying pw::type:tech-debt as the original did" \
  "--label pw::type:tech-debt" "$calls"
body="$(cat "$CREATED_BODY")"
assert_contains "perform: the copy carries the original body" "The body." "$body"
assert_contains "perform: ...and its later lines" "More." "$body"
assert_not_contains "perform: ...less every Blocked-by line" "Blocked-by:" "${body%%---*}"
assert_contains "perform: ...with a bare #n qualified to the original repository" \
  "See acme/widgets#480 and" "$body"
assert_contains "perform: ...an already qualified reference left alone" \
  "and acme/widgets#12, then" "$body"
assert_contains "perform: ...a url fragment left alone" \
  "issues/3#issuecomment-9." "$body"
assert_contains "perform: ...and a closing keyword no longer live here" \
  "Fixes acme/widgets#7" "$body"
assert_eq "perform: ...the body and the provenance section are separated by a rule" "1" \
  "$(grep -c '^---$' <<<"$body")"
assert_contains "perform: ...the marker" \
  "<!-- agent-ops:refiled-from repo=acme/widgets item=515 -->" "$body"
assert_contains "perform: ...the original's url" "https://github.com/acme/widgets/issues/515" "$body"
assert_contains "perform: ...the verified paths" '`lib/x.sh`, `prompts/p.md`' "$body"
assert_contains "perform: ...and the decision" "https://github.com/acme/widgets/issues/702" "$body"
assert_contains "perform: ...and says what was rewritten" 'now reads `acme/widgets#n`' "$body"
assert_contains "perform: closes the original as not planned" \
  "issue close 515 -R acme/widgets --reason not planned --comment" "$calls"
comment="$(cat "$CLOSE_COMMENT")"
assert_contains "perform: the closing comment names the copy" \
  "https://github.com/pipe/ops/issues/900" "$comment"
assert_contains "perform: ...and the decision" "https://github.com/acme/widgets/issues/702" "$comment"
assert_contains "perform: ...in the pipeline's voice" "autonomous pipeline" "$comment"
assert_contains "perform: ...says both halves reverse by hand, naming the copy to close" \
  "close https://github.com/pipe/ops/issues/900 and reopen this issue" "$comment"
assert_contains "perform: ...and that the log issue is no lever now" \
  "reopening the decision's log issue does nothing now the act has run" "$comment"
assert_contains "perform: ...with the pipeline comment marker" "actor=enabler-decide -->" "$comment"

reset_gh
orig_json="$(gh issue view 515 -R acme/widgets --json title,body,state,labels,url)"
: > "$GH_CALLS"
rc=0; out="$(refile_perform acme/widgets 515 pipe/ops '["lib/x.sh"]' u "$orig_json")" || rc=$?
assert_eq "perform: handed the original, it is not read again" "0" "$(count '^issue view' "$GH_CALLS")"
assert_eq "perform: ...and the act is performed from it" "0" "$rc"

reset_gh
GH_ORIG_LABELS='[{"name":"blocked"}]'
refile_perform acme/widgets 515 pipe/ops '["lib/x.sh"]' u >/dev/null
assert_not_contains "perform: no label is carried the original lacked" "--label" "$(cat "$GH_CALLS")"

reset_gh
GH_CREATE_FAIL_LABELLED=1
rc=0; out="$(refile_perform acme/widgets 515 pipe/ops '["lib/x.sh"]' u)" || rc=$?
assert_eq "perform: a failed labelled create is retried unlabelled" "0" "$rc"
assert_eq "perform: ...exactly one labelled and one unlabelled create" "2" "$(count '^issue create' "$GH_CALLS")"

reset_gh
GH_ORIG_STATE="CLOSED"
rc=0; out="$(refile_perform acme/widgets 515 pipe/ops '["lib/x.sh"]' u)" || rc=$?
assert_eq "perform: an original already closed, with no marked copy, is refused for good" "2" "$rc"
assert_contains "perform: ...saying someone acted first" "someone acted first" "$out"
assert_eq "perform: ...with no filing and no close" "0" "$(count '^issue (create|close)' "$GH_CALLS")"

reset_gh
GH_ORIG_STATE="CLOSED"
GH_LIST_EXISTING='[{"number":890,"url":"https://github.com/pipe/ops/issues/890","body":"<!-- agent-ops:refiled-from repo=acme/widgets item=515 -->"}]'
rc=0; out="$(refile_perform acme/widgets 515 pipe/ops '["lib/x.sh"]' u)" || rc=$?
assert_eq "perform: an original already closed whose marked copy exists is the act, performed" "0" "$rc"
assert_eq "perform: ...printing that copy" $'890\thttps://github.com/pipe/ops/issues/890' "$out"
assert_eq "perform: ...with no second filing and no second close" "0" "$(count '^issue (create|close)' "$GH_CALLS")"

reset_gh
GH_ORIG_STATE="CLOSED"
GH_LIST_FAIL=1
rc=0; out="$(refile_perform acme/widgets 515 pipe/ops '["lib/x.sh"]' u)" || rc=$?
assert_eq "perform: an original already closed whose copy cannot be searched for waits" "1" "$rc"
assert_contains "perform: ...saying so" "could not search pipe/ops for an earlier copy" "$out"

reset_gh
GH_ORIG_FAIL=1
rc=0; out="$(refile_perform acme/widgets 515 pipe/ops '["lib/x.sh"]' u)" || rc=$?
assert_eq "perform: an unreadable original waits" "1" "$rc"
assert_contains "perform: ...saying it could not read it" "could not read acme/widgets#515" "$out"

reset_gh
GH_LIST_FAIL=1
rc=0; out="$(refile_perform acme/widgets 515 pipe/ops '["lib/x.sh"]' u)" || rc=$?
assert_eq "perform: a search for an earlier copy that fails waits — it is not none" "1" "$rc"
assert_contains "perform: ...saying why" "might file it twice" "$out"
assert_eq "perform: ...with no filing" "0" "$(count '^issue create' "$GH_CALLS")"

reset_gh
GH_CREATE_FAIL=1
rc=0; out="$(refile_perform acme/widgets 515 pipe/ops '["lib/x.sh"]' u)" || rc=$?
assert_eq "perform: a failed create waits" "1" "$rc"
assert_contains "perform: ...saying so" "could not file the copy in pipe/ops" "$out"
assert_eq "perform: ...and does not close the original" "0" "$(count '^issue close' "$GH_CALLS")"

reset_gh
GH_CLOSE_FAIL=1
rc=0; out="$(refile_perform acme/widgets 515 pipe/ops '["lib/x.sh"]' u)" || rc=$?
assert_eq "perform: a failed close waits" "1" "$rc"
assert_contains "perform: ...naming the copy it did file" \
  "filed the copy as https://github.com/pipe/ops/issues/900 but could not close acme/widgets#515" "$out"

reset_gh
GH_LIST_EXISTING='[{"number":880,"url":"https://github.com/pipe/ops/issues/880","body":"other"},{"number":890,"url":"https://github.com/pipe/ops/issues/890","body":"x\n<!-- agent-ops:refiled-from repo=acme/widgets item=515 -->\ny"}]'
rc=0; out="$(refile_perform acme/widgets 515 pipe/ops '["lib/x.sh"]' u)" || rc=$?
assert_eq "perform: a copy already carrying the marker is reused" "0" "$rc"
assert_eq "perform: ...its number and url returned" \
  $'890\thttps://github.com/pipe/ops/issues/890' "$out"
assert_eq "perform: ...with no second filing" "0" "$(count '^issue create' "$GH_CALLS")"
assert_eq "perform: ...and the close still made" "1" "$(count '^issue close' "$GH_CALLS")"

# ============================================================================
# refile_act: the act-time sequence, in the order that spends the fewest reads
# ============================================================================
reset_gh
GH_PRESENT=$'pipe/ops lib/x.sh\npipe/ops prompts/p.md'
act='{"kind":"refile-to-pipeline-repo","paths":["lib/x.sh","prompts/p.md"]}'
rc=0; out="$(refile_act acme/widgets 515 "$act" https://github.com/acme/widgets/issues/702)" || rc=$?
assert_eq "act: an open original with verified paths is performed" "0" "$rc"
assert_eq "act: ...printing the copy" $'900\thttps://github.com/pipe/ops/issues/900' "$out"
assert_eq "act: the original is read first, before any contents read" \
  "issue view 515 -R acme/widgets --json title,body,state,labels,url" "$(head -n1 "$GH_CALLS")"
assert_eq "act: ...then the paths, two reads each" "4" "$(count '^api repos/' "$GH_CALLS")"
assert_eq "act: ...then the search, the filing and the close" "3" "$(count '^issue (list|create|close)' "$GH_CALLS")"

reset_gh
rc=0; out="$(refile_act acme/widgets pr-9-review-77 "$act" u)" || rc=$?
assert_eq "act: a shape that cannot stand is refused" "2" "$rc"
assert_eq "act: ...before any read at all" "0" "$(wc -l < "$GH_CALLS" | tr -d ' ')"

reset_gh
GH_ORIG_STATE="CLOSED"
rc=0; out="$(refile_act acme/widgets 515 "$act" u)" || rc=$?
assert_eq "act: an original someone closed is refused" "2" "$rc"
assert_eq "act: ...at the cost of one read of it and one search, and no contents read" "0" \
  "$(count '^api repos/' "$GH_CALLS")"
assert_eq "act: ...two calls in all" "2" "$(wc -l < "$GH_CALLS" | tr -d ' ')"

reset_gh
GH_PRESENT=$'pipe/ops lib/x.sh\npipe/ops prompts/p.md'
GH_UNKNOWN="acme/widgets prompts/p.md"
rc=0; out="$(refile_act acme/widgets 515 "$act" u)" || rc=$?
assert_eq "act: a path that cannot be read waits — a decision that stood is not retired over a failed read" "1" "$rc"
assert_contains "act: ...saying which" 'could not establish whether `prompts/p.md` exists in acme/widgets' "$out"
assert_eq "act: ...with no filing and no close" "0" "$(count '^issue (create|close)' "$GH_CALLS")"

reset_gh
GH_PRESENT=$'acme/widgets lib/x.sh\npipe/ops lib/x.sh\npipe/ops prompts/p.md'
rc=0; out="$(refile_act acme/widgets 515 "$act" u)" || rc=$?
assert_eq "act: a path that exists where the item was filed is refused" "2" "$rc"
assert_contains "act: ...naming it" '`lib/x.sh` exists in acme/widgets' "$out"

reset_gh
GH_ORIG_FAIL=1
rc=0; out="$(refile_act acme/widgets 515 "$act" u)" || rc=$?
assert_eq "act: an unreadable original waits" "1" "$rc"
assert_eq "act: ...after that one read" "1" "$(wc -l < "$GH_CALLS" | tr -d ' ')"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
