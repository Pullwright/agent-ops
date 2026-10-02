#!/usr/bin/env bash
#
# scripts/docs-benchmark.sh — score the documentation against a fixed set of
# real questions (requirement 52a, component 24a of
# docs/IMPLEMENTATION-PIPELINE-SPEC.md).
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
# input and output tokens (lib/metering.sh's figures); and the wall time. A
# full run writes its report as docs/reviews/<date>-docs-benchmark.md in this
# checkout, with the raw records beside it as <date>-docs-benchmark.jsonl; a
# second full run on the same day takes the suffix -2, then -3. A one-question
# run is named <date>-docs-benchmark-only-<id>.md, so that it never takes the
# day's full-run name. Each run's transcripts, its records and its run
# description are kept in a temporary directory whose path the run prints at
# the end.
#
# The questions come from this checkout and the documents from REF, so an
# older ref can be measured with today's questions. Before the first question,
# lib/docs-benchmark.sh's `docs_benchmark_strip_clone` removes every path named
# `*docs-benchmark*` from the clone — this script, its libraries and test, the
# questions with their gold answers, and every earlier report — so that no
# answer can be found by grepping for the benchmark itself.
#
# `--calibrate` asks nothing of the documentation. It grades each question's
# own gold answer against its own required facts, and reports any question
# that its gold answer fails: a question no answer can pass would lower every
# score for a reason unrelated to the documentation. It clones nothing and
# writes no report. Run it after editing the questions, and before a baseline.
#
# Never run this from a pipeline stage: a stage that launched `claude` would be
# an agent launching an agent, which the specification's Actors section
# forbids. It is not wired into CI or the crontab either, because every run
# spends tokens. Run it by hand, or from an interactive session.
#
# Usage:
#   scripts/docs-benchmark.sh [REF]                 # every question; REF defaults to main
#   scripts/docs-benchmark.sh --only operator-03 REF
#   scripts/docs-benchmark.sh --calibrate           # grade the gold answers themselves
#   scripts/docs-benchmark.sh --dry-run [REF]       # print what would run, launch nothing
#
# REF is anything `git rev-parse` resolves in a clone of this checkout's
# `origin`: a branch, a tag or a commit, so it must have been pushed.
#
# Three environment variables exist for the test, which runs the whole script
# against a stub `claude`; none of them changes the protocol, and the report
# records the hash of whichever questions file was used:
# DOCS_BENCHMARK_QUESTIONS (the questions file), DOCS_BENCHMARK_REPORT_DIR
# (where the report is written) and DOCS_BENCHMARK_SOURCE (what is cloned, in
# place of `origin`).
#
# Exit status: 0 when every question was answered and graded, whatever the
# score (with --calibrate: when every gold answer passed); 1 when at least one
# was not (with --calibrate: when any gold answer failed or went ungraded); 2
# when the run could not start (no `claude`, a questions file that fails
# validation or holds no records, a ref that does not resolve); 3 when the
# questions were run but the report could not be written, in which case the
# message names the surviving records; 64 for a usage error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/docs-benchmark.sh
. "$SCRIPT_DIR/lib/docs-benchmark.sh"
# shellcheck source=lib/docs-benchmark-report.sh
. "$SCRIPT_DIR/lib/docs-benchmark-report.sh"

QUESTIONS_FILE="${DOCS_BENCHMARK_QUESTIONS:-$SCRIPT_DIR/test/docs-benchmark/questions.jsonl}"
REPORT_DIR="${DOCS_BENCHMARK_REPORT_DIR:-$SCRIPT_DIR/docs/reviews}"

usage() {
  cat <<'USAGE'
usage: docs-benchmark.sh [--dry-run] [--only ID] [--calibrate] [REF]

Asks every question in test/docs-benchmark/questions.jsonl of headless Claude
Code in a fresh clone of REF (default: main), grades each answer with a
second call, and writes docs/reviews/<date>-docs-benchmark.md with the raw
records beside it.

  --dry-run    print each question and the commands that would run, and
               launch nothing
  --only ID    run the one question with this id
  --calibrate  grade each question's own gold answer against its required
               facts instead, and report any that fail; clones nothing and
               writes no report
USAGE
}

dry_run=0
calibrate=0
only=""
ref=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --calibrate) calibrate=1; shift ;;
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
declare -i n_records=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  n_records=$(( n_records + 1 ))
  if [[ -z "$only" ]] || [[ "$(jq -r '.id' <<<"$line")" == "$only" ]]; then
    RECORDS+=("$line")
  fi
done < <(jq -c . "$QUESTIONS_FILE")
if (( n_records == 0 )); then
  echo "docs-benchmark: $QUESTIONS_FILE holds no records" >&2
  exit 2
