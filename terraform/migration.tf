# ──────────────────────────────────────────────────────────────────
# migration.tf — AWS DataSync + EFS staging infrastructure
#
# Supports all three migration methods:
#
#   Method 1 (hydration):    DataSync → EFS → initContainer copies to NVMe
#   Method 2 (double-mount): DataSync → EFS → mount both EFS + NVMe in pod
#   Method 3 (velero/s3):    DataSync → S3  → Velero restore to NVMe PVC
#
# These resources are TEMPORARY — destroy after migration is confirmed:
#   terraform destroy -target=aws_datasync_task.leveldb \
#                     -target=aws_efs_file_system.staging \
#                     -target=aws_s3_bucket.migration
# ──────────────────────────────────────────────────────────────────

locals {
  migration_active      = var.migration_method != "none"
  efs_method            = contains(["hydration", "double-mount"], var.migration_method)
  datasync_agents_ready = length(var.datasync_agent_arns) > 0
  num_servers           = length(var.old_server_ips)
}

# ── EFS Staging Filesystem (Methods 1 + 2) ────────────────────────
resource "aws_efs_file_system" "staging" {
  count = local.efs_method ? 1 : 0

  creation_token   = "${var.cluster_name}-migration-staging"
  encrypted        = true
  kms_key_id       = aws_kms_key.s3.arn
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = {
    Name        = "${var.cluster_name}-migration-staging"
    Method      = var.migration_method
    DeleteAfter = "migration-complete"
  }
}

resource "aws_efs_mount_target" "staging" {
  count = local.efs_method ? length(var.availability_zones) : 0

  file_system_id  = aws_efs_file_system.staging[0].id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs[0].id]
}

resource "aws_security_group" "efs" {
  count = local.efs_method ? 1 : 0

  name_prefix = "${var.cluster_name}-efs-"
  vpc_id      = module.vpc.vpc_id
  description = "EFS migration staging — NFS from VPC only"

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "NFS"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-efs-migration" }
}

# ── EFS StorageClass — used by PVCs in migration jobs/pods ────────
resource "kubernetes_storage_class" "efs_migration" {
  count = local.efs_method ? 1 : 0

  metadata {
    name   = "efs-migration"
    labels = { purpose = "migration", "delete-after" = "migration-complete" }
  }

  storage_provisioner    = "efs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = false

  parameters = {
    fileSystemId     = aws_efs_file_system.staging[0].id
    directoryPath    = "/"
    provisioningMode = "efs-ap"
    gidRangeStart    = "1000"
    gidRangeEnd      = "2000"
    basePath         = "/"
  }

  depends_on = [module.eks, aws_efs_mount_target.staging]
}

# ── DataSync CloudWatch log group ─────────────────────────────────
resource "aws_cloudwatch_log_group" "datasync" {
  count             = local.migration_active && local.datasync_agents_ready ? 1 : 0
  name              = "/aws/datasync/${var.cluster_name}"
  retention_in_days = 14
}

# ── DataSync: NFS source (one per old server) ──────────────────────
resource "aws_datasync_location_nfs" "source" {
  count = local.datasync_agents_ready ? local.num_servers : 0

  server_hostname = var.old_server_ips[count.index]
  subdirectory    = var.old_server_data_path

  on_prem_config {
    agent_arns = [var.datasync_agent_arns[count.index]]
  }

  mount_options { version = "NFS4_1" }
}

# ── DataSync: EFS destination (Methods 1+2) ───────────────────────
resource "aws_datasync_location_efs" "staging" {
  count = local.efs_method && local.datasync_agents_ready ? local.num_servers : 0

  efs_file_system_arn = aws_efs_file_system.staging[0].arn
  subdirectory        = "/pod-${count.index}" # /pod-0, /pod-1, /pod-2

  ec2_config {
    security_group_arns = [aws_security_group.efs[0].arn]
    subnet_arn          = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:subnet/${module.vpc.private_subnets[0]}"
  }
}

# ── DataSync: S3 destination (Method 3) ───────────────────────────
resource "aws_datasync_location_s3" "migration" {
  count = var.migration_method == "velero" && local.datasync_agents_ready ? local.num_servers : 0

  s3_bucket_arn = aws_s3_bucket.migration.arn
  subdirectory  = "/leveldb/pod-${count.index}"

  s3_config {
    bucket_access_role_arn = aws_iam_role.datasync.arn
  }
}

# ── DataSync Tasks ────────────────────────────────────────────────
# Method 1+2: old server NFS → EFS
resource "aws_datasync_task" "to_efs" {
  count = local.efs_method && local.datasync_agents_ready ? local.num_servers : 0

  name                     = "${var.cluster_name}-to-efs-pod${count.index}"
  source_location_arn      = aws_datasync_location_nfs.source[count.index].arn
  destination_location_arn = aws_datasync_location_efs.staging[count.index].arn

  options {
    verify_mode            = "ONLY_FILES_TRANSFERRED"
    overwrite_mode         = "ALWAYS"
    preserve_deleted_files = "REMOVE"
    bytes_per_second       = -1 # Full bandwidth
    mtime                  = "PRESERVE"
    posix_permissions      = "PRESERVE"
    log_level              = "TRANSFER"
  }

  excludes {
    filter_type = "SIMPLE_PATTERN"
    value       = "/LOCK|/*.tmp"
  }

  cloudwatch_log_group_arn = aws_cloudwatch_log_group.datasync[0].arn

  tags = { Name = "${var.cluster_name}-migration-pod${count.index}", Method = "efs" }
}

# Method 3: old server NFS → S3
resource "aws_datasync_task" "to_s3" {
  count = var.migration_method == "velero" && local.datasync_agents_ready ? local.num_servers : 0

  name                     = "${var.cluster_name}-to-s3-pod${count.index}"
  source_location_arn      = aws_datasync_location_nfs.source[count.index].arn
  destination_location_arn = aws_datasync_location_s3.migration[count.index].arn

  options {
    verify_mode            = "ONLY_FILES_TRANSFERRED"
    overwrite_mode         = "ALWAYS"
    preserve_deleted_files = "REMOVE"
    bytes_per_second       = -1
    log_level              = "TRANSFER"
  }

  excludes {
    filter_type = "SIMPLE_PATTERN"
    value       = "/LOCK|/*.tmp"
  }

  cloudwatch_log_group_arn = aws_cloudwatch_log_group.datasync[0].arn

  tags = { Name = "${var.cluster_name}-migration-s3-pod${count.index}", Method = "s3-velero" }
}
