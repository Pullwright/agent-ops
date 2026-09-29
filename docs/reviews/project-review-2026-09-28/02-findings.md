# Findings

This is the fifth full review of agent-ops. It treats the 2026-09-21 review (revision `5284c02`)
as a verified baseline: every finding from that review was re-verified with fresh evidence — code
re-read, and every cited GitHub issue re-checked live via `gh issue view` — against the current
tree (revision `069e94b`, 63 commits / 196 files later), rather than assumed carried-forward.
Findings confirmed unchanged are marked accordingly; findings new to this round are marked `(new)`.

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 1 |
| Medium | 18 |
| Low | 21 |

18 further findings from the 2026-09-21 review are confirmed **Resolved** this round and are
listed in their dimension section without contributing to the tally above.

## Architecture and design (ARCH)

**Strengths:** the 63-commit window shows deliberate seam engineering where it matters most: the
new changelog subsystem (`lib/changelog-grammar.sh`, `scripts/check-changelog-section.sh`,
`scripts/assemble-changelog.sh`) puts the parsing grammar for a producer (a PR description) and
consumer (the release/roll assembler) in one shared file instead of two re-implementations, and is
exercised end-to-end in `test/changelog-section-gate.test.sh`. `lib/report-directory.sh`'s
degraded-vs-empty distinction and `lib/rebase-only.sh`'s fail-closed patch-id primitive (new this
window) are further examples of well-bounded modules with explicit failure semantics.
`docs/ROADMAP.md` D6/D8 explicitly names the bash-monolith shape as a deliberate "strangler" state
pending a language rewrite/repo split, so the architecture's proportionality is a documented
decision that matches reality, not an oversight.

### F-ARCH-01 — `agent-cycle.sh`'s undecomposed top-level flow keeps growing, and the issue meant to catch up the whole backlog has itself gone inert · **Medium**

**Evidence:** `agent-cycle.sh` is now 4,236 lines (was 4,025 at the prior baseline, 3,408 two
reviews ago) — +211 lines (+5%) this window, tracked only by agent-ops#1253 (open, unchanged,
`updatedAt: 2026-09-08`, no activity since filed). `monitor-cycle.sh` is essentially byte-identical
to baseline (1,310 lines both times), so its ~62% flat-top-level-flow ratio is unchanged.
Critically, agent-ops#1756 — opened by the prior review specifically to file issues for
`run_standdown_checks`/`compute_skip_lists`, file one for `monitor-cycle.sh`, and close stale
#1256 — is **still open with zero comments beyond its own creation**. `#1256` is still open, still
naming `coordinator_corroborate_retry_or_fallback`, a function PR #1560 already deleted from the
tree.

**Impact:** the project's own remediation-tracking issue for this defect has itself become inert —
a meta-regression stacked on the original one; a reader trusting the tracker sees four promised
actions that never happened and one issue pointing at dead code.

**Direction:** action #1756's four items directly, or close and re-file with corrected scope.
Addressed by R-11.

### F-ARCH-02 — Small utility functions duplicated between `agent-cycle.sh` and `review-cycle.sh` · **Resolved**

**Evidence:** unchanged from the prior confirmation: `lib/config-access.sh` (`cfg()`, `cfg_json()`,
`expand_home()`) and `lib/log-event.sh` remain the shared homes; agent-ops#967 is closed. The new
`monitor-cycle.sh` entrypoint also sources `lib/config-access.sh` rather than redefining these
helpers — no regression from the third entrypoint.

### F-ARCH-03 — No cross-tool seam regressions found in this window's producer/consumer changes · **Resolved** (new observation)

**Evidence:** traced the two most plausible seam-break candidates from this window: (1) `498646e`
(minting the landing-refused class as an enforced field) — every reader already reads `.class`
consistently with the writer's new closed value set; (2) the `report_directory` resolution and
degraded-walk-signalling commits — both call sites explicitly check `$?` with a comment explaining
why. Neither seam shows a one-sided update.

### F-ARCH-04 — Deprecated-alias migration (`project_review`→`repository_review`) is clean, and unrelated to the similarly-spelled `project-review` candidate source · **Resolved** (new observation)

