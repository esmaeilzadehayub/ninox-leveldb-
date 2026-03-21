# ── Build ─────────────────────────────────────────────────────────
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /app/ninox-leveldb ./cmd/server

# ── Runtime ───────────────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /app/ninox-leveldb /usr/local/bin/ninox-leveldb
USER 1000:1000
VOLUME ["/var/lib/leveldb"]
EXPOSE 8080 9090
ENTRYPOINT ["ninox-leveldb"]
CMD ["--data-dir=/var/lib/leveldb", "--port=8080", "--metrics-port=9090"]
