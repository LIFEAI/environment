#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────────────────────
# GitHub Actions Self-Hosted Runner — Entrypoint
#
# Handles three scenarios:
#   1. First run: register with GitHub using RUNNER_TOKEN
#   2. Subsequent runs: credentials already exist in volume
#   3. Forced re-registration: FORCE_REREGISTER=true
# ──────────────────────────────────────────────────────────

RUNNER_DIR="/home/runner/actions-runner"
CRED_FILE="${RUNNER_DIR}/.credentials"

cd "${RUNNER_DIR}"

# ── Registration ──────────────────────────────────────────

if [ "${FORCE_REREGISTER:-false}" = "true" ] && [ -f "${CRED_FILE}" ]; then
    echo ">>> Force re-registration requested. Removing old credentials..."
    ./config.sh remove --token "${RUNNER_TOKEN:-dummy}" 2>/dev/null || true
    rm -f "${CRED_FILE}" ".runner"
fi

if [ ! -f "${CRED_FILE}" ]; then
    echo ">>> No credentials found — registering runner with GitHub..."

    if [ -z "${RUNNER_TOKEN:-}" ]; then
        echo "ERROR: RUNNER_TOKEN is required for first-time registration."
        echo "Get one from: https://github.com/LIFEAI/regen-root/settings/actions/runners/new"
        echo ""
        echo "NOTE: This token is ephemeral — used ONCE during registration."
        echo "After registration, the runner stores persistent credentials in the volume."
        echo "You can remove RUNNER_TOKEN from env vars after the runner appears in GitHub."
        exit 1
    fi

    ./config.sh \
        --url "${RUNNER_REPOSITORY_URL:-https://github.com/LIFEAI/regen-root}" \
        --token "${RUNNER_TOKEN}" \
        --name "${RUNNER_NAME:-coolify-runner-01}" \
        --labels "${RUNNER_LABELS:-self-hosted,linux,coolify}" \
        --work "${RUNNER_WORKDIR:-/home/runner/work}" \
        --unattended \
        --replace

    echo ">>> Registration complete. Credentials stored in volume."
    echo ">>> You can now REMOVE RUNNER_TOKEN from Coolify env vars."
    echo ">>> The runner will reconnect using stored credentials on restart."
else
    echo ">>> Credentials found — skipping registration (already registered)."
fi

# ── Graceful shutdown ─────────────────────────────────────

cleanup() {
    echo ">>> Caught signal — shutting down runner gracefully..."
    # The runner handles SIGTERM internally; just wait
    kill -TERM "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || true
    echo ">>> Runner stopped."
}

trap cleanup SIGTERM SIGINT

# ── Start the runner ──────────────────────────────────────

echo ">>> Starting GitHub Actions runner: ${RUNNER_NAME:-coolify-runner-01}"
echo ">>> Labels: ${RUNNER_LABELS:-self-hosted,linux,coolify}"
echo ">>> Node: $(node --version), pnpm: $(pnpm --version)"
echo ""

./run.sh &
RUNNER_PID=$!
wait "$RUNNER_PID"
