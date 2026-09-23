#!/usr/bin/env bash
#
# lib/pager-invariants.sh — the built-in invariants lib/pager.sh's framework
# ships with. Issue #1278 shipped the first two, chosen to exercise every
# branch of the framework itself:
#
#   verdict-unanimous    a pipeline-act invariant, pure over fleet_nodes_json
#                        alone (stage_health/updater/doctor already travel in
#                        every heartbeat — doctor's own verdict was folded in
#                        by this same change, scripts/state-sync.sh).
#   page-outlived-item   a pipeline-act invariant that reads GitHub directly
#                        (via PAGER_EVAL_REPO/PAGER_EVAL_ESCALATION_LABEL,
#                        lib/pager.sh's own documented exception to "pure
#                        over replicated facts") — an escalation issue's own
#                        terminal state is not a fact any heartbeat or union
#                        log carries.
#
# Issue #1282 (part 3c of #1126's findings) adds five more — fleet liveness
# from a *peer's* vantage, the class where every signal a node emitted was
# one it also consumed, so only another node evaluating it can catch the
# gap. All five are owner-only: none has an automatic fix a pipeline could
# perform on its own behalf, unlike verdict-unanimous's tech-debt filing.
#
#   firing-missed          a *cycling* node — fresh heartbeat, published
#                          role not a standby's (`pager_row_cycling`
#                          below) — whose newest `cycle-start` *or
#                          `cycle-skipped`* (the implementation union log
#                          — either one proves the scheduler fired) is
#                          older than 2× `schedule.cycle_interval_minutes`
#                          while it holds no lock — caught purely from the
#                          union log, since `lock.json` is never published
#                          (scripts/state-sync.sh excludes it) and
#                          `schedule.cycle_interval_minutes` is fleet-wide
#                          config, identical on every node that reads it,
#                          including the evaluating node itself. A standby
#                          is exempt, not merely allowed a longer window:
#                          requirement 2.4 makes its ticks leave no trace
#                          in the union log at all, so there is nothing
#                          there to judge it by in either direction
#                          (agent-ops#1686), which also leaves its own
#                          stopped scheduler invisible until it is
#                          promoted — agent-ops#1788's gap, not one
#                          node-stale covers, since a heartbeat is pushed
#                          from a crontab line of its own. Filing waits
#                          one interval plus a margin so that a promotion
#                          — whose first tick is by definition not in the
#                          log yet — never files a page of its own.
#   node-stale             a node's publication age past 2×
#                          `node_stale_after_minutes` — files only after
#                          `pager_stale_file_after_minutes` (default 180),
#                          a per-key override of the framework's own
#                          `pager_min_firing_minutes` hysteresis
#                          (lib/pager.sh's `PAGER_MIN_FIRING_MINUTES_
#                          OVERRIDE`), because a node gone dark deserves a
#                          faster page than paperwork.
#   updater-stuck          `updater.status == "stuck"` for over 2×
#                          `updater_stuck_after_minutes` on any live node
#                          — every node runs its own updater, standby
#                          included, and one whose image has stopped
#                          rolling cannot safely be promoted
#                          — `.updater.seconds` already carries the
#                          streak's own elapsed time (lib/updater-health.sh),
#                          so no new bookkeeping is needed to test it.
#   review-pipeline-failing  `review-log.jsonl`'s streak of failed review
#                          *runs*, per node, at or above 3 (the same
#                          threshold lib/stage-health.sh's own
#                          `stage_health_verdicts` uses, not schema-backed
#                          for the identical reason that file states: this
#                          class has not yet seen a real incident to tune
#                          it against) with no completed review between —
#                          a run, not an event, because `review-end` is
#                          written on every run whatever happened (see the
#                          function's own header). The fleet-vantage reader
#                          of the same fact `docs/REVIEW-PIPELINE-SPEC.md`
#                          R19 publishes per node as `review_stage_health`
#                          (agent-ops#996): R19 states the verdict, this
#                          files a page on it.
#   dashboard-unreadable   a node's `data.js` took longer than
#                          `pager_dashboard_fetch_seconds` to fetch, or
#                          failed to parse, from a *viewer's* vantage — a
#                          fact no node can observe about itself. Reads a
#                          `dashboard_fetch: {seconds, parsed}` field this
#                          issue defines as the contract #1283's own
#                          viewer-vantage probe is expected to fold into
#                          `fleet_nodes_json` the same way `doctor` was
#                          folded in for verdict-unanimous (#1278); until
#                          #1283 lands and populates it, every row's
#                          `dashboard_fetch` is absent and this invariant
#                          never fires — never a false negative from a
#                          producer that does not exist yet, on the same
#                          null-until-populated convention `doctor`/
#                          `updater`/`stage_health` already use for a peer
#                          row built from a heartbeat that predates the
#                          check.
#
# firing-missed, node-stale, updater-stuck and dashboard-unreadable read
# fleet_nodes_json/the union log exactly as verdict-unanimous does, plus one
# more documented exception each — a threshold `pager_evaluate` cannot derive
# from either argument (PAGER_EVAL_CYCLE_INTERVAL_MINUTES and its siblings,
# lib/pager.sh's own header) — on the identical "plain variable, not a third
# EVAL_FN argument" pattern PAGER_EVAL_REPO already established.
# review-pipeline-failing needs a second union log review-log.jsonl is
# fleet-replicated too (scripts/state-sync.sh does not exclude it), so its
# own union travels the same way, via PAGER_EVAL_REVIEW_UNION_LOG_FILE.
#
# Issue #1281 (part 3b of #1126's findings) adds seven more — the selection
# and ledger invariants: the class that wedged or starved the fleet in
# August and September, this time read from the Co-Ordinator's own
# selection/fit machinery (idle-with-demand, fit-ladder-pinned,
# work-order-repaired-rate) and from the block/escalation ledger
# (blocked-label-orphaned, claim-unreconciled, escalation-burst,
# digest-truncated):
#
#   idle-with-demand        an active node whose last `pager_idle_cycles`
#                           *cycles* — each one's own last `node-state`
#                           event, since `node-state` is emitted several
#                           times per cycle (lib/node-time-state.sh, D21) —
#                           all end `idle-with-demand` with a cause
#                           other than `back-pressure` (a deliberate
#                           throttle, not a symptom) — the D21 state
#                           vocabulary already excludes every externally-
#                           blocking cause (usage-limit, disk/memory,
#                           unauthorized, a fleet/kill-switch's own `down`)
#                           on its own terms, so no separate stand-down
#                           reclassification is needed here. owner-only:
#                           the evidence embeds the node's own most recent
#                           `none-selected.reason` and `coordinator-input-
#                           fitted` detail, the two facts a diagnosis
#                           starts from, but there is no fix a pipeline
#                           could perform on the owner's behalf.
#   fit-ladder-pinned       `coordinator-input-fitted` pinned in the
#                           ladder's own entry-dropping segment — rung 11 or
#                           tighter, the first of the 7 entry caps that
#                           follow lib/coordinator-input.sh's 10 prose tiers
#                           (the first entry cap, which #1281's own evidence
#                           sat at when it was rung 9 of an 8-tier ladder) —
#                           with `entries_dropped > 0` in every fitted
#                           cycle a node logged in the trailing 24h.
#                           owner-only: raising `coordinator_prompt_max_
#                           bytes` or shrinking the backlog is an owner's
#                           call, not a pipeline fix.
#   work-order-repaired-rate  more than `pager_repair_rate_percent` of a
#                           day's `selection` events also logged a
#                           `work-order-repaired` (agent-ops#821's own
#                           signature: a work order composed from trimmed
#                           input). owner-only; retire once agent-ops#769's
#                           part (b) lands and agent-ops#1156 removes the
#                           gate this rate reads.
#   blocked-label-orphaned  a live `blocked:needs-refinement`/`blocked`
#                           label with no open block behind it — either
#                           lib/refinement.sh's own `own-label-action`
#                           history shows an `add` with no later `remove`
#                           (`refinement_blocked_label_stale`, pure over
#                           the union log), or a live GitHub read finds one
#                           history cannot prove ours
#                           (`refinement_blocked_label_orphaned`, requirement
#                           38b, agent-ops#816). pipeline-act: the remedy
#                           calls the identical `refinement_label_remove`/
#                           `label_own_action_fields` requirement 38b's own
#                           release path already uses — never a
#                           reimplementation — so a removal that succeeds
#                           clears on the invariant's own next evaluation,
#                           and only a removal that keeps failing stays
#                           filed.
#   claim-unreconciled      an `enabler-examined` event whose `outcome` is
#                           the Enabler's own escalate verdict
#                           (`lib/enabler.sh`'s `outcome="$verdict"`, never
#                           reassigned on that path) in the trailing 24h
#                           with no `escalated` or `tech-debt-filed` event
#                           for the same repo, item
#                           and cycle — agent-ops#815's own signature (#640
#                           sat blocked five days on a claim an
#                           adjudication pass had cancelled) recurring by a
#                           different route (a crash between the two, or an
#                           engagement that never reached its own
#                           reconciliation call). pipeline-act: the remedy
#                           re-checks live and, if still unreconciled,
#                           posts one correction comment naming what could
#                           not be confirmed.
#   escalation-burst        more than `pager_escalation_burst` `escalated`
#                           events fleet-wide in the trailing 24h, or the
#                           same re-flag reason (the triggering
#                           `attempt-failed`'s own `detail`/
#                           `unblock_condition`, fingerprinted with
#                           `escalation_autonomy_decide_reason_key`,
#                           lib/escalation-autonomy.sh — requirement 36d's
#                           own per-reason bound, reused rather than
#                           duplicated) paged the same item twice inside
#                           that same window. owner-only: the evidence
#                           carries the reason histogram.
#   digest-truncated        a repo's most recent `source-state-digest`
#                           event (lib/candidate-gather.sh, logged
#                           alongside `gather_source_state`'s own already-
#                           fetched counts — no extra `gh` call on that
#                           cheap per-cycle path) still claiming `ok: true`
#                           while undercounting a live total this
#                           invariant fetches itself, once per evaluation
#                           rather than once per node per cycle — the
#                           agent-ops#1165 signature (requirement 34i read
#                           absence-from-digest as "closed" and
#                           false-cleared every block past the newest
#                           hundred) recurring. pipeline-act: the remedy
#                           logs a `digest-truncation-veto` for the
#                           affected repo, which `lib/candidate-gather.sh`
#                           checks before trusting that repo's digest —
#                           "refuse to act on absence for that cycle" — then
#                           files, a durable record if it keeps recurring.
#
# Issue #1280 (part 3a of #1126's findings) adds three more — landing and
# approval: the class that lets a pull request sit ready, or a whole
# repository stop landing, with nothing any existing invariant reads
# catching it, because the facts live in the Landing Gate's own refusal path
# and the Approver's own unreviewed-trigger memory rather than a node's
# liveness or the Co-Ordinator's own selection machinery.
#
#   landing-never-armed     a repository configured at merge_autonomy
#                           agent-merges-routine or above with zero
#                           landing-armed events despite landing-refused
#                           activity in the trailing
#                           pager_landing_armed_within_days (default 7)
#                           window. Caught: #718 — agent-ops sat at
#                           agent-merges-routine from 2026-08-18 with 115
#                           landing-refused and zero armings for six days,
#                           because landing_protected_paths_hit's `gh api …
#                           -F` POSTed and 404'd on every call. Configured
#                           level only, never the live effective level (a
#                           per-repository merge-budget-freeze read this
#                           invariant declines to pay for on every
#                           evaluation, the same approximation the
#                           back-pressure card already makes, D18 WI-6) —
#                           and gated on landing-refused activity in the
#                           same window, so a repository with nothing ready
#                           to land never fires. pipeline-act: files
#                           tech-debt against lib/landing.sh's refusal path,
#                           with the window's own refusal-class histogram as
#                           evidence.
#   landing-refused-unknown  landing-refused events of class `unknown`
#                           (lib/landing.sh's own `unknown:<reason>`
#                           vocabulary — landing_eligible/landing_protected_
#                           path_controls_ok's fail-closed answer when a
#                           live GitHub read could not even be attempted,
#                           never a deterministic ineligible) make up at
#                           least half of a trailing-24h window's
#                           landing-refused events, with at least five.
#                           Caught: the same #718 incident (72 of 115). 5 and
#                           one-half are fixed, un-schema-backed constants —
#                           lib/pager-invariants.sh's own review-pipeline-
#                           failing precedent, this class not yet having seen
#                           a second incident to tune them against.
#                           pipeline-act: files tech-debt.
#   pr-unreviewed           a ready, non-draft, pr_label pull request with no
#                           standing review at all (GitHub's own
#                           reviewDecision, read once per candidate
#                           repository's own `gh pr list` — a superset of
#                           "no standing *App* review" specific enough in
#                           practice, since a third party reviewing an
#                           autonomous pipeline's own draft ahead of the
#                           Approver is not the ordinary case this invariant
#                           needs to rule out), no approver-verdict, no
#                           warning naming it and no approver-unreviewed-
#                           engaged event *at all* — never merely stale, the
#                           total silence that is requirement 46's own
#                           unreviewed trigger (#890) never having run for
#                           this pull request even once. Caught: PR #1059,
#                           stranded when the kill-switch read failed closed
#                           with no log line (#1081) — exactly the silent
#                           skip this invariant is built to notice from
#                           outside the sweep that skipped. createdAt older
#                           than approver_unreviewed_engage_after_hours,
#                           requirement 46's own cutoff, reused rather than
#                           duplicated. pipeline-act: the remedy logs the
#                           identical approver-unreviewed-engaged event
#                           requirement 46's own sweep would (`result:
#                           "unavailable"`, truthful — this framework has no
#                           clone or model credential to post a real review
#                           with) for every candidate found — which starts
#                           the escalate clock `_approver_restale_sweep_repo`
#                           reads (`approver_unreviewed_prior_engagement`)
#                           for a pull request that clock had never started
#                           for at all, so the very next ordinary sweep (any
#                           node, its own next cycle) either posts a real
#                           review or — once
#                           approver_restale_escalate_after_hours passes from
#                           this logged engagement — escalates to
#                           enabler_assignee itself. "Enqueue the
#                           re-engagement, and file if a second window
#                           passes" (the issue's own remedy text): the
#                           logged engagement is the enqueue, the ordinary
#                           sweep's own escalation is the second window, and
#                           this invariant's own pw::pager issue, filed
#                           alongside on the ordinary hysteresis terms every
#                           pipeline-act remedy files under, is never the
#                           only place this is visible.
#
# All three read the union log and the forge alone — never a clone, never a
# host — on the compatibility the issue's own acceptance names for the
# orchestrated-container target.
#
# Sourced after lib/pager.sh; registration itself is a separate call
# (`pager_register_builtin_invariants`), not top-level code, so a test can
# source this file and register only what it means to exercise.

