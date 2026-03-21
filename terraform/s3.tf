# ──────────────────────────────────────────────────────────────────
# S3 — Velero backup bucket + Loki log bucket
# ──────────────────────────────────────────────────────────────────

# ════════════════════════════════════════════════════════════════════
# VELERO BACKUP BUCKET
# ════════════════════════════════════════════════════════════════════

resource "aws_s3_bucket" "backups" {
  bucket = var.backup_bucket_name   # "ninox-backup-storage-s3"

  tags = {
    Name    = var.backup_bucket_name
    Purpose = "velero-backups"
  }
}

resource "aws_s3_bucket_versioning" "backup_versioning" {
  bucket = aws_s3_bucket.backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true
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
    id     = "expire-old-backups"
    status = "Enabled"

    # Velero also enforces TTL, but belt-and-suspenders:
    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ════════════════════════════════════════════════════════════════════
# LOKI LOG BUCKET
# ════════════════════════════════════════════════════════════════════

resource "aws_s3_bucket" "loki" {
  bucket = var.loki_bucket_name   # "ninox-loki-logs"

  tags = {
    Name    = var.loki_bucket_name
    Purpose = "loki-log-storage"
  }
}

resource "aws_s3_bucket_versioning" "loki_versioning" {
  bucket = aws_s3_bucket.loki.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true
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

    # Hot (0–30d): S3 Standard — fast Grafana queries
    transition {
      days          = 30
      storage_class = "GLACIER_IR"   # Glacier Instant Retrieval — cheap + queryable
    }

    expiration {
      days = 365   # Delete logs older than 1 year
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ── Shared KMS key for both buckets ──────────────────────────────
resource "aws_kms_key" "s3" {
  description             = "${var.cluster_name} S3 encryption (Velero + Loki)"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "s3" {
  name          = "alias/${var.cluster_name}-s3"
  target_key_id = aws_kms_key.s3.key_id
}
