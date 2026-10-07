## Requirements

### The Implementer

21. Operates as a single non-interactive `claude -p` invocation with no
    resumption: once it emits a final message with no further tool calls,
    the process exits for good — nothing wakes it later. It must wait for
    long-running commands (dependency installs, builds, test suites)
    synchronously, in the foreground or by polling within the same session,
    rather than ending its turn expecting an external notification when
    they finish. A command too slow to wait out within the stage timeout is
    grounds for `"status": "blocked"`, not an early, hopeful end of turn.
22. Runs inside the cycle's clone. First reads the repo's `AGENTS.md` — or
    `CLAUDE.md`, for a repo that has not migrated; `CLAUDE.md` imports
    `AGENTS.md` where it has — and obeys it throughout. Checks out the branch
    named in the work order —
    already created on origin by the Script as the item's claim (requirement
    17a) — and never creates, renames, or deletes a branch of its own.
23. **Makes the claim visible before implementing.** The branch is the
    lock, but humans read PRs, not refs: opens a draft PR immediately,
    labelled with the work order's `pr_label` — guaranteed correct because
    the claim loop stamps it from `config.json`'s own `pr_label` key
    unconditionally (requirement 17a), the Co-Ordinator's own verbatim copy
    (requirement 20) being belt-and-braces rather than the load-bearing
    source — with a Conventional-Commits title (it will become the squash commit on `main`)
    and a body giving the item reference and planned approach. Immediately
    records the PR's URL at `.git/agent-ops-pr-url` in the clone — `.git/` is
    never part of the tracked tree, so this can't leak into a commit — so the
    Script can still identify the PR even if this stage never reaches a
    parseable final message (requirement 9). That breadcrumb is a courtesy,
    not the guarantee: it is one more step in this
    stage's procedure, and requirement 9's fourth lookup is what covers the
    stage that performed none of them. For issues and tech-debt items alike —
    a tech-debt item is an issue carrying the product-managed
    `pw::type:tech-debt` label, and both claim identically (requirement
    17a) — it
    comments on the issue linking the draft PR; the work order's `context`
    already carries the issue body and its comments (requirement 20), but if
    the Implementer consults the issue directly it reads the whole thread
    (`gh issue view <n> --comments`), never a bare `gh issue view <n>` that
    hides the comments where corrected requirements usually live. For `security`/`code-quality`
    findings, the draft PR body names the alert (its `ref` and URL) so the
    claim is visible to any other cycle scanning open PRs. For a
    `project-review` recommendation, the draft PR body names the ref
    (`review-<date>-R-NN`) and links the review folder and recommendation, so
    the claim (and, once merged, the completion) is visible to any other cycle
    scanning PRs — there is no register entry and the review folder is not
    modified.
23b. **Stamps an issue-sourced draft PR with a machine-readable marker naming
    the issue it claims to close.** `<!-- agent-ops:closes-issue item=N -->`
    (`lib/pipeline-marker.sh`'s convention extended to this one new purpose:
    an invisible, greppable fact in the PR body), where `N` is the work
    order's `item`. This is what requirement 25a's deterministic check and
    requirement 17c's post-merge sweep both key on — neither reads prose, so
    "Implements #N" is invisible to both, which is exactly the shape of the
    defect requirement 25a exists to close (issue #240; PR #206 wrote
    "Implements #198" and #198 stayed open three days after its own fix
    merged).
23a. **Pushes at checkpoints, not only at the claim and at the end.** Once the
    draft PR exists, the Implementer commits and pushes again at each
    meaningful checkpoint — a passing test, a completed file, a finished
    logical unit — rather than holding every later change in the working tree
    until its final message. The clone is ephemeral and gone once the cycle
    ends, so a commit that never reached `origin` is lost with it; a pushed
    one survives on the claim branch regardless of how the stage ends. This is
    what lets an interrupted stage's successor — most often the
    `abandoned-drafts` recovery path (requirement 3e) — resume from the last
    checkpoint instead of from the claim commit alone, and it is also a
    "genuine push" in the sense requirement 3e's own activity clock already
    watches for.
24. Implements the item, then runs the same checks the repo's CI runs (as
    documented in that repo's `AGENTS.md`/`CLAUDE.md` and workflow files) and
    fixes anything they surface.
