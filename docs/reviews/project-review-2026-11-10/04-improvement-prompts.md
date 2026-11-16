# Improvement prompts

One prompt per recommendation, in priority order (severity first, then effort). Each prompt is
self-contained and may be pasted into a fresh AI agent session with no other context. No
ordering dependency exists between any two prompts below except where a prompt's **Run after**
line says otherwise.

## Prompt for R-01 — Close the Vercel-secret redaction coverage gap

**Bundles:** R-01 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops is a Bash-based operations pipeline for an autonomous
coding-agent fleet. It transcripts its own agent sessions and mirrors state to an external
repository, so any secret that reaches either path leaks for real. `scripts/preview-deploy.sh`
deploys preview builds to Vercel and reads two credentials: `VERCEL_TOKEN` (used directly in an
`Authorization: Bearer` header, currently around line 281) and
`VERCEL_AUTOMATION_BYPASS_SECRET` (read into a `bypass` variable around line 306, used at later
call sites). `lib/redact.sh` provides `redact_add_literal`, a function that registers a literal
string for scrubbing before content reaches a transcript or the state-mirror push; it is already
called for `notify_webhook_url` in `scripts/state-sync.sh` and `scripts/publish-dashboard.sh`.
Neither Vercel credential is currently registered anywhere in the repository — confirm this
yourself with `grep -rn "redact_add_literal" --include="*.sh" .` and `grep -n "VERCEL"
scripts/preview-deploy.sh` before starting.

The problem: because neither credential is registered with `redact_add_literal`, either one
reaching a transcript or the external state-mirror push passes through completely unmasked.
This project has already had one real incident of exactly this kind (a different credential
pair leaked into a transcript and had to be rotated) — this is the same mechanism, for a
credential class that incident didn't cover.

The goal (acceptance criteria):
1. `scripts/preview-deploy.sh` calls `redact_add_literal` for both `VERCEL_TOKEN` and
   `VERCEL_AUTOMATION_BYPASS_SECRET` at the point each is read into a shell variable, following
   the exact pattern the `notify_webhook_url` call sites already use.
2. `test/redact.test.sh` gains test cases exercising `lib/redact.sh`'s six fixed-shape
   `REDACT_SED_ARGS` rules (currently around lines 20-26) against a matching example each, and
   a test for `redact_add_literal`'s newline no-op behaviour (currently around lines 68-72) —
   none of this is currently tested at all, so write these as new tests, not modifications.
3. `docs/DATA-HANDLING.md`'s "Redaction for screenshots" paragraph (currently around lines
   141-143) is corrected so it no longer implies the dashboard-screenshot redaction pass and the
   mirror-push redaction pass (the one this fix extends) have the same coverage — name them as
   two distinct passes with distinct scope.

Constraints: do not change `redact_add_literal`'s signature or behaviour, only its call sites
and test coverage. Do not touch the `notify_webhook_url` call sites beyond using them as the
pattern to follow. Match this repository's existing Bash style (no new dependencies, no new
abstractions beyond what's needed).

