## Acceptance checks

### Acceptance checks — continued (part 6 of 6; items 51–52b)

51. **The pager framework files once per firing key, closes once the fact
    clears, and never twice for the same transition (requirement 51).**
    `test/pager.test.sh` drives `lib/pager.sh` directly, against fixture
    union logs built inline the same way `test/crash-loop-escalate.test.sh`
    does, with `gh`/`lib/claim.sh` stubbed as shell functions: a fire →
    re-evaluate → clear sequence over one `pipeline-act` invariant asserts
    exactly one `pager-fired` and, once the stub's eval function reports
    clear, exactly one `pager-cleared` — never a second of either on a
    third, fourth or fifth re-evaluation while the state is unchanged; a
    candidate that stops firing before `pager_min_firing_minutes` elapses
    logs `pager-candidate-cleared` and never reaches `pager-fired` at all;
    and one test per remedy class confirms what each one actually does —
    `pipeline-act` calls the registered remedy function and embeds its
    return value in the issue body, `config-lever` files a second, separate
    `pw::decision` issue via the closed-immediately convention alongside the
    ordinary tracking issue, and `owner-only` assigns the tracking issue to
    the configured assignee and no other class does. `test/pager-invariants.
    test.sh` drives `lib/pager-invariants.sh`'s two built-ins against fixture
    heartbeat sets: `verdict-unanimous` fires on a `stage_health` stage
    failing on every active (non-stale) node, on `updater.status: "stuck"`
    fleet-wide, and on `doctor.verdict: "fail"` fleet-wide, but not when
    only some nodes agree, not when fewer than two nodes are active, and not
    when a stale node's own disagreement would otherwise break the
    unanimity; `page-outlived-item` fires when a stubbed `gh issue
    list`/`gh pr view` shows an open page's own linked PR merged or closed,
    and its remedy closes exactly the pages found outlived, none still
    open. The same file also drives agent-ops#1282's five peer-vantage
    invariants against fixture union logs and heartbeat sets:
    `firing-missed` fires on an active node whose newest `cycle-start` or
    `cycle-skipped` is past 2× a configured interval with no lock held, but
    not on a node that recently cycled, not on one whose heartbeat is itself
    stale, not on one whose own last event is an unmatched `cycle-start`
    (still holds its lock) however old, not on one whose long-running
    cycle-start is trailed by a recent `cycle-skipped` — proof its scheduler
    kept ticking and correctly deferred — even though that skip is not
    itself a lock hold, and not on one whose published `role` is a
    standby's however old its newest cycle event — including a raw
    `"STANDBY "`, since the role is read normalised. Five nodes sharing
    that one ancient history and differing only in the role their row
    publishes pin the rest of the matrix: `"Active"` is named (requirement
    2.4 runs cycles on it, so a peer must not read it as a standby),
    `"unknown"` and a row carrying no `role` field at all are named too (no
    evidence of a standby is not evidence of one), and the same node
    republished as `active` fires — the exemption is by role, not by name
    or history. The registration case beside them pins the filing window
    that keeps that last case from paging an ordinary promotion:
    `schedule.cycle_interval_minutes` plus fifteen minutes, derived from
    the configured interval rather than fixed, and absent altogether when
    no interval is passed, leaving `node-stale`'s own override untouched.
    Evidence carries the firing node's own cycle-duration histogram; `node-stale` fires only on a row whose
    `heartbeat_age_s` exceeds 2× the configured threshold; `updater-stuck`
    fires only on a live row reporting `updater.status: "stuck"` past 2×
    the configured threshold, never a stale row's; `review-pipeline-failing`
    fires on a per-node streak of 3 or more failed review runs *each of
    which ends in a `review-end` reporting `exit_code: 0`* — the shape
    `review-cycle.sh` actually writes, and the one a reader reducing over
    raw events would silence itself on — resets on a run that completed a
    review, is left untouched by a stood-down run between two failures, and
    its evidence names agent-ops#996's own `project-reviewer` verdict — the
    per-node reading this invariant is the fleet-vantage alarm for — and
    counts runs rather than events;
    `dashboard-unreadable` fires
    on a row whose `dashboard_fetch` names a slow fetch or a failed parse,
    never on a row carrying no probe result at all. Each of the five also
    proves it never fires with its own threshold unconfigured (an empty
    `PAGER_EVAL_*` variable). `test/pager.test.sh` additionally proves
    `pager_register`'s new, optional fifth argument records against the key
    (empty when omitted) and that a key registered with an override ignores
    `pager_evaluate`'s own shared `MIN_FIRING_MINUTES` entirely.

    The same file also drives agent-ops#1281's seven selection/ledger
    invariants against fixture union logs (`lib/refinement.sh`/
    `lib/cycle-state.sh`/`lib/label-marker.sh`/`lib/pipeline-marker.sh`/
    `lib/escalation-autonomy.sh` sourced alongside, for the three that call
    their own real detection/remedy functions rather than a
    reimplementation) and a shared, extended `gh` stub (`issue edit`, `issue
    comment` and `api` added to the existing `issue list`/`issue create`/
    `issue close`/`pr view`/`issue view` cases): `idle-with-demand` fires on
    an active node whose last `pager_idle_cycles` cycles all *ended*
    `idle-with-demand` — against a fixture carrying the `overhead`
    transitions a real cycle logs alongside its terminal one, so that an
    invariant reading raw events rather than per-cycle terminals cannot pass
    here while never firing in production — excludes a node whose own streak
    is `back-pressure` throughout, excludes a node whose streak is broken by
    a cycle that ended `idle-without-demand`, decides nothing from fewer
    than `pager_idle_cycles` cycles however many events they carry, stops
    firing on that same streak the moment the node's row publishes a
    standby's role, and never fires with `pager_idle_cycles`
    unconfigured, with its evidence carrying the node's own `none-selected`
    reason and `coordinator-input-fitted` detail; `fit-ladder-pinned` fires
    on a node whose every `coordinator-input-fitted` event in the trailing
    24h sits at rung 17 with entries dropped *and* on one pinned at rung 11
    (the first entry cap, #1128's own shape renumbered), with its evidence
    naming that node's rung and drop range, not on a node that came back up
    to a prose rung within the window, not on a node whose every cycle sits
    on the identity-only rung 10 dropping nothing, and not on a fitted event
    outside the trailing 24h; `work-order-repaired-rate` fires when the fleet-wide ratio
    of `work-order-repaired` to `selection` events in the trailing 24h
    exceeds `pager_repair_rate_percent`, not below it, and never on a window
    with zero selections; `blocked-label-orphaned` fires on an
    `own-label-action add` with no later `remove` whose item has since
    cleared, its remedy calls a stubbed `issue edit --remove-label` and
    reports a failing removal rather than dropping it silently, and it does
    not fire against a union log carrying no blocked-label history at all;
    `claim-unreconciled` fires on an `enabler-examined` event reading
    `outcome: "escalate"` with no matching `escalated` in the same cycle,
    does not fire once a matching `escalated` event is added, does not fire
    on an `escalation-failed` outcome (which never claimed to escalate),
    does not fire on a claim older than the trailing 24h and posts no
    correction comment for one, and
    its remedy posts a stubbed `issue comment` naming what could not be
    confirmed; `escalation-burst` fires once the fleet-wide `escalated`
    count in the trailing 24h exceeds `pager_escalation_burst`, and,
    independently, when the same `attempt-failed` `detail`/
    `unblock_condition` fingerprint pages the same item twice regardless of
    the count threshold, with evidence naming the reflagged item, but not
    when that same pair of pages sits outside the trailing 24h; and
    `digest-truncated` fires when a `source-state-digest` event's own counts
    fall short of a stubbed `gh api search/issues` total bound to that
    event's own `ts` via a `created:<=<ts>` qualifier, not when the two
    agree as of that same `ts`, and not when a live total only exceeds the
    digest in an unbound "right now" query while matching it as of the
    digest's own `ts` — the #1348 false-positive the bound exists to
    prevent, where ordinary traffic created more issues/PRs after the
    digest was captured; its remedy logs a `digest-truncation-veto` event
    naming the affected repo (parsed from the evidence's own repo token,
    never re-deriving the live counts), and it never fires against a union
    log carrying no `source-state-digest` event at all.

    The same file also drives agent-ops#1280's three landing/approval
    invariants, a `pr list` case added to the shared `gh` stub, answering per
    the `-R` repository the call actually names (mirroring the existing
    per-label answering `issue list` already does) so a fixture can give two
    repositories two different pull-request listings: `landing-never-armed`
    fires on a repository named in `PAGER_EVAL_REPOS_JSON` at
    `agent-merges-routine` with `landing-refused` events but no
    `landing-armed` event in the trailing `pager_landing_armed_within_days`
    window, with evidence naming its own refusal-class histogram, its remedy
    filing a stubbed `pw::type:tech-debt` issue naming that histogram; does
    not fire on a repository at `human`, on one with a `landing-armed` event
    inside the window, or on one with no `landing-refused` activity in the
    window at all (nothing ready to land is not this incident); and does not
    fire with `PAGER_EVAL_REPOS_JSON`/`PAGER_EVAL_LANDING_ARMED_WITHIN_DAYS`
    unconfigured.
    `landing-refused-unknown` fires when a trailing-24h window's
    `landing-refused` events are at least half class `unknown` (split on the
    reason's own first colon) with at least five; it does not fire when
    either bound alone is missed — four `unknown` of six total is at or
    above half but under the five-event floor, five of eleven clears the
    floor but is under half, so the two bounds are exercised independently —
    nor on the same qualifying shape dated outside the trailing 24h at all;
    its remedy files a stubbed `pw::type:tech-debt` issue. `pr-unreviewed` fires on a stubbed `pr list` naming a ready,
    non-draft, `pr_label` pull request older than
    `PAGER_EVAL_APPROVER_UNREVIEWED_ENGAGE_AFTER_HOURS` with an empty
    `reviewDecision` and no `approver-verdict`/`approver-unreviewed-engaged`/
    matching `warning` event in the union log; does not fire on a draft, on
    one younger than the cutoff, on one whose `reviewDecision` already names
    a standing decision, or on one already carrying any of the three
    disqualifying union-log events; its remedy logs a fresh
    `approver-unreviewed-engaged` event (`result: "unavailable"`) for every
    candidate found, re-deriving the candidate set live rather than parsing
    the evidence string, and reports how many it enqueued.

    `scripts/render-config-table.sh --check` passes with
    `pager_stale_file_after_minutes`/`pager_dashboard_fetch_seconds`/
    `pager_idle_cycles`/`pager_repair_rate_percent`/`pager_escalation_burst`/
    `pager_landing_armed_within_days` added. `scripts/lint-shell.sh` is
    clean on every file this requirement touches.

9. **An open question the Reviewer could not settle holds unattended landing,
   resolves through the configured ladder, and never through a new commit
   alone (requirement 8f, agent-ops#668).** `test/landing.test.sh` passes
   against a stubbed `gh`: `landing_open_question_hit` reads `hit`/`clear`/
   `unknown` off a pull request's own labels, fresh every call, never a
   log join; `landing_open_question_label_project` mirrors `refinement_
   label_project`'s own `added`/`present`/`unrecorded`/`failed` vocabulary
   and exit status exactly, never removing a label it finds already present;
   `landing_open_question_label_release` removes only the fixed
   `open-question` label; `landing_open_question_latest` reads every
   question a pull request's own `open-question-raised` events carry off a
   synthetic log, filtered to a high-water mark first — only events logged
   at or after the most recent `settled`-verdict `open-question-adjudication`
   event for that pull request survive, or every event if none has settled
   yet — then deduplicated by question text across whatever rounds remain,
   never only the most recent round's, so a second round's further question
   never drops a still-unsettled first one, while a question a prior round
   already settled never resurfaces; `[]` when none is on it.

   `test/landing-wiring.test.sh` lifts the modified `_landing_stage_attempt`
   verbatim and proves the new gate sits between eligibility and the review
   gate: a `clear` label leaves every existing case in this file passing
   unchanged (no new stub defaults it); an `unknown` label read refuses with
   its own reason, naming no escalation issue and running no adjudication,
   since an unreadable label list is a plain retryable failure, not a
   confirmed question; a `hit` at `escalation_autonomy: "always-escalate"`
   refuses with an `open-question:`-prefixed reason (grouped by the
   *Autonomous landings* panel's existing `byReason` split, `docs/DASHBOARD-
   SPEC.md`) and calls `open_question_escalate` exactly once; a `hit` at
   `adjudicate-first` with `run_open_question_adjudication` stubbed to
   return `settled` releases the label, posts the PR comment, logs
   `open-question-adjudication` with `verdict: "settled"`, and **arms** —
   the gate clearing on its own round, no second read required, with the
   landing audit record's own `open-question` gate reading `settled` there
   and `clear` on the round where no question ever stood
   (`test/landing-audit-record.test.sh` pins the latter alongside every
   other gate); the same
   stub returning `escalate` refuses and escalates exactly as
   `always-escalate` does; a pull request already carrying an
   `open-question-adjudication` event on the log runs no further
   adjudication pass and escalates directly (`open_question_pass_available`'s
   own bound), unless a closed escalation issue for its `pr-<n>-
   open-question` reference stands, in which case one further pass runs.
   Replaying agent-ops#652's own shape — `complexity:low`, an open question
   standing — does not arm, the regression this requirement exists to close.
   The same file's `run_case_direct` proves requirement 8u's retry sweep
   reaches the identical gate, never a second copy of it: `_landing_stage_
   attempt` called directly with `RETRY` set — exactly as `_landing_retry_
   sweep_repo` calls it — refuses on the same `open-question:` reason with no
   stubbing beyond what the gate-0 path above already exercises, since both
   entry points share one function body. `test/landing-retry-sweep.test.sh`
   itself stubs `_landing_stage_attempt` as a black box (it tests candidate
   selection, not gate behaviour), so it is unaffected by this gate and needs
   no change.

   `test/open-question-adjudication.test.sh` lifts `run_open_question_
   adjudication`, `open_question_escalate`, `open_question_pass_available`
   and `open_question_adjudicated_before` verbatim out of `lib/landing.sh`:
   the adjudication prompt launches at `approver_model_critical`, never
   `enabler_model` or `approver_model_default`/`approver_model_complex`,
   against `prompts/approver-adjudicate-open-question.md`, never
   `prompts/approver.md` or `prompts/enabler-adjudicate.md`; a missing
   prompt file, a stage failure, a timeout and an unparseable verdict all
   print `escalate` with a distinguishing `evidence` string, never
   `adequate`/`inadequate` (requirement 36b's own vocabulary) and never
   `land`/`refuse`/`escalate` unadorned (requirement 8c's own, which also
   accepts `escalate`, but never emits `settled`); `open_question_escalate`
   composes an issue body naming the question text from a synthetic log's
   `open-question-raised` event and keys `create_escalation_issue`'s dedup
   on a `pr-<n>-open-question` reference, distinct from `pr-<n>-approver-
   adjudication` (requirement 8c) sharing the same pull request number.
   `test/prompt-untrusted-framing.test.sh` (requirement 8z) covers
   `prompts/approver-adjudicate-open-question.md` alongside every other
   shipped stage prompt. `test/dashboard-render.test.sh` (requirement 8x)
   asserts an `open-question:`-classed refusal in a fixture renders as its
   own `byReason` group, exactly as `ineligible`/`kill-switch` already do,
   with no `dashboard/index.html` change required to produce it. No test
   name, event name, label name or prompt filename this requirement adds
   contains `human` (requirement 45's own framing, extended by
   agent-ops#679) — `open-question`, `open_questions`, `open-question-
   raised`, `open-question-adjudication`, `open-question-escalated` and
   `approver-adjudicate-open-question.md` all name the question, never
   where it goes.

   `test/open-question-cycle-wiring.test.sh` lifts `agent-cycle.sh`'s own
   requirement 8f block verbatim — from the `open_questions` read through
   the landing arming call — and proves the regression agent-ops#889 found:
   with `landing_open_question_label_project` stubbed to print `failed` (or
   `unrecorded`) and exit 1 on every call, the block still logs
   `open-question-raised` with the truthful `label_projection`, still runs
   the `failed` branch's self-heal (`refinement_label_ensure_one`,
   agent-ops#687), and still reaches both `run_approver_stage` and
   `run_landing_stage` — an unguarded `oq_proj="$(…)"` regressing to the
   pre-#889 behaviour would abort the block before either stage call and
   this test would fail with no `run_approver_stage`/`run_landing_stage`
   call recorded and no trailing marker proving the block ran to its own
   end.

10. **The egress fence holds its shape (D24).** `test/egress-fence.test.sh`
    passes: the baked allowlist carries every domain the cycles need
    (`codeload.github.com` and `ghcr.io` included — the two no grep of the
    source would find), the squid config is default-deny with CONNECT-to-443
    the only allow, the scheduler sits on the internal-only `egress` network
    with the proxy variables and Claude-Code opt-outs in its environment,
    `egress-proxy` bridges exactly `[default, egress]`, and
    `egress-proxy-start.sh`'s merge behaves — run for real against a stub
    squid. The build additionally runs `squid -k parse` over the shipped
    config (deploy/docker/Dockerfile). The *live* fence is deliberately not
    asserted here: the suite runs inside one container and cannot stand up
    Docker networks, so per-node enforcement is `scripts/doctor.sh`'s Egress
    probes' job, on every unattended run.

51. **Overrun-slot skips are computed and logged correctly (requirement 11a,
    agent-ops#1287).** `test/schedule-slots.test.sh` passes:
    `lib/schedule-slots.sh`'s `schedule_overrun_slots` names exactly the
    slots of the series running forward from the span's own start minute
    that fell strictly inside a fixture `[start, end]` span for a given
    `schedule` block, including a fixture cycle spanning two slots
    (asserting both `slot_ts` values), a span crossing an hour boundary, a
    span crossing midnight, an hour `cycle_hours` excludes entirely, and an
    unparseable start printing nothing rather than failing; `agent-cycle.sh`'s
    own cleanup-time call site, lifted verbatim out of the script (the same
    extraction `test/finish-then-continue.test.sh` uses), logs one
    `cycle-skipped {reason: "overlap", slot_ts, held_by, elapsed_s}` per slot
    returned, only when `lock_acquired` is `1` and the cycle is the cron-fired
    original — logging nothing for a chained cycle (`chain_count` above 1) or
    for a `--once` or `--dry-run` run, whose slots the contending tick already
    records; and `lib/manage.sh`'s
    `overlap_status_report` counts only this node's own last-24h
    `reason: "overlap"` events, ignoring the `reason`-less lock-contention
    `cycle-skipped` shape, counting the events either side of a spliced line,
    reading zero for a log not yet written, and printing `unreadable` and
    reporting through `guard_warn` when the read fails outright. `test/publish-dashboard.test.sh`'s "Overrun-slot
    skips are counted alongside, never folded into total" fixture confirms
    `noop_ticks.overlap` counts a working cycle's own overlap events without
    removing its row from `cycles[]` or inflating `noop_ticks.total`; and
    `test/dashboard-render.test.sh`'s `overlap-only.json` fixture confirms
    the page's summary line renders the overrun count even when
    `noop_ticks.total` is `0`.

52. **The table of contents is generated from headings, and regenerating it
    is gated (requirement 52, component 24).** `scripts/render-toc.sh` with
    no arguments run against this repository's own
    `docs/spec/implementation/README.md` and each guide under
    `docs/guides/` leaves every file byte-identical
    to what is committed — regenerating a clean tree is a no-op — and
    `--check` exits 0 against it; `git diff` confirms nothing moved.
    Renaming a heading without regenerating makes `--check` exit non-zero
    naming that file; regenerating repairs it. Every generated link
    resolves to a real in-document anchor, matching GitHub's own
    heading-anchor algorithm exactly rather than an approximation of it —
    in particular, a heading whose removed character (`&`, `—`) leaves two
    adjacent spaces behind renders two hyphens, not one, since GitHub does
    not collapse consecutive hyphens either. `.github/workflows/toc.yml`
    runs `--check` on every pull request, so a heading edited without a
    matching regeneration fails CI rather than leaving a stale or broken
    link. Deleting a target file's marker pair entirely, leaving only one
    of `<!-- toc:start -->` / `<!-- toc:end -->`, or leaving both markers
    but with `toc:end` on an earlier line than `toc:start`, makes both the
    plain and `--check` invocations exit non-zero naming that file, rather
    than leaving the file byte-identical and `--check` exiting 0 against a
    region that no longer exists (or, in the reversed case, silently
    corrupted); `test/render-toc.test.sh` exercises all of these
    marker-validation cases against the real script.
52a. **The documentation benchmark's questions hold, and its runner
    measures what it says without launching anything in the test
    (requirement 52a, components 24 and 24a).**
    `scripts/docs-benchmark.sh --check` exits 0 against this checkout, as
    `.github/workflows/docs-benchmark.yml` runs it on every pull request,
    and `test/docs-benchmark.test.sh` passes:
    - `test/docs-benchmark/questions.jsonl` holds at least 48 records, at
      least eight per reader, each well formed, with each fact's backticked
      tokens in its gold answer. The validator rejects each defect it exists
      for, against a fixture tree, including a component or actor cited as a
      requirement, a label inside an indented fence, a fact that begins with
      a list number and a locator holding a tab, and finds a heading that
      holds a backslash; `--check` passes and fails against the same tree.
    - The protocol hash moves when a time cap, an effort, the classification
      of an unanswered question or the borrowed token count changes, and not
      for a comment, a change to the question check or a change elsewhere in
      a borrowed library. The protocol's lists hold every function and
      variable that their functions use, and every function and variable of
      the library is on them or deliberately off them. The questions hash
      ignores sources and the order of the records.
    - A checkout leaves out every benchmark path, naming each, and leaves no
      `.git`; the runs lose every variable that changes the model's
      behaviour and keep those that signing in needs.
    - The grader's verdict is read from a recorded grading transcript and
      from variants of it: prose with braces around the object, an unclosed
      brace before it, a worked example before it, facts in another order
      (matched by text, with the missing fact attributed correctly) or
      echoed with list numbers, echoed facts that are not the question's
      (ungraded), an absent overall verdict (not an inconsistency), a reply
      with no JSON, a 48 KB reply full of braces (read within 30 seconds),
      an error result and a torn stream. A run stopped at its cap by TERM,
      or by KILL after it, is said to have been; one killed before its cap
      is not.
    - The report renders from canned records with each table row's column
      count matching its header, a pass rate over graded questions only,
      the comparability rule with the Claude Code version in it, and the
      ungraded and inconsistency sections; the description of a run that
      did not finish renders with how far it got.
    - `--dry-run` lists every question and launches and writes nothing.
    - The whole script, run against a stub `claude` and a local source,
      asks nothing in a tree that holds a `*docs-benchmark*` path or a
      `.git` or whose path names the benchmark, nor with a cleared variable
      set; records a pass, a fail naming its missing fact, and an answer and
      a grading each stopped at its cap; exits 1 for the questions it could
      not grade; names a second full run `-2` and a one-question run
      `-only-<id>`; exits 3 without claiming success when the report cannot
      be written, naming files from which it renders again; on a Ctrl-C to
      its process group exits 130 at once, stops the question in flight,
      asks nothing more and leaves records that render as unfinished; exits
      2 and writes nothing when `timeout`, `sha256sum` or `git` is missing;
      and with `--calibrate` exits 1 naming the fact a gold answer lacks.

    `test/markdown-scan.test.sh` passes: `markdown_unfenced` keeps a tilde
    line inside a backtick fence (and the reverse) or a shorter run inside a
    longer one as content, treats an indented fence as a fence and a
    backtick run with another backtick on its line as inline code, runs an
    unterminated fence to the end of the file, and closes a fence in a file
    with CRLF line endings; and `markdown_unfenced_numbered` keeps the same
    lines, each tagged with its line number in the file.

57. **Node health, readiness and liveness (requirements 57-60, issue #608).**
    `test/node-health.test.sh` passes: `lib/node-health.sh`'s
    `node_health_fold` composition rule (fail beats unknown beats ok, empty
    input reads unknown), `node_health_liveness` (no marker, a fresh marker,
    an aged-out marker, a future mtime clamped to zero age), the
    `outbound`/`updater`/`image` component mappings of requirement 59a
    against every named status (including "behind" both within and past
    `image_behind_grace_hours`, and with an unreadable `registry_created_at`),
    `node_health_converged` and `node_health_health`'s composition —
    including, for acceptance criterion 4, health reaching `unknown` when
    neither #602's nor #603's own field has ever been published, then `ok`
    and `fail` once fixture stand-ins for both exist — and
    `node_health_readiness` naming every one of the eight conditions
    requirement 58 enumerates by its own stable code, an unreadable local
    meter never blocking readiness on its own, and every simultaneously
    failing condition reported together rather than only the first. It also
    holds every component and `node_health_health` itself to requirement
    59's "one valid object, never a non-zero return" contract against input
    that does not parse as JSON at all — a heartbeat truncated by a
    container killed mid-write — as well as against a bare scalar, an array
    and the empty string, each of which must read `unknown`.
    `test/node-health-cli.test.sh` passes: `scripts/node-health.sh` is
    read-only end to end (a fixture `state_dir`/`workspace_root` unchanged,
    file for file, across every mode, excepting only the documented
    rate-limit cache), a single fixture proves the node simultaneously live,
    not-ready and unhealthy across three separate calls, liveness stays true
    while a cycle holds `lock.json` and false once the marker is removed,
    `--health`'s three exit codes (`0`/`1`/`2`) are distinct for `ok`/`fail`/
    `unknown`, and `--metrics` carries every field requirement 60e documents;
    with a `gh` stub on `PATH` it also asserts requirement 58a's own
    arithmetic — that `--ready` reads *both* budget figures out of the forge
    response, that one poll makes exactly one forge call, and that a second
    poll inside the TTL makes none. `test/node-health-http.test.sh` passes:
    `scripts/node-health-server.py`, started on a free port against a
    fixture `HOME`, answers all four documented paths with requirement 60d's
    own status codes and a JSON body on each (including the `503` halves),
    `404`s every other path — a trailing slash, a query string and a
    traversal attempt among them — and still answers `/healthz` with valid
    JSON reading `unknown` while `state_dir` is unreadable (acceptance
    criterion 8), rather than hanging or stack-tracing.
    `test/render-crontab.test.sh` passes unchanged with the new liveness-
    marker line in `deploy/docker/crontab.tmpl` (requirement 57), and
    `test/state-sync.test.sh` asserts the two new node-health caches
    (`.node-health-ratelimit-cache.json`, `.node-alive`) do not replicate
    (requirements 58a and 57 respectively). `docker compose config` (in `deploy/docker/`) renders
    the scheduler's new `healthcheck:` and the new `node-health` service
    cleanly. `scripts/lint-shell.sh` is clean over every new/changed shell
    file; the new `scripts/node-health-server.py` is syntactically valid
    Python 3.

55. **Resource usage is self-measured, both cgroup layouts are handled, and
    a budget breach is reportable (requirement 55, D14, issue #606).**
    Against a v2 cgroup fixture (`cgroup.controllers`, `memory.current`,
    `cpu.stat`), `resource_memory_current_bytes`/`resource_cpu_usage_nanos`
    read the same figures a real container's own `/sys/fs/cgroup` would
    carry; against a v1 fixture (`memory/memory.usage_in_bytes`,
    `cpuacct/cpuacct.usage`) they read the same figures from the legacy
    layout; against a directory carrying neither marker they read empty,
    never a fabricated `0` — `test/resource-usage.test.sh` exercises all
    three. `resource_cpu_cores`/`resource_rate_per_hour` given a later
    cumulative value smaller than the earlier one (a simulated container
    recreation) print nothing rather than a negative rate. `scripts/collect-
    resource-usage.sh --config … --service scheduler --cgroup-root … --net-
    dev-file … --now …`, run twice five minutes apart against fixtures whose
    counters advance between calls, appends a first sample with no
    `cpu_cores`/`net_*_bytes_per_hour` (no baseline yet) and a second
    carrying the correct delta-derived figures — `test/collect-resource-
    usage.test.sh` computes the expected numbers by hand and asserts them
    exactly. The same fixture run twice inside `resources.
    disk_sample_interval_minutes` samples disk once, not twice; run again
    past that interval, it samples again. `resource_budget_report` given a
    canned six-line sample set (one malformed) reports `sample_count: 5`,
    the correct `{latest, median, p95}` per numeric field (nearest-rank,
    asserted against hand-computed values) and the correct
    `growth_bytes_per_day` for a two-point disk series; given no input at
    all it reports `{"containers":{},"volumes":{},"sample_count":0,
    "window_start":null}`, never a jq failure. `resource_budget_breaches`
    given a report and a budget object reports no breach for a figure
    exactly at the budget or just under it, and exactly one breach for a
    figure just over it, naming the container/volume, the resource, the
    measured figure and the configured budget; given an unbudgeted
    container it reports nothing for that container regardless of usage.
    `scripts/doctor.sh --config … --offline` against a fixture samples file
    whose `scheduler` CPU and memory figures and `workspace_root` disk usage
    all exceed the (default-shipped) `resources` budgets prints three
    `[warn]` lines under "Resource budgets", each naming the
    container/volume, the resource, the actual figure, the budget and the
    `config.json` key that states it, and says nothing about the resources
    still within budget; against a fixture within every budget it prints one
    `[ ok ]` line naming the sample count and window and no breach warning at
    all; against a node with no `.resource-samples.jsonl` yet, and against
    one whose every sample predates `resources.report_window_hours`, it
    prints `[skip]` naming the file — `test/config-schema.test.sh` exercises
    all four, alongside every other `doctor.sh --offline` assertion
    (`test/doctor.test.sh`'s own header records why the offline half lives
    there). `deploy/docker/render-crontab.sh` against a
    config naming `schedule.resource_sample_minutes` renders
    `*/<N> * * * * /app/scripts/collect-resource-usage.sh …` with no
    `@RESOURCE_SAMPLE_MINUTES@` placeholder surviving — `test/render-
    crontab.test.sh`'s own "no placeholder survives a render" and
    "supercronic accepts the rendered schedule" assertions cover it
    alongside every other cadence. `scripts/resource-budget-report.sh`
    against a state directory with no samples file at all prints the
    identical empty-report shape rather than erroring, and `--state-dir`/
    `--window-hours`/`--now` each override what `config.json` would
    otherwise supply — `test/resource-budget-report.test.sh` exercises all
    four.
52b. **The documentation's links, map, size, citations and phrasing are
    checked, and each check fails on a fixture built to break it
    (requirement 52b, components 24 and 24b).** `scripts/check-docs.sh
    --check` exits 0 against this checkout, as `.github/workflows/docs.yml`
    runs it on every pull request, on `merge_group` and on push to `main`.
    `test/check-docs.test.sh` passes: a clean fixture repository reports all
    five checks ok and exits 0, and a fresh copy of that repository, broken
    one way at a time, exits non-zero naming the defect — a relative link to
    a file that does not exist, a document on disk the map never lists, a
    document padded past 100,000 bytes with no size-ratchet entry, a
    size-ratchet entry for a document that is exempt, missing or within the
    budget (one over it only by its generated region included), a size
    exemption that matches no document (the specification pattern, once the
    specifications move into a subdirectory of `docs/`, where they are then
    held to the budget), a citation reworded to name a heading that is not
    there, and a sentence of historical phrasing in a document with no
    phrasing-ratchet entry. Each of the four as-built specifications
    `AGENTS.md` lists, `CHANGELOG.md`, `docs/ROADMAP.md` and a review report
    at either depth under `docs/reviews/`, padded past 100,000 bytes with no
    entry, passes, and so does a document whose bytes past the budget all lie
    inside one generated region, of each kind, where `lib/markdown-scan.sh`
    lists it. The same bytes count as hand-written, and the document fails,
    when the region sits in a file or carries an id or fragment the library
    does not list, when a stamped region closes under another fragment's name,
    when it has no end marker, when its markers sit inside fenced code, and
    when it is a second copy of a listed region. A ratchet entry at a
    document's hand-written size holds it although a region with fenced code
    inside takes its whole size past the entry, and one more hand-written byte
    fails. A
    `#fragment` that no heading slugs to, but an explicit `<a id="…">`
    anchor in the target provides, passes — as `docs/concepts/glossary.md`'s
    own `#human-level` and `#no-op-cycle` links do, both of which sit over a
    heading that slugs to something else — while a fragment matching neither
    a heading nor an anchor still fails.

