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
#     eight for each of the six readers, every one well formed, with every
#     backticked token of a required fact present in its gold answer. Whether
#     the documents still hold their sources is not asserted here: the image's
#     suite does not run for the documentation-only change that moves one, so
#     the runner's --check does that, in a workflow of its own that runs for
#     every pull request. The validator is shown each kind of defect against a
#     fixture tree of its own, so a check that passes vacuously cannot, and
#     --check is run against that tree.
#
#   the protocol
#     its hash moves with any definition it names, a borrowed pipeline
#     function included, and with nothing else: not a comment, not the
#     validator, not the rest of a borrowed library. Its lists are closed, so
#     no function or variable a protocol function uses is left off them. The
#     questions hash ignores sources and the order of the records.
#
#   the tree and the environment
#     a checkout leaves the benchmark out without a trace, and the runs lose
#     every variable that changes the model's behaviour while keeping what
#     signing in needs.
#
#   the grader's verdict
#     read from a grading transcript recorded from a real run, and from
#     variants of it rewritten here: prose with braces around the JSON, an
#     unclosed brace before it, a worked example before it, facts in another
#     order or echoed with list numbers, echoed facts that are not the
#     question's, a failed fact, an absent or contradicting overall verdict, a
#     reply of the wrong shape, a long reply full of braces (read in bounded
#     time), an error result and a torn stream. A question left unanswered or
#     ungraded says whether a cap stopped it, by TERM or by KILL.
#
#   the answering run's figures
#     tool calls and tokens read from an answering transcript recorded from a
#     real run (tool results trimmed to keep the fixture small), against the
#     figures that run reported.
#
#   the report
#     rendered from canned records, so its tables, pass-rate denominators,
#     comparability rule and optional sections are pinned without a run, and
#     from the description of a run that did not finish.
#
#   the runner
#     the dry run launches and writes nothing, and --check passes and fails
#     as it should. Then the whole script runs against a stub `claude` and a
#     local Git source: the answering run's tree holds none of the benchmark
#     and no .git, under a path that does not name it, and its environment
#     none of the cleared variables; a pass, a fail, an answer timeout and a
#     grading timeout are each recorded as such; the report names follow the
#     full-run, second-run and one-question rules; a report that cannot be
#     written exits 3, says so and can be rendered again; Ctrl-C stops the run
#     and the question in flight at once, leaving records that render; a
#     missing tool stops a run before anything is written; and --calibrate
#     grades the gold answers.
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

