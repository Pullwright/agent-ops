## Requirements

### The Script — requirements, continued (part 13 of 13; 8d–8d: The arming step (D18 WI-7, same design §5.1/§6/§7; agent-ops#410)…)

8d. <a id="impl-8d"></a>**The arming step (D18 WI-7, same design §5.1/§6/§7; agent-ops#410).**
   Immediately after `run_approver_stage` returns — never before, and gating
   nothing above it, the same placement 8b already establishes for the
   Approver stage itself relative to the handoff — `run_landing_stage`
   (`lib/landing.sh`, called from `agent-cycle.sh`'s own phase sequence)
   decides whether to land the
   pull request this cycle just reviewed. It arms nothing at all unless this
   very round's own Approver engagement reached an explicit, non-adjudicating
   `approve` — an adjudication's own `land` does not count, because a
   disagreement settled this round is not the same fact as an engagement
   that agreed the first time, and a tier the Approver stage never reached
   at all (the stage disabled, a credential absent, an unparseable verdict)
   arms nothing by construction. Everything else is re-read fresh from
   GitHub at the moment of decision, never reused from earlier in the round
   — the same discipline `lib/review-gate.sh` established for the ready-gate
   handoff, applied here because nothing that arms an automatic merge may
   trust state more than one function call old:

   1. `merge_autonomy_effective_level` (`lib/merge-autonomy.sh`), called
      with `FRESH` (issue #513) so the kill switch bypasses this process's
      own memo — must still be `agent-merges-routine` or
      `agent-merges-all`. The kill switch or a WI-6 budget freeze may have
      moved since the Approver stage ran. A refusal here names its actual
      cause (`landing_autonomy_refusal_reason`, `lib/landing.sh`, D18 issue
      #576, exercised end to end — one case per `merge_autonomy` rung — by
      `test/landing-kill-switch-wiring.test.sh`): a second, independent read
      of `merge_autonomy_kill_state` (also `FRESH`, since gate 1's own LEVEL
      read already carries it) tells the fleet-wide kill switch apart from a
      repository that simply has not had its level raised, since LEVEL alone
      is the *collapsed* answer and does not itself say why it collapsed. The
      `kill-switch:` tag this branch prefixes onto its `reason`
      (`landing-refused`, requirement 33) is what lets
      `scripts/publish-dashboard.sh`'s landings digest (`byReason`,
      `dashboard/index.html`) group it apart from every other refusal class,
      including the plain "effective level is …" wording this gate emits
      when the level was simply never raised — one tag among the class
      prefixes every colon-carrying refusal reason in this step wears
      (requirement 33).
   2. `landing_eligible` (`lib/landing.sh`) — the deterministic classifier: a
      `complexity:*` grade in this repository's own
      `merge_autonomy_routine_complexity` (default `["low", "medium"]`; D18
      Stage 3, agent-ops#725), a `source` in this repository's own
      `merge_autonomy_routine_sources`, and `landing_protected_paths_hit`
      reporting no protected path touched (`.github/`, `deploy/`,
      `prompts/`, `lib/`, `config.schema.json`, `CODEOWNERS` — anchored
      whole-path prefixes, in the shape `scripts/is-docs-only.sh` uses for
      its own allowlist; `lib/landing.sh` is self-protecting through the
      `lib/` prefix already). Reads the changed-file list fresh from GitHub
      (`gh api repos/SLUG/pulls/N/files`), bounded and truncation-checked
      the way `lib/github-limit.sh`'s `GITHUB_PR_LIST_LIMIT` bounds a `gh pr
      list` — a truncated or unreadable list is `unknown`, never a pass, and
      so is a `merge_autonomy_protected_paths` list `_landing_is_protected`
      cannot even evaluate against a path (a non-string entry, which raises
      rather than returns false; TD-PPagop-26082320) — never read as "no
      protected path touched" merely because the comparison itself failed.
      The two causes are distinct exit codes from `landing_protected_paths_hit`
      (2 for the changed-file list, 3 for the protected-paths list) and
      `landing_eligible` names which one fired in its own `unknown:` reason
      text, rather than blaming the changed-file list regardless of cause
      (TD-PPagop-26082325). Any exit code outside `landing_protected_paths_hit`'s
      documented 0/1/2/3 contract (e.g. 128+n from the command-substitution
      subshell being signal-killed mid-gate, agent-ops#1232) is `unknown` too
      — `landing_eligible`'s own `hit_rc` case names the legitimate exit 1
      explicitly and fails every other unrecognised code closed, rather than
      falling through to the same `eligible` arm exit 1 reaches. `unknown` is
      treated as `ineligible` at this and every other call site; an empty or
      unrecognised `source` or
      `complexity` is `ineligible`, never eligible by omission. Widening
      `merge_autonomy_routine_complexity` to admit `high` interacts with
      requirement 26a, which already forces that grade onto anything
      touching concurrency/locking, security, CI/workflow machinery or
      shared library code — so this key's ceiling and that rule's floor meet
      at the same diffs, and the protected-path gate below stays in force
      regardless of this key (risk register item 1's belt and braces).
      Protected paths refuse arming at every level below
      `agent-merges-all` unconditionally. At `agent-merges-all` a hit
      is deliberately reported `eligible` instead (D18 WI-12, Stage 4,
      agent-ops#415) — this classifier alone cannot see the two
      compensating controls §7 risk 1 requires, so it defers rather than
      refuses, and gate 4.5 below is what actually decides. A resolved
      `merge_autonomy_protected_paths` of `[]` — schema-valid, since the
      schema constrains each entry to a non-empty string but sets no
      `minItems` — disables this gate for that repository at every level: an
      operator may legitimately want that for a repository whose own gate
      code lives elsewhere, so this classifier honours the empty list
      exactly as any other, but reaching it silently would leave a
      repository at `agent-merges-routine` or above with its deadliest
      landing gate off with nothing to show for it; `scripts/doctor.sh`
      (component 14, D18 Stage 3, TD-PPagop-26082403) warns, naming the
      repository and its configured level, when its resolved list is empty
      and its configured `merge_autonomy` is `agent-merges-routine` or
      above, the same shape as its neighbouring `landing_cool_off_hours 0`
      warning.
   3. `review_gate_verdict` (`lib/review-gate.sh`) — must read `clean`.
      Stricter than the ready-gate handoff's own use of this function
      (requirement 31a): there, an alerts-only `unknown` still lets the
      handoff proceed with a logged warning; here, any word but `clean` —
      `dirty` or either flavour of `unknown` — refuses arming outright.
   4. The Approver App's own review is genuinely standing `APPROVED` on
      GitHub right now (`landing_approver_standing_review`,
      `lib/landing.sh`), and no human `CHANGES_REQUESTED` stands
      (`_handoff_blocking_reviewers`, `lib/handoff.sh`, requirement 34a's
      own standing-position computation, reused rather than re-derived for
      the human half). Both fresh reads, and the first is not redundant
      with the explicit `approve` gate 0 already required: `approver_post_or_warn`
      always returns 0 even when the write itself failed ("a missing
      review, never a stranded PR", requirement 8b) — a review GitHub
      itself refused reaches this point with `approver_stage_verdict` still
      reading `approve`, which is this process's own *intent*, never proof
      the review exists. `_handoff_latest_reviews` cannot answer the first
      half either way — it excludes bots outright (requirement 34a), and
      the Approver posts as one — so `landing_approver_standing_review`
      reads the same endpoint directly, filtered to the App's own login.
      `landing_approver_standing_review_at` (D18 WI-12) is what this gate
      actually calls — the same one reviews-list read, plus the standing
      review's own `submitted_at` and `commit_id`, at no extra cost — since
      gate 4.5 needs both and it is never worth a second fetch.

      Neither of the two reads above sees a plain comment: a human cannot
      leave a formal `REQUEST_CHANGES` review on this system's own pull
      requests at all (GitHub refuses that review type from a pull request's
      own author, and every pipeline write and every human comment here land
      under the same account), so an ordinary comment is their only
      instrument, and `_handoff_blocking_reviewers` reads only formal
      reviews. `lib/reconciliation-gate.sh`'s `reconciliation_gate`
      (requirement 31c, agent-ops#533) already closes that gap at the
      Reviewer's own ready-flip — a pull request carrying an unreconciled
      comment since it last left draft cannot be flipped Ready in the first
      place — but that gate runs once, at hand-off, and does not reach here:
      a plain comment posted after the pull request is already Ready, in the
      window before a later cycle's arming step lands it, was answered by
      neither mechanism (agent-ops#672). Gate 4 closes that residual window
      by calling `reconciliation_gate` itself a second time, unbounded (no
      `NOT_AFTER`) — this stage never flips the pull request out of draft the
      way the Reviewer's own call must guard against, so the real current
      "last left draft, and stayed left" anchor is exactly the read this gate
      needs. `dirty` refuses arming, naming the unreconciled comment(s) as
      the reason; any other answer that is not `clean` — `unknown`, where the
      timeline or the comment list could not be read, and the empty word left
      behind by a call that did not execute at all — refuses too (#753's
      ruling on agent-ops#746), naming the pull request and what could not
      be confirmed. Neither is unfolded as a case distinct from the other,
      and neither is conditioned on `merge_autonomy_effective_level`: unlike
      the Reviewer's own reconciliation read at hand-off, which does
      tolerate an `unknown` there with a logged warning, this arming-time
      instance never lets an unanswered question pass. Only the exact word
      `clean` passes silently: a veto check that reads as clear on the one
      path where it never ran is the failure this gate exists to prevent.
      Because every non-`clean` word now refuses before this gate sequence
      can reach an arm, the landing audit record (acceptance check 8x) can only
      ever carry a `comment-reconciliation` entry reading `clean`.
   4.5. D18 WI-12 (Stage 4, agent-ops#415): only at `agent-merges-all`, and
      only for a pull request `landing_protected_path_controls_ok`
      (`lib/landing.sh`) itself re-confirms still touches a protected path —
      gate 2 above already deferred, rather than refused, that case. Three
      controls must hold — the two compensating controls §7 risk 1 names,
      plus the head-match that is what makes the second of them measurable
      here: the
      approving engagement ran at the Critical tier (requirement 8b's own
      `critical_reason`; read from this round's own in-process fact on the
      round that first approved the pull request, or from the fleet log's
      `approver-verdict` event, `landing_retry_tier`, on a landing-retry
      sweep re-arm outside that round — acceptance check 8u); the standing
      review's own `commit_id` (gate 4's own read) still matches a fresh
      read of the pull request's current `headRefOid`; and the configurable
      `landing_cool_off_hours` (default 24, `0` disables) has elapsed since
      gate 4's own `submitted_at`, re-read fresh every time this gate runs
      rather than cached anywhere. A push after approval moves `headRefOid`
      without touching the standing review at all — nothing in this
      pipeline dismisses a stale review on push — so a `commit_id` mismatch
      refuses on its own, regardless of how much of the cool-off has
      otherwise elapsed: there is no fresher `submitted_at` to measure from
      until the Approver reviews the new head, which is the sense in which
      a fresh push restarts the wait rather than merely pausing it. Any
      control unmet refuses, naming the tier it actually found, the
      mismatched commits, or the remaining cool-off time; an unreadable
      re-check of the changed-file list or of the pull request's current
      head is `unknown`, never a pass. A pull request that does not touch a
      protected path at all clears this gate immediately, since none of the
      three controls applies to it.
   5. `merge_budget_decide`/`merge_budget_apply_decision`
      (`lib/merge-budget.sh`, requirement 2.3c) — only `arm` proceeds.
      `hold` (the budget is exhausted) and `refuse` (the count could not be
      established) are applied — logging `merge-budget-hold`, or a
      `warning` for `refuse` — and stop here; neither arms anything, and
      this call itself does not queue a retry of its own. The landing-retry
      sweep (acceptance check 8u, "## The Landing Gate") is what re-enters this
      whole gate sequence for such a pull request on a later cycle, rather
      than this gate doing so itself. `merge_budget_decide` reads an
      ALREADY_ARMED count from its own caller and discounts it from the live
      merged-PR count before comparing to the cap — GitHub's own record only
      ever shows a pull request as merged once the merge has actually landed,
      never the moment this gate arms its enqueue or auto-merge, so any two
      calls into this gate within one cycle must share a running tally or
      each reads the same not-yet-merged count and both arm (requirement
      8u's own bound; PR #557 review round 2 widened this from a tally
      private to the landing-retry sweep's own pass to
      `landing_armed_by_repo`, a cycle-scoped map keyed by repository slug
      that this gate's two call sites — the sweep and this stage's own gate
      0 — both read and grow, since either can run first within one cycle
      process).
   6. `merge_queue_probe` (`lib/merge-queue.sh`) — the pull request must not
      already be queued, and must not have been queued and removed without
      being re-queued since. "Could not read" is "possibly queued or
      dequeued" (the same rule the merge-queue-awareness discipline already
      applies elsewhere in this document), so it refuses too. A dequeue this
      stage finds is never its own to retry (PR #557 review round 2):
      `merge_queue_dequeue_actionable` (`lib/merge-queue.sh`) only ever
      chooses the refusal's wording, never whether it refuses — a `manual`
      removal is the maintainer's own deliberate act, reversing it would
      silently undo their click every cycle for as long as the pull request
      stays open, and any other reason (chiefly `failed_checks`) is exactly
      what `scripts/gather-dequeued.sh`'s own `dequeued` source exists to
      diagnose and fix before a human re-queues — arming it blindly here
      instead would re-run the same failing merge group once per cycle
      indefinitely, for no forward progress.

   Any read above that cannot be answered is a refusal — logged
   `landing-refused` (requirement 33) — never a pass, and every refusal
   path costs exactly that: one log event, never a blocked pull request,
   never a withheld claim, the same "a missing action costs a missing
   action, never a stranded PR" contract 8b already establishes for the
   Approver stage. Only once every gate above clears does `landing_arm`
   (`lib/landing.sh`) perform the one write: `merge_queue_for_branch`
   (`lib/merge-queue.sh`, beside `merge_queue_probe`) reads whether the pull
   request's base branch itself carries an active merge queue — where it
   does, `enqueuePullRequest` (GraphQL); where it does not, `gh pr merge
   --auto --squash`. Both run under the Approver App's own minted
   installation token, as a leading one-invocation `GH_TOKEN="$token" gh …`
   assignment — never `export`, exactly as `approver_post_review` already
   does and for the same reason: never the pipeline's own authoring
   identity — the owner's `GH_TOKEN`, or, once provisioned, the forge
   authoring App (D25, component 14g) — which would collapse the
   two-identity audit trail §5.3 exists for into the same account
   authoring, approving and landing every pull request. A successful arm
   logs `landing-armed`
   exactly once, naming the `method` actually used (`enqueued` or
   `auto-merge`), and never withholds anything requirement 8b already did.
   `auto-merge` names the *call* made (`gh pr merge --auto --squash`), not a
   guarantee it armed anything to fire later: with the `gh` CLI version the
   node image installs, that call merges the pull request immediately from
   `CLEAN`/`UNSTABLE` rather than deferring, and only genuinely arms
   auto-merge from `BLOCKED` (agent-ops#553; `lib/landing.sh`'s own header
   carries the full finding).

   The fleet-wide kill switch and a per-repository downgrade (setting
   `merge_autonomy` back to `human` or `agent-approves`) both disarm
   cleanly: `merge_autonomy_effective_level` is what gate 1 above reads,
   never the raw configured value, so the very next round this function
   runs for a repository at or below `agent-approves` refuses at gate 1
   before any other read — no separate switch, no partial disarm.
