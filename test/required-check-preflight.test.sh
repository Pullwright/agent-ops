#!/usr/bin/env bash
#
# test/required-check-preflight.test.sh — regression test for
# lib/required-check-preflight.sh (issue #1543): the deterministic pre-flight
# half of the fix — name the owner-act prerequisite the moment a pull
# request's own diff deletes, or edits away, the workflow job producing a
# required status check, at pull-request time rather than waiting for a
# downstream item to happen to block on it (the PR #1503/#1540 precedent).
#
# `gh` is stubbed through REQUIRED_CHECK_PREFLIGHT_GH, the same convention
# test/review-gate.test.sh's stub uses — every call this file's functions
# make is `gh api …`, so the stub only needs to answer that one subcommand.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/required-check-preflight.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/required-check-preflight.sh
. "$SCRIPT_DIR/lib/required-check-preflight.sh"

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

SLUG="Pullwright/agent-ops"
BASE="main"
NUMBER="1503"
PR_URL="https://github.com/Pullwright/agent-ops/pull/1503"

# --- The stub gh --------------------------------------------------------------
# State lives in files:
#   $tmp_dir/rules-branches.json  `repos/<slug>/rules/branches/<base>`'s
#                                 payload; "ERROR" makes the call fail.
#   $tmp_dir/files.json           `repos/<slug>/pulls/<n>/files`'s payload;
#                                 "ERROR" makes the call fail.
#   $tmp_dir/base-sha.txt         the `.base.sha` `pulls/<n>` reports.
#   $tmp_dir/head-sha.txt         the `.head.sha` `pulls/<n>` reports.
#   $tmp_dir/content-<ref>__<path>  a workflow file's raw content at REF, PATH
#                                 with every `/` and `:` turned into `_` —
#                                 absent means "this path did not exist at
#                                 this ref" (a 404, the shape a deleted file's
#                                 "new" side and a newly-added file's "old"
#                                 side both take); "ERROR" makes the call fail
#                                 outright instead.
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
[[ "$1" == "api" ]] || exit 1
shift

