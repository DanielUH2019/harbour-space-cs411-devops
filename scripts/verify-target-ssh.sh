#!/usr/bin/env bash
#
# verify-target-ssh.sh - verify the same SSH access Jenkins needs before
# running the pipeline.
#
# Required environment variables:
#   TARGET_HOST       - target machine DNS name or IP address
#   TARGET_USER       - SSH username stored in Jenkins credentials
#   PRIVATE_KEY_FILE  - private key file that will be pasted into Jenkins
#
# Optional environment variables:
#   SSH_PORT          - SSH port, default: 22
#   SSH_OPTIONS       - extra ssh options
set -euo pipefail

: "${TARGET_HOST:?TARGET_HOST must be set}"
: "${TARGET_USER:?TARGET_USER must be set}"
: "${PRIVATE_KEY_FILE:?PRIVATE_KEY_FILE must be set}"

SSH_PORT="${SSH_PORT:-22}"
SSH_OPTIONS="${SSH_OPTIONS:-}"

if [ ! -r "$PRIVATE_KEY_FILE" ]; then
    echo "Cannot read PRIVATE_KEY_FILE: $PRIVATE_KEY_FILE" >&2
    exit 1
fi

chmod 600 "$PRIVATE_KEY_FILE"

remote="$TARGET_USER@$TARGET_HOST"

echo "Verifying SSH access to $remote ..."
# shellcheck disable=SC2086
ssh -p "$SSH_PORT" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    $SSH_OPTIONS \
    -i "$PRIVATE_KEY_FILE" \
    "$remote" \
    'sudo -n true && command -v systemctl >/dev/null && echo "SSH, sudo, and systemd are ready."'
