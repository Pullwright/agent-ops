# Improvement prompts

One prompt per recommendation, in priority order (severity first, then quick wins before long
campaigns). Each prompt is self-contained and may be pasted into a fresh AI agent session with no
other context. Ordering dependencies, where they exist, are noted in each prompt's **Run after**
line and repeated inside the prompt text itself.

Every prompt below assumes the executing agent works in **this project's own repository
conventions**: clone `Pullwright/agent-ops` fresh (never reuse a shared checkout), work on a
dedicated branch, commit, push, and open a pull request per `AGENTS.md`'s "Branch workflow" and
"Commit messages" sections (Conventional Commits title, since the PR title becomes the squash
commit on `main`) — this is not repeated in each prompt below to save space, but is a hard
constraint on every one of them. Where a prompt's issue is `agent-ops#<n>` and it fully resolves
that issue, the PR must close it with a real closing keyword (`Fixes #<n>`).

## Prompt for R-01 — Resolve the live-secret transcript exposure and close the redaction-coverage gap it exposed

**Bundles:** R-01 only · **Run after:** no prerequisites

```text
Context: agent-ops (Pullwright/agent-ops) is Bash/jq operations tooling for an autonomous
coding-agent pipeline. Its redaction module, lib/redact.sh, is responsible for masking secrets in
cycle transcripts before scripts/state-sync.sh pushes them to an external state-mirror repository,
and before scripts/publish-dashboard.sh publishes dashboard JSON. Two callers currently register
one runtime literal each via redact_add_literal (notify_webhook_url).

The problem: on 2026-09-16, an Implementer stage's `docker compose config` invocation printed a
live Vercel token and GitHub App private-key paths into its own session transcript (issue #1627,
still open 13+ days later with zero comments). lib/redact.sh's shape-based rules (gh*_, github_pat_,
sk-, "Bearer ...") do not match a Vercel token or a filesystem path, and neither is registered via
redact_add_literal, so a recurrence reaching the state-mirror push would not be caught. A follow-up
issue (#1752, filed 2026-09-21) scopes the code fix: register VERCEL_TOKEN and
VERCEL_AUTOMATION_BYPASS_SECRET via redact_add_literal at their one call site,
scripts/preview-deploy.sh (which currently uses VERCEL_TOKEN directly in an Authorization: Bearer
header at line ~281). Separately, docs/DATA-HANDLING.md states operational data is made "safely
shareable for debugging" and that data is "never... shared unless deliberately pushed... by the
operator" — both readings overstate what the mirror-push redaction pass actually guarantees.

The goal (read #1627 and #1752 on GitHub first for the full, authoritative context and any
maintainer comments since this review was written):
1. Determine and record whether the exposed Vercel token and GitHub App private-key paths need
   rotation. This is very likely an owner-only decision (per #1627's own framing) — if you cannot
   make this call yourself, post a clear comment on #1627 laying out the decision needed and do not
   block the rest of this work on it.
2. Register VERCEL_TOKEN and VERCEL_AUTOMATION_BYPASS_SECRET via redact_add_literal at
   scripts/preview-deploy.sh's use of them, following the exact pattern notify_webhook_url already
   uses in scripts/state-sync.sh and scripts/publish-dashboard.sh.
3. Update docs/DATA-HANDLING.md's redaction paragraph to state precisely what is and isn't covered:
   a fixed set of shape rules plus explicitly-registered runtime literals — not a blanket
   "safe to share" or "never shared" claim — cross-referencing #1752.

Constraints: do not weaken any existing redaction rule. Do not change the redaction pass's
architecture (shape rules + explicit registration) — only extend its registered-literal set and
correct the documentation's claims about it. Follow the file's existing comment style.

Verification: run the existing redaction test suite (test/redact.test.sh, test/state-sync.test.sh,
test/publish-dashboard.test.sh) via `bash test/<name>.test.sh` (this repo's suite needs Docker for
a fully faithful run via scripts/run-tests.sh — use that if available, otherwise run the specific
files directly with jq 1.7). Add a new assertion confirming a VERCEL_TOKEN-shaped value is masked
in scripts/preview-deploy.sh's output path. Confirm docs/DATA-HANDLING.md's wording no longer makes
an unqualified "safe"/"never shared" claim.

Work cost-consciously. Where your environment supports subagents, delegate the mechanical
redact_add_literal registration and its test to a mid-cost tier (it follows an exact existing
pattern). Do the doc-wording edit and the #1627 rotation-decision framing yourself at a
high-capability tier, since getting a security document's claims precisely right matters more than
speed here. Verify all delegated work before integrating it.

Deliverable: a pull request that closes #1752 with a real closing keyword, references #1627 without
closing it (unless you also completed the rotation/sandboxing decision, which is unlikely to be
yours to make), and includes the redaction registration, its test, and the DATA-HANDLING.md wording
fix.
```

## Prompt for R-02 — Make the config-table/toc AND changelog-section checks actual required merge gates

**Bundles:** R-02 only (config-table/toc and changelog-section share the identical remediation
pattern and sequencing constraint, so fixing them together avoids doing the same `merge_group:`
research twice) · **Run after:** no prerequisites

```text
Context: agent-ops (Pullwright/agent-ops) has three GitHub Actions workflows that check generated
or structured content on every pull request but do not block the merge if they fail:
.github/workflows/config-table.yml, .github/workflows/toc.yml, and
.github/workflows/changelog-section.yml. None of the three currently appears in the repository's
branch ruleset (id 18857310 at review time — re-fetch the live ruleset yourself, do not assume this
ID is still current) required-status-check list, and none has a merge_group: trigger, which is a
prerequisite: without it, a PR sitting in a merge queue would stall for the check's full timeout
before ever running it there.

The problem: issue agent-ops#1144 records the owner's own binding decision for config-table/toc:
"(1) add a merge_group: trigger to the workflow — ordinary work, do it now; (2) only after that
lands on main, the owner adds the check to the ruleset's required contexts by hand — do not do (2)
first." Read #1144 in full for the exact rationale. Issue agent-ops#1916 (filed by this review)
documents the identical gap for changelog-section.yml specifically — its own workflow header
already states the requirement, and scripts/doctor.sh's own acceptance check (requirement 25c)
already detects and warns about the gap live.

The goal: add a merge_group: trigger to all three workflows' `on:` blocks (step 1 of #1144's
sequencing, extended to changelog-section.yml). Do NOT attempt step 2 (editing the branch ruleset)
yourself — that is an explicit owner-only action per #1144's own text (requirement 36a); your job
ends at making all three workflows merge_group:-triggerable.

Constraints: match the merge_group: trigger shape already used by this repo's one check that is
both required and merge_group:-enabled today (tech-debt-register.yml — read it as the reference
pattern). Do not change any other trigger behaviour of these three workflows. Do not touch the
branch ruleset itself.

Verification: confirm each workflow file is valid YAML and that its merge_group: trigger fires on
the same events/paths the existing pull_request: trigger does (a config change should trigger both
identically). If this environment lets you inspect GitHub Actions workflow syntax via `gh workflow
view` or similar, use it; otherwise a careful manual read against tech-debt-register.yml's working
example is sufficient — this is not something you can safely execute end-to-end without merging.

Work cost-consciously. This whole task suits a low-cost tier: it is a mechanical, well-specified
edit to three YAML files following one already-proven pattern in the same repository.

Deliverable: a pull request that closes agent-ops#1916 with a real closing keyword and references
(does not close) agent-ops#1144, since #1144's own text reserves closing it for after the owner
completes step 2.
```