Verification: run `./scripts/run-tests.sh redact` (or the project's documented equivalent) and
confirm the new test cases pass and the existing ones still pass. Manually trace that
`scripts/preview-deploy.sh`'s two credential variables are registered before any code path that
could print them. Run `./scripts/check-docs.sh` to confirm the documentation change doesn't
violate the size budget or any generated-region rule.

Work cost-consciously. Where your environment supports subagents, delegate well-specified,
self-contained subtasks to subagents running the lowest-cost model tier that has a high
probability of completing the subtask correctly at the first attempt. Writing the new
`test/redact.test.sh` cases (mechanical, pattern-following) suits a low-cost tier; the
`preview-deploy.sh` registration itself and the `DATA-HANDLING.md` wording fix should be done
or reviewed at a mid-to-high-capability tier, since getting the registration point wrong
(e.g. registering after a code path that already echoed the value) would defeat the whole fix.
Verify all delegated work before integrating it.

Deliverable: a single commit/PR (title in Conventional Commits format, e.g. `fix(deploy): redact
Vercel credentials from transcripts and the state mirror`) containing the code fix, the new
tests, and the documentation correction together — per this repository's own convention, land a
fix and its regression guard in the same change. Closes agent-ops#1752 and agent-ops#1757.
```

## Prompt for R-02 — Bound the rest of `do_push`; add a bounded DNS-failure retry

**Bundles:** R-02 only (F-OPS-02 and F-OPS-05 are fixed together since a retry on an unbounded
call would itself need a deadline) · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops's `scripts/state-sync.sh` mirrors fleet state to an external
repository on a schedule across multiple nodes. Its `do_push()` function (currently around
lines 1046-1321) takes a cross-node `mirror_lock` and then runs several steps: a `git fetch`
(line ~1071), two `rsync -a --delete` passes (lines ~1077-1078 and ~1099-1100), a
`redact_mirror_files` call, and a final `mirror_write push` (line ~1319, which plainly calls
`git -C "$mirror" "$@"` via `mirror_write()` around line 736). Only the `redact_mirror_files`
step is wrapped in a deadline, via the existing `mirror_run_with_deadline "$push_deadline_seconds"
redact_mirror_files "$mirror"` call. This project has already suffered a real, multi-hour,
fleet-wide incident from exactly this unbounded-step pattern: a push holding `mirror_lock`
indefinitely made every other node's fetch unable to distinguish "another push is in progress"
from "a node died mid-push."

The problem: the `git fetch`, both `rsync` passes, and the final push all still run with no
deadline — any one of them hanging (a stuck network call, a stalled or full-disk `rsync`) can
wedge the shared `mirror_lock` for an unbounded time, exactly reproducing the prior incident.
Separately, a transient DNS/proxy failure on the fetch or push currently has no retry, so it
fails silently and permanently for that cycle.

The goal (acceptance criteria):
1. The `git fetch`, both `rsync` calls, and the final `mirror_write push` inside `do_push()` are
   each wrapped in `mirror_run_with_deadline`, budgeted against the time remaining in
   `push_deadline_seconds` (not simply re-granted the full budget each — the four steps must
   share one overall deadline the way `redact_mirror_files` already respects it).
2. A transient DNS/proxy failure on the fetch or the final push triggers a bounded retry (2-3
   attempts, short backoff) rather than ending the cycle silently.
3. No step can hold `mirror_lock` past the configured `push_deadline_seconds` overall.

Constraints: do not change `mirror_lock`'s acquisition/release semantics, only what happens
while it is held. Do not change the `rsync` flags' semantics (still `-a --delete`), only add a
deadline around the calls. Preserve existing logging/error-reporting conventions in this file.

Verification: run this project's state-sync test suite (`test/state-sync.test.sh` and any
sibling push/fetch test files) and confirm all pass, including any new tests you add for the
deadline-wrapping and retry behaviour (add tests simulating a hung step timing out within the
deadline, and a transient failure succeeding on retry — this project's existing tests use
process-signal/timing techniques you can follow as a pattern). Read the whole of `do_push()`
after your change and confirm by inspection that no code path between taking and releasing
`mirror_lock` can run unboundedly.

Work cost-consciously. This is a correctness/reliability fix in a shared-lock, fleet-wide-impact
code path — do the design and the deadline-wrapping itself at a high-capability tier, since a
mistake here (e.g. a deadline that's too short and aborts a legitimate slow push, or an
incorrectly-shared budget that double-counts) could cause the exact kind of incident this fix
prevents. Writing the new regression tests for already-specified behaviour can be delegated to a
mid-cost tier. Verify all delegated work before integrating it.

Deliverable: a single commit/PR (e.g. `fix(state-sync): bound do_push's remaining unguarded
steps; add bounded DNS-failure retry`) with the code change and new/updated tests. Closes
agent-ops#1701 and agent-ops#1604.
```

## Prompt for R-03 — Wire `toc` and `spec` into the required-status-check ruleset

**Bundles:** R-03 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops's GitHub repository has a branch protection ruleset on `main`
(ruleset ID 18857310) that lists required status checks a PR must pass before merging. Two CI
workflows, `toc.yml` and `spec.yml`, already run on every pull request (confirm with `gh api
repos/Pullwright/agent-ops/rulesets/18857310` and compare against `.github/workflows/toc.yml`
and `.github/workflows/spec.yml`) but are not in that required-checks list.

The problem: `toc` checks that a guide's table of contents matches its headings; `spec` checks
that every requirement-label citation in the repository resolves and doesn't collide
(`scripts/spec.sh check`). Because neither is a required check, a PR can currently merge with a
stale table of contents or a dangling/colliding requirement citation — exactly the defects these
checks exist to catch. `docs/README.md` (around line 506) describes `spec.sh check` as a
"permanent guard," which is not accurate while it isn't required.

The goal: this is an owner-only account-settings change (a GitHub repository ruleset edit), not
something an agent's own credentials can perform — editing branch protection rules is reserved
for the repository owner. Do not attempt to call the GitHub API to change the ruleset yourself.

Deliverable: do not open a pull request for this recommendation. Instead, produce a short,
precise instruction for the repository owner: "In GitHub, go to Settings → Rules → Rulesets →
the ruleset covering `main` (ID 18857310) → edit its required status checks → add `toc` and
`spec` to the list → save." If your environment lets you message or notify the owner directly,
do so with exactly that instruction; otherwise, state it as your final output so a human can
act on it. Do not mark this recommendation complete until the owner confirms the ruleset change
is live (re-check with `gh api repos/Pullwright/agent-ops/rulesets/18857310` afterward — both
`toc` and `spec` should appear in the required-status-checks list).

Work cost-consciously: this whole task is a short lookup-and-notify; it suits a low-cost tier
end to end.
```

## Prompt for R-04 — Paginate `publish-dashboard.sh`'s open-issues fetch

**Bundles:** R-04 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops's `scripts/publish-dashboard.sh` builds a local monitoring
dashboard. Around line 3368, it fetches open issues for the dashboard's Priority display with
`gh_call api "repos/$slug/issues?state=open&per_page=30"` — no `--paginate` flag, so it silently
truncates at 30 issues. This repository's real open-issue count is over 600, so the Priority
display is currently missing the vast majority of open issues.

The problem: a reader of the dashboard's Priority section sees at most 30 of 600+ open issues,
with no indication that the list is truncated.

The goal (acceptance criteria): either (a) the fetch uses `--paginate` (or an equivalent
multi-page fetch idiom already used elsewhere in this codebase — check `lib/approver.sh` or
`lib/enabler.sh` for the established pattern of consuming `gh api --paginate`'s NDJSON output)
so the Priority display reflects the true open-issue set, or (b) if a full fetch is judged too
expensive for a per-tick read (profile it first), add an explicit, documented cap with a visible
"N of M" indicator in the rendered dashboard so a reader knows the list is incomplete and by how
much.

Constraints: match the existing `gh_call`/pagination idiom already used elsewhere in this file
or in `lib/`, don't invent a new one. Preserve the dashboard's existing rendering structure;
change only the data-fetch and (if option (b)) the displayed count, not the layout.

Verification: run the dashboard's test suite (`test/publish-dashboard.test.sh`) and confirm it
passes, adding a test that asserts the fetch is no longer capped at 30 (or, for option (b), that
the displayed count accurately reflects the true total). Manually run
`./scripts/publish-dashboard.sh --no-github --fast` (or the project's documented dry-run mode)
and inspect the generated dashboard's Priority section.

Work cost-consciously: this is a small, mechanical, well-specified fix suited to a low-cost
tier; delegate the test-writing similarly, reserving your own attention for picking between
options (a) and (b).

Deliverable: a single commit/PR (e.g. `fix(dashboard): paginate the open-issues fetch for the
Priority display`). Closes agent-ops#1171.
```

## Prompt for R-05 — Fix `publish-dashboard.sh`'s `--help` swallowing; add `--help` to `monitor-cycle.sh`

**Bundles:** both fixes bundled since they are the same defect class (missing/swallowed
`--help`) in two sibling entrypoints, already tracked by one issue · **Run after:** no
prerequisites

```text
Context: Pullwright/agent-ops has several CLI entrypoints: `agent-cycle.sh`,
`review-cycle.sh`, `scripts/doctor.sh`, `scripts/publish-dashboard.sh`, and `monitor-cycle.sh`.
The first three already handle `--help`/`-h` correctly, printing usage text and exiting 0.

The problem (reproduce both live before fixing): running
`./scripts/publish-dashboard.sh --help --no-github --fast` currently prints no usage text and
runs a full dashboard publish to completion instead — its flag-parsing loop (currently around
line 208) ends in a bare `*) shift ;;` catch-all that silently swallows an unrecognized
`--help`. Running `./monitor-cycle.sh --help` currently exits 64 with "unknown argument: --help"
on stderr — loud, but it never prints usage text, because there is no `-h`/`--help` case in its
flag parser at all.

The goal (acceptance criteria):
1. `./scripts/publish-dashboard.sh --help` prints usage text and exits 0, without running a
   publish.
2. `./monitor-cycle.sh --help` prints usage text and exits 0.
3. Both scripts' usage text matches the style and level of detail already used by
   `agent-cycle.sh --help` / `review-cycle.sh --help` / `scripts/doctor.sh --help` — read one of
   those as the pattern to follow.

Constraints: do not change any other flag's behaviour in either script. Add an explicit
`-h|--help)` case; do not simply special-case the catch-all.

Verification: run `./scripts/publish-dashboard.sh --help` and `./monitor-cycle.sh --help`
yourself and confirm usage text prints and exit code is 0 in both cases. Run each script's test
suite and confirm no regression; add a test asserting the `--help` behaviour for each if none
exists yet.

Work cost-consciously: mechanical, pattern-following work; suits a low-cost tier end to end.

Deliverable: a single commit/PR (e.g. `fix(cli): add --help handling to publish-dashboard.sh
and monitor-cycle.sh`). Closes agent-ops#1753.
```

