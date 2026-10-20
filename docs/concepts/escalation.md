---
title: Escalation
summary: How a decision the pipeline cannot make reaches the human owner
audience: evaluator
kind: explanation
---

# Escalation

Not every blocked item resolves itself, and not every question is the
pipeline's to answer. This page explains what the Enabler does with a
long-blocked item, how far the `escalation_autonomy` ladder lets it decide
things on the pipeline's own authority, the boundary that ladder can never
widen past, how a genuine escalation reaches the human owner, and the
separate fleet-level pager that watches for conditions no single item
captures.

## The Enabler

The Enabler is a headless Claude Code invocation, engaged rarely and at the
end of a cycle, that re-examines items recorded as blocked which the
pipeline has not cleared by itself — see
[The life of an item](life-of-an-item.md#the-three-ways-out). It reads
through `gh`, may leave one concise decision or evidence comment, and must
never write code, push, create or delete a branch, or touch anything that
is already void. For each item it reaches, it settles on one of: unblocked,
still blocked (a fresher condition recorded), escalate, or void.

Authoritative: `docs/spec/implementation/README.md` § "Actors", item 7
(Enabler); `docs/spec/implementation/requirements/enabler-01.md`,
requirements 35 and 36.

## `decide-tactical` and the escalation autonomy ladder

Before the Script files an escalation issue for an Enabler `escalate`
verdict, `escalation_autonomy` controls whether something intervenes first.
Four rungs, each including the one below it unless stated otherwise:

1. **`always-escalate`** (the default) — no adjudication pass ever runs;
   every `escalate` verdict goes straight to a human.
2. **`adjudicate-first`** — gates only a refinement disagreement (a
   `needs-refinement` item a human has already touched once). One bounded
   pass reaches either `adequate` (recorded as an ordinary unblocked) or
   `inadequate` (escalates as before).
3. **`decide-tactical`** — widens the same pairing to *every* `escalate`
   verdict, not refinement disagreements alone. Before the Script files the
   issue, one bounded pass runs first and may settle the item (recorded as
   an ordinary `unblocked`) or decide a tactical question on the pipeline's
   own authority — one comment plus a `decision-taken` event — instead of
   paging a human at all. It never widens the owner-only boundary below.
4. **`decide-with-veto`** — includes everything `decide-tactical` reaches,
   and widens it in exactly three named reaches: accepting residual risk in
   an owner-held repository where no credential, secret, App, ruleset, or
   account is touched; corroborating a void for three specific pull-request
   shapes requirement 34k already closes (an abandoned one, a superseded
   one, and a review-feedback one); and relocating a misfiled item into the
   pipeline's own repository. A decision that carries an *act* under this
   rung waits out a veto window before the act is taken, so a human can
   reopen the decision's own log issue to stop it first.

Authoritative: `docs/spec/implementation/requirements/enabler-01.md`,
requirements 36a, 36b, 36d; `docs/spec/implementation/requirements/enabler-02.md`,
requirement 36f; `config.schema.json`, key `escalation_autonomy`.

## Owner decisions and the owner-only boundary

No rung of that ladder ever reaches past one fixed boundary, written once
and only ever referenced elsewhere, never restated: `escalate` is required
whenever a decision spends money or changes a cap, budget, model tier, or
node count; touches credentials, secrets, GitHub Apps, rulesets,
permissions, or organisation or account settings; touches licence, revenue,
pricing, or any go-to-market matter; adds, amends, or renames a roadmap
decision, a phase gate, or a roadmap item; creates an ongoing human
obligation; moves a trust boundary of the pipeline itself (`merge_autonomy`,
`escalation_autonomy`, a protected path, a kill switch, the Approver's own
identity); depends on an
external service or account the pipeline does not hold; needs information
that exists only in someone's head; or was explicitly reserved by the
item's own author — through the `pw::owner-decision` label or an "Owner
decision: yes" line, never through prose alone.

Authoritative: `docs/spec/implementation/requirements/enabler-01.md`,
requirement 36a, "The owner-only boundary".

## How escalation reaches the owner

Escalation is a GitHub issue — filed by the Script, never the model, under
a duplicate guard that reuses an open escalation already quoting the same
item rather than filing a second one — carrying a fixed label and assigned
to a configured human (`enabler_assignee`). Closure is the whole protocol,
and the issue body says so: the human does the thing the issue describes
and closes the issue. Nothing else is required of them, and this is also
what guarantees the escalation surfaces on that person's own "Assigned to
me" view rather than depending on them to go looking for it.

Authoritative: `docs/spec/implementation/requirements/enabler-01.md`,
requirement 36a, "The issue contract"; `docs/spec/implementation/requirements/enabler-02.md`,
requirement 38 ("Human-visibility"); `docs/concepts/glossary.md`, entries
"Escalation" and "Page".

## The pager

Separately from any single item, a fleet-level invariant check watches
facts already replicated to every node — the union log, every peer's
heartbeat, a node's own health check — for conditions no one blocked item
would surface on its own. A candidate must hold for a hysteresis window
before it fires; once fired, it is handled by one of three remedy classes:
an automatic fix the pipeline runs itself, a decision filed as a tactical
record (inheriting the same veto window as `decide-with-veto` above), or an
owner-only issue assigned exactly like an ordinary escalation. Where
`notify_webhook_url` is configured, a firing (or clearing) pager posts
there directly, independent of whether anyone is reading the issue tracker
at that moment. `pager_enabled` is the master switch, and it gates
evaluation outright — set false and the checks themselves stop running,
dashboard included; leaving `pager_repo` empty, by contrast, still lets
every check evaluate and reach the dashboard, only with nowhere to file an
issue when one fires.

Authoritative: `docs/spec/implementation/requirements/approver-02.md`
§ "Fleet-level invariants (the pager)", requirement 51; `config.schema.json`,
keys `pager_enabled`, `pager_repo`, and `notify_webhook_url`.

## Related pages

- [The life of an item](life-of-an-item.md) — how an item becomes blocked
  in the first place
- [The Landing Gate and merge autonomy](landing-gate.md) — the trust ladder
  escalation's own boundary is one of the things that can never move
  without the owner
- [The security model](security-model.md) — the credentials and identities
  the owner-only boundary exists to keep out of an agent's reach
- [Glossary](glossary.md) — every coined term, defined once
