# ──────────────────────────────────────────────────────────────────
# EKS — terraform-aws-modules/eks/aws v19
#
# Node groups:
#   stateful_nvme — i4i.xlarge with NVMe + LVM bootstrap
#   system        — m5.xlarge for monitoring / velero / topolvm
# ──────────────────────────────────────────────────────────────────

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true

  cluster_encryption_config = {
    provider_key_arn = aws_kms_key.eks.arn
    resources        = ["secrets"]
  }

  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }
    aws-ebs-csi-driver = { most_recent = true
    service_account_role_arn = module.ebs_csi_irsa.iam_role_arn }

    # EFS CSI — only needed for migration Methods 1 and 2
    # Remove after migration is complete to reduce attack surface
    aws-efs-csi-driver = { most_recent = true
    service_account_role_arn = module.efs_csi_irsa.iam_role_arn }
  }

  eks_managed_node_groups = {

    # ── i4i.xlarge — NVMe nodes for LevelDB ──────────────────
    stateful_nvme = {
      instance_types = [var.nvme_instance_type]
      min_size       = var.nvme_min_size
      max_size       = var.nvme_max_size
      desired_size   = var.nvme_desired_size
      ami_type       = "AL2_x86_64"

      # ── LVM bootstrap runs before node joins EKS ──────────
      # Creates Volume Group "node-vg" from the 937 GB NVMe disk.
      # TopoLVM reads this VG and carves LVs dynamically per PVC.
      pre_bootstrap_user_data = <<-EOT
        #!/bin/bash
        set -euo pipefail
        exec > >(tee /var/log/nvme-lvm-setup.log | logger -t nvme-lvm) 2>&1

        echo "=== NVMe + LVM Setup: $(date -Iseconds) ==="
        yum install -y lvm2
        modprobe dm-thin-pool
        modprobe dm-snapshot

        DEVICE="/dev/nvme1n1"
        for i in $(seq 1 30)
do
          [ -b "$DEVICE" ] && break
          echo "Waiting for $DEVICE ... ($i/30)"
sleep 2
        done
        [ -b "$DEVICE" ] || { echo "ERROR: $DEVICE not found"
exit 0
}

        vgdisplay "${var.topolvm_vg_name}" &>/dev/null && { echo "VG exists — skip"
exit 0
}

        wipefs -a "$DEVICE" || true
        pvcreate --force --yes "$DEVICE"
        vgcreate "${var.topolvm_vg_name}" "$DEVICE"

        echo "=== LVM ready ==="
        vgdisplay "${var.topolvm_vg_name}"
      EOT

      labels = {
        "node-role"     = "stateful"
        "ninox/storage" = "nvme"
        "workload-type" = "leveldb"
      }

      taints = {
        dedicated = { key = "workload-type", value = "leveldb", effect = "NO_SCHEDULE" }
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            kms_key_id            = aws_kms_key.ebs.arn
            delete_on_termination = true
          }
        }
      }
    }

    # ── System nodes for monitoring / velero / topolvm ────────
    system = {
      instance_types = [var.system_instance_type]
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      ami_type       = "AL2_x86_64"
      labels         = { "node-role" = "system" }
      taints         = {}

      metadata_options = { http_endpoint = "enabled", http_tokens = "required", http_put_response_hop_limit = 1 }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            kms_key_id            = aws_kms_key.ebs.arn
            delete_on_termination = true
          }
        }
      }
    }
  }

  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node — all protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  tags = { Cluster = var.cluster_name }
}

# ── KMS keys ─────────────────────────────────────────────────────
resource "aws_kms_key" "eks" {
  description             = "${var.cluster_name} EKS secrets"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_key" "ebs" {
  description             = "${var.cluster_name} EBS volumes"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/${var.cluster_name}-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}

# ── EBS CSI IRSA ─────────────────────────────────────────────────
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# ── EFS CSI IRSA (migration only — remove after migration) ───────
module "efs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-efs-csi"
  attach_efs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa"]
    }
  }
}

# ── gp3 StorageClass — Prometheus / Grafana / Alertmanager PVs ───
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name        = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"
  parameters = {
    type       = "gp3"
    iops       = "3000"
    throughput = "125"
    encrypted  = "true"
    kmsKeyId   = aws_kms_key.ebs.arn
  }
  depends_on = [module.eks]
}
