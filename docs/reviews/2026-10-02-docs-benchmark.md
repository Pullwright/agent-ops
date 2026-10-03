# Documentation benchmark, 2026-10-02

This is a dated record of one run of `scripts/docs-benchmark.sh`. Each question was asked of headless Claude Code in a checkout of the ref below, without `.git` and without the files of the benchmark itself, and a separate call graded the answer against the gold answer in `test/docs-benchmark/questions.jsonl`. An answer passes when it contains every required fact.

- **Ref:** `main` at `802dc090e022`.
- **Questions:** 54, from a questions file whose ids, readers, questions, gold answers and required facts have SHA-256 `2469038f166a`.
- **Answering model:** `claude-sonnet-5` at `medium` effort, with only the Read, Grep and Glob tools, no MCP servers and project settings only.
- **Grading model:** `claude-opus-5` at `high` effort, with no tools.
- **Claude Code:** 2.1.246 (Claude Code).
- **Protocol:** SHA-256 `3d1294c7f692` of the definitions that `lib/docs-benchmark.sh` names as the protocol.
- **Comparable with:** a run whose questions hash, protocol hash and Claude Code version all match these.
- **Started and finished:** 2026-10-02T22:17:46Z to 2026-10-02T22:59:12Z.
- **Cost:** about $8.63 for answering and grading together.
- **Raw records:** [`2026-10-02-docs-benchmark.jsonl`](2026-10-02-docs-benchmark.jsonl).

## Summary

Medians are over the questions in each row. Input tokens include cache reads and cache writes. A pass rate is over the graded questions only.

| Reader | Questions | Passed | Failed | Ungraded | Pass rate | Median tool calls | Median input tokens | Median output tokens | Median wall time (s) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| target-user | 9 | 2 | 7 | 0 | 22% | 6 | 158790 | 2089 | 38.6 |
| operator | 9 | 2 | 7 | 0 | 22% | 4 | 109329 | 1251 | 23.6 |
| evaluator | 9 | 4 | 5 | 0 | 44% | 5 | 139471 | 1925 | 34.4 |
| contributor | 9 | 5 | 4 | 0 | 56% | 2 | 42156 | 859 | 21.6 |
| cycle-agent | 9 | 3 | 5 | 1 | 38% | 6 | 151551 | 1769 | 30.1 |
| output-reader | 9 | 3 | 6 | 0 | 33% | 5 | 137459 | 1662 | 21.5 |
| **All** | 54 | 19 | 34 | 1 | 36% | 5 | 121121 | 1622 | 25.4 |

## Questions

