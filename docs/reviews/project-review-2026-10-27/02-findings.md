# Findings

All findings below were either carried forward from the 2026-09-28 baseline review and
re-verified with fresh evidence against current code and live GitHub state, or newly found this
round. A finding marked **RESOLVED** is retained for continuity but excluded from the severity
tally; a **PARTIALLY RESOLVED** finding counts once, at its current (reduced) severity, toward the
still-open half only.

| Severity | Count (substantive) |
|---|---|
| Critical | 0 |
| High | 1 |
| Medium | 19 |
| Low | 17 |

## Architecture and design (ARCH)

**Strengths:** all three cycle entrypoints still share config/logging helpers rather than
redefining them; the dashboard writer/reader seam is genuinely exercised end-to-end by a real test
harness; the schema-is-source-of-truth design for configuration hasn't drifted in 202 commits.

### F-ARCH-01 — Stage-orchestration decomposition keeps growing faster than it's fixed · **Medium**

**Evidence:** `agent-cycle.sh` dropped 4,297→2,122 lines via PR #1974 (extracting
`lib/gather-phase.sh`/`lib/coordinator-phase.sh`) but has regrown to 2,470 (+16%) since. PR #1974's
own description says the line-count win does not fix the underlying problem and files `#1996`
itself. Meta-tracker `#1756` (open, 1 comment, `updatedAt 2026-09-21`) and `#1253` (open) remain
unresolved.

**Impact:** the god-flow pattern this tracks keeps recurring faster than the existing issues close
it, and the same pattern was built into a new entry point (`monitor-cycle.sh`) rather than reusing
`review-cycle.sh`'s already-proven decomposed shape.

**Direction:** addressed by R-15 for its worst current instance; the broader tracker (`#1756`,
`#1253`–`#1255`) remains the right home for the rest.

### F-ARCH-02 — RESOLVED

Unchanged since baseline; re-confirmed.

### F-ARCH-03 — RESOLVED

Re-confirmed on a different (dashboard writer/reader) seam this round.

### F-ARCH-04 — RESOLVED

Not independently re-checked this round (no delta activity); carried forward as resolved.

### F-ARCH-05 — Decomposition relocated two functions' bulk rather than reducing their complexity (new) · **Low**

**Evidence:** `lib/coordinator-phase.sh:28`'s `run_coordinator_through_finishing_phase()` is ~705
of the file's 1,780 lines; `lib/gather-phase.sh:34`'s `run_gather_phase()` is ~595 of the file's
629 lines — essentially the whole file.

**Impact:** a reader judging "is the god-flow problem fixed" purely from `agent-cycle.sh`'s line
count would be misled — the same shape now lives one `source` away, in a brand-new file.

**Direction:** when `#1996` is worked, split these two functions into named sub-steps rather than
further file-splitting that just relocates one function per phase.

## Code quality and maintainability (CODE)

**Strengths:** zero TODO/FIXME/HACK markers anywhere in `lib/`/`scripts/`/the three entrypoints;
`dashboard/index.html`'s `renderBody()` has stopped growing (flat at 552 lines); the `san()`/`cfg()`
dedup fix for the shared half still holds.

### F-CODE-01 — `run_standdown_checks` is now the largest undecomposed function in the repository, still untracked · **Medium**

**Evidence:** `lib/standdown.sh:22`–1362, ~1,340 lines (was 1,008 at baseline, **+33%**, the
largest single-function growth of any review window to date). Issue `#1756` explicitly recommended
filing a dedicated issue for this function a month ago; none existed until this review. `#1256`
(same original batch) names a function (`coordinator_corroborate_retry_or_fallback`) that no
longer exists in the tree.

**Impact:** the specific defect the prior two reviews flagged (runaway, untracked growth) is
unambiguously worse, not better, and now the repository's single largest decomposition target.

**Direction:** addressed by R-15. New issue filed this round: agent-ops#2699.

### F-CODE-02 — RESOLVED

Unchanged since baseline (`lib/claim-key.sh:17`).

### F-CODE-03 — Large CI/ops scripts growing faster than the prior window · **Low**

**Evidence:** `scripts/publish-dashboard.sh` 4,236→4,751 lines (+12.2%, vs +3.6% prior);
`scripts/doctor.sh` 2,657→3,158 lines (+18.9%, vs +4.9% prior).

