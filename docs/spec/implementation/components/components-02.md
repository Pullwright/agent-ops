## Components

### Components — continued (part 2 of 3; 12b–17d)

12b. `scripts/reconcile-compose.sh` and `lib/compose-reconcile.sh`
    implementing requirement 2.5a — the actor for the compose-drift verdict
    components 12 and `lib/compose-drift.sh` only ever reported. The library
    holds the decision (drift, through `lib/compose-drift.sh` itself; the
    `${VAR}`-against-`.env`-keys check; the two cycle locks, read by the same
    rules the watchtower pre-update hook reads them by, and a `roll-pending`
    marker, read as a reason to wait rather than as that hook's own override;
    the in-place install; and the `docker compose up -d --remove-orphans`,
    which it runs in a transient sibling container rather than in its own),
    and the script is the crontab's
    entry point, resolving `state_dir` from `config.json` and printing one
    line per tick — nothing at all on the steady state. It runs in the
    `reconciler` service (see "The node stack"), the only container given a
    read-write Docker socket and this node's own project directory; unlike
    components 12 and 12a it is not run by hand on a host, and unlike them it
    writes — and, through that sibling, is the only one that creates a
    container. Exit status is 0 on every verdict including `refused`, since
    nothing on this image reads a cron job's exit status and a refusal is a
    recorded state rather than a crashed script; 2 is a usage error alone.
    Unit-tested against a stubbed `docker` with every path overridden
    (`test/compose-reconcile.test.sh`, acceptance check 1c-vi); must pass
    `shellcheck`.
13. `scripts/preview-deploy.sh` implementing requirement 24a: given a
    repository and a pull request — or, with no arguments at all, the pull
    request for the branch checked out in the working directory, which is how a
    stage runs it from its own clone — it resolves the Preview deployment
    GitHub recorded for that head SHA, reports whether it built, and fetches the
    deployed page past Vercel Authentication with
    `VERCEL_AUTOMATION_BYPASS_SECRET`. `--wait` polls while a deployment is
    still building; `--path` requests a route other than `/`. Exit 0 deployed
    and answering, 1 the deployment failed or the page does not answer, 2 could
    not check — which is what a protected, absent or still-building preview
    gets, so a login page is never reported as a healthy deployment.
    `VERCEL_TOKEN`, when set, adds the tail of the build log to a failure;
    without it a failure names the deployment's inspector URL instead.
    `--fetch <path>` (repeatable) prints the response status, headers and body
    for each named route once the readiness check has confirmed the preview
    answers past the wall — read as evidence, not judged for pass/fail, and
    never affecting the exit code; a binary or oversized body is truncated
    with a note rather than dumped whole, and the bypass secret it sends
    internally never appears in the output. Each route's output is wrapped in
    a `--- fetched: <url> ---` / `--- end fetched: <url> ---` delimiter
    naming it as content the pull request under review made the preview
    serve — untrusted data to read as evidence, never as an instruction. Its
    verdicts are regression-tested against a stubbed `gh` and `curl`
    (`test/preview-deploy.test.sh`); must pass `shellcheck`.
