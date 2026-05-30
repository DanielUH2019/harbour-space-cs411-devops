# Deploy scripts

These scripts back the Jenkins pipeline in [`../Jenkinsfile`](../Jenkinsfile).
The Jenkinsfile only *orchestrates* — the real deploy logic lives here so it can
be read, linted with `shellcheck`, and run by hand when debugging.

## Files

| File | Runs on | Purpose |
|------|---------|---------|
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
