# Recommendations

Ordered by severity first (High before Medium before Low), then by effort within a severity band
(quick wins before long campaigns at equal severity). Every finding carried forward from the
2026-09-28 review is reconfirmed here with refreshed evidence and renumbered for this review;
recommendations covering a finding new to this round are marked `(new)` in `02-findings.md`. The
**Tracked as** line names the GitHub issue(s) that carry the work forward — an existing issue
where one already covers the gap, or a freshly filed one where this review found none.

| ID | Recommendation | Severity | Effort | Addresses | Tracked as |
|---|---|---|---|---|---|
| R-01 | Close the Vercel-secret redaction coverage gap | High | Small | F-SEC-09, F-DATA-03, F-TEST-04 | agent-ops#1752, #1757 (existing) |
| R-02 | Wire `toc` and `spec` into the required-status-check ruleset | Medium | Small | F-CI-08, F-DOC-06 | agent-ops#2117, #2563/#2578 (existing) |
| R-03 | Fix the spec-split rename-during-split regression; add a mechanical guard | Medium | Small | F-DOC-05 | agent-ops#2694 (new) |
| R-04 | Re-file the dropped coverage-tooling tech debt | Medium | Small | F-TEST-02 | agent-ops#2695 (new) |
| R-05 | Paginate `publish-dashboard.sh`'s open-issues fetch | Medium | Small | F-CI-02 | agent-ops#1171 (existing) |
| R-06 | Add a container-image vulnerability scan to `build-image.yml` | Medium | Small | F-CI-09 | agent-ops#2696 (new) |
| R-07 | Fix `publish-dashboard.sh`'s `--help` swallowing; add `--help` to `monitor-cycle.sh` | Medium | Small | F-UX-02, F-UX-03, F-GOV-02 (remainder) | agent-ops#1753 (existing) |
| R-08 | Owner check-in on backlog growth / fit-ladder trajectory | Medium | Small | F-GOV-04 | STANDING-DECISIONS 2026-10-16, #2416/#2417/#2422 (existing) |
| R-09 | Add a Dependabot `docker` ecosystem entry for the base image | Medium | Small | F-DEPS-05 | agent-ops#2697 (new) |
| R-10 | SHA-pin every Actions `uses:` step | Medium | Medium | F-TOOL-02, F-CI-03 (remainder) | agent-ops#1918 (existing) |
| R-11 | Bound the rest of `do_push`; add a bounded DNS-failure retry | Medium | Medium | F-OPS-02, F-OPS-05 | agent-ops#1701, #1604 (existing) |
| R-12 | Diagnose and unstick the CHANGELOG roll automation | Medium | Medium | F-CI-07 | agent-ops#1846, #1848 (existing) |
| R-13 | Grant the Reviewer stage CI-log read/rerun access | Medium | Medium | F-CI-04 | agent-ops#1496 (existing) |
| R-14 | Action #2434's dashboard local-tick fix | Medium | Medium | F-PERF-04 | agent-ops#2434 (existing) |
| R-15 | Decompose `run_standdown_checks`; retire stale issue `#1256` | Medium | Large | F-CODE-01, F-ARCH-01 (partial) | agent-ops#2699 (new) |
| R-16 | Harden `san()` against a bare `..` path segment | Low | Small | F-SEC-04 | agent-ops#1172 (existing) |
| R-17 | Clean up fixture identity hygiene | Low | Small | F-DATA-02 | agent-ops#1174 (existing) |
| R-18 | Add `.editorconfig` | Low | Small | F-TOOL-01 | agent-ops#1758 (existing) |
| R-19 | Deduplicate `cfg()` | Low | Small | F-CODE-05 | agent-ops#1755 (existing) |
| R-20 | Land the ready `publish-dashboard.sh` flaky-test fix | Low | Small | F-TEST-05 (remainder) | agent-ops#1205 (existing) |
| R-21 | Add a memory/cgroup pager invariant | Low | Small | F-OPS-04 | agent-ops#2698 (new) |
| R-22 | Close stale issue `#2326` | Low | Small | F-DOC-07 | agent-ops#2326 (existing — flag for maintainer) |
| R-23 | Extract a shared paginated-fetch helper | Low | Medium | F-CODE-06, F-CODE-03 (partial) | agent-ops#1919 (existing) |

