## Acceptance checks

Every change to this pipeline must leave all of these passing; before opening
a pull request, run the ones the change touches and any it could regress.

The implementation pipeline's *Acceptance checks* preamble carries one rule
that applies here unchanged: **no check may expect a particular value from
`config.json`.** The shipped file is asserted to be valid; every fixture
supplies its own `repository_review` block, or mutates
`test/fixtures/config-base.json`. Changing a threshold, a cadence or a
reviewed repository is a configuration change, and must not oblige anyone to
edit a test.

1. <a id="rev-ac-1"></a>`shellcheck review-cycle.sh` is clean.
2. <a id="rev-ac-2"></a>`--dry-run` completes against the real repos: the stand-down and skip-guard
   checks are evaluated, the Script prints which repos it *would* review,
   nothing further launches, and `review-log.jsonl` records the run.
3. <a id="rev-ac-3"></a>A second invocation while the review lock is held exits without acting; and
   while the implementation `lock.json` is held by a live process, the Review
   Script stands down.
4. <a id="rev-ac-4"></a>Skip-guard: with today's report directory present on a repo's default
   branch — `reviews/project-review-<today>/` under the shipped fallback, or
   whatever that repo's own resolved `report_directory` names (R4a) — (or an
   open `project-review`-labelled PR for it), that repo is skipped, and the
   `min_days_between_reviews` boundary is respected.
4b. <a id="rev-ac-4b"></a>**The role guard stands this pipeline down too (R2b).** `test/role.test.sh`
   passes: a `review-cycle.sh` with `AGENT_OPS_ROLE` unset or standby exits 0
   with one line and writes nothing under `state_dir`, while `--dry-run` runs
   regardless of the role.
4c. <a id="rev-ac-4c"></a>**A peer's usage-limit hit stands this pipeline down too (R2c/R6).** With
   a peer's materialised log carrying a `limit-hit` whose `resume_at` is in
   the future, `review-cycle.sh` logs a `review-stand-down`, exits 0 and
   clones nothing; its cleanup still pushes this node's state to its own
   branch (`test/state-sync.test.sh` covers the shared machinery).
4a. <a id="rev-ac-4a"></a>**The switch stands this pipeline down too (R2a).** With
   `agent-cycle.sh --disable 'testing'` set, a plain `review-cycle.sh` logs a
   `review-stand-down` carrying the reason, exits 0, and launches no `claude`;
   `--enable` restores it. Check this against the *review* script specifically
   and not by inference from `agent-cycle.sh` passing — a shared switch that
   only one pipeline reads is the whole failure mode R2a exists to prevent, and
   it looks identical to a working one until the week a review fires into a
   half-edited `lib/`. The same one-pipeline-blind hazard applies to the
   fleet switch, so `test/toggle.test.sh`'s offline e2e runs the real
   `review-cycle.sh` against a set `fleet/disabled.json` and asserts the
   `review-stand-down` names it.
