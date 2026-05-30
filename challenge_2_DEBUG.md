# Debug Task

## Ranked Hypotheses

1. The pipeline starts the app as a child of the SSH session, for example with `./main &`, and the process receives `SIGHUP` or is cleaned up when that SSH session exits. This is the most likely cause because the app works while the SSH session is alive and dies exactly when the session closes.

2. The pipeline only proves that the copy/start command returned successfully, not that the service is still running and reachable after the remote shell exits. This is likely because a "Copy + run on target" stage can go green before checking whether anything is listening on port `4444`.

## Verification Steps

For hypothesis 1, inspect the target process tree while the app is running from SSH:

```sh
ps -eo pid,ppid,sid,tty,stat,cmd | grep '[m]ain'
```

If `main` belongs to the SSH shell's session instead of a supervisor like `systemd`, it is tied to that login session and can die when SSH exits.

For hypothesis 2, check whether the pipeline logs contain only the copy/start command and no post-start listener or HTTP check:

```sh
grep -E 'scp|./main|curl|ss -ltnp|systemctl status' jenkins-console.log
```

If the log shows the app was started but never checks `curl http://<target-host>:4444/` or `ss -ltnp`, the pipeline can be green even though the service is gone by the time a user tests it.

## Fix

Use a minimal supervisor. The preferred fix is a `systemd` unit and a restart from the pipeline:

```sh
sudo install -m 0755 main /opt/myapp/main
sudo install -m 0644 myapp.service /etc/systemd/system/myapp.service
sudo systemctl daemon-reload
sudo systemctl enable myapp
sudo systemctl restart myapp
sudo systemctl status myapp --no-pager
```

Then make the pipeline run a health check after restart:

```sh
curl -fsS http://<target-host>:4444/
```

If `systemd` is not available, a smaller but weaker fix is to detach the process from the SSH session:

```sh
nohup /opt/myapp/main >/var/log/myapp.log 2>&1 </dev/null &
```

`systemd` is better because it restarts the app, records status/logs, and gives the pipeline a stable service to manage.

## Lesson

A process that exists right now is just a child of whatever started it; a supervised process is owned by a service manager that keeps it independent of the login session and gives us a reliable way to start, stop, inspect, and restart it.
