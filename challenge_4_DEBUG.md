# DEBUG — `ImagePullBackOff` on the Pod, yet `docker pull` works on Jenkins

## Symptom

- Pipeline builds, pushes the image to `ttl.sh`, and `kubectl apply`s the Pod manifest — all green.
- `kubectl get pods` shows `myapp` stuck in **`ImagePullBackOff`**.
- The `image:` field in `pod.yaml` is byte-for-byte the tag the pipeline pushed (`ttl.sh/danieluh2019:2h`) — so it is **not** a typo'd tag.
- On the **Jenkins machine**, `docker pull ttl.sh/danieluh2019:2h` **succeeds**.

The trap is the last two facts read like "the image is fine, so Kubernetes is broken." But the entity that pulls for the Pod is **not** Jenkins — it is the **kubelet on the cluster node**. The image being pullable *from Jenkins* says nothing about whether it is pullable *by that node*, because the node has a different CPU architecture and a different network than the Jenkins host. `ImagePullBackOff` is the node's puller failing, repeatedly backing off, and retrying.

---

## Ranked hypotheses

### H1 — Architecture mismatch: the pushed image has no manifest for the node's arch (most likely)

The pipeline pushes with `docker buildx build --platform linux/amd64`, i.e. **amd64 only**. If the cluster node is **arm64** (common for ARM-based VMs / Apple-silicon-hosted clusters), the kubelet asks the registry for an image matching `linux/arm64`, the manifest list has no such entry, and the pull fails with *"no matching manifest."* Jenkins is amd64, so *its* `docker pull` finds a match and succeeds — the exact split the symptom describes. This is the prime suspect because the repo's own pipeline hard-codes a single, possibly-wrong platform.

### H2 — The node can't reach the `ttl.sh` registry the way Jenkins can (less likely)

The kubelet pulls from the **node's** network namespace, which may lack the outbound internet / DNS / proxy egress that the Jenkins host has. If the node can't resolve or route to `ttl.sh`, the pull times out or is refused, while Jenkins — sitting on a network with internet access — pulls fine.

---

## Verification — one command per hypothesis

The two hypotheses fail at different layers, so they leave different fingerprints: H1 is a *manifest-matching* failure (the registry was reached but had nothing for this arch); H2 is a *connectivity* failure (the registry was never reached).

**H1 — compare the node's architecture against the platforms actually pushed:**

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.architecture}{"\n"}{end}'
docker buildx imagetools inspect ttl.sh/danieluh2019:2h   # lists the platforms in the manifest list
```

→ If a node reports `arm64` but the image only lists `linux/amd64`, the node's arch is absent from the manifest → **H1 confirmed**. (The same conclusion shows up in `kubectl describe pod myapp` Events as `no matching manifest for linux/arm64 in the manifest list entries`.)

**H2 — read the failure message in the Pod's events:**

```bash
kubectl describe pod myapp | sed -n '/Events:/,$p'
```

→ A network message — `dial tcp …: i/o timeout`, `lookup ttl.sh: no such host`, or `connection refused` — means the node never reached the registry → **H2 confirmed**. This is distinct from H1's `no matching manifest` (registry reached, nothing matched).

---

## Fix (minimal)

**For H1 (the likely cause) — push a fresh image that includes the node's architecture.** No manifest rewrite, no Docker-in-Pod: just widen the one `--platform` value in the pipeline so the manifest list covers both arches:

```bash
# Jenkinsfile — Docker Build and Push stage
docker buildx build --platform linux/amd64,linux/arm64 -t ${IMAGE} --push .
```

The Dockerfile already cross-compiles correctly (`GOOS=${TARGETOS} GOARCH=${TARGETARCH}` driven by `$BUILDPLATFORM`), so the multi-arch build emits a matching arm64 binary inside the arm64 image. After re-pushing, the deploy stage's existing `kubectl delete pod … && apply` with `imagePullPolicy: Always` pulls the now-matching image.

**For H2 (if the events show a network error instead)** — the minimal fix is on the node, not the manifest: give the node egress/DNS to `ttl.sh` (open the firewall/proxy), or push to a registry the node can already reach. `imagePullSecrets` would *not* help here — `ttl.sh` is anonymous, so the failure is reachability, not auth.

---

## Underlying lesson

"I can pull this image" is a claim about **one machine** — Jenkins, with *its* CPU architecture, *its* network, and *its* credentials — finding a matching manifest; "the cluster can pull this image" is a claim about a **specific node's kubelet**, whose architecture, egress, and auth may all differ, so a green `docker pull` on the build host proves nothing about whether the node that actually runs the Pod can fetch a manifest that matches *it*.
