# ── Shared KMS key ────────────────────────────────────────────────
resource "aws_kms_key" "s3" {
  description             = "${var.cluster_name} S3 (Velero + Loki)"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "s3" {
  name          = "alias/${var.cluster_name}-s3"
  target_key_id = aws_kms_key.s3.key_id
}

# ── Helper locals ─────────────────────────────────────────────────
locals {
  s3_sse_rule = [{
    apply_server_side_encryption_by_default = {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true
  }]
  s3_block_public = {
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }
}

# ════════════════════════════════════════════════════════════════════
# 1. Velero backup bucket
# ════════════════════════════════════════════════════════════════════
resource "aws_s3_bucket" "backups" {
  bucket        = var.velero_bucket_name
  force_destroy = false
  tags          = { Name = var.velero_bucket_name, Purpose = "velero-backups" }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  dynamic "rule" {
    for_each = local.s3_sse_rule
    content {
      apply_server_side_encryption_by_default {
        sse_algorithm     = rule.value.apply_server_side_encryption_by_default.sse_algorithm
        kms_master_key_id = rule.value.apply_server_side_encryption_by_default.kms_master_key_id
      }
      bucket_key_enabled = rule.value.bucket_key_enabled
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    id     = "expire-backups"
    status = "Enabled"
    expiration { days = 90 }
    noncurrent_version_expiration { noncurrent_days = 30 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

# ════════════════════════════════════════════════════════════════════
# 2. Loki log bucket
# ════════════════════════════════════════════════════════════════════
resource "aws_s3_bucket" "loki" {
  bucket        = var.loki_bucket_name
  force_destroy = false
  tags          = { Name = var.loki_bucket_name, Purpose = "loki-logs" }
}

resource "aws_s3_bucket_versioning" "loki" {
  bucket = aws_s3_bucket.loki.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  dynamic "rule" {
    for_each = local.s3_sse_rule
    content {
      apply_server_side_encryption_by_default {
        sse_algorithm     = rule.value.apply_server_side_encryption_by_default.sse_algorithm
        kms_master_key_id = rule.value.apply_server_side_encryption_by_default.kms_master_key_id
      }
      bucket_key_enabled = rule.value.bucket_key_enabled
    }
  }
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket                  = aws_s3_bucket.loki.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    id     = "loki-tiering"
    status = "Enabled"
    transition {
      days          = 30
      storage_class = "GLACIER_IR"
    }
    expiration { days = 365 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

# ════════════════════════════════════════════════════════════════════
# 3. Migration staging bucket (Method 3: Velero/S3 path)
#    DataSync → S3 → Velero restore into LVM PVC
# ════════════════════════════════════════════════════════════════════
resource "aws_s3_bucket" "migration" {
  bucket        = var.migration_bucket_name
  force_destroy = true # Safe to delete after migration
  tags          = { Name = var.migration_bucket_name, Purpose = "migration-staging", DeleteAfter = "migration-complete" }
}

resource "aws_s3_bucket_versioning" "migration" {
  bucket = aws_s3_bucket.migration.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "migration" {
  bucket = aws_s3_bucket.migration.id
  dynamic "rule" {
    for_each = local.s3_sse_rule
    content {
      apply_server_side_encryption_by_default {
        sse_algorithm     = rule.value.apply_server_side_encryption_by_default.sse_algorithm
        kms_master_key_id = rule.value.apply_server_side_encryption_by_default.kms_master_key_id
      }
      bucket_key_enabled = rule.value.bucket_key_enabled
    }
  }
}

resource "aws_s3_bucket_public_access_block" "migration" {
  bucket                  = aws_s3_bucket.migration.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "migration" {
  bucket = aws_s3_bucket.migration.id
  rule {
    id     = "auto-cleanup"
    status = "Enabled"
    expiration { days = 30 }
    abort_incomplete_multipart_upload { days_after_initiation = 3 }
  }
}
