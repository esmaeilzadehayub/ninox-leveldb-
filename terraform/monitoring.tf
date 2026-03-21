# ──────────────────────────────────────────────────────────────────
# Monitoring — kube-prometheus-stack + Loki (S3 backend)
# ──────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
  depends_on = [module.eks]
}

# ── Loki ServiceAccount (IRSA) ────────────────────────────────────
resource "kubernetes_service_account" "loki" {
  metadata {
    name      = "loki"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = module.loki_irsa.iam_role_arn
    }
  }
  depends_on = [kubernetes_namespace.monitoring]
}

# ════════════════════════════════════════════════════════════════════
# kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
# ════════════════════════════════════════════════════════════════════

resource "helm_release" "prometheus_stack" {
  name             = "prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true     # matches pattern from your example
  version          = "57.2.0"

  wait            = true
  timeout         = 600
  atomic          = true
  cleanup_on_fail = true

  depends_on = [
    module.eks,
    kubernetes_storage_class.gp3,
  ]

  values = [
    yamlencode({

      # ── Grafana ─────────────────────────────────────────────
      grafana = {
        enabled       = true
        adminPassword = var.grafana_admin_password

        nodeSelector = { "node-role" = "system" }

        # Pre-add Loki as a data source so dashboards work immediately
        additionalDataSources = [
          {
            name      = "Loki"
            type      = "loki"
            url       = "http://loki-gateway.monitoring.svc.cluster.local"
            access    = "proxy"
            isDefault = false
          }
        ]

        persistence = {
          enabled          = true
          storageClassName = "gp3"
          size             = "10Gi"
        }

        sidecar = {
          dashboards = {
            enabled         = true
            searchNamespace = "ALL"
          }
        }
      }

      # ── Prometheus ──────────────────────────────────────────
      prometheus = {
        prometheusSpec = {
          # Pick up ServiceMonitors / PodMonitors from any namespace
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          ruleSelectorNilUsesHelmValues           = false

          retention     = "30d"
          retentionSize = "45GB"

          nodeSelector = { "node-role" = "system" }

          # 50 Gi gp3 EBS for Prometheus TSDB
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "gp3"
                resources = {
                  requests = {
                    storage = "50Gi"
                  }
                }
              }
            }
          }

          resources = {
            requests = { cpu = "500m",  memory = "2Gi" }
            limits   = { cpu = "2",     memory = "4Gi" }
          }
        }
      }

      # ── Alertmanager ────────────────────────────────────────
      alertmanager = {
        alertmanagerSpec = {
          nodeSelector = { "node-role" = "system" }

          storage = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "gp3"
                resources = { requests = { storage = "5Gi" } }
              }
            }
          }
        }

        # Alert routing: critical → PagerDuty, warning → Slack
        config = {
          global = {
            resolve_timeout = "5m"
            slack_api_url   = "https://hooks.slack.com/services/REPLACE_ME"
          }
          route = {
            group_by        = ["alertname", "namespace"]
            group_wait      = "10s"
            group_interval  = "5m"
            repeat_interval = "4h"
            receiver        = "slack-warnings"
            routes = [
              { match = { severity = "critical" }, receiver = "pagerduty" },
              { match = { severity = "warning" },  receiver = "slack-warnings" },
            ]
          }
          receivers = [
            {
              name = "slack-warnings"
              slack_configs = [{
                channel       = "#ops-alerts"
                title         = "[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}"
                text          = "{{ range .Alerts }}{{ .Annotations.description }}\n{{ end }}"
                send_resolved = true
              }]
            },
            {
              name = "pagerduty"
              pagerduty_configs = [{
                routing_key = "REPLACE_ME"
                description = "{{ .GroupLabels.alertname }}: {{ .CommonAnnotations.summary }}"
              }]
            },
          ]
        }
      }

      # ── node-exporter + kube-state-metrics ──────────────────
      nodeExporter     = { enabled = true }
      kubeStateMetrics = { enabled = true }

      # ── Default alert rules ──────────────────────────────────
      defaultRules = {
        create = true
        rules  = {
          kubernetesApps     = true
          kubernetesStorage  = true
          node               = true
          prometheus         = true
        }
      }
    })
  ]
}

