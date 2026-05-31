# Prompts — Challenge 3 Session

---

## 1. "Would the Dockerfile benefit from having the HEALTHCHECK in docker-compose?"

**Why asked**: After writing the `HEALTHCHECK` instruction in the Dockerfile, the natural next question was whether it belonged there or in a Compose file — since Compose also supports a `healthcheck` key and some guides recommend putting it there.

**What we found**: The Dockerfile is the right place for this setup. A Compose-level healthcheck only runs under `docker compose up`, while the Dockerfile instruction is portable to any launch method — including the bare `docker run` in the Jenkinsfile. More importantly, neither location does anything useful unless an orchestrator or pipeline actually reads the health status and acts on it. At the time, nothing did.

**Learning**: `EXPOSE` and `HEALTHCHECK` in a Dockerfile are signals, not enforcement. Their value depends entirely on the runtime acting on them. A healthcheck baked into the image is always available; one in Compose only works if you use Compose.

---

## 2. "What does an orchestrator do with a HEALTH signal?" (k8s, Compose, Swarm, ECS)

Health can mean two different actions:

1. **Stop routing traffic**
   - Kubernetes: readiness probe does this.
   - ECS: usually through service/load balancer health and task health.
   - Swarm: service routing is tied to running service tasks, but it does not have Kubernetes-style readiness probes.
   - Compose: no real traffic router unless you add one.

2. **Restart or replace the workload**
   - Kubernetes: liveness probe restarts the container.
   - ECS: unhealthy service task is replaced.
   - Swarm: unhealthy/failed task can be replaced.
   - Compose: usually just marks it unhealthy; restart policy normally reacts to process exit, not health failure.

So, `HEALTH=unhealthy` means:

| Runtime        | Consequence                                          |
| -------------- | ---------------------------------------------------- |
| K8s readiness  | Remove from traffic                                  |
| K8s liveness   | Restart container                                    |
| Compose        | Mark unhealthy, may affect dependency startup        |
| Swarm          | Replace unhealthy service task                       |
| ECS            | Mark task unhealthy, replace if managed by a service |

For backend apps, the best mental model is:

```
readiness = "can I receive traffic?"
liveness  = "am I stuck and should be restarted?"
startup   = "give me time before judging me"
```

Kubernetes models those separately. Docker HEALTHCHECK, Compose, Swarm, and ECS are closer to a single “is this container healthy?” signal, with different consequences depending on the orchestrator.

---

## 3. "Should the base images be pinned by digest instead of a tag?"

**Why asked**: The Dockerfile used `FROM golang:1.24` and `FROM alpine:3.21`. Tags are mutable — the registry can repoint them to a new image at any time — so the same Dockerfile can build a different image tomorrow than it does today.

**What we changed**: Pinned both stages by digest:

```dockerfile
FROM golang:1.24@sha256:d2d2bc1c84f7e60d7d2438a3836ae7d0c847f4888464e7ec9ba3a1339a1ee804 AS builder
...
FROM alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d
```

The tag is kept alongside the digest purely for human readability; the digest is what Docker actually resolves. These are multi-arch *index* digests, so builds on different architectures still resolve correctly.

**One failure mode it prevents**: A maintainer re-pushes `alpine:3.21` with an updated package set (or a compromised mirror serves a malicious image under that tag). With a bare tag, the next build silently pulls the new bytes — a green pipeline can ship a different, possibly broken or backdoored, runtime than the one that was tested. With the digest, any change to the underlying image makes the pull fail loudly instead of substituting content behind your back.

**One inconvenience it introduces**: Patch updates are no longer free. When `alpine:3.21` gets a CVE fix, the digest-pinned Dockerfile keeps building the old, vulnerable image until someone manually re-resolves the digest and commits it. You trade automatic drift for a manual bump step — best handled by an automated tool like Dependabot or Renovate so the update becomes a reviewable PR rather than an invisible change.

---

## 4. "What is `docker buildx`, and why isn't it part of native `docker build`?"

**Why asked**: The cross-arch fix relied on `docker buildx build --platform …`, which raised the question of what `buildx` actually is and why the capability lives in a separate command.

**What we found**: `buildx` is a CLI plugin that extends `docker build` with features the legacy builder lacks — most relevantly, multi-architecture image builds (`--platform linux/amd64,linux/arm64`) via BuildKit.

**Learning**: It stays a separate plugin for backwards compatibility — the classic `docker build` behavior is preserved, while `buildx` layers the newer BuildKit-powered capabilities on top.
