# Recommendations

Ordered by severity first (High before Medium before Low), then by effort within a severity
band (quick wins before long campaigns at equal severity). Every finding carried forward from
the 2026-10-27 review is reconfirmed here with refreshed evidence and renumbered for this
review; a recommendation covering a finding new to this round is marked `(new)` in
`02-findings.md`. Four of the prior round's 23 recommendations (R-06, R-09, R-15, R-21) are
fully executed and dropped from this round's active list — see `02-findings.md`'s RESOLVED
entries for F-CODE-01, F-DEPS-05, F-CI-09, F-OPS-04. The **Tracked as** line names the GitHub
issue(s) that carry the work forward — every one of them already exists; this round files no
new tech-debt issue (see `02-findings.md`'s closing note and the PR body's `Defers:` section).

| ID | Recommendation | Severity | Effort | Addresses | Tracked as |
|---|---|---|---|---|---|
| R-01 | Close the Vercel-secret redaction coverage gap | High | Small | F-SEC-09, F-DATA-03, F-TEST-04 | agent-ops#1752, #1757 (existing) |
| R-02 | Bound the rest of `do_push`; add a bounded DNS-failure retry | High | Medium | F-OPS-02, F-OPS-05 | agent-ops#1701, #1604 (existing) |
| R-03 | Wire `toc` and `spec` into the required-status-check ruleset | Medium | Small | F-CI-08, F-DOC-06 | agent-ops#2117, #2563/#2578 (existing) |
| R-04 | Paginate `publish-dashboard.sh`'s open-issues fetch | Medium | Small | F-CI-02 | agent-ops#1171 (existing) |
| R-05 | Fix `publish-dashboard.sh`'s `--help` swallowing; add `--help` to `monitor-cycle.sh` | Medium | Small | F-UX-02, F-UX-03, F-GOV-02 (remainder) | agent-ops#1753 (existing) |
| R-06 | Re-file/execute the coverage-tooling decision | Medium | Small | F-TEST-02 | agent-ops#2695 (existing) |
| R-07 | SHA-pin every Actions `uses:` step | Medium | Medium | F-TOOL-02, F-CI-03 (remainder) | agent-ops#1918 (existing) |
| R-08 | Grant the Reviewer stage CI-log read/rerun access | Medium | Medium | F-CI-04 | agent-ops#1496 (existing) |
| R-09 | Diagnose and unstick the CHANGELOG roll automation | Medium | Medium | F-CI-07 | agent-ops#1846, #1848 (existing) |
| R-10 | Action `#2434`'s dashboard local-tick fix | Medium | Medium | F-PERF-04 | agent-ops#2434 (existing) |
| R-11 | Owner check-in on backlog growth; check `#2437`'s `BLOCKED` status | Medium | Small | F-GOV-04 | STANDING-DECISIONS 2026-10-16, #2416/#2417/#2422/#2437 (existing) |
| R-12 | Fix the spec-split rename-during-split regression; add a mechanical guard | Medium | Small | F-DOC-05 | agent-ops#2694 (existing) |
| R-13 | Decompose the next two fastest-growing god-functions (`maybe_run_enabler`, `run_approver_stage`) | Medium | Large | F-ARCH-01 (remainder), F-ARCH-05 | agent-ops#1254, #1255, #1756, #1253, #1996 (existing) |
| R-14 | Harden `san()` against a bare `..` path segment | Low | Small | F-SEC-04 | agent-ops#1172 (existing) |
| R-15 | Clean up fixture identity hygiene | Low | Small | F-DATA-02 | agent-ops#1174 (existing) |
| R-16 | Add `.editorconfig` | Low | Small | F-TOOL-01 | agent-ops#1758 (existing) |
| R-17 | Widen the `cfg()`/`expand_home()` dedup scope | Low | Medium | F-CODE-05 | agent-ops#1755 (existing — scope correction) |
| R-18 | Land the ready `publish-dashboard.sh` flaky-test fix | Low | Small | F-TEST-05 (remainder) | agent-ops#1205 (existing) |
| R-19 | Close three stale issues describing already-resolved work | Low | Small | F-TEST-06, F-DOC-07, F-SEC-10 | agent-ops#1036, #2326, #2813 (existing — flag for maintainer) |
| R-20 | Extract a shared paginated-fetch helper | Low | Medium | F-CODE-06, F-CODE-03 (partial) | agent-ops#1919 (existing) |

## R-01 — Close the Vercel-secret redaction coverage gap