# ── PrometheusRule: LevelDB custom alerts ─────────────────────────
resource "kubernetes_manifest" "leveldb_alerts" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "leveldb-alerts"
      namespace = "monitoring"
      labels = {
        release = "prometheus-stack"   # Must match Prometheus ruleSelector
      }
    }

    spec = {
      groups = [
        {
          name = "LevelDBStorage"
          rules = [
            # ── PVC high usage (> 85%) ───────────────────────
            {
              alert = "PersistentVolumeHighUsage"
              expr  = "kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.85"
              for   = "5m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "StatefulSet Pod {{ $labels.pod }} storage usage > 85%"
                description = "Pod {{ $labels.pod }} PVC usage is {{ $value | humanizePercentage }}. Expand the volume or trigger cleanup."
                runbook_url = "https://github.com/ninox-org/ninox-k8s/blob/main/docs/velero-backup.md"
              }
            },
            # ── PVC critical usage (> 95%) ───────────────────
            {
              alert = "PersistentVolumeCriticalUsage"
              expr  = "kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.95"
              for   = "2m"
              labels = { severity = "critical" }
              annotations = {
                summary     = "CRITICAL: Pod {{ $labels.pod }} PVC almost full ({{ $value | humanizePercentage }})"
                description = "LevelDB will stop writing. Immediate action required."
              }
            },
            # ── Velero backup not recent ─────────────────────
            {
              alert = "VeleroBackupNotRecent"
              expr  = "(time() - velero_backup_last_successful_timestamp{schedule=\"leveldb-6h-backup\"}) > 25200"
              for   = "5m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "Velero backup for leveldb-6h-backup not run in 7+ hours"
                description = "RPO of 6h may be exceeded. Last backup: {{ $value | humanizeDuration }} ago."
              }
            },
            # ── Velero backup failed ─────────────────────────
            {
              alert = "VeleroBackupFailed"
              expr  = "velero_backup_failure_total > 0"
              for   = "5m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "Velero backup {{ $labels.schedule }} failed"
                description = "Check: kubectl logs -n velero deploy/velero"
              }
            },
            # ── Pod crash loop ───────────────────────────────
            {
              alert = "LevelDBPodCrashLooping"
              expr  = "rate(kube_pod_container_status_restarts_total{namespace=\"production\", pod=~\"ninox-leveldb-.*\"}[5m]) * 60 > 1"
              for   = "2m"
              labels = { severity = "critical" }
              annotations = {
                summary     = "LevelDB pod {{ $labels.pod }} is crash-looping"
                description = "Restart rate: {{ $value | humanize }}/min"
              }
            },
            # ── LevelDB write latency p99 ────────────────────
            {
              alert = "LevelDBHighWriteLatency"
              expr  = "histogram_quantile(0.99, rate(leveldb_write_duration_seconds_bucket{namespace=\"production\"}[5m])) > 0.5"
              for   = "5m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "LevelDB p99 write latency > 500ms on {{ $labels.pod }}"
                description = "May indicate compaction pressure or I/O saturation on NVMe."
              }
            },
          ]
        }
      ]
    }
  }

  depends_on = [helm_release.prometheus_stack]
}

# ════════════════════════════════════════════════════════════════════
# LOKI — log aggregation with S3 backend
# ════════════════════════════════════════════════════════════════════

resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  version          = "5.47.2"
  namespace        = "monitoring"
  create_namespace = false   # Already created by prometheus_stack

  wait            = true
  timeout         = 600
  atomic          = true
  cleanup_on_fail = true

  depends_on = [
    helm_release.prometheus_stack,
    kubernetes_service_account.loki,
    aws_s3_bucket.loki,
  ]

  values = [
    yamlencode({

      deploymentMode = "SingleBinary"

      singleBinary = {
        replicas = 2
        nodeSelector = { "node-role" = "system" }
        resources = {
          requests = { cpu = "500m", memory = "1Gi" }
          limits   = { cpu = "2",    memory = "4Gi" }
        }
        persistence = {
          enabled          = true
          storageClass     = "gp3"
          size             = "20Gi"   # WAL before flush to S3
        }
      }

      # Use the IRSA ServiceAccount
      serviceAccount = {
        create = false
        name   = kubernetes_service_account.loki.metadata[0].name
      }

      loki = {
        auth_enabled = false   # Single-tenant

        commonConfig = {
          replication_factor = 1
          path_prefix        = "/loki"
        }

        # ── S3 storage backend ─────────────────────────────
        storage = {
          type = "s3"
          s3 = {
            region      = var.aws_region
            bucketnames = aws_s3_bucket.loki.bucket
            # Auth via IRSA — no access key needed
          }
        }

        schemaConfig = {
          configs = [
            {
              from         = "2024-01-01"
              store        = "tsdb"
              object_store = "s3"
              schema       = "v13"
              index = {
                prefix = "loki_index_"
                period = "24h"
              }
            }
          ]
        }

        # ── Retention: 30 days ─────────────────────────────
        limits_config = {
          retention_period            = "720h"
          ingestion_rate_mb           = 16
          ingestion_burst_size_mb     = 32
          max_query_parallelism       = 32
          max_entries_limit_per_query = 50000
        }

        compactor = {
          working_directory  = "/loki/compactor"
          shared_store       = "s3"
          retention_enabled  = true
        }
      }

      # ── Monitoring ─────────────────────────────────────────
      monitoring = {
        serviceMonitor = {
          enabled = true
          labels  = { release = "prometheus-stack" }
        }
        selfMonitoring = {
          enabled = false
          grafanaAgent = { installOperator = false }
        }
        lokiCanary = { enabled = false }
      }

      gateway = {
        enabled  = true
        replicas = 2
        nodeSelector = { "node-role" = "system" }
      }

      test = { enabled = false }
    })
  ]
}

# ── Promtail DaemonSet — ships all pod logs → Loki ────────────────
resource "helm_release" "promtail" {
  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  version    = "6.15.5"
  namespace  = "monitoring"

  depends_on = [helm_release.loki]

  values = [
    yamlencode({
      # Run on ALL nodes including NVMe leveldb nodes
      tolerations = [
        { key = "workload-type", operator = "Equal", value = "leveldb", effect = "NoSchedule" },
      ]

      config = {
        clients = [{
          url = "http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push"
        }]

        snippets = {
          extraScrapeConfigs = <<-EOT
            - job_name: ninox-leveldb
              kubernetes_sd_configs:
                - role: pod
              relabel_configs:
                - source_labels: [__meta_kubernetes_namespace]
                  action: keep
                  regex: production
                - source_labels: [__meta_kubernetes_pod_name]
                  target_label: pod
                - source_labels: [__meta_kubernetes_pod_container_name]
                  target_label: container
              pipeline_stages:
                - json:
                    expressions:
                      level: level
                      msg:   msg
                - labels:
                    level:
                - drop:
                    expression: ".*healthz.*"
          EOT
        }
      }

      serviceMonitor = {
        enabled = true
        labels  = { release = "prometheus-stack" }
      }

      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "200m", memory = "256Mi" }
      }
    })
  ]
}