fi
if [[ ${#RECORDS[@]} -eq 0 ]]; then
  echo "docs-benchmark: no question has the id '$only'" >&2
  exit 64
fi

source_url="${DOCS_BENCHMARK_SOURCE:-$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null)}"

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
  if (( calibrate )); then
    printf 'Would grade the gold answers of %d question(s) against their own required facts, each with this command:\n\n' \
      "${#RECORDS[@]}"
  else
    printf 'Would clone %s at %s into a temporary directory, remove every %s path from it,\n' \
      "${source_url:-(this checkout has no origin)}" "$ref" "$DOCS_BENCHMARK_STRIP_PATTERN"
    printf 'and run %d question(s), each with these two commands:\n\n' "${#RECORDS[@]}"
  fi
  for record in "${RECORDS[@]}"; do
    printf '%s [%s] %s\n' "$(jq -r '.id' <<<"$record")" "$(jq -r '.reader' <<<"$record")" \
      "$(jq -r '.question' <<<"$record")"
    if (( ! calibrate )); then
      printf '  answer: '
      command_line "<clone of $ref>" "${DOCS_BENCHMARK_ANSWER_ARGS[@]}"
    fi
    printf '  grade:  '
    command_line "<empty directory>" "${DOCS_BENCHMARK_GRADER_ARGS[@]}"
  done
  if (( ! calibrate )); then
    if [[ -n "$only" ]]; then
      printf '\nWould write %s/%s-docs-benchmark-only-%s.md and .jsonl.\n' "$REPORT_DIR" "$(date -u +%F)" "$only"
    else
      printf '\nWould write %s/%s-docs-benchmark.md and .jsonl.\n' "$REPORT_DIR" "$(date -u +%F)"
    fi
  fi
  exit 0
fi

command -v claude >/dev/null 2>&1 || { echo "docs-benchmark: claude is not on PATH" >&2; exit 2; }

run_dir="$(mktemp -d "${TMPDIR:-/tmp}/docs-benchmark.XXXXXX")" || exit 2
clone="$run_dir/clone"
empty_dir="$run_dir/empty"
mkdir -p "$empty_dir" "$run_dir/transcripts"
# The clone goes; the transcripts, records and run description stay, for
# whoever wants to see why an answer failed or to render the report again.
trap 'rm -rf "$clone" "$empty_dir"' EXIT

# run_grader RECORD CANDIDATE STREAM — run the grader on one candidate answer, and
# set `grade` (the parsed verdict), `grade_run` and `grade_wall`.
run_grader() {
  local record="$1" candidate="$2" stream="$3" g0 g1
  g0="$EPOCHREALTIME"
  ( cd "$empty_dir" && timeout -k 10 "$DOCS_BENCHMARK_GRADER_TIMEOUT_SEC" claude "${DOCS_BENCHMARK_GRADER_ARGS[@]}" \
      <<<"$(docs_benchmark_grader_prompt "$record" "$candidate")" ) \
    >"$stream" 2>"$stream.stderr"
  g1="$EPOCHREALTIME"
  grade="$(docs_benchmark_parse_verdict "$stream" "$(jq -c '.must_mention' <<<"$record")")"
  grade_run="$(docs_benchmark_run_record "$DOCS_BENCHMARK_GRADER_MODEL" "$stream")"
  grade_wall="$(docs_benchmark_elapsed "$g0" "$g1")"
}

if (( calibrate )); then
  failed=0
  for record in "${RECORDS[@]}"; do
    id="$(jq -r '.id' <<<"$record")"
    run_grader "$record" "$(jq -r '.answer' <<<"$record")" "$run_dir/transcripts/$id.calibrate.stream.jsonl"
    case "$(jq -r 'if .status != "graded" then "ungraded" elif .passed then "pass" else "fail" end' <<<"$grade")" in
      pass) printf 'pass      %s\n' "$id" ;;
      fail)
        failed=1
        printf 'FAIL      %s: the gold answer lacks %s\n' "$id" \
          "$(jq -r '[.facts[] | select(.present | not) | "\"\(.fact)\""] | join("; ")' <<<"$grade")" ;;
      *)
        failed=1
        printf 'UNGRADED  %s: %s\n' "$id" "$(jq -r '.error' <<<"$grade")" ;;
    esac
  done
  printf 'docs-benchmark: transcripts are in %s\n' "$run_dir/transcripts" >&2
  exit "$failed"
fi

[[ -n "$source_url" ]] || { echo "docs-benchmark: this checkout has no origin to clone" >&2; exit 2; }
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
while IFS= read -r removed; do
  printf 'docs-benchmark: removed %s from the clone\n' "$removed" >&2