assert_ne() {
  local desc="$1" unexpected="$2" actual="$3"
  if [[ "$unexpected" != "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected anything but: %s\n' "$desc" "$actual"
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

problems="$(docs_benchmark_check_questions "$QUESTIONS")"
rc=$?
assert_eq "questions.jsonl is well formed" "0" "$rc"
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

## Paths like C:\temp
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
expect_problem "a fact that begins with a list number" "a fact that begins with a list number" \
  "$(mutate '.must_mention = ["1. run `stop`"]')"
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
expect_problem "a locator holding a tab" "has a locator holding a tab or a line break" \
  "$(mutate '.sources = [{"path": "README.md", "heading": "Pausing\teverything"}]')"
expect_problem "a path holding a line break" "holds a tab or a line break" \
  "$(mutate '.sources = [{"path": "README\n.md", "heading": "Pausing everything"}]')"
out="$(check_record_lines "$(mutate '.sources = [{"path": "README.md", "heading": "Paths like C:\\temp"}]')")"
assert_eq "a heading holding a backslash is found word for word" "0:" "$?:$out"
expect_problem "and is not found with the backslash doubled" 'heading Paths like C:\\temp not found' \
  "$(mutate '.sources = [{"path": "README.md", "heading": "Paths like C:\\\\temp"}]')"
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

# --- The tree the answering run sees ----------------------------------------

co_src="$tmp_dir/co-src"
mkdir -p "$co_src/test/docs-benchmark" "$co_src/docs/reviews" "$co_src/scripts"
printf '# Source\n' >"$co_src/README.md"
printf 'gold\n' >"$co_src/test/docs-benchmark/questions.jsonl"
printf 'report\n' >"$co_src/docs/reviews/2026-01-01-docs-benchmark.md"
printf 'runner\n' >"$co_src/scripts/docs-benchmark.sh"
printf 'other\n' >"$co_src/scripts/other.sh"
git -C "$co_src" init -q -b main
git -C "$co_src" add -A
git -C "$co_src" -c user.name=test -c user.email=test@example.invalid commit -q -m "test(docs-benchmark): the source"
git clone --quiet --no-checkout "$co_src" "$tmp_dir/co" 2>/dev/null
left="$(docs_benchmark_checkout "$tmp_dir/co" "$(git -C "$co_src" rev-parse HEAD)")"
assert_eq "a checkout succeeds" "0" "$?"
assert_eq "it names every benchmark path it leaves out" \
  "docs/reviews/2026-01-01-docs-benchmark.md scripts/docs-benchmark.sh test/docs-benchmark/questions.jsonl" \
  "$(LC_ALL=C sort <<<"$left" | paste -sd' ' -)"
assert_eq "it puts none of them on disk" "" "$(find "$tmp_dir/co" -name '*docs-benchmark*')"
assert_eq "it leaves no .git, so neither a status nor a history to read" "no" \
  "$([[ -e "$tmp_dir/co/.git" ]] && echo yes || echo no)"
assert_eq "and it checks out everything else" "yes:yes" \
  "$([[ -f "$tmp_dir/co/README.md" ]] && echo yes):$([[ -f "$tmp_dir/co/scripts/other.sh" ]] && echo yes)"

cleared_names="$(env -i PATH="$PATH" HOME=/nowhere MAX_THINKING_TOKENS=1 CLAUDE_CODE_EFFORT_LEVEL=max \
  CLAUDE_EFFORT=xhigh CLAUDECODE=1 ANTHROPIC_DEFAULT_SONNET_MODEL=x ANTHROPIC_MODEL=y \
  DISABLE_PROMPT_CACHING=1 CLAUDE_CODE_OAUTH_TOKEN=t CLAUDE_CONFIG_DIR=/c ANTHROPIC_API_KEY=k \
  CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_CLIENT_CERT=/cert \
  bash -c '. "$1/lib/docs-benchmark.sh" && docs_benchmark_cleared_env' _ "$SCRIPT_DIR" | LC_ALL=C sort | paste -sd' ' -)"
assert_eq "the runs lose every variable that changes the model's behaviour, and keep what signing in needs" \
  "ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_MODEL CLAUDECODE CLAUDE_CODE_EFFORT_LEVEL CLAUDE_EFFORT DISABLE_PROMPT_CACHING MAX_THINKING_TOKENS" \
  "$cleared_names"

# --- The protocol and the questions hash -----------------------------------
#
# The protocol is whatever DOCS_BENCHMARK_PROTOCOL_FUNCTIONS and
# DOCS_BENCHMARK_PROTOCOL_VARIABLES name, and its hash is over those
# definitions alone. These are the library's functions and variables that are
# deliberately not part of it; anything new must join one list or the other.
NOT_PROTOCOL_FUNCTIONS=(docs_benchmark_readers_json docs_benchmark_check_questions
  docs_benchmark_questions_hash docs_benchmark_protocol_hash)
NOT_PROTOCOL_VARIABLES=(DOCS_BENCHMARK_LIB_DIR DOCS_BENCHMARK_READERS
  DOCS_BENCHMARK_PROTOCOL_VARIABLES DOCS_BENCHMARK_PROTOCOL_FUNCTIONS)

# listed WORD ARRAY... — whether WORD is one of the remaining arguments.
listed() {
  local word="$1"; shift
  [[ " $* " == *" $word "* ]]
}

# What sourcing the library defines, in a clean shell, so that neither this
# test's own functions nor its environment are counted.
lib_functions="$(env -i PATH="$PATH" bash -c '. "$1/lib/docs-benchmark.sh" && compgen -A function' _ "$SCRIPT_DIR")"
lib_variables="$(env -i PATH="$PATH" bash -c '. "$1/lib/docs-benchmark.sh" && compgen -v DOCS_BENCHMARK_' _ "$SCRIPT_DIR")"

unclassified=""
while IFS= read -r f; do
  listed "$f" "${DOCS_BENCHMARK_PROTOCOL_FUNCTIONS[@]}" "${NOT_PROTOCOL_FUNCTIONS[@]}" || unclassified+=" $f"
done < <(grep '^docs_benchmark_' <<<"$lib_functions")
while IFS= read -r v; do
  listed "$v" "${DOCS_BENCHMARK_PROTOCOL_VARIABLES[@]}" "${NOT_PROTOCOL_VARIABLES[@]}" || unclassified+=" $v"
done <<<"$lib_variables"
assert_eq "every function and variable of the library is on the protocol's lists or deliberately off them" "" "$unclassified"

open_ends=""
for f in "${DOCS_BENCHMARK_PROTOCOL_FUNCTIONS[@]}"; do
  body="$(declare -f "$f" | tail -n +2)"
  if [[ -z "$body" ]]; then
    open_ends+=" $f(undefined)"
    continue
  fi
  while IFS= read -r g; do
    if [[ "$g" != "$f" ]] && grep -qw -- "$g" <<<"$body"; then
      listed "$g" "${DOCS_BENCHMARK_PROTOCOL_FUNCTIONS[@]}" || open_ends+=" $f->$g"
    fi
  done <<<"$lib_functions"
  while IFS= read -r v; do
    [[ -z "$v" ]] || listed "$v" "${DOCS_BENCHMARK_PROTOCOL_VARIABLES[@]}" || open_ends+=" $f->\$$v"
  done < <(grep -o 'DOCS_BENCHMARK_[A-Z_]*' <<<"$body" | sort -u)
done
for v in "${DOCS_BENCHMARK_PROTOCOL_VARIABLES[@]}"; do
  declare -p "$v" >/dev/null 2>&1 || open_ends+=" \$$v(undefined)"
done
assert_eq "the protocol's lists are closed: every function and variable a protocol function uses is on them" \
  "" "$open_ends"

# protocol_hash_of LIB_DIR — the protocol hash a copy of lib/ gives, in a clean shell.
protocol_hash_of() {
  env -i PATH="$PATH" bash -c '. "$1/docs-benchmark.sh" && docs_benchmark_protocol_hash' _ "$1"
}
# edited FILE SED_SCRIPT — a fresh copy of lib/ with one file edited; prints its hash.
edited() {
  local copy="$tmp_dir/lib-copy"
  rm -rf "$copy"
  cp -R "$SCRIPT_DIR/lib" "$copy"
  sed "$2" "$copy/$1" >"$copy/$1.new" && mv "$copy/$1.new" "$copy/$1"
  if cmp -s "$SCRIPT_DIR/lib/$1" "$copy/$1"; then
    printf 'edit had no effect on %s\n' "$1"
  else
    protocol_hash_of "$copy"
  fi
}

protocol_hash="$(protocol_hash_of "$SCRIPT_DIR/lib")"
assert_eq "the protocol hash is twelve hex digits" "1" "$(grep -c '^[0-9a-f]\{12\}$' <<<"$protocol_hash")"
assert_eq "the same in this shell as in a clean one" "$protocol_hash" "$(docs_benchmark_protocol_hash)"
assert_eq "a comment inside a protocol function leaves it alone" "$protocol_hash" \
  "$(edited docs-benchmark.sh '/^docs_benchmark_elapsed() {$/a\
  # A new comment.')"
assert_eq "so does a change to the question check" "$protocol_hash" \
  "$(edited docs-benchmark.sh 's/is not one of the six/is not one of the readers/')"
assert_eq "and a change elsewhere in a borrowed library" "$protocol_hash" \
  "$(edited stage-run.sh 's/select(length > 0) | (try tonumber catch empty)/select(length > 1) | (try tonumber catch empty)/')"
assert_ne "a time cap moves it" "$protocol_hash" \
  "$(edited docs-benchmark.sh 's/^DOCS_BENCHMARK_ANSWER_TIMEOUT_SEC=900$/DOCS_BENCHMARK_ANSWER_TIMEOUT_SEC=901/')"
assert_ne "so does an effort" "$protocol_hash" \
  "$(edited docs-benchmark.sh 's/^DOCS_BENCHMARK_EFFORT="medium"$/DOCS_BENCHMARK_EFFORT="low"/')"
assert_ne "so does the classification of an unanswered question" "$protocol_hash" \
  "$(edited docs-benchmark.sh 's/the answer was empty/the answer was blank/')"
assert_ne "so does the borrowed token count" "$protocol_hash" \
  "$(edited metering.sh 's/inputTokens \/\/ 0/inputTokens \/\/ 1/')"

printf '%s\n' "$good" "$(mutate '.id = "operator-02"')" >"$tmp_dir/qa.jsonl"
printf '%s\n' "$(mutate '.id = "operator-02" | .sources = [{"path": "docs/SPEC.md", "check": "8"}]')" "$good" \
  >"$tmp_dir/qb.jsonl"
printf '%s\n' "$good" "$(mutate '.id = "operator-02" | .must_mention = ["run `stop` at once"]')" >"$tmp_dir/qc.jsonl"
assert_eq "the questions hash ignores sources and the order of the records" \
  "$(docs_benchmark_questions_hash "$tmp_dir/qa.jsonl")" "$(docs_benchmark_questions_hash "$tmp_dir/qb.jsonl")"
assert_ne "and moves with a required fact" \
  "$(docs_benchmark_questions_hash "$tmp_dir/qa.jsonl")" "$(docs_benchmark_questions_hash "$tmp_dir/qc.jsonl")"

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

with_reply "$tmp_dir/unclosed-before.jsonl" "I think {this answer is close. $object"
assert_eq "an unclosed brace in the prose before the object does not hide it" "graded:true" \
  "$(parse "$tmp_dir/unclosed-before.jsonl" | jq -r '"\(.status):\(.passed)"')"

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

with_reply "$tmp_dir/numbered.jsonl" \
  "$(jq -c '.facts |= (to_entries | map(.value.fact = "\(.key + 1). \(.value.fact)" | .value))' <<<"$object")"
assert_eq "facts echoed with their list numbers still match" "graded:true" \
  "$(parse "$tmp_dir/numbered.jsonl" | jq -r '"\(.status):\(.passed)"')"

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

# Each pass over a reply is linear in its length. Searched slice by slice
# instead, a reply this size, full of JSON snippets, would take hours, and the
# reading runs outside the grader's time cap.
long_reply="$(for _ in $(seq 1500); do printf 'see {"a": [1, {"b": "}"}]} and '; done; printf 'a stray { here. %s' "$object")"
with_reply "$tmp_dir/long.jsonl" "$long_reply"
assert_eq "a long reply full of braces is read, in bounded time" "graded:true" \
  "$(timeout 30 bash -c '. "$1/lib/docs-benchmark.sh" && docs_benchmark_parse_verdict "$2" "$3"' \
     _ "$SCRIPT_DIR" "$tmp_dir/long.jsonl" "$must" | jq -r '"\(.status):\(.passed)"')"

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

# --- Stopped at a cap, or not -----------------------------------------------

nothing='{"result": null, "error": "no result event in the stream"}'
assert_eq "an answer stopped by TERM at its cap says so" \
  "the answer was stopped at its 900-second cap (exit 124)" \
  "$(docs_benchmark_unanswered "$nothing" 124 900.2 | jq -r '.error')"
assert_eq "so does one that needed KILL after it" \
  "the answer was stopped at its 900-second cap (exit 137)" \
  "$(docs_benchmark_unanswered "$nothing" 137 910.4 | jq -r '.error')"
assert_eq "a run killed before its cap is not called stopped at it" \
  "no result event in the stream (exit 137)" \
  "$(docs_benchmark_unanswered "$nothing" 137 12.5 | jq -r '.error')"
assert_eq "nor is one whose wall time is unknown" "no result event in the stream (exit 137)" \
  "$(docs_benchmark_unanswered "$nothing" 137 null | jq -r '.error')"
assert_eq "a grading stopped at its cap says so" \
  "the grading was stopped at its 300-second cap (exit 124)" \
  "$(docs_benchmark_grade "$tmp_dir/torn.jsonl" "$must" 124 300.1 | jq -r '.error')"
assert_eq "a grading that failed otherwise keeps its exit status" \
  "no result event in the grading stream (exit 1)" \
  "$(docs_benchmark_grade "$tmp_dir/torn.jsonl" "$must" 1 3.5 | jq -r '.error')"
assert_eq "a grading that gave a verdict is graded, whatever its exit status" "graded" \
  "$(docs_benchmark_grade "$recorded" "$must" 124 301 | jq -r '.status')"

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
        protocol_sha: "bbbbbbbbbbbb", model: "m1", effort: "medium", grader_model: "m2",
        grader_effort: "high", questions_total: 3, raw: "x.jsonl", only: "",
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
assert_contains "it states the comparability rule, the Claude Code version in it" \
  "a run whose questions hash, protocol hash and Claude Code version all match these" "$report"
assert_contains "it names each model's effort" "\`m1\` at \`medium\` effort" "$report"
assert_contains "the grader's too" "\`m2\` at \`high\` effort" "$report"
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
assert_not_contains "a run that finished does not say it did not" "did not finish" "$report"
jq '.finished = null | .raw = null | .questions_total = 5' "$tmp_dir/run.json" >"$tmp_dir/run-unfinished.json"
unfinished="$(docs_benchmark_render_report "$tmp_dir/run-unfinished.json" "$tmp_dir/records.jsonl")"
assert_contains "a run that did not finish says how far it got" \
  "This run did not finish: it holds 3 of the 5 questions it set out to ask" "$unfinished"
assert_contains "and points at its records where they are" "\`records.jsonl\` in the run directory" "$unfinished"

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
  "$(grep -c "^  answer: cd <tree of main> && claude -p --model $DOCS_BENCHMARK_MODEL --effort $DOCS_BENCHMARK_EFFORT --tools Read,Grep,Glob " <<<"$dry")"
assert_eq "--dry-run prints a grading command for every question" \
  "$(jq -s 'length' "$QUESTIONS")" \
  "$(grep -c "^  grade:  cd <empty directory> && claude -p --model $DOCS_BENCHMARK_GRADER_MODEL --effort $DOCS_BENCHMARK_GRADER_EFFORT --tools '' " <<<"$dry")"
assert_contains "--dry-run keeps the person's own settings out" "--setting-sources project --strict-mcp-config" "$dry"
assert_contains "--dry-run names the full-run report" "-docs-benchmark.md and .jsonl" "$dry"
assert_eq "--dry-run launches nothing" "no" "$([[ -e "$tmp_dir/claude-called" ]] && echo yes || echo no)"
assert_eq "--dry-run writes no report" "$reviews_before" "$(ls -A "$SCRIPT_DIR/docs/reviews" 2>/dev/null)"

first_id="$(head -n 1 "$QUESTIONS" | jq -r '.id')"
dry_one="$(PATH="$stub_dir:$PATH" "$RUNNER" --dry-run --only "$first_id" v1.0 2>&1)"
assert_eq "--dry-run --only lists that one question" "1" "$(grep -c '^[a-z-]*-[0-9][0-9] \[' <<<"$dry_one")"
assert_contains "--dry-run --only names it" "$first_id [" "$dry_one"
assert_contains "--dry-run names the ref it would check out" "<tree of v1.0>" "$dry_one"
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

# --- --check, against the validator's fixture tree --------------------------

check_tree="$tmp_dir/check-tree"
cp -R "$root" "$check_tree"
mkdir -p "$check_tree/scripts"
cp "$RUNNER" "$check_tree/scripts/"
cp -R "$SCRIPT_DIR/lib" "$check_tree/lib"
printf '%s\n' "$good" >"$tmp_dir/check-good.jsonl"
printf '%s\n' "$good" "$(mutate '.id = "operator-02" | .sources = [{"path": "README.md", "heading": "Moved away"}]')" \
  >"$tmp_dir/check-moved.jsonl"
out="$(DOCS_BENCHMARK_QUESTIONS="$tmp_dir/check-good.jsonl" PATH="$stub_dir:$PATH" \
  "$check_tree/scripts/docs-benchmark.sh" --check 2>&1)"
assert_eq "--check passes when every source holds" "0" "$?"
assert_contains "and says so" "every source it cites holds" "$out"
out="$(DOCS_BENCHMARK_QUESTIONS="$tmp_dir/check-moved.jsonl" PATH="$stub_dir:$PATH" \
  "$check_tree/scripts/docs-benchmark.sh" --check 2>&1)"
assert_eq "--check fails when a cited heading has moved" "1" "$?"
assert_contains "naming the question and the heading" "operator-02: heading Moved away not found in README.md" "$out"
PATH="$stub_dir:$PATH" "$RUNNER" --check main >/dev/null 2>&1
assert_eq "--check with a ref is a usage error" "64" "$?"
assert_eq "--check never launched the stub" "no" "$([[ -e "$tmp_dir/claude-called" ]] && echo yes || echo no)"

# --- The runner, end to end, against a stub claude -------------------------
#
# The stub answers like the real CLI's stream: an answer with one tool call;
# exit 124, as `timeout` would, for a question carrying ANSWER-CAP; or, for
# one carrying HANG-ME, a wait long enough to be interrupted. As the grader it
# echoes the prompt's required facts, judging the first one absent when the
# candidate carries FAIL-ME, and exits 124 when it carries GRADE-CAP. As the
# answerer it also records the question, its working directory, and anything
# of the benchmark, of `.git` or of the cleared environment that it can see.

e2e="$tmp_dir/e2e"
mkdir -p "$e2e/bin" "$e2e/source/docs/reviews" "$e2e/source/test/docs-benchmark" "$e2e/source/scripts" "$e2e/tmp"
cat >"$e2e/bin/claude" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then echo "0.0.0 (stub)"; exit 0; fi
tools=""; prev=""
for a in "\$@"; do [[ "\$prev" == "--tools" ]] && tools="\$a"; prev="\$a"; done
prompt="\$(cat)"
if [[ "\$tools" == "Read,Grep,Glob" ]]; then
  pwd >>"$e2e/cwds"
  sed -n 's/^Question: //p' <<<"\$prompt" >>"$e2e/asked"
  {
    find . -name '*docs-benchmark*' -print
    [[ -e .git ]] && echo ".git is present"
    env | grep -o '^\(MAX_THINKING_TOKENS\|CLAUDE_EFFORT\|CLAUDECODE\)='
  } >>"$e2e/leaks"
  case "\$prompt" in
    *ANSWER-CAP*) exit 124 ;;
    *HANG-ME*) echo "\$\$" >"$e2e/hang.pid"; exec sleep 30 ;;
  esac
  answer="Stub answer."
  case "\$prompt" in
    *FAIL-ME*) answer="Stub answer. FAIL-ME" ;;
    *GRADE-CAP*) answer="Stub answer. GRADE-CAP" ;;
  esac
  jq -nc '{type: "system", subtype: "init", tools: ["Glob", "Grep", "Read"]}'
  jq -nc '{type: "assistant", message: {content: [{type: "tool_use", name: "Grep", input: {pattern: "x"}}]}}'
  jq -nc --arg a "\$answer" '{type: "result", subtype: "success", is_error: false, num_turns: 2, result: \$a,
    total_cost_usd: 0.01, modelUsage: {"m": {inputTokens: 10, outputTokens: 5, cacheReadInputTokens: 100, cacheCreationInputTokens: 20}}}'
