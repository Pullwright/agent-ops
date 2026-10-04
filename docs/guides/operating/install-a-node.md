# Install a node

A node is one Compose project running the agent-ops scheduler and supporting services in containers. This page covers the container installation path only.

## Prerequisites

- Docker and Docker Compose installed
- A GitHub personal access token (`GH_TOKEN`) with `repo`, `read:org`, and `security_events` scopes
- Claude model credentials (API key or subscription)
- A Tailscale authkey (optional, for dashboard access over your tailnet)

See [docs/DATA-HANDLING.md](../../DATA-HANDLING.md) to understand what data the pipeline reads, stores, and retains.

## GitHub authentication

The pipeline authenticates with GitHub in two ways:

**Primary:** A personal access token (`GH_TOKEN`) set in `.env`. Required scopes:
- `repo` — to read and write to repositories the pipeline works on
- `read:org` — to list organizations and repositories
- `security_events` — to read Dependabot and code-scanning alerts

**Optionally: Forge authoring App** (D18 decision 1). If your installation provisions a GitHub App for short-lived tokens, set `GH_APP_ID`, `GH_APP_INSTALLATION_ID`, and `GH_APP_PRIVATE_KEY` in `.env`; the App mints tokens automatically, letting you rotate the key or remove the App without restarting nodes. Omit these and nodes authenticate with `GH_TOKEN` alone, which is the simpler path.

Test token access:
```bash
# From the host
export GH_TOKEN=<your-token>
gh repo list --limit 1

# From inside the container (after bringing it up)
docker compose exec scheduler gh repo list --limit 1
```

## Model authentication

The scheduler runs Claude over text from GitHub, so every node needs model credentials. Two paths:

