# Pipeline Review Prompts

These prompts document the main failure modes I checked while turning the manual
deploy into a Jenkins pipeline. Each one is written as a reviewer question, the
risk behind it, and the fix used in this repository.

## Idempotent Deploy

Question: Can the deploy be run repeatedly without leaving an old server
process behind, corrupting the binary while it is running, or colliding with
port `4444`?

Risk: A simple deploy such as `scp main target:/opt/myapp/main && ./main &`
can leave unmanaged background processes outside systemd. The next deploy may
then fail because the old process still owns port `4444`, or it may overwrite a
binary while the service is using it.

Fix: `scripts/deploy.sh` uploads the binary to a temporary target-side path,
then `scripts/remote-install.sh` installs it as `/opt/myapp/main.new` and
atomically renames it to `/opt/myapp/main`. The service is managed with
`systemctl restart myapp`, so repeated deploys replace the existing service
instead of starting another copy.

## Post-Deploy Health Check

Question: Does the pipeline prove that the app is actually serving traffic
after the deploy, or does it only prove that files copied and systemd accepted a
restart command?

Risk: `scp` and `systemctl restart` can both succeed while the app immediately
crashes because the unit file is invalid, port `4444` is unavailable, or the
target cannot execute the binary.

Fix: `scripts/health-check.sh` polls `http://$TARGET_HOST:4444/` after deploy
and verifies the expected JSON fields. The pipeline only reports success after
the HTTP endpoint responds correctly.

## Jenkins SSH Credential

Question: Is the deploy key stored in Jenkins Credentials, and does the public
key exist in the target user's `authorized_keys` file?

Risk: If the private key is pasted incorrectly, the Jenkins agent may fail with
`Load key ... error in libcrypto`. If the matching public key is missing on the
target, SSH fails with `Permission denied (publickey)`.

Fix: Run `scripts/setup-target-local-jenkins-ssh.sh` on the target. It creates
or reuses the deploy key, installs the matching public key for the target user,
fixes the iximiuz `authorized_keys` permission issue, grants passwordless sudo,
and prints the private key block to paste into Jenkins as an
`SSH Username with private key` credential.

## SSH Host Key Trust

Question: Can Jenkins trust the target host non-interactively before the first
`ssh` or `scp` command runs?

Risk: An interactive shell can ask whether to trust a new host fingerprint, but
a Jenkins pipeline cannot answer that prompt. Without pre-trusting the host key,
the deploy can fail with `Host key verification failed`.

Fix: `scripts/deploy.sh` runs `ssh-keyscan -H "$TARGET_HOST"` before the first
SSH connection and appends the result to the workspace-local `.ssh/known_hosts`
file used by `SSH_OPTIONS`.