else
  facts="\$(sed -n '/^Required facts\./,/^The candidate answer/ s/^- //p' <<<"\$prompt")"
  candidate="\$(sed -n '/^<<<CANDIDATE\$/,/^CANDIDATE>>>\$/p' <<<"\$prompt")"
  case "\$candidate" in *GRADE-CAP*) exit 124 ;; esac
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
git -C "$e2e/source" -c user.name=test -c user.email=test@example.invalid commit -q -m "test(docs-benchmark): the source"
source_head="$(git -C "$e2e/source" rev-parse HEAD)"

# e2e_question ID QUESTION ANSWER FACT... — one record citing the source's README.
e2e_question() {
  local id="$1" question="$2" answer="$3"; shift 3
  jq -nc --arg id "$id" --arg q "$question" --arg a "$answer" '$ARGS.positional as $facts
    | {id: $id, reader: ($id | sub("-[0-9]+$"; "")), question: $q, answer: $a,
       sources: [{path: "README.md", heading: "Source"}], must_mention: $facts}' --args "$@"
}
{
  e2e_question operator-01 "How do I pause it?" "Pause it gently." "pause it" "gently"
  e2e_question evaluator-01 "What does it cost? FAIL-ME" "It costs little. FAIL-ME" "costs" "little"
  e2e_question contributor-01 "How do I test it? ANSWER-CAP" "Run the tests." "run the tests"
  e2e_question cycle-agent-01 "Whom do I ask? GRADE-CAP" "Ask the coordinator." "ask the coordinator"
} >"$e2e/questions.jsonl"

