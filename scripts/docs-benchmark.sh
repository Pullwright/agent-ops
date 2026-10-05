#!/usr/bin/env bash
#
# scripts/docs-benchmark.sh — score the documentation against a fixed set of
# real questions (requirement 52a of
# docs/spec/implementation/requirements/the-script-01.md, component 24a of
# docs/spec/implementation/components/components-03.md).
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
# description are kept in a temporary directory whose path the run prints
# when it starts. The run description is written before the first question,
# so a run that is stopped part-way can still be rendered.
#
# The questions come from this checkout and the documents from REF, so an
# older ref can be measured with today's questions. The answering run sees a
# plain directory of REF's files, with no `.git`, and without any path named
# `*docs-benchmark*` — this script, its libraries, test, fixtures and
# workflow, the questions with their gold answers, and every earlier report —
# so that no answer can be found by searching for the benchmark itself.
# lib/docs-benchmark.sh's `docs_benchmark_checkout` says why it is done that
# way.
#
# Ctrl-C stops a run, and the question in flight with it; the run then says
# where its records are and how to render them.
#
# `--calibrate` asks nothing of the documentation. It grades each question's
# own gold answer against its own required facts, and reports any question
# that its gold answer fails: a question no answer can pass would lower every
# score for a reason unrelated to the documentation. It clones nothing and
# writes no report. Run it after editing the questions, and before a baseline.
#
# `--check` asks nothing of a model either. It checks the questions file and
# follows every source it cites in this checkout, and exits 1 if any of them
# does not hold. .github/workflows/docs-benchmark.yml runs it on every pull
# request, because a documentation-only change that moves a heading is exactly
# the change that breaks one, and the image's test suite does not run for it.
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
#   scripts/docs-benchmark.sh --check               # check the questions and their sources
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
# score (with --calibrate: when every gold answer passed; with --check: when
# every question and source holds); 1 when at least one was not (with
# --calibrate: when any gold answer failed or went ungraded; with --check:
# when anything does not hold); 2 when the run could not start (a tool it
# needs is not on PATH, a questions file that fails validation or holds no
# records, a ref that does not resolve, a tree that could not be made); 3 when
# the questions were run but the report could not be written, in which case
# the message names the surviving records; 64 for a usage error; and 128 plus
# the signal's number when a signal stopped the run.

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
       docs-benchmark.sh --check

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
  --check      check the questions and follow every source they cite in
               this checkout; launches nothing
USAGE
}

dry_run=0
calibrate=0
check=0
only=""
ref=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --calibrate) calibrate=1; shift ;;
    --check) check=1; shift ;;
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
if (( check )) && { (( dry_run || calibrate )) || [[ -n "$only" || -n "$ref" ]]; }; then
  usage >&2
  exit 64
fi
ref="${ref:-main}"

