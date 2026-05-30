#!/usr/bin/env bash
#
# setup-target-local-jenkins-ssh.sh - run this ON THE TARGET host when you have
# a shell there already. It creates the Jenkins deploy key, installs the matching
# public key for the target SSH user, grants passwordless sudo, and optionally
# verifies SSH login back into this host.
#
# Optional environment variables:
#   TARGET_USER     - user Jenkins should SSH as
#                     default: current user
#   KEY_PATH        - private key path to create/use
#                     default: $HOME/.ssh/jenkins-deploy-key
#   TARGET_HOST     - host/IP to verify with ssh
#                     default: skip SSH verification
#   SSH_PORT        - SSH port
#                     default: 22
#   CREDENTIAL_ID   - Jenkins credential ID to print in the final instructions
#                     default: target-ssh-key
set -euo pipefail

TARGET_USER="${TARGET_USER:-$USER}"
KEY_PATH="${KEY_PATH:-$HOME/.ssh/jenkins-deploy-key}"
TARGET_HOST="${TARGET_HOST:-}"
SSH_PORT="${SSH_PORT:-22}"
CREDENTIAL_ID="${CREDENTIAL_ID:-target-ssh-key}"

case "$TARGET_USER" in
    *[!a-zA-Z0-9_.-]* | "" )
        echo "TARGET_USER contains unsupported characters: $TARGET_USER" >&2
        exit 1
        ;;
esac

mkdir -p "$(dirname "$KEY_PATH")"
chmod 700 "$(dirname "$KEY_PATH")"

if [ ! -f "$KEY_PATH" ]; then
    ssh-keygen -t ed25519 -C "jenkins-deploy" -f "$KEY_PATH" -N ""
fi

if [ ! -f "$KEY_PATH.pub" ]; then
    ssh-keygen -y -f "$KEY_PATH" > "$KEY_PATH.pub"
fi

chmod 600 "$KEY_PATH"
chmod 644 "$KEY_PATH.pub"

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    sudo useradd --create-home --shell /bin/bash "$TARGET_USER"
fi

target_home="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')"
if [ -z "$target_home" ]; then
    echo "Could not determine home directory for $TARGET_USER" >&2
    exit 1
fi

public_key="$(cat "$KEY_PATH.pub")"
ssh_dir="$target_home/.ssh"
authorized_keys="$ssh_dir/authorized_keys"
tmp_keys="$(mktemp)"
tmp_sudoers="$(mktemp)"
cleanup() {
    rm -f "$tmp_keys" "$tmp_sudoers"
}
trap cleanup EXIT

sudo install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_USER" "$ssh_dir"

if sudo test -f "$authorized_keys"; then
    sudo cat "$authorized_keys" > "$tmp_keys"
fi

if ! grep -qxF "$public_key" "$tmp_keys"; then
    printf '%s\n' "$public_key" >> "$tmp_keys"
fi

# Use install instead of appending directly so iximiuz's pre-baked 0400
# authorized_keys file is corrected to the SSH-required 0600 mode.
sudo install -m 0600 -o "$TARGET_USER" -g "$TARGET_USER" "$tmp_keys" "$authorized_keys"

printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$TARGET_USER" > "$tmp_sudoers"
sudo install -m 0440 -o root -g root "$tmp_sudoers" "/etc/sudoers.d/jenkins-deploy-$TARGET_USER"
sudo visudo -cf "/etc/sudoers.d/jenkins-deploy-$TARGET_USER" >/dev/null

if [ -n "$TARGET_HOST" ]; then
    echo "Verifying SSH login to $TARGET_USER@$TARGET_HOST ..."
    ssh -p "$SSH_PORT" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        -i "$KEY_PATH" \
        "$TARGET_USER@$TARGET_HOST" \
        'sudo -n true && echo "SSH key and passwordless sudo verified."'
fi

cat <<EOF

Target SSH user:
  $TARGET_USER

Jenkins credential:
  Kind: SSH Username with private key
  ID: $CREDENTIAL_ID
  Username: $TARGET_USER

Paste this PRIVATE key into Jenkins:
------------------------------------------------
$(cat "$KEY_PATH")
------------------------------------------------

Run Jenkins with:
  TARGET_HOST=${TARGET_HOST:-<target-ip-or-dns>}
  SSH_CREDENTIALS_ID=$CREDENTIAL_ID
EOF
