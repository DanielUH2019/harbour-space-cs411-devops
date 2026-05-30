# Prompts — Challenge 3 Session

---

## 1. "Would the Dockerfile benefit from having the HEALTHCHECK in docker-compose?"

**Why asked**: After writing the `HEALTHCHECK` instruction in the Dockerfile, the natural next question was whether it belonged there or in a Compose file — since Compose also supports a `healthcheck` key and some guides recommend putting it there.

**What we found**: The Dockerfile is the right place for this setup. A Compose-level healthcheck only runs under `docker compose up`, while the Dockerfile instruction is portable to any launch method — including the bare `docker run` in the Jenkinsfile. More importantly, neither location does anything useful unless an orchestrator or pipeline actually reads the health status and acts on it. At the time, nothing did.

**Learning**: `EXPOSE` and `HEALTHCHECK` in a Dockerfile are signals, not enforcement. Their value depends entirely on the runtime acting on them. A healthcheck baked into the image is always available; one in Compose only works if you use Compose.

---

## 2. “What does an orchestrator do with a HEALTH signal?” (k8s, Compose, Swarm, ECS)

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
readiness = “can I receive traffic?”
liveness  = “am I stuck and should be restarted?”
startup   = “give me time before judging me”
```

Kubernetes models those separately. Docker HEALTHCHECK, Compose, Swarm, and ECS are closer to a single “is this container healthy?” signal, with different consequences depending on the orchestrator.