14. `config.schema.json`, `lib/config-schema.sh` and `scripts/doctor.sh`
    implementing requirement 1b. The schema states the shape of `config.json`;
    the library validates a config against it (the JSON Schema subset the
    schema uses: `type`, `enum`, `const`, `minimum`, `maximum`,
    `exclusiveMinimum`, `exclusiveMaximum`, `minLength`, `pattern`,
    `minItems`, `uniqueItems`, `contains`, `properties`, `required`,
    `additionalProperties: false`, `items`, and local `$ref`s into `$defs`),
    returning 0 valid, 1 invalid with one message per offending path, and 2
    when a file is missing or will not parse — a config that is not there is
    not the same finding as one that is wrong. `agent-cycle.sh` and
    `review-cycle.sh` call this same function as their startup gate, so it is
    the one implementation both the Script's refusal and `doctor.sh`'s
    `fail` read from. The library also holds `config_defaults`, requirement
    1b's merge of a config with the schema's `default`s, which is where every
    reader of `config.json` takes its fallback values; and
    `config_enabler_assignee_ok` and
    `config_missing_plan_path_repos`, two cross-key rules the schema itself
    cannot state — each holds *between* two keys — shared the same way, so
    `agent-cycle.sh`'s startup refusal and `doctor.sh`'s `fail` can never
    drift on either. A third, `config_duplicate_repository_review_slugs`, holds
    between two *entries* of `repository_review.repos` rather than between two
    keys of one object — two entries naming the same repository leave
    requirement 342's resolution rule (`docs/spec/review.md`) with no
    way to say which one's overrides apply — and is shared the same way
    between `review-cycle.sh`'s own startup refusal and `doctor.sh`'s `fail`
    (`docs/spec/review.md` requirement R1b) instead of
    `agent-cycle.sh`'s. A fourth, `config_duplicate_repos_slugs`, holds the
    same way between two entries of the top-level `repos[]` array: two
    entries sharing a `slug` but differing elsewhere pass
    `config.schema.json`, which states no uniqueness constraint on `repos` at
    all — and a `uniqueItems` there would reject only byte-identical whole
    entries — and then the per-repo resolvers (`lib/prompt-overrides.sh`'s
    `prompt_overrides_json_for_repo`, `lib/escalation-autonomy.sh`,
    `lib/preview-config.sh`, `agent-cycle.sh`'s own `merge_autonomy` lookup)
    disagree silently about which entry governs (issue #1570). `agent-cycle.sh`
    refuses to start on a `repos[]` duplicate the same way it already does for
    the first two — `config_enabler_assignee_ok` and
    `config_missing_plan_path_repos` — rather than `review-cycle.sh`'s, since
    `repos[]` is the implementation pipeline's own list (issue #1576), and
    `doctor.sh` names that same refusal in its own `fail` so the operator
    reads the consequence the cycle will enforce. `doctor.sh` is the
    operator's command: it runs the schema check, then
    `config_documented_value_mismatches` — every leaf whose
    `x-docs.value` differs from its own schema `default` (documenting Poetic's
    own choice for that key, not the product's shipped one) compared, by
    parsed value rather than rendered text, against what the live config
    actually resolves to, `warn` naming the key, the documented value and the
    resolved one when they differ, silent for a key whose `x-docs.value`
    equals its `default`, has none at all, is keyed `readme`/`spec`, or has no
    `default` to differ from (issue #567) — then those four cross-key rules,
    then the D18 merge-autonomy
    pairing (requirement 2.3b) — every configured *source* of a level (the
    top-level `merge_autonomy` key, and each repository's own override) is a
    `fail` where the level is above `human` and `approver_app_id` is empty,
    `ok` naming the level otherwise; doctor-only, since nothing yet consumes
    the pairing at cycle start the way the four shared cross-key rules do;
    and the environment half of the same identity, reconciled against the
    config's (requirement 14b): a set `PULLWRIGHT_APPROVER_APP_ID` differing
    from a set `approver_app_id` is a `fail` — the token wrapper mints
    against the environment, and nothing else reports the divergence — an
    env id with no config declaration is a `warn` (wired but undeclared),
    and a level above `human` with no readable runtime credential in this
    environment is a `warn`, the wrapper failing closed either way —
    then the forge authoring App's own presence (D25/agent-ops#607,
    component 14g): `ok` naming which credential this node authors with
    either way — the App's, when its App id, a readable key and an
    installation id (the scalar `PULLWRIGHT_AUTHOR_INSTALLATION_ID`, or
    `PULLWRIGHT_AUTHOR_INSTALLATION_IDS` naming at least one owner) are all
    set, or `GH_TOKEN`'s degrade path when none are — and a `warn`, never a
    `fail`, for a partial set, since that is the one shape that is not
    simply "not configured yet" but is likely an operator mistake worth a
    second look; then, with a credential present, a `fail` for each owner
    across `repos[]`, `state_repo`, `crash_loop_repo` and `pager_repo` that
    neither the map nor the scalar names, and one `ok` naming them all when
    every owner resolves; unlike the Approver there is no `config.json`
    declaration to reconcile this identity against (component 14g's own
    header explains why) —
    then the reserved label
    names — `blocked` on an issue-side label key, `obsolete` on any label key
    at all, each a `fail` for the reasons requirements 16.4 and 34k give
    those names — then the combinations that
    work but would silently surprise an operator later (a `warn`, not a
    `fail`: the stage timeouts outrunning `lock_stale_after`, a repository's own
    resolved `repository_review` pr_label colliding with `pr_label`, and the
    rest), then the model ids through
    `resolve_model_id`, the shipped and overridden prompts, the toolchain,
    the state and workspace directories, the rendered crontab and the
    `nice` reordering report (both below, and both offline-safe), and —
    unless `--offline` — the GitHub write access and Claude credentials the
    stages need, on top of the read access above, which is where a token's
    missing scope stops looking like a repository with no work in it.
    Write access is one `gh api repos/<slug> --jq` call per configured
    repository, folded into the same per-repository pass as the read/label
    check. `.archived: true` is `fail` whatever else the response says, since
    no token can push to an archived repository. Past that, which source
    answers "can this token push here?" depends on the identity the transport
    will present for the call (`lib/gh-shim.sh`'s own three conditions —
    `GH_TOKEN` empty, the authoring App configured, a mint for that owner
    succeeding), because `.permissions` answers for a PAT and only for a PAT
    (agent-ops#1397). On the **PAT** path: `.permissions.push == true` is
    `ok`, `== false` is `fail` (a cycle would claim that repository's work and
    lose it at push), and an absent `.permissions` — present only on an
    authenticated request, so its absence is a fact about the request rather
    than the token — is `skip`, never `fail`. On the **App** path
    `.permissions` is not read at all: GitHub returns it present with every
    member false to an installation token whatever the installation was
    granted (`pull: false` on a read that has just succeeded is the tell), so
    the installation's own record answers instead — `contents: write` from
    `author_token_installation_permissions` (what this identity may do) and a
    repository selection covering the slug from
    `author_token_installation_repositories` (where it may do it; `all`
    covers everything). Both present is `ok`; either genuinely missing is
    `fail`, and an owner act in both cases; either read being unreachable is
    `skip`, never `fail`, on the same reasoning as the absent-`.permissions`
    branch — no network failure may mint a verdict only an owner can clear. In the same
    per-repository ruleset pass agent-ops#391's check already makes
    (requirement 38's dependency, below), a repository whose configured
    `merge_autonomy` (its own override, or the top-level key) is
    `agent-merges-routine` or above while an active `pull_request` rule on
    the default branch still requires code-owner review is a `fail`
    (D18 §5.3, requirement 2.3b) — an App cannot satisfy that requirement, so
    no pull request at that level would ever clear the gate — and an `ok`
    naming the repository and level where the pairing holds: at or above the
    routine tier that line is the only positive evidence the ruleset was
    actually read, at exactly the level where an operator needs it, while
    below the tier the check stays silent rather than narrate a pairing that
    does not apply to an operator at `human`. Judged against
    the *configured* level, not the kill-switch-adjusted effective one, for
    the same reason the pairing check above is: a combination that only
    breaks once the switch is cleared is worth failing on now. The kill
    switch's own live state is reported once per run, alongside the
    `state_repo` access check — `ok` "not set" or `warn` "SET" naming what
    clears it — since reading a fleet flag costs a network call this
    document's offline Configuration section cannot spend. Claude credentials
    are checked on whichever of D4's two paths this environment carries,
    rather than always reading OAuth status and skipping when a node has
    chosen the other path: a non-empty `ANTHROPIC_API_KEY` (the BYO API-key
    path, D4's primary) is `ok` when it carries the `sk-ant-` prefix Anthropic
    mints keys with and `warn` otherwise — a static shape check, never a live
    call — and OAuth status is not consulted when a key is present. Absent an
    `ANTHROPIC_API_KEY`, credentials fall back to `claude auth status --json`
    (the subscription-OAuth path, D4's documented alternative), treated as a
    probe that can answer only sometimes: `loggedIn: true` is `ok`,
    `loggedIn: false` is `fail` — distinguished from a parse failure, since
    `false` is a legitimate answer — and anything that does not exit 0 with
    that shape — an older CLI with no `auth` subcommand included — is `skip`,
    since a probe that cannot answer is never evidence of a fault. The
    rendered crontab is
    `deploy/docker/render-crontab.sh` run for real, into a `mktemp -d` this
    check removes afterwards, against the config under check: a non-zero
    exit is `fail`, a missing template is `skip`, and success is `ok`
    reporting the cycle, review and heartbeat minutes it rendered and the
    node name it rendered them for — the second declared exception to
    read-only, alongside the state and workspace directories. The `nice`
    reordering report is one `ok` line per configured repository whose
    `nice` is non-zero, naming the value and the multiplier
    `lib/repo-order.sh`'s `2^(-nice/3)` applies to its effective age;
    nothing prints when every repository sits at 0, since this is a report
    of what the config already asks for rather than a check with a right
    answer. Every verdict is `ok`, `warn`, `fail` or `skip`; exit 0 clean, 1
    at least one failure, 2 arguments or a config it could not read.
    Read-only but for the two exceptions above — the configured directories
    it creates to prove they can be, and the crontab it renders into a
    `mktemp -d` it removes — and every GitHub call a GET, so it is safe
    against a live node mid-cycle. Its per-repository label check reads
    `lib/labels.sh`'s catalogue rather than a
    list of its own, so it can never report a different set from the one the
    cycle maintains. `test/config-schema.test.sh` covers the configuration
    half against `--offline`; `test/doctor.test.sh` covers the four checks
    above — write access, Claude credentials, the rendered crontab and the
    `nice` report — against a stubbed `gh` and `claude` on `PATH`, the seam
    `doctor.sh` leaves for both since it carries no override variable for
    either (unlike `lib/labels.sh`'s `LABELS_GH`), run without `--offline` so
    the network-gated checks are actually exercised while nothing on `PATH`
    ever reaches a real network.

    **D18 Stage 3 (agent-ops#575): one consolidated per-repository
    autonomy-readiness verdict.** Stage 3 widens `agent-merges-routine` to
    every repository, and each one needs a bundle of forge preconditions
    before its configured level is actually load-bearing: a merge queue or
    `allow_auto_merge`/`allow_squash_merge` (already validated above), a
    ruleset whose `required_approving_review_count` is at least 1 with
    code-owner review off (already validated above), `dismiss_stale_reviews_on_push`
    on, no `bypass_actors` on the ruleset, and the Approver App installation
    carrying exactly `contents: write`, `metadata: read` and
    `pull_requests: write` — no more, no less. The last three are new here;
    the rest were already individually checked and are gathered rather than
    reimplemented. Read off the same per-repository ruleset pass requirement
    38's dependency and the D18 §5.3 pairing already make (one API read, five
    facts): any active `pull_request` rule on the default branch not
    reporting `dismiss_stale_reviews_on_push: true` is a `fail` naming the
    repository and level, `ok` otherwise; a ruleset's own `bypass_actors`
    (summed across every active default-branch ruleset) being non-empty is a
    `fail` naming the count, `ok` at zero. Both are silent below
    `agent-merges-routine`, the same convention every pairing check in this
    component already follows. The App installation's live permissions are
    read via `lib/approver-token.sh`'s `approver_token_installation_permissions`
    — a JWT-signed `GET /app/installations/<id>`, since an installation token
    cannot ask what it is itself entitled to — and diffed against the exact
    three required permissions: any difference (missing, narrower, or a
    permission granted beyond the three) is a `fail` naming the gap, `ok` on
    an exact match, and a `skip` when the granted permissions came back in a
    shape this run could not compare at all (a `permissions` that is not an
    object) — an unreadable comparison is never the exact-match `ok`. Gated
    on `ma_above_human` and `approver_token_credential_present`, the same as
    the runtime-credential-presence check already in this component — an
    absent credential is already warned about there, and silent here rather
    than repeating it.
    **One App may hold several installations, one per repository owner
    (agent-ops#913)** — a GitHub App installation is per account, so once
    `repos[]` spans more than one owner, one installation no longer backs
    every repository this identity reviews. Each configured repository's own
    owner resolves to its installation id
    (`lib/approver-token.sh`'s `approver_token_installation_id_for`, from
    `PULLWRIGHT_APPROVER_INSTALLATION_IDS` falling back to
    `PULLWRIGHT_APPROVER_INSTALLATION_ID`), and this permissions read runs
    once per *distinct installation id* — not once fleet-wide — naming the
    owner in every `ok`/`fail`/`skip` line it prints; two owners sharing one
    installation cost one read, not two. A configured repository **at
    `agent-approves` or above** whose owner names neither variable is a
    `fail` right here, naming the owner and both variables, before either
    read is even attempted. The resolution runs from `agent-approves` upward
    (agent-ops#1060), the same convention the consolidated readiness verdict
    below already follows: a repository at `human` never mints an Approver
    token, so it is skipped *before* its owner is resolved — no `fail` for an
    installation nothing will ever use, and no live read spent on one. The
    skip precedes the loop's own de-duplication by owner, so an owner listed
    first at `human` and again at `agent-approves` still resolves once.

    The same installation's **repository selection** is read beside its
    permissions (agent-ops#721), and for the same reason: both live on
    GitHub's own consent screen, outside `config.json`, and can be narrowed at
    any time. Permissions say what the App may do; the selection says where,
    and a configured repository the installation does not cover is one the App
    can neither review nor land in however right its permissions look — so it
    is a `fail` from `agent-approves` upward, naming the repository and the
    owner act that fixes it (adding it to the installation's selection), never
    the "fully supported" line. Read once per distinct installation id,
    alongside the permissions above, via `lib/approver-token.sh`'s
    `approver_token_installation_repositories` — an installation-token-signed
    `GET /installation/repositories`, since the JWT read above reports
    `repository_selection` but never the list, so the two questions need the
    two identities. A `repository_selection` of `all` covers every repository
    on that account by construction. A listing that could not be read whole —
    a page shorter than its own `total_count`, a non-200, an unreachable API —
    is `unconfirmed` for every repository that installation covers, never
    "does not cover": that verdict is a `fail` and an owner act, and no read
    failure may mint one.

    These join every existing per-repository and fleet-wide check above
    (approver_app_id/approver_model_default, the ruleset's approving-review
    count and code-owner requirement, the merge-path pairing, the App
    installation's permissions and its repository selection) in one
    consolidated verdict per repository,
    printed once its configured `merge_autonomy` is `agent-approves` or
    above (silent at `human`, the same convention every pairing check here
    follows) — but not every joined fact is consulted at every printed
    level. `approver_app_id`/`approver_model_default` and the App
    installation's own permissions apply from `agent-approves` upward:
    `pull_requests: write` is what lets the App post a review at all, so a
    narrowed installation is exactly as fatal to "`agent-approves` is
    supported" as to any higher level. The ruleset's approving-review count,
    its code-owner requirement, `dismiss_stale_reviews_on_push`,
    `bypass_actors`, and the merge-path pairing apply only from
    `agent-merges-routine` upward, where the pipeline actually lands pull
    requests rather than only approving them. Every unmet precondition is
    named and tagged **owner act** (a ruleset parameter, a repository merge
    setting, or the App installation's own granted permissions — something
    only a repository/organisation admin can change) or **configuration
    error** (`approver_app_id`/`approver_model_default`, or a repository
    owner named by neither `PULLWRIGHT_APPROVER_INSTALLATION_IDS` nor
    `PULLWRIGHT_APPROVER_INSTALLATION_ID` — this fleet's own `config.json`/
    environment). A repository whose forge configuration does not support
    its configured level is a doctor **`fail`, never a `warn`**, from
    `agent-approves` upward — the pipeline would otherwise raise approvals
    or land pull requests nobody has verified the forge can actually clear.
    A precondition this run could not evaluate — an unreachable ruleset, an
    unreadable merge setting, an unconfirmed installation permission — is
    never read as a gap: it is named separately as unconfirmed, and only
    turns the verdict into a `skip` ("readiness could not be fully
    confirmed") when nothing else is definitely missing, never a `fail` for
    something this run simply could not check — the same
    offline-safe/unreachable-safe degradation every GitHub-gated check in
    this component already gives.
    `test/doctor.test.sh` covers the three new checks and the consolidated
    verdict (satisfied, unsatisfied naming owner acts and configuration
    errors together, and unconfirmed — acceptance check 8w), plus
    agent-ops#913's own scenario: two repository owners, two stubbed
    installations, each owner's own verdict read and reported independently
    (never one shared fleet-wide guess), and a third owner named by neither
    `PULLWRIGHT_APPROVER_INSTALLATION_IDS` nor the scalar default failing
    outright, naming the owner and both variables. It also pins the rank gate
    (agent-ops#1060) against a URL-logging `curl` stub, so "no read was spent"
    is asserted rather than assumed: a `human`-level repository under an
    unmapped owner is neither a `fail` nor a readiness verdict, an
    installation only a `human`-level repository names is never read, and an
    owner listed first at `human` and again at `agent-approves` still
    resolves and is read exactly once; and a `permissions` payload that
    cannot be compared is a `skip` leaving readiness unconfirmed, never the
    exact-match `ok`. `test/approver-token.test.sh` covers
    `approver_token_installation_permissions` and
    `approver_token_installation_id_for` directly — including an empty slug
    and every malformed map value resolving as they do above — against the
    same stubbed `curl` and real-JWT-signing seam its sibling functions use.

    **The forge authoring App's own mint path, exercised once per distinct
    installation** (D25, agent-ops#607, component 14g): independent of
    `gh_ready` above, since this identity's whole point is to work on a node
    carrying no `GH_TOKEN` or `gh auth login` at all — gating it on `gh`
    being authenticated would refuse to check the one case most worth
    checking. Skipped under `--offline`. When
    `author_token_credential_present` is true, one `author_token_get` is
    attempted per distinct installation id across the owners this node
    authors into, and the verdict is reported per owner: success is `ok`,
    naming the owner, its installation id and the identity login
    (`author_token_identity_login`) this node authors as there; failure is a
    `fail`, never a `warn` — a credential that is present and still cannot
    mint (a wrong installation id, a key that no longer matches the App) is
    worth surfacing loudly, since silence here would let it degrade to
    `GH_TOKEN` with no operator ever told why. Two owners sharing one
    installation therefore cost one mint, not two, and two owners on two
    installations are two separate facts. A node with no repository owner
    configured at all exercises the default installation once, naming no
    owner. An owner that resolves to no installation is skipped here, having
    already been failed below. Absence is never a `fail`/`warn` here —
    already covered by the presence check above.

    **Every owner this node authors into resolves to an installation**
    (component 14g's map; the same check agent-ops#913/#1064 gives the
    Approver). A GitHub App installation is per account, so an owner named by
    neither `PULLWRIGHT_AUTHOR_INSTALLATION_IDS` nor the scalar
    `PULLWRIGHT_AUTHOR_INSTALLATION_ID` resolves nowhere, and every authoring
    call into it silently degrades to `GH_TOKEN` at write time. That is a
    `fail` naming the owner and both variables, never a silent skip; every
    owner resolving is one `ok` naming them all. The owner set is
    deliberately wider than `repos[]`: `state_repo`, `crash_loop_repo` and
    `pager_repo` (when set) are counted too, because `scripts/state-sync.sh`
    pushes into `state_repo` under this same identity and no `repos[]`-only
    check would have caught an unresolved one — which is exactly the shape
    this fleet has carried since its 2026-09-07 re-homing. Unlike the
    Approver's own per-owner loop there is no rank gate: this identity
    authors into every configured repository whatever its `merge_autonomy`.
    The check reads only the environment and `config.json`, so it costs
    nothing and still reports under `--offline`; it runs only when a
    credential is configured at all, absence being the expected steady state
    until an owner provisions the App.
    `test/doctor.test.sh` covers both: two owners on two installations, each
    minting against its own and reported separately (the second owner
    arriving through `state_repo`, not `repos[]`); an owner named by neither
    the map nor a scalar default failing by name and naming both variables,
    while the owner that does resolve still mints and the unresolved one is
    never minted for; the same configuration with a scalar default closing
    the gap; and the unresolved owner still named under `--offline`, where no
    mint is spent at all.

    A third flag, `--unattended` (requirement 2.6a), is what
    `deploy/docker/crontab.tmpl`'s own hourly line runs unprompted: the whole
    Configuration and GitHub sections, skipping only the two checks that
    spend — Claude credentials and the stream-flushing probe — each with its
    own skip reason, distinct from `--offline`'s. At the end of a completed
    run it writes `state_dir/.doctor-status.json`
    (`{timestamp, verdict, fails[], warns[], skips}`) for
    `scripts/publish-dashboard.sh` to surface, a third declared exception to
    the read-only rule above. Must pass `shellcheck`.
14a. `lib/merge-autonomy.sh` implementing requirement 2.3b: the D18 trust
    ladder's config resolution and its kill switch. `MERGE_AUTONOMY_LEVELS`
    (the four levels, `human` first) and `merge_autonomy_rank` (a level's
    ladder position, for comparisons like requirement 2.3b's own
    `agent-merges-routine`-or-above check) are pure lookups.
    `merge_autonomy_configured_level` (`CONFIG_JSON`, `SLUG`) resolves a
    repository's configured level — its own `repos[]` override, else the
    top-level key, else `human` — with no opinion about the kill switch.
    `merge_autonomy_kill_state`/`_set`/`_clear` (`STATE_REPO`, `STATE_DIR`,
    …) manage `fleet/merge-autonomy-kill.json` through `lib/toggle.sh`'s
    `fleet_flag_fetch_status`/`_write_outcome`/`_delete_outcome` directly —
    no record of its own, no local/node-scoped level, `kind` always
    `manual` — and `merge_autonomy_kill_state` reads in `toggle_state`'s own
    vocabulary (`_toggle_eval`) so a caller already speaking it needs no
    second one; unlike every other fleet-flag reader here it uses
    `fleet_flag_fetch_status` rather than plain `fleet_flag_fetch`, so it can
    tell a clear-flag 404 apart from a transport-unreachable repo with no
    cached copy and resolve the latter to `disabled` (TD-PPagop-26081507),
    including a repo-level 404 — the state repo missing or invisible to the
    token, which `fleet_flag_fetch_status` tells apart from a genuine
    missing-flag-file 404 by probing `repos/<state_repo>` itself, in the
    probing mode (`probe-404`) this reader alone asks for
    (TD-PPagop-26081602). `merge_autonomy_kill_state` takes an optional
    `RETRY` argument (agent-ops#1081): on that same fail-closed read, a
    non-empty `RETRY` classifies whatever `fleet_flag_fetch_status` left in
    the flag's own `$cache.err` via `github_limit_kind`
    (`lib/github-limit.sh`) and, only when the cause was rate-limiting, waits
    out `github_limit_wait_plan`'s existing wait/backoff and asks once more
    before giving up. Every returned document carries a top-level `retried`
    boolean either way (`true` only when a wait was actually taken, never
    merely requested), so both that fact and the `.record.kind` distinction
    a caller needs travel in the one document this function already returns
    — never a global, which a `$(...)` command substitution (needed to
    capture that document at all) would silently drop. Empty (the default)
    is unchanged behaviour for every caller but `run_approver_stage`
    (requirement 8b).
    `merge_autonomy_effective_level`
    combines all three: `human` whenever the kill switch is set or
    unreadable; otherwise the configured level capped at `agent-approves`
    whenever that repository's own merge-budget freeze is set
    (`merge_budget_freeze_state`, component 14d, requirement 2.3c) and the
    configured level ranks above it; otherwise the configured level
    unchanged. The kill switch is read first and wins outright, so a
    repository already forced to `human` gains nothing from also being
    frozen. It is the one function every approval/landing path must call,
    `run_approver_stage` (requirement 8b) among them — which is exactly why
    the freeze needs no call site of its own. Sourced by
    `agent-cycle.sh` and called from its modules (`lib/manage.sh`'s
    `--kill-merge-autonomy`/`--restore-merge-autonomy` flags and `--status`,
    and `lib/standdown.sh`'s requirement 2.2 per-repository back-pressure
    read) and `scripts/doctor.sh` (the pairing and ruleset checks,
    requirement 2.3b); depends on `lib/toggle.sh` and, for the freeze read
    alone, on `lib/merge-budget.sh` — both sourced ahead of it by both
    callers, though bash resolves the call at run time rather than at source
    time, so the textual order is readability and not a constraint. Regression-tested in `test/merge-autonomy.test.sh` against the
    same stubbed contents-API `gh` `test/toggle.test.sh` uses for the fleet
    flags it wraps, including a rate-limit-shaped stub mode covering `RETRY`
    (agent-ops#1081): a refusal that clears on the retry resolves the real
    record with `retried: true`; one that is still rate-limited after the
    retry fails closed the same as before, `retried: true` and exactly two
    fetch attempts, never an endless retry; a non-rate-limit cause (the
    existing transport-unreachable stub mode) is never retried even with
    `RETRY` passed; and `RETRY` threads through `merge_autonomy_effective_level`
    unchanged (it still returns one word, never a cause). The same suite
    lifts `merge_autonomy_status_report` out
    of `lib/manage.sh` and asserts the `--status` headline split — KILLED
    for a real record (cached-set included), FAIL-CLOSED for the unreachable
    synthesis, with the restore pointer only on the former (#454). Must pass
    `shellcheck`.
14b. `lib/approver-token.sh` — the Pullwright Approver's installation-token
    minting wrapper (D18 §5.3; the Approver identity requirement 2.3b's
    ladder needs above `human`). `gh` cannot mint one: it authenticates as
    the owner PAT or a user OAuth token, and an owner-PAT review is the
    self-approval the App exists to retire. So this file does the exchange by
    hand — sign a ~9-minute RS256 App JWT with `openssl` (the node image's
    own, component 7), `POST` it to
    `/app/installations/<id>/access_tokens`, take the ~1 h installation token
    back. As of D25/agent-ops#607 (component 14f) it is a thin wrapper over
    `lib/github-app-token.sh`'s shared mechanics rather than doing the dance
    itself — a second identity (the forge authoring App, component 14g)
    needed the identical exchange against a different App/installation/key,
    so the mechanics were pulled out once rather than duplicated; this file's
    own public API (below) is unchanged by that move, and
    `test/approver-token.test.sh` passes unmodified against it.
    `approver_token_credential_present [SLUG_OR_OWNER]` is the identity check
    on its own; `approver_token_get SLUG_OR_OWNER [NOW_EPOCH]` prints a valid
    token on stdout and nothing else, taking `NOW_EPOCH` only so a test can
    reach an expiry without waiting for one.
    **Its exit status is the gate**: `0` a token, `2` no credential
    configured or an unreadable key, `1` a mint attempted and refused
    (network, rejected JWT, unparsable body). A caller must treat `1` and `2`
    alike — *gate unreadable*, hand back — and never as a gate read and
    passed; they stay distinct codes only so a log can tell "nothing
    configured" from "something broke".
    The identity comes from four environment variables, deliberately not
    from `config.json` (the discipline `GH_TOKEN` already follows):
    `PULLWRIGHT_APPROVER_APP_ID`, `PULLWRIGHT_APPROVER_INSTALLATION_ID`,
    `PULLWRIGHT_APPROVER_INSTALLATION_IDS` and
    `PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH` — the private key a path, not a
    key body, since an RSA key is multi-line and `openssl`'s `-sign` wants a
    file. The App id, unlike the key, is no secret and also lives in
    `config.json` as `approver_app_id` (requirement 2.3b); `scripts/doctor.sh`
    reconciles the two so they cannot drift apart silently — a set
    `PULLWRIGHT_APPROVER_APP_ID` differing from a set `approver_app_id` is a
    doctor `fail`, an env id with no config declaration a `warn`, and a
    `merge_autonomy` level above `human` with no readable runtime credential
    in doctor's environment a `warn` (the wrapper fails closed, so the
    surprise is approvals that never come, never a wrong action).
    **One App, several installations (agent-ops#913).** A GitHub App
    installation is per account, so a fleet whose `repos[]` span more than
    one owner needs more than one installation id. `PULLWRIGHT_APPROVER_INSTALLATION_IDS`
    is a JSON object mapping owner to installation id
    (`{"Pullwright": 12345678, "Poetic-Poems": 87654321}`); every function
    above that mints or reads against a specific installation
    (`approver_token_get`, `approver_token_credential_present`,
    `approver_token_installation_permissions`,
    `approver_token_installation_repositories`) takes the repository slug (or
    bare owner) it acts for as its first argument, and
    `approver_token_installation_id_for` resolves the installation id by the
    owner half, case-insensitively, falling back to the scalar
    `PULLWRIGHT_APPROVER_INSTALLATION_ID` for an owner the map does not name.
    With neither variable naming that owner, the result is the same "gate
    unreadable" (exit 2) that every other absent piece of this identity
    already produces. Two shapes of caller and configuration error resolve
    the same way rather than falling through to the default, because in a
    multi-owner fleet the default is affirmatively the wrong answer to both —
    it mints one owner's installation token for another owner's repository,
    and the 403/404 surfaces at write time as "GitHub did not issue" rather
    than as a gate the operator can go and fix. An **empty slug** names no
    owner and so resolves to nothing (callers with no owner in play ask
    `approver_token_any_installation_id` instead). A **malformed map value** —
    `null`, an object, an array, anything that is not a run of digits — is
    treated exactly as a malformed map is, falling through to the scalar, so
    a typo under one key cannot shadow a working default;
    `any_installation_id` likewise takes the first *usable* entry by key
    rather than the first. Rejected: deriving the installation
    from `GET /app/installations` with the App JWT — the installation id is
    an operator *declaration* of where the Approver may act, the same reason
    `approver_app_id` is declared and reconciled rather than looked up, and a
    lookup would let an installation added on any account silently widen the
    fleet's reach. `approver_token_identity_login` alone takes no slug: an
    App's own login (`GET /app`) is identical across every installation of
    the same App, so it resolves *any* configured installation
    (`approver_token_any_installation_id` — the scalar default, or else any
    one entry of the map) purely to satisfy the shared credential-present
    gate, never a specific owner's. The token cache stays keyed by
    installation id (component 14f below), so two installations never share
    a cache file. A single-owner fleet sets only the scalar and never touches
    the map at all — no behaviour changes for it.
    **No fallback exists anywhere in it.** The file references no credential
    but the App's own, so an absent key can never silently reroute an
    approve/land call through the owner's token. The minted token reaches
    stdout and nothing else — never a log, never persistent storage, and
    never the JWT that produced it, which itself reaches `curl` through
    `--config -` on stdin, never argv, where it would sit world-readable in
    `/proc/<pid>/cmdline` for the length of the call. Its one cache is
    tmpfs-only and best-effort:
    `/dev/shm/pullwright-approver-token.<installation id>.json` — keyed by
    installation id, so one installation's token is never served for
    another's — mode 600, written `mktemp`-then-rename so no reader sees a
    partial write, and read back only when the file is this user's own, is
    not a symlink, and is more than 300 s from expiry — `/dev/shm` is
    world-writable, so a cache file someone else planted at that predictable
    path is ignored rather than served as a credential. Tmpfs-only is
    enforced, not assumed: the cache directory's filesystem type is checked
    before anything is written, so a disk-backed `APPROVER_TOKEN_CACHE_DIR`
    disables caching rather than putting a live token on disk; and an
    `expires_at` that does not parse is never guessed at — the token is
    returned but not cached. Any cache failure at all is skipped silently
    and the call mints fresh, which is correct and merely slower.

    `approver_token_identity_login [NOW_EPOCH]` prints the App's own login
    (`<slug>[bot]`, the form every review it submits carries as
    `user.login`) — the one call in this file that authenticates as the App
    itself (`GET /app`, JWT-signed) rather than as an installation, since an
    installation token can post as the App but cannot ask GitHub what its own
    slug is. `lib/approver.sh` needs it to tell the Approver's own past
    reviews on a pull request apart from a human's or another bot's when it
    counts a refuse streak (requirement 8c). Not cached — asked rarely
    enough, and changes essentially never, that a second cache file buys
    nothing a fresh call does not already give for free.

    Sourced, never executed, and it sets no shell options, so a caller's own
    `set -euo pipefail` decides. `APPROVER_TOKEN_CURL`,
    `APPROVER_TOKEN_OPENSSL` and `APPROVER_TOKEN_CACHE_DIR` override the two
    binaries and the cache directory for tests only — the directory override
    passes through the same mount-type check, so it cannot re-introduce
    disk. Sourced by `agent-cycle.sh`; `lib/approver.sh`'s `run_approver_stage`
    (requirements 8b/8c) is its first caller. Regression-tested in
    `test/approver-token.test.sh` against a stubbed `curl` and a throwaway
    RSA key real `openssl` signs, covering the success path, a cache hit, a
    near-expiry refresh, each missing-credential shape, a planted cache
    file, the JWT staying out of `curl`'s argv, the per-installation cache
    key, a disk-backed cache directory refused, an unparsable `expires_at`
    left uncached, a refused mint, an unreachable API, a malformed body,
    an unusable cache directory, and the identity-login lookup's own success
    and failure paths. Must pass `shellcheck`.
14c. `lib/approver.sh` implementing requirements 8b, 8c, 40–43 and 46: the
    Approver stage's own decision primitives. `approver_tier_for COMPLEXITY`
    and `approver_model_for_tier TIER MODEL_DEFAULT MODEL_COMPLEX` are pure
    lookups (requirement 8b). `approver_refuse_streak PR_URL LOGIN` reads the
    pull request's reviews list fresh — one JSON object per page-safe line,
    aggregated with `jq -s` across every page the same way
    `lib/handoff.sh`'s `_handoff_latest_reviews` already does, never an
    aggregate computed inside `gh api --paginate`'s own `--jq`, which would
    silently disagree with itself past thirty reviews — and counts LOGIN's
    own `CHANGES_REQUESTED` reviews back from the newest, stopping at its own
    most recent `APPROVED` (requirement 8c). `approver_prior_refusal_bodies
    PR_URL LOGIN` prints the same login's `REQUEST_CHANGES` review bodies,
    oldest first, for the adjudication prompt. `approver_post_review PR_URL
    EVENT BODY TOKEN` POSTs the actual `APPROVE`/`REQUEST_CHANGES` review,
    `GH_TOKEN` set for that one invocation only, never exported — the one
    GitHub write this whole stage performs, and the only place in this
    codebase that mints a review under a non-owner identity. A refusal's own
    status and body land in `approver-post.err` (`_approver_err_log`, cycle_dir
    when the caller has one, `/tmp` otherwise) rather than `/dev/null`
    (agent-ops#945), the same discipline `lib/tech-debt-file.sh`'s own
    `_techdebt_err_log` already applies. This file also
    carries the stage itself (moved from `agent-cycle.sh`, #771):
    `run_approver_stage`, `approver_post_or_warn`, `approver_escalate`,
    `approver_escalation_retire` — requirement 8c's `cause: "land"`
    retirement, the read-back half of `approver_escalate`'s own dedup lookup
    (agent-ops#1215) — and
    `approver_stage_complexity`, the sole callers of the primitives above,
    composing them with `merge_autonomy_effective_level`
    (`lib/merge-autonomy.sh`), `create_escalation_issue` (`lib/enabler.sh`,
    component 2) and the ordinary `run_claude_stage` launch every other stage
    uses. Sourced, never executed, by `agent-cycle.sh`. Regression-tested in
    `test/approver.test.sh` against a stubbed `gh`, and the wiring those
    primitives hang off in `test/approver-wiring.test.sh`, which lifts
    `run_approver_stage`, `approver_post_or_warn` and `approver_stage_complexity`
    verbatim out of this file rather than restating their logic (acceptance
    check 8s). `approver_review_stale STATE COMMIT HEAD_SHA` (requirement 46,
    agent-ops#682) is a pure predicate: a standing `CHANGES_REQUESTED` whose
    `commit_id` no longer matches the pull request's head. `approver_newest_
    commit_authored_at PR_URL` reads the newest `authoredDate` among the pull
    request's own commits — one `gh pr view --json commits` call, unaffected
    by a rebase, which reuses each replayed commit's original author date and
    only stamps a fresh committer date. `approver_dismiss_review PR_URL
    REVIEW_ID BODY TOKEN` PUTs `.../reviews/{id}/dismissals` under the same
    `GH_TOKEN`-scoped-to-one-call discipline `approver_post_review` already
    holds. The sweep that drives those three — `_approver_restale_sweep_repo`,
    `_approver_restale_review`, `_approver_restale_dismiss` and
    `_approver_restale_escalate` — moved here from `agent-cycle.sh` with the
    stage it re-enters (#771), rather than to `lib/landing.sh` beside the
    landing-retry sweep it sat next to while both were inline; `run_standdown_
    checks` (`lib/standdown.sh`, component 2a) calls it in place. They compose
    the three primitives with `run_approver_stage` itself (reused, not
    duplicated, for the genuine re-review path), `create_escalation_issue`
    (component 2) and `merge_autonomy_effective_level`
    (`lib/merge-autonomy.sh`). Regression-tested in `test/approver.test.sh`
    (the three primitives) and `test/approver-restale-sweep.test.sh`, which
    lifts `_approver_restale_sweep_repo` and `_approver_restale_review`
    verbatim out of this file (acceptance check 46). Must pass `shellcheck`.
14d. `lib/merge-budget.sh` implementing requirement 2.3c: the
    `merge_budget_per_day` spend governor. `merge_budget_effective_cap
    CONFIG_JSON SLUG` resolves the cap on the same precedence
    `merge_autonomy_configured_level` uses. `merge_budget_window_status SLUG
    PR_LABEL MERGED_LOGIN [NOW_ISO]` prints `STATUS<TAB>COUNT`
    (`fleet_flag_fetch_status`'s own compound-return idiom) — `ok`,
    `unreadable` or `truncated` (at `GITHUB_PR_LIST_LIMIT`,
    `lib/github-limit.sh`'s `github_pr_list_truncated`) — from one `gh pr
    list --state merged --search "merged:>=<cutoff>"` read, scoped to the
    window by that qualifier (requirement 2.3c) and filtered in `jq` on
    `mergedAt`, `mergedBy.login` and `labels`.
    `merge_budget_oldest_waiting SLUG PR_LABEL` is a second,
    best-effort read of SLUG's open pull requests for a `hold` decision's
    backlog, from `gh pr list --state open --search "sort:created-asc
    draft:false"`: the search qualifiers ask GitHub to order the listing
    itself and to drop drafts from it before `--limit` cuts the page, so the
    first entry is the true oldest non-draft regardless of that page cap.
    Without the sort, past `GITHUB_PR_LIST_LIMIT` open labelled pull requests
    the unsorted page's own oldest is not necessarily the oldest waiting
    overall; without `draft:false`, a page whose oldest `GITHUB_PR_LIST_LIMIT`
    entries are all drafts leaves the local non-draft filter nothing to find
    and reports no backlog at all, even though an older non-draft is waiting
    just past the page. The local non-draft filter stays regardless, against
    the search index's own eventual consistency.
    `merge_budget_decide` composes both into one JSON object —
    `{decision, cap, count, anomaly, waiting_backlog}` — with no log events
    and no writes: `merge_budget_apply_decision DECISION_JSON SLUG
    STATE_REPO ESCALATION_LABEL ASSIGNEE` is the write side, calling
    `log_event` directly (assumed already defined by its one real caller,
    `agent-cycle.sh`, the same "sourced by every caller already" convention
    this file's own `fleet_flag_*`/`_toggle_eval` dependency on
    `lib/toggle.sh` uses) and, on an anomaly, `merge_budget_freeze_set` plus
    an inlined dedup-then-`gh issue create` against SLUG itself — this file
    cannot call `create_escalation_issue` (`lib/enabler.sh`), which every
    other escalation in this pipeline goes through: `lib/enabler.sh` is
    sourced by `agent-cycle.sh` alone, and this file is also sourced by
    `scripts/doctor.sh`, which never loads it. `merge_budget_freeze_
    state`/`_set`/`_clear` manage `fleet/merge-budget-freeze-<slug>.json`
    through `lib/toggle.sh`'s generic machinery, exactly as
    `lib/merge-autonomy.sh`'s kill-switch functions manage their own flag,
    but fail *open* on an unreachable state repo with no cache — see this
    file's own header for why, unlike the kill switch, that direction is
    correct here. `lib/merge-autonomy.sh`'s `merge_autonomy_effective_level`
    calls `merge_budget_freeze_state` directly (that file's own shellcheck
    source note), so this file must be sourced before any caller of that
    function runs, though not necessarily textually before
    `lib/merge-autonomy.sh` itself — bash resolves the call at run time, not
    at source time. Sourced by `agent-cycle.sh` and `scripts/doctor.sh`,
    after `lib/toggle.sh` and `lib/github-limit.sh`. Nothing calls
    `merge_budget_decide` or `merge_budget_apply_decision` from a behaviour-
    affecting path yet (requirement 2.3c) — regression-tested directly, in
    `test/merge-budget.test.sh`, against a stubbed `gh` covering the
    contents API, `pr list` and `issue list`/`create`; the freeze's
    integration with `merge_autonomy_effective_level` is
    `test/merge-autonomy.test.sh`'s own coverage instead, so the two files'
    tests do not restate each other. Must pass `shellcheck`.
14e. `lib/escalation-autonomy.sh` implementing the `escalation_autonomy`
    config key (D18, agent-ops#627, requirement 36b): the one function
    `escalation_autonomy_configured_level CONFIG_JSON SLUG` resolves a
    repository's configured level — its own `repos[]` override, else the
    top-level key, else `always-escalate` — the same precedence
    `merge_autonomy_configured_level` uses, and nothing else: there is no
    kill switch and no `_effective_level` layer here, because
    `adjudicate-first` never lets the Script act with less human oversight
    than `always-escalate` already does (this file's own header explains why
    that makes a safety override pointless). Sourced by `agent-cycle.sh`
    (`lib/enabler.sh`'s `maybe_run_enabler`, in its `escalate` verdict handling) and `scripts/doctor.sh`
    (the `enabler_model` pairing check) — plus
    `escalation_autonomy_adjudicated_before REPO ITEM`, requirement 36b's
    "bounded, not a loop" predicate, which reads the log on stdin the way
    `crash_loop_escalated_since` reads its own already-escalated fact and is
    true when an `enabler-adjudication` event for that item is already on it
    — and `enabler_decide_precedents REPO STANDING_FILE ESCALATION_LABEL`,
    requirement 36d's `precedents` builder, which prints the one JSON object
    the decide pass receives from the standing-decisions file, the
    repository's `pw::decision` records and its closed escalations, every
    member best-effort.
    Regression-tested in `test/escalation-autonomy.test.sh`, on the same terms
    `test/merge-autonomy.test.sh` covers its own precedence resolution; the
    guard's integration with `maybe_run_enabler` is
    `test/enabler-verdicts.test.sh`'s own coverage instead, so the two files'
    tests do not restate each other.
14f. `lib/github-app-token.sh` — the GitHub App installation-token minting
    mechanics component 14b (`lib/approver-token.sh`) originally implemented
    for itself alone, generalised (D25, agent-ops#607) once a second identity
    — the forge authoring App, component 14g — needed the identical dance
    against a different App/installation/key. Every function here is
    parameterised over app id, installation id, key path, cache directory,
    cache-file prefix, and the `curl`/`openssl` binaries (or their test
    stubs) rather than reading a fixed set of environment variables, so it
    carries no identity of its own: `github_app_token_credential_present`,
    `github_app_token_get`, `github_app_token_installation_permissions`,
    `github_app_token_installation_repositories` and
    `github_app_token_identity_login` are the same five calls component 14b
    exposed under its own `approver_token_*` names, minus the identity — a
    caller's own wrapper (component 14b or 14g) supplies that and delegates.
    The JWT-signing, the mint, the exit-status contract (`0`/`1`/`2`, "gate
    unreadable" on `1` and `2` alike), the stdin-not-argv handling of the
    Authorization header, and the tmpfs-only best-effort cache (mode 600,
    `mktemp`-then-rename, ownership/symlink-checked on read, keyed by
    installation id *and* by the caller's own cache-file prefix so two
    identities sharing one cache directory can never collide) are all exactly
    what component 14b already specified — nothing about the mechanics
    changed in the generalisation, only where they live. No fallback to any
    other credential exists anywhere in this file: it references only the
    identity values a caller passes in, so an absent App key can never
    silently reroute a call through some other credential — that decision
    belongs entirely to the caller (component 14h, never here).
    Sourced, never executed. Regression-tested indirectly, through
    `test/approver-token.test.sh` (component 14b's own identity, exercising
    every mechanic this file implements) and `test/author-token.test.sh`
    (component 14g's, including that the two identities' cache files never
    collide when pointed at the same directory). Must pass `shellcheck`.
14g. `lib/author-token.sh` — the forge authoring App's own installation-token
    minting wrapper (D25, agent-ops#607), the same thin-wrapper shape
    component 14b now has: `author_token_credential_present [OWNER]`,
    `author_token_get [NOW_EPOCH] [OWNER]` and `author_token_identity_login
    [NOW_EPOCH] [OWNER]` each delegate straight to component 14f, supplying
    this identity's own four environment variables — `PULLWRIGHT_AUTHOR_APP_ID`,
    `PULLWRIGHT_AUTHOR_INSTALLATION_ID`,
    `PULLWRIGHT_AUTHOR_INSTALLATION_IDS`, `PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH`
    — its own cache-file prefix (`pullwright-author-token`, keyed by
    installation id the same way component 14b's is, so two owners' tokens
    share neither a cache file nor each other) and its own override
    variables (`AUTHOR_TOKEN_CURL`, `AUTHOR_TOKEN_OPENSSL`,
    `AUTHOR_TOKEN_CACHE_DIR`), never the Approver's.
    **One App, several installations.** A GitHub App installation is per
    account, and this fleet's repositories span two of them
    (`Poetic-Poems`, `Pullwright`), so one installation id cannot back every
    authoring call. `PULLWRIGHT_AUTHOR_INSTALLATION_IDS` is a JSON object
    mapping owner to installation id (`{"Pullwright": 12345678,
    "Poetic-Poems": 87654321}`) and `author_token_installation_for_owner
    OWNER` resolves it by the owner half of a slug, case-insensitively,
    falling back to the scalar `PULLWRIGHT_AUTHOR_INSTALLATION_ID` for an
    owner the map does not name — the identical shape, and identical
    malformed-map and malformed-value fall-throughs, component 14b already
    carries for the Approver (agent-ops#913). It differs from component 14b
    in exactly one place: an **empty owner** resolves to the scalar default
    rather than to nothing, because this identity's busiest caller
    (component 22c's `gh_shim_resolve_token`, which runs on every `gh` call
    and every `git` credential fill) legitimately cannot name an owner for
    some invocations, and the scalar is the operator's own declared answer
    to that. `author_token_credential_present` with no owner, and
    `author_token_identity_login` with none, resolve through
    `author_token_any_installation_id` instead — the scalar if set, else the
    first usable map entry by key — so a fleet carrying only the map still
    reads as configured and can still be asked which login it authors as
    (`GET /app` is identical across every installation of one App). A mint
    never resolves that way: a token minted against an arbitrary
    installation is the silent wrong answer the map exists to retire, so
    `author_token_get` with an owner nothing names returns the same gate
    unreadable (exit 2) every other absent piece of this identity produces. This is the identity
    every authoring act — cloning a target repository, pushing a branch,
    opening or commenting on a pull request or issue — runs under once
    configured (component 14h decides when), in place of the owner's own
    `GH_TOKEN`. Never the Approver's own App: a single identity able to both
    author and approve its own work would recreate the self-approval D18
    already exists to retire, which is why this is a *second* App rather
    than a second installation of the first.
    Unlike component 14b, there is no `config.json` declaration to reconcile
    this identity's App id against — nothing in `config.json` gates on
    knowing it ahead of time the way `approver_app_id` gates
    `merge_autonomy` (requirement 2.3b), the same reason `GH_TOKEN` itself
    has no `config.json` key. `scripts/doctor.sh` (component 14) reports this
    identity's presence, key readability, and — with one live mint attempt —
    validity, but never fails over its absence: landing with the values
    unset is the expected state until an owner provisions the App (D25's own
    text on why this cannot be done by the pipeline itself).
    Sourced, never executed. Sourced by `agent-cycle.sh`, by
    `lib/gh-shim.sh` (component 22c, which mints through it on every call),
    and by `deploy/docker/entrypoint.sh` — the last of these purely for
    `author_token_credential_present`, which is what decides whether the
    entrypoint stashes the node's ambient PAT into `PW_GH_DEGRADE_TOKEN` and
    leaves `GH_TOKEN` empty for the seam to resolve through; it mints nothing
    itself.
    Regression-tested in `test/author-token.test.sh`, on the same terms
    `test/approver-token.test.sh` covers component 14b's own identity — the
    success path, the cache and its expiry/ownership/tmpfs guarantees, every
    missing-credential shape, a mint refused or unreachable — plus the
    cross-identity cache-isolation case component 14b's own tests do not
    need, and the per-owner resolution itself: which installation each owner
    resolves to (map, case-insensitively; scalar fallback; nothing at all),
    every malformed-map and malformed-value fall-through, the no-owner
    contract of each of the five functions, and that two owners' minted
    tokens land in two cache files and are never served for each other.
    Must pass `shellcheck`.
14h. `lib/forge-auth.sh` — which identity a cycle authors as (D25,
    agent-ops#607), and the name of the on-demand credential seam's
    degrade-path variable (D25 as amended, agent-ops#1021, component 22c). No
    single point in a cycle's process resolves a credential once for the
    process's whole life any more: a forge authoring App installation token
    carries GitHub's ~1 h lifetime, and a cycle routinely outlives that
    (`lib/stage-budget.sh`'s own priors put the Implementer alone at 150
    minutes), so the credential is resolved on demand, per call, by
    component 22c's `gh` transport shim (every `gh` invocation) and, for
    plain `git`, the same shim reached through `git`'s own credential helper
    (`!gh auth git-credential`, `deploy/docker/entrypoint.sh`, component 7).
    Both mint only when `GH_TOKEN` is already empty in their own
    environment — "explicit wins; empty resolves" — so a human's own exported
    token, or `lib/approver.sh`'s own
    `GH_TOKEN="$(approver_token_get)" gh …`, always passes through untouched;
    the seam must never re-identify the Approver's own calls as the author,
    which is the point of D18's two-identity separation. `PW_GH_DEGRADE_TOKEN`
    is this file's own contribution to that seam: the name
    `deploy/docker/entrypoint.sh` stashes the node's ambient PAT under, when
    the forge authoring App is configured, before it leaves `GH_TOKEN` itself
    empty for every process it execs — the seam's fallback whenever no App is
    configured, or a mint attempt fails, which is the degrade path
    agent-ops#607 requires: an unset, unreadable or momentarily unreachable
    App identity must never brick a node that has always worked fine on its
    PAT alone, and a token that ages out mid-cycle must never present a stale
    one to the call that needed it.
    `forge_auth_effective_gh_token [NOW_EPOCH]` no longer sets anything a
    cycle authenticates with — it is diagnostic only, called once from
    `lib/standdown.sh`'s `run_standdown_checks`, purely to log which path a
    call made right now would take: print `SOURCE<TAB>TOKEN` on stdout (never
    a bare token — a caller must read the two apart with `IFS=$'\t' read -r
    source token < <(...)`, the same shape `lib/github-limit.sh`'s
    `github_auth_probe` already uses, and for the same reason a plain
    `x="$(...)"` command substitution cannot hand a side-effect global back
    to its caller through a subshell boundary). `SOURCE` is `forge-app` when
    component 14g's `author_token_credential_present` is true and a mint (or
    a cache hit) actually succeeds, `gh-token-degraded` when the credential
    is configured but a mint attempt just failed, and `gh-token` when no
    forge authoring App is configured at all — the last two both resolve
    `TOKEN` to whatever `PW_GH_DEGRADE_TOKEN`, or (absent that) the node's own
    ambient `GH_TOKEN`, already held, which may itself be empty (the
    pre-existing "no credential" case this file does not change). **Never
    fails.** It names no repository owner, so the mint it reports on is
    against the *scalar default* installation — the same one component 22c
    uses for any call it cannot attribute — which means a fleet carrying only
    component 14g's per-owner map and no scalar default reads
    `gh-token-degraded` here, correctly: an owner-less call on such a node
    does take the fallback, and the log line says which of the two causes it
    was.
    `lib/standdown.sh` logs the `forge-auth` event naming `SOURCE`, and a
    `warning` once per cycle for a `gh-token-degraded` resolution, so
    `scripts/publish-dashboard.sh` and any operator reading the log can see
    which identity a cycle would author under; 2.0b's credential-fault probe
    two steps later validates the identity the cycle actually uses, because
    its own `gh` call goes through the seam too.
    Sourced, never executed; requires component 14g already sourced.
    Regression-tested in `test/forge-auth.test.sh`: the plain-`GH_TOKEN` path
    with and without one set, the App path (fresh mint and a cached reuse),
    and the degraded path on both a refused mint and an unreachable API,
    each asserting both `TOKEN` and `SOURCE`. Must pass `shellcheck`.
15. `lib/labels.sh` implementing requirement 6a: `labels_catalogue` (what a
    repository in a given role — `target`, `review`, `escalation` — needs, as
    `name`/`colour`/`description`, with the names taken from the config as
    `config_defaults` merges it — so a label name absent from `config.json`
    is the schema's own default rather than a literal repeated here — and an
    empty name yielding nothing) — except role `review`'s own pr_label, which
    (requirement 342) is resolved per repository rather than read once from
    the config, so `labels_catalogue` takes it as an explicit optional
    argument the caller (already holding that repository's own resolved
    value) passes through — and `labels_ensure` (create what is absent in
    one repository, reporting `created` or `failed` per label and nothing at
    all for those already there, so the steady state is silent). Also
    implementing requirement 6c: `labels_reserved_names` (the complete set a
    stage-minted label may never claim), `labels_validate_name` (one
    candidate against that set plus length/comma/emptiness), and
    `labels_mint` (create and apply a stage's own suggested labels onto one
    issue or pull request, capped and reporting `created`/`applied`/
    `refused`) — called from `agent-cycle.sh`'s Implementer handoff and
    `lib/refinement.sh`'s `_refiner_apply_labels`. `LABELS_GH`
    overrides the `gh` binary for tests. Sourced by `agent-cycle.sh`,
    `review-cycle.sh` and `scripts/doctor.sh`; component 3h's
    `_refiner_apply_labels` calls `labels_mint`/`labels_reserved_names`
    without sourcing this file itself, so it resolves them only in a process
    that has sourced both — `agent-cycle.sh`, which sources both files
    (`agent-cycle.sh:184` and `:211`) among the libraries it loads into one
    process, is the only caller that reaches it, and
    `test/refiner-verdicts.test.sh` sources both files itself for the same
    reason. Regression-tested against a stubbed `gh` that records every
    invocation (`test/labels.test.sh`, `test/refiner-verdicts.test.sh`,
    `test/implementer-labels-wiring.test.sh`); must pass `shellcheck`.
16. `scripts/render-config-table.sh` implementing requirement 1b's generated-
    table property: renders the Markdown table body rows of the three prose
    configuration tables (this document's, `docs/spec/review.md`'s,
    and the two in `docs/reference/configuration.md`) from `config.schema.json`'s leaf keys, in the
    schema's own property order — `schedule` and `repository_review` flatten one
    level into dotted keys (`schedule.review_hour`,
    `repository_review.lock_stale_after`) in the parent's position, and
    `repository_review.defaults` flattens one level further still
    (`repository_review.defaults.model`); every other object- or array-valued key
    (`repos`, `repository_review.repos`, `prompt_overrides`) renders as a single
    row — including `project_review` itself (agent-ops#592, D7): the
    deprecated alias shares `repository_review`'s shape by `$ref` rather than
    carrying its own `properties`, so it is never flattened, and renders as
    one opaque summary row from its own `description`, the same way
    `escalation_webhook_url` does for `notify_webhook_url`. Each key's value
    cell is,
    in order, its `x-docs.value` verbatim — one string for both documents,
    or an object keyed `readme`/`spec` for the keys whose two tables say
    different things there, the spec's `Value` column carrying the unit
    (`4 h`, `15 min`) the README's `Default` column leaves to the key's name
    — else its schema `default`, a non-empty string bare in backticks and
    anything else as compact JSON in backticks, else `*(required)*`; its
    notes cell is
    `x-docs.readme` for the README's two tables and `x-docs.spec` for the two
    specs' — a string, or an array of blocks (a string is a paragraph,
    `{"list": [...]}` an unordered list, `{"code": ..., "lang": ...}` a
    fenced example, `lang` optional) — falling back to `description` when the
    key carries no `x-docs` for that audience. A cell holds one line, so every
    block flattens into it: a paragraph verbatim, a list's items joined `, `,
    code's newlines turned to spaces and wrapped in a backtick span whose
    delimiter backs off to the code's own content — the widest run of
    consecutive backticks already in the code, plus one, the same rule
    CommonMark itself uses for nesting a code span inside a code span — with
    a leading and trailing space added if the code starts or ends with a
    backtick, each block joined to the next by a single space — the same
    join a plain array of paragraph strings always got, and what a single
    string (a one-block array) already renders as unchanged.
    Rewrites four marked regions (`<!-- config-table:start id=main -->` /
    `id=review` … `<!-- config-table:end -->`) in place with no arguments,
    reading the regions from `lib/markdown-scan.sh`'s `CONFIG_TABLE_REGIONS`
    and matching their markers by the same library's patterns, the list and
    grammar component 24b reads to leave these regions out of the size
    budget. A
    start marker's `id=<id>` token may be followed by further prose before
    the closing `-->` — AGENTS.md's "Generated regions" note and the
    markers themselves carry the same generated-from-schema contract inline
    (#356), so an editor who reaches a row directly, without having read
    CLAUDE.md first, still sees it — and matching it is therefore a prefix
    match on `id=<id>`, not exact-line equality: any such trailing prose is
    accepted and reproduced untouched rather than regenerated. The end
    markers (`config-table:end`, `config-table:notes-end`) carry no id and
    no prose, and stay matched exactly.
    Each region's first two lines, immediately after the start marker, are a
    header row and a `|---|---|---|` delimiter row, carried verbatim rather
    than generated — passed through untouched on every rewrite, which is
    what lets the README say `Default` where the specs say `Value` without
    this script knowing either; the generated rows follow directly beneath
    them, with no line in between. Both modes refuse a region whose first two
    lines are not a header row and a delimiter row, since a bare marker
    comment between the delimiter row and the first data row has no pipe in
    it, so it does not look like a table row and GitHub's Markdown parser
    ends the table right there — the row still looks right in a diff while
    the rendered page shows an empty table body followed by literal piped
    text.
    Each region's Notes cell is additionally capped at 500 characters
    (`NOTES_CAP`): a cell at or under the cap renders the note verbatim, `|`
    escaped, as before; a longer one renders a prefix — at most 480
    characters, tokenised into Markdown atoms (a code span, a link, an
    emphasis run, a whitespace run or a plain word, matched in that order so
    a code span is claimed before its contents are mistaken for a link's or
    an emphasis run's own syntax; a double-backtick-delimited code span is
    tried before a single-backtick one, mirroring CommonMark's own
    preference for the longest matching delimiter run, so a span whose
    content itself contains a literal backtick (`` ``…`…`` ``) is claimed
    whole rather than having its opening `` `` `` read as an empty
    single-backtick span) and cut at the last atom boundary that fits, so a
    cut never lands inside one of those constructs — followed by
    `...[continued below](#extended-notes-<slug>)`. The note's full text is
    repeated, unescaped, under a generated `Extended notes: `<key>`` heading
    in that document's own `config-table:notes id=<region>` … `notes-end`
    region, one per `config-table:start` region and required even where
    nothing in it currently overflows; a region with nothing to say renders
    empty. Unlike the cell, this subsection is ordinary document prose, so
    each block renders as real block Markdown instead of flattening — a
    paragraph string on its own, blank-line-separated from its neighbours; a
    list as real `- ` items; code as a real fenced ```` ``` ```` block — one
    blank line between each pair of blocks.
    The heading's level is derived, not hard-coded — the nearest ATX
    heading strictly above the notes-start marker, plus one, clamped at 6 —
    and its own placement, unlike the table region's, is up to whoever wrote
    the surrounding prose: the script rewrites whatever sits between the
    markers and never moves them. The anchor is GitHub's own heading slug
    (lower-cased, stripped to `[a-z0-9_-]` and space, spaces to `-`); two
    headings in one document slugging the same, or a notes marker with no
    heading above it, are both hard failures rather than silently
    mis-rendered output.
    `--check` renders each region — table and notes alike — to a temporary
    file instead and exits non-zero, naming the file, the region and the
    first differing key, the moment any region is stale — what
    `.github/workflows/config-table.yml` runs on every pull request, on push
    to `main`, and on `merge_group`, so the `config-table` context reports
    inside the merge queue rather than leaving every queue entry to wait out
    the ruleset's `check_response_timeout_minutes`.
    Regression-tested end to end, against the shipped script copied into a
    scratch fixture repository rather than a reimplementation of its logic,
    in `test/render-config-table.test.sh`; must pass `shellcheck`.
17. `scripts/check-closing-keyword.sh` and `.github/workflows/closing-keyword.yml`
    implementing requirement 25a: given a pull request body, extracts every
    `<!-- agent-ops:closes-issue item=N -->` marker (requirement 23b) and
    exits non-zero, naming the missing number, for any that has no matching
    GitHub closing keyword (`close(s|d)`, `fix(es|ed)`, `resolve(s|d)`,
    case-insensitive, a word of its own, immediately followed by the issue
    reference in any of the three spellings GitHub's own linked-issue syntax
    honours — `#N`, `GH-N`, or `owner/repo#N`, the last for any `owner/repo`
    (issue #1460)) in the
    same body — "unclosed #N" and "discloses #N" contain a keyword and close
    nothing, exactly as they do to GitHub's own parser, in every
    spelling. A body
    with no marker passes trivially. The workflow runs on every
    `pull_request` event, fetching the pull request's current body at run
    time (`gh pr view --json body`, keyed on the event's own immutable PR
    number) rather than reading `github.event.pull_request.body`'s snapshot
    of the triggering event, so a rerun of a stale run — no new push —
    evaluates the body as it stands now rather than replaying whatever it
    said when the event fired (agent-ops#1991). It assigns the fetched body
    to a shell variable rather than interpolating it into the step directly,
    so an attacker-controlled body from a fork PR still cannot inject shell.

    Given a repo slug and this pull request's own number as two further,
    optional arguments (a caller that omits either — every caller that
    predates issue #1363 — gets exactly the behaviour above and nothing
    more), the same script also enforces requirement 25's tech-debt
    record-file flip: for each issue number the marker/keyword resolution
    above yields, **or that the PR body cites via a bare closing keyword
    alone with no marker and no `agent/<N>` head branch** (issue #1438 — a
    human's PR, or an interactive agent's, that closes a tech-debt issue with
    a plain `Fixes #N` and nothing else this script's marker/branch
    resolution would otherwise notice), it fetches that issue (`gh issue
    view … --json body,labels`). A number is harvested from a keyword only
    under the same word-of-its-own rule the marker half applies — the one
    shared pattern both halves match on — so "discloses #N" and "unfixed #N"
    drag nothing into this loop either, in any spelling: a lookalike that
    closes no issue must not demand a record flip of a pull request that
    closes none. The issue *reference* is where the two halves differ (issue
    #1460). Both read `#N` and `GH-N`; the repo-qualified `owner/repo#N` is
    harvested here only when its `owner/repo` case-insensitively equals the
    repo slug passed in, so `Fixes otherowner/otherrepo#5` contributes
    nothing — it closes someone else's #5, and demanding this repository's
    own record flip for it would fail a pull request over an issue it never
    closes. The marker half applies no such filter, deliberately, because it
    runs where no slug was passed at all (the bullet above; issue #1468
    tracks what that leaves open). The number is read from the end of each
    match rather than its first digit run, a repository name being free to
    carry digits of its own. This harvest reads from a copy of the body with
    every fenced code block, inline code span, and line beginning with `>`
    stripped out first — GitHub's own parser creates no closing reference
    inside any of the three, so a keyword written there (documenting the
    convention, or quoting someone else's PR body — PR #1396's `` `Closes
    #1083` `` discussing why that issue is deliberately left open, the
    concrete case) closes nothing and must not demand a record flip GitHub
    itself never asked for (issue #1463). The marker/keyword half above reads
    the raw body throughout, never this stripped copy, so a defect in the
    stripping can only affect this half. Where the issue is `pw::type:tech-debt`-labelled
    and its body's last non-blank line reads "Filed as `tech-debt/<id>.md`,
    <date>." (left by `scripts/migrate-tech-debt-register.sh` or an
    earlier direct filing), it reads this pull request's own changed-files
    listing (`gh api repos/<slug>/pulls/<n>/files`) and exits non-zero,
    naming the issue and the record file, unless that file's diff adds a
    line setting its `status:` to a terminal state — `resolved` or
    `not-debt` (issue #1437). This is the CI-side check for the miss PR
    #1355's first round made by hand — issue closed, `tech-debt/TD-PPagop-
    26082412.md` left at `status: open` until a later round. `<id>` in that
    line is matched against the register's own ID charset —
    `[A-Za-z0-9._-]+`, the grammar `docs/TECH-DEBT-REGISTER.md` in
    `Poetic-Poems/poetic` defines and every record in `tech-debt/`
    satisfies — rather than any run of non-backticks, so that a path read
    out of an issue body cannot carry a character the register's own grammar
    never produces into anything downstream that interpolates it (issue
    #1764). A path outside that charset matches nothing and demands nothing,
    the same as an issue with no "Filed as" line at all. This is the live
    guard on a real interpolation, not narrowing ahead of the need: besides
    the `jq --arg` binding and the three messages naming it, the captured
    path is interpolated unescaped into the contents-API URL below, where an
    injected `?` or `&` would alter the query string. Before either failure
    fires, it reads the named record from the base branch (`gh api
    repos/<slug>/pulls/<n>` for `.base.ref`, `.base.sha` only as a fallback,
    then `gh api repos/<slug>/contents/<path>?ref=<that>`, whose
    newline-wrapped base64 it strips before decoding) and passes where that
    copy already carries a terminal `status:` — an earlier, unrelated pull
    request having flipped it, leaving no truthful `+status:` line to add
    and an append-only register that forbids inventing one (issue #1493).
    That `status:` is read from the record's leading `---`-delimited
    frontmatter block alone, so a still-`open` record whose body quotes
    another record's `status:
    resolved` line at column 0 is not read as terminal (issue #1764). Either
    `gh` call that fails outright (the token, a transient outage) warns rather
    than failing the check, the issue read and the changed-files read alike:
    the marker/keyword half above never depended on the network, and this
    half must not fail a pull request over GitHub's own availability — a
    changed-files listing that could not be fetched is indistinguishable
    from an empty one, so the failed call is read as "could not ask" rather
    than as a pull request that touched nothing. The base-branch read is the
    one exception, and in the safe direction: it can only excuse a pull
    request, so a failed read falls through to the ordinary failure rather
    than warning and skipping. The workflow passes
    `github.repository` and
    `github.event.pull_request.number` alongside the body and head branch,
    and carries `issues: read` and `pull-requests: read` (`GH_TOKEN:
    ${{ github.token }}` for `gh` itself) besides the `contents: read` the
    checkout already needed — safe on a fork PR under the same guarantee as
    every other permission here, since GitHub forces a `pull_request` run
    from a fork to a read-only token regardless of what is requested.
    `lib/closing-keyword-gate.sh` (17a below) does not pass these two
    further arguments, so `poetic` and `poetic-fiddle` — which carry no
    `tech-debt/` register of their own — get the marker/keyword half only,
    unchanged. Unit-tested (`test/check-closing-keyword.test.sh`); must pass
    `shellcheck`.
17a. `lib/closing-keyword-gate.sh` implementing requirement 25a's other
    layer: given a pull request URL, `closing_keyword_gate` reads its
    current body and head branch with `gh pr view --json body,headRefName`
    and runs both through `scripts/check-closing-keyword.sh` unmodified,
    printing `clean`, `dirty<TAB>reason` or `unknown<TAB>reason` — the same
    shape `lib/review-gate.sh`'s `review_gate_verdict` reports, so a caller
    folds both into one handoff gate. The reason is always a single line —
    the checker emits one `::error::`-prefixed line per fault and an
    `agent/<N>` branch missing its marker earns two, so they are flattened
    into one and the workflow-command prefix stripped, every caller parsing
    the verdict with a single `read` that would otherwise keep only the
    first. `dirty` is reserved for a fault in the pull request itself;
    "could not ask" — `gh pr view` failing, answering without a head branch,
    or the checker exiting 126 or higher — is `unknown`, never a crash and
    never a fault attributed to the pull request. An empty URL is the one
    exception, `dirty` because it is a bug in the caller rather than a
    degraded node. `agent-cycle.sh` calls it at the two points it already
    knows a pull request's body and head branch: right after the
    Implementer's PR is raised (a dirty verdict there becomes the
    `## Script findings` section of the Reviewer's prompt, not a refusal) and
    again at the Reviewer's own `ready` handoff, which is the enforcing one
    (handing back through `log_reviewer_handback` on a dirty verdict, the
    same shape a failing required check or a new security alert already
    uses there). `CLOSING_KEYWORD_GATE_GH` stubs `gh` for tests, and
    `CLOSING_KEYWORD_GATE_CHECK` the checker's path. Unit-tested
    (`test/closing-keyword-gate.test.sh`); must pass `shellcheck`.
17b. `scripts/check-changelog-section.sh` and
    `.github/workflows/changelog-section.yml` implementing requirement 25c:
    given a pull request's description and title, decides from the title
    whether a `## Changelog` section is owed (`feat`, `fix`, `perf`, or any
    type carrying `!`, on `.githooks/check-commit-format.sh`'s own pattern)
    and checks any section present against the grammar requirement 25c
    states — outside fenced code and HTML comments, the six categories spelt
    exactly, at least one bullet each, no duplicate category, no loose
    prose, or the single line `None.` — writing one `::error::` line per
    fault to stderr and exiting 1, or exiting 0 with no output when the
    description is in order (a heading with no content but blank lines and
    comments counts as absent, so the template's untouched section is never
    itself a fault); exit 2 is a usage error. `\r` is stripped
    before parsing, since a description saved through GitHub's editor
    arrives CRLF. The workflow runs on every `pull_request` event including
    `edited`, passes the title and the body through `env:`, and reports
    skipped on `merge_group`. `lib/changelog-section-gate.sh` (17d below)
    calls this script unmodified against a pull request's current body and
    title, re-read with `gh pr view`, for the two target repositories this
    workflow does not cover. Both this script and component 17c below read the
    `## Changelog` grammar off `lib/changelog-grammar.sh`'s
    `changelog_grammar_walk` rather than each parsing it independently — one
    fence/HTML-comment/heading state machine, and one None/category/bullet
    classification, driving both a validator and an extractor from the same
    tab-separated event stream. Unit-tested
    (`test/check-changelog-section.test.sh`); must pass `shellcheck`.
17c. `scripts/assemble-changelog.sh` implementing requirement 25d: given
    `[--check] [--since <ref>] [<path>]`, resolves the commit range from
    `<path>`'s own `<!-- changelog:assembled-through sha=… -->` marker (or
    `--since`, required when the file carries neither), walks each
    `git log --first-parent --reverse` candidate's body through
    `changelog_grammar_walk`, and stages its bullets locally — merged into
    the running per-category result only once that commit's one section is
    confirmed fault-free, so a malformed body (a real, merged example
    predating the `changelog-section` check's own ruleset wiring is
    agent-ops#1819) contributes nothing rather than a truncated bullet.
    Renders `## [Unreleased]` (created below the preamble if absent) with
    one `### <Category>` per category present in Keep a Changelog order,
    newest commit first, each bullet suffixed ` (#N)` from the squash
    title's own trailing `(#N)` unless already cited; merges into an
    existing section by splicing into its lines rather than re-rendering it
    from the grammar, so every existing bullet and every released section is
    left byte-for-byte unchanged even where the file carries what the
    description grammar would fault. `--check` computes what a
    normal run would write and diffs it against the file's current content,
    exiting non-zero without writing when they differ. Requires real commit
    history reachable from `HEAD` (a blobless clone is enough; a shallow one
    is not — a consumer's CI needs `fetch-depth: 0`); a range it cannot read
    is an error that writes nothing, never an empty range that would carry
    the marker past unread commits. Canonical here (D20)
    and distributed to `poetic`/`poetic-fiddle` via the `.agent` sync
    manifests, each repository's own adoption issue adding the manifest
    line. Unit-tested against a fixture git repository of squash-shaped
    commits (`test/assemble-changelog.test.sh`); must pass `shellcheck`.
17d. `lib/changelog-section-gate.sh` implementing requirement 25c's other
    layer, on `lib/closing-keyword-gate.sh`'s own pattern (17a above,
    agent-ops#1808): given a pull request URL, `changelog_section_gate` reads
    its current body and title with `gh pr view --json body,title` and runs
    both through `scripts/check-changelog-section.sh` unmodified, printing
    `clean`, `dirty<TAB>reason` or `unknown<TAB>reason` — the same shape
    `closing_keyword_gate` reports, so a caller folds both into one handoff
    gate. The reason is always a single line, flattened and stripped of the
    checker's `::error::` workflow-command prefix the same way 17a's own
    reason is. `dirty` is reserved for a fault in the pull request itself;
    "could not ask" — `gh pr view` failing, answering without a title, or the
    checker exiting 126 or higher — is `unknown`, never a crash and never a
    fault attributed to the pull request. An empty title is the signal an
    unreadable answer leaves here, since every real pull request carries one
    and the checker itself reads an empty title as "owes nothing" — the same
    hazard 17a's own empty-head-branch check guards against. An empty URL is
    the one exception, `dirty` because it is a bug in the caller rather than
    a degraded node. `agent-cycle.sh` calls it at the same two points it
    calls `closing_keyword_gate`: right after the Implementer's PR is raised
    (a dirty verdict there becomes a second `## Script findings` entry
    beside a closing-keyword one where both fire, not a refusal) and again
    inside `lib/handoff.sh`'s `handoff_complete_review`, right after the
    closing-keyword gate, which is the enforcing call (handing back through
    `log_reviewer_handback` on a dirty verdict, the same shape a dirty
    closing-keyword verdict already uses there). `CHANGELOG_SECTION_GATE_GH`
    stubs `gh` for tests, and `CHANGELOG_SECTION_GATE_CHECK` the checker's
    path. Unit-tested (`test/changelog-section-gate.test.sh`); must pass
    `shellcheck`.
