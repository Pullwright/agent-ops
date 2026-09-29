# Recommendations

Ordered by severity first (High before Medium before Low), then by effort within a severity band
(quick wins before long campaigns at equal severity). Every finding carried forward from the
2026-09-21 review is reconfirmed here with refreshed evidence and renumbered for this review;
recommendations covering a finding new to this round are marked `(new)`. The **Tracked as** line
names the GitHub issue(s) that carry the work forward — an existing issue where one already covers
the gap, or a freshly filed one where this review found none.

| ID | Recommendation | Severity | Effort | Addresses | Tracked as |
|---|---|---|---|---|---|
| R-01 | Resolve the live-secret transcript exposure and close the redaction-coverage gap it exposed | High | Medium | F-SEC-05, F-SEC-09, F-DATA-03 | agent-ops#1627, #1752 (existing) |
| R-02 | Make the config-table/toc AND changelog-section checks actual required merge gates | Medium | Small | F-CI-01, F-CI-06 | agent-ops#1144 (existing) + #1916 (new) |
| R-03 | Fix `publish-dashboard.sh`'s silent unknown-flag swallowing; add `--help` to `monitor-cycle.sh` | Medium | Small | F-UX-02, F-UX-03, F-GOV-02 (partial) | agent-ops#1753 (existing) |
| R-04 | Refresh the vendored project-review skill's provenance stamp and add a drift-check | Medium | Small | F-DOC-01, F-GOV-02 (partial) | agent-ops#1146 (existing) |
| R-05 | Add an update mechanism, pin floating images/tags, and SHA-pin high-privilege Actions steps | Medium | Medium | F-DEPS-01, F-DEPS-02, F-CI-03, F-TOOL-02 | agent-ops#1145 (existing) + #1918 (new) |
| R-06 | Paginate `publish-dashboard.sh`'s open-issues fetch for the Priority display | Medium | Small–Medium | F-CI-02 | agent-ops#1171 (existing) |
| R-07 | Bound the rest of `state-sync.sh`'s `do_push` and wrap `gh` API calls with a timeout | Medium | Medium | F-OPS-02 | agent-ops#1701, #1604 (existing) |
| R-08 | Grant the Reviewer stage read/rerun access to CI logs and jobs | Medium | Medium | F-CI-04 | agent-ops#1496 (existing) |
| R-09 | Extend the proven `jq` streaming fix to `publish-dashboard.sh`'s remaining full-log reads | Medium | Medium | F-PERF-01 | agent-ops#1649 (existing) |
| R-10 | Resolve the memory-cgroup unbounded/livelocked remediation gap | Medium | Large | F-OPS-01 | agent-ops#1569, #1639 (existing) |
| R-11 | Action #1756's decomposition items; keep pace with god-function growth | Medium | Large | F-ARCH-01, F-CODE-01 | agent-ops#1756, #1253–1255 (existing) |
| R-12 | Fix README's crontab duplicated-path typo; widen the org-name-drift sweep | Medium | Small | F-DOC-03, F-DOC-04 | agent-ops#1917 (new) + #1870 (existing) |
| R-13 | Add `openssl` to `doctor.sh`'s toolchain check | Low | Small | F-DEPS-03 | agent-ops#1147 (existing) |
| R-14 | Harden `san()` (`lib/claim-key.sh`) against a bare `..` path segment | Low | Small | F-SEC-04 | agent-ops#1172 (existing) |
| R-15 | Deduplicate `cfg()` between `lib/claim.sh` and `scripts/sweep-orphan-branches.sh` | Low | Small | F-CODE-05 | agent-ops#1755 (existing) |
| R-16 | Close small test-coverage gaps (`git-identity.sh`, `redact.sh` shape-rule coverage) | Low | Small | F-TEST-01, F-TEST-02, F-TEST-04 | agent-ops#1148, #1757 (existing) |
| R-17 | Land the two ready one-line flaky-test fixes | Low | Small | F-TEST-05 | agent-ops#1205, #1722 (existing) |
| R-18 | Clean up fixture identity hygiene | Low | Small | F-DATA-02 | agent-ops#1174 (existing) |
| R-19 | Developer-experience polish (`.editorconfig`) | Low | Small | F-TOOL-01 | agent-ops#1758 (existing) |
| R-20 | Decompose the dashboard's `renderBody()`; extract a shared paginated-fetch helper | Low | Medium | F-CODE-03, F-CODE-04, F-CODE-06 | agent-ops#1173 (existing) + #1919 (new) |

