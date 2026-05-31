# DEBUG — `exec /app/main: exec format error` on the x86_64 docker VM

## Symptom

- Built on an **ARM** host (Apple Silicon / Linux ARM) with a plain `docker build -t ttl.sh/<your-name>:2h .`, then pushed.
- Build green, push green, **manifest pulls fine** on the x86_64 docker VM.
- `docker run …` starts the container, which dies immediately with:

  ```
  exec /app/main: exec format error
  ```

`exec format error` is the Linux kernel refusing to run an ELF binary whose machine type doesn't match the CPU. The container filesystem is fine; the *executable inside it* is built for the wrong architecture.

The pull succeeding is a red herring: `docker pull` happily fetches a single-arch image regardless of the host CPU. Nothing checks the architecture until the kernel actually tries to `exec` the binary at `docker run` time.

## Two layers that can independently carry an architecture

1. **The image manifest** — the OCI descriptor's `architecture` field plus which `alpine` base variant was selected. Controlled by `docker build --platform`.
2. **The Go binary inside the image** — the ELF's target machine. Controlled by `GOOS`/`GOARCH` at compile time.

In our Dockerfile the build line is:

```dockerfile
RUN CGO_ENABLED=0 GOOS=linux go build -o main main.go
```

`GOOS` is pinned but `GOARCH` is **not**, so the binary inherits the *build environment's* native arch. These two layers are set by two different mechanisms and can disagree.

---

## Ranked hypotheses

### H1 — The whole image is `linux/arm64` (most likely)

A plain `docker build` on an Apple Silicon / ARM host defaults to `--platform linux/arm64`, so **both** the `alpine` base and the natively-compiled Go binary end up arm64; the x86_64 VM pulls it without complaint but cannot `exec` an aarch64 ELF.

### H2 — Manifest is `amd64` but the binary inside is still arm64 (less likely)

If the manifest was coerced to amd64 (e.g. a `--platform linux/amd64` somewhere) but the `go build` line still omits `GOARCH`, the binary compiles for the builder's native arm64 — so a "correct-looking" amd64 image ships an arm64 executable.

---

## Verification — one command per hypothesis

The two hypotheses differ precisely in whether the **manifest arch** and the **binary arch** agree. Test each layer separately.

**H1 — check the manifest's declared architecture** (run on the VM or against the registry):

```bash
docker buildx imagetools inspect ttl.sh/<your-name>:2h
# or, after pulling:
docker image inspect ttl.sh/<your-name>:2h --format '{{.Architecture}}'
```

→ If it reports `arm64`, the whole image is arm64 → **H1 confirmed**.

**H2 — check the actual binary's arch, independent of the manifest** (extract it; don't `exec` it):

```bash
cid=$(docker create ttl.sh/<your-name>:2h)
docker cp "$cid":/main /tmp/main && docker rm "$cid"
readelf -h /tmp/main | grep Machine     # or: file /tmp/main
```

→ `AArch64` = arm64 binary, `Advanced Micro Devices X86-64` = amd64 binary.
If H1's command said `amd64` but this says `AArch64`, the layers disagree → **H2 confirmed**.

---

## Fix (minimal — no framework change)

Build for the architecture the deploy host actually runs. Two options:

**Minimal — build the one platform the VM needs:**

```bash
docker buildx build --platform linux/amd64 -t ttl.sh/<your-name>:2h --push .
```

**Robust — build a multi-arch image so it runs on ARM and x86_64:**

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t ttl.sh/<your-name>:2h --push .
```

Either flag fixes H1. To also close the latent H2 bug (the missing `GOARCH`), make the Dockerfile cross-compile to the requested target using buildx's automatic build args — this keeps the builder running natively on the fast host while emitting a binary for `TARGETARCH`:

```dockerfile
FROM --platform=$BUILDPLATFORM golang:1.24@sha256:... AS builder
ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -o main main.go
```

Now both layers — manifest and binary — are driven by the same `--platform` value and can no longer drift apart.

---

## Underlying lesson

"The image is built" only promises the build succeeded for **some** architecture — by default the builder's — not that the binary inside can `exec` on the deploy host; a container image is CPU-architecture-specific, and a green build/push/pull says nothing about whether that target arch matches the runtime host.
