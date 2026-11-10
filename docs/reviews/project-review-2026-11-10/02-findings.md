# Findings

All findings below were either carried forward from the 2026-10-27 baseline review and
re-verified with fresh evidence against current code and live GitHub state, or newly found this
round. A finding marked **RESOLVED** is retained for continuity but excluded from the severity
tally; a **PARTIALLY RESOLVED** finding counts once, at its current (reduced) severity, toward
the still-open half only. Purely informational findings (no severity assigned) are also excluded.

| Severity | Count (substantive) |
|---|---|
| Critical | 0 |
| High | 2 |
| Medium | 14 |
| Low | 16 |

## Architecture and design (ARCH)

**Strengths:** the three cycle entrypoints (`agent-cycle.sh`, `review-cycle.sh`,
`monitor-cycle.sh`) still share config/logging/stage-launch machinery (`lib/config-access.sh`,
`run_model_stage`, `stage_prompt_text`) rather than redefining it; `lib/model-id.sh` (new this
window, PR #2647) adds multi-provider weighted model-set selection as 16 small (<100-line),
single-purpose functions — clean new architecture, not a hot-spot; PR #2707 (see F-CODE-01)
also partially resolves this dimension's F-ARCH-01 by eliminating the worst instance of the
god-flow pattern.

### F-ARCH-01 — Stage-orchestration god-flow pattern recurring · **Medium** (partially improved)

**Evidence:** of the pattern's four tracked instances, one is now resolved (`lib/standdown.sh`'s
`run_standdown_checks`, via PR #2707 — see F-CODE-01); the other three are unchanged or worse:
- `agent-cycle.sh` top-level body is still ~2,513 lines of sequential, un-functioned flow (was
  2,470, +1.7%); tracker `#1253` (OPEN, `updatedAt 2026-09-08`) unchanged.
- `monitor-cycle.sh` — a new entrypoint added since the 2026-09-28 review — reproduces the same
  shape: lines ~400–1411 are top-level script body (finding loop `monitor-cycle.sh:1294`, triage
  loop `:1349` both sit directly at file scope, not inside any function). `#1756` (OPEN,
  `updatedAt 2026-09-21`) names this exact reproduction in its own title.
- `lib/enabler.sh`'s `maybe_run_enabler()` (`lib/enabler.sh:1486`–2527) is now ~1,041 lines, up
  from ~895 at the 2026-10-27 review (+16%). `lib/approver.sh`'s `run_approver_stage()`
  (`lib/approver.sh:716`–1254) is now ~538 lines, up from ~432 (+25%). `#1254`, `#1255` both
  OPEN, `updatedAt 2026-09-08`.

Live `gh` checks confirm `#1756`, `#1253`, `#1254`, `#1255`, `#1996` all `state: OPEN`.

**Impact:** the one instance the prior two reviews most worried about is fixed — real progress —
but the pattern isn't converging: the next two largest functions in the repo grew 16–25% in the
two weeks since last measured, and a new entrypoint was built with the exact flat shape `#1756`
already flagged as a mistake to repeat.

**Direction:** `#2699`/PR #2707 is done. Remaining backlog (`#1756`, `#1253`–`#1255`, `#1996`)
is unchanged in direction but now clearly the highest-priority of the four, since they're
growing rather than holding steady. Addressed by R-13.

### F-ARCH-02, F-ARCH-03, F-ARCH-04 — RESOLVED

Not independently re-checked this round beyond confirming no regression signal in the
66-commit window; carried forward as resolved per the prior review's own re-confirmation
(F-ARCH-02, -03) / carry-forward (F-ARCH-04).

### F-ARCH-05 — Decomposition relocates bulk without reducing per-function complexity · **Low**

**Evidence:** `lib/coordinator-phase.sh:43`'s `run_coordinator_through_finishing_phase()` is
now ~717 lines (file total 1,828; was ~705/1,780). `lib/gather-phase.sh:34`'s
`run_gather_phase()` is now ~610 lines (file total 644, essentially the whole file; was
~595/629). Both grew slightly, in step with `agent-cycle.sh`, rather than being further
decomposed.

**Impact:** unchanged — a reader judging "is the god-flow problem solved" from
`agent-cycle.sh`'s line count alone is misled; the same single-function-fills-its-file shape
persists one `source` away in both extracted files.

**Direction:** unchanged — folds into `#1996`'s scope (decompose into named sub-steps, not
further file-splitting). No new issue needed. Addressed by R-13.

## Code quality and maintainability (CODE)

**Strengths:** zero TODO/FIXME/HACK markers anywhere in `lib/`/`scripts/`/the three entrypoints
(confirmed again this round); `dashboard/index.html` is byte-for-byte unchanged in size (4,570
lines both at baseline and now) — `renderBody()` growth remains halted; the `san()` dedup
(`lib/claim-key.sh:17`) still holds as the only definition in the tree; `lib/landing.sh` and
`lib/candidate-select.sh`, sampled as the two largest `lib/` files besides `standdown.sh`, show
no comparable hot-spot — largest functions are 462 and 175 lines respectively, both well inside
normal range.

### F-CODE-01 — `run_standdown_checks` god-function · **RESOLVED this round**

**Evidence:** PR #2707 ("refactor(standdown): decompose run_standdown_checks into named
helpers", merged 2026-10-28) split the function into 17 named `_standdown_*` helpers
(`lib/standdown.sh:44`–1411, e.g. `_standdown_forge_auth_identity`, `_standdown_disk_space`,
`_standdown_backpressure`); `run_standdown_checks()` itself is now `lib/standdown.sh:1412`–1430,
an 18-line orchestrator calling each helper in sequence (independently re-confirmed against
current `HEAD`: `_standdown_*` helper definitions run from line 44 to the `run_standdown_checks`
orchestrator at line 1412, in a 1,613-line file). Issue `#2699` closed (`closedAt
2026-10-28T03:48:49Z`); `#1256` (the stale sibling naming a since-deleted function) also closed
the same PR, as superseded by PR #1560, with a `td-record` for each in the PR body.

