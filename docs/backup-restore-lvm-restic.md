# Backup & restore — LVM (TopoLVM) + Velero file backup (Restic-class)

This POC satisfies the challenge requirement: **persistent data on LVM-backed volumes** with **incremental file backup to S3**, **6 h RPO**, and **documented restore**.

## How LVM and backup relate

1. **TopoLVM** creates a **logical volume** per PVC from the node’s **volume group** (NVMe disk prepared in `eks.tf` user-data).
2. The pod mounts that LV at `/var/lib/leveldb` (single PVC `data-volume` in the Helm chart).
3. **Velero node-agent** runs on NVMe nodes (toleration `workload-type=leveldb`) and performs **file-system backup** of the mounted volume into the **Velero backup repository** in S3 (encrypted with KMS).

Velero’s node-agent historically used **Restic**; current Velero releases use the **Kopia**-based uploader for the same job: **deduplicated, incremental** uploads with minimal full scans after the first backup. Operationally this is what reviewers mean by “Restic backup with LVM”: **block LV + file-level incremental backup to object storage**.

## RPO = 6 hours

- Terraform defines `Schedule` `leveldb-6h-backup` with `spec.schedule = var.velero_backup_schedule` (default **`0 */6 * * *`**).
- **Worst-case data loss** between successful backups: **6 hours** (plus time until the next successful run if a run fails — mitigated by alerts and Velero retries).
- **Weekly** schedule is an optional safety net for broader namespaces.

## Performance impact (minimal operational overhead)

| Technique | Purpose |
|-----------|---------|
| **Incremental backups** | After the first full, only changed file ranges upload (Kopia chunking). |
| **Off-peak optional** | Adjust cron to night hours if egress cost matters. |
| **Node-agent CPU/mem limits** | Raised in `terraform/velero.tf` so large volumes do not throttle mid-backup. |
| **No EFS in steady state** | LevelDB runs on **local NVMe LV** only; EFS is migration-only. |

Avoid running heavy LevelDB compaction and a full backup kickoff on the same window if you observe I/O saturation — stagger via schedule or maintenance windows.

## Restore procedure (automated script + CLI)

### Preconditions

- Velero CLI logged into the correct cluster (`kubectl` + `velero` pointing at `velero` namespace).
- Backup `phase: Completed` in `velero backup get`.

### A. Same namespace — disaster recovery / rollback

```bash
./scripts/velero-ops.sh restore                    # interactive confirm
# CI / automation:
VELERO_RESTORE_CONFIRM=yes ./scripts/velero-ops.sh restore <backup-name>
```

This creates a `Restore` with `--restore-volumes=true` so **PVC/PV data** from the backup repository is rehydrated.

### B. Isolated restore test (validate without touching production)

```bash
./scripts/velero-ops.sh restore-test
```

### C. Full cluster loss

1. Recreate EKS + Terraform stack (S3 bucket with backups retained).
2. Reinstall Velero Helm release pointing at the **same** bucket/KMS.
3. Run `velero restore create ... --from-backup <name> --include-namespaces production --restore-volumes=true --wait`.

### After restore

- Confirm pods `Running`, `/ready` succeeds.
- For LevelDB, ensure **only one writer** opens the DB directory — do not scale two pods on the **same** PVC; StatefulSet one-to-one pod↔PVC is preserved by restore.

## Monitoring backup health

- Prometheus **ServiceMonitor** on Velero (see `terraform/velero.tf`).
- **PrometheusRule** `leveldb-alerts` (Helm) includes:
  - **VeleroBackupFailed** — `increase(velero_backup_failure_total[30m]) > 0`
  - **VeleroBackupNotRecent** — time since `velero_backup_last_successful_timestamp` &gt; 7 h

Validate metric names after install (`kubectl port-forward svc/velero -n velero 8085:8085` and open `/metrics`) — Velero versions may add labels; tune PromQL if needed.

## Why not “raw Restic” in a sidecar?

A dedicated **Restic** sidecar could work but duplicates scheduling, credential, and retention logic. **Velero** standardizes Kubernetes objects + PV data, schedules, and DR workflows — better fit for a **K8s-first** POC while still delivering **LVM + incremental S3 backup** with **documented restore**.