**Severity:** High · **Effort:** Small · **Addresses:** F-SEC-09, F-DATA-03, F-TEST-04

**Current state:** `agent-ops#1752` (filed 2026-09-21, scoped, one comment, no PR, 50 days
stale as of this review) asks that `redact_add_literal` be called for `VERCEL_TOKEN` and
`VERCEL_AUTOMATION_BYPASS_SECRET` at their one call site, `scripts/preview-deploy.sh`. Both
values are still used directly in HTTP headers there with no redaction registration anywhere in
the repository. Three successive review rounds (2026-09-21, 2026-10-27, 2026-11-10) have found
this unchanged.

**Intended end state:** `redact_add_literal` is called for both `VERCEL_TOKEN` and
`VERCEL_AUTOMATION_BYPASS_SECRET` at their `scripts/preview-deploy.sh` call site, the same
pattern already used for `notify_webhook_url`; `lib/redact.sh`'s shape-based rules and
`redact_add_literal`'s newline-handling gain test coverage (`#1757`); `docs/DATA-HANDLING.md`'s
screenshot-redaction paragraph is corrected to distinguish the mirror-push pass's actual
(narrower) scope from the screenshot pass's.

**Approach:** register the two literals via `redact_add_literal` at the point they're read into
shell variables in `scripts/preview-deploy.sh`; add test cases to `test/redact.test.sh`
covering the shape rules and the newline no-op before landing the fix; correct the one
paragraph in `docs/DATA-HANDLING.md`.

## R-02 — Bound the rest of `do_push`; add a bounded DNS-failure retry

**Severity:** High · **Effort:** Medium · **Addresses:** F-OPS-02, F-OPS-05

**Current state:** `scripts/state-sync.sh`'s `do_push()` wraps only its `redact_mirror_files`
step in a deadline; the `git fetch`, both `rsync` passes, and the final mirror push remain
unbounded after the mirror lock is taken — the same failure class that produced a real,
documented 7-hour fleet-wide wedge incident (`#1679`). A related, separately-tracked issue
(`#1604`) describes a push silently ending with no retry on a transient DNS/proxy error.
Severity escalated from Medium to High this round: the gap is unchanged after two full review
cycles, and `do_fetch` (the sibling half of the same file) received two rounds of hardening this
very window while `do_push` received none.

**Intended end state:** every step inside `do_push()` after the mirror lock runs under its own
deadline, the same `mirror_run_with_deadline` wrapper already used for `redact_mirror_files`; a
transient DNS/proxy failure triggers a bounded retry rather than a silent, permanent stall.

**Approach:** wrap the `git fetch`, both `rsync` calls, and the final `mirror_write push` in
`mirror_run_with_deadline`, budgeting each against the remaining time in
`push_deadline_seconds`; add a bounded retry (2–3 attempts, short backoff) around the
fetch/push network calls specifically, since these two issues should be fixed together.

## R-03 — Wire `toc` and `spec` into the required-status-check ruleset

**Severity:** Medium · **Effort:** Small · **Addresses:** F-CI-08, F-DOC-06

**Current state:** `toc` (`#2117`) and `spec` (`#2563`/`#2578`) both run on every PR but remain
absent from branch ruleset `18857310`'s required-status-checks list — now the cheapest fully
open item in this review, having sat 21–38 days with every prerequisite already satisfied.

**Intended end state:** both `toc` and `spec` appear in the ruleset's required-status-checks
list, so a PR with a stale table of contents or a dangling/colliding requirement-label citation
cannot merge.

**Approach:** a repository-settings ruleset edit (Settings → Rules → the `main` ruleset → add
`toc` and `spec` to required status checks).

### Default: add both checks to the ruleset exactly as `#2578` specifies

**Owner decision: yes** — editing branch-protection ruleset settings is an account/settings
change under the owner-only boundary (requirement 36a); no pipeline identity holds the
permission to make this edit itself.

## R-04 — Paginate `publish-dashboard.sh`'s open-issues fetch

**Severity:** Medium · **Effort:** Small · **Addresses:** F-CI-02

**Current state:** `scripts/publish-dashboard.sh:3368` fetches at most 30 open issues for the
dashboard's Priority display with no `--paginate`. Now more directly relevant than ever:
F-GOV-04 establishes the real open-issue count is 609. Tracked: `agent-ops#1171` (existing, 63
days stale).