## Prompt for R-06 — Re-file/execute the coverage-tooling decision

**Bundles:** R-06 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops has 281 Bash test files run via `./scripts/run-tests.sh`, but no
coverage-measurement tooling exists — confirm with `grep -n "coverage\|kcov\|bashcov"
scripts/run-tests.sh` (currently returns nothing).

The problem: with 281 test files and no coverage signal, there is no mechanical way to tell
"exercised" from "never tested" beyond manual inspection.

The goal: evaluate whether `kcov` (or an equivalent Bash coverage tool) is viable against this
project's test harness. If it is viable, add a `--coverage` flag to `scripts/run-tests.sh` and
an initial, even generous, coverage floor, following the ratcheted-floor pattern this repository
already uses for documentation size budgets (see `scripts/docs-size-ratchet.tsv` and
`scripts/check-docs.sh` for the pattern to mirror — a floor that can only tighten, never loosen,
over time). If it is not viable (e.g. `kcov` doesn't instrument Bash reliably in this project's
environment), document that conclusion and close the investigation rather than leaving it open
indefinitely.

Constraints: do not change existing test behaviour or `run-tests.sh`'s other flags. If adding
`kcov`, do not make it a required dependency for running tests without coverage — `--coverage`
should be opt-in.

Verification: if you add coverage tooling, run `./scripts/run-tests.sh --coverage` and confirm
it produces a coverage report without breaking the existing `--list`/default test-run paths.
Run the full existing test suite to confirm no regression.

Work cost-consciously: the evaluation and design decision suit a mid-cost tier; if you proceed
with implementation, delegate the ratchet-file setup (mechanical, pattern-following) to a
low-cost tier.

