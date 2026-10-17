# Monitoring Dashboard — as-built specification

Companion to `docs/spec/implementation/README.md` (the pipeline spec). This document
describes the local monitoring dashboard **as built**: what it is, the state
it reads, how it is assembled, and the decisions behind it. Use it to
understand, modify, or regenerate the dashboard — and keep it accurate: any
change to the dashboard lands together with the edit that keeps this
document describing what actually exists (see `AGENTS.md`, "As-built
specifications"). Where it says "requirement N", it means requirement N of
`docs/spec/implementation/README.md`.

Split from a single file by #2094 so every part is within the 100,000-byte documentation size budget (`docs/README.md` "Size budget").

<!-- toc:start -->
- [Components (as built)](components.md)
- [Design decisions](design-decisions.md)
- [Integration](integration.md)
- [The Publisher (`scripts/publish-dashboard.sh`)](publisher.md)
- [The Site (`dashboard/index.html`)](site.md)
- [State it reads (verified 2026-07-14)](state.md)
- [Verifying a change](verifying-a-change.md)
<!-- toc:end -->

## What it is

A single-page dashboard for watching and debugging the autonomous agent
pipeline: current status, usage-limit stand-downs, open agent PRs and their
CI, recent cycles with per-stage cost/duration/model, failures, blocked and
void items, the work sources the Co-Ordinator sees, spend by day, by model and
by actor, which version each node is running, the raw log, and each stage's
transcript inline.

Three properties are deliberate and non-negotiable:

- **Local and private.** Nothing is published anywhere. The site is generated
  onto local disk and opened in a browser. There is no server and nothing
  listening on a network address (an optional loopback-only server exists
  purely as a `file://` fallback), and no GitHub Pages. The pipeline's
  operational telemetry — costs, cadence, failure detail, agent reasoning —
  never leaves the machine except, when the optional tailnet access documented
  in the README is installed, to the owner's own signed-in devices:
  `tailscale serve` proxies the unchanged loopback server over the owner's
  private tailnet, and nothing ever gets a public URL.
- **Free to run.** The generator is `bash` + `jq` + `gh` on the existing cron
  cadence; the page is a static file; there are **no model calls anywhere**.
- **A reader, never a participant.** It only reads the pipeline's state and
  GitHub. It never writes into the state tree, never touches the lock, and
  cannot slow or disturb a running cycle. It redacts home paths and
  token-shaped strings so a screenshot is safe to share.

## What a badge means

An index from a dashboard badge — or a background risk with no badge at
all — straight to its fuller explanation, for an operator who sees
something wrong and does not yet know which file explains it. Each entry
links out to the existing fuller paragraph and to the `lib/*.sh` header
comment that is the design-rationale source; neither is repeated here.

- **N stage(s) failing** (the Stage health panel, agent-ops#662) — a
  stage's most recent run of attempts is failing on this node. What to do:
  read the named stage's own consecutive-failure count and last-attempt
  detail on the panel (or its transcript inline) and fix the cause; the
  badge clears itself once that stage next succeeds. See [The Doctor and
  stage-health panels](site.md#the-doctor-and-stage-health-panels) and
  [`lib/stage-health.sh`](../../../lib/stage-health.sh)'s own header
  comment (the 2026-08-21 all-stages-failing incident this badge exists to
  catch).
- **updater deferring** / **updater stuck** (agent-ops#603) — grey
  "deferring" is informational only: a roll is waiting on a cycle or
  review in flight, and resolves on its own once that ends. Amber "stuck"
  needs a human: the retry it is waiting on repeats the very collision
  that stuck it, so it will not clear by itself — recreate or restart the
  named container. See the "updater deferring"/"updater stuck" bullet in
  [Design decisions](design-decisions.md) and
  [`lib/updater-health.sh`](../../../lib/updater-health.sh)'s own header
  comment (the 2026-08-14 watchtower container-hostname collision this
  badge exists to catch).
- Orphaned-workspace disk fill (agent-ops#605) — background risk, not a
  dashboard badge: a cycle killed by the machine (an out-of-memory kill, a
  host freeze, a container recreate mid-stage) leaves its scratch clone
  under `workspace_root` forever, invisible until the volume fills. What to
  do: nothing from the dashboard — there is no badge for this to watch; see
  [`lib/workspace.sh`](../../../lib/workspace.sh)'s own header comment for
  the reaper that reclaims it on its own schedule.

## Architecture

```
pipeline state (this machine)            GitHub (public repos, via gh)
  ~/.local/state/poetic-agents/            open agent PRs + checks, failed runs,
    log.jsonl, cycles/<id>/*.out,          issues, tech-debt, and security /
    lock.json, cron.log                    code-quality findings (via
                                           scripts/gather-findings.sh)
        │                                        │
        └────────────┬───────────────────────────┘
                     ▼
        scripts/publish-dashboard.sh   (the Publisher)
          → <state_dir>/dashboard/data.js   (redacted JSON, generated)
          → <state_dir>/dashboard/stamp.js  ({generated_at, fingerprint})
          → <state_dir>/dashboard/index.html (copied from repo)
                     │
                     ▼
        open index.html in a browser  (file://, no server)

Refresh triggers:  end-of-cycle hook in agent-cycle.sh
                +  */5 cron → publish-dashboard-launcher.sh (sub-minute ticks)
```

The page (`dashboard/index.html`, the source of truth, committed) loads its
siblings `data.js` and `stamp.js` with plain `<script src>` tags — which work
from a `file://` URL with no server. The Publisher rewrites both and copies
the page next to them each run. Opening the page needs nothing else.