# require TOOL... — exit 2, naming every tool that is not on PATH, before
# anything is cloned, asked or written. Without `timeout`, for one, every
# question would be recorded as unanswered and a report of nothing written.
require() {
  local tool
  local -a missing=()
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  (( ${#missing[@]} == 0 )) && return 0
  printf 'docs-benchmark: not on PATH: %s\n' "${missing[*]}" >&2
  exit 2
}
require jq

if (( check )); then
  require awk
  if docs_benchmark_check_questions "$QUESTIONS_FILE" "$SCRIPT_DIR"; then
    printf 'docs-benchmark: every question in %s is well formed, and every source it cites holds\n' \
      "${QUESTIONS_FILE#"$SCRIPT_DIR"/}"
    exit 0
  fi
  echo "docs-benchmark: when a document moves, move the sources of the questions that cite it" >&2
  exit 1
fi

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
    printf 'Would check %s out at %s into a temporary directory, with no .git and no %s path,\n' \
      "${source_url:-(this checkout has no origin)}" "$ref" "$DOCS_BENCHMARK_STRIP_PATTERN"
    printf 'and run %d question(s), each with these two commands:\n\n' "${#RECORDS[@]}"
  fi
  for record in "${RECORDS[@]}"; do
    printf '%s [%s] %s\n' "$(jq -r '.id' <<<"$record")" "$(jq -r '.reader' <<<"$record")" \
      "$(jq -r '.question' <<<"$record")"
    if (( ! calibrate )); then
      printf '  answer: '
      command_line "<tree of $ref>" "${DOCS_BENCHMARK_ANSWER_ARGS[@]}"
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

if (( calibrate )); then
  require claude timeout
else
  require claude timeout sha256sum git
fi

run_dir="$(mktemp -d "${TMPDIR:-/tmp}/docs-benchmark.XXXXXX")" || exit 2
empty_dir="$run_dir/empty"
raw_records="$run_dir/records.jsonl"
run_json="$run_dir/run.json"
tree_dir=""
mkdir -p "$empty_dir" "$run_dir/transcripts" || exit 2
printf "docs-benchmark: this run's transcripts and records are in %s\n" "$run_dir" >&2
# The tree and the empty directory go; the transcripts, records and run
# description stay, for whoever wants to see why an answer failed or to render
# the report again.
trap 'rm -rf "$empty_dir" ${tree_dir:+"$tree_dir"}' EXIT

# render_hint — say where the run's records are, and how to render them.
render_hint() {
  printf 'docs-benchmark: the records are in %s and the run description in %s;\n' "$raw_records" "$run_json" >&2
  printf "docs-benchmark: render the report from this checkout with: . lib/docs-benchmark-report.sh && docs_benchmark_render_report %s %s\n" \
    "$run_json" "$raw_records" >&2
}

# stop_run NAME NUMBER — the trap for INT, TERM and HUP. The question in
# flight runs in a process group of its own (see docs_benchmark_launch), which
# a Ctrl-C at the terminal never reaches, so it is stopped here, and waited
# for so that its transcript is whole; then the run says what it leaves.
# shellcheck disable=SC2317  # invoked only through the traps below, which a static reader does not follow
stop_run() {
  trap '' INT TERM HUP
  local pid
  for pid in $(jobs -p); do
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
  done
  wait
  printf 'docs-benchmark: stopped by SIG%s\n' "$1" >&2
  if [[ -s "$run_json" ]]; then
    render_hint
  else
    printf 'docs-benchmark: transcripts are in %s\n' "$run_dir/transcripts" >&2
  fi
  exit $(( 128 + $2 ))
}
trap 'stop_run INT 2' INT
trap 'stop_run TERM 15' TERM
trap 'stop_run HUP 1' HUP

# run_grader RECORD CANDIDATE STREAM — grade one candidate answer, and set
# `grade` (the parsed verdict), `grade_run` and `grade_wall`.
run_grader() {
  local record="$1" candidate="$2" stream="$3" g0 g1 rc
  g0="$EPOCHREALTIME"
  docs_benchmark_launch "$DOCS_BENCHMARK_GRADER_TIMEOUT_SEC" "$empty_dir" "$stream" \
    "$(docs_benchmark_grader_prompt "$record" "$candidate")" "${DOCS_BENCHMARK_GRADER_ARGS[@]}"
  rc=$?
  g1="$EPOCHREALTIME"
  grade_wall="$(docs_benchmark_elapsed "$g0" "$g1")"
  grade="$(docs_benchmark_grade "$stream" "$(jq -c '.must_mention' <<<"$record")" "$rc" "$grade_wall")"
  grade_run="$(docs_benchmark_run_record "$DOCS_BENCHMARK_GRADER_MODEL" "$stream")"
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
tree_dir="$(mktemp -d "${TMPDIR:-/tmp}/$DOCS_BENCHMARK_TREE_NAME.XXXXXX")" || exit 2
tree="$tree_dir/$DOCS_BENCHMARK_TREE_NAME"
if ! git clone --quiet --filter=blob:none --no-checkout "$source_url" "$tree"; then
  echo "docs-benchmark: could not clone $source_url" >&2
  exit 2
fi
commit="$(git -C "$tree" rev-parse --verify --quiet "origin/$ref^{commit}" \
  || git -C "$tree" rev-parse --verify --quiet "$ref^{commit}")" || commit=""
if [[ -z "$commit" ]]; then
  echo "docs-benchmark: $ref does not resolve to a commit in $source_url" >&2
  exit 2
fi
if ! left_out="$(docs_benchmark_checkout "$tree" "$commit")"; then
  echo "docs-benchmark: could not check $commit out without the benchmark" >&2
  exit 2
fi
while IFS= read -r path; do
  [[ -z "$path" ]] || printf 'docs-benchmark: left %s out of the tree\n' "$path" >&2
done <<<"$left_out"

started="$(date -u +%FT%TZ)"
cli_version="$(claude --version 2>/dev/null | head -n 1)"
questions_sha="$(docs_benchmark_questions_hash "$QUESTIONS_FILE")"
protocol_sha="$(docs_benchmark_protocol_hash)"
total=${#RECORDS[@]}

# write_run_json FINISHED RAW — the run's description, for the report. It is
# written before the first question, with FINISHED and RAW empty, so that a
# run stopped part-way can be rendered; and again at the end.
write_run_json() {
  jq -n --arg ref "$ref" --arg commit "$commit" --arg started "$started" --arg finished "$1" \
    --arg cli "$cli_version" --arg questions_sha "$questions_sha" --arg protocol_sha "$protocol_sha" \
    --arg model "$DOCS_BENCHMARK_MODEL" --arg effort "$DOCS_BENCHMARK_EFFORT" \
    --arg grader_model "$DOCS_BENCHMARK_GRADER_MODEL" --arg grader_effort "$DOCS_BENCHMARK_GRADER_EFFORT" \
    --argjson total "$total" --arg raw "$2" --arg only "$only" \
    --argjson readers "$(docs_benchmark_readers_json)" '
    {ref: $ref, commit: $commit, started: $started,
     finished: (if $finished == "" then null else $finished end), cli: $cli,
     questions_sha: $questions_sha, protocol_sha: $protocol_sha,
     model: $model, effort: $effort, grader_model: $grader_model, grader_effort: $grader_effort,
     questions_total: $total, raw: (if $raw == "" then null else $raw end),
     only: $only, readers: $readers}' >"$run_json"
}
if ! { : >"$raw_records" && write_run_json "" ""; }; then
  echo "docs-benchmark: could not write the run description in $run_dir" >&2
  exit 2
fi

incomplete=0
n=0
for record in "${RECORDS[@]}"; do
  n=$(( n + 1 ))
  id="$(jq -r '.id' <<<"$record")"
  printf 'docs-benchmark: [%d/%d] %s\n' "$n" "$total" "$id" >&2
  answer_stream="$run_dir/transcripts/$id.answer.stream.jsonl"

  t0="$EPOCHREALTIME"
  docs_benchmark_launch "$DOCS_BENCHMARK_ANSWER_TIMEOUT_SEC" "$tree" "$answer_stream" \
    "$(docs_benchmark_answer_prompt "$(jq -r '.question' <<<"$record")")" "${DOCS_BENCHMARK_ANSWER_ARGS[@]}"
  answer_rc=$?
  t1="$EPOCHREALTIME"
  wall="$(docs_benchmark_elapsed "$t0" "$t1")"
  answer_run="$(docs_benchmark_run_record "$DOCS_BENCHMARK_MODEL" "$answer_stream")"
  answer_text="$(docs_benchmark_answer_text "$answer_run")"

  if [[ -n "$answer_text" ]]; then
    run_grader "$record" "$answer_text" "$run_dir/transcripts/$id.grade.stream.jsonl"
  else
    grade="$(docs_benchmark_unanswered "$answer_run" "$answer_rc" "$wall")"
    grade_run="null"
    grade_wall="null"
  fi
  [[ "$(jq -r '.status' <<<"$grade")" == "graded" ]] || incomplete=1

  if ! docs_benchmark_record "$record" "$answer_run" "$answer_rc" "$wall" "$grade" "$grade_run" \
    "$grade_wall" "$ref" "$commit" >>"$raw_records"; then
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

# Each step checked, because a run that has spent tokens on every question must
# not report a report it did not write.
report_failed() {
  printf 'docs-benchmark: could not write the report to %s: %s\n' "$REPORT_DIR" "$1" >&2
  render_hint
  exit 3
}
write_run_json "$finished" "$base.jsonl" || report_failed "the run description could not be updated"
mkdir -p "$REPORT_DIR" 2>/dev/null || report_failed "the directory could not be created"
report="$(docs_benchmark_render_report "$run_json" "$raw_records")" || report_failed "the report could not be rendered"
cp "$raw_records" "$REPORT_DIR/$base.jsonl" 2>/dev/null || report_failed "the records could not be copied"
printf '%s\n' "$report" >"$REPORT_DIR/$base.md" 2>/dev/null || report_failed "the report could not be saved"

printf 'docs-benchmark: wrote %s and %s\n' "$REPORT_DIR/$base.md" "$REPORT_DIR/$base.jsonl" >&2
printf 'docs-benchmark: transcripts are in %s\n' "$run_dir/transcripts" >&2
exit "$incomplete"
