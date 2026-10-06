## Requirements

### The Co-Ordinator (selection only)

14. Works read-only: `gh` reads (runs, PRs, file contents via
    `gh api`) — it does not clone, and writes nothing but its final message.
    For the `security` and `code-quality` sources it does **not** re-query the
    Dependabot/code-scanning APIs itself; it reads the pre-fetched `findings`
    array the Script attached to each repo (requirement 3a). The `issues`
    source likewise: its candidates are the pre-fetched `issues` array
    (requirement 3j), threads included, and an empty array is a repo with no
    issue candidates, never issue data withheld. The `failed-runs` source has
    no array and never did — it is queried live, and "not pre-fetched" means
    "go and look", not "skip". The remaining `gh` budget goes on the cheap
    claim/blocked checks below and on reading what an item references.
14a. **An issue is its whole thread, not just the opening post.** Whenever it
    evaluates or selects a GitHub issue, the Co-Ordinator reads the body *and
    every comment*. For `issues`-source candidates both arrive in the array
    entry (`body`, `comments` — verbatim); for an issue outside the array (one
    another item references, or a blocked issue the array's filter dropped),
    it fetches the thread — `gh issue view <n> --comments` (or `gh api
    repos/<slug>/issues/<n>/comments`); a bare `gh issue view <n>` or `gh api
    .../issues/<n>` returns only the body and silently drops the comments,
    where the parts that decide the work routinely live: added acceptance
    criteria, clarifications or corrections to the original ask, scope cuts, a
    "blocked"/"won't do" note, or a maintainer turning a discussion into an
    actionable task. A later comment that contradicts the body is the current
    instruction; the body alone is never taken as the whole ask.
15. One Co-Ordinator engagement per configured repository, launched in the
    walk order requirement 3 computes — not one engagement across every
    repository together (issue #587; before this, a single engagement's
    `repos` array held every configured repository, and this requirement
    read "walks the repos in the order given"). Each engagement's own
    runtime input's `repos` holds exactly one entry — that repository's own
    — and the engagement walks that repository's own work sources in the
    configured priority order; it never sees another repository's own data,
    and nothing in its runtime input names one. For "failed Actions runs", a
    candidate exists only where the **most recent** run of a workflow on the
    default branch is a failure (a later green run supersedes older
    failures). The `security` source's candidates are the pre-fetched
    `findings` with `source: "security"` (Dependabot alerts and
    security-severity code-scanning alerts); the `code-quality` source's
    candidates are the `findings` with `source: "code-quality"`. The
    `project-review` source's candidates are the recommendations (`R-NN`) in
    the **most recent** folder under that repository's own resolved
    `report_directory` (requirement 3k; `reviews/project-review-YYYY-MM-DD/`
    where the repository configures neither `repository_review.repos[]`'s nor
    `repository_review.defaults`' own `report_directory`) on the
    default branch: read that folder's `03-recommendations.md` and
    `04-improvement-prompts.md` via `gh api .../contents/...` (no pre-fetch —
    these are ordinary tracked files, like `TECH-DEBT.md`). A
    recommendation's stable ref is `review-<review-date>-R-NN`; the paired
    improvement prompt is the brief. The `issues` source's candidates are the
    pre-fetched `issues` array (requirement 3j), and it appears at four ranks
    rather than one, banded by each entry's `priority` — see requirement
    15e. The `implementation-plan` source's candidates are the next
    unblocked task(s) in the repo's own plan document, read at the path in
    that repo's runtime-input `implementation_plan_path` (requirement 3k) —
    no pre-fetch, and no path named in the prompt.
15z. **The Script reconciles the six cross-repository tiers itself, once
    every repository's own engagement this cycle has answered** (issue
    #587). Before the split, one engagement saw every repository at once and
    could judge "is repository Z's security finding more urgent than
    repository A's plain issue" directly; a per-repository engagement has no
    other repository's candidates in front of it to make that judgement
    with. `coordinator_merge_candidates` (`lib/stage-attempt.sh`) takes
    every repository's own returned `candidates` array, tagged by the Script
    with that repository's own walk-order position (requirement 3) and that
    candidate's own rank within its repository's list, and sorts the merged
    whole by: the candidate's tier (security, urgent issues, review-feedback,
    merge-conflicts, dequeued, abandoned-drafts, then every other source as
    one residual tier — requirements 15a/15e/15b/15d/15f/15c respectively),
    then repository walk order, then the candidate's own rank within its
    repository. The residual tier is where requirement 3's plain repository
    order alone decides between two candidates — landing-refusals,
    human-visibility, tech-debt, `issues:high`/`issues:medium`/`issues:low`,
    code-quality, and the three sources with no pre-fetched array collapse
    into it exactly because none of them carries a cross-repository tier of
    its own (requirement 15g), which is what stops a residual-tier source in
    a less-overdue repository from ever outranking one in a more-overdue
    repository the way a true tier's own candidate does. The merged,
    reordered list is then capped to `candidates_max` (requirement 17a) —
    the one enforcement of that bound that happens mechanically rather than
    by instruction, since no single engagement can cap a merge across
    repositories it never saw.
15y. **An engagement that produces no verdict costs its own repository's
    opportunity, and nothing else** (issue #587). Each engagement writes its
    own stage transcript to `<cycle-dir>/coordinator-<slug>.out` (plus the
    `.out.stderr` and `.stream.jsonl` `run_model_stage` derives from it),
    where `<slug>` is that repository's configured slug with its `/`
    flattened to `-` — one flat file per repository in the cycle directory,
    never a path with a directory component in it, which nothing in the cycle
    creates and which would fail both of those redirections before `claude`
    was ever launched. An engagement that fails to launch, is killed, or
    returns an unparseable final message is recorded (requirement 21's
    `attempt-failed`, and `handle_stage_failure`) and the cycle moves to the
    next repository rather than exiting, since one repository's failure must
    not cost every other repository this cycle's own chance. Three
    consequences follow for the stand-down. The first two exist because a
    repository that was never successfully asked has established nothing
    about its own backlog; the third because a repository that answered
    without contributing a candidate has not accounted for its own backlog
    either, and so must be treated the same way:

    - **Where every engagement failed, the cycle exits exactly where the
      pre-split single attempt exited** — before requirement 3v's
      corroboration and before any `none-selected` is written at all. No
      repository is in the "said no" set, so corroboration would have nothing
      to check and would fall straight through to a stand-down the model
      never actually reported. A launch failure is typically node-wide (an
      API refusal, a usage limit, an image fault), so this is the ordinary
      shape of the failure rather than an exotic one.
    - **Where some engagements failed and the cycle still stands down, the
      `none-selected` event omits `fingerprint` and carries
      `engagements_failed`** — the count of engagements that produced no
      verdict. The fingerprint is a fleet-wide claim that every configured
      repository was asked and none had anything, which is what arms
      requirement 3b's no-op short-circuit against the *next* cycle; a cycle
      that could not ask every repository has not established it, and must
      leave the short-circuit unarmed for the same reason requirement 3t's
      rejected verdict does. The reason text names the shortfall too.
    - **A `"selected": true` engagement that contributes zero candidates is
      treated as an answered-`false` repository, not as a selection.** This
      is a distinct case from the two above — the engagement launched,
      parsed, and answered — but a `true` verdict whose `candidates` array is
      present and empty is a contract violation the engagement itself should
      never produce (requirement 20's single-selection grace, for the
      no-`candidates`-array shape, always contributes exactly one candidate,
      so this can only be an explicit empty array). Trusting the verdict at
      face value would leave this repository out of
      `coord_false_repo_slugs_json` while it contributed nothing to the
      merge: requirement 3v's corroboration is scoped to that set, so this
      repository's own eligible items would be checked by nothing, and — if
      every other repository was likewise empty or genuinely had nothing — a
      fleet-wide `none-selected` could arm the no-op fingerprint against a
      backlog this repository's own answer never actually accounted for. The
      Script folds it into `coord_false_repo_slugs_json` instead, with a
      reason naming the contract violation, exactly as an honest
      `"selected": false` is.
15b. **Review feedback comes third, across repositories.** Like security and
    urgent issues, this outranks the plain source walk: any selectable
    `review_feedback` candidate in any repository is taken before any work
    below it in another — reconciled by the Script (requirement 15z) rather
    than judged by any one engagement, which sees only its own repository's
    `review_feedback` array. The
    human is this system's only consumer and its scarcest resource; when they
    have spent their time and asked for something specific, answering beats
    starting something new — and the work is already 90% done. The Co-Ordinator
    must **not** apply requirement 16's claim exclusion to this source: the open
    PR *is* the item, and excluding it makes every candidate permanently
    unselectable while looking entirely correct.
15d. **Merge conflicts come fourth, across repositories.** After security, urgent
    issues and review-feedback, and likewise outranking the plain
    source walk: any
    selectable `merge_conflicts` candidate in any repository is taken before any fresh
    work in a more-overdue one — reconciled by the Script (requirement 15z),
    the same as review-feedback. The PR is otherwise ready to land, and until
    the conflict is resolved nothing else on it can proceed, so
    a rebase-and-resolve is finishing, not starting. As with review-feedback, the
    Co-Ordinator must **not** apply requirement 16's claim exclusion to this
    source — the open PR *is* the item, and the pre-fetch (requirement 3g) has
    already established it is ours and conflicting. The Implementer's job here is
    narrow: rebase onto the base and resolve the conflict, without completing or
    re-doing the underlying item (that is what merges the PR, and remains this
    repository's own landing decision — see "The Landing Gate" — not the
    Implementer's to make). A Dependabot takeover candidate (requirement 3s)
    ranks and is exempted from requirement 16's claim exclusion here
    identically, even though
    it is, unlike every other `merge_conflicts` candidate, genuinely new work — a
    fresh PR on a fresh branch, not a finish of an existing one, and it does raise
    `max_open_agent_prs`' count by one once claimed (Dependabot's own PR never
    counted toward it; the replacement does, until it merges or is closed). This
    is a deliberate simplicity trade-off, not an oversight: a takeover is rare
    (it fires only after a nudge has already failed to clear the conflict) and
    routing it through a second source or a back-pressure carve-out of its own
    would be exactly the new ledger/escalation concept the feature was built
    without (issue #250's acceptance criteria).
15f. **Dequeued pull requests come fifth, across repositories.** After
    security, urgent issues, review-feedback and merge-conflicts, and
    likewise outranking the plain source walk: any selectable `dequeued`
    candidate in any repository is taken before any fresh work in a
    more-overdue one — reconciled by the Script (requirement 15z), the same
    as review-feedback and merge-conflicts. The PR was otherwise ready and
    something had already committed it to landing, and until the
    merge-group's own checks failure is fixed it cannot be re-queued, so a
    diagnose-and-fix is finishing, not starting, for the identical reason
    merge-conflicts ranks where it does. As with review-feedback, the
    Co-Ordinator must **not** apply requirement 16's claim exclusion to this
    source — the open PR *is* the item, and the pre-fetch has already
    established it is ours, dequeued and actionable.
15c. **Abandoned drafts come sixth, across repositories.** After security, urgent
    issues, review-feedback, merge-conflicts and dequeued, and likewise outranking the plain
    source walk: any selectable `abandoned_drafts` candidate in any repository
    is taken before any fresh work in a more-overdue one — reconciled by the
    Script (requirement 15z), the same as the four tiers above. A previous cycle already
    implemented most of the work behind that draft, so finishing beats starting;
    and every cycle it sits stalled it holds a back-pressure slot that throttles new
    work fleet-wide. As with review-feedback, the Co-Ordinator must **not** apply
    requirement 16's claim exclusion to this source — the open draft PR *is* the
    item, and the pre-fetch (requirement 3e) has already established it is stale
    and ours, so treating it as a claim would make every candidate permanently
    unselectable.
15g. **landing-refusals and human-visibility carry no cross-repository tier
    of their own**, unlike the six sources requirements 15a/15e/15b/15d/15f/15c
    name — each is selectable only when its own repository's ordinary source
    walk reaches its configured rank there, and requirement 15z's merge
    leaves both in the residual tier alongside tech-debt, the three
    lower issue bands and code-quality: two candidates from that tier, from
    two different repositories, are ordered by repository walk order alone,
    never by which of the two sources either one is.
15a. **Security is always prioritised.** Within a single repository, a
    candidate is security-related if it is a `security` finding, a GitHub
    issue labelled `security`/`vulnerability`, a tech-debt entry flagged as
    a security concern, or a `project-review` recommendation whose text
    flags a security concern — and the repository's own engagement ranks any
    such candidate ahead of every non-security item it returns, most severe
    first where severity is known (the pre-fetched `findings` array arrives
    already sorted that way). Only the first of those four kinds carries that
    priority **across** repositories: the Script's own reconciliation
    (requirement 15z) gives global tier 0 to a candidate only when
    `source == "security"` (a Dependabot alert or a security-severity
    code-scanning alert) — a security-labelled issue, a security-flagged
    tech-debt entry, and a security-flagged project-review recommendation
    remain security-related within their own repository's own ranking, but
    carry no cross-repository tier of their own: the merge places each at
    whatever tier its own source and band would have earned it with no
    security flagging at all — requirement 15g's residual tier for a
    tech-debt entry, a `project-review` recommendation or a
    `High`/`Medium`/`Low` issue, and requirement 15e's `Urgent` tier for an
    issue the organisation marks `Urgent`. Within global tier 0, the merge
    breaks a tie between
    two different repositories' own `security` candidates by repository
    walk order (requirement 3) alone — an approximation of "most severe
    fleet-wide" the same way requirement 15e's `Urgent` bullet documents for
    issues: a repository's own findings are sorted most-severe-first before
    the Script ever sees them, but the merge does not itself compare
    severity across repositories once every engagement has answered.
15e. **Issues rank by their `Priority` field.** An open issue's band is its
    organisation-level `Priority` issue field — `Urgent`, `High`, `Medium` or
    `Low` — and the band is the issue's rank in the walk, as
    `issues:urgent` / `issues:high` / `issues:medium` / `issues:low` in the
    repo's configured `sources`:

    - **`Urgent` is a global tier, second only to security.** Like
      review-feedback, merge-conflicts, dequeued and abandoned-drafts, it
      outranks the plain source walk: if any selectable urgent issue
      exists in any repository, it is taken before any non-security item anywhere —
      including ahead of the four finishing sources — reconciled by the
      Script (requirement 15z) exactly as those four tiers are: an engagement
      ranks its own repository's urgent issues by age among themselves
      (oldest first), and the Script's merge breaks ties between two
      different repositories' own urgent issues by repository walk order,
      an approximation of "oldest first" fleet-wide that no per-repository
      engagement could otherwise make without seeing another repository's
      own issue dates. Those tiers exist because
      finishing beats starting; `Urgent` is the one signal that outranks even
      that, because it is the human stating outright that this cannot wait,
      and a top band that still queued behind four other tiers would not mean
      what it says. It cannot starve the finishing sources either:
      back-pressure (requirement 2.2a) narrows the cycle to exactly those four
      once `max_open_agent_prs` is reached, and that gate is applied to the
      runtime input before the Co-Ordinator sees it.
    - **`High` sits between failed-runs and tech-debt** in the per-repo walk.
      Below a red default branch, which is repo-wide breakage that blocks every
      other item's checks; above tech-debt, which is by construction work that
      was already judged deferrable.
    - **`Medium` sits between tech-debt and the implementation plan** — exactly
      where the unbanded `issues` source ranked before this requirement existed.
    - **`Low` sits between project-review and code-quality**: still a human's
      filed, deliberate request, so above the automated quality suggestions, but
      below the review recommendations a human approved without marking them
      least-pressing.

    **An issue with no `Priority` set is `Medium`.** The default is not
    "unranked" and never "lowest": an untriaged backlog must behave exactly as
    it did before banding existed, so that setting the field is what moves an
    issue and leaving it alone changes nothing.

    The band arrives on each pre-fetched entry as `priority`, derived by the
    Script (requirement 3j) from `issue_prefetch_open_issues`'s GraphQL walk
    (`lib/issue-prefetch.sh`, agent-ops#1085; a REST issues-endpoint read
    before it), whose payload carries `issue_field_values`; the band is the
    `single_select_option.name` of the entry whose `issue_field_name` is
    `Priority`. `gh issue view --json` does not expose issue fields, which is
    why neither surface this can come from is that command. Anything that is
    not one of the four names — absent, empty, unreadable by this token, or a
    value the organisation added later — is `Medium`, which keeps an
    unrecognised or invisible field a no-op rather than a re-ranking.

    Banding changes rank and nothing else. Within a band, candidates are
    evaluated oldest issue first, and every other rule that applies to an issue
    applies unchanged: requirement 14a's whole-thread read, requirement 16's
    exclusions, requirement 15a (a `security`-labelled issue is security work
    whatever its band, including a `Low` one), the bare issue number as the item
    ref, and `"source": "issues"` in the work order (requirement 21) —
    downstream consumers never see the band.
16. Excludes from candidacy any item that is:
    - recorded as blocked in the shared log (an `attempt-failed` event not
      followed by an `unblocked` event for that item) — for a GitHub issue,
      only once requirement 18a's mandatory re-check, where it applies, has
      found the recorded blocker still holds — or recorded as void (an
      `item-void` event not followed by `unvoided`), which has no re-check to
      preserve for any source. For `findings`, `review_feedback`,
      `abandoned_drafts`, `merge_conflicts`, `dequeued`,
      `human_visibility` and
      `tech_debt`, both halves are already applied deterministically by the
      Script (requirement 3u) before the runtime input is assembled — there
      is nothing left here for the Co-Ordinator to check for any of those
      seven sources. `issues` gets the same treatment for its void half and for a
      *stale* blocked entry; only a blocked issue carrying evidence fresh
      enough to warrant requirement 18a's live re-check ever reaches the
      Co-Ordinator;
    - a tech-debt item that is assigned, labelled `blocked`, or names an
      unresolved `Blocked-by:` dependency (requirement 34j) — the same three
      deterministic drops the `issues` bullet below describes, applied by
      `scripts/gather-tech-debt.sh` before the runtime input is assembled
      (requirement 3t);
    - already referenced by any open PR or draft (a claim, per the repos'
      claiming workflow), or its repo+item appears in the pre-fetched
      `claimed` array (requirement 3o) — a peer node's claim, by either shape,
      even one that has not yet surfaced as a draft PR; the Script's own
      atomic claim in requirement 17a is the hard gate, this exclusion merely
      avoids proposing work that will lose the race. Unlike the open-PR half,
      there is nothing to check live here: `claimed` is exhaustive over both a
      registry entry and a live `agent/<item-ref>` branch, already
      age-filtered to `claim_ttl_hours`, so an entry present excludes and an
      entry absent (or aged out) does not — for
      a `security`/`code-quality` finding, that means
      an open PR whose branch or body already references the same alert
      (`ref`, alert URL, or the affected package/rule); for a `project-review`
      recommendation, an open PR whose branch or body references its ref
      (`review-<date>-R-NN`); for the five sources that finish an existing
      pull request, whose own scoped item refs would otherwise dodge this
      bullet's
      repo+item lookup, requirement 3p has already dropped any candidate whose
      `pr_number` matches a peer's claim from `review_feedback`,
      `merge_conflicts`, `dequeued`, `landing_refusals` and
      `abandoned_drafts` before this runtime
      input was assembled — there is nothing left in those arrays for this
      exclusion to apply to, deterministically, rather than a comparison added
      to this judgement call;
    - a `project-review` recommendation that is already **done** — a *merged*
      PR references its ref (`review-<date>-R-NN`) — or that is already owned
      by a higher-priority source: the review files debt-shaped
      recommendations as `pw::type:tech-debt`-labelled issues
      cross-referencing the `R-NN` (`docs/spec/review.md`, R12/R12a),
      so a recommendation cross-referenced by such an issue — or by a current
      tech-debt entry a repository's own register still carries — is left to
      that source and skipped
      here. (A single `gh` PR search per repo for the review date surfaces the
      open/merged/closed PRs referencing that review; match refs against it.)
      Note that a merged PR is a *floor*, not a proof: work that landed as a
      direct commit, or before the repo required PRs, leaves no PR to find and
      so reads as outstanding forever. The cross-reference is what covers that
      gap, which is why the review spec (`docs/spec/review.md`, R12a)
      is required to write it and not merely expected to; requirement 9a is
      the backstop for when it is missing anyway — the item is then
      investigated once, and the finding remembered.
    - an issue that is assigned, labelled `blocked`, names an unresolved
      `Blocked-by:` dependency (requirement 34j), or is a question or
      discussion rather than actionable work — the first three are
      deterministic and already applied by the Script (requirement 3j drops
      them from the `issues` array before the Co-Ordinator sees it, and
      reports each drop and its reason in `issues_excluded`, below); the
      judgement half is the Co-Ordinator's, over the whole thread
      (requirement 14a), since a comment can block, close, re-scope, or
      answer an issue that its body alone would make look selectable.

      **The dependency third is never the Co-Ordinator's to re-derive, and the
      Script refuses it if offered anyway** (agent-ops#566). An issue reaching
      the Co-Ordinator has, by requirement 3j's own construction, no unresolved
      `Blocked-by:` reference — but a stale sentence can still sit in its
      thread after the reference it named has closed, and a model reading that
      thread can reach for the sentence rather than the fact that the item is
      in front of it at all. Requirement 34e's recorder refuses a
      `needs_refinement` entry, from any reporting stage, whose own
      `reason`/`missing`/`evidence` names, by its issue number, the same
      dependency this cycle's own dependency gate (requirement 34j) already
      proves resolved for that item's thread: no block is recorded, no labels
      applied, and the refusal is logged — the item is
      left exactly as unaccounted-for as if nothing had been reported
      (requirement 3x), so it is not silently closed off by a report that
      never engaged with it. The judgement half above is untouched by this: a
      report declining an issue as a question or discussion, or for genuine
      under-specification, names no such reference, so it is recorded exactly
      as requirement 34e describes.

      **The assignee exclusion is a permanent, deliberate rule, not an
      incidental side effect** (agent-ops#447). It is load-bearing for the
      Enabler's escalation protocol: requirement 36a assigns every escalation
      issue to `enabler_assignee` precisely *so that* this exclusion keeps the
      pipeline from ever selecting its own request for human help as if it
      were work, and the config-time guard next to `enabler_assignee`
      (Configuration table) exists only because an unassigned escalation
      would defeat it. A human's own, unrelated assignment to themselves is
      read exactly the same way: an issue somebody has claimed by hand is
      theirs to work, not the pipeline's, and the rule does not distinguish
      the two — an assigned issue reaching this exclusion is always either
      one of those, never the pipeline's own bookkeeping (agent-ops#639: the
      only bookkeeping assignment this pipeline ever made — requirement
      38b's, below — was retired in favour of `blocked`/`blocked:<reason>`
      labels precisely so this exclusion would no longer need to tell the
      two apart). The rule therefore stays a hard exclusion, and stays
      permanent: it is not eligible for the Co-Ordinator's `needs_refinement`
      under requirement 16a, which is scoped to items *reached and evaluated
      in this cycle's own priority walk* — an assigned issue is dropped
      before that walk ever sees it, so there is nothing for the
      Co-Ordinator to report a judgement about.

      What was missing was never the rule — it was visibility into when a
      projection outlives its own reason. Requirement 38b's label pair is
      meant to be temporary, self-removing the moment its block clears
      (`release_refinement_label`), but a removal that fails (a `gh` call
      that does not take) can leave `blocked`/`blocked:needs-refinement` on
      an issue whose block has already cleared — readable only by a human
      already suspicious enough to read the filter's own source. Before
      agent-ops#639 the equivalent failure was on the *assignment*, and sat
      unnoticed for two days on agent-ops#338 before it was fixed by hand;
      moving the projection to labels does not remove the possibility of a
      failed removal, only the invisibility, since a stray `blocked`/
      `blocked:<reason>` label is exactly as visible on the issue as the one
      a human applies by hand. `issues_excluded` (requirement 3j) is the
      general fix for a *stuck exclusion*, whatever put it there, and a
      *reporting* one deliberately, not a *relaxing* one — narrowing the
      exclusion would only let the pipeline pick up exactly the escalation
      and refinement-tracking issues it exists to keep off the list. A live
      `issues_excluded` entry on the Co-Ordinator's own input whose most
      recent `issues-excluded` event (requirement 33) is old is now the
      signal a human needs to notice a stuck removal and clear it by hand —
      a reading requirement 33's own unknown-skips rule protects: a cycle
      whose gather failed or degraded leaves that event untouched rather
      than logging a fabricated change, so a transient `gh` hiccup does not
      refresh the timestamp and hide a genuinely stuck exclusion behind it;
    - a security finding whose only available fix is one a human must choose
      (e.g. a Dependabot alert with no non-breaking upgrade, needing a major
      version bump that changes the repo's public behaviour) — flag it, don't
      guess the upgrade;
    - dependent on a product or architecture decision that has not been
      made. (Example: poetic-fiddle's milestone M2 is gated on the §6.1
      packaging decision in its implementation plan — while that decision
      is open, M2 tasks do not meet the bar. Decisions belong to the human;
      never attempt to make one.)

    The last two exclusions, and requirement 17's "if in doubt, skip it", are
    reported rather than acted on silently — see requirement 16a.
16a. **Under-specified and decision-gated skips are reported, not silent.** The
    Co-Ordinator's final message carries an optional `needs_refinement` array,
    alongside `unblocked` and `voided`, whose entries are
    `{repo, item, source, reason, missing, evidence}`: `reason` is one line on
    why the item fails the selection bar, `missing` is what a selectable version
    would need (acceptance criteria, a scope bound, a named decision,
    reproduction steps), and `evidence` is what the Co-Ordinator actually read.

    An item qualifies only if it was **reached and evaluated in this cycle's own
    priority walk** and failed selection *solely* because it is too
    under-specified to rank against requirement 17's bar, because it is gated
    on an unmade human decision (the last two exclusions of requirement 16), or
    because it is an issue that is a question or a discussion rather than
    actionable work (requirement 16's issue exclusion, judgement half).
    Items excluded for any other reason — claimed, already blocked, void,
    assigned — are not reported: they are already handled, and reporting one
    would re-block an item whose clock is already running.

    The question-or-discussion case was itself on that not-reported list until
    requirement 3x, and being there was an error of exactly the kind the
    paragraph below describes. The other four are all cases where *something
    else already recorded the item*: a claim, a block, a void, an assignee.
    Nothing records a question. No clock runs on it. It is re-read and
    re-skipped every cycle, forever, and it is the one issue exclusion the
    Script cannot decide for itself (`scripts/gather-issues.sh` applies the
    other three; this one "cannot be a jq filter"), so it is also the one whose
    silence requirement 3x's corroboration would otherwise have to be blind
    to. Reporting it makes the judgement a record: the Enabler can adjudicate
    it (requirement 35a), a human sees the label, and the band becomes
    corroboratable like every other.

    Three limits keep it side-work. The Co-Ordinator must **not** sweep for
    under-specified items beyond the walk it was doing anyway (flags accumulate
    across cycles by themselves, and a sweep would spend a selection pass on
    something nobody asked for); it must not re-report an item already recorded
    as blocked — ordinarily requirement 16's first exclusion means it is never
    re-evaluated at all, and where requirement 18a's mandatory re-check does
    look at one again, that re-check is scoped to whether the recorded blocker
    still holds and is never grounds to re-report `needs_refinement`; requirement
    34e refuses the re-report regardless, if it happens anyway; and reporting
    never changes what the cycle selects. An empty array is the normal case.

    What this replaces is a silent skip, and the silence was the defect. An item
    nobody had specified was re-read and re-skipped by every cycle for as long as
    it existed: the pipeline paid to rediscover the same non-answer cycle after
    cycle, the item never became selectable by any route, and the one person
    who could have written the missing criteria was never told it existed.
    The pipeline looked healthy throughout, which is this system's signature
    failure mode (requirement 3b, requirement 34d) in its purest form — an item
    that starves while every component behaves exactly as specified.
17. From the remaining candidates, ranks the qualifying items best-first and
    returns up to `candidates_max` of them, each a stand-alone unit of work,
    clearly scoped, and adequately refined; the ranking preserves the
    priority walk, and the alternates exist because a peer node may win the
    claim on the first choice — not to lower the bar. Do not guess: if in
    doubt about an item, skip it — and report it under requirement 16a rather
    than skipping it silently. If nothing in the current category
    qualifies, fall through to the next category, then the next repo. Only
    after exhausting all repos does it return `{"selected": false}` with a
    one-line reason.
17b. **A refined item is selected on what the refinement says.** Where
    requirement 3h's `refinements` map names an item the Co-Ordinator is putting
    in a work order, an entry carrying a `spec` is carried into the work order's
    `context` **verbatim** — it exists nowhere else, and the Implementer starts
    with nothing but the work order, so a summarised refinement is one that was
    written by an expensive model and read by nobody. For `project-review` and
    `implementation-plan` — the two sources that still carry a `spec` and whose
    `context` the Co-Ordinator still authors itself (requirement 17h) — the
    Co-Ordinator pastes it; for `tech-debt`, requirement 17h's own compose step
    splices it in unconditionally instead, since the model no longer authors
    that source's `context` at all. An entry carrying a `comment_url` needs no
    special handling: the refinement is a comment on the item's own issue,
    which requirement 17h's live read (for `issues`/`tech-debt`) or requirement
    20's own paste instruction (for the sources that still have one) already
    carries in full, and requirement 14a already makes the latest contradicting
    comment the current instruction.
17f. **The Script verifies traceability before claiming, rather than trusting
    the model's own account (agent-ops#626).** A work order composed alongside
    others in the same Co-Ordinator engagement can carry one candidate's
    `context`/`acceptance` while actually holding another item's refinement
    content — the response is syntactically fine and each candidate
    individually plausible, so nothing catches the cross-item swap until an
    Implementer, handed nothing but the mismatched work order, finds it
    incoherent and burns the item's one refinement-per-human-touch allowance
    re-flagging a fault the item never had. `refinement_traceability_fault`
    (`lib/candidate-select.sh`) closes this the only way that does not depend on the
    model getting it right a second time: for each ranked candidate of a
    model-composed work order, in claim order, before requirement 17a's claim
    is attempted, it re-derives the item's own recorded refinement from
    `refinements` — keyed on that candidate's own `repo`/`item`, never on
    anything the candidate itself claims — and confirms it is genuinely
    present, after normalizing whitespace (TD-PPagop-26082307: collapse every
    run of whitespace to a single space and trim both ends, on both sides of
    the comparison), in that candidate's own `context` or `acceptance`. A
    model's paste of a multi-kilobyte spec or issue thread drifts in exactly
    this way — a reflowed line, a normalized list marker, a trimmed trailing
    space — without changing what it says, and normalizing tolerates all of
    that while still failing a passage that is genuinely missing or
    different; `TRACEABILITY_DEBUG=1` logs, to stderr, the normalized
    haystack/needle a comparison actually ran against, never required to
    diagnose a failure, only to see it directly.
    - A `spec` entry (requirement 17b) costs no extra read: the text is
      already in `refinements`, so its presence in `context` is checked
      directly.
    - A `comment_url` entry (requirement 17b) is checked in two stages. First,
      free: the issue number embedded in the URL itself must equal the
      candidate's own `item` — a comment_url naming a different issue is a
      fault regardless of what the work order says, and catches a corrupted
      `refinements` entry as readily as a model that ignored a correct one.
      Second, one `gh api repos/<repo>/issues/comments/<id>` read of the
      actual comment (the pre-fetched `comments` array on a repo's `issues`
      entry carries no per-comment id to join against, so this is the only
      way to know the comment's real text) — a fault if that text, normalized
      the same way, is present in neither `context` nor `acceptance`. The
      comment id itself is extracted by `refinement_comment_url_id`
      (`lib/refinement.sh`, the same predicate requirement 39c (The Refiner)'s recording
      seam and requirement 35a's reading seam both test a comment URL's
      shape against), which recognises the HTML permalink anchor
      (`#issuecomment-<n>`) and the REST API form (`.../issues/comments/<n>`)
      alike (TD-PPagop-26082603) — a `comment_url` matching neither shape is
      now a fault too, reported the same way the structural (wrong-issue)
      check above is, rather than the pre-fix behaviour of a bare `sed`
      extraction that recognised only the HTML form and silently returned "no
      fault" for anything else, having tested nothing at all.
    **A model-typed prose citation is checked too, independent of what is on
    record (agent-ops#1027).** The two checks above validate the *recorded*
    `refinements[repo][item]` entry; neither reads the `Refinement:`-style
    citation requirement 17b has the Co-Ordinator paste into the work order's
    own `context`/`acceptance` prose. That citation is text the model wrote,
    not anything the Script maintains, so it can name the wrong issue's
    comment even when the recorded refinement is correct, or when there is no
    recorded refinement for the item at all — agent-ops#876's work order cited
    agent-ops#911's own comment 5452331924 this way: a real, well-formed
    comment, just posted on a different issue. `refinement_traceability_fault`
    scans `context` and `acceptance` for every `issues/<n>#issuecomment-<id>`
    URL they contain — any repo-qualified or bare form, the same shape the
    structural `comment_url` check above already extracts — and faults the
    candidate the moment one names an issue other than its own `item`. This
    needs no `gh` call, runs before either check above, and is not scoped to
    an entry existing in `refinements` at all. Like the structural
    `comment_url` mismatch above, it is never repaired: `refinement_traceability_repair`
    only ever appends text, so a wrong citation the model already wrote stays
    in `context`/`acceptance` verbatim after repair and this check faults it
    again — a hard skip, not a repair candidate.
    It is, however, scoped to an `item` that is itself an issue ref (a bare
    number): "this citation names a different issue than the item" is a
    comparison that means something only when the item *is* an issue. Every
    other item ref a candidate can carry is a source's own composite key — a
    `project-review` recommendation's `review-<date>-R-NN`, a `failed-runs`
    workflow's `failed-run-<basename>`, an `implementation-plan` task — so
    without that scope the check would report a mismatch for every citation
    those sources' work orders carry, by construction rather than by fault:
    they are the three sources this function is reachable for at all (the 17h
    note below), the three whose `context` requirement 17b has the
    Co-Ordinator make self-contained by pasting related text verbatim, and the
    only ones a recorded `spec` is ever written for — which the repair half
    below appends to `context` itself, so an unscoped check would fault the
    Script's own append and leave a freshly refined item permanently
    unclaimable.
    **A failed check is repaired, not discarded (agent-ops#767).** The
    requirement is that the work order *carry* the item's refinement — not
    that the model be the one who carried it — and the Script is holding the
    text at the moment it asks. So `refinement_traceability_repair` appends
    the recorded refinement verbatim to `context`, under a heading naming it
    as the Script's own insertion, and the candidate proceeds to its claim;
    the repair is logged as `work-order-repaired` carrying the fault it
    answered. Traceability becomes true **by construction**, which is a
    stronger guarantee than any check of a model's compliance and one no
    model can fail.

    That this is the right half to enforce was settled in production. Between
    the check landing (2026-08-22T23:42Z) and the repair, it discarded 92
    candidates across 20 issues on four nodes and admitted **none** — while
    `coordinator_model` was `claude-haiku-4-5-20251001` and the bands feeding
    it were being trimmed to fit that model's window, so the text it was
    required to paste had in some cycles already been trimmed out of what it
    was given. The fleet selected no issue-sourced work for fifteen hours. A
    gate with no observed passes is not a gate.

    **Two faults are never repaired**: a `comment_url` whose embedded issue
    number disagrees with the candidate's `item`, and a model-typed prose
    citation (agent-ops#1027, above) that names a different issue. Both are
    a corrupt record or a copying failure the model already committed to
    text, not something appending a correct refinement alongside can fix,
    and appending another issue's refinement to this item's order is
    precisely the cross-item swap this requirement exists to prevent. Both
    stay a hard skip, and neither spends a `gh` read to reach that verdict.

    A candidate whose fault the repair cannot answer is skipped without a
    claim attempt — logged as `claim-skipped` with `cause: "untraceable"` and
    a `detail` naming what disagreed — exactly as a pre-claimed candidate is
    skipped, so a peer's later ranked candidate still gets a chance this
    cycle. Such a skip is counted in its own right: a cycle that loses every
    candidate this way stands down with `cause: "untraceable"` and a reason
    naming the check, never `raced`. It reported `raced` with `race_losses:
    0` for the whole of the fifteen hours above, sending every reader after a
    claim contention that did not exist, which is why the cause is now
    counted separately from both the pre-claimed skips and the race losses.
    An item with no `refinements` entry at all costs nothing: the check
    returns immediately with no `gh` call. A `gh` read that fails (network,
    rate limit) is itself a fault (TD-PPagop-26082307), reported the same way
    as a mismatched paste — `cause: "untraceable"`, retried next cycle — and
    surfaced via `guard_warn` rather than swallowed. This is the one place
    this requirement's own `gh` read departs from every other degraded `gh`
    read in this pipeline's fail-open convention: those read a fact about
    GitHub's availability, but this check exists to gate a claim on a
    refinement really being present, and assuming pass on a read it could not
    complete means a token going bad, a narrowed scope, or a sustained rate
    limit silently disarms the whole gate, indefinitely, while it keeps
    reading as green — exactly the failure mode this item's own repair
    (agent-ops#767, below) exists to prevent for the opposite direction. A
    refinement that cannot be read cannot be repaired either, so a candidate
    faulted this way is a hard skip, same as a corrupt `comment_url`.

    A fallback selection (requirement 3v) is not checked. `context` there is
    composed by `fallback_select_candidate` in jq, out of the very band entry
    the candidate names, so one item's refinement cannot reach another item's
    work order; and that composition draws on the item's own record rather
    than on `refinements`, so a spec-refined item picked mechanically carries
    no verbatim spec and would fault every time. The fallback's candidate
    list is one candidate long, so that fault would leave the cycle with
    nothing to claim — disarming the path requirement 3v exists to provide
    precisely when the model will not select.

    **Since requirement 17h (agent-ops#769), this check's own reachable scope
    has narrowed to the three sources whose `context`/`acceptance` the
    Co-Ordinator still authors itself** — `project-review`, `failed-runs`,
    `implementation-plan` — and this includes the model-typed prose-citation
    check above (agent-ops#1027): it is folded into the same
    `refinement_traceability_fault`, called at the same guarded site, so it
    is exempted for the identical reason — a requirement 17h compose replaces
    `context`/`acceptance` with a live read before this function ever sees
    the candidate, discarding whatever prose citation the model wrote along
    with everything else it authored. Read with that check's own
    issue-ref scope above, this leaves it a latent guard rather than one the
    ordinary cycle exercises: none of those three sources keys its items on an
    issue number, so the citation comparison is live only for a candidate that
    reaches the claim loop naming no `source` at all — the one shape a
    requirement 17h compose is not attempted for. Every other source's
    candidate is composed by
    requirement 17h before it ever reaches this check (`c_composed` in the
    claim loop), which calls `refinement_traceability_repair` unconditionally
    as part of composing — so the splice this requirement exists to verify
    has already happened, by construction, before this check would run. This
    is the same exemption a fallback pick already had, generalised: neither a
    fallback pick nor a requirement 17h compose can hold another item's
    refinement, because neither ever reads `refinements` for anything but the
    one item it is building.
17g. **No check verifies a trimmed candidate's `acceptance` against the
    item's own live text — requirement 17h's compose step removed the
    condition such a check would exist to catch.** Between agent-ops#821
    (issue #815) and agent-ops#1156, this requirement specified
    `item_text_fault`/`item_text_supply` (`lib/candidate-select.sh`, backed
    by an `item_live_text` fetch and a `_span_is_quotable` shape test): a
    trimmed `issues`/`tech-debt` candidate's `acceptance` was checked, its
    backtick-quoted spans against a fresh live read, because a Co-Ordinator
    running on the fleet's cheapest model against fit-ladder-trimmed input
    could invent a specific an Implementer would then trust as the item's
    own (cycle 20260826T064910Z-poetic-1-186841, issue #815's incident).

    Requirement 17h (agent-ops#769) removed the condition instead of leaving
    a check to keep catching its failure: every `issues`/`tech-debt`
    candidate's `context`/`acceptance`/`title` is now composed by the Script
    itself, from a live read, immediately before the claim — never from the
    model, and never from a trimmed extract. Nothing reaching the claim loop
    from either source can any longer be a model's paste of a possibly-
    trimmed extract, so there is nothing left for a check built to catch
    exactly that failure mode to intercept:
    `coordinator_fit_trimmed_items`'s own output — the scope both retired
    checks were gated on — could no longer contain a candidate that reached
    them un-composed (`c_composed` in the claim loop) from the moment
    requirement 17h landed (`6a4eaa4`, 2026-09-06T03:45:52Z). TD-PPagop-26090604
    is the record of that gap opening; agent-ops#1156 is where it closed,
    once requirement 17h's own compose step had run in production long
    enough to trust it was not itself regressing into the fabrication or
    incompleteness failure modes this requirement used to catch (an owner
    decision on agent-ops#1156, 2026-09-11, resolving escalation #1333: the
    soak was judged over).

    `item_text_fault`, `item_text_supply`, `item_live_text` and
    `_span_is_quotable` no longer exist in `lib/candidate-select.sh`; the
    claim loop no longer counts a `fab_faults` skip or stands down with
    `cause: "fabricated"`. A cycle whose every candidate fails traceability
    now stands down `untraceable` regardless of whether requirement 17f's own
    check or requirement 17h's compose step produced the fault, since there
    is no second, narrower cause left to distinguish one from the other.
    Requirement 17f's fail-closed refusal on an unreachable `gh` read, and
    requirement 17h's own fail-closed refusal on a failed live fetch at
    composition (folded into `cause: "untraceable"`), are both unchanged by
    this retirement — neither depended on the checks that were removed.
17h. **The Script composes `context`/`acceptance`/`title` for a Co-Ordinator
    selection, from a live read or the pre-fetched band entry — never from
    the model, and never from a trimmed extract (agent-ops#769, resolving the
    escalation at agent-ops#844 with option (b)).** Requirements 17f/17g exist
    because the Co-Ordinator runs on the fleet's cheapest model
    (`coordinator_model`, `claude-haiku-4-5-20251001`) against input the fit
    ladder (requirement 4i) may already have trimmed, and are asked to
    reproduce kilobytes of that input verbatim — a task requirements 17f/17g
    could only ever catch failing after the fact. This requirement removes
    the task instead of catching its failure: for the ten sources the
    Script already gathers as structured data (`security`, `code-quality`,
    `review-feedback`, `merge-conflicts`, `dequeued`, `landing-refusals`,
    `abandoned-drafts`,
    `human-visibility`, `tech-debt`, `issues`), the
    Co-Ordinator selects `{repo, source, item}` and the Script itself builds
    `context`, `acceptance` and `title` immediately before the claim
    (`compose_selected_candidate_text`, `lib/candidate-select.sh`) — the model
    authors neither field for these sources. The three sources the
    Co-Ordinator still derives itself live — `project-review`, `failed-runs`,
    `implementation-plan` — are unaffected: they have no pre-fetched band for
    the Script to compose from, and were never subject to the fit ladder's
    trimming in the first place, so this requirement does not reach them and
    the Co-Ordinator still authors `context`/`acceptance` for them exactly as
    requirement 20 describes.

    - **A live read for the only two trimmed bands, the pre-fetched entry for
      the rest.** `issues` and `tech-debt` are the only bands the fit ladder
      (requirement 4i) ever trims, so these two are rebuilt from a fresh live
      read (`item_live_entry`) every time they are selected, whether or
      not this particular cycle actually trimmed them — a work order's
      `context` must never depend on the band entry's freshness at all, not
      merely recover when it happened to be visibly short. That read is two
      calls, and the split is load-bearing: `gh issue view --json title,body`
      for the title and body, and the **paginated** REST comments endpoint
      (`gh api repos/<slug>/issues/<n>/comments --paginate`) for the thread,
      never `gh issue view`'s own `--json comments` — that GraphQL field
      returns only the first ~100 comments and does not paginate, so composing
      from it would have capped this requirement's "body and every comment"
      guarantee at a ceiling it never declares and a longer thread would lose
      its tail silently, exactly where a clarification or a scope cut tends to
      sit (agent-ops#1012). The composed `context` therefore carries the whole
      thread at any length. Tech-debt has been
      a GitHub issue carrying `pw::type:tech-debt` since the register's D15
      migration, so it is fetched identically to an `issues` entry. The other
      eight sources' band entries are never trimmed at all (the fit ladder's
      own scope, requirement 17g above), so the Script composes directly from
      the entry `coordinator_eligible_items` already located for this
      candidate's own `{repo, source, item}` — a lookup, not a second fetch.
    - **The per-source template mirrors `fallback_select_candidate`'s own**
      (requirement 3v) — the working precedent this requirement generalises
      from a last-resort mechanical pick to the ordinary selection path,
      keeping the same wording so a work order reads the same regardless of
      which path produced it. A Dependabot takeover (`merge-conflicts` with
      `bot`/`rebase_requested` both true) is templated on its own terms —
      naming the replacement pull request and the bot's own closure — never
      the ordinary rebase instruction, since a takeover is fresh work on a new
      branch, not a finish of the existing one. `tech-debt` is the one source
      whose wording deliberately departs from the fallback's: the fallback
      reduces a tech-debt entry to its `body` alone, having only the band
      entry to compose from, where this requirement's live read holds the
      whole issue thread — so it is composed through the same body-and-every-
      comment shape as `issues`, and its `acceptance` names the current state
      of that thread rather than the record as originally filed. A
      clarification or scope cut left in a tech-debt issue's comments is
      exactly the text this requirement exists to stop losing.
    - **The recorded refinement is spliced unconditionally, generalising
      agent-ops#767.** `refinement_traceability_repair` — the repair half of
      requirement 17f — is called on every freshly composed candidate,
      always, rather than only after a fault check finds one missing: there
      is no model-authored text left to fault, so the one way a refinement
      ever reaches a Script-composed work order now is this unconditional
      splice.
    - **A failed live fetch is fail-closed, folded into `cause: "untraceable"`
      (requirement 17f's own cause), not a fallback to the trimmed or stale
      entry.** So is a candidate naming an `{repo, source, item}` this cycle's
      own gather (`ordered_repos_json`) no longer contains — a stale or
      malformed candidate the Co-Ordinator should never have named. Both skip
      the candidate exactly as an unrepaired requirement 17f fault does: the
      next-ranked candidate gets the slot, and a cycle that loses every
      candidate this way stands down `untraceable`, never `raced`.
    - **A fallback selection (requirement 3v) is composed the same way.** The
      claim loop runs this requirement's compose step for a fallback pick too
      (`c_composed`, alongside `selected_by_fallback`), so an `issues`/
      `tech-debt` item the mechanical fallback picks is rebuilt from a live
      read the same as an ordinary selection would be — `fallback_select_candidate`'s
      own band-entry composition for these two sources was subject to exactly
      the trimming this requirement exists to close, and unifying the two
      paths costs nothing extra for the other eight sources, whose template
      output is identical either way.
17a. **The claim.** The Script — never the model — takes an atomic per-item
    claim before the Implementer starts, walking the ranked candidates in
    order and handing the first successful claim onward (`lib/claim.sh`).
    The primitive is create-only, so GitHub arbitrates every race:
    - *Branch claims* (every source except the four finishing ones —
      `review-feedback`, `merge-conflicts`, `dequeued` and `abandoned-drafts`
      — plus one exception within `merge-conflicts` itself, below): a REST
      create-ref (`POST /git/refs`) on the target repository at the default
      branch's head. The claim branch **is** the
      working branch, derived deterministically (`claim_branch_for`,
      `lib/candidate-select.sh`) so every node computes the same name for the
      same item: `agent/<item-ref>`, uniformly — tech-debt included, since D15
      as revised (#869/#875/#879) moved its item to the same bare-issue-number
      shape an `issues` item already has, so it claims the same way. A 422
      (ref exists, even at the same SHA — which a plain `git push` of an
      identical ref would no-op) means a peer holds the item: log
      `claim-lost` and move to the next candidate.

      A `merge-conflicts` work order carrying `"takeover": true` (requirement
      3s) takes a *branch* claim, not the file claim every other
      `merge-conflicts` item takes below — it names Dependabot's PR, and
      taking it over means a new PR on a new branch of ours, exactly like any
      other fresh item, not a finish of an existing one. The item ref
      (`pr-<n>-conflict-<head-sha>`) still exists and is still what gets
      claimed — only the *kind* of claim differs, decided by the work order's
      `takeover` field, which the Co-Ordinator sets and the Script reads
      before deriving `agent/<item-ref>` as usual.
    - *File claims* (`review-feedback`, `dequeued`, `landing-refusals` and
      `abandoned-drafts`,
      plus every `merge-conflicts` work order *except* a takeover, which
      finish an existing PR and have no new branch to create): a create-only
      contents-API PUT (no `sha`) of `claims/<repo>/<ref>.json` in the state
      repository. For `abandoned-drafts` the ref is scoped to the draft's head SHA
      (`pr-<n>-abandoned-<head-sha>`), for `merge-conflicts` likewise to the
      PR's head SHA (`pr-<n>-conflict-<head-sha>`), for `dequeued`
      likewise again (`pr-<n>-dequeued-<head-sha>`), and for
      `landing-refusals` to the unreconciled comment ids instead
      (`pr-<n>-landing-refusal-<ids>`, requirement 53 — that source's own
      candidacy turns on which comments are unanswered, not on the head),
      so two nodes racing to
      finish, rebase, or fix the same PR contend on the same file and one
      wins. This list is exactly `PREFLIGHT_EXISTING_BRANCH_SOURCES`
      (requirement 34m) plus the takeover carve-out above, and the two are
      written down in two places (`lib/coordinator-phase.sh`'s claim dispatch
      and
      `lib/preflight.sh`) that must agree: a source preflight believes has a
      pre-existing branch, but the dispatch does not, gets a fresh branch
      minted for it off the default branch and the candidate's own `branch`
      overwritten with it, handing the Implementer a branch no pull request
      tracks. A takeover needs no separate file claim of its own: `agent/<item-ref>` is derived
      from the same head-SHA-scoped ref, so two nodes racing to take over the
      *same* Dependabot PR compute the identical branch name and contend on
      that single `POST /git/refs` instead — one claim, not two.
    - **The PR-keyed claim (issue #238).** A round- or head-SHA-scoped item claim
      excludes nothing about a peer working the *same* PR under a *different*
      round's or head's ref — the mechanism that let PR #205 be worked by three
      nodes at once. So immediately after winning a finishing-source item claim
      taken via the file-claim path above — every `review-feedback`,
      `dequeued`, `landing-refusals` and `abandoned-drafts` work order, and
      every `merge-conflicts`
      work order except a takeover, which contends on its branch claim instead —
      the Script takes a second, separate file claim keyed `pr-<number>` (same
      repository, same create-only primitive) *before* handing the work order
      onward. The number is the candidate's own `pr_number` where it carries a
      usable one, and otherwise the one its **item ref** embeds — all five
      sources mint refs shaped `pr-<n>-review-<id>`,
      `pr-<n>-conflict-<sha>`, `pr-<n>-dequeued-<sha>`,
      `pr-<n>-landing-refusal-<ids>` and `pr-<n>-abandoned-<sha>`
      (requirements 3c, 3e, 3g, 3z, 53), so the Script derives it deterministically
      rather than depending on the Co-Ordinator having copied a field: a gate
      that engages only when the model remembered would silently reopen the
      very failure this closes. Only a ref of none of those shapes yields no
      number, and then no PR-keyed claim is taken. Losing it means a peer
      already holds this PR — under whatever ref won there — so the item claim
      just won is released (nothing was pushed under it) and selection falls
      through to the next candidate
      exactly as a lost item claim would. Winning it holds both claims — but,
      unlike the item-keyed one, the PR-keyed claim is held until *this
      cycle's own end*, not until `pr-raised`: see *Release* below (issue
      #360).  This is what makes the exclusion real fleet-wide and race-safe
      — requirement 3p's candidate filter is a cost-saving visibility layer
      over the same fact, not a substitute for it, since a peer's claim taken
      after 3p's filter ran is still possible and only this second
      create-only write actually arbitrates it.
    - Every won claim also writes a best-effort **registry entry** at
      `claims/<repo>/<key>.json` in the state repository — the lock is the
      ref or file above; the registry (minus the PR-keyed exclusion entries
      *Release* below explains) is what back-pressure counts (2.2), and the
      whole registry, PR-keyed entries included, is what gc sweeps —
      recording the base SHA, node, cycle, item, source, timestamp and, for a
      finishing-source claim (either the item-keyed or the PR-keyed one), the
      `pr_number` it targets (requirement 3o).
    - *Release*: an open PR supersedes the *item-keyed* claim — that registry
      entry is dropped the moment `pr-raised` is logged, and the branch lives
      on as the PR's head. The PR-keyed claim is not dropped at the same
      moment: it exists to keep a peer off this PR, and the Reviewer stage
      that runs next still writes to it, so it is held until this cycle's own
      end — the Reviewer's terminal handoff (`pr-ready`), a reviewer handback,
      a stage failure, or a signal — whichever this cycle actually reaches.
      An ending none of those handlers see — an unhandled `errexit` abort
      after `pr-raised` — is caught by the EXIT trap's backstop: `cleanup`
      releases the PR-keyed claim as its first act, idempotent (a handled
      ending has already cleared the key, and then it does nothing) and
      time-bounded like the signal handler's release, so no exit path leaves
      `pr-<n>` standing for the gc alone to retire.
      Dropping it at `pr-raised` reopened the exact race issue #238 closed: a
      Reviewer stage still pushing to a PR forty-three minutes after its
      cycle's own PR-keyed claim was released, while a peer claimed and
      force-pushed a rebase of the same PR under a fresh ref (agent-ops#360).
      Every path that ends the cycle without a PR at all (a void verdict, a
      blocked verdict with no PR, a failed workspace clone, a stage failure or
      timeout before any PR exists) releases both claims together, in the
      same call — a claim branch is deleted **only** when it still points at
      the SHA the claim recorded and no open PR uses it, so pushed work is
      never deleted. Entries older than `claim_ttl_hours` are swept by
      `lib/claim.sh gc` under the same only-if-untouched rule (a node that
      died mid-cycle must not hold its item forever); every cycle runs the
      sweep at start (2.1a), so a dead node's claims — item-keyed or
      PR-keyed — outlive it by at most the TTL plus one cycle interval.
    - A candidate this cycle's own gather already saw claimed is **skipped
      without an attempt**: the Script checks each candidate's repo+item
      (raw, and in its branch-sanitised form) against the claims gathered
      for requirement 3o before spending a claim call on it, logs
      `claim-skipped` with `cause: "pre-claimed"`, and moves to the next
      candidate. The attempt would lose anyway — but a loss knowable from
      data already in hand is not contention, it is the Co-Ordinator
      proposing claimed work (requirement 3q closes the pre-fetched
      sources; this closes the derived ones), and counting it as a race
      would corrupt the contention signal 17d exists to keep honest. Skips
      count toward neither `claim_attempts` nor `race_losses`.
    - Claims **fail closed** per candidate: any outcome other than a won
      claim (a lost race, or GitHub unreachable) moves to the next
      candidate. Each miss logs `claim-lost` with a `cause` — `held` for
      `lib/claim.sh`'s rc 3 (a peer genuinely holds the item: healthy
      contention, the work is being done, just not by this node) or
      `unreachable` for its rc 1 (GitHub could not be reached at all,
      fail-closed: no work is being done by anyone), any other rc verbatim.
      A miss on the PR-keyed claim above rather than on the item claim reads
      `pr-held` instead of `held` — the same healthy contention, named apart so
      a reader can tell which of the two claims a peer holds — and carries the
      `pr_claim_key` it contended on. It renames `held` only: a PR-keyed claim
      that came back `unreachable` is an outage like any other and is counted
      as one.
      A cycle whose every candidate is lost stands down with reason "every
      candidate is already claimed elsewhere" — unless every miss was
      `unreachable`, in which case the reason instead names the outage
      ("GitHub could not be reached for any candidate — this is an outage,
      not contention"), so a GitHub or token outage does not read as a fleet
      politely yielding to itself. A node that cannot reach GitHub to claim
      could not have pushed the work either. A cycle that attempted nothing
      at all because every candidate was skipped as pre-claimed stands down
      with reason "every candidate was already claimed before this cycle's
      Co-Ordinator ran — skipped without an attempt". This `stand-down`
      event also carries the same distinction structured, as `cause` —
      `raced`, `unreachable`, `pre-claimed` or `untraceable` (requirement
      17f, and requirement 17h's own fail-closed refusal, name the last one,
      with its own reason and its own counter) — so a reader (the dashboard
      included) does not have to re-parse the reason text (issue #245), plus
      `claim_skips` whenever any candidate was skipped and `trace_faults`
      whenever the traceability check faulted one, whatever the cause. A
      `raced` stand-down chains another selection cycle under requirement
      39 (Finish-then-continue)'s ordinary bounds; `unreachable`, `pre-claimed` and `untraceable`
      never chain — re-running into the same outage or the same selection
      defect buys a second Co-Ordinator engagement and the same ending.
      A win that followed one or more
      `held` losses is a *recovered* race, not an ordinary first-try
      selection: the `selection` event that names the winning candidate
      additionally carries `race_losses`, the count of `held` losses that
      preceded it, present only when it is greater than zero.
    - When `state_repo` is unset (a single-node operation), file claims are
      vacuously won and the registry is skipped; branch claims still work.
    - `--dry-run` claims nothing. `--once` claims exactly like an unattended
      cycle: a supervised run contends with the fleet on equal terms.
    - **The winning candidate's `pr_label` (agent-ops#956).** The instant a
      claim is won, the Script stamps the configured `pr_label` — the same
      `config.json` value threaded into the Co-Ordinator's runtime input —
      onto the claimed work order, alongside `branch`, unconditionally
      overriding whatever value the candidate already carried (including
      none). This is the guaranteed source of the field the Implementer
      labels its pull request with (requirement 23): the Co-Ordinator's own
      copy (requirement 20) and `fallback_select_candidate`'s composition
      (requirement 3v) are belt-and-braces, never load-bearing, since a
      Co-Ordinator whose model output omits or mistypes `pr_label` would
      otherwise raise a pull request no gatherer — `gather-review-
      feedback.sh`, `gather-abandoned-drafts.sh`, `gather-merge-
      conflicts.sh`, `gather-dequeued.sh`,
      `gather-human-visibility-hygiene.sh`, `scripts/sweep-closed-issues.sh`,
      `lib/merge-budget.sh` — or the back-pressure count (2.2), could ever
      find again.
17b. **The orphan-branch sweep.** The gc's only-if-untouched rule (17a)
    leaves one state behind on purpose that is right for the work and wrong
    for the item: an Implementer that pushed commits and died before its
    draft PR existed leaves a moved ref with no PR — which nothing recovers
    (`gather-abandoned-drafts.sh` lists PRs, not branches), every later
    claim 422s against, and the Co-Ordinator's exclusion reads as "claimed,
    skip". The work is unreachable and the item permanently unselectable,
    with no event ever saying so. Its sibling is the unmoved ref whose
    best-effort registry write never landed, wedging the item with nothing
    to recover. So after the gc (2.1a), every cycle runs
    `scripts/sweep-orphan-branches.sh` over each configured repo's
    `<branch_prefix>*` and `td-record/*` refs.
    `techdebt_file_debt` (`lib/tech-debt-file.sh`) no longer mints
    one — agent-ops#874 moved its filing to a labelled issue — but this walk
    still needs to recognise, and eventually retire, any branch a filing from
    before that move left behind. A ref is a provable orphan only when **all
    three** hold: no open PR uses it, no registry entry stands for it (only
    a clean 404 proves absence — any other failure skips the ref, fail
    closed), and its tip commit is older than `abandoned_draft_after_hours`
    — the same judgement that makes a draft abandoned.
    `td-record/<ID>` is swept differently again, and is
    the one prefix that is delete-only, never recovered: a filing pull
    request a human has closed without merging means they declined that
    record, and a recovery draft would hand it straight back to them
    (TD-PPagop-26082310). The sweep asks
    `gh pr list --head <branch> --state closed` and counts only the pull
    requests whose own state is `CLOSED` — that listing is `[CLOSED,
    MERGED]`, exactly as GitHub's own "Closed" tab is, so a merged filing
    must be filtered out here rather than assumed absent — leaving a
    non-zero count unambiguous: the filing was declined. It then
    deletes `td-record/<ID>` outright (`released`,
    `reason: "filing-declined"`), then goes one step further than any other
    ref here: it reads `tech-debt/<ID>.md` at the default branch's own tip to
    ask whether `<ID>`'s record reached `main` some other way. A clean 404
    means it never did, so the id is spent with nothing to show for it and
    its `td/<ID>` reservation is released alongside it (a second `released`);
    a 200 means the record landed some other way, so
    the reservation is left alone as an inert, already-honoured lock; any other failure answers nothing, so — fail closed,
    like every guard here — it is left alone too. Because this delete and
    release together can cost two actions against the per-run cap below, the
    sweep reserves both up front rather than checking once per branch: a run
    with only one action of headroom left defers the whole pair instead of
    deleting `td-record/<ID>` and stranding the reservation release for a
    later pass — neither ref is touched, and the branch is found again,
    unchanged, next run (TD-PPagop-26082310). This is a narrow exception
    to the reservation-lock exemption two sentences above, not a relaxation
    of it: a `td/<ID>` reservation is only ever released this way from inside
    the declined-filing arm, immediately after its own `td-record/<ID>`
    sibling was confirmed declined, never for a bare reservation encountered
    with no such sibling. A `td-record/<ID>` whose pull request merged needs
    no separate handling — the ordinary merged-PR check below already
    deletes a merged head's leftover ref — and one with no pull request at
    all, a filing killed between its contents write and `gh pr create`, falls
    through to the ordinary recovery-draft path unchanged, since that is a
    genuine crash orphan, not a declined one. For each other orphan the sweep restores a state the
    pipeline already handles: commits ahead of
    the default branch become a **draft PR** (labelled `pr_label`, so the
    abandoned-drafts machinery recovers the work exactly as it recovers any
    stalled draft; retried without the label, loudly, where the label is
    missing) — **unless a PR was ever merged from that head**, which the
    sweep checks (`gh pr list --head <branch> --state merged`) before
    trusting `ahead_by` at all: every repo here squash-merges, so a merged
    branch's own commits never enter the default branch's history and
    `ahead_by` stays positive forever even though the work already landed —
    without this check that permanently-ahead, already-merged-but-undeleted
    ref would read as a fresh orphan on every sweep and mint an endless
    stream of redundant recovery drafts (issue #302) — **or unless the
    branch's own *work*, not its own head, already landed via a rival
    branch**, which the sweep checks by reducing both branches to a stem —
    the `branch_prefix` claim prefix stripped from
    the front and a
    trailing, **exactly** twelve-hex-character random suffix stripped from
    the back, if present (a lower bound would misfire: a tech-debt id like
    `TD-PPagop-26081403`'s own trailing `-26081403` is eight hex-legal
    digits, and treating that as the suffix would collapse every item under
    the `TD-PPagop` scope to one stem) — and searching the repository's
    recently closed pull requests for a different branch sharing that stem
    whose merge postdates this branch's own first commit: two cycles can
    claim the same item concurrently and race to a PR, and the loser's dead
    branch carries commits a rival already superseded (sometimes with a
    fix the loser never saw), so resurrecting it as a recovery draft would
    reintroduce that superseded — sometimes regressed — code (issue #500,
    PR #370). A ref with nothing ahead, with a merged PR against its own
    head, or superseded by a rival branch's merge, is **deleted** — it was
    only ever the claim, and the claim is dead, already honoured, or
    honoured elsewhere. A failure to determine the merge state fails the
    same way as the other guards: skip the ref, warn, touch nothing. The
    rival-branch search is the one guard that does not: it cannot make the
    ref *safer* to delete, only safer to leave as unrecovered work, so on no
    match, or on any failure to get an answer, nothing about today's
    behaviour changes and the ordinary recovery draft still gets filed —
    quietly on a clean "no rival found", but with a `warning` naming the
    branch when the lookup itself failed, so that gap stays visible without
    adding noise to every ordinary recovery. Actions are capped per run
    (three per repo per cycle, the overflow reported, never silent), logged
    as `orphan-branch-recovered` / `orphan-branch-released` events, and
    every node may sweep concurrently: GitHub rejects a second open PR for
    the same head and a second ref delete is a no-op, so the worst race
    outcome is a warning. Skipped on `--dry-run`. One priced residual: a
    live claim whose registry write failed and whose ref is untouched looks
    identical to the empty orphan, so its ref can be deleted mid-run — the
    Implementer's later push recreates it, and the cost is at worst a
    duplicate PR, priced against an item wedged forever.
17c. **The post-merge closing-keyword sweep.** Requirement 25a's checks — its
    CI workflow and its script-side gate — stop a *new* pull request from
    merging without a real closing keyword;
    this is the backstop for what already got through — a PR merged before
    that check existed, or one that merged some other way — and for the
    ordinary lag between a fix landing and the issue it was meant to close
    actually closing. After the orphan-branch sweep (17b), every cycle runs
    `scripts/sweep-closed-issues.sh` over each configured repo: for every
    merged, `pr_label`-labelled pull request naming an issue `N` GitHub
    still reports open, it closes that issue with a comment citing the merge
    as evidence (the PR number, its merge commit) instead of leaving the
    tombstone that keeps a finished item selectable forever (issue #240;
    PR #206's "Implements #198" left #198 open for three days after its own
    fix merged, selected and voided twice in the meantime). A merged PR
    names its issue by the `<!-- agent-ops:closes-issue item=N -->` marker
    (requirement 23b), or — when the marker is missing — by a head branch of
    exactly `agent/<N>`, the same Script-minted anchor requirement 25a's CI
    check reads, so one forgotten prompt instruction cannot blind the CI
    check and this sweep on the same PR.
    An issue GitHub reports `state_reason: "reopened"` is exempt: somebody
    reopened it after a close, and "still open" alone cannot tell that apart
    from "never closed". Without the exemption the sweep would re-close, on
    the hour and with a fresh comment each time, exactly the issue a human
    deliberately put back — the same answer requirement 34k's
    `void-object-closed` record gives on the other sweep, spelled here with
    no record of our own to keep, because the re-open is GitHub's record of
    it. The skip is reported as a warning, never silent.

    Bounded to the most recently updated merged pull requests per repo, and
    idempotent by construction — it only ever acts on an issue GitHub itself
    still reports open and not reopened, so re-running it costs nothing once
    the backlog is cleared. Actions are capped per run (three per repo per cycle, the
    overflow reported, never silent), logged as `issue-closed-post-merge`
    events, and every node may sweep concurrently: GitHub's own issue-close
    is idempotent, so the worst race outcome is two nodes both finding
    nothing left to do. Skipped on `--dry-run`.

    The same pass also retires the requirement 8c `cause: "merged"` half of
    an Approver-adjudication escalation (agent-ops#1215): one extra `gh issue
    list` call per repo, never per pull request, for every open issue
    carrying `enabler_escalation_label` whose body names a `pr-<n>-approver-
    adjudication` reference, matched locally against the merged-pull-request
    listing this sweep already fetched. A match closes the issue with a
    comment naming who merged the pull request and when, and reports
    `{"action":"approver-escalation-retired", …, "cause":"merged", …}` for
    the caller to log as `approver-escalation-retired` — this is the only
    fleet-wide site that ever notices a pull request merged some way other
    than this pipeline's own arm (`lib/landing.sh`), so it is also the only
    place a human's own merge click can retire one. Shares this pass's
    `$max_actions`/deferred budget with the closing-keyword sweep above,
    rather than a separate cap of its own. An escalation somebody reopened
    (`stateReason`, read on the same listing rather than for a second call)
    is left alone, for the identical reason the closing-keyword sweep above
    refuses a `state_reason: "reopened"` issue: this pass re-lists the same
    merged pull request every stand-down for as long as it stays inside
    `pr_search_limit`, so without the check a re-open would be undone —
    with a fresh comment — on the hour, every hour. A listing that fails
    outright reports a `warning`, the same as the merged-pull-request
    listing above: a successful call with nothing matching answers `[]`, so
    an empty result means the call itself did not answer, and skipping that
    silently would be indistinguishable from the common "nothing is
    escalated" case while retiring nothing for as long as the failure
    lasted. The rest of the pass runs regardless — the closing-keyword
    sweep does not depend on this call.
17g. **The reservation-release retry sweep.** A `td/<id>`/`td-record/<id>`
    tech-debt reservation branch a failed cleanup delete could not remove is
    not left orphaned for good: since TD-PPagop-26082427, that
    failure wrote a durable marker into the state repository instead of
    only logging and swallowing it, and this sweep is what
    retries it. The cleanup that wrote such a marker was `lib/tech-debt-file.sh`'s
    own `_techdebt_unfile`, on `techdebt_file_debt`'s old id-reservation
    filing path; agent-ops#874 retired that path (component 23d), so this
    sweep now only ever has pre-existing markers left to drain, never a fresh
    one. `scripts/release-pending-reservations.sh` walks every marker
    under `reservation-releases/` in `state_repo`, one invocation covering
    every configured repository at once — each marker already names its own
    target repo, so this is not a per-repo loop the way 17b/17c are — and
    for each: retries the branch's own delete; on success, or on a delete
    that fails but a follow-up read confirms the branch already gone
    (released by a peer's own concurrent retry), clears the marker; on a delete that fails
    again, leaves the marker for the next cycle's pass. Recovery therefore
    costs no more than time — the marker survives until the transient
    GitHub failure that first defeated `_techdebt_unfile` finally clears, or
    until a human deletes the branch by hand and lets this sweep notice and
    clear the stale marker on its next pass. Where a `td-record/<id>` marker
    and its sibling `td/<id>` marker for the same `id` both sit in the same
    repo's directory under `reservation-releases/` — the shape a window that
    failed both of `_techdebt_unfile`'s own deletes leaves behind — this
    sweep fetches and classifies every marker in that directory before
    acting on any of them, then releases every `td-record/<id>`-branch
    marker before any `td/<id>`-branch marker, matching `_techdebt_unfile`'s
    own record-before-reservation ordering regardless of what order the
    state repository's own directory listing names the two files in
    (TD-PPagop-26082805). A delete that keeps failing is
    not retried and warned about identically forever, though: once the
    marker's own `ts` is at least `reservation_release_stuck_after_days` old
    (TD-PPagop-26082806, agent-ops#1011; `0` restores the old unconditional
    retry-forever behaviour) and it has not already been flagged, this sweep
    treats it as stuck rather than merely transient — an archived target
    repository, a protected branch, a login that lost push access — and
    escalates exactly once: it writes `escalated_at` back onto the marker
    itself (a CAS `PUT` against the same `sha` this pass already read) and
    reports it, rather than the usual `warning`. The branch delete is still
    retried every pass after that, same as before — it is cheap, and it is
    what lets a belated fix on the target-repo side self-heal via the
    ordinary released/absent path above — but a marker already carrying
    `escalated_at` reports nothing further on a delete that keeps failing:
    the one-time escalation already told a human, and repeating it, or
    falling back to `warning`, would be exactly the identical-every-cycle
    noise this behaviour exists to stop. A marker whose `escalated_at` write
    itself fails is treated as not yet escalated and reported as an ordinary
    `warning` instead, so the next pass gets another chance to persist it
    rather than silently losing the escalation. Logged as
    `reservation-release-retried` (`outcome: "released"|"absent"`), or a
    `warning` naming the repo and branch a delete or a marker-clear failed
    again on, or — the once-only stuck case above —
    `reservation-release-stuck` naming the repo, branch and how long the
    delete has been failing. Every node may run it concurrently: a second
    delete of an already-gone branch is a no-op and a second clear of an
    already-cleared marker 404s, which this sweep already treats as nothing
    to report — the same race tolerance 17b/17c already rely on. Skipped on
    `--dry-run`: it deletes refs and state-repo markers. A no-op — logged as
    nothing, since there is nothing to warn about — where `state_repo` is
    unset, the same single-node reading `lib/claim.sh`'s own claim registry
    gives it.
18. When it skips a blocked item, it may cheaply verify whether the recorded
    blocker still holds; if the blocker is demonstrably gone, it reports
    that in its final message so the Script can append an `unblocked` event,
    and may then treat the item as a candidate this same cycle. Two limits,
    both load-bearing (requirements 9b, 34c):
    - This applies to *impediments only*. Discovering that the item's work is
      already **done** is never grounds to unblock it — that is a void, and
      unblocking it hands it back to the pool to be rediscovered every cycle.
      Say so explicitly in the prompt, with the reasoning: an agent told to
      "clear blockers that no longer apply" will otherwise conclude, correctly
      and disastrously, that an already-done item has no blocker.
    - It may **never** clear a void item, and is given no field with which to
      try. It may *create* one, in `voided`, for a candidate it can see
      conclusively is already done, which saves an entire Implementer run — with
      the `reason` and the `evidence` requirement 34c has always demanded, and
      subject to requirement 34d's guard, which records an unevidenced or
      refuted entry as blocked instead.
