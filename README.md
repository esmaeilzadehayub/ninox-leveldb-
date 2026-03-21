# Ninox — LevelDB on Kubernetes

> Production-grade stateful application on EKS with NVMe storage, Velero/Restic backups, ELK logging, Jaeger tracing, and a blue-green migration strategy.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  CI/CD Pipeline                                                              │
│  Code ──► GitHub Actions ──► Docker Build ──► Trivy Scan ──► ECR ──► EKS  │
└──────────────────────────────────────┬───────────────────────────────────────┘
                                       │
┌──────────────────────────────────────▼───────────────────────────────────────┐
│  Kubernetes Cluster  (EKS · eu-west-1 · 3 AZs)                              │
│                                                                              │
│  ┌────────────────── StatefulSet ────────────────────┐                       │
│  │   App Pod 1        App Pod 2        App Pod 3     │                       │
│  │   LevelDB          LevelDB          LevelDB       │                       │
│  │      │                │                │          │                       │
│  │   PV (NVMe)       PV (NVMe)       PV (NVMe)      │                       │
│  │      └────────────────┴────────────────┘          │                       │
│  │               LevelDB Storage (TopoLVM)           │                       │
│  └──────────────────────────────────────┬────────────┘                       │
│                                         │                                    │
│              ┌──────────────────────────┴──────────────────────┐             │
│              │  LVM & Backup                                   │             │
│              │  LVM Snapshot ──► Restic/Kopia ──► S3 Bucket   │             │
│              │  Velero Schedule: every 6 h                     │             │
│              └─────────────────────────────────────────────────┘             │
│                                                                              │
│  ┌── Security ──────────────────────────────────────────────────────────┐   │
│  │  RBAC · TLS (cert-manager) · Wazuh (FIM + IDS) · OPA Gatekeeper     │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────────┘
         │                          │                           │
         ▼                          ▼                           ▼
┌─ Monitoring ───────┐   ┌─ Logging (ELK) ──────────┐  ┌─ Tracing ──────────┐
│  Prometheus        │   │  Elasticsearch            │  │  Jaeger            │
│  Grafana           │   │  Logstash                 │  │  OpenTelemetry SDK │
│  Alertmanager      │   │  Kibana                   │  └────────────────────┘
└────────────────────┘   └───────────────────────────┘

── Migration Strategy ──────────────────────────────────────────────────────────
  Sync Data  ──►  Blue-Green Deploy  ──►  Traffic Switch  ──►  Cutover
```

---

## Table of Contents

1. [Components](#components)
2. [Repository Layout](#repository-layout)
3. [Prerequisites](#prerequisites)
4. [Quick Start](#quick-start)
5. [Infrastructure — Terraform](#infrastructure--terraform)
6. [Storage — NVMe + LVM + TopoLVM](#storage--nvme--lvm--topolvm)
7. [Backup & Restore — Velero + Restic](#backup--restore--velero--restic)
8. [CI/CD Pipeline](#cicd-pipeline)
9. [Monitoring & Alerting](#monitoring--alerting)
10. [Logging — ELK Stack](#logging--elk-stack)
11. [Distributed Tracing — Jaeger](#distributed-tracing--jaeger)
12. [Security — RBAC, TLS, Wazuh](#security--rbac-tls-wazuh)
13. [Migration Strategy](#migration-strategy)
14. [Operations Runbook](#operations-runbook)
15. [Design Decisions](#design-decisions)

---

## Components

| Layer | Component | Purpose |
|---|---|---|
| **Compute** | EKS + `i4i.xlarge` | Kubernetes with local NVMe |
| **Storage** | TopoLVM + LVM on NVMe | Dynamic LV per PVC from 937 GB NVMe disk |
| **Application** | StatefulSet (3 replicas) | LevelDB app, one pod per AZ |
| **Backup** | Velero + Kopia → S3 | File-system backup every 6 h (RPO = 6 h) |
| **Backup (legacy)** | Restic + LVM snapshots | CoW snapshot → S3 per CronJob |
| **CI/CD** | GitHub Actions + ECR | Lint → Test → Trivy → Push → Deploy |
| **Metrics** | Prometheus + Grafana | Cluster, LevelDB, and Velero metrics |
| **Alerting** | Alertmanager | PagerDuty (critical) / Slack (warning) |
| **Logging** | ELK Stack | Elasticsearch + Logstash + Kibana |
| **Tracing** | Jaeger + OpenTelemetry | Distributed request tracing |
| **Security** | RBAC + TLS + Wazuh | Auth, encryption, runtime IDS |

---

## Repository Layout

```
ninox-k8s/
├── Dockerfile
├── terraform/
│   ├── versions.tf          Provider pins + S3 backend
│   ├── variables.tf
│   ├── vpc.tf               VPC module (3 AZ, public + private subnets)
│   ├── eks.tf               EKS module + i4i.xlarge node group (NVMe + LVM)
│   ├── s3.tf                Velero + Loki S3 buckets (KMS, versioning, lifecycle)
│   ├── iam.tf               IRSA roles: Velero, Loki, EBS-CSI, CI/CD
│   ├── topolvm.tf           TopoLVM Helm → StorageClass: topolvm-provisioner
│   ├── velero.tf            Velero Helm + VeleroSchedule every 6 h
│   ├── monitoring.tf        kube-prometheus-stack + Loki + Promtail
│   └── outputs.tf
├── helm/ninox-leveldb/
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── statefulset.yaml      StatefulSet (Velero + Prometheus annotations)
│       ├── vpa.yaml              VerticalPodAutoscaler (Auto mode)
│       ├── prometheusrule.yaml   LevelDB + Velero alert rules
│       └── service.yaml          Headless + ClusterIP + PDB + ServiceMonitor
├── scripts/
│   ├── rsync-migrate.sh     5-phase on-prem → EKS rsync migration
│   └── velero-ops.sh        Backup / restore / restore-test helper
└── .github/workflows/
    ├── ci.yaml              Lint + Test + Trivy + ECR push
    └── deploy.yaml          Terraform apply + Helm deploy on git tag
