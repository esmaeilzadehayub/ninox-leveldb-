resource "kubernetes_namespace" "velero" {
  metadata {
    name = "velero"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
  depends_on = [module.eks]
}

resource "kubernetes_service_account" "velero" {
  metadata {
    name      = "velero"
    namespace = kubernetes_namespace.velero.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = module.velero_irsa.iam_role_arn
    }
  }
}

resource "helm_release" "velero" {
  name       = "velero"
  repository = "https://vmware-tanzu.github.io/helm-charts"
  chart      = "velero"
  version    = var.velero_chart_version
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

  values = [yamlencode({
    serviceAccount = {
      server = {
        create = false
        name   = "velero"
      }
    }
    credentials = { useSecret = false }

    initContainers = [{
      name         = "velero-plugin-for-aws"
      image        = "velero/velero-plugin-for-aws:v1.9.0"
      volumeMounts = [{ mountPath = "/target", name = "plugins" }]
    }]

    configuration = {
      backupStorageLocation = [{
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
      }]
      volumeSnapshotLocation = [{
        name     = "aws"
        provider = "aws"
        config = {
          region = var.aws_region
        }
      }]
    }

    defaultVolumesToFsBackup = true
    features                 = "EnableCSIVolumePolicy"
    deployNodeAgent          = true

    nodeAgent = {
      tolerations = [{ key = "workload-type", operator = "Equal", value = "leveldb", effect = "NoSchedule" }]
      resources = {
        requests = { cpu = "200m", memory = "256Mi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }
    }

    resources = {
      requests = { cpu = "500m", memory = "512Mi" }
      limits   = { cpu = "1", memory = "1Gi" }
    }
    nodeSelector = { "node-role" = "system" }
    metrics = {
      enabled = true
      serviceMonitor = {
        enabled          = true
        additionalLabels = { release = "prometheus-stack" }
      }
    }
    upgradeCRDs = true
  })]
}

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
      schedule = var.velero_backup_schedule
      template = {
        includedNamespaces       = ["production"]
        includedResources        = ["*"]
        includeClusterResources  = true
        defaultVolumesToFsBackup = true
        snapshotVolumes          = false
        storageLocation          = "default"
        ttl                      = var.velero_backup_ttl
        metadata = {
          labels = {
            "velero.io/schedule-name" = "leveldb-6h-backup"
            environment               = "production"
          }
        }
      }
      paused = false
    }
  }
  depends_on = [helm_release.velero]
}

resource "kubernetes_manifest" "velero_schedule_weekly" {
  manifest = {
    apiVersion = "velero.io/v1"
    kind       = "Schedule"
    metadata = {
      name      = "leveldb-weekly-full"
      namespace = kubernetes_namespace.velero.metadata[0].name
    }
    spec = {
      schedule = "0 2 * * 0"
      template = {
        includedNamespaces       = ["production", "monitoring", "velero"]
        includeClusterResources  = true
        defaultVolumesToFsBackup = true
        snapshotVolumes          = false
        storageLocation          = "default"
        ttl                      = "2160h0m0s"
        metadata = {
          labels = {
            "backup-type" = "weekly-full"
          }
        }
      }
      paused = false
    }
  }
  depends_on = [helm_release.velero]
}
