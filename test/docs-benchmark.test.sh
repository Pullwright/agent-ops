#!/usr/bin/env bash
#
# test/docs-benchmark.test.sh — the documentation benchmark (requirement 52a,
# component 24a, acceptance check 52a): its questions, its readers of a run's
# transcripts, its report, and the whole runner against a stub `claude`.
#
# The benchmark itself is never run here: every real run spends tokens, and a
# test that launched `claude` would be an agent launching an agent. What can
# be proven without a model is proven:
#
#   the questions
#     test/docs-benchmark/questions.jsonl holds at least 48 records, at least
#     eight for each of the six readers, every field present, every
#     backticked token of a required fact present in its gold answer, and
#     every source followed to a heading, or to a label in the section its
#     kind names. The validator is then shown each kind of defect, against a
#     fixture tree of its own, so a check that passes vacuously cannot.
#
#   the grader's verdict
#     read from a grading transcript recorded from a real run, and from
#     variants of it rewritten here: prose with braces around the JSON, a
#     worked example before it, facts in another order, echoed facts that are
#     not the question's, a failed fact, an absent or contradicting overall
#     verdict, a reply of the wrong shape, an error result and a torn stream.
#
#   the answering run's figures
#     tool calls and tokens read from an answering transcript recorded from a
#     real run (tool results trimmed to keep the fixture small), against the
#     figures that run reported.
#
#   the report
#     rendered from canned records, so its tables, pass-rate denominators and
#     optional sections are pinned without a run.
#
#   the runner
#     the dry run launches and writes nothing. Then the whole script runs
#     against a stub `claude` and a local Git source: the clone is stripped of
#     the benchmark before any question is asked; a pass, a fail and a timeout
#     are each recorded as such; the report names follow the full-run, second
#     run and one-question rules; a report that cannot be written exits 3,
#     says so and can be rendered again; and --calibrate grades the gold
#     answers.
#
# Run directly: ./test/docs-benchmark.test.sh — exit 0 iff all passed.
#
# shellcheck disable=SC2016
# Backticks and dollar signs in this file are literal Markdown and report
# text, never command substitution or expansion.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/docs-benchmark.sh
. "$SCRIPT_DIR/lib/docs-benchmark.sh"
# shellcheck source=lib/docs-benchmark-report.sh
. "$SCRIPT_DIR/lib/docs-benchmark-report.sh"

QUESTIONS="$SCRIPT_DIR/test/docs-benchmark/questions.jsonl"
FIXTURES="$SCRIPT_DIR/test/fixtures/docs-benchmark"
RUNNER="$SCRIPT_DIR/scripts/docs-benchmark.sh"

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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected not to contain: %s\n     actual: %s\n' "$desc" "$needle" "$haystack"
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
  "$(docs_benchmark_readers_json | jq -c 'sort')" \
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

```
~~~
## Hidden by a mixed fence
```

## After the mixed fence
EOF
cat >"$root/docs/SPEC.md" <<'EOF'
## Actors

10. An actor.

## Requirements

7. A requirement.
   7a. A nested one.
   ```text
   9. Inside an indented fence.
   ```

## Components

22c. A component.

## Acceptance checks

8. A check.
EOF
good='{"id":"operator-01","reader":"operator","question":"How do I stop it?","answer":"Run `stop` like this.","sources":[{"path":"README.md","heading":"Pausing everything"},{"path":"README.md","heading":"After the mixed fence"},{"path":"docs/SPEC.md","requirement":"7a"},{"path":"docs/SPEC.md","check":"8"}],"must_mention":["run `stop`"]}'

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
expect_problem "two facts that read the same" "two facts that read the same" \
  "$(mutate '.must_mention = ["Run stop.", "run `stop`"]')"
expect_problem "a fact naming a token the gold answer lacks" \
  'fact 2 names `pause`, which the gold answer does not contain' \
  "$(mutate '.must_mention = ["run `stop`", "or `pause`"]')"
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
expect_problem "a tilde line does not close a backtick fence" "heading Hidden by a mixed fence not found" \
  "$(mutate '.sources = [{"path": "README.md", "heading": "Hidden by a mixed fence"}]')"
