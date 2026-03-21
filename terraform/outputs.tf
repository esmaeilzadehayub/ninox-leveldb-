output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = true
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "velero_s3_bucket" {
  value = aws_s3_bucket.backups.bucket
}

output "loki_s3_bucket" {
  value = aws_s3_bucket.loki.bucket
}

output "migration_s3_bucket" {
  value = aws_s3_bucket.migration.bucket
}

output "velero_irsa_role" {
  value = module.velero_irsa.iam_role_arn
}

output "loki_irsa_role" {
  value = module.loki_irsa.iam_role_arn
}

output "github_actions_role" {
  value = aws_iam_role.github_actions.arn
}

output "efs_filesystem_id" {
  value       = length(aws_efs_file_system.staging) > 0 ? aws_efs_file_system.staging[0].id : "not-created"
  description = "EFS ID — set as EFS_ID env var in migration scripts"
}

output "migration_method" {
  value       = var.migration_method
  description = "Active migration method"
}

output "grafana_access" {
  value = "kubectl port-forward svc/prometheus-stack-grafana -n monitoring 3000:80"
}

output "velero_check" {
  value = "velero backup get && velero schedule get"
}
output "next_steps" {
  value = <<-EOT
    1. Configure kubectl:
       ${module.eks.cluster_name} → aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}

    2. Deploy application:
       helm upgrade --install ninox-leveldb helm/ninox-leveldb \
         --namespace production --create-namespace \
         --set image.tag=v1.0.0 \
         --set migration.method=${var.migration_method} \
         --set migration.efsFileSystemId=$(terraform output -raw efs_filesystem_id)

    3. Run migration (Method: ${var.migration_method}):
       EFS_ID=$(terraform output -raw efs_filesystem_id) \
         ./scripts/efs-mount-and-copy.sh

    4. Verify:
       velero backup get
       kubectl port-forward svc/prometheus-stack-grafana -n monitoring 3000:80
  EOT
}
