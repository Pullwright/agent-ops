# Documentation benchmark, 2026-10-02

This is a dated record of one run of `scripts/docs-benchmark.sh`. Each question was asked of headless Claude Code in a checkout of the ref below, without `.git` and without the files of the benchmark itself, and a separate call graded the answer against the gold answer in `test/docs-benchmark/questions.jsonl`. An answer passes when it contains every required fact.

- **Ref:** `802dc090e022556d26a58efbdf6f4da8515a9fe1` at `802dc090e022`.
- **Questions:** 54, from a questions file whose ids, readers, questions, gold answers and required facts have SHA-256 `2469038f166a`.
- **Answering model:** `claude-sonnet-5` at `medium` effort, with only the Read, Grep and Glob tools, no MCP servers and project settings only.
- **Grading model:** `claude-opus-5` at `high` effort, with no tools.
- **Claude Code:** 2.1.246 (Claude Code).
- **Protocol:** SHA-256 `3d1294c7f692` of the definitions that `lib/docs-benchmark.sh` names as the protocol.
- **Comparable with:** a run whose questions hash, protocol hash and Claude Code version all match these.
- **Started and finished:** 2026-10-02T23:13:41Z to 2026-10-02T23:54:19Z.
- **Cost:** about $8.64 for answering and grading together.
- **Raw records:** [`2026-10-02-docs-benchmark-2.jsonl`](2026-10-02-docs-benchmark-2.jsonl).

## Summary

Medians are over the questions in each row. Input tokens include cache reads and cache writes. A pass rate is over the graded questions only.

| Reader | Questions | Passed | Failed | Ungraded | Pass rate | Median tool calls | Median input tokens | Median output tokens | Median wall time (s) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| target-user | 9 | 1 | 8 | 0 | 11% | 4 | 124569 | 1549 | 24.7 |
| operator | 9 | 3 | 6 | 0 | 33% | 4 | 109864 | 1354 | 25.9 |
| evaluator | 9 | 3 | 6 | 0 | 33% | 5 | 139323 | 1799 | 32.6 |
| contributor | 9 | 4 | 5 | 0 | 44% | 3 | 60791 | 1095 | 21.7 |
| cycle-agent | 9 | 4 | 5 | 0 | 44% | 8 | 174748 | 2245 | 28.2 |
| output-reader | 9 | 3 | 6 | 0 | 33% | 4 | 102015 | 1417 | 20.6 |
| **All** | 54 | 18 | 36 | 0 | 33% | 5 | 113940 | 1541 | 25.6 |

## Questions

