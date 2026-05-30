#!/bin/sh
#
# remote-install.sh — install and (re)start the service ON THE TARGET host.
#
# This is the privileged half of the deploy. `deploy.sh` streams it to the
# target over SSH (`ssh ... sh -s < remote-install.sh`), so it runs there, not
# on the Jenkins agent. It must be POSIX sh — NO bash-isms — because the target
# may use dash/busybox as /bin/sh.
#
# Inputs (exported by deploy.sh through the ssh command line):
#   REMOTE_BIN      - path to the uploaded binary in /tmp
#   REMOTE_UNIT     - path to the uploaded, already-rendered systemd unit
#   REMOTE_APP_DIR  - install directory (e.g. /opt/myapp)
#   SERVICE_NAME    - systemd service name (e.g. myapp)
#   SERVICE_USER    - unprivileged system user to run the service as
#
# Privileged steps use `sudo`; the SSH user therefore needs passwordless sudo
# for these commands on the target.
set -eu

: "${REMOTE_BIN:?}"
: "${REMOTE_UNIT:?}"
: "${REMOTE_APP_DIR:?}"
: "${SERVICE_NAME:?}"
: "${SERVICE_USER:?}"

# --- 1. Ensure the install directory exists --------------------------------
sudo install -d -m 0755 -o root -g root "$REMOTE_APP_DIR"

# --- 2. Ensure the unprivileged service user exists ------------------------
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    # Prefer a real nologin shell; fall back to /bin/false if unavailable.
    nologin_shell=/usr/sbin/nologin
    [ -x "$nologin_shell" ] || nologin_shell=/bin/false
    sudo useradd --system --home-dir "$REMOTE_APP_DIR" --shell "$nologin_shell" "$SERVICE_USER"
fi

# Safety net: never run the service as root, even if the name resolves to uid 0.
if [ "$(id -u "$SERVICE_USER")" -eq 0 ]; then
    echo "$SERVICE_USER must not resolve to uid 0" >&2
    exit 1
fi

# --- 3. Atomically swap in the new binary ----------------------------------
# Install to a temp name with correct mode/owner, then rename over the live
# binary. `mv` within the same filesystem is atomic, so there is no moment
# where the service points at a half-written file.
sudo install -m 0755 -o root -g root "$REMOTE_BIN" "$REMOTE_APP_DIR/main.new"
sudo mv -f "$REMOTE_APP_DIR/main.new" "$REMOTE_APP_DIR/main"
rm -f "$REMOTE_BIN"

# --- 4. Install the systemd unit -------------------------------------------
sudo install -m 0644 -o root -g root "$REMOTE_UNIT" "/etc/systemd/system/$SERVICE_NAME.service"
rm -f "$REMOTE_UNIT"

# --- 5. One-time migration: retire the legacy hello-go.service -------------
# Older deploys created a unit named hello-go.service. If it is still present,
# disable and stop it so it cannot clash with the current service. This block
# is safe to remove once no target still has the legacy unit.
if systemctl list-unit-files --no-legend hello-go.service 2>/dev/null | grep -q '^hello-go.service'; then
    sudo systemctl disable --now hello-go.service || true
fi

# --- 6. Reload systemd and (re)start the service ---------------------------
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

echo "Installed and restarted $SERVICE_NAME"
