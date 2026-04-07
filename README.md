# Ninox — LevelDB on Kubernetes

Production EKS infrastructure for Ninox's stateful LevelDB application.  
## Architecture

See **[docs/architecture.md](docs/architecture.md)** (diagram + trade-offs) and **[docs/backup-restore-lvm-restic.md](docs/backup-restore-lvm-restic.md)** (LVM + Velero FS backup, RPO, restore).

<img width="1536" height="1024" alt="image" src="https://github.com/user-attachments/assets/600031ec-7757-4cc9-8d18-764dac1f5e5f" />

```
── Migration Strategy 

Migration:
  On-Prem ──DataSync──► EFS ──initContainer──► NVMe PVC (Method 1)
  On-Prem ──DataSync──► EFS ──double-mount──►  NVMe + EFS (Method 2)
  On-Prem ──DataSync──► S3  ──Velero restore►  NVMe PVC (Method 3)
```

---

## Quick Start

```bash
# 1. Bootstrap Terraform state (one-time)
aws s3 mb s3://ninox-terraform-state --region eu-west-1
aws dynamodb create-table --table-name ninox-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region eu-west-1

# 2. Deploy full stack (~25 min)
cd terraform
terraform init
terraform apply -var="grafana_admin_password=YOUR_PASSWORD"

# 3. Connect kubectl
aws eks update-kubeconfig --name ninox-production --region eu-west-1

# 4. Deploy app
helm upgrade --install ninox-leveldb helm/ninox-leveldb \
  --namespace production --create-namespace \
  --set image.tag=v1.0.0 \
  --wait

# 5. Verify
velero schedule get                  # 6h backup schedule active
velero backup-location get           # BSL: Available (S3 reachable)
kubectl get pods -n production       # 3/3 Running
kubectl port-forward svc/prometheus-stack-grafana -n monitoring 3000:80
```

---

## Migration from on-premises

Three methods — see [docs/migration-methods.md](docs/migration-methods.md).

### Method 1 — Hydration (Recommended)

```bash
# 1. DataSync copies data overnight (EFS destination)
#    Set datasync_agent_arns + old_server_ips in terraform.tfvars
terraform apply  # creates DataSync tasks + EFS

# 2. Start DataSync
aws datasync start-task-execution --task-arn <arn>

# 3. Deploy with hydration method (initContainer copies EFS → NVMe)
export EFS_ID=$(terraform output -raw efs_filesystem_id)
METHOD=hydration ./scripts/efs-mount-and-copy.sh
```

### Method 2 — Double-mount

```bash
METHOD=double-mount EFS_ID=fs-xxxx ./scripts/efs-mount-and-copy.sh
```

### Method 3 — Velero/S3 (no EFS cost)

```bash
METHOD=velero ./scripts/efs-mount-and-copy.sh
# Follow printed instructions for Velero restore
```

### rsync migration (no DataSync)

```bash
export OLD_SERVERS="db1.prod.internal,db2.prod.internal,db3.prod.internal"
./scripts/rsync-migrate.sh 1  # Bulk copy
./scripts/rsync-migrate.sh 2  # Catch-up (repeat)
./scripts/rsync-migrate.sh 3  # Final sync (< 5 min pause)
./scripts/rsync-migrate.sh 4  # Validate
./scripts/rsync-migrate.sh 5  # Cut over
```

---

## Repository layout

```
ninox-k8s/
├── Dockerfile
├── terraform/
│   ├── versions.tf         Provider pins + S3 backend
│   ├── variables.tf        All inputs (migration_method, EFS, etc.)
│   ├── vpc.tf              VPC module — 3 AZ, public + private
│   ├── eks.tf              EKS v19 — i4i.xlarge NVMe + LVM userdata
│   ├── s3.tf               Velero + Loki + migration S3 buckets
│   ├── iam.tf              IRSA: Velero, Loki, App, DataSync, CI/CD
│   ├── topolvm.tf          TopoLVM — NVMe StorageClass
│   ├── velero.tf           Velero Helm + 6h + weekly schedules
│   ├── monitoring.tf       Prometheus + Loki + Promtail + alerts
│   ├── migration.tf        DataSync + EFS (Methods 1/2) or S3 (Method 3)
│   └── outputs.tf
├── helm/ninox-leveldb/
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── statefulset.yaml  All 3 migration methods as conditional blocks
│       ├── service.yaml      Headless + ClusterIP + PDB + ServiceMonitor + VPA
│       └── prometheusrule.yaml
├── k8s/migration/
│   └── efs-pvcs.yaml         EFS PVs + PVCs (one per pod)
├── scripts/
│   ├── efs-mount-and-copy.sh All 3 migration methods orchestration
│   ├── rsync-migrate.sh      5-phase rsync migration (no DataSync)
│   └── velero-ops.sh         Backup / restore / restore-test
├── docs/
│   └── migration-methods.md  Method comparison + trade-offs
└── .github/workflows/
    ├── ci.yaml               Lint + Test + Trivy + ECR push
    └── deploy.yaml           Terraform apply + Helm deploy on tag
```

---

## Velero backup operations

```bash
./scripts/velero-ops.sh status        # schedules + BSL health + last 5 backups
./scripts/velero-ops.sh backup        # manual backup now
./scripts/velero-ops.sh restore       # restore from latest backup
./scripts/velero-ops.sh restore-test  # restore to isolated namespace + validate
```

---

## Key design decisions

| Decision | Rationale |
|---|---|
| **Single TopoLVM PVC per pod** | One LV holds LevelDB data; init + app + backup must share it (two PVCs would split hydration vs runtime data). |
| **i4i.4xlarge NVMe nodes** | ~2 Ti per pod needs **3750 GB** local NVMe; `i4i.xlarge` . |
| NVMe over gp3 EBS for DB | Local NVMe latency and IOPS fit LevelDB compaction; TopoLVM on NVMe. |
| EFS not for steady-state LevelDB | NFS semantics break single-writer / LOCK expectations; use only as migration source. |
| VPA vs HPA | **VPA** for CPU/RAM per replica; **HPA** only if you intentionally run **sharded** DBs (each replica = separate dataset). |
| Method 1 (Hydration) | App runs on NVMe; EFS is a one-time seed. |
| Velero **node-agent** every **6h** | Meets **6h RPO**; FS backup of the LVM mount to S3 (Kopia uploader in current Velero — same class as legacy Restic). |

---

## GitHub Secrets required

| Secret | Value |
|---|---|
| `AWS_ACCOUNT_ID` | 12-digit AWS account ID |
| `GRAFANA_PASSWORD` | Grafana admin password |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook |
| `PAGERDUTY_KEY` | PagerDuty routing key |