**Impact:** none remaining — the repository's largest undecomposed function and the stale
tracking issue are both gone in the same change.

**Direction:** R-15 (prior round) fully delivered; no further action.

### F-CODE-02 — RESOLVED

`lib/claim-key.sh:17`'s single `san()` definition re-confirmed; unchanged since baseline.

### F-CODE-03 — Large CI/ops scripts growing faster than the prior window · **Low, improving**

**Evidence:** `scripts/publish-dashboard.sh` 4,751→4,754 lines (+0.06% this window, vs +12.2%
the prior window); `scripts/doctor.sh` 3,158→3,200 lines (+1.3%, vs +18.9% the prior window).

**Impact:** the acceleration the prior review flagged has reversed — both files are now nearly
flat. Not resolved (still large, still growing slightly) but materially improved and no longer
the concerning trend it was.

**Direction:** no change needed beyond continued monitoring; R-20's paginated-fetch extraction
(still not done — see F-CODE-06) remains the mechanism that would shrink
`publish-dashboard.sh` further.

### F-CODE-04 — RESOLVED, reconfirmed

`dashboard/index.html` unchanged at 4,570 lines (identical file-level line count at both the
2026-10-27 baseline revision and now); `renderBody()` growth remains halted.

### F-CODE-05 — `cfg()`/`expand_home()` duplicated far beyond the two files tracked · **Low**
(scope significantly wider than previously described)

**Evidence:** `lib/config-access.sh:20` is the canonical `cfg()` (no stderr suppression) and
`:14` the canonical `expand_home()`. Re-verifying against current code (not just the two files
issue `#1755` names) found:
- `cfg()` is independently redefined in **14** other files: `lib/claim.sh:111`,
  `scripts/sweep-orphan-branches.sh:132`, `scripts/sweep-closed-issues.sh:118`,
  `scripts/node-health.sh:141`, `scripts/release-pending-reservations.sh:114`,
  `scripts/sweep-human-visibility.sh:217`, `scripts/publish-dashboard.sh:227` (7 of these
  diverge behaviorally with a `2>/dev/null` stderr-suppression the canonical version lacks, plus
  `node-health.sh` also changes the jq query to `// empty`), plus `scripts/constraint.sh:108`,
  `scripts/pickup-metrics.sh:172`, `scripts/item-lifecycle.sh:87`, `scripts/rotate-logs.sh:119`,
  `scripts/state-sync.sh:160`, `scripts/node-time-state.sh:114`, `scripts/doctor.sh:236` (7 that
  currently match the canonical body exactly, but are still separate copies that can drift).
- `expand_home()` is independently redefined, identically, in **20** files
  (`scripts/state-sync.sh:151`, `scripts/reconcile-compose.sh:60`, `scripts/constraint.sh:98`,
  `scripts/sweep-closed-issues.sh:123`, `scripts/autonomy-stage-report.sh:182`,
  `scripts/pickup-metrics.sh:159`, `scripts/github-budget-report.sh:103`,
  `scripts/item-lifecycle.sh:77`, `scripts/open-dashboard.sh:28`, `scripts/publish-dashboard.sh:222`,
  `scripts/wake-poll.sh:160`, `scripts/node-time-state.sh:104`, `scripts/verdict-fate-report.sh:105`,
  `scripts/serve-dashboard.sh:45`, `scripts/collect-resource-usage.sh:95`,
  `scripts/publish-dashboard-launcher.sh:102`, `scripts/resource-budget-report.sh:63`,
  `scripts/node-health.sh:112`, and more).
- Only **4** files actually `source`/reference `lib/config-access.sh` at all: the three
  entrypoints (`agent-cycle.sh`, `review-cycle.sh`, `monitor-cycle.sh`) and
  `scripts/collect-host-facts.sh`. This duplication was already present at the 58b6e42 baseline
  (confirmed via `git show 58b6e42:<file>`), i.e. it is not new growth — the prior review's issue
  (`#1755`) and finding simply undercounted the scope, naming 2 of what are actually ~15 (`cfg`)
  + ~20 (`expand_home`) duplicate definitions across `scripts/`.

**Impact:** `lib/config-access.sh`'s stated purpose ("the small, identical config-reading helpers
both cycles build on") is true only for the three entrypoints; nearly every standalone
`scripts/*.sh` tool reinvents both helpers instead, and 7 of the 15 `cfg()` copies have already
diverged in error-suppression behavior from the canonical one, exactly the risk `#1755`
describes — just at roughly 7x the scope the issue currently states.

**Direction:** still addressed by R-17/`#1755` in principle, but this is a genuine scope
correction to an existing open finding (cited rather than filed as a second issue, per the
dedup-first rule), not a new defect. No new issue filed; `#1755`'s scope should be widened when
it is next worked.

### F-CODE-06 — Paginated-`gh`-fetch idiom reimplemented across multiple files · **Low**,
unchanged

**Evidence:** `lib/github-limit.sh` still has no `gh_paginated_fetch` function (confirmed via
grep — only commentary at `lib/github-limit.sh:688` referencing the pattern, and a separate
rate-limit-retry `gh()` wrapper that is a different concern). That slurp idiom is still
duplicated near-verbatim in at least `lib/approver.sh:179,246,1747`, `lib/enabler.sh:473`,
`lib/candidate-select.sh:969`, `lib/pipeline-marker.sh:168`,
`scripts/autonomy-stage-report.sh:257,406`. Issue `#1919` ("reimplemented in 13+ files")
confirmed live `state: OPEN`.

**Impact:** unchanged from the prior review — a correctness fix to the pagination-aggregation
idiom still has to be applied at each of 7+ call sites by hand.

**Direction:** unchanged, addressed by R-20/`#1919` (existing, open).

## Security (SEC)