expect_problem "a numbered line inside an indented fence is not a label" \
  "requirement 9 not found in the Requirements section of docs/SPEC.md" \
  "$(mutate '.sources = [{"path": "docs/SPEC.md", "requirement": "9"}]')"
expect_problem "a component is not a requirement" "requirement 22c not found" \
  "$(mutate '.sources = [{"path": "docs/SPEC.md", "requirement": "22c"}]')"
expect_problem "an actor is not a requirement" "requirement 10 not found" \
  "$(mutate '.sources = [{"path": "docs/SPEC.md", "requirement": "10"}]')"
expect_problem "an acceptance check cited as a requirement" "requirement 8 not found" \
  "$(mutate '.sources = [{"path": "docs/SPEC.md", "requirement": "8"}]')"
expect_problem "a requirement cited as an acceptance check" "check 7 not found in the Acceptance checks section" \
  "$(mutate '.sources = [{"path": "docs/SPEC.md", "check": "7"}]')"
expect_problem "a line that is not JSON" "line 2: not a JSON object" "$good" "not json"
expect_problem "a line that is JSON but not an object" "line 2: not a JSON object" "$good" "[1]"
expect_problem "a duplicate id" "operator-01: duplicate id" "$good" "$good"

# --- The small helpers ------------------------------------------------------

assert_eq "elapsed time reads a point-decimal reading" "1.5" "$(docs_benchmark_elapsed 100.25 101.75)"
assert_eq "elapsed time reads a comma-decimal reading" "1.5" "$(docs_benchmark_elapsed 100,25 101,75)"
assert_eq "an unusable reading is null, not an error" "null" "$(docs_benchmark_elapsed "" 101.75)"

strip="$tmp_dir/strip"
mkdir -p "$strip/test/docs-benchmark" "$strip/docs/reviews" "$strip/scripts" "$strip/.git/docs-benchmark"
touch "$strip/test/docs-benchmark/questions.jsonl" "$strip/docs/reviews/2026-01-01-docs-benchmark.md" \
  "$strip/scripts/docs-benchmark.sh" "$strip/README.md" "$strip/.git/docs-benchmark/keep"
assert_eq "stripping names every benchmark path it removes" \
  "docs/reviews/2026-01-01-docs-benchmark.md scripts/docs-benchmark.sh test/docs-benchmark" \
  "$(docs_benchmark_strip_clone "$strip" | sort | paste -sd' ' -)"
assert_eq "and leaves nothing of the benchmark outside .git" "" \
  "$(find "$strip" -path "$strip/.git" -prune -o -name '*docs-benchmark*' -print)"
assert_eq "and leaves everything else, .git included" "yes:yes" \
  "$([[ -e "$strip/README.md" ]] && echo yes):$([[ -e "$strip/.git/docs-benchmark/keep" ]] && echo yes)"

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

parse() { docs_benchmark_parse_verdict "$1" "$must"; }

with_reply "$tmp_dir/fenced.jsonl" "Here is my grading.

