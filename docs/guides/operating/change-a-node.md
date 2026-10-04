# Change a node

Update images, configuration, node roles, and manage node removal.

## Roll a new image

The scheduler image updates automatically if the `auto-update` profile is enabled (watchtower). To roll manually or check the current version:

```bash
# Pull the latest image
docker compose pull

# Start the updated image (recreates the scheduler)
docker compose up -d

# Verify the version
docker compose exec scheduler cat /app/.image-info.json | jq .

# Or check the dashboard — nodes show "behind" if an older image is running
```

To pin to a specific build (for testing or rollback):

```bash
echo "AGENT_OPS_IMAGE=ghcr.io/pullwright/agent-ops:<sha>" >> .env
docker compose pull
docker compose up -d
```

Check the [package registry](https://github.com/pullwright/agent-ops/pkgs/container/agent-ops) for available SHAs. A documentation-only merge publishes no image.

### Timing

Don't recreate the scheduler mid-cycle. Use `--disable` to wait out any in-flight cycle first:

```bash
docker compose exec scheduler /app/agent-cycle.sh --disable "rolling new image"
docker compose exec scheduler /app/agent-cycle.sh --status  # wait for cycle to finish

# Now safe to restart
docker compose up -d

docker compose exec scheduler /app/agent-cycle.sh --enable
```

If watchtower is enabled, it already does this — its pre-update hook reads the same locks and defers the roll.

## Update configuration

Configuration is either baked into the image (rebuilt with `--build-arg`) or mounted as a volume. If mounted:

1. **Edit the config file on the host:**
   ```bash
   $EDITOR /path/to/config.json
   ```

2. **Validate it:**
   ```bash
   docker compose exec scheduler /app/scripts/doctor.sh --config /path/to/config.json
   ```

3. **Apply it** (no restart needed; the scheduler reads the volume):
   ```bash
   # The change takes effect at the next cycle
   ```

If config is baked into the image, rebuild and roll:

```bash
docker build --build-arg CONFIG=/path/to/config.json -t agent-ops:local deploy/docker
docker compose up -d
```

## Change the node's role

Promote a standby node to active, or demote an active node to standby:

```bash
# Edit .env
ROLE=active    # or standby

# Apply the change (takes effect next cycle)
docker compose up -d
```

No restart needed; the role is checked at cycle start.

## Allow an extra egress domain

If a Vercel project or another service serves from a custom domain:

```bash
echo "EGRESS_EXTRA_ALLOW=preview.example.com" >> .env
docker compose up -d egress-proxy
```

For fleet-wide additions (domains multiple nodes need), add to `deploy/docker/egress-allowlist.txt` in the repository:

```
example.com  # used by custom Vercel domains
```

Then rebuild or wait for the next image to be pulled.

For multiple domains, comma- or whitespace-separate them:

```bash
echo "EGRESS_EXTRA_ALLOW=preview.example.com other-domain.com" >> .env
docker compose up -d egress-proxy
```

## Take one node out while others keep working

To pause a single node without affecting the rest of the fleet:

```bash
docker compose exec scheduler /app/agent-cycle.sh --disable "maintenance" --this-node
# ... do maintenance ...
docker compose exec scheduler /app/agent-cycle.sh --enable --this-node
```

This does not publish to the state repository; it affects only this node's local switch.

## Remove a node for good

If you no longer need a node:

1. **Check the fleet can spare it:**
   ```bash
   # Verify at least one other node is active
   gh api repos/Poetic-Poems/agent-ops-state/branches \
     | jq -r '.[] | select(.name | startswith("nodes/")) | .name'
   ```

2. **Let any in-flight cycle finish:**
   ```bash
   docker compose exec scheduler /app/agent-cycle.sh --status
   # Wait until cycle: idle and review: idle
   ```

3. **Take off anything you want to keep:**
   - State archives (logs, cycle records): `~/.local/state/poetic-agents/`
   - Configuration: `~/poetic-node/.env`, `/path/to/config.json`
   - Data volumes: checkpoint any `state_dir` contents

4. **Destroy the stack, volumes, and credentials:**
   ```bash
   docker compose down -v
   # Revoke the node's GitHub token at github.com/settings/tokens
   # Revoke the Tailscale identity (if enabled)
   ```

5. **Remove from the fleet's memory** (if state repository is configured):
   ```bash
   # The node's branch in the state repository will be pruned
   # after it hasn't published for longer than state sync retention
   # Or delete manually:
   git push origin :nodes/<node-name> -f  # force-delete the branch
   ```

6. **Delete the directory:**
   ```bash
   rm -rf ~/poetic-node
   ```

## Uninstall

To remove agent-ops entirely from a host:

1. **Stop and remove containers:**
   ```bash
   docker compose down -v
   cd ..
   rm -rf ~/poetic-node
   ```

2. **Revoke credentials** (if the node had them):
   - GitHub PAT: [github.com/settings/tokens](https://github.com/settings/tokens)
   - Anthropic API key: [claude.ai/settings](https://claude.ai/settings)
   - Tailscale (if enabled): [app.tailscale.com/admin/machines](https://app.tailscale.com/admin/machines)

3. **Remove from fleet** (if state repository is configured):
   ```bash
   # Delete the node's branch
   git push origin :nodes/<node-name> -f
   ```

4. **Archive logs** (if you want to keep them):
   ```bash
   tar czf agent-ops-logs-$(date -u +%F).tar.gz ~/.local/state/poetic-agents/
   ```

## Related pages

- [Install a node](install-a-node.md) — bringing nodes up
- [Run and pause](run-and-pause.md) — operating the switch and drain
- [Diagnose by symptom](diagnose-by-symptom.md) — troubleshooting