# run_e2e REPORT_DIR ARGS... — the runner against the stub, with variables
# exported that the runs must not see; stderr to $e2e/stderr.
run_e2e() {
  local report_dir="$1"; shift
  DOCS_BENCHMARK_QUESTIONS="$e2e/questions.jsonl" DOCS_BENCHMARK_REPORT_DIR="$report_dir" \
    DOCS_BENCHMARK_SOURCE="$e2e/source" TMPDIR="$e2e/tmp" PATH="$e2e/bin:$PATH" \
    MAX_THINKING_TOKENS=1 CLAUDE_EFFORT=xhigh CLAUDECODE=1 \
    "$RUNNER" "$@" 2>"$e2e/stderr"
}

run_e2e "$e2e/reviews" main >/dev/null
assert_eq "a run with an unanswered or ungraded question exits 1" "1" "$?"
assert_eq "the answering run saw none of the benchmark, no .git and no cleared variable" "" \
  "$(cat "$e2e/leaks" 2>/dev/null)"
assert_eq "its working directory names the repository, not the benchmark" "4:0" \
  "$(grep -c '/agent-ops$' "$e2e/cwds"):$(grep -c 'docs-benchmark' "$e2e/cwds")"
stderr="$(cat "$e2e/stderr")"
assert_contains "the run directory is named before the first question" "this run's transcripts and records are in" \
  "$(head -n 1 <<<"$stderr")"
