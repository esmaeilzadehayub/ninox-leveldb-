resource "kubernetes_namespace" "topolvm" {
  metadata {
    name   = "topolvm-system"
    labels = { "pod-security.kubernetes.io/enforce" = "privileged" }
  }
  depends_on = [module.eks]
}

resource "helm_release" "topolvm" {
  name       = "topolvm"
  repository = "https://topolvm.github.io/topolvm"
  chart      = "topolvm"
  version    = var.topolvm_chart_version
  namespace  = kubernetes_namespace.topolvm.metadata[0].name
  wait       = true
  timeout    = 300
  depends_on = [module.eks, kubernetes_namespace.topolvm, kubernetes_storage_class.gp3]

  values = [yamlencode({
    node = {
      tolerations  = [{ key = "workload-type", operator = "Equal", value = "leveldb", effect = "NoSchedule" }]
      nodeSelector = { "ninox/storage" = "nvme" }
    }
    lvmd = {
      managed    = true
      socketName = "/run/topolvm/lvmd.sock"
      deviceClasses = [{
        name                  = "default"
        volumeGroup           = var.topolvm_vg_name
        default               = true
        lvcreateOptionClasses = [{ name = "thin", options = ["--type=thin", "--poolname=thinpool"] }]
      }]
    }
    controller = { replicaCount = 2, nodeSelector = { "node-role" = "system" } }
    webhook    = { replicaCount = 2, nodeSelector = { "node-role" = "system" } }
    scheduler  = { enabled = true }
    storageClasses = [{
      name = "topolvm-provisioner"
      storageClass = {
        isDefaultClass       = false
        volumeBindingMode    = "WaitForFirstConsumer"
        allowVolumeExpansion = true
        reclaimPolicy        = "Retain"
        additionalParameters = { "topolvm.io/device-class" = "default" }
      }
    }]
  })]
}
