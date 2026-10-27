# Improvement prompts

One prompt per recommendation, in priority order (severity first, then effort). Each prompt is
self-contained and may be pasted into a fresh AI agent session with no other context. Where one
prompt's work depends on another's, that is noted in its own **Run after** line and repeated
inside the prompt text.

## Prompt for R-01 — Close the Vercel-secret redaction coverage gap

**Bundles:** R-01 only · **Run after:** no prerequisites

```text
Context: you are working in Pullwright/agent-ops, a Bash-based ops-tooling repository for
autonomous Claude Code agent pipelines. `scripts/preview-deploy.sh` deploys Vercel preview
environments and uses two secrets directly: VERCEL_TOKEN (as an Authorization: Bearer header,
around line 281) and VERCEL_AUTOMATION_BYPASS_SECRET (as an x-vercel-protection-bypass header
value, around lines 306, 350, 387). `lib/redact.sh` provides a `redact_add_literal` function that
registers an exact string for redaction before any cycle transcript or state-mirror push can leak
it; two other secrets (notify_webhook_url, in scripts/state-sync.sh:202 and
scripts/publish-dashboard.sh:332) already use this pattern — read those two call sites as your
template.

The problem: neither VERCEL_TOKEN nor VERCEL_AUTOMATION_BYPASS_SECRET is ever registered via
redact_add_literal. This is not hypothetical: a live instance of exactly this credential class
(a Vercel token and GitHub App key paths) was printed into a session transcript on 2026-09-16
(agent-ops#1627, since rotated) — this gap is the mechanism that incident used, left open for one
specific credential pair. Separately, `test/redact.test.sh` covers only one narrow bug
(placeholder-escaping) in `lib/redact.sh` — it does not exercise the six shape-based rules in
`REDACT_SED_ARGS` (lib/redact.sh:20-28) or redact_add_literal's handling of a secret containing a
newline (lib/redact.sh:80, a documented no-op). Finally, docs/DATA-HANDLING.md's "Redaction for
screenshots" paragraph (around line 141) implies broader coverage than the mirror-push redaction
pass (lib/redact.sh + redact_add_literal) actually provides, without saying so.

The goal: (1) scripts/preview-deploy.sh registers both VERCEL_TOKEN and
VERCEL_AUTOMATION_BYPASS_SECRET via redact_add_literal at the point each is read into a shell
variable, before either is used in an HTTP header. (2) test/redact.test.sh gains test cases
covering each of the six REDACT_SED_ARGS shape rules and redact_add_literal's behaviour on a
secret containing a newline. (3) docs/DATA-HANDLING.md's screenshot-redaction paragraph is edited
to explicitly distinguish the screenshot redaction pass's scope from the separate, narrower
mirror-push pass, so a reader cannot over-trust the mirror-push pass's coverage.

Constraints: follow the existing redact_add_literal call pattern exactly (do not invent a new
registration mechanism); do not change preview-deploy.sh's actual deployment behaviour, only add
the two registration calls; keep the documentation edit to the one paragraph — this repository's
docs are as-built, so do not add "previously"/"used to" phrasing.

Verification: run the project's test suite via ./scripts/run-tests.sh (requires Docker; if
unavailable, at minimum run test/redact.test.sh directly and confirm your new cases pass and the
existing cases still pass); grep scripts/preview-deploy.sh to confirm both secrets are registered
before first use; read docs/DATA-HANDLING.md's edited paragraph aloud to confirm it no longer
implies broader coverage than the mirror-push pass has.

Work cost-consciously. This is a security-relevant fix — do the redaction-call change and the
documentation correction yourself at a high-capability tier rather than delegating; the new test
cases for lib/redact.sh's existing shape rules are mechanical (apply a documented pattern across
several test cases) and suit a low-cost tier if you delegate them, but verify the delegated tests
actually exercise the described behaviour before integrating.

Deliverable: a single commit/PR with: the two redact_add_literal calls in
scripts/preview-deploy.sh, new test cases in test/redact.test.sh, and the corrected paragraph in
docs/DATA-HANDLING.md. PR title in Conventional Commits format, e.g. "fix(redact): register
Vercel secrets for mirror-push redaction". Close agent-ops#1752 and agent-ops#1757 with the PR's
closing keywords.
```

## Prompt for R-02 — Wire `toc` and `spec` into the required-status-check ruleset

**Bundles:** R-02 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops protects its `main` branch with a GitHub repository ruleset
(ruleset ID 18857310) that lists required status checks. Two CI workflows — toc.yml and spec.yml —
already run on every pull request (toc.yml checks that generated tables-of-contents are current;
spec.yml, via scripts/spec.sh check, verifies every requirement/acceptance-check/component
citation in docs/spec/ resolves and has no duplicates) but neither appears in the ruleset's
required-status-checks list, so a PR can currently merge even if either check fails red.

The problem: this is the third and fourth recurrence of a pattern already fixed twice in this
repository's history (config-table and changelog-section were both promoted from advisory to
required in prior review cycles). agent-ops#2117 (toc) and agent-ops#2578 (spec, which names its
own precondition — PR #2506 landing spec.yml on main — as already satisfied) are both open,
fully-scoped, one-click ruleset edits waiting on the repository owner.

The goal: `gh api repos/Pullwright/agent-ops/rulesets/18857310` shows both `toc` and `spec` present
in the `required_status_checks` rule's `required_status_checks` array, alongside the existing
required checks.

Constraints: this specific action — editing a GitHub repository ruleset — requires the repository
owner's own GitHub credentials; it cannot be performed by an autonomous pipeline identity. Do not
attempt to work around this by editing the workflow files themselves (that would not make the
check "required" in the branch-protection sense).

Verification: after the owner applies the change, run `gh api
repos/Pullwright/agent-ops/rulesets/18857310 --jq '.rules[] | select(.type ==
"required_status_checks") | .parameters.required_status_checks[].context'` and confirm both `toc`
and `spec` appear in the output.