```

---

## Prerequisites

| Tool | Version |
|---|---|
| `terraform` | ≥ 1.5 |
| `helm` | ≥ 3.14 |
| `kubectl` | ≥ 1.29 |
| `aws-cli` | ≥ 2.15 |
| `velero` CLI | ≥ 1.13 |

---

## Quick Start

### 1 — Bootstrap remote state (one-time)

```bash
aws s3 mb s3://ninox-terraform-state --region eu-west-1

aws dynamodb create-table \
  --table-name ninox-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-west-1
```

### 2 — Deploy the full stack

```bash
cd terraform
terraform init
terraform apply -var="grafana_admin_password=YOUR_SECURE_PASSWORD"
```

`terraform apply` deploys in order:

| Step | What happens |
|---|---|
| 1 | VPC + EKS cluster |
| 2 | `i4i.xlarge` node group — userdata runs `pvcreate` + `vgcreate node-vg` |
| 3 | TopoLVM — exposes `topolvm-provisioner` StorageClass |
| 4 | Velero + S3 BSL — schedule every 6 h active immediately |
| 5 | kube-prometheus-stack — Prometheus + Grafana + Alertmanager |
| 6 | Loki + Promtail — logs → S3 |

### 3 — Connect and deploy the app

```bash
aws eks update-kubeconfig --name ninox-production --region eu-west-1

helm upgrade --install ninox-leveldb helm/ninox-leveldb \
  --namespace production --create-namespace \
  --set image.tag="v1.0.0" \
  --wait
```

### 4 — Verify

```bash
kubectl get pods -n production              # 3/3 Running
velero schedule get                         # leveldb-6h-backup active
velero backup-location get                  # default: Available

# Grafana
kubectl port-forward svc/prometheus-stack-grafana -n monitoring 3000:80
# http://localhost:3000  (admin / your-password)
```

---

## Infrastructure — Terraform

### EKS cluster + NVMe nodes

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "ninox-production"
  cluster_version = "1.28"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets

  eks_managed_node_groups = {
    stateful_nvme = {
      instance_types = ["i4i.xlarge"]  # 4 vCPU · 32 GB · 937 GB NVMe
      min_size       = 3
      max_size       = 6

      pre_bootstrap_user_data = <<-EOT
        #!/bin/bash
        yum install -y lvm2
        pvcreate /dev/nvme1n1
        vgcreate node-vg /dev/nvme1n1
      EOT
    }
  }
}
```

### S3 buckets

```hcl
resource "aws_s3_bucket" "backups" {
  bucket = "ninox-backup-storage-s3"
}

resource "aws_s3_bucket_versioning" "backup_versioning" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration { status = "Enabled" }
}
```

---

## Storage — NVMe + LVM + TopoLVM

### Why `i4i.xlarge`?

| Metric | i4i.xlarge (NVMe) | EBS gp3 |
|---|---|---|
| IOPS | ~275,000 | 16,000 |
| Latency | < 100 µs | 1–3 ms |
| Data survives node loss | No — ephemeral | Yes — persistent |

LevelDB compaction is IOPS-bound. NVMe delivers a **17× IOPS improvement** over EBS.

### LVM layout

```
/dev/nvme1n1  (937 GB)
  └─ PV  (pvcreate)
       └─ VG: node-vg  (vgcreate)
            └─ TopoLVM thin pool
                 ├─ LV for pod-0 PVC  (800 Gi)
                 ├─ LV for pod-1 PVC  (800 Gi)
                 └─ Snapshot space    (~137 Gi)
```

