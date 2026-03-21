# ──────────────────────────────────────────────────────────────────
# Velero — backup every 6 hours to S3 (Kopia file-system backup)
#
# Why Kopia and not EBS snapshots?
#   TopoLVM LVs are LOCAL NVMe — no EBS snapshot API exists.
#   Kopia (Velero's file-system backup engine since v1.12) streams
#   PVC files directly to S3. LevelDB WAL ensures crash-consistency.
# ──────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "velero" {
  metadata {
    name = "velero"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }

  depends_on = [module.eks]
}

# ── ServiceAccount annotated with IRSA role ───────────────────────
resource "kubernetes_service_account" "velero" {
  metadata {
    name      = "velero"
    namespace = kubernetes_namespace.velero.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = module.velero_irsa.iam_role_arn
    }
  }

  depends_on = [kubernetes_namespace.velero]
}

# ── Velero Helm release ───────────────────────────────────────────
resource "helm_release" "velero" {
  name       = "velero"
  repository = "https://vmware-tanzu.github.io/helm-charts"
  chart      = "velero"
  version    = "6.0.0"
  namespace  = kubernetes_namespace.velero.metadata[0].name

  wait            = true
  timeout         = 300
  atomic          = true
  cleanup_on_fail = true

  depends_on = [
    kubernetes_service_account.velero,
    module.velero_irsa,
    aws_s3_bucket.backups,
    helm_release.topolvm,
  ]

  values = [
    yamlencode({

      # ── Reuse the IRSA ServiceAccount we created above ──────
      serviceAccount = {
        server = {
          create = false
          name   = kubernetes_service_account.velero.metadata[0].name
        }
      }

      # ── No static credentials — IRSA handles auth ───────────
      credentials = {
        useSecret = false
      }

      # ── AWS plugin (S3 object store + EBS snapshot) ─────────
      initContainers = [
        {
          name  = "velero-plugin-for-aws"
          image = "velero/velero-plugin-for-aws:v1.9.0"
          volumeMounts = [
            { mountPath = "/target", name = "plugins" }
          ]
        }
      ]

      # ── Storage locations ────────────────────────────────────
      configuration = {
        backupStorageLocation = [
          {
            name     = "default"
            provider = "aws"
            bucket   = aws_s3_bucket.backups.bucket
            prefix   = "velero"
            default  = true
            config = {
              region               = var.aws_region
              s3ForcePathStyle     = "false"
              serverSideEncryption = "aws:kms"
              kmsKeyId             = aws_kms_key.s3.arn
            }
          }
        ]

        volumeSnapshotLocation = [
          {
            name     = "aws"
            provider = "aws"
            config = {
              region = var.aws_region
            }
          }
        ]
      }

      # ── Kopia file-system backup (for TopoLVM local NVMe) ────
      # defaultVolumesToFsBackup = true means every PVC in a
      # backup is streamed via Kopia unless opted out with:
      #   backup.velero.io/backup-volumes-excludes: <vol-name>
      defaultVolumesToFsBackup = true

      # Required feature flag for CSI policy
      features = "EnableCSIVolumePolicy"

      # ── Node agent DaemonSet ─────────────────────────────────
      # Runs on every NVMe node; Kopia reads the PVC mount point
      deployNodeAgent = true

      nodeAgent = {
        tolerations = [
          { key = "workload-type", operator = "Equal", value = "leveldb", effect = "NoSchedule" },
        ]
        resources = {
          requests = { cpu = "200m", memory = "256Mi" }
          limits   = { cpu = "1",    memory = "1Gi" }
        }
      }

      # ── Main velero pod ──────────────────────────────────────
      resources = {
        requests = { cpu = "500m", memory = "512Mi" }
        limits   = { cpu = "1",    memory = "1Gi" }
      }

      nodeSelector = { "node-role" = "system" }

      # ── Metrics for Prometheus ───────────────────────────────
      metrics = {
        enabled = true
        serviceMonitor = {
          enabled             = true
          additionalLabels    = { release = "prometheus-stack" }
        }
      }

      upgradeCRDs = true
    })
  ]
}