Work cost-consciously. This task has no implementation work for an agent to do — it is a one-line
repository-settings change. Do not attempt to automate it; simply surface the two issue numbers
(agent-ops#2117, agent-ops#2578) and this exact `gh api` command to the repository owner.

Deliverable: nothing to commit. Close agent-ops#2117 and agent-ops#2578 once the owner confirms
the ruleset edit, citing the verification command's output in the closing comment.
```

## Prompt for R-03 — Fix the spec-split rename-during-split regression; add a mechanical guard

**Bundles:** R-03 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops splits oversized as-built specification files under
docs/spec/implementation/requirements/ when they exceed a 100KB-per-file documentation size
budget. The convention (documented in docs/guides/contributing/README.md § "Size budget and
checks") requires that a split add new files at the next unused number and never rename or
renumber a file that already existed — this rule exists specifically because PR #2453 once
renumbered acceptance-checks-02..06.md to 03..07.md and silently reverted a concurrent main-side
edit to one of those files (diagnosed as agent-ops#2472, fixed by PR #2478).

The problem: commit 9235549 (PR #2665, merged 2026-10-25, "docs(spec): split the-script-09.md")
violated this convention eight days after it was adopted: it renamed the pre-existing
docs/spec/implementation/requirements/the-script-10.md to the-script-12.md and the-script-11.md to
the-script-13.md, inserting new split-off content at the vacated the-script-10.md/the-script-11.md
paths instead. No automated check caught this — scripts/check-docs.sh and scripts/spec.sh check
both passed, because neither checks for a rename during a documentation-only split.

The goal: (1) restore the-script-10.md and the-script-11.md to their original pre-9235549 content
and names (use `git show 9235549^:docs/spec/implementation/requirements/the-script-10.md` and the
-11 equivalent to recover the original content). (2) move whatever content 9235549 actually
intended to split off to new, never-before-used file numbers in the same directory instead (check
the directory for the next unused number). (3) update every cross-reference and the directory's
table-of-contents region accordingly, and re-run scripts/render-toc.sh. (4) add a mechanical check
— in scripts/check-docs.sh or as a new, narrowly-scoped check — that fails a documentation-only
spec-directory-split commit if any file that existed in the parent commit is absent from the split
commit while a new file with substantially similar heading/content structure exists.

Constraints: do not alter the technical content of any requirement, acceptance check or component
— this is a pure file-identity fix, not a content edit. Preserve every <a id> anchor exactly
(scripts/spec.sh check will catch a broken one). Follow the existing split convention exactly, the
same way PR #2679 (the acceptance-checks-02.md split the day after this regression) did it
correctly — read that PR's diff as your positive model.

Verification: run `scripts/check-docs.sh` and `scripts/spec.sh check` and confirm both pass; run
`scripts/render-toc.sh --check` and confirm no drift; diff the restored the-script-10.md/-11.md
against their pre-9235549 content and confirm an exact match; confirm your new mechanical guard
actually fails against commit 9235549 itself if you replay its diff in isolation (a sanity check
that the guard would have caught this).

Work cost-consciously. The file-restoration and renumbering is mechanical (apply a known-good
pattern) and suits a mid-cost tier; writing the new mechanical guard touches a shared CI script
multiple other checks depend on, so do that part yourself at a high-capability tier and verify any
delegated restoration work byte-for-byte before integrating.

Deliverable: one PR, title e.g. "fix(spec): restore the-script-10/11.md's identity; guard against
rename-during-split", closing agent-ops#2694.
```

## Prompt for R-04 — Re-file the dropped coverage-tooling tech debt

**Bundles:** R-04 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops is a Bash project with 277 test files under test/, run via
./scripts/run-tests.sh (a Docker-based harness). No coverage-measurement tooling exists anywhere
in the repository — there is no way to measure what fraction of lib/ and scripts/ (roughly 91,500
lines) the test suite actually exercises, beyond manual inspection and ad hoc gap-filing as issues
are noticed.

The problem: a prior fix (PR #2664, closing issue #1148) explicitly scoped this question out and
asked for a separate tech-debt item to be filed if a coverage floor was wanted later; that
follow-up item (agent-ops#2695) now exists but has no decision or implementation attached.

The goal: a decision on whether to adopt a bash coverage tool (kcov is the most mature option for
bash; bashcov is an alternative), and if adopted, a `--coverage` flag on
./scripts/run-tests.sh and an initial coverage floor recorded somewhere checked in CI — follow
this repository's own existing ratchet pattern (see scripts/docs-size-ratchet.tsv for the style:
a tracked, generous starting floor that tightens over time rather than a hard threshold imposed
immediately).

Constraints: the tool must run inside this repository's existing Docker-based test harness
(./scripts/run-tests.sh) without requiring network access during the test run (this pipeline's
containers are network-fenced by an egress allowlist). If kcov cannot be made to work reliably in
that environment within a reasonable effort, document why and propose the next-best alternative
rather than forcing a brittle integration.

Verification: run ./scripts/run-tests.sh --coverage (once added) inside the project's own test
container and confirm it produces a coverage report; confirm a deliberately-added untested
function shows as uncovered in that report (a sanity check that the tool is actually measuring
something real, not just running).

Work cost-consciously. Evaluating kcov's bash integration is exploratory and benefits from a
high-capability tier doing the initial spike; once a working integration is found, wiring the flag
and the ratchet file is mechanical and suits a mid-cost tier.

Deliverable: one PR adding the coverage flag and initial floor (or, if no viable tool is found
within a reasonable effort, a PR updating agent-ops#2695 with that finding and a recommended next
step, left open rather than closed). Title e.g. "feat(test): add a coverage-measurement flag to
run-tests.sh".
```

## Prompt for R-05 — Paginate `publish-dashboard.sh`'s open-issues fetch

**Bundles:** R-05 only · **Run after:** no prerequisites

```text
Context: scripts/publish-dashboard.sh (around line 3365) fetches open issues for the dashboard's
Priority display with `gh_call api "repos/$slug/issues?state=open&per_page=30"` — a single page,
capped at 30 issues, with no `--paginate`. A 2026-10-27 project review established the
repository's actual open-issue count is 581, so this display is silently truncating to roughly 5%
of the real backlog.

The problem: the Priority display cannot show issues beyond the first 30 returned by the GitHub
API's default ordering, which may not surface the highest-priority items at all.

The goal: the dashboard's Priority display reflects the true open-issue set (or, if a full fetch
is judged too expensive for a per-tick read given the fleet-wide call-budget concerns this
codebase already tracks via lib/github-limit.sh, an explicit, visible "N of M" indicator replacing
the current silent cap).

Constraints: this script runs on every dashboard-publish tick across the fleet — any fix must
respect the existing rate-limit/caching machinery in lib/gh-shim.sh and lib/github-limit.sh rather
than bypassing it with a raw unthrottled fetch. Do not change the Priority display's visual
layout, only its data completeness.

Verification: run scripts/publish-dashboard.sh --no-github --fast locally against a test fixture
with more than 30 synthetic open issues and confirm the Priority display reflects all of them (or
the explicit cap indicator, if you choose that approach); confirm the fetch still goes through the
existing gh-shim/github-limit layer by checking it hits the same cache/rate-limit code path other
gh_call invocations in this file use.

Work cost-consciously. This is a well-specified, mechanical change (add --paginate to an existing
call, following a pattern this repo uses in several other files) and suits a mid-cost tier.

Deliverable: one PR, title e.g. "fix(dashboard): paginate the open-issues fetch for the Priority
display", closing agent-ops#1171.
```

## Prompt for R-06 — Add a container-image vulnerability scan to `build-image.yml`

**Bundles:** R-06 only · **Run after:** no prerequisites

```text
Context: .github/workflows/build-image.yml builds and publishes ghcr.io/pullwright/agent-ops from
ubuntu:24.04. Both the source repository and the published image are public. No workflow in
.github/workflows/ runs a container vulnerability scanner.

The problem: a known-CVE OS package or installed toolchain binary in the published image would
have nothing in CI flagging it. This is distinct from the existing codeql.yml workflow, which
scans Actions YAML source only (CodeQL has no Bash analyzer) and does not cover OS-package
vulnerabilities inside the built image at all.

The goal: build-image.yml's existing build job runs a container vulnerability scan (Trivy is the
most common choice for this) against the image it just built, with results visible in the
Actions run and/or the PR.

