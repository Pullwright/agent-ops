# agent-ops

Operations tooling for the Poetic autonomous agent pipelines: the
implementation cycle (`agent-cycle.sh`), the repository-review cycle
(`review-cycle.sh`), the Pipeline Monitor (`monitor-cycle.sh`), and the
local dashboard (`dashboard/`). `README.md`
explains what the pipelines do and how to configure, install, pause, and
monitor them; `docs/*-SPEC.md` are the as-built requirement specifications
for each component; `prompts/` holds the runtime prompts the pipelines pass
to their agents.

## As-built specifications

Each component has an as-built requirements specification in `docs/`:

- `docs/IMPLEMENTATION-PIPELINE-SPEC.md` — the implementation
  pipeline (`agent-cycle.sh`, `lib/`, `scripts/`, and the five stage
  prompts).
- `docs/REVIEW-PIPELINE-SPEC.md` — the repository-review pipeline: it reviews
  one repository per run (`review-cycle.sh`, `prompts/project-reviewer.md`,
  the vendored skill).
- `docs/MONITOR-PIPELINE-SPEC.md` — the Pipeline Monitor: a scheduled
  reading of the pipelines' own state (`monitor-cycle.sh`,
  `lib/monitor-digest.sh`, `prompts/monitor.md`).
- `docs/DASHBOARD-SPEC.md` — the monitoring dashboard
  (`scripts/publish-dashboard.sh`, `dashboard/index.html`).

These are requirement documents, and they are **as-built**: at all times they
describe the system that actually exists. Any change that alters what a
component does, requires, or produces must land in the same pull request as
the spec edit that keeps its document accurate — update the affected numbered
requirement (and any acceptance check anchored to it), or add one for new
behaviour. Requirements state only what is, never what used to be or what is
planned; history and rationale belong in the specs' design-decision and
gotcha sections. If you find a spec and the code disagreeing, that is a bug:
fix whichever is wrong rather than working around the mismatch.

The specs outrank the operating prompts: `prompts/*.md` implement the specs'
requirements, so bring the spec in line first, then the affected prompt(s).

## Generated regions

Two types of generated regions exist in this repository:

1. **Configuration tables** — `README.md`'s two configuration tables and each
   as-built spec's own (`docs/IMPLEMENTATION-PIPELINE-SPEC.md`'s,
   `docs/REVIEW-PIPELINE-SPEC.md`'s) are rendered from `config.schema.json`
   by `scripts/render-config-table.sh` — four `<!-- config-table:start
   id=... -->` … `<!-- config-table:end -->` regions in total, each paired
   with a `<!-- config-table:notes id=... -->` … `<!-- config-table:notes-end
   -->` region below the table for notes too long to fit a cell. Never
   hand-edit a row inside either region: edit the owning key's `description`,
   `x-docs.readme`/`x-docs.spec` or `x-docs.value` in the schema instead,
   then run `scripts/render-config-table.sh` (no arguments) to regenerate
   every region and `scripts/render-config-table.sh --check` before you push
   — `.github/workflows/config-table.yml` runs the same check on every pull
   request, and a hand-edit fails it even when the wording was right, because
   only the schema copy survives a regeneration. Each region's start marker
   carries this same contract inline, so it reads even to someone who reaches
   the row directly and never opened this file.

2. **Table of contents** — `README.md` and `docs/IMPLEMENTATION-PIPELINE-SPEC.md`
   have a table of contents between `<!-- toc:start -->` … `<!-- toc:end -->`
   markers, extracted from their `##` and `###` headings by
   `scripts/render-toc.sh`. Never hand-edit the content between these markers:
   edit headings instead, then run `scripts/render-toc.sh` (no arguments) to
   regenerate and `scripts/render-toc.sh --check` before you push —
   `.github/workflows/toc.yml` runs the same check on every pull request. The
   same contract applies: a hand-edit fails the check even when the wording
   was right, because only the rendered copy survives a regeneration.

3. **Stamped regions** — the two `<!-- agent-info:start fragment=... -->` …
   `<!-- agent-info:end fragment=... -->` regions in this file carry the text
   every Pullwright and Poetic-Poems repository shares (the branch workflow,
   commit messages and the maintainer statement), stamped from the
   organisation's `Pullwright/.agent` repository by its `scripts/sync.sh`.
   Never hand-edit inside them: change the fragment in `.agent`, then re-stamp.
   Each start marker records the source commit and a hash of the content, so
   the sync's `--check` tells a hand edit from a stale copy.

<!-- agent-info:start fragment=conventions source=Pullwright/.agent@b517d3d sha256=30bd787a7b6c -->
<!-- Stamped by Pullwright/.agent scripts/sync.sh from Pullwright/.agent:fragments/conventions.md - a hand edit inside this region is overwritten at the next sync; edit the source instead. -->

