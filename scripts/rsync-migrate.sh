#!/bin/bash
# ──────────────────────────────────────────────────────────────────
# rsync-migrate.sh  —  On-premises → EKS LevelDB data migration
#
# PHASES
# ──────
#  1  Initial bulk copy        (hot, application still running)
#  2  Catch-up sync            (repeat until delta < 100 MB)
#  3  Final sync               (brief write pause, final consistency)
#  4  Validate                 (file counts + MANIFEST check + health)
#  5  Cut over                 (DNS / ALB flip instructions)
#
# REQUIREMENTS
# ────────────
#  - SSH access to old servers
#  - kubectl access to EKS cluster (ninox-production)
#  - rsync installed on old servers
#
# USAGE
# ─────
#  export OLD_SERVERS="db1.prod.internal,db2.prod.internal,db3.prod.internal"
#  export SSH_KEY="~/.ssh/id_rsa"
#  ./rsync-migrate.sh 1      # Initial bulk copy
#  ./rsync-migrate.sh 2      # Catch-up (repeat until output says ready)
#  ./rsync-migrate.sh 3      # Final sync with brief pause
#  ./rsync-migrate.sh 4      # Validate
#  ./rsync-migrate.sh 5      # Cut over
# ──────────────────────────────────────────────────────────────────
set -euo pipefail

PHASE="${1:-}"
OLD_SERVERS="${OLD_SERVERS:-}"
SSH_USER="${SSH_USER:-ec2-user}"
SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"
SRC_DIR="${SRC_DIR:-/data/leveldb}"
DST_DIR="${DST_DIR:-/var/lib/leveldb}"
NAMESPACE="${NAMESPACE:-production}"
STS_NAME="${STS_NAME:-ninox-leveldb}"
DELTA_THRESHOLD_MB=100   # Phase 2 proceeds to phase 3 when delta < this

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [phase-${PHASE}] $*"; }
ok()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*" >&2; }
die()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ ERROR: $*" >&2; exit 1; }

[[ -z "$PHASE" ]]       && die "Usage: $0 <1|2|3|4|5>"
[[ -z "$OLD_SERVERS" ]] && die "Set OLD_SERVERS env var (comma-separated hostnames)"

IFS=',' read -ra SERVERS <<< "$OLD_SERVERS"
NUM="${#SERVERS[@]}"
log "Servers (${NUM}): ${SERVERS[*]}"
log "Namespace: ${NAMESPACE}  StatefulSet: ${STS_NAME}"

# ── Pre-flight: verify pods are reachable ─────────────────────────
check_pods() {
  for i in $(seq 0 $(( NUM - 1 ))); do
    POD="${STS_NAME}-${i}"
    kubectl get pod "$POD" -n "$NAMESPACE" &>/dev/null \
      || die "Pod $POD not found. Deploy the StatefulSet before migrating."
    STATUS=$(kubectl get pod "$POD" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}')
    [[ "$STATUS" == "Running" ]] || die "Pod $POD is $STATUS — must be Running"
  done
  ok "All ${NUM} pods are Running"
}

# ── Core rsync function ────────────────────────────────────────────
# Strategy: rsync on the local machine pulls from old server,
# then kubectl cp pushes the local copy into the pod.
# For very large datasets (2 TB) this is run in parallel per pod.
do_rsync() {
  local server="$1"
  local pod="$2"
  local flags="${3:---archive --verbose --human-readable --progress --partial}"
  local dry="${4:-false}"

  local tmp="/tmp/rsync_${pod}_$$"
  mkdir -p "$tmp"

  log "  rsync ${server}:${SRC_DIR}/ → ${pod}:${DST_DIR}/"

  if [[ "$dry" == "true" ]]; then
    # Dry run: just measure what would transfer
    rsync \
      --archive --dry-run --stats \
      --exclude "LOCK" --exclude "*.tmp" \
      -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10" \
      "${SSH_USER}@${server}:${SRC_DIR}/" \
      "$tmp/" 2>/dev/null \
      | grep "Total transferred file size" \
      | awk '{gsub(/,/,"",$5); printf "%.0f\n", $5/1048576}' \
      || echo "0"
    rm -rf "$tmp"
    return
  fi

  # Step 1: pull from old server to local temp dir
  # shellcheck disable=SC2086
  rsync \
    $flags \
    --exclude "LOCK" \
    --exclude "*.tmp" \
    -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10" \
    "${SSH_USER}@${server}:${SRC_DIR}/" \
    "$tmp/"

  # Step 2: push local temp dir into the pod
  # First ensure destination exists
  kubectl exec "$pod" -n "$NAMESPACE" -- mkdir -p "$DST_DIR"

  # kubectl cp recursively uploads the directory
  kubectl cp "$tmp/." "${NAMESPACE}/${pod}:${DST_DIR}/"

  rm -rf "$tmp"
  ok "  Sync complete: ${server} → ${pod}"
}