Constraints: do not make the scan a required/blocking check in this same change — land it as
report-only first (see cost policy below for why). Do not change the Dockerfile or the build job's
existing steps beyond adding the scan step.

Verification: trigger the workflow (e.g. via a draft PR) and confirm the new scan step runs and
produces a readable report in the Actions run output; confirm the existing build/push steps are
unaffected (image still builds and (on the appropriate trigger) pushes successfully).

Work cost-consciously. Adding a well-documented Action step (e.g. aquasecurity/trivy-action) is
mechanical and suits a mid-cost tier.

Deliverable: one PR, title e.g. "ci(build-image): add a report-only Trivy vulnerability scan",
closing agent-ops#2696. Note in the PR description that the scan is deliberately non-blocking for
now, with a follow-up to promote it to a required check once its false-positive rate is known.
```

## Prompt for R-07 — Fix `publish-dashboard.sh`'s `--help` swallowing; add `--help` to `monitor-cycle.sh`

**Bundles:** R-07 only (two files, one shape of fix — the baseline review already filed both under
one issue, agent-ops#1753) · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops has three top-level cycle scripts: agent-cycle.sh,
review-cycle.sh, and monitor-cycle.sh, plus scripts/publish-dashboard.sh. The first two, and
scripts/doctor.sh, already implement a `-h|--help)` case in their flag-parsing loop that prints
usage text and exits 0. monitor-cycle.sh and scripts/publish-dashboard.sh do not follow this
pattern consistently.

The problem: scripts/publish-dashboard.sh's flag-parsing loop (around line 208) ends in a bare
`*) shift ;;` catch-all, so `--help` is silently absorbed as an unrecognized flag and the script
proceeds to run a full dashboard publish instead of printing usage. monitor-cycle.sh has no
`-h`/`--help` case at all — it exits 64 with "unknown argument: --help", which is at least loud,
but gives no usage text.

The goal: `./scripts/publish-dashboard.sh --help` prints usage text and exits 0 without publishing
anything. `./monitor-cycle.sh --help` prints usage text and exits 0.

Constraints: match the existing usage-text style and format used by agent-cycle.sh --help and
review-cycle.sh --help exactly (same section headers, same flag-description format) — do not
invent a new help-text convention.

Verification: run `./scripts/publish-dashboard.sh --help` and confirm it prints usage and exits 0
with no side effects (no files written under dashboard/ or wherever it publishes to); run
`./monitor-cycle.sh --help` and confirm the same. Run both scripts' existing test suites
(test/publish-dashboard.test.sh, and monitor-cycle's test file if one exists) and confirm no
regression.

Work cost-consciously. This is mechanical, well-specified work (apply an existing documented
pattern to two more files) and suits a low-cost tier.

Deliverable: one PR, title e.g. "fix(cli): add --help handling to publish-dashboard.sh and
monitor-cycle.sh", closing agent-ops#1753.
```

## Prompt for R-08 — Owner check-in on backlog growth / fit-ladder trajectory

