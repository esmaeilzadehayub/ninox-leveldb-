#!/bin/bash
# ──────────────────────────────────────────────────────────────────
# rsync-migrate.sh — 5-phase on-premises → EKS migration
#
# USAGE
#   export OLD_SERVERS="db1.prod.internal,db2.prod.internal,db3.prod.internal"
#   export SSH_KEY="~/.ssh/id_rsa"
#   ./rsync-migrate.sh 1   # Bulk copy     (~2–4 h, app keeps running)
#   ./rsync-migrate.sh 2   # Catch-up      (repeat until delta < 100 MB)
#   ./rsync-migrate.sh 3   # Final sync    (< 5 min write pause)
#   ./rsync-migrate.sh 4   # Validate
#   ./rsync-migrate.sh 5   # Cut over      (DNS / ALB instructions)
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
DELTA_THRESHOLD_MB=100

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [phase-${PHASE}] $*"; }
ok()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*" >&2; }
die()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $*" >&2; exit 1; }

[[ -z "$PHASE" ]]       && die "Usage: $0 <1|2|3|4|5>"
[[ -z "$OLD_SERVERS" ]] && die "Set OLD_SERVERS env var (comma-separated hostnames)"

IFS=',' read -ra SERVERS <<< "$OLD_SERVERS"
NUM="${#SERVERS[@]}"