**Evidence:** `3bf42ec` renamed the config block with a fail-on-both-set guard; `doctor.sh` and
`render-config-table.sh` handle it consistently. Verified this is unrelated to the hyphenated
`project-review` candidate-source name used elsewhere in the codebase — a distinct, intentionally
and consistently named concept, not a missed rename.

## Code quality and maintainability (CODE)

**Strengths:** no TODO/FIXME/HACK markers and no commented-out code found anywhere in `lib/`,
`scripts/`, or the three entry points. A per-file `shellcheck` sweep (full `-x` runs were
infeasible in this sandbox — OOM-killed under its RAM ceiling) turned up findings in only four
files, every one manually traced to a genuine cross-file global consumed by a sourced `lib/*.sh` —
false positives from single-file analysis, not real dead code. This is consistent with the prior
review's "shellcheck clean" finding.

### F-CODE-01 — Stage-orchestration god functions: no new fix landed; `run_standdown_checks` grew further while two others held steady · **Medium**

**Evidence:** `maybe_run_enabler` (`lib/enabler.sh`): 986 lines, up from 978. `run_approver_stage`
(`lib/approver.sh`): 442 lines, unchanged. `run_standdown_checks` (`lib/standdown.sh`): **1,008
lines, up from 936 (+72, +7.7%)** — the largest single-function growth of the window.
`compute_skip_lists` (`lib/candidate-gather.sh`): 786 lines, unchanged. Tracking issues #1254/#1255
remain open with no comments since 2026-09-08; #1256 still names a deleted function; no issue
exists yet for `run_standdown_checks` or `compute_skip_lists`.

**Impact:** the largest of these functions keeps absorbing new logic rather than being decomposed,
making the eventual split more expensive each time it is deferred.

**Direction:** same fixes as already specified in #1254/#1255, plus the two still-missing issues
from #1756. Addressed by R-11.

### F-CODE-02 — `san()` copy-pasted between `lib/claim.sh` and `scripts/sweep-orphan-branches.sh` · **Resolved**

**Evidence:** both still source the shared `lib/claim-key.sh:17` — unchanged since PR #1332.

### F-CODE-03 — `scripts/publish-dashboard.sh` and `scripts/doctor.sh` remain almost entirely top-level flow and keep growing · **Low**

**Evidence:** `publish-dashboard.sh`: 4,236 lines (was 4,087, +3.6%), 18 functions (was 16).
`doctor.sh`: 2,657 lines (was 2,534, +4.9%), 11 functions (was 10). Growth continues at roughly the
same rate as the prior two review windows.

**Impact:** low; no acute risk, but the gap versus `review-cycle.sh`'s decomposed shape widens
slightly every cycle.

**Direction:** no urgent action. Addressed nominally by R-20 (watch, not act).

### F-CODE-04 — `dashboard/index.html`'s `renderBody()` is still the dominant, still-growing outlier function · **Low**

**Evidence:** `renderBody()` is now **552 lines**, up from 538 at baseline and 462 two reviews ago —
still growing every window. The next-largest function is `landingsPanel()` at 159 lines, so
`renderBody()` is now ~3.5x its size. agent-ops#1173 (extract per-banner helpers) is open with no
comments since 2026-09-08.

**Direction:** extract per #1173. Addressed by R-20.

### F-CODE-05 — `cfg()` is still duplicated (and still diverging) between `lib/claim.sh` and `scripts/sweep-orphan-branches.sh` · **Low**

**Evidence:** both files still define `cfg()` with a `2>/dev/null` suppression the shared
`lib/config-access.sh:20` version lacks. agent-ops#1755 (fully-specified fix, opened by the prior
review) is open with no comments since creation and no commit in the window references it.

**Impact:** low (cosmetic stderr suppression), but it is the one piece of the #1332 `san()`/`cfg()`
cleanup left undone and remains un-actioned a full review cycle later.

**Direction:** execute #1755 as written. Addressed by R-15.

### F-CODE-06 — The paginated-comment/-review-fetch idiom is independently reimplemented in 13+ files, with no shared helper, and this window added two more instances rather than extracting one · **Low** (new)

**Evidence:** 13 files independently implement the same `gh api ".../comments|reviews|timeline"
--paginate` shape; two commits this window (`79e6353`, `40dcb65`) each added one more instance
citing an existing file's idiom rather than extracting a shared helper; the same caveat comment is
repeated verbatim in at least 6 of these files.