Deliverable: either a commit/PR adding `--coverage` and a floor, or a short written decision
(e.g. as an issue comment) explaining why coverage tooling isn't viable here, so the decision
isn't lost again the way it was when `#1148` closed. Closes agent-ops#2695.
```

## Prompt for R-07 — SHA-pin every Actions `uses:` step

**Bundles:** R-07 only (one mechanical change applied uniformly across all workflow files)
· **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops has 17+ GitHub Actions workflow files under `.github/workflows/`.
Every `uses:` line in every one of them currently references a mutable version tag (e.g.
`actions/checkout@v7`) — confirm with `grep -rhn "uses:" .github/workflows/*.yml | grep -cE
'@[0-9a-f]{40}'`, which currently returns 0.

The problem: a mutable tag can be re-pointed by the action's publisher (deliberately or via
compromise) to different code without the workflow file changing, so a compromised or
re-tagged upstream Action would be pulled automatically into a pipeline that has write access to
a public image registry.

The goal (acceptance criteria): every `uses: owner/action@vN` line across every workflow file in
`.github/workflows/` is changed to `uses: owner/action@<full 40-character commit SHA> # vN`
(keeping the version as a trailing comment for human readability), where `<full commit SHA>` is
the commit that tag currently points to. Dependabot (already configured for the
`github-actions` ecosystem in `.github/dependabot.yml`) should continue to propose updates
correctly once pins are SHA-based — confirm this is true for this ecosystem rather than assuming
it.

Constraints: do not change which action or which logical version is used, only how it's
pinned. Do not touch the new Trivy step in `build-image.yml` (it's pulled via a `docker run`
inside a `run:` block, already digest-pinned on its own, and is out of scope for this change).

Verification: after pinning, trigger (or inspect the most recent run of) each workflow and
confirm it still executes successfully — a wrong SHA will fail immediately. Run
`grep -rhn "uses:" .github/workflows/*.yml | grep -cE '@[0-9a-f]{40}'` and confirm it now
matches the total count of `uses:` lines.

Work cost-consciously: resolving each tag to its current commit SHA and rewriting the line is
mechanical and suits a low-cost tier, run across workflow files in parallel subagents if your
environment supports it; have a mid-cost tier spot-check a sample of the resolved SHAs against
the tag they claim to represent before finalizing, since a wrong SHA silently pins the wrong
code.

Deliverable: a single commit/PR (e.g. `ci: SHA-pin every Actions uses: step`). Closes
agent-ops#1918.
```

## Prompt for R-08 — Grant the Reviewer stage CI-log read/rerun access

**Bundles:** R-08 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops's pipeline has several prompt files under `prompts/` that define
what each pipeline stage's AI agent is told to do. `prompts/implementer.md` (around line 308)
documents a route for reading a failing CI run's log: `gh run view --log`. `prompts/reviewer.md`
has no equivalent route — confirm with `grep -n "gh run view\|--log" prompts/reviewer.md`
(currently no matches).

The problem: when the Reviewer stage's agent is handed a pull request with a red CI check, it
has no documented way to read why the check failed, so it cannot diagnose or fix it itself.

The goal (acceptance criteria): `prompts/reviewer.md` documents the same `gh run view --log`
extraction route `prompts/implementer.md` already uses (mirror the wording and context, adapted
to the Reviewer stage's own situation — it's looking at a PR it's already reviewing, not one
it just opened). Where the Reviewer stage's GitHub identity doesn't already have permission to
re-run a failed job, document what's needed to grant it (but first confirm via this project's
credential/permission setup, e.g. `lib/approver-token.sh` or wherever Reviewer-stage credentials
are configured, whether the permission is already implicitly present since it already reads PR
state).

Constraints: do not change `prompts/implementer.md`. Do not grant new credentials without first
confirming the existing ones are actually insufficient — adding unnecessary permissions is
itself a security cost.

Verification: read the updated `prompts/reviewer.md` and confirm it would let an agent following
it extract a failing CI log's content, the same way `prompts/implementer.md`'s route does. If
you determine new credentials are needed, do not grant them yourself — flag the specific
permission gap in your deliverable instead, since credential/permission changes are an
owner-only action per this repository's conventions.

Work cost-consciously: this is a documentation-mirroring task; suits a low-cost-to-mid-cost
tier.

Deliverable: a commit/PR updating `prompts/reviewer.md` (e.g. `docs(prompts): give the Reviewer
stage a CI-log read route`), plus — if a credential gap is found — a clear note of what the
owner needs to grant and why. Closes agent-ops#1496.
```

## Prompt for R-09 — Diagnose and unstick the CHANGELOG roll automation

**Bundles:** R-09 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops has a scheduled automation (added by PR #1842) meant to
periodically open a pull request from a `changelog-roll` branch that assembles `CHANGELOG.md`
entries from merged PR descriptions (see `scripts/assemble-changelog.sh` and the "Documentation
principles" section of `AGENTS.md`/this repo's contributing guide for how the mechanism is
supposed to work). As of this task, it has produced zero such PRs in 48+ days — confirm with
`gh api "search/issues?q=repo:Pullwright/agent-ops+head:changelog-roll" --jq '.total_count'`
(expected: 0) and `git log -1 --format="%H %ad" --date=short -- CHANGELOG.md` (expected: a date
well before the roll mechanism merged). Two known sub-bugs are tracked in issues `#1846` and
`#1848`.

The problem: something is preventing the roll from ever running end-to-end, not just the two
known sub-bugs — fixing those in isolation without first confirming the mechanism actually
*runs* risks leaving the real root cause unexplained.

The goal: trace one full scheduled run of the roll mechanism from its trigger (find the
scheduling configuration — likely a cron entry or GitHub Actions `schedule:` trigger referencing
`scripts/assemble-changelog.sh` or a related script) through to wherever it decides not to open
a PR, or fails to run at all. Read the actual run history (workflow run logs if it's a GitHub
Actions scheduled workflow; otherwise whatever this project's own log/state mechanism records
for scheduled jobs) rather than just reading the two bug reports. Once you understand why it
has never fired, fix that root cause, then apply `#1846`'s and `#1848`'s fixes as well if they
are still independently needed.

Constraints: do not change `CHANGELOG.md`'s own format or the assembly logic's output format,
only what prevents it from running/completing.

Verification: after your fix, either trigger the mechanism manually (if the project has a way to
do so) or wait for its next scheduled run, and confirm a `changelog-roll` PR actually opens with
sensible content. Run this mechanism's own test coverage (if any exists under `test/`) and
confirm it passes.

Work cost-consciously: the end-to-end trace needs genuine investigation and should be done at a
high-capability tier, since symptom-fixing without understanding the root cause has already
failed four times (per the four follow-on fixes already attempted). Once the root cause is
understood, delegate the mechanical fix-application to a mid-cost tier if it's well-specified by
then.

Deliverable: a commit/PR fixing the root cause (and `#1846`/`#1848` if still needed), with a
clear explanation in the PR description of what was actually preventing the roll from running.
Closes agent-ops#1846 and agent-ops#1848.
```

## Prompt for R-10 — Action `#2434`'s dashboard local-tick fix

**Bundles:** R-10 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops's `scripts/publish-dashboard.sh` has a "local tick" (a
non-GitHub-fetching dashboard refresh) that runs roughly eight full `jq` passes over a
fleet-wide log file (`log.jsonl`, 124 MB+ and growing, never rotated by design) on every local
tick — confirm by reading `read_events()` and its callers around line 1188 and the surrounding
per-cycle-summary/cycle-id-scan readers. This is the common-case tick (roughly nine of every ten
launcher windows). GitHub issue `#2434` already documents three candidate fixes in full detail:
(a) recency-suffix reads with a whole-union fallback, (b) bounding the per-cycle summary to only
consumed cycles, or (c) an incremental parse cache.

The problem: every local tick's cost grows linearly with the installation's total log history,
since `log.jsonl` is never rotated — this is a slow-burning scaling problem, not a crisis (the
overall publisher CPU load was already fixed for a related issue), but it keeps climbing in the
background.

The goal: read `#2434` yourself for the full detail of all three candidates, pick the one that
best fits the current code structure (do not re-scope the problem — the issue has already done
that correctly; your job is to execute one of the three), and implement it so the local tick's
per-invocation cost stops growing linearly with total log history.

Constraints: do not change the dashboard's rendered output or the GitHub-fetching tick's
behaviour, only the local tick's internal read strategy. Preserve exact behavioural output
(the dashboard must show the same data, just computed more efficiently).

Verification: benchmark the local tick's wall-clock time before and after your change against a
large synthetic `log.jsonl` (append many cycles' worth of realistic records to a test fixture)
and confirm the after-cost no longer scales linearly with total history size for the common
case. Run `test/publish-dashboard.test.sh` and confirm no regression in output correctness.

Work cost-consciously: implementing one of three already-fully-scoped candidates is
well-specified engineering work; suits a mid-cost tier, with benchmarking/verification done
carefully since a subtle correctness regression in dashboard data would be hard to notice later.

Deliverable: a commit/PR (e.g. `perf(dashboard): bound the local tick's cost independent of
total log history`) with before/after benchmark numbers in the description. Closes
agent-ops#2434.
```

## Prompt for R-11 — Owner check-in on backlog growth; check `#2437`'s `BLOCKED` status

**Bundles:** R-11 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops's GitHub repository has 609 open issues (measure live yourself:
`gh api "search/issues?q=repo:Pullwright/agent-ops+is:issue+is:open" --jq '.total_count'`), 77%
labelled `pw::type:tech-debt`. The repository owner recorded a deliberate, dated decision in
`docs/STANDING-DECISIONS.md` (the 2026-10-16 entry) not to manage this backlog by raw volume,
relying instead on a Priority/Issue-Dependencies ranking mechanism. That mechanism's
implementation, pull request `#2437`, is open, mergeable, but has had `mergeStateStatus:
BLOCKED` for 25+ days (confirm with `gh pr view 2437 --repo Pullwright/agent-ops --json
mergeable,mergeStateStatus,updatedAt`).

The problem: this is not a code defect — it's a visibility gap. No action beyond giving the
owner current, accurate numbers is prescribed by this recommendation, and no pipeline identity
should attempt to resolve PR `#2437`'s blocked status itself, since the reasons something is
decision-blocked at this level are typically a product/roadmap call reserved for the owner.

The goal: surface the current measured numbers (open-issue count, tech-debt-label proportion,
filed:closed ratio since the last measurement, and `#2437`'s specific blocking reason if
discoverable) to the repository owner, and ask specifically what `#2437` is waiting on.

Constraints: do not attempt to unblock, merge, or modify PR `#2437` yourself. Do not file a new
issue or edit `STANDING-DECISIONS.md` — this recommendation's entire scope is informational.

Verification: not applicable — there is no code change to verify. Confirm only that your
message to the owner accurately states the live numbers you measured (re-run the `gh api`
queries above immediately before sending, since these numbers move daily).

Work cost-consciously: this whole task is a live measurement and a short message; suits a
low-cost tier end to end.

Deliverable: a message to the repository owner (via whatever channel this installation uses for
owner-directed communication — check for an existing pattern, e.g. an issue assigned to the
human, per this project's own Enabler-stage convention) stating the current numbers and asking
what `#2437` needs to move forward. Do not open a pull request for this recommendation.
```

## Prompt for R-12 — Fix the spec-split rename-during-split regression; add a mechanical guard

**Bundles:** R-12 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops keeps as-built requirement specifications under `docs/spec/`,
split across numbered files (e.g. `docs/spec/implementation/requirements/the-script-NN.md`).
This project's own written convention (in its contributing guide) says a spec split must never
rename or renumber an existing file — new content goes at the next unused number instead. Commit
`9235549` (PR #2665) violated this: it renamed pre-existing `the-script-10.md` to
`the-script-12.md` and `the-script-11.md` to `the-script-13.md` while inserting new content at
the vacated numbers 10 and 11. This has never been reverted — confirm with `git log --oneline --
docs/spec/implementation/requirements/the-script-10.md` (and `-11.md`, `-12.md`, `-13.md`): no
commit since `9235549` touches any of the four. GitHub issue `#2694` already has a fully-scoped
implementation approach in its own comment thread: a base-ref/head-ref diff check modeled on
`scripts/check-closing-keyword.sh`.

The problem: (1) the renamed files currently carry content under the wrong historical identity,
reintroducing the exact silent-revert-on-concurrent-edit risk the no-rename convention exists to
prevent; (2) no automated check exists to catch a future rename-during-split.

The goal (acceptance criteria):
1. `the-script-10.md` and `the-script-11.md` are restored to their original names with their
   original content (check out the pre-`9235549` version of each from git history); the content
   that commit `9235549` inserted at those numbers instead occupies the next unused numbers in
   that same requirements directory, following the convention correctly (PR #2679 did this
   correctly afterward — use it as a worked example of the right pattern).
2. A mechanical check (read `#2694`'s own comment thread for the suggested approach, and
   `scripts/check-closing-keyword.sh` for the base-ref/head-ref diff pattern to model it on) is
   added — likely to `scripts/check-docs.sh` or a new dedicated script wired into CI — that
   fails a documentation-only spec-split commit which removes a pre-existing path from a spec
   directory while new content with similar heading structure appears elsewhere.

Constraints: do not change the content of any spec file beyond restoring/relocating it correctly
— no wording edits as part of this fix. Any cross-references elsewhere in the repository to the
old (incorrect) `the-script-12.md`/`-13.md` numbering for this content must be updated to point
at the restored/relocated files.

Verification: run `scripts/spec.sh check` (or whatever this project's spec-validation entrypoint
is) and confirm it passes against the corrected file layout. Run `./scripts/check-docs.sh`.
Write a test for the new mechanical guard that constructs a synthetic rename-during-split commit
and confirms the check fails it, plus a test that a correctly-additive split (new numbers only)
passes.

Work cost-consciously: untangling the exact pre-9235549 content and relocating it correctly
needs careful attention — do this part at a mid-to-high-capability tier. Writing the new
mechanical-guard script, once its approach is clear from `#2694`'s own comment, is
well-specified and suits a mid-cost tier.

Deliverable: a single commit/PR (e.g. `fix(docs): revert the spec rename-during-split
regression; guard against recurrence`). Closes agent-ops#2694.
```

## Prompt for R-13 — Decompose the next two fastest-growing god-functions

**Bundles:** both functions bundled since they're being fixed via the same precedent and
pattern established by a just-landed sibling decomposition · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops is a Bash pipeline where several "god functions" — single
functions hundreds to over a thousand lines long, doing many sequential, loosely-related things
— have historically grown without bound until decomposed. The most recent instance,
`lib/standdown.sh`'s `run_standdown_checks`, was just successfully decomposed (pull request
#2707) into 17 small, named `_standdown_*` helper functions, each independently testable, with
`run_standdown_checks()` itself reduced to an 18-line orchestrator that calls each helper in
sequence — read this PR's diff (or the current state of `lib/standdown.sh`) as your model for
the decomposition style to follow.

The problem: two other functions are now growing the fastest in the repository:
`lib/enabler.sh`'s `maybe_run_enabler()` (currently roughly 1,000+ lines) and
`lib/approver.sh`'s `run_approver_stage()` (currently roughly 500+ lines) — both grew
double-digit percentages in the two weeks before this task was written. Confirm current sizes
and line ranges yourself by reading both files before starting, since they will have moved.

The goal (acceptance criteria): decompose each of `maybe_run_enabler` and `run_approver_stage`
into a family of smaller, named helper functions (following the `_standdown_*` naming/structure
precedent), each independently testable, with the original function reduced to a short
orchestrator that calls each helper in sequence. Preserve exact existing behaviour — this is a
pure refactor, not a behaviour change.

Constraints: do not change what either stage does, only how its code is organized. Do not
change either function's external interface (how it's invoked from `agent-cycle.sh`/
`review-cycle.sh`). Match this repository's existing naming conventions (the `_standdown_*`
prefix pattern, or an equivalent `_enabler_*`/`_approver_*` prefix).

Verification: run this project's full test suite before and after and confirm identical
pass/fail results (a pure refactor must not change test outcomes). Specifically run
`test/enabler-*.test.sh` and `test/approver*.test.sh` (or whatever their actual test file names
are — grep `test/` for them) and confirm they all still pass. Read the decomposed functions and
confirm each helper has a single, nameable responsibility, the same bar PR #2707 set.

Work cost-consciously: this is a large (week-plus) decomposition effort. Do the decomposition
design itself (identifying the right helper boundaries) at a high-capability tier, since getting
the boundaries wrong creates the same "relocated bulk without reducing complexity" problem this
review separately flagged in `lib/coordinator-phase.sh`/`lib/gather-phase.sh`. Once boundaries
are chosen, delegate the mechanical extraction of well-specified individual helpers to a
mid-cost tier, verifying each extraction preserves behaviour before moving to the next.

Deliverable: one commit/PR per function decomposed (so each is independently reviewable), e.g.
`refactor(enabler): decompose maybe_run_enabler into named helpers` and
`refactor(approver): decompose run_approver_stage into named helpers`. Reference agent-ops#1254
(enabler) and agent-ops#1255 (approver) respectively; also reference the broader trackers
agent-ops#1756, #1253, #1996.
```

## Prompt for R-14 — Harden `san()` against a bare `..` path segment

**Bundles:** R-14 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops's `lib/claim-key.sh` defines a sanitization function `san()`
(currently around line 17) used to turn arbitrary strings into safe path/key segments. It has
no explicit check rejecting a bare `.` or `..` result. Every current caller (in `lib/claim.sh`
and `scripts/sweep-orphan-branches.sh`) happens to append a suffix afterward, which makes this
unexploitable today, but that safety is incidental to the callers, not to `san()` itself.

The problem: a future caller that uses `san()`'s output directly (e.g. as a GitHub-contents-API
path segment) with no appended suffix would silently inherit a path-traversal-shaped gap.

The goal (acceptance criteria): `san()` itself explicitly rejects (returns an error, or
substitutes a safe placeholder — follow whatever error-handling convention this function already
uses for other invalid inputs) any result that is exactly `.` or `..`, regardless of what the
caller does afterward.

Constraints: do not change `san()`'s behavior for any valid input — only add the explicit
rejection for the bare `.`/`..` case. Do not change any caller; the fix belongs in `san()`
itself specifically so future callers are protected automatically.

Verification: add a test to this function's existing test coverage (check for
`test/claim-key.test.sh` or wherever `san()` is currently tested) asserting that an input
producing a bare `.` or `..` is rejected, and that all existing valid-input cases still pass
unchanged. Run the full test suite to confirm no regression in current callers.

Work cost-consciously: small, mechanical, well-specified fix; suits a low-cost tier end to end.

Deliverable: a single commit/PR (e.g. `fix(claim-key): reject a bare .. from san() directly`).
Closes agent-ops#1172.
```

## Prompt for R-15 — Clean up fixture identity hygiene

**Bundles:** R-15 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops's test suite under `test/` has 32 files (confirm with `grep -rl
"warwickallen\|Warwick-Allen" test/*.sh | wc -l`) that reference the repository maintainer's
real GitHub usernames (`warwickallen` and `Warwick-Allen`) as test fixture data.

The problem: these are the maintainer's own public GitHub handles appearing in test fixtures
rather than placeholder identities — a low-severity hygiene issue (not a credential or private
individual's data), but worth cleaning up since it's accumulated across many files.

The goal (acceptance criteria): replace the real usernames with placeholder values (e.g.
`test-user`, `example-maintainer`) across the affected fixture files, choosing names that make
it clear in context that they're placeholders, not real accounts.

Constraints: do not change any test's actual assertions or logic, only the literal fixture
values. Where a test specifically relies on matching against `config.json`'s own
`enabler_assignee`/`CODEOWNERS` values (which legitimately are the maintainer's real handles,
documented as "not a value to copy" in `config.schema.json`), leave those specific references
alone — only change fixture data that's standing in for "some GitHub user," not references that
are deliberately testing against this installation's real configured identity.

Verification: run `grep -rl "warwickallen\|Warwick-Allen" test/*.sh | wc -l` after your change
and confirm the count has dropped to only the legitimate CODEOWNERS/config-identity references
(if any remain, state which and why in your deliverable). Run the full test suite and confirm no
test's behavior changed as a result of the substitution (a test that was accidentally relying on
a specific name's length or GitHub-ID-lookup behavior would be a sign you need to adjust it
carefully, not just find-and-replace blindly).

Work cost-consciously: this is mechanical find-and-replace work across many files, well suited
to a low-cost tier; have a mid-cost tier spot-check that no test's actual assertions were broken
by the substitution.

Deliverable: a single commit/PR (e.g. `test: replace the maintainer's real GitHub handles with
placeholder fixture identities`). Closes agent-ops#1174.
```

## Prompt for R-16 — Add `.editorconfig`

**Bundles:** R-16 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops has no `.editorconfig`, `.shellcheckrc`, or `Makefile` at its
repository root — confirm with `ls .editorconfig .shellcheckrc Makefile` (all should report "No
such file or directory").

The problem: without a committed `.editorconfig`, an editor has no machine-readable signal for
this project's actual formatting conventions (indentation, line endings, final newline), so
contributors' editors may default to inconsistent settings.

The goal (acceptance criteria): add a `.editorconfig` file at the repository root covering at
least `.sh`, `.md`, `.json`, and `.yml`/`.yaml` files, with settings that match this project's
*actual* existing conventions — inspect a representative sample of existing files in each
extension (indent style/size, line-ending style, whether files end with a final newline) rather
than guessing or using generic defaults.

Constraints: the `.editorconfig` must describe the conventions this codebase already follows,
not conventions you'd prefer — if you find inconsistency in the existing codebase, document what
you chose and why rather than silently picking one.

Verification: run `editorconfig-checker` (or equivalent) against the repository, if available,
and confirm no mass of pre-existing violations appears — if it does, that signals your
`.editorconfig` doesn't actually match this project's real conventions, and you should revise it
rather than leave contributors fighting their editor over it.

Work cost-consciously: this whole task is small and mechanical; suits a low-cost tier end to
end.

Deliverable: a single commit/PR (e.g. `chore: add .editorconfig`). Closes agent-ops#1758.
```

## Prompt for R-17 — Widen the `cfg()`/`expand_home()` dedup scope

**Bundles:** R-17 only (a single, larger version of an already-tracked cleanup — see context)
· **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops's `lib/config-access.sh` defines canonical `cfg()` (line ~20) and
`expand_home()` (line ~14) helpers. An existing tracking issue (agent-ops#1755) names two files
(`lib/claim.sh` and `scripts/sweep-orphan-branches.sh`) as redefining `cfg()` locally instead of
sourcing the shared version. A fuller audit found the real scope is much larger: `cfg()` is
independently redefined in roughly 15 files across `scripts/` and `lib/`, and `expand_home()` in
roughly 20 — re-run `grep -rln "^cfg()\|^expand_home()" lib/ scripts/` yourself to get the
current, authoritative list, since files may have been added or changed since this was last
measured. Only the three cycle entrypoints (`agent-cycle.sh`, `review-cycle.sh`,
`monitor-cycle.sh`) and `scripts/collect-host-facts.sh` currently source
`lib/config-access.sh` directly.

The problem: nearly every standalone `scripts/*.sh` tool reinvents both helpers instead of
sourcing the shared versions. At least 7 of the `cfg()` copies have already diverged
behaviorally (some suppress stderr with `2>/dev/null` where the canonical version doesn't) —
a future fix to the canonical `cfg()`'s error-handling behavior would silently not apply to any
of these divergent copies.

The goal (acceptance criteria): every file in `lib/`/`scripts/` that currently redefines
`cfg()` or `expand_home()` locally instead sources `lib/config-access.sh` (or extracts the
minimal subset it needs from it) and removes its local definition. Behavior must be preserved
exactly — including, where it turns out a caller actually *depends* on a divergent behavior
(e.g. the stderr suppression), either fix that caller's dependency explicitly and document why,
or special-case it rather than silently changing its behavior.

Constraints: do this incrementally, one file (or a small batch of clearly-identical files) per
commit, each verified independently — do not do all ~35 files in one unreviewable commit. Do not
change `lib/config-access.sh`'s own `cfg()`/`expand_home()` behavior as part of this task.

Verification: after each file's migration, run that file's own test coverage (if any) plus the
full test suite, and confirm no behavioral change. At the end, re-run the same `grep` search
above and confirm it returns only `lib/config-access.sh` itself.

Work cost-consciously: migrating each individual file is mechanical (source the shared helper,
delete the local copy, verify tests pass) and suits a low-cost tier; delegate files in parallel
batches to subagents where your environment supports it, but have a mid-cost tier review the 7
files with known behavioral divergence specifically, since those need a real decision, not just
a mechanical swap.

Deliverable: a series of small commits/PRs migrating files in batches (e.g. `refactor(scripts):
source the shared cfg()/expand_home() helpers in <N> files`). References agent-ops#1755 (widen
its scope rather than closing it with only the original two files addressed).
```

## Prompt for R-18 — Land the ready `publish-dashboard.sh` flaky-test fix

**Bundles:** R-18 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops's `test/publish-dashboard.test.sh` has a flaky assertion at
`run_window 20` (confirm the current line number — it has shifted slightly over time, currently
around line 1548). A byte-for-byte identical flaky pattern existed in `test/state-sync.test.sh`
and was already fixed by changing its assertion from an exact `0` to a tolerant `<= 1` (that fix
landed as a specific, small commit — find it via `git log --oneline -S"<= 1" --
test/state-sync.test.sh` to see the exact pattern used).

The problem: `publish-dashboard.test.sh`'s sibling assertion still expects an exact value under
timing conditions that can legitimately vary by one unit, making it an intermittent CI flake.

The goal (acceptance criteria): apply the identical one-line tolerance-widening fix pattern to
`test/publish-dashboard.test.sh`'s `run_window 20` assertion that was already applied to
`state-sync.test.sh`'s equivalent.

Constraints: change only this one assertion's tolerance, nothing else in the test file. Do not
widen the tolerance by more than the state-sync fix's precedent justifies (the same amount,
not more).

Verification: run `test/publish-dashboard.test.sh` repeatedly (e.g. 10+ times in a loop, or
under artificial scheduling pressure if your environment allows it) and confirm it no longer
flakes on this assertion while still catching a genuine regression (temporarily break the
underlying behavior and confirm the test still fails appropriately).

Work cost-consciously: this is a one-line, precedent-following fix; suits a low-cost tier end
to end.

Deliverable: a single commit/PR (e.g. `test(dashboard): widen run_window's flaky exact-match
assertion, matching state-sync's fix`). Closes agent-ops#1205.
```

## Prompt for R-19 — Close three stale issues describing already-resolved work

**Bundles:** all three bundled since they're the same action (verify-and-close) repeated three
times · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops's GitHub issue tracker has three open issues whose underlying work
appears to already be done:
- `agent-ops#1036` — describes a single-page issue-digest gap; `scripts/gather-source-state.sh`
  (currently around line 127) already uses `gh api --paginate`, fixed by a since-merged pull
  request.
- `agent-ops#2326` — describes a documentation size-budget violation in a spec file that a
  later, unrelated split already brought back under budget.
- `agent-ops#2813` — describes a missing check that a security hook file is root-owned and
  non-writable; `.github/workflows/build-image.yml` (currently around lines 460-466) already
  implements and CI-enforces exactly this check.

The problem: all three issues remain open despite their described gap being closed, which
clutters the backlog and could mislead a future reader into treating them as live gaps.

The goal: for each of the three issues, independently re-verify (do not simply trust this
prompt — re-read the current code and confirm) that the work is actually done, then close the
issue with a comment naming the specific commit, PR, or code location that resolved it.

Constraints: do not close any of the three if your own re-verification finds the work is not
actually complete — report back what's still missing instead. Do not file a new issue or make
any code change as part of this task; it is purely an issue-tracker correction.

Verification: for each issue, cite the specific file/line/commit you checked and what it showed,
in the closing comment itself, so the closure is independently auditable.

Work cost-consciously: this is a read-and-confirm task with no code change; suits a low-cost
tier end to end.

Deliverable: three issue-closing comments (no pull request). Closes agent-ops#1036,
agent-ops#2326, and agent-ops#2813.
```

## Prompt for R-20 — Extract a shared paginated-fetch helper

**Bundles:** R-20 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops calls `gh api ... --paginate` in several places and then
aggregates the NDJSON (one JSON object per line, not one array per page) output with `jq -s`.
This idiom — including a near-identical explanatory comment about the "one JSON object per
line" trap — is independently re-implemented in at least `lib/approver.sh` (multiple call
sites), `lib/enabler.sh`, `lib/candidate-select.sh`, `lib/pipeline-marker.sh`, and
`scripts/autonomy-stage-report.sh` (multiple call sites). `lib/github-limit.sh` already provides
a separate rate-limit-aware `gh()` wrapper but has no shared helper for this specific
pagination-aggregation idiom.

The problem: a correctness fix to this idiom (e.g. improved rate-limit handling, or fixing an
edge case in the aggregation) currently has to be applied by hand at every one of these 7+ call
sites, and already-diverging copies risk drifting further apart.

The goal (acceptance criteria): write a single `gh_paginated_fetch(endpoint, jq_filter)` function
in `lib/github-limit.sh` that matches the existing idiom's behavior exactly (same pagination,
same NDJSON-aggregation semantics, same error handling), then migrate each of the 7+ existing
call sites to use it instead of their own copy of the idiom.

Constraints: migrate one call site (or one file) at a time, each independently verified, rather
than one large unreviewable change. Preserve exact existing output for every call site — this is
a pure refactor.

Verification: for each migrated call site, run its specific test coverage (if any) plus the full
test suite, and confirm identical output before and after the migration (capture actual output
from a real or fixture-backed `gh api` call before changing the code, then diff against the
output after). As a side effect, confirm `scripts/publish-dashboard.sh`'s line count decreases
slightly if any of its call sites are migrated.

Work cost-consciously: writing the shared helper itself (matching subtle existing behavior
exactly) should be done at a mid-to-high-capability tier, since getting an edge case wrong (e.g.
empty-page handling, rate-limit retry behavior) would introduce a regression in every migrated
call site at once. Migrating individual, well-specified call sites afterward, each verified
independently, suits a mid-cost tier.

Deliverable: one commit/PR adding `gh_paginated_fetch` plus a series of small follow-on commits
(or one combined PR, if small enough to review as a unit) migrating each call site. Closes
agent-ops#1919.
```