**Strengths:** the backgrounded-wait-guard hardening chain opened and closed across this review
window (#2778 → #2800/#2801 → PR #2812 → #2816/#2821 → PR #2822/#2828, plus the regression test
added in PR #2843/`b5a33df`) is a genuinely thorough defense-in-depth sequence: it moved a
`PreToolUse` hook from an agent-writable path under `/app` to a root-owned, non-writable
location outside it, then mechanically verified in CI not just the hook files' own ownership and
write-refusal but every directory in the chain that could be used to delete-and-recreate them —
closing exactly the "fail-open-and-silent" class the issue chain itself named. `lib/tech-debt-file.sh`'s
two credential-isolation fixes this window (`fd13102`, `3331f50`) both explicitly preserve the
"`GH_TOKEN` is really absent, not merely emptied" guarantee while fixing adjacent bugs, rather
than trading isolation away for convenience. CI gained image vulnerability scanning this window
(PR #2819, hardened by PR #2830 to pin the scanner by digest and drop a read-write Docker-socket
mount in favour of scanning a `docker save` tarball) — report-only today, tracked for promotion
by `#2836`. A fresh secret-shape scan of the working tree found no real secret, only
clearly-named placeholders (e.g. `sk-ant-api03-policy-probe-placeholder` in
`scripts/claude-policy-probe.sh`) and a synthetic PEM fixture in
`test/stage-boundary.test.sh:74-75`.

### F-SEC-01 through F-SEC-03 — RESOLVED

Unchanged since baseline; no file touched by any of the 66 intervening commits.

### F-SEC-04 — `lib/claim-key.sh`'s `san()` has no explicit rejection of a bare `..` path
segment · **Low**

**Evidence:** `lib/claim-key.sh:17` is byte-identical to the 2026-10-27 baseline (`git log
--oneline 58b6e42..HEAD -- lib/claim-key.sh` returns nothing). Every current caller
(`lib/claim.sh:153,344,366`, `scripts/sweep-orphan-branches.sh:269`) still appends a suffix
(`.json` or a second `san()`-encoded segment) before use, so this remains unexploitable in
practice today.

**Impact:** low in the current call-site set; a future caller that passes a bare `san()` result
straight into a GitHub-contents-API path with no appended suffix would inherit the gap silently.

**Direction:** addressed by R-14 (existing `#1172`, still open, untouched since 2026-09-08).

### F-SEC-05 — RESOLVED

Unchanged since baseline (`#1627` remains closed, rotation confirmed; structurally mitigated by
the `#2206` stage-user boundary).

### F-SEC-06, F-SEC-07, F-SEC-08 — RESOLVED

Unchanged since baseline. Re-confirmed live: `lib/redact.sh:52-59`
(`_redact_escape_replacement`) still escapes a custom placeholder for F-SEC-06; the documented
newline no-op at `lib/redact.sh:72-76` still covers F-SEC-07; `config.json:47`'s
`enabler_assignee: "warwickallen"` is this installation's own documented live value (per
`config.schema.json:574`'s own comment, "not a value to copy"), not a reintroduced hard-coded
product default, so F-SEC-08 stays resolved.

### F-SEC-09 — `redact_add_literal`'s coverage gap for Vercel-shaped runtime secrets remains
fully open — the direct sibling of the resolved F-SEC-05 incident · **High**

**Evidence:** confirmed unfixed against current `HEAD`, independently re-verified by this
review's own lead pass: `scripts/preview-deploy.sh:281` uses `VERCEL_TOKEN` directly in an
`Authorization: Bearer` header; `VERCEL_AUTOMATION_BYPASS_SECRET` is read at line 306 and used
at lines 350/387. Zero `redact_add_literal` calls anywhere in the file or the rest of the
repository for either name — `grep -rn "redact_add_literal" --include="*.sh" .` (excluding
tests) shows only the two pre-existing `notify_webhook_url` call sites
(`scripts/state-sync.sh:207`, `scripts/publish-dashboard.sh:332`), unchanged in count and
content since baseline. `lib/redact.sh`'s six fixed-shape `REDACT_SED_ARGS` rules are
byte-identical to baseline and have no pattern that would catch either Vercel secret shape.
`test/redact.test.sh` is also byte-identical (107 lines), so no regression guard exists either.

Live GitHub state, independently re-confirmed: `agent-ops#1752` (the fix issue) is still
**OPEN**, `updatedAt 2026-09-21T17:40:42Z` — no activity in the 50 days since filing beyond the
Refiner's own scoping comment. No open PR addresses it. `#1757` (the companion test-coverage
issue) is likewise **OPEN**, 50 days stale.

**Impact:** severity follows the credential, not the project's own maturity, per the
dangerous-defect test — the harm is not bounded by this project's own importance. Should either
`VERCEL_TOKEN` or `VERCEL_AUTOMATION_BYPASS_SECRET` reach a cycle transcript or the state-mirror
push again, it passes through completely unmasked: this is the exact mechanism that produced the
F-SEC-05 incident (a live Vercel token and GitHub App key path printed into a 2026-09-16
transcript, rotated 2026-10-01), for the one credential class in that incident that still has no
registered redaction. Three successive review rounds (2026-09-21, 2026-10-27, and now
2026-11-10) have found this gap open with no PR ever opened against it.

**Direction:** addressed by R-01 (existing `#1752`, `#1757`). **This review's #1 priority open
item** — unchanged in severity and unchanged in code across three review cycles spanning 50
days.

### F-SEC-10 (new) — `#2813` describes background-wait-guard hook hardening that is already
fully implemented; the issue has gone unresolved across five live re-confirmations · **Low**