**Impact:** low today, but the idiom — and its caveat — is now copy-documented in a dozen-plus
places; a future correctness fix must be manually propagated to all of them.

**Direction:** consider a thin shared `gh_paginated_fetch` wrapper in `lib/github-limit.sh`; not
urgent. Addressed by R-20 (new tracking issue agent-ops#1919 filed this run).

## Security (SEC)

**Strengths:** the redaction module continues to receive careful, well-tested incremental
hardening (two more fixes landed this window, both closing prior review findings). `.env`
permission checks remain in place and unchanged. `deploy/docker/.env.example` is exemplary in
documenting which values are secrets, how to rotate them, and why. The dashboard's `esc()`
mis-naming fix continues to hold. A genuine personal-data leak in shipped deploy defaults was found
and fixed within this window (F-SEC-08).

### F-SEC-01 — Dashboard `esc()` helper's misleading name · **Resolved**

**Evidence:** `esc()` still doesn't escape, but zero call sites pair it with `innerHTML`; a warning
comment guards against the misuse. Issue #965 still closed.

### F-SEC-02 — No `SECURITY.md` · **Resolved**

**Evidence:** unchanged since the prior review — still documents a private-advisory disclosure
route.

### F-SEC-03 — CodeQL covers only Actions YAML · **Resolved (documented non-go)**

**Evidence:** unchanged; issue #976 remains closed via the "SAST spike is a no-go for now"
decision.

### F-SEC-04 — `lib/claim-key.sh`'s `san()` has no explicit `.`/`..` rejection · **Low**

**Evidence:** issue #1172 still open, 21+ days no activity. Code unchanged; every current caller
still appends a filename suffix after calling `san()`, so a bare `..` remains unexploitable in
practice.

**Direction:** addressed by R-14.

### F-SEC-05 — Live production secrets printed into an agent session transcript on 2026-09-16 remain unresolved 13 days later · **High**

**Evidence:** issue #1627 still open, **zero comments**, `updatedAt` unchanged since creation —
**13 days** of complete silence, up from 6 days at the prior review. No commit references #1627.
No visible record that the exposed Vercel token or GitHub App private-key paths have been rotated.
`lib/redact.sh`'s shape rules still do not cover a Vercel token shape or a key path.

**Impact:** harm is bounded only by what the real, still-possibly-unrotated credentials grant on
the accounts behind them, per the checklist's "weighing a dangerous defect in a trivial project"
guidance — not by this project's maturity. The 13 days of zero engagement is itself a growing
exposure window.

**Direction:** rotate/assess exposed credentials; decide the sandboxing/environment-separation
question — an owner-only decision per the issue's own framing. Addressed by R-01.

### F-SEC-06 — `redact_add_literal`'s PLACEHOLDER argument was unescaped for sed-replacement specials · **Resolved** (fixed this window)

**Evidence:** issue #1741 closed, fixed by commit `cb6929d` (PR #1791, merged 2026-09-23) — a
`_redact_escape_replacement()` helper now escapes `\`/`&`/`#` before splicing into the sed rule.
New dedicated `test/redact.test.sh` covers the fix.

**Direction:** the fix's own PR filed two follow-on issues (#1823, #1757) — see F-SEC-09/F-TEST-04.

### F-SEC-07 — `redact_add_literal` silently no-ops on a newline-bearing secret · **Resolved** (fixed this window)

**Evidence:** issue #1730 closed, fixed by commit `6739654` (PR #1761, merged 2026-09-22) — both
call sites now check the newline condition themselves and warn on stderr before calling
`redact_add_literal`.

### F-SEC-08 — Shipped deploy defaults hard-coded the maintainer's real username, home path and timezone · **Resolved** (new, fixed this window)

**Evidence:** issue #656 closed by commit `76c1639` (PR #1868, merged 2026-09-26). `RUNAS`/`APPDIR`
are now hard-required with no default; `TZ` now defaults to `UTC`.

**Impact:** resolved for the shipped defaults, but not fully swept: `README.md` and
`docs/IMPLEMENTATION-PIPELINE-SPEC.md` still carry one literal example command naming the same
real username and path, outside the scope #656's PR touched.

**Direction:** low-severity follow-up to genericise the two remaining example lines; not filed as a
separate issue (illustrative only, grants no access).

### F-SEC-09 — `redact_add_literal`'s coverage gap for env-sourced runtime secrets (Vercel token, GitHub App key paths) remains open with only a scoping comment · **Medium** (new, tracks the same gap as F-SEC-05)

**Evidence:** issue #1752 open, filed 2026-09-21, one scoping comment the same day and nothing
since (8 days). Neither `scripts/preview-deploy.sh` nor any other script registers `VERCEL_TOKEN`/
`VERCEL_AUTOMATION_BYPASS_SECRET` via `redact_add_literal`, though `preview-deploy.sh` uses
`VERCEL_TOKEN` directly in an `Authorization: Bearer` header — a value that, per F-SEC-05's
incident, has already reached at least one transcript unmasked.

**Impact:** same underlying gap as F-SEC-05 — a real class of secret this pipeline handles is not
covered by the redaction pass used before pushing content to the state-mirror repository.

**Direction:** land the scoped fix. Addressed by R-01.

## Testing and quality assurance (TEST)

**Strengths:** test volume grew from 223 to 234-237 files in this window; test LOC now exceeds
`lib/`+`scripts/` LOC by a 1.31:1 ratio. A sample of 11 touched/added test files all ran clean
directly on the host (jq 1.7, matching CI). Tests document behaviour, typically citing the
originating issue and failure scenario in their own assertion messages.

### F-TEST-01 — `lib/git-identity.sh` has no test coverage anywhere in the suite · **Low**

**Evidence:** `require_git_identity` is called by both entry points but has no matching assertions
anywhere; the five test files referencing its env vars use them only as a fixture precondition for
an unrelated scenario. Issue #1148 remains open, unchanged.

**Direction:** addressed by R-16.

### F-TEST-02 — No coverage-measurement tooling exists · **Low**

**Evidence:** no `kcov`/`bashcov`/equivalent anywhere; `scripts/run-tests.sh` has no `--coverage`
option. Issue #1148 (shared with F-TEST-01) still open.

**Direction:** addressed by R-16.

### F-TEST-03 — `5284c02`'s webhook-redaction fix left one call site untested; now closed · **Resolved**

**Evidence:** commit `6739654` (PR #1761) added the missing regression block to
`test/publish-dashboard.test.sh`, mirroring `test/state-sync.test.sh`'s existing coverage.

### F-TEST-04 — `lib/redact.sh` still has no test file matching its own comprehensive-coverage bar; tracking issue #1757 half-closed but left open · **Low**

**Evidence:** `test/redact.test.sh` now exists but covers only the placeholder-escaping bug, not the
shape-based rules or the newline no-op behaviour issue #1757's own acceptance criteria asked for.
#1757 remains open even though its other criterion (F-TEST-03) is done.

**Direction:** addressed by R-16.

### F-TEST-05 — Two flaky tests have fully-specified, one-line fixes sitting idle for 9–23 days · **Low**

**Evidence:** issue #1205's fix (`run_window 20`→`30` at `test/publish-dashboard.test.sh:1277`) has
sat unpicked 23 days; issue #1722's fix (widen an exact-`"0"` assertion) has sat unpicked 9 days.
Neither has a linked PR. `build-image.yml`'s last 50 runs: 0 failures.

**Direction:** addressed by R-17.

### F-TEST-06 — Issue #1036 continues to describe already-resolved work, now unclosed for 3 review cycles · **Low**

**Evidence:** the pagination fix #1036 describes shipped in commit `916a951` (PR #1165), which
predates even the *2026-09-21* baseline — #1036 remains open with no cross-reference.

**Direction:** not a code fix; flagged for the maintainer to confirm and close.

## Dependencies and supply chain (DEPS)

**Strengths:** the Dockerfile's supply-chain hygiene is genuinely strong: `supercronic` and
`shellcheck` are pinned to a release tag *and* checksum-verified at build time; `claude-code` is
pinned to an exact npm version; each pin carries an inline rationale comment. GHA build caching is
wired for both build legs. CI is green and fast across the last 15 runs sampled.

### F-DEPS-01 — No update mechanism for agent-ops's own pinned dependencies · **Medium**

**Evidence:** no `dependabot.yml`/Renovate config anywhere; no automated bump has touched any
Actions `uses:` line or Dockerfile `ARG` in this window. Issue #1145 open, unchanged.

**Impact:** every version literal is bumped only when a human or agent notices by hand.
`CLAUDE_CODE_VERSION` has sat unchanged 19+ days.

**Direction:** addressed by R-05.

### F-DEPS-02 — Two Compose sidecar images still float on `:latest` with no pin · **Medium**

**Evidence:** `tailscale/tailscale:latest` and `containrrr/watchtower:latest` remain unpinned;
every other image reference in the file resolves to this repo's own CI-published tag. Tracked by
the same issue #1145.

**Direction:** addressed by R-05.

### F-DEPS-03 — `scripts/doctor.sh`'s Toolchain check still omits `openssl` · **Low**

**Evidence:** unchanged; `lib/approver-token.sh` still hard-depends on `openssl` for JWT signing,
the Dockerfile still installs it for that reason, `doctor.sh`'s toolchain loop still doesn't check
for it. Issue #1147 open, unchanged.

**Direction:** addressed by R-13.

### F-DEPS-04 — No dependency manifest exists to have a licence-compatibility problem · **Resolved** (informational)

**Evidence:** no package manifest anywhere; the only "dependencies" are OS packages and pinned
binaries baked into a private deployment image, never redistributed. `LICENCE` already assessed
under GOV (F-GOV-01).

## Tooling and developer experience (TOOL)

**Strengths:** `scripts/run-tests.sh` is a well-designed build-health safeguard, running the suite
inside a throwaway container from the published image with an explicit, documented rationale. The
container install path in README is concrete and every referenced file/command was verified to
exist. CI is fast; the last 15 sampled runs are all green.

### F-TOOL-01 — No `.editorconfig`, `.shellcheckrc`, or Makefile/scripts-index · **Low**

**Evidence:** all three still absent. Issue #1758 (filed 2026-09-21) still open, scoped narrowly
(editorconfig only, three properties). No PR references it.

**Direction:** addressed by R-19.

### F-TOOL-02 — GitHub Actions still pinned to version tags, not commit SHAs · **Low**

**Evidence:** every `uses:` line across all 10 action-consuming workflows still references a
mutable tag; `docker/login-action`/`docker/build-push-action` run with registry-push credentials on
every push to `main`. Distinct from #1145's version-*bump* scope — no issue previously tracked the
tag-vs-SHA trust model specifically.

**Direction:** addressed by R-05 (new tracking issue agent-ops#1918 filed this run).

### F-TOOL-03 — Newcomer clone-to-running path is traceable and all referenced artifacts exist, but unverifiable end-to-end in this sandbox · **Low** (new, informational)

**Evidence:** every file/command README's container-install section names was confirmed to exist at
its stated path; no Docker daemon is available in this research sandbox, so the actual
`docker compose up -d`/boot path could not be executed.

**Direction:** a future review with Docker access should close this verification gap; not a repo
defect.

## CI/CD and release engineering (CI)

**Strengths:** 11 workflows totaling 1,077 lines, each with an unusually thorough rationale
comment. Recent run history is healthy across most workflows (30/30 success in the last 30 runs for
several); the few failures on others are on since-corrected pipeline-authored branches, i.e. the
gates are demonstrably catching real violations.

### F-CI-01 — The config-table (and toc) check is still not an actual required merge gate · **Medium**

**Evidence:** the live branch ruleset requires exactly 8 named contexts, neither `config-table` nor
`toc` among them; neither workflow has a `merge_group:` trigger. Issue #1144 (the owner's own
binding sequencing decision) unchanged since 2026-09-08.

**Direction:** addressed by R-02.

### F-CI-02 — `publish-dashboard.sh`'s issues fetch remains single-page · **Medium**

**Evidence:** the fetch is still `per_page=30` with no `--paginate`. Issue #1171 open, unchanged.

**Direction:** addressed by R-06.

### F-CI-03 — No update mechanism for pinned dependencies; GitHub Actions still pinned to mutable tags · **Medium**

**Evidence:** same underlying gap as F-DEPS-01/F-DEPS-02/F-TOOL-02; issue #1145, open.

**Direction:** addressed by R-05.

### F-CI-04 — The Reviewer stage still cannot read a failing CI log or re-run a failed job · **Medium**

**Evidence:** `prompts/reviewer.md` still lacks the run-level-log route `prompts/implementer.md`
already documents. Issue #1496 carries a fully-verified, twice-confirmed specification; no PR
references it.

**Direction:** addressed by R-08.

### F-CI-05 — CodeQL's security-scanning coverage remains limited to the `actions` language · **Low**

**Evidence:** unchanged; an accurate, self-aware, already-resolved limitation.

### F-CI-06 — The new `changelog-section` gate is live and catching violations, but not wired into the branch ruleset as a required check — a fresh instance of the F-CI-01 pattern · **Medium** (new)

**Evidence:** `doctor.sh`'s own live acceptance check reproduces the gap directly: `[warn] ...
default branch ruleset does not require "changelog-section"`. Issue #1804 (the feature's own
tracking issue) is closed with the check shipped and running, but nothing tracked the
ruleset-wiring gap specifically until this review.

**Impact:** a pull request can currently merge with a missing/malformed `## Changelog` section — the
exact defect the check exists to catch — as long as the other 8 required checks pass.

**Direction:** addressed by R-02 (new tracking issue agent-ops#1916 filed this run).

### F-CI-07 — The just-shipped weekly CHANGELOG.md roll has not yet produced its first scheduled run · **Low** (new, observational)

**Evidence:** the feature (PR #1842) merged 2026-09-25; its first scheduled firing under the shipped
defaults would have been Monday 2026-09-28 ~06:13 UTC, but `CHANGELOG.md`'s last edit still predates
the feature and no roll-output PR exists. Could be normal image-rollout lag rather than a defect —
not verifiable from a static checkout.

**Direction:** worth a from-the-fleet check on the next opportunity; not a code fix from what this
review could verify.

## Performance and scalability (PERF)

**Strengths:** the window shows real, verifiable convergence toward measurement over estimation:
the `min_free_workspace_bytes` derivation (previously an estimate) is now measurement-derived.
`lib/stage-budget.sh` (new) derives timeout/watchdog budgets from the fleet's own event log via a
documented, censoring-aware controller. `lib/stage-health.sh` explicitly parses its stream via
`jq -R -n 'inputs'` rather than slurp-and-regex-split, reusing the proven fast-parse pattern — just
not everywhere it needs to be (F-PERF-01).

### F-PERF-01 — `publish-dashboard.sh`'s headline full-log slurp is unchanged; the proven streaming fix was applied to a sibling reader, not to the reader the fleet's own incidents named · **Medium**

**Evidence:** `scripts/publish-dashboard.sh:1110` still runs `jq -sc '.' "$events_jsonl"` — the
exact slurp issue #1649 exists to convert. #1649 remains open with no PR ever opened against it;
the one PR that did land in this area (#1635) fixed a different memory coupling in the same
script. `log.jsonl` remains permanently unrotated by design, so this reader's working set keeps
growing for the node's lifetime.

**Impact:** the container-OOM/livelock failure mode that produced two real, now-closed incidents on
this exact code path can recur, because the fix that would prevent it hasn't been applied to it.

**Direction:** addressed by R-09.

### F-PERF-02 — Disk-footprint estimation → measurement gap closed · **Resolved**

**Evidence:** issue #904 closed, resolved by #1903 (measurement-derived clone-footprint threshold),
ratified by #1908.

### F-PERF-03 — No new unbounded loops or algorithmic red flags found in the window's four new subsystems · **Resolved** (new, informational)

**Evidence:** `lib/rebase-only.sh`, `lib/stage-budget.sh`, `lib/stage-health.sh`, and the changelog
subsystem were all read in full — every loop/fold is bounded by a count, time window, or single
bounded diff.

## Usability and accessibility (UX)

**Scope note:** the only human-facing UI remains `dashboard/index.html`; everything else is
CLI/config surface. Confirmed by diffing the dashboard across this window: the new panels added
(review stage health, mirror-rebuild verdict) are read-only, non-interactive display elements.

**Strengths:** 30 of 33 top-level scripts with argument-parsing loops have a real `-h|--help` case.
`review-cycle.sh`'s `usage()` is a good model.

### F-UX-01 — Dashboard's clickable rows/cards remain keyboard-operable · **Resolved**

**Evidence:** no interactive elements were added or changed in this window; `makeActivatable()`
still applies unchanged to the three original click targets.

### F-UX-02 — `scripts/publish-dashboard.sh` still silently discards any unrecognised flag, including `-h`/`--help` · **Medium**

**Evidence:** the flag loop's catch-all is byte-for-byte unchanged (`*) shift ;;`). Issue #1753
(opened by the prior review, fully scoped) is still open, unassigned, no PR references it — a full
review cycle later.

**Impact:** a typo'd flag, or `-h`, silently runs a full dashboard rebuild instead of erroring or
printing help.

**Direction:** addressed by R-03.

### F-UX-03 — `monitor-cycle.sh` still has no `-h`/`--help` · **Low**

**Evidence:** the loud unknown-argument error is unchanged, but there's still no `-h|--help` case or
`usage()` function. Same tracking issue #1753.

**Direction:** addressed by R-03.

## Documentation (DOC)

**Strengths:** both generated regions are current and pass their checks. The `project_review`→
`repository_review` config rename is documented coherently everywhere checked.

### F-DOC-01 — `docs/REVIEW-PIPELINE-SPEC.md`'s vendored-skill provenance stamp is still stale, still with no drift-check · **Medium**

**Evidence:** still names a vendoring date and upstream commit that predates two real in-repo edits
since. Issue #1146, filed 2026-08-31, still open, fully scoped, unassigned — now 29 days old and
unfixed across four consecutive reviews.

**Direction:** addressed by R-04.

### F-DOC-02 — Both pipeline specs' target-repositories sections now correctly list all three configured repositories · **Resolved**

**Evidence:** PR #1901 (closing #1754) landed both spec edits, matching `config.json`'s three
configured repos exactly.

### F-DOC-03 — README's "Keep it fresh" crontab example has a duplicated path segment · **Medium** (new)

**Evidence:** the current (non-legacy) crontab install line duplicates the `Poetic-Poems` org
segment in its path (`.../Poetic-Poems/Poetic-Poems/agent-ops/...`) — distinct from the
already-tracked legacy-section org-name drift (agent-ops#1870), since this line is a currently
active install instruction, not a marked-retired one.

**Impact:** an adopter who copies this line verbatim installs a crontab entry pointing at a
non-existent path; the dashboard's periodic refresh silently never fires, with no error surfaced.

**Direction:** addressed by R-12 (new tracking issue agent-ops#1917 filed this run).

### F-DOC-04 — README's post-transfer org-name drift is documented but only partially tracked · **Low** (new)

**Evidence:** the repo moved from `Poetic-Poems/agent-ops` to `Pullwright/agent-ops`; most
references were updated, but the README's intro-sentence link and one legacy-section example still
name the old org, neither cited by the existing tracking issue (agent-ops#1870, filed the day
before this review) even though it already covers eight other locations.

**Direction:** addressed by R-12 (widen #1870's existing scope by one location).

## Governance and project health (GOV)

**Bus factor:** unchanged from `AGENTS.md`'s own disclosure (single maintainer, two GitHub
handles, self-review by design, no succession plan) — a known, disclosed risk, not re-litigated
here.

### F-GOV-01 — `SECURITY.md`, `CONTRIBUTING.md`, issue/PR templates, and the licence-transition notice remain present and coherent · **Resolved**

**Evidence:** all four unchanged in substance and still coherent with `AGENTS.md`'s own stated
obligations. A `default` branch ruleset remains active on `main`.

### F-GOV-02 — Two `refined`, ready-to-work tracking issues (#1146, #1753) have sat unpicked for a full review cycle or more · **Medium** (new)

**Evidence:** both issues are fully scoped and unassigned; #1146 is 29 days old, #1753 is 8 days
old (the prior review's own output). Neither has attracted a PR. By contrast, the bulk of the
30-issue open backlog turns over within days of filing — these two are outliers, not evidence of
general triage failure.

**Impact:** two low-effort, fully-scoped fixes requiring no design work have outlasted three-plus
review cycles.

**Direction:** both are already fully specified — see F-DOC-01 (R-04) and F-UX-02/F-UX-03 (R-03);
no further refinement needed, just execution.

### F-GOV-03 — A substantive draft PR (#1577) has sat inactive for two weeks after the pipeline's own reviewer flagged a content conflict · **Low** (new)

**Evidence:** PR #1577 (a complete 287-line roadmap-split plan document, checks passing) was left
in Draft the same day it was opened because the pipeline's own Reviewer found its central premise
inconsistent with `docs/ROADMAP.md`'s current, amended D8 decision. No activity since (14 days).

**Impact:** low — reflects the pipeline correctly self-catching a real inconsistency rather than a
hygiene failure, but the correction hasn't been picked back up.

**Direction:** none prescribed; flagged for visibility only.

## Observability and operations (OPS)

**Strengths:** `lib/stage-health.sh` (new) is a genuinely good addition: a per-node, per-stage
health verdict computed from the node's own event stream, written atomically, wired into the
published heartbeat. The `docs/STANDING-DECISIONS.md` `actions: write` entry is a clean example of
an authorization question being surfaced, decided by the owner, and recorded rather than left
ambient. Two comment-pagination-ceiling bugs were fixed this window.

### F-OPS-01 — The `unbounded`/`livelocked` memory-cgroup verdict is now five investigations and 9 days deep with zero remediation, still has no paging path, and the host-access gap that blocks it has itself become a standing pattern · **Medium**

**Evidence:** issue #1569 still open (5 days stale), now carrying **five independent
investigations** reaching the identical conclusion: the fix needs host access no pipeline stage can
reach. A second, related issue (#1639) shows the pattern compounding — the setup script's own
shipped default produces the exact `livelocked` shape its sibling code now warns about.
`lib/pager-invariants.sh` still carries no `memory`/`cgroup` entry.

**Impact:** a verdict visible on the dashboard and known via five separate investigations still
produces zero automatic escalation to a human.

**Direction:** addressed by R-10.

### F-OPS-02 — The mirror-lock wedge fix remains scoped to the redaction loop only; the rest of `do_push` is confirmed still unbounded · **Medium**

**Evidence:** only `redact_mirror_files` is wrapped in a deadline; the `git fetch`, both `rsync`
passes, and the final `git push` all execute after `mirror_lock` is taken with no deadline. Issue
#1701 (fully specced) is open with no PR; a repo-wide grep again found no `timeout`(1) wrapper on
any `gh api`/`gh pr`/`gh issue`/`gh graphql` call anywhere.

**Impact:** the exact failure class that produced a 7-hour wedge incident can recur from any of the
four still-unbounded steps.

**Direction:** addressed by R-07.

### F-OPS-03 — No dedicated runbook or incident index exists; incident knowledge is still scattered file-header prose, and it keeps growing in this form · **Low**

**Evidence:** two more full incident narratives were added to file headers this window alone; no
file cross-references the others.

**Direction:** low urgency for a single-maintainer audience; unchanged since the prior review.

## Data handling and privacy (DATA)

**Strengths:** `docs/DATA-HANDLING.md` remains substantive and accurate. No real secrets or PII
dumps found in a fresh scan of the working tree. `deploy/docker/.env.example` ships with every
secret field empty and thoroughly documented.

### F-DATA-01 — No personal-data inventory doc · **Resolved**

**Evidence:** `docs/DATA-HANDLING.md` unchanged and still substantive.

### F-DATA-02 — Fixtures carry the maintainer's real GitHub usernames, and the count is growing despite an already-scoped fix · **Low**

**Evidence:** now 35 test files (up from 33), even though issue #1174's fix has been scoped since
2026-09-05 with no pickup.

**Impact:** low-sensitivity (a public GitHub username, already public), but the direction of travel
is wrong.

**Direction:** addressed by R-18.

### F-DATA-03 — The state-mirror redaction pass has a demonstrated, still-open gap for non-token-shaped runtime secrets, and `docs/DATA-HANDLING.md` does not flag it · **Medium**

**Evidence:** the document's redaction claim is scoped to dashboard screenshots and doesn't mention
the separately-applied, separately-gapped mirror-push redaction pass (F-SEC-05/F-SEC-09); its "none
of this data is published outside the installation" line reads as though the mirror push were not
exactly that kind of sharing.

**Impact:** a reader could reasonably over-trust the redaction pass's coverage for what reaches the
external mirror.

**Direction:** addressed by R-01.