# ════════════════════════════════════════════════════════════════════
# VELERO SCHEDULE — every 6 hours (RPO = 6h)
# ════════════════════════════════════════════════════════════════════

resource "kubernetes_manifest" "velero_schedule_6h" {
  manifest = {
    apiVersion = "velero.io/v1"
    kind       = "Schedule"
    metadata = {
      name      = "leveldb-6h-backup"
      namespace = kubernetes_namespace.velero.metadata[0].name
      labels = {
        app                            = "ninox-backup"
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }

    spec = {
      # Every 6 hours — matches RPO requirement
      schedule = "0 */6 * * *"

      template = {
        # Back up the production namespace (LevelDB app lives here)
        includedNamespaces = ["production"]

        # Include all resource types
        includedResources = ["*"]

        # Include cluster-scoped resources (PVs, StorageClasses, etc.)
        includeClusterResources = true

        # Kopia file-system backup for TopoLVM NVMe volumes
        defaultVolumesToFsBackup = true

        # snapshotVolumes = true would trigger EBS snapshots.
        # For TopoLVM local volumes, Kopia FS backup is used instead.
        snapshotVolumes = false

        storageLocation = "default"

        # How long to keep each backup in S3 (30 days)
        ttl = var.velero_backup_ttl   # "720h0m0s"

        # Optional: pre-hook to flush LevelDB WAL before backup
        # Uncomment if app exposes a quiesce API endpoint
        # hooks = {
        #   resources = [{
        #     name               = "leveldb-flush"
        #     includedNamespaces = ["production"]
        #     labelSelector = {
        #       matchLabels = { "app.kubernetes.io/name" = "ninox-leveldb" }
        #     }
        #     pre = [{
        #       exec = {
        #         container = "application"
        #         command   = ["/bin/sh", "-c", "curl -sf http://localhost:8080/admin/flush"]
        #         onError   = "Fail"
        #         timeout   = "60s"
        #       }
        #     }]
        #   }]
        # }

        metadata = {
          labels = {
            schedule    = "6h"
            environment = "production"
          }
        }
      }

      paused = false
      useOwnerReferencesInBackup = false
    }
  }

  depends_on = [helm_release.velero]
}

# ── Weekly full backup (all namespaces, 90-day retention) ─────────
resource "kubernetes_manifest" "velero_schedule_weekly" {
  manifest = {
    apiVersion = "velero.io/v1"
    kind       = "Schedule"
    metadata = {
      name      = "leveldb-weekly-full"
      namespace = kubernetes_namespace.velero.metadata[0].name
    }

    spec = {
      schedule = "0 2 * * 0"   # Sunday 02:00 UTC

      template = {
        includedNamespaces       = ["production", "monitoring", "velero"]
        includeClusterResources  = true
        defaultVolumesToFsBackup = true
        snapshotVolumes          = false
        storageLocation          = "default"
        ttl                      = "2160h0m0s"   # 90 days

        metadata = {
          labels = {
            schedule    = "weekly"
            backup-type = "full"
          }
        }
      }

      paused = false
    }
  }

  depends_on = [helm_release.velero]
}

# ── BackupStorageLocation (explicit resource declaration) ─────────
resource "kubernetes_manifest" "velero_bsl" {
  manifest = {
    apiVersion = "velero.io/v1"
    kind       = "BackupStorageLocation"
    metadata = {
      name      = "default"
      namespace = kubernetes_namespace.velero.metadata[0].name
    }

    spec = {
      default  = true
      provider = "aws"
      objectStorage = {
        bucket = aws_s3_bucket.backups.bucket
        prefix = "velero"
      }
      config = {
        region               = var.aws_region
        s3ForcePathStyle     = "false"
        serverSideEncryption = "aws:kms"
        kmsKeyId             = aws_kms_key.s3.arn
      }
    }
  }

  depends_on = [helm_release.velero]
}