## Prompt for R-03 — Fix `publish-dashboard.sh`'s silent unknown-flag swallowing; add `--help` to `monitor-cycle.sh`

**Bundles:** R-03 only (both fixes share the exact same established pattern and issue) · **Run
after:** no prerequisites

```text
Context: agent-ops (Pullwright/agent-ops) has three top-level pipeline entry points:
agent-cycle.sh, review-cycle.sh, and monitor-cycle.sh, plus scripts/publish-dashboard.sh. The first
two, and scripts/check-node-compose.sh, all error loudly on an unrecognised command-line flag and
answer -h/--help with real usage text (see review-cycle.sh's usage() function for the model to
follow). scripts/publish-dashboard.sh and monitor-cycle.sh do not.

The problem, fully scoped already on issue agent-ops#1753 (read it first — it may carry updates
since this review): scripts/publish-dashboard.sh's flag-parsing loop ends with a bare `*) shift ;;`
catch-all, so any unrecognised flag — including -h or --help — is silently discarded and a full
(possibly minutes-long, GitHub-API-consuming) dashboard rebuild runs anyway. monitor-cycle.sh
already errors loudly on an unknown flag (exit 64 with a message) but has no -h|--help case or
usage() function at all.

The goal:
1. In scripts/publish-dashboard.sh, replace the `*) shift ;;` catch-all with a loud error (print to
   stderr, exit non-zero) matching monitor-cycle.sh's existing pattern, and add a -h|--help case
   that prints a usage summary of the script's actual flags (--no-github, --fast, --now, and any
   others currently supported) and exits 0.
2. In monitor-cycle.sh, add a usage() function and a -h|--help case, modelled directly on
   review-cycle.sh's usage() (synopsis line, one-line description, a pointer to
   docs/MONITOR-PIPELINE-SPEC.md, per-flag descriptions).

Constraints: do not change either script's behaviour for any currently-valid flag combination.
Match each file's existing code style exactly (indentation, quoting conventions, error-message
phrasing already used elsewhere in the same file).

Verification: run `scripts/publish-dashboard.sh --bogus-flag` and confirm it now errors instead of
rebuilding; run `scripts/publish-dashboard.sh -h` / `--help` and confirm it prints usage and exits
0 without touching GitHub or the dashboard output. Same two checks for monitor-cycle.sh. Add or
extend test/publish-dashboard.test.sh and a monitor-cycle test file with assertions for both new
behaviours, following the suite's existing conventions (see test/review-cycle.test.sh's -h test for
a model).

Work cost-consciously. This whole task suits a low-cost tier: it is mechanical, follows an exact
pattern already implemented twice in this repository, and needs no design judgment.

Deliverable: a pull request that closes agent-ops#1753 with a real closing keyword.
```

## Prompt for R-04 — Refresh the vendored project-review skill's provenance stamp and add a drift-check

**Bundles:** R-04 only · **Run after:** no prerequisites

```text
Context: agent-ops (Pullwright/agent-ops) vendors a copy of an upstream Claude Code skill
("project-review") for its repository-review pipeline. docs/REVIEW-PIPELINE-SPEC.md documents this
vendored copy's provenance — an upstream commit hash and a "vendored on <date>" claim.

The problem, fully scoped on issue agent-ops#1146 (read it first for the exact current wording and
any updates since this review): the provenance stamp in docs/REVIEW-PIPELINE-SPEC.md is stale — it
names a vendoring date/commit that predates at least two real in-repo edits to the skill's own
content since (made directly in this repository, not re-synced from upstream). No automated check
catches this drift; the issue has been open, fully scoped, and unassigned for 29+ days across four
consecutive project reviews.

The goal: (1) correct the provenance stamp in docs/REVIEW-PIPELINE-SPEC.md to accurately describe
the skill's current state — either the actual last-synced upstream commit/date if it can be
determined, or a rephrasing that doesn't make a falsifiable point-in-time claim if the skill has
diverged enough that "vendored from commit X" is no longer meaningful; and (2) add a lightweight
drift-check, even a minimal one (a PR-template checklist item, or a CI step that flags any commit
touching the skill's files without a corresponding spec update), so this specific class of
staleness doesn't silently recur a fifth time.

Constraints: do not change the skill's actual content — this is a documentation-accuracy fix only.
Follow docs/REVIEW-PIPELINE-SPEC.md's existing prose style and the "as-built" documentation
convention in AGENTS.md (state what is, not history — put any historical framing in the PR's
Changelog section instead).

Verification: read the actual skill files in the repository and confirm the corrected provenance
stamp matches what you find. If you add a CI-based drift-check, confirm it actually fires on a
test change to the skill's files (dry-run its logic, or point to an existing similar check in this
repo's workflows as your evidence it works).

Work cost-consciously. This whole task suits a low-cost tier for the stamp correction itself; use a
mid-cost tier only if you design a CI-based drift-check from scratch (a PR-template checklist line
is the cheaper, sufficient option if you're unsure).

Deliverable: a pull request that closes agent-ops#1146 with a real closing keyword.
```

## Prompt for R-05 — Add an update mechanism, pin floating images/tags, and SHA-pin high-privilege Actions steps

**Bundles:** R-05 only (agent-ops#1145's three sub-items plus the new SHA-pinning item share one
underlying theme — agent-ops's own supply-chain hygiene — but are independent enough to land as
separate commits within one PR, or as separate PRs if you prefer smaller units) · **Run after:** no
prerequisites