\`\`\`json
$object
\`\`\`

I hope this helps."
assert_eq "a reply fenced and wrapped in prose is still read" "graded:true" \
  "$(parse "$tmp_dir/fenced.jsonl" | jq -r '"\(.status):\(.passed)"')"

with_reply "$tmp_dir/multibyte.jsonl" "Grading — résumé of the answer: $object"
assert_eq "multi-byte prose before the object does not shift it" "graded" \
  "$(parse "$tmp_dir/multibyte.jsonl" | jq -r '.status')"

with_reply "$tmp_dir/brace-after.jsonl" "$object

{end of grading}"
assert_eq "a brace in the prose after the object does not hide it" "graded:true" \
  "$(parse "$tmp_dir/brace-after.jsonl" | jq -r '"\(.status):\(.passed)"')"

with_reply "$tmp_dir/example-before.jsonl" "I will reply in the shape {\"facts\": [...]} as asked.
$(jq -c '.facts[0].present = false | .verdict = "fail"' <<<"$object")"
assert_eq "a worked example before the object does not hide it" "graded:false" \
  "$(parse "$tmp_dir/example-before.jsonl" | jq -r '"\(.status):\(.passed)"')"

with_reply "$tmp_dir/valid-example-before.jsonl" "For example: {\"facts\": [], \"verdict\": \"pass\"}. My grading:
$(jq -c '.facts[1].present = false | .verdict = "fail"' <<<"$object")"
assert_eq "the last object with facts is the verdict, not a valid example before it" "graded:1" \
  "$(parse "$tmp_dir/valid-example-before.jsonl" | jq -r '"\(.status):\([.facts[] | .present] | index(false))"')"

with_reply "$tmp_dir/reordered.jsonl" "$(jq -c '.facts |= reverse | .facts[0].present = false | .verdict = "fail"' <<<"$object")"
v="$(parse "$tmp_dir/reordered.jsonl")"
assert_eq "facts listed in another order are matched by their text" "graded:$(( n_facts - 1 ))" \
  "$(jq -r '"\(.status):\(.facts_present)"' <<<"$v")"
assert_eq "so the missing fact is the one the grader named, not the first" \
  "$(jq -c '.[-1]' <<<"$must")" "$(jq -c '[.facts[] | select(.present | not) | .fact] | .[0]' <<<"$v")"

with_reply "$tmp_dir/wrong-facts.jsonl" "$(jq -c '.facts[0].fact = "something else entirely"' <<<"$object")"
v="$(parse "$tmp_dir/wrong-facts.jsonl")"
assert_eq "echoed facts that are not the question's are ungraded" "ungraded" "$(jq -r '.status' <<<"$v")"
assert_contains "and say so" "not the question's required facts" "$(jq -r '.error' <<<"$v")"

with_reply "$tmp_dir/restyled.jsonl" "$(jq -c '.facts[0].fact |= (ascii_upcase | gsub("`"; ""))' <<<"$object")"
assert_eq "an echo differing only in case and punctuation still matches" "graded" \
  "$(parse "$tmp_dir/restyled.jsonl" | jq -r '.status')"

with_reply "$tmp_dir/one-missing.jsonl" "$(jq -c '.facts[0].present = false | .verdict = "fail"' <<<"$object")"
v="$(parse "$tmp_dir/one-missing.jsonl")"
assert_eq "one missing fact fails the answer" "false:$(( n_facts - 1 )):true" \
  "$(jq -r '"\(.passed):\(.facts_present):\(.verdict_consistent)"' <<<"$v")"

with_reply "$tmp_dir/inconsistent.jsonl" "$(jq -c '.facts[0].present = false | .verdict = "pass"' <<<"$object")"
v="$(parse "$tmp_dir/inconsistent.jsonl")"
assert_eq "the facts decide when the overall verdict contradicts them" "false:false" \
  "$(jq -r '"\(.passed):\(.verdict_consistent)"' <<<"$v")"

with_reply "$tmp_dir/no-verdict.jsonl" "$(jq -c 'del(.verdict)' <<<"$object")"
v="$(parse "$tmp_dir/no-verdict.jsonl")"
assert_eq "an absent overall verdict is not an inconsistency" "true:null:null" \
  "$(jq -r '"\(.passed):\(.grader_verdict):\(.verdict_consistent)"' <<<"$v")"

with_reply "$tmp_dir/short.jsonl" "$(jq -c '.facts |= .[1:]' <<<"$object")"
v="$(parse "$tmp_dir/short.jsonl")"
assert_eq "too few facts judged is ungraded" "ungraded" "$(jq -r '.status' <<<"$v")"
assert_contains "and says how many" "judged $(( n_facts - 1 )) facts, but the question has $n_facts" "$(jq -r '.error' <<<"$v")"

with_reply "$tmp_dir/stringly.jsonl" "$(jq -c '.facts[0].present = "yes"' <<<"$object")"
assert_eq "a fact judged with a non-boolean is ungraded" "ungraded" \
  "$(parse "$tmp_dir/stringly.jsonl" | jq -r '.status')"

with_reply "$tmp_dir/prose.jsonl" "The answer looks right to me."
v="$(parse "$tmp_dir/prose.jsonl")"
assert_eq "a reply with no JSON is ungraded" "ungraded" "$(jq -r '.status' <<<"$v")"
assert_eq "and keeps what the grader said" "The answer looks right to me." "$(jq -r '.raw' <<<"$v")"

jq -c 'if .type == "result" then .is_error = true | .subtype = "error_during_execution" else . end' \
  "$recorded" >"$tmp_dir/errored.jsonl"