**Primary: BYO API key**
1. Get an Anthropic API key from [claude.ai/settings](https://claude.ai/settings)
2. Set `ANTHROPIC_API_KEY=<key>` in `.env`
3. `docker compose up -d` — the key is picked up at container start

This scales to any number of nodes sharing the same key.

**Alternative: Subscription OAuth**
1. `docker compose up -d` to start the node
2. `docker compose exec scheduler claude` to authenticate interactively
3. Complete the login flow in your browser
4. The node's Claude session is saved to its `~/.claude` volume

This path is interactive per node (no script), and the subscription's terms limit it to your own use, not a service for others. Until one of these is configured, every cycle fails at its first stage.

## Install a container node

1. **Create a node directory and download the stack:**
   ```bash
   mkdir -p ~/poetic-node
   cd ~/poetic-node
   
   base=https://raw.githubusercontent.com/Pullwright/agent-ops/main/deploy/docker
   curl -fsSLO "$base/compose.yaml"
   curl -fsSLO "$base/ts-serve.json"
   curl -fsSL "$base/.env.example" -o .env
   curl -fsSLO "https://raw.githubusercontent.com/Pullwright/agent-ops/main/scripts/watch-node.sh"
   chmod +x watch-node.sh
   ```

2. **Edit `.env` to name the node and set credentials:**
   ```bash
   $EDITOR .env
   ```
   
   Required:
   - `NODE_NAME=<your-node-name>` — a short identifier (alphanumeric, no spaces)
   - `GH_TOKEN=<token>` — GitHub PAT from above
   - Either `ANTHROPIC_API_KEY=<key>` (primary) or leave empty and set up subscription OAuth in step 4
   
   Optional (for dashboard over your tailnet):
   - `COMPOSE_PROFILES=tailnet`
   - `TS_AUTHKEY=<key>` — Tailscale authkey; see [Tailscale](https://tailscale.com/kb/1101/oauth/)
   
   Optional (for preview deployment checking):
   - `VERCEL_AUTOMATION_BYPASS_SECRET` — from Vercel project settings
   - `VERCEL_TOKEN` — optional, for build logs on failed deployments

3. **Start the container:**
   ```bash
   docker compose up -d
   ```

4. **If using subscription OAuth, log in to Claude:**
   ```bash
   docker compose exec scheduler claude
   # Follow the interactive login flow
   ```

5. **Run the first health check:**
   ```bash
   docker compose exec scheduler /app/scripts/doctor.sh
   ```
   
   This verifies your configuration, GitHub access, and model credentials. All three Egress checks should show `[ ok ]`.

6. **Run a dry run to see the pipelines in action:**
   ```bash
   docker compose exec scheduler /app/agent-cycle.sh --dry-run
   ```
   
   This selects work without launching agents — a good first check that everything is wired up.

## The Compose stack

The image carries the whole toolchain (`/app` is agent-ops itself). A node updates by pulling a new image, never by pulling a branch inside a running container. Each merge to `main` that touches files the container reads publishes a new image to `ghcr.io/pullwright/agent-ops` as `latest` and as the commit SHA.

To pin a node to a known-good build or roll back, set in `.env`:
```bash
AGENT_OPS_IMAGE=ghcr.io/pullwright/agent-ops:<sha>
```

Check the [package registry](https://github.com/pullwright/agent-ops/pkgs/container/agent-ops) for available SHAs. A documentation-only merge publishes no image.

Five things are worth knowing:

- **`~/.claude` is a volume.** Claude's OAuth credentials refresh and write back. The entrypoint seeds `settings.json` only when absent.

- **`state_dir` is a volume.** The pipelines' memory lives here and is shared between nodes via the state repository (see [Keeping every node warm](#keeping-every-node-warm) in the Monitoring section).

- **`state_dir` must be writable by the container user** (uid 1000 by default). The entrypoint refuses to start if it is not. To match a different host uid, rebuild with `docker build --build-arg PUID=<uid> deploy/docker`.

- **The dashboard is never reachable from a network.** The `tailnet` profile puts it in the Tailscale sidecar's namespace; the `local` profile publishes it only to the host's loopback (`127.0.0.1:${DASHBOARD_PORT:-8787}`). If port 8787 is taken, set `DASHBOARD_PORT` in `.env` to move the host side of the mapping.

- **Profiles** in `COMPOSE_PROFILES` decide what runs alongside the scheduler:
  
  | Profile | What it adds |
  |---|---|
  | `tailnet` | Tailscale sidecar + dashboard, served over HTTPS to your tailnet at `https://<node>.<tailnet>` |
  | `local` | Dashboard on loopback only (`http://127.0.0.1:8787`) |
  | `node-health` | HTTP health endpoints (`/livez`, `/readyz`, `/healthz`, `/metrics`) on loopback at port 8788 for monitoring |
  | `auto-update` | Watchtower, which pulls new images and restarts into them |
  
  The scheduler is in no profile: it runs on every node.

## The egress fence

The scheduler reaches the internet only through the `egress-proxy` service's domain allowlist (`deploy/docker/egress-allowlist.txt`). This is topology, not convention: the scheduler sits on an internal Docker network with no gateway, and the proxy is the only way out. It permits HTTPS only to the domains the pipelines actually use:
- GitHub (`github.com`, `raw.githubusercontent.com`, `ghcr.io`)
- Anthropic API
- Vercel previews (if configured)
- npm registry (for build-time dependencies)
- Docker image registry

Everything else is refused, including Claude Code's optional traffic (updates, telemetry, error reporting), which the scheduler's environment turns off at the source.

### For a node needing an extra domain

If you're running a Vercel project serving previews from a custom domain:
```bash
echo "EGRESS_EXTRA_ALLOW=preview.example.com" >> .env
docker compose up -d egress-proxy
```

Comma- or whitespace-separated for multiple domains. Fleet-wide additions belong in `deploy/docker/egress-allowlist.txt` instead, where each entry names the code that needs it.

### Troubleshooting the fence

If everything times out after enabling the fence:

1. **Check the MTU.** An MTU black hole through the proxy looks exactly like a refused domain. See the MTU note in `compose.yaml`.

2. **Run doctor.sh.** The Egress section names three failure shapes:
   - Proxy path broken
   - Allowlist not enforcing
   - Direct egress still open (this node's compose.yaml predates the fence)

   ```bash
   docker compose exec scheduler /app/scripts/doctor.sh
   ```

3. **Check the domain is in the allowlist.** Open `deploy/docker/egress-allowlist.txt` or set `EGRESS_EXTRA_ALLOW` (above).

There is deliberately no off-switch variable: unfencing a node is an explicit edit to its compose.yaml, made knowingly or not at all.

## Node roles: active and standby

Set `ROLE=active` in `.env` for nodes meant to run cycles unattended; the rest stay `standby`. Any number of nodes may be active at once — per-item claims keep them off each other's work. A standby node still publishes its heartbeat and follows every peer's memory, so promoting one is one variable change away.

For more on how this works, see [Which node runs the cycles](watch.md#which-node-runs-the-cycles).

## Next steps

After installation:
- See [Configure](configure.md) to set up repositories and work sources
- See [Run and pause](run-and-pause.md) to operate the pipelines
- See [Watch](watch.md) to monitor your nodes
