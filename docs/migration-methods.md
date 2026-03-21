# Migration Methods — EFS to NVMe PVC

## Summary Table

| Method | Complexity | Cost | Performance | Best For |
|---|---|---|---|---|
| **Method 1 — Hydration** | Medium | High (EFS + copy time) | **Excellent** (app on NVMe) | Production (recommended) |
| **Method 2 — Double-mount** | Low | High (EFS ongoing) | Good (NVMe, but EFS billed) | Verification / testing |
| **Method 3 — Velero/S3** | High | **Lowest** (no EFS) | **Excellent** (app on NVMe) | Large datasets, cost-conscious |

---

## Method 1 — Hydration initContainer (Recommended)

EFS is used as a one-time seed. On pod first boot, an `initContainer` copies 2 TB from EFS to the NVMe LV. After that, the app runs entirely on NVMe. EFS is never touched again.

```yaml
initContainers:
  - name: data-sync-from-efs
    image: alpine:3.19
    command:
      - /bin/sh
      - -c
      - |
        # Only copy if NVMe is empty (first run — not pod restart)
        if [ -z "$(ls -A /data)" ]; then
          echo "NVMe empty — hydrating from EFS..."
          rsync --archive --checksum --exclude LOCK /mnt/efs/ /data/
          echo "Hydration complete"
        else
          echo "NVMe already has data — skipping hydration"
        fi
    volumeMounts:
      - name: lvm-storage      # NVMe destination (ReadWriteOnce)
        mountPath: /data
      - name: efs-migration    # EFS source (ReadOnlyMany)
        mountPath: /mnt/efs
        readOnly: true
```

**Why `rsync` instead of `cp -rav`:**
- `rsync --checksum` skips identical files on retry — crucial if the pod restarts mid-copy
- Shows progress and transfer stats for 2 TB visibility
- `--exclude LOCK` prevents the LevelDB LOCK file being copied (would prevent DB from opening)

**Timeline for 2 TB copy:**
- EFS → NVMe on same node: ~300 MB/s = ~2 hours
- initContainer timeout is set to 60 min in Helm deploy (`--timeout 60m`)

---

## Method 2 — Double-mount

Both volumes mounted simultaneously. App reads/writes NVMe. EFS visible as read-only archive.

```yaml
containers:
  - name: application
    volumeMounts:
      - name: lvm-storage            # Primary — NVMe LVM
        mountPath: /var/lib/leveldb
      - name: efs-migration          # Secondary — EFS archive (read-only)
        mountPath: /mnt/migration-archive
        readOnly: true
```

**Use case:** Side-by-side verification before committing to the migrated data.

```bash
# Compare file counts between old EFS data and new NVMe data
kubectl exec ninox-leveldb-0 -n production -- sh -c "
  echo 'EFS (original):  '$(ls /mnt/migration-archive/*.ldb 2>/dev/null | wc -l)
  echo 'NVMe (migrated): '$(ls /var/lib/leveldb/*.ldb 2>/dev/null | wc -l)"
```

**Switch to production mode** (remove EFS) when satisfied:
```bash
helm upgrade ninox-leveldb helm/ninox-leveldb \
  --set migration.method=none \
  --set migration.efsFileSystemId=''
```

---

## Method 3 — Velero/S3 (No EFS)

DataSync writes directly to S3. Velero restores from S3 into the NVMe PVC. No EFS cost.

```
On-Prem Server
  /data/leveldb/
       │
       │ DataSync (aws_datasync_task.to_s3)
       ▼
  S3 Bucket: ninox-migration-staging
  /leveldb/pod-0/
  /leveldb/pod-1/
  /leveldb/pod-2/
       │
       │ Velero restore
       ▼
  NVMe PVC: data-volume-ninox-leveldb-{0,1,2}
  /var/lib/leveldb/
```

**Run the restore:**
```bash
# 1. Register S3 migration data as a Velero backup location
velero backup-location create migration-source \
  --provider aws \
  --bucket ninox-migration-staging \
  --prefix leveldb/pod-0 \
  --config region=eu-west-1

# 2. Restore to production namespace
velero restore create migration-restore \
  --from-backup <backup-name> \
  --include-namespaces production \
  --restore-volumes=true \
  --wait

# 3. Verify
velero restore describe migration-restore
kubectl get pods -n production
```

---

## Choosing the Right Method

```
Do you need ongoing access to original data for comparison?
├── YES → Method 2 (double-mount), then switch to Method 1 after verification
└── NO  →
         Is EFS cost a concern (>$0.30/GB/month)?
         ├── YES → Method 3 (Velero/S3 — no EFS)
         └── NO  → Method 1 (Hydration — simplest automation)
```

---

## Post-migration cleanup

After confirming the app is healthy with migrated data:

```bash
# 1. Remove EFS PVCs and PVs
for i in 0 1 2; do
  kubectl delete pvc efs-migration-staging-pod${i} -n production
  kubectl delete pv efs-migration-pv-pod${i}
done

# 2. Remove EFS + DataSync Terraform resources
terraform destroy \
  -target=aws_datasync_task.to_efs \
  -target=aws_efs_file_system.staging \
  -target=aws_s3_bucket.migration

# 3. Remove EFS CSI addon (no longer needed)
terraform destroy -target=aws_eks_addon.efs_csi \
                  -target=module.efs_csi_irsa

# 4. Set migration.method=none in Helm
helm upgrade ninox-leveldb helm/ninox-leveldb \
  --set migration.method=none \
  --set migration.efsFileSystemId=''
```