| Id | Result | Facts present | Tool calls | Input tokens | Output tokens | Wall time (s) |
|---|---|---:|---:|---:|---:|---:|
| `target-user-01` | fail | 3/4 | 4 | 112805 | 1147 | 23.3 |
| `target-user-02` | pass | 4/4 | 3 | 98821 | 1147 | 21.9 |
| `target-user-03` | fail | 2/4 | 5 | 140565 | 1549 | 24.7 |
| `target-user-04` | fail | 1/4 | 4 | 124569 | 2629 | 37.8 |
| `target-user-05` | fail | 3/4 | 3 | 89064 | 1243 | 21.6 |
| `target-user-06` | fail | 2/4 | 7 | 202432 | 2466 | 31.1 |
| `target-user-07` | fail | 3/4 | 4 | 117874 | 1359 | 17.9 |
| `target-user-08` | fail | 1/4 | 8 | 254877 | 3215 | 44.4 |
| `target-user-09` | fail | 2/4 | 9 | 338265 | 3625 | 62.2 |
| `operator-01` | fail | 3/4 | 5 | 130411 | 2265 | 41.2 |
| `operator-02` | fail | 3/4 | 12 | 318787 | 4423 | 61.8 |
| `operator-03` | fail | 2/3 | 3 | 60770 | 870 | 10.9 |
| `operator-04` | pass | 4/4 | 3 | 85652 | 1354 | 25.9 |
| `operator-05` | fail | 1/4 | 2 | 64156 | 531 | 8.8 |
| `operator-06` | pass | 4/4 | 2 | 67034 | 770 | 10.7 |
| `operator-07` | fail | 2/4 | 7 | 176925 | 2572 | 39.1 |
| `operator-08` | pass | 3/3 | 4 | 109864 | 938 | 24.7 |
| `operator-09` | fail | 0/4 | 10 | 219435 | 3150 | 56.6 |
| `evaluator-01` | pass | 4/4 | 6 | 160718 | 1776 | 32.6 |
| `evaluator-02` | fail | 3/4 | 3 | 71688 | 1662 | 28.8 |
| `evaluator-03` | fail | 1/4 | 8 | 207383 | 2757 | 38.9 |
| `evaluator-04` | fail | 1/4 | 5 | 139323 | 2141 | 35.7 |
| `evaluator-05` | fail | 3/4 | 9 | 107619 | 2486 | 31.3 |
| `evaluator-06` | fail | 1/3 | 5 | 148372 | 2102 | 40.8 |
| `evaluator-07` | pass | 4/4 | 5 | 133044 | 1541 | 26.8 |
| `evaluator-08` | fail | 0/4 | 1 | 39564 | 517 | 14.4 |
| `evaluator-09` | pass | 4/4 | 8 | 218153 | 1799 | 33.8 |
| `contributor-01` | fail | 2/3 | 2 | 60791 | 629 | 14.6 |
| `contributor-02` | pass | 4/4 | 1 | 40201 | 1102 | 21.7 |
| `contributor-03` | fail | 2/4 | 4 | 60200 | 1800 | 25.6 |
| `contributor-04` | fail | 3/4 | 5 | 101509 | 1095 | 25.1 |
| `contributor-05` | fail | 3/4 | 5 | 104294 | 1449 | 24.3 |
| `contributor-06` | pass | 4/4 | 0 | 19677 | 385 | 7.8 |
| `contributor-07` | pass | 4/4 | 0 | 19687 | 631 | 15 |
| `contributor-08` | fail | 2/4 | 3 | 108246 | 1077 | 15.3 |
| `contributor-09` | pass | 4/4 | 5 | 144669 | 1768 | 24.7 |
| `cycle-agent-01` | pass | 4/4 | 12 | 389783 | 3043 | 51.1 |
| `cycle-agent-02` | fail | 3/4 | 18 | 723830 | 5706 | 86.7 |
| `cycle-agent-03` | pass | 4/4 | 4 | 121898 | 1868 | 25.6 |
| `cycle-agent-04` | pass | 4/4 | 7 | 169914 | 2245 | 28.7 |
| `cycle-agent-05` | fail | 3/4 | 8 | 174748 | 2183 | 26.8 |
| `cycle-agent-06` | fail | 3/4 | 4 | 67732 | 1078 | 21.2 |
| `cycle-agent-07` | fail | 2/4 | 8 | 194286 | 2304 | 40.9 |
| `cycle-agent-08` | fail | 3/4 | 9 | 277246 | 2265 | 28.2 |
| `cycle-agent-09` | pass | 4/4 | 4 | 102059 | 1068 | 13.3 |
| `output-reader-01` | fail | 2/4 | 3 | 99560 | 1525 | 17.7 |
| `output-reader-02` | fail | 3/4 | 4 | 84522 | 1106 | 18.1 |
| `output-reader-03` | pass | 4/4 | 3 | 94743 | 1250 | 20.6 |
| `output-reader-04` | fail | 2/4 | 6 | 158137 | 1520 | 26.2 |
| `output-reader-05` | pass | 4/4 | 11 | 269530 | 3093 | 44.9 |
| `output-reader-06` | pass | 3/3 | 5 | 102015 | 1328 | 19.3 |
| `output-reader-07` | fail | 3/4 | 6 | 163944 | 1640 | 27.2 |
| `output-reader-08` | fail | 2/4 | 2 | 72890 | 905 | 18.2 |
| `output-reader-09` | fail | 2/4 | 4 | 113940 | 1417 | 28.8 |
