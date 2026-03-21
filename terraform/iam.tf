data "aws_caller_identity" "current" {}

# ── Velero IRSA ───────────────────────────────────────────────────
module "velero_irsa" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version   = "~> 5.0"
  role_name = "${var.cluster_name}-velero"
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["velero:velero"]
    }
  }
  role_policy_arns = { velero = aws_iam_policy.velero.arn }
}

resource "aws_iam_policy" "velero" {
  name = "${var.cluster_name}-velero"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3Objects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:DeleteObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts", "s3:CreateMultipartUpload", "s3:CompleteMultipartUpload"]
        Resource = "${aws_s3_bucket.backups.arn}/*"
      },
      {
        Sid      = "S3Bucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
        Resource = aws_s3_bucket.backups.arn
      },
      # Velero Method 3: also needs migration bucket for S3 restore
      {
        Sid      = "S3MigrationRead"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.migration.arn, "${aws_s3_bucket.migration.arn}/*"]
      },
      {
        Sid      = "KMS"
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
        Resource = aws_kms_key.s3.arn
      },
      {
        Sid      = "EC2"
        Effect   = "Allow"
        Action   = ["ec2:DescribeVolumes", "ec2:DescribeSnapshots", "ec2:CreateSnapshot", "ec2:DeleteSnapshot", "ec2:DescribeTags", "ec2:CreateTags"]
        Resource = "*"
      },
    ]
  })
}

# ── Loki IRSA ─────────────────────────────────────────────────────
module "loki_irsa" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version   = "~> 5.0"
  role_name = "${var.cluster_name}-loki"
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["monitoring:loki"]
    }
  }
  role_policy_arns = { loki = aws_iam_policy.loki.arn }
}

resource "aws_iam_policy" "loki" {
  name = "${var.cluster_name}-loki"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3Objects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListMultipartUploadParts", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.loki.arn}/*"
      },
      {
        Sid      = "S3Bucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.loki.arn
      },
      {
        Sid      = "KMS"
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = aws_kms_key.s3.arn
      },
    ]
  })
}

# ── App IRSA ──────────────────────────────────────────────────────
module "app_irsa" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version   = "~> 5.0"
  role_name = "${var.cluster_name}-app"
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["production:ninox-leveldb"]
    }
  }
  role_policy_arns = { app = aws_iam_policy.app.arn }
}

resource "aws_iam_policy" "app" {
  name = "${var.cluster_name}-app"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "Identity"
      Effect   = "Allow"
      Action   = ["sts:GetCallerIdentity"]
      Resource = "*"
    }]
  })
}

# ── DataSync IAM ──────────────────────────────────────────────────
resource "aws_iam_role" "datasync" {
  name = "${var.cluster_name}-datasync"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "datasync.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
  tags = { Purpose = "migration-only", DeleteAfter = "migration-complete" }
}

resource "aws_iam_role_policy" "datasync" {
  name = "${var.cluster_name}-datasync"
  role = aws_iam_role.datasync.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = [aws_s3_bucket.migration.arn, "${aws_s3_bucket.migration.arn}/*", "${aws_s3_bucket.backups.arn}", "${aws_s3_bucket.backups.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = aws_kms_key.s3.arn
      },
      {
        Effect   = "Allow"
        Action   = ["elasticfilesystem:*"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups"]
        Resource = "*"
      },
    ]
  })
}

# ── GitHub Actions OIDC ───────────────────────────────────────────
resource "aws_iam_role" "github_actions" {
  name = "${var.cluster_name}-github-actions"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:ninox-org/*:*" }
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions" {
  name = "${var.cluster_name}-github-actions"
  role = aws_iam_role.github_actions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECR"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage"]
        Resource = "*"
      },
      {
        Sid      = "EKS"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = module.eks.cluster_arn
      },
    ]
  })
}

# ── ECR ───────────────────────────────────────────────────────────
resource "aws_ecr_repository" "app" {
  name                 = "ninox-leveldb"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ebs.arn
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 20 tagged"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 20
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged after 7d"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
    ]
  })
}
