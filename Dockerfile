FROM golang:1.24 AS builder

WORKDIR /app

COPY main.go ./

RUN CGO_ENABLED=0 GOOS=linux go build -o main main.go

FROM alpine:3.21

COPY --from=builder /app/main /main

EXPOSE 4444

HEALTHCHECK --interval=5s --timeout=2s --start-period=5s --retries=3 CMD wget -qO- http://localhost:4444/ || exit 1

CMD ["/main"]
