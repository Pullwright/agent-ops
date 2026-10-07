#!/usr/bin/env bash
#
# lib/docs-benchmark-report.sh — the documentation benchmark's dated report
# (component 24a of docs/spec/implementation/components/components-03.md).
#
# Sourced by scripts/docs-benchmark.sh and by test/docs-benchmark.test.sh. The
# report's layout is not part of the benchmark's protocol (see the head of
# lib/docs-benchmark.sh), so rewording a table heading leaves every report
# comparable with the ones before it.

# docs_benchmark_render_report RUN_JSON RECORDS_JSONL
# Print the Markdown report for one run. A pure function of two files: RUN_JSON
# describes the run (`ref`, `commit`, `started`, `finished` — null while the
# run is in progress or if it never finished — `cli`, `questions_sha`,
# `protocol_sha`, `model`, `effort`, `grader_model`, `grader_effort`,
# `questions_total`, `raw` — the records' file name as the report links it,
# null until the report is written — `only`, and `readers`, the report order),
# and RECORDS_JSONL holds one record per question as the runner writes them.
# The runner keeps both in its run directory from the first question on, so a
# report that could not be written, or a run that was stopped part-way, can be
# rendered from them.
#
# A pass rate is over the questions that were graded, never over the ones
# that were not, and a reader with none graded shows `–`. Medians are
# nearest-rank, so every figure is one a question really produced.
docs_benchmark_render_report() {
  local run_json="$1" records="$2"
  jq -rs --slurpfile run "$run_json" '
    $run[0] as $r
    | def median: map(select(type == "number")) | sort
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
    | [$all[] | select(outcome == "ungraded")] as $ungraded
    | [$all[] | select(outcome != "ungraded") | select(.grade.verdict_consistent == false)] as $inconsistent
    | [
        "# Documentation benchmark, \($r.started[0:10])",
        "",
        "This is a dated record of one run of `scripts/docs-benchmark.sh`. Each question was asked of headless Claude Code in a checkout of the ref below, without `.git` and without the files of the benchmark itself, and a separate call graded the answer against the gold answer in `test/docs-benchmark/questions.jsonl`. An answer passes when it contains every required fact.",
        "",
        (if ($r.only // "") != "" then "This was a partial run of one question, `\($r.only)`, and is not comparable with a full run.\n" else empty end),
        (if $r.finished == null then "This run did not finish: it holds \($all | length) of the \($r.questions_total) questions it set out to ask, and is not comparable with a run that finished.\n" else empty end),
        "- **Ref:** `\($r.ref)` at `\($r.commit[0:12])`.",
        "- **Questions:** \($all | length), from a questions file whose ids, readers, questions, gold answers and required facts have SHA-256 `\($r.questions_sha)`.",
        "- **Answering model:** `\($r.model)` at `\($r.effort)` effort, with only the Read, Grep and Glob tools, no MCP servers and project settings only.",
        "- **Grading model:** `\($r.grader_model)` at `\($r.grader_effort)` effort, with no tools.",
        "- **Claude Code:** \($r.cli).",
        "- **Protocol:** SHA-256 `\($r.protocol_sha)` of the definitions that `lib/docs-benchmark.sh` names as the protocol.",
        "- **Comparable with:** a run whose questions hash, protocol hash and Claude Code version all match these.",
        "- **Started and finished:** \($r.started) to \($r.finished // "–, as the run did not finish").",
        "- **Cost:** about $\($cost * 100 | round / 100) for answering and grading together.",
        (if $r.raw == null then "- **Raw records:** `records.jsonl` in the run directory."
         else "- **Raw records:** [`\($r.raw)`](\($r.raw))." end),
        "",
        "## Summary",
        "",
        "Medians are over the questions in each row. Input tokens include cache reads and cache writes. A pass rate is over the graded questions only.",
        "",
        "| Reader | Questions | Passed | Failed | Ungraded | Pass rate | Median tool calls | Median input tokens | Median output tokens | Median wall time (s) |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
        ($r.readers[] as $reader | [$all[] | select(.reader == $reader)] | select(length > 0) | row($reader; .)),
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
        (if ($ungraded | length) > 0 then
           "## Ungraded questions\n\n" + ([$ungraded[] | "- `\(.id)`: \(.grade.error)."] | join("\n")) + "\n"
         else empty end),
        (if ($inconsistent | length) > 0 then
           "## Grader inconsistencies\n\nFor these questions the overall verdict of the grader disagreed with its own per-fact judgements, and the per-fact judgements were used.\n\n"
           + ([$inconsistent[] | "- `\(.id)`"] | join("\n")) + "\n"
         else empty end)
      ] | join("\n")' "$records"
}
