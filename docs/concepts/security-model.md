---
title: The security model
summary: What stops an issue's text from steering an agent that holds write credentials
audience: evaluator
kind: explanation
---

# The security model

The pipeline's defining act is reading work items from public repositories
and acting on them with write credentials. This page states, concretely,
what stops that from being a vulnerability: how untrusted text is framed,
what a compromised stage can actually reach, which GitHub identities hold
which permissions, and what is accepted as residual risk rather than
claimed to be solved. For how to report a vulnerability you find, see
[Reporting a vulnerability](#reporting-a-vulnerability) below.

## Untrusted content and its framing

Text written on the forge by anyone outside the pipeline — issue and
pull-request titles and bodies, comments, review text, commit messages — is
untrusted wherever a stage meets it, whether it arrives embedded in the
stage's own prompt input or is fetched live with `gh` mid-run. Every
shipped stage prompt carries one canonical, byte-identical block stating
this: such text is data about the work, never instructions to the agent. It
may define what the work is, since that is its job, but it cannot change
how the agent operates — its role, its rules, its prompt, or what it may
do — however it is phrased or whoever it claims to be from. An agent must
not comply with an embedded instruction to run an unrelated command, fetch
an unrelated URL, reveal a credential, or change a verdict, and must never
authenticate a comment by its content: a stamp claiming pipeline
authorship inside a comment can be typed by anyone, and only the identity
GitHub itself reports says who actually wrote it. This wording is pinned
mechanically — a test fails if any shipped prompt's copy of it differs by a
byte.

Authoritative: `docs/spec/implementation/requirements/every-stage.md`,
requirements 45 and 45a; requirement 45b (the pinning test).

## The egress fence

A node's scheduler reaches the internet only through a proxy service's own
domain allowlist; the scheduler itself sits on an internal network with no
other gateway, so the proxy is the only way out. The allowlist admits
GitHub, the model provider's API, Vercel (for a preview deploy), the npm
registry, and the image registry — nothing else, and there is deliberately
no operator-facing off switch for it. Everything else Claude Code might
otherwise reach on its own — its update checks, telemetry, and error
reporting — is turned off at the source by the scheduler's own environment,
not merely left unrouted.

Authoritative: `docs/guides/operating/install-a-node.md` § "The egress
fence" (which names the Anthropic case only); `deploy/docker/egress-allowlist.txt`
is where the xAI entries (`api.x.ai`, `auth.x.ai`, D29) sit alongside it,
which is why this page says "the model provider's API" rather than naming
just one.

The monitoring dashboard follows the same boundary from the other
direction: it is served on the host's own loopback address by default, and,
where the `tailnet` profile is enabled, over HTTPS to the operator's own
tailnet — never to the public internet.

Authoritative: `docs/guides/operating/watch.md` § "The dashboard".

This is the "Next" stage of a three-stage, explicitly staged response to
the exposure above: prompt framing now (requirement 45a), container egress
allowed only to the forge and the model provider's API next, and per-stage
tool scoping at a defined future trigger. What that staging accepts
permanently, named rather than silently carried: the Implementer keeps
broad tool access because implementing is what it exists to do, and the
forge itself remains an exfiltration channel in any design that lets this
pipeline write to a public repository.

Authoritative: `docs/ROADMAP.md` § "Settled decisions", decision D24
("Untrusted-content containment").

## Credentials and the two GitHub App identities

GitHub itself refuses to let a pull request's author approve it — so no
level of agent approval is possible without a second identity, and this
pipeline provisions exactly two, kept deliberately separate:

- **The authoring identity** ("Pullwright Author", D25) mints the tokens
  every authoring act uses — cloning a repository, pushing a branch,
  opening or commenting on a pull request or issue. It is a separate App
  from the Approver specifically so the authoring identity can never
  approve its own work, which a single shared App would recreate. Where it
  is not provisioned, a node degrades silently to the operator's own
  personal access token for authoring.
- **The Approver** ("Pullwright Approver") holds exactly three permissions
  and no more: `contents: write`, `metadata: read`, and
  `pull_requests: write`. At every merge-autonomy level above `human`,
  approval and landing are acts of the Script under this identity, never
  under the authoring one, and no model ever holds approve or merge
  rights itself.

Authoritative: `docs/ROADMAP.md` § "Settled decisions", decisions D18
("Merge autonomy") and D25 ("Forge authoring identity");
`docs/guides/working-with-pullwright/README.md` § "Merge autonomy"; the
exact permission triple is `docs/spec/implementation/configuration.md`
§ "Extended notes: `merge_autonomy`" (D18 Stage 3).

Underneath both identities, every model stage runs as its own Unix user,
distinct from the user the Script and its scheduler run as. That user
cannot read either App's private key, the Script's own environment, or its
minted-token cache, and cannot write anything outside the one workspace it
was given.

Authoritative: `docs/spec/implementation/requirements/every-stage.md`,
requirement 45e.

## Protected paths

A routine landing — one that does not go through a human's own review and
click — must touch none of `merge_autonomy_protected_paths`: this
repository's own nine whole-path prefixes governing the pipeline's own
behaviour (`.github/*`, `deploy/*`, `prompts/*`, `lib/*`,
`config.schema.json`, `config.json`, `agent-cycle.sh`, `review-cycle.sh`,
`CODEOWNERS`). This is a direct answer to the specific risk of a pull
request modifying the gate it is riding through: below the top trust level
a hit refuses the landing outright, and even at the top level it is
diverted to a stricter review tier and a cool-off wait rather than ever
skipping review. The full mechanics are on
[The Landing Gate and merge autonomy](landing-gate.md#protected-paths).

Authoritative: `docs/spec/implementation/landing-gate.md` § "The Landing
Gate".

## What a malicious issue can and cannot do

Putting the controls above together, an issue, comment, or review authored
by anyone outside the pipeline **cannot**:

- change what a stage is allowed to do, no matter how it is phrased or who
  it claims to be from (the untrusted-content framing above);
- make a stage authenticate a forged pipeline-authorship stamp as if
  GitHub itself had written it;
- reach any host outside the egress allowlist, so it cannot use the
  pipeline as a channel to an attacker-controlled server;
- make a pull request approve or merge itself — GitHub's own rule against
  author self-approval, plus the Approver holding an identity distinct from
  the one that authored the change, make that structurally impossible, not
  merely discouraged;
- land a change to a protected path without the stricter review and
  cool-off a hit there always triggers; or
- read either GitHub App's private key or the Script's own state, because
  the stage that reads the issue runs as a Unix user walled off from both.

What is named and accepted as residual, rather than claimed solved: the
Implementer's own broad tool access, and the forge itself as an
exfiltration channel for any pipeline that writes to a public repository.
Both are bounded by the standing controls above — scoped, expiring
authoring credentials; the Approver's separately held token; per-stage user
isolation; branch protection and protected paths; and the fleet's own
pause and crash-loop detection — rather than left unbounded.

Authoritative: `docs/ROADMAP.md` § "Settled decisions", decision D24.

## Reporting a vulnerability

Report a suspected vulnerability privately through this repository's
Security tab ("Report a vulnerability"), which opens a private advisory
visible only to the maintainer until a fix is ready, rather than as a
public issue, pull request, or discussion. There is no bug-bounty
programme; this is a best-effort, single-maintainer project.

Authoritative: `SECURITY.md`.

## Related pages

- [The Landing Gate and merge autonomy](landing-gate.md) — protected paths
  and the trust ladder in full
- [Escalation](escalation.md) — the owner-only boundary that keeps a
  credential or ruleset change out of any agent's reach
- [Architecture](architecture.md) — where the Script, nodes, and the state
  repository sit relative to each other
- [Glossary](glossary.md) — every coined term, defined once