# --- Shared row predicates ---------------------------------------------------
#
# Two different questions get asked of a fleet row, and this file spelled both
# of them `.stale | not` until agent-ops#1686:
#
#   live       the node is publishing — its heartbeat is fresh. The question
#              every invariant over a *published* fact wants: verdict-
#              unanimous's stage_health and doctor verdicts, updater-stuck's
#              own streak. Those are collected on every node whatever its
#              role, so a standby's answer counts exactly as much as an
#              active node's.
#   cycling    the node is one the fleet expects to be *running cycles*: live,
#              and its published role is not a standby's. The question every
#              invariant over the union log's record of cycles wants —
#              firing-missed, idle-with-demand — because requirement 2.4
#              stops a standby's tick before the log, so its newest cycle
#              event is whatever it left behind before it was demoted and
#              only ever grows older.
#
# `PAGER_JQ_ROW_PREDICATES` is prepended to the jq programs that need the
# second, so one definition serves them both rather than a copy each. The
# dashboard's own reading (`dashboard/index.html`, `n.role === "active" &&
# !n.stale`) is a third, in another language; what keeps the two honest is
# that scripts/state-sync.sh and scripts/publish-dashboard.sh now publish the
# role already normalised, so a strict comparison is a sound one.
#
# The role is compared normalised here too — lowercased, whitespace stripped,
# lib/role.sh's own rule — because requirement 2.4's guard compares that way:
# `AGENT_OPS_ROLE=Active` runs unattended cycles, so it must not read as a
# standby here. A node running an image older than that normalisation can
# still publish a raw `Active`, and this is what covers it.
#
# A row whose role is absent or `unknown` counts as cycling. The exemption
# needs positive evidence that a node is standing by; no evidence means what
# it meant before agent-ops#1686 was fixed — judge the node on its cycles.
# `unknown` is what publish-dashboard.sh writes for a peer whose heartbeat
# carries no role at all, and what both publishers write for a process that
# was handed no role; neither is a node saying it is a standby.
PAGER_JQ_ROW_PREDICATES='
def pager_role_normalised: (.role // "" | ascii_downcase | gsub("\\s"; ""));
def pager_row_live: (.stale | not);
def pager_row_cycling:
  pager_row_live
  and (pager_role_normalised | . == "active" or . == "" or . == "unknown");
'

# pager_eval_verdict_unanimous FLEET_NODES_JSON UNION_LOG_FILE
# Fires when every *live* node (`pager_row_live`; fewer than two live nodes
# can never be "unanimous" about anything) reports the identical failing
# verdict at once — the #1071 signature: all four nodes read `updater stuck`
# because the *reader's* rule was wrong, not because every node had
# independently failed the same way at the same instant.
#
# Live, not cycling: stage_health, updater and doctor verdicts are collected
# on a standby exactly as they are on an active node, so a standby's
# agreement is evidence like any other. `$active` below is this invariant's
# own older word for the same test, kept because its evidence line uses it.
#
# Checks, in order,
# the first hit wins: a stage_health stage failing on every active node, the
# updater stuck on every active node, the doctor verdict `fail` on every
# active node.
#
# The doctor branch also names the checks (agent-ops#1397): the `fails`
# entries common to *every* active node, at most two of them, from the
# bounded array scripts/state-sync.sh folds into each heartbeat. The
# intersection is the right set for a unanimity invariant — what all of them
# say is what the suspect reader said — and it is what turns this evidence
# from "every node's doctor is unhappy" into the name of the check to go and
# read, which #1398 could not do and cost a hand search of four nodes.
# Absent (an older peer, still publishing `{timestamp, verdict}` alone) or
# disjoint (nodes failing genuinely different checks) both yield no clause
# rather than a wrong one, and the `stage_health`/`updater` branches, which
# carry no `detail`, keep their evidence byte-identical.
pager_eval_verdict_unanimous() {
  local fleet_nodes_json="$1"
  jq -c -n --argjson nodes "$fleet_nodes_json" "$PAGER_JQ_ROW_PREDICATES"'
    ($nodes | map(select(pager_row_live))) as $active
    | if ($active | length) < 2 then {firing: false}
      else
        ( [$active[] | (.stage_health.stages // {}) | keys[]] | unique ) as $stages
        | ( [ $stages[] as $s
              | ($active | map(.stage_health.stages[$s].verdict? // null)) as $verdicts
              | select(($verdicts | length) == ($active | length))
              | select(all($verdicts[]; . == "failing"))
              | {kind: "stage_health[\($s)]", nodes: [$active[].node]}
            ] | first) as $stage_hit
        | ( if ($active | all(.updater.status? == "stuck"))
            then {kind: "updater.status=stuck", nodes: [$active[].node]} else null end ) as $updater_hit
        | ( if ($active | all(.doctor.verdict? == "fail"))
            then {kind: "doctor.verdict=fail", nodes: [$active[].node],
                  detail: ( [$active[] | (.doctor.fails // [])]
                            | if (length > 0) and (all(.[]; length > 0))
                              then reduce .[1:][] as $f (.[0]; . - (. - $f))
                              else [] end
                            | .[0:2] )}
            else null end ) as $doctor_hit
        | ($stage_hit // $updater_hit // $doctor_hit) as $hit
        | if $hit == null then {firing: false}
          else
            ( ($hit.detail // [])
              | if length == 0 then ""
                else " — failing on every one of them: " + (map("“\(.)”") | join("; "))
                end ) as $detail
            | {firing: true,
               evidence: "\($hit.kind) on every active node (\($hit.nodes | join(", ")))\($detail) — the #1071 signature: a uniform fleet-wide failure is almost always the reader being wrong, not every node failing alike at once"}
          end
      end
  ' 2>/dev/null || printf '{"firing":false}'
}

# pager_remedy_verdict_unanimous KEY EVIDENCE
# Pipeline act: files a `pw::type:tech-debt` issue against the reader — this
# pipeline's own repository, since the code that computed the uniform verdict
# (lib/stage-health.sh, lib/updater-health.sh, scripts/doctor.sh) lives here,
# never in a target repo. Reads PAGER_REMEDY_REPO, set by lib/pager.sh's own
# pager_file immediately before calling this.
pager_remedy_verdict_unanimous() {
  local key="$1" evidence="$2" repo="${PAGER_REMEDY_REPO:-}"
  [[ -n "$repo" ]] || { printf 'no pager_repo configured — could not file the tech-debt issue'; return 1; }
  local item="pager-reader:$key" body_file created number
  body_file="$(mktemp)"
  {
    printf 'A fleet-wide invariant fired: every active node reported the same failing verdict at once.\n\n'
    printf '%s\n\n' "$evidence"
    printf 'This is the #1071 signature — a uniform failure across the whole fleet is almost always the *reader* (a bad rule, a bad threshold) rather than every node independently failing the same way at the same instant. Find and fix the rule the evidence above names.\n\n'
    printf -- '---\nFiled automatically by lib/pager.sh (issue #1278).\nref: %s\n' "$item"
  } > "$body_file"
  # No ENSURE_ROLE (lib/pager.sh's 7th parameter): `pw::type:tech-debt` lives
  # in the `target` catalogue, and ensuring that whole role here would mint a
  # dozen unrelated pipeline labels (`refined`, `complexity:*`, `blocked`, …)
  # in a repository that is only ever the *reader's* — often, but not
  # necessarily, also a target repo. The retry-without-label path is the
  # safety net instead: unlike `pw::pager`, nothing later finds this issue by
  # its label — the tech-debt register is the human's own filter, and this
  # function's dedup narrows on the body's `ref:` line regardless.
  if created="$(_pager_create_issue "$repo" "$item" "pw::type:tech-debt" \
        "Pager: verdict-unanimous fired ($evidence)" "$body_file" "")" && [[ -n "$created" ]]; then
    number="${created%%$'\t'*}"
    rm -f "$body_file"
    printf 'filed %s#%s (pw::type:tech-debt)' "$repo" "$number"
    return 0
  fi
  rm -f "$body_file"
  return 1
}

# _pager_open_page_issues -> number\turl\tbody(TSV, newlines squashed to spaces)
# per open issue carrying PAGER_EVAL_ESCALATION_LABEL or pw::pager in
# PAGER_EVAL_REPO. Shared by the eval and remedy functions below so both walk
# the identical listing rather than risking two reads disagreeing.
#
# One listing per label, merged and deduped on the issue number, because the
# relation wanted here is a union and `gh issue list`'s own is an
# intersection: `--label "a,b"` splits on the comma and filters for issues
# carrying *every* name given. No page ever carries both of these labels — an
# Enabler escalation is not a pager page and vice versa — so a single
# comma-joined listing is empty in every real case, which would leave this
# invariant permanently `firing: false`.
#
# `--limit 200` rather than `gh`'s undeclared default of 30, on
# lib/tech-debt-file.sh's own TECHDEBT_DEDUP_LIST_LIMIT reasoning: a
# truncated listing is indistinguishable from a complete one, and the
# listing is newest-first, so the page most likely to have outlived its item
# is exactly the oldest one the cap would hide.
_pager_open_page_issues() {
  local repo="${PAGER_EVAL_REPO:-}" label="${PAGER_EVAL_ESCALATION_LABEL:-enabler-escalation}" gh l
  [[ -n "$repo" ]] || return 0
  gh="${PAGER_GH:-gh}"
  { for l in "$label" "pw::pager"; do
      [[ -n "$l" ]] || continue
      "$gh" issue list -R "$repo" --label "$l" --state open --limit 200 \
        --json number,url,body 2>/dev/null
    done
  } | jq -sr 'add // [] | unique_by(.number) | .[]
              | [.number, .url, (.body // "" | gsub("\n"; " "))] | @tsv' 2>/dev/null
}

# _pager_outlived_ref BODY -> "kind\treference" (kind: pr|issue) for the
# first PR or issue URL BODY names, or nothing. A page's body always carries
# one — every escalation this codebase files links the item it is about.
_pager_outlived_ref() {
  local body="$1" ref
  ref="$(grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' <<<"$body" | head -n1)"
  if [[ -n "$ref" ]]; then printf 'pr\t%s' "$ref"; return 0; fi
  ref="$(grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[0-9]+' <<<"$body" | head -n1)"
  [[ -n "$ref" ]] && printf 'issue\t%s' "$ref"
  return 0
}

# pager_eval_page_outlived_item FLEET_NODES_JSON UNION_LOG_FILE
# Fires when any open enabler-escalation/pw::pager page's own item — the PR
# or issue its body links — has already gone terminal (merged, closed).
# Deliberately not a pure union-log reader: an issue's live GitHub state is
# the fact in question, so this reads PAGER_EVAL_REPO/PAGER_EVAL_ESCALATION_
# LABEL/PAGER_GH directly (lib/pager.sh's documented exception).
pager_eval_page_outlived_item() {
  local n _url body kind ref state outlived=()
  while IFS=$'\t' read -r n _url body; do
    [[ -n "$n" ]] || continue
    IFS=$'\t' read -r kind ref <<<"$(_pager_outlived_ref "$body")"
    [[ -n "$ref" ]] || continue
    if [[ "$kind" == "pr" ]]; then
      state="$("${PAGER_GH:-gh}" pr view "$ref" --json state --jq '.state' 2>/dev/null)"
      [[ "$state" == "MERGED" || "$state" == "CLOSED" ]] && outlived+=("#$n")
    else
      state="$("${PAGER_GH:-gh}" issue view "$ref" --json state --jq '.state' 2>/dev/null)"
      [[ "$state" == "CLOSED" ]] && outlived+=("#$n")
    fi
  done < <(_pager_open_page_issues)
  if (( ${#outlived[@]} > 0 )); then
    local joined
    joined="$(IFS=', '; printf '%s' "${outlived[*]}")"
    jq -c -n --arg ev "${#outlived[@]} page(s) whose own item already concluded: $joined" \
      '{firing: true, evidence: $ev}'
  else
    printf '{"firing":false}'
  fi
}

# pager_remedy_page_outlived_item KEY EVIDENCE
# Pipeline act: close every outlived page found — the generalisation of
# #1215's approver_escalation_retire from the adjudication page to every
# page this framework or the Enabler files. Re-walks the listing (one more
# `gh issue list`) rather than parsing EVIDENCE's own prose, so a wording
# change to the evidence string can never desync the two.
pager_remedy_page_outlived_item() {
  local n _url body kind ref state closed=0 comment gh
  gh="${PAGER_GH:-gh}"
  while IFS=$'\t' read -r n _url body; do
    [[ -n "$n" ]] || continue
    IFS=$'\t' read -r kind ref <<<"$(_pager_outlived_ref "$body")"
    [[ -n "$ref" ]] || continue
    if [[ "$kind" == "pr" ]]; then
      state="$("$gh" pr view "$ref" --json state --jq '.state' 2>/dev/null)"
      [[ "$state" == "MERGED" || "$state" == "CLOSED" ]] || continue
    else
      state="$("$gh" issue view "$ref" --json state --jq '.state' 2>/dev/null)"
      [[ "$state" == "CLOSED" ]] || continue
    fi
    comment="This page's own item ($ref) is $state. Retiring — the item this page was raised for has already concluded.

---
Retired automatically by lib/pager.sh (issue #1278)."
    "$gh" issue close "$n" -R "${PAGER_EVAL_REPO:-}" --comment "$comment" >/dev/null 2>&1 \
      && closed=$(( closed + 1 ))
  done < <(_pager_open_page_issues)
  printf 'closed %d outlived page(s)' "$closed"
  return 0
}

# --- agent-ops#1282: fleet liveness from a peer's vantage --------------------

# pager_eval_firing_missed FLEET_NODES_JSON UNION_LOG_FILE
# Fires when an *active* node's newest evidence of its scheduler firing — a
# `cycle-start` or a `cycle-skipped` (agent-cycle.sh's own `acquire_lock`
# logs `cycle-skipped` only when it found the lock held by another live
# pid, which is proof the scheduler ticked on schedule and deferred
# correctly, not proof of anything missing) — is older than 2×
# PAGER_EVAL_CYCLE_INTERVAL_MINUTES while it holds no lock — the signature
# of supercronic dropping a firing outright (agent-ops#1287 records the gap
# from the inside: no `cycle-start`, no `cycle-skipped`, nothing in
# `log.jsonl` at all) as distinct from a cycle that is simply still running,
# or a long cycle whose scheduler keeps ticking (and skipping) around it.
#
# The nodes judged are the *cycling* ones — `pager_row_cycling` above, a
# fresh heartbeat and a published role that is not a standby's — not the
# merely live ones, which is what this read until agent-ops#1686. A standby
# is exempt outright rather than given a wider window, because requirement
# 2.4 stops its tick before the lock, the log and the cycle directory: it
# writes neither a `cycle-start` nor a `cycle-skipped`, so the newest cycle
# event the union log holds for it is whatever it left behind before it was
# demoted, and that age only grows. Any finite multiple of the interval
# therefore pages on a perfectly healthy standby in the end — ockham-2 sat
# at 7,970 minutes when #1768 fired, against the 150 minutes a 10× window
# would have allowed it.
#
# What the exemption costs, stated because the alternative was weighed and
# not taken: a standby whose scheduler has quietly stopped is invisible
# here until it is promoted. node-stale is not the detector for it —
# that reads the heartbeat, which state-sync.sh pushes from its own crontab
# line, so a node that has lost its `agent-cycle.sh` line alone (agent-
# ops#1287's own signature) keeps publishing and looks healthy. Closing
# that gap means giving a standby tick one trace to be judged by rather
# than widening a window that measures nothing, which moves requirement
# 2.4's own ordering; it is filed as agent-ops#1788.
#
# Promotion is the edge a published role alone cannot see. The moment a
# node's role turns `active` its newest cycle event is as old as its
# demotion, so this invariant fires at once — correctly, in that the node
# is not cycling, and uselessly, because its first tick has not come round
# yet. Nothing is *filed* on that: `pager_register_builtin_invariants`
# registers this key with a filing window of one whole scheduling interval
# plus a margin for replication (`MIN_FIRING_MINUTES_OVERRIDE`,
# lib/pager.sh), so the promoted node's first `cycle-start` clears the
# candidate before any page is written, while a node that really is
# dropping firings stays firing across the window and is filed exactly as
# it always was.
#
# Demotion, symmetrically, clears an open page: an operator who demotes a
# broken node to stop the noise gets its page closed as cleared rather than
# left open, because the fleet has stopped expecting cycles from it. The
# evidence stays in the closed issue, and agent-ops#1788 is what would let
# the fault keep being noticed after the demotion.
# `lock.json` itself is never published (scripts/state-sync.sh excludes
# it), so "holds no lock" is derived purely from the union log: a node's own
# newest cycle-start/cycle-end/cycle-skipped event — whichever the union
# log's own timestamps put last — being a `cycle-start` means that cycle has
# not yet ended, i.e. the lock is (or very recently was) held, so a long
# *legitimate* cycle is never mistaken for a missed firing. Staleness itself
# is measured from the newer of the node's last `cycle-start` and last
# `cycle-skipped` — not from `cycle-start` alone — so a cycle that outlasts
# 2× the interval while its scheduler keeps ticking (and correctly skipping,
# because the earlier cycle still holds the lock) never crosses the age
# threshold either; only silence on both counts does. Evidence embeds each
# firing node's age and its own recent cycle-duration histogram (up to the
# last 5 completed cycles, matched by the `cycle` id every cycle-start/
# cycle-end pair shares) — "file, with the node's cycle-duration histogram"
# (#1282's own acceptance).
pager_eval_firing_missed() {
  local fleet_nodes_json="$1" union_log_file="$2"
  local interval_min="${PAGER_EVAL_CYCLE_INTERVAL_MINUTES:-}"
  [[ "$interval_min" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '{"firing":false}'; return 0; }
  [[ -f "$union_log_file" ]] || { printf '{"firing":false}'; return 0; }
  jq -c -R -n --argjson nodes "$fleet_nodes_json" --argjson interval "$interval_min" \
    --argjson now "$(date -u +%s)" "$PAGER_JQ_ROW_PREDICATES"'
    ($nodes | map(select(pager_row_cycling)) | map(.node)) as $active
    | [ inputs | select(length > 0) | (fromjson? // empty)
        | select(.event == "cycle-start" or .event == "cycle-end" or .event == "cycle-skipped")
        | select((.node // "") as $n | $active | index($n) != null) ] as $events
    | ( [ $active[] as $n
          | ($events | map(select(.node == $n)) | sort_by(.ts)) as $node_events
          | ($node_events | map(select(.event == "cycle-start"))) as $starts
          | if ($starts | length) == 0 then empty
            else
              ($node_events | last) as $last_event
              | ($node_events | map(select(.event == "cycle-start" or .event == "cycle-skipped"))
                 | last) as $last_activity
              | ($last_activity.ts | fromdateiso8601) as $start_epoch
              | (($now - $start_epoch) / 60) as $age_min
              | ($last_event.event == "cycle-start") as $lock_held
              | if ($lock_held | not) and ($age_min > (2 * $interval)) then
                  ( ($node_events | group_by(.cycle)
                     | map(select((map(.event) | index("cycle-start"))
                                  and (map(.event) | index("cycle-end"))))
                     | map({s: (map(select(.event == "cycle-start")) | .[0].ts),
                            e: (map(select(.event == "cycle-end")) | .[0].ts)})
                     | map((((.e | fromdateiso8601) - (.s | fromdateiso8601)) / 60) | floor)
                     | .[-5:]) as $durations
                  | {node: $n, age_min: ($age_min | floor), durations: $durations} )
                else empty end
            end
        ] ) as $hits
    | if ($hits | length) == 0 then {firing: false}
      else {firing: true, nodes: ($hits | map(.node)),
            evidence: ("newest cycle-start or cycle-skipped older than 2× schedule.cycle_interval_minutes ("
              + ($interval | tostring) + "m) while the heartbeat is fresh and no lock is held, on "
              + (($hits | map("\(.node) (\(.age_min)m since last cycle-start/cycle-skipped; recent cycle "
                  + "durations in minutes: "
                  + (if (.durations | length) == 0 then "none recorded"
                     else (.durations | map(tostring) | join(", ")) end) + ")")) | join("; ")))}
      end
  ' < "$union_log_file" 2>/dev/null || printf '{"firing":false}'
}

# pager_eval_node_stale FLEET_NODES_JSON UNION_LOG_FILE
# Fires when any node's `heartbeat_age_s` (lib/fleet.sh's
# `fleet_publication_status`, already carried by every row, self included —
# requirement 2.5) exceeds 2× PAGER_EVAL_NODE_STALE_AFTER_MINUTES: past the
# dashboard's own `.stale` badge (1×) and into "the 2026-08-08 both-laptop-
# nodes signature", four days nobody was looking at a page nobody had.
# Files only after `pager_stale_file_after_minutes`
# (`pager_register_builtin_invariants`'s own registration below), a per-key
# override of the framework's ordinary `pager_min_firing_minutes` hysteresis.
pager_eval_node_stale() {
  local fleet_nodes_json="$1" _union_log_file="$2"
  local threshold_min="${PAGER_EVAL_NODE_STALE_AFTER_MINUTES:-}"
  [[ "$threshold_min" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '{"firing":false}'; return 0; }
  jq -c -n --argjson nodes "$fleet_nodes_json" --argjson threshold_min "$threshold_min" '
    (2 * $threshold_min * 60) as $threshold_s
    | ($nodes | map(select((.heartbeat_age_s // 0) > $threshold_s))) as $hits
    | if ($hits | length) == 0 then {firing: false}
      else {firing: true, nodes: ($hits | map(.node)),
            evidence: ("publication age past 2× node_stale_after_minutes on "
              + (($hits | map("\(.node) (\((( .heartbeat_age_s // 0) / 60) | floor)m)"))
                 | join(", ")))}
      end
  ' 2>/dev/null || printf '{"firing":false}'
}

# pager_eval_updater_stuck FLEET_NODES_JSON UNION_LOG_FILE
# Fires when any *live* node's `.updater.status == "stuck"` for more than
# 2× PAGER_EVAL_UPDATER_STUCK_AFTER_MINUTES — live, not cycling: the updater
# is what keeps a node's image current, it runs from its own crontab line
# whatever the node's role, and a standby whose image has stopped rolling is
# a standby that cannot safely be promoted. The header said "active" until
# agent-ops#1686 while the code said `.stale | not`; the code was right.
# `.updater.seconds`
# (lib/updater-health.sh's `updater_status`) already carries the streak's
# own elapsed time, recomputed fresh on every heartbeat write, so this reads
# it directly rather than re-deriving an age from the union log the way
# firing-missed has to for a fact (a lock) that is never published at all.
pager_eval_updater_stuck() {
  local fleet_nodes_json="$1" _union_log_file="$2"
  local threshold_min="${PAGER_EVAL_UPDATER_STUCK_AFTER_MINUTES:-}"
  [[ "$threshold_min" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '{"firing":false}'; return 0; }
  jq -c -n --argjson nodes "$fleet_nodes_json" --argjson threshold_min "$threshold_min" \
    "$PAGER_JQ_ROW_PREDICATES"'
    (2 * $threshold_min * 60) as $threshold_s
    | ($nodes | map(select(pager_row_live))
       | map(select((.updater.status? == "stuck")
                    and ((.updater.seconds? // 0) > $threshold_s)))) as $hits
    | if ($hits | length) == 0 then {firing: false}
      else {firing: true, nodes: ($hits | map(.node)),
            evidence: ("updater.status=stuck for over 2× updater_stuck_after_minutes on "
              + (($hits | map("\(.node) (\((( .updater.seconds // 0) / 60) | floor)m)"))
                 | join(", ")))}
      end
  ' 2>/dev/null || printf '{"firing":false}'
}

# pager_eval_review_pipeline_failing FLEET_NODES_JSON UNION_LOG_FILE
# Fires when any node's streak of failed review *runs* (review-log.jsonl,
# fleet-replicated like log.jsonl — scripts/state-sync.sh does not exclude
# it) reaches 3 with no successful run between. 3 mirrors
# lib/stage-health.sh's own un-schema-backed `THRESHOLD` default for the
# identical reason that file states: this class has not yet seen a real
# incident to tune the number against. The fleet-vantage reader of the same
# fact `docs/REVIEW-PIPELINE-SPEC.md` R19's own `project-reviewer` verdict
# (agent-ops#996) carries in the heartbeat: R19 computes and publishes a
# node's verdict for a human or the dashboard to look at, this invariant
# reduces the fleet's own replicated `review-log.jsonl` union and *files a
# page* when no one is looking. Reads
# PAGER_EVAL_REVIEW_UNION_LOG_FILE (lib/pager.sh's own documented exception
# — see this file's header) rather than either of its own two arguments,
# since review-log.jsonl's union is not the implementation union log.
#
# A *run*, grouped by the `review` id review-cycle.sh's own `log_event`
# stamps on every line it writes, not a bare event: `review-end` is written
# by that script's `cleanup()` EXIT trap on every run whatever happened, and
# both ordinary `review-attempt-failed` sites (a clone that would not clone,
# a Reviewer stage that exited non-zero, timed out or returned no usable
# completion) `return 0`, so the run itself still exits 0. Reducing over raw
# events and resetting on `review-end`'s own `exit_code == 0` therefore
# resets the streak on the very run that just failed, and the streak can
# never reach 3 at one repository per run — inert for exactly the case
# agent-ops#996 describes and this invariant exists to read. So, per run:
#
#   any `review-attempt-failed`               the run failed          streak + 1
#   none, and a `review-stage-end`            a review completed      streak → 0
#   neither (stand-down, skip, nothing due)   carries no information  unchanged
#
# The third line is the whole point of grouping: a run that stood down or
# had no repository due says nothing about whether the pipeline works, so it
# must neither raise the alarm nor silence one — which is the very
# indistinguishability agent-ops#996 names, refused here rather than
# answered: this invariant declines to guess, and R19's own heartbeat
# verdict is what answers the question positively.
pager_eval_review_pipeline_failing() {
  local _fleet_nodes_json="$1" _union_log_file="$2"
  local review_union_file="${PAGER_EVAL_REVIEW_UNION_LOG_FILE:-}"
  local threshold=3
  [[ -n "$review_union_file" && -f "$review_union_file" ]] || { printf '{"firing":false}'; return 0; }
  jq -c -R -n --argjson threshold "$threshold" '
    [ inputs | select(length > 0) | (fromjson? // empty)
      | select(.event == "review-attempt-failed" or .event == "review-stage-end") ] as $events
    | ([ $events[] | .node // "unknown" ] | unique) as $nodes
    | ( [ $nodes[] as $n
          | ($events | map(select((.node // "unknown") == $n))) as $node_events
          | ( $node_events | group_by(.review // "")
              | map({ts: (map(.ts) | min),
                     failed: ((map(.event) | index("review-attempt-failed")) != null)})
              | sort_by(.ts) ) as $runs
          | (reduce $runs[] as $r (0; if $r.failed then . + 1 else 0 end)) as $streak
          | select($streak >= $threshold)
          | {node: $n, streak: $streak} ] ) as $hits
    | if ($hits | length) == 0 then {firing: false}
      else {firing: true, nodes: ($hits | map(.node)),
            evidence: ("failed review runs at/above " + ($threshold | tostring)
              + " consecutively, with no completed review between (the fleet-vantage reader of the project-reviewer verdict agent-ops#996 publishes per node), on "
              + (($hits | map("\(.node) (\(.streak) runs)")) | join(", ")))}
      end
  ' < "$review_union_file" 2>/dev/null || printf '{"firing":false}'
}

# pager_eval_dashboard_unreadable FLEET_NODES_JSON UNION_LOG_FILE
# Fires when any row's `dashboard_fetch` object — `{seconds, parsed}`, the
# contract #1283's own viewer-vantage probe is expected to fold into
# `fleet_nodes_json` (this file's own header) — names a fetch slower than
# PAGER_EVAL_DASHBOARD_FETCH_SECONDS or one that failed to parse. A row with
# no `dashboard_fetch` at all (every row, until #1283 lands) never
# contributes a hit, on the same null-until-populated convention `doctor`/
# `updater`/`stage_health` already use.
pager_eval_dashboard_unreadable() {
  local fleet_nodes_json="$1" _union_log_file="$2"
  local threshold_s="${PAGER_EVAL_DASHBOARD_FETCH_SECONDS:-}"
  [[ "$threshold_s" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '{"firing":false}'; return 0; }
  jq -c -n --argjson nodes "$fleet_nodes_json" --argjson threshold_s "$threshold_s" '
    ($nodes | map(select(.dashboard_fetch != null))
     | map(select((.dashboard_fetch.parsed? == false)
                  or ((.dashboard_fetch.seconds? // 0) > $threshold_s)))) as $hits
    | if ($hits | length) == 0 then {firing: false}
      else {firing: true, nodes: ($hits | map(.node)),
            evidence: ("data.js unreadable from a viewer'"'"'s vantage (#1283) on "
              + (($hits | map(
                   if (.dashboard_fetch.parsed? == false) then "\(.node) (failed to parse)"
                   else "\(.node) (\(.dashboard_fetch.seconds)s fetch)" end))
                 | join(", ")))}
      end
  ' 2>/dev/null || printf '{"firing":false}'
}

# --- agent-ops#1281: selection and ledger -----------------------------------

# pager_eval_idle_with_demand FLEET_NODES_JSON UNION_LOG_FILE
# Fires when a *cycling* node's (`pager_row_cycling`) last PAGER_EVAL_IDLE_CYCLES
# *cycles* all ended in state `idle-with-demand` (lib/node-time-state.sh,
# D21) with a cause other than `back-pressure` — a deliberate throttle, not a
# symptom, and the one `idle-with-demand` cause the issue's own exclusion
# list names that the D21 state vocabulary does not already separate out on
# its own (every other named exclusion — usage-limit, disk/memory,
# unauthorized, a fleet/kill-switch's own `down` — already logs a *different*
# `node-state` state: `externally-blocked` or `down`). Fewer than
# PAGER_EVAL_IDLE_CYCLES cycles for a node decides nothing — "last N cycles"
# cannot be confirmed from an incomplete window, the same direction every
# other "unknown decides nothing" guard in this codebase takes.
#
# *Cycling*, not merely live, for the reason firing-missed is
# (agent-ops#1686): a node demoted to standby keeps publishing a fresh
# heartbeat while requirement 2.4 stops its ticks, so the window this reads
# is frozen at whatever its last cycles before the demotion happened to be.
# A fleet that demoted a node mid-streak would otherwise page on that streak
# for as long as the node stood by, and unlike firing-missed's own version
# of the fault it needs no passage of time to become wrong: there are no
# further cycles to break the streak, ever.
#
# One cycle, not one event, and the distinction is the whole invariant:
# `node-state` is emitted many times per cycle — `overhead` unconditionally
# at the top of every cycle that takes the lock (agent-cycle.sh), and one
# transition per `stage-start` (`producing` for the Implementer and the
# Reviewer, `overhead` for every other actor) — so a run of
# PAGER_EVAL_IDLE_CYCLES *consecutive events* all reading `idle-with-demand`
# is a shape no cycling node can produce, and an invariant testing for one
# would simply never fire. How a cycle *ended* is that cycle's own last
# `node-state` event: `finalize_node_state_for_cycle`
# (lib/node-time-state.sh) logs it once, at the very end of `cleanup`, after
# the Enabler's and the Refiner's own transitions have had their chance to
# add real overhead to the same timeline. So the events are grouped by the
# `cycle` id every one of them carries, each cycle contributes its own last
# event, and the window is applied to those. A tick that skipped
# (`cycle-skipped`, whose `suppress_node_state_transitions` logs no
# `node-state` at all) contributes nothing either way, which is the answer
# this invariant wants: a tick that deferred to a cycle already running is
# not a cycle that ended idle.
pager_eval_idle_with_demand() {
  local fleet_nodes_json="$1" union_log_file="$2"
  local n="${PAGER_EVAL_IDLE_CYCLES:-}"
  if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n <= 0 )); then printf '{"firing":false}'; return 0; fi
  [[ -f "$union_log_file" ]] || { printf '{"firing":false}'; return 0; }
  jq -c -R -n --argjson nodes "$fleet_nodes_json" --argjson n "$n" \
    "$PAGER_JQ_ROW_PREDICATES"'
    ($nodes | map(select(pager_row_cycling)) | map(.node)) as $active
    | [ inputs | select(length > 0) | (fromjson? // empty) ] as $all
    | ($all | map(select(.event == "node-state"))) as $ns_all
    | ($all | map(select(.event == "none-selected"))) as $none_selected
    | ($all | map(select(.event == "coordinator-input-fitted"))) as $fitted
    | ( [ $active[] as $node
          | ($ns_all | map(select(.node == $node))
             | group_by(.cycle // "") | map(sort_by(.ts) | last)
             | sort_by(.ts)) as $node_ns
          | if ($node_ns | length) < $n then empty
            else
              ($node_ns[-$n:]) as $window
              | if ($window | all(.state == "idle-with-demand" and ((.cause // "") != "back-pressure")))
                then
                  ($window | map(.cause // "unknown") | unique) as $causes
                  | (($none_selected | map(select(.node == $node)) | sort_by(.ts) | last) // {}) as $ns
                  | (($fitted | map(select(.node == $node)) | sort_by(.ts) | last) // {}) as $fit
                  | {node: $node, causes: $causes,
                     reason: ($ns.reason // ""), fit: ($fit.detail // "")}
                else empty end
            end
        ] ) as $hits
    | if ($hits | length) == 0 then {firing: false}
      else {firing: true, nodes: ($hits | map(.node)),
            evidence: ("last " + ($n | tostring) + " cycles ended idle-with-demand (excluding back-pressure) on "
              + (($hits | map("\(.node) (causes: \(.causes | join(", "))"
                  + (if .reason != "" then "; none-selected reason: \(.reason)" else "" end)
                  + (if .fit != "" then "; fit report: \(.fit)" else "" end)
                  + ")")) | join("; ")))}
      end
  ' < "$union_log_file" 2>/dev/null || printf '{"firing":false}'
}

# pager_eval_fit_ladder_pinned FLEET_NODES_JSON UNION_LOG_FILE
# Fires when a node's `coordinator-input-fitted` events (agent-cycle.sh,
# lib/coordinator-input.sh) in the trailing 24h have *all* run out of prose
# to shed and started dropping whole entries — rung 11 or tighter (the first
# of the 7 entry-cap rungs that follow the 10 prose tiers:
# `COORDINATOR_INPUT_TIERS` + 1, a fixed constant of the ladder rather than a
# field either array carries) with `entries_dropped > 0` — a node whose
# eligible backlog has outgrown `coordinator_prompt_max_bytes` on every
# fitted cycle for a full day, not merely a one-off spike. A node with no
# fitted cycle at all in the window contributes nothing (never fires on
# silence).
#
# The entry-dropping segment, not its last notch: #1281's own evidence for
# this invariant is `poetic-1` sitting at the *loosest* entry cap — 64 per
# band per repo, rung 9 of the eight-tier ladder of the day — dropping 48–68
# entries in 149 of the 150 fitted cycles from 2026-09-04, so a test for the
# last notch alone would miss the very incident (#1128, #1136) this invariant
# is built from. The two clauses are close to one clause by construction:
# `coordinator_apply_rung`'s own `cap($max; …)` is a no-op while `$emax` is
# null, which is every prose rung, so `entries_dropped > 0` is unreachable
# above the first entry cap anyway — the rung floor says the same thing in
# the ladder's own vocabulary rather than leaving it implied by a derived
# count. agent-ops#1379 added two prose tiers (`0:0:300`, `0:0:0`) beneath
# `0:0:1000`, which moved the first entry cap from rung 9 to rung 11; the
# floor moved with it.
pager_eval_fit_ladder_pinned() {
  local _fleet_nodes_json="$1" union_log_file="$2"
  local entry_cap_rung=11
  [[ -f "$union_log_file" ]] || { printf '{"firing":false}'; return 0; }
  jq -c -R -n --argjson floor "$entry_cap_rung" --argjson now "$(date -u +%s)" '
    86400 as $window_s
    | [ inputs | select(length > 0) | (fromjson? // empty)
        | select(.event == "coordinator-input-fitted")
        | select((try (.ts | fromdateiso8601) catch null) != null)
        | select(($now - (.ts | fromdateiso8601)) <= $window_s) ] as $recent
    | ([$recent[] | .node] | unique) as $nodes
    | ( [ $nodes[] as $n
          | ($recent | map(select(.node == $n))) as $node_events
          | select(($node_events | length) > 0)
          | select($node_events | all(((.rung // 0) >= $floor) and ((.entries_dropped // 0) > 0)))
          | {node: $n, count: ($node_events | length),
             rung_min: ($node_events | map(.rung) | min),
             rung_max: ($node_events | map(.rung) | max),
             dropped_min: ($node_events | map(.entries_dropped) | min),
             dropped_max: ($node_events | map(.entries_dropped) | max)}
        ] ) as $hits
    | if ($hits | length) == 0 then {firing: false}
      else {firing: true, nodes: ($hits | map(.node)),
            evidence: ("coordinator-input-fitted pinned in the ladder'"'"'s entry-dropping segment (rung "
              + ($floor | tostring)
              + " or tighter) with entries dropped on every fitted cycle in the trailing 24h on "
              + (($hits | map("\(.node) (\(.count) cycle(s) at rung \(.rung_min)-\(.rung_max), "
                  + "\(.dropped_min)-\(.dropped_max) entries dropped)"))
                 | join("; ")))}
      end
  ' < "$union_log_file" 2>/dev/null || printf '{"firing":false}'
}

# pager_eval_work_order_repaired_rate FLEET_NODES_JSON UNION_LOG_FILE
# Fires when the fleet-wide count of `work-order-repaired` events
# (agent-cycle.sh, agent-ops#821 — a work order composed from trimmed input)
# in the trailing 24h exceeds PAGER_EVAL_REPAIR_RATE_PERCENT percent of that
# same window's `selection` count. A window with zero selections decides
# nothing (no rate is defined against an empty denominator).
pager_eval_work_order_repaired_rate() {
  local _fleet_nodes_json="$1" union_log_file="$2"
  local pct="${PAGER_EVAL_REPAIR_RATE_PERCENT:-}"
  [[ "$pct" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '{"firing":false}'; return 0; }
  [[ -f "$union_log_file" ]] || { printf '{"firing":false}'; return 0; }
  jq -c -R -n --argjson pct "$pct" --argjson now "$(date -u +%s)" '
    86400 as $window_s
    | [ inputs | select(length > 0) | (fromjson? // empty)
        | select(.event == "selection" or .event == "work-order-repaired")
        | select((try (.ts | fromdateiso8601) catch null) != null)
        | select(($now - (.ts | fromdateiso8601)) <= $window_s) ] as $recent
    | ([$recent[] | select(.event == "selection")] | length) as $selections
    | ([$recent[] | select(.event == "work-order-repaired")] | length) as $repaired
    | if $selections == 0 then {firing: false}
      else
        (($repaired * 100.0) / $selections) as $rate
        | if $rate > $pct
          then {firing: true,
                evidence: ("\($repaired) work-order-repaired event(s) out of \($selections) selection(s) in the trailing 24h ("
                  + (($rate * 10 | round) / 10 | tostring) + "%), above pager_repair_rate_percent (" + ($pct | tostring) + "%)")}
          else {firing: false}
          end
      end
  ' < "$union_log_file" 2>/dev/null || printf '{"firing":false}'
}

# _pager_blocked_label_candidate_repos UNION_LOG_FILE -> one repo per line
# The bounded candidate set for blocked-label-orphaned's own live reads: every
# repo this pipeline's own history shows it has ever applied the
# `needs-refinement` block kind, or a `blocked`/`blocked:<reason>` label, to
# — never an arbitrary configured-repo list, so this invariant costs one `gh`
# call per repo this history actually names, not per repo ever configured.
_pager_blocked_label_candidate_repos() {
  local union_log_file="$1"
  [[ -f "$union_log_file" ]] || return 0
  jq -r -R '
    (fromjson? // empty)
    | select((.event == "attempt-failed" and (.kind // "") == "needs-refinement")
             or (.event == "own-label-action"
                 and ((.label // "") == "blocked" or ((.label // "") | startswith("blocked:")))))
    | (.repo // empty)
  ' "$union_log_file" 2>/dev/null | sort -u
}

# _pager_blocked_label_candidates UNION_LOG_FILE -> "<repo>\t<item>\t<label>"
# per line. Shared by the eval and remedy functions below, mirroring
# `_pager_open_page_issues`'s own "one shared listing" discipline: both the
# history-only half (`refinement_blocked_label_stale`, pure over the union
# log) and the live-read half (`refinement_blocked_label_orphaned`,
# requirement 38b, agent-ops#816) that candidate-gather.sh's own
# reconciliation sweep already uses — never a reimplementation. Requires
# lib/refinement.sh and lib/cycle-state.sh (`blocked_items`) to already be
# sourced by the caller; a caller that has not (this file's own tests) simply
# sees this print nothing, exactly the "no candidates" answer an untouched
# repository would also give.
_pager_blocked_label_candidates() {
  local union_log_file="$1" repo open_blocked reason_label live_json gh
  declare -F blocked_items >/dev/null 2>&1 || return 0
  declare -F refinement_blocked_label_stale >/dev/null 2>&1 || return 0
  declare -F refinement_blocked_label_orphaned >/dev/null 2>&1 || return 0
  declare -F refinement_blocked_reason_label >/dev/null 2>&1 || return 0
  gh="${PAGER_GH:-gh}"
  open_blocked="$(blocked_items "$union_log_file")"
  refinement_blocked_label_stale "$open_blocked" "$union_log_file"
  reason_label="$(refinement_blocked_reason_label "${REFINEMENT_BLOCK_KIND:-needs-refinement}")"
  [[ -n "$reason_label" ]] || return 0
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    live_json="$("$gh" issue list -R "$repo" --label "$reason_label" --state open --limit 200 \
        --json number,labels 2>/dev/null \
      | jq -c '[.[] | {number: .number, labels: [.labels[].name]}]' 2>/dev/null)"
    [[ -n "$live_json" ]] || live_json='[]'
    refinement_blocked_label_orphaned "$open_blocked" "$live_json" "$repo" "$union_log_file"
  done < <(_pager_blocked_label_candidate_repos "$union_log_file")
}

# pager_eval_blocked_label_orphaned FLEET_NODES_JSON UNION_LOG_FILE
# Fires when `_pager_blocked_label_candidates` finds at least one
# `blocked:<reason>`/`blocked` label still live with no open block behind it
# (agent-ops#816's own signature: twelve issues unselectable for five days
# after being unblocked).
pager_eval_blocked_label_orphaned() {
  local _fleet_nodes_json="$1" union_log_file="$2"
  [[ -f "$union_log_file" ]] || { printf '{"firing":false}'; return 0; }
  local hits
  hits="$(_pager_blocked_label_candidates "$union_log_file")"
  [[ -n "$hits" ]] || { printf '{"firing":false}'; return 0; }
  jq -Rsc '
    (split("\n") | map(select(length > 0) | split("\t"))
     | map({repo: .[0], item: .[1], label: .[2]})) as $rows
    | {firing: true,
       evidence: ("\($rows | length) orphaned blocked-label issue(s) with no open block behind them: "
         + ($rows | map("\(.repo)#\(.item) (\(.label))") | join(", ")))}
  ' <<<"$hits" 2>/dev/null || printf '{"firing":false}'
}

# pager_remedy_blocked_label_orphaned KEY EVIDENCE
# Pipeline act: re-derive the same candidate set (never parse EVIDENCE's own
# prose, on `pager_remedy_page_outlived_item`'s own terms) and call
# `refinement_label_remove` — requirement 38b's own release path, the
# identical function candidate-gather.sh's sweep already uses — for each,
# logging `own-label-action` on success via `label_own_action_fields`. A
# removal that succeeds clears on this invariant's own next evaluation (the
# label is gone); only a removal that keeps failing stays filed, which is
# what "the invariant files only if the removal fails" means in a framework
# that always records a pipeline-act attempt (lib/pager.sh's own header).
pager_remedy_blocked_label_orphaned() {
  local _key="$1" _evidence="$2"
  local union_log_file="${PAGER_REMEDY_UNION_LOG_FILE:-}" log_file="${PAGER_REMEDY_LOG_FILE:-}" \
        node="${PAGER_REMEDY_NODE:-}" cycle="${PAGER_REMEDY_CYCLE:-}"
  declare -F refinement_label_remove >/dev/null 2>&1 || { printf 'refinement_label_remove is not available'; return 1; }
  [[ -n "$union_log_file" ]] || { printf 'no PAGER_REMEDY_UNION_LOG_FILE — nothing to re-derive'; return 1; }
  local hits removed=0 failed=0 repo item label
  hits="$(_pager_blocked_label_candidates "$union_log_file")"
  while IFS=$'\t' read -r repo item label; do
    [[ -n "$repo" && -n "$item" && -n "$label" ]] || continue
    if refinement_label_remove "$repo" "$item" "$label"; then
      removed=$(( removed + 1 ))
      if declare -F label_own_action_fields >/dev/null 2>&1 && [[ -n "$log_file" ]]; then
        pager_log_event "$log_file" "$node" "$cycle" "own-label-action" \
          "$(label_own_action_fields "$repo" "$item" "$label" "remove")"
      fi
    else
      failed=$(( failed + 1 ))
    fi
  done <<<"$hits"
  printf 'removed %d orphaned label(s); %d removal(s) failed' "$removed" "$failed"
}

# pager_eval_claim_unreconciled FLEET_NODES_JSON UNION_LOG_FILE
# Fires when an `enabler-examined` event whose `outcome` is the Enabler's own
# escalate verdict (lib/enabler.sh: `outcome="$verdict"`, never reassigned on
# the path that actually files) carries no `escalated`/`tech-debt-filed`
# event for the same repo, item and cycle — agent-ops#815's own signature
# (#640 sat blocked five days on a claim an adjudication pass had cancelled)
# recurring by a different route.
#
# The claims are windowed to the trailing 24h, on the same terms every other
# invariant in this class is (`fit-ladder-pinned`, `work-order-repaired-rate`,
# `escalation-burst`), and for a reason particular to a ledger reader: the
# union log is never rotated (scripts/rotate-logs.sh leaves `log.jsonl`
# alone), so an unwindowed reading would fire on the original #815 incident
# itself — still in this fleet's own history — and, worse, could never
# *clear*: a fact derived from immutable history stays true for ever, the
# `pw::pager` issue never closes, and the remedy's correction comment lands
# on items resolved months ago. `escalated`/`tech-debt-filed` stay
# unwindowed: they are only ever matched within the claim's own cycle, so a
# reconciliation is always within seconds of the claim it answers.
pager_eval_claim_unreconciled() {
  local _fleet_nodes_json="$1" union_log_file="$2"
  [[ -f "$union_log_file" ]] || { printf '{"firing":false}'; return 0; }
  jq -c -R -n --argjson now "$(date -u +%s)" '
    86400 as $window_s
    | [ inputs | select(length > 0) | (fromjson? // empty) ] as $all
    | ($all | map(select(.event == "enabler-examined" and (.outcome // "") == "escalate"))
       | map(select((try (.ts | fromdateiso8601) catch null) != null))
       | map(select(($now - (.ts | fromdateiso8601)) <= $window_s))) as $claims
    | ($all | map(select(.event == "escalated" or .event == "tech-debt-filed"))) as $resolved
    | ( [ $claims[]
          | . as $c
          | select(($resolved | map(select(.cycle == $c.cycle and (.repo // "") == ($c.repo // "")
                                           and ((.item // "") | tostring) == (($c.item // "") | tostring)))
                    | length) == 0)
          | {repo: $c.repo, item: $c.item, cycle: $c.cycle}
        ] ) as $hits
    | if ($hits | length) == 0 then {firing: false}
      else {firing: true,
            evidence: ("\($hits | length) enabler escalation claim(s) with no matching escalated/tech-debt-filed event in the same cycle: "
              + ($hits | map("\(.repo)#\(.item) (cycle \(.cycle))") | join(", ")))}
      end
  ' < "$union_log_file" 2>/dev/null || printf '{"firing":false}'
}

# pager_remedy_claim_unreconciled KEY EVIDENCE
# Pipeline act: re-check live (never parse EVIDENCE's own prose) and, for
# every claim still unreconciled, post one correction comment on the item's
# own thread naming what could not be confirmed — the agent-ops#815 pattern
# (`escalation_thread_reconcile`), mirrored rather than called directly:
# that function reads cycle-scoped globals (`node_name`/`cycle_id`/
# `cycle_dir`) lib/pager.sh's own header documents as unavailable to the
# Publisher's process. The re-check applies the identical trailing-24h window
# its own EVAL_FN does — a remedy reading a wider history than the invariant
# that fired would comment on items the fire was never about.
pager_remedy_claim_unreconciled() {
  local _key="$1" _evidence="$2"
  local union_log_file="${PAGER_REMEDY_UNION_LOG_FILE:-}" node="${PAGER_REMEDY_NODE:-}" \
        cycle="${PAGER_REMEDY_CYCLE:-}" gh
  gh="${PAGER_GH:-gh}"
  [[ -n "$union_log_file" && -f "$union_log_file" ]] || { printf 'no union log available — nothing corrected'; return 1; }
  if ! declare -F pipeline_comment_header >/dev/null 2>&1 || ! declare -F pipeline_comment_marker >/dev/null 2>&1; then
    printf 'lib/pipeline-marker.sh is not available'; return 1
  fi
  local hits posted=0 repo item body
  hits="$(jq -r -R -n --argjson now "$(date -u +%s)" '
    86400 as $window_s
    | [ inputs | select(length > 0) | (fromjson? // empty) ] as $all
    | ($all | map(select(.event == "enabler-examined" and (.outcome // "") == "escalate"))
       | map(select((try (.ts | fromdateiso8601) catch null) != null))
       | map(select(($now - (.ts | fromdateiso8601)) <= $window_s))) as $claims
    | ($all | map(select(.event == "escalated" or .event == "tech-debt-filed"))) as $resolved
    | ( [ $claims[] | . as $c
          | select(($resolved | map(select(.cycle == $c.cycle and (.repo // "") == ($c.repo // "")
                                           and ((.item // "") | tostring) == (($c.item // "") | tostring)))
                    | length) == 0)
          | {repo: $c.repo, item: $c.item} ]
      | unique
      | .[] | "\(.repo)\t\(.item)" )
  ' < "$union_log_file" 2>/dev/null || true)"
  [[ -n "$hits" ]] || { printf 'no unreconciled claim found on re-check — nothing to correct'; return 0; }
  while IFS=$'\t' read -r repo item; do
    [[ -n "$repo" && -n "$item" ]] || continue
    body="$(pipeline_comment_header script "$node")

This pipeline previously indicated it was escalating this item, but no \`escalated\` or tech-debt record was ever confirmed for that engagement — an adjudication or decide-tactical pass may have overridden the original verdict, or the engagement did not complete. A later cycle will re-examine this item.

$(pipeline_comment_marker "$cycle" script)"
    "$gh" issue comment "$item" -R "$repo" --body "$body" >/dev/null 2>&1 \
      && posted=$(( posted + 1 ))
  done <<<"$hits"
  printf 'posted %d correction comment(s)' "$posted"
}

# pager_eval_escalation_burst FLEET_NODES_JSON UNION_LOG_FILE
# Fires when the fleet-wide count of `escalated` events in the trailing 24h
# exceeds PAGER_EVAL_ESCALATION_BURST, or the same re-flag reason (the
# triggering `attempt-failed`'s own `detail`/`unblock_condition`,
# fingerprinted with `escalation_autonomy_decide_reason_key` — requirement
# 36d's own per-reason bound, reused rather than duplicated) paged the same
# item twice in that same trailing 24h.
#
# Both halves are windowed, the re-flag half included, for the reason
# `pager_eval_claim_unreconciled` above states at length: the union log is
# never rotated, so an unwindowed re-flag count would fire on the 2026-08-28
# burst (#933–#938) still sitting in this fleet's own history and could never
# clear afterwards. The window also bounds the loop below, which forks two
# `jq`s and a `sha256sum` per escalation it has to fingerprint — a per-
# evaluation cost that would otherwise grow with the whole log, on a path
# that runs every five minutes. The `attempt-failed` half stays unwindowed:
# it is only ever read to look up the reason behind an escalation already
# inside the window, and the re-flag it names can be a little older than the
# page it caused.
pager_eval_escalation_burst() {
  local _fleet_nodes_json="$1" union_log_file="$2"
  local burst="${PAGER_EVAL_ESCALATION_BURST:-}"
  if ! [[ "$burst" =~ ^[0-9]+$ ]] || (( burst <= 0 )); then printf '{"firing":false}'; return 0; fi
  [[ -f "$union_log_file" ]] || { printf '{"firing":false}'; return 0; }
  local now count pairs
  now="$(date -u +%s)"
  count="$(jq -R -n --argjson now "$now" '
    86400 as $w
    | [ inputs | select(length > 0) | (fromjson? // empty)
        | select(.event == "escalated")
        | select((try (.ts | fromdateiso8601) catch null) != null)
        | select(($now - (.ts | fromdateiso8601)) <= $w) ] | length
  ' < "$union_log_file" 2>/dev/null)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0

  local reflag_desc=""
  if declare -F escalation_autonomy_decide_reason_key >/dev/null 2>&1; then
    pairs="$(jq -c -R -n --argjson now "$now" '
      86400 as $w
      | [ inputs | select(length > 0) | (fromjson? // empty) ] as $all
      | ($all | map(select(.event == "attempt-failed"))) as $attempts
      | ($all | map(select(.event == "escalated"))
         | map(select((try (.ts | fromdateiso8601) catch null) != null))
         | map(select(($now - (.ts | fromdateiso8601)) <= $w))) as $escalated
      | [ $escalated[] | . as $e
          | ($attempts | map(select((.repo // "") == ($e.repo // "")
                                    and ((.item // "") | tostring) == (($e.item // "") | tostring)
                                    and .ts <= $e.ts))
             | sort_by(.ts) | last) as $a
          | select($a != null)
          | {repo: $e.repo, item: $e.item, detail: ($a.detail // ""), unblock_condition: ($a.unblock_condition // "")} ]
    ' < "$union_log_file" 2>/dev/null || true)"
    [[ -n "$pairs" ]] || pairs='[]'
    local -A reflag_count=()
    local row repo item rk k
    while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      repo="$(jq -r '.repo' <<<"$row" 2>/dev/null)"
      item="$(jq -r '.item' <<<"$row" 2>/dev/null)"
      rk="$(escalation_autonomy_decide_reason_key "$row")"
      [[ -n "$repo" && -n "$item" && -n "$rk" ]] || continue
      k="$repo|$item|$rk"
      reflag_count["$k"]=$(( ${reflag_count[$k]:-0} + 1 ))
    done < <(jq -c '.[]' <<<"$pairs" 2>/dev/null)
    for k in "${!reflag_count[@]}"; do
      if (( reflag_count[$k] >= 2 )); then
        reflag_desc+="${reflag_desc:+; }${k%%|*}#$(printf '%s' "$k" | cut -d'|' -f2) reflagged ${reflag_count[$k]}x"
      fi
    done
  fi

  if (( count > burst )) || [[ -n "$reflag_desc" ]]; then
    local ev="$count escalated event(s) in the trailing 24h (pager_escalation_burst: $burst)"
    [[ -n "$reflag_desc" ]] && ev="$ev; repeat re-flags: $reflag_desc"
    jq -nc --arg e "$ev" '{firing: true, evidence: $e}'
  else
    printf '{"firing":false}'
  fi
}

# pager_eval_digest_truncated FLEET_NODES_JSON UNION_LOG_FILE
# Fires when the most recent `source-state-digest` event (lib/candidate-
# gather.sh, logged alongside `gather_source_state`'s own already-fetched
# counts) for some repo, still claiming `ok: true`, undercounts a live total
# this invariant fetches itself via GitHub's search API — cheaply, once per
# evaluation window rather than once per node per cycle the way gather-
# source-state.sh's own already-paginated fetch runs. The agent-ops#1165
# signature (requirement 34i read absence-from-digest as "closed" and
# false-cleared blocks past the newest hundred) recurring.
#
# The live query is bound to the matched digest row's own `ts` (a
# `created:<=<ts>` qualifier, GitHub search's date-range syntax) rather than
# an unbounded "right now" total: every `log_event` write already carries a
# `ts`, and without this bound a repo that creates issues/PRs quickly enough
# — this pipeline's own traffic, several per cycle — under-reads its own
# "live" total against a digest that is merely a few minutes old, which is
# drift, not truncation (agent-ops#1348).
pager_eval_digest_truncated() {
  local _fleet_nodes_json="$1" union_log_file="$2"
  [[ -f "$union_log_file" ]] || { printf '{"firing":false}'; return 0; }
  local gh latest
  gh="${PAGER_GH:-gh}"
  latest="$(jq -c -R -n '
    [ inputs | select(length > 0) | (fromjson? // empty)
      | select(.event == "source-state-digest" and (.ok // false) == true and (.repo // "") != "") ]
    | group_by(.repo) | map(sort_by(.ts) | last)
  ' < "$union_log_file" 2>/dev/null)"
  [[ -n "$latest" && "$latest" != "null" ]] || { printf '{"firing":false}'; return 0; }
  local row repo digest_issues digest_prs live_issues live_prs ts created_qualifier
  local hits=()
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    repo="$(jq -r '.repo' <<<"$row")"
    digest_issues="$(jq -r '.issues_count // 0' <<<"$row")"
    digest_prs="$(jq -r '.open_prs_count // 0' <<<"$row")"
    ts="$(jq -r '.ts // empty' <<<"$row")"
    [[ -n "$repo" ]] || continue
    created_qualifier=""
    [[ -n "$ts" ]] && created_qualifier="+created:<=$ts"
    live_issues="$("$gh" api "search/issues?q=repo:$repo+type:issue+state:open${created_qualifier}" --jq '.total_count' 2>/dev/null)"
    live_prs="$("$gh" api "search/issues?q=repo:$repo+type:pr+state:open${created_qualifier}" --jq '.total_count' 2>/dev/null)"
    [[ "$live_issues" =~ ^[0-9]+$ ]] || live_issues=""
    [[ "$live_prs" =~ ^[0-9]+$ ]] || live_prs=""
    if { [[ -n "$live_issues" ]] && (( live_issues > digest_issues )); } \
       || { [[ -n "$live_prs" ]] && (( live_prs > digest_prs )); }; then
      hits+=("$repo (digest issues=$digest_issues/live=${live_issues:-?}, digest open_prs=$digest_prs/live=${live_prs:-?})")
    fi
  done < <(jq -c '.[]' <<<"$latest" 2>/dev/null)
  if (( ${#hits[@]} > 0 )); then
    local joined
    joined="$(IFS='; '; printf '%s' "${hits[*]}")"
    jq -nc --arg ev "source-state digest undercounts a live paginated total (the #1165 signature): $joined" \
      '{firing: true, evidence: $ev}'
  else
    printf '{"firing":false}'
  fi
}

# pager_remedy_digest_truncated KEY EVIDENCE
# Pipeline act: log a `digest-truncation-veto` for each affected repo (parsed
# from EVIDENCE's own repo tokens — the live counts themselves are not
# re-derived here, since the veto is unconditional for the cycle regardless
# of the exact numbers) — lib/candidate-gather.sh checks for this event
# before trusting that repo's digest, refusing to act on its absence for the
# vetoed cycle, exactly as the issue's own remedy class states — then files,
# a durable record if the veto keeps recurring.
pager_remedy_digest_truncated() {
  local _key="$1" evidence="$2"
  local log_file="${PAGER_REMEDY_LOG_FILE:-}" node="${PAGER_REMEDY_NODE:-}" cycle="${PAGER_REMEDY_CYCLE:-}"
  [[ -n "$log_file" ]] || { printf 'no PAGER_REMEDY_LOG_FILE — could not veto this cycle'\''s clearances'; return 1; }
  local repos repo vetoed=0
  repos="$(grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+ \(digest' <<<"$evidence" 2>/dev/null \
    | sed 's/ (digest.*//' | sort -u)"
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    pager_log_event "$log_file" "$node" "$cycle" "digest-truncation-veto" \
      "$(jq -nc --arg r "$repo" '{repo: $r}')"
    vetoed=$(( vetoed + 1 ))
  done <<<"$repos"
  printf 'vetoed this cycle'\''s work-gone clearances for %d repo(s) pending a healthy digest' "$vetoed"
}

# --- agent-ops#1280: landing and approval -----------------------------------

# pager_eval_landing_never_armed FLEET_NODES_JSON UNION_LOG_FILE
# Fires when a repository PAGER_EVAL_REPOS_JSON names at merge_autonomy
# agent-merges-routine or above logged at least one landing-refused event in
# the trailing PAGER_EVAL_LANDING_ARMED_WITHIN_DAYS (default 7) window but no
# landing-armed event in that same window — the #718 signature: six days of
# refusals and zero armings, because the refusal path itself
# (landing_protected_paths_hit's `gh api … -F`) was silently failing closed
# on every attempt. The landing-refused gate (never "no landing-armed event"
# alone) is deliberate: a repository with nothing ready to land in the window
# is not this incident, and would otherwise fire on every quiet repository
# configured at this level, forever. merge_autonomy here is the *configured*
# level (PAGER_EVAL_REPOS_JSON's own `merge_autonomy`, this file's header),
# never the live effective one — a per-repository merge-budget-freeze read
# this invariant declines to pay for on every evaluation, the same
# approximation `scripts/publish-dashboard.sh`'s own back-pressure card
# already makes (D18 WI-6) for an identical reason. Evidence embeds each
# repository's own refusal-class histogram (`reason`'s own `<class>:<detail>`
# vocabulary, split on the first colon) — the two facts the remedy's own
# tech-debt issue starts a diagnosis from.
pager_eval_landing_never_armed() {
  local _fleet_nodes_json="$1" union_log_file="$2"
  local repos_json="${PAGER_EVAL_REPOS_JSON:-}" days="${PAGER_EVAL_LANDING_ARMED_WITHIN_DAYS:-}"
  [[ "$days" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '{"firing":false}'; return 0; }
  if [[ -z "$repos_json" ]] || ! jq -e 'type == "array"' <<<"$repos_json" >/dev/null 2>&1; then
    printf '{"firing":false}'; return 0
  fi
  [[ -f "$union_log_file" ]] || { printf '{"firing":false}'; return 0; }
  jq -c -R -n --argjson repos "$repos_json" --argjson days "$days" --argjson now "$(date -u +%s)" '
    (86400 * $days) as $window_s
    | [ inputs | select(length > 0) | (fromjson? // empty)
        | select(.event == "landing-armed" or .event == "landing-refused")
        | select((.repo // "") != "")
        | select((try (.ts | fromdateiso8601) catch null) != null)
        | select(($now - (.ts | fromdateiso8601)) <= $window_s) ] as $recent
    | ($recent | map(select(.event == "landing-armed"))) as $armed
    | ($recent | map(select(.event == "landing-refused"))) as $refused
    | ($repos | map(select((.merge_autonomy // "human") as $l
                    | ["agent-merges-routine", "agent-merges-all"] | index($l) != null))) as $eligible
    | ( [ $eligible[] as $r
          | ($r.slug) as $slug
          | ($refused | map(select(.repo == $slug))) as $repo_refused
          | select(($repo_refused | length) > 0)
          | select(($armed | map(select(.repo == $slug)) | length) == 0)
          | ($repo_refused | group_by((.reason // "") | split(":")[0])
             | map({class: ((.[0].reason // "") | split(":")[0]), count: length})
             | sort_by(-.count)) as $hist
          | {repo: $slug, refused: ($repo_refused | length),
             histogram: ($hist | map("\(.class): \(.count)") | join(", "))}
        ] ) as $hits
    | if ($hits | length) == 0 then {firing: false}
      else {firing: true, nodes: [],
            evidence: ("at merge_autonomy agent-merges-routine or above with zero landing-armed events in the trailing "
              + ($days | tostring) + " day(s) despite landing-refused activity (the #718 signature), on "
              + (($hits | map("\(.repo) (\(.refused) refusal(s); refusal-class histogram: \(.histogram))")) | join("; ")))}
      end
  ' < "$union_log_file" 2>/dev/null || printf '{"firing":false}'
}

# pager_remedy_landing_never_armed KEY EVIDENCE
# Pipeline act: files a `pw::type:tech-debt` issue against this pipeline's
# own repository (PAGER_REMEDY_REPO) — the reader (lib/landing.sh) lives
# here, never in a target repo, the identical reasoning
# pager_remedy_verdict_unanimous already states — naming the refusal-class
# histogram EVIDENCE already carries.
pager_remedy_landing_never_armed() {
  local key="$1" evidence="$2" repo="${PAGER_REMEDY_REPO:-}"
  [[ -n "$repo" ]] || { printf 'no pager_repo configured — could not file the tech-debt issue'; return 1; }
  local item="pager-reader:$key" body_file created number
  body_file="$(mktemp)"
  {
    printf 'A fleet-wide invariant fired: a repository configured at merge_autonomy agent-merges-routine or above armed no landing in pager_landing_armed_within_days despite refusal activity.\n\n'
    printf '%s\n\n' "$evidence"
    printf 'This is the #718 signature — a gate inside _landing_stage_attempt (most often landing_protected_paths_hit) failing closed on every attempt, refusing every landing regardless of merit. The refusal-class histogram above names which gate to start from.\n\n'
    printf -- '---\nFiled automatically by lib/pager.sh (issue #1280).\nref: %s\n' "$item"
  } > "$body_file"
  if created="$(_pager_create_issue "$repo" "$item" "pw::type:tech-debt" \
        "Pager: landing-never-armed fired ($evidence)" "$body_file" "")" && [[ -n "$created" ]]; then
    number="${created%%$'\t'*}"
    rm -f "$body_file"
    printf 'filed %s#%s (pw::type:tech-debt)' "$repo" "$number"
    return 0
  fi
  rm -f "$body_file"
  return 1
}

# pager_eval_landing_refused_unknown FLEET_NODES_JSON UNION_LOG_FILE
# Fires when landing-refused events of class `unknown`
# (lib/landing.sh's own `unknown:<reason>` vocabulary — the fail-closed
# answer landing_eligible/landing_protected_path_controls_ok give when a live
# GitHub read could not even be attempted, never a deterministic ineligible)
# make up at least half of a trailing-24h window's landing-refused events,
# fleet-wide, with at least five. Caught: the #718 incident (72 of 115). The
# fraction and the floor are fixed, un-schema-backed constants —
# `pager_eval_review_pipeline_failing`'s own precedent (this file's header),
# for the identical reason it states: this class has not yet seen a second
# incident to tune them against.
pager_eval_landing_refused_unknown() {
  local _fleet_nodes_json="$1" union_log_file="$2"
  local min_events=5
  [[ -f "$union_log_file" ]] || { printf '{"firing":false}'; return 0; }
  jq -c -R -n --argjson now "$(date -u +%s)" --argjson min "$min_events" '
    86400 as $window_s
    | [ inputs | select(length > 0) | (fromjson? // empty)
        | select(.event == "landing-refused")
        | select((try (.ts | fromdateiso8601) catch null) != null)
        | select(($now - (.ts | fromdateiso8601)) <= $window_s) ] as $refusals
    | ($refusals | length) as $total
    | ($refusals | map(select((((.reason // "") | split(":")[0])) == "unknown")) | length) as $unknown
    | if $total == 0 then {firing: false}
      elif ($unknown >= $min) and (($unknown * 2) >= $total)
      then {firing: true,
            evidence: ("\($unknown) of \($total) landing-refused event(s) fleet-wide in the trailing 24h are class \"unknown\" ("
              + (( ($unknown * 1000.0 / $total | round) / 10 ) | tostring) + "%) — at or above half, with at least \($min) events (the #718 signature)")}
      else {firing: false}
      end
  ' < "$union_log_file" 2>/dev/null || printf '{"firing":false}'
}

# pager_remedy_landing_refused_unknown KEY EVIDENCE
# Pipeline act: files a `pw::type:tech-debt` issue against this pipeline's
# own repository, on the identical terms pager_remedy_landing_never_armed
# already uses — the two invariants share one root cause class, and often
# fire together for the same incident.
pager_remedy_landing_refused_unknown() {
  local key="$1" evidence="$2" repo="${PAGER_REMEDY_REPO:-}"
  [[ -n "$repo" ]] || { printf 'no pager_repo configured — could not file the tech-debt issue'; return 1; }
  local item="pager-reader:$key" body_file created number
  body_file="$(mktemp)"
  {
    printf 'A fleet-wide invariant fired: at least half of a trailing 24h'\''s landing-refused events are class "unknown".\n\n'
    printf '%s\n\n' "$evidence"
    printf 'A refusal class of "unknown" (lib/landing.sh'\''s own vocabulary) means a live GitHub read the Landing Gate needed could not even be attempted — never a deterministic ineligible verdict. This is the #718 signature: a gate inside _landing_stage_attempt (most often landing_protected_paths_hit) failing closed on every attempt. Check the fleet log'\''s own landing-refused reasons for the affected repository(ies) directly.\n\n'
    printf -- '---\nFiled automatically by lib/pager.sh (issue #1280).\nref: %s\n' "$item"
  } > "$body_file"
  if created="$(_pager_create_issue "$repo" "$item" "pw::type:tech-debt" \
        "Pager: landing-refused-unknown fired ($evidence)" "$body_file" "")" && [[ -n "$created" ]]; then
    number="${created%%$'\t'*}"
    rm -f "$body_file"
    printf 'filed %s#%s (pw::type:tech-debt)' "$repo" "$number"
    return 0
  fi
  rm -f "$body_file"
  return 1
}

# _pager_ready_pr_candidates REPOS_JSON PR_LABEL CUTOFF_HOURS [CONFIG_KEY] ->
# one "<repo>\t<number>\t<url>\t<head>" line per open, non-draft, PR_LABEL
# pull request, in every repo REPOS_JSON names, whose own `createdAt` is
# older than CUTOFF_HOURS and whose `reviewDecision` names no terminal
# review at all (empty or `REVIEW_REQUIRED`) — a superset of "no standing
# *App* review" specific enough in practice, since a third party reviewing
# an autonomous pipeline's own pull request ahead of the Approver is not the
# ordinary case this invariant needs to rule out, and reading it straight off
# the one `gh pr list` call every candidate repository needs anyway costs no
# further per-pull-request API call the way a live per-pull-request read
# (`landing_approver_standing_review_at`, which additionally needs the
# Approver App's own login) would. CONFIG_KEY, defaulted to the generic
# parameter name below, names the actual config.schema.json key CUTOFF_HOURS
# was read from, so an empty-cutoff warning (below) points a human at the
# setting to fix rather than at this function's own local parameter name.
_pager_ready_pr_candidates() {
  local repos_json="$1" pr_label="$2" cutoff_hours="$3" config_key="${4:-cutoff_hours}"
  local gh cutoff repo open
  gh="${PAGER_GH:-gh}"
  cutoff="$(jq -n -r --arg h "$cutoff_hours" \
    '(now - ($h|tonumber)*3600) | strftime("%Y-%m-%dT%H:%M:%SZ")' 2>/dev/null || true)"
  if [[ -z "$cutoff" ]]; then
    # PAGER_REMEDY_LOG_FILE/NODE/CYCLE: the same documented-exception plain
    # variables `_pager_evaluate_one` sets before calling EVAL_FN (lib/pager.sh's
    # own header) — the only way this eval-path helper can reach a log file at
    # all. Empty when sourced outside that call (e.g. by the test suite calling
    # this directly): `pager_log_event`'s own `>> "$log_file" 2>/dev/null || true`
    # then silently writes nothing rather than failing.
    pager_log_event "${PAGER_REMEDY_LOG_FILE:-}" "${PAGER_REMEDY_NODE:-}" "${PAGER_REMEDY_CYCLE:-}" "warning" \
      "$(jq -nc --arg k "$config_key" --arg v "$cutoff_hours" --arg fn "_pager_ready_pr_candidates" \
        --arg d "empty cutoff computed from $config_key=$cutoff_hours in _pager_ready_pr_candidates — the pr-unreviewed pager invariant is skipped this evaluation" \
        '{detail: $d, key: $k, value: $v, fn: $fn}')"
    return 0
  fi
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    open="$("$gh" pr list -R "$repo" --state open --label "$pr_label" \
      --json number,url,isDraft,reviewDecision,createdAt,headRefOid --limit 200 2>/dev/null || true)"
    jq -e 'type == "array"' <<<"$open" >/dev/null 2>&1 || continue
    jq -r --arg cutoff "$cutoff" --arg repo "$repo" '
      .[] | select(.isDraft | not)
      | select(((.reviewDecision // "") == "") or ((.reviewDecision // "") == "REVIEW_REQUIRED"))
      | select((.createdAt // "") != "" and .createdAt < $cutoff)
      | [$repo, (.number | tostring), .url, (.headRefOid // "")] | @tsv
    ' <<<"$open" 2>/dev/null
  done < <(jq -r '.[].slug' <<<"$repos_json" 2>/dev/null)
}

# _pager_pr_unreviewed_candidates REPOS_JSON PR_LABEL CUTOFF_HOURS
#                                  UNION_LOG_FILE -> the same TSV shape as
# _pager_ready_pr_candidates, narrowed to the pull requests requirement 46's
# own unreviewed trigger (agent-ops#890) has never once touched at all: no
# approver-verdict, no warning naming it, and no approver-unreviewed-engaged
# event for its own pr_url anywhere in UNION_LOG_FILE. Never merely stale —
# total silence, the #1081 signature (a sweep that returned before it ever
# reached its own unreviewed-trigger loop, logging nothing at all about why).
# Shared by the eval and remedy functions below, the same "one listing,
# never re-derived twice" discipline every other invariant here follows.
_pager_pr_unreviewed_candidates() {
  local repos_json="$1" pr_label="$2" cutoff_hours="$3" union_log_file="$4"
  [[ -n "$repos_json" && -n "$pr_label" ]] || return 0
  if [[ ! "$cutoff_hours" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    pager_log_event "${PAGER_REMEDY_LOG_FILE:-}" "${PAGER_REMEDY_NODE:-}" "${PAGER_REMEDY_CYCLE:-}" "warning" \
      "$(jq -nc --arg k "approver_unreviewed_engage_after_hours" --arg v "$cutoff_hours" \
        --arg fn "_pager_pr_unreviewed_candidates" \
        --arg d "schema-illegal cutoff approver_unreviewed_engage_after_hours=$cutoff_hours in _pager_pr_unreviewed_candidates — the pr-unreviewed pager invariant is skipped this evaluation" \
        '{detail: $d, key: $k, value: $v, fn: $fn}')"
    return 0
  fi
  local raw touched='[]'
  raw="$(_pager_ready_pr_candidates "$repos_json" "$pr_label" "$cutoff_hours" \
    "approver_unreviewed_engage_after_hours")"
  [[ -n "$raw" ]] || return 0
  if [[ -f "$union_log_file" ]]; then
    touched="$(jq -c -R -n '
      [ inputs | select(length > 0) | (fromjson? // empty)
        | select(.event == "approver-verdict" or .event == "approver-unreviewed-engaged" or .event == "warning")
        | (.pr_url // empty) | select(. != "") ] | unique
    ' < "$union_log_file" 2>/dev/null)"
    [[ -n "$touched" ]] || touched='[]'
  fi
  jq -R -r --argjson touched "$touched" '
    (split("\t")) as $f
    | select(($f | length) == 4)
    | select(($touched | index($f[2])) == null)
    | $f | @tsv
  ' <<<"$raw" 2>/dev/null
}

# pager_eval_pr_unreviewed FLEET_NODES_JSON UNION_LOG_FILE
# Fires when at least one ready, non-draft, PAGER_EVAL_PR_LABEL pull request,
# older than PAGER_EVAL_APPROVER_UNREVIEWED_ENGAGE_AFTER_HOURS (requirement
# 46's own cutoff, reused rather than duplicated), carries no standing
# review, no approver-verdict, no Approver warning and no
# approver-unreviewed-engaged event at all — requirement 46's own unreviewed
# trigger never having run for it even once. Caught: PR #1059, stranded when
# the kill-switch read failed closed with no log line (#1081) — exactly the
# silent skip this invariant is built to notice from outside the sweep that
# skipped.
pager_eval_pr_unreviewed() {
  local _fleet_nodes_json="$1" union_log_file="$2"
  local repos_json="${PAGER_EVAL_REPOS_JSON:-}" pr_label="${PAGER_EVAL_PR_LABEL:-}" \
        hours="${PAGER_EVAL_APPROVER_UNREVIEWED_ENGAGE_AFTER_HOURS:-}"
  local hits
  hits="$(_pager_pr_unreviewed_candidates "$repos_json" "$pr_label" "$hours" "$union_log_file")"
  [[ -n "$hits" ]] || { printf '{"firing":false}'; return 0; }
  jq -Rsc '
    (split("\n") | map(select(length > 0) | split("\t")) | map({repo: .[0], number: .[1]})) as $rows
    | {firing: true, nodes: [],
       evidence: ("\($rows | length) ready pull request(s) with no standing review, no approver-verdict, no Approver warning and no approver-unreviewed-engaged event at all — requirement 46'\''s own unreviewed trigger (agent-ops#890) never ran for them (the #1081 signature): "
         + ($rows | map("\(.repo)#\(.number)") | join(", ")))}
  ' <<<"$hits" 2>/dev/null || printf '{"firing":false}'
}

# pager_remedy_pr_unreviewed KEY EVIDENCE
# Pipeline act: re-derives the same candidate set (never parses EVIDENCE's
# own prose, `pager_remedy_page_outlived_item`'s own terms) and, for each,
# logs the identical `approver-unreviewed-engaged` event requirement 46's own
# sweep would (`result: "unavailable"` — truthful, since this framework has
# no clone or model credential with which to post a real review itself, the
# same host-independence this issue's own compatibility note requires).
# Logging it is the "enqueue" the issue's own remedy text asks for: it starts
# the escalate clock `_approver_restale_sweep_repo` reads
# (`approver_unreviewed_prior_engagement`) for a pull request that clock had
# never started for at all, so the very next ordinary sweep — any node, its
# own next cycle, needing no signal from here to run — either posts a real
# review or, once `approver_restale_escalate_after_hours` passes from this
# logged engagement, escalates to `enabler_assignee` itself: the "file if a
# second window passes" half of the issue's own remedy text, performed by
# the sweep this remedy hands the baton to rather than reimplemented here.
pager_remedy_pr_unreviewed() {
  local _key="$1" _evidence="$2"
  local repos_json="${PAGER_EVAL_REPOS_JSON:-}" pr_label="${PAGER_EVAL_PR_LABEL:-}" \
        hours="${PAGER_EVAL_APPROVER_UNREVIEWED_ENGAGE_AFTER_HOURS:-}" \
        union_log_file="${PAGER_REMEDY_UNION_LOG_FILE:-}" log_file="${PAGER_REMEDY_LOG_FILE:-}" \
        node="${PAGER_REMEDY_NODE:-}" cycle="${PAGER_REMEDY_CYCLE:-}"
  [[ -n "$log_file" ]] || { printf 'no PAGER_REMEDY_LOG_FILE — nothing to enqueue'; return 1; }
  local hits repo number url head engaged=0
  hits="$(_pager_pr_unreviewed_candidates "$repos_json" "$pr_label" "$hours" "$union_log_file")"
  while IFS=$'\t' read -r repo number url head; do
    [[ -n "$url" ]] || continue
    pager_log_event "$log_file" "$node" "$cycle" "approver-unreviewed-engaged" \
      "$(jq -nc --arg u "$url" --arg r "$repo" --arg h "$head" \
        '{pr_url: $u, repo: $r, head: $h, result: "unavailable"}')"
    engaged=$(( engaged + 1 ))
  done <<<"$hits"
  printf 'enqueued %d ready pull request(s) into requirement 46'\''s own retry/escalate memory (approver-unreviewed-engaged, result: unavailable)' "$engaged"
}

# pager_register_builtin_invariants [STALE_FILE_AFTER_MINUTES] \
#                                    [CYCLE_INTERVAL_MINUTES]
# Register every built-in invariant above with lib/pager.sh's own registry.
# Not top-level code (see this file's header). STALE_FILE_AFTER_MINUTES —
# `pager_stale_file_after_minutes` (config.schema.json), default 180 when
# omitted — is node-stale's own per-key override of the framework's ordinary
# `pager_min_firing_minutes` hysteresis (lib/pager.sh's `pager_register`,
# fifth argument): the fact behind node-stale is itself already slow-forming
# (a publication age past 2× node_stale_after_minutes), so filing waits far
# longer than the framework's own blip-sized default before opening a
# tracking issue.
#
# CYCLE_INTERVAL_MINUTES — `schedule.cycle_interval_minutes`, omitted by a
# caller that only wants the list of registered keys — sets firing-missed's
# own override the same way, and for the opposite reason: its fact forms
# *instantly* at a moment when it means nothing. A node promoted from
# standby to active has a newest cycle event as old as its demotion, so the
# invariant fires the instant the promotion is published, and keeps firing
# until the node's first tick comes round — up to one whole interval away,
# plus the time a peer needs to see that tick (state-sync fetches every 7
# minutes). Filing waits that out: one interval plus fifteen minutes, so the
# first `cycle-start` clears the candidate before any page is written, while
# a scheduler that has genuinely dropped a firing keeps the fact true across
# the window and is filed as before (agent-ops#1686's own second edge — the
# exemption fixes the standby that never cycles, this fixes the standby that
# has just been told to). Omitted, or not a number, falls through to the
# framework's own `pager_min_firing_minutes` exactly as before.
pager_register_builtin_invariants() {
  local stale_file_after_minutes="${1:-180}" cycle_interval_minutes="${2:-}"
  local firing_missed_file_after=""
  if [[ "$cycle_interval_minutes" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    # Rounded up: the window is a floor to clear a promotion, not a budget.
    firing_missed_file_after="$(awk -v i="$cycle_interval_minutes" \
      'BEGIN { v = i + 15; printf "%d", (v == int(v) ? v : int(v) + 1) }')"
  fi
  pager_register verdict-unanimous pager_eval_verdict_unanimous \
    pipeline-act pager_remedy_verdict_unanimous
  pager_register page-outlived-item pager_eval_page_outlived_item \
    pipeline-act pager_remedy_page_outlived_item
  pager_register firing-missed pager_eval_firing_missed owner-only \
    "A node the fleet expects to be cycling appears to have had a firing dropped outright (the union log carries neither a cycle-start nor a cycle-skipped recent enough, and this node's newest cycle event is not an unmatched cycle-start) rather than merely still running a long cycle — a cycle-skipped would itself have proved the scheduler ticked and deferred to a held lock. Check the node's own cron/supercronic logs and crontab directly — on Kubernetes, check for a concurrencyPolicy: Forbid skip. The evidence above carries this node's own recent cycle-duration histogram. A node whose published role is a standby's is never named here: requirement 2.4 stops its ticks before the log, so there is nothing in the union log to judge it by in either direction, and a standby whose scheduler has stopped is invisible until it is promoted (agent-ops#1788). If this page names a node you have just promoted, its first cycle will clear it; if it names one you then demote, the page is closed as cleared, because the fleet has stopped expecting cycles from it." \
    "$firing_missed_file_after"
  pager_register node-stale pager_eval_node_stale owner-only \
    "This node has not confirmed a publication into the shared state for over twice node_stale_after_minutes. Confirm directly whether the node (container/host) is still running, and check its own state-sync push logs. Once agent-ops#1279's notification channel lands, this class of page reaches it automatically (notify_events' own default includes \"pager\") — today it is filed only." \
    "$stale_file_after_minutes"
  pager_register updater-stuck pager_eval_updater_stuck owner-only \
    "A container this node's own updater told to roll has been \"stuck\" for over twice updater_stuck_after_minutes. Check watchtower / the deploy pipeline on this node directly — this may be agent-ops#603's container-name collision, or, on Kubernetes, an ImagePullBackOff or a rollout stuck past progressDeadlineSeconds."
  pager_register review-pipeline-failing pager_eval_review_pipeline_failing owner-only \
    "The repository-review pipeline (review-cycle.sh) has failed its last several attempts on this node with no successful review-end between. Start with that node's own project-reviewer verdict (agent-ops#996): the dashboard's Review stage health panel, or the review_stage_health field of its heartbeat, which carries the consecutive-failure count and the last attempt's own detail. Then check review-log.jsonl and the Reviewer stage's own logs on this node directly."
  pager_register dashboard-unreadable pager_eval_dashboard_unreadable owner-only \
    "A viewer fetching this node's data.js (agent-ops#1283's own probe) found it slower than pager_dashboard_fetch_seconds or unparseable — a fact this node cannot observe about itself. Check network/tailnet conditions to this node and the size of its data.js directly."
  # agent-ops#1281: the selection and ledger class.
  pager_register idle-with-demand pager_eval_idle_with_demand owner-only \
    "A node's own selection/stand-down history shows real demand going unclaimed for several cycles running (agent-ops#1128/#1163/#1165's own class of fleet-wide stand-down and starvation). The evidence above carries this node's own most recent none-selected reason and coordinator-input-fitted detail — the two facts a diagnosis starts from. Check the Co-Ordinator's own verdicts and eligibility gates on this node directly."
  pager_register fit-ladder-pinned pager_eval_fit_ladder_pinned owner-only \
    "The coordinator input ladder (lib/coordinator-input.sh) has bottomed out at its own tightest rung and is still shedding backlog entries on every fitted cycle for a full day — the eligible backlog has outgrown coordinator_prompt_max_bytes. Either raise the byte budget or reduce the backlog (close stale issues, tighten a repo's own sources) directly."
  pager_register work-order-repaired-rate pager_eval_work_order_repaired_rate owner-only \
    "More than pager_repair_rate_percent of a day's selections needed a work-order-repaired repair (agent-ops#821's own signature: a work order composed from trimmed input). Check the fit report and the trimmed candidates' own sizes directly. Retire this invariant once agent-ops#769's part (b) lands and agent-ops#1156 removes the gate this rate reads."
  pager_register blocked-label-orphaned pager_eval_blocked_label_orphaned \
    pipeline-act pager_remedy_blocked_label_orphaned
  pager_register claim-unreconciled pager_eval_claim_unreconciled \
    pipeline-act pager_remedy_claim_unreconciled
  pager_register escalation-burst pager_eval_escalation_burst owner-only \
    "More than pager_escalation_burst escalations were filed fleet-wide in the trailing 24h, or the same re-flag reason paged the same item twice (agent-ops#933's own signature: a mechanical burst from a handful of unfixed bugs). The evidence above carries the reason histogram — start from whichever reason recurs most."
  pager_register digest-truncated pager_eval_digest_truncated \
    pipeline-act pager_remedy_digest_truncated
  # agent-ops#1280: the landing and approval class.
  pager_register landing-never-armed pager_eval_landing_never_armed \
    pipeline-act pager_remedy_landing_never_armed
  pager_register landing-refused-unknown pager_eval_landing_refused_unknown \
    pipeline-act pager_remedy_landing_refused_unknown
  pager_register pr-unreviewed pager_eval_pr_unreviewed \
    pipeline-act pager_remedy_pr_unreviewed
}