**Intended end state:** the Priority display reflects the true open-issue set, or an explicit,
documented cap with a visible "N of M" indicator if a full fetch is judged too expensive for a
per-tick read.

**Approach:** add `--paginate` to the existing `gh_call api` invocation, following the same
idiom already used elsewhere in the codebase (candidate for R-20's shared helper once that
lands).

## R-05 — Fix `publish-dashboard.sh`'s `--help` swallowing; add `--help` to `monitor-cycle.sh`

**Severity:** Medium · **Effort:** Small · **Addresses:** F-UX-02, F-UX-03, F-GOV-02 (remainder)

**Current state:** `scripts/publish-dashboard.sh`'s flag loop ends in a bare `*) shift ;;`
catch-all, so `--help` is silently swallowed and a full publish runs instead; `monitor-cycle.sh`
has no `-h`/`--help` case at all. Both fully scoped in `agent-ops#1753`, open and unassigned
~50 days.

**Intended end state:** `./scripts/publish-dashboard.sh --help` prints usage and exits 0 without
publishing; `./monitor-cycle.sh --help` prints usage and exits 0.

**Approach:** add an explicit `-h|--help)` case to each script's flag-parsing loop, matching the
usage-text pattern already used by `agent-cycle.sh`/`review-cycle.sh`/`doctor.sh`.

## R-06 — Re-file/execute the coverage-tooling decision

**Severity:** Medium · **Effort:** Small · **Addresses:** F-TEST-02

**Current state:** no coverage-measurement tooling exists; `agent-ops#2695` (filed last round)
remains open with no PR.

**Intended end state:** a tracked decision on whether to adopt `kcov`/`bashcov`/equivalent for
`scripts/run-tests.sh`, and if so, a `--coverage` flag and an initial (even generous) floor.

**Approach:** evaluate `kcov` against the bash test harness; if viable, add `--coverage` and a
ratcheted floor matching this repo's existing `scripts/docs-size-ratchet.tsv`-style pattern.

## R-07 — SHA-pin every Actions `uses:` step

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-TOOL-02, F-CI-03 (remainder)

**Current state:** every `uses:` line across all 17 workflow files references a mutable version
tag; none are SHA-pinned (confirmed: 0 of 27 `uses:` lines). Dependabot already covers the
*update* mechanism for Actions — this recommendation covers the separate *pinning* half.
Tracked: `agent-ops#1918` (existing, 42 days stale).

**Intended end state:** every `uses:` line is pinned to a commit SHA, with Dependabot configured
to keep SHA pins current (it supports this natively for the `github-actions` ecosystem).

**Approach:** replace each `uses: owner/action@vN` with `uses: owner/action@<sha> # vN`, across
all 17 workflow files; confirm Dependabot's existing config picks up SHA-pinned actions
correctly.

## R-08 — Grant the Reviewer stage CI-log read/rerun access

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-CI-04

**Current state:** `prompts/implementer.md` has a documented route to read a failing CI log
(`gh run view --log`); `prompts/reviewer.md` has no equivalent. Tracked: `agent-ops#1496`
(existing, 57 days stale).

**Intended end state:** the Reviewer stage's prompt documents the same `gh run view --log`
extraction route, and, where its credentials allow, can re-run a failed job.

**Approach:** mirror `prompts/implementer.md`'s existing CI-log route into
`prompts/reviewer.md`; confirm the Reviewer's GitHub identity already has the permissions
needed before assuming new credentials are required.

## R-09 — Diagnose and unstick the CHANGELOG roll automation

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-CI-07

**Current state:** the scheduled roll (PR #1842, merged 2026-09-25) has produced zero output in
48 days; no PR has ever opened from a `changelog-roll` branch, despite four follow-on fixes to
its marker mechanism and two still-open bugs in its own logic (`#1846`, `#1848`).

**Intended end state:** the roll either produces its first PR, or the specific reason it never
fires is identified and fixed — not just the two known sub-bugs independently.

**Approach:** trace one full scheduled run of the roll workflow from trigger to its decision not
to open a PR (or its failure to run at all) before applying `#1846`/`#1848`'s fixes in
isolation.

### Default: trace the end-to-end run history first, then land `#1846`/`#1848`

Fixing the two known sub-bugs without first confirming the roll actually *runs* risks declaring
victory on symptoms while the root cause (zero observed runs, now 48 days) remains unexplained.

## R-10 — Action `#2434`'s dashboard local-tick fix

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-PERF-04

**Current state:** the dashboard publisher's local (non-GitHub) tick still runs ~8 full `jq`
passes over the fleet-log union every tick, proportional to total log history (124 MB+ and
growing, never rotated). Already fully scoped on `agent-ops#2434` with three candidate
approaches documented in the issue itself, now 25 days stale with zero follow-up.

**Intended end state:** the local tick's cost stops growing linearly with the installation's
total log history.

**Approach:** execute one of `#2434`'s three already-documented candidates (recency-suffix
reads with whole-union fallback, bounding the per-cycle summary to consumed cycles, or an
incremental parse cache) — this recommendation does not re-scope the fix; execution, not further
scoping, is what's outstanding.

