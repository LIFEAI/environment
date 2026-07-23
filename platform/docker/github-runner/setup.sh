#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────────────────────
# GitHub Actions Self-Hosted Runner — Coolify Setup Script
#
# Creates the runner as a docker-compose app on Coolify,
# sets env vars, and deploys.
#
# Prerequisites:
#   - clauth daemon running (http://127.0.0.1:52437)
#   - RUNNER_TOKEN from GitHub (see Step 1 below)
#   - jq installed
#
# Usage:
#   export RUNNER_TOKEN="AXXXX..."  # from GitHub Settings
#   bash infra/github-runner/setup.sh
# ──────────────────────────────────────────────────────────

echo "=== GitHub Actions Self-Hosted Runner — Setup ==="
echo ""

# ── Validate prerequisites ────────────────────────────────

if [ -z "${RUNNER_TOKEN:-}" ]; then
    echo "ERROR: RUNNER_TOKEN is not set."
    echo ""
    echo "Step 1: Go to https://github.com/LIFEAI/regen-root/settings/actions/runners/new"
    echo "Step 2: Select 'Linux' and 'x64'"
    echo "Step 3: Copy the token from the './config.sh --token AXXXX...' command"
    echo "Step 4: Run: export RUNNER_TOKEN=\"AXXXX...\""
    echo "Step 5: Re-run this script"
    echo ""
    echo "NOTE: The token is ephemeral (expires in ~1 hour)."
    echo "      It is used ONCE for registration, then discarded."
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required. Install with: apt install jq / brew install jq"
    exit 1
fi

# ── Get Coolify API token ─────────────────────────────────

echo ">>> Fetching Coolify API token from clauth daemon..."
COOLIFY_TOKEN=$(curl -sf http://127.0.0.1:52437/get/coolify-api | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])" 2>/dev/null)

if [ -z "${COOLIFY_TOKEN}" ]; then
    echo "ERROR: Could not fetch Coolify token from clauth daemon."
    echo "Ensure clauth is running: curl -s http://127.0.0.1:52437/ping"
    exit 1
fi

COOLIFY_API="https://deploy.regendevcorp.com/api/v1"
SERVER_UUID="ih386anenvvvn6fy1umtyow0"
GITHUB_APP_UUID="xdmcy60putp5h9j7k4kwg9c3"

# Use the Infra project or create under an existing one
# Using the Place Fund project environment for infrastructure
PROJECT_UUID="m19b6r4mk6a18qd74bgxgyj6"

echo ">>> Coolify API token acquired."
echo ""

# ── Create the app on Coolify ─────────────────────────────

echo ">>> Creating docker-compose app on Coolify..."

CREATE_RESPONSE=$(curl -sf -X POST \
    -H "Authorization: Bearer ${COOLIFY_TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d "{
        \"project_uuid\": \"${PROJECT_UUID}\",
        \"server_uuid\": \"${SERVER_UUID}\",
        \"github_app_uuid\": \"${GITHUB_APP_UUID}\",
        \"git_repository\": \"LIFEAI/regen-root\",
        \"git_branch\": \"main\",
        \"build_pack\": \"dockercompose\",
        \"name\": \"github-runner\",
        \"base_directory\": \"/infra/github-runner\",
        \"docker_compose_location\": \"/infra/github-runner/docker-compose.yml\",
        \"ports_exposes\": \"0\"
    }" \
    "${COOLIFY_API}/applications/private-github-app")

APP_UUID=$(echo "${CREATE_RESPONSE}" | jq -r '.uuid // empty')

if [ -z "${APP_UUID}" ]; then
    echo "ERROR: Failed to create app. Response:"
    echo "${CREATE_RESPONSE}" | jq . 2>/dev/null || echo "${CREATE_RESPONSE}"
    echo ""
    echo "If the app already exists, find its UUID with:"
    echo "  curl -s -H 'Authorization: Bearer \$COOLIFY_TOKEN' ${COOLIFY_API}/applications | jq '.[] | select(.name==\"github-runner\")'"
    exit 1
fi

echo ">>> App created: UUID = ${APP_UUID}"
echo ""

# ── Set environment variables ─────────────────────────────

echo ">>> Setting environment variables..."

set_env() {
    local key="$1"
    local value="$2"
    local is_preview="${3:-false}"

    curl -sf -X POST \
        -H "Authorization: Bearer ${COOLIFY_TOKEN}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "{
            \"key\": \"${key}\",
            \"value\": \"${value}\",
            \"is_preview\": ${is_preview}
        }" \
        "${COOLIFY_API}/applications/${APP_UUID}/envs" > /dev/null
    echo "  Set: ${key}"
}

set_env "RUNNER_TOKEN"    "${RUNNER_TOKEN}"
set_env "RUNNER_NAME"     "coolify-runner-01"
set_env "FORCE_REREGISTER" "false"

echo ""

# ── Set watch paths (only rebuild on infra/github-runner changes) ──

echo ">>> Setting watch paths..."

curl -sf -X PATCH \
    -H "Authorization: Bearer ${COOLIFY_TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d '{"watch_paths":"infra/github-runner/**"}' \
    "${COOLIFY_API}/applications/${APP_UUID}" > /dev/null

echo "  Watch paths: infra/github-runner/**"
echo ""

# ── Deploy ────────────────────────────────────────────────

echo ">>> Deploying..."

DEPLOY_RESPONSE=$(curl -sf -X GET \
    -H "Authorization: Bearer ${COOLIFY_TOKEN}" \
    -H "Accept: application/json" \
    "${COOLIFY_API}/applications/${APP_UUID}/start")

echo ">>> Deploy triggered."
echo ""

# ── Summary ───────────────────────────────────────────────

echo "================================================================"
echo "  GitHub Actions Self-Hosted Runner — Setup Complete"
echo "================================================================"
echo ""
echo "  Coolify App UUID:  ${APP_UUID}"
echo "  Runner Name:       coolify-runner-01"
echo "  Labels:            self-hosted, linux, coolify"
echo "  Server:            64.237.54.189"
echo ""
echo "  NEXT STEPS:"
echo ""
echo "  1. Wait 2-3 minutes for the container to build and start."
echo ""
echo "  2. Verify the runner appears in GitHub:"
echo "     https://github.com/LIFEAI/regen-root/settings/actions/runners"
echo ""
echo "  3. IMPORTANT: After the runner appears as 'Idle' in GitHub,"
echo "     REMOVE the RUNNER_TOKEN env var from Coolify."
echo "     It was used once for registration and is no longer needed."
echo "     The runner stores persistent credentials in a Docker volume."
echo ""
echo "  4. Update .github/workflows/ci.yml to use:"
echo "     runs-on: [self-hosted, coolify]"
echo ""
echo "  5. Update CLAUDE.md coolify deployment registry with UUID: ${APP_UUID}"
echo ""
echo "================================================================"
