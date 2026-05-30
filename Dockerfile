FROM golang:1.24@sha256:d2d2bc1c84f7e60d7d2438a3836ae7d0c847f4888464e7ec9ba3a1339a1ee804 AS builder

WORKDIR /app

COPY main.go ./

RUN CGO_ENABLED=0 GOOS=linux go build -o main main.go

FROM alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d

COPY --from=builder /app/main /main

EXPOSE 4444

HEALTHCHECK --interval=5s --timeout=2s --start-period=5s --retries=3 CMD wget -qO- http://localhost:4444/ || exit 1

CMD ["/main"]