24a. **Checks the preview deployment its own pull request produced, for a
    repository whose config declares one (D19 Phase 1, agent-ops#586).** Which
    provider, if any, applies is stated in that repository's own `preview`
    config block (`repos[].preview`, requirement 1b's schema) — never
    hard-coded in either stage's prompt or in this requirement. Absent, or
    absent its own `provider`, resolves to `"none"`: this step does not run,
    and neither stage reports anything about it. `"vercel"` is the only implemented
    provider: where the target repository deploys from GitHub through
    Vercel's Git integration, every pull request head SHA gets its own preview
    deployment, and requirement 24's checks say nothing about it — the
    integration reports through GitHub's *deployments* API rather than as a
    check run, so `gh pr checks` is green over a preview that never built.
    `scripts/preview-deploy.sh` (component 13) is how a stage asks. A preview
    that failed to build, or that answers an error, is a defect in the pull
    request and is fixed like any other. The Script resolves the block once,
    from `config_defaults`, and stamps it onto the work order's own `preview`
    field before either stage's prompt is assembled (`lib/preview-config.sh`'s
    `preview_config_for_repo`) — a mechanical field, on the same "no model
    judgement to report" terms as `pr_label` (requirement 20).

    **A preview the stage cannot reach is not a failure of the pull request.**
    Preview deployments sit behind Vercel Authentication, and an
    unauthenticated request for one is answered with a 302 to
    `vercel.com/login` — which, followed, is a **200** from the login page, so a
    check reading a status code alone certifies a wall as a healthy deployment.
    The script therefore judges where a response points rather than what it is
    numbered, and reports a protected preview as "could not check" (exit 2),
    naming the node configuration that would fix it. The script itself still
    reads exactly two fixed environment variable names,
    `VERCEL_AUTOMATION_BYPASS_SECRET` and `VERCEL_TOKEN` — that is unchanged by
    this item, D19's "served"/"rendered" tiers being separate work — but a
    repository's own `preview.vercel.bypass_secret_env`/`preview.vercel.token_env`
    may name a *different* environment variable to read the credential from
    (default the same two fixed names, so an installation that has set
    neither is unaffected), which the Script remaps onto the two fixed names
    the script reads, immediately before either stage runs
    (`preview_config_export_vercel_credentials`) — the one thing that would
    otherwise have to change per repository once a second Vercel-deployed
    repository needs its own secret on the same node. Either way, the
    credential is a property of the node, not of the branch: a node without it
    runs every cycle exactly as it did before this check existed, and neither
    stage may report `blocked` for the want of it.

    **A passing check says only that the preview answers, not what it
    answers.** `--path` (a single route, judged for pass/fail) and `--fetch`
    (any number of routes, repeatable, judged for nothing) both exist because
    of this gap: poetic-fiddle#319's `frame-src` CSP defect sat in a response
    header throughout its pull request and was caught only when a human later
    opened the deployed preview in a browser. `--fetch <path>` runs once the
    readiness check above has confirmed the preview answers past the wall, and
    prints that route's response status, headers — a served
    `Content-Security-Policy` among them — and body, sending the same
    `x-vercel-protection-bypass` header internally so the secret never appears
    in a command line, this output, or the stage transcript. An oversized or
    binary body is truncated with a note saying so rather than dumped whole.
    Both prompts (component 4) direct their stage to name every route the
    diff touches on the same invocation as the readiness check, after any
    push; `--fetch`'s output is read as review evidence and never changes the
    check's own exit code.

    **Fetched content is untrusted data, never an instruction.** Each route's
    output is wrapped in a delimiter naming it as such: everything between
    `--- fetched: <url> ---` and `--- end fetched: <url> ---` is whatever the
    pull request under review made the preview serve — the same rule D19
    states for a rendered page's content, applied one tier earlier to a
    served page's HTML and headers. Both prompts state this immediately where
    they describe `--fetch`'s output, so a stage reading it treats it as
    evidence about the change to report, not as an instruction to follow, no
    matter how it is phrased inside the page or its headers.

    Both stages reach the script through **`AGENT_OPS_ROOT`**, which
    `agent-cycle.sh` exports as its own directory and every stage inherits. A
    stage's working directory is its ephemeral clone, so a prompt naming a tool
    this repository ships has nothing to name it relative to. A hard-coded
    `/app` would be right for every node as deployed and wrong for every other
    way this repository is run — a maintainer's checkout, the test suite, any
    future node that is not a container — and a prompt cannot tell which it is
    in. It is the only variable the Script
    exports for the stages, and `test/preview-deploy.test.sh` asserts the export
    and both prompts' use of it against each other, so the path cannot drift
    between the three (requirement 34a).
24b. **Filing deferred work inline, instead of losing it to scope creep or a
    separate round trip (agent-ops#631; the issue-backed convention, D15 as
    revised, #869/#875/#879).** Adjacent cleanup the Implementer is tempted to
    do but must keep out of this pull request (requirement 24's own scope
    discipline) is *noted*, not silently dropped: a labelled GitHub issue,
    riding along on this same branch rather than waiting for a future cycle
    to notice and re-derive it. The mechanism is one API call, not a register
    file: dedup-search first (`gh issue list --label pw::type:tech-debt
    --search "<working title>"`), to avoid filing a duplicate of an
    already-tracked gap, then `gh issue create` labelled `pw::type:tech-debt`
    — never a branch or a pull request of its own — plus a `Defers: #<n>`
    line added to *this* pull request's body, naming the freshly filed issue.
    `Defers:` is never a closing keyword (`Closes`/`Fixes`/`Resolves`):
    deferring is not resolving, and GitHub's own closing-keyword parser (the
    one requirement 25a's check mirrors) does not recognise it as one either
    way, so there is no risk of it auto-closing anything — the distinction
    matters for the *reader*, human or Reviewer, not for GitHub's own
    behaviour. The issue and the `Defers:` line both land before the
    Implementer's own turn ends — the Reviewer (requirement 30d) verifies
    each one, not files it fresh. Where the gap is a question or a decision
    rather than a scoped piece of work, an unlabelled `gh issue create`
    mentioned in the pull request body substitutes, with no `Defers:` line.
    A `Defers:`-linked issue with no accompanying code change is ordinary
    traffic through this band, not scope creep, and requirement 26a's
    complexity grading treats it accordingly (issue-only stays `low`). This
    is a **note**, never the fix: the actual work for a filed issue is left
    for a future item to pick up on its own merits.
24c. **A large test suite is run in pieces, never as one invocation, when the
    Implementer's own checks are this repo's suite too (agent-ops#962,
    extending 29a's fix to this stage).** Requirement 21's ceiling binds the
    Implementer exactly as it binds the Reviewer, and requirement 24's own
    verification step runs the identical well-over-a-hundred-file `test/*.test.sh` suite,
    through the identical `scripts/run-tests.sh`, whenever the repo under
    work is agent-ops itself — so a single unbatched invocation risks the
    same silent loss of test evidence requirement 29a exists to prevent.
    Requirement 24's check therefore lists the selected tests first
    (`scripts/run-tests.sh --list`, host-side, no Docker, returns instantly),
    splits that list into groups sized to finish comfortably inside the
    ceiling, and invokes `scripts/run-tests.sh` once per group, reading each
    group's own `PASS`/`FAIL` lines before the next group runs — the same
    discipline requirement 29a already requires of the Reviewer over the
    same suite.
25. Updates the originating record: an issue — tech-debt or otherwise —
    linked with a real GitHub closing keyword (`Closes`/`Fixes`/`Resolves
    #N`) naming the same `N` as requirement 23b's marker; implementation-plan
    task marked done.

    **Tech-debt's closing keyword carries a second thing besides the
    reference: a structured record.** Since D15 as revised (#869/#875/#879)
    moved the store off an in-repo register and onto the issue itself — a
    mutable, editable object, unlike a register file's line in `main`'s own
    history — the permanent record now has to be written somewhere immutable
    at resolution time, and the pull request body, carried verbatim into the
    squash-merge commit on `main` (`squash_merge_commit_message: PR_BODY`),
    is that somewhere. The Implementer adds a fenced `td-record` block to the
    PR body alongside the closing keyword:

    ```td-record
    issue: <n>
    title: "<the issue's own title, verbatim>"
    filed: <the issue's own creation date, YYYY-MM-DD>
    summary: "<what the debt was, briefly>"
    resolution: "<what this PR did about it>"
    ```

    All five fields are required, in this order — `issue` matching the
    closing keyword's own `N`; `filed` the issue's `created_at` date
    (already in the work order's `context`), never the day of resolution, so
    the record states when the debt was noticed rather than only when it was
    paid off. Where the issue's own body's final line begins with a "Filed
    as `tech-debt/<id>.md`, <date>." phrase — left by #1039's migration, or
    an earlier direct filing — that file is still the permanent register
    entry: the same pull request must also flip its frontmatter to `status:
    resolved`, filling `resolved:` and `ref:`, exactly as `TECH-DEBT.md`'s
    "Resolution and history" describes (PR #1313 is the precedent) — or,
    where the work's conclusion is that the item was never debt, to
    `status: not-debt` with `ref:` pointing at where the content moved
    (`TECH-DEBT.md` "Resolution and history"; issue #1437) —
    closing the issue alone does not resolve it, and skipping this step is
    what left `tech-debt/TD-PPagop-26082412.md` at `status: open` after PR
    #1355's first round. An issue with no such line has no file to flip —
    this is a pull-request-body convention,
    not a file, for that case only — and the block's shape is fixed so the
    archive mirror and later analytics can parse it (the mirror and its own
    retention are D15's separate concern, not this requirement's).
    For `security`/`code-quality` findings, no register flip applies — GitHub
    closes a Dependabot or code-scanning alert automatically once the fix
    lands on the default branch and is re-scanned — so the PR body names the
    alert it resolves (and its URL); the Implementer never dismisses an alert
    itself (dismissal is a human decision). For a `project-review`
    recommendation, there is likewise no register entry to flip and the
    review folder (a point-in-time record) is left untouched — the PR body
    names the ref
    (`review-<date>-R-NN`) so its eventual merge marks the recommendation done;
    a later review re-evaluates the code and simply omits anything now fixed.
    Writes the changelog entry into the pull-request description's
    `## Changelog` section when the change is notable by that repo's
    definition (a security fix usually is, under `### Security`), or `None.`
    when it is not — never into `CHANGELOG.md` (requirement 25c).

25a. **The closing keyword requirement 25 asks for is enforced deterministically
    — by CI and by the Script — not by trusting the prompt.**
    `.github/workflows/closing-keyword.yml` runs
    `scripts/check-closing-keyword.sh` against the PR body and head branch
    on every `pull_request` event, and two anchors decide what the body owes:

    - **The marker.** Every `<!-- agent-ops:closes-issue item=N -->` marker
      (requirement 23b) in the body fails the check, naming the missing
      number, unless the body also carries a real closing keyword for that
      same `N`, in any of the three spellings GitHub's own linked-issue
      syntax honours: `#N`, `GH-N`, or `owner/repo#N`. The repo-qualified
      spelling satisfies the marker whatever its `owner/repo` reads, since
      this anchor is only ever asked whether a closing keyword for `N`
      exists at all — never in which repository — and it runs where no repo
      slug was passed to the checker in the first place
      (`lib/closing-keyword-gate.sh`, acceptance check 17a).
    - **The branch.** A head branch of exactly `agent/<N>` — the name the
      Script itself mints for any work order whose item is a bare issue
      number, `issues` and `tech-debt` sources alike (`claim_branch_for`),
      and for nothing else (`lib/work-gone.sh`) — requires both the
      marker for `N` and the closing keyword for `N` to be *present*. This
      anchor is the one no model writes: a marker-only check passes
      trivially on the PR whose Implementer forgot the marker, which is the
      same silent prompt-skip that motivated issue #240, whereas the branch
      name was fixed by the Script before the Implementer ever ran.

    A PR with no marker on any other branch — every source with nothing to
    close — passes; the check has nothing to say about a PR with nothing to
    close.
    This is what makes requirement 25's "Implements #198" failure (issue
    #240) structurally impossible to repeat unnoticed: the pull request
    itself goes red, in front of the human who reviews it, rather than
    depending on a model that has already been asked once and skipped it.
    The `closing-keyword` check must also be listed in the repository
    ruleset's required status checks — a repo setting, not a workflow file —
    so red blocks the merge rather than merely reporting, and pinned there
    to the GitHub Actions app (`integration_id` 15368), as every other
    required context is, so no other integration can satisfy the requirement
    by reporting a check of the same name. Acceptance check 8m is how that
    setting is verified, it being the one piece of requirement 25a no file
    in this repository carries.

    **A second, independent gap the same check closes (issue #1363, extended
    by #1438): the tech-debt record-file flip requirement 25 asks for.**
    This half checks every issue number the closing keyword covers — the
    marker- and branch-anchored ones above, **and any issue number the PR
    body cites via a bare closing keyword with no marker and no `agent/<N>`
    head branch at all** (issue #1438: a human's PR, or an interactive
    agent's, that closes a `pw::type:tech-debt` issue with a plain
    `Fixes #N` and nothing else the marker/branch anchors above would have
    caught) — in `#N` and `GH-N` spelling alike, and in the repo-qualified
    `owner/repo#N` spelling only where `owner/repo` is this repository's own,
    since a keyword naming another repository's issue closes nothing here and
    must not demand a flip of a record this pull request never owed (issue
    #1460). This harvest runs against a copy of the body with every fenced
    code block, inline code span, and line beginning with `>` (a blockquote)
    stripped first — GitHub's own parser creates no closing reference inside
    any of the three, so a keyword quoting the convention or someone else's
    PR body would otherwise demand a record flip GitHub itself never asked
    for (issue #1463; PR #1396's body is the concrete case: a `Closes #1083`
    written inside an inline code span, discussing why that issue is
    deliberately left open). The marker/branch anchors above are unaffected —
    they check the raw body, never this stripped copy, so a stripping defect
    can only ever affect this half. Where such an issue is
    `pw::type:tech-debt`-labelled and its
    body's last non-blank line names a permanent register file (a "Filed as
    `tech-debt/<id>.md`, <date>." line — `scripts/migrate-tech-debt-
    register.sh` or an earlier direct filing), `check-closing-keyword.sh`
    also reads this pull request's own changed-files listing (`gh api
    …/pulls/<n>/files`) and fails, naming the issue and the file, unless its
    diff adds a line setting that file's `status:` to one of the register's
    two terminal states — `resolved`, or `not-debt` for an item the
    resolving pull request concludes was never debt (issue #1437: both are
    equally terminal to `lib/work-gone.sh` and
    `lib/candidate-gather.sh`, and a `not-debt` row still requires a `ref:`
    of its own). PR #1355's first round is
    the concrete miss this closes: the issue closed, the file left at
    `status: open` on `main` until a later round caught it by hand — nothing
    before this checked the flip mechanically, only the prose
    (`CLAUDE.md`, `TECH-DEBT.md`, `prompts/implementer.md`,
    `prompts/reviewer.md`) agreeing.

    The demand lapses for a record that already carries a terminal `status:`
    on the base branch (issue #1493). Before failing either shape of miss —
    a diff that never touches the file, or one that touches it without
    adding a terminal `+status:` line — the check reads the named record
    from the base branch (`gh api …/pulls/<n>` for `.base.ref`, falling back
    to `.base.sha` where a payload carries no branch, then `gh api
    …/contents/<path>?ref=<that>`) and passes when that copy is already
    `resolved` or `not-debt`. That reading is bounded to the record's own
    frontmatter block — the leading `---`-delimited block alone, the same
    shape `scripts/gather-register-status.sh`'s `item_frontmatter()` takes —
    so a still-`open` record whose *body* quotes another record's `status:
    resolved` line at column 0, in a fenced code block or a "Resolution and
    history" note pasting another item's frontmatter verbatim, is not read as
    terminal (issue #1764). An earlier, unrelated pull request may have
    flipped it — issue #982's own record was flipped by PR #1150, the
    2026-08-31 repository review, before the pull request closing #982
    reached it — leaving no truthful
    `+status:` line for the closing pull request to add, and the register is
    append-only (`TECH-DEBT.md` "Resolution and history"), so demanding one
    would be demanding a false rewrite. The *branch* is read in preference
    to the commit because `.base.sha` is the base branch's head at the pull
    request's last sync rather than its head now, which would re-fail a
    long-lived branch for the very reason this lapse exists.

    A terminal base copy grants this amnesty only when the record's own patch
    is a pure append: no `-` deletion line against it, and no `+status:` line
    setting a non-terminal value (issue #1795). The append-only convention
    that justifies the amnesty is exactly what a patch of either shape
    violates: deleting or rewriting the record's frozen lines, or de-flipping
    its status back to a non-terminal one, is not the harmless
    provenance-note append (PR #1492's own case) this lapse exists for, and
    the base copy's status alone cannot tell the two apart. Such a patch
    therefore still fails the ordinary record-flip demand even though the
    base copy is terminal. An empty patch — the record untouched — cannot be
    destructive and keeps the amnesty on the base's terminal status alone.

    Either `gh` call that fails outright
    (the token, a transient outage) warns rather than failing the check —
    the issue read and the changed-files read alike — the same
    "could not ask" reasoning as `unknown` below, applied inline rather than
    as a separate verdict, since the marker/keyword half never depended on
    the network and this half must not fail a pull request over GitHub's own
    availability. The base-branch read is deliberately the exception: it
    decides whether to *excuse* rather than whether to *accuse*, so a failed
    read falls through to the ordinary failure instead of warning and
    skipping — an unreadable base must not become an amnesty no record-flip
    has to satisfy. This half runs only through the workflow, where the repo
    slug and pull request number are available to pass — `lib/closing-
    keyword-gate.sh` (below) re-derives only the body and head branch from
    `gh pr view`, so `poetic` and `poetic-fiddle`, neither of which carries a
    `tech-debt/` register of their own, get the marker/keyword half alone.

    That workflow file guards only agent-ops, the repository that carries
    it — a workflow guards the repository it ships in, not every repository
    the pipeline raises pull requests in. `poetic` and `poetic-fiddle` carry
    no closing-keyword workflow of their own, so enforcement there is
    script-side instead: `lib/closing-keyword-gate.sh`'s `closing_keyword_gate`
    re-reads a pull request's current body and head branch with `gh pr view`
    and runs them through the same `scripts/check-closing-keyword.sh`,
    at two points the Script (`agent-cycle.sh`) already stands between the
    pull request and a human. The two are asked for different reasons and
    answered differently:

    - **Right after the Implementer's PR is raised**, this is *feedback*, not
      a gate. A dirty verdict is recorded as a warning and handed to the
      Reviewer as a `## Script findings` entry in its prompt; the cycle
      continues into the review exactly as it would have. What the check
      finds is a pull-request body edit — the class of defect the Reviewer's
      own step 4 fixes and pushes in the same cycle — so refusing the handoff
      here would convert a self-healing case into an item recorded
      `attempt-failed` and blocked pending an Enabler engagement, at no gain:
      the second call is what a pull request cannot reach a human through.
      What this call buys is that the Reviewer *knows*, since it cannot see
      the later verdict from inside its own session and would otherwise hand
      off, be handed back, and cost the review anyway.
    - **At the Reviewer's own `ready` handoff**, alongside
      `review_gate_verdict`, this is the gate. A dirty verdict hands back
      through `log_reviewer_handback`, exactly as a failing required check or
      a new security-severity alert already does, and the PR stays a draft.
      It is asked again here rather than trusted from the earlier call for
      the same reason requirement 31c re-reads everything at this point: the
      body can change between the two, and a Reviewer that ignored its
      `## Script findings` entry has to stop somewhere.

    A verdict of `unknown` — `gh pr view` failed past
    `lib/github-limit.sh`'s retry, its answer carried no head branch, or the
    checker could not be run — is a fact about the node, not the pull
    request, and warns at both points rather than blocking either. This is
    the reasoning `review_gate_security_alerts` already applies to an alerts
    API it cannot reach, and deliberately *not* the one
    `review_gate_required_checks` applies to a check list it cannot read:
    that one reports `unknown` too (requirement 31c) but still refuses the
    handoff, because a pull request that genuinely runs no CI reaches it in
    the same shape and silence is itself the hazard there, whereas an
    unreadable pull request looks nothing like one missing its keyword. A
    node degraded enough for this to matter is stopped at the `ready` handoff
    by `review_gate_required_checks`, which does fail closed, before this
    gate is ever consulted.

    So every target repository gets the same deterministic gate: agent-ops
    from its own CI workflow *and* the script-side gate that also covers it
    a second time, `poetic` and `poetic-fiddle` from the script-side gate
    alone. Acceptance check 8p is how the gate itself is verified.
25b. **A `pw::type:tech-debt` issue closed some other way still gets an
    advisory check — never a gate (issue #877; D15 as revised,
    #869/#875/#879's "close-guard").** Requirement 25's closing keyword and
    `td-record` are written only when the resolving change is a pull
    request; a `pw::type:tech-debt` issue closed directly — by a human, as
    `not_planned` or as a `duplicate` — carries neither, and requirement 25a's
    deterministic
    check has nothing to look at, since there is no pull request body for it
    to read. `.github/workflows/tech-debt-close-guard.yml`, filtered at the
    job level to a `closed` issue event carrying the `pw::type:tech-debt`
    label, runs `scripts/tech-debt-close-guard.sh` against the evidence rules
    its own header states, one per close reason GitHub records:

    - **`completed`** (or a close with no stated reason at all — GitHub's own
      default): a linked closing pull request (`closedByPullRequestsReferences`,
      `includeClosedPrs: true`, so a merged one still counts — verified live
      against agent-ops#1226/#1227 that the more obvious-looking
      `timelineItems(itemTypes:[CLOSED_EVENT]) { closer }` this used at first
      reports `closer: null` for a squash-merged closing pull request, which
      GitHub does not always populate) or a linked closing commit (the same
      timeline `closer`, kept as the fallback for the one shape the
      pull-request field cannot see — a closing keyword in a plain commit,
      which this repository's own branch protection rules out but not every
      repository this script may run against does), or a comment already on
      the issue.
    - **`not_planned`**: a comment already on the issue, inheriting the
      retired register's own `not-debt` meaning (D15's revision) — a reason
      stated, not a fix.
    - **`duplicate`**: a comment already on the issue, on the same rule and
      for the same reason — a close that resolves nothing can have no closing
      pull request to point at, so asking the `completed` rule's question here
      would be asking for something that cannot exist. GitHub records nothing
      else for it either: sampled live over the 29 most recent
      `reason:duplicate` closes on github.com, not one carried a
      `MarkedAsDuplicateEvent` on its timeline (that event belongs to the
      older "mark as duplicate" action, not to the close reason) and 18 of the
      29 carried no comment either, so a comment naming the original is the
      only trace such a close can leave.
    - **Any other reason GitHub may add later**: the `completed` rule, and the
      comment names the reason verbatim rather than reporting a completed
      close — `duplicate` was such a value until the rule above learnt it.

    Every rule's "a comment" is satisfied by *any* comment already present —
    content is never read, the same simplification requirement 25a's own
    checker makes about a closing keyword's wording — except the guard's own
    past comments on the same issue, which never count as one: without that
    exclusion the first guarded close would leave a comment that silently
    satisfied every later close of the same issue. When neither rule is met,
    the workflow posts exactly one comment naming what is missing, marked
    `<!-- agent-ops:td-close-guard closed_at=<the issue's own closed_at> -->`
    so a workflow re-run never posts a second comment for the *same* close; a
    later close of the same issue carries a different `closed_at` and is
    judged fresh.

    **Advisory only, and only ever that.** The workflow never reopens the
    issue, never relabels it, and never fails its own run over a
    non-compliant close — `tech-debt-close-guard.sh` always exits 0. Nothing reads this workflow's conclusion:
    it is not a required status check, it gates no merge (an issue close has
    none to gate), and no work source or gate anywhere in this pipeline
    consults it. A red run means the guard itself could not operate — `gh`
    unreachable, a malformed event payload — never that the close was
    irregular.
56. **A pull request that deletes, or edits away, the workflow job producing
    a required status check names the ruleset edit as an owner-act
    prerequisite deterministically, at pull-request time — not only once a
    downstream item happens to block on it (issue #1543).** The live
    instance is requirement 55's own: PR #1503 deleted
    `.github/workflows/tech-debt-register.yml`, whose `register` job ruleset
    18857310 required, and nothing named the ruleset edit as a prerequisite
    until #1529 happened to block on the merge 6+ hours later. This is the
    earlier of the issue's two seams; requirement 55 is the backstop that
    catches the same fact again at the Reviewer's `ready` handoff, for a
    finding this one missed or a workflow edited after the Implementer's own
    pass.

    `lib/required-check-preflight.sh`'s `required_check_preflight_findings`
    runs right after the Implementer's pull request is raised — the same
    moment requirement 25a's `closing_keyword_gate` already runs, in
    `agent-cycle.sh`'s own Implementer-stage block. It reads the base
    branch's `required_status_checks` contexts
    (`repos/<slug>/rules/branches/<base>`), the pull request's changed-file
    list (`repos/<slug>/pulls/<n>/files`), and — for every changed
    `.github/workflows/*.yml`/`*.yaml` file whose status is `removed`,
    `modified` or `renamed` — that file's raw content on each side
    (`repos/<slug>/contents/<path>?ref=<sha>`, the base and head commits
    `pulls/<n>` itself reports), extracting each side's top-level job ids
    with a line-oriented heuristic over the literal YAML text
    (`_required_check_preflight_job_ids`: the direct 2-space-indented keys of
    a 0-indent `jobs:` map) rather than a full parser — it recognises the
    ordinary shape, the one PR #1503's own `register` job was, and says
    nothing for a workflow whose `jobs:` is laid out some other way, so a
    shape it cannot read costs one missed finding, never a false escalation.
    A job id dropped between the two sides that matches a required context
    is a finding: the context and the file that used to produce it.

    Any finding runs `required_check_preflight_escalate`, a thin body
    composition around `create_escalation_issue` (`lib/enabler.sh`) — the
    same escalation primitive `lib/landing.sh`'s open-question escalation,
    `lib/approver.sh`'s stale-review escalations and `lib/standdown.sh`'s
    auth-failure escalation already call directly, ahead of any Enabler
    engagement, so this follows the pipeline's existing convention for a
    Script-side gate that needs a human now rather than inventing a second
    escalation route. The issue this files carries `enabler_escalation_label`
    and names the missing context(s), the file(s) that used to produce them,
    and the ruleset edit itself as the ask; a `gh pr comment` on the pull
    request (`pipeline_comment_header`/`pipeline_comment_marker`, the
    ordinary Script-authored comment shape) links it, so a human reading the
    pull request sees the prerequisite without having to find the escalation
    issue first. A ruleset, changed-file list or file content this cannot
    read is a fact about this node or GitHub's availability, not the pull
    request — `required_check_preflight_findings` prints nothing rather than
    guessing, the same non-blocking convention requirement 55's own backstop
    and `review_gate_security_alerts` already apply to an API they cannot
    ask — and an escalation that could not be filed warns and is retried the
    next time this runs, rather than failing the Implementer's own handoff.

    Nothing this gate finds ends the cycle. Its whole verdict travels on
    `required_check_preflight_findings`'s stdout; the function's exit status
    is always 0, on the finding path as much as on the no-finding and
    could-not-read ones, and `agent-cycle.sh`'s own block assigns it with a
    `|| true` besides. Both halves are deliberate: this block runs after the
    pull request is already raised and under `set -euo pipefail`, so a
    non-zero status leaking out of the one path this requirement exists for
    would abort the Implementer stage — no `complexity:*` label, no Reviewer
    engagement, and no escalation filed — precisely when a finding was in
    hand.

    The Refiner applies the same rule ahead of selection: where an item's own
    inventory names a `.github/workflows/*.yml` file being deleted or
    substantially rewritten, its specification states the ruleset-edit
    prerequisite explicitly, so an Implementer that later reaches this
    requirement's own deterministic check is confirming a prerequisite the
    work order already named, not discovering it cold.

    `docs/STANDING-DECISIONS.md` carries the converse of 2026-08-22 · #648:
    doing the ruleset edit early is harmless — a pull request that still
    carries the workflow keeps running it, only without gating — so the safe
    ordering (edit the ruleset, then merge) never wedges the repository.
25c. **The changelog entry is a section of the pull-request description, and
    its shape is checked deterministically (roadmap decision D27,
    agent-ops#1804).** A change records its changelog entry under a
    `## Changelog` heading in its own pull-request description: one or more
    of Keep a Changelog's six category sub-headings — `### Added`,
    `### Changed`, `### Deprecated`, `### Removed`, `### Fixed`,
    `### Security`, spelt exactly — each followed by at least one `- ` bullet
    written for that repository's changelog audience, or the single line
    `None.` where the change is not notable, so an omission is deliberate
    rather than forgotten. The squash merge writes the description onto
    `main` (`squash_merge_commit_message: PR_BODY`, the same store
    requirement 25's `td-record` block relies on), so the entry reaches
    `main`'s history without the pull request touching `CHANGELOG.md`; that
    file stays in Keep a Changelog format and is written by one kind of pull
    request only — the release pull request in a repository that cuts
    releases, a scheduled roll in one that does not — which assembles every
    entry merged since the commit its own marker names (the assembler is
    agent-ops#1807; this repository's roll is agent-ops#1809). A repository
    is under this requirement from the commit that stamps the
    `documentation-principles` fragment from `Pullwright/.agent` into its
    `AGENTS.md`, which is how it adopts D27, and the stage prompts defer to
    that file for which regime applies, never to their own summary: in a
    repository so stamped no stage edits `CHANGELOG.md`; in one whose
    `AGENTS.md` still states the file rule, a stage adds the `[Unreleased]`
    entry that file asks for and writes no section, so a stage and the
    repository it works never say different things during the adoption
    window (PR #1810 review). The finishing sources (`review-feedback`,
    `merge-conflicts`, `dequeued`, `landing-refusals`) add nothing to a
    description that already carries its section, as they never wrote a file
    entry; `abandoned-drafts` writes the section on completion, as it wrote
    the entry before.

    Which descriptions owe a section is decided by the title, the one anchor
    no description edit moves: a Conventional Commits type of `feat`, `fix`
    or `perf`, or the `!` breaking-change marker on any type, requires the
    section, even if only to say `None.`; every other type may omit it, and
    a section that is present is checked for shape whatever the type.
    `.github/workflows/changelog-section.yml` runs
    `scripts/check-changelog-section.sh` against the title and the body on
    every `pull_request` event (`opened`, `edited`, `reopened`,
    `synchronize` — `edited` because the description can change without a
    push), passing both through `env:` so a fork's title or body cannot
    inject shell, and reporting skipped on `merge_group`, where there is no
    description to check and a skipped conclusion satisfies a required
    check. The check reads the description outside fenced code blocks and
    HTML comments — a fenced example of the heading is not a section — and
    fails, one `::error::` annotation per fault, on: a title that owes a
    section with no `## Changelog` section carrying content — a heading
    whose content is nothing but blank lines and HTML comments, which is
    the pull-request template's own untouched state, is treated as absent,
    so a type that owes nothing passes it as it stands and a type that owes
    one gets this same fault rather than one it could only clear by
    deleting a heading the template gave it; more than one such section
    with content; a first content line that is neither a category heading
    nor `None`; a sub-heading that is not one of the six categories, spelt
    exactly; a category with no bullet, or listed twice; a line under a
    category that is neither a bullet, an indented continuation of one, nor
    a comment; and a `None` section that also lists a category or a bullet.
    The Reviewer's fix for any of these is a description edit
    (`gh pr edit --body-file`), which moves no head, evicts no queued branch
    and stales no approval — the property that makes the trade worth
    making, since a hand-added entry in `CHANGELOG.md` was the sole
    conflicting path in 16 of the 22 merge conflicts the pipeline repaired
    in this repository between 2026-09-13 and 2026-09-23, each repair
    re-running the Implementer, the Reviewer and the Approver.

    The `changelog-section` context must be listed in the repository
    ruleset's required status checks, pinned to the GitHub Actions app
    (`integration_id` 15368), for the same reason and on the same terms as
    requirement 25a's `closing-keyword`; `scripts/doctor.sh` reads both
    contexts in one pass and warns for whichever is missing or unpinned
    (acceptance check 8m). Doing the ruleset edit ahead of the merge is
    harmless (`docs/STANDING-DECISIONS.md`, 2026-08-22 · #648's converse).
    That workflow file guards only agent-ops, the repository that carries
    it — a workflow guards the repository it ships in, not every repository
    the pipeline raises pull requests in. `poetic` and `poetic-fiddle` carry
    no `changelog-section` workflow of their own, so enforcement there is
    script-side instead, on requirement 25a's own `lib/closing-keyword-
    gate.sh` pattern (agent-ops#1808): `lib/changelog-section-gate.sh`'s
    `changelog_section_gate` re-reads a pull request's current body and title
    with `gh pr view --json body,title` and runs them through the same
    `scripts/check-changelog-section.sh`, at the same two points in
    `agent-cycle.sh` the closing-keyword gate already stands between the
    pull request and a human, asked for the same reasons and answered the
    same way:

    - **Right after the Implementer's PR is raised**, this is *feedback*, not
      a gate — a second `## Script findings` entry
      ("**Changelog section (requirement 25c):**") alongside the
      closing-keyword one where both fire, since both are pull-request body
      edits the Reviewer's own step 4 already fixes.
    - **At the Reviewer's own `ready` handoff**, inside `handoff_complete_
      review` (`lib/handoff.sh`) right after the closing-keyword gate and
      before the reconciliation gate, this is the gate: a `dirty` verdict
      hands back through `log_reviewer_handback`, the same shape a dirty
      closing-keyword verdict already uses, and the handoff JSON carries a
      `changelog_section: {word, reason}` key beside `closing_keyword`.

    A verdict of `unknown` — `gh pr view` failed past `lib/github-limit.sh`'s
    retry, its answer carried no title, or the checker could not be run — is
    a fact about the node, not the pull request, and warns at both points
    rather than blocking either, on the same reasoning requirement 25a's own
    `unknown` carries. `CHANGELOG_SECTION_GATE_GH` stubs `gh` for tests, and
    `CHANGELOG_SECTION_GATE_CHECK` the checker's path.

    So every target repository gets the same deterministic gate: agent-ops
    from its own CI workflow *and* the script-side gate that also covers it a
    second time, `poetic` and `poetic-fiddle` from the script-side gate
    alone. Acceptance check 8k is how the gate itself is verified.
25d. **`CHANGELOG.md` is assembled from merged pull-request descriptions,
    never hand-edited by the change itself (roadmap decision D27,
    agent-ops#1807).** `scripts/assemble-changelog.sh [--check]
    [--since <ref>] [<path>]` is the one place requirement 25c's descriptions
    become the file, run by the release pull request in a repository that
    cuts releases or a scheduled roll in one that does not (this
    repository's own roll is agent-ops#1809) — never by any other pull
    request, which is the property that lets two pull requests stop
    conflicting over the file in the first place. `<path>` defaults to
    `CHANGELOG.md` at the script's own repository root, wherever it has been
    synced.

    The file carries its own progress marker near its top,
    `<!-- changelog:assembled-through sha=<full sha> -->`; every first-parent
    commit on the current branch strictly after that commit
    (`git log --first-parent --reverse <sha>..HEAD`) is a candidate.
    `--since <ref>` overrides the marker as the range's start — required on a
    file that carries neither a marker nor a prior `--since`, which is an
    error rather than a guessed starting point. So is a range that cannot be
    read: a starting commit this checkout does not carry — a shallow clone, a
    marker naming a commit of another repository — exits non-zero, naming the
    missing history, and writes nothing. It is never treated as an empty
    range, which would let the marker advance past commits that were never
    read and lose their entries permanently and silently. Each candidate's body is
    parsed by the exact grammar requirement 25c states, shared rather than
    duplicated: `lib/changelog-grammar.sh`'s `changelog_grammar_walk` runs
    the fence/HTML-comment/heading state machine and None/category/bullet
    classification once, emitting one tab-separated event per line, and both
    `scripts/check-changelog-section.sh` (validates) and
    `scripts/assemble-changelog.sh` (extracts) read the same event stream. A
    body with no `## Changelog` section, or whose section says `None.`,
    contributes nothing. A body whose one section fails the grammar
    anywhere — every fault the checker itself would raise, not merely the
    ones that resemble a missing bullet — contributes nothing at all, rather
    than the bullets read before the fault: every bullet a commit's body
    yields is staged locally and merged into the running per-category result
    only once that commit's whole section is confirmed clean, because a
    truncated bullet shipped silently into `CHANGELOG.md` is worse than a
    dropped one. This is not a hypothetical: a real, merged commit in this
    repository's own history (agent-ops#1819, predating the `changelog-
    section` check's own wiring into the ruleset, agent-ops#1808) carries an
    unindented paragraph continuation the grammar reads as loose prose
    mid-bullet, and the assembler drops that commit's section whole rather
    than truncating it there.

    Under a (created, if absent, below the preamble) `## [Unreleased]`
    heading, one `### <Category>` per category present, in Keep a Changelog
    order (Added, Changed, Deprecated, Removed, Fixed, Security), newest
    commit first within a category and, within one commit, in the order its
    author wrote them. Each bullet ends with ` (#N)`, `N` the
    squash title's own trailing `(#N)` GitHub appends on merge, unless the
    bullet already cites that number somewhere in its own text.

    An existing `[Unreleased]` section is **spliced, never re-rendered**: its
    lines are carried across one for one and new bullets inserted above the
    existing ones of their category, a wholly new category heading taking its
    Keep a Changelog place among whatever headings are already there. Existing
    bullets, and every released section, are therefore left byte-for-byte
    unchanged. The shared grammar is deliberately *not* used to read the
    existing section back: it is a validator for one pull-request
    description, and a long-lived `CHANGELOG.md` legitimately carries things
    it faults — a category heading appearing more than once (this
    repository's own file has thirteen headings for six names), a heading
    outside the six, prose before the first one, a blank line between two
    bullets. Reconstructing the section from a parse that is allowed to fail
    means every such file loses its whole `[Unreleased]` section on the first
    run, silently and with exit 0; splicing cannot lose what it never
    re-renders. The marker is
    rewritten to `HEAD` whether or not any commit in range carried a bullet,
    since it tracks how far the file has been read, not how far it has
    changed — the property `--check` relies on: it computes what a normal
    run would write and compares it to the file's current content, exiting
    non-zero without writing when they differ, so a release workflow can
    refuse to tag a stale file, and exiting 0 on a second run with no new
    commits (idempotence).

    Requires a checkout with real commit history reachable from `HEAD` back
    past the marker (or `--since`) commit — a blobless clone
    (`--filter=blob:none`) is enough, since only commit metadata is read,
    never blob content, but a shallow one (`--depth`) is not: a consumer's
    CI must check out with `fetch-depth: 0`. Distributed to `poetic` and
    `poetic-fiddle` through the `.agent` sync manifests as a `file` entry —
    each repository's own adoption issue adds that manifest line, not this
    one — so there is one implementation and one test suite:
    `test/assemble-changelog.test.sh`, against a fixture git repository of
    squash-shaped commits, covering the marker, `--since`, `None.`, a body
    without a section, a fenced example of the heading, a malformed section
    contributing nothing rather than a truncated bullet, category ordering,
    the `(#N)` suffix (including a bullet that already cites its own
    number), merging into a pre-existing `[Unreleased]` section, an existing
    section the description grammar would fault surviving intact (duplicate
    and non-standard headings, prose, blank lines between bullets), two
    bullets from one commit keeping their written order, an unreadable range
    refusing rather than advancing the marker, idempotence
    and `--check`. `poetic`'s `changelog-check` and `poetic-fiddle`'s
    `changelog-rename` release jobs, and `poetic-fiddle`'s
    `scripts/extract-changelog-notes.mjs`, all read the file's own
    `## [<version>]` headings and stay valid, because the release pull
    request that runs this script assembles first and renames
    `[Unreleased]` second — this script never touches a released section.
25e. **A repository that cuts no releases still gets its `[Unreleased]`
    section rolled, on a schedule (agent-ops#1809).**
    `scripts/roll-changelog.sh [<owner/repo>]` is the scheduled roll
    requirement 25d's own text names for this repository: run weekly, plus
    on demand (a plain manual invocation — a Script-side duty needs no
    separate dispatch mechanism the way a GitHub Actions workflow's
    `workflow_dispatch` would), it runs `scripts/assemble-changelog.sh`
    against `<owner/repo>`'s own `CHANGELOG.md` (`<owner/repo>` defaults to
    wherever this script itself is checked out, resolved from `git remote
    get-url origin`, mirroring requirement 25d's own "wherever it has been
    synced" default), renames the resulting `## [Unreleased]` heading to
    `## [<today's UTC date>]` (Keep a Changelog's version slot; this
    repository carries no version numbers) and opens a fresh, empty
    `## [Unreleased]` above it. `git`/`gh` credentials resolve through the
    same on-demand shim (`lib/gh-shim.sh`) every other Script-side duty
    already uses, so no separate authoring identity needs wiring up here.

    A `CHANGELOG.md` carrying no `<!-- changelog:assembled-through -->`
    marker at all is the one-time migration this repository's own file
    needed at adoption: rather than running the assembler over the
    5,150-line hand-written `[Unreleased]` section that predates the D27
    convention (agent-ops#1804, #1810), the script renames that section,
    unchanged, to a fixed `## [2026-09-23]` heading — #1810's own merge
    date — opens a fresh empty `[Unreleased]` above it, and sets the marker
    to #1810's own squash-merge commit
    (`5e78f991c282a0f858942fcd10066a39c102e365`), so only a description
    merged after D27 landed is ever assembled. This path runs exactly once,
    the run after which the marker exists; every later run takes the
    ordinary path below.

    A run against a marker that already exists first counts the
    first-parent commits since it (`git log --first-parent
    <marker>..HEAD`); zero means nothing has merged since the last roll,
    and the run is a no-op — no commit, no branch push, no pull request.
    Otherwise it runs the assembler (which may still find no bullet-bearing
    description among the commits in range, e.g. a run of `chore`/`test`-
    only merges — the marker still advances and the section is still
    rolled, empty, exactly as the assembler's own idempotence contract
    already allows), renames the assembled `[Unreleased]` to today, opens a
    fresh one, commits `CHANGELOG.md` and opens or updates one
    `docs(changelog): roll <date>` pull request on the fixed
    `changelog-roll` branch — a second run while the first's pull request
    is still open force-pushes the same transform, freshly re-applied over
    the current default branch, over that branch rather than opening a
    second one, first checking (`lib/merge-queue.sh`'s
    `merge_queue_probe`) that the existing pull request is not currently in
    the merge queue — the same "never push under a queued pull request"
    rule every other pushing stage in this pipeline already observes, an
    unreadable queue state treated the same as "queued" (skip), never as
    "safe to push". A first run opens that pull request ready for review,
    not draft, carrying the config's own `pr_label` (`.pr_label //
    "autonomous-agent"`, the same global fallback
    `scripts/publish-revert-rate.sh` falls back to) and a `complexity:low`
    label (created first if the repository lacks it, best-effort, the same
    colour and description `lib/labels.sh`'s own catalogue gives it) — it is
    the one pull request D27 (requirement 25c) permits to edit
    `CHANGELOG.md`. This branch's fixed name is never `branch_prefix`-
    prefixed and this pull request carries no cycle-authored `selection`
    event in the fleet log, so it is invisible to every mechanism that reads
    either of those: the automatic landing-retry sweep (`lib/landing.sh`)
    can never arm it, and `gather-review-feedback.sh`/`gather-dequeued.sh`/
    `gather-landing-refusals.sh` can never turn a human's follow-up comment
    on it into a work order. Being ready and non-draft is what puts it in
    the ordinary open-pull-request list a human already watches for every
    other `pr_label`-carrying pull request, and what the unreviewed trigger
    (agent-ops#890, requirement 46) reads once `merge_autonomy` is raised
    above `human` — but landing it, on the first run and every force-pushed
    update after, is always a human's own review and merge, never something
    this pipeline arms on its own.

    Cadence: `schedule.changelog_roll_hour`/`_offset_minutes` (the same
    per-node jitter every other daily publish tick uses) and
    `schedule.changelog_roll_day_of_week` (`0`-`6`, cron's own Sunday-is-`0`
    convention) together render one weekly crontab line
    (`deploy/docker/render-crontab.sh`, `deploy/docker/crontab.tmpl`) —
    unlike the Pipeline Monitor's own daily-within-an-hourly-line cadence,
    cron's own day-of-week field means the line itself only ever fires on
    that one day, so no run-time "is this due" check is needed. Unit-tested
    against a fixture git repository and a stubbed `gh`
    (`test/roll-changelog.test.sh`), covering the migration rename, the
    ordinary roll's assemble-then-rename and marker advance, the fixed
    branch being updated rather than duplicated while its pull request is
    still open, and the merge-queue skip; must pass `shellcheck`.
26. Verifies the PR via `gh pr view --json mergeable,mergeStateStatus`
    (against GitHub's view, not inferred locally) and resolves any conflict
    with the current default branch. Leaves the PR as a **draft** — the
    Reviewer flips it to ready. For the `review-feedback` and
    `merge-conflicts` sources — the two whose branch and pull request already
    exist before the Implementer starts — every push to it, including this
    verification step's own rebase-and-push, is preceded by a merge-queue
    membership check (requirement 38f); a queued pull request, or a probe
    that fails, stops the push and reports `blocked` rather than risking a
    silent eviction. `abandoned-drafts`' push is exempt: its pull request is
    always a draft, which GitHub does not allow to be queued.
26a. **Grades the complexity of the work, ex post, and labels the PR with
    it.** After implementing, the Implementer grades the PR `low`, `medium`
    or `high` against a rubric anchored to observable features of the work,
    never to how difficult it felt — the PR that most needs a strong review
    is the one whose author misunderstood something and didn't notice, and
    that author will find it easy:
    - `low` — docs, comments, register entries, or a lone deferred-work
      issue (a `Defers:` line with no accompanying code change) only; no
      behaviour change. A work order the Co-Ordinator classified trivial
      (requirement 19) is `low` by definition, no deliberation required.
    - `medium` — a behaviour change confined to one area and well covered by
      existing or added tests.
    - `high` — the diff touches concurrency/locking, security, state
      replication, CI/workflow machinery, or shared library code; or the
      Implementer deviated from the work order; or the acceptance criteria
      cannot be verified mechanically.
    It applies the grade to the PR as a `complexity:<grade>` label — creating
    the label in the repo first when absent, best-effort — leaving the PR
    with exactly one `complexity:*` label. On a PR that already carries one
    (the finishing sources), it may **raise** the label but never lower it:
    the grade describes the PR's whole content, not the final round's effort,
    and rebasing a `high` PR is not `low` work. Labelling must not fail the
    stage — the summary's `complexity` field (requirement 27) is the
    authoritative carrier for this cycle's model choice (requirement 8a); the
    label is the durable mirror that survives for later finishing rounds and
    tells the Human Reviewer how carefully to read.
26b. **May name labels for its own pull request (requirement 6c, issue
    #714).** The summary's optional `labels` field
    (`[{name, colour?, description?}, …]`, requirement 27) is a suggestion,
    not a write: the Script mints and applies each accepted entry to the
    Implementer's own PR through `lib/labels.sh`'s `labels_mint`, capped at 3
    and refusing anything named in requirement 6c's reserved set. This is a
    different channel from requirement 26a's own `complexity:*` label, which
    the Implementer applies itself, by its own `gh label create`/`gh pr
    edit` calls — `labels` is descriptive only, and nothing in this pipeline
    may read one back to decide anything, exactly as requirement 6c's
    inertness invariant states.
27. Ends with a single JSON object as its entire final message:
    `{"status": "complete", "pr_url": …, "branch": …, "complexity": "low" | "medium" | "high", "labels": […, optional], "notes": …}`,
    `{"status": "blocked", "reason": …, "unblock_condition": …}`, or
    `{"status": "void", "reason": …, "evidence": …}`. The Implementer is the
    only component positioned to tell `blocked` from `void` (requirement 9b) —
    it is the one that actually reads the tree — so its prompt must draw the
    distinction explicitly and demand evidence for `void`. Do not leave it to
    infer that "already done" is a kind of blocker; it reads that way, and the
    two states behave in opposite ways downstream.

