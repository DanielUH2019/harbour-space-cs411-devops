#!/usr/bin/env bash
#
# bootstrap-target-ssh.sh - install Jenkins' public key on the target host and
# grant the SSH user passwordless sudo for the challenge deploy.
#
# Required environment variables:
#   TARGET_HOST      - target machine DNS name or IP address
#   TARGET_USER      - user Jenkins should SSH as
#   PUBLIC_KEY_FILE  - path to Jenkins' public key file
#
# Optional environment variables:
#   ADMIN_USER       - initial SSH user used to bootstrap the target
#                      default: TARGET_USER
#   SSH_PORT         - SSH port
#                      default: 22
#   SSH_OPTIONS      - extra ssh options
#   SUDOERS_FILE     - sudoers drop-in path
#                      default: /etc/sudoers.d/jenkins-deploy-<TARGET_USER>
#
# The initial ADMIN_USER must already be able to SSH to the target and run sudo.
set -euo pipefail

: "${TARGET_HOST:?TARGET_HOST must be set}"
: "${TARGET_USER:?TARGET_USER must be set}"
: "${PUBLIC_KEY_FILE:?PUBLIC_KEY_FILE must be set}"

ADMIN_USER="${ADMIN_USER:-$TARGET_USER}"
SSH_PORT="${SSH_PORT:-22}"
SSH_OPTIONS="${SSH_OPTIONS:-}"
SUDOERS_FILE="${SUDOERS_FILE:-/etc/sudoers.d/jenkins-deploy-$TARGET_USER}"

case "$TARGET_USER" in
    *[!a-zA-Z0-9_.-]* | "" )
        echo "TARGET_USER contains unsupported characters: $TARGET_USER" >&2
        exit 1
        ;;
esac

case "$SUDOERS_FILE" in
    /etc/sudoers.d/*) ;;
    *)
        echo "SUDOERS_FILE must be under /etc/sudoers.d" >&2
        exit 1
        ;;
esac

if [ ! -r "$PUBLIC_KEY_FILE" ]; then
    echo "Cannot read PUBLIC_KEY_FILE: $PUBLIC_KEY_FILE" >&2
    exit 1
fi

public_key="$(sed -n '1p' "$PUBLIC_KEY_FILE")"
if [ -z "$public_key" ]; then
    echo "PUBLIC_KEY_FILE is empty: $PUBLIC_KEY_FILE" >&2
    exit 1
fi

remote="$ADMIN_USER@$TARGET_HOST"

echo "Bootstrapping $TARGET_USER on $TARGET_HOST via $remote ..."
# shellcheck disable=SC2086
ssh -p "$SSH_PORT" $SSH_OPTIONS "$remote" sh -s -- "$TARGET_USER" "$public_key" "$SUDOERS_FILE" <<'REMOTE'
set -eu

target_user=$1
public_key=$2
sudoers_file=$3

if ! id "$target_user" >/dev/null 2>&1; then
    sudo useradd --create-home --shell /bin/bash "$target_user"
fi

home_dir=$(getent passwd "$target_user" | awk -F: '{print $6}')
if [ -z "$home_dir" ]; then
    echo "Could not determine home directory for $target_user" >&2
    exit 1
fi

ssh_dir="$home_dir/.ssh"
authorized_keys="$ssh_dir/authorized_keys"
tmp_keys=$(mktemp)
tmp_sudoers=
cleanup() {
    rm -f "$tmp_keys"
    if [ -n "$tmp_sudoers" ]; then
        rm -f "$tmp_sudoers"
    fi
}
trap cleanup EXIT

sudo install -d -m 0700 -o "$target_user" -g "$target_user" "$ssh_dir"

if sudo test -f "$authorized_keys"; then
    sudo cat "$authorized_keys" > "$tmp_keys"
fi

if ! grep -qxF "$public_key" "$tmp_keys"; then
    printf '%s\n' "$public_key" >> "$tmp_keys"
fi

sudo install -m 0600 -o "$target_user" -g "$target_user" "$tmp_keys" "$authorized_keys"

tmp_sudoers=$(mktemp)
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$target_user" > "$tmp_sudoers"
sudo install -m 0440 -o root -g root "$tmp_sudoers" "$sudoers_file"
sudo visudo -cf "$sudoers_file" >/dev/null

echo "Installed SSH key and passwordless sudo for $target_user"
REMOTE

echo "Done. Verify with:"
echo "  TARGET_HOST=\"$TARGET_HOST\" TARGET_USER=\"$TARGET_USER\" PRIVATE_KEY_FILE=<private-key-path> bash scripts/verify-target-ssh.sh"