## Branch workflow

`main` is protected: it does not accept direct commits or pushes, from anyone
or anything, including maintainers and AI agents. Every change goes through a
pull request. A repo ruleset scoped to the default branch restricts merges
into `main` to squash only (other branches allow any merge method) — so a
pull request's title becomes the subject line of the single commit that
lands on `main`.
Write that title in Conventional Commits format (see "Commit messages"
below); the individual commits on the branch are discarded when squashed, so
only the title needs to conform. The squash commit's body is pre-filled from
the pull request's description (GitHub repo setting `squash_merge_commit_message:
PR_BODY`), so a filled-in PR description carries through to `main`'s history —
write one whenever the change needs more context than the title alone gives.

Because every change is gated by a PR and CI regardless of who or what proposes it, agents
work autonomously up to the PR stage: commit, push a branch, and open the pull request
without pausing to ask permission first. Review happens on the PR, not before it — the repo
owner reviews there and requests changes if needed. This does not extend to actions on `main`
itself (direct commits/pushes are rejected by the branch protection anyway) or to
force-pushing/merging, which still require explicit instruction.

All Poetic-Poems and Pullwright repositories, this one included, operate in a multi-agent
environment: autonomous and interactive agents, and the maintainer, may push branches, merge
pull requests, and move `main` at any time. Before commencing any changes, make your own
dedicated fresh clone of `origin/main` and work in that — never in a checkout shared with
anyone else, such as the user's working copy (which may be edited at any moment) or a clone
another agent is already using:

```bash
git clone --filter=blob:none https://github.com/Pullwright/agent-ops.git <scratch-dir>/agent-ops
```

A blobless clone is the default: it keeps the full commit history, so rebasing onto a moved
`main`, `git log`, `git blame` and merge-base all just work, and it fetches file contents only
as they are read. It is the default because you cannot reliably know in advance whether a
task will need history, and the two ways of guessing wrong are not symmetric — a blobless
clone that never needed history has cost a little metadata, whereas a shallow clone
(`--depth 1`) has no merge base and must be deepened (`git fetch --unshallow`) before it can
rebase. Use `--depth 1` only where nothing will rebase or read history, and a full clone
where you want every blob locally. Commit, push the feature branch, and open the pull request
from that clone; delete the clone once the work has landed. And when you open the PR, do not
assume `origin/main` is still in the state it was when you cloned — another change may have
merged meanwhile, which is why the post-PR mergeable check below is mandatory.

Before starting on any implementation, check for in-flight or prior work on the same
problem: open pull requests (`gh pr list --search "<keywords>"`), open issues, and any claim
the autonomous pipeline may hold on the item. These repositories are worked by concurrent
autonomous agents, so the work may already be under way; if it is, reconcile first — adopt
it, supersede it with an explanation, or stand down — before writing code.

Keep feature branches short-lived and narrowly scoped. Prefer breaking a large piece of
work into a series of small pull requests, each a safe, self-contained, independently
reviewable and mergeable unit, over accumulating many changes on one long-running branch.
As soon as a branch reaches such a unit of work — coherent on its own, with CI passing —
open it (or mark an existing draft) as "Ready for review" rather than holding it back to
bundle in more. Smaller PRs review faster, land sooner, and keep branches close to `main`,
which minimises the divergence and conflicts that long-running branches invite. Split off
follow-on work into its own branch and PR.

A pull request's readiness state is the signal the maintainer reads. Open it as a draft
(`gh pr create --draft`) while its content is still changing, its tests are unproven, or a
correction is still on its way, and mark it Ready only when it may merge exactly as it
stands: a Ready, green, unconflicted pull request may be put into the merge queue at any
moment, and once queued its head branch refuses further pushes (the queue lock, not a
permissions problem — stack any further change on a fresh branch instead). A "do not merge"
note in the description is not a substitute for Draft.

In this workspace, a local `post-checkout` Git hook in `.githooks/` refreshes the local
`main` branch from `origin/main` after switching to `main`, helping keep the branch aligned
with GitHub while working locally.

After opening (or updating) a pull request, confirm it is actually mergeable via `gh`
(e.g. `gh pr view <n> --json mergeable,mergeStateStatus`) — in addition to, not instead
of, whatever local checks the agent already ran. The remote can diverge from what the
agent last saw locally (another PR merging to `main` first, for example), so this check
has to happen after the PR exists, against GitHub's own view of it, not inferred from the
local working tree. If it comes back conflicting, resolve the conflict (e.g. rebase onto
the current `main`) and push the fix; force-pushing to update a branch still requires
explicit instruction, per above.

## Commit messages

All commits follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
(`<type>[(scope)][!]: <description>`, e.g. `fix(build): resolve output path`). Allowed
types: `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style`,
`test`. A `commit-msg` hook (`.githooks/commit-msg`) enforces this once a contributor runs
`git config core.hooksPath .githooks`. Because `main` only accepts squash merges (see
"Branch workflow" above), the pull request title is what actually becomes the commit on
`main` — CI (`.github/workflows/commit-format.yml`) checks both the PR title and every
commit on the branch.

<!-- agent-info:end fragment=conventions -->

<!-- agent-info:start fragment=maintainer source=Pullwright/.agent@b517d3d sha256=55824e959da4 -->
<!-- Stamped by Pullwright/.agent scripts/sync.sh from Pullwright/.agent:fragments/maintainer.md - a hand edit inside this region is overwritten at the next sync; edit the source instead. -->

This project presently has a single maintainer. The one approving review that the `main`
ruleset requires (it is a required review, not a code-owner review — `CODEOWNERS` lists
`@warwickallen` and `@Warwick-Allen` only so that a reviewer is requested automatically) is
given either by that maintainer's own second GitHub account or by the Pullwright Approver
App acting on the maintainer's behalf — one person, two handles, one email throughout the
git history — so it is self-review by design, not independent peer review; a reader (human
or agent) should not infer otherwise from the branch-protection description above. There
is also no succession plan: if the maintainer becomes unavailable, no one else currently
holds equivalent access or repo context. The multi-agent conventions in this file manage
concurrent agents working on the repo at once; they do not substitute for independent
review or bus-factor redundancy.

<!-- agent-info:end fragment=maintainer -->

## Pull requests in this repository

The pipelines this repo hosts already follow the dedicated-clone rule by
construction: every cycle clones its target repo fresh from GitHub into
`workspace_root` and deletes the clone afterwards, and the user's own
checkouts under `~/Code` are never touched.

A pull request whose head branch is named `agent/<n>` is, to CI, an
issue-sourced work order: `.github/workflows/closing-keyword.yml` fails it
unless the body carries both the `<!-- agent-ops:closes-issue item=<n> -->`
marker and a real closing keyword (`Closes #<n>`) for that issue — see
requirement 1b of `docs/IMPLEMENTATION-PIPELINE-SPEC.md`. An interactive
session that opens such a branch must write both; a body edit (`gh pr edit
<n> --body-file …`) re-runs the check.