path=""
jqfilter=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--jq" ]]; then
    jqfilter="$arg"
  elif [[ "$arg" == repos/* ]]; then
    path="$arg"
  fi
  prev="$arg"
done

case "$path" in
  */rules/branches/*)
    content="$(cat "$d/rules-branches.json" 2>/dev/null || printf '[]')"
    [[ "$content" == "ERROR" ]] && exit 1
    printf '%s' "$content"
    exit 0
    ;;
  */pulls/*/files)
    content="$(cat "$d/files.json" 2>/dev/null || printf '[]')"
    [[ "$content" == "ERROR" ]] && exit 1
    printf '%s' "$content"
    exit 0
    ;;
  */pulls/*)
    base_sha="$(cat "$d/base-sha.txt" 2>/dev/null || printf 'basesha')"
    head_sha="$(cat "$d/head-sha.txt" 2>/dev/null || printf 'headsha')"
    [[ "$base_sha" == "ERROR" || "$head_sha" == "ERROR" ]] && exit 1
    payload="$(jq -nc --arg b "$base_sha" --arg h "$head_sha" '{base:{sha:$b},head:{sha:$h}}')"
    if [[ -n "$jqfilter" ]]; then
      jq -r "$jqfilter" <<<"$payload"
    else
      printf '%s' "$payload"
    fi
    exit 0
    ;;
  */contents/*)
    rest="${path#*contents/}"
    file_path="${rest%%\?ref=*}"
    ref="${rest#*\?ref=}"
    key="$(printf '%s' "$ref:$file_path" | tr '/:' '__')"
    content_file="$d/content-$key"
    [[ -f "$content_file" ]] || exit 1
    raw="$(cat "$content_file")"
    [[ "$raw" == "ERROR" ]] && exit 1
    encoded="$(printf '%s' "$raw" | base64 -w0)"
    payload="$(jq -nc --arg c "$encoded" '{content: $c}')"
    jq -r "$jqfilter" <<<"$payload"
    exit 0
    ;;
esac
exit 1
STUB
chmod +x "$tmp_dir/gh"
export REQUIRED_CHECK_PREFLIGHT_GH="$tmp_dir/gh"

set_rules() { printf '%s' "$1" >"$tmp_dir/rules-branches.json"; }
set_files() { printf '%s' "$1" >"$tmp_dir/files.json"; }
set_base_sha() { printf '%s' "$1" >"$tmp_dir/base-sha.txt"; }
set_head_sha() { printf '%s' "$1" >"$tmp_dir/head-sha.txt"; }
set_content() {  # set_content REF PATH CONTENT
  local key
  key="$(printf '%s' "$1:$2" | tr '/:' '__')"
  printf '%s' "$3" >"$tmp_dir/content-$key"
}

# --- _required_check_preflight_job_ids ----------------------------------------

WORKFLOW_WITH_REGISTER='name: CI
on: [pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
  register:
    runs-on: ubuntu-latest
    steps:
      - run: echo register
'

WORKFLOW_WITHOUT_REGISTER='name: CI
on: [pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
'

out="$(_required_check_preflight_job_ids <<<"$WORKFLOW_WITH_REGISTER" | sort | tr '\n' ',')"
assert_eq "extracts every top-level job id" "build,register," "$out"

out="$(_required_check_preflight_job_ids <<<"$WORKFLOW_WITHOUT_REGISTER" | sort | tr '\n' ',')"
assert_eq "a workflow with one job extracts just that one" "build," "$out"

out="$(_required_check_preflight_job_ids <<<"name: CI
on: [pull_request]
")"
assert_eq "a workflow with no jobs: key at all extracts nothing" "" "$out"

# --- required_check_preflight_findings ----------------------------------------
# The PR #1503/#1540 precedent: a branch deletes
# .github/workflows/tech-debt-register.yml, whose `register` job is a
# required context on the base branch's own ruleset.

set_rules '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CI"},{"context":"register"}]}}]'
set_base_sha 'BASESHA'
set_head_sha 'HEADSHA'
set_files '[{"status":"removed","filename":".github/workflows/tech-debt-register.yml"}]'
set_content 'BASESHA' '.github/workflows/tech-debt-register.yml' "$WORKFLOW_WITH_REGISTER"

out="$(required_check_preflight_findings "$SLUG" "$BASE" "$NUMBER")"
assert_eq "a deleted workflow whose job is a required context is found" \
  "$(printf 'register\t.github/workflows/tech-debt-register.yml')" "$out"

# A modified (not deleted) workflow that simply drops the job is the same
# finding, from the diff between the old and new content at each side's own
# commit.
set_files '[{"status":"modified","filename":".github/workflows/tech-debt-register.yml"}]'
set_content 'BASESHA' '.github/workflows/tech-debt-register.yml' "$WORKFLOW_WITH_REGISTER"
set_content 'HEADSHA' '.github/workflows/tech-debt-register.yml' "$WORKFLOW_WITHOUT_REGISTER"
out="$(required_check_preflight_findings "$SLUG" "$BASE" "$NUMBER")"
assert_eq "a modified workflow that drops the job is found the same way" \
  "$(printf 'register\t.github/workflows/tech-debt-register.yml')" "$out"

# A rename that keeps the job produces nothing — the job is still there,
# reading the rename's own previous_filename for the old side.
set_files '[{"status":"renamed","filename":".github/workflows/ci.yml","previous_filename":".github/workflows/tech-debt-register.yml"}]'
set_content 'BASESHA' '.github/workflows/tech-debt-register.yml' "$WORKFLOW_WITH_REGISTER"
set_content 'HEADSHA' '.github/workflows/ci.yml' "$WORKFLOW_WITH_REGISTER"
out="$(required_check_preflight_findings "$SLUG" "$BASE" "$NUMBER")"
assert_eq "a rename that keeps every job finds nothing" "" "$out"

# A file outside .github/workflows/ is never inspected, whatever it does.
set_files '[{"status":"removed","filename":"scripts/build.sh"}]'
out="$(required_check_preflight_findings "$SLUG" "$BASE" "$NUMBER")"
assert_eq "a non-workflow file is ignored" "" "$out"

# A deleted workflow whose job is not a required context at all finds nothing.
set_rules '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CI"}]}}]'
set_files '[{"status":"removed","filename":".github/workflows/tech-debt-register.yml"}]'
set_content 'BASESHA' '.github/workflows/tech-debt-register.yml' "$WORKFLOW_WITH_REGISTER"
out="$(required_check_preflight_findings "$SLUG" "$BASE" "$NUMBER")"
assert_eq "a deleted job that was never a required context finds nothing" "" "$out"

# An unreadable ruleset, changed-file list, or content read is a fact about
# this node or GitHub, not the pull request — it must never itself surface a
# finding.
set_rules '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"register"}]}}]'
set_files '[{"status":"removed","filename":".github/workflows/tech-debt-register.yml"}]'
set_content 'BASESHA' '.github/workflows/tech-debt-register.yml' "$WORKFLOW_WITH_REGISTER"

set_rules 'ERROR'
out="$(required_check_preflight_findings "$SLUG" "$BASE" "$NUMBER")"
assert_eq "an unreadable ruleset finds nothing rather than blocking" "" "$out"
set_rules '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"register"}]}}]'

set_files 'ERROR'
out="$(required_check_preflight_findings "$SLUG" "$BASE" "$NUMBER")"
assert_eq "an unreadable changed-file list finds nothing rather than blocking" "" "$out"
set_files '[{"status":"removed","filename":".github/workflows/tech-debt-register.yml"}]'

set_base_sha 'ERROR'
out="$(required_check_preflight_findings "$SLUG" "$BASE" "$NUMBER")"
assert_eq "an unreadable base sha finds nothing rather than blocking" "" "$out"
set_base_sha 'BASESHA'

out="$(required_check_preflight_findings "" "$BASE" "$NUMBER")"
assert_eq "no slug given finds nothing" "" "$out"
out="$(required_check_preflight_findings "$SLUG" "" "$NUMBER")"
assert_eq "no base branch given finds nothing" "" "$out"
out="$(required_check_preflight_findings "$SLUG" "$BASE" "not-a-number")"
assert_eq "a non-numeric pull request number finds nothing" "" "$out"

# --- required_check_preflight_escalate ----------------------------------------
# A thin body-composition wrapper around create_escalation_issue (lib/
# enabler.sh); stubbed here exactly as test/crash-loop-escalate.test.sh and
# test/approver.test.sh already stub it, since the real one needs `gh` and
# network for a call this file's own tests must not make.

STUB_CREATE_CALLS_FILE="$tmp_dir/create-calls"
: >"$STUB_CREATE_CALLS_FILE"
create_escalation_issue() {
  jq -nc --arg repo "$1" --arg item "$2" --arg label "$3" --arg title "$4" \
    --arg body "$(cat "$5" 2>/dev/null)" \
    '{repo:$repo,item:$item,label:$label,title:$title,body:$body}' >>"$STUB_CREATE_CALLS_FILE"
  printf '2001\thttps://github.com/Pullwright/agent-ops/issues/2001'
}

enabler_escalation_label="enabler-escalation"
cycle_id="20260914T235350Z-ockham-container-6107"
node_name="ockham-container"

findings="$(printf 'register\t.github/workflows/tech-debt-register.yml')"
out="$(required_check_preflight_escalate "$SLUG" "1543" "$PR_URL" "$BASE" "$findings")"
assert_eq "a finding files the escalation, returning create_escalation_issue's own result" \
  "2001	https://github.com/Pullwright/agent-ops/issues/2001" "$out"
assert_eq "  ... exactly one call" "1" "$(wc -l <"$STUB_CREATE_CALLS_FILE" | tr -d ' ')"

call="$(tail -n1 "$STUB_CREATE_CALLS_FILE")"
assert_eq "  ... against the right repo" "$SLUG" "$(jq -r '.repo' <<<"$call")"
assert_eq "  ... with the escalation label" "enabler-escalation" "$(jq -r '.label' <<<"$call")"
assert_contains "  ... the title names the missing context" "register" "$(jq -r '.title' <<<"$call")"
assert_contains "  ... the title names the base branch" "main" "$(jq -r '.title' <<<"$call")"
assert_contains "  ... the title names the pull request" "$PR_URL" "$(jq -r '.title' <<<"$call")"
assert_contains "  ... the body names the context" "\`register\`" "$(jq -r '.body' <<<"$call")"
assert_contains "  ... the body names the producing file" "tech-debt-register.yml" "$(jq -r '.body' <<<"$call")"
assert_contains "  ... the body names the ruleset edit as the ask" "required_status_checks" "$(jq -r '.body' <<<"$call")"
assert_contains "  ... the body cites issue #1543" "#1543" "$(jq -r '.body' <<<"$call")"

: >"$STUB_CREATE_CALLS_FILE"
out="$(required_check_preflight_escalate "$SLUG" "1543" "$PR_URL" "$BASE" "")"; rc=$?
assert_eq "no findings files nothing" "" "$out"
assert_eq "  ... and returns non-zero" "1" "$rc"
assert_eq "  ... create_escalation_issue is never called" "0" "$(wc -l <"$STUB_CREATE_CALLS_FILE" | tr -d ' ')"

printf '\n'
if (( failures )); then
  printf 'required-check-preflight.test.sh: %d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'required-check-preflight.test.sh: all assertions passed\n'
