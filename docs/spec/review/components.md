## Components

What exists, and the requirements each part answers to:

1. <a id="rev-c-1"></a>`review-cycle.sh` implementing R1–R8, R16 and R19 (including the role guard,
   R2b, through `lib/role.sh`, the union snapshot and state push of R2c, through
   `scripts/state-sync.sh`, the per-repository instructions and context of
   R1c and R5 step 2a through `lib/review-context.sh`, shared with
   `scripts/doctor.sh` so the cycle's own refusal and doctor's `fail` read
   one implementation, the metering record on `review-stage-end`
   through `lib/metering.sh`, shared with `agent-cycle.sh` — see
   `docs/reference/metering-schema.md` — and R19's own stage-health verdict through
   `lib/stage-health.sh`, shared with `agent-cycle.sh`/`monitor-cycle.sh`).
   `shellcheck`-clean; sets its own `PATH`.
2. <a id="rev-c-2"></a>`prompts/project-reviewer.md` implementing R9–R15. It must embed the
   relevant shared-repo conventions (as the other operating prompts do) so the
   stage never depends on context it was not given.
3. <a id="rev-c-3"></a>`.claude/skills/project-review/` — the vendored skill (pinned; re-sync
   from upstream deliberately).
4. <a id="rev-c-4"></a>`config.json` — the `repository_review` block.
5. <a id="rev-c-5"></a>`docs/guides/operating/README.md` names the review pipeline under "How
   the pipelines work"; `docs/guides/operating/change-a-node.md` § "Uninstall"
   covers how to uninstall; and `docs/reference/configuration.md` documents
   every `repository_review.*` config key.
6. <a id="rev-c-6"></a>The crontab line(s): on a containerized node, rendered from `deploy/docker/crontab.tmpl` and run by supercronic in the scheduler service.