## Tests

Run the suite through `./scripts/run-tests.sh`, which copies the working tree
into a throwaway container from the image; the host's tools and a `docker
exec` into a live node both fail tests on a pristine `main` (see
`README.md` §"Running the tests" for why). A test asserts that `config.json`
is *valid* — it matches the schema and `doctor.sh` accepts it — and never
what it says: every fixture supplies its own values by mutating
`test/fixtures/config-base.json` or writing its own block, and a check that
really is about the shipped file reads its values back through
`config_defaults`, the same resolution the code uses, rather than repeating
them. A routine configuration change must not break a test.

## Tech debt

When you defer work, take a shortcut, or notice a known gap, record it in
the tech-debt register — do not leave it only in a commit message or in
chat. This repository's register is per-item: one `tech-debt/<id>.md` file
per record (YAML frontmatter plus a Markdown body), IDs scoped `PPagop`,
with `TECH-DEBT.md` at the repo root holding only the policy — the filing
and claiming workflows and the declared scope.
`docs/TECH-DEBT-REGISTER.md` in `Poetic-Poems/poetic` specifies the format
and the scope-code registry.

Resolving an item is a frontmatter-only edit — `status: resolved`, plus
`resolved:` and `ref:` — with the body left in place; item files are never
deleted or renamed (CI enforces both). Where the item's work order arrived
as a GitHub issue instead — the common case since #1039's migration —
closing the issue does not resolve it: the same pull request must still
make this frontmatter edit. See TECH-DEBT.md's "Resolution and history"
for how the two compose, and its one exception (an issue filed with no
file behind it at all). `perl scripts/td-check.pl`
(argless — it detects the register's format) checks the register and is
what `.github/workflows/tech-debt-register.yml` runs on every pull
request, so run it before you push. The register scripts are
byte-identical copies of the canonical ones in `Poetic-Poems/poetic`
(see `.github/workflows/td-tooling-drift.yml`) — fix them upstream, never
here.

Roadmap item #882 retires this register machinery in favour of the labelled
issues already used by `Poetic-Poems/poetic` and `poetic-fiddle`; until it
lands, this section, `TECH-DEBT.md` and the `td` skill describe the hybrid
that is in force.