assert_contains "the paths left out are named" "left test/docs-benchmark/questions.jsonl out of the tree" "$stderr"
full_md="$(find "$e2e/reviews" -name '*-docs-benchmark.md')"
full_jsonl="${full_md%.md}.jsonl"
assert_eq "a full run writes the day's report and records" "1:yes" \
  "$(printf '%s\n' "$full_md" | grep -c .):$([[ -f "$full_jsonl" ]] && echo yes)"
assert_eq "every question has a record" "4" "$(wc -l <"$full_jsonl" | tr -d ' ')"
assert_eq "the records carry the source's commit" "$source_head" "$(jq -r '.commit' "$full_jsonl" | sort -u)"
assert_eq "outcomes: a pass, a fail and two ungraded" \
  "operator-01:true evaluator-01:false contributor-01:ungraded cycle-agent-01:ungraded" \
  "$(jq -r '"\(.id):\(if .grade.status == "graded" then .grade.passed else "ungraded" end)"' "$full_jsonl" | paste -sd' ' -)"
assert_eq "the fail names the missing fact" '["costs"]' \
  "$(jq -c 'select(.id == "evaluator-01") | [.grade.facts[] | select(.present | not) | .fact]' "$full_jsonl")"
assert_eq "an answer stopped at its cap says so" "the answer was stopped at its 900-second cap (exit 124)" \
  "$(jq -r 'select(.id == "contributor-01") | .grade.error' "$full_jsonl")"