assert_contains "an error result is ungraded, naming it" "error_during_execution" \
  "$(parse "$tmp_dir/errored.jsonl" | jq -r '.error')"

grep -v '"type":"result"' "$recorded" >"$tmp_dir/torn.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"te' >>"$tmp_dir/torn.jsonl"
assert_contains "a stream torn before its result event is ungraded" "no result event" \
  "$(parse "$tmp_dir/torn.jsonl" | jq -r '.error')"

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

# --- The report, from canned records ---------------------------------------

jq -n '{ref: "main", commit: "0123456789abcdef", started: "2026-10-03T01:00:00Z",
        finished: "2026-10-03T02:00:00Z", cli: "9.9.9 (Claude Code)", questions_sha: "aaaaaaaaaaaa",
        runner_sha: "bbbbbbbbbbbb", model: "m1", grader_model: "m2", raw: "x.jsonl", only: "",
        readers: ["target-user", "operator", "evaluator"]}' >"$tmp_dir/run.json"
{
  jq -nc '{id: "operator-01", reader: "operator", tool_calls: 2, input_tokens: 100, output_tokens: 10,
           wall_seconds: 1.25, cost_usd: 0.5, grader: {cost_usd: 0.25},
           grade: {status: "graded", passed: true, facts_present: 2, facts_total: 2, verdict_consistent: null}}'
  jq -nc '{id: "operator-02", reader: "operator", tool_calls: 10, input_tokens: 300, output_tokens: 30,
           wall_seconds: 4, cost_usd: 0.5, grader: {cost_usd: 0.25},
           grade: {status: "graded", passed: false, facts_present: 1, facts_total: 3, verdict_consistent: false}}'
  jq -nc '{id: "evaluator-01", reader: "evaluator", tool_calls: 0, input_tokens: null, output_tokens: null,
           wall_seconds: 900, cost_usd: null, grader: {cost_usd: null},
           grade: {status: "ungraded", error: "the answer was stopped at its 900-second cap (exit 124)"}}'
} >"$tmp_dir/records.jsonl"
report="$(docs_benchmark_render_report "$tmp_dir/run.json" "$tmp_dir/records.jsonl")"
assert_contains "the report is titled with the run's date" "# Documentation benchmark, 2026-10-03" "$report"
assert_contains "it names the ref and commit" '`main` at `0123456789ab`' "$report"
assert_contains "it carries both hashes" "SHA-256 \`aaaaaaaaaaaa\`" "$report"
assert_contains "and the protocol's" "SHA-256 \`bbbbbbbbbbbb\`" "$report"
assert_contains "it totals the cost of answering and grading" 'about $1.5 for' "$report"
assert_contains "a reader's row counts its outcomes and pass rate" \
  "| operator | 2 | 1 | 1 | 0 | 50% | 2 | 100 | 10 | 1.3 |" "$report"
assert_contains "a reader with nothing graded shows no pass rate" \
  "| evaluator | 1 | 0 | 0 | 1 | – |" "$report"
assert_not_contains "a reader with no questions has no row" "| target-user |" "$report"
assert_contains "the pass rate is over graded questions only" "| **All** | 3 | 1 | 1 | 1 | 50% |" "$report"
assert_contains "each question has a row" "| \`operator-02\` | fail | 1/3 | 10 | 300 | 30 | 4 |" "$report"
assert_contains "an ungraded question has no facts figure" "| \`evaluator-01\` | ungraded | – |" "$report"
assert_contains "the ungraded section gives the reason" \
  "- \`evaluator-01\`: the answer was stopped at its 900-second cap (exit 124)." "$report"
assert_contains "the inconsistency section lists a contradicting grader" $'## Grader inconsistencies\n' "$report"
assert_contains "naming the question" $'\n- `operator-02`' "$report"
assert_not_contains "but not one that gave no overall verdict" "- \`operator-01\`" "$report"
assert_not_contains "a full run is not called partial" "partial run" "$report"
assert_eq "every table row has its header's column count" "" \
  "$(awk -F'|' '/^\| (Reader|Id) \|/ { want = NF; next } /^\|/ && want && NF != want { print NR": "$0 } /^$/ { want = 0 }' <<<"$report")"
