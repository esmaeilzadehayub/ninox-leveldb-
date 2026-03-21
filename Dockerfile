# ──────────────────────────────────────────────────────────────────
# Dockerfile — ninox-leveldb application
#
# Replace the "builder" and "runtime" stages with your actual build.
# The app MUST expose:
#   GET :8080/healthz  → 200 OK  (liveness)
#   GET :8080/ready    → 200 OK  (readiness — return 503 while loading)
#   GET :9090/metrics  → Prometheus text format
# ──────────────────────────────────────────────────────────────────

# ── Stage 1: Build ────────────────────────────────────────────────
FROM golang:1.22-alpine AS builder

WORKDIR /app

# Cache dependencies first
COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -o /app/ninox-leveldb ./cmd/server

# ── Stage 2: Runtime ──────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot

# Copy binary
COPY --from=builder /app/ninox-leveldb /usr/local/bin/ninox-leveldb

# Non-root user (matches securityContext.runAsUser: 1000)
USER 1000:1000

# Data directory — mounted as PVC at /var/lib/leveldb
VOLUME ["/var/lib/leveldb"]

# HTTP API
EXPOSE 8080

# Prometheus metrics
EXPOSE 9090

ENTRYPOINT ["ninox-leveldb"]
CMD ["--data-dir=/var/lib/leveldb", "--port=8080", "--metrics-port=9090"]
