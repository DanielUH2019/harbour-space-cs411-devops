#!/usr/bin/env bash
#
# deploy.sh — ship the freshly built binary to the target host and (re)start it.
#
# This script runs ON THE JENKINS AGENT. It is the orchestration half of the
# deploy: it renders the systemd unit, copies the binary + unit to the target
# over SSH, then runs `remote-install.sh` ON THE TARGET to do the privileged
# installation. Keeping this logic in a real script (instead of inline in the
# Jenkinsfile) means it is shellcheck-able and you can run it by hand to debug.
#
# It expects the following environment variables, all of which the Jenkins
# pipeline exports for us:
#   TARGET_HOST     - DNS name / IP of the machine to deploy to        (param)
#   SSH_KEY         - path to the private key file   (from withCredentials)
#   SSH_USER        - SSH username                    (from withCredentials)
#   SSH_OPTIONS     - common ssh/scp flags (BatchMode, known_hosts, ...)
#   ARTIFACT        - path to the built binary on the agent
#   REMOTE_APP_DIR  - install directory on the target (e.g. /opt/myapp)
#   SERVICE_NAME    - systemd service name (e.g. myapp)
#   SERVICE_USER    - unprivileged user the service runs as
#
# `set -euo pipefail`: exit on any error (-e), treat unset variables as an
# error (-u), and fail a pipeline if ANY command in it fails (pipefail).
# Jenkins' default `sh` already runs with -xe, but being explicit makes the
# script behave identically when run by hand, and adds -u and pipefail.
set -euo pipefail

# Fail fast with a clear message if a required variable is missing.
# The `${VAR:?message}` form aborts with "message" when VAR is unset/empty.
: "${TARGET_HOST:?TARGET_HOST must be set}"
: "${SSH_KEY:?SSH_KEY must be set (provided by withCredentials)}"
: "${SSH_USER:?SSH_USER must be set (provided by withCredentials)}"
: "${SSH_OPTIONS:?SSH_OPTIONS must be set}"
: "${ARTIFACT:?ARTIFACT must be set}"
: "${REMOTE_APP_DIR:?REMOTE_APP_DIR must be set}"
: "${SERVICE_NAME:?SERVICE_NAME must be set}"
: "${SERVICE_USER:?SERVICE_USER must be set}"

# Resolve the directory this script lives in so we can find its siblings
# (the unit template and the remote installer) regardless of the caller's cwd.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UNIT_TEMPLATE="$SCRIPT_DIR/myapp.service"
REMOTE_INSTALL="$SCRIPT_DIR/remote-install.sh"

ssh_target="$SSH_USER@$TARGET_HOST"

# --- 1. Render the systemd unit on the agent -------------------------------
# We substitute the placeholders HERE (where the values live) so the target
# only ever receives a final, ready-to-install unit file.
rendered_unit="$(mktemp)"
sed \
    -e "s|@@SERVICE_USER@@|$SERVICE_USER|g" \
    -e "s|@@REMOTE_APP_DIR@@|$REMOTE_APP_DIR|g" \
    "$UNIT_TEMPLATE" > "$rendered_unit"

# --- 2. Lock down the local SSH material -----------------------------------
# SSH refuses to use a private key with loose permissions. The known_hosts
# path is workspace-relative to match UserKnownHostsFile in SSH_OPTIONS.
chmod 600 "$SSH_KEY"
mkdir -p .ssh
touch .ssh/known_hosts
chmod 700 .ssh
chmod 600 .ssh/known_hosts

# Pre-trust the target host key non-interactively. This writes to the same
# workspace-local known_hosts file referenced by SSH_OPTIONS.
echo "Pre-trusting SSH host key for $TARGET_HOST ..."
if ! known_hosts_entry="$(ssh-keyscan -T 10 -H "$TARGET_HOST" 2>/dev/null)"; then
    echo "Could not fetch SSH host key for $TARGET_HOST" >&2
    exit 1
fi
if [ -z "$known_hosts_entry" ]; then
    echo "ssh-keyscan returned no host keys for $TARGET_HOST" >&2
    exit 1
fi
printf '%s\n' "$known_hosts_entry" >> .ssh/known_hosts

# --- 3. Create temp files on the target ------------------------------------
# We upload to neutral /tmp paths first, then install atomically on the target.
# NOTE on `# shellcheck disable=SC2086`: $SSH_OPTIONS is a list of flags that
# MUST undergo word-splitting, so we deliberately leave it unquoted. shellcheck
# warns about this by default, hence the per-line suppression.
# shellcheck disable=SC2086
remote_bin="$(ssh $SSH_OPTIONS -i "$SSH_KEY" "$ssh_target" 'mktemp /tmp/myapp-bin.XXXXXX')"
# shellcheck disable=SC2086
remote_unit="$(ssh $SSH_OPTIONS -i "$SSH_KEY" "$ssh_target" 'mktemp /tmp/myapp-unit.XXXXXX')"

# Always clean up: remove the local rendered unit and any remote temp files,
# even if a later step fails. `trap ... EXIT` runs on any exit path.
cleanup() {
    rm -f "$rendered_unit"
    # shellcheck disable=SC2086
    ssh $SSH_OPTIONS -i "$SSH_KEY" "$ssh_target" \
        "rm -f '$remote_bin' '$remote_unit'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 4. Upload the binary and rendered unit --------------------------------
# shellcheck disable=SC2086
scp $SSH_OPTIONS -i "$SSH_KEY" "$ARTIFACT" "$ssh_target:$remote_bin"
# shellcheck disable=SC2086
scp $SSH_OPTIONS -i "$SSH_KEY" "$rendered_unit" "$ssh_target:$remote_unit"

# --- 5. Run the privileged installer on the target -------------------------
# We stream remote-install.sh over stdin into `sh -s` so nothing needs to be
# left behind on the target. The remote paths and names are passed as env vars.
echo "Installing $SERVICE_NAME on $TARGET_HOST ..."
# shellcheck disable=SC2086
ssh $SSH_OPTIONS -i "$SSH_KEY" "$ssh_target" \
    "REMOTE_BIN='$remote_bin' REMOTE_UNIT='$remote_unit' REMOTE_APP_DIR='$REMOTE_APP_DIR' SERVICE_NAME='$SERVICE_NAME' SERVICE_USER='$SERVICE_USER' sh -s" \
    < "$REMOTE_INSTALL"

echo "Deploy of $SERVICE_NAME to $TARGET_HOST completed."
