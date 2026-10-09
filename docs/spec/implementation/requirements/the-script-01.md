## Requirements

### The Script (`agent-cycle.sh`)

1. **Lock.** On start, acquire a lock file in `state_dir` recording PID,
   start time, and the writer's hostname (`host` — on a containerised node
   the container, which is the PID namespace the recorded PID is meaningful
   in; the watchtower pre-update hook reads it, see the node stack section).
   A pid is only meaningful in the PID namespace that minted it, so a lock
   whose recorded `host` differs from this run's own is judged by host, not
   pid: it was written by a container that is gone by construction, taken
   over immediately — no liveness check, no process-group kill — logging the
   same `warning`. Only a lock whose `host` matches (or carries none, from
   before this stamp existed) is judged by liveness: if held by a live
   process younger than `lock_stale_after`, log `cycle-skipped`, remove the
   record directory this tick made (its only content is the fleet-log
   snapshot taken before the lock, and a directory that ran no stage would
   otherwise take one of `state_local_streams_retained`'s slots from a cycle
   that did — requirement 2.5) and exit 0;
   if the holder is dead or older than `lock_stale_after`, end its whole
   process group if still alive — TERM first, then a polled grace of up to
   20 seconds for the process to exit, then KILL — log a `warning` (a stale
   cycle indicates a fault — it should not occur in normal operation), take
   the lock, and continue. The grace exists for requirement 9c: TERM is what
   invites the doomed cycle's own signal handler to write its
   `attempt-failed`, release its claim and log its `cycle-end`, and it is
   sized to that handler's worst case (one process-group kill, one log
   append, one 8-second-bounded claim release). Polled rather than slept, so
   a cycle that records and exits in one second costs one second.