jq '.only = "operator-01"' "$tmp_dir/run.json" >"$tmp_dir/run-only.json"
assert_contains "a one-question run says it is partial" "partial run of one question, \`operator-01\`" \
  "$(docs_benchmark_render_report "$tmp_dir/run-only.json" "$tmp_dir/records.jsonl")"

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
dry="$(PATH="$stub_dir:$PATH" "$RUNNER" --dry-run 2>&1)"
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
assert_contains "--dry-run names the full-run report" "-docs-benchmark.md and .jsonl" "$dry"
assert_eq "--dry-run launches nothing" "no" "$([[ -e "$tmp_dir/claude-called" ]] && echo yes || echo no)"
assert_eq "--dry-run writes no report" "$reviews_before" "$(ls -A "$SCRIPT_DIR/docs/reviews" 2>/dev/null)"

first_id="$(head -n 1 "$QUESTIONS" | jq -r '.id')"
dry_one="$(PATH="$stub_dir:$PATH" "$RUNNER" --dry-run --only "$first_id" v1.0 2>&1)"
assert_eq "--dry-run --only lists that one question" "1" "$(grep -c '^[a-z-]*-[0-9][0-9] \[' <<<"$dry_one")"
assert_contains "--dry-run --only names it" "$first_id [" "$dry_one"
assert_contains "--dry-run names the ref it would clone" "<clone of v1.0>" "$dry_one"
assert_contains "--dry-run --only names the one-question report" "-docs-benchmark-only-$first_id.md" "$dry_one"

dry_cal="$(PATH="$stub_dir:$PATH" "$RUNNER" --dry-run --calibrate 2>&1)"
assert_eq "--dry-run --calibrate prints only grading commands" "0:$(jq -s 'length' "$QUESTIONS")" \
  "$(grep -c '^  answer: ' <<<"$dry_cal"):$(grep -c '^  grade:  ' <<<"$dry_cal")"

PATH="$stub_dir:$PATH" "$RUNNER" --dry-run --only no-such-id >/dev/null 2>&1
assert_eq "--only with an unknown id is a usage error" "64" "$?"
PATH="$stub_dir:$PATH" "$RUNNER" --frobnicate >/dev/null 2>&1
assert_eq "an unknown option is a usage error" "64" "$?"
PATH="$stub_dir:$PATH" "$RUNNER" --dry-run main extra >/dev/null 2>&1
assert_eq "a second ref is a usage error" "64" "$?"
: >"$tmp_dir/empty.jsonl"
out="$(DOCS_BENCHMARK_QUESTIONS="$tmp_dir/empty.jsonl" PATH="$stub_dir:$PATH" "$RUNNER" --dry-run 2>&1)"
assert_eq "an empty questions file cannot start a run" "2" "$?"
assert_contains "and says so, not that an id is unknown" "holds no records" "$out"
assert_eq "--dry-run never launched the stub" "no" "$([[ -e "$tmp_dir/claude-called" ]] && echo yes || echo no)"

# --- The runner, end to end, against a stub claude -------------------------
#
# The stub answers like the real CLI's stream: an answer with one tool call,
# or exit 124 as `timeout` would for a question carrying TIMEOUT-ME. As the
# grader it echoes the prompt's required facts, judging the first one absent
# when the candidate carries FAIL-ME. As the answerer it also records any
# benchmark path it can see in the clone.

e2e="$tmp_dir/e2e"
mkdir -p "$e2e/bin" "$e2e/source/docs/reviews" "$e2e/source/test/docs-benchmark" "$e2e/source/scripts" "$e2e/tmp"
cat >"$e2e/bin/claude" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then echo "0.0.0 (stub)"; exit 0; fi
tools=""; prev=""
for a in "\$@"; do [[ "\$prev" == "--tools" ]] && tools="\$a"; prev="\$a"; done
prompt="\$(cat)"
if [[ "\$tools" == "Read,Grep,Glob" ]]; then
  find . -path ./.git -prune -o -name '*docs-benchmark*' -print >>"$e2e/leaks"
  case "\$prompt" in *TIMEOUT-ME*) exit 124 ;; esac
  answer="Stub answer."
  case "\$prompt" in *FAIL-ME*) answer="Stub answer. FAIL-ME" ;; esac
  jq -nc '{type: "system", subtype: "init", tools: ["Glob", "Grep", "Read"]}'
  jq -nc '{type: "assistant", message: {content: [{type: "tool_use", name: "Grep", input: {pattern: "x"}}]}}'
  jq -nc --arg a "\$answer" '{type: "result", subtype: "success", is_error: false, num_turns: 2, result: \$a,
    total_cost_usd: 0.01, modelUsage: {"m": {inputTokens: 10, outputTokens: 5, cacheReadInputTokens: 100, cacheCreationInputTokens: 20}}}'