### PVC in StatefulSet

```yaml
volumeClaimTemplates:
  - metadata:
      name: data-volume
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: "topolvm-provisioner"
      resources:
        requests:
          storage: {{ .Values.persistence.size }}  # 800Gi
```

---

## Backup & Restore — Velero + Restic

### Velero schedule (every 6 hours)

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: leveldb-6h-backup
  namespace: velero
spec:
  schedule: "0 */6 * * *"        # RPO = 6 h
  template:
    includedNamespaces:
      - production
    defaultVolumesToFsBackup: true # Kopia streams NVMe LV → S3
    snapshotVolumes: false          # NVMe is local — no EBS snapshot API
    ttl: 720h0m0s                  # 30-day retention
```

### Day-to-day commands

```bash
# Status
velero backup get
velero schedule get

# Manual backup
./scripts/velero-ops.sh backup

# Restore from latest
./scripts/velero-ops.sh restore

# Weekly automated restore test
./scripts/velero-ops.sh restore-test
```

### RPO / RTO

| Metric | Value |
|---|---|
| RPO | 6 hours |
| RTO | ~1–2 hours (800 Gi via Kopia parallel restore) |
| Backup retention | 30 days (6 h) · 90 days (weekly full) |

---

## CI/CD Pipeline

```
Push to main / open PR
  │
  ├─ helm lint
  ├─ terraform fmt -check
  ├─ go test ./...
  ├─ docker build
  ├─ trivy scan  ──► FAIL on CRITICAL CVEs
  │
  └─ (on release tag)
       ├─ ECR push (via GitHub OIDC → IAM, no static keys)
       ├─ terraform apply
       ├─ helm upgrade --atomic  (auto-rollback on failure)
       ├─ velero backup create post-deploy-*
       └─ Slack notification
```

### GitHub Secrets required

| Secret | Value |
|---|---|
| `AWS_ACCOUNT_ID` | 12-digit account ID |
| `GRAFANA_PASSWORD` | Grafana admin password |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook |

---

## Monitoring & Alerting

```hcl
resource "helm_release" "prometheus_stack" {
  name       = "prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = "monitoring"
  create_namespace = true

  values = [yamlencode({
    grafana = { enabled = true }
    prometheus = {
      prometheusSpec = {
        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = "gp3"
              resources = { requests = { storage = "50Gi" } }
            }
          }
        }
      }
    }
  })]
}
```

### Alert rules

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: leveldb-alerts
  namespace: monitoring
spec:
  groups:
    - name: LevelDBStorage
      rules:
        - alert: PersistentVolumeHighUsage
          expr: >
            kubelet_volume_stats_used_bytes
            / kubelet_volume_stats_capacity_bytes > 0.85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "StatefulSet Pod {{ $labels.pod }} storage usage > 85%"
```

### Access

```bash
# Grafana
kubectl port-forward svc/prometheus-stack-grafana -n monitoring 3000:80
```

### Alert routing

| Severity | Destination | SLA |
|---|---|---|
| `critical` | PagerDuty | 15 min |
| `warning` | Slack `#ops-alerts` | Best-effort |

---

## Logging — ELK Stack

```
Pod logs  ──►  Logstash (parse + enrich)  ──►  Elasticsearch  ──►  Kibana
```

### Access Kibana

```bash
kubectl port-forward svc/kibana -n logging 5601:5601
# http://localhost:5601
```

### Useful queries in Kibana

```
# All errors in production namespace
kubernetes.namespace: "production" AND level: "error"

# LevelDB compaction events
message: "Compaction" AND kubernetes.namespace: "production"

# Velero backup activity
kubernetes.namespace: "velero"

# Last hour for a specific pod
kubernetes.pod.name: "ninox-leveldb-0" AND @timestamp: [now-1h TO now]
```

### Log retention

| Tier | Duration |
|---|---|
| Elasticsearch (hot) | 7 days |
| S3 / Loki (warm) | 30 days |
| S3 Glacier IR (cold) | 30–365 days |

---

## Distributed Tracing — Jaeger

```
App (OTel SDK) ──► OTel Collector ──► Jaeger Backend ──► Jaeger UI
```

### Access Jaeger UI

```bash
kubectl port-forward svc/jaeger-query -n monitoring 16686:16686
# http://localhost:16686
```

### What is traced

- Every LevelDB `Get`, `Put`, `Delete`
- Compaction events (with duration)
- Backup job lifecycle (start → LVM snapshot → S3 upload → done)
- HTTP API request end-to-end

---

## Security — RBAC, TLS, Wazuh

### RBAC (least privilege)

