# Prompts — Challenge 4 Session (Deploy to Kubernetes + stretches)

The core task moved the deploy off `docker run` and onto a Kubernetes Pod named
`myapp`, applied by the Jenkins pipeline. Jenkins authenticates to the API server
at `https://kubernetes:6443` using a bearer token for ServiceAccount
`default:jenkins-robot` (bound to `cluster-admin`), stored as a *Secret text*
credential and consumed by the Kubernetes CLI plugin's `withKubeConfig` step. The
Pod runs `ttl.sh/danieluh2019:2h` and serves JSON on `:4444`.

One decision worth recording from the core task: the deploy does
`kubectl delete pod myapp --ignore-not-found` *before* `apply`, and the Pod sets
`imagePullPolicy: Always`. The `:2h` tag is reused on every build, so the image
*string* in the spec never changes — a plain `kubectl apply` sees no diff, is a
no-op, and the node keeps serving the previously cached layers. Recreating the Pod
is what actually forces the freshly pushed image to be pulled.

---

## Debugging — the `401` that wasn't expiration or RBAC

The first pipeline run died on the very first `kubectl` call:

```text
+ kubectl delete pod myapp --ignore-not-found --wait
... couldn't get current server API group list: the server has asked for the
    client to provide credentials
error: You must be logged in to the server (the server has asked for the client
    to provide credentials)
```

**Reading the error precisely was the whole game.** "The server has asked for the
client to provide credentials" is an HTTP **401**, and a 401 means the request
*reached* the API server and TLS was fine — the server simply saw no valid bearer
token and treated the caller as `system:anonymous`. That immediately rules out a
class of red herrings: it is *not* a DNS/network problem (that fails to connect,
not 401), *not* a TLS/CA problem (that fails the handshake), and *not* RBAC (that
would be a **403** "forbidden", token-accepted-but-not-allowed). The fault had to
be the token itself or how it was delivered.

The agent's first instinct was **token expiry** — `kubectl create token` defaults
to a ~1h TTL, a classic CI gotcha — and it proposed a long-lived
`kubernetes.io/service-account-token` Secret. **I pushed back: it wasn't
expiration.** That correction mattered, because it stopped us from "fixing" the
wrong thing and shipping a non-expiring token we didn't need.

So we isolated the two sides with **one decisive test** — mint a fresh token and
hit the API directly, outside Jenkins entirely:

```bash
TOKEN=$(kubectl create token jenkins-robot)
curl -sk -H "Authorization: Bearer $TOKEN" \
  https://kubernetes:6443/api/v1/namespaces/default/pods -o /dev/null -w "%{http_code}\n"
# -> 200
```

A **200** split the problem cleanly: the ServiceAccount, the `cluster-admin`
rolebinding, and the API server are all correct in isolation. Combined with the
Jenkins credential being the right *kind* (Secret text — the only kind the
Kubernetes CLI plugin injects as a `--token`), the only remaining variable was the
**byte value stored in the credential**. The culprit: a **trailing newline pasted
into the Secret text field**. Copying the output of `kubectl create token` from a
terminal drags along a `\n`, so the plugin built `Authorization: Bearer <token>\n`
— a malformed header the server can't parse, so it falls back to anonymous → 401.

**Fix:** re-paste the token with no trailing whitespace. Build went green.

One hardening that *did* survive: a `kubectl auth can-i create pods -n default`
guard at the top of the deploy block. If the credential ever breaks again it fails
on that line with a readable message, instead of the wall of `memcache` 401 noise
that every subsequent command would otherwise spew.

**Lesson:** the HTTP status code is a triage tree, not a detail — 401 vs 403 vs a
connection error each points at a different layer, and naming the layer first kept
us from chasing expiry and CA certs. And when an auth value "looks right," suspect
the invisible bytes (newline, leading space) before suspecting the logic.

---

## Stretch 1 — Liveness + readiness probes

Both probes are `httpGet` on path `/` port `4444`, the same endpoint the app
already serves. Added to `pod.yaml`:

```yaml
readinessProbe:
  httpGet: { path: /, port: 4444 }
  initialDelaySeconds: 2
  periodSeconds: 5
livenessProbe:
  httpGet: { path: /, port: 4444 }
  initialDelaySeconds: 5
  periodSeconds: 10
```

**They are not redundant — each controls something the other cannot:**

