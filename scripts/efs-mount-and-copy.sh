#!/bin/bash
# ──────────────────────────────────────────────────────────────────
# efs-mount-and-copy.sh — orchestrate EFS → NVMe PVC data copy
#
# This script implements all three migration methods.
# Set METHOD env var before running:
#
#   METHOD=hydration    — (default) initContainer copies at pod startup
#   METHOD=double-mount — mount both EFS + NVMe; verify before switching
#   METHOD=velero       — restore from S3 via Velero (no EFS involved)
#
# PREREQUISITES
# ─────────────
#   export EFS_ID="fs-0abc1234"      # terraform output efs_filesystem_id
#   export NAMESPACE="production"
#   export STS_NAME="ninox-leveldb"
#   export METHOD="hydration"
#
# USAGE
#   ./efs-mount-and-copy.sh
# ──────────────────────────────────────────────────────────────────
set -euo pipefail

EFS_ID="${EFS_ID:-}"
NAMESPACE="${NAMESPACE:-production}"
STS_NAME="${STS_NAME:-ninox-leveldb}"
METHOD="${METHOD:-hydration}"
REPLICA_COUNT=3

log()  { echo "[$(date '+%H:%M:%S')] [$METHOD] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $*"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $*" >&2; }
die()  { echo "[$(date '+%H:%M:%S')] ✗ $*" >&2; exit 1; }

# ════════════════════════════════════════════════════════════════════
# METHOD 1: Hydration via initContainer
# ════════════════════════════════════════════════════════════════════
# The StatefulSet already has the data-sync-from-efs initContainer
# built in (helm/ninox-leveldb/templates/statefulset.yaml).
# This function just ensures the EFS PVCs exist and triggers the deploy.
method_hydration() {
  log "=== Method 1: Hydration initContainer ==="
  log ""
  log "How it works:"
  log "  1. EFS PVC mounted as /mnt/efs inside initContainer"
  log "  2. initContainer runs: if [ -z NVMe ]; then rsync EFS/ → NVMe/"
  log "  3. initContainer exits — EFS unmounts"
  log "  4. Main app starts — sees all data on fast NVMe"
  log "  5. On pod restart: NVMe already has data — hydration skipped"
  log ""

  [[ -z "$EFS_ID" ]] && die "Set EFS_ID env var. Find: terraform output efs_filesystem_id"

  # Apply EFS PVCs
  log "Creating EFS PVCs..."
  sed "s/fs-REPLACE_WITH_ID/${EFS_ID}/g" k8s/migration/efs-pvcs.yaml | kubectl apply -f -
  ok "EFS PVCs created"

  # Wait for EFS PVCs to bind
  for i in 0 1 2; do
    kubectl wait --for=condition=Bound pvc/efs-migration-staging-pod${i} \
      -n "$NAMESPACE" --timeout=120s
    ok "  EFS PVC pod-${i} bound"
  done

  # Deploy/upgrade Helm chart with hydration method
  log "Deploying StatefulSet with hydration initContainer..."
  helm upgrade --install ninox-leveldb helm/ninox-leveldb \
    --namespace "$NAMESPACE" --create-namespace \
    --set migration.method=hydration \
    --set migration.efsFileSystemId="$EFS_ID" \
    --set image.tag="${IMAGE_TAG:-latest}" \
    --wait --timeout 60m   # Allow up to 60 min for 800 GB copy

  ok "Deployment complete. initContainer copied EFS → NVMe on first boot."
  log ""
  log "Verify hydration succeeded:"
  for i in 0 1 2; do
    log "  kubectl logs ${STS_NAME}-${i} -n ${NAMESPACE} -c data-sync-from-efs"
  done

  cleanup_instructions
}

# ════════════════════════════════════════════════════════════════════
# METHOD 2: Double-mount (EFS + NVMe simultaneously)
# ════════════════════════════════════════════════════════════════════
# App runs on NVMe. EFS is mounted read-only at /mnt/migration-archive.
# Useful for verification scripts that compare old vs new data.
method_double_mount() {
  log "=== Method 2: Double-Mount (EFS + NVMe) ==="
  log ""
  log "How it works:"
  log "  /var/lib/leveldb      → NVMe LVM (app reads/writes here)"
  log "  /mnt/migration-archive → EFS read-only (for verification)"
  log ""
  warn "Performance note: LevelDB runs on NVMe (fast). EFS is passive."
  warn "Remove EFS mount after verification to reduce cost + complexity."
  log ""

  [[ -z "$EFS_ID" ]] && die "Set EFS_ID env var"

  log "Creating EFS PVCs..."
  sed "s/fs-REPLACE_WITH_ID/${EFS_ID}/g" k8s/migration/efs-pvcs.yaml | kubectl apply -f -

  log "Deploying StatefulSet with double-mount..."
  helm upgrade --install ninox-leveldb helm/ninox-leveldb \
    --namespace "$NAMESPACE" --create-namespace \
    --set migration.method=double-mount \
    --set migration.efsFileSystemId="$EFS_ID" \
    --set image.tag="${IMAGE_TAG:-latest}" \
    --wait

  ok "Deployment complete."
  log ""
  log "Verify both mounts in a pod:"
  log "  kubectl exec ${STS_NAME}-0 -n ${NAMESPACE} -- df -h"
  log "  kubectl exec ${STS_NAME}-0 -n ${NAMESPACE} -- ls /mnt/migration-archive"
  log "  kubectl exec ${STS_NAME}-0 -n ${NAMESPACE} -- ls /var/lib/leveldb"
  log ""
  log "Compare file counts:"
  log "  kubectl exec ${STS_NAME}-0 -n ${NAMESPACE} -- sh -c '"
  log "    echo EFS: \$(ls /mnt/migration-archive/*.ldb 2>/dev/null | wc -l)"
  log "    echo NVMe: \$(ls /var/lib/leveldb/*.ldb 2>/dev/null | wc -l)'"
  log ""
  log "After verification, switch to method=none to remove EFS mount:"
  log "  helm upgrade ninox-leveldb helm/ninox-leveldb --set migration.method=none ..."

  cleanup_instructions
}

# ════════════════════════════════════════════════════════════════════
# METHOD 3: Velero/S3 restore (no EFS needed)
# ════════════════════════════════════════════════════════════════════
# DataSync copied data to S3. Velero restores it directly to the NVMe PVC.
# Most cost-efficient — no EFS charges.
method_velero() {
  log "=== Method 3: Velero / S3 Restore ==="
  log ""
  log "How it works:"
  log "  1. DataSync has already copied on-prem data to S3"
  log "  2. Import the S3 data as a Velero backup"
  log "  3. Velero restore writes directly to NVMe PVCs"
  log "  4. StatefulSet starts — sees restored data"
  log ""

  BACKUP_BUCKET="${VELERO_BUCKET:-$(terraform -chdir=terraform output -raw velero_s3_bucket 2>/dev/null || echo '')}"
  [[ -z "$BACKUP_BUCKET" ]] && die "Set VELERO_BUCKET env var or run from terraform dir"

  # Verify Velero is installed
  velero backup-location get &>/dev/null || die "Velero not installed. Run: terraform apply"

  # Check BSL is available (S3 accessible)
  BSL_PHASE=$(velero backup-location get default -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  [[ "$BSL_PHASE" == "Available" ]] || die "Velero BSL not Available (phase: ${BSL_PHASE}). Check S3 + IRSA."

  log "Velero BSL: Available ✓"
  log ""
  log "Manual steps for Method 3:"
  log ""
  log "  Step 1: Verify DataSync completed:"
  log "    aws datasync list-task-executions --query 'TaskExecutions[*].Status'"
  log ""
  log "  Step 2: List available backups:"
  log "    velero backup get"
  log ""
  log "  Step 3: If migrating from S3 (not a prior Velero backup),"
  log "  register the S3 location as a BSL and sync:"
  log "    velero backup-location create migration-source \\"
  log "      --provider aws \\"
  log "      --bucket ${BACKUP_BUCKET} \\"
  log "      --prefix migration-data \\"
  log "      --config region=${AWS_REGION:-eu-west-1}"
  log "    velero backup-location get  # wait for Available"
  log ""
  log "  Step 4: Restore to production namespace:"
  log "    velero restore create migration-restore-\$(date +%s) \\"
  log "      --from-backup <backup-name> \\"
  log "      --include-namespaces ${NAMESPACE} \\"
  log "      --restore-volumes=true \\"
  log "      --wait"
  log ""
  log "  Step 5: Verify:"
  log "    kubectl get pods -n ${NAMESPACE}"
  log "    velero restore describe migration-restore-*"
}

# ════════════════════════════════════════════════════════════════════
# VALIDATION — run after any method
# ════════════════════════════════════════════════════════════════════
validate() {
  log "=== Validating migration ==="
  PASS=0; FAIL=0

  kubectl rollout status sts/"$STS_NAME" -n "$NAMESPACE" --timeout=300s

  for i in 0 1 2; do
    POD="${STS_NAME}-${i}"
    log "  Checking ${POD}..."

    # Health check
    HTTP=$(kubectl exec "$POD" -n "$NAMESPACE" -- \
      sh -c "curl -sf -o /dev/null -w '%{http_code}' http://localhost:8080/healthz 2>/dev/null" \
      || echo "000")
    [[ "$HTTP" == "200" ]] && { ok "  $POD /healthz → 200"; (( PASS++ )); } \
                           || { warn "  $POD /healthz → $HTTP"; (( FAIL++ )); }

    # MANIFEST file
    MAN=$(kubectl exec "$POD" -n "$NAMESPACE" -- \
      sh -c "ls /var/lib/leveldb/MANIFEST-* 2>/dev/null | wc -l" || echo "0")
    [[ "$MAN" -gt 0 ]] && { ok "  $POD MANIFEST present"; (( PASS++ )); } \
                       || { warn "  $POD no MANIFEST"; (( FAIL++ )); }
  done

  log ""
  log "  Result: PASS=${PASS} FAIL=${FAIL}"
  [[ "$FAIL" -gt 0 ]] && die "Validation FAILED" || ok "Validation PASSED"
}

cleanup_instructions() {
  log ""
  log "=== After confirming the app is healthy, clean up EFS ==="
  log ""
  log "  # Delete EFS PVCs"
  for i in 0 1 2; do
    log "  kubectl delete pvc efs-migration-staging-pod${i} -n ${NAMESPACE}"
    log "  kubectl delete pv efs-migration-pv-pod${i}"
  done
  log ""
  log "  # Remove EFS + DataSync Terraform resources"
  log "  terraform destroy -target=aws_datasync_task.to_efs \\"
  log "                    -target=aws_efs_file_system.staging"
  log ""
  log "  # Switch Helm to no migration"
  log "  helm upgrade ninox-leveldb helm/ninox-leveldb \\"
  log "    --set migration.method=none \\"
  log "    --set migration.efsFileSystemId=''"
}

# ── Main dispatcher ───────────────────────────────────────────────
log "Migration method: ${METHOD}"
log ""

case "$METHOD" in
  hydration)    method_hydration ;;
  double-mount) method_double_mount ;;
  velero)       method_velero ;;
  validate)     validate ;;
  *)            die "METHOD must be: hydration | double-mount | velero | validate" ;;
esac
