# Pipeline Review Prompts

## Idempotent Deploy

Question: Which deploy line leaves an old server outside systemd, or overwrites the running binary in a way that can make the next run collide with port 4444?

One-line fix: Copy to a target-side `mktemp` path, atomically move it into `/opt/myapp/main`, and use `sudo systemctl restart myapp` instead of backgrounding `./main &`.

## Post-Deploy Health Check

Real-world failure mode: The binary can copy successfully while the service immediately crashes because port 4444 is already in use, the unit file is invalid, or the target cannot execute the artifact.

Why the pipeline can lie without it: SSH and `systemctl restart` can return before anyone has proven the HTTP endpoint is actually serving the expected JSON, so a deploy can look green even though users get connection failures.
