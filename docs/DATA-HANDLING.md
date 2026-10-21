# Data handling

This document describes what data the agent-ops pipeline reads, stores, and retains.

## What the pipeline reads

The pipeline reads only public GitHub data for the configured repositories:

- **GitHub usernames** — issue/PR/comment/review authors
- **Issue and pull-request text** — bodies, comments, review text
- **Repository metadata** — branch names, tag names, collaborator access levels
- **Workflow and check information** — CI run results and logs, commit statuses

All of this data is already public on GitHub for public repositories. The pipeline
makes no attempts to read or use private repository data.

## What a stage sends to its model provider

Every stage's own prompt — a work order, an issue body, review content, and
whatever the stage itself reads and writes during its run — is sent to
whichever model provider the stage's configured model resolves to:
Anthropic's own API for a Claude Code stage, or xAI's for a Grok Build one
(`providers`, [docs/reference/configuration.md](reference/configuration.md)).
Neither sends this content anywhere else on the installation's behalf.

A node authenticating the xAI provider's subscription credential path
(issue #2139, `docker compose exec scheduler grok login --device-auth`)
contacts `auth.x.ai` to complete the device-code login; the subscriber
completes the sign-in itself, in their own browser, on `accounts.x.ai`,
which the node never reaches, and nothing beyond that login exchange is
sent to `auth.x.ai`. Where a subscription-authenticated stage's own model
traffic lands — `api.x.ai`, as the API-key path uses, or
`cli-chat-proxy.grok.com`, which Grok Build's model catalogue names for
this path — is not yet confirmed against the egress fence (no live
subscription was available to test it; tracked as tech debt in #2330), so
this domain is not yet on `deploy/docker/egress-allowlist.txt` and a stage
on this path may need it added once that is confirmed.

A Grok Build stage sends one thing beyond the stage's own prompt: xAI's own
CLI also sends the head of that same prompt, truncated, to a second xAI
model (`grok-4.6`) to generate a session title, on every run, with no switch
that turns it off. The same xAI account receives it either way, so no new
party sees any data because of this — but its cost is not in the envelope
the pipeline reads (`docs/reference/metering-schema.md`), so a Grok Build stage's
recorded cost understates what the run actually spent by a few thousand
input tokens on that second model.

## What the pipeline stores and where

The pipeline stores operational telemetry under the configured `state_dir` directory
and its optional replicated mirror (configured separately). This telemetry includes:

- **Cycle logs** — per-cycle JSON event streams (one event per line) recording
  selections, stage handoffs, work item completions, and outcomes
- **Dashboard data** — aggregated metrics for the monitoring dashboard: cost by
  model, cost by actor, cost by day, stage durations, failure counts
- **Cycle transcripts** — per-stage text output and error logs for debugging

None of this data is published outside the installation, with three exceptions, each
optional and off by default:

- **`state_repo`** — when set, `scripts/state-sync.sh` pushes this node's own
  `state_dir` to a branch of a private GitHub repository the installation itself
  creates and controls, and fetches every peer node's branch back the same way, so a
  multi-node fleet can read a union of its own state. Empty (the default) makes every
  mode of that script a no-op.
- **`notify_webhook_url`** — when set, `lib/notify.sh` POSTs one compact JSON body
  per escalation issue filed or auto-closed, per pager fired or cleared, and per
  fleet-wide stand-down beginning or ending, to this URL. Empty (the default)
  disables the channel: nothing is attempted.
- **Tailscale integration** — if `tailscale serve` is enabled, the dashboard (and its
  underlying data files) are made available over the owner's private tailnet to
  their own signed-in devices; nothing reaches a public or third-party URL.

Beyond those three, the pipeline's own outbound calls are the domains
`deploy/docker/egress-allowlist.txt` names, which is the authoritative list — every
entry there carries its reason, and on a containerized node the egress fence refuses
everything the file does not name:

- **GitHub** (`github.com`, `api.github.com`, `codeload.github.com`,
  `.githubusercontent.com`) — every `gh` call, clone and push a cycle makes.
- **The model providers** (`api.anthropic.com`, `platform.claude.com`, `claude.ai`,
  `claude.com`, `api.x.ai`, `auth.x.ai`) — each stage's own prompt, as the
  "What a stage sends to its model provider" section above describes.
- **Vercel** (`api.vercel.com`, `.vercel.app`, `vercel.com`) — only for a target
  repository configured with a `vercel` preview provider: `scripts/preview-deploy.sh`
  reads the pull request's own preview deployment and fetches the routes a stage
  names. It sends the branch's deployment identifier and a bypass header, not
  repository content.
- **`ghcr.io`** — `lib/image-drift.sh` reads the fleet's own image digest from the
  registry, every few minutes. A read; nothing is sent but the manifest request.
- **The target repositories' own toolchains** (`registry.npmjs.org`,
  `fonts.googleapis.com`, `fonts.gstatic.com`) — reached by a stage running a
  target repository's build, not by the pipeline itself.

A node's operator may widen the set for that one node with `EGRESS_EXTRA_ALLOW` in its
own `.env`; fleet-wide additions land in the file itself and ship with the image.

## Data retention

Data retention is governed by four configuration keys in `config.json`, documented
in [docs/reference/configuration.md](reference/configuration.md):

- **`cycles_retained`** — the number of recent complete cycles to retain in full
  (their logs and transcripts). Older cycles' logs are deleted. This does not affect
  cycle metadata (counts, costs, outcomes) used by the dashboard.

- **`state_local_cycles_retained`** — the number of recent cycles to retain in the
  optional replicated state copy (in addition to the primary state directory). When
  the replication mirror reaches this count, the oldest cycle's data is deleted from
  it, matching the age of data in the primary directory.

- **`log_retained_bytes`** — the size at which `scripts/rotate-logs.sh` rotates each
  of the diagnostic and cron logs it owns: `dashboard.log`, `state-sync.log`,
  `doctor.log`, `revert-rate.log`, `tech-debt-archive.log`, `wake-poll.log`,
  `cron.log`, `review-cron.log`, `monitor-cron.log` and `gh-shim/ledger.ndjson`.
  Rotation is a rename, not a trim: the live file becomes `<name>.1`, each existing
  generation shifts down one, the oldest is deleted, and a fresh empty file takes the
  original name. The pipeline's own event logs — `log.jsonl`, `review-log.jsonl`,
  `monitor-log.jsonl` and `revert-rate.jsonl` — are never rotated, regardless of
  size, because the fleet's union readers scan each one whole and dropping its head
  would change what the pipeline believes has already been tried.

- **`log_generations`** — how many rotated generations of each of those logs are kept
  beside the live file (`<name>.1` … `<name>.<log_generations>`). The disk a rotated
  log can occupy is therefore `log_retained_bytes × (log_generations + 1)`, not
  `log_retained_bytes`.

Refer to [docs/reference/configuration.md](reference/configuration.md) for the default
values and detailed explanations of each setting.

## Privacy and security considerations

- **Minimal scope.** The pipeline reads only the data it needs to select and track
  work. It does not fetch the whole repository tree or scan history beyond what
  the work selection process requires.
- **Local retention.** All data stays on disk locally; no telemetry or usage
  information is sent anywhere by default. The dashboard and logs are never
  uploaded or shared unless deliberately pushed to an external service by the
  operator (e.g., via `git` or a manual copy).
- **Redaction for screenshots.** The dashboard includes redaction logic to obscure
  home paths and token-shaped strings when saving a screenshot, so operational
  data can be safely shared for debugging without leaking credentials.

## Onboarding a new installation

Before deploying this pipeline to an installation that is not Poetic-Poems:

1. Review this document and [docs/reference/configuration.md](reference/configuration.md)
   to understand what data will be retained and for how long.
2. Adjust `cycles_retained`, `state_local_cycles_retained`, `log_retained_bytes` and
   `log_generations` in `config.json` to match your retention and privacy
   requirements.
3. Ensure the machine running the pipeline has adequate disk space for the maximum
   configured retention period (see `log_retained_bytes` × `log_generations` in
   particular).
4. If using a replication mirror, ensure the mirror location is on a trusted device
   with the same security properties as the primary state directory.