# ══════════════════════════════════════════════════════════════════
# PHASE 1 — Initial bulk copy (hot, no write pause)
# ══════════════════════════════════════════════════════════════════
phase_1() {
  log "=== Phase 1: Initial Bulk Copy ==="
  log "  ~800 GB per pod. At 1 Gbps: ~2 h per pod."
  log "  All 3 pods sync in parallel. Run inside screen/tmux."
  log "  Application on old servers keeps running normally."
  echo ""

  check_pods

  for i in "${!SERVERS[@]}"; do
    (
      do_rsync "${SERVERS[$i]}" "${STS_NAME}-${i}" \
        "--archive --verbose --human-readable --progress --partial --stats"
    ) &
    log "  Launched background rsync for pod ${i} (PID $!)"
  done

  log "Waiting for all rsync jobs..."
  wait
  ok "Phase 1 complete."
  log "→ Run Phase 2 to catch up changes that happened during Phase 1."
}

# ══════════════════════════════════════════════════════════════════
# PHASE 2 — Catch-up sync (repeat until delta < 100 MB)
# ══════════════════════════════════════════════════════════════════
phase_2() {
  log "=== Phase 2: Catch-up Sync ==="
  log "  Runs up to 10 iterations. Stop when delta < ${DELTA_THRESHOLD_MB} MB."

  check_pods

  for iter in $(seq 1 10); do
    log "  Iteration ${iter}/10..."

    # Measure remaining delta per server (dry run)
    max_delta=0
    for i in "${!SERVERS[@]}"; do
      delta=$(do_rsync "${SERVERS[$i]}" "${STS_NAME}-${i}" "" "true")
      log "    Server ${SERVERS[$i]}: delta = ${delta} MB"
      (( delta > max_delta )) && max_delta=$delta
    done

    # Actual sync
    for i in "${!SERVERS[@]}"; do
      (
        do_rsync "${SERVERS[$i]}" "${STS_NAME}-${i}" \
          "--archive --checksum --verbose --human-readable --progress --partial"
      ) &
    done
    wait

    log "  Max delta after iteration ${iter}: ${max_delta} MB"

    if (( max_delta < DELTA_THRESHOLD_MB )); then
      ok "Delta below ${DELTA_THRESHOLD_MB} MB — ready for Phase 3 (final sync)"
      return 0
    fi

    log "  Still above threshold, continuing..."
    sleep 15
  done

  warn "After 10 iterations delta is still > ${DELTA_THRESHOLD_MB} MB."
  warn "High write rate detected. Proceed to Phase 3 anyway and accept the pause."
}

# ══════════════════════════════════════════════════════════════════
# PHASE 3 — Final sync (brief write pause)
# ══════════════════════════════════════════════════════════════════
phase_3() {
  log "=== Phase 3: Final Sync ==="
  log ""
  log "  You must PAUSE WRITES on the old servers before confirming."
  log "  Options:"
  log "    A) Put old app into read-only mode via config/feature flag"
  log "    B) Stop the application process temporarily"
  log "    C) Block port 8080 with iptables: iptables -A INPUT -p tcp --dport 8080 -j DROP"
  log ""
  read -r -p "  Confirm writes are paused on old servers (type 'yes'): " confirm
  [[ "$confirm" != "yes" ]] && { log "Aborted."; exit 0; }

  check_pods

  START=$(date +%s)

  log "Running final --checksum sync (all pods in parallel)..."
  for i in "${!SERVERS[@]}"; do
    (
      do_rsync "${SERVERS[$i]}" "${STS_NAME}-${i}" \
        "--archive --checksum --delete --verbose --human-readable --stats"
    ) &
  done
  wait

  END=$(date +%s)
  DURATION=$(( END - START ))
  ok "Final sync complete in ${DURATION}s ($(( DURATION / 60 ))m $(( DURATION % 60 ))s)"

  if (( DURATION > 300 )); then
    warn "Write pause ${DURATION}s exceeded 5-minute target."
    warn "Consider running more Phase 2 catch-up iterations next time."
  else
    ok "Within 5-minute write pause target."
  fi

  log "→ Run Phase 4 to validate, then Phase 5 to cut over traffic."
}

