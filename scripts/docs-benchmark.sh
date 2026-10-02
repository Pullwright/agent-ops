#!/usr/bin/env bash
#
# scripts/docs-benchmark.sh — score the documentation against a fixed set of
# real questions (component 24a of docs/IMPLEMENTATION-PIPELINE-SPEC.md,
# agent-ops#2086).
#
# The questions are test/docs-benchmark/questions.jsonl: each is asked the way
# one of six readers would ask it, with a gold answer, the documents that state
# it, and the facts a correct answer must contain. This runner asks every
# question of headless Claude Code in a fresh clone of REF, with the fixed
# model and the read-only tool set lib/docs-benchmark.sh declares, then has a
# second, separate call grade each answer against the gold one. Scored before
# and after a documentation change, the same questions say whether people and
# agents now find what they need more quickly and more correctly, which is the
# point of measuring at all.
#
# For each question it records the answer; whether the answer contains every
# required fact, with the grader's reasoning; the number of tool calls; the
# input and output tokens (lib/metering.sh's figures); and the wall time. It
# writes the summary as a dated report, docs/reviews/<date>-docs-benchmark.md
# in this checkout, with the raw records beside it as
# docs/reviews/<date>-docs-benchmark.jsonl. Each run's transcripts are kept in
# a temporary directory whose path the run prints at the end.
#
# The questions come from this checkout and the documents from REF, so an
# older ref can be measured with today's questions. Every path named
# `*docs-benchmark*` is removed from the clone before the first question —
# this script, its library and test, the questions with their gold answers,
# and every earlier report — so that no answer can be found by grepping for
# the benchmark itself.
#
# Never run this from a pipeline stage: a stage that launched `claude` would be
# an agent launching an agent, which the specification's Actors section
# forbids. It is not wired into CI or the crontab either, because every run
# spends tokens. Run it by hand, or from an interactive session.
#
# Usage:
#   scripts/docs-benchmark.sh [REF]                 # every question; REF defaults to main
#   scripts/docs-benchmark.sh --only operator-03 REF
#   scripts/docs-benchmark.sh --dry-run [REF]       # print what would run, launch nothing
#
# REF is anything `git rev-parse` resolves in a clone of this checkout's
# `origin`: a branch, a tag or a commit, so it must have been pushed.
#
# Exit status: 0 when every question was answered and graded, whatever the
# score; 1 when at least one was not; 2 when the run could not start (no
# `claude`, a questions file that fails validation, a ref that does not
# resolve); 64 for a usage error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/docs-benchmark.sh
. "$SCRIPT_DIR/lib/docs-benchmark.sh"

QUESTIONS_FILE="$SCRIPT_DIR/test/docs-benchmark/questions.jsonl"
REPORT_DIR="$SCRIPT_DIR/docs/reviews"
ANSWER_TIMEOUT_SEC=900
GRADER_TIMEOUT_SEC=300

usage() {
  cat <<'USAGE'
usage: docs-benchmark.sh [--dry-run] [--only ID] [REF]

Asks every question in test/docs-benchmark/questions.jsonl of headless Claude
Code in a fresh clone of REF (default: main), grades each answer with a
second call, and writes docs/reviews/<date>-docs-benchmark.md with the raw
records beside it.

  --dry-run   print each question and the commands that would run, and
              launch nothing
  --only ID   run the one question with this id
USAGE
}

dry_run=0
only=""
ref=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --only)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 64; }
      only="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 64 ;;
    *)
      [[ -z "$ref" ]] || { usage >&2; exit 64; }
      ref="$1"; shift ;;
  esac
done
ref="${ref:-main}"

if ! docs_benchmark_check_questions "$QUESTIONS_FILE" >&2; then
  echo "docs-benchmark: $QUESTIONS_FILE fails validation" >&2
  exit 2
fi

declare -a RECORDS=()
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  if [[ -z "$only" ]] || [[ "$(jq -r '.id' <<<"$line")" == "$only" ]]; then
    RECORDS+=("$line")
  fi