assert_eq "so does a grading stopped at its cap" "the grading was stopped at its 300-second cap (exit 124)" \
  "$(jq -r 'select(.id == "cycle-agent-01") | .grade.error' "$full_jsonl")"
assert_eq "tool calls and tokens are recorded" "1:130:5" \
  "$(jq -r 'select(.id == "operator-01") | "\(.tool_calls):\(.input_tokens):\(.output_tokens)"' "$full_jsonl")"
assert_eq "wall times are numbers" "true" "$(jq -s 'all(.[]; (.wall_seconds | type) == "number")' "$full_jsonl")"
full_report="$(cat "$full_md")"
assert_contains "the report lists the timeout as ungraded" "- \`contributor-01\`: the answer was stopped at its 900-second cap" "$full_report"
assert_contains "the report carries the protocol hash" "SHA-256 \`$protocol_hash\` of the definitions" "$full_report"
assert_contains "and the questions hash" "SHA-256 \`$(docs_benchmark_questions_hash "$e2e/questions.jsonl")\`" "$full_report"
assert_not_contains "a run that finished does not say otherwise" "did not finish" "$full_report"
assert_contains "the runner says what it wrote" "wrote $full_md" "$stderr"

run_e2e "$e2e/reviews" main >/dev/null
assert_eq "a second full run the same day takes the -2 suffix" "yes:yes" \
  "$([[ -f "${full_md%.md}-2.md" ]] && echo yes):$([[ -f "${full_md%.md}-2.jsonl" ]] && echo yes)"

