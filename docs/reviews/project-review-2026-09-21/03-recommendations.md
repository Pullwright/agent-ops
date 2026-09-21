# Recommendations

Ordered by severity first (High before Medium before Low), then by effort within a severity band
(quick wins before long campaigns). All findings carried forward from the 2026-09-05 review are
reconfirmed here with refreshed evidence and renumbered for this review; recommendations covering
a finding new to this round are marked `(new)`. The **Tracked as** line names the GitHub issue(s)
that carry the work forward — an existing issue where one already covers the gap, or a freshly
filed one where this review found none.

| ID | Recommendation | Severity | Effort | Addresses | Tracked as |
|---|---|---|---|---|---|
| R-01 | Resolve the live-secret transcript exposure and close the redaction-coverage gap it exposed | High | Medium | F-SEC-05, F-DATA-03 | agent-ops#1627 (existing) + #1752 (new) |
| R-02 | Make the config-table/toc checks actual required merge gates | Medium | Small | F-CI-01 | agent-ops#1144 (existing) |
| R-03 | Fix `publish-dashboard.sh`'s silent unknown-flag swallowing; add `--help` to `monitor-cycle.sh` | Medium | Small | F-UX-02, F-UX-03 | agent-ops#1753 (new) |
| R-04 | Refresh the vendored project-review skill's provenance stamp and add a drift-check | Medium | Small | F-DOC-01 | agent-ops#1146 (existing) |
| R-05 | Correct both pipeline specs' target-repository tables to name agent-ops itself | Medium | Small | F-DOC-03 | agent-ops#1754 (new) |
| R-06 | Add an update mechanism and pin floating/tag-only references across agent-ops's own supply chain | Medium | Medium | F-DEPS-01, F-DEPS-02, F-CI-03, F-TOOL-03 | agent-ops#1145 (existing) |
| R-07 | Paginate `publish-dashboard.sh`'s open-issues fetch for the Priority display | Medium | Small–Medium | F-CI-02 | agent-ops#1171 (existing) |
| R-08 | Bound the rest of `state-sync.sh`'s `do_push` and wrap `gh` API calls with a timeout | Medium | Medium | F-OPS-02 | agent-ops#1701 (existing) |
| R-09 | Grant the Reviewer stage read/rerun access to CI logs and jobs | Medium | Medium | F-CI-04 | agent-ops#1496 (existing) |
| R-10 | Extend the proven `jq` `splits`→`inputs` fix to `publish-dashboard.sh`'s remaining full-log reads | Medium | Medium | F-PERF-01 | agent-ops#982, #1649 (existing) |
| R-11 | Resolve the memory-cgroup unbounded/livelocked remediation gap | Medium | Large | F-OPS-01 | agent-ops#1569, #1639 (existing) |
| R-12 | Keep decomposing stage-orchestration god functions and extend the fix to new entry points before they grow further | Medium | Large | F-ARCH-01, F-CODE-01 | agent-ops#1253–1257 (existing, partial) + #1756 (new) |
| R-13 | Add `openssl` to `doctor.sh`'s toolchain check | Low | Small | F-DEPS-03 | agent-ops#1147 (existing) |
| R-14 | Fix `redact_add_literal`'s placeholder escaping and newline-secret visibility | Low | Small | F-SEC-06, F-SEC-07 | agent-ops#1741, #1730 (existing) |
| R-15 | Harden `san()` (`lib/claim-key.sh`) against a bare `..` path segment | Low | Small | F-SEC-04 | agent-ops#1172 (existing) |
| R-16 | Deduplicate `cfg()` between `lib/claim.sh` and `scripts/sweep-orphan-branches.sh` | Low | Small | F-CODE-05 | agent-ops#1755 (new) |
| R-17 | Close small test-coverage gaps (`git-identity.sh`, a dedicated `lib/redact.sh` test, the missing `publish-dashboard.sh` webhook-redaction assertion) | Low | Small | F-TEST-01, F-TEST-05, F-TEST-06 | agent-ops#1148 (existing) + #1757 (new) |
| R-18 | Clean up fixture identity hygiene | Low | Small | F-DATA-02 | agent-ops#1174 (existing) |
| R-19 | Developer-experience polish (`.editorconfig`, scripts index) | Low | Small | F-TOOL-01, F-TOOL-02 | agent-ops#1758 (new) |
| R-20 | Decompose the dashboard's `renderBody()`; keep an eye on `publish-dashboard.sh`/`doctor.sh`'s growth | Low | Medium | F-CODE-03, F-CODE-04 | agent-ops#1173 (existing, `renderBody()` only) |