else
  facts="\$(sed -n '/^<<<CANDIDATE\$/q; s/^[0-9][0-9]*\. //p' <<<"\$prompt")"
  candidate="\$(sed -n '/^<<<CANDIDATE\$/,/^CANDIDATE>>>\$/p' <<<"\$prompt")"
  fail=false; [[ "\$candidate" == *FAIL-ME* ]] && fail=true
  reply="\$(jq -Rn --argjson fail "\$fail" '[inputs] | to_entries
    | map({fact: .value, present: (if \$fail and .key == 0 then false else true end), reasoning: "stub"})
    | {facts: ., verdict: (if \$fail then "fail" else "pass" end), reasoning: "stub"}' <<<"\$facts")"
  jq -nc --arg r "\$reply" '{type: "result", subtype: "success", is_error: false, num_turns: 1, result: \$r,
    total_cost_usd: 0.02, modelUsage: {"m": {inputTokens: 50, outputTokens: 30, cacheReadInputTokens: 0, cacheCreationInputTokens: 0}}}'
fi
EOF
chmod +x "$e2e/bin/claude"

printf '# Source\n' >"$e2e/source/README.md"
printf 'bait\n' >"$e2e/source/test/docs-benchmark/questions.jsonl"
printf 'bait\n' >"$e2e/source/docs/reviews/2026-01-01-docs-benchmark.md"
printf 'bait\n' >"$e2e/source/scripts/docs-benchmark.sh"
git -C "$e2e/source" init -q -b main
git -C "$e2e/source" add -A
git -C "$e2e/source" -c user.name=test -c user.email=test@example.invalid commit -q -m "source"
source_head="$(git -C "$e2e/source" rev-parse HEAD)"

{
  jq -nc '{id: "operator-01", reader: "operator", question: "How do I pause it?", answer: "Pause it gently.",
           sources: [{path: "README.md", heading: "Source"}], must_mention: ["pause it", "gently"]}'
  jq -nc '{id: "evaluator-01", reader: "evaluator", question: "What does it cost? FAIL-ME", answer: "It costs little. FAIL-ME",
           sources: [{path: "README.md", heading: "Source"}], must_mention: ["costs", "little"]}'
  jq -nc '{id: "contributor-01", reader: "contributor", question: "How do I test it? TIMEOUT-ME", answer: "Run the tests.",
           sources: [{path: "README.md", heading: "Source"}], must_mention: ["run the tests"]}'
} >"$e2e/questions.jsonl"

run_e2e() {  # run_e2e REPORT_DIR ARGS... — the runner against the stub; stderr to $e2e/stderr
  local report_dir="$1"; shift
  DOCS_BENCHMARK_QUESTIONS="$e2e/questions.jsonl" DOCS_BENCHMARK_REPORT_DIR="$report_dir" \
    DOCS_BENCHMARK_SOURCE="$e2e/source" TMPDIR="$e2e/tmp" PATH="$e2e/bin:$PATH" \
    "$RUNNER" "$@" 2>"$e2e/stderr"
}

run_e2e "$e2e/reviews" main >/dev/null
assert_eq "a run with an unanswered question exits 1" "1" "$?"
assert_eq "the clone held none of the benchmark when questions were asked" "" "$(cat "$e2e/leaks" 2>/dev/null)"
assert_contains "the stripped paths are named" "removed test/docs-benchmark from the clone" "$(cat "$e2e/stderr")"
full_md="$(find "$e2e/reviews" -name '*-docs-benchmark.md')"
full_jsonl="${full_md%.md}.jsonl"
assert_eq "a full run writes the day's report and records" "1:yes" \
  "$(printf '%s\n' "$full_md" | grep -c .):$([[ -f "$full_jsonl" ]] && echo yes)"