done < <(jq -c . "$QUESTIONS_FILE")
if [[ ${#RECORDS[@]} -eq 0 ]]; then
  echo "docs-benchmark: no question has the id '$only'" >&2
  exit 64
fi

source_url="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null)" || source_url=""

# command_line CWD ARGS...
# The command for one run, as one line for the dry run: CWD is printed as
# given, since it names a directory that does not exist yet, and each argument
# is quoted only when the shell would need it to be.
command_line() {
  local cwd="$1" arg; shift
  printf 'cd %s && claude' "$cwd"
  for arg in "$@"; do
    if [[ "$arg" =~ ^[A-Za-z0-9_./:=,@+-]+$ ]]; then
      printf ' %s' "$arg"
    else
      printf ' %s' "${arg@Q}"
    fi
  done
  printf ' <prompt-on-stdin\n'
}

if (( dry_run )); then
  printf 'Would clone %s at %s into a temporary directory, remove every *docs-benchmark* path from it,\n' \
    "${source_url:-(this checkout has no origin)}" "$ref"
  printf 'and run %d question(s), each with these two commands:\n\n' "${#RECORDS[@]}"
  for record in "${RECORDS[@]}"; do
    printf '%s [%s] %s\n' "$(jq -r '.id' <<<"$record")" "$(jq -r '.reader' <<<"$record")" \
      "$(jq -r '.question' <<<"$record")"
    printf '  answer: '
    command_line "<clone of $ref>" "${DOCS_BENCHMARK_ANSWER_ARGS[@]}"
    printf '  grade:  '
    command_line "<empty directory>" "${DOCS_BENCHMARK_GRADER_ARGS[@]}"
  done
  printf '\nWould write %s/%s-docs-benchmark.md and %s-docs-benchmark.jsonl.\n' \
    "$REPORT_DIR" "$(date -u +%F)" "$(date -u +%F)"
  exit 0
fi

command -v claude >/dev/null 2>&1 || { echo "docs-benchmark: claude is not on PATH" >&2; exit 2; }
[[ -n "$source_url" ]] || { echo "docs-benchmark: this checkout has no origin to clone" >&2; exit 2; }

run_dir="$(mktemp -d "${TMPDIR:-/tmp}/docs-benchmark.XXXXXX")" || exit 2
clone="$run_dir/clone"
empty_dir="$run_dir/empty"
mkdir -p "$empty_dir" "$run_dir/transcripts"
# The clone goes; the transcripts stay, for whoever wants to see why an answer
# failed.
trap 'rm -rf "$clone" "$empty_dir"' EXIT

if ! git clone --quiet --filter=blob:none --no-checkout "$source_url" "$clone"; then
  echo "docs-benchmark: could not clone $source_url" >&2
  exit 2
fi
commit="$(git -C "$clone" rev-parse --verify --quiet "origin/$ref^{commit}" \
  || git -C "$clone" rev-parse --verify --quiet "$ref^{commit}")" || commit=""
if [[ -z "$commit" ]] || ! git -C "$clone" checkout --quiet --detach "$commit"; then
  echo "docs-benchmark: $ref does not resolve to a commit in $source_url" >&2
  exit 2
fi
while IFS= read -r -d '' path; do
  printf 'docs-benchmark: removed %s from the clone\n' "${path#"$clone"/}" >&2
  rm -rf "$path"
done < <(find "$clone" -path "$clone/.git" -prune -o -name '*docs-benchmark*' -print0)

started="$(date -u +%FT%TZ)"
cli_version="$(claude --version 2>/dev/null | head -n 1)"
questions_sha="$(sha256sum "$QUESTIONS_FILE" | cut -c1-12)"
runner_sha="$(sha256sum "$SCRIPT_DIR/lib/docs-benchmark.sh" | cut -c1-12)"
raw_records="$run_dir/records.jsonl"
: >"$raw_records"
incomplete=0
total=${#RECORDS[@]}
n=0

for record in "${RECORDS[@]}"; do
  n=$(( n + 1 ))
  id="$(jq -r '.id' <<<"$record")"
  printf 'docs-benchmark: [%d/%d] %s\n' "$n" "$total" "$id" >&2
  answer_stream="$run_dir/transcripts/$id.answer.stream.jsonl"
  grade_stream="$run_dir/transcripts/$id.grade.stream.jsonl"

  t0="$EPOCHREALTIME"
  ( cd "$clone" && timeout -k 10 "$ANSWER_TIMEOUT_SEC" claude "${DOCS_BENCHMARK_ANSWER_ARGS[@]}" \
      <<<"$(docs_benchmark_answer_prompt "$(jq -r '.question' <<<"$record")")" ) \
    >"$answer_stream" 2>"$answer_stream.stderr"
  answer_rc=$?
  t1="$EPOCHREALTIME"
  answer_run="$(docs_benchmark_run_record "$DOCS_BENCHMARK_MODEL" "$answer_stream")"
  answer_text="$(jq -r 'select(.error == null) | .result // empty' <<<"$answer_run")"

  if [[ -n "$answer_text" ]]; then
    g0="$EPOCHREALTIME"
    ( cd "$empty_dir" && timeout -k 10 "$GRADER_TIMEOUT_SEC" claude "${DOCS_BENCHMARK_GRADER_ARGS[@]}" \
        <<<"$(docs_benchmark_grader_prompt "$record" "$answer_text")" ) \
      >"$grade_stream" 2>"$grade_stream.stderr"
    g1="$EPOCHREALTIME"
    grade="$(docs_benchmark_parse_verdict "$grade_stream" "$(jq -c '.must_mention' <<<"$record")")"
    grade_run="$(docs_benchmark_run_record "$DOCS_BENCHMARK_GRADER_MODEL" "$grade_stream")"
    grade_wall="$(jq -n "$g1 - $g0")"
  else
    grade="$(jq -nc --arg why "the question was not answered (exit $answer_rc)" --argjson run "$answer_run" \
      '{status: "ungraded", error: ($run.error // $why), raw: $run.result}')"
    grade_run="null"
    grade_wall="null"
  fi
  [[ "$(jq -r '.status' <<<"$grade")" == "graded" ]] || incomplete=1

  jq -nc --argjson q "$record" --argjson answer "$answer_run" --argjson grade "$grade" \
    --argjson grade_run "$grade_run" --argjson wall "$(jq -n "$t1 - $t0")" \
    --argjson grade_wall "$grade_wall" --argjson rc "$answer_rc" \
    --arg ref "$ref" --arg commit "$commit" --arg model "$DOCS_BENCHMARK_MODEL" \
    --arg grader_model "$DOCS_BENCHMARK_GRADER_MODEL" '
    ($answer.metering.tokens // {}) as $t
    | {
        id: $q.id, reader: $q.reader, question: $q.question,
        ref: $ref, commit: $commit, model: $model,
        answer: $answer.result,
        answer_exit_code: $rc,
        answer_error: $answer.error,
        grade: $grade,
        tool_calls: $answer.tool_calls,
        tool_calls_by_tool: $answer.tool_calls_by_tool,
        permission_denials: $answer.permission_denials,
        num_turns: $answer.metering.num_turns,
        input_tokens: (if $t == {} then null
                       else (($t.input // 0) + ($t.cache_creation // 0) + ($t.cache_read // 0)) end),
        output_tokens: ($t.output // null),
        tokens: $answer.metering.tokens,
        cost_usd: $answer.metering.cost_usd,
        wall_seconds: $wall,
        grader: {model: $grader_model, wall_seconds: $grade_wall,
                 cost_usd: (if $grade_run == null then null else $grade_run.metering.cost_usd end),
                 tokens: (if $grade_run == null then null else $grade_run.metering.tokens end)}
      }' >>"$raw_records"
done

finished="$(date -u +%FT%TZ)"
date_stamp="${started%%T*}"
mkdir -p "$REPORT_DIR"
base="$date_stamp-docs-benchmark"
suffix=1
while [[ -e "$REPORT_DIR/$base.md" || -e "$REPORT_DIR/$base.jsonl" ]]; do
  suffix=$(( suffix + 1 ))
  base="$date_stamp-docs-benchmark-$suffix"
done
cp "$raw_records" "$REPORT_DIR/$base.jsonl"

readers_json="$(printf '%s\n' "${DOCS_BENCHMARK_READERS[@]}" | jq -R . | jq -sc .)"
jq -rs --arg ref "$ref" --arg commit "$commit" --arg started "$started" --arg finished "$finished" \
  --arg cli "$cli_version" --arg questions_sha "$questions_sha" --arg runner_sha "$runner_sha" \
  --arg model "$DOCS_BENCHMARK_MODEL" --arg grader_model "$DOCS_BENCHMARK_GRADER_MODEL" \
  --arg raw "$base.jsonl" --arg only "$only" --argjson readers "$readers_json" '
  def median: map(select(type == "number")) | sort
    | if length == 0 then null else .[((length * 0.5) | ceil) - 1] end;
  def num: if . == null then "–" elif (type == "number" and . != floor) then (. * 10 | round / 10 | tostring) else tostring end;
  def outcome: if .grade.status != "graded" then "ungraded" elif .grade.passed then "pass" else "fail" end;
  def row($label; $rs):
    ($rs | length) as $n
    | ([$rs[] | select(outcome == "pass")] | length) as $p
    | ([$rs[] | select(outcome == "fail")] | length) as $f
    | ([$rs[] | select(outcome == "ungraded")] | length) as $u
    | "| \($label) | \($n) | \($p) | \($f) | \($u) | "
      + (if ($n - $u) == 0 then "–" else "\((100 * $p / ($n - $u)) | round)%" end)
      + " | \([$rs[].tool_calls] | median | num) | \([$rs[].input_tokens] | median | num)"
      + " | \([$rs[].output_tokens] | median | num) | \([$rs[].wall_seconds] | median | num) |";
  . as $all
  | ([$all[].cost_usd, $all[].grader.cost_usd] | map(select(type == "number")) | add // 0) as $cost
  | [
      "# Documentation benchmark, \($started[0:10])",
      "",
      "This is a dated record of one run of `scripts/docs-benchmark.sh`. Each question was asked of headless Claude Code in a fresh clone of the ref below, and a separate call graded the answer against the gold answer in `test/docs-benchmark/questions.jsonl`. An answer passes when it contains every required fact.",
      "",
      (if $only != "" then "This was a partial run of one question, `\($only)`, and is not comparable with a full run.\n" else empty end),
      "- **Ref:** `\($ref)` at `\($commit[0:12])`.",
      "- **Questions:** \($all | length), from a questions file with SHA-256 `\($questions_sha)`.",
      "- **Answering model:** `\($model)`, with only the Read, Grep and Glob tools, no MCP servers and project settings only.",
      "- **Grading model:** `\($grader_model)`, with no tools.",
      "- **Claude Code:** \($cli).",
      "- **Protocol:** `lib/docs-benchmark.sh` with SHA-256 `\($runner_sha)`. Two runs are comparable when both hashes match.",
      "- **Started and finished:** \($started) to \($finished).",
      "- **Cost:** about $\($cost * 100 | round / 100) for answering and grading together.",
      "- **Raw records:** [`\($raw)`](\($raw)).",
      "",
      "## Summary",
      "",
      "Medians are over the questions in each row. Input tokens include cache reads and cache writes.",
      "",
      "| Reader | Questions | Passed | Failed | Ungraded | Pass rate | Median tool calls | Median input tokens | Median output tokens | Median wall time (s) |",
      "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
      ($readers[] as $r | [$all[] | select(.reader == $r)] | select(length > 0) | row($r; .)),
      row("**All**"; $all),
      "",
      "## Questions",
      "",
      "| Id | Result | Facts present | Tool calls | Input tokens | Output tokens | Wall time (s) |",
      "|---|---|---:|---:|---:|---:|---:|",
      ($all[] | "| `\(.id)` | \(outcome) | "
        + (if .grade.status == "graded" then "\(.grade.facts_present)/\(.grade.facts_total)" else "–" end)
        + " | \(.tool_calls | num) | \(.input_tokens | num) | \(.output_tokens | num) | \(.wall_seconds | num) |"),
      "",
      (if ([$all[] | select(outcome == "ungraded")] | length) > 0 then
         "## Ungraded questions\n\n" + ([$all[] | select(outcome == "ungraded") | "- `\(.id)`: \(.grade.error)."] | join("\n")) + "\n"
       else empty end),
      (if ([$all[] | select(outcome != "ungraded") | select(.grade.verdict_consistent == false)] | length) > 0 then
         "## Grader inconsistencies\n\nFor these questions the overall verdict of the grader disagreed with its own per-fact judgements, and the per-fact judgements were used.\n\n"
         + ([$all[] | select(outcome != "ungraded") | select(.grade.verdict_consistent == false) | "- `\(.id)`"] | join("\n")) + "\n"
       else empty end)
    ] | join("\n")' "$raw_records" >"$REPORT_DIR/$base.md"

printf 'docs-benchmark: wrote %s and %s\n' "$REPORT_DIR/$base.md" "$REPORT_DIR/$base.jsonl" >&2
printf 'docs-benchmark: transcripts are in %s\n' "$run_dir/transcripts" >&2
exit "$incomplete"