run_e2e "$e2e/reviews" --only operator-01 main >/dev/null
assert_eq "a one-question run that passes exits 0" "0" "$?"
only_md="$(find "$e2e/reviews" -name '*-docs-benchmark-only-operator-01.md')"
assert_eq "a one-question run has its own name" "1" "$(printf '%s\n' "$only_md" | grep -c .)"
assert_eq "and leaves the full-run names alone" "2" "$(find "$e2e/reviews" -name '*-docs-benchmark.md' -o -name '*-docs-benchmark-2.md' | wc -l | tr -d ' ')"

# render_hint_files STDERR — the records and run description a run named.
render_hint_files() {
  sed -n 's/^docs-benchmark: the records are in \([^ ]*\) and the run description in \([^;]*\);$/\1 \2/p' <<<"$1"
}

: >"$e2e/blocker"
run_e2e "$e2e/blocker/reviews" --only operator-01 main >/dev/null
assert_eq "a report that cannot be written exits 3" "3" "$?"
stderr="$(cat "$e2e/stderr")"
assert_contains "and says so" "could not write the report" "$stderr"
assert_not_contains "and does not claim to have written it" "docs-benchmark: wrote" "$stderr"
read -r survivor_records survivor_run <<<"$(render_hint_files "$stderr")"
assert_eq "it names the surviving records and run description" "yes:yes" \
  "$([[ -s "$survivor_records" ]] && echo yes):$([[ -s "$survivor_run" ]] && echo yes)"
