# Product-Repository Split Plan

**Document captured at:** `d59423e4359c7b28104381e9d9d14981d16950f1`

This plan describes the split of agent-ops from a monolithic operations repository into a product repository (hosted in the Pullwright organisation) and a consumer instance (Poetic's configuration and deployment in Poetic-Poems/agent-ops).

## Inventory of top-level paths

This section classifies every top-level path on `main` as of the commit above. The repository has gained paths since the issue specification (AGENTS.md, CONTRIBUTING.md, SECURITY.md, monitor-cycle.sh); all are classified below.

| Path | Class | Notes |
|------|-------|-------|
| `.claude/` | Product | Vendored review skill in `skills/` moves; becomes product source (D7) |
| `.dockerignore` | Product | Docker build configuration |
| `.github/` | Both | See "workflows" section below |
| `.githooks/` | Consumer | Poetic's own local git hooks |
| `.gitignore` | Product | Standard VCS ignore patterns |
| `AGENTS.md` | Product | Repository operations conventions (moved) |
| `CHANGELOG.md` | Consumer | Poetic's own changelog |
| `CLAUDE.md` | Product | References AGENTS.md which moves; kept in product for consistency |
| `CODEOWNERS` | Product | Pipeline repo ownership and review routing |
| `CONTRIBUTING.md` | Consumer | Poetic-specific contribution guidelines |
| `LICENCE` | Both | Currently MIT; product carries its own licence (D15, open in Phase 2) |
| `README.md` | Both | See "documentation" section below |
| `SECURITY.md` | Consumer | Poetic's own security policy |
| `TECH-DEBT.md` | Product | Policy document; applies to both |
| `agent-cycle.sh` | Product | Implementation pipeline entrypoint |
| `config.json` | Consumer | Poetic's configuration values |
| `config.schema.json` | Product | Configuration schema (shared, versioned with product) |
| `dashboard/` | Both | See "dashboard" section below |
| `deploy/` | Both | See "deployment" section below |
| `docs/` | Both | See "documentation" section below |
| `lib/` | Product | Pipeline runtime libraries |
| `monitor-cycle.sh` | Product | Monitor pipeline entrypoint |
| `prompts/` | Product | Stage operating prompts |
| `review-cycle.sh` | Product | Repository-review pipeline entrypoint |
| `scripts/` | Both | See "scripts" section below |
| `tech-debt/` | Consumer | Poetic's own tech-debt register (frozen archive) |
| `test/` | Product | Pipeline test suite |

## Classification details

### `.claude/skills/` — Vendored Review Skill (D7)

**Current state:** Pinned copy of personal authoring repository, vendored into agent-ops.

**After split:**
- **Product:** The authoritative source becomes the skill definition in the product repository
- **Consumer:** Poetic's `review-cycle.sh` stages the product skill into each target repository at runtime, same as today

**Mechanism:** `review-cycle.sh` continues to vendor the skill but sources it from the product repository rather than a personal repo.

### `tech-debt/` and register tooling (D15, D20)

**Current state:** Poetic's frozen tech-debt register (items filed under scope `PPagop`). Tooling (`scripts/check-closing-keyword.sh`, etc.) exists locally for register maintenance.

**After split:**
- **Tech-debt register (`tech-debt/`):** Consumer. Poetic retains its own frozen archive as a historical record
- **Register tooling:** Product. D15 moves canonical tooling into the product repository
- **Delivery mechanism:** D20 specifies *delivered by the product, not copied into it*. Consumer repositories receive the tooling via product delivery, not vendoring

**Current interim state (through D20):** Tooling remains in both places to avoid deepening the copying the split is meant to retire. After D20 resolves delivery, product tooling is the authoritative source and consumers receive it.

### `config.json` vs `config.schema.json`

**Current state:** Schema is shared; Poetic has its own values.

**After split:**
- **Product:** `config.schema.json` (the schema definition, versioned with product)
- **Consumer:** `config.json` (Poetic's own values, specific to its deployment)
- **Mechanism:** Poetic fetches or inherits the schema from the product at deployment time; maintains its own values file

### `.github/workflows/`

**Current state:** Mixed pipeline CI and Poetic-specific deployment workflows.

**After split:**
- **Product workflows:** `commit-format.yml`, `config-table.yml`, `toc.yml`, and other pipeline-infrastructure checks
- **Consumer workflows:** `build-image.yml` (Poetic's docker image build), `*.init` (Poetic's service startup)
- **Shared/Both:** Workflows that depend on product pipelines but run against consumer config (e.g., validation workflows)

Product workflows move; consumer-specific ones stay. Workflows that validate the consumer instance against the product schema stay in consumer (Poetic).

### `docs/`

**Documentation is split by role:**

| Path | Class | Notes |
|------|-------|-------|
| `docs/*-SPEC.md` | Product | As-built specs for pipeline components |
| `docs/ROADMAP.md` | Consumer | Poetic's own roadmap and Phase 1 planning |
| `docs/PRODUCT-SPLIT-PLAN.md` | Consumer | This document; Poetic's record of the split plan |
| `docs/TECH-DEBT-REGISTER.md` | Product | Register format and policy (moved) |
| `docs/reviews/` | Consumer | Poetic's own pipeline review reports (dated) |

Product specs move to the product repository. Poetic retains its roadmap, planning documents, and review history.

### `dashboard/`

**Current state:** Shared monitoring dashboard, built for the autonomous fleet.

**After split:**
- **Product:** Dashboard code and build (moved to Pullwright)
- **Consumer:** Poetic's deployment configuration for the dashboard
- **Access:** Fleet nodes (including Poetic) access the dashboard at a shared hosted URL or fetch deployment from product

The dashboard is product infrastructure; Poetic accesses it, does not maintain it.

### `deploy/`

**Current state:** Docker image definition, environment configuration, and deployment scripts.

**After split:**

| Path | Class | Notes |
|------|-------|-------|
| `deploy/docker/` | Product | Dockerfile and image build configuration |
| `deploy/image-build.sh` | Product | Image build entrypoint |
| `deploy/poetic.env` | Consumer | Poetic's environment configuration |
| `deploy/compose-*.yml` | Consumer | Poetic's Docker Compose configuration |

**Mechanism:** Product provides the image build system. Poetic provides its own environment and compose files that reference the product-built image. `.github/workflows/build-image.yml` updates the image on product changes; Poetic references it by tag.

### `scripts/`

**Scripts split by function:**

| Path | Class | Notes |
|------|-------|-------|
| `scripts/run-tests.sh` | Product | Pipeline test harness |
| `scripts/lint-shell.sh` | Product | Pipeline code quality |
| `scripts/render-*.sh` | Product | Generated-region rendering (config tables, TOC) |
| `scripts/check-closing-keyword.sh` | Product | Issue/PR closing validation (D15 tooling) |
| `scripts/preview-deploy.sh` | Consumer | Poetic's Vercel preview validation |
| `scripts/publish-dashboard.sh` | Product | Dashboard build/publish (moves with dashboard) |
| `scripts/gather-*.sh` | Product | Pipeline coordination scripts |
| `lib/` subdirectory scripts | Product | Runtime libraries (pipeline operations) |

Product scripts move; consumer-specific scripts stay.

## Migration order and fleet continuity

### Phase 1: Create the product repository

1. **Create the Pullwright/poetic-pipeline repository** with:
   - All product-classified paths
   - Product-side of "both" paths (schema, specs, workflows, deployment tooling)
   - Initial configuration for product-level autonomy (#581 constraint)

2. **Timing:** Can proceed in parallel with subsequent phases, but must complete before Phase 2.

3. **Fleet impact:** None. No code moves on fleet nodes yet.

### Phase 2: Cutover consumer code paths

Once the product repository exists and is CI-green:

1. **Delete product paths from agent-ops**, leaving:
   - Consumer paths (config.json, Poetic-specific docs, tech-debt register)
   - Consumer-side of "both" paths (Poetic's docs, Poetic's workflows, Poetic's deploy config)

2. **Update agent-ops references** to pull product paths from the product repository at runtime:
   - `agent-cycle.sh` imports stage prompts from product
   - `review-cycle.sh` stages the review skill from product
   - Build workflows clone product repo for specs and tooling

3. **Transition duration:** ~0–2 hours of coordinated cutover

4. **What breaks during transition:**
   - **Mid-cycle nodes:** A node executing a cycle when product paths are deleted will fail. Mitigation:
     - Pause fleet (recommended for coordinated cutover)
     - OR: Pin mid-cycle nodes to a specific product commit (ref pinning), allow new cycles to start on the next product commit once product repo is ready
     - OR: Nodes fetch product code at cycle start (pull, not clone), so deletion is transparent as long as clones have already occurred

5. **Fleet continuity:** Implement product-code fetching at cycle start to tolerate concurrent deletions. Example:
   ```bash
   # In agent-cycle.sh cycle start
   git clone <product-repo> $PRODUCT_CODE
   PATH=$PRODUCT_CODE/scripts:$PATH  # Use product tools
   ```

   This allows nodes mid-cycle to complete, and new cycles to start immediately on product code.

### Phase 3: Update deployment pipeline

After agent-ops references point to the product repository:

1. **Update `deploy/docker/`** to reference product image builds rather than maintaining a local Dockerfile
2. **CI/CD workflows:** Poetic's `build-image.yml` triggers on product repo changes, tags the built image, and caches it
3. **Node rollout:** On next node deployment cycle, nodes pull the product-built image

**Transition duration:** Immediate once Phase 2 completes.

### Broken functionality during transition

**During Phase 2 cutover (between deletion and product reference):**
- Pipeline code (agent-cycle.sh, review-cycle.sh) may fail to import stage prompts
- Review skill staging fails until review-cycle.sh is updated
- New cycles cannot start until product repo is cloned

**Duration:** 0–2 hours (coordinated) or until all mid-cycle nodes complete (uncoordinated).

**Prevention:** Implement fetching at cycle start (Phase 2 above) so mid-cycle nodes complete normally and new cycles start after product repo is ready.

## Node deployment follow-through

### How a node's deployment follows the code

1. **Docker image build:** Triggered by changes to `deploy/docker/` in the product repository
   - Build runs in Poetic's `build-image.yml` workflow (consumer)
   - Image is pushed to Poetic's container registry (consumer config)
   - Tag is published for nodes to pull

2. **Node startup:** On deployment/restart:
   - Node pulls the latest product-built image tag
   - Runs `deploy/compose-poetic.yml` (consumer config)
   - Starts `agent-cycle.sh` and `review-cycle.sh` from the image

3. **Mid-cycle deployment:** If a cycle is running when new image is available:
   - Current cycle completes using the running image
   - Next node startup pulls the new image
   - Cycles running mid-deployment are unaffected

### Workflow update

**`.github/workflows/build-image.yml` (consumer):**
- Triggers on product repository commits (via webhook or scheduled sync)
- Clones product repository to access `deploy/docker/Dockerfile`
- Builds and tags image for Poetic's use
- No changes to Poetic's own compose or init scripts

**`monitor-cycle.sh` implications:**
- Remains in Poetic's agent-ops; monitors fleet state
- No changes needed; accesses product data via cloned product repo on each cycle

### Retired: `td-tooling-drift.yml`

**Current role:** Vendoring policeman for register tooling (D20 context).

**After split:**
- **If D20 uses vendoring (interim):** Workflow continues, now polling product repo instead of personal repo
- **Once D20 resolves delivery mechanism:** Workflow is retired; product delivers tooling directly

**Plan:** State dependency on D20 resolution. For now, assume interim vendoring from product repo.

## Constraints and dependencies

### #581 — Product repository autonomy level

The Pullwright repository is provisioned at agent-ops's autonomy level (`agent-merges-routine` or equivalent) from day one, not at the product default (`human-decides`). This means:
- Autonomous agents can propose and merge changes to the product repository
- Review gate and approval automation are configured at provisioning time
- No human escalation needed for routine product changes

**Impact on split:** Provisioning is the **first step** before any code moves. Once provisioned, the repository is ready to receive moved code immediately.

### #600 — Licence decision (open, Phase 2 gate)

The product repository must carry a licence. The question of which licence and how it interacts with agent-ops's current MIT licence is an open question (#600) with a Phase 2 exit gate.

**Plan assumption:** Until resolved, assume the product repository carries the same MIT licence as agent-ops, and no licence-specific changes are needed for this split.

### D20 — Tooling delivery mechanism (open, Phase 2 gate)

D20 specifies how the product repository delivers register tooling to consumer repositories (delivered, not vendored). Until resolved, the plan assumes interim vendoring from the product repository.

**Impact on split:**
- Phase 2 proceeds with vendoring; tooling location changes from personal repo to product repo
- Phase 3+ (after D20 resolution) transitions to delivery; tooling stops being vendored

**Plan:** Document interim vendoring explicitly. Once D20 resolves delivery, `scripts/check-closing-keyword.sh` and related tooling stop being copied; consumers receive them via product delivery instead.

## Implementation checklist

- [ ] **Phase 1:** Create Pullwright/poetic-pipeline with all product paths
- [ ] **Phase 1:** Verify product repo CI is green and stable
- [ ] **Phase 1:** Verify product repo is provisioned at agent-ops autonomy level (#581)
- [ ] **Phase 2:** Update agent-ops to import product code at cycle start
- [ ] **Phase 2:** Delete product paths from agent-ops
- [ ] **Phase 2:** Verify fleet continues operating across cutover
- [ ] **Phase 3:** Update deployment workflows to reference product image builds
- [ ] **Phase 3:** Verify node deployments pull correct product-built images
- [ ] **Post-Phase 2:** Resolve D20 (delivery mechanism) and update `td-tooling-drift.yml`
- [ ] **Post-Phase 2:** Resolve #600 (licence) and update product repository metadata