check_pods() {
  for i in $(seq 0 $((NUM-1))); do
    kubectl get pod "${STS_NAME}-${i}" -n "$NAMESPACE" &>/dev/null \
      || die "Pod ${STS_NAME}-${i} not found. Deploy StatefulSet first."
    STATUS=$(kubectl get pod "${STS_NAME}-${i}" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
    [[ "$STATUS" == "Running" ]] || die "Pod ${STS_NAME}-${i} is ${STATUS}"
  done
  ok "All ${NUM} pods Running"
}

do_rsync() {
  local server="$1" pod="$2"
  local flags="${3:---archive --verbose --human-readable --progress --partial}"
  local tmp="/tmp/rsync_${pod}_$$"
  mkdir -p "$tmp"
  log "  rsync ${server}:${SRC_DIR}/ → ${pod}:${DST_DIR}/"
  rsync $flags --exclude "LOCK" --exclude "*.tmp" \
    -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=15" \
    "${SSH_USER}@${server}:${SRC_DIR}/" "$tmp/"
  kubectl exec "$pod" -n "$NAMESPACE" -- mkdir -p "$DST_DIR"
  kubectl cp "$tmp/." "${NAMESPACE}/${pod}:${DST_DIR}/"
  rm -rf "$tmp"
  ok "  Sync done: ${server} → ${pod}"
}

measure_delta_mb() {
  rsync --archive --dry-run --stats --exclude "LOCK" --exclude "*.tmp" \
    -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no" \
    "${SSH_USER}@${1}:${SRC_DIR}/" /dev/null 2>/dev/null \
    | grep "Total transferred file size" \
    | awk '{gsub(/,/,"",$5); printf "%.0f\n", $5/1048576}' || echo "9999"
}

phase_1() {
  log "=== Phase 1: Bulk Copy (hot, app keeps running) ==="
  check_pods
  for i in "${!SERVERS[@]}"; do
    ( do_rsync "${SERVERS[$i]}" "${STS_NAME}-${i}" \
        "--archive --verbose --human-readable --progress --partial --stats" ) &
  done
  wait; ok "Phase 1 done → run Phase 2"
}

phase_2() {
  log "=== Phase 2: Catch-up Sync ==="
  check_pods
  for iter in $(seq 1 10); do
    max_delta=0
    for i in "${!SERVERS[@]}"; do
      delta=$(measure_delta_mb "${SERVERS[$i]}")
      log "  ${SERVERS[$i]}: delta=${delta} MB"
      (( delta > max_delta )) && max_delta=$delta
      ( do_rsync "${SERVERS[$i]}" "${STS_NAME}-${i}" \
          "--archive --checksum --verbose --progress --partial" ) &
    done
    wait
    log "  Max delta after iter ${iter}: ${max_delta} MB"
    (( max_delta < DELTA_THRESHOLD_MB )) && { ok "Ready for Phase 3"; return; }
  done
  warn "Delta still above threshold — proceed to Phase 3 anyway"
}

phase_3() {
  log "=== Phase 3: Final Sync (write pause) ==="
  log "  Options to pause writes on old servers:"
  log "    A) iptables -A INPUT -p tcp --dport 8080 -j DROP"
  log "    B) Deregister from ALB target group"
  log "    C) Application read-only mode"
  read -r -p "  Confirm writes are paused (type 'yes'): " c
  [[ "$c" != "yes" ]] && { log "Aborted."; exit 0; }
  START=$(date +%s)
  for i in "${!SERVERS[@]}"; do
    ( do_rsync "${SERVERS[$i]}" "${STS_NAME}-${i}" \
        "--archive --checksum --delete --verbose --stats" ) &
  done
  wait
  DURATION=$(( $(date +%s) - START ))
  ok "Final sync done in ${DURATION}s ($(( DURATION/60 ))m $(( DURATION%60 ))s)"
  (( DURATION > 300 )) && warn "Exceeded 5-min target" || ok "Within 5-min target"
}

phase_4() {
  log "=== Phase 4: Validation ==="
  PASS=0; FAIL=0
  for i in "${!SERVERS[@]}"; do
    SERVER="${SERVERS[$i]}"; POD="${STS_NAME}-${i}"
    old=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER}" \
      "find ${SRC_DIR} -name '*.ldb' 2>/dev/null | wc -l" || echo "-1")
    new=$(kubectl exec "$POD" -n "$NAMESPACE" -- \
      sh -c "find ${DST_DIR} -name '*.ldb' 2>/dev/null | wc -l" || echo "-1")
    [[ "$old" == "$new" && "$old" != "-1" ]] \
      && { ok "  $POD SST count matches: $old"; (( PASS++ )); } \
      || { warn "  $POD mismatch old:$old new:$new"; (( FAIL++ )); }
    man=$(kubectl exec "$POD" -n "$NAMESPACE" -- \
      sh -c "ls ${DST_DIR}/MANIFEST-* 2>/dev/null | wc -l" || echo "0")
    [[ "$man" -gt 0 ]] && { ok "  $POD MANIFEST present"; (( PASS++ )); } \
                       || { warn "  $POD no MANIFEST"; (( FAIL++ )); }
    http=$(kubectl exec "$POD" -n "$NAMESPACE" -- \
      sh -c "curl -sf -o /dev/null -w '%{http_code}' http://localhost:8080/healthz" || echo "000")
    [[ "$http" == "200" ]] && { ok "  $POD /healthz → 200"; (( PASS++ )); } \
                           || { warn "  $POD /healthz → $http"; (( FAIL++ )); }
  done
  log "=== PASS=${PASS} FAIL=${FAIL} ==="
  [[ "$FAIL" -gt 0 ]] && die "Validation FAILED" || ok "All checks passed — safe to cut over"
}

phase_5() {
  log "=== Phase 5: Cut Over ==="
  EKS_ALB=$(kubectl get svc -n "$NAMESPACE" "${STS_NAME}-lb" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "not-provisioned")
  log "  EKS ALB: ${EKS_ALB}"
  log ""
  log "  Option A — DNS flip (TTL must be 60s, set 24h before):"
  log "    aws route53 change-resource-record-sets --hosted-zone-id Z123 --change-batch '{"
  log '    "Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"api.ninox.com",'
  log "    \"Type\":\"CNAME\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"${EKS_ALB}\"}]}}]}'"
  log ""
  log "  Option B — ALB weighted routing (safest):"
  log "    Shift: 5% → 25% → 50% → 100% with auto-rollback if errors > 1%"
  log ""
  log "  After cutover: keep old servers on standby 2 weeks"
  log "  Monitor: kubectl port-forward svc/prometheus-stack-grafana -n monitoring 3000:80"
}

case "$PHASE" in
  1) phase_1 ;; 2) phase_2 ;; 3) phase_3 ;;
  4) phase_4 ;; 5) phase_5 ;;
  *) die "Phase must be 1–5" ;;
esac