**Bundles:** R-08 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops's Co-Ordinator stage selects work from an open-issue backlog that a
2026-10-27 project review measured at 581 open issues (not the ~30 every prior review's `gh issue
list` default-page view suggested), growing roughly 3:1 (issues filed vs. closed) over the three
weeks measured. The repository owner has already recorded a considered decision on this in
docs/STANDING-DECISIONS.md (dated 2026-10-16, referencing agent-ops#2319/#2422): declining to
manage the backlog by volume, asking instead that issue-filing agents make better use of the
Priority field and Issue Dependencies. Architectural mitigation (tuning the Co-Ordinator's
input-fit ladder, tracked by agent-ops#2416/#2417/#2422) is already in progress.

The problem/goal: this is not a code-fix task. It is a visibility task: surface the current,
measured backlog numbers (581 open, roughly 3:1 filed:closed over three weeks) to the repository
owner so they have accurate current data to judge whether the existing standing decision still
holds, rather than relying on a stale ~30-issue impression any future review might otherwise
repeat.

Constraints: do not file a new issue proposing a backlog-management policy change — the owner has
already made and recorded that decision; this task is purely about delivering accurate current
numbers, not second-guessing the decision.

Verification: confirm the numbers are current by re-running `gh api search/issues -f
q="repo:Pullwright/agent-ops is:issue is:open" --jq '.total_count'` and a filed-vs-closed count
over whatever window is most recent at the time this prompt is executed, rather than reusing this
review's October numbers verbatim.

Work cost-consciously. This is a short, low-effort reporting task — do it directly, no delegation
needed.

Deliverable: a short message or comment (wherever the owner is reachable — e.g. a comment on
agent-ops#2422) with the current backlog total, the current filed:closed ratio, and a one-line
pointer to docs/STANDING-DECISIONS.md's existing entry. No code change, no new issue.
```

## Prompt for R-09 — Add a Dependabot `docker` ecosystem entry for the base image

**Bundles:** R-09 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops's .github/dependabot.yml configures automated dependency-update PRs
for two ecosystems: github-actions, and docker-compose (directory /deploy/docker). It has no
package-ecosystem: "docker" entry, so Dependabot never tracks deploy/docker/Dockerfile's own `FROM
ubuntu:24.04` base image.

The problem: ubuntu:24.04 security patches get no automated update signal — the Dockerfile's base
image pin has been unchanged for 47+ days with nothing flagging whether a newer patch release is
available.

The goal: Dependabot opens a PR when a newer ubuntu:24.04 (or later LTS) base image tag is
available, the same way it already does for the github-actions and docker-compose ecosystems.

Constraints: do not attempt to add automated-update coverage for the Dockerfile's four hand-pinned
toolchain ARGs (SUPERCRONIC_VERSION, SHELLCHECK_VERSION, CLAUDE_CODE_VERSION, GROK_BUILD_VERSION) —
no Dependabot ecosystem parses a plain Dockerfile ARG consumed by a curl/npm install -g step inside
a RUN statement, and building bespoke tooling for four values is out of scope for this task; those
remain accepted manual-review debt.

Verification: after adding the entry, confirm `.github/dependabot.yml` validates (GitHub validates
dependabot.yml syntax on push; also runnable locally with a YAML linter) and that the new entry's
`directory` correctly points at the directory containing the Dockerfile (deploy/docker).

Work cost-consciously. This is a small, mechanical config addition and suits a low-cost tier.

Deliverable: one PR, title e.g. "build(deps): add a Dependabot docker ecosystem entry for the base
image", closing agent-ops#2697.
```

## Prompt for R-10 — SHA-pin every Actions `uses:` step

**Bundles:** R-10 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops has 17 GitHub Actions workflow files under .github/workflows/. Every
`uses:` line in every one of them references a mutable version tag (e.g. actions/checkout@v7,
docker/build-push-action@v7, github/codeql-action/analyze@v4) rather than a pinned commit SHA.
Dependabot (already configured, .github/dependabot.yml, github-actions ecosystem) handles the
*update* mechanism for Actions but does not itself pin them — that's a separate, manual step.

The problem: a compromised or maliciously re-tagged upstream Action release would be pulled
automatically into a pipeline with write access to a public container registry and (via other
workflows) merge privileges on this repository's own code.

The goal: every `uses:` line across all 17 workflow files is pinned to a commit SHA, with the
version tag preserved as a trailing comment for readability (e.g. `uses:
actions/checkout@<40-char-sha> # v7`).

Constraints: pin to the SHA corresponding to the *currently referenced* tag for each action (do
not silently upgrade versions while pinning — that's a separate concern Dependabot will now
surface on its own schedule once pins are in place). Verify each SHA against the action's own
published release/tag on GitHub before using it.

Verification: for each workflow file, confirm every `uses:` line now has a 40-character hex SHA;
trigger each workflow (or at minimum the ones that run on every PR) and confirm it still succeeds
with no behavioural change; confirm Dependabot's config requires no changes (it supports
SHA-pinned actions natively — it will propose SHA updates with the version-tag comment preserved).

Work cost-consciously. This is mechanical, well-specified work (resolve a tag to a SHA, replace a
string, for each of ~30-40 uses: lines across 17 files) and suits a low-cost tier if delegated;
verify each resolved SHA actually corresponds to the claimed tag before integrating, since a wrong
SHA pin is a worse outcome than no pin at all.

Deliverable: one PR, title e.g. "ci: SHA-pin every Actions step", closing agent-ops#1918.
```

## Prompt for R-11 — Bound the rest of `do_push`; add a bounded DNS-failure retry

**Bundles:** R-11 (F-OPS-02 and F-OPS-05 bundled — a retry added on top of an already-unbounded
call needs its own deadline regardless, so these are two faces of one change) · **Run after:** no
prerequisites

```text
Context: scripts/state-sync.sh's do_push() function (lines 995-1280) pushes this pipeline's shared
fleet state to a mirror repository under a lock (mirror_lock, taken at line 999). Only one step
inside it — redact_mirror_files — is currently wrapped in a deadline, via
`mirror_run_with_deadline "$push_deadline_seconds" redact_mirror_files ...` (line 1238).

The problem: the git fetch (line 1017), both rsync -a --delete passes (lines 1026, 1048), and the
final mirror_write push (around line 1267) all run after the lock is taken with no deadline
wrapper — any of these four steps hanging (e.g. on a network stall) wedges the lock indefinitely,
the same failure class that produced a documented 7-hour wedge incident. Separately,
agent-ops#1604 describes a push that fails silently with no retry when a transient DNS/proxy
resolution error occurs.

The goal: every step inside do_push() after the mirror lock is taken runs under its own deadline
(the same mirror_run_with_deadline wrapper already used for redact_mirror_files, budgeted against
the remaining push_deadline_seconds); the fetch/push network calls specifically retry 2-3 times
with a short backoff on a transient DNS/proxy failure before giving up.

