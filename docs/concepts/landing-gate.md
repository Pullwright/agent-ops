---
title: The Landing Gate and merge autonomy
summary: Who approves and lands a pull request, and what always stops one
audience: evaluator
kind: explanation
---

# The Landing Gate and merge autonomy

Every pull request this pipeline raises passes through the Landing Gate
before it can merge onto a repository's protected default branch. This page
explains the trust ladder that decides who approves and who lands it, the
limits that bound how much can land, and what always stops a landing
regardless of the ladder's level. For how a pull request gets here, see
[The life of an item](life-of-an-item.md); for the two GitHub App identities
the ladder depends on, see [The security model](security-model.md#credentials-and-the-two-github-app-identities).

## The merge autonomy levels

`merge_autonomy` is an opt-in trust ladder, set per installation and per
repository; the product default is `human`, and nothing a customer has not
opted into ever lands a pull request without a person.

- **`human`** — today's behaviour, unchanged: a human approves and a human
  merges, on every pull request.
- **`agent-approves`** — the Approver stage gives an independent second
  read, under the non-author "Pullwright Approver" GitHub App identity, and
  posts a real `APPROVE` or `REQUEST_CHANGES` review. A human still merges;
  the App's review is additional, not a replacement for a human's own.
- **`agent-merges-routine`** — reviewed identically to `agent-approves`.
  Once the Approver's own review reaches an explicit, non-adjudicating
  `APPROVE`, the arming step re-reads every gate fresh and, if every one
  clears, lands the pull request itself — enqueued where the base branch
  has an active merge queue, or merged directly where it does not — under
  the Approver App's own token, never the pipeline's authoring identity.
  Eligibility is restricted to a pull request whose complexity grade is
  low or medium (`merge_autonomy_routine_complexity`), whose work order's
  source is on an allowed list (`merge_autonomy_routine_sources`, `tech-debt`
  only by default), and which touches no protected path (below).
- **`agent-merges-all`** — lands exactly what `agent-merges-routine` lands,
  plus the one class that level refuses outright: a pull request touching a
  protected path. That class is not eligible by default here either — it is
  deferred to a stricter Critical Approver tier and the cool-off wait,
  below.

Authoritative: `docs/spec/implementation/landing-gate.md` § "The Landing
Gate"; `docs/ROADMAP.md` § "Settled decisions", decision D18 ("Merge
autonomy").

A human `CHANGES_REQUESTED` review from your own account blocks landing at
every one of these levels, unconditionally — see "What always stops a
landing" below.

## Protected paths

`merge_autonomy_protected_paths` names the whole-path prefixes a routine
landing must touch none of. The default, this repository's own nine:
`.github/*`, `deploy/*`, `prompts/*`, `lib/*`, `config.schema.json`,
`config.json`, `agent-cycle.sh`, `review-cycle.sh`, and `CODEOWNERS` — the
paths that govern the pipeline's own behaviour, so that a pull request
cannot land a change to the gate it is riding through on the same routine
terms as anything else. An entry ending `/*` matches as a whole-path
prefix; any other entry matches only that exact path. A repository's own
override replaces this default for that repository alone.

Below `agent-merges-all`, a hit refuses the landing outright — it is simply
not eligible, whatever its complexity or source. At `agent-merges-all`, a
hit is not refused; it is deferred to the compensating controls below.

Authoritative: `docs/spec/implementation/landing-gate.md` § "The Landing
Gate"; `config.schema.json`, key `merge_autonomy_protected_paths`.

## The cool-off

`landing_cool_off_hours` (default 24) is a wait that applies only at
`agent-merges-all`, and only to a pull request that hit a protected path.
It is measured from the Approver's own standing `APPROVE` of that pull
request to the moment the arming step would land it, and only against a
review whose own recorded commit still matches the pull request's current
head — a push after approval restarts the wait from zero.

Authoritative: `docs/spec/implementation/landing-gate.md` § "The Landing
Gate".

## The merge budget

`merge_budget_per_day` (default 8) caps how many pull requests this
pipeline may land in one repository within a rolling 24 hours, enforced at
the arming step itself rather than left to however often a human happens to
click merge. Reaching the cap still lets a pull request through ordinary
review, but its landing does not arm — the backlog queues visibly rather
than merging past the cap. Above `human` but below `agent-merges-routine`,
no budget applies at all: the only thing bounding how fast pull requests
merge there is a human's own click. A counting anomaly — more landed in a
window than the cap should ever have allowed — freezes the repository's
effective level at `agent-approves` until a human clears it, regardless of
what is configured.

Authoritative: `docs/spec/implementation/landing-gate.md` § "The Landing
Gate"; `docs/spec/implementation/requirements/the-script-03.md`,
requirement 2.3c.

## Back-pressure

Separately from how fast pull requests land, `max_open_agent_prs` (default
8) bounds how many are open for this pipeline's own attention at once:
counting draft pull requests, `CHANGES_REQUESTED` pull requests, and live
claims across the repositories a fleet works. At the cap, a cycle starts no
new work and only finishes what is already open — the same limit that
narrows the Co-Ordinator's candidates described in
[The life of an item](life-of-an-item.md#selection).

Authoritative: `docs/concepts/glossary.md`, entry "Back-pressure"
(`docs/spec/implementation/requirements`, requirement 2, step 2).

## What always stops a landing

Three controls hold regardless of the configured `merge_autonomy` level:

- **A human `CHANGES_REQUESTED` review from your own account blocks
  landing at every level, unconditionally.** The pipeline never dismisses a
  human review; nothing about the ladder above relaxes this.
  Authoritative: `docs/guides/working-with-pullwright/README.md` § "Merge
  autonomy".
- **`--kill-merge-autonomy "<reason>"`** forces every repository's
  *effective* level to `human`, fleet-wide, immediately, without editing
  `config.json` — only approval and landing stop; cycles keep running
  exactly as before. `--restore-merge-autonomy` clears it, and `--status`
  reports whether it is set.
  Authoritative: `docs/spec/implementation/requirements/the-script-03.md`,
  requirement 2.3b; `docs/spec/implementation/configuration.md` § "Extended
  notes: `merge_autonomy`".
- **`--disable`** stands the whole fleet down — new intake as well as
  landing — which is a wider stop than the kill switch above, which leaves
  cycles running and only stops approval and landing.
  Authoritative: `docs/guides/operating/run-and-pause.md` § "The
  disable/enable switch".

## Related pages

- [The life of an item](life-of-an-item.md) — the path a pull request takes
  to reach the Landing Gate
- [The security model](security-model.md) — the two GitHub App identities
  and why self-approval is structurally impossible
- [Escalation](escalation.md) — how the owner-only boundary interacts with
  trust levels this pipeline holds
- [Glossary](glossary.md) — every coined term, defined once