## R-11 — Owner check-in on backlog growth; check `#2437`'s `BLOCKED` status

**Severity:** Medium · **Effort:** Small · **Addresses:** F-GOV-04

**Current state:** the repository's open-issue backlog is now 609 (up from 581 two weeks ago),
77% labelled `pw::type:tech-debt`. The owner has already made a considered, dated decision
(`STANDING-DECISIONS.md`, 2026-10-16) not to manage this by volume, and architectural mitigation
(PR `#2437`) is under active, recent development but has sat `BLOCKED` for 25 days.

**Intended end state:** no code change is prescribed by this recommendation. The end state is
that the owner has current, accurate numbers to judge whether the growth trajectory remains
acceptable, and knows what `#2437` is waiting on.

**Approach:** no implementation approach — this is a visibility recommendation, not a fix.

### Default: no action beyond this review's own numbers; check what `#2437` is blocked on

**Owner decision: yes** — whether the current backlog-growth trajectory is acceptable, and
whether to unblock `#2437`, are product/roadmap judgement calls reserved for the owner
(requirement 36a), not something a pipeline stage decides.

## R-12 — Fix the spec-split rename-during-split regression; add a mechanical guard

**Severity:** Medium · **Effort:** Small · **Addresses:** F-DOC-05

**Current state:** commit `9235549` renamed two pre-existing spec files during a split, eight
days after the convention banning exactly that was adopted. The rename has never been reverted;
no automated check catches a rename-during-split. Tracked: `agent-ops#2694` (existing), whose
own Refiner comment already carries a fully-scoped implementation approach.

**Intended end state:** the renamed files are restored to their original names with their
original content, with the inserted new content instead occupying the next unused numbers; a
mechanical check (in `scripts/check-docs.sh` or equivalent) fails a documentation-only spec-split
commit that removes a pre-existing path from a spec directory.

**Approach:** revert the two renames; add a check comparing the spec directory's file list
before/after a split commit, failing if any pre-existing path disappears while new content with
similar heading structure appears elsewhere — modelled on `scripts/check-closing-keyword.sh`'s
base-ref/head-ref diff approach, per `#2694`'s own comment.

## R-13 — Decompose the next two fastest-growing god-functions

**Severity:** Medium · **Effort:** Large · **Addresses:** F-ARCH-01 (remainder), F-ARCH-05

**Current state:** `lib/standdown.sh`'s `run_standdown_checks` — the repository's largest
undecomposed function at the prior review — was successfully decomposed this window (PR #2707,
see F-CODE-01). The next two largest now grow fastest: `lib/enabler.sh`'s `maybe_run_enabler`
(+16% in two weeks) and `lib/approver.sh`'s `run_approver_stage` (+25%). `agent-cycle.sh` and
`monitor-cycle.sh` remain flat, un-functioned top-level bodies. Tracked: `#1254`, `#1255`
(name the two functions specifically), `#1756`, `#1253`, `#1996` (the broader meta-trackers).

**Intended end state:** `maybe_run_enabler` and `run_approver_stage` are decomposed into named
sub-steps, following the same model `run_standdown_checks`'s own decomposition (PR #2707) and
`maybe_run_refiner`'s earlier one (`#964`, PR #1258) already set.

**Approach:** split each function into a family of smaller, named helper functions, each
independently testable, following the `_standdown_*` naming/structure precedent PR #2707 just
established.

## R-14 — Harden `san()` against a bare `..` path segment

**Severity:** Low · **Effort:** Small · **Addresses:** F-SEC-04

**Current state:** `lib/claim-key.sh:17`'s `san()` has no explicit rejection of a bare `..`;
every current caller happens to make this unexploitable by appending a suffix. Tracked:
`agent-ops#1172` (existing).

