variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "ninox-production"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.28"
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
# i4i.4xlarge: 16 vCPU / 128 GB RAM / 3750 GB NVMe
# Gives enough local capacity for 2 TiB PVC + snapshot headroom.
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

# ── S3 ────────────────────────────────────────────────────────────
variable "backup_bucket_name" {
  description = "S3 bucket for Velero backups"
  type        = string
  default     = "ninox-backup-storage-s3"
}

variable "loki_bucket_name" {
  description = "S3 bucket for Loki log storage"
  type        = string
  default     = "ninox-loki-logs"
}

# ── Velero ────────────────────────────────────────────────────────
variable "velero_backup_ttl" {
  type    = string
  default = "720h0m0s" # 30 days
}

# ── Grafana ───────────────────────────────────────────────────────
variable "grafana_admin_password" {
  type      = string
  sensitive = true
  default   = "changeme"   # Override via TF_VAR_grafana_admin_password
}

# ── App ───────────────────────────────────────────────────────────
variable "app_image_repository" {
  type    = string
  default = "your-ecr-account.dkr.ecr.eu-west-1.amazonaws.com/ninox-leveldb"
}

variable "app_image_tag" {
  type    = string
  default = "latest"
}

variable "pvc_size" {
  description = "PVC size per pod"
  type        = string
  default     = "2Ti"
}
