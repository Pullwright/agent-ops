# Diagnose by symptom

When something unexpected happens, start here. Each symptom lists its possible causes, the check that tells them apart, and the fix.

## No cycles are running

**Causes:**
1. The disable switch is set (operator paused the pipeline)
2. The account hit a usage limit
3. The node is not `ROLE=active`
4. Configuration is invalid
5. Credentials are missing or expired

**Check:**
```bash
docker compose exec scheduler /app/agent-cycle.sh --status
```

If output shows `switch: DISABLED` or `limit: STANDING DOWN`, those are the causes. If the cycle and review are both `idle` and there's no message, check the next items.

**Fixes:**

- **Switch is disabled:** `docker compose exec scheduler /app/agent-cycle.sh --enable`
- **Usage limit hit:** See [Lifting a usage-limit stand-down](run-and-pause.md#lifting-a-usage-limit-stand-down)
- **Node is standby:** Set `ROLE=active` in `.env`, then `docker compose up -d`
- **Configuration invalid:** `docker compose exec scheduler /app/scripts/doctor.sh` lists what is wrong
- **Credentials missing:** `doctor.sh` also checks model and GitHub access

## Cycles run but select nothing

**Causes:**
1. No work exists (repositories are empty or quiet)
2. Configuration has no repositories or they are unreachable
3. All items are blocked or void (awaiting dependencies or already done)
4. The fingerprint shows nothing changed (no-op short-circuit)

**Check:**
```bash
docker compose exec scheduler /app/agent-cycle.sh --dry-run
```

The output shows what the Coordinator sees: which repositories, which issues, and what it selected (or why it selected nothing). Also check the log:

```bash
jq -r 'select(.event == "stand-down") | "\(.ts)  \(.reason)"' \
  ~/.local/state/poetic-agents/log.jsonl | tail -3
```

**Fixes:**

- **No work:** That's fine — the pipeline idles. Watch the dashboard to see if new issues appear.
- **Configuration has no repos:** Add repositories to `config.json` and get the change merged and rolled onto the node — see [Configuration reaches a node](configure.md#configuration-reaches-a-node)
- **All items blocked:** See [An item is blocked or void](#an-item-is-blocked-or-void) — most blocks clear themselves once the blocker resolves
- **No-op stand-down:** Nothing is wrong. The next cycle with actual changes will run.

## A pull request will not land

**Causes:**
1. A required review is still outstanding (human reviewer hasn't approved)
2. A CI check is failing
3. The pull request is in draft
4. The pull request was dequeued from the merge queue
5. A required comment on the PR hasn't been reconciled

**Check:**
```bash
gh pr view <number> --json state,reviewDecision,mergeStateStatus,isDraft
```

**Fixes:**

- **Review pending:** Wait for the reviewer, or post feedback on the PR for the pipeline to react to
- **CI failing:** Check the workflow run for the error; the pipeline will fix transient failures or re-run the item
- **Draft pull request:** Set `ROLE=active` on a node with the pipeline enabled; the Reviewer flips it to ready
- **Dequeued:** The pipeline diagnosed why and fixed it; re-queue with "Merge when ready"
- **Unreconciled comment:** The pipeline needs to answer a comment. Check for comments with `needs-reconciliation` or a structured `<!-- agent-ops:reconciles comment=… -->` marker

## An item is blocked or void

**Causes (blocked):**
- A dependency hasn't landed yet
- Configuration or credentials are wrong
- The item was under-specified (no acceptance criteria)
- Something only you can decide is in the way

**Causes (void):**
- The work is already done
- The item was a duplicate
- The premise turned out to be false

**Check:**
```bash
# See all blocked items
gh issue list -R <repo> --label blocked

# See void items on the dashboard or in the log
jq -r 'select(.event == "item-void") | "\(.ts)  \(.repo)#\(.item)  \(.detail)"' \
  ~/.local/state/poetic-agents/log.jsonl | tail -5
```

**Fixes (blocked):**

- **Dependency:** The pipeline re-checks automatically. Once the dependency resolves, the item unblocks.
- **Under-specified:** The Enabler will write a specification or ask you. Answer on the escalation issue it files, then close it.
- **Your decision needed:** An `enabler-escalation` issue names what you need to decide. Answer there and close the issue.

**Fixes (void):**

- **Already done:** The item is closed automatically once the merged PR or closed issue settles into the void list.
- **Re-open if it's wrong:** Add the `unvoided` label to the issue or PR, and the next cycle will reconsider it.

## A stage was stopped

**Causes:**
1. The stage hit its time budget (backstop timeout)
2. The stage produced no output for its inactivity window
3. The account hit a usage limit mid-stage
4. An error caused it to exit

**Check:**
```bash
# See recent stage completions
jq -r 'select(.event == "stage-end") | "\(.ts)  \(.stage)  \(.kill_reason // "completed")  \(.duration_ms // "?")ms"' \
  ~/.local/state/poetic-agents/log.jsonl | tail -10

# Read the stage's transcript
ls ~/.local/state/poetic-agents/cycles/<cycle-id>/
cat ~/.local/state/poetic-agents/cycles/<cycle-id>/implementer.stream.jsonl
```

**Fixes:**

- **Timeout:** A timeout that stays long suggests a cap too tight for the real work. The timeouts self-tune from history — `doctor.sh` shows the current table.
- **Inactivity timeout:** The stage stopped producing output. Read the `.stream.jsonl` to see what it was doing last.
- **Usage limit:** Not a fault — wait for the cap to reset or raise it.
- **Error:** The stream shows what went wrong. Re-run the cycle or check the error in more detail.

## A node is on an old image

**Cause:**
The node hasn't pulled a new image since one was built.

**Check:**
```bash
# On the node's host, from the stack directory — compares against the
# newest published build and reports how far behind this node is
curl -fsSLO https://raw.githubusercontent.com/Pullwright/agent-ops/main/scripts/check-node-image.sh
chmod +x check-node-image.sh
./check-node-image.sh

# Or read the stamp this node's image was built with directly
docker compose exec scheduler cat /app/build-info.json | jq .

# On the dashboard
# The node card shows "behind" if it's older than the latest published build
```

**Fixes:**

1. **If watchtower is enabled** (the `auto-update` profile), it pulls and restarts automatically. Wait a few hours, then check again.

2. **To roll manually:**
   ```bash
   docker compose pull
   docker compose up -d
   ```

3. **To pin to a specific build:**
   ```bash
   echo "AGENT_OPS_IMAGE=ghcr.io/pullwright/agent-ops:<sha>" >> .env
   docker compose up -d
   ```

## Checking an installation

Run `doctor.sh` to verify the whole installation:

```bash
docker compose exec scheduler /app/scripts/doctor.sh
```

This checks:
- Configuration matches the schema
- Repositories are readable and writable
- GitHub token has needed scopes
- Model credentials are set
- The container's own rendered crontab (`deploy/docker/crontab.tmpl` via `render-crontab.sh`) is valid
- Prompts and overrides exist
- Egress fence is working

Run it after editing `config.json`, on a new node before its first cycle, and whenever a cycle behaves unexpectedly.

## Reading stage transcripts

When a stage fails or times out, read its transcript:

```bash
ls ~/.local/state/poetic-agents/cycles/
cat ~/.local/state/poetic-agents/cycles/<cycle-id>/<stage>.stream.jsonl
```

The stream shows every event the stage emitted, one JSON object per line, written as it happened. Read it when a stage timed out (the envelope shows only the completion, not how far it got).

## Related pages

- [Run and pause](run-and-pause.md) — control cycles and the disable switch
- [Watch](watch.md) — monitor dashboards and logs
- [Change a node](change-a-node.md) — update or remove nodes