Constraints: preserve the existing lock-release-on-exit behaviour exactly — a bounded deadline
must still release the lock cleanly on timeout, the same way the existing redact_mirror_files
wrapper does. Do not change do_push()'s success-path behaviour or its return value's meaning.

Verification: run test/state-sync.test.sh and confirm all existing cases pass; add a new test case
that simulates a hung git fetch (or rsync) and confirms the deadline wrapper times it out and
releases the lock rather than wedging; add a test case simulating a transient DNS failure and
confirming the bounded retry succeeds on a subsequent attempt.

Work cost-consciously. Wrapping existing calls in an already-proven deadline helper is mechanical
and suits a mid-cost tier; writing the new hang-simulation test cases is more delicate (getting a
test to reliably simulate a hang without actually hanging the test suite) and benefits from a
higher-capability tier or careful review of a delegated attempt.

Deliverable: one PR, title e.g. "fix(state-sync): bound every step of do_push; add a DNS-failure
retry", closing agent-ops#1701 and agent-ops#1604.
```

## Prompt for R-12 — Diagnose and unstick the CHANGELOG roll automation

**Bundles:** R-12 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops assembles CHANGELOG.md from merged pull requests' `## Changelog`
sections via a scheduled "roll" workflow (introduced by PR #1842, merged 2026-09-25). The roll is
meant to periodically open a PR against main with newly-assembled changelog entries.

The problem: 32 days after the roll mechanism merged, CHANGELOG.md's last edit is still the
pre-feature migration commit (a256590, 2026-09-23) — no roll-produced PR has ever existed (confirm
with `gh api search/issues?q=repo:Pullwright/agent-ops+head:changelog-roll` — expect total_count:
0 unless this has changed since this prompt was written). Two bugs in the roll's own logic are
already tracked (agent-ops#1846 — review feedback on a roll PR isn't picked up automatically;
agent-ops#1848 — a label-ensure ordering bug) but neither bug report explains why zero PRs have
ever opened in the first place.

The goal: either the roll produces its first real PR, or the specific reason it has never fired at
all is identified and fixed — not just the two known downstream bugs patched in isolation while
the actual non-firing cause remains unexplained.

Constraints: trace the *scheduled trigger's own run history* first (check the workflow's Actions
run log for the relevant schedule, e.g. via `gh run list --workflow <the roll's workflow file>`)
before touching any code — you need to know whether the workflow is running at all and silently
deciding not to open a PR, or not running/failing before it gets that far.

Verification: after your fix, either observe a real roll-produced PR appear (wait for the next
scheduled run, or trigger it manually if the workflow supports workflow_dispatch), or, if you
identify and fix a reason it was failing silently, demonstrate the fixed path produces a PR in a
manual/dispatched run.

Work cost-consciously. The initial trace (reading Actions run history, understanding the roll's
own control flow) is exploratory and benefits from a high-capability tier; once the root cause is
identified, the actual fix is likely small and suits a mid-cost tier.

Deliverable: one PR with the root-cause fix (and, incidentally, #1846/#1848 if they turn out to be
part of the same root cause — otherwise leave them as separate, correctly-scoped fixes). Title
e.g. "fix(changelog-roll): <the actual root cause once found>", closing whichever of
agent-ops#1846/#1848 your fix actually resolves.
```

## Prompt for R-13 — Grant the Reviewer stage CI-log read/rerun access

**Bundles:** R-13 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops's Reviewer pipeline stage (prompts/reviewer.md) checks an
Implementer-raised pull request and fixes what it can before handing off. The Implementer stage's
own prompt (prompts/implementer.md, around line 308) documents a route for reading a failing CI
run's log: `gh run view --log` followed by extracting the relevant job's log section (the prompt
gives an example pattern like '2_Build and test (linux_amd64).txt').

The problem: prompts/reviewer.md has no equivalent route. Its one CI-log-adjacent mention (around
line 260) is about re-running commands *locally* to reproduce a failure, not about reading the
actual CI run's log when a PR the Reviewer is checking has a red CI status.

The goal: prompts/reviewer.md documents the same `gh run view --log` extraction route
Implementer already has, so the Reviewer stage can diagnose a failing CI run directly rather than
only being able to reproduce commands locally (which may not reproduce an environment-specific CI
failure at all).

Constraints: before changing the prompt, confirm whether the Reviewer stage's existing GitHub
credentials already have permission to read Actions run logs (likely yes, since it already reads
PR state via gh) — if a credential/scope gap exists, that is a separate, larger finding to report
rather than something this prompt's prompt-text change alone can fix.

Verification: after the prompt change, run (or simulate) a Reviewer-stage session against a PR
with a known-red CI run and confirm the stage successfully extracts and reads the relevant job's
log using the newly-documented route.

Work cost-consciously. This is primarily a documentation/prompt-text change (mirroring an existing
pattern into a sibling file) and suits a mid-cost tier; confirming the credential-scope question
is worth doing carefully, at a higher tier, since a wrong assumption there would make the prompt
change non-functional.

Deliverable: one PR, title e.g. "docs(reviewer): document the CI-log read route", closing
agent-ops#1496.
```

## Prompt for R-14 — Action `#2434`'s dashboard local-tick fix

**Bundles:** R-14 only · **Run after:** no prerequisites

```text
Context: scripts/publish-dashboard.sh's local (--no-github --fast) tick runs roughly eight full jq
passes over the fleet-log union (a never-rotated log.jsonl, now 124MB+ and growing 3-4.7MB/day) on
every invocation — read_events, a per-cycle summary fold, a cycle-id scan, a detail-window event
selector, a log tail, a per-node latest cycle-start, and a per-node live-state fold. A related
series of PRs (#2430/#2431/#2435, closing #2429) already fixed the *other* eight-plus jq passes in
this same file by prefiltering to each pager invariant's declared event types before the fold —
but deliberately left these eight out of scope, because each is keyed by cycle id or needs to see
every record, so the same prefilter doesn't directly apply. That deferred scope is tracked as
agent-ops#2434, which already documents three candidate fixes: (a) recency-suffix reads with a
whole-union fallback, (b) bounding the per-cycle summary fold to only the cycles actually
consumed by this tick, (c) an incremental parse cache across ticks.

The problem: this tick remains a linear function of total log history even after the #2429 series'
fixes, because log.jsonl is never rotated by design — the cost will keep climbing as the fleet
ages, and could again erode the duty cycle the #2429 series just restored.

The goal: the local tick's cost stops scaling linearly with total log history. This prompt does
not ask you to re-scope the problem — agent-ops#2434 already did that correctly; read it in full
before starting, since it already evaluated tradeoffs between the three candidates.

Constraints: whichever candidate you choose, preserve exact output parity with the current
(slurp-based) behaviour for every one of the eight affected readers — this is a performance fix,
not a behaviour change, and the existing test/dashboard-render.test.sh harness (which runs the
dashboard's real JS against fixture data) must continue to pass unchanged.

Verification: run test/dashboard-render.test.sh and the rest of the publish-dashboard test suite
and confirm no regression; measure the local tick's wall-clock time before and after against a
realistic-sized synthetic log.jsonl fixture (or the real one, if available) and report the
improvement.

Work cost-consciously. agent-ops#2434 already did the hard scoping work (three evaluated
candidates with tradeoffs) — implementing the chosen candidate against clear acceptance criteria
suits a mid-cost tier; reserve a higher tier only if the chosen candidate turns out to need a new
caching data structure shared across ticks (candidate c), which is more architecturally delicate
than the other two.

Deliverable: one PR, title e.g. "perf(dashboard): bound the local tick's remaining full-union jq
passes", closing agent-ops#2434.
```

## Prompt for R-15 — Decompose `run_standdown_checks`; retire stale issue `#1256`

**Bundles:** R-15 only · **Run after:** no prerequisites

```text
Context: lib/standdown.sh's run_standdown_checks function (starting at line 22, running to line
1362) is approximately 1,340 lines — the largest single undecomposed function in the
Pullwright/agent-ops repository, having grown 33% in the last review cycle alone. This repository
has a proven decomposition model for exactly this kind of growth: issue #964 (fixed by PR #1258)
split a similarly-sized function, maybe_run_refiner, into an 11-helper family. A separate, stale
issue (#1256) names a function, coordinator_corroborate_retry_or_fallback, that no longer exists
in the tree (superseded by PR #1560).

The problem: run_standdown_checks has never had a dedicated tracking issue despite a month-old
meta-tracker (#1756) explicitly recommending one be filed; it is now the clearest single
decomposition target in the codebase.

The goal: run_standdown_checks is split into a family of smaller, named helper functions, each
handling one coherent sub-check or sub-step of the stand-down logic, following the #964/PR #1258
model's shape (read that PR's diff as your template for how fine-grained the split should be and
how helpers should be named/organized). Issue #1256 is closed as superseded by PR #1560, since the
function it names no longer exists.

Constraints: this is a pure refactor — run_standdown_checks's external behaviour (what it checks,
what it returns, what it logs) must not change at all. Preserve every existing log-event call and
its exact event name/fields; this codebase's dashboard and pager-invariant logic parse those
events structurally. Do not change any other function in lib/standdown.sh beyond what's needed to
wire the new helpers together.

Verification: run the full lib/standdown.sh test suite (test/standdown.test.sh or equivalent —
check test/ for the actual filename) before and after and confirm byte-identical behaviour on
every existing test case; run a static line-count check confirming no single resulting helper
function exceeds roughly 150-200 lines (a reasonable target given the #964 model's own helper
sizes); confirm `grep -rn "coordinator_corroborate_retry_or_fallback"` still shows only the stale
comment (unrelated to this task, but worth a sanity check that #1256's premise is indeed gone).

Work cost-consciously. Decomposing a 1,340-line function while preserving exact behaviour is
genuinely delicate, cross-cutting work — do the decomposition itself at a high-capability tier.
Writing additional unit tests for the newly-extracted helpers (once their boundaries are decided)
is more mechanical and can be delegated to a mid-cost tier, with the high-capability tier
reviewing that the new tests actually exercise the extracted logic rather than just calling
through to the same code path.

Deliverable: one PR, title e.g. "refactor(standdown): decompose run_standdown_checks into named
helpers", closing agent-ops#2699. Close agent-ops#1256 in the same PR with a comment citing PR
#1560 as the supersession (not a closing keyword, since #1256 isn't being "fixed" by this PR, just
retired as describing dead code).
```

## Prompt for R-16 — Harden `san()` against a bare `..` path segment

**Bundles:** R-16 only · **Run after:** no prerequisites

```text
Context: lib/claim-key.sh's san() function (line 17) sanitizes a string for use as part of a claim
key / path segment. Every current caller (in lib/claim.sh and scripts/sweep-orphan-branches.sh)
happens to append a suffix after calling san(), which incidentally makes a bare ".." result
unexploitable today — but san() itself does not explicitly reject "." or "..".

The problem: a future caller that uses san()'s output directly, without appending a suffix, would
silently inherit a path-traversal-shaped gap.

The goal: san() itself rejects (errors out, or substitutes a safe placeholder — match this
codebase's existing error-handling convention for similar sanitization functions) a bare "." or
".." result, independent of what any particular caller does afterward.

Constraints: do not change san()'s behavior for any currently-valid input — only add a check for
the specific "." / ".." edge case. Keep the fix small and localized to lib/claim-key.sh.

Verification: add test cases to the existing test file covering lib/claim-key.sh confirming "."
and ".." inputs are now rejected/handled safely; confirm all existing callers' test suites
(test for lib/claim.sh and scripts/sweep-orphan-branches.sh) still pass unchanged.

Work cost-consciously. This is small, well-specified, low-risk work and suits a low-cost tier.

Deliverable: one PR, title e.g. "fix(claim-key): reject a bare '.' or '..' in san()", closing
agent-ops#1172.
```

## Prompt for R-17 — Clean up fixture identity hygiene

**Bundles:** R-17 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops's test fixtures (under test/) are supposed to use placeholder GitHub
identities, not real ones. 32 test files currently reference the maintainer's real GitHub
usernames (warwickallen / Warwick-Allen) in fixture data (confirm the current count with `grep -rl
"warwickallen\|Warwick-Allen" test/*.sh | wc -l` — it may have changed since this prompt was
written).

The problem: fixtures carrying a real person's identity are an unnecessary, if low-severity,
privacy exposure and a bad example for anyone using this repository as a reference for writing
their own fixtures.

The goal: every test fixture uses a placeholder identity (e.g. test-user, example-maintainer, or
similar) instead of the maintainer's real GitHub handles, with no change in test behaviour.

Constraints: do not change what any test actually asserts — this is a pure find-and-replace of
identity strings in fixture data, not a behavioral change. Where a test's logic specifically
depends on matching a particular username pattern (e.g. testing CODEOWNERS matching), make sure
the replacement placeholder still satisfies that logic (check the test's assertions, not just its
fixture data, before replacing).

Verification: run the full test suite via ./scripts/run-tests.sh and confirm zero regressions;
re-run the grep above and confirm it returns 0.

Work cost-consciously. This is mechanical, well-specified work (a scoped find-and-replace across a
known file list) and suits a low-cost tier — but verify each replacement against its test's actual
assertions before integrating, since a few of the 32 files may have logic that depends on the
specific string.

Deliverable: one PR, title e.g. "test: replace the maintainer's real GitHub identity in fixtures
with placeholders", closing agent-ops#1174.
```

## Prompt for R-18 — Add `.editorconfig`

**Bundles:** R-18 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops has no .editorconfig file. The project's actual formatting
conventions (indentation style and width, line endings, trailing-whitespace policy, final-newline
requirement) can be inferred from its existing files and from scripts/check-docs.sh / any
lint/format tooling already configured (e.g. the trailing-whitespace check this repository's CI
already runs via `npm run check` or equivalent — check AGENTS.md/CONTRIBUTING.md for the exact
command).

The problem: without a committed .editorconfig, an editor has no machine-readable signal for this
project's conventions, so contributors' editors may auto-apply different indentation/line-ending
defaults.

The goal: a committed .editorconfig at the repository root matching the conventions this project's
existing files and CI checks already enforce (do not invent new conventions — derive them from
what's already true of the codebase).

Constraints: the .editorconfig must not contradict any existing enforced convention (e.g. if CI
already fails on trailing whitespace, the .editorconfig should set trim_trailing_whitespace =
true, not leave it unset).

Verification: apply the new .editorconfig to a sample of existing files in an editorconfig-aware
editor (or the editorconfig-checker CLI tool) and confirm zero reported violations against the
current codebase — an .editorconfig that immediately conflicts with the existing code is worse
than none.

Work cost-consciously. This is small, mechanical, low-risk work and suits a low-cost tier.

Deliverable: one PR, title e.g. "chore: add .editorconfig", closing agent-ops#1758.
```

## Prompt for R-19 — Deduplicate `cfg()`

**Bundles:** R-19 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops has a shared config-reading helper, cfg(), defined once in
lib/config-access.sh (line 20) as `cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG"; }`. Two other files
— lib/claim.sh (line 111) and scripts/sweep-orphan-branches.sh (line 132) — each define their own
local cfg() that additionally suppresses stderr (`2>/dev/null`), diverging from the shared
version's behaviour.

The problem: a future change to the shared cfg()'s error-handling behaviour (e.g. making a missing
key louder) would silently not apply to these two call sites, since they never call the shared
version at all.