assert_contains "from which the report renders again" "# Documentation benchmark" \
  "$(docs_benchmark_render_report "$survivor_run" "$survivor_records")"

# Ctrl-C, as the terminal sends it: SIGINT to the runner's process group,
# which `set -m` gives it here. The question in flight is in a group of its
# own, so only the runner can stop it.
{
  e2e_question operator-01 "How do I pause it?" "Pause it gently." "pause it" "gently"
  e2e_question operator-02 "How long does it take? HANG-ME" "A while." "a while"
  e2e_question operator-03 "Is there more?" "No more." "no more"
} >"$e2e/questions-int.jsonl"
: >"$e2e/asked"
rm -f "$e2e/hang.pid"
(
  set -m
  DOCS_BENCHMARK_QUESTIONS="$e2e/questions-int.jsonl" DOCS_BENCHMARK_REPORT_DIR="$e2e/reviews-int" \
    DOCS_BENCHMARK_SOURCE="$e2e/source" TMPDIR="$e2e/tmp" PATH="$e2e/bin:$PATH" \
    "$RUNNER" main >/dev/null 2>"$e2e/stderr-int" &
  runner=$!
  for _ in $(seq 150); do
    [[ -s "$e2e/hang.pid" ]] && break
    sleep 0.2
  done
  started_at=$SECONDS
  kill -INT -- "-$runner"
  wait "$runner"
  echo "$?:$(( SECONDS - started_at ))" >"$e2e/rc-int"
) 2>/dev/null
hang_pid="$(cat "$e2e/hang.pid" 2>/dev/null)"
IFS=: read -r rc_int took_int <"$e2e/rc-int"
assert_eq "Ctrl-C stops the run, with 130" "130" "$rc_int"
assert_eq "at once, not at the question's cap" "yes" "$( (( took_int < 15 )) && echo yes || echo no)"
assert_eq "it stops the question in flight too" "gone" \
  "$([[ -n "$hang_pid" ]] && ! kill -0 "$hang_pid" 2>/dev/null && echo gone || echo running)"
[[ -z "$hang_pid" ]] || kill "$hang_pid" 2>/dev/null
assert_eq "and asks nothing after it" "2" "$(wc -l <"$e2e/asked" | tr -d ' ')"
stderr="$(cat "$e2e/stderr-int")"
assert_contains "it says what stopped it" "stopped by SIGINT" "$stderr"
read -r int_records int_run <<<"$(render_hint_files "$stderr")"
assert_contains "and what it leaves renders, saying the run did not finish" \
  "This run did not finish: it holds 1 of the 3 questions" \
  "$(docs_benchmark_render_report "$int_run" "$int_records" 2>&1)"
assert_eq "it writes no report" "no" "$([[ -e "$e2e/reviews-int" ]] && echo yes || echo no)"

# A host without one of the tools a run needs: nothing is cloned, asked or written.
minbin="$e2e/minbin"
mkdir -p "$minbin" "$e2e/tmp-min"
for tool in bash jq dirname; do ln -s "$(command -v "$tool")" "$minbin/$tool"; done
ln -s "$e2e/bin/claude" "$minbin/claude"
out="$(DOCS_BENCHMARK_QUESTIONS="$e2e/questions.jsonl" DOCS_BENCHMARK_REPORT_DIR="$e2e/reviews-min" \
  DOCS_BENCHMARK_SOURCE="$e2e/source" TMPDIR="$e2e/tmp-min" PATH="$minbin" "$RUNNER" main 2>&1)"
assert_eq "a run without timeout, sha256sum or git cannot start" "2" "$?"
assert_contains "and names each one missing" "not on PATH: timeout sha256sum git" "$out"
assert_eq "and writes nothing" "no:" \
  "$([[ -e "$e2e/reviews-min" ]] && echo yes || echo no):$(ls -A "$e2e/tmp-min")"

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
