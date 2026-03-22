resource "kubernetes_namespace" "monitoring" {
  metadata { name = "monitoring" }
  depends_on = [module.eks]
}

resource "kubernetes_service_account" "loki" {
  metadata {
    name        = "loki"
    namespace   = kubernetes_namespace.monitoring.metadata[0].name
    annotations = { "eks.amazonaws.com/role-arn" = module.loki_irsa.iam_role_arn }
  }
  depends_on = [kubernetes_namespace.monitoring]
}

resource "helm_release" "prometheus_stack" {
  name             = "prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  version          = var.prometheus_chart_version
  wait             = true
  timeout          = 600
  atomic           = true
  cleanup_on_fail  = true
  depends_on       = [module.eks, kubernetes_storage_class.gp3]

  values = [yamlencode({
    grafana = {
      enabled               = true
      adminPassword         = var.grafana_admin_password
      nodeSelector          = { "node-role" = "system" }
      additionalDataSources = [{ name = "Loki", type = "loki", url = "http://loki-gateway.monitoring.svc.cluster.local", access = "proxy", isDefault = false }]
      persistence           = { enabled = true, storageClassName = "gp3", size = "10Gi" }
      sidecar               = { dashboards = { enabled = true, searchNamespace = "ALL" } }
    }
    prometheus = {
      prometheusSpec = {
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
        retention                               = "30d"
        retentionSize                           = "45GB"
        nodeSelector                            = { "node-role" = "system" }
        storageSpec                             = { volumeClaimTemplate = { spec = { storageClassName = "gp3", resources = { requests = { storage = "50Gi" } } } } }
        resources                               = { requests = { cpu = "500m", memory = "2Gi" }, limits = { cpu = "2", memory = "4Gi" } }
      }
    }
    alertmanager = {
      alertmanagerSpec = {
        nodeSelector = { "node-role" = "system" }
        storage      = { volumeClaimTemplate = { spec = { storageClassName = "gp3", resources = { requests = { storage = "5Gi" } } } } }
      }
      config = {
        global = { resolve_timeout = "5m", slack_api_url = var.slack_webhook_url }
        route = {
          group_by = ["alertname", "namespace"], group_wait = "10s", group_interval = "5m", repeat_interval = "4h"
          receiver = "slack-warnings"
          routes   = [{ match = { severity = "critical" }, receiver = "pagerduty" }, { match = { severity = "warning" }, receiver = "slack-warnings" }]
        }
        receivers = [
          { name = "slack-warnings", slack_configs = [{ channel = "#ops-alerts", title = "[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}", text = "{{ range .Alerts }}{{ .Annotations.description }}\n{{ end }}", send_resolved = true }] },
          { name = "pagerduty", pagerduty_configs = [{ routing_key = var.pagerduty_routing_key, description = "{{ .GroupLabels.alertname }}: {{ .CommonAnnotations.summary }}" }] },
        ]
      }
    }
    nodeExporter     = { enabled = true }
    kubeStateMetrics = { enabled = true }
    defaultRules     = { create = true, rules = { kubernetesApps = true, kubernetesStorage = true, node = true, prometheus = true } }
  })]
}

# PrometheusRules for ninox-leveldb live in helm/ninox-leveldb/templates/prometheusrule.yaml
# (single source of truth; avoids duplicate "leveldb-alerts" with Terraform + Helm)

resource "helm_release" "loki" {
  name            = "loki"
  repository      = "https://grafana.github.io/helm-charts"
  chart           = "loki"
  version         = var.loki_chart_version
  namespace       = "monitoring"
  wait            = true
  timeout         = 600
  atomic          = true
  cleanup_on_fail = true
  depends_on      = [helm_release.prometheus_stack, kubernetes_service_account.loki, aws_s3_bucket.loki]

  values = [yamlencode({
    deploymentMode = "SingleBinary"
    singleBinary   = { replicas = 2, nodeSelector = { "node-role" = "system" }, resources = { requests = { cpu = "500m", memory = "1Gi" }, limits = { cpu = "2", memory = "4Gi" } }, persistence = { enabled = true, storageClass = "gp3", size = "20Gi" } }
    serviceAccount = { create = false, name = "loki" }
    loki = {
      auth_enabled  = false
      commonConfig  = { replication_factor = 1, path_prefix = "/loki" }
      storage       = { type = "s3", s3 = { region = var.aws_region, bucketnames = aws_s3_bucket.loki.bucket } }
      schemaConfig  = { configs = [{ from = "2024-01-01", store = "tsdb", object_store = "s3", schema = "v13", index = { prefix = "loki_index_", period = "24h" } }] }
      limits_config = { retention_period = "720h", ingestion_rate_mb = 16, ingestion_burst_size_mb = 32, max_query_parallelism = 32, max_entries_limit_per_query = 50000 }
      compactor     = { working_directory = "/loki/compactor", shared_store = "s3", retention_enabled = true }
    }
    monitoring = { serviceMonitor = { enabled = true, labels = { release = "prometheus-stack" } }, selfMonitoring = { enabled = false, grafanaAgent = { installOperator = false } }, lokiCanary = { enabled = false } }
    gateway    = { enabled = true, replicas = 2, nodeSelector = { "node-role" = "system" } }
    test       = { enabled = false }
  })]
}

resource "helm_release" "promtail" {
  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  version    = "6.15.5"
  namespace  = "monitoring"
  depends_on = [helm_release.loki]

  values = [yamlencode({
    tolerations = [{ key = "workload-type", operator = "Equal", value = "leveldb", effect = "NoSchedule" }]
    config = {
      clients  = [{ url = "http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push" }]
      snippets = { extraScrapeConfigs = "- job_name: ninox-leveldb\n  kubernetes_sd_configs:\n    - role: pod\n  relabel_configs:\n    - source_labels: [__meta_kubernetes_namespace]\n      action: keep\n      regex: production\n    - source_labels: [__meta_kubernetes_pod_name]\n      target_label: pod\n  pipeline_stages:\n    - json:\n        expressions: {level: level, msg: msg}\n    - labels: {level:}\n    - drop: {expression: \".*healthz.*\"}\n" }
    }
    serviceMonitor = { enabled = true, labels = { release = "prometheus-stack" } }
    resources      = { requests = { cpu = "100m", memory = "128Mi" }, limits = { cpu = "200m", memory = "256Mi" } }
  })]
}
