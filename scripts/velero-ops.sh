#!/bin/bash
# ──────────────────────────────────────────────────────────────────
# velero-ops.sh — Day-to-day Velero backup operations
#
# Commands:
#   status          Show schedules, recent backups, BSL health
#   backup          Trigger manual backup now
#   restore BACKUP  Restore a named backup to production namespace
#   restore-test    Restore latest to isolated test namespace + validate
#   list            List all backups with size and status
#   logs BACKUP     Show logs for a specific backup
# ──────────────────────────────────────────────────────────────────
set -euo pipefail

CMD="${1:-status}"
NAMESPACE="production"
VELERO_NS="velero"

ok()  { echo "✓ $*"; }
log() { echo "[$(date '+%H:%M:%S')] $*"; }
warn(){ echo "⚠ $*" >&2; }
die() { echo "✗ ERROR: $*" >&2; exit 1; }

# ── status ────────────────────────────────────────────────────────
cmd_status() {
  echo "════════════════════════════════════════"
  echo " Velero Status"
  echo "════════════════════════════════════════"

  echo ""
  echo "── Schedules ──"
  velero schedule get 2>/dev/null || echo "(none)"

  echo ""
  echo "── BackupStorageLocation ──"
  velero backup-location get 2>/dev/null || echo "(none)"

  echo ""
  echo "── Last 5 Backups ──"
  velero backup get 2>/dev/null | head -7 || echo "(none)"

  echo ""
  echo "── Node Agent DaemonSet ──"
  kubectl get daemonset -n "$VELERO_NS" node-agent 2>/dev/null \
    || echo "(node-agent not found)"

  echo ""
  echo "── Velero Pod ──"
  kubectl get pods -n "$VELERO_NS" -l app.kubernetes.io/name=velero 2>/dev/null
}

# ── backup ────────────────────────────────────────────────────────
cmd_backup() {
  NAME="manual-$(date +%Y%m%d-%H%M%S)"
  log "Creating backup: ${NAME}"

  velero backup create "$NAME" \
    --include-namespaces "$NAMESPACE" \
    --default-volumes-to-fs-backup=true \
    --include-cluster-resources=true \
    --ttl 720h \
    --wait

  velero backup describe "$NAME" --details
  ok "Backup ${NAME} complete"
}

# ── restore ───────────────────────────────────────────────────────
cmd_restore() {
  BACKUP="${2:-}"
  [[ -z "$BACKUP" ]] && {
    # Default to latest completed backup
    BACKUP=$(velero backup get -o json 2>/dev/null \
      | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
completed = [i for i in items if i['status'].get('phase') == 'Completed']
if not completed:
    print(''); exit(1)
latest = sorted(completed, key=lambda x: x['metadata']['creationTimestamp'])[-1]
print(latest['metadata']['name'])
" 2>/dev/null || echo "")
    [[ -z "$BACKUP" ]] && die "No completed backups found. Specify: $0 restore <backup-name>"
    log "Using latest backup: ${BACKUP}"
  }

  echo ""
  log "Restoring ${BACKUP} → namespace ${NAMESPACE}"
  echo "WARNING: This will overwrite existing resources in ${NAMESPACE}."
  read -r -p "Type 'yes' to confirm: " confirm
  [[ "$confirm" != "yes" ]] && { log "Aborted."; exit 0; }

  RESTORE_NAME="restore-$(date +%Y%m%d-%H%M%S)"

  velero restore create "$RESTORE_NAME" \
    --from-backup "$BACKUP" \
    --include-namespaces "$NAMESPACE" \
    --restore-volumes=true \
    --existing-resource-policy=update \
    --wait

  log "Restore status:"
  velero restore describe "$RESTORE_NAME"
}

# ── restore-test ──────────────────────────────────────────────────
cmd_restore_test() {
  TEST_NS="velero-restore-test"
  log "=== Automated Restore Test to ${TEST_NS} ==="

  # Get latest backup
  BACKUP=$(velero backup get -o json 2>/dev/null \
    | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
completed = [i for i in items if i['status'].get('phase') == 'Completed'
             and 'leveldb-6h-backup' in i['metadata'].get('labels', {}).get('velero.io/schedule-name', '')]
if not completed:
    items_all = [i for i in items if i['status'].get('phase') == 'Completed']
    completed = items_all
if not completed: exit(1)
latest = sorted(completed, key=lambda x: x['metadata']['creationTimestamp'])[-1]
print(latest['metadata']['name'])
" 2>/dev/null || echo "")

  [[ -z "$BACKUP" ]] && die "No completed backup found for restore test"
  log "Testing restore of: ${BACKUP}"

  # Create isolated namespace
  kubectl create namespace "$TEST_NS" --dry-run=client -o yaml | kubectl apply -f -

  # Restore into test namespace
  velero restore create "test-$(date +%s)" \
    --from-backup "$BACKUP" \
    --namespace-mappings "${NAMESPACE}:${TEST_NS}" \
    --restore-volumes=true \
    --wait

  # Validate
  log "Validating restored pods..."
  sleep 30   # Wait for pod startup

  POD="ninox-leveldb-0"
  kubectl wait --for=condition=ready pod/"$POD" \
    -n "$TEST_NS" --timeout=300s 2>/dev/null \
    || warn "Pod not ready within 5 min"

  HEALTH=$(kubectl exec "$POD" -n "$TEST_NS" -- \
    sh -c "curl -sf -o /dev/null -w '%{http_code}' http://localhost:8080/healthz" \
    2>/dev/null || echo "000")

  MANIFEST=$(kubectl exec "$POD" -n "$TEST_NS" -- \
    sh -c "ls /var/lib/leveldb/MANIFEST-* 2>/dev/null | wc -l" \
    || echo "0")

  echo ""
  echo "── Test Results ──"
  echo "  Health check: HTTP ${HEALTH} $([[ $HEALTH == 200 ]] && echo ✓ || echo ✗)"
  echo "  MANIFEST:     ${MANIFEST} file(s) $([[ $MANIFEST -gt 0 ]] && echo ✓ || echo ✗)"

  # Cleanup
  kubectl delete namespace "$TEST_NS" --ignore-not-found
  log "Test namespace cleaned up"

  if [[ "$HEALTH" == "200" && "$MANIFEST" -gt 0 ]]; then
    ok "Restore test PASSED"
  else
    die "Restore test FAILED — review logs above"
  fi
}

# ── list ──────────────────────────────────────────────────────────
cmd_list() {
  velero backup get 2>/dev/null || die "Velero not found"
}

# ── logs ─────────────────────────────────────────────────────────
cmd_logs() {
  BACKUP="${2:-}"
  [[ -z "$BACKUP" ]] && die "Usage: $0 logs <backup-name>"
  velero backup logs "$BACKUP"
}

# ── dispatch ──────────────────────────────────────────────────────
case "$CMD" in
  status)       cmd_status ;;
  backup)       cmd_backup ;;
  restore)      cmd_restore "$@" ;;
  restore-test) cmd_restore_test ;;
  list)         cmd_list ;;
  logs)         cmd_logs "$@" ;;
  *)
    echo "Usage: $0 <status|backup|restore [name]|restore-test|list|logs <name>>"
    exit 1
    ;;
esac