- **Readiness controls traffic, not lifecycle.** When the readiness probe fails,
  Kubernetes removes the Pod's IP from the `myapp` Service's Endpoints, so clients
  stop being routed to it — but the container is **left running and is never
  restarted**. This is the only mechanism that handles "alive but temporarily can't
  serve" (warming up, a full connection pool, a slow dependency): the Pod quietly
  drops out of rotation and rejoins when it recovers, with zero restarts.

- **Liveness controls lifecycle, not traffic.** When the liveness probe fails past
  its threshold, the kubelet **kills and restarts the container** (incrementing its
  restart count). A failing liveness probe does *not* by itself pull the Pod out of
  the Service — that only happens as a side effect once the container is down. This
  is the only mechanism that recovers a wedged process (deadlock, hung event loop)
  that will never fix itself without a restart.

The asymmetry that proves it: readiness failure on a deadlocked process would just
park it out of rotation forever; liveness failure on a briefly-overloaded process
would pointlessly restart something that only needed a few seconds. You want the
one whose *consequence* matches the failure mode, which is why both exist.

---

## Stretch 2 — Resource requests + limits

Added to the container in `pod.yaml`:

```yaml
resources:
  requests:
    memory: "16Mi"
    cpu: "50m"
  limits:
    memory: "64Mi"
    cpu: "250m"
```

(A static-linked Go HTTP server idles in a few MB; these are deliberately small but
non-zero so the scheduler and the OOM/throttle machinery have real numbers.)

**What goes wrong if you set *neither*:** the Pod lands in the `BestEffort` QoS
class. The scheduler treats it as needing **zero** resources, so it will happily
pack it onto a node that is already full — and at runtime the container has **no
memory ceiling**, so a leak or a traffic spike lets it grow until it triggers
node-level memory pressure. The kubelet then starts evicting Pods to save the node,
and `BestEffort` Pods are **first to be killed**. So "no resources set" doesn't mean
"unlimited and safe" — it means "unbounded blast radius *and* first in line to die."

**What goes wrong if you set *only limits* (no requests):** Kubernetes defaults the
request for each limited resource to that same limit, which is *not* what most
people expect when they "just add a limit." That silently changes scheduling: the
scheduler now reserves the full limit amount on a node (so you fit fewer Pods than
you intended, and can get unschedulable Pods even though real usage is tiny). If
you set matching limits for every CPU and memory field, the Pod can also be
promoted to `Guaranteed` QoS by accident; if you only limit memory, it is usually
`Burstable`, but the scheduling problem still applies. The harm is the inverse of
stretch's first case — instead of over-packing, you *under-pack* the cluster and
waste capacity, all from a default you didn't write down. Requests (what you're
guaranteed / scheduled on) and limits (the hard cap) answer two different
questions; omitting requests lets the limit answer both, usually wrong.

---

## Stretch 3 — A Service in front of the Pod

Added `service.yaml` — a `ClusterIP` Service selecting the Pod's `run: myapp` label
and targeting `4444`:

```yaml
apiVersion: v1
kind: Service
metadata: { name: myapp }
spec:
  type: ClusterIP
  selector: { run: myapp }
  ports:
  - { name: http, port: 4444, targetPort: 4444 }
```

**Why a Pod IP is a bad target for clients:** a Pod IP is ephemeral and tied to that
exact Pod instance. The moment the Pod is recreated or rescheduled — a node reboot,
an eviction, a failed node, or our own `kubectl delete && apply` on the next
pipeline run — it comes back with a **different IP**, and every client holding the
old address is now talking to nothing. A normal liveness-probe restart only
restarts the container inside the same Pod, so it usually keeps the same Pod IP;
the IP changes when the Pod itself is replaced. There is also no load balancing: a
Pod IP points at one replica, so you can't scale out behind it.

**What the Service buys you:** a *stable* virtual IP and DNS name (`myapp` /
`myapp.default.svc.cluster.local`) that never changes for the life of the Service.
Kubernetes continuously updates the Service's Endpoints from the label selector, so
as Pods come and go the Service transparently re-points at whatever healthy Pods
currently match — and **readiness gates that membership** (stretch 1), so a Pod that
isn't ready is never sent traffic. Clients get one durable name with built-in
load-balancing and health-aware routing, instead of a fragile pointer to one
disposable Pod.

(The dashboard's core check still hits the Pod IP directly on `:4444`, so the
Service isn't on that path — it's the right production-shaped target for any real
in-cluster client, which is what this stretch is graded on.)