done < <(docs_benchmark_strip_clone "$clone")

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

  t0="$EPOCHREALTIME"
  ( cd "$clone" && timeout -k 10 "$DOCS_BENCHMARK_ANSWER_TIMEOUT_SEC" claude "${DOCS_BENCHMARK_ANSWER_ARGS[@]}" \
      <<<"$(docs_benchmark_answer_prompt "$(jq -r '.question' <<<"$record")")" ) \
    >"$answer_stream" 2>"$answer_stream.stderr"
  answer_rc=$?
  t1="$EPOCHREALTIME"
  answer_run="$(docs_benchmark_run_record "$DOCS_BENCHMARK_MODEL" "$answer_stream")"
  answer_text="$(jq -r 'select(.error == null) | .result // empty' <<<"$answer_run")"

  if [[ -n "$answer_text" ]]; then
    run_grader "$record" "$answer_text" "$run_dir/transcripts/$id.grade.stream.jsonl"
  else
    # Why the question went unanswered, with the exit status kept: 124 is
    # `timeout` stopping the run at its cap, which says to look at the cap,
    # where anything else says to read the stderr file.
    grade="$(jq -nc --argjson run "$answer_run" --argjson rc "$answer_rc" \
      --argjson cap "$DOCS_BENCHMARK_ANSWER_TIMEOUT_SEC" '
      {status: "ungraded",
       error: (if $rc == 124 then "the answer was stopped at its \($cap)-second cap (exit 124)"
               elif $rc != 0 then "\($run.error // "the question was not answered") (exit \($rc))"
               else ($run.error // "the answer was empty") end),
       raw: $run.result}')"
    grade_run="null"
    grade_wall="null"
  fi
  [[ "$(jq -r '.status' <<<"$grade")" == "graded" ]] || incomplete=1

  if ! jq -nc --argjson q "$record" --argjson answer "$answer_run" --argjson grade "$grade" \
    --argjson grade_run "$grade_run" --argjson wall "$(docs_benchmark_elapsed "$t0" "$t1")" \
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
      }' >>"$raw_records"; then
    # A record that cannot be written would otherwise vanish from both tables
    # while the run still read as complete.
    printf 'docs-benchmark: could not record %s; its transcripts are in %s\n' "$id" "$run_dir/transcripts" >&2
    incomplete=1
  fi
done

finished="$(date -u +%FT%TZ)"
date_stamp="${started%%T*}"
if [[ -n "$only" ]]; then
  stem="$date_stamp-docs-benchmark-only-$only"
else
  stem="$date_stamp-docs-benchmark"
fi
base="$stem"
suffix=1
while [[ -e "$REPORT_DIR/$base.md" || -e "$REPORT_DIR/$base.jsonl" ]]; do
  suffix=$(( suffix + 1 ))
  base="$stem-$suffix"
done

run_json="$run_dir/run.json"
jq -n --arg ref "$ref" --arg commit "$commit" --arg started "$started" --arg finished "$finished" \
  --arg cli "$cli_version" --arg questions_sha "$questions_sha" --arg runner_sha "$runner_sha" \
  --arg model "$DOCS_BENCHMARK_MODEL" --arg grader_model "$DOCS_BENCHMARK_GRADER_MODEL" \
  --arg raw "$base.jsonl" --arg only "$only" --argjson readers "$(docs_benchmark_readers_json)" \
  '{ref: $ref, commit: $commit, started: $started, finished: $finished, cli: $cli,
    questions_sha: $questions_sha, runner_sha: $runner_sha, model: $model,
    grader_model: $grader_model, raw: $raw, only: $only, readers: $readers}' >"$run_json"

# Each step checked, because a run that has spent tokens on every question must
# not report a report it did not write.
report_failed() {
  printf 'docs-benchmark: could not write the report to %s: %s\n' "$REPORT_DIR" "$1" >&2
  printf 'docs-benchmark: the records survive in %s and the run description in %s;\n' "$raw_records" "$run_json" >&2
  printf "docs-benchmark: render the report again from this checkout with: . lib/docs-benchmark-report.sh && docs_benchmark_render_report %s %s\n" \
    "$run_json" "$raw_records" >&2
  exit 3
}
mkdir -p "$REPORT_DIR" 2>/dev/null || report_failed "the directory could not be created"
report="$(docs_benchmark_render_report "$run_json" "$raw_records")" || report_failed "the report could not be rendered"
cp "$raw_records" "$REPORT_DIR/$base.jsonl" 2>/dev/null || report_failed "the records could not be copied"
printf '%s\n' "$report" >"$REPORT_DIR/$base.md" 2>/dev/null || report_failed "the report could not be saved"

printf 'docs-benchmark: wrote %s and %s\n' "$REPORT_DIR/$base.md" "$REPORT_DIR/$base.jsonl" >&2
printf 'docs-benchmark: transcripts are in %s\n' "$run_dir/transcripts" >&2
exit "$incomplete"
