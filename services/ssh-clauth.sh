#!/usr/bin/env bash
# ssh-clauth.sh — SSH into Vultr via clauth-held key + ssh-agent
# Usage:
#   scripts/ssh-clauth.sh                         # interactive shell
#   scripts/ssh-clauth.sh "pm2 list --no-color"   # run a command
#   scripts/ssh-clauth.sh "pm2 list" user@host    # custom target

set -euo pipefail

SERVICE="${SSH_CLAUTH_SERVICE:-vultr-dev-ssh}"
TARGET="${2:-root@64.237.54.189}"
COMMAND="${1:-}"

# Fetch key from clauth daemon. Strip CR — the stored value carries CRLF line
# endings, which OpenSSH rejects as "invalid format" (Windows) / "libcrypto:
# unsupported" (Git's ssh). Normalize to LF or every connect fails.
KEY=$(curl -sf http://127.0.0.1:52437/v/"$SERVICE" | tr -d '\r') || {
  echo "BLOCKED: clauth daemon not reachable or key '$SERVICE' missing" >&2
  exit 1
}

# Load into ssh-agent via process substitution (key never touches disk)
ssh-add - <<< "$KEY" 2>/dev/null || {
  echo "WARN: ssh-add stdin failed, trying temp file" >&2
  TMPKEY=$(mktemp)
  trap 'rm -f "$TMPKEY"' EXIT
  printf '%s\n' "$KEY" > "$TMPKEY"
  chmod 600 "$TMPKEY"
  ssh-add "$TMPKEY" 2>/dev/null
}

# Run SSH
if [ -n "$COMMAND" ]; then
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$TARGET" "$COMMAND"
else
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$TARGET"
fi
EXIT=$?

# Cleanup agent
ssh-add -D 2>/dev/null || true

exit $EXIT
