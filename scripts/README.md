# Deploy scripts

These scripts back the Jenkins pipeline in [`../Jenkinsfile`](../Jenkinsfile).
The Jenkinsfile only *orchestrates* — the real deploy logic lives here so it can
be read, linted with `shellcheck`, and run by hand when debugging.

## Files

| File | Runs on | Purpose |
|------|---------|---------|
| `create-jenkins-deploy-key.sh` | Operator machine | Generate the SSH key pair Jenkins will use for deploys. |
| `bootstrap-target-ssh.sh` | Operator machine + target host | Install Jenkins' public key on the target and grant the SSH user passwordless sudo. |
| `verify-target-ssh.sh` | Operator machine | Verify SSH, passwordless sudo, and systemd access before running Jenkins. |
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

Generate a deploy key pair:

```bash
bash scripts/create-jenkins-deploy-key.sh
```

Install the public key on the target host and grant the SSH user passwordless
sudo. `ADMIN_USER` is only needed when the final Jenkins SSH user does not
already exist or cannot bootstrap itself:

```bash
PUBLIC_KEY_FILE="$HOME/.ssh/jenkins-deploy-key.pub" \
TARGET_HOST=1.2.3.4 \
TARGET_USER=deploy \
ADMIN_USER=ubuntu \
bash scripts/bootstrap-target-ssh.sh
```

Verify the access Jenkins will need:

```bash
TARGET_HOST=1.2.3.4 \
TARGET_USER=deploy \
PRIVATE_KEY_FILE="$HOME/.ssh/jenkins-deploy-key" \
bash scripts/verify-target-ssh.sh
```

Then add the private key to Jenkins:

```text
Manage Jenkins -> Credentials -> System -> Global credentials -> Add Credentials
Kind: SSH Username with private key
ID: target-ssh-key
Username: deploy
Private Key: paste the contents of $HOME/.ssh/jenkins-deploy-key
```

Run the Jenkins job with:

```text
TARGET_HOST=1.2.3.4
SSH_CREDENTIALS_ID=target-ssh-key
```

If you are doing the public-key install manually inside the iximiuz target
console, fix the pre-baked `authorized_keys` permissions before appending:

```bash
chmod 600 ~/.ssh/authorized_keys
cat /path/to/jenkins-deploy-key.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

The `bootstrap-target-ssh.sh` helper does not append directly; it installs the
final `authorized_keys` file with mode `0600`.

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