The goal: lib/claim.sh and scripts/sweep-orphan-branches.sh both source and use the shared cfg()
from lib/config-access.sh instead of defining their own.

Constraints: before removing either local definition, confirm whether any existing caller in
either file actually relies on the stderr-suppression behaviour (i.e., calls cfg() expecting it to
silently return empty rather than printing a jq error to stderr on a missing/malformed key) — if
so, either fix that caller to handle the louder behaviour explicitly, or document why suppression
is genuinely needed at that one call site rather than removing it blindly.

Verification: run the test suites for both lib/claim.sh and scripts/sweep-orphan-branches.sh (and
any script depending on them) and confirm no regression; grep both files afterward to confirm
no local cfg() definition remains.

Work cost-consciously. This is small, mechanical work with one judgment call (the stderr-behaviour
check above) and suits a mid-cost tier.

Deliverable: one PR, title e.g. "refactor(config): deduplicate cfg() between claim.sh and
sweep-orphan-branches.sh", closing agent-ops#1755.
```

## Prompt for R-20 — Land the ready `publish-dashboard.sh` flaky-test fix

**Bundles:** R-20 only · **Run after:** no prerequisites

```text
Context: test/publish-dashboard.test.sh (line 1545) asserts `run_window 20` against an exact
expected value. Its sibling test in test/state-sync.test.sh had an identical flaky-timing pattern,
already fixed by changing an exact-equality assertion (`ml_age == 0`) to a tolerant one (`ml_age <=
1`) — see test/state-sync.test.sh lines 2045-2046 for the already-landed pattern to replicate.