```text
Context: agent-ops (Pullwright/agent-ops) is a Bash/jq project with no package manifest; its
supply chain is GitHub Actions (.github/workflows/*.yml), a Dockerfile
(deploy/docker/Dockerfile), and Compose sidecar images (deploy/docker/compose.yaml). The
Dockerfile already pins supercronic and shellcheck to an exact release AND verifies a checksum at
build time — that is the bar the rest of the supply chain does not yet meet.

The problem, tracked on agent-ops#1145 (three items) and agent-ops#1918 (one item, filed by this
review — read both first):
1. No .github/dependabot.yml or Renovate config exists anywhere, so every Actions `uses:` version
   and Dockerfile ARG is bumped only by hand.
2. deploy/docker/compose.yaml pins `tailscale/tailscale:latest` and
   `containrrr/watchtower:latest` with no version pin at all, unlike every other image reference in
   the same file.
3. Every `uses:` line across all ~10 action-consuming workflow files references a mutable version
   tag (e.g. actions/checkout@v7), not a commit SHA — including docker/login-action and
   docker/build-push-action, which hold registry-push credentials on every push to main.

The goal:
1. Add .github/dependabot.yml with at minimum a `github-actions` ecosystem entry (per #1145's own
   scoping comment, which explicitly excludes the Docker base image and curl-fetched binary
   versions as a separate concern — do not try to solve those with Dependabot).
2. Pin `tailscale/tailscale` and `containrrr/watchtower` in compose.yaml to a specific version tag
   (not `latest`, not necessarily a digest — match the pinning style of every other image reference
   in the same file).
3. Pin docker/login-action and docker/build-push-action (the two steps holding registry-push
   credentials) to commit SHAs, with a trailing comment noting the tag each SHA corresponds to
   (e.g. `uses: docker/build-push-action@<sha> # v7`).

Constraints: do not change any image's actual version to something untested — pin to the version
currently in use unless you have a specific reason (and evidence) to bump it. Do not attempt to
SHA-pin every workflow's every action in this pass — start with the two credential-holding steps
named above; a broader SHA-pinning sweep can be a follow-up.