1a. **Model id resolution, against a configured set of providers (D12,
   issue #2131).** `providers` states which providers beyond the implicit
   `anthropic` a model key may qualify with — keyed by provider name, each
   entry naming a `substrate` (the adapter that launches it; `claude-code`
   is the only one this image has, and accepts the `anthropic` provider
   only — D29, issue #2198: Claude Code pointed at another vendor's own
   endpoint is not a thing this codebase does, so any other provider naming
   `claude-code` is a config error, named below) and, optionally, a
   `credential_env` (defaulting by substrate — `ANTHROPIC_API_KEY` for
   `claude-code`).
   `lib/model-id.sh`'s `providers_load` loads it into `PROVIDER_SUBSTRATE`
   (and `PROVIDER_CREDENTIAL_ENV`) once, at startup, before any model key is
   resolved — synthesizing `anthropic` with substrate `claude-code` whether
   or not `providers` names it explicitly, so no existing `config.json`
   needs to change. Every model key read from config —
   `coordinator_model`, `implementer_model_default`,
   `implementer_model_trivial`, `reviewer_model_default`,
   `reviewer_model_complex`, `enabler_model`, `enabler_model_critical`,
   `refiner_model`, `approver_model_default`, `approver_model_complex`,
   `approver_model_critical` — is resolved immediately after
   being read, before the lock and before any stage may launch: a bare id
   (`claude-sonnet-5`) means `anthropic/claude-sonnet-5`; a qualified id has
   the qualifier stripped to the same bare id once the named provider is
   accepted; a qualifier naming a provider absent from `providers` is a
   fail-fast config error naming the offending key, not a value ever passed
   to `claude --model`, and so is one naming a provider whose configured
   `substrate` has no adapter in this codebase — named alongside the key, so
   a `grok-4.3` qualifier can never reach `claude --model` because the
   schema admitted it. An empty value (the "disable this stage" convention
   `reviewer_model_complex` and `enabler_model` both use) passes through
   unresolved. `review-cycle.sh` applies the same resolution to every
   repository's own resolved `repository_review.defaults.model` (or its own
   override in `repository_review.repos`, requirement 342)
   (`docs/spec/review.md`). Both scripts share one implementation,
   `lib/model-id.sh`'s `resolve_model_id_into` (and its siblings
   `resolve_model_id`, the same resolution as a value on stdout, and
   `resolve_model_provider`, which names the provider a key resolves to
   rather than the bare id `claude --model` wants), so the two pipelines can
   never drift on what counts as a supported provider. **Resolution also
   records which provider each bare id came from, in `MODEL_PROVIDER`, and
   that is why every stage model is resolved through the assigning
   `resolve_model_id_into VAR KEY VALUE` rather than the printing
   `resolve_model_id`** (issue #2133): the recording is a side effect in the
   caller's own shell, and a caller writing
   `VAR="$(resolve_model_id KEY VALUE)"` runs the whole resolution in a
   subshell, so the bare id returns and the recording is discarded with it.
   Requirement 4d's substrate dispatch and requirement 33a's `provider` field
   are the two readers of that map, and both fall back to
   `anthropic`/`claude-code` rather than failing when it holds nothing — so
   the printing form at a stage-model site costs no error, only a stage
   silently launching on the wrong provider's adapter. The printing form is
   for a caller that genuinely wants the string alone: `scripts/doctor.sh`'s
   configuration report, `scripts/publish-dashboard.sh`'s tier lookups, and
   `resolve_model_qualified`, which builds the `<provider>/<bare-id>` id
   requirement 1c's tier ladder is keyed by. `providers`'s own
   entries are each named by the installation, which is outside what the
   declarative schema (requirement 1b) can shape-validate on its own — an
   eighth guard alongside requirement 1b's other seven,
   `lib/config-schema.sh`'s `config_provider_errors`, rejects an unknown key
   inside an entry, a missing or unsupported `substrate`, a `substrate` of
   `claude-code` named by any provider but `anthropic`, or an explicit
   empty `credential_env`, shared the same way between `agent-cycle.sh`,
   `review-cycle.sh` and `scripts/doctor.sh`. Launching a stage on any
   substrate but `claude-code` is out of this requirement's scope (#2133,
   #2134), and so, until one of those lands, is a second provider ever
   resolving at all: `claude-code` is the only adapter this image has, and
   it is `anthropic`'s alone, so no other provider configured today clears
   `config_provider_errors`.

   A provider's entry may also carry `lanes` (the credit mix, D30, issue
   #2240): an object naming at most the two credential paths `api` and
   `subscription`, each carrying `weight` (an integer >= 0; a lane's share of
   its provider's launches relative to its sibling, and so of its spend in
   expectation — #2241 is the launcher that reads it; this requirement only
   configures and validates it), `enabled` (a boolean, or unset meaning "open
   only when it is the one the CLI would use unaided" — the key when
   present, else the login, which is every node's behaviour before this
   configuration key existed), and the thresholds `scripts/doctor.sh`'s
   "Claude" section reads and #2243's closing lever will act on:
   `spend_cap_usd` (0 means none) with `spend_window_hours`, and
   `balance_usd`, `balance_as_of` and `balance_floor_usd`. Absent, or present
   without `lanes`, a provider's two lanes resolve to `api` weight 1,
   `subscription` weight 0, neither enabled and no thresholds — D4's
   precedence exactly as every node already runs it, reproduced rather than
   newly configured. `config_provider_errors` validates `lanes` the same way
   it validates the rest of a provider's entry, and for the same reason
   (each provider's own key, and now each lane nested inside it, is a name
   the installation chooses, outside the declarative schema's reach):
   an unknown lane name, a lane value that is not an object, an unknown key
   inside a lane, a `weight` that is not an integer >= 0, an `enabled` that
   is not a boolean, a `spend_cap_usd`/`balance_usd`/`balance_floor_usd` that
   is not a number or a `spend_window_hours` that is not a positive integer,
   a `balance_as_of` that is not a string, a `balance_floor_usd` set without
   both `balance_usd` and `balance_as_of`, a `spend_cap_usd` or
   `balance_floor_usd` set on a lane `lib/model-id.sh`'s
   `PROVIDER_LANE_NO_MEASURE` names as having no cost measure at all (no
   substrate-reported cost and no statement, #2248 — today: `xai/subscription`
   alone, #2246), and both lanes resolving to weight 0, which would leave the
   provider with no open lane. `providers_load` populates `PROVIDER_LANES`
   (keyed by provider name, valued by a JSON object carrying both lanes fully
   defaulted) alongside `PROVIDER_SUBSTRATE` and `PROVIDER_CREDENTIAL_ENV`,
   synthesizing the same all-default object for the implicit `anthropic`
   whenever `providers` does not name it explicitly. `scripts/doctor.sh`'s
   "Claude" section reads it to report both of `anthropic`'s own lanes
   independently — the `api` lane by `ANTHROPIC_API_KEY`'s presence and
   shape, the `subscription` lane by `claude auth status --json` run with
   that key stripped from its own environment (so the answer is about the
   login, not the key), naming whether the login is a genuine subscription
   or a Console account (which bills the API and so is not an open
   subscription lane, #2241) — each line naming present or absent, the
   lane's own configured weight, and whether it is enabled (explicitly, or by
   default given this node's own live credential presence). Both lanes
   absent is still a `fail`, exactly as a single missing credential was
   before this paragraph's own configuration key existed.
1b. **The configuration has a machine-readable schema, and it is the startup
   gate both pipelines run on.** `config.schema.json` states the shape of
   `config.json` — every key an installation may set, its type, its
   constraints, and the value the code falls back to when it is absent. It
   covers both pipelines' keys, including the `repository_review` object of
   `docs/spec/review.md`, because there is one configuration file
   and a schema that described half of it would licence the other half to
   drift. Every object in it is closed (`additionalProperties: false`), which
   is the point: an unread key is a default nobody chose, so a misspelling is
   otherwise indistinguishable from a deliberate omission for as many cycles
   as it takes a human to notice. `lib/config-schema.sh` validates a config
   against it, implementing the subset of JSON Schema the file uses and no
   more; the schema may use only keywords that library implements, which
   `test/config-schema.test.sh` asserts by reading the keywords back out of
   the schema — a validator that silently ignores a keyword is worse than no
   validator, because it reports the configuration sound. Both
   `agent-cycle.sh` and `review-cycle.sh` call it at startup, immediately
   after `CONFIG_FILE` is known and before any individual key is read from it
   — the same fail-fast position requirement 1a's model-id resolution
   occupies, and well before the lock. A validation failure is fatal and
   names every offending path at once, the way the retired `nice` guard
   already named every offending slug at once: one error per run turns a
   five-key typo into one cycle to fix, not five. `scripts/doctor.sh`
   (component 14) is what an operator runs ahead of time, against the same
   library function, so its verdict and the Script's own refusal can never
   disagree. The schema is also the single source for the three prose
   configuration tables — this document's, `docs/spec/review.md`'s
   and the README's — each leaf key's `x-docs` fields carrying the prose,
   `scripts/render-config-table.sh` (component 16) rendering it into the
   documents' marked regions and gating it in CI, so a key can no longer be
   added to the schema and forgotten in a prose copy the way `unvoid_label`
   and `state_local_cycles_retained` both once were. A leaf's `x-docs.value`
   equal to its own schema `default` documents the product's shipped
   behaviour and nothing checks a live installation against it; one that
   differs documents Poetic's own choice for that key, and `scripts/doctor.sh`
   (component 14) warns when a live `config.json` resolves it to something
   else — `refiner_model` documented as installed while the key had never
   once been set, silently running the stage off, is exactly the drift this
   catches (issue #567).

   A `$ref` resolves to a fixpoint, not one hop: a `$def` that itself carries
   a `$ref` — `pr_label`'s `minLength: 1` folded into a `requiredLabel` that
   `$ref`s `label`, say — has every level's keywords enforced, not only the
   outermost, and each hop's sibling keywords keep winning over the target's
   own. Resolution is bounded to a handful of iterations so a cyclic `$ref`
   cannot hang jq. A `$ref` naming a `$defs` path that does not exist, or a
   chain still unresolved past the bound, is a fault in the schema itself —
   `config_schema_errors` reports it as an offending path, the same as any
   other invalid config, rather than treating the missing target as no
   constraints at all (`getpath` on an absent path returns `null`, and jq's
   `null + {...}` would otherwise silently keep only the sibling keywords,
   turning a typo'd `$ref` into a hole under `additionalProperties: false`).
   Reported that way alone, at the config path the `$ref` was reached from,
   the check's reach would be only as deep as the config: both cycles gate on
   the raw config, and a walk that descends only into keys the config
   actually sets would never resolve a `$ref` on a property the operator has
   omitted, leaving that property's own typo exactly as silent as before.
   `config_schema_errors` therefore also sweeps the schema on its own
   terms — descending only through the keywords the validator itself
   understands (`properties`, `items`, `$defs`), never over every `paths`,
   which cannot tell a schema node from a `default`, `const` or `enum` value
   that happens to carry a `$ref` key of its own, and a false positive there
   would fail both pipelines' startup gate for every installation. This sweep
   resolves every `$ref` it finds regardless of whether any config key
   reaches it, including a `$defs` entry nothing currently references and an
   `items` schema behind an array the config leaves empty; its fault is
   reported in schema space (`schema.$defs.label`,
   `schema.properties.pr_label`) rather than borrowing a config path it no
   longer has, so the two kinds of fault read distinctly.
   `config_defaults` resolves the same fixpoint so an inner `$def`'s
   `default` reaches through a chain too, but performs no validation of its
   own: there, an unresolved `$ref` just means no `default` to find at that
   hop, the same as an ordinary `$def` carrying none — including a `$ref`
   combined with a sibling `default` on a key the config omits, which the
   schema-wide sweep above catches as a fault even though `config_defaults`
   still degrades it to nothing there.

   The schema is likewise the single statement of the *values* a reader falls
   back to, and not merely a description of them. `lib/config-schema.sh`'s
   `config_defaults` merges a config with every `default` the schema declares
   — recursively, treating an explicit `null` exactly as absent (the two cases
   jq's own `//` treats alike), filling each item of an array such as `repos`
   on its own, and synthesising an absent object whole from its leaves' own
   defaults so `schedule` may be omitted entirely — and every reader of
   `config.json` reads that merge rather than a `// literal` of its own:
   `agent-cycle.sh`, `review-cycle.sh`, `scripts/doctor.sh`, `lib/claim.sh`,
   `lib/labels.sh`, `scripts/state-sync.sh`, `scripts/rotate-logs.sh`,
   `scripts/sweep-orphan-branches.sh`, `scripts/publish-dashboard.sh` and
   `deploy/docker/render-crontab.sh`. A default therefore exists in one place,
   and each of those scripts requires `config.schema.json` beside
   `config.json` at runtime. The merge performs no validation of its own — a
   config that fails the gate above still merges, defaults and all — which is
   what lets `doctor.sh` go on diagnosing a config the Script would refuse.
   Three kinds of fallback are deliberately not schema defaults and stay in
   code: one that holds *between* two keys, of which
   `refinement_after_coordinator_cycles` inheriting
   `enabler_after_coordinator_cycles` (requirement 34e) is the case in point;
   readers that must depend on nothing but bash, `jq` and `config.json` by
   design, so that what they read cannot drift from what is actually
   deployed — `deploy/docker/watchtower-pre-update.sh`, reading three keys
   (`state_dir`, `lock_stale_after`, `repository_review.lock_stale_after`) that
   carry no schema `default` to take, and `scripts/check-node-image.sh`'s in-container
   grace read, which runs inside whatever image the node is currently running
   and so must stay correct against an image that predates `config_defaults`
   entirely — its `image_behind_grace_hours` key does carry a schema
   `default`, but the read stays a literal `// 3` on principle rather than on
   necessity; and the shipped priors of the two self-tuning stage caps
   (requirement 4f), which live in `lib/stage-budget.sh`'s
   `STAGE_BUDGET_PRIORS`. The last is the one case where a `default` here would
   be actively wrong rather than merely redundant: the `timeout_*`,
   `inactivity_*` and `repository_review.defaults.timeout_review` /
   `repository_review.defaults.inactivity_review` (and their per-repo overrides)
   keys are *overrides*, and a reader distinguishes "configured" from "absent" only
   by the key's absence. A `default` on `$defs/inactivityMinutes` or
   `$defs/timeoutMinutes` would be merged in by `config_defaults`, read as an
   explicit override, and win permanently — pinning the cap at the injected
   value and leaving the derivation unreachable. Both `$defs` therefore carry
   none, and the keys' documented value stays *(unset)*.

   The schema being a gate retires the two startup guards it wholly
   subsumes: `nice`'s range (requirement 3) and `prompt_overrides`' shape
   (requirement 4a) are both fully expressible as `type`/`minimum`/
   `maximum`/`additionalProperties` on a single object, so neither has a
   hand-written check left in `agent-cycle.sh` or
   `lib/prompt-overrides.sh`. Five guards stay in code rather than moving into
   the schema, because each holds *between* two keys, which
   `additionalProperties`/`required`/etc. on one object cannot state: the
   Enabler's assignee (requirement 35), the implementation-plan path
   (requirement 3k), and the three guards of requirement 1c below — the
   model-tier floor, a `"required"` refinement source with `refiner_model`
   empty, and one left unrefinable by `refiner_max_per_engagement: 0`.
   All five are shared, not duplicated, between `agent-cycle.sh` and
   `scripts/doctor.sh` — `lib/config-schema.sh`'s `config_enabler_assignee_ok`,
   `config_missing_plan_path_repos`, `config_model_tier_floor_violations`,
   `config_required_refinement_sources_without_refiner` and
   `config_refinement_sources_paused_by_cap` are the one
   implementation each script calls, so the Script's refusal (or, for the last
   of them, its `warning`) and `doctor.sh`'s `fail`/`warn`
   can never drift on what counts as a fault. Requirement 1c's sixth guard,
   `config_required_failed_runs_source`, is the one exception to the division
   above: it holds within a single key — `refinement_policy["failed-runs"]`
   being `"required"` — and the schema could state it by giving that one
   property its own enum in place of the shared `$defs/refinementPolicyValue`
   `$ref`. It stays in code because agent-ops#924 requires the doctor's own
   message to be the contract for it, and a schema violation reports the
   schema's path rather than why `failed-runs` can never be refined; sharing
   one implementation with `agent-cycle.sh` is what keeps that message from
   drifting. A seventh guard, `config_duplicate_repos_slugs`, stays in code
   for the same reason one step
   out: it holds between two *entries* of `repos[]` rather than between two
   keys of one object, which no array keyword the schema has can state
   either — `uniqueItems` rejects only byte-identical whole entries, and
   `repos` carries none in any case — so two entries sharing a `slug` while
   differing elsewhere leave the per-repo resolvers with no way to say which
   one's overrides apply. `agent-cycle.sh` refuses to start on it,
   naming the duplicated slug(s), and `scripts/doctor.sh` reports the same
   condition as a `fail` through that one implementation, so those two cannot
   drift either (component 14 below; `config_duplicate_repository_review_slugs`
   is the same rule for `repository_review.repos`, shared with `review-cycle.sh`
   instead — `docs/spec/review.md` requirement R1b).

   An eighth guard, `config_provider_errors` (issue #2131), stays in code for
   a reason none of the first seven share: it holds *within* one key,
   `providers`, but that key's own entries are each named by the
   installation rather than drawn from a fixed set the schema's `properties`
   could enumerate in advance — the same gap `additionalProperties: false`
   exists to close everywhere else, with nothing here for it to close
   against. `config_provider_errors` rejects an unknown key inside one
   entry (only `substrate` and `credential_env` are read), a missing or
   unsupported `substrate` — `lib/model-id.sh`'s `PROVIDER_SUBSTRATE_INSTALLED`
   names the full enum, `claude-code` alone after this issue — a `substrate`
   of `claude-code` named by any provider key but `anthropic` (D29, issue
   #2198: that substrate is Claude Code pointed at the provider's own
   endpoint, which only `anthropic` — a Bedrock/Vertex credential route of
   it included, D4 — is entitled to do), and an explicit empty
   `credential_env`. `agent-cycle.sh` and `review-cycle.sh`
   both refuse to start on it, and `scripts/doctor.sh` reports the same
   condition as a `fail` through that one implementation, so the three can
   never drift.

1c. **The model-tier floor (agent-ops#822).** Nothing before this requirement
    stopped the cheapest model in the fleet from authoring a work order
    specification (`context`/`acceptance`) that a more capable model then
    implemented — #815 (fixed by #819) and #821 both trace to exactly this
    gap. `lib/model-id.sh`'s `MODEL_TIER_RANK` is the ordering that makes
    "cheaper" and "more capable" checkable rather than conventional: the
    fleet's four currently configured Claude model ids, ranked by capability
    (Anthropic's own relative pricing confirms the order) —
    `claude-haiku-4-5-20251001` below `claude-sonnet-5` below
    `claude-opus-5` below `claude-fable-5` — each keyed by its fully-qualified
    id (`anthropic/claude-sonnet-5`, `resolve_model_qualified`'s own return
    shape, issue #2131) rather than the bare one `resolve_model_id` returns.
    `model_tier_rank`, `model_tier_known` and `model_tier_below` all take a
    qualified id and read the table by it; a model the table has never heard
    of (a future release, a typo the `modelId` pattern still accepts, or a
    second provider's own model before its own tier is ever added here) ranks
    unknown rather than lowest or highest, and every check below treats
    "unknown" as "cannot verify" — never as "fails" or "passes" — so a model
    newer than this table cannot itself be rejected by it. Tiers are compared
    only *within* one provider (D29, issue #2198): `model_tier_below`
    compares the two ids' provider segments explicitly, before reading
    either side's rank, and returns false for a pair whose providers differ
    whatever either side's rank is — ranking a second provider's models here
    does not, on its own, make this comparison safe, since both sides would
    then be ranked, just on scales nobody has compared; each provider's own
    ranks are its own scale, ordered by that provider's own prices, until the
    roadmap's open question on cross-provider tier ordering is decided.
    `scripts/doctor.sh` warns separately (in its "Models" section) when one of
    `coordinator_model`, `refiner_model`, `enabler_model`,
    `implementer_model_default`, `implementer_model_trivial` or
    `reviewer_model_default` is unranked, and separately again —
    `config_cross_provider_floor_pairs`, named below — whenever a floor
    pair's two sides name different providers, whatever either side's rank,
    so neither case is ever silently invisible to the checks that use this
    table (a cross-provider pair with an unranked side draws both warnings,
    which is the honest reading: each names a reason the floor cannot be
    verified, and removing either one would not restore the comparison).

    Two authors can write a work order's `context`/`acceptance` directly
    rather than relay text a human, the Script, or a gatherer already wrote:
    the Refiner, writing `refined_spec` or an issue comment (requirement 39
    (The Refiner)),
    and the Enabler, writing the same when it settles a `needs-refinement`
    block (requirement 36b). **The floor**: `config_model_tier_floor_violations`
    (`lib/config-schema.sh`) rejects a configuration where `refiner_model` or
    `enabler_model` ranks strictly below `implementer_model_default` or
    `implementer_model_trivial` — either pairing means that author could write
    a specification for an Implementer more capable than itself. Both
    `agent-cycle.sh` (a startup guard, fatal) and `scripts/doctor.sh` (`fail`)
    call the one function, so neither can drift from the other. An empty
    value on either side of a pair is skipped (that stage, or that
    implementer tier, is simply not in play), and so is a pair naming a model
    the table cannot rank, or one whose author and floor name different
    providers (D29, issue #2198) — reported instead as `scripts/doctor.sh`'s
    unranked-model warning above, or its `config_cross_provider_floor_pairs`
    (`lib/config-schema.sh`) warning for the cross-provider case, never
    silently treated as clearing the floor. `config_cross_provider_floor_pairs`
    takes the same four already-resolved qualified ids as
    `config_model_tier_floor_violations` and prints the same
    `author_key\tfloor_key\tauthor_id\tfloor_id` shape for every pair whose
    two sides differ by provider segment, regardless of either side's rank;
    `scripts/doctor.sh` is its only caller — `agent-cycle.sh` has nothing to
    refuse on a pair that is merely unverifiable rather than in violation.
    `coordinator_model` is deliberately outside this comparison:
    requirement 39a (The Refiner)'s "Per-source refinement policy" is what keeps it from
    authoring a specification for a source it must not — see the next
    paragraph — rather than a tier comparison the Co-Ordinator's whole
    reason for existing (cheap triage) would otherwise make impossible to
    satisfy.

    Today's shipped configuration holds `refiner_model` and
    `implementer_model_default` at the **same** tier (`claude-sonnet-5` for
    both) — the floor permits this deliberately, and the reasoning is
    recorded here rather than left implicit: writing a specification demands
    no more capability than implementing it does, so equal tier is
    sufficient, and only a rank strictly *below* either implementer tier is
    ever rejected. `enabler_model` sits a further tier above
    (`claude-opus-5`), for the harder judgement calls requirement 36b's
    refinement duty can involve.

    **Closing the gap on the sources that can still reach an Implementer
    unrefined.** `refinement_policy` (requirement 39a (The Refiner)) is what actually keeps
    a cheap model's own composition out of a work order for a given source:
    `"required"` never selects an unrefined item from that source, so its
    `context`/`acceptance` can only ever have come from the Refiner or the
    Enabler — both held to the floor above — never from `coordinator_model`
    composing one itself. `project-review` and `implementation-plan` are the
    two remaining sources whose items can carry a specification
    `coordinator_model` composed from ambiguous material rather than one
    already fully written elsewhere — every other source `refinement_policy`
    can name is `exempt` by default for exactly that reason, and stays so.
    An installation that runs no Refiner cannot safely set either to
    `"required"` — see the next paragraph — and is left, by the shipped
    `"preferred"` default, exactly as exposed to `coordinator_model`
    authorship as before this requirement for those two sources alone; every
    other source remains `exempt` and therefore Script- or gatherer-composed,
    never model-authored, with nothing here to validate because there is
    nothing here that can go wrong.

    `issues` and `tech-debt` used to belong in the list above — a
    `coordinator_model` composing `context`/`acceptance` for either from an
    issue thread's current state or a tech-debt row's own body was exactly
    the ambiguous-material gap this requirement exists to close, and the
    schema's own shipped default still names both `"preferred"`
    (`config.schema.json`'s `refinement_policy.default`), with this
    installation's `config.json` setting both to `"required"` outright.
    Requirement 17h (agent-ops#769) has since closed that gap structurally
    rather than through `refinement_policy` alone: the Script composes
    `context`/`acceptance` for every `issues`/`tech-debt` candidate itself,
    from a live read, regardless of the item's refinement state — so
    `coordinator_model` cannot author either field for these two sources at
    all any more, whatever `refinement_policy` says about them.
    `refinement_policy`'s `"required"`/`"preferred"` distinction still governs
    whether an *unrefined* `issues`/`tech-debt` item may be selected in the
    first place (requirement 39a (The Refiner)) — that judgement is unchanged — but no
    longer decides who authors its work order text once selected.

    **Resolving `refiner_model`'s optionality.** A `"required"` policy with no
    Refiner to ever refine anything is a configuration nobody can act on:
    `prompts/coordinator.md`'s "Per-source refinement policy" never selects
    an unrefined item from a `"required"` source, and requirement 39 (The
    Refiner)'s own gate on `refiner_model` being set means nothing ever refines one either —
    the source's items would simply wait forever. Three spellings reach that
    state, and the fleet's own decision on the first tech-debt item this
    invariant's own gap was filed against (TD-PPagop-26082704, agent-ops#1003)
    splits them into two consequences:

    - An empty `refiner_model` with any source resolved to `"required"` —
      `config_required_refinement_sources_without_refiner`
      (`lib/config-schema.sh`) rejects this outright, checked by the same two
      callers as the floor above.
    - `failed-runs` resolved to `"required"`, whatever `refiner_model` or
      `refiner_max_per_engagement` are — it is the one source with no
      candidate array at all for the Refiner's own candidate gathering to
      ever reach (`prompts/coordinator.md`'s "Per-source refinement policy"),
      so a `"required"` policy on it is unsatisfiable by construction.
      `config_required_failed_runs_source` rejects this outright too, the
      same refuse class as the case above.
    - `refiner_max_per_engagement: 0` with `refiner_model` set and a source
      resolved to `"required"` — `refiner_engagement_set`
      (`lib/refinement.sh`) slices every engagement's candidates to none, so
      nothing is ever refined even though the Refiner itself is configured.
      Unlike the two cases above, this is not a configuration nobody could
      ever satisfy: `0` is documented behaviour, a deliberate and temporary
      pause of a stage that still exists, and working down an already-refined
      backlog before specifying more is coherent. `agent-cycle.sh` and
      `scripts/doctor.sh` therefore *warn* rather than refuse — every cycle
      the condition holds, never only once, so it cannot age out of the
      dashboard's window the way a once-only warning would —
      `config_refinement_sources_paused_by_cap` computes the set warned
      about. The condition is read with the rest of the configuration, ahead
      of the log existing at all, and the `warning` event is emitted once
      logging is initialised; a management command (requirement 2.3's
      `--status` and its siblings) runs no cycle and emits none, so no
      operator poll can mint a cycle id carrying an event but no
      `cycle-start`. Auto-degrading the source's own policy to `"preferred"`
      was considered and rejected: what runs must be what the config says.

    `refiner_model` therefore stays optional in the schema (a fresh install
    with every default in force sets neither key, and clears every check
    above trivially — `refinement_policy` defaults to `"preferred"` on the
    two sources that carry one at all), but an installation that opts a
    source into `"required"` — as this one has for `issues` and `tech-debt`
    — is rejected outright unless it also runs a Refiner, and unless that
    source is not `failed-runs`; setting `refiner_max_per_engagement: 0`
    afterwards does not then need every `"required"` policy flipped back too
    — it only warns.

    **Escalating a wrong-but-implementable specification does not need a
    fresh mechanism.** A Refiner-authored (or Enabler-authored) specification
    that is technically actionable but wrong already has a route to a
    higher-tier read without waiting on a multi-cycle block-and-age cycle:
    the Implementer that receives it can itself report `"needs-refinement"`
    (its own "Ending" contract), which is exactly the block that makes the
    item Enabler-eligible (requirement 35a) — and `refinement_after_coordinator_cycles`
    (config, minimum `0`) already controls how many further Co-Ordinator
    cycles that eligibility waits on, independently of
    `enabler_after_coordinator_cycles`. An installation that wants a
    wrong-but-implementable specification reaching `enabler_model` (a higher
    tier than either the Refiner or the Co-Ordinator, per the floor above) as
    fast as this system allows sets `refinement_after_coordinator_cycles: 0`
    rather than needing a second escalation channel built beside the one
    `needs-refinement` already is — a block is still required (one signal
    that something is wrong), but no *wait* is, which is the reading of
    "without requiring the item to have visibly blocked first" this
    requirement satisfies.

    `test/config-schema.test.sh` asserts both `agent-cycle.sh` and
    `scripts/doctor.sh` refuse a configuration violating the floor, including
    `refiner_model` ranked below `implementer_model_default`, and refuse a
    `"required"` source with `refiner_model` empty.
1d. **Every timing sized against a once-an-hour cycle derives from the
   configured cadence instead, or states plainly that it does not.** Before
   this requirement, `schedule.cycle_interval_minutes` (issue #248,
   "faster heartbeat") let an installation run its implementation cycle far
   more often than once an hour, but a handful of timings whose *intent* was
   always "a few cycles" stayed literal numbers of hours chosen when a cycle
   and an hour were the same thing: raised at 15-minute cadence, "far beyond a
   whole cycle" became 24 cycles rather than 6, and "beyond a whole cycle, so
   a draft merely being worked never qualifies" stopped bounding what it was
   supposed to. A stale-but-live claim, held four times longer than the
   installation's own cadence would suggest, and a no-op safety valve that
   waits four times as many skipped cycles as intended are both silent —
   neither refuses to start, neither logs a warning — so nothing short of
   this audit would have surfaced either.

   `config_defaults` (requirement 1b) is where the fix lives, as a
   post-fill derivation over the same merged object every one of its
   callers already reads — no reader needed to change. It resolves **two
   gaps between cycles**, both in minutes, from the already-defaulted
   `schedule` block, and the three shapes of key below take one each — the
   first the worst-case gap, the second and third the mean.

   The **worst-case gap** — the longest an installation can go between two
   firings, which is what a threshold that must outlast a quiet stretch is
   sized against: `cycle_hours` (a cron hour field — `*`, `*/N`, `a-b`,
   `a-b/N` and plain numbers, comma-combined) contributes the longest run of
   consecutive disallowed hours, circularly, times 60; `cycle_interval_minutes`
   and `excluded_minutes` contribute the widest gap between two kept firings
   within an allowed hour, measured from the earliest minute
   `excluded_minutes` leaves standing (a representative case, not a worst
   case over every minute a node's own cadence hash could land on — worst-
   casing that collapses the derivation to a fixed ~60 minutes regardless of
   `cycle_interval_minutes`, since a base minute chosen late in the hour can
   genuinely produce only one firing that hour under
   `deploy/docker/render-crontab.sh`'s own restart-at-the-base-minute-each-hour
   loop). The two sum:
   an installation whose `cycle_hours` restricts operation to business hours
   has a worst gap measured in hours regardless of how tight its
   `cycle_interval_minutes` is within them — the implementation note this
   requirement was built from names the failure a derivation blind to
   `cycle_hours` would risk: a `claim_ttl_hours` sized to the bare interval
   expiring a live node's claim overnight.

   The **mean gap** — a day divided by the number of firings in it, which is
   what a *count of firings elapsed* is sized against, whether the key spells
   that count as a number of retained cycle directories or as an hour figure
   that is really "N firings" in disguise: every
   allowed hour repeats the identical kept-minute pattern, so the firings are
   the allowed hours times the kept minutes within one, and the mean gap is
   `1440 / firings_per_day`. It equals the worst-case gap for any
   installation that has restricted neither `cycle_hours` nor
   `excluded_minutes`, and only where they part company does the distinction
   bite — see the second and third shapes of key below for why the worst-case
   gap is the wrong denominator there.

   The derivation validates none of the three `schedule` leaves it reads,
   because `config_defaults` validates nothing (requirement 1b): a
   wrong-typed or unparseable one degrades to the historical hourly
   assumption, under which both gaps are 60 minutes — so neither gap moves
   any of the seven derived keys from the flat figure each already carried
   before this requirement, whichever of the two it takes — rather than
   raising an error that would abandon the
   merge and hand every caller an empty configuration. `scripts/doctor.sh` is
   why that distinction matters: the tool whose job is to report exactly such
   a violation reads a defaulted config to do it, so the derivation must
   survive the configurations it is run to diagnose.

   Three shapes of key are re-expressed against these gaps, each keeping the
   key's *name*, *type* and *unit* unchanged — this is a derivation, not the
   breaking rename a `claim_ttl_cycles` would be. Which shape a key takes
   follows what it is actually sized against, not its unit: an hour-valued
   key can take either gap, and two of the four do.

   - **A stretch that must be outlasted, expressed in hours, against the
     worst-case gap**: `claim_ttl_hours` (6 cycles) and
     `abandoned_draft_after_hours` (4 cycles) each bound a live claim or a
     draft still being worked, and outlasting the longest possible gap is
     the whole of their intent — the worst-case gap is what a threshold
     with that job is sized against (see above). Both also carry the second,
     runtime floor described below.
   - **A count of firings elapsed, expressed in hours, against the mean
     gap**: `disable_default_ttl` (4 cycles) and `none_selected_recheck_hours`
     (24 cycles) each carried an hour figure that was really "N cycles"
     measured back when a cycle was an hour — but the cycles they count are
     firings elapsed (a few cycles of `--disable`, a day's worth of skipped
     `none-selected` runs), the same quantity a count-valued key below counts
     in cycle directories, so each is sized against the mean gap for the
     identical reason: a quantity that accrues at the installation's
     throughput follows how often it fires, not how long its longest quiet
     stretch is. Sizing either against the worst-case gap would starve its
     own documented bound the same way the count-valued keys below would be
     starved by it — see their own bullet for the "9-17" example, which
     applies here unchanged: 36 firings a day derives 3 and 16 respectively,
     where the worst-case gap's 915 minutes would derive 61 and 366 — a
     `disable_default_ttl` outlasting the weekend, and a
     `none_selected_recheck_hours` that can stall the pipeline for a
     fortnight rather than the day requirement 3b documents.

     All four keys across both bullets above are bash integer arithmetic on
     the read side (`lib/claim.sh`'s `$(( claim_ttl_hours * 3600 ))`,
     `scripts/sweep-orphan-branches.sh`'s `^[0-9]+$` guard), never a float,
     and widening that contract is outside this requirement's scope. Absent,
     each is `N * gap_minutes / 60` against its own gap, rounded up to a
     whole hour.
     `none_selected_recheck_hours` alone carries a "0 disables the valve"
     convention (`minimum: 0`, not `exclusiveMinimum`); an explicit 0 stays
     exactly 0, never raised by the derivation, or a deliberate "don't" would
     silently turn back on under a fast enough cadence.
   - **A span of wall-clock history, expressed in cycle directories, against
     the mean gap**:
     `cycles_retained` (200), `state_local_cycles_retained` (1000) and
     `state_local_streams_retained` (50) each bounded roughly how many
     *days* of history a fleet running hourly kept, not literally that many
     cycle directories. Absent, each is now
     `ceil(N * 60 / mean_gap_minutes)`, preserving the same wall-clock span
     (~8.3 days, ~41.7 days and ~2.1 days respectively) as the gap between
     cycles moves, rather than letting a faster cadence quietly shrink the
     retained window fourfold the way a flat count already had. Against the
     **mean** gap, not the worst-case one `claim_ttl_hours` and
     `abandoned_draft_after_hours` take: a cycle directory is written per
     firing, so how many of them a span holds follows how often this
     installation fires, not how long its longest quiet stretch is. The two
     coincide unless `cycle_hours` disallows an hour or `excluded_minutes`
     drops a reachable occurrence, and where they part company only the mean
     preserves the window: a `9-17` installation firing every 15 minutes
     fires 36 times a day (a mean gap of 40 minutes) and so keeps 300 cycle
     directories, where the worst-case gap of 915 minutes would keep 14 —
     about three hours of history in place of eight days, and fewer than the
     flat 200 this derivation replaced.
     `state_local_streams_retained` alone takes a configured value as
     configured — a cap as well as a floor (agent-ops#1826; the design
     decision "A configured `state_local_streams_retained` is a cap as well
     as a floor" records why). It is the one key of the three that bounds
     files of a different order of size from the records holding them, and
     a host whose disk cannot hold the derived count has to be able to say
     so. The value passed on is a whole number of at least 1 — an integral
     float the schema admits (`20.0`) is floored, and 0 or below falls
     through to the derivation — so `scripts/state-sync.sh`'s integer
     arithmetic never meets a literal it cannot read. The other two keep the
     floor-only shape, because a value below their derivation could only
     shorten the record. `config.json` is built into the image every node
     runs, so a value configured here applies to the whole fleet;
     `STATE_SYNC_STREAMS_RETAINED`, which `deploy/docker/compose.yaml`
     forwards to the scheduler from a node's `.env`, sets the count for that
     node ahead of the key, so an installation whose nodes' disks differ
     sizes each on its own (requirement 2.5 has the variable's own rules).
     `crash_loop_after` is the fourth key issue
     #591's audit considered under this same "counted in cycles already"
     heading and decided *against* deriving: its four carries the
     count of *consecutive failures* before a crash-loop escalation fires,
     which is the whole of its intent — time-to-escalation falling as the
     cadence speeds up is the point of a faster cadence, not a defect in the
     count, so it keeps its plain schema default and moves on the operator's
     own terms.

   **`claim_ttl_hours` and `abandoned_draft_after_hours` carry a second
   floor beyond the cadence one.** Both bound a cycle's own worst-case
   *runtime*, not only the gap between cycle starts — `lib/claim.sh`'s
   `do_gc` sweeps a claim-registry entry (and, with it, the claim branch,
   while it is still untouched and PR-less) once `claim_ttl_hours` has
   passed, and `scripts/gather-abandoned-drafts.sh`'s own candidacy race
   presumes the claim it races against has not already been swept, which
   needs `claim_ttl_hours` at least as wide as `abandoned_draft_after_hours`
   too. At a fast enough cadence the cadence term alone can undershoot that:
   6 cadence firings at 15 minutes is 90 minutes, well under the shipped
   Implementer backstop alone (150 minutes, `lib/stage-budget.sh`'s
   `STAGE_BUDGET_PRIORS`), and a cycle whose Implementer has not pushed by
   then would have its claim branch swept by another node's `do_gc` while it
   is still being worked. So each of these two keys' `hour_key` result is
   additionally floored at requirement 4f's own `lock_stale_after` quantity
   (`stage_budget_lock_seconds`) — the same shape as the cadence floor
   above, raised, never lowered. Computed from `STAGE_BUDGET_PRIORS` and
   this configuration's own actor overrides (`stage_budget_all_overrides`)
   alone, with an empty budget table rather than the fleet's own learned
   per-(actor, repository, model) history: `config_defaults` remains a
   function of `config_file` and `schema_file` alone (no reader needing an
   event log to compute its own defaults), and this is the same
   conservative, no-history baseline a fresh installation's
   `scripts/doctor.sh` and `scripts/publish-dashboard.sh` already fall back
   on before any cycle has run, applied here unconditionally rather than
   only until the first one has. `disable_default_ttl` and
   `none_selected_recheck_hours` bound no in-flight claim or draft, so
   neither carries this second floor.

   **The three count-valued keys' resulting volumes, at the shipped
   15-minute cadence** (`cycles_retained` 200 → 800,
   `state_local_cycles_retained` 1000 → 4000, `state_local_streams_retained`
   50 → 200, all fourfold since `gap_minutes` falls from the historical 60
   to 15; TD-PPagop-26082830): `state_local_streams_retained` is the one
   worth quantifying rather than only ratioed, since it alone bounds files
   large enough to matter. A cycle directory without its derived files is
   kilobytes and a stage stream megabytes, so 200 retained cycles' streams
   are low hundreds of megabytes on a busy repository, against
   `cycles_retained`'s and `state_local_cycles_retained`'s tens of megabytes
   each — inside `min_free_workspace_bytes`'s 2 GiB pre-clone floor (2.0c),
   the one check any of these three keys' derivation could trip. The
   fleet-log snapshot is the file of a different order: measured on both
   poetic nodes on 2026-09-18 (agent-ops#1678), 200 retained snapshots ran
   45 MB apiece and 7.3–7.4 GB per node, regrowing at about 4.3 GB per node
   per day, and each is larger the longer the fleet's `log.jsonl` runs.
   That is why a snapshot does not stay to be counted at all: the cycle or
   review that wrote it removes it when it ends (requirement 2.5), and this
   count meets a snapshot only where a run died before its own cleanup.

   Both shapes share `lock_stale_after`'s own contract (requirement 4f),
   with the one exception the count-valued bullet above names: a
   configured value is a **floor under the derivation, never a ceiling**. An
   operator's explicit hours or cycle count can still be *raised* by the
   derivation — the overnight-expiry failure above, guarded against even for
   a value someone set by hand — but the derivation can never lower what was
   explicitly configured; `state_local_streams_retained` alone is taken as
   configured in both directions. Absent entirely, the derivation is the whole
   answer, which is why each of these seven keys now carries no schema
   `default` of its own (`x-docs.value` renders `*(unset)*`, the same
   convention `lock_stale_after` already uses) — a literal default here would
   be merged in by the generic fill above, read back as an explicit override,
   and win permanently, leaving the derivation unreachable, exactly the
   reasoning 1b's own closing paragraph already gives for why the two
   self-tuning `$defs` carry none.

   **Already independent, confirmed rather than changed.** `lock_stale_after`
   and `repository_review.lock_stale_after` are each already a floor under a
   value derived from the stage backstops in force (requirement 4f) — a
   cycle's own worst-case runtime, not the scheduling interval between cycle
   starts, is what a stuck lock has to outlast, and the two quantities are
   independent by construction. The usage-limit stand-down probe (2.1b)
   already runs once per cycle however often that is, so it follows
   `cycle_interval_minutes` mechanically and needed no change. The roadmap's
   "lock staleness" candidate (`docs/ROADMAP.md` Phase 1, D7) is this
   paragraph's answer: already correct, not a fourth case for the table
   above.

   **Independent by design, and each says so on its own schema entry.**
   `enabler_recheck_hours`, `human_nudge_idle_hours`,
   `merge_queue_dequeue_notice_max_age_hours` and `void_retire_after_days`
   measure human-world time — how long before a person is expected to have
   looked at something — which does not shrink because the pipeline itself
   runs more often. `limit_escalate_after_hours` and `lib/limit-detect.sh`'s
   `LIMIT_LONG_COOLDOWN_HOURS` are bounded by the account provider's own reset
   clock, not this installation's cadence. `image_behind_grace_hours` bounds
   how long a node may run behind a published image mid-roll, a property of
   the deploy pipeline, not the cycle cadence. `stage_budget.window_days` and
   `window_runs` are a statistical window over *runs*, which a faster cadence
   fills with more data without changing what the window means.
   `schedule.heartbeat_minutes`, `state_sync_push_minutes`,
   `state_sync_fetch_minutes`, `log_rotation_minute`, `doctor_offset_minutes`
   and `review_offset_minutes` each have their own crontab line in
   `deploy/docker/crontab.tmpl` and run hourly or sub-hourly on their own
   terms, independent of the implementation cycle's. `log_retained_bytes`
   triggers rotation on size, which self-corrects regardless of how often
   the log is written to.
52. **The table of contents is generated from headings, not hand-maintained,
   and regenerating it is gated in CI.** Each guide under `docs/guides/`
   carries a `<!-- toc:start -->` … `<!-- toc:end -->` region, placed
   immediately after the document's title (and any lead-in paragraph,
   before its first `##` heading), holding a nested bullet list of every
   `##`/`###` heading in the document — the same "generated, never
   hand-edited" contract AGENTS.md's "Generated regions" note states for the
   configuration tables (requirement 1b, component 16), for a second kind of
   region. `docs/spec/implementation/README.md` and
   `docs/spec/dashboard/README.md` carry the same marker pair, but hold a
   directory-wide list instead — one entry per sibling file under their own
   directory, linking each sibling's own first heading, rather than headings
   within the README itself. `scripts/render-toc.sh` (component 24) renders
   both kinds, from `lib/markdown-scan.sh`'s `TOC_FILES` (the own-heading
   kind) and `TOC_DIR_FILES` (the directory-wide kind): for the own-heading
   kind, extracting headings in document order while
   skipping fenced code blocks (`lib/markdown-scan.sh`, the one fence-aware
   reading it shares with requirement 52a), slugging each to GitHub's own heading-anchor
   algorithm — lower-cased, stripped to `[a-z0-9_-]` and space, spaces to
   `-`, with no further collapsing of consecutive hyphens, since GitHub's
   own algorithm does not collapse them either — and de-duplicating repeated
   slugs across the whole document the way GitHub's own renderer does (the
   first occurrence keeps the bare slug, each later one is suffixed `-1`,
   `-2`, …), so every generated link resolves to a real in-document anchor.
   Before rendering, each target file is checked for exactly one
   `<!-- toc:start -->` / `<!-- toc:end -->` marker pair with the start
   marker on an earlier line than the end marker; a file with neither
   marker, only one of the pair, more than one of either, or the pair in
   reversed order, is refused — in both the plain and `--check`
   invocations — naming the file, rather than copied through unchanged
   (or, for the reversed case, silently corrupted), which would otherwise
   leave a missing or unpaired region undetected. `.github/workflows/toc.yml` runs
   `scripts/render-toc.sh --check` on every pull request, failing it the
   moment a heading is added, removed or reworded without a matching
   regeneration, or a target file's marker pair is missing or malformed.
52a. **The documentation is measured against a fixed benchmark of real
   questions, not asserted to be good, and the benchmark is never run by the
   pipeline.** `test/docs-benchmark/questions.jsonl` holds at least 48
   questions, at least eight for each of six readers (`target-user`,
   `operator`, `evaluator`, `contributor`, `cycle-agent` and
   `output-reader`), each with a gold answer, the sources that state it and
   the facts a correct answer must contain. Every source names a file and a
   heading of it, a label inside its `## Requirements` section, or a label
   inside its `## Acceptance checks` section, outside fenced code, and every
   backticked token of a required fact appears in its gold answer. The
   sources are checked on every pull request, because the change that moves
   one is usually documentation-only. `scripts/docs-benchmark.sh` (component
   24a) asks each question of `claude -p` in a plain directory holding a
   ref's files, with no `.git` and no path named `*docs-benchmark*`, with a
   fixed model at a fixed effort, only the Read, Grep and Glob tools, project
   settings only and the environment variables that change the model's
   behaviour cleared, and has a separate call grade each answer fact by
   fact. It records the answer, the grade with the grader's reasoning, the
   tool calls, the tokens and the wall time, and writes a dated report under
   `docs/reviews/`. The definitions that decide what a run's figures mean
   are named as the protocol in `lib/docs-benchmark.sh` and hashed; every
   report records that hash, a hash of what a run reads of the questions,
   and the Claude Code version, and two reports are comparable when all
   three match. No stage, workflow or crontab entry runs the benchmark
   itself: a stage that launched `claude` would be an agent launching an
   agent (see "Actors"), and every run spends tokens.
52b. **The documentation's links, map, size budget, section citations and
   as-built phrasing are checked offline on every pull request.**
   `scripts/check-docs.sh` (component 24b) makes five checks over every
   tracked Markdown file bar the fixtures `test/check-docs.test.sh` builds to
   break them and the frozen `tech-debt/` archive, printing one line per
   violation and exiting non-zero if any check failed. Every relative
   Markdown link, and every `x-docs` link in `config.schema.json`, resolves
   to a path that exists, and a `#fragment` on one matches either a heading
   of the target — slugged by `lib/markdown-scan.sh`'s `gh_slug`, the one
   GitHub anchor-slug formula shared with requirement 52's table of contents,
   so the fragment this accepts and the anchor that generates cannot
   disagree — or an explicit `<a id="…">`/`<a name="…">` anchor in it, which
   GitHub resolves a fragment against just as readily and which a
   heading-only reading would call broken. Every in-scope document is named
   in `docs/README.md`'s "All documents" map, one row per file except a dated
   `docs/reviews/project-review-*/` directory, which takes one entry for the
   whole directory, and every path that map names exists. No in-scope
   document's hand-written content — its bytes outside the generated regions
   `lib/markdown-scan.sh` lists, the configuration tables of requirement 1b,
   the tables of contents of requirement 52 and the regions the organisation's
   sync stamps, which a schema change, a new heading or a re-stamp regenerates
   — exceeds the 100,000-byte budget `docs/README.md`'s "Size budget" section
   fixed, unless the document is exempt there (`CHANGELOG.md`,
   `docs/ROADMAP.md`, `docs/reviews/**`, and every as-built specification,
   `docs/*-SPEC.md` with its `*` inside one path segment, which `AGENTS.md`'s
   "As-built specifications" section requires to grow) or carries an entry in
   `scripts/docs-size-ratchet.tsv` naming the byte count it may not grow past
   and the issue that will bring it under budget. A marker pair in a file, or
   with an id or fragment, that the library does not list holds hand-written
   bytes, as does a region that never reaches its own end marker, so only what
   a renderer rewrites leaves the measure. An entry for a document that is
   missing, exempt or within the budget fails, as does an exemption that
   matches no document, so neither list outlives what it describes. A quoted
   section citation,
   in any of the three forms `docs/README.md`'s "How sections are cited"
   section and this repository's prose use, names a heading of the file it
   cites or text that still exists in it — checked in documents, prompts,
   scripts and workflows alike, but never inside a frozen record, whose
   citations were true when it was filed and which is never edited
   afterwards. And the count of the five historical-sounding phrases
   `scripts/docs-phrasing-ratchet.tsv`'s own header lists stays at or below
   that file's entry for each as-built document: a ratchet, not a ban, since
   the standing decision of 2026-09-04 (#1154) allows a historical aside that
   passes the deletion test. Both ratchet files are inventories of what is
   over the line today, the exemptions aside, never a place to buy slack by
   raising a limit.
   The whole check runs offline, reading no network, so an external link is
   out of scope by design — as are spelling, grammar and requirement-label
   citations, which issue #2095 covers instead.
   `.github/workflows/docs.yml` runs `scripts/check-docs.sh --check` on every
   pull request, on `merge_group` and on push to `main`, ungated by `paths:`
   — a renamed heading, a moved file or a new citation anywhere in the tree
   can break any of the five.
