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

output "velero_irsa_role_arn" {
  value = module.velero_irsa.iam_role_arn
}

output "loki_irsa_role_arn" {
  value = module.loki_irsa.iam_role_arn
}

output "grafana_access" {
  value = "kubectl port-forward svc/prometheus-stack-grafana -n monitoring 3000:80"
}

output "velero_status" {
  value = "velero backup get && velero schedule get"
}