| ServiceAccount | Permissions |
|---|---|
| `ninox-leveldb` | Read own PVC + pod metadata only |
| `velero` | S3 backup bucket read/write (IRSA) |
| `loki` | Loki S3 bucket read/write (IRSA) |
| `developer` (human) | `get`, `list`, `exec` in `production` ns |
| `github-actions` | ECR push + `eks:DescribeCluster` (OIDC) |

### TLS

- **Ingress**: cert-manager + Let's Encrypt (auto-renewed)
- **Pod-to-pod**: Linkerd mTLS (transparent, ~2 ms overhead)
- **EBS volumes**: AWS KMS CMK encryption at rest

### Wazuh (Runtime Security)

| Feature | Detects |
|---|---|
| File Integrity Monitoring | Changes to `/var/lib/leveldb`, binaries, `/etc` |
| Rootkit scan | Hidden processes, kernel module injection |
| Intrusion detection | Brute-force, privilege escalation, suspicious syscalls |
| Log analysis | Auth failures, EKS audit log anomalies |

### OPA Gatekeeper

```
✓  Images: ECR only
✓  Resource limits: required on all containers
✓  runAsNonRoot: true
✓  readOnlyRootFilesystem: true
✗  Privileged containers: blocked
✗  hostPath mounts: blocked
```

---

## Migration Strategy

```
Step 1 — Sync Data
  On-prem LevelDB ──rsync──► EKS StatefulSet PVCs
  (live copy, app still running, multiple catch-up iterations)

Step 2 — Blue-Green Deployment
  BLUE = old servers (100% traffic)
  GREEN = EKS cluster (0% traffic, validation + synthetic tests only)

Step 3 — Traffic Switch
  ALB weighted routing:
    5% → GREEN  (monitor 15 min, auto-rollback if errors > 1%)
   25% → GREEN
   50% → GREEN
  100% → GREEN

Step 4 — Cutover
  1. DNS TTL → 60 s  (set 24 h before)
  2. Pause writes on BLUE (< 5 min)
  3. Final rsync (delta only)
  4. Flip DNS → EKS ALB
  5. Resume writes on GREEN

Post-cutover
  - BLUE on standby 2 weeks
  - Decommission after Velero backup integrity confirmed
```

**Total write downtime target: < 5 minutes**

### Run the migration

```bash
export OLD_SERVERS="db1.prod.internal,db2.prod.internal,db3.prod.internal"
export SSH_KEY="~/.ssh/id_rsa"

./scripts/rsync-migrate.sh 1   # Bulk copy (~2 h at 1 Gbps)
./scripts/rsync-migrate.sh 2   # Catch-up (repeat until delta < 100 MB)
./scripts/rsync-migrate.sh 3   # Final sync (brief write pause)
./scripts/rsync-migrate.sh 4   # Validate
./scripts/rsync-migrate.sh 5   # Cut over
```

---

## Operations Runbook

### Pod crash loop

```bash
kubectl describe pod ninox-leveldb-0 -n production | tail -30
kubectl logs ninox-leveldb-0 -n production -c init-leveldb
kubectl logs ninox-leveldb-0 -n production --previous
kubectl delete pod ninox-leveldb-0 -n production  # Force reschedule
```

### PVC nearly full

```bash
kubectl exec ninox-leveldb-0 -n production -- df -h /var/lib/leveldb

# Online expansion (no restart needed)
kubectl patch pvc data-volume-ninox-leveldb-0 -n production \
  --type merge \
  -p '{"spec":{"resources":{"requests":{"storage":"900Gi"}}}}'
```

### Restore from backup

```bash
velero backup get                               # List backups
./scripts/velero-ops.sh restore                 # Restore latest
./scripts/velero-ops.sh restore-test            # Test restore to isolated namespace
```

### Velero backup not running

```bash
kubectl logs -n velero daemonset/node-agent -f  # Check Kopia agent
velero backup-location get                       # Check S3 connectivity
velero schedule get                              # Check schedule is not paused
```

---

## Design Decisions

| Decision | Choice | Reason |
|---|---|---|
| Storage | NVMe (i4i) over EBS | 17× IOPS; LevelDB compaction is I/O-bound |
| Scaling | VPA over HPA | LevelDB is single-process; HPA creates N isolated DBs |
| Backup engine | Velero + Kopia | Local NVMe has no EBS snapshot API; Kopia streams to S3 |
| Service mesh | Linkerd | ~2 ms mTLS overhead vs ~5 ms for Istio |
| Secrets | IRSA (no static keys) | Pod-level IAM via OIDC; zero credential rotation burden |
| Logging | ELK + Loki | ELK for complex analysis; Loki for correlated metrics+logs in Grafana |
| Migration | rsync + blue-green | Proven, simple; < 5 min write pause with delta catch-up |

---

*Maintained by the Ninox Platform Team.*
