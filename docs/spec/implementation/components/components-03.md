## Components

### Components — continued (part 3 of 3; 17e–24b)

17e. `scripts/roll-changelog.sh` implementing requirement 25e: with no
    marker present, renames the file's whole `[Unreleased]` section
    unchanged to the fixed migration heading and sets the marker to the
    fixed migration commit, running the assembler not at all; otherwise
    counts first-parent commits since the marker and, finding none, exits 0
    without touching the file, a branch or a pull request; otherwise runs
    `scripts/assemble-changelog.sh`, renames the result to today's UTC
    date, opens a fresh `[Unreleased]`, and pushes a commit to the fixed
    `changelog-roll` branch — force-pushed (`--force-with-lease`) over a
    prior run's own commit rather than opening a second pull request, first
    checking via `lib/merge-queue.sh`'s `merge_queue_probe` that an
    existing pull request, if any, is not currently queued.
    `<owner/repo>` defaults to the script's own `git remote get-url
    origin`; `gh`/`git` credentials resolve through the same on-demand shim
    (`lib/gh-shim.sh`) every other Script-side duty already uses, needing
    no separate wiring. Cadence is
    `schedule.changelog_roll_hour`/`_offset_minutes`/`_day_of_week`,
    rendered into one weekly crontab line by
    `deploy/docker/render-crontab.sh`; unit-tested against a fixture git
    repository and a stubbed `gh` (`test/roll-changelog.test.sh`); must pass
    `shellcheck`.
18. `scripts/sweep-closed-issues.sh` implementing requirement 17c's sweep:
    given a repo slug, a node name and a cycle id, lists that repo's merged
    `pr_label`-labelled pull requests (bounded to the most recently updated),
    and for each carrying an `agent-ops:closes-issue` marker whose named
    issue is still open and not `state_reason: "reopened"`, closes it with a
    `pipeline_comment_header`/
    `pipeline_comment_marker`-wrapped comment citing the merge as evidence,
    printing one JSON action per outcome (`closed`, `merge-observed`,
    `approver-escalation-retired`, `deferred`, `warning`)
    for the Script to log. Capped at three actions per repo per call, the
    overflow reported rather than silent. `SWEEP_GH` stubs `gh` for tests.
    Unit-tested (`test/sweep-closed-issues.test.sh`); must pass `shellcheck`.
19. `scripts/close-void-github-items.sh` implementing requirement 34k: given
    a repo slug, a node name, a cycle id and (on stdin) that repo's void
    candidates already filtered to the id shapes `lib/work-gone.sh` defines
    (a bare issue number, `pr-<n>-…`) and to what
    `void_object_closed_items` has not already processed, closes each still-
    open object with a comment carrying the void's `detail`/`evidence`,
    printing one JSON action per outcome (`closed` — `closed_by: "sweep"` or
    `"already"` — `deferred`, `warning`) for the Script to log as
    `void-object-closed`. The `pr-<n>-conflict-<head-sha>` and
    `pr-<n>-dequeued-<head-sha>` shapes are
    excluded from the pull-request case — each names a live PR the void says
    nothing about closing — and left untouched exactly like any other id
    shape; their sibling `pr-<n>-superseded-<head-sha>` (TD-PPagop-26081304)
    carries no such exclusion and closes through the ordinary `pr-<n>-…`
    branch. When the pull request being closed carries the human-applied
    `obsolete` label — re-checked live off the same fetch that reads its
    `state`, never trusted from the void's own claim — the close comment
    names it (TD-PPagop-26081308), so the close is auditable from the
    comment alone. The corroboration gate admits four stages: the three
    requirement 34d's guard covers (`coordinator`, `enabler`, `implementer`)
    and `decision`, requirement 36f's delegate-mandate act, whose
    corroboration is its own unpulled veto lever. Capped at three actions per call, the
    overflow reported rather than silent. `SWEEP_GH` stubs `gh` for tests.
    Unit-tested (`test/close-void-github-items.test.sh`); must pass
    `shellcheck`.
20. `lib/review-gate.sh` implementing requirement 31c: given a pull request
    URL and the repository's default branch, `review_gate_verdict` prints
    `clean`, `dirty<TAB>reason` or `unknown<TAB>reason` — every required
    status check green at the current head commit
    (`review_gate_required_checks`, `gh pr checks --required`, a pull request
    with no required checks treated as failing rather than vacuously passing)
    and no code-scanning
    alert carrying a security severity that the pull request's branch has and
    the default branch does not (`review_gate_security_alerts`, the base
    branch's own open alerts subtracted first so inherited debt never blocks a
    pull request that did not introduce it). `review_gate_required_checks`
    itself prints `clean`, `dirty<TAB>reason` or `unknown<TAB>reason` too
    (TD-PPagop-26081305): a pull request with no required checks, or a real
    failing check, is `dirty`; only `gh pr checks --required` failing to
    answer at all is `unknown` — and unlike every other `unknown` in this
    file, it still exits non-zero, refusing the handoff exactly like `dirty`,
    because an unread required-check list is never evidence of "nothing
    wrong". The first two of those reach it in the same shape, since `gh`
    reports a pull request with no required checks as an error (`no required
    checks reported on the '<branch>' branch`, returned before the `--json`
    payload is written) and not as `[]`, so the word is chosen from the
    diagnosis `gh` writes to stderr — which the call therefore captures rather
    than discards — and an unrecognised diagnosis is `unknown`, the
    conservative word, since both refuse the handoff. `review_gate_verdict`
    propagates that distinction through its own exit status: 0 when the
    verdict is `clean`, or `unknown` only because the security-alert read
    failed; 1 when the verdict is `dirty` with the required-check list read;
    2 whenever that list could not be read — whether the printed word is the
    blocking `unknown`, or a `dirty` the alerts check won over it
    (TD-PPagop-26081404): a real alert outranks an unreadable check list for
    the word and the reason, but the word alone would then falsely certify
    the required-checks read as having succeeded, so the read's own health
    travels in the exit status independently of which sub-check won. A
    caller must inspect this exit status rather
    than discard it, or it will silently let an unreadable required-check
    list through the same way it safely can for the alerts-only `unknown`.
    Keying on another tool's wording is a dependency, and `gh` is installed
    unpinned on a node, so the node image's build asserts it: both diagnoses
    are grepped out of the installed `gh` binary and a release that reworded
    either fails the build (acceptance check 1b), which is where a lost
    discriminator is cheap to notice — on a node it would be silent, every
    conflicting pull request quietly demoted from the trap it is to a
    node-level `unknown`.

    The pull request's alerts are read on its **merge** ref
    (`refs/pull/<n>/merge`) — the ref its `pull_request`-triggered analysis
    runs against, and so the only one GitHub files a pull request's alerts
    under; `refs/pull/<n>/head` carries no analysis and answers with an empty
    list and a 200, which is indistinguishable from a clean pull request. An
    **empty** alert list is believed only after `_review_gate_analysis_exists`
    confirms at least one code-scanning analysis exists for that same merge
    ref (`code-scanning/analyses`, one existence read, spent only on the
    empty-list path — alerts in hand are their own proof an analysis ran):
    the alerts endpoint answers a never-analysed ref with the same `[]` and
    200 a clean pull request produces, so without the existence check a pull
    request CodeQL skipped, a first-push race, or a repository that scans on
    push only (its alerts filed under `refs/heads/<branch>`, where the
    merge-ref query can never see them) would all certify `clean`. No
    analysis for the ref, or an existence check that cannot be asked, is
    `unknown`, never `clean` (agent-ops#270). An alerts API that
    cannot be asked at all is `unknown`, never `clean` — the same "could not
    check is not a pass" contract requirement 24a's `scripts/preview-deploy.sh`
    already keeps. `REVIEW_GATE_GH` stubs `gh` for tests.

    `review_gate_unknown_streak_verdict THRESHOLD NODE` (TD-PPagop-26081404),
    reading a `review-gate-checks-read` event stream on stdin, prints one
    `{node, gate, count, first_ts, last_ts}` object when NODE's own most
    recent run of consecutive `{ok: false}` events reaches THRESHOLD or more,
    with no `{ok: true}` from the same node in between; prints nothing
    otherwise, including for a THRESHOLD under 1 (the off switch, matching
    `lib/crash-loop.sh`'s `crash_loop_verdict`). It reuses that function's
    reduce-over-a-filtered-stream, run-resets-on-success shape rather than
    calling into it, because `crash_loop_verdict` counts across the whole
    fleet — one run per repository (agent-ops#1630), shared by every node —
    where a `gh` degraded on one node is a per-node fact a peer's success
    must never reset.

    `review_gate_degraded_since FIRST_TS NODE`, its dedup companion, exits 0
    when NODE's own `review-gate-checks-degraded` event for the run that
    began at FIRST_TS is already in the stream — the same already-escalated
    question `crash_loop_escalated_since` answers for requirement 2.7's
    crash loop, but matched exactly on the run's own `first_ts` (the
    escalation event is the verdict object itself) rather than on
    detail-at-or-after, so the current streak escalates once however many
    items it degrades through, while a new streak — its `first_ts` matching
    no logged event — escalates afresh.

    Also carries two Reviewer/Enabler helpers (moved from `agent-cycle.sh`,
    #771): `log_reviewer_handback DETAIL PR_URL UNBLOCK_CONDITION`, the
    single `attempt-failed` recording for a Reviewer verdict that did not end
    in a human-visible pull request; and
    `review_gate_escalate_unreadable_streak`, the streak-and-escalate
    sequence both the Reviewer's own "ready" handoff and the Enabler's
    `complete_handoff` recovery path share (TD-PPagop-26081603), built on
    `review_gate_unknown_streak_verdict`/`review_gate_degraded_since` above.

    Unit-tested (`test/review-gate.test.sh`); must pass `shellcheck`.
20a. `lib/reconciliation-gate.sh` implementing requirement 31c's
    reconciliation gate (agent-ops#533): given a pull request URL,
    `reconciliation_gate` prints `clean`, `dirty<TAB>reason` or
    `unknown<TAB>reason` — the same three-way shape `lib/review-gate.sh` and
    `lib/closing-keyword-gate.sh` report, so `lib/handoff.sh`'s
    `handoff_complete_review` folds all three into one gate. An optional
    second argument bounds the anchor search; `handoff_complete_review` passes
    its own fourth argument through, and `agent-cycle.sh` passes the cycle's
    start time (`cycle_started_at`) at both call sites. The anchor is the pull
    request's most recent `ready_for_review` timeline event at or before that
    bound that has no `convert_to_draft` event after it and at or before the
    same bound (`repos/<slug>/issues/<n>/timeline`, read for both event types
    at once; the maximum `created_at` among `ready_for_review` entries with
    no qualifying `convert_to_draft` entry later than them), falling back to
    the pull request's own `created_at` (`repos/<slug>/pulls/<n>`) when no
    such event exists — never having left draft by then, or every
    `ready_for_review` on record having eventually been undone. The bound is
    what makes the anchor mean anything on the Reviewer's own path: the
    Reviewer runs `gh pr ready` itself (requirement 31) before this gate is
    ever asked, so an unbounded search selects that flip and every comment
    the round was meant to answer falls before it — on the paths where no
    flip happens inside the round (`review-feedback`, and the Enabler's
    `complete_handoff` recovery) the bound selects the same event an
    unbounded search would. The undone-event exclusion is what stops a
    *reverted* flip from winning the anchor one round after the round it was
    refused in (agent-ops#539): `lib/handoff.sh`'s `handoff_complete_review`
    converts a pull request back to draft on a `dirty` reconciliation
    verdict (`confirm_pr_draft`, below), which GitHub records as a
    `convert_to_draft` event rather than deleting the `ready_for_review` it
    undoes, so without this exclusion that stale flip would again be "the
    most recent `ready_for_review` event at or before the bound" on the very
    next round, and the comment the gate had just refused to let through
    would read as reconciled. A "human comment"
    is any general PR comment
    (`repos/<slug>/issues/<n>/comments`, where `gh pr comment` files them —
    never a formal review or an inline review comment, since a
    `REQUEST_CHANGES` review is unavailable to a human on this system's own
    pull requests to begin with, see the file's own header) posted after that
    anchor, from a non-Bot account that is not a GitHub App acting under a
    user identity (`performed_via_github_app`), whose body does not carry
    `lib/pipeline-marker.sh`'s `PIPELINE_COMMENT_MARKER_PREFIX` — author alone
    cannot tell a human's write from the pipeline's, since every pipeline
    write and every human comment on this project's own pull requests land
    under the same GitHub account. It counts as reconciled once some comment
    posted since carries a line `<!-- agent-ops:reconciles comment=<id> -->`
    naming that human comment's own issue-comment id, in any comment carrying
    the pipeline marker — the one new convention this component adds, on the
    Reviewer's side (`prompts/reviewer.md`'s completion comment): a script can
    confirm the citation was made, never whether the diff it names actually
    answers the human's words, so it checks the citation exists rather than
    trying to judge the answer itself. `dirty` names every unreconciled
    comment's own `#issuecomment-<id>` permalink — one form serving both the
    human reading the handback and the Reviewer writing the citation, since
    the id the citation needs is the permalink's own fragment; `clean` covers
    both "no human comments since the anchor" and
    "every one is cited". `unknown` covers the timeline, the creation-time
    fallback or the comment list failing to read at all — a node or token
    fact, and this primitive itself decides nothing about it either way; its
    callers differ. `lib/handoff.sh`'s `handoff_complete_review` treats it as
    never itself blocking (the same "could not ask is not a failure" contract
    `lib/closing-keyword-gate.sh` already keeps), logging a warning and
    letting the rest of that gate sequence decide; requirement 8d's own gate
    4, re-reading this same primitive a second time at arming, refuses
    outright instead (#753's ruling on agent-ops#746) — arming an automatic
    merge tolerates an unanswered question even less than a hand-off does. An
    empty URL is `dirty`, a bug in the caller rather than a degraded node.
    `RECONCILIATION_GATE_GH` stubs `gh` for tests. Unit-tested
    (`test/reconciliation-gate.test.sh`); must pass `shellcheck`.
21. `scripts/pickup-metrics.sh` — a read-only operator report, like
    `scripts/watch-node.sh` (component 11) and `scripts/check-node-compose.sh`
    (component 12): answers issue #248's acceptances 4 and 5 from the union
    event log and this repository's own `config.json`, itself adding no event
    and touching no pipeline behaviour. Reads `lib/fleet.sh`'s `fleet_logs`
    over `state_dir`/`fleet_peers_dir workspace_root` (or `--state-dir`/
    `--peers-dir` overrides), parsing defensively one line at a time
    (`jq -c -R 'fromjson? // empty'`, as `scripts/publish-dashboard.sh` does,
    since the log is appended to while it reads) and bounded by an optional
    `--since <iso8601>`.

    Acceptance 5 (no increase in duplicate-work incidents): splits every
    `selection` and contended `claim-lost` event (`cause` of `held` or
    `pr-held` — WI-2 renames a PR-keyed `held` loss to `pr-held`, so counting
    only `held` would silently undercount after #238; a `claim-lost` with no
    `cause` at all, from before requirement 17a carried one, counts toward
    neither) into a "before"/"after" era **per node, at that node's own first
    `chained` event** (component-21's reason for reading it rather than
    #268's merge timestamp: an auto-updated fleet picks up a change at
    different real times per node, so only a node's own evidence that it
    exercised finish-then-continue marks its own adoption; a node with no
    `chained` event in the window is entirely "before"). Prints both eras'
    `selection` and contended-`claim-lost` counts and each ratio, and beside
    them `contention_by_node` — the identical population grouped by node
    instead of by era (`.fleet`, and `.by_node`'s `selections`,
    `contended_losses` and `ratio` per node), computed by
    `lib/fleet-sizing.sh`'s `fleet_sizing_contention_by_node` rather than by a
    fold of this script's own, so that the per-node duplicate-work input the
    dashboard's fleet-sizing figure reads (`docs/spec/dashboard/README.md`, issue
    #612) and the figure this report prints can never be two independently
    maintained counts of the same events.

    Acceptance 4 (median pickup latency, TD-PPagop-26081405): pairs each
    `first-seen` (requirement 33) with the `selection` that later claims the
    same `{repo, item}` — both reduced first-wins-by-`ts` on the rare
    duplicate a race between two nodes' gathers can produce — and reports the
    gap in seconds as `pickup_latency`: `count`/`median_seconds`/
    `p90_seconds` fleet-wide (`.fleet`) and per claiming node (`.by_node`),
    plus `bootstrap_excluded_count` — paired items left out of both figures
    because their `first-seen` carried `bootstrap: true`, still counted so
    the exclusion is visible rather than a silent drop. An item with only one
    half of the pair is reported instead under `coverage`: `paired`,
    `first_seen_only` (seen, not yet claimed) and `selection_only` (claimed,
    but never `first-seen` — most often an item that predates this
    instrumentation). `selection_only` is also where every pickup from the
    four sources requirement 33 leaves uncovered lands, and lands
    permanently: `pickup_latency` describes the eight pre-fetched arrays that
    emit `first-seen`, not the fleet's whole intake, so a reader comparing
    `median_seconds` against issue #248's own target is reading an
    8-of-12-source figure by construction — `coverage` is what says so, and
    requirement 33 is where the four are named.
    `cadence_bound_minutes` echoes `config.json`'s
    `schedule.cycle_interval_minutes` — the floor under every latency figure
    above, since a poll-based `first-seen` is only as fresh as the gather
    that logged it.

    The pairing tolerates every `selection` shape the log has ever held,
    because `log.jsonl` is never rotated (requirement 2.6, component 3i) and
    so still carries events from before `scripts/gather-issues.sh` minted its
    `ref` as `(.number | tostring)`: an `item` is stringified before it is
    keyed, which both avoids a jq type error on a numeric one and unifies
    issue `45` with issue `"45"` onto the single key they deserve, and a
    paired `selection` carrying no `node` at all counts fleet-wide but is
    left out of `by_node` rather than keyed under a null. Neither shape may
    abort the report: a single unreadable event costs its own line, never the
    whole run, the same defensive posture the line-at-a-time parse above
    takes.

    Both acceptances share the report's `since` and `window` (the timestamps
    covered), as JSON on stdout. Regression-tested against a fixture log
    covering a malformed trailing line, a causeless `claim-lost`, a
    `pr-held` one, a bootstrapped `first-seen`, both unpaired classes, a
    first-seen race between two nodes, and a legacy numeric-`item`,
    node-less `selection` (`test/pickup-metrics.test.sh`); must pass
    `shellcheck`.