**Evidence:** `agent-ops#2813` ("Nothing verifies that the installed backgrounded-wait guard
hook is root-owned and non-writable by `agent`") is still **OPEN**, created 2026-11-03. Its own
comment thread — five separate autonomous "Re-confirmed against `origin/main`" comments dated
2026-11-05, 2026-11-08 (×2) and 2026-11-09 — each independently finds the exact mechanism the
issue asks for already present in code: `.github/workflows/build-image.yml` lines 460-466
(independently confirmed in this review's own read of the current file) stat both hook files'
ownership (`root:755`) and assert `agent` cannot `touch` them, landed by PR #2812/`e1e6e4c` on
2026-11-04. The issue itself was never closed despite each re-check confirming completion.

**Impact:** low — backlog hygiene noise, not a code defect; the underlying security property
(both hardening layers: directory ownership via `#2816`/`#2821`, now also closed, and file
ownership via this issue) is actually in place and CI-enforced. Same pattern as the prior
round's F-TEST-06 (a stale issue describing already-fixed work), but notable here because it
sits in the security hardening chain and a reader scanning open issue counts could mistakenly
treat this as a live gap.

**Direction:** not independently actionable by this review (closing an issue is a maintainer
action); flagged for visibility under R-19 alongside the other stale-issue items.

## Testing and quality assurance (TEST)

**Strengths:** test investment kept pace with code growth over this 14-day window — 281 test
files (up from 277), 4 new files (`test/background-wait-guard.test.sh`,
`test/docker-toolchain-drift.test.sh`, `test/enabler-void-refusal-exclusion.test.sh`,
`test/selection-fingerprint-model-set.test.sh`), 67 existing test files touched, +2,621/-268
lines. New tests are well-targeted (e.g. `b5a33df` adds five live-fire checks proving the
backgrounded-wait-guard `PreToolUse` hook actually blocks a tool call, not just that the policy
is shipped); none of the four new files makes a real network call. `./scripts/run-tests.sh --list`
still works without Docker.

### F-TEST-01 — RESOLVED
Unchanged since baseline.

### F-TEST-02 — No coverage-measurement tooling exists · **Medium**

**Evidence:** `grep -n "coverage\|kcov\|bashcov" scripts/run-tests.sh` returns nothing. Tracking
issue `agent-ops#2695` confirmed `OPEN`, last updated 2026-10-27 (14 days stale); no open PR
touches `run-tests.sh` or adds a coverage harness.

**Impact:** unchanged — 281 test files, no mechanical "exercised vs never-tested" signal.

**Direction:** addressed by R-06 (existing `#2695`), no change needed.

### F-TEST-03 — RESOLVED
Unchanged.

### F-TEST-04 — `lib/redact.sh`'s shape-based rules and newline no-op remain untested · **Medium**

**Evidence:** `test/redact.test.sh` is still exactly 107 lines, covering only the
`redact_add_literal` placeholder-escaping bug (`#1741`). None of the six fixed shape rules in
`REDACT_SED_ARGS` (`lib/redact.sh:20-26`) is exercised against a matching example, and
`redact_add_literal`'s newline no-op (`lib/redact.sh:68-72`) has no test. `agent-ops#1757`
confirmed `OPEN`, 50 days stale, 1 comment, no PR.

**Impact:** unchanged — the suite that would catch a regression in the mechanism F-SEC-09 needs
extended still doesn't exercise it.

**Direction:** addressed by R-01 (existing `#1757`) — sequence with F-SEC-09's fix.

### F-TEST-05 — PARTIALLY RESOLVED · **Low** (remaining half)

**Evidence:** state-sync half remains fixed. `test/publish-dashboard.test.sh:1548` (shifted +3
lines from baseline's 1545, content identical) still calls `run_window 20`. `agent-ops#1205`
confirmed `OPEN`, now 63 days stale (up from 51), no PR.

**Direction:** addressed by R-18 (existing `#1205`); zero movement in 12 days despite a proven
one-line fix pattern already landed in the sibling file (`#1722`).

### F-TEST-06 — Issue `#1036` describes already-fixed work, unclosed across five review cycles
· **Low**

**Evidence:** confirmed `OPEN`, unchanged. `scripts/gather-source-state.sh:127` still uses
`gh api --paginate` (fixed by PR #1165, 2+ months ago).

**Direction:** unchanged; flagged again for maintainer closure under R-19.

### F-TEST-07 — Fixed-duration sleeps checking process-table state · **Low**

**Evidence:** `test/stage-boundary.test.sh` still has 23 `sleep` calls (unchanged);
`test/state-sync.test.sh` now has 23 (up from 18 at baseline).

**Direction:** watch-only, as before; sleep count growth in `state-sync.test.sh` tracks this
window's hooks/state-sync feature work — fold into whatever eventually generalizes F-TEST-05's
fix pattern.

## Dependencies and supply chain (DEPS)

**Strengths:** Dependabot now covers all three ecosystems that admit it (`github-actions`,
`docker-compose`, and — new this window — `docker` for the base image), and is demonstrably
live: `a471ae1` (`#2804`, tailscale sidecar bump) merged, and `#2805`
(`dependabot/docker/deploy/docker/ubuntu-26.04`) is open right now, generated by the exact new
entry this round closes F-DEPS-05 with. Separately, this window also closed the one gap
Dependabot structurally cannot reach: the four hand-pinned toolchain `ARG`s in
`deploy/docker/Dockerfile` now have their own scheduled drift detector
(`scripts/check-docker-toolchain-drift.sh` + `.github/workflows/docker-toolchain-drift.yml`,
`#2717`), visibly working — five bump commits landed in the 66-commit window.

### F-DEPS-01, F-DEPS-02, F-DEPS-03, F-DEPS-04 — RESOLVED

Unchanged from baseline; re-confirmed still resolved.

### F-DEPS-05 — RESOLVED this round

**Evidence:** `.github/dependabot.yml` now has a third `updates` entry (`package-ecosystem:
"docker"`, `directory: "/deploy/docker"`, weekly), landed via `cc04be8` (`#2706`), closing issue
`#2697`. Live proof: PR `#2805` bumps `ubuntu` 24.04→26.04 in `deploy/docker`, generated by this
entry.

**Direction:** R-09 (prior round) fully executed; no further action. The four hand-pinned
toolchain `ARG`s the baseline's own Default note left as accepted debt are themselves now
covered by the independent drift-detector mechanism above (`#2717`).

### F-DEPS-06 (new) — The toolchain drift detector files but never merges a fix · informational,
no severity

**Evidence:** `scripts/check-docker-toolchain-drift.sh` and PR `7bc1285` state explicitly it
"never bumps a pin itself and never opens a pull request" — a deliberate design choice
(`#2708`). Five observed bump commits this window are each a distinct, hand-written, single-pin
PR.

**Direction:** no action needed; a reasoned, documented design choice, not a gap.

## Tooling and developer experience (TOOL)

**Strengths:** `./scripts/run-tests.sh --list` reconfirmed working with no Docker daemon
present. A new drift-detection workflow continues this project's pattern of thorough,
self-documenting CI rationale comments.

### F-TOOL-01 — No `.editorconfig`, `.shellcheckrc`, or `Makefile` · **Low**

**Evidence:** confirmed absent. `agent-ops#1758` confirmed `OPEN`, 50 days stale.

**Direction:** addressed by R-16 (existing `#1758`); unchanged.

### F-TOOL-02 — Every Actions `uses:` line still references a mutable tag · **Medium**

**Evidence:** `grep -rhn "uses:" .github/workflows/*.yml | grep -cE '@[0-9a-f]{40}'` → `0` of 27
`uses:` lines across all 17 current workflow files. (The new Trivy step is pulled via `docker run
aquasec/trivy@sha256:...` inside a `run:` block, not a workflow `uses:` line — digest-pinned on
its own, correctly, but outside this finding's scope.) `agent-ops#1918` confirmed `OPEN`, 42 days
stale (up from 29).

**Impact:** unchanged — a compromised/re-tagged upstream Action is still pulled automatically
into a pipeline with write access to a public image registry.

**Direction:** addressed by R-07 (existing `#1918`); unchanged, growing stale.

### F-TOOL-03 — Docker-dependent verification gap · **Low** (informational)

**Evidence:** reconfirmed this round — no Docker daemon in this sandbox either; `--list` fast
path independently re-verified working.

**Direction:** no action needed, as before; this is a limitation of the review's own sandbox.

## CI/CD and release engineering (CI)

**Strengths:** a new scheduled workflow, `docker-toolchain-drift.yml`, checks four hand-pinned
toolchain `ARG` versions against upstream daily. The container-image vulnerability scan (F-CI-09)
landed and was hardened within days of being flagged.

### F-CI-01 — unchanged, PARTIALLY RESOLVED (see F-CI-08)

### F-CI-02 — `publish-dashboard.sh`'s open-issues fetch remains single-page · **Medium**

**Evidence:** `scripts/publish-dashboard.sh:3368`: `gh_call api
"repos/$slug/issues?state=open&per_page=30"`, still no `--paginate`. `agent-ops#1171` confirmed
`OPEN`, 63 days stale, no PR.

**Direction:** addressed by R-04 (existing `#1171`); unchanged.

### F-CI-03 — unchanged, PARTIALLY RESOLVED (see F-TOOL-02)

### F-CI-04 — Reviewer stage still cannot read a failing CI log · **Medium**

**Evidence:** `prompts/reviewer.md` has zero matches for `gh run view`/`--log`;
`prompts/implementer.md:308` still has the sole route. `agent-ops#1496` confirmed `OPEN`, 57
days stale.

**Direction:** addressed by R-08 (existing `#1496`); unchanged.

### F-CI-05, F-CI-06 — RESOLVED, unchanged.

### F-CI-07 — The scheduled CHANGELOG roll has still produced zero output · **Medium**

**Evidence:** `CHANGELOG.md`'s last edit remains `a256590` (2026-09-23) — now 48 days since the
roll mechanism (PR #1842) merged, with zero observed roll output.
`gh api "search/issues?q=repo:Pullwright/agent-ops+head:changelog-roll" --jq '.total_count'` →
still `0`. `#1846`/`#1848` confirmed `OPEN`, unchanged since 2026-09-24. The mechanism runs
inside the deployed node's own scheduled cron, not a GitHub Actions workflow, so this review's
sandbox cannot trace a live run directly — only the absence of any resulting PR is directly
verifiable.

**Impact:** worse than baseline's framing — 48 days of zero output, not 32, despite the same
unresolved sub-bugs.

**Direction:** addressed by R-09 (existing `#1846`, `#1848`); the end-to-end trace it recommends
is more overdue now than at baseline.

### F-CI-08 — "advisory check, not required gate" still true for `toc` and `spec` · **Medium**

**Evidence:** independently re-confirmed: `gh api repos/Pullwright/agent-ops/rulesets/18857310
--jq '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context'`
lists `Analyze (actions)`, `Build and test (linux/amd64)`, `Build and test (linux/arm64)`,
`Work out the version stamp`, `Work out what changed`, `closing-keyword`, `commit-format`,
`shellcheck`, `changelog-section`, `config-table`, `docs-benchmark sources` — **no `toc`, no
`spec`**. Both workflows already carry a bare `merge_group:` trigger — the prerequisite step
`#2117`/`#2578` call for is done; only the owner-only ruleset edit remains. `#2117` confirmed
`OPEN`, 38 days stale; `#2563`/`#2578` confirmed `OPEN`, 21 days stale.

**Impact:** unchanged — a PR with a stale TOC or a dangling/colliding requirement-label
citation can still merge.

**Direction:** addressed by R-03 (existing `#2117`/`#2563`/`#2578`) — a fully-specified,
one-click, owner-only edit that has now sat open 21-38 days with no blocker other than the edit
itself; the cheapest open item in this entire review.

### F-CI-09 — RESOLVED this round

**Evidence:** independently re-confirmed: `.github/workflows/build-image.yml:325-352` runs
Trivy (`aquasec/trivy@sha256:be1190af...`, digest-pinned) against the built image's `docker save`
tarball on every build. Landed via `796de6b` (2026-11-04), closing `agent-ops#2696`. Hardened five
days later by `7d05f09` (2026-11-09): pinned the scanner by digest instead of a mutable tag, and
dropped the Docker-socket mount entirely. Deliberately **report-only**
(`continue-on-error: true` plus Trivy's own `--exit-code 0`), exactly matching R-06's "Default: add
the scan as non-blocking first" recommendation. Promotion to a required check is itself tracked
and open: `agent-ops#2836`.

**Direction:** fully resolved per R-06's own specified default; `#2836` is the correctly-scoped
follow-up, already filed.

## Performance and scalability (PERF)

**Strengths:** the three baseline resolutions hold with no regression; a new, narrowly-scoped
fix this window (`597c180`/`96584cb`, `#2745`/`#2746`/`#2748`) correctly diagnosed and fixed a
real fleet-observed performance pathology — `state-sync.sh fetch` giving up instantly on
ordinary, short-lived `flock` contention with a concurrent push, causing
`pager-evaluation-skipped` to fire on roughly 1 in 5 cycles — with before/after reasoning from
live cron-log evidence, and a follow-up PR caught and closed a cadence-dependent edge case before
it could recur. `lib/github-limit.sh`'s rate-limit wait-budget ledger also got a correctness fix
this window (`504cf14`), keeping the GitHub rate-limit backoff logic honest.

### F-PERF-01, F-PERF-02, F-PERF-03 — RESOLVED

Unchanged from baseline; re-confirmed still resolved.

### F-PERF-04 — The dashboard publisher's local (non-GitHub) tick remains a linear function of
total log history · **Medium** (unchanged)

**Evidence:** `git log --oneline 58b6e42..HEAD -- scripts/publish-dashboard.sh` shows exactly
two touching commits, neither changing the local-tick read path.
`scripts/publish-dashboard.sh:1188`'s `read_events "$raw_events_jsonl"` and the surrounding
per-cycle/cycle-id-scan readers are byte-for-byte unchanged from the baseline's citation. Issue
`#2434` is still `OPEN`, unchanged since baseline, no linked PR — the three candidate fixes it
already scopes remain unexecuted.

**Impact:** unchanged from baseline — `log.jsonl` is never rotated by design, so the ~8 full
`jq` passes per local tick keep growing with the fleet's age; this is the common-case tick (nine
of every ten launcher windows per the restored duty cycle), so the cost curve keeps climbing in
the background even though the publisher's overall CPU load is no longer in crisis.

**Direction:** addressed by R-10 (existing `#2434`, already fully scoped) — still awaiting
execution; now 25 days stale with zero follow-up activity.

### F-PERF-05 (new) — New host-facts/pager-invariant features add bounded, timeout-wrapped
per-tick cost, no new scaling concern · informational, no severity

**Evidence:** the two new per-node network probes added or touched this window
(`host_facts_viewer_probe_one`, `lib/host-facts-kubernetes.sh:148`) are both timeout-bounded and
run once per node per collection cycle; the new `pager_eval_viewer_probe_unanimous` and
`pager_eval_memory_cgroup` both operate over the already-small per-node fleet snapshot, not the
fleet-log union.

**Direction:** no action needed.

## Usability and accessibility (UX)

**Strengths:** `agent-cycle.sh --help`, `review-cycle.sh --help`, and `scripts/doctor.sh --help`
all still produce thorough, accurate usage text (exit 0, live-tested); no dashboard changes at
all since baseline, so no new interactive-element risk; `scripts/spec.sh` and
`scripts/check-docs.sh --help` both still behave cleanly.

### F-UX-01 — RESOLVED

Confirmed still resolved; zero dashboard commits in the 66-commit delta.

### F-UX-02 — `publish-dashboard.sh --help` is still silently swallowed · **Medium** (unchanged)

**Evidence:** live-tested: `./scripts/publish-dashboard.sh --help --no-github --fast` printed no
usage text and ran a full publish to completion, exit 0. `scripts/publish-dashboard.sh:208`'s
`*) shift ;;` catch-all is byte-for-byte unchanged. `#1753` still open, unassigned, now ~50 days
stale.

**Direction:** addressed by R-05 (existing `#1753`), unactioned.

### F-UX-03 — `monitor-cycle.sh` still has no `-h`/`--help` case · **Low** (unchanged)

**Evidence:** live-tested: `./monitor-cycle.sh --help` → exit 64, stderr "unknown argument:
--help" — loud, but no usage text. Same `#1753`.

**Direction:** addressed by R-05 (existing `#1753`), unactioned.

## Documentation (DOC)

**Strengths:** the 66-commit delta is dominated by careful, small, scoped doc-accuracy fixes
(`5509684` carves a reversibility exception out of a monotonicity claim with a precise mechanism
explanation; `416ef38` repoints a dangling cross-reference; `eeef64c` corrects a misquoted
third-party legal clause after verifying against the live source; `3c7107e` fixes a
documentation snippet that was silently destructive if followed literally —
`COMPOSE_PROFILES=local` would have dropped the `tailnet`/`auto-update` profiles).
`scripts/check-docs.sh` and `scripts/spec.sh check` both still pass clean against HEAD.
`CONTRIBUTING.md`'s pointer chain resolves cleanly.

### F-DOC-01, F-DOC-02, F-DOC-03, F-DOC-04 — RESOLVED

Unchanged from baseline; no regression found.

### F-DOC-05 — Rename-during-split regression is still unreverted, still no mechanical guard
· **Medium** (unchanged)

**Evidence:** `git log --oneline -- docs/spec/implementation/requirements/the-script-10.md`
(and `-11.md`, `-12.md`, `-13.md`) shows no commit since `9235549` (PR #2665) touching any of
these four files — the rename has never been reverted. Issue `agent-ops#2694` is still `OPEN`,
one Refiner work-order comment, no linked PR. No script/workflow/diff-based guard against a
rename-during-split exists.

**Impact:** unchanged — a concurrent main-side edit to `the-script-10.md`/`-11.md` before a
future spec-split PR touching those numbers would still silently revert.

**Direction:** addressed by R-12, unactioned. `#2694`'s own Refiner comment already carries a
fully-scoped implementation approach (base-ref/head-ref diff check modeled on
`scripts/check-closing-keyword.sh`).

### F-DOC-06 — `docs/README.md` still overclaims `spec.sh check` as a "permanent guard"
· **Medium** (unchanged)

**Evidence:** `docs/README.md:506` still reads "`scripts/spec.sh check` is the permanent guard:
it fails…". See F-CI-08 — neither `spec` nor `toc` is in the live required-status-checks list.

**Impact:** unchanged — a reader relying on the stated guarantee is wrong about what blocks a
merge.

**Direction:** addressed by R-03 (same fix as F-CI-08); an owner-only ruleset edit, still
unactioned.

### F-DOC-07 — Issue `#2326` remains open, still stale backlog noise · **Low** (unchanged)

**Evidence:** `gh issue view 2326` → `"state":"OPEN"`. Underlying size-budget violation already
fixed incidentally by `#2665` before the prior review was even written.

**Direction:** flagged again for the maintainer to close (R-19); not independently actionable.

## Governance and project health (GOV)

**Strengths:** branch ruleset confirmed live and unchanged (squash-only merges, one required
review, `require_extra_approval_for_unattributed_changes`); `CODEOWNERS` matches `AGENTS.md`'s
description exactly; the backlog's own fit-ladder mitigation shows genuine, recent activity (see
F-GOV-04) rather than having stalled.

### F-GOV-01, F-GOV-03 — RESOLVED

Unchanged, still coherent.

### F-GOV-02 — PARTIALLY RESOLVED · **Low** (remaining part, now staler)

**Evidence:** `#1753` (the UX-02/03 pair) remains `OPEN`, unassigned, ~50 days stale (up from 36
at baseline), zero new comments.

**Direction:** addressed by R-05 (existing `#1753`), unactioned.

### F-GOV-04 — Open-issue backlog has grown to 609 (77% tech-debt), fit-ladder mitigation is
active but not yet landed · **Medium** (updated)

**Evidence (freshly measured today, independently cross-checked by two subagents and this
review's lead):**
- `gh api "search/issues?q=repo:Pullwright/agent-ops+is:issue+is:open" --jq '.total_count'` →
  **609** (up from 581 at baseline, 14 days ago).
- `gh api "search/issues?q=repo:Pullwright/agent-ops+is:issue+is:open+label:pw::type:tech-debt"
  --jq '.total_count'` → **469** (77% of open issues).
- Over the 14-day window: ~78 closed, ~108 opened — a ~1.4:1 filed:closed ratio this window,
  notably lower than the 3:1 trend `STANDING-DECISIONS.md`'s 2026-10-16 entry measured over the
  prior three weeks, though 14 days is too short a window to call this a trend reversal.
- `docs/STANDING-DECISIONS.md`: most recent entry 2026-10-17 (unrelated, model-tier ordering) —
  no newer entry revisits the 2026-10-16 backlog-volume decision; it remains the operative,
  unsuperseded standing decision.
- Fit-ladder tracking issues `#2416`/`#2417`/`#2422` are themselves quiet (last updated
  2026-10-16), but the actual mitigation work is live: PR `#2437` ("Priority and Issue
  Dependencies rank the backlog") is `OPEN`, `MERGEABLE` but `mergeStateStatus: BLOCKED`, opened
  2026-10-16, **last updated 2026-11-09** (yesterday) — active, recent work, not abandoned.

**Impact:** unchanged in kind from baseline: (1) any future review must keep deriving backlog
size from a measured `search/issues` total, never `gh issue list`'s default page; (2) the
backlog continues to grow in absolute terms, but the owner's dated decision to rank by
Priority/Issue Dependencies rather than manage by volume stands un-revisited, and the mechanism
it depends on (`#2437`) is under active, recent development.

**Direction:** addressed by R-11 — still a visibility/owner-decision item, not a code fix, per
the prior review's own framing. Worth flagging to the owner that `#2437` is close enough to
warrant a check on what `BLOCKED` is waiting on, given it has been open 25 days.

## Observability and operations (OPS)

**Strengths:** the pager-invariant mechanism (`lib/pager-invariants.sh`) is actively growing and
closing exactly the kind of blind spot it exists to catch: this window added
`pager_eval_memory_cgroup` (closing F-OPS-04) and `pager_eval_viewer_probe_unanimous`, the latter
specifically to page on the uniform fleet-wide-failure signature that let the `viewer_probe` bug
go unnoticed for weeks. A second, independent self-healing mechanism landed this window too:
`a7aeef9` adds a circuit breaker so an item whose void-verdict is refused twice in a row
escalates to a filed issue instead of being re-selected forever. `state-sync.sh fetch`'s own
lock-contention behaviour was also hardened twice this window, fixing a real, cron-log-evidenced
~1-in-5-cycle `pager-evaluation-skipped` pathology.

### F-OPS-01 — RESOLVED

Unchanged from baseline; re-confirmed still resolved.

### F-OPS-02 — `state-sync.sh`'s `do_push` remains unbounded outside its one patched step
· **High** (escalated this round — see Impact)

**Evidence:** `scripts/state-sync.sh`'s `do_push()` (current HEAD, lines 1046–1321) still wraps
only `redact_mirror_files` in `mirror_run_with_deadline` (line 1290). The `git -C "$mirror" fetch
--quiet --depth 1 origin "$state_branch"` (line 1071), both `rsync -a --delete` passes (lines
1077–1078 and 1099–1100), and the final `mirror_write push push --quiet --force origin
"HEAD:refs/heads/$state_branch"` (line 1319) all run after `mirror_lock` with no deadline wrapper
of any kind — `mirror_write()` (line 736) is a plain `git -C "$mirror" "$@"` call with no
timeout. The only two commits touching this file in the window (`96584cb`, `597c180`) both modify
`do_fetch`'s pre-lock wait behaviour exclusively — neither adds a deadline inside `do_push`
itself. Issue `#1701` is still `OPEN`, unchanged since baseline, zero new activity, no PR.

**Impact:** the exact failure class that produced the baseline-cited 7-hour wedge incident
(`agent-ops#1679`, a push holding `mirror_lock` the whole time while every other node's fetch
read "another state-sync holds the mirror" as indistinguishable from a dead node) can still
recur from any of these four unguarded steps. **Severity escalated from Medium to High this
round**: this is a real, already-occurred, fleet-wide-blast-radius incident with its exact
reproducing mechanism still unpatched after two full review cycles, and the asymmetry has
widened — `do_fetch` received two rounds of careful hardening this very window while `do_push`
received none. Rated on ordinary "significant risk/cost, should be addressed soon" grounds
(not the dangerous-defect-beyond-project-boundary exception, since the blast radius is this
project's own fleet availability).

**Direction:** addressed by R-02 (existing `#1701`, `#1604`) — fully scoped, still unexecuted.

### F-OPS-03 — No dedicated runbook/incident index · **Low** (unchanged)

**Evidence:** `find docs -iname "*runbook*" -o -iname "*incident*"` returns nothing, same as
baseline.

**Direction:** low urgency for a single-maintainer audience, consistent with baseline; not
covered by a numbered recommendation.

### F-OPS-04 — RESOLVED this round

**Evidence:** `lib/pager-invariants.sh` now has `pager_eval_memory_cgroup` (line 1029) and a
corresponding registration. Landed via `2ec99d1` (`#2704`), closing issue `#2698`.

**Direction:** R-21 (prior round) fully executed, same window as F-DEPS-05's fix.

### F-OPS-05 — State-sync push failures on a transient DNS/proxy error have no retry
· **Low** (unchanged)

**Evidence:** issue `#1604` is still `OPEN`, unchanged since baseline. No retry logic was added
to `do_push`'s steps in this window.

**Impact:** unchanged — still compounds F-OPS-02's unbounded-steps gap.

**Direction:** addressed by R-02 (existing `#1604`) — sequence with F-OPS-02's fix.

### F-OPS-06 (new) — `do_fetch`'s lock-contention fix leaves a 3-deep deferral chain, tracked but
unresolved · **Low** (informational)

**Evidence:** `96584cb` explicitly defers two follow-ons (`Defers: #2747`, `Defers: #2748`), and
`597c180` (which fixes `#2748`) in turn defers a third, `#2755` (`fleet_peers_stale`'s own 1800s
cap sitting below one fetch interval whenever `state_sync_fetch_minutes > 30`).

**Direction:** flagged for visibility only — a deliberate, correctly-filed deferral chain, not a
dropped thread.

## Data handling and privacy (DATA)

**Strengths:** `deploy/docker/.env.example` continues to ship every secret field empty with
rotation procedure documented inline; a fresh scan of the working tree found no real secret or
PII, only clearly-named placeholders and synthetic test fixtures.

### F-DATA-01 — RESOLVED

Unchanged in substance; `docs/DATA-HANDLING.md` untouched by any of the 66 intervening commits.

### F-DATA-02 — Fixtures still carry the maintainer's real GitHub usernames, count unchanged this
window · **Low**

**Evidence:** `grep -rl "warwickallen\|Warwick-Allen" test/*.sh | wc -l` returns 32, same as
baseline. `#1174` still `OPEN`, ~63 days stale.

**Impact:** low — test fixtures, not shipped defaults or live secrets.

**Direction:** addressed by R-15 (existing `#1174`).

### F-DATA-03 — `docs/DATA-HANDLING.md` still overclaims the mirror-push redaction pass's
coverage · **Medium**

**Evidence:** `docs/DATA-HANDLING.md:141-143`'s "Redaction for screenshots" paragraph is
byte-identical to baseline. It still reads: "…so operational data can be safely shared for
debugging without leaking credentials" — a blanket claim that does not distinguish the
dashboard-screenshot redaction pass from the separate, narrower mirror-push pass that actually
runs before content reaches the external state-mirror repository, and that pass is confirmed
(F-SEC-09, still fully open) to have no coverage for `VERCEL_TOKEN`/`VERCEL_AUTOMATION_BYPASS_SECRET`.

**Impact:** a reader relying on this document's language would over-trust the mirror-push
pass's actual coverage for exactly the credential class F-SEC-09 shows is unmasked today.

**Direction:** addressed by R-01, alongside the F-SEC-09 code fix it describes — this paragraph
should be corrected in the same pull request that closes `#1752`.

---

## Not covered by a numbered recommendation

F-ARCH-02/03/04, F-CODE-02/04, F-SEC-01-03/05-08, F-DEPS-01-04, F-PERF-01-03, F-OPS-01,
F-DATA-01 are RESOLVED, confirmed unchanged. F-CODE-01, F-DEPS-05, F-CI-09, F-OPS-04 are newly
RESOLVED this round. F-CODE-03 (CI/ops script growth) is monitored only, now improving.
F-TOOL-03 (Docker verification gap) is this review's own sandbox limitation. F-OPS-03 (no
runbook) remains low-urgency for a single-maintainer audience. F-TEST-07 (sleep-based test
flakiness risk) is watch-only pending an observed flake. F-DEPS-06, F-PERF-05, F-OPS-06 are
purely informational — reasoned design choices or correctly-filed deferral chains, not gaps.
F-TEST-06, F-DOC-07, and F-SEC-10 (three issues — `#1036`, `#2326`, `#2813` — describing
already-resolved work) are bundled under R-19 and flagged for the maintainer to close; closing
an issue is outside this review's mandate to action directly.
