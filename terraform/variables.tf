variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "cluster_name" {
  type    = string
  default = "ninox-production"
}

variable "cluster_version" {
  type    = string
  default = "1.28"
}

variable "environment" {
  type    = string
  default = "production"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
}

# ── Node sizing ───────────────────────────────────────────────────
# i4i.4xlarge: 16 vCPU / 128 GB / 3750 GB NVMe — required for ~2 Ti PVC per pod
# (i4i.xlarge 937 GB cannot satisfy a 2 Ti TopoLVM LV)
variable "nvme_instance_type" {
  type    = string
  default = "i4i.4xlarge"
}

variable "nvme_min_size" {
  type    = number
  default = 3
}

variable "nvme_max_size" {
  type    = number
  default = 6
}

variable "nvme_desired_size" {
  type    = number
  default = 3
}

variable "system_instance_type" {
  type    = string
  default = "m5.xlarge"
}

variable "topolvm_vg_name" {
  type    = string
  default = "node-vg"
}

# ── Application ───────────────────────────────────────────────────
variable "app_image_repository" {
  type    = string
  default = "ACCOUNT.dkr.ecr.eu-west-1.amazonaws.com/ninox-leveldb"
}

variable "app_image_tag" {
  type    = string
  default = "latest"
}

variable "app_replica_count" {
  type    = number
  default = 3
}

variable "pvc_size" {
  type    = string
  default = "2Ti"
}

# ── S3 ────────────────────────────────────────────────────────────
variable "velero_bucket_name" {
  type    = string
  default = "ninox-backup-storage-s3"
}

variable "loki_bucket_name" {
  type    = string
  default = "ninox-loki-logs"
}

variable "migration_bucket_name" {
  type    = string
  default = "ninox-migration-staging"
}

# ── Velero ────────────────────────────────────────────────────────
variable "velero_chart_version" {
  type    = string
  default = "6.0.0"
}

variable "velero_backup_ttl" {
  type    = string
  default = "720h0m0s"
}

variable "velero_backup_schedule" {
  type    = string
  default = "0 */6 * * *"
}

# ── Monitoring ────────────────────────────────────────────────────
variable "prometheus_chart_version" {
  type    = string
  default = "57.2.0"
}

variable "loki_chart_version" {
  type    = string
  default = "5.47.2"
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
}

variable "slack_webhook_url" {
  type      = string
  sensitive = true
  default   = ""
}

variable "pagerduty_routing_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "topolvm_chart_version" {
  type    = string
  default = "15.3.2"
}

# ── Migration ─────────────────────────────────────────────────────
# Migration method controls the StatefulSet initContainer behaviour:
#   "hydration"    — Method 1: copy EFS → NVMe on first boot (recommended)
#   "double-mount" — Method 2: mount both EFS + NVMe simultaneously
#   "velero"       — Method 3: restore from S3 via Velero (no EFS needed)
#   "none"         — No migration (fresh cluster, skip migration resources)
variable "migration_method" {
  type    = string
  default = "hydration"
  validation {
    condition     = contains(["hydration", "double-mount", "velero", "none"], var.migration_method)
    error_message = "migration_method must be hydration, double-mount, velero, or none"
  }
}

variable "datasync_agent_arns" {
  type    = list(string)
  default = []
}

variable "old_server_ips" {
  type    = list(string)
  default = []
}

variable "old_server_data_path" {
  type    = string
  default = "/data/leveldb"
}