| Id | Result | Facts present | Tool calls | Input tokens | Output tokens | Wall time (s) |
|---|---|---:|---:|---:|---:|---:|
| `target-user-01` | pass | 4/4 | 4 | 129987 | 1505 | 42.4 |
| `target-user-02` | pass | 4/4 | 14 | 472981 | 4955 | 103.1 |
| `target-user-03` | fail | 2/4 | 3 | 83874 | 877 | 17.8 |
| `target-user-04` | fail | 1/4 | 8 | 158790 | 2358 | 38.6 |
| `target-user-05` | fail | 2/4 | 2 | 64472 | 949 | 21.5 |
| `target-user-06` | fail | 3/4 | 8 | 232194 | 3164 | 47.6 |
| `target-user-07` | fail | 3/4 | 4 | 130285 | 1734 | 30.5 |
| `target-user-08` | fail | 3/4 | 7 | 195870 | 2089 | 36.3 |
| `target-user-09` | fail | 0/4 | 6 | 208174 | 2896 | 43.5 |
| `operator-01` | fail | 2/4 | 8 | 172558 | 1622 | 27.2 |
| `operator-02` | fail | 2/4 | 6 | 119432 | 2058 | 30.4 |
| `operator-03` | fail | 2/3 | 3 | 60801 | 905 | 17 |
| `operator-04` | pass | 4/4 | 2 | 72839 | 1169 | 19.2 |
| `operator-05` | fail | 2/4 | 5 | 136935 | 1054 | 22.1 |
| `operator-06` | fail | 3/4 | 4 | 109329 | 1251 | 23.6 |
| `operator-07` | fail | 2/4 | 5 | 143700 | 2052 | 31.1 |
| `operator-08` | pass | 3/3 | 2 | 66391 | 1080 | 23.6 |
| `operator-09` | fail | 2/4 | 3 | 103290 | 1398 | 25.4 |
| `evaluator-01` | pass | 4/4 | 4 | 139471 | 1986 | 34.4 |
| `evaluator-02` | pass | 4/4 | 4 | 121121 | 1787 | 32.2 |
| `evaluator-03` | fail | 1/4 | 8 | 166048 | 2345 | 35.4 |
| `evaluator-04` | fail | 1/4 | 6 | 162666 | 2498 | 35.4 |
| `evaluator-05` | fail | 3/4 | 5 | 86081 | 1462 | 19.3 |
| `evaluator-06` | pass | 3/3 | 5 | 149948 | 2010 | 39 |
| `evaluator-07` | fail | 3/4 | 4 | 125231 | 1758 | 35.2 |
| `evaluator-08` | fail | 2/4 | 0 | 19663 | 410 | 7.4 |
| `evaluator-09` | pass | 4/4 | 5 | 150426 | 1925 | 33.5 |
| `contributor-01` | fail | 2/3 | 2 | 42156 | 712 | 12.6 |
| `contributor-02` | pass | 4/4 | 1 | 40196 | 859 | 10.9 |
| `contributor-03` | fail | 2/4 | 3 | 64412 | 1681 | 31.5 |
| `contributor-04` | pass | 4/4 | 0 | 19677 | 316 | 22 |
| `contributor-05` | fail | 3/4 | 5 | 104209 | 1342 | 24.3 |
| `contributor-06` | pass | 4/4 | 0 | 19681 | 291 | 11.7 |
| `contributor-07` | pass | 4/4 | 1 | 38703 | 756 | 18 |
| `contributor-08` | fail | 2/4 | 3 | 108842 | 1595 | 27.2 |
| `contributor-09` | pass | 4/4 | 8 | 167475 | 1493 | 21.6 |
| `cycle-agent-01` | fail | 3/4 | 13 | 474779 | 3982 | 57.5 |
| `cycle-agent-02` | fail | 3/4 | 12 | 407125 | 3712 | 72.1 |
| `cycle-agent-03` | pass | 4/4 | 4 | 110138 | 1769 | 30.1 |
| `cycle-agent-04` | pass | 4/4 | 11 | 381450 | 3144 | 42.5 |
| `cycle-agent-05` | fail | 3/4 | 5 | 85998 | 1628 | 23.5 |
| `cycle-agent-06` | fail | 3/4 | 3 | 61049 | 1150 | 13.8 |
| `cycle-agent-07` | ungraded | – | 6 | 151551 | 1576 | 26.4 |
| `cycle-agent-08` | fail | 3/4 | 10 | 270598 | 3121 | 51.5 |
| `cycle-agent-09` | pass | 4/4 | 4 | 101651 | 1207 | 19.8 |
| `output-reader-01` | pass | 4/4 | 9 | 148577 | 1724 | 23.6 |
| `output-reader-02` | fail | 3/4 | 3 | 99568 | 1000 | 19.6 |
| `output-reader-03` | pass | 4/4 | 3 | 94067 | 922 | 18.6 |
| `output-reader-04` | fail | 3/4 | 6 | 158918 | 1550 | 21.5 |
| `output-reader-05` | pass | 4/4 | 10 | 225896 | 2102 | 33.2 |
| `output-reader-06` | fail | 2/3 | 11 | 340021 | 4026 | 76.9 |
| `output-reader-07` | fail | 3/4 | 5 | 120762 | 1875 | 22.9 |
| `output-reader-08` | fail | 3/4 | 2 | 62967 | 806 | 14.9 |
| `output-reader-09` | fail | 2/4 | 5 | 137459 | 1662 | 20.1 |

## Ungraded questions

- `cycle-agent-07`: the grader judged 3 facts, but the question has 4.
