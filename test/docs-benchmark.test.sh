#!/usr/bin/env bash
#
# test/docs-benchmark.test.sh — the documentation benchmark's questions, its
# dry run, and its readers of a run's transcripts (component 24a,
# agent-ops#2086).
#
# The benchmark itself is never run here: every real run spends tokens, and a
# test that launched `claude` would be an agent launching an agent. What can
# be proven without a model is proven:
#
#   the questions
#     test/docs-benchmark/questions.jsonl holds at least 48 records, at least
#     eight for each of the six readers, every field present, and every source
#     followed to a file, heading or label that exists. The validator is then
#     shown each kind of defect, so a check that passes vacuously cannot.
#
#   the dry run
#     lists every question and the two commands each would run, launches
#     nothing (`claude` is a stub that records being called) and writes
#     nothing.
#
#   the grader's verdict
#     read from a grading transcript recorded from a real run, and from
#     variants of it rewritten here: prose or a fence around the JSON, a failed
#     fact, a verdict that contradicts its own facts, a reply of the wrong
#     shape, an error result and a stream torn before its result event.
#
#   the answering run's figures
#     tool calls and tokens read from an answering transcript recorded from a
#     real run (tool results trimmed to keep the fixture small), against the
#     figures that run reported.
#
# Run directly: ./test/docs-benchmark.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/docs-benchmark.sh
. "$SCRIPT_DIR/lib/docs-benchmark.sh"

QUESTIONS="$SCRIPT_DIR/test/docs-benchmark/questions.jsonl"
FIXTURES="$SCRIPT_DIR/test/fixtures/docs-benchmark"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual: %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

