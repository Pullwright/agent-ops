# Findings

This review re-verified every finding from the 2026-09-05 review with fresh evidence against the
current tree, then hunted for new findings in the 180 commits landed since that review's pinned
revision (`916a951` → `5284c02`) and from deeper/different sampling. Findings carried forward are
marked accordingly; new findings are marked `(new)`.

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 1 |
| Medium | 15 |
| Low | 21 |

9 further findings from the 2026-09-05 review are confirmed **Resolved** this round and are listed
in their dimension section without contributing to the tally above.

## Architecture and design (ARCH)

**Strengths:** the `lib/` split's decomposition discipline is still actively applied, not just
inherited — several commits this window extracted shared helpers to stop duplication rather than
tolerating it, and `b31e122` (#1560) replaced a 329-line orchestration function with two much
smaller, single-purpose ones as part of a genuine architectural improvement (per-repository
Co-Ordinator engagement instead of one fleet-wide engagement). New subsystems added since the
baseline (`monitor-cycle.sh`, `lib/compose-reconcile.sh`, `scripts/node-health-server.py`) each
arrived with a matching as-built spec section and dedicated tests.

### F-ARCH-01 — `agent-cycle.sh`'s undecomposed top-level flow has grown since the prior review, and the newly added `monitor-cycle.sh` entry point reproduces the identical anti-pattern · **Medium**

**Evidence:** `agent-cycle.sh` is now 4,025 lines (was 3,408); its undecomposed top-level regions
total ~2,357 lines (up from ~2,000), despite a dedicated tracked issue (agent-ops#1253, still
open). `monitor-cycle.sh` — a new entry point added this window (#1388) — was built with the same
shape: ~809 of its 1,310 lines (~62%) are flat top-level script, a worse ratio than
`agent-cycle.sh`'s own ~59%, even though `review-cycle.sh` (explicitly cited as the model to
follow when #964 was closed) keeps its equivalent span to ~280 lines.

**Impact:** the project's own tracked fix (#1253) is scoped only to `agent-cycle.sh`; nothing
tracks the same defect having been newly introduced in `monitor-cycle.sh`.

**Direction:** extend the decomposition effort to `monitor-cycle.sh`, using `review-cycle.sh` as
the template. Addressed by R-12.

### F-ARCH-02 — Small utility functions duplicated between `agent-cycle.sh` and `review-cycle.sh` · **Resolved**

**Evidence:** commit `756a405` (#1332, closing agent-ops#967) extracted `expand_home()`/`cfg()`/
`cfg_json()` into `lib/config-access.sh` and `log_event`'s shared envelope into
`lib/log-event.sh`, sourced identically by all three entry points including the newly added
`monitor-cycle.sh`. Issue #967 is closed.

## Code quality and maintainability (CODE)

**Strengths:** zero genuine `TODO`/`FIXME`/`HACK`/`XXX` markers remain anywhere in the sampled
surface. `shellcheck -x lib/*.sh scripts/*.sh` is clean (independently re-run by this review, see
Scope and method). Comment/header density and quality remain very high, routinely citing the
originating issue/requirement and explaining *why*, not just *what*. The two most recent commits
on `main` at review time are both small, well-scoped hardening fixes that choose to fail closed
(drop/empty a file rather than risk committing it unredacted) — the project's own discipline
holding in the newest code, not only in the reviewed baseline.

### F-CODE-01 — Stage-orchestration god functions: one of seven now fixed, two grew larger, two were never tracked · **Medium**

**Evidence:** of the seven oversized functions the 2026-08-31/2026-09-05 reviews named,
`maybe_run_refiner` is fully resolved (PR #1258, an 11-helper split). `maybe_run_enabler` (857→978
lines) and `run_approver_stage` (419→442 lines) both grew since being filed as #1254/#1255
(still open). `coordinator_corroborate_retry_or_fallback` no longer exists — superseded by a
smaller pair of functions (#1560) — but its tracking issue (#1256) still names the dead function.
`run_standdown_checks` (936/957 lines) and `compute_skip_lists` (786/1,433 lines) were flagged by
the prior review's own sampling but never filed as issues.

**Impact:** the decomposition fix works when applied, but the four untouched, actively-worked
functions are net larger today in two of four cases, and two known instances were never made
trackable at all.

**Direction:** file the two missing issues and correct #1256; extend R-08's scope to keep pace
with growth. Addressed by R-12 (new tracking issue #1756 filed this run).

### F-CODE-02 — `san()` copy-pasted between `lib/claim.sh` and `scripts/sweep-orphan-branches.sh` · **Resolved**

**Evidence:** both now source the shared `lib/claim-key.sh:17` definition (PR #1332, closing
agent-ops#967).

### F-CODE-03 — `scripts/publish-dashboard.sh` and `scripts/doctor.sh` remain almost entirely top-level flow, and both have grown substantially · **Low**

**Evidence:** `publish-dashboard.sh` is now 4,087 lines (+26%, still only 16 functions);
`doctor.sh` is now 2,534 lines (+35%, still only 10 functions).

**Impact:** unchanged urgency (neither is the hourly hot path, both have dedicated test coverage)
but the growth rate now outpaces either file's function count.

**Direction:** no urgent action; addressed nominally by R-20 (watch, not act).

### F-CODE-04 — `dashboard/index.html`'s `renderBody()` remains the dominant, growing outlier function · **Low**

**Evidence:** now ~538 lines (was 462), ~3.5x the next-largest function (`landingsPanel()`, 153
lines). Tracked as agent-ops#1173, still open.

**Direction:** extract each banner group into its own named function, per #1173. Addressed by
R-20.

### F-CODE-05 — `cfg()` is still duplicated between `lib/claim.sh` and `scripts/sweep-orphan-branches.sh`, in the very PR that fixed their `san()` duplication · **Low** (new)

**Evidence:** both files define `cfg()` with a `2>/dev/null` suppression the shared
`lib/config-access.sh:20` version lacks — the pair has already begun to diverge from the
"canonical" shared version, the exact hazard duplication findings warn about.

**Direction:** source the shared `cfg()` from both files, or document the divergence. Addressed
by R-17 (new tracking issue #1755 filed this run).

## Security (SEC)

**Strengths:** redaction, credential-minting and cache-provenance code is written with unusually
explicit adversarial reasoning in its own comments (a `/dev/shm` symlink race guard, argv-exposure
avoidance for JWTs/installation tokens, an associative-array-subscript injection guard). No
`pull_request_target` usage anywhere; every workflow reading fork-controllable text does so via an
`env:` indirection, not inline interpolation. The project self-reports security-relevant incidents
as GitHub issues with clear "why this needs a human" framing rather than silently patching around
them.

### F-SEC-01 — Dashboard `esc()` helper's misleading name · **Resolved**

**Evidence:** `esc()` still doesn't escape (it's a `String()` coercion), but the two call sites
that previously paired it with `innerHTML` assignment are gone — a fresh grep finds zero such
pairings — and `esc()` now carries an explicit warning comment against that exact misuse. Issue
#965 closed.

### F-SEC-02 — No `SECURITY.md` · **Resolved**

**Evidence:** `SECURITY.md` now exists with a private-advisory disclosure route. Issue #973 closed.

### F-SEC-03 — CodeQL covers only Actions YAML · **Resolved (as a documented non-go)**

**Evidence:** issue #976 closed via PR #1466, "SAST spike is a no-go for now" — the recommendation
was executed and its conclusion recorded rather than silently dropped.

### F-SEC-04 — `lib/claim.sh`'s (now `lib/claim-key.sh`'s) `san()` has no explicit `.`/`..` rejection · **Low**

**Evidence:** relocated during dedup (#1332) but behaviourally unchanged; every current caller
happens to append a filename suffix after calling `san()`, so a bare `..` is not currently
exploitable — the safety property is an accident of callers, not a guarantee `san()` itself makes.
Issue #1172 (R-13 from the prior review) remains open.

**Direction:** addressed by R-15.

### F-SEC-05 — Live production secrets (Vercel token, GitHub App private-key paths) were printed into an agent session transcript on 2026-09-16, and the incident remains open and unresolved six days later · **High** (new)

**Evidence:** issue #1627, filed 2026-09-16, still open with zero comments. An Implementer stage
ran `docker compose config` against a real compose file inside a live node container; the rendered
output carried a live Vercel token and GitHub App private-key paths from the process environment
into that cycle's own transcript, caught only after the fact. Independently verified the
structural gap that makes this more than a one-off: `lib/redact.sh`'s shape-based rules
(`gh*_`/`github_pat_`/`sk-`/`Bearer …`) plus one runtime-registered literal (`notify_webhook_url`
only, as of the recent #1721/PR #1727 fix) do not cover a Vercel token or a key *path* — neither
has a matched shape and neither is registered. `state-sync.sh`'s `redact_mirror_files` applies
this same incomplete pass to cycle transcripts pushed to the state-mirror repository.

**Impact:** per the checklist's "weighing a dangerous defect in a trivial project" guidance, this
harm is not bounded by the project's own maturity — it is bounded by whatever the exposed
credentials grant on the real accounts behind them. Rated High rather than Critical because
containment held on the facts recorded (nothing reached `.env`/git, the Implementer caught and
remediated its own session), but six days unresolved with no rotation decision and no fix to the
underlying redaction-coverage gap leaves the exposure window and the general gap both live.

**Direction:** rotate/assess the exposed credentials; decide the sandboxing question the issue
raises; generalise `redact_add_literal`'s registration beyond the single webhook-URL call site.
Addressed by R-01 (existing #1627 plus new tracking issue #1752 filed this run for the redaction
generalisation specifically).

### F-SEC-06 — `redact_add_literal`'s PLACEHOLDER argument is unescaped for sed-replacement specials · **Low** (already tracked, unexploited)

**Evidence:** issue #1741, open. A future custom placeholder containing `&`/`\`/`#` would paste
the secret back or corrupt the rule set; both current call sites use the default placeholder, so
not exploitable at HEAD.

**Direction:** addressed by R-14.

### F-SEC-07 — `redact_add_literal` silently no-ops on a newline-bearing secret, with no operator-visible signal · **Low** (already tracked)

**Evidence:** issue #1730, open. Correct to refuse (a single `-e` sed rule cannot span an embedded
newline), but produces no warning distinguishing "nothing to redact" from "something was
skipped."

**Direction:** addressed by R-14.

## Testing and quality assurance (TEST)

**Strengths:** the suite continues to grow (176 → 223 files) and remains unusually disciplined —
most files are regression tests tied to a specific incident number, explaining the failure mode
they guard against before a single assertion runs. `candidate-select.sh` and the credential-minting
core are both thoroughly covered indirectly, through differently-named scenario test files rather
than one matching-basename file — a legitimate design a naive basename cross-reference would
misclassify as a gap. Real production bugs get same-day regression coverage in at least one of
their two symmetric call sites (see F-TEST-05). The suite's `sleep`-based timing (60 occurrences)
is overwhelmingly disciplined — bounded poll loops or deliberately explained waits, not arbitrary
padding.

### F-TEST-01 — `lib/git-identity.sh` has no test coverage anywhere in the suite · **Low**

**Evidence:** confirmed unchanged; `require_git_identity` is genuinely called by both
`agent-cycle.sh` and `review-cycle.sh` but has no matching assertions anywhere. Issue #1148, open.

**Direction:** addressed by R-17.

### F-TEST-02 — No coverage-measurement tooling exists · **Low**

**Evidence:** confirmed the naive basename cross-reference this finding warns about is indeed
misleading: of 5 apparently-untested `lib/*.sh` files sampled, 4 are covered under differently-
named scenario tests and only `lib/redact.sh` (F-TEST-06) is a genuine gap. Issue #1148, open.

### F-TEST-05 — `5284c02`'s own webhook-redaction fix added a regression test to one call site but not its sibling changed in the same commit · **Low** (new)

**Evidence:** `scripts/publish-dashboard.sh:291`'s new `redact_add_literal` call (added by
`5284c02` for the same reason as the `state-sync.sh` change in the same commit) got no matching
test; only `test/state-sync.test.sh` gained assertions.

**Impact:** a future refactor of `publish-dashboard.sh`'s redaction wiring has no test to catch a
regression that would leak a genuine bearer secret into the dashboard's published output.

**Direction:** addressed by R-18 (new tracking issue #1757 filed this run).

### F-TEST-06 — `lib/redact.sh`, the module solely responsible for keeping secrets out of mirrored/published state, has no dedicated test file · **Low** (new)

**Evidence:** exercised only as a side effect of `state-sync.sh`'s integration tests; its own
shape rules and `redact_add_literal`'s edge cases (already the subject of two open issues, #1730,
#1741) are never asserted in isolation.

**Direction:** addressed by R-18.

### F-TEST-07 — Two timing-dependent tests are self-documented as flaky, with open tracking issues, still unresolved · **Low**

**Evidence:** #1205 and #1722, both open. Empirically rare in practice — the last 50
`build-image.yml` CI runs show 0 failures.

**Impact:** compounds with F-CI-04 — see that finding.

### F-TEST-08 — A tracked pagination-gap issue (agent-ops#1036) appears already resolved by an unrelated-looking PR, but was never closed · **Low** (new, issue-hygiene observation)

**Evidence:** the digest #1036 describes as unpaginated is now fetched via `api_json_paged`
(PR #1165, closing a different tracked issue) and `lib/work-gone.sh` reads from that same,
now-paginated digest — the described defect looks structurally fixed, but #1036 remains open with
no cross-reference.

**Direction:** not a code fix; flagged for the maintainer to confirm and close.

## Dependencies and supply chain (DEPS)

**Strengths:** the dependency surface is genuinely minimal and justified for a Bash-only,
manifest-less project. `supercronic` and `shellcheck` remain pinned to an exact release and
checksum-verified at build time. `CLAUDE_CODE_VERSION` — previously floating — is now pinned
(#1355, landed this window), closing what would otherwise have been a gap on the pipeline's own
highest-reach dependency. The Dockerfile's comments are explicit about *why* the base image and
its apt packages are deliberately left floating (CI rebuilds on every merge) — documented,
deliberate risk acceptance, not oversight.

### F-DEPS-01 — No update mechanism (Dependabot/Renovate) for agent-ops's own dependencies · **Medium**

**Evidence:** no `.github/dependabot.yml`/Renovate config anywhere; every version literal in
`deploy/docker/Dockerfile` and every Actions `uses:` line remains hand-maintained. Issue #1145,
open.

**Direction:** addressed by R-06.

### F-DEPS-02 — Two Compose sidecar images still float on `:latest` with no pin · **Medium**

**Evidence:** `tailscale/tailscale:latest` and `containrrr/watchtower:latest` remain unpinned;
every other image reference in the same file is at least this repo's own CI-published image.

**Impact:** undermines the "every node runs the same file and image" guarantee the README's
install section states as the point of the container design.

**Direction:** addressed by R-06.

### F-DEPS-03 — `scripts/doctor.sh`'s Toolchain check still omits `openssl` · **Low**

**Evidence:** `lib/approver-token.sh` hard-depends on `openssl` for JWT signing and the Dockerfile
deliberately installs it for that reason, but `doctor.sh`'s toolchain loop doesn't check for it.
Issue #1147, open.

**Direction:** addressed by R-13.

## Tooling and developer experience (TOOL)

**Strengths:** the container onboarding path is accurate end to end — every file README's
installation section names exists exactly where cited, and a non-mutating `docker compose config`
parse resolves cleanly. `--help` coverage materially improved this window: issue #974 (closed via
PR #1447) added `-h|--help` to `review-cycle.sh`, `scripts/serve-dashboard.sh`, and
`scripts/open-dashboard.sh`, and corrected a stale record that `agent-cycle.sh` was missing one.
Individual script header comments remain unusually thorough as a partial substitute for a scripts
index.

### F-TOOL-01 — No `.editorconfig` and no `.shellcheckrc` · **Low**

**Evidence:** neither exists; explicitly deferred by #974's resolution with no follow-up filed
until this review.

**Direction:** addressed by R-19 (new tracking issue #1758 filed this run).

### F-TOOL-02 — No task-runner/Makefile; discoverability rests entirely on reading script headers · **Low**

**Evidence:** no `Makefile`, no scripts index, across 100 `lib/` and 67 `scripts/` files.

**Direction:** addressed by R-19.

### F-TOOL-03 — GitHub Actions still pinned to version tags, not commit SHAs · **Low**

**Evidence:** every `uses:` line across all 9 action-using workflow files references a mutable
tag, in contrast to the SHA/checksum verification this repo applies to `supercronic`/`shellcheck`
in the Dockerfile. `docker/login-action`/`docker/build-push-action` run with registry-push
credentials on every push to `main`.

**Direction:** addressed by R-06.

## CI/CD and release engineering (CI)

**Strengths:** `build-image.yml` is the most carefully reasoned workflow in the repository — every
non-obvious decision is explained inline with the incident that taught the lesson. A merge to
`main` genuinely deploys via the fleet's own `watchtower` sidecar polling the published image —
not a manual-deploy project. The branch ruleset gates merges through `code_scanning` and
`code_quality` ruleset rule types in addition to named status checks. `CHANGELOG.md` is hand-
maintained but a spot-check of the five most recent commits against their entries showed no drift.

### F-CI-01 — The config-table (and toc) check is still not an actual required merge gate · **Medium**

**Evidence:** `config-table.yml`/`toc.yml` still have no `merge_group:` trigger; the current
branch ruleset (fetched live via `gh api`) requires 8 named status-check contexts, neither of
these among them. Issue #1144 — the owner's own binding sequencing decision — remains open.

**Direction:** addressed by R-02.

### F-CI-02 — `publish-dashboard.sh`'s issues fetch is still single-page for the Priority display; a follow-up added only a total-count display, not pagination · **Medium**

**Evidence:** the fetch (`per_page=30`, no `--paginate`) is unchanged in shape; a mitigation added
since the prior review (#1171) shows a true open-issue count via a separate search call, but the
per-page detail (including Priority) is still capped at 30.

**Direction:** addressed by R-07.

### F-CI-03 — No update mechanism for agent-ops's own pinned dependencies; GitHub Actions still pinned to mutable tags · **Medium**

**Evidence:** same underlying gap as F-DEPS-01/F-TOOL-03; issue #1145, open.

**Direction:** addressed by R-06.

### F-CI-04 — The autonomous Reviewer stage cannot read a failing CI log or re-run a failed job, so every flake in this repository's own CI costs a full empty-commit re-run · **Medium** (new)

**Evidence:** issue #1496, open, documents both `gh run view --log` (blocked by the egress proxy)
and `gh run rerun --failed` (blocked, `actions: write` not granted) failing, citing a concrete
incident (PR #1494) where a plausible flake (F-TEST-07) could not even be diagnosed and cost a
full ~25-minute re-run via an empty commit.

**Impact:** compounds directly with F-TEST-07 — every timing-sensitive flake in the 223-file suite
is, for the autonomous Reviewer specifically, indistinguishable from a real regression.

**Direction:** addressed by R-09.

### F-CI-05 — CodeQL's security-scanning coverage remains limited to the `actions` language · **Low**

**Evidence:** unchanged; an accurate, self-aware limitation (no Shell/Perl CodeQL support exists),
already addressed by the existing R-18/agent-ops#976 resolution.

## Performance and scalability (PERF)

**Strengths:** the resource-measurement machinery is disproportionately mature for a batch
pipeline — cgroup v1/v2-aware, refuses to report a rate across a container recreation, derives
percentiles via nearest-rank so every figure traces to a real sample. A 2026-08-25 fix that
replaced eight slurp-based `jq` union-log readers with a ~1000x-faster streaming form is real and
still in force at every call site checked. The new disk-pressure prune (#1696, landed this window)
is a well-reasoned, tested backstop.

### F-PERF-01 — `log.jsonl`'s unbounded growth has now measurably caused, not merely risked, the fleet's own memory-livelock incidents, and the fix proven for one reader class has not been extended to the rest · **Medium** (upgraded from the prior review's "no action needed")

**Evidence:** the prior review rated this Low with no recommended action. Since then: issue #1649
measures `publish-dashboard.sh`'s own `jq -sc` slurp reads as a direct linear function of the
never-rotated `log.jsonl` (429 MB peak after an unrelated bash-side fix removed a larger, now-
fixed component); and that growth is the documented cause of two real production incidents this
window (#1620, its lineage #1305, and #1643) — a `memory.high` livelock class that stalls a node
silently for tens of minutes to hours. The proven fast-parse fix (#982, applied 2026-08-25 to
`lib/crash-loop.sh` et al.) was never extended to `publish-dashboard.sh`'s own remaining slurp
calls; a draft PR meant to correct a stale cross-reference (#1492) has sat unmerged 9+ days.

**Impact:** a fleet-wide component the whole team depends on to see the pipeline's health has a
memory footprint that grows with a log that never shrinks; any cgroup ceiling picked for it today
"is a ceiling that expires" (#1649's own words).

**Direction:** addressed by R-10.

### F-PERF-02 — The disk-pressure prune added this window is itself evidence the fleet is growing derived-file volume faster than any prior estimate assumed, and the same estimate-not-measurement pattern hasn't been checked elsewhere · **Low**

**Evidence:** #1678's incident replaced a "low hundreds of megabytes" estimate with a measured
~7.3–7.4 GB/node, regrowing at ~4.3 GB/node/day — two orders of magnitude off. `min_free_
workspace_bytes`'s own derivation (#904) is still open and not yet re-derived from measurement.

**Direction:** no urgent action; measure rather than estimate when #904 is next touched.

## Usability and accessibility (UX)

**Scope note:** the only human-facing UI is `dashboard/index.html`; everything else is CLI/config
surface. No automated accessibility checker (axe/Lighthouse) was available in this environment —
assessed by static markup/JS reading only; colour contrast was not assessed.

**Strengths:** the prior review's headline UX gap is now genuinely fixed. Commit `db9aaba` (#1391,
closing #970) added a shared `makeActivatable()` helper giving keyboard operability (`tabindex`,
`role`, `aria-label`, Enter/Space handling, `:focus-visible` styling) to all three previously
click-only dashboard widgets, documented in the spec and covered by new test assertions in the
same commit. CLI error-message quality is a genuine strength across the sample — failures
routinely name both the condition and what to run next, not a bare exit.

### F-UX-01 — Dashboard's clickable rows/cards are now keyboard-operable · **Resolved**

**Evidence:** `makeActivatable()` applied to all three previously click-only widgets; spec and
test coverage landed in the same commit (`db9aaba`, closing #970).

### F-UX-02 — `scripts/publish-dashboard.sh` silently discards any unrecognised flag, including `-h`/`--help` · **Medium** (new)

**Evidence:** the flag loop's catch-all is a bare `*) shift ;;` — no error, no exit code, no usage
text; a full (possibly minutes-long) dashboard rebuild runs regardless. Every sibling script
(`monitor-cycle.sh`, `scripts/check-node-compose.sh`) errors loudly on an unknown argument
instead. Issue #974's `--help` sweep explicitly scoped this file out; the silent-swallow behaviour
itself was never raised.

**Impact:** a typo'd real flag silently runs the expensive default path instead of erroring — the
kind of silent-drift failure mode this codebase is otherwise disciplined about avoiding.

**Direction:** addressed by R-03 (new tracking issue #1753 filed this run).

### F-UX-03 — `monitor-cycle.sh`, the newest of the three pipeline entry points, has no `-h`/`--help` — its two siblings both do now · **Low** (new)

**Evidence:** falls into the script's own loud unknown-argument error (unlike F-UX-02) but gives
no usage text; added after #974's `--help` sweep had already run across the other entry points.

**Direction:** addressed by R-03.

## Documentation (DOC)

**Strengths:** the as-built-spec discipline holds up under fresh sampling — every claim checked
against `monitor-cycle.sh`/`review-cycle.sh`/`config.schema.json` directly matched code exactly.
Generated-region discipline is real, not just documented: both `render-toc.sh --check` and
`render-config-table.sh --check` pass clean against the current tree. The container onboarding
path README documents is accurate end to end.

### F-DOC-01 — `docs/REVIEW-PIPELINE-SPEC.md`'s vendored-skill provenance stamp remains stale, and the staleness window has grown again · **Medium**

**Evidence:** still names the skill's state as of 2026-07-19 despite two real content edits since
(2026-08-01, 2026-08-28); no drift-check exists anywhere in CI. Now roughly 9 weeks stale, up from
~2 weeks at the 2026-08-31 review and ~5 weeks at 2026-09-05. Issue #1146, open, unfixed across
three consecutive reviews.

**Direction:** addressed by R-04.

### F-DOC-02 — The implementation-pipeline spec's navigation gap · **Resolved**

**Evidence:** a generated table of contents was added (#1399, hardened by #1411);
`render-toc.sh --check` passes. The spec grew to 29,228 lines and 115 headings in this window; the
generated-ToC remedy the prior recommendation offered was genuinely delivered.

### F-DOC-03 — Both pipeline specs' "target repositories" claims are out of date: agent-ops has been reviewing and implementing changes on itself the whole time, and neither spec's own repo table says so · **Medium** (new)

**Evidence:** both specs' target-repository sections list exactly two repos and state their own
tables are the "one place a config change needs an editorial update to stay accurate," but
`config.json`'s `.repos[]` and `.project_review.repos[]` have had three entries since at least the
prior review's own pinned baseline — the third being `Pullwright/agent-ops` itself, with its own
distinct autonomy/budget/source configuration. `AGENTS.md` describes this correctly; the drift is
specific to the two as-built specs.

**Impact:** this is the review currently running against agent-ops's own configured entry, which
neither spec documents anywhere.

**Direction:** addressed by R-05 (new tracking issue #1754 filed this run).

## Governance and project health (GOV)

**Strengths:** the biggest prior gap for this dimension — no `SECURITY.md`, `CONTRIBUTING.md`, or
issue/PR templates — is now fully closed, landed together in one coherent commit (`a48ed71`,
closing #1439) that also resolved the licence-transparency gap (a provisional-licence notice for
the planned FSL-1.1-ALv2 move). Bus factor remains exactly as `AGENTS.md` discloses it (single
maintainer, self-review by design via a second identity or the Pullwright Approver App, no
succession plan) — a known, disclosed risk, not a fresh finding. Issue/PR hygiene is healthy
despite the raw volume: of 312 open issues, the least-recently-touched was last updated ~3 weeks
ago and the oldest-created is only ~25 days old — no multi-month stale-issue backlog despite 246 of
312 carrying `pw::type:tech-debt`; all 7 open PRs were opened within the last week, 6 of 7
`MERGEABLE`.

### F-GOV-01 — `SECURITY.md`, `CONTRIBUTING.md`, issue/PR templates, and a licence-transition notice are now present and coherent · **Resolved**

**Evidence:** all four landed together in commit `a48ed71` (closing #1439); each read in full and
found coherent with `AGENTS.md`'s own stated obligations.

## Observability and operations (OPS)

**Strengths:** this window shows real incident-driven engineering, not detection theatre.
`lib/mirror-lock.sh` (new, 191 lines) is a careful root-cause fix for a genuine 7-hour production
wedge (#1679): it correctly identifies that the lock file's own mtime cannot answer "how long has
the current holder run" and adds a separate, atomically-written holder marker to answer that.
`lib/memory.sh`'s cgroup-verdict state machine has been revised twice more since the prior review
to close gaps its own prior fix left open, each revision driven by a real incident number rather
than hypothetical hardening. The container-memory verdict now reaches the dashboard automatically,
hourly, and separately into the Monitor's own digest — a materially better outcome than the prior
review's R-15 asked for. `lib/log-event.sh`'s envelope logic type-checks payloads before merge and
carries only caller-supplied structured fields, never a credential.

### F-OPS-01 — The memory-cgroup "unbounded"/"livelocked" verdict now travels to the dashboard automatically, but visibility has not produced remediation: a real node ran OOM-killing production stages for 4+ days after discovery, because the fix requires host access the autonomous pipeline cannot grant itself, and nothing pages on it · **Medium** (new)

**Evidence:** `memory_cgroup_verdict` is read hourly by `doctor.sh` and published to the dashboard
and Monitor digest without a human running it by hand. Despite that, issue #1569 (open, filed
2026-09-15) records a live node with no parent memory ceiling and `oom_kill_count: 12`; three
separate autonomous-pipeline sessions investigated across 2026-09-15–2026-09-19 and each concluded
the fix needs host (`sudo`) access no container in this architecture has — the most recent comment
(2026-09-19, three days before this review) records no change. Separately, issue #1639 (open)
shows the setup script's own documented default configuration produces the exact `livelocked`
shape its sibling code warns about. No entry for `memory`/`cgroup` exists anywhere in
`lib/pager-invariants.sh` — this condition has no paging path.

**Impact:** detection quality has clearly outpaced remediation reach — the system knows exactly
what is wrong and says so hourly, but the one class of fix it needs sits entirely outside what any
container can do, and nothing escalates that gap the way a genuine pager invariant would.

**Direction:** addressed by R-11.

### F-OPS-02 — The mirror-lock wedge fix is explicitly a one-off, scoped to a single call site; the far more likely wedge source (`git fetch`/`git push` over the network) is still unbounded, and outbound `gh` API calls have no timeout anywhere · **Medium** (new)

**Evidence:** commit `073ba0c` (closing #1679) bounds only the redaction loop within
`state-sync.sh push` with a new deadline helper; its own message defers the rest ("a wedge
anywhere else in `do_push` ... still holds `mirror_lock` indefinitely," #1701, open), and #1604
(open) independently confirms the underlying network-hang failure mode is real for this transport.
By contrast, `run_claude_stage`, the Vercel preview probes, and the notify webhook POST are all
properly time-bounded — but a repo-wide grep of every `lib/`/`scripts/` file invoking `gh api`/
`gh pr`/`gh issue`/`gh repo`/`gh graphql` (64 files) found no `timeout`(1) wrapper anywhere,
including in the 1,208-line `gh` shim itself.

**Impact:** `gh` calls are the pipeline's primary means of reading and writing GitHub state across
nearly every stage; a DNS/proxy stall on one — the same failure class #1604 already reproduced for
git — would wedge a cycle with no backstop at all, a strictly worse position than the one
`mirror_lock` was just hardened against.

**Direction:** addressed by R-08.

### F-OPS-03 — No dedicated runbook exists; incident knowledge lives only in source-file headers, and the volume of such content keeps growing · **Low**

**Evidence:** `lib/memory.sh`'s and `lib/mirror-lock.sh`'s headers each now document multiple
chained incidents with measured figures and decision tables, reachable only by opening that one
file; no incident index cross-references them. Unchanged from the prior review's F-OPS-02/R-09.

**Direction:** low urgency for a single-maintainer audience who wrote every header; no new action
needed beyond what R-09 (prior review) already covers.

## Data handling and privacy (DATA)

**Strengths:** `docs/DATA-HANDLING.md` (new since the prior review) is a genuine, accurate
personal-data inventory — correctly scoped to already-public GitHub activity, naming concrete
retention levers with pointers to their canonical documentation, and including an onboarding
checklist for a future installation with different privacy requirements. The redaction pass
genuinely runs before both external-facing data surfaces checked (dashboard JSON, state-mirror
push), with an explicit code comment tying the ordering requirement to the incident that motivated
it.

### F-DATA-01 — No personal-data inventory doc · **Resolved**

**Evidence:** `docs/DATA-HANDLING.md` now exists and is substantive — what is read, what is stored
and where, the three retention config keys, an onboarding checklist. Issues #973/#975 closed.

### F-DATA-02 — Fixtures carry the maintainer's real GitHub usernames · **Low**

**Evidence:** now 33 test files plus 1 dashboard-data fixture use `warwick`/`warwickallen`/
`Warwick-Allen` as real fixture values, up from ~20 files at the prior review — accumulation from
180 commits of test-suite growth, not a regression. Issue #1174, open. Risk unchanged: self-
referential, already-public identity, very low practical exposure, but real personal data in a
growing number of committed fixtures.

**Direction:** addressed by R-18.

### F-DATA-03 — The pipeline's stated redaction guarantee for "operational data... safe to share for debugging" has a demonstrated gap for non-token-shaped runtime secrets, and the data-handling doc doesn't flag the gap · **Medium** (new)

**Evidence:** `docs/DATA-HANDLING.md` states redaction lets operational data be "safely shared for
debugging without leaking credentials" — accurate for the dashboard's published JSON, but the same
machinery applied to cycle transcripts pushed to the state-mirror repository was shown by the real
2026-09-16 incident (F-SEC-05/#1627) to miss non-token-shaped runtime secrets. The document makes
no mention of this limitation, and states data "is never uploaded or shared unless deliberately
pushed... by the operator" — which reads as though the state-mirror push (itself described
earlier in the same document as an automated destination) were not exactly that kind of sharing.

**Impact:** a reader relying on this document to judge what's safe to share would over-trust the
redaction pass's coverage.

**Direction:** addressed by R-01, alongside the underlying redaction-coverage fix.
