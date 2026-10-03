# Provider seam audit

This is the inventory issue #2130 asks for: every place `lib/`, `scripts/`,
`deploy/`, `prompts/`, the three cycle scripts (`agent-cycle.sh`,
`review-cycle.sh`, `monitor-cycle.sh`), `config.schema.json` and `test/`
assume the Claude Code CLI — rather than any agentic CLI a provider adapter
could substitute — classified so the provider seam (#2131, the `providers`
config block; #2133, the substrate adapter behind the stage launcher) is cut
in the right place. It does not sweep or fix any of them: this is a planning
document, not an as-built specification, so `AGENTS.md`'s as-built rule pulls
no specification in, and no code, prompt or configuration changes ride along
with it. The precedent is
[`docs/PHASE-1-POETIC-SPECIFICS-AUDIT.md`](PHASE-1-POETIC-SPECIFICS-AUDIT.md)
(#584), which inventoried the Poetic-specifics the same way before the sweep
that removed them.

Every hit below was found by a case-insensitive search for `claude`,
`anthropic` and `CLAUDE_` across `lib/`, `scripts/`, `deploy/`, `prompts/`,
`agent-cycle.sh`, `review-cycle.sh`, `monitor-cycle.sh`, `config.schema.json`
and `test/`, run at `main`'s head,
**`17b0ca9f2ef8149c3e465622b79e30b5636a0646`**: 886 matching lines across 48
files (the issue's own rough count, 656, undercounted because it was taken
before this run and over a narrower grep; the gap is almost entirely `test/`,
568 of the 886, covered in its own section below rather than line by line).

## Method

Every matching file was read in full or in grepped context and each hit
classified into one of five classes, the same five the issue names:

1. **The substrate contract** — what a stage launcher needs from *any*
   agentic CLI, independent of which one.
2. **Provider-specific, behind the seam** — what Anthropic's own CLI and
   account model require, which a provider adapter owns and a different
   provider's adapter would own differently.
3. **Prompt text that names the substrate** — model-facing prose, not code,
   that tells the model what it is running under.
4. **Product-development tooling that stays on Claude** — tooling that
   benchmarks or develops this product and is not part of the pipeline it
   ships, so it needs no seam.
5. **Documentation that states the assumption** — prose outside `prompts/`
   that asserts Claude/Anthropic is the (or the only) provider.

Classes 1 and 2 are the ones that matter for #2131/#2133: class 1 is what the
adapter interface must expose, class 2 is what each provider's adapter
implements behind it. For every row in those two classes, this audit records
Grok Build's own documented equivalent — verified on 2026-10-03 against its
[headless-mode guide](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/14-headless-mode.md)
and
[authentication guide](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/02-authentication.md)
— or says plainly that none is documented. These are the gaps #2132's
measurement will have to close; this audit names them, it does not probe
anything live.

## Summary

| Class | What | Rows below |
|---|---|---|
| 1 | The substrate contract: launch, stream, cap, cost, resume | §1 |
| 2 | Provider-specific, behind the seam: binary, credentials, limits, model ids | §2 |
| 3 | Prompt text that names the substrate | §3 |
| 4 | Product-development tooling that stays on Claude | §4 |
| 5 | Documentation that states the assumption | §5 |
| — | Test doubles mirroring classes 1/2 (`test/`, 568 lines, 79 files) | §6 |

## §1 — The substrate contract

What `lib/stage-run.sh`'s `run_claude_stage` (the one stage launcher,
requirement 4d of `docs/IMPLEMENTATION-PIPELINE-SPEC.md`, sourced by
`agent-cycle.sh` and `review-cycle.sh`) needs from the CLI it launches, and
what every stage call site and every reader of its output depends on. This
is the list #2133's adapter interface has to reproduce for a second
provider.

| Operation / field | Today's shape | Reader(s) |
|---|---|---|
| Launch, prompt on stdin (never argv — requirement 4c, Linux's `MAX_ARG_STRLEN`) | `claude "${claude_args[@]}" <<<"$prompt"`, `claude_args=(-p --model "$model" --dangerously-skip-permissions --output-format stream-json --verbose)` | `lib/stage-run.sh:207-209,245` |
| Model selection | `--model "$model"` | same |
| Non-interactive permission bypass | `--dangerously-skip-permissions` | same |
| Streaming progress output, flushed per event | `--output-format stream-json --verbose` → `<stage>.stream.jsonl` | `lib/stage-run.sh`'s poll loop (liveness watchdog, requirement 4e); every call site's own `<stage>.stream.jsonl` |
| Resume an existing session | `--resume "$resume_session_id"` | `lib/stage-attempt.sh`'s `stage_salvage_result` (requirement 9e), `lib/limit-probe` call in `lib/standdown.sh` |
| Process-group kill on timeout | `kill -TERM "-$pid"` / `-KILL`, needs the launched process in its own group (`set -m`) | `lib/stage-run.sh`'s two caps (backstop, watchdog), requirement 9c's signal handler |
| Final envelope: `result` (text or verdict JSON), `session_id` | last line of the stream, truncated into `<stage>.out` | `lib/stage-attempt.sh` (`extract_json_result`, `session_id` for salvage), every stage's own JSON-fence parser |
| Final envelope: `is_error` | same | `lib/metering.sh`, `lib/stage-attempt.sh` |
| Final envelope: `total_cost_usd` | same | `lib/metering.sh` (`cost_usd`), `scripts/publish-dashboard.sh`'s cost scan, `lib/docs-benchmark.sh`/`lib/docs-benchmark-report.sh` |
| Final envelope: `modelUsage` (per-model `inputTokens`/`outputTokens`/`cacheCreationInputTokens`/`cacheReadInputTokens`[/`costUSD`]) | same | `lib/metering.sh` (`tokens`), `scripts/publish-dashboard.sh`'s cost-by-model scan |
| Final envelope: `duration_ms`, `num_turns` | same | `lib/metering.sh` |
| Final envelope: `terminal_reason`, `api_error_status` | same | `lib/stage-attempt.sh`'s `stage_api_refusal`/`authentication_failed` classification |
| In-stream: a top-level `rate_limit_event` with `rate_limit_info.status` (`allowed`/`allowed_warning`/`rejected`) | emitted mid-run, read by a `grep` pre-filter then a `jq` confirmation | `lib/stage-run.sh`'s `stage_rejected_rate_limit` (requirement 4e's third stop condition), `lib/limit-detect.sh`'s `limit_decide_structured` (requirement 10) |
| CLI resolvable on PATH, version queryable | `claude --version`, `command -v claude` | `agent-cycle.sh`/`review-cycle.sh`/`monitor-cycle.sh`'s PATH bootstrap, `scripts/doctor.sh` |
| GitHub budget reading attributed to the stage that just ran | `github_budget_record stage "$stage"`, called unconditionally after every `run_claude_stage` return | `lib/stage-run.sh:370-372` — not substrate-dependent itself, but sited here because it runs on every provider's stage exit alike |

Two things that look like substrate but are not, because nothing downstream
treats the CLI as the source of truth for them: the **gap statistics**
(`stage_gaps_json`, requirement 33a) are the Script's own observation of the
stream file's growth, not a field the CLI emits; and the **GitHub rate limit**
`lib/github-limit.sh` tracks is GitHub's, read from `gh`'s own response
headers — unrelated to, and explicitly distinguished in that file's own
header comment from, the model account's usage limit.

## §2 — Provider-specific, behind the seam

Everything a provider's own adapter would own — the binary, its credentials,
its account-level limits, its model ids and settings — classified with Grok
Build's own documented equivalent beside each, or the gap if none exists.

| Mechanism | Today (Claude Code / Anthropic) | Location(s) | Grok Build equivalent |
|---|---|---|---|
| Binary, installed and pinned | `npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"`, `ARG CLAUDE_CODE_VERSION=2.1.267` | `deploy/docker/Dockerfile:55,160-171` | Not documented in the fetched guides (no install/pin mechanism named) |
| API-key credential | `ANTHROPIC_API_KEY`, read directly by the CLI, "sk-ant-" prefix shape-checked | `.env.example:81-98`, `compose.yaml:48-53,595-597,1076-1078`, `entrypoint.sh:67-73`, `scripts/doctor.sh:2462-2473` | `XAI_API_KEY` (same shape: env var, read directly; no documented key-prefix convention to shape-check) |
| Subscription/OAuth credential, interactive login | `docker compose exec scheduler claude` once, then `claude auth status --json` (`.loggedIn`, `.authMethod`, `.subscriptionType`/`.apiProvider`) | `scripts/doctor.sh:2474-2489`, `deploy/docker/README.md:194-218`, `cloud-init.yaml:5-10,99-105` | `grok login --device-auth` (device-code flow, documented specifically for headless/SSH/container use — no `auth status --json`-shaped query documented; a probe would have to parse `grok login`'s own output or the credential file directly) |
| Credential storage location | config *directory* `~/.claude` (`CLAUDE_CONFIG_DIR`), holding `.credentials.json`, `settings.json`, `projects/`, `sessions/`; global config file `~/.claude.json` moved inside the directory by setting `CLAUDE_CONFIG_DIR` to it | `Dockerfile:204-255`, `entrypoint.sh:44-73`, `lib/node-health.sh:224-226` | `~/.grok/auth.json` (session tokens, `0600`), `~/.grok/mcp_credentials.json` (OAuth), both under `$GROK_HOME` if set — a single override variable, same shape as `CLAUDE_CONFIG_DIR` |
| Settings seeded into the config directory | `deploy/docker/claude-settings.json` (`effortLevel`, `includeCoAuthoredBy`) copied in by `entrypoint.sh` if absent | `entrypoint.sh:63-65` | Not documented — no equivalent settings file named in the guides fetched |
| Egress domains | `api.anthropic.com` (model calls), `platform.claude.com` (OAuth token exchange/refresh/revocation), `claude.ai`/`claude.com` (interactive login only) | `deploy/docker/egress-allowlist.txt:43-55` | Not documented in the fetched guides — xAI's own API/auth domains are not named there |
| Optional-traffic suppression | `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `DISABLE_AUTOUPDATER=1`, `ENABLE_CLAUDEAI_MCP_SERVERS=false` | `compose.yaml:513-523`, `egress-allowlist.txt:12-14` | `GROK_DISABLE_AUTOUPDATER` — narrower: covers the auto-updater only, nothing documented for telemetry/error-reporting/MCP-connector traffic the way Claude Code's one flag does |
| Usage-limit phrase matching | `LIMIT_PHRASE_REGEX` over free text ("hit your .* limit", "usage limit", "rate limit", "usage cap", "quota exceeded"); literal example "You've hit your monthly spend limit · raise it at claude.ai/settings/usage" | `lib/limit-detect.sh`, `test/fixtures/monthly-spend-limit.txt`, `test/fixtures/probe-limited-envelope.txt` | **Gap.** No documented limit-reached phrase or event for Grok Build at all |
| Structured rate-limit event | top-level `rate_limit_event`/`rate_limit_info.status` in the stream (requirement 4e/10) | `lib/stage-run.sh`'s `stage_rejected_rate_limit`, `lib/limit-detect.sh`'s `limit_decide_structured` | **Gap**, confirmed by the fetched headless-mode guide: no `rate_limit_event` is documented anywhere in Grok Build's streaming formats |
| `authentication_failed` classification | phrase-matches the envelope's `result` against `authenticat\|oauth\|unauthori[sz]ed` when `terminal_reason == "api_error"` | `lib/stage-attempt.sh:191-249` | Grok's `error` stream event carries a `message` and spend fields, but no documented terminal-reason/status-code vocabulary to classify against the same way |
| `is_error` on the final envelope | boolean, present/absent | `lib/metering.sh`, `lib/stage-attempt.sh` | **Gap.** The fetched guide documents `stop_reason`/`subtype` on `result`, never a boolean `is_error`; an adapter would have to derive one (e.g. from `stop_reason` or the presence of an `error` event) rather than read it straight across |
| Model-tier capability ranking | `MODEL_TIER_RANK` (`haiku` < `sonnet` < `opus` < `fable`), confirmed against Anthropic's own relative pricing | `lib/model-id.sh:57-62` | Not documented — Grok Build names one model family member (`grok-4.6`) in its examples, no published cross-model tier ordering |
| Model-id qualifier | bare id or `anthropic/`-qualified; any other qualifier fails fast | `lib/model-id.sh:23-43`, `config.schema.json` `$defs.modelId` (pattern `^(anthropic/)?[A-Za-z0-9][A-Za-z0-9._-]*$`), 12 model-bearing config keys (`coordinator_model`, `implementer_model_default`/`_trivial`, `reviewer_model_default`/`_complex`, `approver_model_default`/`_complex`/`_critical`, `enabler_model`/`_critical`, `refiner_model`, `monitor_model`, `repository_review.defaults.model`), each defaulting to a real Claude model id | The mechanism is already provider-ready by construction (an `xai/`-qualified id is exactly the shape `resolve_model_id` would need a second `case` arm for); the *default values* are Anthropic's own, which is correct today and #2131's business to extend, not this audit's |
| Prompt delivery | stdin, via a here-string, specifically to dodge `MAX_ARG_STRLEN` (requirement 4c) | `lib/stage-run.sh:230-244` | **Gap, and the sharpest one in this table.** The fetched guide states plainly that Grok Build does **not** read stdin automatically; prompt delivery is `-p/--single <PROMPT>` (an argument, so it inherits the same `MAX_ARG_STRLEN` exposure requirement 4c exists to avoid) or `--prompt-file <PATH>`. An adapter for this provider cannot reuse the stdin here-string at all — it has to write the assembled prompt to a temp file and pass `--prompt-file`, which is a different failure mode (disk, not argv) requirement 4c's own reasoning does not cover |
| `--resume` | `--resume <session_id>` | `lib/stage-run.sh:209` | `-r/--resume <ID_OR_TITLE>` — same shape |
| Permission bypass flag | `--dangerously-skip-permissions` | `lib/stage-run.sh:207` | `--yolo` or `--permission-mode bypassPermissions` — same shape, two spellings |
| Streaming wire format | `--output-format stream-json --verbose` | `lib/stage-run.sh:208` | `--output-format streaming-messages-json` documented as emitting the same Messages-API `stream-json` wire format, including a terminal `result` carrying `total_cost_usd`, `duration_ms`, `num_turns`, `usage`, `modelUsage` — the closest match in the whole table, and the reason the issue's brief singles it out |
| Partial/omitted cost on an incomplete run | not a documented concept for Claude Code's envelope — `total_cost_usd` is simply absent on a killed run, which `lib/metering.sh` already treats as null | — | Grok Build documents this explicitly: `cost_is_partial`/`usage_is_incomplete` flags, with **all cost floats omitted** whenever any call in the run lacked a cost, "to prevent fake bills". A reader built only against Claude Code's silent-absence convention would not notice this flag exists, but would still degrade correctly, since an adapter that also omits cost floats on the same signal reproduces the behaviour `lib/metering.sh` already expects (absent ⇒ null) |
| Fleet-wide shared-account usage-limit cooldown | "every node shares one Claude account" — a limit any node hits stands the whole fleet down | `lib/standdown.sh:371-372,454-456`, `lib/toggle.sh:510-512`, `scripts/publish-dashboard.sh:1864-1866`, `scripts/render-crontab.sh:6-10`, `.env.example:277-279`, `deploy/docker/README.md:291,664` | Provider-neutral in shape (the mechanism keys on "the account", not on Anthropic specifically) but today's comments and config describe one Anthropic account; a second provider in the same fleet needs this generalised to "the account for *this stage's* provider," which is #2131/#2133's scope, not named as a gap in Grok's own docs since it is this pipeline's own design, not something Grok Build documents |

## §3 — Prompt text that names the substrate

Every stage prompt's own "you are not in an interactive session" framing,
checked line by line rather than assumed uniform:

| Prompt | Wording | Assessment |
|---|---|---|
| `prompts/implementer.md`, `prompts/reviewer.md`, `prompts/approver.md` | "You are not in an interactive Claude Code session. The Script launches you as a single non-interactive `claude -p` invocation…" | **Names the substrate.** Needs a neutral reword (e.g. "a single non-interactive invocation of this stage's own CLI") or, better, a one-line "you are running under `<provider>`" the adapter prepends — the same resolution the issue's class 3 proposes |
| `prompts/coordinator.md` (line 494), `prompts/enabler.md` (lines 29,35), `prompts/refiner.md` (lines 22,28) | "…a single non-interactive invocation with no resumption… the promise that you will be notified when it finishes is a feature of an interactive session, and you are not in one…" | **Already substrate-neutral.** No CLI or vendor named; this wording needs no change for a second provider |
| `prompts/enabler.md` (line 711), `prompts/reviewer.md` (line 771) | "**Never run a long command in the background…** In an interactive Claude Code session a background command or agent finishing re-invokes you…" | **Names the substrate**, in a second, separately-written section of each prompt from the one in the row above — these two files are internally inconsistent: neutral in one place, naming Claude Code by name in another. Needs the same reword as the first row |
| `prompts/project-reviewer.md` | References `.claude/skills/project-review/` directly, five times, as the mechanism the model must stage and never touch | **Names a substrate mechanism, not just prose.** `.claude/skills/` is a Claude Code CLI convention (the CLI loads that directory as invocable skills); an adapter for a provider with no equivalent concept would need either its own skill-loading mechanism or the audited behaviour folded into the prompt text directly, not left as a directory the CLI is trusted to discover |
| `prompts/approver.md`, `prompts/coordinator.md`, `prompts/enabler.md`, `prompts/reviewer.md` | "Read the repo's own `AGENTS.md` — its `CLAUDE.md` imports it, and is the fallback for a repository that has not migrated" | **Names a filename convention, not the pipeline's own substrate.** `CLAUDE.md` is Claude Code's own auto-loaded project-memory file name (the reason this very repository's own `CLAUDE.md` is a one-line `@AGENTS.md` import); the instruction to *read* it is addressed to the model as an explicit tool-call step in every one of these prompts, not relied on as auto-load, so a different provider's model can follow the same instruction against the same two filenames without anything breaking — the coupling here is naming, not behaviour |
| `prompts/coordinator.md` (lines 98, 1732) | `"models": {"default": "claude-sonnet-5", "trivial": "claude-haiku-4-5-20251001"}`, `"model": "claude-sonnet-5"` | **Illustrative sample values**, matching the "genuinely generic (cosmetic)" class the Poetic-specifics audit used for the same pattern — real model ids in a worked example JSON, not load-bearing |

## §4 — Product-development tooling that stays on Claude

`lib/docs-benchmark.sh` and `scripts/docs-benchmark.sh` ask a fixed set of
real documentation questions of headless Claude Code and grade the answers —
measuring *this repository's documentation*, never run from a pipeline
stage (a stage that launched `claude` would be an agent launching an agent,
which the specification's Actors section forbids). It needs no seam: there
is nothing here a second provider's customer ever runs, so cutting one would
spend effort on a tool whose only user is this repository's own maintainer.
Its env-var-clearing lists (`DOCS_BENCHMARK_ENV_CLEARED`/`_KEPT` —
`CLAUDE*`, `ANTHROPIC_*MODEL*`, `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_*`,
etc., `lib/docs-benchmark.sh:90-93`) are themselves class-2-shaped — Claude
Code's own environment-variable vocabulary — but belong to this tool, not
the pipeline; nothing else in classes 1–5 depends on them.

No other file in the search surface fits this class: everything else
either is the pipeline (classes 1–3), documents it (class 5), or tests it
(§6).

## §5 — Documentation that states the assumption

Outside the search surface proper (`docs/` was not grepped for this audit —
only `prompts/`, `lib/`, `scripts/`, `deploy/`, the cycle scripts,
`config.schema.json` and `test/` were, per the issue's own scope), these
documents assert the Claude/Anthropic assumption in prose:

- **`README.md`** — the credential and configuration sections describe the
  two Anthropic credential paths and the model-key defaults the same way
  `deploy/docker/README.md` and `.env.example` do (§2's rows); generated
  from `config.schema.json` by `scripts/render-config-table.sh` where it is
  a config-table region, hand-written elsewhere.
- **`docs/METERING-SCHEMA.md`** — states explicitly, of the envelope §1's
  contract depends on: "This document does not restate that envelope's own
  schema — that is Anthropic's contract, not this repo's, and only a subset
  of it is used here." This is the one piece of documentation that already
  names the seam in exactly the terms this audit uses — the envelope is a
  *provider's* contract, and this repo documents only the fields it reads
  from it.
- **`docs/DASHBOARD-SPEC.md`** — its design decision on plan limits (around
  "Plan limits are not on this page, because they are not obtainable") is
  Anthropic-subscription-specific: "the envelope carries no quota,
  rate-limit, or credits-remaining field of any kind." A second provider's
  envelope may carry one — Grok Build's own `usage`/cost fields (§2) are
  shaped differently enough that this design decision would need
  re-examining per provider, not assumed to generalise.
- **`docs/DATA-HANDLING.md`** — states "The pipeline runs entirely locally,
  with no external service calls except to GitHub via the `gh` CLI." This
  is incomplete independent of the provider seam: every stage run already
  sends repository content read from GitHub to Anthropic's API via `claude`
  (§2's egress-allowlist rows confirm the live egress path), which this
  document never names. Filed as a tech-debt item below rather than fixed
  here, since fixing prose is outside this audit's "no changes" scope.
- **`config.schema.json`**'s `$defs.modelId` `description` — "Anthropic is
  the only executable provider today, so the two forms are the same value;
  a qualifier naming any other provider is rejected at cycle start" — is the
  schema's own accurate, current statement of class 2's model-id row; no
  gap, already as-built.
- **`test/docs-benchmark/questions.jsonl`**'s `evaluator-05` gold answer
  states the same fact for the documentation benchmark's own grading: "Not
  today… Anthropic is the only executable model provider… Non-Claude
  providers are a settled intention on the roadmap (D12), with the first one
  planned to land in Phase 3." This is a **gold fact a provider seam lands
  will falsify** — #2131/#2133 landing, or any phase-numbering change the
  tranche settles on, will need this question's `answer` and `must_mention`
  updated in the same pull request, or the documentation benchmark will
  start failing a question whose premise the product has just outgrown.

## §6 — Test doubles (`test/`, 568 of the 886 hits, 79 files)

Every `test/` hit mirrors a mechanism already classified in §1 or §2 at the
production-code level — it is a test double or fixture, not a fresh
coupling — and groups into four recurring patterns rather than needing
itemisation line by line:

- **Stub `claude` binary exercising §1/§2's doctor and stage-launch checks.**
  `test/doctor.test.sh` (the single biggest file, 54 hits) writes a `stub_bin/
  claude` shell script replying to `--version`, `auth status --json`
  (`STUB_CLAUDE_AUTH_JSON`, `STUB_CLAUDE_NO_AUTH_SUBCOMMAND`) and the
  stream-flushing probe, so §2's credential-check rows are tested without a
  real account. `test/egress-fence.test.sh` asserts the exact four domains
  of §2's allowlist row and the `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`
  flag. `test/stage-prompt-delivery.test.sh`, `stage-stream.test.sh`,
  `stage-watchdog.test.sh`, `stage-salvage.test.sh`, `stage-gaps.test.sh`,
  `stage-overrun.test.sh`, `signal-exit.test.sh`, `finish-then-continue.test.sh`,
  `noop-skip.test.sh`, `cgroup-parent-setup.test.sh`,
  `collect-resource-usage.test.sh`, `node-health-cli.test.sh`,
  `node-health-http.test.sh`, `node-health.test.sh`, `is-docs-only.test.sh`,
  `monitor-cycle.test.sh`, `role.test.sh`, `record-directory-lifetime.test.sh`,
  `rebase-only-wiring.test.sh`, `compose-reconcile.test.sh`,
  `entrypoint.test.sh`, `review-cycle-auth.test.sh` each exercise one of §1's
  launcher/stream/cap/credential behaviours against the same kind of stub.
- **Model-id/tier strings as test data.** `test/model-id.test.sh` (27 hits)
  tests `resolve_model_id`/`model_tier_rank` directly against real bare and
  `anthropic/`-qualified ids; `test/stage-budget.test.sh` (45),
  `stage-budget-apply-join-key.test.sh`, `metering.test.sh` (31),
  `config-schema.test.sh` (36), `autonomy-stage-report.test.sh`,
  `resource-budget-report.test.sh`, `toggle.test.sh`, `github-limit.test.sh`,
  `cycle-state.test.sh`, `candidate-text-compose.test.sh`,
  `coordinator-input-wiring.test.sh`, `coordinator-merge-fallback.test.sh`,
  `approver-wiring.test.sh`, `approver-tech-debt-file-wiring.test.sh`,
  `enabler-tech-debt-file-wiring.test.sh`, `enabler-verdicts.test.sh`,
  `refiner-verdicts.test.sh`, `refiner-priority-triage.test.sh`,
  `open-question-adjudication.test.sh`, `review-claim.test.sh`,
  `review-context-wiring.test.sh`, `review-not-before.test.sh`,
  `review-stage-health-wiring.test.sh`, `verdict-fate-report.test.sh`,
  `node-time-state.test.sh`, `landing-audit-record.test.sh` (10) each use
  literal model-id strings (`claude-opus-5`, `claude-sonnet-5`,
  `claude-haiku-4-5[-20251001]`) as sample data for logic that is itself
  provider-agnostic (budgets, metering arithmetic, audit records) — the
  string is incidental, not a coupling the logic depends on.
- **Dashboard fixture JSON carrying sample model names.**
  `test/fixtures/dashboard-data/*.json` (14 files, the largest being
  `token-economics.json` at 14 hits and `token-economics-dedup.json`),
  `test/dashboard-render.test.sh`, `test/publish-dashboard.test.sh` (22),
  `test/render-config-table.test.sh` carry `"model": "claude-sonnet-5-…"`
  as sample rows for rendering logic that reads `modelUsage`/`cost_usd`
  generically (§1's envelope fields) — again incidental sample data.
- **`docs-benchmark` harness fixtures.** `test/docs-benchmark.test.sh` (25),
  `test/docs-benchmark/questions.jsonl` (9, including `evaluator-05` from
  §5), `test/fixtures/docs-benchmark/answer.stream.jsonl` (25) and
  `grade.stream.jsonl` test §4's tool against a stubbed `claude`, the same
  pattern as the first bucket, scoped to the one tool that stays on Claude
  by design.
- **Limit-phrase fixtures.** `test/fixtures/monthly-spend-limit.txt` and
  `test/fixtures/probe-limited-envelope.txt` are literal copies of §2's
  Claude-specific limit phrase and envelope shape, feeding
  `test/github-limit.test.sh` and any limit-detection test that reads them
  — these are the test-side half of §2's "usage-limit phrase matching" row,
  and would need a Grok-Build-shaped sibling fixture if and when #2132 finds
  a documented phrase or event to match against; today there is nothing to
  write one from.

None of these 79 files need to change for this audit — they are evidence for
§1/§2's classification, not a fresh finding — but a provider-neutral stage
launcher will need either a provider-neutral stub convention alongside the
Claude-shaped one these tests already use, or a parametrised stub the two
provider adapters' own test suites can both drive; which of those is #2133's
call, not this audit's.

## Where this leaves #2131/#2133

The seam cuts cleanly at `run_claude_stage` (§1): everything above that line
— the two caps, the gap-stats observation, the GitHub-budget reading, the
metering/limit-detection/salvage readers — is already provider-agnostic in
its own logic, reading a handful of envelope fields and one in-stream event
type. Everything below that line (§2) is Anthropic's today and would become
one adapter among several. The sharpest gap §2 surfaces is prompt delivery:
Grok Build's documented CLI does not read stdin, so an adapter for it cannot
reuse `run_claude_stage`'s here-string unmodified — it needs a
`--prompt-file`-shaped path, which changes what "deliver the prompt" means
at the one call site every stage shares. The two next-sharpest gaps are
silence, not difference: no documented rate-limit event and no documented
`is_error`-equivalent field, both of which `lib/stage-attempt.sh` and
`lib/limit-detect.sh` currently read with confidence from Claude Code's own
envelope. §3 is a smaller, mostly cosmetic rewording; §4 and §5 need no
pipeline change at all, only (per §5) one documentation fix and one
benchmark-question update whenever a seam actually lands.
