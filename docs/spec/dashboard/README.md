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