Not covered by a numbered recommendation this round (Low severity, no new action needed per the
finding's own direction): F-TEST-02 (no coverage-measurement tooling — same issue as R-17,
agent-ops#1148), F-TEST-07 (two flaky tests, already tracked as agent-ops#1205/#1722, rare in
practice), F-TEST-08 (issue-hygiene observation about agent-ops#1036 possibly already fixed — not
a code change, flagged for the maintainer to confirm and close), F-CI-05 (CodeQL's Actions-only
scope, already resolved as a documented non-go via agent-ops#976), F-PERF-02 (a measurement-vs-
estimate lesson to apply next time agent-ops#904 is touched, no urgent action now), F-OPS-03 (no
dedicated runbook, already covered by the prior review's R-09, still open, low urgency).

## R-01 — Resolve the live-secret transcript exposure and close the redaction-coverage gap it exposed (new)

**Severity:** High · **Effort:** Medium · **Addresses:** F-SEC-05, F-DATA-03

**Current state:** on 2026-09-16, an Implementer stage's `docker compose config` invocation
printed a live Vercel token and GitHub App private-key paths into its own session transcript
(agent-ops#1627). The Implementer caught and remediated its own session, and nothing reached
`.env` or this repository's git history, but the issue remains open six days later with no
rotation decision recorded and no fix to the structural gap it names: `lib/redact.sh`'s shape-
based rules plus its single registered literal (`notify_webhook_url`) do not cover a Vercel token
or a key path, so a recurrence reaching the state-mirror push (which applies this same redaction
pass to cycle transcripts) would not be caught either. `docs/DATA-HANDLING.md` still states
redaction makes data "safely shareable" without qualifying this limit.

**Intended end state:** the exposed credentials have been rotated or explicitly judged
unnecessary to rotate (a documented decision either way); the question of why a verification stage
can see production secrets via an ordinary command has a documented answer or a scoping fix;
`redact_add_literal`'s registration is generalised to cover `VERCEL_TOKEN`/
`VERCEL_AUTOMATION_BYPASS_SECRET` and any other env-sourced runtime secret a stage can see, the
same way `notify_webhook_url` now is; and `docs/DATA-HANDLING.md`'s redaction paragraph states
what is and isn't covered rather than a blanket "safe to share" claim.

**Approach:** the credential-rotation and sandboxing questions are owner-only decisions per
agent-ops#1627's own framing — this recommendation's code portion (the redaction generalisation
and doc update) can proceed independently and is tracked as new issue agent-ops#1752. No
dependency on other recommendations.

## R-02 — Make the config-table/toc checks actual required merge gates

**Severity:** Medium · **Effort:** Small · **Addresses:** F-CI-01

**Current state:** `config-table.yml` and `toc.yml` both run on every PR but have no
`merge_group:` trigger, so neither is eligible to be added to the branch ruleset's required-
status-check list — confirmed via a live `gh api` read of the current ruleset, which requires 8
named contexts, neither of these among them. The owner's own tracked decision (agent-ops#1144)
sequences this as "add `merge_group:` first, then add to the ruleset," and has sat open since it
was filed.

**Intended end state:** both workflows have a `merge_group:` trigger and are added to the required-
status-check list, so the exact class of drift they exist to catch (a schema/heading edit landing
without its generated-region regeneration) is structurally prevented from merging, not just
flagged on the PR.

**Approach:** small, mechanical addition to each workflow's `on:` block; the ruleset edit is the
owner's own action per agent-ops#1144's sequencing.

## R-03 — Fix `publish-dashboard.sh`'s silent unknown-flag swallowing; add `--help` to `monitor-cycle.sh` (new)

**Severity:** Medium · **Effort:** Small · **Addresses:** F-UX-02, F-UX-03

**Current state:** `publish-dashboard.sh`'s flag loop ends with a bare `*) shift ;;` — any
unrecognised flag, including `-h`/`--help`, is silently discarded and a full dashboard rebuild
runs regardless. `monitor-cycle.sh` errors loudly on an unknown flag but has no `--help` case at
all, unlike its two siblings (`agent-cycle.sh`, `review-cycle.sh`), which both do.

**Intended end state:** `publish-dashboard.sh` errors loudly on an unrecognised flag (matching
`monitor-cycle.sh`'s and `check-node-compose.sh`'s existing pattern) and answers `-h`/`--help`
with its own usage summary; `monitor-cycle.sh` answers `-h`/`--help` the same way its siblings do.

**Approach:** mechanical, following the exact pattern issue agent-ops#974's fix already
established for `review-cycle.sh`/`scripts/serve-dashboard.sh`/`scripts/open-dashboard.sh`.
Tracked as new issue agent-ops#1753.

## R-04 — Refresh the vendored project-review skill's provenance stamp and add a drift-check

**Severity:** Medium · **Effort:** Small · **Addresses:** F-DOC-01

**Current state:** `docs/REVIEW-PIPELINE-SPEC.md` still names the skill's upstream sync as of
2026-07-19, despite two real content edits since (2026-08-01, 2026-08-28). No drift-check exists.
Tracked as agent-ops#1146, open across three consecutive reviews with no fix landed.

**Intended end state:** the provenance line names the actual last-synced commit/date, and a
lightweight drift-check (even a manual PR-template checklist item, mirroring the sibling
`td-tooling-drift.yml` pattern) prevents this specific staleness from silently recurring.

**Approach:** as issue agent-ops#1146 already proposes; no new issue needed.

## R-05 — Correct both pipeline specs' target-repository tables to name agent-ops itself (new)

**Severity:** Medium · **Effort:** Small · **Addresses:** F-DOC-03

**Current state:** both `docs/IMPLEMENTATION-PIPELINE-SPEC.md` and `docs/REVIEW-PIPELINE-SPEC.md`
document exactly two target repositories, but `config.json` has configured a third —
`Pullwright/agent-ops` itself — since at least the prior review's own pinned baseline, with its
own distinct autonomy level, merge budget, protected-paths list, and source ordering, none of it
documented in either spec.

**Intended end state:** both specs' target-repository sections accurately list all three
configured repositories (or are rephrased to avoid an enumerable claim a routine config change
would silently invalidate).

**Approach:** a direct table/prose edit in each spec, sourced from the current `config.json`.
Tracked as new issue agent-ops#1754.

## R-06 — Add an update mechanism and pin floating/tag-only references across agent-ops's own supply chain

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-DEPS-01, F-DEPS-02, F-CI-03, F-TOOL-03

**Current state:** no Dependabot/Renovate config exists anywhere in the tree; two Compose sidecar
images (`tailscale/tailscale:latest`, `containrrr/watchtower:latest`) float unpinned; every
GitHub Actions `uses:` line across all 9 action-using workflows references a mutable version tag,
including the two steps (`docker/login-action`, `docker/build-push-action`) that hold
registry-push credentials on every push to `main`. All four gaps are tracked under the same open
issue, agent-ops#1145.

**Intended end state:** `.github/dependabot.yml` exists (at minimum a `github-actions` ecosystem
entry); both Compose sidecar images are pinned to a specific tag or digest; the highest-privilege
Actions steps are pinned to commit SHAs.

**Approach:** as agent-ops#1145 already scopes; no new issue needed. Independent of other
recommendations.

## R-07 — Paginate `publish-dashboard.sh`'s open-issues fetch for the Priority display

**Severity:** Medium · **Effort:** Small–Medium · **Addresses:** F-CI-02

**Current state:** the fetch is still `per_page=30` with no `--paginate`; a follow-up (agent-
ops#1171) added a separate total-count display so the panel no longer understates the open-issue
count, but the Priority field itself — the code's own comment calls it load-bearing for the
Co-Ordinator's ranking — is still truncated past the 30 newest open issues.

**Intended end state:** the Priority display reflects the full open-issue set, using the same
`api_json_paged`-style fix already proven in `scripts/gather-source-state.sh` for the identical
bug class; or, if that cost isn't justified, the 30-row cap is explicitly documented as an
accepted trade-off now that the total-count workaround exists.

**Approach:** as agent-ops#1171 already scopes; no new issue needed.

## R-08 — Bound the rest of `state-sync.sh`'s `do_push` and wrap `gh` API calls with a timeout

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-OPS-02

**Current state:** the recent mirror-lock wedge fix (agent-ops#1679's resolution) bounds only the
redaction loop within `do_push`; the `git fetch`/`git push` steps and two `rsync` passes remain
unbounded while holding the same lock (agent-ops#1701, open), and separately, no `gh api`/`gh pr`/
`gh issue`/`gh repo`/`gh graphql` call anywhere in the 64 files that make them has any timeout —
the pipeline's single most frequent outbound call class is the one left completely unbounded.

**Intended end state:** `do_push`'s remaining network/rsync steps are deadline-bounded using the
same `mirror_run_with_deadline` machinery already proven for the redaction loop (or individually
bounded via `timeout`(1) plus `http.lowSpeedLimit`/`http.lowSpeedTime`); `gh` invocations in the
shim are wrapped with an outer `timeout`(1) so a hung API call degrades the same way a hung Claude
stage or webhook POST already does.

**Approach:** as agent-ops#1701 already proposes for the first half; the `gh`-timeout half is new
work best scoped as a follow-up to that issue rather than a separate filing, given the shared root
cause (unbounded outbound calls holding pipeline state).

## R-09 — Grant the Reviewer stage read/rerun access to CI logs and jobs

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-CI-04

**Current state:** the pipeline's own App installation lacks `actions: write`, and the node's
egress proxy blocks the Actions log-blob host, so the autonomous Reviewer stage can neither read
why a check failed nor re-run it — confirmed by a concrete incident (agent-ops#1496, open) that
cost a full ~25-minute re-run via an empty commit for what was plausibly an already-known flake.

**Intended end state:** the Reviewer stage can read a failing job's log and re-run just the failed
job, so a flake (F-TEST-07) is distinguishable from a real regression without a full re-run.

**Approach:** as agent-ops#1496 already proposes (grant `actions: read`/`actions: write`; allow the
log-blob host through the egress proxy) — a permissions/infrastructure change, not a code change,
so effort here is mostly the App-permission and proxy-allowlist decisions rather than
implementation.

## R-10 — Extend the proven `jq` `splits`→`inputs` fix to `publish-dashboard.sh`'s remaining full-log reads

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-PERF-01

**Current state:** a 2026-08-25 fix (agent-ops#982's underlying pattern) replaced eight slurp-based
`jq -R -s` union-log readers with a ~1000x-faster streaming form across `lib/crash-loop.sh` and
siblings, but `scripts/publish-dashboard.sh`'s own `jq -sc` full-log reads (line 1043 and
siblings) were never converted. This is not merely a latency concern any more: the resulting
memory footprint has been the documented, measured cause of two real fleet-wide memory-livelock
incidents this window (agent-ops#1620 and its lineage #1305, #1643), and agent-ops#1649 shows the
publisher's own working set is now a direct linear function of the never-rotated `log.jsonl`.

**Intended end state:** `publish-dashboard.sh`'s remaining full-log `jq -sc` calls use the same
`-n`/`inputs` streaming conversion already proven elsewhere; the harder windowed-fold cases
(`item_lifecycle_fold`) get the streaming treatment agent-ops#1649 outlines. The stale, partially-
obsolete agent-ops#982 is closed or corrected once its remaining named call sites are actually
fixed, rather than left as text a future contributor might re-derive from scratch.

**Approach:** mechanical for the straightforward slurp calls (per-call-site, matching the already-
proven pattern); the streaming-fold conversion is the harder remaining piece. No dependency on
other recommendations.

## R-11 — Resolve the memory-cgroup unbounded/livelocked remediation gap

**Severity:** Medium · **Effort:** Large · **Addresses:** F-OPS-01

**Current state:** the memory-cgroup verdict now reaches the dashboard and Monitor digest
automatically every hour, but a live node has been running with no parent memory ceiling and
`oom_kill_count: 12` for multiple days (agent-ops#1569, open) because the only known fix
(`scripts/cgroup-parent-setup.sh`) requires host-level access no container in this architecture
has — three separate autonomous-pipeline sessions investigated and each reached the same dead
end. Separately, the setup script's own documented default configuration produces the exact
failure shape it exists to prevent (agent-ops#1639, open). No pager invariant exists for this
condition.

**Intended end state:** either the pipeline has a narrowly-scoped, privileged path to apply the
cgroup-parent fix itself, or a sustained `unbounded`/`livelocked`/rising-`oom_kill_count` verdict
pages a human rather than waiting to be noticed on a dashboard; and the setup script's own
documented default no longer contradicts its sibling code's warning.

**Approach:** this is an architecture/isolation-posture decision (agent-ops#1569's "option 1 vs
option 2," previously deferred) as much as an implementation task — the owner's call on which
path to take is the real dependency here. The #1639 self-inconsistency fix is small and
independent and can land first as a quick partial win.

## R-12 — Keep decomposing stage-orchestration god functions and extend the fix to new entry points before they grow further

**Severity:** Medium · **Effort:** Large · **Addresses:** F-ARCH-01, F-CODE-01

**Current state:** one of seven previously-flagged oversized stage-orchestration functions is
fully decomposed (`maybe_run_refiner`, via agent-ops#1258); two of the remaining four tracked ones
have grown larger since being filed (`maybe_run_enabler`, `run_approver_stage`); two functions the
prior review's own sampling flagged were never filed as issues (`run_standdown_checks`,
`compute_skip_lists`); and the newest pipeline entry point, `monitor-cycle.sh`, was built with the
identical undecomposed-top-level-flow shape rather than reusing `review-cycle.sh`'s already-proven
decomposition.

**Intended end state:** `run_standdown_checks` and `compute_skip_lists` are tracked and eventually
decomposed following the same pattern as agent-ops#1254/#1255/#1257; `monitor-cycle.sh`'s two
undecomposed regions are decomposed using `review-cycle.sh` as the template; the stale
agent-ops#1256 (naming a function that no longer exists after agent-ops#1560's redesign) is closed
or retitled; and the fix is applied faster than new undecomposed code accumulates.

**Approach:** incremental, matching the codebase's own established pattern of small,
independently-reviewable decomposition PRs, one function/region at a time. Tracked as new issue
agent-ops#1756 (covering the two untracked functions and the `monitor-cycle.sh` gap); the four
pre-existing per-function issues (agent-ops#1253/#1254/#1255/#1257) continue independently.

## R-13 — Add `openssl` to `doctor.sh`'s toolchain check

**Severity:** Low · **Effort:** Small · **Addresses:** F-DEPS-03

**Current state:** `lib/approver-token.sh` hard-depends on `openssl` for JWT signing, and the
Dockerfile deliberately installs it for that reason, but `doctor.sh`'s toolchain loop doesn't
check for its presence. Tracked as agent-ops#1147, open.

**Intended end state:** a node running `merge_autonomy` above `human` without `openssl` gets a
doctor warning ahead of time, rather than discovering the gap mid-cycle when a token mint fails.

**Approach:** a one-line addition to the existing toolchain loop, gated on whether any configured
`merge_autonomy` source is above `human`.

## R-14 — Fix `redact_add_literal`'s placeholder escaping and newline-secret visibility

**Severity:** Low · **Effort:** Small · **Addresses:** F-SEC-06, F-SEC-07

**Current state:** the `PLACEHOLDER` argument to `redact_add_literal` is unescaped for sed-
replacement specials (agent-ops#1741, open — not exploitable today since both current callers use
the default placeholder), and a newline-bearing secret is silently skipped with no operator-
visible signal (agent-ops#1730, open — the correct refusal, but invisible when it fires).

**Intended end state:** the placeholder is escaped the same way `VALUE` already is; a skipped
newline-bearing secret produces a visible warning rather than a silent no-op.

**Approach:** as both issues already propose; no new issue needed. Small, independent fixes to
`lib/redact.sh`.

## R-15 — Harden `san()` (`lib/claim-key.sh`) against a bare `..` path segment

**Severity:** Low · **Effort:** Small · **Addresses:** F-SEC-04

**Current state:** `san()`'s safety against path traversal is currently an accident of every
caller appending a filename suffix after calling it, not a guarantee the function itself makes.
Tracked as agent-ops#1172, open since the 2026-08-31 review.

**Intended end state:** `san()` explicitly rejects (or otherwise neutralises) a bare `.`/`..`
input, so the safety property holds independently of caller discipline.

**Approach:** as agent-ops#1172 already scopes; no new issue needed.

## R-16 — Deduplicate `cfg()` between `lib/claim.sh` and `scripts/sweep-orphan-branches.sh` (new)

**Severity:** Low · **Effort:** Small · **Addresses:** F-CODE-05

**Current state:** both files define an identical `cfg()` that already differs from the shared
`lib/config-access.sh` version (a `2>/dev/null` suppression the shared version lacks) — the exact
divergence-after-duplication hazard the project's own prior dedup effort (agent-ops#967) was
meant to close for this pair of files, but that fix touched only `san()`, not `cfg()`.

**Intended end state:** both files source the shared `cfg()` from `lib/config-access.sh` (after
confirming the `2>/dev/null` difference doesn't matter to either caller), or the divergence is
explicitly documented as deliberate.

**Approach:** small, mechanical. Tracked as new issue agent-ops#1755.

## R-17 — Close small test-coverage gaps

**Severity:** Low · **Effort:** Small · **Addresses:** F-TEST-01, F-TEST-05, F-TEST-06

**Current state:** `lib/git-identity.sh` has no test coverage anywhere (agent-ops#1148, open);
`lib/redact.sh` — the module solely responsible for keeping secrets out of mirrored/published
state, and the subject of two fix commits this window alone — has no dedicated test file; and
`5284c02`'s own webhook-redaction fix added a regression test to one of its two symmetric call
sites (`state-sync.sh`) but not the other (`publish-dashboard.sh`), in the same commit.

**Intended end state:** `test/git-identity.test.sh` exists; `test/redact.test.sh` asserts each
shape rule and `redact_add_literal`'s escaping/newline behaviour directly; `test/publish-
dashboard.test.sh` gains the same webhook-literal assertion `state-sync.test.sh` already has.

**Approach:** straightforward, well-specified unit-test additions following the suite's existing
conventions. `git-identity.sh` coverage tracked as agent-ops#1148 (existing); the `redact.sh`/
`publish-dashboard.sh` test gaps tracked as new issue agent-ops#1757.

## R-18 — Clean up fixture identity hygiene

**Severity:** Low · **Effort:** Small · **Addresses:** F-DATA-02

**Current state:** 33 test files plus 1 dashboard-data fixture use the maintainer's real GitHub
usernames as fixture values, up from ~20 files at the prior review as the test suite has grown.
Tracked as agent-ops#1174, open.

**Intended end state:** fixtures use synthetic identities instead of the maintainer's own,
real-though-already-public GitHub identity.

**Approach:** as agent-ops#1174 already scopes; no new issue needed. Low urgency (self-referential,
already-public, very low practical exposure) but grows with every new fixture until addressed.

## R-19 — Developer-experience polish (`.editorconfig`, scripts index) (new)

**Severity:** Low · **Effort:** Small · **Addresses:** F-TOOL-01, F-TOOL-02

**Current state:** neither `.editorconfig` nor a `Makefile`/scripts-index exists; both were
explicitly scoped out of the prior `--help`-coverage fix (agent-ops#974) with no follow-up filed
until this review.

**Intended end state:** an `.editorconfig` codifies the 2-space-indent/LF/final-newline convention
already followed by inspection; optionally, a generated scripts index (mirroring
`scripts/render-toc.sh`'s own pattern) surfaces the full command set at a glance.

**Approach:** low priority, optional; a reasonable trade-off has held so far for a solo maintainer
who knows the tree. Tracked as new issue agent-ops#1758.

## R-20 — Decompose the dashboard's `renderBody()`; keep an eye on `publish-dashboard.sh`/`doctor.sh`'s growth

**Severity:** Low · **Effort:** Medium · **Addresses:** F-CODE-03, F-CODE-04

**Current state:** `renderBody()` has grown from 462 to ~538 lines across two consecutive review
cycles despite being flagged both times (agent-ops#1173, open); `publish-dashboard.sh` and
`doctor.sh` have each grown 26–35% this window while remaining almost entirely flat top-level
script, though neither is on the hourly hot path and both have dedicated test coverage.

**Intended end state:** `renderBody()` is split by banner group, mirroring the file's existing
`*Panel` convention. No urgent action needed yet for `publish-dashboard.sh`/`doctor.sh`; the same
phase-extraction treatment applies whenever their change frequency rises further.

**Approach:** as agent-ops#1173 already scopes for `renderBody()`; no new issue needed for the
other two files given the "watch, don't act yet" verdict both this review and the prior one
reached independently.