Not covered by a numbered recommendation this round (Low severity, no new action needed per the
finding's own direction): F-TEST-06 (agent-ops#1036 issue-hygiene observation — the described work
already shipped via PR #1165, not a code fix, flagged for the maintainer to confirm and close),
F-CI-05 (CodeQL's Actions-only scope, already resolved as a documented non-go), F-CI-07 (the new
changelog roll's first scheduled run is unconfirmed — needs a from-the-fleet check this review
cannot perform, not a code change), F-GOV-03 (draft PR #1577 stalled after the pipeline's own
Reviewer correctly caught a roadmap inconsistency — flagged for visibility only), F-TOOL-03 (this
review's own verification-coverage gap — no Docker in this sandbox — not a repo defect), and
F-ARCH-03/F-ARCH-04/F-DEPS-04/F-PERF-03 (informational/resolved observations recorded for the next
review's continuity, no action needed).

## R-01 — Resolve the live-secret transcript exposure and close the redaction-coverage gap it exposed

**Severity:** High · **Effort:** Medium · **Addresses:** F-SEC-05, F-SEC-09, F-DATA-03

**Current state:** on 2026-09-16, an Implementer stage's `docker compose config` invocation printed
a live Vercel token and GitHub App private-key paths into its own session transcript
(agent-ops#1627). Thirteen days later, the issue still has zero comments and no record of rotation.
The prior review's own follow-up (agent-ops#1752, filed 2026-09-21, scoped to registering
`VERCEL_TOKEN`/`VERCEL_AUTOMATION_BYPASS_SECRET` via `redact_add_literal`) has had one scoping
comment and no fix in the eight days since. `docs/DATA-HANDLING.md` still doesn't flag that the
mirror-push redaction pass has this gap (F-DATA-03).

**Intended end state:** the exposed credentials have been rotated or explicitly judged unnecessary
to rotate (a documented decision either way); the sandboxing question #1627 raises (why a
verification stage can see production secrets via an ordinary command) has a documented answer or a
scoping fix; `redact_add_literal`'s registration is generalised to cover `VERCEL_TOKEN`/
`VERCEL_AUTOMATION_BYPASS_SECRET` at its `scripts/preview-deploy.sh` call site, the same way
`notify_webhook_url` now is; and `docs/DATA-HANDLING.md`'s redaction paragraph states what is and
isn't covered rather than a blanket "safe to share" framing.

**Approach:** the credential-rotation and sandboxing questions are owner-only decisions per
agent-ops#1627's own framing — the code portion (registering the two Vercel secrets, updating the
doc) can and should proceed independently on agent-ops#1752. No dependency on other
recommendations.

## R-02 — Make the config-table/toc AND changelog-section checks actual required merge gates

**Severity:** Medium · **Effort:** Small · **Addresses:** F-CI-01, F-CI-06

**Current state:** two independent doc/format drift-detectors — `config-table.yml`/`toc.yml` and
the newer `changelog-section.yml` — each run on every PR and report a result, but none is in the
branch ruleset's 8 required-status-check contexts, and neither `config-table.yml`/`toc.yml` nor
`changelog-section.yml` has a `merge_group:` trigger (a prerequisite for adding either to the
ruleset without stalling the merge queue). agent-ops#1144 is the owner's own binding sequencing
decision for the first pair, filed 2026-09-08 and unchanged since. `changelog-section.yml`'s own
header already documents the same requirement for itself (requirement 25c), and `doctor.sh`'s own
live acceptance check already reports the gap — but nothing tracked it until this review
(agent-ops#1916).

**Intended end state:** all three workflows have a `merge_group:` trigger and are added to the
required-status-check list, so the exact class of drift each exists to catch (a schema/heading
edit landing without regeneration; a PR merging without a valid `## Changelog` section) is
structurally prevented from merging, not just flagged.

**Approach:** small, mechanical addition to each workflow's `on:` block; the ruleset edit itself is
an owner-only action (requirement 36a) per agent-ops#1144's own sequencing, which applies equally to
`changelog-section`.

## R-03 — Fix `publish-dashboard.sh`'s silent unknown-flag swallowing; add `--help` to `monitor-cycle.sh`

**Severity:** Medium · **Effort:** Small · **Addresses:** F-UX-02, F-UX-03, F-GOV-02 (partial)

**Current state:** `publish-dashboard.sh`'s flag loop ends with a bare `*) shift ;;` — any
unrecognised flag, including `-h`/`--help`, is silently discarded and a full dashboard rebuild runs
regardless. `monitor-cycle.sh` errors loudly on an unknown flag but has no `--help` case at all.
Both gaps are fully scoped on agent-ops#1753, which has sat `refined` and unassigned for a full
review cycle (8 days) with no PR against it — the kind of stall F-GOV-02 flags directly.

**Intended end state:** `publish-dashboard.sh` errors loudly on an unrecognised flag (matching
`monitor-cycle.sh`'s and `check-node-compose.sh`'s existing pattern) and answers `-h`/`--help` with
its own usage summary; `monitor-cycle.sh` answers `-h`/`--help` the same way its siblings do.

**Approach:** mechanical, following the exact pattern issue agent-ops#974's fix already established
for the other entry points. No new issue needed — agent-ops#1753 is ready to execute as written.

## R-04 — Refresh the vendored project-review skill's provenance stamp and add a drift-check

**Severity:** Medium · **Effort:** Small · **Addresses:** F-DOC-01, F-GOV-02 (partial)

**Current state:** `docs/REVIEW-PIPELINE-SPEC.md` still names the skill's upstream sync as of a date
and commit that predate two real in-repo content edits since. agent-ops#1146, filed 2026-08-31, is
still open, fully scoped, unassigned — 29 days old and unfixed across four consecutive reviews, the
same stall pattern F-GOV-02 flags.

**Intended end state:** the provenance line names the actual last-synced commit/date, and a
lightweight drift-check prevents this specific staleness from silently recurring.

**Approach:** as issue agent-ops#1146 already proposes; no new issue needed — it is ready to
execute as written.

## R-05 — Add an update mechanism, pin floating images/tags, and SHA-pin high-privilege Actions steps

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-DEPS-01, F-DEPS-02, F-CI-03, F-TOOL-02

**Current state:** no Dependabot/Renovate config exists anywhere; two Compose sidecar images
(`tailscale/tailscale:latest`, `containrrr/watchtower:latest`) float unpinned; every GitHub Actions
`uses:` line across all 10 action-using workflows references a mutable version tag rather than a
commit SHA, including the two steps (`docker/login-action`, `docker/build-push-action`) that hold
registry-push credentials on every push to `main`. The first three gaps are tracked under
agent-ops#1145 (open, unchanged); the SHA-pinning trust-model gap is distinct from #1145's own
version-*bump* scope and had no tracking issue until this review (agent-ops#1918).

**Intended end state:** `.github/dependabot.yml` exists (at minimum a `github-actions` ecosystem
entry); both Compose sidecar images are pinned to a specific tag; the highest-privilege Actions
steps are pinned to commit SHAs with a comment noting the tag each SHA corresponds to.

**Approach:** as agent-ops#1145 already scopes for the first three; the SHA-pinning half is
independent, scoped narrowly to the two credential-holding steps as a starting point. Independent
of other recommendations.

## R-06 — Paginate `publish-dashboard.sh`'s open-issues fetch for the Priority display

**Severity:** Medium · **Effort:** Small–Medium · **Addresses:** F-CI-02

**Current state:** the fetch is still `per_page=30` with no `--paginate`; the Priority field — the
code's own comment calls it load-bearing for the Co-Ordinator's ranking — is still truncated past
the 30 newest open issues. Tracked as agent-ops#1171, open, unchanged.

**Intended end state:** the Priority display reflects the full open-issue set, using the same
`api_json_paged`-style fix already proven elsewhere in this codebase for the identical bug class;
or, if that cost isn't justified, the 30-row cap is explicitly documented as an accepted trade-off.

**Approach:** as agent-ops#1171 already scopes; no new issue needed.

## R-07 — Bound the rest of `state-sync.sh`'s `do_push` and wrap `gh` API calls with a timeout

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-OPS-02

**Current state:** only the redaction loop within `do_push` is deadline-bounded; the `git fetch`,
both `rsync -a --delete` passes, and the final `git push` all execute after `mirror_lock` is taken
with no deadline applied. agent-ops#1701 (open, fully specced, explicitly rules out a
per-command-`timeout` alternative as insufficient for the `rsync` passes) and agent-ops#1604 (a
retry-with-backoff spec for the underlying network-hang failure mode) are both unimplemented.
Separately, a repo-wide grep of every `gh api`/`gh pr`/`gh issue`/`gh repo`/`gh graphql` call
(58+ files) again found no `timeout`(1) wrapper anywhere.

**Intended end state:** `do_push`'s remaining network/rsync steps are deadline-bounded using the
same `mirror_run_with_deadline` machinery already proven for the redaction loop; `gh` invocations in
the shim are wrapped with an outer `timeout`(1) so a hung API call degrades the same way a hung
Claude stage or webhook POST already does.

**Approach:** as agent-ops#1701 already proposes for the first half (option A, wrap the whole
lock-holding body); the `gh`-timeout half is best scoped as a follow-up to that issue given the
shared root cause.

