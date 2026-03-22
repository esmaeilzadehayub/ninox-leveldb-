#!/bin/bash
# velero-ops.sh — Day-to-day Velero operations
# Usage: ./velero-ops.sh <status|backup|restore [name]|restore-test|list>
set -euo pipefail
CMD="${1:-status}"; NAMESPACE="production"; VELERO_NS="velero"
ok()  { echo "✓ $*"; }; log() { echo "[$(date '+%H:%M:%S')] $*"; }; die() { echo "✗ $*" >&2; exit 1; }

case "$CMD" in
  status)
    echo "── Schedules ──";    velero schedule get 2>/dev/null || echo "(none)"
    echo "── BSL ──";          velero backup-location get 2>/dev/null || echo "(none)"
    echo "── Last 5 backups ──"; velero backup get 2>/dev/null | head -7 || echo "(none)"
    echo "── Pods ──";         kubectl get pods -n "$VELERO_NS" 2>/dev/null ;;
  backup)
    NAME="manual-$(date +%Y%m%d-%H%M%S)"
    velero backup create "$NAME" --include-namespaces "$NAMESPACE" \
      --default-volumes-to-fs-backup=true --include-cluster-resources=true \
      --ttl 720h --wait
    ok "Backup ${NAME} complete" ;;
  restore)
    BACKUP="${2:-$(velero backup get -o json 2>/dev/null \
      | python3 -c "import sys,json; items=[i for i in json.load(sys.stdin).get('items',[]) if i['status'].get('phase')=='Completed']; print(sorted(items,key=lambda x:x['metadata']['creationTimestamp'])[-1]['metadata']['name'] if items else '')" 2>/dev/null || echo "")}"
    [[ -z "$BACKUP" ]] && die "No completed backups. Specify: $0 restore <name>"
    if [[ "${VELERO_RESTORE_CONFIRM:-}" != "yes" ]]; then
      read -r -p "Restore ${BACKUP} to ${NAMESPACE}? (yes): " c
      [[ "$c" == "yes" ]] || { log "Aborted."; exit 0; }
    fi
    # FS backups of TopoLVM PVCs → restore-volumes repopulates the LV from object storage
    velero restore create "restore-$(date +%s)" --from-backup "$BACKUP" \
      --include-namespaces "$NAMESPACE" --restore-volumes=true --existing-resource-policy=update --wait ;;
  restore-test)
    TEST_NS="velero-restore-test"
    BACKUP=$(velero backup get -o json 2>/dev/null \
      | python3 -c "import sys,json; items=[i for i in json.load(sys.stdin).get('items',[]) if i['status'].get('phase')=='Completed']; print(sorted(items,key=lambda x:x['metadata']['creationTimestamp'])[-1]['metadata']['name'] if items else '')" 2>/dev/null || echo "")
    [[ -z "$BACKUP" ]] && die "No completed backups"
    kubectl create namespace "$TEST_NS" --dry-run=client -o yaml | kubectl apply -f -
    velero restore create "test-$(date +%s)" --from-backup "$BACKUP" \
      --namespace-mappings "${NAMESPACE}:${TEST_NS}" --restore-volumes=true --wait
    sleep 30
    HTTP=$(kubectl exec ninox-leveldb-0 -n "$TEST_NS" -- \
      sh -c "curl -sf -o /dev/null -w '%{http_code}' http://localhost:8080/healthz" 2>/dev/null || echo "000")
    kubectl delete namespace "$TEST_NS" --ignore-not-found
    [[ "$HTTP" == "200" ]] && ok "Restore test PASSED" || die "Restore test FAILED (HTTP ${HTTP})" ;;
  list) velero backup get ;;
  *)    echo "Usage: $0 <status|backup|restore [name]|restore-test|list>"; exit 1 ;;
esac
