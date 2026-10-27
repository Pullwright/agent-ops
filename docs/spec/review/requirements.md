## Requirements

### The Review Script (`review-cycle.sh`)

R1. <a id="rev-r1"></a>**Bootstrap.** Reuse the `PATH` bootstrap and binary checks of
   `agent-cycle.sh` verbatim (claude, gh, git, jq must resolve under cron's
   minimal environment). Source `lib/limit-detect.sh`. The script must pass
   `shellcheck`.

R1a. <a id="rev-r1a"></a>**Model id resolution, against a configured set of providers (D12,
   issue #2131).** `lib/model-id.sh`'s `providers_load` loads the top-level
   `providers` object into `PROVIDER_SUBSTRATE` once, at startup, before the
   sweep below — the same call and the same startup position
   `agent-cycle.sh` makes (`docs/spec/implementation/requirements/the-script-01.md`
   requirement 1a). Every configured repository's own resolved model
   (`repository_review.defaults.model`, or its own override in
   `repository_review.repos`, issue #342) is then resolved through
   `lib/model-id.sh`'s `model_key_load_into` immediately after `repository_review`'s
   settings are read and resolved, before the lock — the same helper and the
   same rule `agent-cycle.sh` applies to its own model keys, the assigning
   form included, so that this sweep is also what records each repository's
   provider for `run_model_stage`'s substrate dispatch to read back
   (`docs/spec/implementation/README.md` requirements 1a and 4d): a bare id means
   `anthropic`, a qualified id has the qualifier stripped once the named
   provider is accepted, and a qualifier naming a provider `providers` does
   not configure — or one configured with a substrate this image has no
   adapter for — is a fail-fast config error naming the precise key the
   value came from — `repository_review.repos[i].model` for a repository's own
   override, `repository_review.defaults.model` when it does not have one — never
   the generic `repository_review.model`, so the error points at the exact key to
   fix (`lib/config-schema.sh`'s `config_repository_review_repos` resolves each
   repository's `model_key` alongside its `model` for this). Every configured
   repository's model is validated in this one sweep, before any repository is
   worked, so a bad model on one repository is never discovered only after
   others have already been reviewed.

   `repository_review.defaults.model` and a repository's own override may
   instead each name a weighted set of models, on the identical terms
   `docs/spec/implementation/README.md` requirement 1a describes for its own
   model keys (issue #2247) — `model_key_load_into` is the set-aware form of
   `resolve_model_id_into` this sweep now calls, delegating outright to it
   for an ordinary bare/qualified value, so nothing above changes for a
   repository that has not turned its model into a set. A member is drawn
   once per repository review, before the lock budget and the
   `review-stage-start` event are computed — `lib/stage-run.sh`'s
   `stage_model_resolve_into`, the same seeded draw and lane-presence
   screening requirement 4d describes, seeded on `"$review_id:$slug:reviewer"`
   (the per-repository identifier this script's own `while`-loop already
   keys `review-stage-end`/`review-attempt-failed` on, since several
   repositories under one `review_id` must draw independently rather than
   sharing one seed) — so the budget cell, the `review-stage-start` event's
   own `model`, and the eventual launch all agree on the same concrete
   member, and `review-stage-start` additionally carries `model_set`/
   `model_set_member` when the repository's model was a set, on the same
   terms requirement 33 describes for `stage-start`.

R1b. <a id="rev-r1b"></a>**Duplicate-slug refusal.** Issue #342's resolution rule assumes
   exactly one `repository_review.repos` entry per repository; two entries naming
   the same `slug` leave no way to say which one's overrides apply. Checked
   immediately after `repository_review_repos_json` is resolved, before the model
   sweep above: `lib/config-schema.sh`'s `config_duplicate_repository_review_slugs`
   — a third cross-key rule the schema itself cannot state, alongside
   `agent-cycle.sh`'s own two (`docs/spec/implementation/requirements`
   requirement 1b) — names every slug appearing more than once, and the Script
   refuses to start naming them, exactly as `scripts/doctor.sh`'s own `fail`
   does against the same function, so the two can never drift on what counts
   as a fault. An empty `repository_review.repos` has nothing to duplicate and is
   not a fault.

R1c. <a id="rev-r1c"></a>**Review-instructions/context path validation (issue #589, D7).** Every
   configured repository's own resolved `review_instructions`/`review_context`
   entries (issue #342) are validated up front, in the same sweep
   position as the model check above: `lib/review-context.sh`'s
   `review_context_missing_configured` resolves each path against `state_dir`
   (on the same terms as `prompt_overrides`' `extend`, requirement 4a) and
   names every one that is not a readable *regular file* — a directory is
   readable and would contribute an empty source rather than the text the
   operator configured, which is the same silent shortfall this check
   exists to refuse. Unlike a `prompt_overrides` path,
   which a stage silently runs without when it does not resolve, a broken
   entry here refuses to start the whole cycle, naming the exact repository,
   field and path — this text changes how strictly a review judges (see
   "Review instructions and context" above), so a typo must not silently
   review every configured repository against less than the operator asked
   for. `scripts/doctor.sh` runs the identical check through the same
   function, so the two can never disagree about what counts as broken.
   `repo_context_file` is deliberately outside this sweep: it names a file
   inside the repository under review, which legitimately comes and goes
   with that repository's own history, so its absence is read at R5 step 2a
   instead, and is never a fault.

R2. <a id="rev-r2"></a>**Lock.** Acquire `review-lock.json` in `state_dir` recording PID, start
   time, and the writer's hostname (`host`, as the implementation pipeline's
   requirement 1 records it; its own lock, *not* the implementation
   `lock.json`). Apply the same held/stale/dead logic as requirement 1, using
   `repository_review.lock_stale_after`: skip cleanly if a live review is younger
   than the threshold, removing the record directory this run made (its only
   content is R2c's snapshot, and a run that reviewed nothing must not take
   one of `state_local_streams_retained`'s slots from one that did —
   implementation spec requirement 2.5); take over a stale or dead lock — TERM, a polled grace of
   up to 20 seconds so the holder's own signal handler (R7a) can write its
   record and release its claim, then KILL — logging a `warning`. Installation-
   wide only, not per repository — the lock covers whichever repositories a
   run touches, so its derivation takes the widest `timeout_review` /
   `inactivity_review` configured across all of them (defaults or any repo's
   own override), not any one repository's own. The lock has a second reader
   on a containerised node:
   `deploy/docker/watchtower-pre-update.sh` consults it, on the same
   `repository_review.lock_stale_after` bound, to defer an image roll that would
   otherwise kill a review mid-flight — judging liveness only when the lock's
   `host` is its own container, and honouring a lock written elsewhere until
   released or stale, since a pid means nothing outside the PID namespace
   that minted it (see the node stack section of
   `docs/spec/implementation/README.md`). A review is protected exactly as
   long as it would keep the lock against another review.

R3. <a id="rev-r3"></a>**Stand-down checks.** Each logs its reason and exits 0:
   1. *Usage-limit cooldown* — identical to requirement 2.1: the log
      union's most recent `limit-hit` and the live `fleet/limit.json` flag
      are both read, and the **later** `resume_at` wins; if it is still in
      the future, stand down. When *this* pipeline hits a limit it writes
      the same two carriers the implementation cycle does — the `limit-hit`
      event to the shared `log.jsonl`, and the fleet flag, extend-only,
      best-effort (a `warning` is logged when the flag write fails and the
      union carries the signal instead). The union is read with requirement
      2.1's reduction, which skips a line that does not parse; a read that
      fails outright, or a union that could not be built (R2c), is logged as
      a `warning` and leaves the flag to decide alone, here and at the
      re-check between repositories alike.
   2. *Implementation pipeline busy* — if `lock.json` is held by a live
      process, stand down and wait for the next tick (defer to it, per
      "Relationship to the existing pipelines"), removing the record
      directory for the same reason as R2's lock skip.
   3. *A dated stand-down, tier one* — if `repository_review.defaults.not_before`
      is set and now is before it, stand down the whole cycle, logging the
      timestamp on the event so an operator can tell this apart from a
      switch. Checked before the lock, like R2a, so a review that must not
      start never takes a lock a roll would then defer for. This is the
      installation-wide value only: a repository's own `not_before` override
      (issue #342) is resolved separately, per repository, into R4's
      skip-guard below, once the cycle is under way — an override can hold
      one repository off *longer* than this value, but cannot escape it
      while it is in force. This exists because R2a's switch is deliberately
      **shared** with the implementation pipeline: holding the review pipeline
      off until a date while cycles carry on is a thing the switch cannot
      say. A value `date -d` cannot parse stands the pipeline down rather
      than running through it — the operator evidently meant to hold
      reviews off, and guessing otherwise spends whatever they were
      protecting. Absent or empty is not a stand-down. Preferred over
      raising `min_days_between_reviews` because it expires by itself: a
      threshold has to be put back by hand, and one left raised throttles
      every repo indefinitely without anyone noticing.
   4. *A dated stand-down, tier two* — checked immediately after tier one,
      also before the lock: even where `repository_review.defaults.not_before`
      itself does not trip tier one — absent, or already past — the whole
      cycle still stands down when *every* configured repository's own
      resolved `not_before` (its override, or the inherited default,
      already resolved into `repository_review_repos_json`) is future or
      unparseable. This is the case tier one alone misses: a
      `repository_review.defaults.not_before` left unset while every
      repository overrides its own, which tier one — reading only the
      installation-wide key — would let straight through to the lock, for a
      cycle certain to have R4's skip-guard skip every repository anyway.
      Vacuously false, not true, on an empty `repository_review.repos`: nothing
      configured means nothing this tier could ever hold back, not that
      everything is held.

R2a. <a id="rev-r2a"></a>**The switch.** Before the lock, read the shared switch
   (`state_dir/disabled.json`) through `lib/toggle.sh` and stand down while it
   is set, logging `review-stand-down` with the reason it carries — the same
   check `agent-cycle.sh` makes, through the same code, so the two pipelines
   cannot disagree about whether they are meant to be running (requirement
   34a).

   **Stands down under either of the switch's two modes** (implementation
   spec 2.3d) — a full stop (`mode: "stop"`, the default for every record
   before that field existed) and a drain (`mode: "drain"`) alike. `.state ==
   "disabled"` already reads true for both, since `mode` is a field on the
   same record rather than a different `state`, so this requires no branch of
   its own: unlike `agent-cycle.sh`, which keeps finishing already-open pull
   requests during a drain (implementation spec 2.2c/2.9), this pipeline has
   no finishing set to keep working — every review it starts is new work by
   construction — so a drain leaves it nothing to do differently from a full
   stop. Only the logged reason names which mode was in force, for a reader
   of the log wondering why a drain — nominally about letting existing work
   finish — stood this pipeline down entirely.

   The switch is **shared, not per-pipeline**, and this pipeline is the reason
   that matters rather than an afterthought. It exists because an agent editing
   the agent-ops working tree is editing files the next cron tick will source —
   and this script runs out of that same tree and sources that same `lib/`. An
   agent that stood down only the implementation pipeline before editing
   `lib/limit-detect.sh` would have left the review pipeline free to fire into
   a half-written file.

   This pipeline **honours the switch but never sets it**: `agent-cycle.sh
   --disable/--enable/--status` is the single entry point, so there is one
   writer and one record. Reject those flags here with a pointer rather than
   implementing a second way to write the same file. Leave an *expired* switch
   for `agent-cycle.sh` to clear and log, too: this pipeline runs on its own
   configured cadence (`repository_review.defaults.min_days_between_reviews`), so
   letting it clear one would mean the `enabled` event explaining why cycles
   resumed could land days after they did.

   The **fleet switch** (`fleet/disabled.json`; implementation spec 2.3a) is
   honoured on exactly the same terms, checked right after the local one:
   stand down while it is set, never write it, never clear it — not even
   expired, for the same days-late-`enabled` reason.

R2b. <a id="rev-r2b"></a>**The role guard.** Before the switch, the config and the lock, stand the
   run down unless `AGENT_OPS_ROLE` is `active` — the implementation pipeline's
   requirement 2.4, through the same shared `lib/role.sh`, so "active" has one
   definition and a node cannot be standby for one pipeline and active for the
   other. Unset, empty or any other value is a standby: it writes one line to
   stdout (which cron redirects into `review-cron.log`) and exits 0, leaving
   nothing in `state_dir` — not even a `review-start` event. `--dry-run` and
   `--once` bypass it, as they do there.

   The ordering matters and is deliberate: the guard comes first because a
   standby node has no business reading, logging or clearing state that belongs
   to the active one.

R2c. <a id="rev-r2c"></a>**The fleet's memory and state publication.** After the lock and before
   any work, snapshot the fleet's shared event stream — this node's
   `log.jsonl` unioned with every peer's, via `lib/fleet.sh`
   (`docs/spec/implementation/requirements`, requirement 2.5) — so the
   usage-limit checks below see a limit *any* node hit; the union is
   re-snapshotted between repos, and each snapshot is built on the terms of
   that same requirement: `fleet_logs` takes a peer's NUL-holed or spliced
   line apart before its sort, so the snapshot needs no repair and a damaged
   line costs this pipeline only the stumps it held, exactly as it costs a
   cycle. A snapshot that could not be built is logged as a `warning`, and
   the usage-limit read that follows treats it exactly as a read that failed
   (R3.1).
   The run's cleanup removes the snapshot, as a cycle's does: it is scratch
   with the run's lifetime, and a count of retained snapshots bounds how many
   are kept, never how large they are (that requirement's own terms). The
   run's own scratch directory — `agent-ops.review-cycle.<pid>.XXXXXX` under
   `$TMPDIR`, entered before any library is sourced and pointed to by
   `TMPDIR` for the run's lifetime, so that every `mktemp` of the run lies
   inside it (`lib/scratch.sh`, that requirement again) — is released by the
   same cleanup, last of all.
   There is no lease: per-item claims
   (requirement 17a of the implementation spec) arbitrate work.

   Before the lock, reap `workspace_root` on the terms of the implementation
   spec's requirement 6b: this pipeline clones into the same directory and
   loses its clones to a kill in exactly the same way. Its window is its own
   — the review lock is derived from the Reviewer's budget times the
   repository count, so it is wider than a cycle's — and both are floored at
   24 hours, which is why whichever pipeline runs first cannot reap a
   workspace the other is still working in. A `workspaces-reaped` event is
   written only when something was reclaimed. At the
   end of the run — from the cleanup that releases the lock, once the review
   is fully recorded — publish this node's `state_dir` to its own
   `nodes/<NODE_NAME>` branch with `scripts/state-sync.sh push`,
   unconditionally: no other node's push can collide with it.

   The review needs this for the same reason the implementation cycle does: it
   spends, and two nodes reviewing the same repositories would open competing
   review pull requests. R4's skip-guard would not save them — two nodes
   starting within the same minute both see no open review PR. The
   review-branch claim (R5.0) is what closes that window: the second node
   loses the create-ref and skips the repo before cloning anything.

R4. <a id="rev-r4"></a>**Per-repo skip-guard (idempotency; this is how "once a week" is
   enforced).** For each configured repo, skip it *this run* when **any** of
   these independent conditions holds (an OR across the three):
   - its own resolved `not_before` (its override, or
     `repository_review.defaults.not_before`, issue #342) is set and now is
     before it — the same rule R3's cycle-wide check applies, checked again
     here per repository so a repository's own override can hold it off
     *longer* than the installation-wide value; **or**
   - an open pull request labelled with its own resolved `repository_review`
     pr_label already exists for it (a review is in-flight or awaiting
     merge); **or**
   - its default branch already contains a report directory (R4a) dated
     within the last `min_days_between_reviews` days (its own resolved
     value), **or** fewer than `min_prs_between_reviews` pull requests (its
     own resolved value) have merged into its default branch since that same
     report directory's date (read best-effort via `gh`, and only evaluated
     once a most-recent review date exists — a repository's first-ever review
     has nothing to count either threshold since). These two thresholds are
     an **AND**, not a further OR: a review proceeds only once *both* enough
     days have elapsed *and* enough pull requests have merged, so raising
     either alone raises the bar.

   Log `review-skipped` with the reason, naming the count and threshold for
   the `min_prs_between_reviews` case. This guard is what makes a **daily**
   cron tick safe and preferable to a strict weekly one: the Script only
   actually reviews a repo when at least `min_days_between_reviews` days have
   passed, so a tick missed because the machine was asleep simply catches up on
   the next day instead of losing a whole week (compare requirement note that
   "a missed cycle simply waits for the next tick"). `min_prs_between_reviews`
   defaults to 5 in code (`review-cycle.sh`) when neither
   `repository_review.defaults.min_prs_between_reviews` nor a repository's own
   override is set.

R4a. <a id="rev-r4a"></a>**Report directory (issue #761).** Where a report set (R11) is written,
   and where R4's own skip-guard and the implementation pipeline's
   `project-review` Refiner source (`docs/spec/implementation/requirements`
   requirement 3y) look for the most recent one, is a GNU `date`(1) format
   string, resolved with `date -u +"<format>"` relative to the repository
   root — never a fixed path. Resolution, per repository (issue #342's
   rule): its own `repository_review.repos[].report_directory` override when
   set, else `repository_review.defaults.report_directory`, else
   `reviews/project-review-%Y-%m-%d` — today's layout, fixed in code
   (`REPORT_DIRECTORY_DEFAULT` in `lib/report-directory.sh`) rather than the
   schema, so a repository configuring neither key is byte-for-byte
   unaffected by this requirement's existence. `review-cycle.sh` resolves
   this once per repository (alongside `model`, `pr_label`, `branch_prefix`
   and the rest of issue #342's overridable keys) and passes the
   resolved directory as `report_dir` in the Reviewer-Agent's runtime input
   (R5.3) — the prompt writes into `report_dir` exactly as given, never
   re-deriving a layout of its own.

   The write path is resolved for the run's own `review_date` (`date -u -d
   "<review_date>"`), pinned once at start, never for the moment the
   repository's turn comes: repositories are reviewed sequentially (R5) and a
   single review can take an hour, so a run that crosses midnight UTC would
   otherwise write a later repository's report set into a folder dated a day
   after the branch, claim and PR title (`review/<review_date>`, R5.0) that
   name the same review. A format string must therefore be day-granular —
   only date-level specifiers (`%Y`, `%y`, `%m`, `%d`, `%j`) and literal
   text, documented on the config key. Discovery (below) probes a calendar
   day at a time, so a format carrying `%H`, `%M` or `%S` names a directory
   that resolves differently when it is looked for than when it was written:
   the skip-guard would find nothing and review the repository on every tick,
   and requirement 3y's Refiner source would go permanently empty.

   Discovering which of a format string's past instances already exist —
   needed by R4's skip-guard and by `gather-project-review.sh` — cannot
   reuse a single hardcoded pattern the way the fixed layout could, because
   an installation's format string can place its date component anywhere in
   the path. `lib/report-directory.sh` answers it generically: fold every
   leading path segment free of a `%` specifier into one static prefix (the
   common case — the whole dynamic part is the format's final segment, as
   both the shipped default and every example in the issue are shaped —
   costs exactly the one directory listing the fixed layout always made),
   list it, and match the remaining segment(s) against a regular expression
   built from the format string's own specifiers; then find which day each
   surviving candidate belongs to not by parsing its name back into a date,
   but by resolving the format string for each of the last 400 days and
   checking whether that resolved string is one of the candidates — every
   check a local `date` call, no further network cost. Both `review-cycle.sh`
   and `agent-cycle.sh` (via `lib/eligibility.sh`'s Refiner pre-fetch, which
   passes the resolved directory to `gather-project-review.sh` as its third
   argument) resolve through this one shared implementation, so the two
   pipelines cannot discover two different answers for the same repository.

   A listing that *fails* is told apart from one that succeeds and matches
   nothing (issue #1024), because a caller deciding something irreversible on
   "no review folder exists" must not act on a rate limit: both
   `report_directory_find_dirs` and `report_directory_most_recent` exit
   nonzero when some listing inside the walk failed for a reason other than
   the queried path not existing (a clean 404 *is* a definite "nothing here"),
   and zero otherwise. The exit status is the whole of that signal — what they
   print is byte-for-byte what they printed before the distinction existed,
   including for a multi-segment format whose walk lists one level and fails
   at the next, so degraded and found-something are not exclusive states.
   `docs/spec/implementation/requirements` requirement 3y's `--current-date`
   mode is the caller that needs it. R4's own skip-guard
   (`most_recent_review_date`) does not — a failed listing and an absent
   folder both mean "no date to compare against", and the guard already
   proceeds on an empty one — so it declines the signal explicitly, ending its
   pipeline with `|| true`: under `set -o pipefail` the status would otherwise
   reach `review-cycle.sh`'s own errexit through that function's return value,
   turning a transient listing failure into a dead cycle.

R5. <a id="rev-r5"></a>**Per non-skipped repo** (processed **sequentially**, so a failure of one
   never blocks the other and only one heavy `claude` runs at a time):
   0. *Claim the review branch* (R5c; implementation spec requirement 17a).
      `review/<review_date>` is a date-only name: every active node computes
      the same one on the same day, and without a lock the loser discovers
      the collision only after spending a full model review — at push time.
      Before anything expensive, claim the branch through `lib/claim.sh`
      (`claim branch <slug> review/<date> <default_branch>`): one create-ref,
      which GitHub 422s for the second caller even at the same SHA, plus the
      registry entry that back-pressure, the dashboard and gc read
      (`CLAIM_SOURCE=project-review`). A lost claim logs `review-skipped`
      ("already claimed by another node"); a claim *error* also skips the
      repo, fail closed — a node that cannot reach GitHub to claim could not
      have pushed a review either. Releases mirror the implementation
      pipeline's hooks: a failed clone or failed reviewer releases fully
      (`release branch` — the ref is deleted only if it is unmoved **and**
      no open PR uses it, so a review the model pushed before dying
      survives, as does an abandoned-but-open PR); a raised PR releases the
      registry entry only (`release file` — the PR supersedes the claim and
      the branch is its head). `--dry-run` exits before any claim.
   0a. *Git identity.* Immediately after the claim succeeds — the first point
      in this repo's run that could actually commit — require
      `GIT_USER_NAME`/`GIT_USER_EMAIL` via the shared `lib/git-identity.sh`
      (`docs/spec/implementation/environment.md`, "The node image"): both are
      required, with no default, and their absence exits non-zero with an
      actionable message rather than falling back to any identity. The claim's
      own lost/error skips, and every stand-down before it, commit nothing and
      are never gated on this.
   0b. *Labels.* At the same point, and for the same reason it is that point —
      this repo is now certainly going to be worked — ensure its own resolved
      `repository_review` pr_label exists in it, via `labels_reconcile_role`
      (`lib/labels.sh`), unconditionally and unstamped: the same shape
      `docs/spec/implementation/requirements` requirement 6a
      uses for its own selected repository, immediately before the stage that
      needs the label to exist, rather than the rate-limited
      `labels_reconcile_stamped` requirement 6a's per-gathered-repository
      ensure uses. The `review` role reconciles under MODE `additive`, so a
      label outside `label_prefix`'s namespace — which every shipped
      `repository_review` pr_label is — is still created only if absent and
      otherwise left exactly as the operator has it, and nothing is ever
      deleted here: only a pr_label the operator has named inside that
      namespace additionally has its colour and description reconciled
      against the catalogue's (requirement 6a). A repository is selected for
      review at most once per
      `min_days_between_reviews` days (R4), longer in every shipped
      configuration than `labels_ensure_interval_hours` (default 24h), so a
      stamp here would always have gone stale between one review of a
      repository and the next — costing the same listing a stamp would have
      saved, while leaving open the gap a shorter `min_days_between_reviews`
      or a longer `labels_ensure_interval_hours` would create: a `pr_label`
      deleted after a stamp was written going unnoticed until `gh pr create
      --label` fails the create outright, discarding a review that cost up to
      `timeout_review` minutes. Never fatal: a repository whose labels cannot
      be listed, or a token that may not create them, logs `labels-ensured`
      with what failed and the review proceeds. The event carries `created`,
      `updated`, `deleted` and `failed`, the four `labels_reconcile`'s own
      report can hold; at this call site `deleted` is always empty, MODE
      `additive` having no delete pass.
   1. *Workspace.* Create `workspace_root/<review-id>-<repo-slug-safe>/` and
      clone the repo fresh from GitHub — the multi-agent ways-of-working rule
      shared by all Poetic repositories: every agent works in its own
      dedicated fresh clone taken from the tip of the default branch before
      commencing any changes. (A full clone — the review examines git
      history.) The clone goes through `lib/repo-clone.sh`'s `clone_repo`, the
      same function the implementation pipeline's requirement 6 uses: `git
      clone`, because `gh repo clone` resolves the repository through a
      GraphQL query that is billed against the API budget, and git's own
      transport is not rate-limited. The git credential helper
      `deploy/docker/entrypoint.sh` wires — `!gh auth git-credential`, an
      unqualified `gh` that `PATH` resolves to the transport shim and so to
      the on-demand credential seam (docs/spec/implementation/components/components-03.md component
      22c) — authenticates the HTTPS remote, and
      `CLONE_GIT` substitutes a stub for tests, and anything already at the
      target path is discarded rather than inspected (requirement 6). Assert
      the working
      directory is under `workspace_root` before launching any stage
      (requirement 6). The user's own clones under `~/Code` are never touched.
      Once the clone succeeds, measure it — `lib/disk-space.sh`'s
      `disk_space_clone_footprint_bytes`, a `du -sb` of the clone directory —
      and log a `clone-footprint` event carrying `{repo, bytes}` against the
      cloned repository's own slug, to the *shared* `log.jsonl` (R16), which is
      where requirement 2.0c of `docs/spec/implementation/README.md` reads it
      back from to derive its pre-clone free-space threshold. Best-effort: a
      `du` that cannot be read logs no event rather than a fabricated size, and
      nothing about the review depends on it.
   2. *Inject the skill.* Copy this repository's
      `.claude/skills/project-review/` into
      `<clone>/.claude/skills/project-review/`, then append
      `/.claude/skills/project-review/` to `<clone>/.git/info/exclude` so the
      injected tooling can never be staged or committed by the review agent.
      (`.git/info/exclude` is per-clone and never part of the tree, so this
      leaves no trace in the PR. The clone already has its own `.claude/`; the
      injection sits alongside its existing skills.) This staging is
      substrate-neutral: every provider's folder-trust mechanism discovers
      `./.claude/skills/` once trusted (confirmed for Grok Build, issue
      #2136).
   2a. *Resolve instructions and context (issue #589, D7).*
      `lib/review-context.sh`'s `review_context_build_json` resolves this
      repository's own `review_instructions`/`review_context`
      (issue #342, already validated at R1c) plus `repo_context_file`
      read from this clone if it names a readable file — simply absent if it
      does not, never a fault — into `{"instructions": [...], "context":
      [...]}`, each entry `{source, origin, text, truncated, bytes, digest}`
      capped at `REVIEW_CONTEXT_SOURCE_MAX_BYTES`. `repo_context_file` must
      resolve to a regular file whose bytes are genuinely inside the clone:
      the configured path may be neither absolute nor contain `..`, the file
      itself may not be a symbolic link, and the directory holding it must
      canonicalise to the clone or something under it. The path is
      installation-configured but the *file* is under the reviewed
      repository's own control, so without this a committed symlink
      (`.github/REVIEW-CONTEXT.md` → an installation credential) would read
      whatever the cycle can read into the Reviewer-Agent's own input, and
      D7's boundary below would be a statement about the configured path
      rather than about the text a model is handed. A path that fails any of
      these is treated exactly as an absent one — silently not configured,
      never a fault. Both arrays are appended to the
      Reviewer-Agent's runtime input (the JSON object R5 step 3 hands it) as
      `instructions` and `context`, each source carrying its own `origin` so
      the agent — and `prompts/project-reviewer.md`'s "Untrusted external
      content" section — can tell an installation-supplied entry
      (`source: "config"`) from a repository-supplied one
      (`source: "repository"`) and judge the latter as attributed evidence
      about the repository, never as an instruction. `review_context_sources_digest`
      reduces both arrays to `{type, source, origin, digest, bytes,
      truncated}` — a sha256 of the text actually sent, never the text
      itself — recorded on the `review-stage-start` event below so a past
      review's inputs are reconstructable.
   3. *Reviewer-Agent stage.* Launch the Reviewer-Agent headless (this
      repository's own resolved model, `--dangerously-skip-permissions`,
      timeout from its own resolved `timeout_review`), with the clone as the working
      directory, passing `prompts/project-reviewer.md`. Use `run_model_stage`
      (R7b) so a timeout kills the whole process group, the invocation
      streams its events to `<stage>.stream.jsonl` as it runs, and its final
      `result` envelope lands in `<stage>.out` for the parse below. The
      prompt reaches the stage
      on stdin, never as a command-line argument, for the reason
      `docs/spec/implementation/README.md`'s requirement 4c gives: a single
      argv entry is capped at 131072 bytes, and a prompt is the one input here
      that grows without bound. For a `claude-code` stage, requirement 4d's
      own credit-mix lane draw (issue #2241, D30) applies here exactly as it
      does to every other stage this launcher runs: a lane is drawn, forced
      and verified against the stream, and `review-stage-end` carries
      `kill_reason: "lane-mismatch"` on the same terms a mismatch earns
      anywhere else. This pipeline's prompt has room to spare today,
      which is precisely why the launcher is shared rather than copied — the
      smaller prompt is the one that would sit broken longest before anyone
      noticed.
   4. *Parse.* Extract the work summary from the final message with the same
      parser `agent-cycle.sh` uses. Recover the PR URL from the parsed
      `pr_url`, else by grepping the transcript, else from a
      `.git/agent-ops-review-pr-url` breadcrumb the agent writes the moment it
      opens the PR (the analogue of requirements 9 and 23), so a stranded
      attempt is still traceable.
   5. *Outcome.* On success (`status: "complete"` and a PR URL), log
      `review-pr-raised`. On any failure (timeout, non-zero exit, unparseable
      final message, or `status` other than `complete`): log
      `review-attempt-failed` with enough detail to diagnose, and — if a PR was
      already opened — comment on it that the agent abandoned it and why,
      leaving the PR and branch for the human. That comment opens with
      `docs/spec/implementation/README.md`'s requirement 9d header,
      `**Review Script** · autonomous pipeline · node \`<node>\``, and carries
      that same requirement's invisible marker, stamped `actor=review-script`
      — harmless here, since `gather-abandoned-drafts.sh` never sees a review
      PR's `project-review` label or `review/` branch prefix, but it keeps the
      write side of the marker to the one definition in
      `lib/pipeline-marker.sh` that requirement's component describes.

R6. <a id="rev-r6"></a>**Usage-limit detection.** After every `claude` invocation, run the shared
   detector (`lib/limit-detect.sh`). On a match, write a `limit-hit` event to
   the *shared* `log.jsonl` with the requirement-10 shape (`resume_at`,
   `class`, `reset_known`, and requirement 2.1's `provider` naming the
   provider the stage that hit the limit was running on) and stop launching
   further repositories this run.
   This is a single-line, atomic `O_APPEND` write; it is safe even if the
   implementation pipeline (holding its own lock) appends concurrently, and it
   is the one signal both pipelines and the dashboard key their stand-down off.
   Both of this pipeline's stand-down checks read that signal through the same
   shared reduction, so `agent-cycle.sh --clear-limit` lifts the review cycle
   too — one account, one limit, one way to clear it.

R7. <a id="rev-r7"></a>**Cleanup (always, via a trap).** Delete each cycle's clone, write a
   `review-end` event, release the review lock, and tee each stage's
   stdout/stderr to `state_dir/reviews/<review-id>/` for debugging. Optionally
   refresh the dashboard the same way `agent-cycle.sh` does (isolated and
   time-bounded, so it can never affect the run's outcome).

R7a. <a id="rev-r7a"></a>**A signal is a failure with a record.** The Script traps `TERM`, `INT`
   and `HUP` from the moment its cleanup trap is armed, with the same
   handler discipline — and for the same reasons, set out at length there —
   as the implementation pipeline's requirement 9c: kill the in-flight
   stage's own process group (which no signal to the Script's group ever
   reaches), log `review-attempt-failed` naming the repo under review and
   the stage in flight with detail `<stage> terminated by SIG<name>`,
   release the review claim time-bounded (`no-pr` is safe even when the
   model had already raised its PR — lib/claim.sh keeps a ref that has
   moved or that an open PR uses), and exit `128+n` through `exit`, so R7's
   trap still writes `review-end` with a truthful code and releases the
   lock. A signal landing during cleanup itself must not re-enter the
   handler. Covered by the same `test/signal-exit.test.sh` as the
   implementation pipeline's acceptance check 4a.

R7b. <a id="rev-r7b"></a>**One stage launcher, shared, provider-neutral.** `run_model_stage` is
   sourced from
   `lib/stage-run.sh`, the implementation pipeline's requirement 4d — it is
   not a copy of it. The two scripts each held their own until the streaming
   change of #203 had to be made twice; both specs already said the copies
   must not diverge, and a shared file is the only form of that promise a
   reviewer does not have to check by eye. Launching the Reviewer-Agent on a
   provider other than `anthropic` therefore needs no change to this
   pipeline at all (issue #2133): `run_model_stage` resolves the substrate
   adapter from this repository's own resolved model, the same way every
   other caller does. Everything requirement 4d states
   holds here unchanged: the process group, the wall-clock cap, the
   `<stage>.stream.jsonl` written as the run proceeds, and the final `result`
   event truncated into `<stage>.out` for R5.3's parse. The streams are
   local-only here too — `reviews/` replicates without them, and
   `state_local_streams_retained` bounds what stays on the node.
   Requirement 4e's liveness watchdog comes with it: this repository's own
   resolved `inactivity_review` minutes of total silence stops the
   Reviewer-Agent, its own resolved `timeout_review`
   remains the backstop above it, and `review-stage-end` carries the
   `kill_reason` that tells the two apart. Absent, the shipped prior applies;
   `0` disables the watchdog and leaves the backstop as the only cap. This
   pipeline's stage is the long one — a whole project review — which is
   precisely why the distinction matters here: a review that is merely slow
   must not be killed, and one that has stopped should not hold a node for two
   hours. The same requirement's third stop applies too: a stream reporting
   the account refused stops the Reviewer-Agent at once, and
   `detect_and_log_limit_hit` derives the stand-down from the runner's own
   record rather than from prose the stopped stage never wrote.
   Both caps are *derived* rather than configured, by requirement 4f and
   through the same `lib/stage-budget.sh` the implementation pipeline uses:
   the Reviewer-Agent is the cell `(project-reviewer, <repo>, <model>)`, and
   a repository's own resolved `timeout_review` / `inactivity_review` (its
   override, or `repository_review.defaults`') are overrides that win when
   present. `review-stage-start` announces what this run was given and where
   each number came from, plus (R5 step 2a) `review_context_sources`: every
   resolved instructions/context source and a digest of its text.
   `repository_review.lock_stale_after` becomes a floor
   under a derived threshold, which takes the *widest* `timeout_review` /
   `inactivity_review` configured across every repository this run might
   touch — not any one repository's own — and multiplies it by the number of
   repositories configured for review (floored at one, so a single-repository
   installation is unaffected), because one lock can span all of them
   reviewed back to back.

R8. <a id="rev-r8"></a>**Flags.** `--dry-run` (evaluate the stand-down and skip-guard checks,
   print which repos *would* be reviewed, launch no agent), `--once` (one
   verbose run in the foreground), `--repo <slug>` (restrict to one repo, for
   testing). `--disable`, `--enable`, `--status`, `--for` and `--until` are
   recognised only to reject them with a pointer to `agent-cycle.sh` (R2a) —
   an unknown-argument error would read as "this pipeline ignores the
   switch", which is the opposite of true.

### The Reviewer-Agent (`prompts/project-reviewer.md`)

R9. <a id="rev-r9"></a>**One-shot constraint** (requirement 21). A single non-interactive
   `claude -p` invocation with no resumption: once it emits a final message
   with no further tool calls, it exits for good. It must wait synchronously
   for long-running commands (installs, builds, the project's own test suite)
   rather than ending its turn expecting a later notification. A command too
   slow to finish within this repository's own resolved `timeout_review` is
   grounds for `"status": "blocked"`, not a hopeful early end of turn.

R10. <a id="rev-r10"></a>**Obey the repo.** Runs inside the clone. First reads the repo's
   `AGENTS.md` — or `CLAUDE.md`, for a repo that has not migrated;
   `CLAUDE.md` imports `AGENTS.md` where it has — and obeys it throughout
   (branch workflow, commit format, tech-debt register conventions,
   documentation-as-built rules, the `npm run check` whitespace gate, etc.).

R11. <a id="rev-r11"></a>**Run the skill end-to-end.** Invoke the vendored `project-review` skill
   and follow it to completion: produce the report set (index, summary,
   findings, recommendations, improvement prompts) in `report_dir` — the
   directory the runtime input names (R4a) — and file the debt it surfaces
   per R12. `report_dir` is the review folder itself — what the skill's
   Step 0, item 4 calls a review folder the caller names — never a
   directory to create a dated folder inside, whatever shape R4a's format
   gives its path. Every run is a fresh review: where the skill's resume
   scan finds a `review-state.json` in `report_dir` or one of its dated
   siblings, the Reviewer-Agent starts afresh in `report_dir` whatever
   status that file records. Resuming a dated sibling's review would
   continue it in that sibling's folder, outside `report_dir`. No run of
   this pipeline leaves such a file behind: R7 deletes each run's clone, R9
   admits no resumption, and the book-keeping below deletes the state file
   before anything is committed. The injected skill under
   `.claude/skills/project-review/` is *tooling staged for this run*, **not**
   part of the repository under review: exclude it from the review's scope and
   findings, and never `git add` it (R5b also git-excludes it as a backstop).
   Complete the skill's own resumability book-keeping (delete `worknotes/` and
   `review-state.json`) so only the finished reports remain.

R11a. <a id="rev-r11a"></a>**State a recommendation's default fix.** Where an `R-NN`
   recommendation's *Approach* names more than one candidate fix, add a
   `## Default: <fix>` heading (one sentence, the option the reviewer would
   take) directly below it, and an `Owner decision: yes` line beside it when
   that choice falls under `docs/spec/implementation/requirements` requirement
   36a's owner-only boundary (a credential or secret, an account/settings/
   permissions change, a licence/roadmap/product/architecture decision, an
   external service the pipeline does not hold, or information that exists
   only in someone's head) — the same convention `lib/tech-debt-file.sh`'s
   `techdebt_default_section` gives a filed `file_debt`/`file_issue` body
   (requirement 36c), so a recommendation mirrored into an issue under R12a
   below reads identically to one of those. This is guidance to the
   Reviewer-Agent layered on top of the vendored skill's own template
   (`.claude/skills/project-review/references/output-templates.md`), never an
   edit to that pinned copy — see "The `project-review` skill (vendored)"
   above for why this repository does not own it.

R12. <a id="rev-r12"></a>**File review-sourced debt as labelled issues.** New debt this review
   surfaces does not go into the register: it is filed as a GitHub issue in
   the repository under review, labelled `pw::type:tech-debt` (the label the
   implementation pipeline's own label catalogue already ensures exists there
   — `docs/spec/implementation/requirements` requirement 6a), never as a
   `tech-debt/<id>.md` file. Search first — `gh issue list --label
   pw::type:tech-debt --search "<working title>" --state all` against the
   repository under review — and a close match means the gap is already
   tracked: cite its number instead of filing a second issue for it. File
   each new item with `gh issue create --label pw::type:tech-debt`, its body
   describing what, why it matters, where, and a suggested fix — the same
   content a register item's body would have carried. Filing an issue is one
   API call, not a commit: keep the list of every issue filed this run, since
   R13's pull request body is the only record connecting the review to what
   it found, under a `Defers:` section rather than a git diff.

   Where the repository under review still carries an existing tech-debt
   register (per-item or legacy — either predating this requirement, or kept
   in place as history once a repository migrates to issue-based filing),
   never file new debt into it and never migrate it to the other format.
   Where the review finds one of its existing items already resolved, still
   update that item in place, in its own format — a per-item register's
   frontmatter status flip (`status: resolved`, `resolved:`, `ref:`), never
   its body, never deleting or renaming the file; a legacy register's own
   status update, in its established style — since that is an edit to a file
   already there, never a new one the review adds.

R12a. <a id="rev-r12a"></a>**Cross-reference every mirrored recommendation.** Where a GitHub issue
   R12 files covers the whole of a recommendation's *Intended end state*,
   name that recommendation's `R-NN` and this run's `report_dir` in the
   issue's own body, somewhere a reader — and a `gh issue view --json body`
   grep — will find it (e.g. a line `Review: <report_dir> R-<NN>`). Do it
   when the issue is filed, not when it is resolved.

   This is not book-keeping. A recommendation and its mirrored issue are two
   channels onto one piece of work, and the implementation pipeline's
   Co-Ordinator can tell only by finding this cross-reference
   (`docs/spec/implementation/requirements`, requirement 16). Absent
   it, that Co-Ordinator has one remaining test for whether a recommendation
   is done — a merged PR referencing it — which work that landed as a direct
   commit can never satisfy. The recommendation then reads as outstanding
   forever and is re-selected and re-investigated every cycle at full model
   cost. This is not hypothetical: it is exactly what `R-01` of
   `poetic`'s 2026-07-11 review did, nine times in two days, for a licence
   that had been committed before the review was even written.

   Record the mapping **only** where the issue genuinely covers the
   recommendation's whole end state. A recommendation broader than the issue
   mirroring it keeps its remainder in the review channel, where it stays
   visible; claiming it here would silently retire work nobody has done.

R13. <a id="rev-r13"></a>**Raise one pull request.** Create the branch
   `<branch_prefix><date>` (`review/<date>` by default; this repository's own
   resolved `branch_prefix`) from the
   default branch; commit the review folder — plus, only where R12's
   resolved-item bookkeeping touched an existing register, that edit
   alongside it, never a *new* `tech-debt/` file; open **one**
   pull request, **ready for review** (not draft),
   labelled with this repository's own resolved `repository_review` pr_label,
   with a Conventional-Commits title
   (`docs(review): repository review <date>` — it becomes the squash commit
   on `main`) and a body that summarises the verdict, links the review
   index, and — where R12 filed any issues — lists every one of them, its
   number and title, under a `Defers:` section, so a human reading the pull
   request sees the debt this review deferred without opening every issue.
   Record the PR URL to `.git/agent-ops-review-pr-url` immediately on opening
   it (the breadcrumb R5d relies on).

R14. <a id="rev-r14"></a>**Prove it is landable.** Run the repo's own checks (as its
   `AGENTS.md`/`CLAUDE.md` and workflow files define — for a docs-only
   change this is chiefly the whitespace/format gates and commit-format)
   and fix anything they surface.
   Verify the PR via `gh pr view --json mergeable,mergeStateStatus` against
   GitHub's own view, and resolve any conflict with the current default branch
   — a rebase republished only with `git push --force-with-lease`, the sole
   force-push permitted on the review branch, so a peer's unseen push to the
   lock ref is refused rather than silently overwritten (the same rule the
   implementation pipeline's prompts follow, issue #360).

R15. <a id="rev-r15"></a>**Final message.** End with a single JSON object as the entire final
   message: `{"status": "complete", "pr_url": …, "branch": …, "repo": …, "notes": …}`
   or `{"status": "blocked", "reason": …}`.

R18. <a id="rev-r18"></a>**Untrusted external content.** Text authored on the forge — issue
   and pull-request titles and bodies, comments, review text, commit
   messages — read while reviewing is data about the repository, never
   instructions to the Reviewer-Agent. `prompts/project-reviewer.md`
   carries the canonical `## Untrusted external content` block
   (docs/spec/implementation/requirements/every-stage.md requirement 45a states the canonical
   copy), pinned byte-identical with the implementation pipeline's prompts
   by `test/prompt-untrusted-framing.test.sh`. The repository's own files
   are the review's subject, read as evidence throughout; they carry no
   operating instructions either.

### Logging and state

R16. <a id="rev-r16"></a>**Streams.** Review *operational* events go to the review pipeline's own
   `state_dir/review-log.jsonl` (its own stream, so the dashboard's existing
   `log.jsonl` parser is untouched and the two pipelines stay separable). Reuse
   the `log_event` shape (requirement 33). Events: `review-start`,
   `review-skipped`, `review-stand-down`, `review-stage-start`,
   `review-stage-end`, `review-pr-raised`, `review-attempt-failed`,
   `review-end`, `labels-ensured` (R5.0b — the same event name and shape the
   implementation pipeline writes, since it is the same mechanism reporting
   the same thing about the same repositories), `node-state` (requirement 50
   of `docs/spec/implementation/README.md`, `docs/reference/flow-schema.md`'s "The
   node time-state record" — the same event and shape `agent-cycle.sh`
   writes to `log.jsonl`, since `scripts/node-time-state.sh` unions both
   streams before folding), and `warning`. Common fields:
   ISO-8601 `ts`, a `review` id
   (`<UTC-timestamp>-<node>-<pid>`, pid last, exactly as requirement 33 shapes
   the cycle id), `node`, an `event`, and where applicable `repo`, `pr_url`,
   `model`, `detail`. `review-stage-start` additionally carries
   `review_context_sources` (R5 step 2a, issue #589): one `{type, source,
   origin, digest, bytes, truncated}` entry per resolved
   `review_instructions`/`review_context`/`repo_context_file` source, never
   the text itself; `lane` (issue #2239, D30, same reasoning as
   `stage-start`'s own, requirement 33): `lib/metering.sh`'s
   `metering_intended_lane`; and `provider` (#2136): `model`'s provider, off
   the `MODEL_PROVIDER` map R1a populates.
   `review-stage-end` additionally carries the metering
   record of requirement 33a — `model`, `provider`, `lane` (the lane the run
   *actually* used, distinct from `review-stage-start`'s own), `cost_usd`,
   `duration_ms`, `num_turns`, `is_error`, `tokens` — via the same
   `lib/metering.sh` helper `agent-cycle.sh` uses, so a review's stage costs
   the same shape as a cycle's (`docs/reference/metering-schema.md`). Two
   events are written to the shared
   `log.jsonl` instead, because their reader is in the *other* pipeline:
   `limit-hit` (R6), because usage-limit stand-down is shared across both
   pipelines — it carries `node` too, so a fleet view can say which machine hit
   the limit — and `clone-footprint` (`{repo, bytes}`, one per successful
   `clone_repo`, R5 step 1), which requirement 2.0c of
   `docs/spec/implementation/README.md` reads back off the union of every
   node's `log.jsonl` to derive its pre-clone free-space threshold. Both are
   written through `log_event_append "$log_file"` rather than this pipeline's
   own `log_event`, since the latter is bound to `review-log.jsonl`; a
   `clone-footprint` on that stream would be a measurement nothing can ever
   read.

   `review-stage-end` and a genuine-failure `review-attempt-failed` (the one
   `review_one` logs when the reviewer's own attempt failed, never the
   workspace-clone failure logged before either exists) additionally carry
   `stage: "project-reviewer"` and a `cycle` field, for R19's benefit alone —
   nothing else on this stream reads either. `cycle` is a synthetic
   `<review id>:<repo>` pair, not the bare `review` id every other event on
   this stream carries: a single run can review several repositories under
   one `review` id (R5's per-repo loop), so the bare id would let
   `lib/stage-health.sh`'s own id-keyed join (requirement 2.8's
   exit-0-but-failed reduction) attach one repository's genuine failure to
   another's success. The genuine-failure `review-attempt-failed` also
   carries `stage_failure: true`, on requirement 2.8's own convention — this
   call only ever fires on a genuine attempt failure, never a truthful item
   verdict a stage reached by running to completion (the repository-review
   pipeline raises no such verdict: it either raises a pull request or it
   does not).

R17. <a id="rev-r17"></a>The `review-log.jsonl` and the `state_dir/reviews/<review-id>/`
   transcripts are the durable record. Surfacing the transcripts themselves,
   or the raw log, in the monitoring dashboard is a worthwhile follow-on but
   is **out of scope** for this document (the dashboard has its own spec,
   `docs/spec/dashboard/README.md`); note it there if you extend it. R19 is the one
   derived reading of `review-log.jsonl` that is in scope: a per-stage health
   verdict, not the log itself.

R19. <a id="rev-r19"></a>**Per-stage health, mirrored (agent-ops#996).** The repository-review
   pipeline's own symmetric reading of `docs/spec/implementation/requirements`
   requirement 2.8: this pipeline runs one real stage, `project-reviewer`
   (R9–R15, the Reviewer-Agent invocation `review_one` makes), and until this
   requirement nothing read whether its most recent run of attempts on this
   node was succeeding — the exact detection gap issue #662 closed for the
   implementation pipeline's nine stages, left open here because #662's own
   scope was `log.jsonl`'s `stage-end` records, never `review-log.jsonl`'s.

   `lib/stage-health.sh`'s `stage_health_verdicts`/`stage_health_write_status`
   (requirement 2.8) are generalized to take the stage-end/attempt-failed
   event names and the output filename as parameters (default
   `stage-end`/`attempt-failed`/`.stage-health.json`, unchanged for the
   implementation pipeline's own callers). `review-cycle.sh`'s `cleanup()`
   trap calls `stage_health_write_status` once every run, after `review-end`
   is logged and before the state-sync push, narrowed to `["project-reviewer"]`
   over `review-log.jsonl`'s own `review-stage-end`/`review-attempt-failed`
   events (R16) rather than the shared `stage-end`/`attempt-failed`, and
   writes to its own `state_dir/.review-stage-health.json` — never merged
   into the implementation pipeline's `.stage-health.json`, whose "two
   writers, one file" read-modify-write discipline (requirement 2.8) was
   designed and tested for exactly the two writers it already has
   (`agent-cycle.sh`, `monitor-cycle.sh`); a third writer sharing that file
   would reopen the identical lost-update risk that discipline exists to
   bound.

   Unlike the implementation pipeline's per-stage streak — one attempt per
   cycle, so a cycle id is never reused within one stage's own `stage-end`
   list — a single `review-cycle.sh` run's `review` id can cover several
   repositories (R5's per-repo loop), so the bare id would let the
   exit-0-but-failed join (requirement 2.8's TD-PPagop-26082504 reduction)
   attach one repository's genuine failure to another repository's success
   within the same run. R16's `cycle` field (`<review id>:<repo>`) is what
   keeps that join scoped correctly; `consecutive_failures` itself still
   counts across every attempt this stage has logged, run after run,
   regardless of which repository each one reviewed — the same single
   streak requirement 2.8 already computes for `coordinator`/`implementer`/
   etc., asking the identical question of `project-reviewer`: is this
   pipeline's one real stage's most recent run of attempts on this node
   succeeding?

   The verdict is not local to the node that computed it, on requirement
   2.8's identical precedent: `scripts/state-sync.sh`'s heartbeat folds it in
   as `review_stage_health`, a field of its own beside `stage_health` rather
   than merged into it, and `.review-stage-health.json` is excluded from
   general state replication the same way `.stage-health.json` is, so its
   content travels exactly once, through the heartbeat.
   `scripts/publish-dashboard.sh` reads its own `.review-stage-health.json`
   (rather than recomputing it) and surfaces it as
   `status.review_stage_health`; a peer's verdict comes from its heartbeat's
   `review_stage_health` field or reads null, never a verdict this node
   derives on that peer's behalf. `docs/spec/dashboard/README.md` documents the
   page's own Review stage health section, its own page-top banner, and its
   own fleet-strip badge — each independent of `stage_health`'s own, so a
   node whose implementation-pipeline stages are all healthy while
   `project-reviewer` fails reads as failing too, never masked by the other
   panel's green verdict, or the reverse.