# ══════════════════════════════════════════════════════════════════
# PHASE 4 — Validate data integrity
# ══════════════════════════════════════════════════════════════════
phase_4() {
  log "=== Phase 4: Validation ==="

  PASS=0; FAIL=0

  for i in "${!SERVERS[@]}"; do
    SERVER="${SERVERS[$i]}"
    POD="${STS_NAME}-${i}"
    log "  Checking ${SERVER} vs ${POD}..."

    # ── File count ──────────────────────────────────────────────
    OLD_COUNT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
      "${SSH_USER}@${SERVER}" \
      "find ${SRC_DIR} -name '*.ldb' -o -name '*.sst' 2>/dev/null | wc -l" \
      || echo "-1")

    NEW_COUNT=$(kubectl exec "$POD" -n "$NAMESPACE" -- \
      sh -c "find ${DST_DIR} -name '*.ldb' -o -name '*.sst' 2>/dev/null | wc -l" \
      || echo "-1")

    if [[ "$OLD_COUNT" == "$NEW_COUNT" && "$OLD_COUNT" != "-1" ]]; then
      ok "  SST files match: ${OLD_COUNT}"
      (( PASS++ ))
    else
      warn "  SST mismatch — old: ${OLD_COUNT}, k8s: ${NEW_COUNT}"
      (( FAIL++ ))
    fi

    # ── LevelDB MANIFEST ────────────────────────────────────────
    MANIFEST=$(kubectl exec "$POD" -n "$NAMESPACE" -- \
      sh -c "ls ${DST_DIR}/MANIFEST-* 2>/dev/null | wc -l" || echo "0")

    if [[ "$MANIFEST" -gt 0 ]]; then
      ok "  MANIFEST file present"
      (( PASS++ ))
    else
      warn "  MANIFEST missing — data may be corrupt"
      (( FAIL++ ))
    fi

    # ── App health ───────────────────────────────────────────────
    HTTP=$(kubectl exec "$POD" -n "$NAMESPACE" -- \
      sh -c "curl -sf -o /dev/null -w '%{http_code}' http://localhost:8080/healthz 2>/dev/null" \
      || echo "000")

    if [[ "$HTTP" == "200" ]]; then
      ok "  /healthz → HTTP 200"
      (( PASS++ ))
    else
      warn "  /healthz → HTTP ${HTTP}"
      (( FAIL++ ))
    fi

    echo ""
  done

  log "=== Validation: PASS=${PASS} FAIL=${FAIL} ==="

  if [[ "$FAIL" -gt 0 ]]; then
    die "${FAIL} check(s) failed. Fix issues before cutting over."
  fi
  ok "All checks passed — safe to cut over in Phase 5."
}

# ══════════════════════════════════════════════════════════════════
# PHASE 5 — Traffic cut over
# ══════════════════════════════════════════════════════════════════
phase_5() {
  log "=== Phase 5: Cut Over ==="
  echo ""

  K8S_HOST=$(kubectl get svc -n "$NAMESPACE" "${STS_NAME}-lb" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null \
    || echo "(not yet provisioned)")

  log "  K8s ALB hostname: ${K8S_HOST}"
  echo ""
  log "  OPTIONS (pick one):"
  log ""
  log "  A) DNS flip (recommended)"
  log "     — 24h before: set TTL to 60s on your DNS record"
  log "     — Now: change CNAME/A record to ${K8S_HOST}"
  log "     — Wait 60s for propagation, then validate"
  log ""
  log "  B) ALB weighted routing"
  log "     — Create two ALB target groups (old servers + K8s nodes)"
  log "     — Shift 5% → 25% → 50% → 100% over 1 hour"
  log "     — Auto-rollback if error rate > 1%"
  log ""
  log "  After cut over:"
  log "  1. Keep old servers in standby for 2 weeks"
  log "  2. Velero automatically backs up every 6h"
  log "  3. Decommission after backup integrity is confirmed"
  echo ""
  log "  Check Grafana: kubectl port-forward svc/prometheus-stack-grafana -n monitoring 3000:80"
  log "  Check Velero:  velero backup get"
}

# ── Main dispatcher ───────────────────────────────────────────────
case "$PHASE" in
  1) phase_1 ;;
  2) phase_2 ;;
  3) phase_3 ;;
  4) phase_4 ;;
  5) phase_5 ;;
  *) die "Phase must be 1–5. Got: '$PHASE'" ;;
esac