assert_ge() {
  local desc="$1" floor="$2" actual="$3"
  if [[ "$actual" =~ ^[0-9]+$ ]] && (( actual >= floor )); then
    printf 'ok   - %s (%s)\n' "$desc" "$actual"
  else
    printf 'FAIL - %s\n     expected at least: %s\n     actual: %s\n' "$desc" "$floor" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# --- The questions ----------------------------------------------------------

problems="$(docs_benchmark_check_questions "$QUESTIONS" "$SCRIPT_DIR")"
rc=$?
assert_eq "questions.jsonl validates, with every source followed" "0" "$rc"
[[ -z "$problems" ]] || printf '     %s\n' "${problems//$'\n'/$'\n'     }"

assert_ge "at least 48 questions" 48 "$(jq -s 'length' "$QUESTIONS")"
for reader in "${DOCS_BENCHMARK_READERS[@]}"; do
  assert_ge "at least eight questions for $reader" 8 \
    "$(jq -s --arg r "$reader" '[.[] | select(.reader == $r)] | length' "$QUESTIONS")"
done
assert_eq "the readers are exactly the six" \
  "$(printf '%s\n' "${DOCS_BENCHMARK_READERS[@]}" | sort | jq -R . | jq -sc .)" \
  "$(jq -s -c '[.[].reader] | unique' "$QUESTIONS")"

# The validator, shown each defect against a fixture tree of its own, so that
# these cases do not move when the real documents do.
root="$tmp_dir/root"
mkdir -p "$root/docs"
cat >"$root/README.md" <<'EOF'
# Product

## Pausing everything

Some prose.

```bash
# Not a heading
```
EOF
cat >"$root/docs/SPEC.md" <<'EOF'
## Requirements

7. A requirement.
   7a. A nested one.

## Acceptance checks

8. A check.
EOF
good='{"id":"operator-01","reader":"operator","question":"How do I stop it?","answer":"Like this.","sources":[{"path":"README.md","heading":"Pausing everything"},{"path":"docs/SPEC.md","requirement":"7a"},{"path":"docs/SPEC.md","check":"8"}],"must_mention":["this"]}'

check_record_lines() {  # check_record_lines LINE... — validate these lines against $root
  printf '%s\n' "$@" >"$tmp_dir/q.jsonl"
  docs_benchmark_check_questions "$tmp_dir/q.jsonl" "$root"
}

expect_problem() {  # expect_problem DESC NEEDLE LINE...
  local desc="$1" needle="$2" out rc; shift 2
  out="$(check_record_lines "$@")"
  rc=$?
  assert_eq "$desc: rejected" "1" "$rc"
  assert_contains "$desc: named" "$needle" "$out"
}

mutate() { jq -c "$1" <<<"$good"; }

out="$(check_record_lines "$good")"
assert_eq "a well-formed record with followed sources passes" "0:" "$?:$out"
expect_problem "a missing field" "operator-01: missing field answer" "$(mutate 'del(.answer)')"
expect_problem "an unknown field" "operator-01: unknown field notes" "$(mutate '.notes = "x"')"
expect_problem "an unknown reader" 'reader "manager" is not one of the six' \
  "$(mutate '.reader = "manager" | .id = "manager-01"')"
expect_problem "an id not of the form <reader>-NN" "id is not <reader>-NN" "$(mutate '.id = "operator-1"')"
expect_problem "an id under another reader" "id does not start with its reader" "$(mutate '.id = "evaluator-01"')"
expect_problem "an empty question" "question is empty" "$(mutate '.question = ""')"
expect_problem "no required facts" "must_mention is not a non-empty list" "$(mutate '.must_mention = []')"
expect_problem "an empty required fact" "must_mention holds an empty" "$(mutate '.must_mention = ["x", ""]')"
expect_problem "no sources" "sources is not a non-empty list" "$(mutate '.sources = []')"
expect_problem "a source with two locators" "needs exactly one of heading, requirement or check" \
  "$(mutate '.sources = [{"path": "README.md", "heading": "Pausing everything", "requirement": "7"}]')"
expect_problem "a source with no locator" "needs exactly one of heading, requirement or check" \
  "$(mutate '.sources = [{"path": "README.md"}]')"
expect_problem "a path outside the repository" "is not repository-relative" \
  "$(mutate '.sources = [{"path": "../README.md", "heading": "Pausing everything"}]')"
expect_problem "a path that does not exist" "source path docs/GONE.md does not exist" \
  "$(mutate '.sources = [{"path": "docs/GONE.md", "heading": "Pausing everything"}]')"
expect_problem "a heading that does not exist" "heading Pausing not found in README.md" \
  "$(mutate '.sources = [{"path": "README.md", "heading": "Pausing"}]')"
expect_problem "a comment inside a code fence is not a heading" "heading Not a heading not found" \
  "$(mutate '.sources = [{"path": "README.md", "heading": "Not a heading"}]')"
expect_problem "a requirement label that does not exist" "requirement 9 not found in docs/SPEC.md" \
  "$(mutate '.sources = [{"path": "docs/SPEC.md", "requirement": "9"}]')"
expect_problem "an acceptance check cited as a requirement" "requirement 8 not found" \
  "$(mutate '.sources = [{"path": "docs/SPEC.md", "requirement": "8"}]')"
expect_problem "a requirement cited as an acceptance check" "check 7 not found" \
  "$(mutate '.sources = [{"path": "docs/SPEC.md", "check": "7"}]')"
expect_problem "a line that is not JSON" "line 2: not a JSON object" "$good" "not json"
expect_problem "a line that is JSON but not an object" "line 2: not a JSON object" "$good" "[1]"
expect_problem "a duplicate id" "operator-01: duplicate id" "$good" "$good"

# --- The dry run ------------------------------------------------------------

stub_dir="$tmp_dir/bin"
mkdir -p "$stub_dir"
cat >"$stub_dir/claude" <<EOF
#!/usr/bin/env bash
echo called >>"$tmp_dir/claude-called"
exit 1
EOF
chmod +x "$stub_dir/claude"

reviews_before="$(ls -A "$SCRIPT_DIR/docs/reviews" 2>/dev/null)"
dry="$(PATH="$stub_dir:$PATH" "$SCRIPT_DIR/scripts/docs-benchmark.sh" --dry-run 2>&1)"
rc=$?
assert_eq "--dry-run exits 0" "0" "$rc"
missing=""
while IFS= read -r id; do
  grep -q "^$id \[" <<<"$dry" || missing+=" $id"
done < <(jq -r '.id' "$QUESTIONS")
assert_eq "--dry-run lists every question" "" "$missing"
assert_eq "--dry-run prints an answering command for every question" \
  "$(jq -s 'length' "$QUESTIONS")" \
  "$(grep -c "^  answer: cd <clone of main> && claude -p --model $DOCS_BENCHMARK_MODEL --tools Read,Grep,Glob " <<<"$dry")"
assert_eq "--dry-run prints a grading command for every question" \
  "$(jq -s 'length' "$QUESTIONS")" \
  "$(grep -c "^  grade:  cd <empty directory> && claude -p --model $DOCS_BENCHMARK_GRADER_MODEL --tools '' " <<<"$dry")"
assert_contains "--dry-run keeps the person's own settings out" "--setting-sources project --strict-mcp-config" "$dry"
assert_eq "--dry-run launches nothing" "no" "$([[ -e "$tmp_dir/claude-called" ]] && echo yes || echo no)"
assert_eq "--dry-run writes no report" "$reviews_before" "$(ls -A "$SCRIPT_DIR/docs/reviews" 2>/dev/null)"

first_id="$(head -n 1 "$QUESTIONS" | jq -r '.id')"
dry_one="$(PATH="$stub_dir:$PATH" "$SCRIPT_DIR/scripts/docs-benchmark.sh" --dry-run --only "$first_id" v1.0 2>&1)"
assert_eq "--dry-run --only lists that one question" "1" "$(grep -c '^[a-z-]*-[0-9][0-9] \[' <<<"$dry_one")"
assert_contains "--dry-run --only names it" "$first_id [" "$dry_one"
assert_contains "--dry-run names the ref it would clone" "<clone of v1.0>" "$dry_one"

PATH="$stub_dir:$PATH" "$SCRIPT_DIR/scripts/docs-benchmark.sh" --dry-run --only no-such-id >/dev/null 2>&1
assert_eq "--only with an unknown id is a usage error" "64" "$?"
PATH="$stub_dir:$PATH" "$SCRIPT_DIR/scripts/docs-benchmark.sh" --frobnicate >/dev/null 2>&1
assert_eq "an unknown option is a usage error" "64" "$?"
PATH="$stub_dir:$PATH" "$SCRIPT_DIR/scripts/docs-benchmark.sh" --dry-run main extra >/dev/null 2>&1
assert_eq "a second ref is a usage error" "64" "$?"

# --- The grader's verdict, from a recorded transcript ----------------------

question="$(cat "$FIXTURES/question.json")"
must="$(jq -c '.must_mention' <<<"$question")"
n_facts="$(jq 'length' <<<"$must")"
recorded="$FIXTURES/grade.stream.jsonl"

verdict="$(docs_benchmark_parse_verdict "$recorded" "$must")"
assert_eq "the recorded grading is graded" "graded" "$(jq -r '.status' <<<"$verdict")"
assert_eq "it judged every required fact" "$n_facts" "$(jq -r '.facts_total' <<<"$verdict")"
assert_eq "its facts are the question's, in order" "$must" "$(jq -c '[.facts[].fact]' <<<"$verdict")"
assert_eq "it passed, every fact present" "true:$n_facts" \
  "$(jq -r '"\(.passed):\(.facts_present)"' <<<"$verdict")"
assert_eq "its overall verdict agrees with its facts" "pass:true" \
  "$(jq -r '"\(.grader_verdict):\(.verdict_consistent)"' <<<"$verdict")"
assert_eq "its reasoning is kept, overall and per fact" "true" \
  "$(jq '(.reasoning | type == "string" and length > 0) and all(.facts[]; .reasoning | type == "string" and length > 0)' <<<"$verdict")"

# with_reply FILE TEXT — the recorded stream with its result event's text replaced.
with_reply() {
  jq -c --arg text "$2" 'if .type == "result" then .result = $text else . end' "$recorded" >"$1"
}
# The recorded reply as one compact object, however the grader formatted it.
reply="$(jq -r 'select(.type == "result") | .result' "$recorded")"
object="$(jq -nc --arg t "$reply" '$t | capture("(?<o>\\{[\\s\\S]*\\})").o | fromjson')"

with_reply "$tmp_dir/fenced.jsonl" "Here is my grading.

\`\`\`json
$object
\`\`\`

I hope this helps — “thanks”."
assert_eq "a reply fenced and wrapped in prose is still read" "graded:true" \
  "$(docs_benchmark_parse_verdict "$tmp_dir/fenced.jsonl" "$must" | jq -r '"\(.status):\(.passed)"')"

with_reply "$tmp_dir/multibyte.jsonl" "Grading — résumé of the answer: $object"
assert_eq "multi-byte prose before the object does not shift it" "graded" \
  "$(docs_benchmark_parse_verdict "$tmp_dir/multibyte.jsonl" "$must" | jq -r '.status')"

with_reply "$tmp_dir/one-missing.jsonl" "$(jq -c '.facts[0].present = false | .verdict = "fail"' <<<"$object")"
v="$(docs_benchmark_parse_verdict "$tmp_dir/one-missing.jsonl" "$must")"
assert_eq "one missing fact fails the answer" "false:$(( n_facts - 1 )):true" \
  "$(jq -r '"\(.passed):\(.facts_present):\(.verdict_consistent)"' <<<"$v")"

with_reply "$tmp_dir/inconsistent.jsonl" "$(jq -c '.facts[0].present = false | .verdict = "pass"' <<<"$object")"
v="$(docs_benchmark_parse_verdict "$tmp_dir/inconsistent.jsonl" "$must")"
assert_eq "the facts decide when the overall verdict contradicts them" "false:false" \
  "$(jq -r '"\(.passed):\(.verdict_consistent)"' <<<"$v")"

with_reply "$tmp_dir/short.jsonl" "$(jq -c '.facts |= .[1:]' <<<"$object")"
v="$(docs_benchmark_parse_verdict "$tmp_dir/short.jsonl" "$must")"
assert_eq "too few facts judged is ungraded" "ungraded" "$(jq -r '.status' <<<"$v")"
assert_contains "and says how many" "judged $(( n_facts - 1 )) facts, but the question has $n_facts" "$(jq -r '.error' <<<"$v")"

with_reply "$tmp_dir/stringly.jsonl" "$(jq -c '.facts[0].present = "yes"' <<<"$object")"
assert_eq "a fact judged with a non-boolean is ungraded" "ungraded" \
  "$(docs_benchmark_parse_verdict "$tmp_dir/stringly.jsonl" "$must" | jq -r '.status')"

with_reply "$tmp_dir/prose.jsonl" "The answer looks right to me."
v="$(docs_benchmark_parse_verdict "$tmp_dir/prose.jsonl" "$must")"
assert_eq "a reply with no JSON is ungraded" "ungraded" "$(jq -r '.status' <<<"$v")"
assert_eq "and keeps what the grader said" "The answer looks right to me." "$(jq -r '.raw' <<<"$v")"

jq -c 'if .type == "result" then .is_error = true | .subtype = "error_during_execution" else . end' \
  "$recorded" >"$tmp_dir/errored.jsonl"
assert_contains "an error result is ungraded, naming it" "error_during_execution" \
  "$(docs_benchmark_parse_verdict "$tmp_dir/errored.jsonl" "$must" | jq -r '.error')"

grep -v '"type":"result"' "$recorded" >"$tmp_dir/torn.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"te' >>"$tmp_dir/torn.jsonl"
assert_contains "a stream torn before its result event is ungraded" "no result event" \
  "$(docs_benchmark_parse_verdict "$tmp_dir/torn.jsonl" "$must" | jq -r '.error')"

# --- The answering run's figures, from a recorded transcript ---------------

answer_stream="$FIXTURES/answer.stream.jsonl"
run="$(docs_benchmark_run_record "$DOCS_BENCHMARK_MODEL" "$answer_stream")"
assert_eq "the recorded answer is read" "true" "$(jq '.result | type == "string" and length > 0' <<<"$run")"
assert_eq "its tool calls are counted" "12" "$(jq -r '.tool_calls' <<<"$run")"
assert_eq "per tool" '{"Grep":8,"Read":4}' "$(jq -c '.tool_calls_by_tool' <<<"$run")"
assert_eq "its tokens are the metering record's" '{"input":1076,"output":4025,"cache_creation":31109,"cache_read":327455}' "$(jq -c '.metering.tokens' <<<"$run")"
assert_eq "it met no permission refusal" "0" "$(jq -r '.permission_denials' <<<"$run")"
assert_eq "it reported no error" "null" "$(jq -r '.error' <<<"$run")"

grep -v '"type":"result"' "$answer_stream" >"$tmp_dir/answer-torn.jsonl"
run="$(docs_benchmark_run_record "$DOCS_BENCHMARK_MODEL" "$tmp_dir/answer-torn.jsonl")"
assert_eq "an answering stream with no result event says so" "no result event in the stream" \
  "$(jq -r '.error' <<<"$run")"
assert_eq "and still counts the calls it made" "12" "$(jq -r '.tool_calls' <<<"$run")"

if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