## R-08 — Grant the Reviewer stage read/rerun access to CI logs and jobs

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-CI-04

**Current state:** the pipeline's own App installation lacks `actions: write`, and the node's
egress proxy blocks the Actions log-blob host, so the autonomous Reviewer stage can neither read
why a check failed nor re-run it. agent-ops#1496 carries a fully-verified, twice-confirmed
specification citing a concrete incident that cost a full ~25-minute re-run via an empty commit;
no PR references it.

**Intended end state:** the Reviewer stage can read a failing job's log and re-run just the failed
job, so a flake is distinguishable from a real regression without a full re-run.

**Approach:** as agent-ops#1496 already proposes (grant `actions: read`/`actions: write`; allow the
log-blob host through the egress proxy) — a permissions/infrastructure decision, not primarily a
code change.

## R-09 — Extend the proven `jq` streaming fix to `publish-dashboard.sh`'s remaining full-log reads

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-PERF-01

**Current state:** `scripts/publish-dashboard.sh:1110` still runs a full-array-materializing
`jq -sc` slurp over the never-rotated `log.jsonl`. The proven streaming pattern (`-n`/`inputs`,
already applied to `lib/crash-loop.sh` and `lib/stage-health.sh`) was never applied here.
agent-ops#1649 is open with no PR ever opened against it; the one PR that did land in this area
(#1635) fixed a different memory coupling in the same script.

**Intended end state:** `publish-dashboard.sh`'s remaining full-log `jq -sc` calls use the same
streaming conversion already proven elsewhere in this codebase.

**Approach:** mechanical, matching the already-proven pattern. No dependency on other
recommendations.

## R-10 — Resolve the memory-cgroup unbounded/livelocked remediation gap

**Severity:** Medium · **Effort:** Large · **Addresses:** F-OPS-01

**Current state:** five independent investigations across agent-ops#1569 (spanning 2026-09-15
through 2026-09-24) all reach the same conclusion: the only known fix requires host-level access no
container in this architecture has. A second issue (agent-ops#1639) shows the setup script's own
shipped default produces the exact failure shape its sibling code warns about. No pager invariant
exists for this condition.

**Intended end state:** either the pipeline has a narrowly-scoped, privileged path to apply the
cgroup-parent fix itself, or a sustained `unbounded`/`livelocked`/rising-`oom_kill_count` verdict
pages a human rather than waiting to be noticed on a dashboard; and the setup script's own shipped
default no longer contradicts its sibling code's warning.

**Approach:** this is an architecture/isolation-posture decision as much as an implementation task
— the owner's call on which path to take is the real dependency. The #1639 self-inconsistency fix
is small and independent and can land first as a quick partial win.

## R-11 — Action agent-ops#1756's decomposition items; keep pace with god-function growth

**Severity:** Medium · **Effort:** Large · **Addresses:** F-ARCH-01, F-CODE-01

**Current state:** one of seven previously-flagged oversized stage-orchestration functions is fully
decomposed; `maybe_run_enabler` and `run_standdown_checks` have both grown further since being
flagged (the latter by +72 lines this window alone); `monitor-cycle.sh` was built with the same
undecomposed-top-level-flow shape as `agent-cycle.sh`. The tracking issue meant to close this whole
gap (agent-ops#1756, filed by the prior review specifically to file the two still-missing issues,
correct stale #1256, and cover `monitor-cycle.sh`) has itself had zero activity since creation.

**Intended end state:** `run_standdown_checks` and `compute_skip_lists` are tracked and eventually
decomposed following the same pattern as the per-function issues already open; `monitor-cycle.sh`'s
undecomposed regions are decomposed using `review-cycle.sh` as the template; stale agent-ops#1256
is closed or retitled; and the fix is applied faster than new undecomposed code accumulates.

**Approach:** incremental, matching the codebase's own established pattern of small,
independently-reviewable decomposition PRs. agent-ops#1756 is already fully specified — the
blocker is pickup, not scoping.

## R-12 — Fix README's crontab duplicated-path typo; widen the org-name-drift sweep

**Severity:** Medium · **Effort:** Small · **Addresses:** F-DOC-03, F-DOC-04

**Current state:** README's current (non-legacy) "Keep it fresh" crontab install line duplicates
the `Poetic-Poems` org segment in its own example path — a currently-active install instruction, so
copying it verbatim silently breaks the dashboard's periodic refresh. Separately, the repository's
post-transfer org-name drift (`Poetic-Poems/agent-ops` → `Pullwright/agent-ops`) is already tracked
across eight locations by agent-ops#1870 (filed the day before this review), but that issue doesn't
cite the README's intro-sentence link or one legacy-section example, both of which still name the
old org.

**Intended end state:** the crontab line's path is correct; agent-ops#1870's sweep additionally
covers the two locations this review found outside its current scope.

**Approach:** both are single-line documentation edits. Tracked as new issue agent-ops#1917 for the
crontab typo; agent-ops#1870's existing scope can simply be widened by one location when picked up,
no new issue needed for that half.

## R-13 — Add `openssl` to `doctor.sh`'s toolchain check

**Severity:** Low · **Effort:** Small · **Addresses:** F-DEPS-03

**Current state:** `lib/approver-token.sh` hard-depends on `openssl` for JWT signing, and the
Dockerfile deliberately installs it for that reason, but `doctor.sh`'s toolchain loop doesn't check
for its presence. Tracked as agent-ops#1147, open.

**Intended end state:** a node running `merge_autonomy` above `human` without `openssl` gets a
doctor warning ahead of time, rather than discovering the gap mid-cycle when a token mint fails.

**Approach:** a one-line addition to the existing toolchain loop, gated on whether any configured
`merge_autonomy` source is above `human`, per agent-ops#1147's own comment.

## R-14 — Harden `san()` (`lib/claim-key.sh`) against a bare `..` path segment

**Severity:** Low · **Effort:** Small · **Addresses:** F-SEC-04

**Current state:** `san()`'s safety against path traversal is currently an accident of every caller
appending a filename suffix after calling it, not a guarantee the function itself makes. Tracked as
agent-ops#1172, open.

**Intended end state:** `san()` explicitly rejects (or otherwise neutralises) a bare `.`/`..` input,
so the safety property holds independently of caller discipline.

**Approach:** as agent-ops#1172 already scopes; no new issue needed.

## R-15 — Deduplicate `cfg()` between `lib/claim.sh` and `scripts/sweep-orphan-branches.sh`

**Severity:** Low · **Effort:** Small · **Addresses:** F-CODE-05

**Current state:** both files define an identical `cfg()` that already differs from the shared
`lib/config-access.sh` version — the exact divergence-after-duplication hazard the project's own
prior dedup effort was meant to close for this pair of files, but that fix touched only `san()`,
not `cfg()`. Tracked as agent-ops#1755, open, unchanged since it was filed.

**Intended end state:** both files source the shared `cfg()` from `lib/config-access.sh`, or the
divergence is explicitly documented as deliberate.

**Approach:** small, mechanical. agent-ops#1755 is ready to execute as written.

## R-16 — Close small test-coverage gaps

**Severity:** Low · **Effort:** Small · **Addresses:** F-TEST-01, F-TEST-02, F-TEST-04

**Current state:** `lib/git-identity.sh` has no test coverage anywhere (agent-ops#1148, open);
`lib/redact.sh`'s own shape-based rules and newline no-op behaviour are still exercised only as a
side effect of an unrelated integration test's fixtures, even though the placeholder-escaping half
of the same gap (`test/redact.test.sh`) was closed this window (agent-ops#1757, open but only
half-actioned).

**Intended end state:** `test/git-identity.test.sh` exists; `test/redact.test.sh` gains direct
assertions for each shape rule and the newline-refusal behaviour, not just the placeholder-escaping
fix it currently covers.

**Approach:** straightforward, well-specified unit-test additions following the suite's existing
conventions. `git-identity.sh` coverage tracked as agent-ops#1148; the `redact.sh` shape-rule gap as
agent-ops#1757 (existing, its scope simply needs completing rather than reopening).

## R-17 — Land the two ready one-line flaky-test fixes

**Severity:** Low · **Effort:** Small · **Addresses:** F-TEST-05

**Current state:** issue agent-ops#1205's fix (widen `run_window 20` to `30` at
`test/publish-dashboard.test.sh:1277`) has sat fully specified and unpicked for 23 days across two
review cycles; agent-ops#1722's fix (tolerate `{0,1}` in an exact-`"0"` age assertion at
`test/state-sync.test.sh:1657`) has sat unpicked for 9 days. Both flakes are empirically rare in
practice (0 failures in the last 50 `build-image.yml` runs).

**Intended end state:** both one-line fixes land exactly as specified.

**Approach:** as both issues already propose; no new issue needed — the blocker is pickup, not
scoping.

## R-18 — Clean up fixture identity hygiene

**Severity:** Low · **Effort:** Small · **Addresses:** F-DATA-02

**Current state:** 35 test files now use the maintainer's real GitHub usernames as fixture values
(up from 33 at the prior review), even though agent-ops#1174's replacement has been scoped since
2026-09-05 with no pickup — the count is growing in the wrong direction.

**Intended end state:** fixtures use synthetic identities instead of the maintainer's own,
real-though-already-public GitHub identity.

**Approach:** as agent-ops#1174 already scopes; no new issue needed. Low urgency but grows with
every new fixture until addressed.

## R-19 — Developer-experience polish (`.editorconfig`)

**Severity:** Low · **Effort:** Small · **Addresses:** F-TOOL-01

**Current state:** neither `.editorconfig` nor a `Makefile`/scripts-index exists. agent-ops#1758
(filed 2026-09-21) scopes a minimal fix (root `.editorconfig`, three properties only) and
explicitly defers the rest.

**Intended end state:** an `.editorconfig` codifies the 2-space-indent/LF/final-newline convention
already followed by inspection.

**Approach:** as agent-ops#1758 already scopes; no new issue needed.

## R-20 — Decompose the dashboard's `renderBody()`; extract a shared paginated-fetch helper

**Severity:** Low · **Effort:** Medium · **Addresses:** F-CODE-03, F-CODE-04, F-CODE-06

**Current state:** `renderBody()` has grown from 462 to 552 lines across three consecutive review
cycles despite being flagged every time (agent-ops#1173, open); `publish-dashboard.sh` and
`doctor.sh` continue growing while remaining almost entirely flat top-level script, though neither
is on the hourly hot path and both have dedicated test coverage. Separately, the paginated
comments/reviews/timeline `gh api --paginate` idiom is now independently reimplemented in 13+
files, with two more instances added this window rather than a shared helper extracted
(agent-ops#1919, new this run).

**Intended end state:** `renderBody()` is split by banner group, mirroring the file's existing
`*Panel` convention; no urgent action needed yet for `publish-dashboard.sh`/`doctor.sh` (watch, not
act); a thin shared `gh_paginated_fetch` wrapper exists for the three most-repeated endpoint shapes.

**Approach:** as agent-ops#1173 already scopes for `renderBody()`; the fetch-helper extraction is
independent, low-urgency, and tracked as new issue agent-ops#1919.
