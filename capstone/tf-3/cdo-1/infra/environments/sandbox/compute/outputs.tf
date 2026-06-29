output "cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name"
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "EKS cluster API endpoint"
}

output "cluster_ca_data" {
  value       = module.eks.cluster_ca_data
  description = "EKS cluster certificate authority data"
}

output "oidc_provider_arn" {
  value       = module.eks.oidc_provider_arn
  description = "OIDC provider ARN for IRSA"
}

output "node_iam_role_arn" {
  value       = module.karpenter.node_iam_role_arn
  description = "ARN of Karpenter node role"
}