**Impact:** growth accelerating rather than stabilising, though neither file has a single-function
hot-spot as acute as F-CODE-01.

**Direction:** monitored; R-23's paginated-fetch extraction partially addresses `publish-dashboard.sh`.

### F-CODE-04 — RESOLVED this round

`dashboard/index.html`'s `renderBody()` growth halted (flat at 552 lines this window, vs continuous
growth every prior window). Tracking issue `#1173` still open but the defect it describes
(continuous growth) did not recur.

### F-CODE-05 — `cfg()` duplicated between `lib/claim.sh` and `scripts/sweep-orphan-branches.sh` · **Low**

**Evidence:** both still define a local `cfg()` that suppresses stderr (`2>/dev/null`), diverging
from the shared `lib/config-access.sh:20` version, which does not.

**Impact:** a future change to the shared `cfg()`'s error behaviour would silently not apply to
these two call sites.

**Direction:** addressed by R-19 (existing `#1755`).

### F-CODE-06 — Paginated-`gh`-fetch idiom independently re-implemented across at least seven files · **Low**

**Evidence:** `lib/approver.sh`, `lib/candidate-select.sh`, `lib/pipeline-marker.sh`, `lib/enabler.sh`,
`scripts/gather-human-visibility-hygiene.sh`, `scripts/autonomy-stage-report.sh`,
`scripts/verdict-fate-report.sh` each implement `gh api ... --paginate` independently;
`lib/github-limit.sh` (the proposed shared home) still has no `gh_paginated_fetch` function.

**Impact:** a correctness fix to the pagination idiom (e.g. rate-limit handling) must currently be
applied at each of seven-plus call sites rather than once.

**Direction:** addressed by R-23 (existing `#1919`).

## Security (SEC)

