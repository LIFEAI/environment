# GitHub Actions Self-Hosted Runner — Coolify

Runs CI builds for `LIFEAI/regen-root` on the Coolify server (64.237.54.189) as a Docker container. Eliminates GitHub Actions billing — the server is already provisioned and paid for.

## Architecture

```
GitHub (push/PR) ──> GitHub Actions ──> Self-Hosted Runner (Coolify)
                                              |
                                              ├── Node 20
                                              ├── pnpm (corepack)
                                              ├── Persistent credentials (volume)
                                              └── pnpm store cache (volume)
```

The runner is a Docker container managed by Coolify. It connects to GitHub over HTTPS (outbound only — no inbound ports needed).

## Setup — Step by Step

### Step 1: Get a Registration Token

1. Go to https://github.com/LIFEAI/regen-root/settings/actions/runners/new
2. Select **Linux** and **x64**
3. Copy the token from the `./config.sh --token AXXXX...` command
4. This token is **ephemeral** — it expires in ~1 hour and is used only once

### Step 2: Run the Setup Script

```bash
export RUNNER_TOKEN="AXXXX..."
bash infra/github-runner/setup.sh
```

This script:
- Creates a docker-compose app on Coolify via API
- Sets RUNNER_TOKEN and other env vars
- Configures watch paths (`infra/github-runner/**`)
- Triggers the first deploy

### Step 3: Verify Registration

1. Wait 2-3 minutes for the container to build and start
2. Check https://github.com/LIFEAI/regen-root/settings/actions/runners
3. The runner should appear as `coolify-runner-01` with status **Idle**

### Step 4: Remove the Registration Token

**After the runner appears in GitHub**, remove `RUNNER_TOKEN` from Coolify env vars. It was used once during registration. The runner now stores persistent credentials in the `runner-credentials` Docker volume. It will reconnect automatically on container restarts without needing a token.

### Step 5: Update CI Workflow

In `.github/workflows/ci.yml`, change:

```yaml
# Before
runs-on: ubuntu-latest

# After
runs-on: [self-hosted, coolify]
```

## How RUNNER_TOKEN Works

This is the most common point of confusion:

1. **Registration token** — Ephemeral, from GitHub Settings, expires in ~1 hour
2. You provide it as `RUNNER_TOKEN` env var for the **first deploy only**
3. The `entrypoint.sh` script calls `./config.sh --token AXXXX...` to register
4. GitHub returns **persistent credentials** stored in `/home/runner/actions-runner/.credentials`
5. These credentials are persisted in the `runner-credentials` Docker volume
6. On subsequent container restarts, the runner reconnects using stored credentials
7. **You do not need RUNNER_TOKEN again** unless you remove the runner from GitHub and re-register

```
First deploy:  RUNNER_TOKEN ──> config.sh ──> .credentials (stored in volume)
All restarts:  .credentials (from volume) ──> run.sh ──> connected
```

## Volumes

| Volume | Purpose | Persist? |
|--------|---------|----------|
| `runner-credentials` | Runner auth after registration | YES — never delete |
| `runner-work` | Build workspace (`_work/` dir) | Ephemeral — can be wiped |
| `pnpm-store` | pnpm content-addressable store | Cache — speeds up installs |

## Resource Limits

| Resource | Limit | Reservation |
|----------|-------|-------------|
| Memory | 4 GB | 1 GB |
| CPU | 2 cores | 0.5 cores |

These limits prevent CI builds from starving other Coolify apps on the same server.

## Re-registration

If you need to re-register (e.g., after removing the runner from GitHub):

1. Get a fresh registration token from GitHub
2. In Coolify, set:
   - `RUNNER_TOKEN=AXXXX...` (fresh token)
   - `FORCE_REREGISTER=true`
3. Redeploy the app
4. After the runner appears in GitHub, set `FORCE_REREGISTER=false` and remove `RUNNER_TOKEN`

## Troubleshooting

### Runner not appearing in GitHub
- Check Coolify runtime logs: `application_logs(uuid, lines=100)`
- Verify `RUNNER_TOKEN` was set before the first deploy
- Ensure the token hasn't expired (they last ~1 hour)

### Runner shows "Offline" in GitHub
- The container may have restarted and lost its credentials volume
- Check if `runner-credentials` volume exists: `docker volume ls | grep github-runner`
- If volume is gone, re-register (see above)

### Builds fail with "pnpm: not found"
- The custom Dockerfile installs pnpm via corepack
- Verify with: check Coolify build logs for the Dockerfile build step
- If using `myoung34/github-runner` base image instead, add a setup-pnpm action step in the workflow

### Out of memory during build
- Current limit: 4 GB. Monorepo builds with Turbo can be memory-hungry.
- Increase in `docker-compose.yml` under `deploy.resources.limits.memory`
- Also bump `NODE_OPTIONS=--max-old-space-size=XXXX` env var accordingly

## Files

```
infra/github-runner/
  docker-compose.yml   — Coolify deployment config
  Dockerfile           — Custom image: Ubuntu 22.04 + Node 20 + pnpm + runner binary
  entrypoint.sh        — Handles registration vs. reconnection logic
  setup.sh             — One-shot Coolify app creation script
  README.md            — This file
```
