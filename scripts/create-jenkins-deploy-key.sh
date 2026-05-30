#!/usr/bin/env bash
#
# create-jenkins-deploy-key.sh - create the SSH key pair Jenkins will use to
# connect to the deployment target.
#
# Optional environment variables:
#   KEY_PATH     - private key path to create
#                  default: $HOME/.ssh/jenkins-deploy-key
#   KEY_COMMENT  - SSH key comment
#                  default: jenkins-deploy
#   PASSPHRASE   - key passphrase
#                  default: empty, suitable for non-interactive Jenkins use
set -euo pipefail

KEY_PATH="${KEY_PATH:-$HOME/.ssh/jenkins-deploy-key}"
KEY_COMMENT="${KEY_COMMENT:-jenkins-deploy}"
PASSPHRASE="${PASSPHRASE:-}"

if [ -e "$KEY_PATH" ] || [ -e "$KEY_PATH.pub" ]; then
    echo "Refusing to overwrite existing key material: $KEY_PATH" >&2
    exit 1
fi

mkdir -p "$(dirname "$KEY_PATH")"
chmod 700 "$(dirname "$KEY_PATH")"

ssh-keygen -t ed25519 -C "$KEY_COMMENT" -f "$KEY_PATH" -N "$PASSPHRASE"
chmod 600 "$KEY_PATH"
chmod 644 "$KEY_PATH.pub"

cat <<EOF
Created:
  Private key: $KEY_PATH
  Public key:  $KEY_PATH.pub

Next:
  1. Add the public key to the target host:
     PUBLIC_KEY_FILE="$KEY_PATH.pub" TARGET_HOST=<target-ip-or-dns> TARGET_USER=<ssh-user> bash scripts/bootstrap-target-ssh.sh

  2. Add the private key to Jenkins:
     Manage Jenkins -> Credentials -> System -> Global credentials -> Add Credentials
     Kind: SSH Username with private key
     ID: target-ssh-key
     Username: <ssh-user>
     Private Key: paste the contents of $KEY_PATH
EOF