4d. <a id="rev-ac-4d"></a>**The review-branch claim gates the review (R5.0).**
   `test/review-claim.test.sh` passes: against a stubbed `lib/claim.sh` seam
   (`CLAIM_GH`) and a fail-fast `gh`, a *lost* claim logs `review-skipped`
   naming another node and never attempts a clone; a claim *error* skips the
   same way, fail closed; a *won* claim proceeds (the stub records
   `claim branch <slug> review/<date> <default-branch>` in that order), and
   when the clone then fails, `release branch` is invoked for the same key —
   the leak the implementation pipeline fixed in its own workspace path
   (#55) must not be reintroduced here.
4e. <a id="rev-ac-4e"></a>**Per-repository resolution, and duplicate slugs refused (R1b).**
   `test/config-schema.test.sh` passes: `config_repository_review_repos` resolves
   an entry carrying only `slug` to every one of `repository_review.defaults`'
   values, an entry setting a key to its own value for that key alone, and an
   explicit `null` back to the default — including the `model_key` each
   resolution names, which is what an unsupported provider is reported
   against (R1a). `config_defaults` fabricates none of the overridable keys
   into a `repos[]` entry: a schema `default` on one would materialise it in
   every entry, so the entry would always "set" it and `defaults` could never
   apply — which is why only the properties under `defaults` may carry one.
   And a config naming the same `slug` twice exits `review-cycle.sh` 1 before
   the lock, naming the repeated slug, while `scripts/doctor.sh` `fail`s on
   the same config through the same `lib/config-schema.sh` function. Check the
   refusal against the *review* script and not by inference from `doctor.sh`:
   `uniqueItems` cannot express this rule — it compares whole objects, so two
   entries for one repository carrying different overrides are distinct to it
   — so nothing else catches it, and the run would otherwise resolve that
   repository from whichever entry it happened to read last.
4f. <a id="rev-ac-4f"></a>**The dated stand-down is two-tier (R3.3).**
   `test/review-not-before.test.sh` passes: a future
   `repository_review.defaults.not_before` stands the whole cycle down before the
   lock, with the date on the event; and with that key empty while *every*
   configured repository's own `not_before` override is still in the future,
   the cycle stands down before the lock too, logging one `review-stand-down`
   naming issue #342. An empty `repository_review.repos` is vacuously *not*
   a stand-down. And the converse, which is what proves the two tiers are
   really two: with one repository held on its own override while another is
   free, neither tier fires, the cycle runs, and R4's skip-guard turns the
   held repository away by name with its own date while the free one goes on
   to be claimed. Check that case specifically — a `not_before` that had
   quietly stayed cycle-wide passes every other assertion in that file and
   fails only this one, and the failure it stands for is a repository nobody
   asked to hold being held by its neighbour's date.
4g. <a id="rev-ac-4g"></a>**The report directory is configurable, and unset is unchanged (R4a).**
   `test/report-directory.test.sh` passes: against a stubbed `gh`,
   `report_directory_find_dirs` discovers a format string's existing
   instances — folding a leading static segment (`docs/`) into the one
   listing the fixed layout always made, and still resolving a format whose
   date component sits in a middle segment — and
   `report_directory_most_recent` names the latest of them with its own date,
   printing nothing where none exist. `report_directory_regex` escapes
   literal regex metacharacters in a format's surrounding text and degrades
   an unrecognised specifier to a wildcard rather than failing. The
   degraded-read signal is covered too: a stubbed listing that fails exits
   nonzero from both functions, a clean 404 and a listing that matched nothing
   exit zero, and a multi-segment format whose walk fails partway still prints
   the candidates it did find — which is what proves the exit status is the
   whole signal and the printed output unchanged. Check the caller side
   specifically, because it is where getting this wrong costs a cycle rather
   than a value: the same `… | cut -f<n>` shape both silent-degrade callers
   use is driven as its own `bash` process (errexit is not honoured inside a
   command substitution, so a probe wrapped in one reports every caller as
   surviving), asserting that the unguarded form really is killed by errexit
   on a failed walk while the guarded form degrades to empty, and that
   `review-cycle.sh` and `lib/candidate-gather.sh` each carry the guard at
   their own call site.
   `test/config-schema.test.sh` covers the resolution: a repository's own
   `report_directory` wins over `repository_review.defaults`', absent it
   inherits, and absent from both it resolves empty rather than fabricated —
   which is what leaves `REPORT_DIRECTORY_DEFAULT` the single fallback.
   Check the unset case against a test that names no directory of its own:
   `test/gather-project-review.test.sh` passes **unmodified**, which is what
   proves an installation configuring neither key reads and writes exactly
   the paths it did before this requirement existed.

   The write path's pinning (R4a) is checked by reading `review_one`, no test
   reaching it without a full model run: `report_dir` resolves through
   `date -u -d "$review_date"`, never a fresh `date -u`. A fresh call passes
   every test above and fails only a sequential run crossing midnight UTC —
   where the second repository's report folder is dated a day after the
   branch, claim and PR title of the same review.
4h. <a id="rev-ac-4h"></a>**Instructions and context reach the review, and a broken configured path
   never silently narrows one (R1c, R5 step 2a).**
   `test/review-context.test.sh` passes: `review_context_build_json` resolves
   this repository's own `review_instructions`/`review_context` into
   `instructions`/`context` entries attributed `source: "config"`, in
   configured order and ahead of the `repo_context_file` entry attributed
   `source: "repository"`; an oversized source is capped at
   `REVIEW_CONTEXT_SOURCE_MAX_BYTES` and marked `truncated`; and
   `review_context_sources_digest` reduces both arrays to a digest per source
   carrying no `text` field. `review_context_missing_configured` reports a
   configured path that names no readable *regular* file — a directory
   included, which is readable and would otherwise contribute a silently
   empty source — and reports nothing where neither key is configured.
   `repo_context_file` is confined to the clone's own bytes: a `..` in the
   configured path, a symbolic link (pointing out of the clone *or* back into
   it), and a path reached through a symlinked directory each contribute
   nothing, while the ordinary regular file the link pointed at is admitted
   as usual. Check the symlink cases specifically: the configured path is the
   installation's, but the file it names is under the reviewed repository's
   own control, and both `-r` and `head -c` follow a link out of the clone —
   a bound on the path alone leaves D7's boundary a statement about the path
   rather than about the text a model is handed.

   `test/review-context-wiring.test.sh` passes, which is what proves R1c is
   wired rather than merely available: a broken `review_instructions` path
   exits the real `review-cycle.sh` 1 before the lock and before any
   repository is touched, naming the repository, the field, the configured
   path and what it resolved to; a broken `review_context` override on one
   repository's own `repos[]` entry refuses the same way, naming that
   repository and not its neighbour (the sweep reads issue #342's
   resolved view, not `defaults` alone); and a path that does resolve, or
   neither key configured at all, ends the tick 0 with no refusal. Check the
   refusal against the *review script* and not by inference from
   `scripts/doctor.sh` passing: a sweep written but never called, or called
   after the lock, satisfies the unit test and doctor's assertions alike and
   still reviews every configured repository against less than the operator
   asked for. `test/config-schema.test.sh` covers the rest of the
   configuration surface: both keys are arrays of non-empty strings, never a
   bare string; `repo_context_file` is a bare string; all three resolve on
   issue #342's rule; and `scripts/doctor.sh` turns the same detector's
   report into a `fail`, not the `warn` a `prompt_overrides` path earns.
5. <a id="rev-ac-5"></a>**Injected-skill isolation:** after a real `--once --repo poetic` run, the
   review PR's diff contains the new `reviews/...` folder but **never** a
   *new* `tech-debt/*.md` file (only an existing item's frontmatter, where
   R12's resolved-item bookkeeping touched one) and **not**
   `.claude/skills/project-review/` — confirm the injected skill is
   git-excluded and absent from the PR, and confirm any debt the review
   surfaced landed as issues instead: `gh issue list --repo Poetic-Poems/poetic
   --label pw::type:tech-debt --state all` shows a fresh issue per finding,
   each named under the PR body's `Defers:` section.
6. <a id="rev-ac-6"></a>Usage-limit: an injected future `limit-hit` on `log.jsonl` stands the review
   down; and a simulated limit phrase in a transcript causes a `limit-hit` to
   be written to `log.jsonl`.
7. <a id="rev-ac-7"></a>One supervised full run (`--once`): for each non-skipped repo it produces a
   labelled, ready, mergeable review PR, with every item of debt it surfaced
   filed as a `pw::type:tech-debt`-labelled GitHub issue in that repo (R12),
   named under the PR's `Defers:` section, and a clean `review-log.jsonl`
   trail. Report the PR URL(s) to the human; merge nothing.
8. <a id="rev-ac-8"></a>**Cross-references land (R12a):** for every issue that run filed which
   mirrors a recommendation, `gh issue view <n> --json body --jq .body`
   contains its `R-NN`. Check this explicitly: it is invisible in the
   review's own output — the reports look complete either way — and only
   shows up weeks later as the implementation pipeline paying to
   re-investigate recommendations that are already done.

9. <a id="rev-ac-9"></a>**The untrusted-content framing holds for the Reviewer-Agent too
   (R18).** `test/prompt-untrusted-framing.test.sh` passes — it lifts the
   canonical block from docs/spec/implementation/requirements/every-stage.md requirement 45a and
   pins `prompts/project-reviewer.md`'s copy byte-identical alongside the
   implementation pipeline's own prompts.

10. <a id="rev-ac-10"></a>**A stage-health verdict for `project-reviewer` (R19, agent-ops#996).**
   `test/stage-health.test.sh` passes: `stage_health_verdicts` told the
   review pipeline's own event names reads a `review-log.jsonl`-shaped stream
   correctly — including the exit-0-but-failed join over the synthetic
   `(review id, repo)`-scoped `cycle` field, and that two repositories
   reviewed under one `review` id do not cross-contaminate each other's
   verdict — while the default event names stay blind to that same stream,
   proving the parameter is load-bearing, not decorative; and a custom
   `STATUS_FILENAME` writes its own file, leaving `.stage-health.json`
   untouched. `test/review-stage-health-wiring.test.sh` passes: the shipped
   `review-stage-end`/`review-attempt-failed` calls carry `stage`, the
   synthetic `cycle`, and (the genuine-failure one) `stage_failure: true`;
   `cleanup()` computes the verdict from `review_log_file` narrowed to
   `["project-reviewer"]`, over this stream's own event names, into
   `.review-stage-health.json`, before the state-sync push. `test/state-sync
   .test.sh` passes: `.review-stage-health.json` does not replicate as a raw
   file, and its content reaches the heartbeat as `review_stage_health`, a
   field of its own alongside `stage_health`. `test/publish-dashboard.test.sh`
   and `test/dashboard-render.test.sh` pass: `status.review_stage_health` and
   `fleet.nodes[].review_stage_health` read verbatim from the written file and
   a peer's heartbeat respectively, and the page's Review stage health
   section, its own page-top banner and its own fleet-strip badge render
   independently of `stage_health`'s own — a node whose implementation-
   pipeline stages are all healthy while `project-reviewer` fails must read
   as failing too, never masked by the other panel's green verdict.

