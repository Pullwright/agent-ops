# Improvement prompts

One prompt per recommendation, in priority order (severity first, then effort within a severity
band). Each prompt is self-contained and may be pasted into a fresh AI agent session with no other
context. Ordering dependencies, where they exist, are noted in both the preamble here and inside
the dependent prompt itself.

`Pullwright/agent-ops` is a self-hosted, unattended Bash pipeline (~400 shell scripts) that
autonomously selects, implements, and reviews pull requests across `Poetic-Poems/poetic`,
`poetic-fiddle`, and `agent-ops` itself. `main` is protected: every change lands via a pull
request, squash-merged with the PR title (Conventional Commits format) as the commit message.
`AGENTS.md` at the repository root is the canonical contributor reference — read it before
starting any of these prompts. Tests run via `./scripts/run-tests.sh` (requires Docker; do not run
the suite directly on the host — see the script's own header for why). Shell files are linted via
`./scripts/lint-shell.sh` (shellcheck v0.10.0). Any change to pipeline behaviour must update the
matching as-built spec under `docs/` in the same pull request.

## Prompt for R-01 — Resolve the live-secret transcript exposure and close the redaction-coverage gap it exposed

**Bundles:** R-01 only · **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: agent-ops#1627 (open) documents that on 2026-09-16, a `docker compose config` invocation
inside a live node container printed a real Vercel token and GitHub App private-key paths from the
process environment into an agent session's own transcript. The Implementer caught and remediated
its own session; nothing reached `.env` or git. The issue names two unresolved questions: whether
to rotate the exposed credentials, and why a verification stage can see production secrets via an
ordinary command at all. Both are maintainer-owned decisions — do not make them yourself. Instead,
read the issue in full (`gh issue view 1627`) and post a comment summarizing the current state and
asking the maintainer to make both calls, if no comment already exists doing so.

The code portion of this work is agent-ops#1752 (open), which you should resolve directly. The
redaction machinery is `lib/redact.sh`. `REDACT_SED_ARGS` matches only fixed token shapes
(`gh[pousr]_…`, `github_pat_…`, `sk-(ant-|proj-)?…`, `Bearer …`/`token …`). Anything else is only
redacted if explicitly registered via `redact_add_literal`; today only `scripts/state-sync.sh`
and `scripts/publish-dashboard.sh` register a literal, and both register only
`notify_webhook_url`. `scripts/preview-deploy.sh` reads `VERCEL_TOKEN` and
`VERCEL_AUTOMATION_BYPASS_SECRET` from the environment with no fixed shape and neither is
registered anywhere.

The goal: register `VERCEL_TOKEN` and `VERCEL_AUTOMATION_BYPASS_SECRET` via `redact_add_literal`
at every call site that currently registers `notify_webhook_url` (grep for
`redact_add_literal.*notify_webhook_url` to find them), following the exact pattern already
established for that variable — value present and non-empty, registered before any `redact()`/
`redact_mirror_files` call. Then update `docs/DATA-HANDLING.md`'s "Privacy and security
considerations" section: it currently states redaction lets operational data be "safely shared for
debugging without leaking credentials" — qualify this to say which shapes/literals are covered and
which are not, rather than a blanket claim.

Constraints: do not change `REDACT_SED_ARGS`'s existing shape rules. Do not attempt to fix the
"why can a stage see production secrets" question in code — that's the maintainer's call, flagged
above, not yours. Keep the fix narrowly scoped to registering the two named Vercel variables; if
you find other env-sourced runtime secrets the pipeline's stages can see with no fixed shape and no
registration, list them in your PR description rather than silently expanding scope.

Verification: run `./scripts/run-tests.sh state-sync publish-dashboard redact` and confirm they
pass. Add or extend a test asserting a configured `VERCEL_TOKEN`/`VERCEL_AUTOMATION_BYPASS_SECRET`
is masked after redaction, following the pattern the existing `notify_webhook_url` test in
`test/state-sync.test.sh` already uses. Run `./scripts/lint-shell.sh` and confirm it's clean.

Work cost-consciously. This is a security-sensitive fix (secret redaction) — do the code change and
its review yourself at a high-capability tier rather than delegating it; you may delegate writing
the new test assertions to a lower-cost subagent once the registration pattern is settled, since
that part is mechanical (matching an existing test's shape). Verify all delegated work before
integrating it.

Deliverable: a pull request titled in Conventional Commits format (e.g. `fix(redact): register
Vercel credentials for redaction`), referencing agent-ops#1752 with a closing keyword, updating
`lib/redact.sh`'s callers, `docs/DATA-HANDLING.md`, and adding the new test coverage. Separately,
post the maintainer-decision comment on agent-ops#1627 if none exists yet — do not close #1627
yourself; it stays open until the maintainer decides.
```

## Prompt for R-02 — Make the config-table/toc checks actual required merge gates

**Bundles:** R-02 only · **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: `.github/workflows/config-table.yml` and `.github/workflows/toc.yml` both run
`--check` on every pull request but have no `merge_group:` trigger, so neither is eligible to be
added to the branch ruleset's required-status-check list (GitHub requires a `merge_group:` trigger
for a check used in a merge queue). agent-ops#1144 (open) records the owner's own binding
sequencing decision: step 1 (add `merge_group:` to both workflows) must land before step 2 (the
owner adds both to the ruleset) — step 2 is not yours to do.

Goal: add a `merge_group:` trigger to both `.github/workflows/config-table.yml` and
`.github/workflows/toc.yml`'s `on:` blocks, following the same pattern already used by
`.github/workflows/shellcheck.yml` and `codeql.yml` (both already have `merge_group:`). Do not
change either workflow's actual check logic — only the `on:` trigger list.

Constraints: do not touch the branch ruleset (`gh api repos/Pullwright/agent-ops/rulesets/...`)
yourself — that is explicitly the owner's step per agent-ops#1144.

Verification: after the change, confirm both workflow files still parse as valid YAML and that a
`workflow_dispatch`/`pull_request` run still behaves identically (the change only adds a trigger,
it doesn't remove or alter existing ones). Run `./scripts/render-config-table.sh --check` and
`./scripts/render-toc.sh --check` locally to confirm both are currently clean (they should be,
unrelated to this change, but confirms you haven't broken anything).

Work cost-consciously. This whole task suits a low-cost tier — it is a two-line YAML addition to
each of two files, following an existing pattern in the same repository.

Deliverable: a pull request titled `ci: add merge_group trigger to config-table and toc checks`,
referencing agent-ops#1144 (not closing it — the ruleset step remains open), with a PR description
noting that the owner still needs to add both check names to the branch ruleset to complete the
fix.
```

## Prompt for R-03 — Fix `publish-dashboard.sh`'s silent unknown-flag swallowing; add `--help` to `monitor-cycle.sh`

**Bundles:** R-03 (both fixes — same CLI-argument-handling gap class, small enough to do together)
· **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: `scripts/publish-dashboard.sh`'s flag-parsing loop (search for `--no-github`) ends with a
bare `*) shift ;;` catch-all — any unrecognised flag, including `-h`/`--help`, is silently consumed
and a full dashboard rebuild runs anyway, with no error and no usage text. Compare this to
`monitor-cycle.sh`'s own flag loop (search for `--dry-run`), whose catch-all is
`*) echo "monitor-cycle: unknown argument: $1" >&2; exit 64 ;;` — it errors loudly, which is the
correct pattern, but it has no `-h|--help` case at all, unlike its siblings `agent-cycle.sh` and
`review-cycle.sh`, both of which answer `--help` with a full `usage()` (added by agent-ops#974,
PR #1447 — `monitor-cycle.sh` was added after that sweep ran and was never included). This work is
tracked as agent-ops#1753 (open).

Goal:
1. In `scripts/publish-dashboard.sh`, replace the `*) shift ;;` catch-all with a loud error
   matching the pattern already used in `monitor-cycle.sh`/`scripts/check-node-compose.sh`
   (`echo "publish-dashboard: unknown argument: $1" >&2; exit 64`), and add a `-h|--help` case that
   prints a short usage summary (the script's own header comment already documents its flags —
   base the usage text on that).
2. In `monitor-cycle.sh`, add a `-h|--help` case to the existing flag loop, printing a `usage()`
   function following the same style as `review-cycle.sh`'s.

Constraints: do not change either script's other flag behaviour (`--no-github`, `--fast`, `--now`
in publish-dashboard.sh; `--dry-run`, `--once` in monitor-cycle.sh, plus its existing switch-
management-flag redirect messages) — only the catch-all/help handling.

Verification: run `./scripts/publish-dashboard.sh --help` and `./scripts/publish-dashboard.sh
--bogus-flag` and confirm both now produce clear output and the latter exits non-zero without
running a rebuild. Run `monitor-cycle.sh --help` and confirm it prints usage and exits 0. Run
`./scripts/run-tests.sh publish-dashboard monitor-cycle` (or the closest-matching test files) and
confirm nothing regresses. Run `./scripts/lint-shell.sh` and confirm it's clean.

Work cost-consciously. This whole task suits a low-cost tier — it is mechanical, following an
existing, already-proven pattern from agent-ops#974's own fix.

Deliverable: a pull request titled `fix(cli): stop publish-dashboard.sh silently swallowing
unknown flags; add monitor-cycle.sh --help`, closing agent-ops#1753 with a closing keyword.
```

## Prompt for R-04 — Refresh the vendored project-review skill's provenance stamp and add a drift-check

**Bundles:** R-04 only · **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: `docs/REVIEW-PIPELINE-SPEC.md` (search for "pinned copy of the upstream skill") states the
vendored `.claude/skills/project-review/` skill was "vendored 2026-07-19" at upstream commit
`2c8e18c`. Since then the skill has been directly edited at least twice (commits `86bfbea` and
`5daa821`, both visible via `git log -- .claude/skills/project-review/`) without the provenance
line being updated — it is now roughly 9 weeks stale. agent-ops#1146 (open) tracks this and has
sat open across three consecutive project reviews. No CI check exists to catch this staleness.

Goal: update `docs/REVIEW-PIPELINE-SPEC.md`'s provenance line to accurately describe the skill's
current state (either name the most recent commit that touched `.claude/skills/project-review/`
as the "last synced" point, or reframe the line to describe local edits explicitly if the skill is
no longer a strict upstream mirror — read the actual git history first to decide which framing is
true). Then add a lightweight drift-check: at minimum, a note in
`.github/PULL_REQUEST_TEMPLATE.md`'s checklist reminding a contributor who edits
`.claude/skills/project-review/` to update this provenance line in the same PR; if a scriptable
check is feasible within this task's budget (comparing a stored hash of the skill directory against
its current state, similar in spirit to `scripts/render-toc.sh --check`), prefer that over the
manual reminder alone.

Constraints: do not change the skill's own content (`.claude/skills/project-review/**`) as part of
this task — only the provenance documentation and the drift-check.

Verification: re-read the updated provenance line against `git log -- .claude/skills/project-
review/` and confirm it's now accurate. If you added a scripted check, run it and confirm it
passes on the current tree and fails when you temporarily touch a file under
`.claude/skills/project-review/` without updating the stamp (then revert that temporary touch).

Work cost-consciously. This whole task suits a low-cost tier for the documentation fix; if you
build a scripted drift-check, that part suits a mid-cost tier (it's ordinary implementation
against a clear pattern — mirror `scripts/render-toc.sh --check`'s approach).

Deliverable: a pull request titled `docs(review-spec): refresh vendored skill provenance stamp and
add a drift reminder`, closing agent-ops#1146 with a closing keyword.
```

## Prompt for R-05 — Correct both pipeline specs' target-repository tables to name agent-ops itself

**Bundles:** R-05 only · **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: `docs/IMPLEMENTATION-PIPELINE-SPEC.md`'s "Target repositories" table (search for that
heading) lists exactly `Poetic-Poems/poetic` and `Poetic-Poems/poetic-fiddle`, and states this
table is "the one place a config change needs an editorial update to stay accurate."
`docs/REVIEW-PIPELINE-SPEC.md` makes the same two-repo claim for its own target list (search for
"Target repositories" or "currently"). Both are wrong: `config.json`'s `.repos[]` and
`.project_review.repos[]` arrays each have a third entry, `Pullwright/agent-ops` itself, with its
own distinct `merge_autonomy`, `merge_budget_per_day`, `merge_autonomy_protected_paths`, `sources`
ordering (implementation) and `min_days_between_reviews`/`report_directory` (review). `AGENTS.md`
at the repo root already describes this correctly ("...implements, and reviews pending work in
poetic, poetic-fiddle, and agent-ops itself"). This is tracked as agent-ops#1754 (open).

Goal: read `config.json`'s current `.repos[]` and `.project_review.repos[]` arrays in full. Add a
third row to `docs/IMPLEMENTATION-PIPELINE-SPEC.md`'s target-repositories table for
`Pullwright/agent-ops`, naming its actual configured `sources` order and any other columns the
existing table has for the other two rows. Update `docs/REVIEW-PIPELINE-SPEC.md`'s equivalent
section the same way, or rephrase it to avoid making an enumerable claim (e.g. "the repositories
configured in `project_review.repos`" rather than naming a fixed count) if that reads more
maintainably long-term — your call, but state your reasoning in the PR description either way.

Constraints: these are as-built specs — describe the currently configured state, not a
recommendation for what it should be. Do not change `config.json` itself. Do not touch the
generated config-table regions (`<!-- config-table:start -->`...`<!-- config-table:end -->`) if
either document has one nearby — those are regenerated from `config.schema.json` by
`scripts/render-config-table.sh` and must not be hand-edited; this table is prose/a hand-maintained
table outside those markers.

Verification: after editing, re-read both tables against the current `config.json` and confirm
every configured repository, and its distinguishing settings, is now named. If either document has
a table of contents region (`<!-- toc:start -->`), run `./scripts/render-toc.sh --check` — it
should still pass since you're not changing headings.

Work cost-consciously. This whole task suits a low-cost tier — it is a factual table/prose update
sourced directly from an existing config file, with no design judgement beyond the two-column
question flagged above.

Deliverable: a pull request titled `docs(specs): add agent-ops to both pipelines' target-
repositories tables`, closing agent-ops#1754 with a closing keyword.
```

## Prompt for R-06 — Add an update mechanism and pin floating/tag-only references across agent-ops's own supply chain

**Bundles:** R-06 only (covers F-DEPS-01, F-DEPS-02, F-CI-03, F-TOOL-03 — all tracked under the
same existing issue, agent-ops#1145) · **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: this repository has no npm/pip-style dependency manifest — its supply chain is OS
packages, pinned binaries in `deploy/docker/Dockerfile`, GitHub Actions, and Compose sidecar
images. Currently: no `.github/dependabot.yml` (or Renovate config) exists anywhere; every
`uses:` line across all 9 action-using workflow files in `.github/workflows/` references a mutable
version tag rather than a commit SHA (in contrast to the SHA/checksum pins the same repo applies
to `supercronic`/`shellcheck`/`claude-code` in the Dockerfile); and
`deploy/docker/compose.yaml` has two sidecar images floating on `:latest`
(`tailscale/tailscale:latest`, `containrrr/watchtower:latest`), unlike the repo's own
CI-published image which every other `image:` line references. All four gaps are tracked under
agent-ops#1145 (open).

Goal:
1. Add `.github/dependabot.yml` with at minimum a `github-actions` ecosystem entry (weekly
   cadence is reasonable; match whatever interval convention, if any, this org's other repos use —
   check `Poetic-Poems/poetic`'s own `.github/dependabot.yml` if it exists, for consistency).
2. Pin `tailscale/tailscale` and `containrrr/watchtower` in `deploy/docker/compose.yaml` to a
   specific tag (not `latest`) — pick each image's current latest stable release tag at the time of
   this change, and say so in the PR description so the choice is auditable.
3. Pin the highest-privilege GitHub Actions steps to commit SHAs: at minimum
   `docker/login-action` and `docker/build-push-action` in `.github/workflows/build-image.yml`
   (both run with `packages: write`/registry-push credentials), and `actions/checkout` in that same
   job. Use a comment noting the SHA's corresponding version tag, following the style GitHub itself
   recommends for SHA-pinned actions (e.g. `uses: actions/checkout@<sha> # v7`).

Constraints: do not pin the base OS image or its apt packages in the Dockerfile — that floating
posture is deliberate and documented in the Dockerfile's own comments (CI rebuilds on every merge,
so a security update lands within a cycle). Do not SHA-pin every single action in every workflow if
that would be a large, low-value diff — prioritise the steps named above; note in the PR
description which others you left as tags and why (e.g. "low-privilege, read-only checkout steps
left as tags for readability; can be tightened in a follow-up if desired").

Verification: run `docker compose -f deploy/docker/compose.yaml config` (non-mutating, does not
require the images to actually pull) and confirm it still parses cleanly after the image-tag
changes. Confirm the Dependabot config is valid YAML (`yamllint` or a `gh` dry-run if available).
Run `./scripts/lint-shell.sh` — should be unaffected, but confirms nothing else broke.

Work cost-consciously. This whole task suits a low-cost-to-mid-cost tier — it is mechanical
version-pinning and a standard Dependabot config, following patterns you can look up (GitHub's own
SHA-pinning documentation, the target images' release pages) rather than design work.

Deliverable: a pull request titled `build(deps): add Dependabot for GitHub Actions and pin
floating image/action references`, closing agent-ops#1145 with a closing keyword.
```

## Prompt for R-07 — Paginate `publish-dashboard.sh`'s open-issues fetch for the Priority display

**Bundles:** R-07 only · **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: `scripts/publish-dashboard.sh` fetches open issues for its Priority display via
`gh_call api "repos/$slug/issues?state=open&per_page=30"` (search for this string) — a single,
unpaginated page. A follow-up (agent-ops#1171, still open) added a separate `search/issues`
call to show a true total open-issue count, but the Priority band itself — the surrounding code
comment calls it load-bearing for the Co-Ordinator's ranking — is still silently truncated past
the 30 newest open issues. `scripts/gather-source-state.sh` already solved the identical bug class
(a single-page `gh api` issues fetch) using an `api_json_paged` helper — read that function and its
call site as the reference implementation.

Goal: convert `scripts/publish-dashboard.sh`'s issues fetch to use the same `api_json_paged`-style
pagination `scripts/gather-source-state.sh` already uses, so the Priority display reflects the full
open-issue set rather than only the newest 30. If full pagination proves too costly for this
script's actual call pattern (e.g. it's invoked far more frequently than `gather-source-state.sh`
and would meaningfully increase API-call volume), instead explicitly document the 30-row cap as an
accepted trade-off in a comment next to the fetch, referencing the total-count workaround
agent-ops#1171 already added — but prefer the pagination fix if the cost is comparable, since it's
the more complete answer to the finding.

Constraints: do not change the total-count `search/issues` call agent-ops#1171 already added —
that's a separate, working piece; leave it as is, or update it only if pagination changes make it
newly redundant (in which case say so in the PR description).

Verification: add or extend a test in `test/publish-dashboard.test.sh` with a fixture carrying
more than 30 open issues, asserting the Priority display reflects an issue beyond the 30th (this is
the same class of regression test agent-ops#1171's own fix should have added but the review found
missing — do not skip it). Run `./scripts/run-tests.sh publish-dashboard` and confirm it passes.
Run `./scripts/lint-shell.sh` and confirm it's clean.

Work cost-consciously. This is ordinary implementation against a clear, already-proven pattern in
the same codebase — suits a mid-cost tier. Writing the new fixture/test can be delegated to a
lower-cost subagent once the pagination approach is settled, since it's mechanical (extending an
existing test file's fixture pattern).

Deliverable: a pull request titled `fix(dashboard): paginate the open-issues fetch feeding the
Priority display`, closing agent-ops#1171 with a closing keyword.
```

## Prompt for R-08 — Bound the rest of `state-sync.sh`'s `do_push` and wrap `gh` API calls with a timeout

**Bundles:** R-08 only · **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: a recent fix (commit closing agent-ops#1679, a real 7-hour production wedge) added
`mirror_run_with_deadline` (`lib/mirror-lock.sh`) and used it to bound only the redaction loop
within `scripts/state-sync.sh`'s `do_push` function. The fix's own PR description explicitly defers
the rest: "a wedge anywhere else in `do_push` (the `git fetch`/`git push` network steps most
plausibly) still holds `mirror_lock` indefinitely" — tracked as agent-ops#1701 (open), which also
notes a real, independently-confirmed DNS/proxy failure mode for this exact transport
(agent-ops#1604, open). Separately, a repo-wide grep of every `lib/`/`scripts/` file calling `gh
api`/`gh pr`/`gh issue`/`gh repo`/`gh graphql` finds no `timeout`(1) wrapper anywhere, including in
`lib/gh-shim.sh` itself — in contrast to `lib/stage-run.sh`'s Claude-stage timeout/watchdog,
`scripts/preview-deploy.sh`'s `curl --max-time 30`, and `lib/notify.sh`'s `curl --max-time 10`, all
of which are properly bounded.

Goal, part 1 (do_push): read `lib/mirror-lock.sh`'s `mirror_run_with_deadline` and
`scripts/state-sync.sh`'s `do_push` function in full. Extend deadline-bounding to cover the
remaining network/filesystem steps in `do_push` — the `git fetch` in `mirror_init`, the final `git
push`, and the two `rsync` passes — using the same `mirror_run_with_deadline` machinery already
proven for the redaction loop, choosing a deadline consistent with the existing one's reasoning
(check `lib/mirror-lock.sh`'s header comment for how that value was chosen).

Goal, part 2 (gh timeout): add an outer `timeout`(1) wrapper around `gh` invocations in
`lib/gh-shim.sh` (or wherever the shim actually issues the call), choosing a timeout value
consistent with this codebase's other outbound-call bounds (`preview-deploy.sh`'s 30s is a
reasonable reference point, but a `gh api` call may legitimately need more for a large paginated
fetch — read `lib/github-limit.sh`/`api_json_paged` for how long-running calls already behave
before picking a value, and err toward a longer bound that still fires rather than none at all).

Constraints: do not weaken or remove the redaction loop's existing deadline bound. Do not change
`gh`'s retry/backoff behaviour beyond adding the outer timeout — if a call legitimately needs to
retry, the timeout should bound each attempt or the whole call as this codebase's existing
conventions dictate (read `lib/github-limit.sh` first to understand the existing retry shape before
deciding where the timeout wraps).

Verification: run `./scripts/run-tests.sh state-sync` and confirm existing mirror-lock/wedge tests
still pass. Add a test simulating a hung `git fetch`/`push` (or the closest simulable equivalent
given the existing test harness's conventions for `do_push`) asserting the lock is released within
the new deadline. For the `gh` timeout, add a test asserting a call wrapped in the new timeout
actually terminates when the underlying command hangs (mock/stub `gh` to sleep past the timeout, if
the test harness supports that pattern elsewhere — check for a precedent in `test/gh-shim.test.sh`
or similar). Run `./scripts/lint-shell.sh` and confirm it's clean.

Work cost-consciously. This touches locking/concurrency and a recent real production incident —
treat both parts as mid-to-high-capability work given the risk of a subtly wrong deadline
reintroducing the wedge class it's meant to close; do not delegate the core deadline-wiring logic
to a low-cost subagent, though test-fixture scaffolding that mirrors an existing pattern can be.
Verify all delegated work before integrating it.

Deliverable: a pull request titled `fix(state-sync): bound do_push's remaining network/rsync steps
and wrap gh calls with a timeout`, closing agent-ops#1701 with a closing keyword, and updating
`docs/IMPLEMENTATION-PIPELINE-SPEC.md`'s relevant section if the deadline/timeout behaviour is
already documented there (check first).
```

## Prompt for R-09 — Grant the Reviewer stage read/rerun access to CI logs and jobs

**Bundles:** R-09 only · **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: agent-ops#1496 (open) documents that the autonomous Reviewer stage cannot read a failing
CI job's log (`gh run view --job <id> --log` is blocked by the node's egress proxy, returning
`Forbidden`/`HTTP 000`) and cannot re-run just the failed job (`gh run rerun <id> --failed` fails
with `Resource not accessible by integration` because the pipeline's GitHub App installation lacks
`actions: write`). A concrete incident (PR #1494) cost a full ~25-minute workflow re-run via an
empty commit because the Reviewer had no way to diagnose a plausible flake. This compounds with
known-flaky tests (agent-ops#1205, #1722): every timing-sensitive flake is currently
indistinguishable, to the Reviewer, from a real regression.

Goal: this is primarily a permissions/infrastructure change, not a code change.
1. Identify what needs to change on the GitHub App installation side to grant `actions: read` (to
   read job logs) and `actions: write` (to re-run failed jobs) — read `lib/github-app-token.sh`
   and `lib/forge-auth.sh` to understand how this pipeline's App installation permissions are
   currently scoped and where they'd need to change (this may require an app-manifest change
   outside this repository, or a config change within it — investigate and report which, since
   you should not assume without checking).
2. Identify the specific host(s) the Actions log-blob download uses (GitHub's log URLs typically
   resolve to a `productionresultssa*.blob.core.windows.net`-style host or similar — confirm the
   actual host by attempting `gh run view --job <id> --log` against a real recent run and reading
   the failure) and add it to `deploy/docker/egress-allowlist.txt`, following that file's existing
   format and comment conventions.
3. Once both are in place (or if the App-permission change is out of this task's reach — say so
   explicitly rather than guessing), update whichever stage/prompt currently handles CI-failure
   triage (likely `prompts/reviewer.md` or the Reviewer's stage logic in `lib/`) to actually use
   `gh run view --log`/`gh run rerun --failed` instead of falling back to an empty-commit re-push.

Constraints: do not weaken the egress fence beyond adding the one specific host needed — read
`deploy/docker/egress-proxy.conf`'s own comments on why the allowlist is scoped tightly before
adding anything. Do not grant broader App permissions than the two named scopes.

Verification: after the egress-allowlist change, confirm the Docker image still builds (the
Dockerfile parses and stages the allowlist at build time — re-run the relevant build step, or at
minimum confirm the file's syntax matches the existing entries' format). If you changed stage
logic, run the relevant test file and confirm it passes. If the App-permission piece is outside
what you can verify without live App credentials, say so explicitly in the PR description rather
than claiming it works.

Work cost-consciously. The permission/allowlist investigation and the App-manifest question need
high-capability judgement (getting scope-of-access wrong has real security consequences for a
pipeline with merge authority); any resulting stage-prompt wording changes can be delegated to a
mid-cost tier once the underlying capability is confirmed working.

Deliverable: a pull request (or, if the App-permission change requires action outside this
repository, a PR for the allowlist/code portions plus a clear comment on agent-ops#1496 describing
exactly what manual step remains and why) titled `feat(ci): let the Reviewer stage read failing job
logs and re-run failed jobs`, closing agent-ops#1496 with a closing keyword only once both halves
are genuinely done.
```

## Prompt for R-10 — Extend the proven `jq` `splits`→`inputs` fix to `publish-dashboard.sh`'s remaining full-log reads

**Bundles:** R-10 only · **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: a 2026-08-25 fix (agent-ops#982's underlying pattern) replaced `jq -R -s '[ splits("\n")
| ... ]'` (slurp the whole file as one string, then split) with `jq -R -n '[ inputs | ... ]'`
(stream line-by-line) across `lib/crash-loop.sh` and its siblings, measured at ~1000x faster
(83s → 0.07s) on a large `log.jsonl`. `scripts/publish-dashboard.sh` still uses the slower
`jq -sc '.' "$events_jsonl"` slurp form at several call sites (search for `jq -sc` in that file).
This is no longer purely a latency concern: agent-ops#1649 (open) measured this script's own memory
footprint as a direct linear function of the never-rotated `log.jsonl`, and that growth is the
documented, measured cause of two real fleet-wide memory-livelock production incidents this window
(agent-ops#1620 and its lineage #1305, #1643). agent-ops#982 itself is stale text — its originally-
named call sites were already fixed the same day it was filed — but the remainder it describes
(this script's own slurp calls) was never converted; a draft PR meant to fix its stale
cross-reference (#1492) has sat unmerged 9+ days.

Goal: convert `scripts/publish-dashboard.sh`'s full-log `jq -sc` reads to the same `-n`/`inputs`
streaming form already proven in `lib/crash-loop.sh` — read that file's converted call sites first
as your reference implementation, and confirm the semantics (especially around empty-input/`null`
handling, which `-n`/`inputs` treats differently from `-s`) are preserved exactly. For any call
site that needs a genuine windowed/roll-up fold rather than a flat map (agent-ops#1649 names
`item_lifecycle_fold` specifically as harder to convert this way), read that issue's own proposed
approach before attempting a naive conversion — a windowed fold over streamed input needs different
handling than a flat transform.

Constraints: do not change the output shape/schema of any of these `jq` transforms — this is a
performance fix, not a behaviour change. Preserve exact behaviour on an empty or missing
`log.jsonl` (test this specifically; `-n`/`inputs` and `-s` can differ here).

Verification: run `./scripts/run-tests.sh publish-dashboard` and confirm all existing assertions
pass unchanged (a regression here would silently change dashboard output, so a green suite before
and after both matter). If feasible in your environment, benchmark one converted call site against
a large synthetic `log.jsonl` (following agent-ops#1649's own measurement approach) and note the
before/after figures in your PR description, the way the original `21ec741` fix did. Once your
conversion covers agent-ops#982's remaining named call sites, close it with a reference to this fix
rather than leaving it open as stale text; if `item_lifecycle_fold` genuinely needs to stay
slurp-based for now, say so explicitly and leave agent-ops#1649 open for that harder remainder.

Work cost-consciously. The straightforward slurp-to-stream conversions suit a mid-cost tier
(mechanical, following an already-proven pattern) once you've confirmed empty-input semantics
match; the `item_lifecycle_fold` windowed-fold conversion, if you attempt it, is closer to
design-level work and should get a high-capability review before merging given it's on the path
that caused two real production incidents.

Deliverable: a pull request titled `perf(dashboard): stream publish-dashboard.sh's remaining
full-log jq reads instead of slurping`, closing agent-ops#982 with a closing keyword for the
call sites it covers, and updating agent-ops#1649 with a comment on what remains if
`item_lifecycle_fold` is left for a follow-up.
```

## Prompt for R-11 — Resolve the memory-cgroup unbounded/livelocked remediation gap

**Bundles:** R-11 only · **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: `lib/memory.sh`'s `memory_cgroup_verdict` is read hourly by `scripts/doctor.sh` and
published to the dashboard and Pipeline Monitor digest automatically. Despite that, agent-ops#1569
(open) records a live node with no parent memory ceiling (`memory.high: max`) and
`oom_kill_count: 12` — three separate autonomous-pipeline sessions investigated across
2026-09-15–2026-09-19 and each concluded the only known fix, `scripts/cgroup-parent-setup.sh`,
requires host-level (`sudo`) access no container in this architecture has. agent-ops#1639 (open,
separately) shows that script's own documented default configuration produces the exact
`livelocked` shape its sibling code warns about. No pager invariant (`lib/pager-invariants.sh`)
exists for a sustained unbounded/livelocked verdict.

Goal: this recommendation names two possible directions and asks you to make a scoped, well-
reasoned choice rather than attempting a full architectural change unsupervised — this is a real
isolation-posture trade-off the maintainer should weigh in on for the larger piece.

1. **Do first (small, independent, safe):** fix agent-ops#1639's self-inconsistency —
   `scripts/cgroup-parent-setup.sh`'s documented default should not produce the failure shape its
   own sibling code (`lib/memory.sh`) warns about. Read both files, understand why the default
   collides, and either correct the default or update the script's own header/`--check` output to
   say so explicitly if a behavioural change isn't safe to make unilaterally.
2. **Propose, do not silently implement:** add a pager invariant to `lib/pager-invariants.sh` for a
   sustained `unbounded`/`livelocked`/rising-`oom_kill_count` verdict, following that file's
   existing invariant conventions (read several existing invariants first for the pattern). This is
   the lower-risk of the two directions named in agent-ops#1569 (a detection/paging improvement,
   not a privilege escalation) — implement this one.
3. **Do not implement without explicit maintainer sign-off:** giving the pipeline a privileged path
   to apply `cgroup-parent-setup.sh` itself. This was "previously rejected for isolation-posture
   reasons" per the finding — do not build this without a maintainer comment on agent-ops#1569
   explicitly approving it. If you believe it's the right call, say so in a comment on that issue
   and stop there.

Constraints: do not grant the pipeline any new host-level/privileged capability as part of this
task. Do not weaken `memory_cgroup_verdict`'s detection logic while adding the paging path — the
detection has already been hardened through three prior incidents; the goal here is escalation, not
re-detection.

Verification: for the #1639 fix, confirm the corrected default (or the corrected documentation)
against the specific failure shape agent-ops#1639 describes. For the pager invariant, run
`./scripts/run-tests.sh pager-invariants` and confirm your new invariant is covered by a test
asserting it fires on a sustained bad verdict and stays silent on a transient one. Run
`./scripts/lint-shell.sh` and confirm it's clean.

Work cost-consciously. The #1639 fix and the pager-invariant addition are both ordinary
implementation against an existing pattern — suits a mid-cost tier. The privileged-access question
is explicitly out of scope for autonomous implementation per the constraint above.

Deliverable: a pull request titled `fix(memory): correct cgroup-parent-setup.sh's self-
inconsistent default and add a paging invariant for sustained unbounded/livelocked verdicts`,
closing agent-ops#1639 with a closing keyword, referencing agent-ops#1569 (not closing it — the
underlying remediation-access question remains open pending the maintainer's decision).
```

## Prompt for R-12 — Keep decomposing stage-orchestration god functions and extend the fix to new entry points before they grow further

**Bundles:** R-12 only · **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: this codebase has an established, proven pattern for decomposing an oversized stage-
orchestration function into a family of smaller named helpers plus a thin orchestrator — see
`maybe_run_refiner`'s decomposition in `lib/refinement.sh` (closed via PR #1258, closing
agent-ops#964) as the reference example, and `review-cycle.sh`'s overall shape (a short top-level
flow handing off into `lib/`) as the reference for a whole *entry point*, not just one function.
This review (agent-ops#1756, open, filed this run) found the pattern needs applying in three
places:

1. `run_standdown_checks` (`lib/standdown.sh`) — currently ~936 of the file's 957 lines.
2. `compute_skip_lists` (`lib/candidate-gather.sh`) — currently ~786 of the file's 1,433 lines.
3. `monitor-cycle.sh` — a newer entry point (added after the pattern was already established
   elsewhere) whose two large undecomposed top-level regions should be split out into `lib/`
   functions the way `review-cycle.sh` already does, rather than left as flat top-level script.

Also: agent-ops#1256 (open) currently names `coordinator_corroborate_retry_or_fallback`, a function
that no longer exists in the tree — it was superseded by two smaller functions
(`coordinator_merge_candidates`, `coordinator_corroborate_and_fallback` in
`lib/stage-attempt.sh`) as part of an unrelated redesign (PR closing #1560). Close or retitle
#1256 to reflect this before starting new work, so the tracker doesn't carry stale text forward.

Goal: pick **one** of the three decomposition targets above to actually implement in this task
(attempting all three in one PR would make review harder and risks conflicts across files with
independent owners — do one well rather than three superficially; state in your PR description
which one you chose and why, and note the other two remain for follow-up PRs). For your chosen
target, extract cohesive sub-responsibilities into separate, clearly-named functions (mirroring
`maybe_run_refiner`'s `_refiner_*` naming convention, or `review-cycle.sh`'s existing
lib-delegation shape for the `monitor-cycle.sh` option), leaving a short orchestrator that calls
them in sequence. Preserve behaviour exactly — this is a refactor, not a rewrite.

Constraints: do not change any function's external behaviour or the config/state contract it reads
or writes. If you choose `monitor-cycle.sh`, do not change `docs/MONITOR-PIPELINE-SPEC.md`'s
described behaviour — only its code's internal shape; if the spec needs an update purely to
reflect new internal function names it references, do that in the same PR per AGENTS.md's rule
that a spec/code change lands together.

Verification: run the full existing test file(s) covering your chosen target
(`test/standdown*.test.sh`, `test/candidate-gather*.test.sh`, or `test/monitor-cycle*.test.sh` as
applicable) before and after your change and confirm identical pass/fail results — a refactor
changing test outcomes is a red flag, not progress. Run `./scripts/lint-shell.sh` and confirm it's
clean. If you can measure it, report the before/after top-level-undecomposed-line-count for your
chosen file in the PR description, the way this review's own findings measured it.

Work cost-consciously. Decomposition refactors of orchestration-critical code (these functions run
in the hourly production pipeline) deserve a high-capability pass for the actual restructuring and
its review — a wrong extraction that subtly changes evaluation order or error-handling could break
a live pipeline. Delegating test-running/verification legwork to a lower-cost subagent is fine once
the refactor itself is done; do not delegate the refactor's design.

Deliverable: a pull request titled with Conventional Commits format naming your chosen target
(e.g. `refactor(standdown): decompose run_standdown_checks into named helpers`), referencing
agent-ops#1756 (closing it only once all three targets it names are eventually done — likely across
several PRs, so reference rather than close on the first one unless you're confident this PR alone
resolves the whole issue). Separately, a small PR closing/retitling the stale agent-ops#1256.
```

## Prompt for R-13 — Add `openssl` to `doctor.sh`'s toolchain check

**Bundles:** R-13 only · **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: `scripts/doctor.sh`'s Toolchain check iterates a list of required tools (search for
`for tool in bash jq git curl perl python3 rsync flock timeout`) plus individual checks for `gh`,
`claude`, and `shellcheck`. `openssl` is missing from this list despite `lib/approver-token.sh`
hard-depending on it (RS256-signing the Pullwright Approver App's JWT) whenever `merge_autonomy` is
configured above `human`. `deploy/docker/Dockerfile` already installs `openssl` deliberately for
this exact reason (its own comment names `lib/approver-token.sh`). Tracked as agent-ops#1147
(open).

Goal: add an `openssl` check to `scripts/doctor.sh`'s toolchain section, following the same pattern
as the existing individual checks for `gh`/`claude`/`shellcheck` (read those first). Gate the
check's *severity* (warning vs. hard failure) on whether any configured `merge_autonomy` source in
the current `config.json` is above `human` — if none is, a missing `openssl` shouldn't block
`doctor.sh`, since nothing on the current configuration actually needs it yet. Read
`lib/approver-token.sh` or `config.schema.json`'s `merge_autonomy` definition to find the existing
helper (if any) for checking whether the configured autonomy level requires Approver-App
credentials, and reuse it rather than re-deriving the condition.

Constraints: do not change any other toolchain check's behaviour. Do not make the check
unconditionally fail `doctor.sh` regardless of configuration — that would be a false positive for
every installation still at `merge_autonomy: human`.

Verification: run `scripts/doctor.sh --help` to confirm the tool still runs and its flag handling
is unaffected. Add or extend a test in `test/doctor.test.sh` covering both cases: `openssl`
missing with autonomy above `human` (should warn/fail per whatever severity you chose) and
`openssl` missing with autonomy at `human` (should not warn). Run `./scripts/run-tests.sh doctor`
and confirm it passes. Run `./scripts/lint-shell.sh` and confirm it's clean.

Work cost-consciously. This whole task suits a low-cost tier — it's a small, well-specified
addition following an existing, directly-adjacent pattern in the same file.

Deliverable: a pull request titled `fix(doctor): check for openssl when merge_autonomy needs the
Approver App`, closing agent-ops#1147 with a closing keyword.
```

## Prompt for R-14 — Fix `redact_add_literal`'s placeholder escaping and newline-secret visibility

**Bundles:** R-14 (both fixes — same function, same file, same PR review round that surfaced both)
· **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: `lib/redact.sh`'s `redact_add_literal` function (search for its definition) has two known,
already-filed gaps. First (agent-ops#1741, open): it escapes its `VALUE` argument for the *pattern*
side of a `sed` substitution (`s#PATTERN#PLACEHOLDER#g`) via `_redact_escape_literal`, but splices
`PLACEHOLDER` into the *replacement* side unescaped — an unescaped `&` in a future custom
placeholder would expand to the full matched string (pasting the secret back), and an unescaped
`\`/`#` could corrupt the shared `REDACT_SED_ARGS` rule set. Not exploitable today since both
current callers use the default placeholder. Second (agent-ops#1730, open): the function correctly
refuses to register a newline-bearing secret (`[[ -n "$value" && "$value" != *$'\n'* ]] || return
0` — a single `-e` sed rule can't span an embedded newline without breaking every other rule), but
this refusal produces no warning anywhere, so a caller can't tell "nothing to redact" from
"something was silently skipped."

Goal:
1. Escape `PLACEHOLDER` the same way `VALUE` already is (via `_redact_escape_literal` or an
   equivalent escaping pass covering `&`, `\`, and the delimiter character `#`) before it's
   spliced into the sed replacement side.
2. When the newline-guard refuses a value, emit a visible warning (to stderr, following this
   file's or its callers' existing logging convention — check `lib/log-event.sh` for whether this
   should be a structured log event or a plain stderr line, matching how other refusals in this
   codebase are surfaced) rather than a silent `return 0`.

Constraints: do not change the newline-refusal's actual behaviour (still refuse to register a
newline-bearing secret — that refusal is correct, only its silence is the problem). Do not change
either current caller's invocation (`scripts/state-sync.sh`, `scripts/publish-dashboard.sh`) unless
the new warning path requires a caller to handle a new return value.

Verification: add test cases to a redaction test file (following R-17's guidance if that
recommendation has already landed — a dedicated `test/redact.test.sh` — or to
`test/state-sync.test.sh` if not yet split out) covering: a placeholder containing `&` no longer
leaks the secret; a newline-bearing value now produces a visible warning and is still not
registered. Run the relevant test file via `./scripts/run-tests.sh` and confirm both pass. Run
`./scripts/lint-shell.sh` and confirm it's clean.

Work cost-consciously. This whole task suits a low-cost tier for the newline-warning half
(mechanical, add a log line); the placeholder-escaping half touches secret-redaction correctness
directly — verify it carefully (a wrong escape could itself defeat redaction) even though the fix
is small, and consider a second look at the diff before merging given the security-sensitivity of
this exact function.

Deliverable: a pull request titled `fix(redact): escape redact_add_literal's placeholder and warn
on a skipped newline-bearing secret`, closing both agent-ops#1741 and agent-ops#1730 with closing
keywords.
```

## Prompt for R-15 — Harden `san()` (`lib/claim-key.sh`) against a bare `..` path segment

**Bundles:** R-15 only · **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: `lib/claim-key.sh`'s `san()` function (`san() { local s="$1"; printf '%s'
"${s//\//__}"; }`) replaces `/` with `__` but does not explicitly reject a bare `.` or `..` input.
Today this is safe only because every current caller (`lib/claim.sh`'s `registry_path()`,
`scripts/sweep-orphan-branches.sh`'s equivalent) happens to append a filename suffix (`.json`)
immediately after calling `san()`, so a bare `..` resolves to a harmless filename like `...json`
rather than a traversal — the safety property is an accident of caller discipline, not a guarantee
`san()` itself makes. Tracked as agent-ops#1172 (open since the 2026-08-31 review).

Goal: make `san()` itself reject or neutralise a `.`/`..` input, so the safety property holds
independently of what a caller does with the result afterward. Read both current call sites first
to confirm your fix doesn't change their behaviour for any currently-valid input (branch names,
issue-number-derived keys, etc.) — only the `.`/`..` edge case should change.

Constraints: do not change `san()`'s existing `/`→`__` substitution behaviour for any other input.
Keep the fix in `lib/claim-key.sh` (the function's current, already-deduplicated home) — do not
reintroduce a second copy in either caller.

Verification: add test cases to whichever test file already covers `san()` (check
`test/claim-key.test.sh` or search for existing `san()` assertions) covering a bare `.` input, a
bare `..` input, and a normal branch-name-shaped input (to confirm no regression). Run
`./scripts/run-tests.sh claim claim-key sweep-orphan-branches` (or whichever test files actually
exercise `san()` and its callers) and confirm all pass. Run `./scripts/lint-shell.sh` and confirm
it's clean.

Work cost-consciously. This whole task suits a low-cost tier — it's a small, well-specified
function hardening with a clear, narrow edge case to test.

Deliverable: a pull request titled `fix(claim-key): reject a bare . or .. in san()`, closing
agent-ops#1172 with a closing keyword.
```

## Prompt for R-16 — Deduplicate `cfg()` between `lib/claim.sh` and `scripts/sweep-orphan-branches.sh`

**Bundles:** R-16 only · **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: `lib/claim.sh` and `scripts/sweep-orphan-branches.sh` each define an identical local
`cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG" 2>/dev/null; }` — but this already differs from the
shared `lib/config-access.sh`'s own `cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG"; }` (no `2>/dev/null`
suppression). Both files already source `lib/claim-key.sh` for `san()` (added by the PR that
deduplicated exactly this pair of files' `san()` definition, agent-ops#967) but that PR didn't
touch `cfg()`, leaving this duplicate-and-already-diverging copy behind. Tracked as new issue
agent-ops#1755 (open, filed this run).

Goal: make both `lib/claim.sh` and `scripts/sweep-orphan-branches.sh` source `lib/config-access.sh`
and use its shared `cfg()`, removing their local definitions — unless you find a concrete reason
either caller actually relies on the `2>/dev/null` suppression (e.g. a call site that expects a
malformed-JSON lookup to silently return empty rather than emit a `jq` error to stderr) — in that
case, instead add a one-line comment on each local `cfg()` explaining why it deliberately differs
from the shared version, following this codebase's existing convention of documenting deliberate
divergences.

Constraints: do not change `lib/config-access.sh`'s own `cfg()` definition. If you do find a real
behavioural dependency on the `2>/dev/null` suppression, do not silently change it to match the
shared version — that could mask a real error in a way a caller currently doesn't expect.

Verification: run `./scripts/run-tests.sh claim sweep-orphan-branches` and confirm all existing
tests pass unchanged. Grep both files afterward to confirm no local `cfg()` definition remains (or,
if you chose the comment-only path, that the comment is present and accurate). Run
`./scripts/lint-shell.sh` and confirm it's clean.

Work cost-consciously. This whole task suits a low-cost tier — it's a small, mechanical
deduplication following a pattern (`san()`'s own dedup, same two files) already proven in this
exact codebase.

Deliverable: a pull request titled `refactor(claim): source the shared cfg() instead of a
local, already-diverging copy`, closing agent-ops#1755 with a closing keyword.
```

## Prompt for R-17 — Close small test-coverage gaps

**Bundles:** R-17 (three related test-coverage gaps, small enough to address together — `git-
identity.sh` coverage tracked separately from the `redact.sh`/`publish-dashboard.sh` gaps but all
are "add a missing, well-specified unit test" work of the same shape) · **Run after:** no
prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: three test-coverage gaps, all straightforward additions against existing, well-understood
code:
1. `lib/git-identity.sh`'s sole function, `require_git_identity`, is called by both
   `agent-cycle.sh` and `review-cycle.sh` but has no test file anywhere (agent-ops#1148, open).
2. `lib/redact.sh` — the module solely responsible for keeping secrets out of mirrored/published
   state, and the subject of two fix commits in this review's own window — has no dedicated test
   file; its shape-matching rules and `redact_add_literal`'s behaviour are exercised only as a side
   effect of `test/state-sync.test.sh`'s integration tests (tracked as new issue agent-ops#1757,
   filed this run).
3. Commit `5284c02` added `redact_add_literal "$notify_webhook_url"` to
   `scripts/publish-dashboard.sh` (search for that call) for the same defensive reason as its
   change to `scripts/state-sync.sh` in the same commit, but only `test/state-sync.test.sh` gained
   a matching regression test — `test/publish-dashboard.test.sh` has no assertion that the
   configured webhook URL is actually masked in the dashboard's own output (also part of
   agent-ops#1757).

Goal:
1. Create `test/git-identity.test.sh` asserting `require_git_identity`'s behaviour — read
   `lib/git-identity.sh` in full (it's short, 29 lines) and both call sites to understand what
   correct behaviour looks like (what it checks, what it does when the check fails), then write
   assertions covering both the success and failure paths, following this repository's existing
   test-file conventions (read a comparably-scoped existing test file, e.g.
   `test/config-access.test.sh` if it exists, for the header/structure convention to match).
2. Create `test/redact.test.sh` asserting each of `lib/redact.sh`'s shape rules
   (`gh[pousr]_…`/`github_pat_…`/`sk-(ant-|proj-)?…`/`Bearer …`/`token …`) redacts correctly in
   isolation, plus `redact_add_literal`'s registration/escaping behaviour, independent of any
   state-sync or dashboard fixture.
3. Extend `test/publish-dashboard.test.sh` with the same webhook-literal assertion
   `test/state-sync.test.sh` already has (configured `notify_webhook_url` value is masked in the
   dashboard's output; a similarly-shaped-but-different URL is left untouched) — read
   `test/state-sync.test.sh`'s existing assertion for this as your template.

Constraints: do not modify `lib/git-identity.sh`, `lib/redact.sh`, or `scripts/publish-dashboard.sh`
themselves — this is test-only work, adding coverage for existing, already-correct behaviour. If
writing tests surfaces an actual behavioural bug in any of the three, stop and report it rather than
"fixing" it inside what's meant to be a coverage-only PR — file it as a new tech-debt issue instead
per this repository's own tech-debt policy (see AGENTS.md's "Tech debt" section), and note it in
your PR description.

Verification: run `./scripts/run-tests.sh git-identity redact publish-dashboard` and confirm every
new and existing assertion passes. Run `./scripts/lint-shell.sh` and confirm the new test files are
clean.

Work cost-consciously. This whole task suits a low-cost-to-mid-cost tier — writing tests for
already-specified, already-correct behaviour against existing conventions is mechanical, well-
specified work well suited to delegation; a subagent can draft each test file independently in
parallel since the three targets don't overlap, with a quick review pass over all three before
merging.

Deliverable: a pull request titled `test: add coverage for git-identity.sh, redact.sh, and the
publish-dashboard.sh webhook-redaction path`, closing both agent-ops#1148 and agent-ops#1757 with
closing keywords.
```

## Prompt for R-18 — Clean up fixture identity hygiene

**Bundles:** R-18 only · **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: 33 test files plus 1 dashboard-data fixture (`test/fixtures/dashboard-data/merge-
autonomy-kill.json`) use the maintainer's real GitHub usernames (`warwick`, `warwickallen`,
`Warwick-Allen`) as login/actor/assignee fixture values, rather than a synthetic placeholder
identity. This is low-risk (self-referential, already-public GitHub identity) but is real personal
data in a growing number of committed fixtures — the count has grown from ~20 files to 34 as the
test suite has expanded. Tracked as agent-ops#1174 (open).

Goal: find every test fixture using `warwick`/`warwickallen`/`Warwick-Allen` as a login/actor/
assignee value (`grep -rli 'warwick' test/` is a reasonable starting point, then narrow to actual
identity-field usages rather than incidental mentions) and replace them with a consistent synthetic
placeholder identity (e.g. `test-user`/`testuser` — pick one and use it uniformly across every
fixture you touch, so the change is internally consistent).

Constraints: do not change any test's actual assertions or behaviour — only the identity string
used as fixture data. Be careful with fixtures that assert something identity-*specific* (e.g. a
test specifically checking behaviour keyed to the maintainer's own CODEOWNERS entry, self-review
detection, or similar maintainer-identity-dependent logic) — for those, either use a fixture value
that still satisfies the specific property being tested (if the test needs "a CODEOWNERS-listed
identity," pick a synthetic identity and update the corresponding CODEOWNERS-lookup fixture too, so
the test still exercises the real code path) or leave that specific fixture as-is with a comment
explaining why, rather than breaking the test's actual intent for the sake of this cleanup.

Verification: run `./scripts/run-tests.sh` (the full suite, or at minimum every file you touched)
and confirm nothing regresses — a fixture-identity swap should never change a test's outcome unless
that test was specifically depending on the maintainer's real identity (see the constraint above).
Run `./scripts/lint-shell.sh` and confirm it's clean. Re-run the same `grep` search afterward and
confirm the count of remaining real-identity fixture uses has dropped to only the deliberately-kept
exceptions you documented.

Work cost-consciously. This whole task suits a low-cost tier for the bulk of the mechanical
find-and-replace work; the small number of fixtures that need judgement (the maintainer-identity-
dependent ones flagged in the constraint above) deserve a closer look before merging, but there
should be few of them.

Deliverable: a pull request titled `test: replace the maintainer's real GitHub identity in
fixtures with a synthetic placeholder`, closing agent-ops#1174 with a closing keyword.
```

## Prompt for R-19 — Developer-experience polish (`.editorconfig`, scripts index)

**Bundles:** R-19 only · **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: this repository has no `.editorconfig` and no `Makefile`/scripts index — both were
explicitly scoped out of an earlier `--help`-coverage fix (agent-ops#974) with no follow-up filed
until this review (tracked as new issue agent-ops#1758, filed this run). The project's actual
formatting convention (2-space indent, LF line endings) is followed consistently by inspection but
isn't codified anywhere machine-readable; discoverability of the 100 `lib/` and 67 `scripts/` files
rests entirely on each file's own header comment, which is generally good but has no single
index.

Goal: this is optional, low-priority polish — do the `.editorconfig` addition (cheap, unambiguous)
and treat the scripts index as a stretch goal only if it fits comfortably in scope.
1. Add a root `.editorconfig` codifying the observed convention: 2-space indent for `.sh`/`.md`/
   `.json`/`.yml` files, LF line endings, UTF-8, a final newline, trimmed trailing whitespace
   (matching what `npm run check`/the trailing-whitespace CI gate already enforces — read that
   gate's actual rule first so `.editorconfig` doesn't contradict it).
2. **Stretch goal, only if time permits:** a generated scripts index (e.g. a `scripts/README.md`
   or a section in the root `README.md`, extracted from each script's first-comment-block), mirroring
   `scripts/render-toc.sh`'s existing "generate from source" pattern rather than a hand-maintained
   list that will drift. If you attempt this, it must be a generated region with a `--check` mode
   following the exact convention `scripts/render-toc.sh`/`scripts/render-config-table.sh` already
   establish (see `AGENTS.md`'s "Generated regions" section) — do not hand-write a static list that
   will immediately start drifting.

Constraints: do not change any existing file's actual formatting to match the new
`.editorconfig` — this task only adds the convention file; a separate reformatting pass (if ever
needed) is out of scope here and would be a much larger, riskier diff.

Verification: confirm `.editorconfig`'s rules don't contradict `./scripts/lint-shell.sh`'s own
checks or the trailing-whitespace CI gate — run both against the current tree and confirm they
still pass (they should, since you haven't reformatted anything). If you built the scripts-index
generator, run its `--check` mode and confirm it matches the current tree.

Work cost-consciously. This whole task suits a low-cost tier — `.editorconfig` is a static,
well-understood file with no design judgement; the stretch-goal generator, if attempted, should
follow an existing in-repo pattern closely enough that it also suits a low-to-mid-cost tier.

Deliverable: a pull request titled `chore: add .editorconfig` (and, if attempted, a generated
scripts index), closing agent-ops#1758 with a closing keyword. If the scripts index
proves more involved than expected, land `.editorconfig` alone and leave the index as a
comment on the issue for a future pass, rather than blocking the small win on the larger one.
```

## Prompt for R-20 — Decompose the dashboard's `renderBody()`; keep an eye on `publish-dashboard.sh`/`doctor.sh`'s growth

**Bundles:** R-20 (the `renderBody()` fix is the actionable part; the other two files are
explicitly a "watch, don't act yet" verdict — bundled because they're the same underlying
"is this file's flatness/size still proportionate" judgement, made together in this review)
· **Run after:** no prerequisites

```text
You are working in Pullwright/agent-ops, a self-hosted Bash pipeline. Read AGENTS.md at the repo
root first.

Context: `dashboard/index.html`'s `renderBody()` function has grown from 462 to ~538 lines across
two consecutive project reviews despite being flagged both times — it is now roughly 3.5x the size
of the next-largest function in the file (`landingsPanel()`, ~153 lines). Tracked as agent-ops#1173
(open). The file already has an established convention for panel-sized functions (search for
`Panel()` — e.g. `landingsPanel()`) that `renderBody()` itself doesn't follow; it renders every
dashboard banner inline instead.

Goal: extract `renderBody()`'s distinct banner groups (read the function in full first to identify
the natural groupings — it likely renders several independent status banners/sections in sequence)
into their own named functions, following the file's existing `*Panel()` naming and structure
convention, leaving `renderBody()` itself as a short function that calls each extracted piece in
order.

Constraints: do not change the dashboard's rendered output or behaviour — this is a pure
refactor. Preserve exact DOM structure/content for every banner; a visual diff (even done manually
by comparing rendered output before/after in a browser, if `scripts/open-dashboard.sh`/
`scripts/serve-dashboard.sh` gives you a way to do that in your environment) is the strongest
verification available for a UI file like this one. Do not attempt to also address
`scripts/publish-dashboard.sh` or `scripts/doctor.sh`'s own growth as part of this task — both were
judged "no urgent action yet" by this review (neither is on the hourly hot path, both have
dedicated test coverage) and are explicitly out of scope here; revisit them only if their own
change frequency rises enough to warrant it independently.

Verification: run `./scripts/run-tests.sh dashboard-render` (or whichever test file(s) cover
`dashboard/index.html`'s rendering) and confirm every existing assertion passes unchanged — a
refactor that changes test outcomes here means the extraction altered behaviour, which it must
not. If you have a way to render the dashboard in this environment (`scripts/serve-dashboard.sh`/
`scripts/open-dashboard.sh`), visually spot-check a few of the extracted banner sections before
and after. Run `./scripts/lint-shell.sh` — likely unaffected since this is an HTML/JS file, but
confirms nothing else broke.

Work cost-consciously. This whole task suits a mid-cost tier — it's a mechanical extraction
following an existing in-file convention (`*Panel()`), with low design ambiguity, but UI-rendering
code benefits from careful before/after verification given the checklist above notes automated
testing alone may not catch a subtle visual regression.

Deliverable: a pull request titled `refactor(dashboard): decompose renderBody() into named banner
functions`, closing agent-ops#1173 with a closing keyword, and updating
`docs/DASHBOARD-SPEC.md` if it references `renderBody()`'s internal structure anywhere (check
first).
```
