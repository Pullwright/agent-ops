## Requirements

### The Co-Ordinator — requirements, continued (part 3 of 3; 17g–18: The reservation-release retry sweep…)

17g. <a id="impl-17g"></a>**The reservation-release retry sweep.** A `td/<id>`/`td-record/<id>`
    tech-debt reservation branch a failed cleanup delete could not remove is
    not left orphaned for good: since TD-PPagop-26082427, that
    failure wrote a durable marker into the state repository instead of
    only logging and swallowing it, and this sweep is what
    retries it. The cleanup that wrote such a marker was `lib/tech-debt-file.sh`'s
    own `_techdebt_unfile`, on `techdebt_file_debt`'s old id-reservation
    filing path; agent-ops#874 retired that path (component 23d), so this
    sweep now only ever has pre-existing markers left to drain, never a fresh
    one. `scripts/release-pending-reservations.sh` walks every marker
    under `reservation-releases/` in `state_repo`, one invocation covering
    every configured repository at once — each marker already names its own
    target repo, so this is not a per-repo loop the way 17b/17c are — and
    for each: retries the branch's own delete; on success, or on a delete
    that fails but a follow-up read confirms the branch already gone
    (released by a peer's own concurrent retry), clears the marker; on a delete that fails
    again, leaves the marker for the next cycle's pass. Recovery therefore
    costs no more than time — the marker survives until the transient
    GitHub failure that first defeated `_techdebt_unfile` finally clears, or
    until a human deletes the branch by hand and lets this sweep notice and
    clear the stale marker on its next pass. Where a `td-record/<id>` marker
    and its sibling `td/<id>` marker for the same `id` both sit in the same
    repo's directory under `reservation-releases/` — the shape a window that
    failed both of `_techdebt_unfile`'s own deletes leaves behind — this
    sweep fetches and classifies every marker in that directory before
    acting on any of them, then releases every `td-record/<id>`-branch
    marker before any `td/<id>`-branch marker, matching `_techdebt_unfile`'s
    own record-before-reservation ordering regardless of what order the
    state repository's own directory listing names the two files in
    (TD-PPagop-26082805). A delete that keeps failing is
    not retried and warned about identically forever, though: once the
    marker's own `ts` is at least `reservation_release_stuck_after_days` old
    (TD-PPagop-26082806, agent-ops#1011; `0` restores the old unconditional
    retry-forever behaviour) and it has not already been flagged, this sweep
    treats it as stuck rather than merely transient — an archived target
    repository, a protected branch, a login that lost push access — and
    escalates exactly once: it writes `escalated_at` back onto the marker
    itself (a CAS `PUT` against the same `sha` this pass already read) and
    reports it, rather than the usual `warning`. The branch delete is still
    retried every pass after that, same as before — it is cheap, and it is
    what lets a belated fix on the target-repo side self-heal via the
    ordinary released/absent path above — but a marker already carrying
    `escalated_at` reports nothing further on a delete that keeps failing:
    the one-time escalation already told a human, and repeating it, or
    falling back to `warning`, would be exactly the identical-every-cycle
    noise this behaviour exists to stop. A marker whose `escalated_at` write
    itself fails is treated as not yet escalated and reported as an ordinary
    `warning` instead, so the next pass gets another chance to persist it
    rather than silently losing the escalation. Logged as
    `reservation-release-retried` (`outcome: "released"|"absent"`), or a
    `warning` naming the repo and branch a delete or a marker-clear failed
    again on, or — the once-only stuck case above —
    `reservation-release-stuck` naming the repo, branch and how long the
    delete has been failing. Every node may run it concurrently: a second
    delete of an already-gone branch is a no-op and a second clear of an
    already-cleared marker 404s, which this sweep already treats as nothing
    to report — the same race tolerance 17b/17c already rely on. Skipped on
    `--dry-run`: it deletes refs and state-repo markers. A no-op — logged as
    nothing, since there is nothing to warn about — where `state_repo` is
    unset, the same single-node reading `lib/claim.sh`'s own claim registry
    gives it.
18. <a id="impl-18"></a>When it skips a blocked item, it may cheaply verify whether the recorded
    blocker still holds; if the blocker is demonstrably gone, it reports
    that in its final message so the Script can append an `unblocked` event,
    and may then treat the item as a candidate this same cycle. Two limits,
    both load-bearing (requirements 9b, 34c):
    - This applies to *impediments only*. Discovering that the item's work is
      already **done** is never grounds to unblock it — that is a void, and
      unblocking it hands it back to the pool to be rediscovered every cycle.
      Say so explicitly in the prompt, with the reasoning: an agent told to
      "clear blockers that no longer apply" will otherwise conclude, correctly
      and disastrously, that an already-done item has no blocker.
    - It may **never** clear a void item, and is given no field with which to
      try. It may *create* one, in `voided`, for a candidate it can see
      conclusively is already done, which saves an entire Implementer run — with
      the `reason` and the `evidence` requirement 34c has always demanded, and
      subject to requirement 34d's guard, which records an unevidenced or
      refuted entry as blocked instead.
