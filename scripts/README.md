# Deploy scripts

These scripts back the Jenkins pipeline in [`../Jenkinsfile`](../Jenkinsfile).
The Jenkinsfile only *orchestrates* — the real deploy logic lives here so it can
be read, linted with `shellcheck`, and run by hand when debugging.

## Files

| File | Runs on | Purpose |
|------|---------|---------|
| `setup-target-local-jenkins-ssh.sh` | Target host | One-command target-local setup when you already have a shell on the target. |
| `deploy.sh` | Jenkins agent | Render the unit, copy binary + unit to the target over SSH, invoke `remote-install.sh` there. |
| `remote-install.sh` | Target host | Privileged install: create the service user, atomically swap the binary, install the systemd unit, restart the service. |
| `myapp.service` | — | systemd unit **template** with `@@PLACEHOLDERS@@`; rendered by `deploy.sh`. |
| `health-check.sh` | Jenkins agent | Poll the service's HTTP endpoint until it answers correctly. |

## How a deploy flows

```
Jenkins agent                                   Target host
-------------                                   -----------
deploy.sh
  render myapp.service (sed)
  scp binary  ───────────────────────────────▶  /tmp/myapp-bin.XXXX
  scp unit    ───────────────────────────────▶  /tmp/myapp-unit.XXXX
  ssh ... sh -s < remote-install.sh  ─────────▶  remote-install.sh
                                                   useradd (if needed)
                                                   install binary -> /opt/myapp/main (atomic)
                                                   install unit    -> /etc/systemd/system/myapp.service
                                                   systemctl daemon-reload / enable / restart
health-check.sh
  curl http://TARGET:4444/  (retry loop)
```

## Configuration

All inputs arrive as **environment variables** exported by the pipeline
(`ARTIFACT`, `APP_PORT`, `REMOTE_APP_DIR`, `SERVICE_NAME`, `SERVICE_USER`,
`SSH_OPTIONS`, plus `SSH_KEY`/`SSH_USER` from Jenkins credentials and
`TARGET_HOST` from the build parameter). Each script documents the exact set it
needs in its header comment and fails fast (`${VAR:?}`) if one is missing.

## SSH setup for Jenkins

If you already have a shell on the target host, use the target-local helper:

```bash
TARGET_USER=laborant \
TARGET_HOST=172.16.0.3 \
bash scripts/setup-target-local-jenkins-ssh.sh
```

It creates or reuses `$HOME/.ssh/jenkins-deploy-key`, installs the matching
public key into the target user's `authorized_keys`, fixes the iximiuz
`authorized_keys` mode issue by installing the file as `0600`, grants
passwordless sudo, verifies SSH login when `TARGET_HOST` is set, and prints the
private key block to paste into Jenkins.

Then add the private key to Jenkins:

```text
Manage Jenkins -> Credentials -> System -> Global credentials -> Add Credentials
Kind: SSH Username with private key
ID: target-ssh-key
Username: laborant
Private Key: paste the contents of $HOME/.ssh/jenkins-deploy-key
```

Run the Jenkins job with:

```text
TARGET_HOST=172.16.0.3
SSH_CREDENTIALS_ID=target-ssh-key
```

## Running a script by hand

Because the scripts read their config from the environment, you can reproduce a
deploy outside Jenkins for debugging:

```bash
export TARGET_HOST=1.2.3.4
export SSH_KEY=~/.ssh/id_ed25519 SSH_USER=deploy
export SSH_OPTIONS='-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=.ssh/known_hosts'
export ARTIFACT=build/main-linux-static REMOTE_APP_DIR=/opt/myapp
export SERVICE_NAME=myapp SERVICE_USER=myapp
bash scripts/deploy.sh
```

## Requirements on the target

The SSH user needs **passwordless sudo** for the `install`, `useradd`, `mv` and
`systemctl` commands in `remote-install.sh`, and the host must use `systemd`.

## Requirements on the Jenkins agent

The agent that runs the pipeline needs `ssh`, `scp`, `ssh-keyscan`, `curl`, and
the configured Go toolchain available on `PATH`.
