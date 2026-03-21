# ──────────────────────────────────────────────────────────────────
# TopoLVM — dynamic LVM volume provisioning from NVMe node-vg
#
# After the node userdata runs pvcreate + vgcreate, TopoLVM's
# node-daemon discovers the "node-vg" VG and exposes it as a
# StorageClass. PVCs with storageClassName: topolvm-provisioner
# get a Logical Volume carved from the local NVMe.
# ──────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "topolvm" {
  metadata {
    name = "topolvm-system"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "topolvm" {
  name       = "topolvm"
  repository = "https://topolvm.github.io/topolvm"
  chart      = "topolvm"
  version    = "15.3.2"
  namespace  = kubernetes_namespace.topolvm.metadata[0].name

  wait    = true
  timeout = 300

  depends_on = [
    module.eks,
    kubernetes_namespace.topolvm,
  ]

  values = [
    yamlencode({

      # ── Node daemon ─────────────────────────────────────────
      # Runs on every NVMe node; reads "node-vg" and creates LVs
      node = {
        tolerations = [
          # Must tolerate the workload-type=leveldb taint
          { key = "workload-type", operator = "Equal", value = "leveldb", effect = "NoSchedule" },
        ]
        nodeSelector = {
          "ninox/storage" = "nvme"
        }
      }

      # ── lvmd config — bind to the VG created in userdata ────
      lvmd = {
        managed    = true
        socketName = "/run/topolvm/lvmd.sock"
        deviceClasses = [
          {
            name        = "default"
            volumeGroup = "node-vg"        # Must match vgcreate in userdata
            default     = true
            # Use thin provisioning for snapshot support
            lvcreateOptionClasses = [
              {
                name    = "thin"
                options = ["--type=thin", "--poolname=thinpool"]
              }
            ]
          }
        ]
      }

      # ── Controller ──────────────────────────────────────────
      controller = {
        replicaCount = 2
        nodeSelector = { "node-role" = "system" }
      }

      # ── Webhook ─────────────────────────────────────────────
      webhook = {
        replicaCount = 2
        nodeSelector = { "node-role" = "system" }
      }

      # ── Scheduler ───────────────────────────────────────────
      scheduler = { enabled = true }

      # ── StorageClass ─────────────────────────────────────────
      storageClasses = [
        {
          name = "topolvm-provisioner"
          storageClass = {
            isDefaultClass       = false
            volumeBindingMode    = "WaitForFirstConsumer"
            allowVolumeExpansion = true
            reclaimPolicy        = "Retain"   # NEVER auto-delete LevelDB data
            additionalParameters = {
              "topolvm.io/device-class" = "default"
            }
          }
        }
      ]

      # ── Metrics ─────────────────────────────────────────────
      podMonitor = {
        enabled = true
        additionalLabels = { release = "prometheus-stack" }
      }
    })
  ]
}