assert_eq "every question has a record" "3" "$(wc -l <"$full_jsonl" | tr -d ' ')"
assert_eq "the records carry the source's commit" "$source_head" "$(jq -r '.commit' "$full_jsonl" | sort -u)"
assert_eq "outcomes: a pass, a fail and an ungraded" "operator-01:true evaluator-01:false contributor-01:ungraded" \
  "$(jq -r '"\(.id):\(if .grade.status == "graded" then .grade.passed else "ungraded" end)"' "$full_jsonl" | paste -sd' ' -)"
assert_eq "the fail names the missing fact" '["costs"]' \
  "$(jq -c 'select(.id == "evaluator-01") | [.grade.facts[] | select(.present | not) | .fact]' "$full_jsonl")"
assert_eq "a timed-out answer says it hit the cap" "the answer was stopped at its 900-second cap (exit 124)" \
  "$(jq -r 'select(.id == "contributor-01") | .grade.error' "$full_jsonl")"
assert_eq "tool calls and tokens are recorded" "1:130:5" \
  "$(jq -r 'select(.id == "operator-01") | "\(.tool_calls):\(.input_tokens):\(.output_tokens)"' "$full_jsonl")"
assert_eq "wall times are numbers" "true" "$(jq -s 'all(.[]; (.wall_seconds | type) == "number")' "$full_jsonl")"
assert_contains "the report lists the timeout as ungraded" "- \`contributor-01\`: the answer was stopped at its 900-second cap" "$(cat "$full_md")"
assert_contains "the report says what it wrote" "wrote $full_md" "$(cat "$e2e/stderr")"

run_e2e "$e2e/reviews" main >/dev/null
assert_eq "a second full run the same day takes the -2 suffix" "yes:yes" \
  "$([[ -f "${full_md%.md}-2.md" ]] && echo yes):$([[ -f "${full_md%.md}-2.jsonl" ]] && echo yes)"

run_e2e "$e2e/reviews" --only operator-01 main >/dev/null
assert_eq "a one-question run that passes exits 0" "0" "$?"
only_md="$(find "$e2e/reviews" -name '*-docs-benchmark-only-operator-01.md')"
assert_eq "a one-question run has its own name" "1" "$(printf '%s\n' "$only_md" | grep -c .)"
assert_eq "and leaves the full-run names alone" "2" "$(find "$e2e/reviews" -name '*-docs-benchmark.md' -o -name '*-docs-benchmark-2.md' | wc -l | tr -d ' ')"

: >"$e2e/blocker"
run_e2e "$e2e/blocker/reviews" --only operator-01 main >/dev/null
assert_eq "a report that cannot be written exits 3" "3" "$?"
stderr="$(cat "$e2e/stderr")"
assert_contains "and says so" "could not write the report" "$stderr"
assert_not_contains "and does not claim to have written it" "docs-benchmark: wrote" "$stderr"
survivor="$(sed -n 's/^docs-benchmark: the records survive in \([^ ]*\) and the run description in \([^;]*\);$/\1 \2/p' <<<"$stderr")"
read -r survivor_records survivor_run <<<"$survivor"
assert_eq "it names the surviving records and run description" "yes:yes" \
  "$([[ -s "$survivor_records" ]] && echo yes):$([[ -s "$survivor_run" ]] && echo yes)"
assert_contains "from which the report renders again" "# Documentation benchmark" \
  "$(docs_benchmark_render_report "$survivor_run" "$survivor_records")"

out="$(run_e2e "$e2e/reviews" --calibrate)"
assert_eq "--calibrate exits 1 when a gold answer fails its own facts" "1" "$?"
assert_contains "and names the fact it lacks" 'FAIL      evaluator-01: the gold answer lacks "costs"' "$out"
assert_contains "and passes the others" "pass      operator-01" "$out"
run_e2e "$e2e/reviews" --calibrate --only operator-01 >/dev/null
assert_eq "--calibrate exits 0 when every gold answer passes" "0" "$?"
assert_eq "--calibrate writes no report" "3" "$(find "$e2e/reviews" -name '*.md' | wc -l | tr -d ' ')"

if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