**Strengths:** every headless-agent invocation now runs as a credential-isolated Unix user
(#2206) — the review series' single biggest structural security improvement to date; credential
minting consistently timeout-wrapped; the egress allowlist remains exemplary and test-pinned; a
fresh secret-shape scan of the working tree found no real secret, only one clearly-named
placeholder.

### F-SEC-01 through F-SEC-03 — RESOLVED

Unchanged since baseline (dashboard `esc()` naming correctly unpaired with `innerHTML`;
`SECURITY.md` present and accurate; CodeQL's Actions-only scope is a documented, accepted
limitation).

### F-SEC-04 — `lib/claim-key.sh`'s `san()` has no explicit rejection of a bare `..` path segment · **Low**

**Evidence:** `lib/claim-key.sh:17`, byte-identical to baseline. Every current caller appends a
suffix or uses the result only as a GitHub-contents-API path segment, so this remains
unexploitable in practice.

**Impact:** low in the current call-site set, but a future caller that doesn't append a suffix
would inherit the gap silently.

**Direction:** addressed by R-16 (existing `#1172`).

### F-SEC-05 — RESOLVED

**Evidence:** `agent-ops#1627` (live Vercel token + GitHub App private-key paths printed into a
2026-09-16 session transcript) is now **CLOSED**; the maintainer's 2026-10-01 comment confirms
both the affected Vercel token and bypass secret were rotated across every affected node, with
hash-verification evidence. The sandboxing question the issue raised is independently closed by
the #2206 stage-user boundary (see Strengths), which structurally prevents a recurrence of this
exact exposure class.

### F-SEC-06, F-SEC-07, F-SEC-08 — RESOLVED

Unchanged since baseline.

### F-SEC-09 — `redact_add_literal`'s coverage gap for Vercel-shaped runtime secrets remains open — the direct sibling of the now-resolved F-SEC-05 incident · **High**

**Evidence:** `agent-ops#1752` (open, one comment since creation on 2026-09-21, no PR, 36 days
stale as of this review) was filed specifically to register `VERCEL_TOKEN` and
`VERCEL_AUTOMATION_BYPASS_SECRET` via `redact_add_literal`. Confirmed unfixed in code:
`scripts/preview-deploy.sh:281,306,350,387` still uses both values directly in HTTP headers with
no `redact_add_literal` call anywhere in the repository for either. `lib/redact.sh`'s fixed-shape
rules (`REDACT_SED_ARGS`) have no pattern that would catch either shape.

**Impact:** rated above what the project's maturity alone would suggest, per the checklist's
dangerous-defect test — the harm here is not bounded by this project's own importance: should
either value reach a transcript or the state-mirror push again, it passes through completely
unmasked, which is the exact mechanism that produced the F-SEC-05 incident this credential class
already caused once, now confirmed still live for this one.

**Direction:** addressed by R-01 (existing `#1752`, `#1757`). Highest-priority open item this
round.

## Testing and quality assurance (TEST)

**Strengths:** test investment (277 files, 116,412 LOC) kept pace with code growth (34 new test
files, 148 commits touching tests); no real network calls found in any sampled test; test-coverage
gaps continue to be actively surfaced as tracked tech debt rather than sitting silently; the test
inventory runs clean without Docker.

### F-TEST-01 — RESOLVED

`test/git-identity.test.sh` (95 lines) added by PR #2664, closing `#1148` (closed 2026-10-25).

### F-TEST-02 — No coverage-measurement tooling exists, and the explicit hand-off to re-file this was itself dropped · **Medium**

**Evidence:** no `kcov`/`bashcov`/equivalent anywhere; `scripts/run-tests.sh` has no `--coverage`
flag. `#1148`'s closing PR explicitly scoped this out and said to "file a separate tech-debt item
… if a quantitative coverage floor is wanted later" — no such issue existed until this review.

**Impact:** 277 test files with no mechanical signal distinguishing "exercised" from "never
tested" beyond inspection and ad hoc gap-filing.

**Direction:** addressed by R-04. New issue filed this round: agent-ops#2695.

### F-TEST-03 — RESOLVED

Unchanged since baseline.

### F-TEST-04 — `lib/redact.sh`'s shape-based rules and newline no-op remain untested — the same mechanism F-SEC-09 needs fixed · **Medium**

**Evidence:** `test/redact.test.sh` (107 lines) covers only the placeholder-escaping bug from
`#1741`; the six hard-coded shape rules (`lib/redact.sh:20-28`) and `redact_add_literal`'s newline
no-op (`lib/redact.sh:80`) remain untested. `#1757` open, 36 days, 1 comment.

**Impact:** the one test suite that would catch a regression in the exact redaction mechanism
F-SEC-09 needs extended doesn't exercise it — a fix to F-SEC-09 landing without this coverage would
have no regression guard.

**Direction:** addressed by R-01 (existing `#1757`) — sequence with F-SEC-09's fix.

### F-TEST-05 — PARTIALLY RESOLVED · **Low** (remaining half)

**Evidence:** the state-sync flaky-test half is fixed (`#1722` closed 2026-10-05,
`test/state-sync.test.sh:2045-2046` now asserts `<= 1` instead of exact `0`). The
`publish-dashboard.sh` half remains: `test/publish-dashboard.test.sh:1545` still calls
`run_window 20`, unchanged; `#1205` now 51 days old, no PR.

**Direction:** addressed by R-20 (existing `#1205`).

### F-TEST-06 — Issue `#1036` describes already-fixed work, unclosed across four review cycles · **Low**

**Evidence:** the gap `#1036` describes (single-page issue digest feeding `work_gone_clearances`)
was fixed by PR #1165 (merged 2026-09-05) — `scripts/gather-source-state.sh:127` now uses `gh api
--paginate`. `#1036` itself, filed 2026-08-29, remains open and uncross-referenced two months later.

**Impact:** low — backlog hygiene noise, not a code defect; flagged for the maintainer to close.

**Direction:** not independently actionable by this review (closing an issue is a maintainer
action, not something this review's mandate covers); flagged here for visibility.

### F-TEST-07 — `test/stage-boundary.test.sh` and `test/state-sync.test.sh` carry many fixed-duration sleeps checking process-table state (new) · **Low**

**Evidence:** 23 `sleep <N>` calls in `stage-boundary.test.sh` (several 0.3–0.5s, checking process
state immediately after a `kill -KILL`/reap action); 18 in `state-sync.test.sh`.

**Impact:** legitimate tests of real OS process-group/signal behaviour, not junk — but short fixed
sleeps checking process-table state are a classic flakiness source under CI contention, the same
family already tracked for `publish-dashboard.test.sh`/`state-sync.test.sh` under F-TEST-05/`#1205`.

**Direction:** watch-only; file a tracked issue if `build-image.yml`'s run history shows a
correlated retry/failure.

## Dependencies and supply chain (DEPS)

**Strengths:** Dockerfile pin hygiene extended to the new Grok Build provider's version ARG;
Dependabot (added this window) is live and already producing merged/open PRs; `doctor.sh`'s
toolchain check now verifies `openssl`.

### F-DEPS-01, F-DEPS-02, F-DEPS-03, F-DEPS-04 — RESOLVED

All four resolved this window: Dependabot added (`#1145` closed via PR #2473); both floating
Compose sidecars pinned (same PR); `openssl` added to `doctor.sh` (`#1147` closed); no dependency
manifest remains correctly informational/resolved.

### F-DEPS-05 — Dependabot has no `docker` ecosystem entry, so the base OS image and hand-pinned toolchain versions get no automated update signal (new) · **Medium**

**Evidence:** `.github/dependabot.yml` covers only `github-actions` and `docker-compose`
(`/deploy/docker`) — no `docker` ecosystem entry for `deploy/docker/Dockerfile`'s `FROM
ubuntu:24.04`. `CLAUDE_CODE_VERSION`'s pin has been unchanged 47 days with zero automated-update
signal.

**Impact:** the same underlying gap `#1145` closed, reopened for a non-overlapping subset — base
OS image security patches in particular are exactly what a `docker` ecosystem entry exists to
catch automatically.

**Direction:** addressed by R-09. New issue filed this round: agent-ops#2697.

## Tooling and developer experience (TOOL)

**Strengths:** the rewritten contributor guide is accurate against current code (every file/command
it names was verified to exist); `./scripts/run-tests.sh --list` works without a container;
`shellcheck.yml` deliberately runs its full memory-unbounded union in CI with a well-reasoned
comment explaining why, and pins both the shellcheck binary version and its release-tarball SHA256.

### F-TOOL-01 — No `.editorconfig`, `.shellcheckrc`, or `Makefile` · **Low**

**Evidence:** confirmed absent; unchanged since baseline.

**Direction:** addressed by R-18 (existing `#1758`).

### F-TOOL-02 — Every Actions `uses:` line references a mutable tag, none SHA-pinned · **Medium**

**Evidence:** confirmed across all 17 current workflow files (`actions/checkout@v7`,
`docker/build-push-action@v7`, `github/codeql-action/analyze@v4`, etc.) — zero SHA pins. `#1918`
open, 29 days, 1 comment.

**Impact:** a compromised or re-tagged upstream Action release would be pulled automatically into
a build/deploy pipeline with write access to a public image registry.

**Direction:** addressed by R-10 (existing `#1918`).

### F-TOOL-03 — Docker-dependent verification gap · **Low** (informational)

**Evidence:** no Docker daemon available in this review's sandbox either, same as every prior
review in this series; the Docker-free fast path (`--list`) was independently confirmed working
this round, narrowing but not closing the gap.

**Impact:** this is a limitation of the review's own sandbox, not a repository defect.

**Direction:** no action needed; not covered by a numbered recommendation.

## CI/CD and release engineering (CI)

**Strengths:** 17 workflows (up from 11), each still carrying unusually thorough rationale
comments; Dependabot demonstrably working (one merged PR, one open); two of the baseline's
"advisory, not required" findings are now fixed (`config-table`, `changelog-section` both required
gates).

### F-CI-01 — PARTIALLY RESOLVED · see F-CI-08 for the still-open remainder

`config-table` is now a required gate (closing the config-table half). `toc` is not — tracked
separately by `#2117` and folded into F-CI-08 below as part of the same recurring pattern.

### F-CI-02 — `publish-dashboard.sh`'s open-issues fetch for the Priority display is single-page · **Medium**

**Evidence:** `scripts/publish-dashboard.sh:3365`, unchanged: `gh_call api
"repos/$slug/issues?state=open&per_page=30"`, no `--paginate`. `#1171` now 52 days old, 1 comment,
no PR.

**Impact:** the dashboard's own Priority display silently truncates at 30 open issues — directly
relevant now that F-GOV-04 establishes the real backlog is 581.

**Direction:** addressed by R-05 (existing `#1171`).

### F-CI-03 — PARTIALLY RESOLVED · see F-TOOL-02 for the still-open remainder (mutable Action tags)

The "no update mechanism" half is resolved by the same Dependabot config that closed F-DEPS-01.

### F-CI-04 — The Reviewer stage cannot read a failing CI log or re-run a job · **Medium**

**Evidence:** `prompts/implementer.md:308` has the `gh run view --log` extraction route;
`prompts/reviewer.md` has no equivalent. `#1496` now 43 days old, 2 comments, no PR.

**Impact:** a PR that reaches Reviewer with a red CI run cannot be diagnosed by the Reviewer stage
itself.

**Direction:** addressed by R-13 (existing `#1496`).

### F-CI-05 — RESOLVED (documented non-go)

Unchanged.

### F-CI-06 — RESOLVED

`changelog-section` is now a required gate; `#1916` closed 2026-10-02.

### F-CI-07 — The scheduled `CHANGELOG.md` roll has produced zero output in 32 days despite active remediation attempts · **Medium**

**Evidence:** `CHANGELOG.md`'s last edit is still the pre-feature migration commit (`a256590`,
2026-09-23), 32 days after the roll mechanism (PR #1842) merged 2026-09-25. No PR has ever opened
from a `changelog-roll` branch (`gh api search/issues?q=repo:Pullwright/agent-ops+head:changelog-roll`
→ `total_count: 0`), despite four follow-on fixes to its supporting marker mechanism (#2082,
#2067, #2118, #2115) and two still-open bugs in its own logic (#1846, #1848).

**Impact:** this has moved from "could be normal rollout lag" (the baseline's framing) to a month
of zero observed output despite active, repeated remediation attempts — the mechanism is not
merely slow, something is actively preventing it from ever firing.

**Direction:** addressed by R-12 (existing `#1846`, `#1848`) — worth an explicit end-to-end trace
of why no roll PR has ever opened, not just fixing the two known sub-bugs independently.

### F-CI-08 — The "advisory check, not a required gate" pattern has recurred for `toc` and `spec` (new) · **Medium**

**Evidence:** `toc` (`#2117`, open 25 days) and `spec` (`#2563`/`#2578`, open 7–8 days) are both
absent from ruleset `18857310`'s required-status-checks list, despite `spec.yml` running on every
PR and `docs/README.md` describing `spec.sh check` as a "permanent guard." `#2578`'s own
precondition (PR #2506 landing `spec.yml` on `main`) is already satisfied; the issue is a
fully-specified, one-click, owner-only ruleset edit that sat open 7 days as of this review.

**Impact:** a PR can currently merge with a dangling/colliding requirement-label citation — exactly
the defect `spec.sh` exists to catch — the same gap `config-table`/`changelog-section` had before
being fixed twice already this review series.

**Direction:** addressed by R-02 (existing `#2117`, `#2563`/`#2578`).

### F-CI-09 — No container-image vulnerability scan exists for the published, public image (new) · **Medium**

**Evidence:** no Trivy/Grype/`docker scout` step anywhere in `.github/workflows/`; the published
image (`ghcr.io/pullwright/agent-ops`) and source repo are both public, built from `ubuntu:24.04`.

**Impact:** a known-CVE OS package or installed toolchain binary would ship to a public registry
with nothing in CI flagging it — distinct from CodeQL's source-only scope.

**Direction:** addressed by R-06. New issue filed this round: agent-ops#2696.

## Performance and scalability (PERF)

**Strengths:** a real, measured host-wide performance incident (publisher duty-cycle collapse,
load average 4–6 on idle hosts) was diagnosed and fixed with before/after evidence across three
sequenced PRs (#2430/#2431/#2435); a second independently-landed fix converted two more full-union
slurps to streaming reducers after they OOM-killed five `jq` processes on one node (#2320); the
state-sync snapshot-growth gap is closed with a real cap, not just a floor (#1932).

### F-PERF-01, F-PERF-02, F-PERF-03 — RESOLVED

F-PERF-01 newly resolved this round (PR #2043 converted the publisher's full-log reader to a true
streaming reducer; every remaining `jq -sc` call site operates on an already-small or
deliberately-whole-array-needed input, several with an explicit comment citing `#1649`).
F-PERF-02/03 remain resolved, unchanged.

### F-PERF-04 — The dashboard publisher's local (non-GitHub) tick remains a linear function of total log history (new) · **Medium**

**Evidence:** about eight full `jq` passes over the 124 MB+ fleet-log union still run every local
tick (`read_events`, the per-cycle summary fold, the cycle-id scan, and five more), because these
readers are keyed by cycle id or need to see every record and so cannot take the declared-type
prefilter #2430/#2435 applied elsewhere. Explicitly deferred as `agent-ops#2434` out of that same
series ("Defers: #2434").

**Impact:** the common case (nine of every ten launcher windows, by the duty cycle the #2429 series
just restored) remains O(log size) even after this round's fixes, since `log.jsonl` is never
rotated by design — the cost will keep climbing with the fleet's age.

**Direction:** addressed by R-14 (existing `#2434`, already fully scoped with three candidate
approaches — execution, not further scoping, is what's needed).

## Usability and accessibility (UX)

**Strengths:** `agent-cycle.sh`/`review-cycle.sh`/`scripts/doctor.sh --help` all produce thorough
usage text; `doctor.sh`'s diagnostic output names what it checked and what to do on failure, with
exit codes verified live to match its documented contract exactly; `scripts/spec.sh`'s CLI
behaviour is clean (usage on no args, specific actionable error on an unresolvable label); no new
interactive elements were added to the dashboard this window.

### F-UX-01 — RESOLVED

Confirmed still resolved; no new interactive dashboard elements in the 202-commit delta.

### F-UX-02 — `publish-dashboard.sh --help` is silently swallowed by the catch-all flag handler · **Medium**

**Evidence:** confirmed live: `./scripts/publish-dashboard.sh --help --no-github --fast` prints no
usage and runs a full publish to completion, exit 0. `scripts/publish-dashboard.sh:208`'s `*)
shift ;;` catch-all is unchanged. `#1753` open, unassigned, 36 days stale.

**Impact:** a user trying to get help instead silently triggers the full publish action.

**Direction:** addressed by R-07 (existing `#1753`).

### F-UX-03 — `monitor-cycle.sh` has no `-h`/`--help` case · **Low**

**Evidence:** confirmed live: `./monitor-cycle.sh --help` exits 64 with "unknown argument: --help"
— loud but no usage text. Same tracking issue `#1753`.

**Direction:** addressed by R-07 (existing `#1753`).

## Documentation (DOC)

**Strengths:** `scripts/check-docs.sh` and `scripts/spec.sh check` both pass clean against current
HEAD; the append-only re-split convention was correctly adopted after a real incident (`#2472`) and
correctly followed by the very next split after this round's one slip; a substantial, measured
documentation overhaul is in flight (`#2083`, `scripts/docs-benchmark.sh`, a full new concept-page
suite, an in-flight Starlight site); the pipeline's own self-correction works (the Approver caught
and filed three contributor-guide inaccuracies promptly, `#2561`).

### F-DOC-01, F-DOC-03, F-DOC-04 — RESOLVED

All three resolved this window: vendored skill provenance restamped (`#1146` closed via `#2464`);
README crontab typo fixed same-day (`#1917`); README org-name drift fixed (`#1870` closed via
`#2170`).

### F-DOC-02 — RESOLVED

Unchanged, still correct.

### F-DOC-05 — A spec-split commit renamed existing files, reintroducing the exact collision `#2472` fixed (new) · **Medium**

**Evidence:** commit `9235549` (PR #2665, merged 2026-10-25) renamed pre-existing
`the-script-10.md`→`the-script-12.md` and `the-script-11.md`→`the-script-13.md` while inserting
new content at the vacated numbers — eight days after the written convention ("never rename or
renumber existing files when splitting") was adopted specifically to prevent this. The PR's
autonomous Approver review described the renames factually without flagging the contradiction, and
approved it. No automated check catches a rename-during-split.

**Impact:** reintroduces the silent-revert-on-concurrent-edit exposure `#2472` diagnosed, for every
file numbered `the-script-10` and above.

**Direction:** addressed by R-03. New issue filed this round: agent-ops#2694.

### F-DOC-06 — `docs/README.md` overclaims `spec.sh check` as a "permanent guard" it currently is not · **Medium**

**Evidence:** see F-CI-08 — `spec` is not a required status check despite the documentation's
wording.

**Impact:** a reader relying on the stated guarantee would be wrong about what currently blocks a
merge.

**Direction:** addressed by R-02, the same fix that closes F-CI-08.

### F-DOC-07 — Issue `#2326` describes a size-budget violation already resolved by a later split (new) · **Low**

**Evidence:** `the-script-08.md` is now 84,962 bytes, under the 100,000-byte budget, almost
certainly fixed incidentally by the neighbouring `#2665` split two weeks after `#2326` was filed.

**Impact:** low — stale backlog noise, the same pattern as F-TEST-06 for a different file.

**Direction:** flagged for the maintainer to close; not independently actionable by this review.

## Governance and project health (GOV)

**Strengths:** the licence-transition framing (MIT, provisional, pending FSL-1.1-ALv2
prerequisites) is internally coherent across `LICENCE`/`README.md`/`ROADMAP.md`; the branch
ruleset enforces squash-only merges, one required review, and
`require_extra_approval_for_unattributed_changes`; the prior review's own headline risk (the
transcript secret leak) is closed with maintainer-verified rotation evidence; a genuinely
deliberate decision log entry (`STANDING-DECISIONS.md`, 2026-10-16) directly adjudicates this
round's own backlog-volume finding with real numbers.

### F-GOV-01 — RESOLVED

Unchanged, still coherent.

### F-GOV-02 — PARTIALLY RESOLVED · **Low** (remaining half)

**Evidence:** `#1146` closed 2026-10-16. `#1753` (the UX-02/03 pair) remains open, unassigned,
zero comments since 2026-09-21 — 36 days stale, now understood as one concrete instance of the
much larger pattern F-GOV-04 documents rather than an isolated stall.

**Direction:** addressed by R-07 (existing `#1753`).

### F-GOV-03 — RESOLVED

Closed deliberately by the maintainer 2026-10-02, a considered decision rather than a hygiene
lapse.

### F-GOV-04 — The repository's real open-issue backlog is 581, not ~30, and growing roughly 3:1 (filed:closed) — a review-methodology correction as much as a project finding (new) · **Medium**

**Evidence:** `gh api search/issues -f q="repo:Pullwright/agent-ops is:issue is:open"
--jq '.total_count'` returns 581 — every prior review's "turns over within days" framing rested on
`gh issue list`'s unqualified 30-row default page, not a measured total. 248 of the 581 predate
the prior review's own baseline date. The pipeline's own Co-Ordinator input-fit ladder is pinned at
its tightest rung (tracked by a family of pager issues: `#2213`, `#2319`, `#2408`, `#2416`,
`#2557`, `#2577`), dropping 80–269 backlog entries per cycle. `STANDING-DECISIONS.md`'s 2026-10-16
entry records the owner's considered, explicit decision not to manage the backlog by volume,
citing a measured 225-filed-vs-78-closed count over three weeks (roughly 3:1).

**Impact:** two distinct things. (1) Every "triage is healthy" strength-claim this review series
has made, including this round's own dimension subagents' first pass, must be re-derived from a
measured total, never `gh issue list`'s silent default page, in every future review of this
repository. (2) The backlog is large, growing, and the owner has made a deliberate, documented
choice to rely on Priority/Issue-Dependencies ranking rather than volume management — defensible,
but it does mean a low-Priority, unbanded issue (like F-GOV-02's own `#1753`) can sit indefinitely
once the fit-ladder is pinned.

**Direction:** addressed by R-08 — no code fix prescribed; already an owner-adjudicated standing
decision with active architectural mitigation (`#2416`/`#2417`/`#2422`) in progress. Worth a
periodic owner check-in on whether the 3:1 trajectory is sustainable.

## Observability and operations (OPS)

**Strengths:** the longest-running, highest-profile OPS escalation in this review series (the
ockham memory-cgroup saga) resolved end-to-end this window, a real example of the owner-escalation
path working as designed; credential-minting outbound calls consistently timeout-wrapped;
`gh-shim.sh`/`github-limit.sh` provide substantial rate-limit-aware retry/caching machinery
installed as a `PATH` shim so it covers bare `gh` calls from inside a stage, not just sourced
library callers; `doctor.sh` gained a genuine new "Stage boundary" self-check with #2206.

### F-OPS-01 — RESOLVED

`#1569` closed `COMPLETED` 2026-10-22, after the maintainer's host-side fix (`#1579`) and
independent verification that two later OOM reports trace to an unrelated issue rather than a
regression. See F-OPS-04 for the residual gap this resolution exposed.

### F-OPS-02 — `state-sync.sh`'s `do_push` remains unbounded outside its one patched step · **Medium**

**Evidence:** `do_push()` (lines 995–1280) wraps only `redact_mirror_files` in a deadline; the
`git fetch`, both `rsync` passes, and the final mirror push all execute after the mirror lock with
no deadline wrapper of any kind. `#1701` open, 1 comment, no PR.

**Impact:** the exact failure class that produced the baseline's cited 7-hour wedge incident can
still recur from any of these four steps.

**Direction:** addressed by R-11 (existing `#1701`, `#1604`).

### F-OPS-03 — No dedicated runbook/incident index · **Low**

**Evidence:** `find docs -iname "*runbook*" -o -iname "*incident*"` returns nothing; unchanged.

**Direction:** low urgency for a single-maintainer audience, consistent with baseline; not covered
by a numbered recommendation.

### F-OPS-04 — No pager invariant exists for a memory/cgroup verdict, despite the gap it caused being resolved by a slower, less direct path (new) · **Low**

**Evidence:** `lib/pager-invariants.sh` has no `memory`/`cgroup` entry; the F-OPS-01 resolution
came from five autonomous investigations escalating to the owner after a blocked-item threshold
crossed — roughly nine days of repeated autonomous re-discovery before a human was paged directly,
not a direct page on the dashboard verdict itself.

**Impact:** the next node whose parent cgroup drifts unconfigured will reproduce the same
multi-day latency before a human is paged.

**Direction:** addressed by R-21. New issue filed this round: agent-ops#2698.

### F-OPS-05 — State-sync push failures on a transient DNS/proxy error have no retry (new) · **Low**

**Evidence:** `#1604` (open, 1 comment, `updatedAt 2026-10-05` with no PR) describes a push
silently ending with no retry on a transient DNS resolution error, correlated with a real node-stale
window.

**Impact:** compounds F-OPS-02's unbounded-steps gap — a retry added on top of an already-unbounded
`do_push` would need its own deadline, so these should be fixed together.

**Direction:** addressed by R-11 (existing `#1604`) — sequence with F-OPS-02's fix.

## Data handling and privacy (DATA)

**Strengths:** `docs/DATA-HANDLING.md` received a genuine accuracy pass this window (corrected
rotated-log inventory and external-services list, PR #2594); `deploy/docker/.env.example` ships
every secret field empty with rotation procedure documented inline; a fresh scan found no real
secrets or PII in the working tree.

### F-DATA-01 — RESOLVED

Unchanged in substance, now more accurate.

### F-DATA-02 — Fixtures still carry the maintainer's real GitHub usernames, though the count has started falling · **Low**

**Evidence:** `grep -rl "warwickallen\|Warwick-Allen" test/*.sh | wc -l` now returns 32, down from
35 at baseline — the first decrease recorded for this item, though likely incidental rather than a
deliberate fix. `#1174` open, unchanged scoping.

**Direction:** addressed by R-17 (existing `#1174`).

### F-DATA-03 — `docs/DATA-HANDLING.md` still overclaims the mirror-push redaction pass's coverage · **Medium**

**Evidence:** the document's "Redaction for screenshots" paragraph is untouched by this window's
otherwise-genuine accuracy pass; it still implies data "can be safely shared for debugging without
leaking credentials" without distinguishing the separate, more limited mirror-push redaction pass
that actually runs before content reaches the external state-mirror repository — the pass F-SEC-09
shows still has an open coverage gap.

**Impact:** a reader relying on this document would over-trust coverage for what actually reaches
the mirror.

**Direction:** addressed by R-01, alongside the code fix it describes.

---

## Not covered by a numbered recommendation

F-ARCH-01's broader tracker (beyond its worst current instance, addressed by R-15) remains the
right home for the rest of the stage-orchestration decomposition backlog (`#1756`, `#1253`–`#1255`,
`#1996`) — no new action beyond what those existing issues already describe. F-CODE-03
(publish-dashboard.sh/doctor.sh growth) is monitored and partially addressed by R-23's
extraction work; no new issue. F-TOOL-03 (Docker verification gap) is this review's own sandbox
limitation, not a repository defect. F-OPS-03 (no runbook) remains low-urgency for a
single-maintainer audience, as the baseline already judged. F-TEST-07 (sleep-based test
flakiness risk) is watch-only pending an actual observed flake. F-TEST-06 and F-DOC-07 (two stale
issues describing already-resolved work) are flagged above for the maintainer to close; closing an
issue is outside this review's own mandate (filing new debt and updating registers), so neither is
actioned directly by this review.
