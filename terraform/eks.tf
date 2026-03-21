# ──────────────────────────────────────────────────────────────────
# EKS — terraform-aws-modules/eks/aws  v19
#
# Node group:  i4i.4xlarge (3750 GB local NVMe)
# Userdata:    lvm2 + pvcreate + vgcreate on /dev/nvme1n1
#              → creates Volume Group "node-vg" for TopoLVM
# ──────────────────────────────────────────────────────────────────

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Allow kubectl from within the VPC (CI/CD runner, bastion)
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true

  # Encrypt Kubernetes secrets with KMS
  cluster_encryption_config = {
    provider_key_arn = aws_kms_key.eks.arn
    resources        = ["secrets"]
  }

  # Send all control-plane logs to CloudWatch
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # ── Managed add-ons ──────────────────────────────────────────
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    # EBS CSI — used for Prometheus/Grafana persistent volumes (gp3)
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  # ── Node groups ───────────────────────────────────────────────
  eks_managed_node_groups = {

    # ── Stateful NVMe nodes (LevelDB workload) ────────────────
    stateful_nvme = {
      instance_types = [var.nvme_instance_type]   # i4i.4xlarge
      min_size       = var.nvme_min_size           # 3
      max_size       = var.nvme_max_size           # 6
      desired_size   = var.nvme_min_size           # Start at min

      # AMI type — AL2 for best LVM compatibility
      ami_type = "AL2_x86_64"

      # ── NVMe + LVM bootstrap ──────────────────────────────
      # Runs BEFORE the node joins the EKS cluster.
      # /dev/nvme1n1 is the 937 GB local NVMe on i4i instances.
      # TopoLVM reads Volume Group "node-vg" to provision LVs per PVC.
      pre_bootstrap_user_data = <<-EOT
        #!/bin/bash
        set -ex

        echo "=== Installing LVM2 ===" 
        yum install -y lvm2
        modprobe dm-thin-pool
        modprobe dm-snapshot

        # Wait for NVMe disk to appear (up to 60s)
        for i in $(seq 1 30); do
          [ -b /dev/nvme1n1 ] && break
          echo "Waiting for /dev/nvme1n1 ... attempt $i"
          sleep 2
        done

        if [ ! -b /dev/nvme1n1 ]; then
          echo "ERROR: /dev/nvme1n1 not found — node will join but TopoLVM has no storage"
          exit 0
        fi

        echo "=== Setting up LVM on /dev/nvme1n1 ==="
        wipefs -a /dev/nvme1n1 || true
        pvcreate /dev/nvme1n1
        vgcreate node-vg /dev/nvme1n1

        echo "=== LVM setup complete ==="
        vgdisplay node-vg
      EOT

      # Node labels so pods can target NVMe nodes
      labels = {
        "node-role"      = "stateful"
        "ninox/storage"  = "nvme"
        "workload-type"  = "leveldb"
      }

      # Taint — only pods that tolerate this taint land here
      taints = {
        dedicated = {
          key    = "workload-type"
          value  = "leveldb"
          effect = "NO_SCHEDULE"
        }
      }

      # IMDSv2 only (security best practice)
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      # Encrypt root EBS volume
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

    # ── System nodes (Prometheus, Velero, Loki, TopoLVM ctrl) ─
    system = {
      instance_types = ["m5.xlarge"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2

      labels = {
        "node-role" = "system"
      }

      # System nodes get no taint — cluster add-ons schedule here
      taints = {}

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
  }

  # Allow worker nodes to communicate with control plane
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  tags = {
    Cluster = var.cluster_name
  }
}

# ── KMS keys ─────────────────────────────────────────────────────
resource "aws_kms_key" "eks" {
  description             = "${var.cluster_name} EKS secrets encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_key" "ebs" {
  description             = "${var.cluster_name} EBS volume encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
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

# ── StorageClass: gp3 (for Prometheus/Grafana/Alertmanager PVs) ──
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
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
