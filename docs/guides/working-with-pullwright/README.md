# Working with Pullwright from a target repository

<!-- toc:start -->
- [What it does](#what-it-does)
- [Responding to your review comments](#responding-to-your-review-comments)
- [Staying in front of you](#staying-in-front-of-you)
- [Issue priority](#issue-priority)
- [Reserving an issue for yourself](#reserving-an-issue-for-yourself)
- [Cross-item dependencies](#cross-item-dependencies)
- [Handing a pull request to the pipeline](#handing-a-pull-request-to-the-pipeline)
- [Merge autonomy](#merge-autonomy)
<!-- toc:end -->

## What it does

Once an hour:

1. **[Co-Ordinator](../../concepts/glossary.md#co-ordinator)** (Haiku) selects at most one well-scoped item of work (security findings, review feedback, merge conflicts on otherwise-ready PRs of ours, abandoned draft PRs of ours, failed CI runs, tech-debt, issues, fiddle's implementation plan, project-review recommendations, or code-quality findings). Security work — open Dependabot alerts and security code-scanning alerts — is always prioritised ahead of everything else; an issue you have marked `Urgent` comes second; answering your review feedback comes third, rebasing a ready PR of ours that has hit a merge conflict comes fourth, and finishing a draft PR this system started and then abandoned comes fifth. Issues rank by their **`Priority`** field — `Urgent`, `High`, `Medium` (also the default when the field is unset) and `Low` each sit at a different point in the order — so triaging an issue is how you move it up or down the queue.
2. **[Implementer](../../concepts/glossary.md#implementer)** (Sonnet/Haiku) clones the repo, implements the item on a feature branch, and opens a draft pull request — or, for review feedback, pushes to the existing branch of the PR you commented on.
3. **[Reviewer](../../concepts/glossary.md#reviewer)** (Sonnet, or Opus when the Implementer graded the work `complexity:high`) checks and corrects the implementation, then marks the PR ready for review.
4. **[The Landing Gate](../../concepts/glossary.md#landing-gate)** reviews and merges the pull request. At the default
   [`merge_autonomy`](../../concepts/glossary.md#merge-autonomy) (`human`) a human does both; an opt-in trust ladder (see
   [The Landing Gate](../../IMPLEMENTATION-PIPELINE-SPEC.md#the-landing-gate))
   can add an **[Approver](../../concepts/glossary.md#approver)** App review and, at its top two rungs, have the
   [Script](../../concepts/glossary.md#script) itself land an eligible pull request — a human's own role then
   narrows to whatever the classifier didn't cover, and a human
   `CHANGES_REQUESTED` blocks landing at every level regardless.

And, at the end of a cycle, rarely: the **[Enabler](../../concepts/glossary.md#enabler)** (Opus) re-examines an item
that has been blocked for several cycles, unblocks it if it can and raises an
issue assigned to you if only you can — see
[Blocked items and the Enabler](../operating/diagnose-by-symptom.md#an-item-is-blocked-or-void). It also writes
the specification for an item too vague to select, which is otherwise skipped
in silence forever — see
[Items nobody has specified](../operating/diagnose-by-symptom.md#an-item-is-blocked-or-void).

At the same end of the same cycle, and not rarely at all: the **[Refiner](../../concepts/glossary.md#refiner)**
(Haiku) writes that specification for an item nobody has scoped *before* it has
to be blocked and wait for the Enabler at all — see
[Refined items and the Refiner](../operating/configure.md#work-source-controls).

If no suitable item exists, or if [back-pressure](../../concepts/glossary.md#back-pressure) shows open agent PRs, the cycle stands down — cheaply, without waking the Co-Ordinator, when nothing has changed since it last found nothing to do (see [Skipping no-op cycles](../operating/run-and-pause.md#staying-warm-without-spending)).

Once a day, a third pipeline reads the other two and reports on them: see
[The Pipeline Monitor](../operating/watch.md#the-pipeline-monitor).

## Responding to your review comments

Request changes on an agent PR and the next cycle picks it up: it reads your
review, pushes a fix to the same branch, replies point by point saying what it
changed and what it didn't and why, and re-requests your review. It never opens
a second PR for this, and it never re-does the original work — it amends what's
there.

This sits second in priority, above everything but security: you're the only
consumer this system has, so answering you beats starting something new.

Five things to know:

- **You'll get the PR back in your review queue.** The re-request is the whole
  handoff on a second round — the PR never went back to draft, so nothing else
  would put it in front of you, and your original review request stopped being
  pending the moment you submitted the review. The pipeline asks GitHub whether
  the re-request actually happened and makes it happen if it didn't, the same
  way it verifies the draft flip on a first round; neither is left to a model's
  good intentions. This is what poetic-fiddle #200 was missing: reviewed,
  answered, pushed, replied to — and then sitting in nobody's queue.
- **Your `CHANGES_REQUESTED` blocks landing at every autonomy level.** The
  pipeline never dismisses a human review — that is the structural human
  **veto**, enforced by the Landing Gate regardless of the `merge_autonomy`
  setting, so your `CHANGES_REQUESTED` blocks landing even in a repository the
  Script is otherwise trusted to merge in. Re-requesting your review does not
  clear the block; it rings the bell without moving the gate, which is
  intentional — the mechanism works the same whether the PR was authored by you,
  by the pipeline's own account, or by a dedicated authoring App.
- **Every comment the pipeline posts says so, up top.** Every comment it posts
  opens with a bold label naming which stage wrote it and which node ran it,
  e.g. `**Implementer** · autonomous pipeline · node \`poetic-2\``. A comment
  with no such label is one you, or another human, wrote.
- **It answers each round exactly once.** Whose turn it is comes from comparing
  your latest review against the branch's head commit: review newer means the
  agent owes you a reply; commit newer means it has replied and is waiting on
  you. Request changes again and it comes straight back.
- **Put the substance where it'll be read.** Every review body and inline
  comment in the round is passed to the agent verbatim, whichever account wrote
  it — so a detailed `COMMENTED` review from one account plus a bare
  `CHANGES_REQUESTED` from another works fine. Say which findings block a merge
  and which don't; the agent honours that split.

Only PRs the system is managing are eligible (labelled `autonomous-agent`, on an
`agent/` branch — see [Handing a pull request to the
pipeline](#handing-a-pull-request-to-the-pipeline)). Your own branches are never
touched.

Back-pressure doesn't block this: if every agent PR is sitting on "changes
requested", the cycle restricts itself to review feedback rather than standing
down, so it can always dig itself out. It still can't open a new PR while the
gate is full.

## Staying in front of you

The re-request above covers the round *after* the first — but a first-round PR
and an already-approved one can go quiet too, and neither is a `CHANGES_REQUESTED`
the pipeline knows to answer:

- **Every ready PR keeps a live review request, not just the one CODEOWNERS made
  at the start.** Once your review is submitted — approving or not — that
  request is consumed, and nothing else asks you again. Every cycle, whether or
  not it touches that PR through any other stage, checks and re-asks whoever
  already reviewed it. This is what poetic-fiddle #170 was missing: approved,
  green, and sitting for 6.8 days because nothing ever asked again.
- **An approved, mergeable, green PR idle for `human_nudge_idle_hours` (default
  24) gets one nudge comment**, `@`-mentioning you, once — not repeated, and not
  instead of the live review request above, which keeps working regardless.
  Never fires on a PR you've already enqueued in a GitHub merge queue, where one
  is enabled — that reads the same as one nobody has acted on yet, so this
  checks for the difference rather than telling you to click a button you
  already clicked. If the queue itself dequeues a PR after a checks failure —
  a state GitHub otherwise gives you no way to notice — you get a one-time
  notice comment instead, immediately, not held for the idle threshold above.
- **A GitHub issue the pipeline reports as needing your decision is labelled
  `blocked` and `blocked:needs-refinement`**, not just the ordinary
  `needs-refinement` label — the same pattern that already resolves an Enabler
  escalation in 1–2 hours, extended to the Co-Ordinator's own `needs_refinement`
  reports so a genuinely human-blocked issue never sits invisible the way #203
  briefly did. Assignment stays reserved for an actual Enabler escalation — a
  separate issue you personally need to act on and close — so Assigned-to-me
  never fills up with the pipeline's own bookkeeping.

## Issue priority

An open issue's place in the queue is its **`Priority`** field — GitHub's own
issue field (`Urgent` / `High` / `Medium` / `Low`), set from the issue page's
sidebar, not a label. Setting it is how you move an issue up or down against
every *other* kind of work the pipeline could pick instead:

| Priority | Where the issue is picked up |
|---|---|
| `Urgent` | **Second overall, across all configured repositories** — ahead of everything except security work, including ahead of your review feedback and of finishing a stalled PR. |
| `High` | After a red default branch, but ahead of [tech-debt source](../../concepts/glossary.md#source) (issues labelled `pw::type:tech-debt`). |
| `Medium` | After tech-debt, ahead of the implementation plan and the repository review's recommendations. |
| `Low` | After the review recommendations, ahead of only the automated code-quality findings. |

**An issue with no `Priority` set counts as `Medium`**, which is exactly where
all issues ranked before this existed — so an untriaged backlog behaves as it
always has, and nothing is quietly demoted for want of triage.

Three things the field does *not* do. It doesn't change how the work is done:
an issue's band decides when it is picked up, and a `Low` issue is implemented
and reviewed to the same standard as any other. It doesn't override the
exclusions — an issue that is assigned (see [Reserving an issue for
yourself](#reserving-an-issue-for-yourself)), labelled `blocked`, or is really a
question stays out of the pipeline at every priority, `Urgent` included. And it
doesn't outrank security: an issue labelled `security` or `vulnerability` is
security work first, whatever its `Priority`.

**No band keeps an issue out of the pipeline**, `Low` included: a band decides
*when* an issue is reached, never *whether*. To reserve one, assign it — see
below.

Re-prioritising an issue is picked up on the next cycle: the band is part of
what the no-op check watches (see [Skipping no-op cycles](../operating/run-and-pause.md#staying-warm-without-spending)),
so a re-triage always wakes the Co-Ordinator rather than being absorbed by a
"nothing changed" skip.

## Reserving an issue for yourself

**Assign an issue and the pipeline will not touch it.** Assignment is the
reservation switch, and it is a hard one: `scripts/gather-issues.sh` drops every
issue that has an assignee before the Co-Ordinator is handed the candidate list,
so a reserved issue is never ranked, never skipped, never reasoned about — it
simply isn't there to consider. Unassign it and the next cycle has it back.

Reach for this when an issue is work you mean to do yourself, in an interactive
session, or that you want to think about before anything starts implementing it.
It is the counterpart of [Handing a pull request to the
pipeline](#handing-a-pull-request-to-the-pipeline): one hands work over, the
other keeps it.

```bash
gh issue edit <n> -R <owner>/<repo> --add-assignee @me      # reserve
gh issue edit <n> -R <owner>/<repo> --remove-assignee @me   # release
```

Three things to know:

- **`Priority: Low` is not a reservation.** `issues:low` is a source in every
  repo's walk, so a cycle with nothing above it to do will reach a `Low` issue
  and select it. Use the band to say how urgent the work is; use assignment to
  say who is doing it.
- **The `blocked` label does the same job, but says something else.** It is the
  same deterministic drop, applied in the same place, and it is the right switch
  when real work is genuinely waiting on something outside itself. An issue you
  have simply claimed is not blocked, and labelling it so tells the next person
  reading the queue the wrong thing.
- **It's the guarantee the Enabler already leans on.** Every escalation issue the
  Enabler raises is assigned to `enabler_assignee`, precisely so the pipeline
  cannot pick up its own request for help — the Script refuses to start a cycle
  when `enabler_model` is set and that assignee is not, rather than raise one
  unassigned. Reserving your own issues rests on the same mechanism.

Assignment hides nothing: the issue stays open, keeps its band, and still appears
in the dashboard's open-issues panel, which lists what is open rather than what
is selectable. Releasing one is picked up on the next cycle — the assignee is
part of the fingerprint the no-op check watches, alongside labels and `Priority`
(see [Skipping no-op cycles](../operating/run-and-pause.md#staying-warm-without-spending)) — so unassigning always
wakes the Co-Ordinator rather than being absorbed by a "nothing changed" skip.

## Cross-item dependencies

**`Blocked-by: #195`, on its own line in an issue's body or any comment on
it, holds that issue back until #195 closes.** For a dependency in another
repository the pipeline works, name it in full: `Blocked-by: owner/repo#42`.
Several references can share one line, comma- or space-separated
(`Blocked-by: #1, #2`), and the line can carry a leading `-` if you're
itemising it in a list.

This is the structured alternative to writing "blocked until #195 is
merged" in prose. Prose has to be re-read and re-judged by a model every time
the pipeline reconsiders the issue, and a note describing a moment in time
does not update itself once that moment has passed — four issues in this
project's own history were repeatedly, wrongly re-blocked from a stale prose
note like that, well after the dependency it named had actually merged, each
false block costing a full Enabler engagement to clear. `Blocked-by:` does
not have that failure mode: nothing here ever trusts what the line says
happened, only what re-checking `#195`'s own state says right now, so a line
left in place after `#195` closes is inert rather than wrong — there's
nothing to remember to clean up.

Both directions are code, not a model's judgement, and cost nothing beyond
one `gh` read per reference:

- **Holding.** An issue naming an unresolved `Blocked-by:` reference never
  reaches the Co-Ordinator's candidates at all — the same deterministic drop
  as an assigned or `blocked`-labelled issue (see [Reserving an issue for
  yourself](#reserving-an-issue-for-yourself)).
- **Releasing.** An issue the pipeline has already recorded blocked — for
  this reason or any other — clears automatically, logged `by:
  "dependency-resolved"`, the moment every `Blocked-by:` reference it still
  names is closed. You do not have to touch the issue for this to happen;
  closing (or merging) the referenced item is enough.

You do not have to write the line yourself: if the pipeline's own agents
recognise an item is waiting on another specific, numbered one, they use this
form too, in a comment, so the mechanism above applies to it as well.

## Handing a pull request to the pipeline

The `autonomous-agent` label is what marks a pull request as the pipeline's to
manage. The system adds it to every PR it raises — but you can add it to an open
PR yourself to hand that PR over, and the next cycle will treat it as an available
work item. For example:

- a **ready PR that has hit a merge conflict** is rebased onto `main` and its
  conflict resolved (the `merge-conflicts` source);
- a **draft the system started and then left stalled** is finished
  (`abandoned-drafts`);
- a PR you have **requested changes on** is answered (`review-feedback`).

This is the switch to reach for when a PR the system *didn't* raise — most often
one you created through `/td` or an interactive session — has drifted into
conflict, or whenever you want the fleet to carry an existing PR the rest of the
way. **If you open a pull request yourself and want the pipeline to review and
shepherd it, apply the `autonomous-agent` label at the time you raise it** — the
pipeline does not discover PRs except through its own sources and through this
label, so an unlabelled PR is invisible to it.

Two things to know:

- **It only applies to `agent/` branches** — the ones the system is
  allowed to push to; the implementation cycle raises every PR on
  `agent/<item>`. An interactive session or `/td` that raises its own PR should
  use a branch name starting with `agent/` (e.g. `agent/my-fix`) if you mean
  to hand it to the fleet; a PR on any other branch (e.g. `feature/…`) is
  ignored even when labelled, because the landing gate reserves those branches
  and the gatherers skip them.
- **Labelling grants write access.** A labelled PR is one the fleet may push to —
  including a `--force-with-lease` rebase to clear a conflict — and it counts
  toward the open-PR back-pressure cap. Remove the label to take the PR back.

## Merge autonomy

Every pull request this pipeline raises goes through the same review and
merge machinery; what varies is *who* performs the approve and the merge.
That's `merge_autonomy`, a four-level trust ladder — see [The Landing
Gate](../../IMPLEMENTATION-PIPELINE-SPEC.md#the-landing-gate) for the full
requirements this section summarises:

| Level | Who approves | Who lands | Your residual act |
|---|---|---|---|
| `human` — **the product default** | You | You | Everything — the pipeline never approves or merges anything |
| `agent-approves` | The Approver App | You | The merge (or enqueue) click |
| `agent-merges-routine` | The Approver App | The Script — for a pull request graded within `merge_autonomy_routine_complexity` (`low`/`medium` by default) from a source in `merge_autonomy_routine_sources`, touching no protected path | The click for anything the classifier doesn't cover |
| `agent-merges-all` | The Approver App | The Script — everything `agent-merges-routine` lands, and a pull request touching a protected path too, once it has cleared the critical-tier review and the cool-off below | The click for anything outside `merge_autonomy_routine_complexity` or `merge_autonomy_routine_sources`, and for the three cases below |

The top two rungs differ only in what a protected path (the pipeline's own
gate code, its prompts, its CI) does to a pull request that touches one.
Below `agent-merges-all` it refuses the landing outright, so the change needs
your click. At `agent-merges-all` it lands with no human click, behind two
controls of its own: the Approver reviews it at the critical tier whatever
its complexity grade, and the Script waits `landing_cool_off_hours` (24 by
default) after that approval before arming the landing, restarting the wait
if anything is pushed after the approval.

At either merging level, three more cases need your click whatever their
grade or source. The first is a pull request that the merge queue has ever
removed for any reason other than merging it, because the landing stage
never re-enqueues one. The second is a pull request whose latest round
answered a comment through the `landing-refusals` source, which cannot be
listed in `merge_autonomy_routine_sources`. The third is a pull request
whose source the landing stage cannot read back from the fleet's log.

**The invariants, at every level:**

- **Nothing lands that you have not opted into.** A fresh install ships
  `merge_autonomy: human`, and it stays there — fleet-wide, and for every
  repository — until you deliberately raise it, per repository or across the
  whole installation.
- **You retain ultimate control.** No model ever holds approve or merge
  rights — not the Implementer, not the Reviewer, not even the Approver's own
  prompt, which only judges and never fixes. Only the Script does, under a
  non-author identity, and only once every deterministic gate and an
  independent Approver verdict have passed. A `CHANGES_REQUESTED` review from
  your own account blocks landing at every level, unconditionally: the
  pipeline never dismisses a human review, so raising the level narrows what
  still needs your merge click, never what needs your veto.

**Identity.** Every level above `human` needs a non-author GitHub App to hold
approve rights. The pipeline may author pull requests through the node's own
GitHub credential (the default `human` degrade path) or through a dedicated
authoring App; in both cases, GitHub refuses to let a pull request's author
approve it, so no level of agent approval is possible without a second
identity. This approval App (**"Pullwright Approver"**) needs `pull_requests:
write` and `contents: write`; its installation token — minted and cached for its
~1-hour lifetime by `lib/approver-token.sh` — is what the Script signs its
reviews and merges with. Set the App's id as `approver_app_id`, and its three
cost tiers as `approver_model_default`/`_complex`/`_critical`; leaving
`approver_model_default` empty switches the whole Approver stage off
regardless of `merge_autonomy`, and leaving either of the other two empty falls
that tier back to the one below it.

**What each level needs at the forge**, beyond `config.json`:

- **`agent-approves` and above** — install the App on the repository, with
  `approver_app_id` and `approver_model_default` both set in `config.json`
  ([`scripts/doctor.sh`](../operating/diagnose-by-symptom.md#checking-an-installation) fails the installation
  otherwise); set the three `PULLWRIGHT_APPROVER_*` environment variables the
  token wrapper reads (the App's id, its installation id, and the path to
  its private key), which `doctor.sh` cross-checks against `approver_app_id`
  itself; and turn the default branch ruleset's code-owner review
  requirement *off* — an App cannot satisfy it, and `doctor.sh` fails the
  installation if a ruleset still demands it at `agent-merges-routine` or
  above (it is only ever a recommendation, not a hard requirement, below
  that). A `pull_request` rule requiring at least one approving review is
  recommended so `reviewDecision` reflects the App's review normally, though
  nothing here fails on `0`.
- **`agent-merges-routine` and `agent-merges-all`**, in addition — if the
  repository has no active merge queue on its default branch, both
  `allow_auto_merge` and `allow_squash_merge` must be enabled, and
  `doctor.sh` fails the installation if either is off: the Script's no-queue
  landing fallback (`gh pr merge --auto --squash`) is refused outright
  otherwise. Where a merge queue does exist, landing is enqueueing, and the
  queue's own checks are one more gate a pull request must clear first.

**The kill switch is a permanent operational control, not rollout
scaffolding.** Independent of `merge_autonomy` itself,
`agent-cycle.sh --kill-merge-autonomy "<reason>"` forces every repository's
*effective* level to `human` immediately and fleet-wide, without touching
`config.json` — cycles keep running exactly as they otherwise would, but no
Approver review and no automatic landing happens anywhere until
`agent-cycle.sh --restore-merge-autonomy` clears it. `--status` reports
whether it's set. Reach for it exactly as you would `--disable` (see
[Pausing the pipelines](../operating/run-and-pause.md#the-disableenable-switch)), when what you want stood
down is the landing gate itself rather than the whole pipeline.