**Intended end state:** `san()` explicitly rejects a bare `.`/`..` result regardless of caller
behaviour, so a future caller cannot silently inherit the gap.

**Approach:** add an explicit check in `san()` itself rather than relying on every caller's
incidental suffix-appending to stay safe.

## R-15 — Clean up fixture identity hygiene

**Severity:** Low · **Effort:** Small · **Addresses:** F-DATA-02

**Current state:** 32 test fixtures still reference the maintainer's real GitHub usernames
(unchanged this window). Tracked: `agent-ops#1174` (existing).

**Intended end state:** fixtures use placeholder identities instead of the maintainer's real
handles.

**Approach:** replace the real usernames with placeholder values (e.g. `test-user`,
`example-maintainer`) across the 32 affected fixture files.

## R-16 — Add `.editorconfig`

**Severity:** Low · **Effort:** Small · **Addresses:** F-TOOL-01

**Current state:** no `.editorconfig` exists. Tracked: `agent-ops#1758` (existing).

**Intended end state:** a committed `.editorconfig` matching the project's actual formatting
conventions (indentation, line endings, final newline).

**Approach:** add a standard `.editorconfig` covering `.sh`, `.md`, `.json`, `.yml`.

## R-17 — Widen the `cfg()`/`expand_home()` dedup scope

**Severity:** Low · **Effort:** Medium · **Addresses:** F-CODE-05

**Current state:** `lib/claim.sh` and `scripts/sweep-orphan-branches.sh` (the two files
`#1755` currently names) each define a local `cfg()` diverging from `lib/config-access.sh`'s
canonical version — but this review found the real scope is far wider: `cfg()` is independently
redefined in **~15** files and `expand_home()` in **~20**, with only 4 files actually sourcing
the canonical versions. Tracked: `agent-ops#1755` (existing — cited rather than duplicated, per
the dedup-first rule; its scope should be widened when next worked, not re-filed).

**Intended end state:** every file that needs `cfg()`/`expand_home()` sources
`lib/config-access.sh` instead of redefining them locally.

**Approach:** remove the local definitions across all ~15/~20 affected files; `source
lib/config-access.sh` (or the relevant subset) in each instead, verifying no behavioural
divergence (several copies currently suppress stderr where the canonical version doesn't) is
silently relied upon by a caller.

## R-18 — Land the ready `publish-dashboard.sh` flaky-test fix

**Severity:** Low · **Effort:** Small · **Addresses:** F-TEST-05 (remainder)

**Current state:** `test/publish-dashboard.test.sh:1548`'s `run_window 20` is the known flaky
assertion; its sibling in `state-sync.test.sh` was already fixed the same way. Tracked:
`agent-ops#1205` (existing, 63 days stale).

**Intended end state:** the assertion tolerates the same timing slack its sibling fix already
established as acceptable.

**Approach:** apply the identical one-line pattern `#1722`'s fix used.

## R-19 — Close three stale issues describing already-resolved work

**Severity:** Low · **Effort:** Small · **Addresses:** F-TEST-06, F-DOC-07, F-SEC-10

**Current state:** `#1036` (fixed by PR #1165, 2+ months ago), `#2326` (fixed incidentally by
`#2665`), and `#2813` (the backgrounded-wait-guard hook-ownership check it asks for is already
implemented and CI-enforced, per five separate autonomous re-confirmations) are all still open.

**Intended end state:** all three issues are closed with a note identifying which PR/mechanism
already resolved them.

**Approach:** this review flags them for the maintainer; closing an issue is outside this
review's own mandate (filing new debt and updating registers) to action directly.

## R-20 — Extract a shared paginated-fetch helper

**Severity:** Low · **Effort:** Medium · **Addresses:** F-CODE-06, F-CODE-03 (partial)

**Current state:** the `gh api ... --paginate`/NDJSON-slurp idiom is independently
re-implemented across at least seven call sites; `lib/github-limit.sh` (the proposed shared
home) has no `gh_paginated_fetch` function yet. Tracked: `agent-ops#1919` (existing).

**Intended end state:** a single `gh_paginated_fetch` helper in `lib/github-limit.sh`, with the
seven-plus existing call sites migrated to use it — also shrinking `scripts/publish-dashboard.sh`'s
line count somewhat (F-CODE-03).

**Approach:** write `gh_paginated_fetch(endpoint, jq_filter)` in `lib/github-limit.sh` matching
the existing idiom's behaviour exactly; migrate call sites one at a time, each with its own test
coverage confirming identical output before and after.