22. `scripts/autonomy-stage-report.sh` — a read-only operator report, like
    `scripts/pickup-metrics.sh` (component 21): for each `config.json` repository
    (or `--repo` override), prints its `merge_autonomy_configured_level`, the
    D18 rollout stage (agent-ops#402, 2026-08-18 amendment) that level
    corresponds to, that stage's exit criteria, the measured value of each,
    and a closing verdict — `met`, `not-met (criterion: …)` or
    `insufficient-evidence` — as Markdown followed by a machine-readable JSON
    block, on stdout. Itself adds no event and touches no pipeline behaviour.
    Reads the configured level rather than `merge_autonomy_effective_level`,
    matching `scripts/doctor.sh`'s own reasoning (requirement 2.3b): a
    momentary kill-switch trip answers whether autonomy is running right now,
    not how much rollout evidence a repository has earned, and checking it
    would add a state-repo network read this report has no other reason to
    make. Stages 2 and 3 share the level `agent-merges-routine` and identical
    exit criteria (agent-ops#402: "Stage 3 … Same metrics per repo"), so a
    repository at that level is reported once, against "Stage 2/3".

    The Stage 2/3 `classifier_escapes` criterion is measured off requirement
    8e's own audit events rather than asserted: a `classifier-escape` event
    for the repository fails the bar outright and names the pull request that
    escaped, however many clean audits stand beside it; a `landing-audit`
    event carrying `outcome: "clean"` is a landing the audit recomputed and
    agreed with, and only those count toward the zero. A repository whose
    audit has recomputed nothing yet — every repository until its first
    autonomous landing — reports `unavailable`, never a guessed `0`: the
    audit reads landings, so zero escapes out of zero audits is an absence of
    evidence rather than evidence of absence. An audit that could not be
    recomputed at all (`outcome: "unverifiable"`) is counted and named
    separately, never folded into the clean tally. Both event shapes carry
    the detector's own `repo` field, which is what is matched, with the
    `pr_url` prefix checked too and anchored rather than substring-matched,
    so `Poetic-Poems/poetic` is never credited with a
    `Poetic-Poems/poetic-fiddle` pull request. The Stage 1
    `divergence` criterion (agent-ops#573) is real: it calls component 22a
    (`lib/verdict-fate.sh`) to join this repository's `approver-verdict`
    events against each named pull request's live GitHub state, and reports
    `met` (a sample-backed zero), `not-met (criterion: divergence)` (at least
    one divergent pull request) or `unavailable` (no settled comparison yet,
    fewer than five — `lib/verdict-fate.sh`'s own `insufficient-sample` — or
    at least one pull request this run could not read from GitHub, even once
    the readable rest alone would clear the sample bar and read clean:
    a zero divergence rate over a partial read is not a confirmed zero
    (agent-ops#661)) off that join — never a rate stated on too small or too
    incomplete a sample, and always naming any pull request it could not read
    from GitHub this run, so a `met` is never mistaken for a zero over pull
    requests nobody looked at.
    "Elapsed time at the current level" is read off
    `lib/fleet.sh`'s union event log rather than this repository's own git
    history, because the deployed image never carries `.git` (`.dockerignore`)
    and this report has to behave identically there and in a checkout: the
    repository's own earliest `landing-armed` event for
    `agent-merges-routine`/`agent-merges-all` (the Script only ever arms a
    landing once a repository's level has reached that rung), or earliest
    `approver-verdict` event (matched by `pr_url`, since that event carries no
    `repo` field of its own) for `agent-approves` — the same Approver stage
    that arms "from the moment [the level] lands" (`lib/merge-autonomy.sh`).
    A repository with no such event yet reports elapsed time `unavailable`,
    which under-counts, never over-counts, time already accrued.

    Autonomous landings and, at `agent-merges-all`, human-authored merges are
    each GitHub's own merged-pull-request record (one `gh api` read per
    repository, filtered to `pr_label`) inner-joined by pull-request URL
    against the fleet's own `landing-armed` events for that repository — a
    landing-armed pull request that never actually merged (a later dequeue,
    say) does not inflate the count. The revert-or-follow-up rate compares a
    fresh `scripts/mine-merge-history.sh` run against the earliest
    `docs/reviews/*-merge-autonomy-baseline.md` on disk (sorted by its own
    dated filename) — the Stage 0 baseline that script's own header says it
    satisfies — `unavailable` when no such file exists or the fresh run
    itself fails.

    `--config`, `--repo`, `--label`, `--reviews-dir`, `--state-dir`,
    `--peers-dir` and `--now` all override their `config.json`-derived
    defaults, the last existing so a test run can fix "elapsed since" against
    a stable clock. Regression-tested
    (`test/autonomy-stage-report.test.sh`) against seven repositories: every
    criterion met; a real failure on a measurable criterion outranking an
    unrelated unavailable one (`not-met`, never `insufficient-evidence`);
    every measurable criterion met while one is unavailable for want of
    evidence (`insufficient-evidence`, never `met`, proving a criterion is
    never reported satisfied from missing data); a `classifier_escapes` zero
    backed by real audits reading `met` while an unverifiable audit beside it
    is named rather than counted, and a single `classifier-escape` event
    failing the bar and reaching the verdict; a real, sample-backed `met`
    verdict on the `divergence` criterion (component 22a), proving the join
    is exercised end to end and not merely its unavailable fallback; and a
    partial read of that same join — a settled sample of pull requests
    clearing the minimum bar alongside one unreadable pull request —
    reporting `divergence` `unavailable`, never `met`, proving a zero over an
    incomplete read is never mistaken for a confirmed zero; must pass
    `shellcheck`.
22a. `lib/verdict-fate.sh` and `scripts/verdict-fate-report.sh` implement the
    D18 Approver-verdict/human-action divergence record (agent-ops#573, a WI
    of umbrella #402) — the pairing component 22's own `divergence` criterion
    consumes rather than recomputes.

    `lib/verdict-fate.sh` is pure — every function reads only its
    arguments, so it is directly unit-tested (`test/verdict-fate.test.sh`)
    without a live GitHub read:

    - `verdict_fate_posted_review VERDICT ADJUDICATION` maps the Approver's
      own verdict vocabulary (requirement 8c: `approve`/`refuse` ordinarily,
      `land`/`refuse`/`escalate` under adjudication) onto the two GitHub
      review events the Script ever actually posts — `APPROVE` or
      `REQUEST_CHANGES` — printing empty for a verdict that reaches neither
      (an adjudication `escalate`, or an unrecognised verdict). Fixed
      application logic, not a runtime fact, so it is safe to recompute for
      an `approver-verdict` event logged before this component existed.
    - `verdict_fate_latest_per_pr EVENTS_JSON [REPO_PREFIX]` reduces the
      event log's `approver-verdict` entries to one per pull request — the
      single latest by `ts` — "one entry per pull request the Approver ruled
      on" (agent-ops#573's own acceptance): a pull request refused, fixed
      and later approved is judged on that later approval alone, and a
      verdict whose review never reached GitHub (`posted: false`, or an
      escalate/unrecognised verdict with no mapped review at all) is
      excluded — nothing to compare a human's action against. An event
      logged before this component existed carries no `posted` field at all
      and defaults to `true`, the best available assumption for history this
      component cannot re-observe; `repo` is likewise always derived from
      `pr_url` rather than read off the event's own field (requirement 33),
      so such an event, which carries no `repo` field at all, still reports
      one. REPO_PREFIX, when given, restricts to pull requests under that
      `owner/repo`, matched by exact prefix — the same no-substring
      discipline component 22's own `agent_approved_prs` criterion already
      applies, so a same-prefix decoy repository is never counted. Each entry
      also carries `first_approve_ts` — the earliest `ts` among that pull
      request's own surviving `APPROVE` verdicts, empty when it has none —
      which is not necessarily the latest verdict's own `ts`: a pull request
      approved, sent a standing human `CHANGES_REQUESTED`, and re-approved
      once `review-feedback` brings it back round carries a later `ts` than
      that `CHANGES_REQUESTED`, but its *first* approval does not, and
      `verdict_fate_classify` must test the standing-request window against
      the latter, never the former, or the divergence goes silently
      unrecorded (agent-ops#661).
    - `verdict_fate_classify POSTED_REVIEW ARMED PR_STATE REVIEWS_JSON
      FIRST_APPROVE_TS` compares the posted review against the pull
      request's live GitHub state and prints `{fate, comparison}`. `fate` is
      one of `landed-by-script` (merged, and a `landing-armed` event exists
      for this pull request — the same join component 22's own
      `autonomous_landings` criterion already performs), `landed-by-human`
      (merged, no such event), `closed-unmerged`, `still-open`, or
      `changes-requested-after-approval` — a human review of state
      `CHANGES_REQUESTED`, not from a bot, submitted after
      `FIRST_APPROVE_TS` (`verdict_fate_latest_per_pr`'s own field: the
      *earliest* posted `APPROVE` for this pull request, not the latest
      verdict's own `ts`), standing on an `APPROVE`. That fifth fate is never
      collapsed into `closed-unmerged` even once the pull request is later
      fixed and lands anyway — agent-ops#573's own stated "sharp edge": a
      standing human override of an agent approval is the signal Stage 1/2
      exist to observe, and it must never be silently dropped, including
      across a re-approval agent-ops#661 fixed this against. `comparison` is
      `agreement`, `divergence` or `pending` (still open, no standing
      request) — symmetric by posted review: an `APPROVE` diverges on
      `closed-unmerged` or the fifth fate and agrees on either landed fate; a
      `REQUEST_CHANGES` diverges if the pull request landed anyway (a human
      override of the refusal) and agrees on `closed-unmerged`.
    - `verdict_fate_summarize ENTRIES_JSON MIN_SAMPLE` counts
      agreement/divergence/pending and computes `sample` (agreement plus
      divergence — `pending` has no eventual action yet to compare against,
      so it is excluded from both the count and the rate) and `rate`
      (divergence over sample, `null` at `sample: 0`). `status` is
      `insufficient-sample` below `MIN_SAMPLE`, `divergence` when any exists,
      `clean` otherwise — never a rate stated on too few pull requests to
      mean anything (agent-ops#573's own acceptance).

    `scripts/verdict-fate-report.sh` is the I/O wrapper and, like component
    22, a read-only operator report: argless-runnable against `config.json`,
    it fetches each candidate pull request's live state and reviews (one
    `gh api` read of each per pull request — `state`+`merged` folded into
    `verdict_fate_classify`'s three-value vocabulary, and the reviews list in
    the same shape `lib/approver.sh`'s `approver_refuse_streak` already
    reads: `{login, state, submitted_at, bot}`, `bot` by `user.type ==
    "Bot"` or a `[bot]`-suffixed login), joins them through
    `lib/verdict-fate.sh`, and prints, per repository, its D18 level and
    stage label alongside agreement/divergence/pending/sample/rate — as
    Markdown followed by a machine-readable JSON block, on stdout. `--since`
    restricts to pull requests whose latest verdict landed on or after a
    given timestamp (default: every verdict `log.jsonl` still holds — safe
    because that file is never rotated, requirement 2.6); `--min-sample`
    (default 5) is `verdict_fate_summarize`'s own threshold. Itself adds no
    event and touches no pipeline behaviour. Regression-tested
    (`test/verdict-fate-report.test.sh`) against one repository exercising
    every fate the issue's own vocabulary names, plus a same-prefix decoy
    repository excluded and a superseded verdict (an early refusal, a later
    approval on the same pull request) contributing only its later entry;
    must pass `shellcheck`.

    Component 22's own `divergence` criterion duplicates
    `scripts/verdict-fate-report.sh`'s two `gh api` read helpers rather than
    shelling out to it — both already hold the fleet event log and the
    rate-limit-aware `gh` wrapper in-process, and a second `gh` subprocess
    per pull request would double the calls one Stage-1 evaluation makes for
    no benefit — but shares `lib/verdict-fate.sh`'s join and classification
    logic unchanged, so a change to the classification rules changes both
    call sites at once, deliberately.
22b. `scripts/github-budget-report.sh` — a read-only operator report, like
    components 21, 22 and 22a: over the `github-budget` events requirement
    2.0d records — this node's `state_dir/log.jsonl` plus every peer's
    mirrored copy, or exactly the log files given as arguments — prints, per
    hour (UTC), the readings taken, the peak `core` used and the minimum
    `core` remaining any reading saw, the peak `graphql` used, the number of
    primary-limit refusals that reached `guard-degraded` and the number of
    requirement-2.0 stand-downs; per stage, the median and maximum of the
    bucket's `core` movement and the median `graphql` movement while the
    stage ran, readings that spanned a window roll excluded; per cycle
    (requirement 48, agent-ops#1086), the sum of `core`/`graphql` movement
    across a cycle's own readable, non-window-rolled readings, node named
    alongside — the figure requirement 48's before/after comparison reads;
    and per node, readings, unreadable readings and cycles carrying a
    record; and — over the `gh` transport shim's own ledger (component 22c),
    read the same fleet-shaped way, or nothing at all when explicit log
    files were given instead, since there is then no `state_dir` to find a
    ledger beside — total calls and how many resolved `hit`/`miss`/`stale`/
    `bypass`, as Markdown followed by a machine-readable JSON block. `--since
    ISO8601` restricts
    the window. Its preamble states what the figures are: the bucket's, an
    upper bound on any one segment's own spend while identities are shared.
    Damaged log lines are dropped, not fatal; an empty read says so and
    exits 0; a named log that does not exist is an error. Itself adds no
    event, makes no network call and changes nothing. Unit-tested
    (`test/github-budget-report.test.sh`); must pass `shellcheck`.

22c. `lib/gh-shim.sh` and `scripts/gh-shim.sh` — the `gh` transport shim
    (requirement 2.0e, agent-ops#1084), and, since agent-ops#1021, the front
    door for the forge authoring App's on-demand credential seam (D18
    decision 1 as amended, component 14h): the executable, installed on
    `PATH` ahead of the real binary (`deploy/docker/Dockerfile`), is a thin
    entry point that sources the library and calls `gh_shim_main "$@"`; every
    other function lives in the library and is unit-tested by sourcing it
    directly. `gh_shim_main` calls `gh_shim_resolve_token` first, ahead of
    classification and every transport pathway below: "explicit wins; empty
    resolves" — a non-empty `GH_TOKEN` is never touched (which is what keeps
    `lib/approver.sh`'s own `GH_TOKEN="$(approver_token_get)" gh …` posting
    as the Approver rather than being re-minted as the author); an empty one
    mints a forge authoring App installation token (`lib/author-token.sh`,
    component 14g) — a cache hit costs nothing, so this runs unconditionally
    on every single invocation, the one place that guarantees every
    `git`/`gh` authoring act this node makes starts with at least
    `lib/github-app-token.sh`'s own `refresh_buffer=300` seconds of token
    life left, however long the cycle or the stage running it has been
    alive — and falls back to `PW_GH_DEGRADE_TOKEN` (component 14h owns the
    name) when no App is configured or a mint attempt fails, leaving
    `GH_TOKEN` empty when neither is available (the pre-existing "nothing
    configured" case). This is the seam's *first* front door; the second is
    the same shim reached through `git`'s own credential helper
    (`!gh auth git-credential`, `deploy/docker/entrypoint.sh`, component 7)
    — an unqualified `gh` there resolves through `PATH` to this file exactly
    as any other caller's does, so `gh_shim_resolve_token` mints for `git`
    too, and `gh auth git-credential`'s own protocol answer
    (`username=x-access-token`, `password=<token>`) reflects whatever this
    file just resolved.
    **Which installation** that mint goes against is `gh_shim_target_owner
    ARGS…`'s answer for the invocation in hand, resolved through component
    14g's per-owner map: a named owner mints for that owner's installation;
    a named owner neither the map nor the scalar default covers falls back
    to `PW_GH_DEGRADE_TOKEN`, because a token minted on the wrong account is
    a 404 at write time rather than a credential; and an invocation naming
    no owner takes the scalar default installation, or `PW_GH_DEGRADE_TOKEN`
    when there is none. `gh_shim_target_owner` is pure — argv, the buffered
    credential request, and the current work tree's own `origin` — and tries,
    in order: a buffered `gh auth git-credential` request's `path=`
    attribute; `-R`/`--repo` in either spelling; for `gh api`, the endpoint
    path (`repos/OWNER/…`, `orgs/OWNER…`, `users/OWNER…`, leading slash and
    query string both tolerated) or, for the literal `graphql` endpoint, an
    `owner=OWNER` field (`-f`/`-F`/`--field`/`--raw-field`) and then a
    `repository(owner: "OWNER"` literal in the query text; for everything
    else the first *positional* argument that is a **github.com URL**, and —
    **only under `gh repo <subcommand>`** — a bare `OWNER/REPO` or
    `HOST/OWNER/REPO` as well; and finally `git remote get-url origin`,
    github.com only, which is how the large remainder (`gh pr list`, `gh pr
    checks`, `gh issue comment 12`) resolves, exactly as `gh` itself resolves
    them. Naming no owner is an ordinary outcome, not a failure: the scalar
    default answers it, and a wrong guess would be worse than none.
    The `gh repo` restriction is load-bearing, not tidiness: a bare `a/b` is
    exactly as much a *branch name* as a repository, and every branch this
    fleet creates carries a slash (`agent/1051`, `feat/x`, `docs/x`), with
    the stages running `gh pr checkout`/`view`/`diff` against one, bare,
    inside a cloned workspace. `gh repo` is the one command family whose
    positional is never a branch, and a URL is never one under any command.
    A flag's value is never read as a repository either (`gh repo clone
    --branch feat/x acme/widgets` names `acme`), and the `HOST/OWNER/REPO`
    form requires its first segment to contain a `.`, so a three-segment
    path (`docs/foo/bar.md`) cannot have its middle segment read as an
    owner. `gh auth git-credential` is also
    the one invocation whose **stdin** `gh_shim_main` reads: git's request
    (`protocol=`, `host=`, `path=`) is buffered to a temporary file which
    then replaces the process's own stdin, so the real binary receives the
    caller's bytes unchanged while the shim gets the `path=` line it needs.
    Nothing else's stdin is ever read, which is what keeps `gh api --input -`
    working.
    `gh_shim_classify` (built on `gh_shim_parse`) is the one place
    a call is sorted into `read` (a plain `gh api` GET, conditioned as one
    request), `paginate` (a `gh api` GET carrying `--paginate`/`--slurp` —
    conditioned and merged one page at a time, falling back to an
    unconditioned single call, still stored and served last-known-good like
    a `read`, when a page does not fit the shape that walk expects),
    `write` (method resolves non-GET), `graphql`
    (the literal `graphql` endpoint), `include` (the caller already asks for
    `-i`/`--include`) or `other` (not `gh api` at all, or `gh api` with no
    endpoint found) — every class but `read` reaching the real binary with
    the caller's own argv, and every class but `read` and `paginate` having
    its stdout passed straight through unread.
    `gh_shim_handle_read` conditions a cacheable GET on a stored `ETag`,
    always adds `-i` itself and always strips it back out of what the caller
    sees, taking the body by byte offset from past the header terminator
    (`gh_shim_header_end_offset`) so it is returned exactly as the wire
    carried it; `gh_shim_handle_paginate` drives a paginated call's own walk
    the same way, one page at a time, following each page's `Link:
    rel="next"` and re-assembling the pages into the shape the real binary's
    own `--paginate`/`--slurp` documents (agent-ops#1114) — falling back to
    `_gh_shim_paginate_legacy`, the single real-binary call with the
    caller's own argv untouched that was this pathway's entire behaviour
    before, when a page does not fit; `gh_shim_split_blocks` parses the HTTP
    response block from that capture; `gh_shim_should_use_lkg` and
    `gh_shim_serve_lkg` decide and perform a last-known-good serve, reusing
    `lib/github-limit.sh`'s own `github_limit_kind` so a refusal can never be
    recognised two different ways in this repository; `gh_shim_cache_dir`
    names the one directory every entry for an (identity, query-stripped
    endpoint path) pair lives in —
    `state_dir/gh-shim/http-cache/<identity>/<sha256(path)[0:24]>` — and
    `gh_shim_cache_read`/`_write`/`_invalidate` manage the `<key>.json`
    entries under it (identity, path, etag, fetched_at, body — written via a
    temp file plus `mv -f`, `--rawfile`-read so an arbitrarily large body
    never passes through a shell variable; a write's invalidation is `rm -rf`
    of the path's directory and its parent path's, never a walk of the
    cache, agent-ops#1422); `gh_shim_prune_cache` retires entries older than
    seven ceilings at any depth, a flat pre-#1422 entry included, and the
    directories that emptied; `gh_shim_ledger_line` and `gh_shim_budget_update`
    write `state_dir/gh-shim/ledger.ndjson` and `budget.json` under `flock`.
    `gh_shim_identity` prints `GH_SHIM_IDENTITY_TAG` when
    `gh_shim_resolve_token` set it — `app-<app id>-<installation id>`, for a
    token that function minted — and otherwise hashes `GH_TOKEN`/`GITHUB_TOKEN`
    (or prints the fixed `no-token` tag) — read after `gh_shim_resolve_token`
    has already run, so a minted App token and the PAT it may have replaced
    never share a cache entry or a budget reading either, while a minted
    token's hourly successor does share its predecessor's. `PW_GH_REAL_BIN`, `PW_GH_STATE_DIR`,
    `PW_GH_NO_CACHE`, `PW_GH_STALE_CEILING_SECONDS` and `PW_GH_STALE_EXIT_CODE`
    are its transport test seams and operator knobs; `PW_GH_DEGRADE_TOKEN`
    (component 14h owns the name) and `PW_GH_NOW_EPOCH` (a test seam only,
    the clock `gh_shim_resolve_token` mints against) are the credential
    seam's own — documented in the library's own header rather than in
    `config.schema.json` — the same convention `lib/github-limit.sh`'s
    own `GITHUB_LIMIT_*` variables already use. Unit- and integration-tested
    against a stub "real gh" binary answering from a per-call JSON plan
    (`test/gh-shim.test.sh`) and, for the credential seam specifically —
    stubbed `curl`/`openssl` and `PW_GH_NOW_EPOCH` advanced past a minted
    token's `expires_at` — `test/gh-shim-auth.test.sh` (acceptance check 2q),
    which also covers `gh_shim_target_owner` rule by rule, including that a
    flag's value is never read as an owner and that an invocation naming
    none prints nothing;
    must pass `shellcheck`.

23d. `lib/tech-debt-file.sh` implementing the filing half of requirements 36c,
    42a and 32c — the Approver and Enabler must never write to GitHub or a
    branch themselves, and the Reviewer whose subject merged mid-pass no
    longer has one to write to (requirement 31d), so this is what the Script
    calls in their place once a stage's final JSON carries
    `file_debt`/`file_issue`. Neither function touches a branch or a clone —
    each is a bounded number of `gh` calls against the target repository's
    Issues API — so neither takes a `GIT_DIR`:

    - `techdebt_file_issue REPO ITEM_REF TITLE BODY_FILE [TOKEN] [DEFAULT_FIX]
      [OWNER_DECISION]` — the same
      duplicate-guard shape `create_escalation_issue` (component 2) already
      uses (an open issue whose body already quotes `ITEM_REF` is returned
      rather than filing a second one — matched on the bare reference, not
      requirement 36a's backtick-delimited token — with
      `DEFAULT_FIX`/`OWNER_DECISION` untouched on that path; a dedup hit
      never re-labels or re-bodies the existing
      issue), but with no label and no assignee: this is not an escalation
      addressed at a specific human, and is legitimate autonomous work for the
      `issues` source to pick up later. A fresh issue's body is `BODY_FILE`'s
      own content plus `techdebt_default_section`'s trailing `## Default`
      section (below); `OWNER_DECISION` of exactly `"true"` additionally
      requests the `pw::owner-decision` label on `gh issue create` itself,
      never a body line — a label, not untrusted body text, is what a later
      gatherer can trust the same way `pw::type:tech-debt` already is —
      **retried once without the label**, exactly as requirement 36a's
      escalation contract is, so a repository that has not had that label
      ensured yet still gets its issue: `gh` resolves a label name to an id as
      part of the create, so a labelled create against a repository lacking it
      fails outright, and a filing lost that way is the one outcome
      agent-ops#938 exists to prevent. Losing the label costs a later Refiner
      its marker — the issue reads to it as an item carrying neither marker
      (requirement 39d's third case); losing the create costs the filing.
      Prints `"<number>\t<url>"` on success, nothing on failure.
    - `techdebt_default_section DEFAULT_FIX [OWNER_DECISION]` (agent-ops#938)
      — the `## Default: <DEFAULT_FIX>` heading both filing functions append
      (`## Default: not stated` when `DEFAULT_FIX` is empty — a malformed
      verdict, per requirements 36c/42a, is filed anyway rather than lost),
      plus an `Owner decision: yes` line immediately below it when
      `OWNER_DECISION` is exactly `"true"`. `techdebt_file_debt` passes both
      through as a body line; `techdebt_file_issue` passes `DEFAULT_FIX` alone
      — its own `OWNER_DECISION` signal is the `pw::owner-decision` label
      above, never a body line, so the two writers never disagree about which
      of body-text or label is the trusted signal for the same fact.
      `techdebt_file_debt`'s own `OWNER_DECISION` stays a body line rather
      than a label even though its target moved to an issue (agent-ops#874):
      the choice it marks is independent of that storage move, and changing
      which signal `file_debt` trusts is no part of it.
    - `techdebt_file_debt REPO TITLE BODY PROVENANCE [TOKEN] [DEFAULT_FIX]
      [OWNER_DECISION]` (agent-ops#874, replacing the id-reservation/
      `td-record/<id>`-branch/filing-pull-request shape D15 as revised #869
      retired) — files a single GitHub issue in `REPO`, labelled
      `pw::type:tech-debt` (the same label `scripts/gather-tech-debt.sh`
      selects the `tech-debt` work band on), deduped first against `REPO`'s
      own open `pw::type:tech-debt` issues by normalised title
      (`_techdebt_title_dedup_match`/`_techdebt_normalize_title`: lower-cased,
      punctuation folded to spaces, whitespace collapsed, then compared for
      equality or — both titles at least eight normalized characters —
      containment either way). That search states its own page cap —
      `--limit TECHDEBT_DEDUP_LIST_LIMIT` (default 500), never `gh issue
      list`'s undeclared default of 30 — for the reason every other listing in
      this pipeline states one ("A listing that silently comes back at its
      page size", Gotchas): a truncated listing is indistinguishable from a
      complete one, and here the cost of not seeing an issue is the duplicate
      filing the dedup exists to prevent, against the *oldest* debt, since the
      listing is newest-first. A listing that comes back at the cap is
      recorded in `tech-debt-file.err` rather than passed off as complete. A
      dedup hit gets `BODY`/`PROVENANCE`, plus
      `techdebt_default_section`'s trailing section, as a comment on the
      matched issue instead of a second filing, and returns that issue's own
      number/url untouched — no re-labelling, no re-titling. No dedup hit
      creates a fresh issue (`gh issue create --label pw::type:tech-debt`)
      whose body is `BODY` plus `techdebt_default_section`'s trailing `##
      Default` section plus `PROVENANCE`. A labelled create that fails is
      retried once unlabelled — a repository whose `pw::type:tech-debt` label
      the ensure pass (component 6a) has not reached yet — exactly as
      `techdebt_file_issue`'s own `pw::owner-decision` retry above, logged to
      `tech-debt-file.err`. Nothing reconciles the result: the filed issue
      carries no `pw::type:tech-debt` label, so it is invisible by
      construction both to `scripts/gather-tech-debt.sh`'s own label search
      and to the archive mirror's (2.6c), and neither of 2.6c's own audits
      catches it either — the empty-body audit reads only what that same
      label search already returned, and the legacy-filing audit looks for
      an open pull request on a `td-record/` branch, not an unlabelled issue
      (agent-ops#1223). Prints `"<number>\t<url>"` on
      success (the new issue's, or the matched one's), nothing on failure.
      There is no id reservation, no branch, and no pull request: a create or
      a comment either lands or it doesn't, so there is nothing to half-finish
      and nothing to clean up on a failure path — unlike the shape this
      replaced, this function has no rollback of its own to test.
    - `TOKEN`, given to either function, runs every `gh` call under that
      identity (`GH_TOKEN="$TOKEN"`) — the Approver's own minted App token
      (`approver_token_get`, `lib/approver-token.sh`, requirement 14b), the
      same one `approver_post_review` (component 14c) already posts its
      review under. Omitted, every call runs under the
      ordinary pipeline login, explicitly (`env -u GH_TOKEN`) rather than
      merely left alone, so a `GH_TOKEN` this process happens to have
      inherited can never leak into a call asked to run under the ordinary
      login — the Enabler's own case, which holds no App identity of its own.

    Regression-tested in `test/tech-debt-file.test.sh`: for `techdebt_file_debt`,
    an exact-title dedup hit comments on the matched issue and returns its own
    number/url with no create attempted; a normalised (case/punctuation-folded)
    title match and a containment match (both titles at least eight normalized
    characters) dedup the same way; a short needle never matches an unrelated
    long title by containment, only by exact equality; an unusable dedup search
    (not a JSON array) is skipped rather than failing the filing; a labelled
    create that fails is retried unlabelled and still succeeds; an unlabelled
    create that fails returns 1 with no output; a token is used for every call;
    and no call ever touches `git/refs` or `pr create`. `techdebt_file_issue`'s
    own suite (unchanged by agent-ops#874) is retained alongside it: the dedup
    hit, the ordinary create, and a failed create; `techdebt_default_section`'s
    three shapes for both functions (agent-ops#938) — `DEFAULT_FIX` alone (the
    heading, no owner line/label), `OWNER_DECISION` alone (`## Default: not
    stated` plus the owner line/label — a stated owner-only choice is never
    malformed even with no default), and neither (`## Default: not stated`, no
    owner line/label); and the label retry: an `issue create` carrying
    `--label pw::owner-decision` that the stub refuses — as `gh` refuses one
    against a repository lacking the label — is re-attempted unlabelled and the
    issue is still filed, while an *unlabelled* create that fails is not
    re-attempted and stays a failed filing. The Script's own wiring — that
    `run_approver_stage`, `maybe_run_enabler` and `reviewer_merge_observed`
    (requirement 32c) actually call these with the right arguments,
    `default_fix`/`owner_decision` extracted from the verdict and threaded
    through past the token in that order (agent-ops#938), the malformed-verdict
    warning logged whenever a filing carries neither, and log the right event
    with `issue_number`/`issue_url` — is covered separately, by
    `test/approver-tech-debt-file-wiring.test.sh`,
    `test/enabler-tech-debt-file-wiring.test.sh` and
    `test/merge-observed.test.sh`, lifting each block out of `lib/approver.sh`,
    `lib/enabler.sh` and `lib/merge-observed.sh` the same way
    `test/approver-wiring.test.sh` and `test/enabler-verdicts.test.sh` already
    do for the rest of either stage's own wiring. Must pass `shellcheck`.
23f. `scripts/release-pending-reservations.sh` implementing requirement 17g's
    reservation-release retry sweep — the durable half of TD-PPagop-26082427,
    behind component 23d's own marker-writing half. A no-op (exit 0, no `gh`
    call at all) where `state_repo` is unset. Otherwise: lists every
    directory under `reservation-releases/` in `state_repo` (one per target
    repository, sanitized `owner__name`) and every marker file beneath each,
    reads each marker's `{repo, branch, ts}` body, and for each attempts `gh
    api -X DELETE repos/<repo>/git/refs/heads/<branch>`. A `malformed`
    marker — missing `repo` or `branch` — is reported as a `warning` and
    left in place rather than acted on. On success, or on a delete that
    fails but a follow-up `git/ref/heads/<branch>` read confirms the branch
    is already gone (a peer node's own concurrent retry — since a marker is
    only ever cleared once, never renewed), the marker itself is deleted
    from `state_repo` and the outcome (`"released"`/`"absent"`) is printed.
    A delete that fails again — or whose follow-up confirmation itself
    cannot be trusted — leaves the marker in place for the next cycle's
    pass; what it prints depends on the marker's own age and history
    (`reservation_release_stuck_after_days`, `0` restoring the unconditional
    behaviour this component had before agent-ops#1011): a marker already
    carrying `escalated_at` prints nothing at all; a marker at least that
    many days past its own `ts` and not yet carrying `escalated_at` writes
    `escalated_at` back onto itself (`gh api -X PUT` against the `sha` this
    pass already read for it) and prints `reservation-release-stuck`
    (`repo`, `branch`, a `detail` naming how long the delete has been
    failing) instead of the usual `warning` — once only, since every later
    pass sees `escalated_at` already set; every other case (below the
    threshold, `ts` missing or unparseable, disabled, or the `escalated_at`
    write itself failing) prints the ordinary `warning` naming the repo and
    branch. One invocation covers every repository with a pending marker,
    never a per-repo loop: each marker already names its own target repo,
    the same shape `lib/claim.sh gc` already uses for its own
    state-repo-wide sweep. Always exits 0. Regression-tested in
    `test/release-pending-reservations.test.sh` (no `state_repo` configured,
    an empty tree, a delete that now succeeds, a delete that fails against
    an already-absent branch, a delete that fails again while still under
    the stuck threshold, a delete on a marker at/past the stuck threshold —
    asserting the escalation fires and `escalated_at` is written — a delete
    on a marker already carrying `escalated_at` — asserting silence, not a
    repeated `warning` or a repeated escalation — a malformed marker, and
    two markers naming different target repositories each handled
    independently); must pass
    `shellcheck`.
23g. `.github/workflows/tech-debt-close-guard.yml` and
    `scripts/tech-debt-close-guard.sh` implement requirement 25b's advisory
    close-guard: on every `issues` `closed` event carrying `pw::type:tech-debt`
    (filtered at the job level, so an unlabelled issue's close never checks
    out the repository), the script asks whether the close carries evidence —
    a linked closing pull request (`closedByPullRequestsReferences`,
    `includeClosedPrs: true`) or commit (`timelineItems`'s
    `ClosedEvent.closer`) for a `completed` close, a comment already present
    for any of them — and posts exactly one comment
    naming what is missing when neither is found, marked
    `<!-- agent-ops:td-close-guard closed_at=<issue's own closed_at> -->` so a
    workflow re-run never double-posts for the same close. A `not_planned` or
    `duplicate` close is judged on the comment alone and never asks GitHub for
    a closing pull request it could not have. The guard's own
    past comments are excluded when counting "a comment already present".
    That comment read pairs `--paginate --slurp` with a *separate* `jq`, never
    `gh`'s own `--jq`, which `gh` refuses alongside `--slurp` (issue #1116):
    the empty stdout that pairing returns would read as "no comments at all"
    and cost requirement 25b both of its guarantees at once — a compliant
    close guarded anyway, and a second comment on every workflow re-run.
    Always exits 0 except on malformed arguments (usage, exit 2, before any
    `gh` call): a comment-post failure is reported as a `warning`, never a
    failure of the run. The comments fetch's own exit status is captured
    separately from the `jq` normalisation that follows it (issue #1240): a
    failed fetch is reported as a `warning` ("cannot verify: comments fetch
    failed") and posts nothing, rather than being read as "no comments at
    all" — which would risk both a spurious comment on a compliantly-closed
    issue and, on a workflow re-run during the same outage, a second comment
    for the same close.
    Regression-tested in `test/tech-debt-close-guard.test.sh` (unlabelled
    issue skipped with no `gh` call at all; a linked pull request or commit,
    or an existing comment, each independently sufficient for `completed`; a
    `not_planned` or `duplicate` close needing only a comment, the
    `duplicate` one asking GitHub nothing about a closing pull request; an
    empty `state_reason` following the `completed` rule while an unknown one
    is named verbatim rather than reported as completed; a stub that refuses
    `--slurp` with `--jq` the way the real `gh` does, so the comment read
    cannot silently regress to issue #1116's empty answer; the guard's own
    past comment excluded
    from "a comment already present"; the same close's marker never posted
    twice while a different `closed_at` is judged fresh; a failed post
    reported as a warning; a failed comments fetch reported as a warning with
    no comment posted and no graphql call made; malformed arguments exiting
    2); must pass `shellcheck`.
24. `scripts/render-toc.sh` and `.github/workflows/toc.yml` implementing
   requirement 52's generated-table-of-contents property, for the files
   `lib/markdown-scan.sh`'s `TOC_FILES` (the own-heading kind) and
   `TOC_DIR_FILES` (the directory-wide kind) list, matching the markers by
   that library's `toc_start_re` and `toc_end_re`, the list and grammar
   component 24b reads to leave these regions out of the size budget: before
   rendering each file, verifies it contains exactly one `<!-- toc:start -->` /
   `<!-- toc:end -->` marker pair with the start marker on an earlier line
   than the end marker — a file with neither marker, only one of the pair,
   more than one of either, or the pair in reversed order, fails the script
   (non-zero exit, naming the file) in both the plain and `--check`
   invocations, rather than being copied through unchanged (or, for the
   reversed case, silently corrupted) the way a bare awk pass over an
   unmatched or misordered marker would otherwise do — matching
   `render-config-table.sh`'s own region-validation precedent (component 16)
   of hard-failing on a malformed region rather than silently mis-rendering
   it. Once validated, with no arguments: for a `TOC_FILES` entry (each guide
   under `docs/guides/`), extracts every `##`/`###` heading from the file
   itself — skipping anything inside a
   fenced (```` ``` ```` or `~~~`) code block, as `lib/markdown-scan.sh`'s
   `markdown_unfenced` reads one for this and for component 24a alike (a
   fence opens on a run of three or more of either character, however far
   indented, and closes only on a run of the same character at least as
   long, a carriage return that ends a line being ignored) — and rewrites
   the file's own
   `<!-- toc:start -->` … `<!-- toc:end -->` region with a nested bullet
   list linking to GitHub's own heading-anchor slug (lower-cased, stripped
   to `[a-z0-9_-]` and space, spaces to `-`; GitHub does not collapse
   consecutive hyphens, so this script does not either), de-duplicated in
   heading order the way GitHub's own renderer de-duplicates repeated
   headings (the first occurrence keeps the bare slug, each later one is
   suffixed `-1`, `-2`, …). For a `TOC_DIR_FILES` entry
   (`docs/spec/implementation/README.md` and `docs/spec/dashboard/README.md`),
   lists every other Markdown file under the paired directory instead,
   linking each sibling's own first heading, nested one level per
   sub-directory. `--check` renders every region to a temporary
   file instead, leaving the working tree untouched, and exits non-zero
   naming the first stale file — the same contract
   `scripts/render-config-table.sh` (component 16) follows. `.github/workflows/toc.yml`
   runs `--check` on every pull request and on push to `main`, modelled on
   `config-table.yml`. Must pass `shellcheck`.
24a. `scripts/docs-benchmark.sh`, `lib/docs-benchmark.sh`,
   `lib/docs-benchmark-report.sh`, `test/docs-benchmark/questions.jsonl` and
   `.github/workflows/docs-benchmark.yml` implementing requirement 52a: the
   documentation benchmark, a developer tool that no pipeline runs. Each
   record of the questions file carries `id`, `reader`, `question`, `answer`
   (the gold answer), `sources` (a path with one `heading`, `requirement` or
   `check` locator) and `must_mention` (the facts a correct answer must
   contain). `docs_benchmark_check_questions` validates every record, checks
   that each backticked token of a required fact appears in its gold answer
   and that no fact begins with a list number, and, given a root, follows
   every source: reading each file once through `lib/markdown-scan.sh`
   (component 24), it accepts a `heading` only as a heading of that file
   word for word, backslashes included, a `requirement` only as a numbered
   label inside `## Requirements`, and a `check` only as one inside
   `## Acceptance checks`, so that a component, an actor or a line of fenced
   code never passes for either. The runner's `--check` follows them against
   its own checkout, and the workflow runs `--check` on every pull request,
   merge group and push to `main`, ungated by paths, because the image's
   test suite does not run for a documentation-only change.
   Given a Git ref (`main` by default), the runner clones this checkout's
   `origin` without checking it out, and `docs_benchmark_checkout` checks the
   ref out sparsely, leaving out every path named `*docs-benchmark*`, then
   removes `.git`; the answering run therefore sees neither the benchmark nor
   a status or a history that names it, in a directory whose path does not
   name it either. The runner asks each question of `claude -p` in that tree,
   with the fixed model at a fixed effort, the Read, Grep and Glob tools only,
   no MCP server and project settings only, in an environment from which every
   `CLAUDE*`, `ANTHROPIC_*MODEL*`, `MAX_THINKING_TOKENS` and
   `DISABLE_PROMPT_CACHING*` variable is cleared apart from those that
   signing in and choosing a provider need, and has a second, separate
   `claude -p` with no tools, launched from an empty directory, grade the
   answer fact by fact. Each run is started in the background and waited
   for, so that a Ctrl-C, TERM or HUP stops the run in flight by its process
   group and then the runner, which exits 128 plus the signal's number.
   The grader's reply is read whatever prose or braces surround it, in passes
   linear in its length: the last object in it with a `facts` array is the
   verdict. Each judgement is matched to its required fact by the fact's text
   as the grader echoed it, ignoring case, spacing, punctuation and a leading
   list number, so the order of the reply does not matter; a reply whose
   echoed facts are not the question's, one each, or whose judgements are not
   booleans, is recorded as ungraded, never guessed at. `passed` comes from
   the per-fact judgements; the grader's own overall verdict is kept beside
   it, and a contradiction between the two is flagged while an absent
   overall verdict is not. For each question the runner records the answer,
   the grade with the grader's reasoning, the tool calls, the input and
   output tokens (`metering_fields`, component 3a's `lib/metering.sh`) and
   the wall time (`$EPOCHREALTIME`, read with either decimal mark). An
   answer or a grading stopped at its time cap, whether by TERM (exit 124)
   or by KILL after it (exit 137 at or past the cap), is recorded as
   ungraded and says so, and any other failure keeps its exit status. The
   runner names its run directory when it starts and writes the run's
   description before the first question, so a run stopped part-way can be
   rendered, and its report says how far it got. A full run writes
   `docs/reviews/<date>-docs-benchmark.md` with the raw records beside it as
   `.jsonl`, a later full run on the same day takes the suffix `-2`, `-3`
   and so on, and a `--only <id>` run writes
   `<date>-docs-benchmark-only-<id>.md`, so that it never takes the day's
   full-run name. The report is rendered by `docs_benchmark_render_report`
   from the run's records and its description, which the run directory
   keeps; a report that cannot be written exits 3, names both files, and can
   be rendered from them again. `--dry-run` prints every question and the
   commands it would run, and launches nothing. `--calibrate` grades each
   question's own gold answer against its own required facts, clones
   nothing, writes no report, and exits 1 when any gold answer fails. A run
   that needs a tool that is not on `PATH` (`jq`, `claude`, `timeout`,
   `sha256sum` or `git`) exits 2 before anything is cloned, asked or
   written. The protocol (the models and their efforts, the argument lists
   and the cleared environment, the prompts, the time caps, the checkout,
   the reading of each run's stream, the classification of an unanswered
   question and the record) is named by `DOCS_BENCHMARK_PROTOCOL_VARIABLES`
   and `DOCS_BENCHMARK_PROTOCOL_FUNCTIONS`, `stage_result_line` and
   `metering_fields` among them, and `docs_benchmark_protocol_hash` hashes
   those definitions as Bash prints them, so that comments, layout, the
   question check, the report and the rest of the two borrowed libraries
   leave the hash alone. The questions hash covers each record's `id`,
   `reader`, `question`, `answer` and `must_mention`, in id order, and not
   its `sources`, which no run reads. Each report records both hashes and the
   Claude Code version, and is comparable with another when all three match.
   `DOCS_BENCHMARK_QUESTIONS`, `DOCS_BENCHMARK_REPORT_DIR` and
   `DOCS_BENCHMARK_SOURCE` let the test run the whole script against a stub
   `claude`. Acceptance check 52a. Must pass `shellcheck`.
24b. `scripts/check-docs.sh`, `scripts/docs-size-ratchet.tsv`,
   `scripts/docs-phrasing-ratchet.tsv` and `.github/workflows/docs.yml`
   implementing requirement 52b: the five offline documentation checks
   `toc.yml` and `config-table.yml` do not make. With no arguments or with
   `--check` it runs all five and exits non-zero naming each violation — the
   two forms do the same thing, unlike components 16 and 24, because there
   is nothing here to render, and `--check` exists only so that every
   documentation gate takes the same invocation. It reads each file through
   `lib/markdown-scan.sh` (component 24), sharing that library's `gh_slug`
   with `scripts/render-toc.sh` and adding `markdown_heading_texts` and
   `markdown_heading_slugs` to it for the heading lookups the two citation
   and fragment checks need. The size check reads the same library's
   `markdown_generated_regions`, which finds the regions that library lists by
   their markers outside fenced code, so a marker shown in an example opens
   nothing, and it counts each region's bytes from the file itself, fenced
   code inside the region included. It scans for regions only in a file whose
   whole size is over the budget or that has a ratchet entry, and the
   dead-entry pass reads the sizes that scan measured. Headings, slugs and
   whole bodies are
   cached per file, the body cache as a scratch file matched with `grep -F`
   rather than a Bash string, because `docs/spec/implementation/README.md`
   alone unfences to 2.3 MB and Bash's own glob matching has no fast substring
   path; both cache helpers must be called as plain statements, never in
   command substitution, which would fork the assignment into a subshell and
   silently turn every call into a cache miss. Soft-wrapped paragraphs are
   joined before citations are matched, so a citation split across a line
   break still reads as one span, and a leading comment marker is stripped
   first in a script or workflow, where each line of a comment block carries
   its own. A citation matches a heading exactly, with the heading's leading
   article dropped, or as a prefix of either (prose routinely stops before a
   heading's parenthetical or em-dash suffix), and failing all three is
   accepted if the quoted text still appears in the file at all, since this
   repository's style quotes bullets and bold labels as well as headings.
   `test/check-docs.test.sh` builds one scratch repository per scenario out
   of fixture documents and runs the shipped script against it, so no
   scenario's break leaks into another's baseline. Acceptance check 52b.
   Must pass `shellcheck`.