Verification: confirm dependabot.yml is valid (GitHub's schema, `github-actions` ecosystem,
sensible schedule). Run `docker compose config` against compose.yaml if Docker is available in your
environment to confirm the file still parses after the pin; otherwise a careful manual YAML check
is sufficient. Confirm each SHA you pin actually corresponds to the tag you cite in its comment (look
up the tag's commit on GitHub).

Work cost-consciously. The dependabot.yml addition and the two image-tag pins suit a low-cost tier
(mechanical, well-specified). Verifying and pinning the two SHA references yourself (not delegated)
is worth the extra care, since an incorrect SHA silently breaks the build/push pipeline.

Deliverable: a pull request that closes agent-ops#1145 and agent-ops#1918 with real closing
keywords.
```

## Prompt for R-06 — Paginate `publish-dashboard.sh`'s open-issues fetch for the Priority display

**Bundles:** R-06 only · **Run after:** no prerequisites

```text
Context: agent-ops's scripts/publish-dashboard.sh fetches a repository's open issues via `gh api`
to populate a Priority display used by the Co-Ordinator's own ranking logic downstream.

The problem, scoped on agent-ops#1171 (read it first): the fetch uses `per_page=30` with no
`--paginate`, so a repository with more than 30 open issues silently truncates the Priority display
past the 30th-newest. A prior partial fix added a separate total-count display so the panel no
longer *understates* the count, but the per-issue Priority detail itself is still capped.

The goal: make the Priority display reflect the full open-issue set, using the same
`api_json_paged`-style helper already proven in this codebase for the identical bug class (see
scripts/gather-source-state.sh's `api_json_paged` for the reference implementation) — or, if you
determine the cost genuinely isn't justified (e.g. performance concerns at scale), explicitly
document the 30-row cap as an accepted trade-off in the script's own comments instead. Prefer the
fix unless you find a concrete reason not to.

Constraints: do not change the Priority field's own computation logic, only how many issues feed
it. Match the existing `api_json_paged` helper's calling convention rather than inventing a new
pagination approach.

Verification: test against a repository (or a synthetic fixture) with more than 30 open issues and
confirm the Priority display now includes issues beyond the 30th. Add or extend
test/publish-dashboard.test.sh with a fixture asserting this.

Work cost-consciously. This whole task suits a mid-cost tier: it's ordinary implementation against
a clear acceptance criterion, reusing an existing helper.

Deliverable: a pull request that closes agent-ops#1171 with a real closing keyword.
```

## Prompt for R-07 — Bound the rest of `state-sync.sh`'s `do_push` and wrap `gh` API calls with a timeout

**Bundles:** R-07 only (both halves share the same root cause — unbounded outbound calls holding
pipeline state — per agent-ops#1701's own framing) · **Run after:** no prerequisites

```text
Context: agent-ops's scripts/state-sync.sh pushes cycle-transcript state to an external
state-mirror repository under `mirror_lock`. A prior fix (closing #1679) wrapped only the
redaction loop inside `do_push` with a `mirror_run_with_deadline` helper, after a real 7-hour
production wedge incident.

The problem, scoped on agent-ops#1701 and agent-ops#1604 (read both first): `do_push`'s
`mirror_init` git fetch, both `rsync -a --delete` passes, and the final `mirror_write push` (a git
push) all still execute after `mirror_lock` is taken and before any deadline applies — any one of
them hanging (a DNS stall, a proxy hang) wedges the lock indefinitely, the same failure class
#1679 already proved happens on this transport. #1701's own analysis explicitly rules out wrapping
each command individually with `timeout`(1) as insufficient (it would still leave the rsync passes
effectively unbounded in aggregate). Separately, a repo-wide grep of every `gh api`/`gh pr`/`gh
issue`/`gh repo`/`gh graphql` invocation (58+ files, including the `gh` shim itself) found zero
`timeout`(1) wrappers anywhere, even though `run_claude_stage`, the Vercel preview probes, and the
notify-webhook POST are all already time-bounded.

The goal:
1. Wrap the entirety of `do_push`'s lock-holding body (fetch, both rsync passes, the final push) in
   `mirror_run_with_deadline`, per #1701's own recommended approach — not per-command `timeout`.
2. Add retry-with-backoff for transient network failures on the push path, per #1604's spec (up to
   3 attempts, 5s/15s backoff, retrying only transient network-class failures, not permanent ones).
3. Wrap `gh` invocations in the shared `gh` shim with an outer `timeout`(1) so a hung API call fails
   the same way a hung Claude stage already does, rather than hanging indefinitely.

Constraints: preserve `do_push`'s existing atomicity guarantees — a partial push must still leave
the mirror in a recoverable state, not a corrupted one. Do not change the redaction loop's own
existing deadline behaviour, only extend the same pattern to the rest of the function. Choose
timeout durations conservatively (long enough that a normal push never times out; short enough that
a genuine hang is caught well inside any watchdog this pipeline already has for the whole cycle —
check lib/stage-budget.sh for what that ceiling is).

Verification: run the existing test/state-sync.test.sh suite and extend it with a fixture that
simulates a hanging git/rsync/gh call (e.g. via a stub that sleeps past the deadline) and asserts
the deadline fires and `mirror_lock` is released rather than held indefinitely. Document your chosen
timeout values and the reasoning for them in a code comment, matching this codebase's existing
practice of citing the incident that motivated a constant.

Work cost-consciously. The `mirror_run_with_deadline` wrapping is mechanical (mid-cost tier,
following the redaction loop's own proven pattern). Choosing the retry/backoff logic and the timeout
durations is more judgment-dependent — do that part yourself at a high-capability tier, or have a
mid-cost-tier subagent draft it and review the result carefully, since getting the failure-recovery
logic wrong here directly risks data loss or a worse wedge than the one being fixed.

Deliverable: a pull request that closes agent-ops#1701 and agent-ops#1604 with real closing
keywords.
```

## Prompt for R-08 — Grant the Reviewer stage read/rerun access to CI logs and jobs

**Bundles:** R-08 only · **Run after:** no prerequisites

```text
Context: agent-ops's autonomous Reviewer stage (see prompts/reviewer.md) reviews pull requests
raised by the Implementer stage against this repository's own CI. Its sibling, prompts/implementer.md,
already documents a route for reading a failing run's log; prompts/reviewer.md does not.

The problem, scoped on agent-ops#1496 (read it first — it carries a concrete incident, PR #1494,
where a plausible flake cost a full ~25-minute re-run via an empty commit because the Reviewer
could neither read the failure's log nor re-run just that job): the pipeline's GitHub App
installation lacks the `actions: write` permission needed to re-run a job, and this environment's
egress proxy blocks the Actions log-blob storage host needed to read a log's full content.

The goal: this is primarily a permissions/infrastructure decision, not a code change — #1496
proposes granting `actions: read`/`actions: write` to the App installation and allowlisting the
log-blob host through the egress proxy. If you have the access to make these two changes, make
them and verify a Reviewer-stage session can then successfully call `gh run view --log` and `gh run
rerun --failed` against a real failing run. If you do NOT have this access (most executing agents
will not — these are owner-level infrastructure changes), your deliverable is instead: (a) confirm
#1496's proposed fix is still accurate against the current App installation's permissions and the
current proxy configuration, and (b) update prompts/reviewer.md with the exact log-read/rerun
procedure prompts/implementer.md already documents, so the prompt-side half of the fix is ready the
moment the permissions land — do not wait for the infrastructure change to write the
prompt-side documentation.

Constraints: do not attempt to work around the missing permissions with an unofficial channel
(e.g. scraping a log through an unintended route) — wait for the proper grant, or document what's
needed and stop there.

Verification: if you made the permissions/proxy changes, verify with a real `gh run view --log` and
`gh run rerun --failed` call against a genuinely failing run. If you only updated the prompt, verify
its wording is consistent with prompts/implementer.md's existing equivalent section.

Work cost-consciously. The prompt-file documentation update suits a low-cost tier (it's copying an
established pattern from a sibling file). The permissions/infrastructure decision, if you have the
access to make it, warrants your own direct attention rather than delegation, since it's a
security-relevant access grant.

Deliverable: if you completed the full fix, a pull request that closes agent-ops#1496 with a real
closing keyword. If you only completed the prompt-side half, a pull request that references (does
not close) #1496 and clearly states in its description what remains (the App-permission grant and
proxy allowlisting).
```

## Prompt for R-09 — Extend the proven `jq` streaming fix to `publish-dashboard.sh`'s remaining full-log reads

**Bundles:** R-09 only · **Run after:** no prerequisites

```text
Context: agent-ops's scripts/publish-dashboard.sh renders a fleet dashboard from a never-rotated
event log, log.jsonl, which grows for a node's entire lifetime by design (see
scripts/rotate-logs.sh's own comment explaining why this file is exempt from rotation). A prior fix
(issue #982, applied to lib/crash-loop.sh and siblings) replaced a full-array-materializing
`jq -sc`/`jq -R -s` slurp read with a streaming `jq -n 'inputs'` form, cutting parse time by roughly
1000x on a real-world log size and — more importantly — capping the reader's peak memory
independent of log size.

The problem, tracked on agent-ops#1649 (read it first): scripts/publish-dashboard.sh:1110 (line
number approximate — locate the exact `jq -sc '.' "$events_jsonl"` call in the current file) still
uses the old slurp form. This is not merely a latency concern: it is the documented, measured cause
of two real fleet-wide memory-livelock incidents (issues #1620 and #1643, both now closed) because
the reader's working set is a direct linear function of log.jsonl's size, and that size only grows.
A different PR (#1635) fixed an unrelated memory coupling in the same script but did not touch this
line.

The goal: convert scripts/publish-dashboard.sh's remaining full-log `jq -sc`/`jq -s` reads to the
same `-n`/`inputs` streaming form already proven in lib/crash-loop.sh and lib/stage-health.sh.
Where a read does more than a flat pass (e.g. a windowed fold like `item_lifecycle_fold`, if it
exists in the current file — check), convert it to a streaming fold using `inputs` and `reduce`
rather than slurping first, following #1649's own outline for the harder cases.

Constraints: the converted reader must produce byte-identical output to the current slurp-based
reader for the same input (this is a performance/memory fix, not a behaviour change) — write a
differential test if the existing test suite doesn't already give you this guarantee. Do not change
log.jsonl's own format or the rotation policy.

Verification: run test/publish-dashboard.test.sh and confirm all existing assertions still pass
unchanged. Add a test that measures (or at least demonstrates) that the converted reader's memory
use no longer scales with an artificially large input log.jsonl fixture, if your environment lets
you measure memory; otherwise, at minimum, confirm output identity between the old and new logic on
a realistic fixture before removing the old code path.

Work cost-consciously. The straightforward slurp-to-streaming conversions suit a mid-cost tier
(mechanical, following an exact proven pattern). If a windowed-fold case exists and needs a genuine
streaming-algorithm redesign, do that part yourself at a high-capability tier rather than
delegating it, and verify the differential-output test passes before considering it done.

Deliverable: a pull request that closes agent-ops#1649 with a real closing keyword.
```

## Prompt for R-10 — Resolve the memory-cgroup unbounded/livelocked remediation gap

**Bundles:** R-10 only · **Run after:** no prerequisites

```text
Context: agent-ops runs a fleet of containerized nodes, each with a memory cgroup ceiling meant to
bound a runaway process. lib/memory.sh computes a `memory_cgroup_verdict` (e.g. "ok",
"unbounded", "livelocked") published hourly to the dashboard and the Monitor's own digest.

The problem, tracked on agent-ops#1569 and agent-ops#1639 (read both in full — #1569 in particular
carries five separate investigation comments spanning multiple weeks and nodes; do not re-derive
what they already establish): a live node has run with no parent memory ceiling and a climbing
`oom_kill_count` for an extended period, because the only known fix
(scripts/cgroup-parent-setup.sh) explicitly refuses to run inside a container (it checks for
/.dockerenv and exits) and needs root/host access that no container in this architecture has. Every
investigation so far reaches the same dead end. Separately, #1639 shows cgroup-parent-setup.sh's
own shipped default configuration (`--max 1536m`) produces exactly the "livelocked" shape its
sibling detection code now warns about — a self-inconsistency independent of the host-access
question. Finally, lib/pager-invariants.sh — the module that pages a human for a defined set of
sustained bad conditions — has no entry for memory/cgroup at all, so this verdict, however bad it
gets, never escalates beyond the dashboard.

The goal, in two independent pieces (do the second even if the first isn't yours to decide):
1. (Likely owner-only architecture decision — see #1569's own "option 1 vs option 2" framing) Give
   the pipeline a narrowly-scoped, privileged path to apply the cgroup-parent fix itself, OR decide
   and document that this genuinely requires host-operator intervention going forward. If this
   decision isn't yours to make, post your analysis as a comment on #1569 rather than guessing.
2. (Independently actionable) Fix cgroup-parent-setup.sh's shipped default so it no longer produces
   the livelocked shape its own sibling code warns about (#1639's specific, narrower fix — read its
   comment for the exact number to change). Then add a `memory`/`cgroup` entry to
   lib/pager-invariants.sh so a sustained "unbounded" or "livelocked" verdict, or a rising
   `oom_kill_count` trend, pages a human the way this module's other invariants already do — this
   does not require solving the host-access problem, only making the existing detection actually
   escalate.

Constraints: do not attempt to give any pipeline stage broader host/root access than the specific,
narrow grant #1569's own framing calls for — err on the side of documenting the need rather than
improvising a workaround with wider blast radius. Match lib/pager-invariants.sh's existing
invariant structure exactly when adding the new entry.

Verification: for the #1639 default fix, confirm the new default no longer reproduces the
livelocked shape under the same conditions the sibling detection code checks for (read that code to
understand its exact trigger condition, then verify against it). For the new pager invariant, add a
test modelled on an existing invariant's test in the pager-invariants test file, confirming it fires
under a synthetic "unbounded"/"livelocked" verdict and does not fire under "ok".

Work cost-consciously. The #1639 default-value fix and the new pager invariant both suit a
mid-cost tier (each follows an existing pattern in the same files). The host-access architecture
question is inherently a judgment call for a high-capability tier or the owner directly — do not
delegate it to a low-cost pass.

Deliverable: a pull request. If you completed only the #1639 fix and the new pager invariant, close
agent-ops#1639 with a real closing keyword and reference (do not close) #1569, clearly stating in
the PR description that the host-access decision remains open.
```

## Prompt for R-11 — Action agent-ops#1756's decomposition items; keep pace with god-function growth

**Bundles:** R-11 only (large effort; expect this to be split into several PRs, one per function or
region, matching this codebase's own established decomposition pattern) · **Run after:** no
prerequisites

```text
Context: agent-ops's agent-cycle.sh (the main autonomous work-loop entry point) and several
lib/*.sh files have grown a set of oversized "stage-orchestration" functions over successive
review cycles. One of an original seven flagged functions (maybe_run_refiner) has already been
fully decomposed as a model to follow (see its PR, #1258, for the pattern: extracting named helper
functions from one large function without changing behaviour).

The problem, tracked on agent-ops#1756 (read it first — it was filed specifically to catch up four
outstanding items and has itself had zero activity since being filed, which this review flags as a
notable stall in its own right):
1. `run_standdown_checks` (in lib/standdown.sh) has grown to roughly 1,000+ lines (check the
   current file for the exact figure) and has no tracking issue of its own yet.
2. `compute_skip_lists` (in lib/candidate-gather.sh) is similarly oversized with no tracking issue.
3. `monitor-cycle.sh`, the newest pipeline entry point, was built with the same undecomposed flat
   top-level-script shape as agent-cycle.sh, rather than following review-cycle.sh's already-proven
   decomposed structure (review-cycle.sh keeps its own top-level flow to a small fraction of its
   total size — read it to see the target shape).
4. Issue #1256 still names `coordinator_corroborate_retry_or_fallback`, a function that no longer
   exists in the codebase (superseded by a redesign in PR #1560) — it needs correcting or closing.
Separately, agent-ops#1254 and agent-ops#1255 already track `maybe_run_enabler` and
`run_approver_stage` respectively, both of which have grown further since being filed — read those
issues too if you pick up either function.

The goal: pick ONE of the above items per pull request (this is explicitly meant to be several
small, independently-reviewable PRs, not one large one, matching this codebase's own established
convention). For a decomposition target, extract named, single-purpose helper functions from the
oversized function, following maybe_run_refiner's PR #1258 as your structural model, with zero
behaviour change. For monitor-cycle.sh, decompose its flat top-level regions into named functions
following review-cycle.sh's structure specifically (not agent-cycle.sh's, which is itself part of
this same defect). For #1256, either correct it to name the actual current god-function that most
resembles its original concern, or close it with an explanation that its target no longer exists.

Constraints: zero behaviour change in any decomposition PR — this is a refactor, not a feature or
bug fix. Preserve every existing test's passing status exactly. Do not decompose more than one
function/region per PR — smaller, reviewable units are the explicit goal here, not a
nice-to-have.

Verification: run the full existing test suite relevant to the file you touched (e.g.
test/standdown.test.sh for run_standdown_checks) before and after your change and confirm identical
results. For a shellcheck-clean codebase, also run `shellcheck` against your changed file and
confirm it remains clean.

Work cost-consciously. Filing the two missing issues (for run_standdown_checks and
compute_skip_lists, per #1756's own item list) suits a low-cost tier — it's pure issue-writing
following an existing template (look at #1254/#1255 as models for the issue body shape). The actual
decomposition work is ordinary refactoring against a clear zero-behaviour-change acceptance
criterion — a mid-cost tier, with your own (higher-capability) review of the diff before it's
proposed, since a subtle behaviour change hidden in a "pure" refactor is exactly the kind of bug
that's easy to miss and costly to ship in a stage-orchestration function.

Deliverable: one pull request per decomposition unit. If your PR fully completes one of #1254,
#1255, or a newly-filed issue for run_standdown_checks/compute_skip_lists, close it with a real
closing keyword. Do not attempt to close agent-ops#1756 itself in a single PR — only once all four
of its items are done should it be closed, and that is unlikely to happen in one pass.
```

## Prompt for R-12 — Fix README's crontab duplicated-path typo; widen the org-name-drift sweep

**Bundles:** R-12 only (both are single-line documentation fixes in the same file family) · **Run
after:** no prerequisites

```text
Context: agent-ops's README.md documents how to install and operate the pipeline, including a
"Keep it fresh" section giving a crontab line to periodically refresh the dashboard. The repository
itself was transferred from the `Poetic-Poems` GitHub organisation to `Pullwright` (commit
`cfa8f0b`), and most references to the old org name were updated at that time.

The problem: (1) the crontab line in README.md's current, non-legacy "Keep it fresh" section
duplicates the `Poetic-Poems` org segment in its own example path (search README.md for
"Poetic-Poems/Poetic-Poems" to find it) — a currently-active install instruction, so copying it
verbatim installs a crontab entry pointing at a path that does not exist, and the dashboard's
periodic refresh then silently never fires (cron redirects stderr to a log nobody is told to check
for this specific failure). (2) Separately, agent-ops#1870 already tracks eight locations across
README.md and both pipeline specs that still say `Poetic-Poems/agent-ops` instead of
`Pullwright/agent-ops` — but it does not cite README.md's own intro-sentence link (near the top of
the file) or one example command in the "legacy, decommissioned" host-install section, both of
which also still name the old org.

The goal: (1) fix the duplicated `Poetic-Poems` segment in the "Keep it fresh" crontab line so it
matches the correct install path used elsewhere in the same document. (2) Read agent-ops#1870 for
its current scope and exact list of locations; if it hasn't already been widened, fix the two
additional locations this review found (the intro-sentence link and the legacy-section example)
in the same pass, alongside whatever #1870 itself already asks for.

Constraints: change only the specific incorrect path/org-name text — do not otherwise reword these
sections. In the legacy-section example, preserve its existing "this is retired, kept as a record"
framing; only the org name in the example itself should change.

Verification: grep README.md and both specs for "Poetic-Poems" after your change and manually
confirm every remaining hit is either (a) a correct historical reference explicitly marked as such,
or (b) genuinely out of scope (e.g. referring to the `Poetic-Poems/poetic` product repository, which
is a real, still-current org/repo and should NOT be changed — only `agent-ops`'s own former home
under that org is stale). Do not blanket-replace every occurrence of the string without checking
this distinction.

Work cost-consciously. This whole task suits a low-cost tier: it is mechanical text correction with
one important judgment call (distinguishing agent-ops's own stale org references from legitimate,
current references to the separate `Poetic-Poems/poetic` product repository) that is simple enough
to check by reading context around each match rather than requiring escalation.

Deliverable: a pull request that closes the new crontab-typo issue (agent-ops#1917) with a real
closing keyword, and that either closes agent-ops#1870 (if this PR completes its full scope) or
references it (if #1870's other locations are left for a separate pass).
```

## Prompt for R-13 — Add `openssl` to `doctor.sh`'s toolchain check

**Bundles:** R-13 only · **Run after:** no prerequisites

```text
Context: agent-ops's scripts/doctor.sh runs a set of health checks on a node, including a
"Toolchain" check that verifies required binaries are present (currently checking for at least
bash, jq, git, curl, perl, python3, rsync, flock, timeout — read the current loop to confirm the
exact list). lib/approver-token.sh hard-depends on `openssl` for RS256 JWT signing when minting a
GitHub App installation token, and the project's own Dockerfile installs openssl specifically for
this reason (its comment says so).

The problem, scoped on agent-ops#1147 (read it first): doctor.sh's toolchain loop does not check
for openssl's presence, so a node missing it (e.g. a stripped custom base image, or a bare host
install outside the shipped Docker image) only discovers the gap when a credential-minting call
fails mid-cycle, rather than getting a doctor warning ahead of time.

The goal: add openssl to doctor.sh's toolchain check, but gate the check on whether it's actually
needed — per #1147's own comment, only fail (not merely warn) if the node's configuration has any
`merge_autonomy` source set above `human` (check lib/config-access.sh or wherever
`merge_autonomy_sources` is already computed for the exact function/variable to reuse — do not
duplicate that logic).

Constraints: match the existing toolchain loop's exact structure and messaging style (read a few
of its existing entries for the pattern). Do not make this check unconditionally fatal — a node
that never approves anything above human autonomy has no need for openssl and should not be broken
by this change.

Verification: run scripts/doctor.sh on a node/container both with and without openssl present (or
simulate its absence, e.g. by temporarily adjusting PATH) and confirm the check fires exactly when
merge_autonomy is configured above human and openssl is missing, and stays silent otherwise. Add a
test to test/doctor.test.sh covering both branches.

Work cost-consciously. This whole task suits a low-cost tier: a one-line addition to an existing
loop, gated on an existing helper, following an established pattern.

Deliverable: a pull request that closes agent-ops#1147 with a real closing keyword.
```

## Prompt for R-14 — Harden `san()` (`lib/claim-key.sh`) against a bare `..` path segment

**Bundles:** R-14 only · **Run after:** no prerequisites

```text
Context: agent-ops's lib/claim-key.sh defines a `san()` helper used to sanitise identifiers before
they become part of a filesystem path (e.g. in claim-registry paths built by lib/claim.sh). Its
current implementation only replaces `/` with `__` — it does not reject a bare `.` or `..` input.

The problem, scoped on agent-ops#1172 (read it first): every current caller happens to append a
filename suffix after calling san() (e.g. `printf 'claims/%s/%s.json' "$(san "$1")" "$(san "$2")"`),
which makes a bare `..` currently unexploitable as a path-traversal vector — but this safety
property is an accident of caller discipline, not something san() itself guarantees, so a future
caller that doesn't follow the same pattern could reintroduce a real vulnerability.

The goal: make san() itself reject or neutralise a bare `.` or `..` input (after the `/`→`__`
substitution, an input that is now exactly `.` or `..` should be treated as invalid), independent of
what any caller does afterward.

Constraints: do not change san()'s behaviour for any currently-valid input — only add handling for
the specific `.`/`..` edge case. Decide (and clearly document in a code comment) whether an invalid
input should cause san() to fail loudly (e.g. return non-zero / print to stderr) or substitute a
safe placeholder — prefer failing loudly, consistent with this codebase's general fail-closed
security posture (see lib/redact.sh's own header for an example of this project's stated
preference), unless a specific caller genuinely cannot tolerate that.

Verification: add unit tests to a claim-key/claim test file covering san(".") and san("..") inputs,
confirming they're now rejected/neutralised, and confirming every currently-passing test for normal
inputs still passes unchanged. Trace every current caller (lib/claim.sh,
scripts/sweep-orphan-branches.sh, and any others found via grep) and confirm none of them breaks
under the new behaviour.

Work cost-consciously. This whole task suits a low-cost tier: a small, well-specified function
change with a clear test plan.

Deliverable: a pull request that closes agent-ops#1172 with a real closing keyword.
```

## Prompt for R-15 — Deduplicate `cfg()` between `lib/claim.sh` and `scripts/sweep-orphan-branches.sh`

**Bundles:** R-15 only · **Run after:** no prerequisites

```text
Context: agent-ops has a shared config-access helper, lib/config-access.sh, defining a canonical
`cfg()` function used throughout the codebase to read values out of the resolved config JSON. A
prior cleanup (issue #967) deduplicated a different helper (`san()`) between lib/claim.sh and
scripts/sweep-orphan-branches.sh by pointing both at a shared lib/claim-key.sh — but left each
file's own local `cfg()` definition in place, un-deduplicated.

The problem, scoped on agent-ops#1755 (read it first): lib/claim.sh and
scripts/sweep-orphan-branches.sh each still define their own copy of `cfg()`, and that copy has
already begun to diverge from the canonical lib/config-access.sh version — both local copies
suppress stderr (`2>/dev/null`) on the underlying jq call, which the shared version does not do.

The goal: make both lib/claim.sh and scripts/sweep-orphan-branches.sh source the shared `cfg()`
from lib/config-access.sh instead of defining their own, after first confirming the `2>/dev/null`
difference doesn't matter to either file's actual usage (i.e., check whether either file relies on
suppressing a jq error message it would now see) — if it does matter, document why the local
override is deliberate instead of removing it.

Constraints: do not change lib/config-access.sh's own `cfg()` behaviour — only change the two
callers to use it. If you find the stderr-suppression difference is actually load-bearing for
either file, stop and document that explicitly rather than silently dropping it.

Verification: run every test file touching lib/claim.sh and scripts/sweep-orphan-branches.sh (grep
the test/ directory for references to either file) before and after your change and confirm
identical results. Specifically check whether any test asserts on stderr output from either file's
config reads.

Work cost-consciously. This whole task suits a low-cost tier: mechanical deduplication with one
small verification step (confirming the stderr-suppression difference is safe to drop).

Deliverable: a pull request that closes agent-ops#1755 with a real closing keyword.
```

## Prompt for R-16 — Close small test-coverage gaps

**Bundles:** R-16 only (git-identity and redact.sh coverage; bundled because both are
narrowly-scoped, independent test-writing tasks of similar size best done in one focused pass) ·
**Run after:** no prerequisites

```text
Context: agent-ops's lib/git-identity.sh provides `require_git_identity`, called by both
agent-cycle.sh and review-cycle.sh to ensure a git commit identity is configured before an
autonomous stage commits anything. Separately, lib/redact.sh is the module solely responsible for
masking secrets before cycle transcripts reach an external state-mirror repository or published
dashboard JSON.

The problem: (1) agent-ops#1148 (read it first) — `require_git_identity` has no test coverage
anywhere; five existing test files reference its two environment variables, but only as a fixture
precondition to let an unrelated scenario proceed past the guard, never testing the function's own
missing-var-exit-1 path or its `git config --global` writes. (2) agent-ops#1757 (read it first,
noting its scope is only half-done) — test/redact.test.sh now exists and covers
redact_add_literal's placeholder-escaping fix, but not lib/redact.sh's shape-based rules
(patterns matching gh*_, github_pat_, sk-, "Bearer ...", etc.) or the newline-bearing-secret
no-op-with-warning behaviour — both still exercised only as a side effect of an unrelated
integration test's fixture data.

The goal:
1. Create test/git-identity.test.sh with direct assertions for require_git_identity: the
   missing-GIT_USER_NAME/EMAIL early-exit path, and the successful-configuration path (verify it
   actually calls `git config --global user.name`/`user.email` with the expected values).
2. Extend test/redact.test.sh with direct assertions for each of lib/redact.sh's shape-based
   rules (one test per pattern, using a representative fake secret matching each shape) and for the
   newline-bearing-secret warning behaviour, independent of any state-sync.sh/publish-dashboard.sh
   integration fixture.

Constraints: follow this suite's existing test-file conventions exactly (see recent additions like
test/redact.test.sh or test/stage-health.test.sh for the current house style — a plain bash test
file with assert helpers, one scenario per assertion block, a comment explaining the failure mode
each assertion guards against).

Verification: run both test files directly (`bash test/git-identity.test.sh`,
`bash test/redact.test.sh`) and confirm all assertions pass. Confirm the new redact.test.sh
assertions would actually fail if you temporarily broke the corresponding shape rule (a quick
sanity check that they're not vacuously true).

Work cost-consciously. This whole task suits a low-cost tier: well-specified, mechanical
test-writing against clearly-defined existing behaviour, following an established house style.

Deliverable: a pull request that closes agent-ops#1148 with a real closing keyword. For #1757,
close it only if your redact.test.sh additions now cover every shape rule and the newline case in
full — otherwise reference it and note what remains.
```

## Prompt for R-17 — Land the two ready one-line flaky-test fixes

**Bundles:** R-17 only (both are trivial, already-specified one-line changes in the test suite) ·
**Run after:** no prerequisites

```text
Context: agent-ops's test suite (test/*.test.sh) has two tests that are self-documented as
occasionally flaky, each with a complete, already-specified one-line fix sitting on its tracking
issue, unpicked for over a week in both cases.

The problem:
1. agent-ops#1205 (read it for the full context): test/publish-dashboard.test.sh line ~1277 calls
   `run_window 20`; the issue's own comment specifies changing this to `run_window 30` to give the
   underlying timing-dependent assertion more margin.
2. agent-ops#1722 (read it for the full context): test/state-sync.test.sh line ~1657 asserts
   `mirror_lock_holder_age_s` equals exactly "0"; the issue's own comment specifies widening this to
   tolerate a value of 0 or 1 (a `{0,1}` pattern or equivalent), since the assertion can legitimately
   observe either value depending on exact timing.

The goal: apply both fixes exactly as specified in their respective issues. Do not investigate
further or redesign either test — both issues already contain a complete, reviewed specification;
your job is to execute it.

Constraints: change only the specific line each issue names. Do not touch any other part of either
test file.

Verification: run both test files (`bash test/publish-dashboard.test.sh`,
`bash test/state-sync.test.sh`) multiple times in a row (e.g. 5-10 iterations) if your environment
allows, to gain some confidence the flake is actually addressed rather than just silenced. Confirm
no other assertion in either file regresses.

Work cost-consciously. This whole task suits a low-cost tier: both fixes are pre-specified,
one-line changes with no design judgment required.

Deliverable: a pull request that closes both agent-ops#1205 and agent-ops#1722 with real closing
keywords (a single PR covering both is fine, since both are trivial and unrelated to each other
only in the sense that combining them saves overhead, not because they interact).
```

## Prompt for R-18 — Clean up fixture identity hygiene

**Bundles:** R-18 only · **Run after:** no prerequisites

```text
Context: agent-ops's test suite includes fixtures (test data representing GitHub users, actors,
assignees, etc.) used across many test files. Some of these fixtures use the project maintainer's
real GitHub usernames (warwick / warwickallen / Warwick-Allen) as literal test values, rather than
synthetic placeholder identities.

The problem, scoped on agent-ops#1174 (read it first — it has a scoping comment from 2026-09-05
specifying the exact replacement approach): 35 test files plus one dashboard-data fixture currently
use the maintainer's real username as a fixture value (a count that has grown, not shrunk, since
this issue was filed, as new tests kept adding the same real value instead of a placeholder). While
low-sensitivity (an already-public GitHub identity), this is real personal data accumulating in
committed fixtures.

The goal: replace the real username occurrences in test fixtures with a synthetic placeholder
identity (e.g. a clearly-fake login/actor/assignee/by value), per #1174's own specified approach.
Grep for warwick/warwickallen/Warwick-Allen across test/ (and any dashboard-data fixture) to find
every occurrence before starting, so you fix all of them in one pass rather than partially.

Constraints: use a single, consistent synthetic identity across all the fixtures you change (unless
a specific test genuinely needs multiple distinct fake identities — check for that case). Do not
change any assertion's actual logic — only the literal fixture value.

Verification: run the full set of affected test files after your change and confirm every
assertion that referenced the real username value was updated consistently (an assertion checking
for "warwick" that you missed would now fail against your new placeholder — treat any such failure
as a signal you missed a spot, not something to work around). Re-grep for the real usernames across
test/ afterward and confirm zero remaining hits (excluding any genuinely-justified exception you
document explicitly).

Work cost-consciously. This whole task suits a low-cost tier: mechanical find-and-replace across a
well-defined set of files, with straightforward verification (existing tests either still pass with
the new placeholder or they don't).

Deliverable: a pull request that closes agent-ops#1174 with a real closing keyword.
```

## Prompt for R-19 — Developer-experience polish (`.editorconfig`)

**Bundles:** R-19 only · **Run after:** no prerequisites

```text
Context: agent-ops is a Bash/jq/Markdown/JSON project with a consistent 2-space-indent, LF-line-
ending, final-newline convention throughout, enforced only by convention/inspection today, not by
any machine-readable declaration.

The problem, scoped on agent-ops#1758 (read it first — it deliberately narrows scope to just this):
no .editorconfig file exists at the repository root, so a newcomer's editor has no automatic
declaration of the repo's already-consistent formatting convention. #1758 explicitly defers a
.shellcheckrc and a Makefile/scripts-index as separate, out-of-scope concerns — do not add either of
those in this pass.

The goal: add a root .editorconfig declaring, at minimum, indent_style, indent_size, end_of_line,
and insert_final_newline, matching the convention already followed throughout the repository (2
spaces, LF, final newline present) — sample a handful of existing files across lib/, scripts/,
test/, and *.md to confirm the convention before writing the file, rather than assuming.

Constraints: keep the .editorconfig minimal, matching #1758's own scoping — do not add
language-specific overrides or opinionated rules beyond what's already the repo's actual, observed
convention.

Verification: run an EditorConfig checker if one is available in your environment (e.g.
`editorconfig-checker`) against a sample of existing files and confirm no false "violations" are
reported for files that already follow the stated convention — if a widespread false-positive
shows up, it likely means your .editorconfig doesn't accurately describe the real convention;
adjust it rather than the files.

Work cost-consciously. This whole task suits a low-cost tier: a small, well-specified configuration
file addition with no code changes.

Deliverable: a pull request that closes agent-ops#1758 with a real closing keyword.
```

## Prompt for R-20 — Decompose the dashboard's `renderBody()`; extract a shared paginated-fetch helper

**Bundles:** two independent sub-tasks bundled into one prompt only because both are Low-severity,
Medium-or-less effort dashboard/tooling polish with no interaction between them — treat them as two
separate PRs even though they're described together here · **Run after:** no prerequisites

```text
Context: agent-ops's dashboard/index.html is a single-file static HTML/JS dashboard. Its
renderBody() function has grown across three consecutive review cycles (462 -> 538 -> 552 lines)
despite being flagged every time, and is now roughly 3.5x the size of the next-largest function,
landingsPanel() (~159 lines), which already follows the file's established `*Panel()` naming/
structure convention. Separately, across lib/ and scripts/, at least 13 files independently
reimplement the same paginated `gh api ".../comments"` / `.../reviews` / `.../timeline`
`--paginate` fetch pattern, each with its own copy of the same caveat comment about `--jq` running
once per page.

The problem: agent-ops#1173 (read it first) scopes the renderBody() decomposition: extract each
banner group currently inlined in renderBody() into its own named function, mirroring the file's
existing `*Panel()` convention (e.g. `landingsPanel()`). agent-ops#1919 (filed by this review;
read it for the full file list) documents the paginated-fetch duplication across
lib/approver.sh, lib/candidate-select.sh, lib/enabler.sh, lib/landing.sh,
lib/reconciliation-gate.sh, and eight scripts/*.sh files.

The goal (two separate pull requests):
1. Decompose renderBody() by extracting each distinct banner group into its own named function
   (e.g. `reviewStageHealthBanner()`, `mirrorRebuildBanner()`, etc. — name each after what it
   renders, matching existing naming in the file), leaving renderBody() itself as a short sequence
   of calls to these new functions plus whatever top-level layout logic doesn't belong in any single
   banner.
2. Extract a thin shared `gh_paginated_fetch` (or similarly-named) helper into lib/github-limit.sh
   (already the shared home for gh rate-limit handling) covering the comments/reviews/timeline
   fetch shape specifically — the three endpoints repeated most often per #1919 — and migrate at
   least the files #1919 lists to use it instead of their own inline implementation. If any file's
   exact filtering/field needs don't fit the shared helper cleanly, leave it using its own
   implementation and note why in the PR description rather than forcing a bad abstraction.

Constraints: for renderBody(), zero visual/behavioural change to the rendered dashboard — this is a
pure refactor. For the paginated-fetch helper, preserve each migrated call site's exact current
filtering/field-selection behaviour; do not change what any of them fetches, only how the pagination
loop itself is implemented.

Verification: for renderBody(), open the dashboard (or its test harness, if one exists) before and
after your change and confirm pixel-identical/structurally-identical output for a representative
data fixture. For the paginated-fetch helper, run every test file covering a migrated call site
before and after and confirm identical results; add a focused unit test for the new helper itself
covering the multi-page case.

Work cost-consciously. Both tasks suit a mid-cost tier: mechanical extraction following an existing
convention (the `*Panel()` naming pattern; the existing `_reconciliation_gate_comments` pagination
idiom as the helper's starting template), with a clear identical-output verification bar. Neither
requires high-capability-tier judgment, but do review the extracted diff yourself before proposing
it, since a subtle scoping bug in a "pure" extraction is easy to introduce and easy to miss in
review.

Deliverable: two pull requests. The first closes agent-ops#1173 with a real closing keyword. The
second closes agent-ops#1919 with a real closing keyword (or references it if you migrate only
some of the listed call sites, stating clearly in the PR description which remain).
```