Not covered by a numbered recommendation this round (Low severity or informational, no new action
needed per the finding's own direction): F-ARCH-01's broader tracker beyond R-15's scope (already
covered by `#1756`/`#1253`–`#1255`/`#1996`), F-ARCH-05 (informational, folded into R-15's framing),
F-TOOL-03 (this review's own sandbox limitation, not a repo defect), F-OPS-03 (low urgency for a
single-maintainer audience, unchanged from baseline's own judgement), F-TEST-07 (watch-only pending
an observed flake), F-TEST-06 and F-DOC-07's own closure (flagging a stale issue for the maintainer
to close is not something this review's mandate extends to beyond naming it).

## R-01 — Close the Vercel-secret redaction coverage gap

**Severity:** High · **Effort:** Small · **Addresses:** F-SEC-09, F-DATA-03, F-TEST-04

**Current state:** `agent-ops#1752` (filed 2026-09-21, scoped, one comment, no PR, 36 days stale
as of this review) asks that `redact_add_literal` be called for `VERCEL_TOKEN` and
`VERCEL_AUTOMATION_BYPASS_SECRET` at their one call site, `scripts/preview-deploy.sh`. Both values
are still used directly in HTTP headers there with no redaction registration anywhere in the
repository. This is the direct sibling of the now-resolved F-SEC-05 incident (a live Vercel token
and GitHub App key paths printed into a transcript, rotated 2026-10-01) — the mechanism that
caused that incident is still unpatched for this one credential class. `docs/DATA-HANDLING.md`'s
"Redaction for screenshots" paragraph still implies broader coverage than the mirror-push pass
actually has (F-DATA-03), and `lib/redact.sh`'s own test suite doesn't exercise the shape rules or
`redact_add_literal`'s newline no-op that this fix would touch (F-TEST-04, `agent-ops#1757`).

**Intended end state:** `redact_add_literal` is called for both `VERCEL_TOKEN` and
`VERCEL_AUTOMATION_BYPASS_SECRET` at their `scripts/preview-deploy.sh` call site, the same pattern
already used for `notify_webhook_url`; `lib/redact.sh`'s shape-based rules and `redact_add_literal`'s
newline-handling gain test coverage (`#1757`); `docs/DATA-HANDLING.md`'s screenshot-redaction
paragraph is corrected to distinguish the mirror-push pass's actual (narrower) scope from the
screenshot pass's.

**Approach:** register the two literals via `redact_add_literal` at the point they're read into
shell variables in `scripts/preview-deploy.sh`; add test cases to `test/redact.test.sh` covering
the shape rules and the newline no-op before landing the fix, so the fix has a regression guard
from day one; correct the one paragraph in `docs/DATA-HANDLING.md`.

## R-02 — Wire `toc` and `spec` into the required-status-check ruleset

**Severity:** Medium · **Effort:** Small · **Addresses:** F-CI-08, F-DOC-06

**Current state:** `toc` (`#2117`) and `spec` (`#2563`/`#2578`) both run on every PR but are absent
from branch ruleset `18857310`'s required-status-checks list — the third and fourth recurrence of
a pattern already fixed twice this review series (`config-table`, `changelog-section`). `#2578`'s
own precondition is already satisfied; it is a fully-specified, one-click ruleset edit that has sat
open 7 days.

**Intended end state:** both `toc` and `spec` appear in the ruleset's required-status-checks list,
so a PR with a stale table of contents or a dangling/colliding requirement-label citation cannot
merge.

**Approach:** a repository-settings ruleset edit (Settings → Rules → the `main` ruleset → add
`toc` and `spec` to required status checks).

### Default: add both checks to the ruleset exactly as `#2578` specifies

**Owner decision: yes** — editing branch-protection ruleset settings is an account/settings
change under the owner-only boundary (requirement 36a); no pipeline identity holds the
permission to make this edit itself.

## R-03 — Fix the spec-split rename-during-split regression; add a mechanical guard

**Severity:** Medium · **Effort:** Small · **Addresses:** F-DOC-05

**Current state:** commit `9235549` renamed two pre-existing spec files during a split, eight days
after the convention banning exactly that was adopted (`#2472`/PR #2478). No automated check
catches a rename-during-split. Tracked: `agent-ops#2694` (new).

**Intended end state:** the renamed files are restored to their original names with their original
content, with the inserted new content instead occupying the next unused numbers (following the
convention correctly, the way PR #2679 did the very next time); a mechanical check (in
`scripts/check-docs.sh` or equivalent) fails a documentation-only spec-split commit that removes a
pre-existing path from a spec directory.

**Approach:** revert the two renames (restore `the-script-10.md`/`the-script-11.md`'s original
content and names, move the content that landed there to new, unused numbers instead); add a
check comparing the spec directory's file list before/after a split commit, failing if any
pre-existing path disappears while new content with similar heading structure appears elsewhere.

## R-04 — Re-file the dropped coverage-tooling tech debt

**Severity:** Medium · **Effort:** Small · **Addresses:** F-TEST-02

**Current state:** no coverage-measurement tooling exists; the explicit hand-off to file this as
its own item (written into `#1148`'s closing PR) was dropped when `#1148` closed. Tracked:
`agent-ops#2695` (new).

**Intended end state:** a tracked decision on whether to adopt `kcov`/`bashcov`/equivalent for
`scripts/run-tests.sh`, and if so, a `--coverage` flag and an initial (even generous) floor.

**Approach:** evaluate `kcov` against the bash test harness; if viable, add `--coverage` and a
ratcheted floor matching this repo's existing `scripts/docs-size-ratchet.tsv`-style pattern.

## R-05 — Paginate `publish-dashboard.sh`'s open-issues fetch

**Severity:** Medium · **Effort:** Small · **Addresses:** F-CI-02

**Current state:** `scripts/publish-dashboard.sh:3365` fetches at most 30 open issues for the
dashboard's Priority display with no `--paginate`. Now directly relevant: F-GOV-04 establishes the
real open-issue count is 581, not ~30. Tracked: `agent-ops#1171` (existing, 52 days stale).

**Intended end state:** the Priority display reflects the true open-issue set, or an explicit,
documented cap with a visible "N of M" indicator if a full fetch is judged too expensive for a
per-tick read.

**Approach:** add `--paginate` to the existing `gh_call api` invocation, following the same idiom
already used elsewhere in the codebase (candidate for R-23's shared helper once that lands).

## R-06 — Add a container-image vulnerability scan to `build-image.yml`

**Severity:** Medium · **Effort:** Small · **Addresses:** F-CI-09

**Current state:** no Trivy/Grype/`docker scout` step exists anywhere in CI; the published image
and source repo are both public. Tracked: `agent-ops#2696` (new).

**Intended end state:** `build-image.yml` runs a vulnerability scan against the built image on
every build, with its findings visible in the PR/Actions UI.

**Approach:** add a Trivy (or equivalent) scan step to the existing build job.

### Default: add the scan as non-blocking (report-only) first

Add the scan as a report-only step initially, promoting it to a required check once its
false-positive rate is proven acceptable — avoids an unreviewed flood of pre-existing base-image
CVEs blocking merges on day one.

## R-07 — Fix `publish-dashboard.sh`'s `--help` swallowing; add `--help` to `monitor-cycle.sh`

**Severity:** Medium · **Effort:** Small · **Addresses:** F-UX-02, F-UX-03, F-GOV-02 (remainder)

**Current state:** `scripts/publish-dashboard.sh`'s flag loop ends in a bare `*) shift ;;`
catch-all, so `--help` is silently swallowed and a full publish runs instead; `monitor-cycle.sh`
has no `-h`/`--help` case at all. Both fully scoped in `agent-ops#1753`, open and unassigned 36
days — the same issue F-GOV-02 names as a concrete instance of the larger stale-backlog pattern
F-GOV-04 documents.

**Intended end state:** `./scripts/publish-dashboard.sh --help` prints usage and exits 0 without
publishing; `./monitor-cycle.sh --help` prints usage and exits 0.

**Approach:** add an explicit `-h|--help)` case to each script's flag-parsing loop, matching the
usage-text pattern already used by `agent-cycle.sh`/`review-cycle.sh`/`doctor.sh`.

## R-08 — Owner check-in on backlog growth / fit-ladder trajectory

**Severity:** Medium · **Effort:** Small · **Addresses:** F-GOV-04

**Current state:** the repository's real open-issue backlog is 581 (not the ~30 every prior review
characterized it as — a `gh issue list` default-page artifact, now corrected). Tech debt is being
filed roughly 3:1 against closure over the three weeks measured. The owner has already made a
considered, dated decision (`STANDING-DECISIONS.md`, 2026-10-16) not to manage this by volume, and
architectural mitigation (the fit-ladder tuning tracked by `#2416`/`#2417`/`#2422`) is already in
flight.

**Intended end state:** no code change is prescribed by this recommendation. The end state is
simply that the owner has current, accurate numbers (not a stale ~30-issue impression) to judge
whether the 3:1 trajectory remains acceptable as the fit-ladder work lands.

**Approach:** no implementation approach — this is a visibility recommendation, not a fix.

### Default: no action beyond this review's own numbers; re-check the trend at the next review

**Owner decision: yes** — whether the current backlog-growth trajectory is acceptable is a
product/roadmap judgement call reserved for the owner (requirement 36a), not something a pipeline
stage decides.

## R-09 — Add a Dependabot `docker` ecosystem entry for the base image

**Severity:** Medium · **Effort:** Small · **Addresses:** F-DEPS-05

**Current state:** `.github/dependabot.yml` covers `github-actions` and `docker-compose` but not
`docker`, so `deploy/docker/Dockerfile`'s `FROM ubuntu:24.04` gets no automated update signal.
Tracked: `agent-ops#2697` (new).

**Intended end state:** Dependabot opens a PR when a newer `ubuntu:24.04` (or later LTS) base image
is available, the same way it already does for Actions and Compose images.

**Approach:** add a `package-ecosystem: "docker"` entry (directory `/deploy/docker`) to
`.github/dependabot.yml`.

### Default: add the `docker` ecosystem entry for the base image only

Leave the four hand-pinned toolchain `ARG`s (`SUPERCRONIC_VERSION`, `SHELLCHECK_VERSION`,
`CLAUDE_CODE_VERSION`, `GROK_BUILD_VERSION`) as accepted manual-review debt — no off-the-shelf
Dependabot ecosystem can parse a plain Dockerfile `ARG` consumed by a `curl`/`npm install -g`
step, and building bespoke tooling for four values is disproportionate to the gap.

## R-10 — SHA-pin every Actions `uses:` step

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-TOOL-02, F-CI-03 (remainder)

**Current state:** every `uses:` line across all 17 workflow files references a mutable version
tag; none are SHA-pinned. Dependabot (added this window) already covers the *update* mechanism for
Actions — this recommendation covers the separate *pinning* half. Tracked: `agent-ops#1918`
(existing, 29 days stale).

**Intended end state:** every `uses:` line is pinned to a commit SHA, with Dependabot configured to
keep SHA pins current (Dependabot supports this natively for the `github-actions` ecosystem).

**Approach:** replace each `uses: owner/action@vN` with `uses: owner/action@<sha> # vN`, across
all 17 workflow files; confirm Dependabot's existing config picks up SHA-pinned actions correctly
(it does, by default, once pinned).

## R-11 — Bound the rest of `do_push`; add a bounded DNS-failure retry

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-OPS-02, F-OPS-05

**Current state:** `scripts/state-sync.sh`'s `do_push()` wraps only its `redact_mirror_files` step
in a deadline; the `git fetch`, both `rsync` passes, and the final mirror push remain unbounded
after the mirror lock is taken — the same failure class that produced the baseline's cited 7-hour
wedge incident. A related, separately-tracked issue (`#1604`) describes a push silently ending with
no retry on a transient DNS/proxy error. Tracked: `agent-ops#1701`, `#1604` (existing).

**Intended end state:** every step inside `do_push()` after the mirror lock runs under its own
deadline, the same `mirror_run_with_deadline` wrapper already used for `redact_mirror_files`; a
transient DNS/proxy failure triggers a bounded retry rather than a silent, permanent stall.

**Approach:** wrap the `git fetch`, both `rsync` calls, and the final `mirror_write push` in
`mirror_run_with_deadline`, budgeting each against the remaining time in `push_deadline_seconds`;
add a bounded retry (2–3 attempts, short backoff) around the fetch/push network calls specifically,
since these two issues should be fixed together — a retry layered on an already-unbounded call
would need its own deadline regardless.

## R-12 — Diagnose and unstick the CHANGELOG roll automation

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-CI-07

**Current state:** the scheduled roll (PR #1842, merged 2026-09-25) has produced zero output in 32
days; no PR has ever opened from a `changelog-roll` branch, despite four follow-on fixes to its
marker mechanism and two still-open bugs in its own logic (`#1846`, `#1848`).

**Intended end state:** the roll either produces its first PR, or the specific reason it never
fires is identified and fixed (not just the two known sub-bugs independently — something is
preventing the mechanism from running end-to-end at all).

**Approach:** trace one full scheduled run of the roll workflow from trigger to its decision not to
open a PR (or its failure to run at all) — read the workflow's own run history on `main`,
not just the two bug reports — before applying `#1846`/`#1848`'s fixes in isolation.

### Default: trace the end-to-end run history first, then land `#1846`/`#1848`

Fixing the two known sub-bugs without first confirming the roll actually *runs* risks declaring
victory on symptoms while the root cause (zero observed runs) remains unexplained.

## R-13 — Grant the Reviewer stage CI-log read/rerun access

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-CI-04

**Current state:** `prompts/implementer.md` has a documented route to read a failing CI log
(`gh run view --log`); `prompts/reviewer.md` has no equivalent, so the Reviewer stage cannot
diagnose a red CI run on the PR it is reviewing. Tracked: `agent-ops#1496` (existing, 43 days
stale).

**Intended end state:** the Reviewer stage's prompt documents the same `gh run view --log`
extraction route (or an equivalent), and, where its credentials allow, can re-run a failed job.

**Approach:** mirror `prompts/implementer.md`'s existing CI-log route into `prompts/reviewer.md`;
confirm the Reviewer's GitHub identity already has the permissions needed (likely yes, since it
already reads PR state) before assuming new credentials are required.

## R-14 — Action `#2434`'s dashboard local-tick fix

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-PERF-04

**Current state:** the dashboard publisher's local (non-GitHub) tick still runs ~8 full `jq`
passes over the fleet-log union every tick, proportional to total log history (124 MB+ and
growing). Already fully scoped on `agent-ops#2434` with three candidate approaches documented in
the issue itself — deliberately deferred out of the #2429 series rather than left unscoped.

**Intended end state:** the local tick's cost stops growing linearly with the installation's total
log history.

**Approach:** execute one of `#2434`'s three already-documented candidates (recency-suffix reads
with whole-union fallback, bounding the per-cycle summary to consumed cycles, or an incremental
parse cache) — this recommendation does not re-scope the fix, since `#2434` already did that work
correctly; it flags that execution, not further scoping, is what's outstanding.

## R-15 — Decompose `run_standdown_checks`; retire stale issue `#1256`

**Severity:** Medium · **Effort:** Large · **Addresses:** F-CODE-01, F-ARCH-01 (partial)

**Current state:** `run_standdown_checks` (`lib/standdown.sh`) is now ~1,340 lines, +33% this
window — the largest single-function growth recorded in this review series and now the
repository's single largest undecomposed function. A month-old meta-tracker (`#1756`) explicitly
recommended filing a dedicated issue for it; none existed until this review. A sibling issue
(`#1256`) names a function that no longer exists in the tree. Tracked: `agent-ops#2699` (new).

**Intended end state:** `run_standdown_checks` is decomposed into named sub-steps, following the
model `maybe_run_refiner`'s own decomposition (`#964`, PR #1258) already set; `#1256` is closed as
superseded.

**Approach:** split `run_standdown_checks` into a family of smaller, named helper functions (the
same pattern #964's 11-helper split used), each independently testable; close `#1256` referencing
PR #1560 as the supersession.

## R-16 — Harden `san()` against a bare `..` path segment

**Severity:** Low · **Effort:** Small · **Addresses:** F-SEC-04

**Current state:** `lib/claim-key.sh:17`'s `san()` has no explicit rejection of a bare `..`; every
current caller happens to make this unexploitable by appending a suffix. Tracked: `agent-ops#1172`
(existing).

**Intended end state:** `san()` explicitly rejects a bare `.`/`..` result regardless of caller
behaviour, so a future caller cannot silently inherit the gap.

**Approach:** add an explicit check in `san()` itself rather than relying on every caller's
incidental suffix-appending to stay safe.

## R-17 — Clean up fixture identity hygiene

**Severity:** Low · **Effort:** Small · **Addresses:** F-DATA-02

**Current state:** 32 test fixtures still reference the maintainer's real GitHub usernames
(down from 35 at baseline). Tracked: `agent-ops#1174` (existing).

**Intended end state:** fixtures use placeholder identities instead of the maintainer's real
handles.

**Approach:** replace the real usernames with placeholder values (e.g. `test-user`,
`example-maintainer`) across the 32 affected fixture files.

## R-18 — Add `.editorconfig`

**Severity:** Low · **Effort:** Small · **Addresses:** F-TOOL-01

**Current state:** no `.editorconfig` exists. Tracked: `agent-ops#1758` (existing).

**Intended end state:** a committed `.editorconfig` matching the project's actual formatting
conventions (indentation, line endings, final newline).

**Approach:** add a standard `.editorconfig` covering `.sh`, `.md`, `.json`, `.yml`.

## R-19 — Deduplicate `cfg()`

**Severity:** Low · **Effort:** Small · **Addresses:** F-CODE-05

**Current state:** `lib/claim.sh` and `scripts/sweep-orphan-branches.sh` each define a local `cfg()`
that diverges from the shared `lib/config-access.sh` version. Tracked: `agent-ops#1755` (existing).

**Intended end state:** both files source the shared `cfg()` instead of redefining it.

**Approach:** remove the two local definitions; `source lib/config-access.sh` (or the relevant
subset) in both files instead.

## R-20 — Land the ready `publish-dashboard.sh` flaky-test fix

**Severity:** Low · **Effort:** Small · **Addresses:** F-TEST-05 (remainder)

**Current state:** `test/publish-dashboard.test.sh:1545`'s `run_window 20` is the known flaky
assertion; its sibling in `state-sync.test.sh` was already fixed the same way (`<= 1` instead of
exact `0`). Tracked: `agent-ops#1205` (existing, 51 days stale).

**Intended end state:** the assertion tolerates the same timing slack its sibling fix already
established as acceptable.

**Approach:** apply the identical one-line pattern `#1722`'s fix used.

## R-21 — Add a memory/cgroup pager invariant

**Severity:** Low · **Effort:** Small · **Addresses:** F-OPS-04

**Current state:** `lib/pager-invariants.sh` has no entry for an `unbounded`/`livelocked`
memory-cgroup verdict; the one real instance of this problem was resolved only after roughly nine
days of repeated autonomous re-discovery. Tracked: `agent-ops#2698` (new).

**Intended end state:** an `unbounded`/`livelocked` memory-cgroup reading pages a human directly,
the same way other host-health verdicts already do.

**Approach:** add a `memory`/`cgroup` entry to `lib/pager-invariants.sh` following the existing
pattern for other host-health pager invariants.

## R-22 — Close stale issue `#2326`

**Severity:** Low · **Effort:** Small · **Addresses:** F-DOC-07

**Current state:** `#2326` describes a documentation size-budget violation that a later,
unrelated split (`#2665`) incidentally fixed two weeks after `#2326` was filed. Tracked:
`agent-ops#2326` (existing).

**Intended end state:** `#2326` is closed with a note that `the-script-09`'s split already
resolved it.

**Approach:** this review flags it for the maintainer; closing an issue is outside this review's
own mandate (filing new debt and updating registers) to action directly.

## R-23 — Extract a shared paginated-fetch helper

**Severity:** Low · **Effort:** Medium · **Addresses:** F-CODE-06, F-CODE-03 (partial)

**Current state:** the `gh api ... --paginate` idiom is independently re-implemented across at
least seven call sites; `lib/github-limit.sh` (the proposed shared home) has no
`gh_paginated_fetch` function yet. Tracked: `agent-ops#1919` (existing).

**Intended end state:** a single `gh_paginated_fetch` helper in `lib/github-limit.sh`, with the
seven-plus existing call sites migrated to use it — also shrinking `scripts/publish-dashboard.sh`'s
line count somewhat (F-CODE-03).

**Approach:** write `gh_paginated_fetch(endpoint, jq_filter)` in `lib/github-limit.sh` matching the
existing idiom's behaviour exactly; migrate call sites one at a time, each with its own test
coverage confirming identical output before and after.