The problem: test/publish-dashboard.test.sh:1545's exact-equality assertion on a timing-derived
value is flaky under CI runner contention, the same class of flakiness its sibling already fixed.

The goal: test/publish-dashboard.test.sh:1545's assertion tolerates the same kind of timing slack
its sibling fix established, without weakening the test's actual intent (confirming run_window
behaves correctly near its boundary).

Constraints: apply the identical fix shape used in test/state-sync.test.sh — do not invent a
different tolerance mechanism. Keep the tolerance window small enough that the test still catches
a genuine regression in run_window's logic, not just timing noise.

Verification: run test/publish-dashboard.test.sh repeatedly (e.g. 20 times in a loop) under
simulated load/contention if possible, and confirm it no longer flakes; confirm it still fails if
you deliberately break run_window's actual logic (a sanity check that the tolerance isn't so wide
it stops testing anything).

Work cost-consciously. This is a one-line, well-specified fix mirroring an already-proven pattern
and suits a low-cost tier.

Deliverable: one PR, title e.g. "test(publish-dashboard): tolerate timing slack in run_window's
boundary assertion, matching state-sync's existing fix", closing agent-ops#1205.
```

## Prompt for R-21 — Add a memory/cgroup pager invariant

**Bundles:** R-21 only · **Run after:** no prerequisites

```text
Context: lib/pager-invariants.sh defines the conditions under which this pipeline's monitoring
pages a human directly (as opposed to raising an issue the pipeline investigates autonomously
first). It has entries for several host-health conditions but none for a memory-cgroup
`unbounded`/`livelocked` reading. A real instance of this problem (agent-ops#1569) took roughly
nine days and five separate autonomous investigations before a human was ever paged, because the
only path to human involvement was the generic blocked-item escalation threshold, not a direct
page on the dashboard verdict itself.

The problem: the next node whose parent cgroup drifts unconfigured will reproduce that same
multi-day latency, because nothing pages directly on the underlying dashboard-visible condition.

The goal: lib/pager-invariants.sh gains a memory/cgroup entry so that an unbounded or livelocked
memory-cgroup reading pages a human directly, the same way the file's other host-health invariants
already do.

Constraints: follow the exact pattern of an existing host-health pager invariant in this file
(read a couple of the existing entries as your template for the expected shape/fields) — do not
invent a new invariant-definition format. Confirm the exact dashboard field/value that represents
"unbounded"/"livelocked" for a memory cgroup (check how scripts/doctor.sh or the dashboard
publisher currently reports this condition) before wiring the invariant to it.

Verification: add a test case simulating the unbounded/livelocked condition and confirm the new
invariant fires (pages) on it; confirm no existing pager invariant's behavior changes.

Work cost-consciously. This is well-specified work applying an existing documented pattern to one
new condition and suits a mid-cost tier.

Deliverable: one PR, title e.g. "feat(pager): add a memory/cgroup pager invariant", closing
agent-ops#2698.
```

## Prompt for R-22 — Close stale issue `#2326`

**Bundles:** R-22 only · **Run after:** no prerequisites

```text
Context: agent-ops#2326 was filed 2026-10-11, describing
docs/spec/implementation/requirements/the-script-08.md as exceeding the documentation size budget
with no tracking issue. A later, unrelated spec split (agent-ops#2665, merged 2026-10-25) brought
the file back under budget as a side effect.

The problem/goal: confirm the-script-08.md's current size is under the 100,000-byte documentation
size budget (check with `wc -c` and compare against the budget described in docs/README.md §
"Size budget"), and if so, close agent-ops#2326 noting that the-script-09's split (#2665)
incidentally resolved it, so the backlog doesn't carry a stale item describing already-fixed work.

Constraints: this is a pure issue-hygiene task — no code or documentation change is needed if the
file is genuinely under budget. Do not make any edit to the-script-08.md itself.

Verification: run `wc -c docs/spec/implementation/requirements/the-script-08.md` and confirm the
hand-written-content byte count (excluding any generated regions per docs/README.md's measurement
rule) is under 100,000 bytes before closing the issue.

Work cost-consciously. This is a trivial verification-and-close task and suits a low-cost tier.

Deliverable: no code change. Close agent-ops#2326 with a comment citing the current byte count and
agent-ops#2665 as the PR that incidentally resolved it.
```

## Prompt for R-23 — Extract a shared paginated-fetch helper

**Bundles:** R-23 only · **Run after:** no prerequisites

```text
Context: Pullwright/agent-ops's shared GitHub-API-rate-limit layer lives in
lib/github-limit.sh (and the related lib/gh-shim.sh, installed as a PATH shim). The `gh api
... --paginate` idiom is currently re-implemented independently in at least seven call sites:
lib/approver.sh, lib/candidate-select.sh, lib/pipeline-marker.sh, lib/enabler.sh,
scripts/gather-human-visibility-hygiene.sh, scripts/autonomy-stage-report.sh, and
scripts/verdict-fate-report.sh.

The problem: a correctness fix to the pagination idiom (e.g. improved rate-limit handling, a retry
policy) must currently be applied at each of these seven-plus call sites independently rather than
once, and new call sites keep re-implementing it from scratch (including, see agent-ops#1171, the
one in scripts/publish-dashboard.sh that currently has NO pagination at all and is the subject of
a separate recommendation, R-05, in this same review).

The goal: a single `gh_paginated_fetch(endpoint, jq_filter)` function in lib/github-limit.sh,
behaviourally identical to the existing ad hoc idiom (same pagination semantics, same
rate-limit/caching integration via the existing gh-shim layer), with the seven-plus existing call
sites migrated to call it instead of re-implementing it inline.

Constraints: migrate one call site at a time, each as its own, independently-revertible commit —
do not do a single big-bang migration across all seven files in one commit. Each migrated call
site's test suite must show byte-identical output before and after the migration (this is a pure
refactor, not a behaviour change).

Verification: for each migrated call site, run its existing test suite before and after and diff
the output; after all seven are migrated, grep the codebase for `--paginate` outside
lib/github-limit.sh itself to confirm no independent re-implementation remains (aside from
scripts/publish-dashboard.sh's new call, if R-05 is implemented using this same helper rather than
before it — check whether R-05 has already landed, and if not, consider doing R-05's fix using this
new helper directly rather than adding an eighth independent implementation).

Work cost-consciously. Writing the shared helper itself is small but needs to exactly replicate
existing behaviour across seven different existing call patterns, which benefits from a
higher-capability tier for the helper's own design; migrating each individual call site afterward,
once the helper's interface is settled, is mechanical and suits a mid-cost tier, verified
call-site-by-call-site.

Deliverable: one PR introducing gh_paginated_fetch plus a first migrated call site (to prove the
interface works), followed by up to six further small PRs migrating the remaining call sites one
or a few at a time — do not bundle all seven migrations into one large, hard-to-review PR. Title
the first PR e.g. "refactor(github-limit): add a shared gh_paginated_fetch helper", closing
agent-ops#1919 once all call sites are migrated (not on the first PR alone).
```
