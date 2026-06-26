output "cluster_name" {
  description = "Dùng bởi modules/karpenter, modules/ingress, modules/observability, providers.tf ở root"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "API server endpoint — dùng cho kubernetes/helm provider ở environments/sandbox/foundation/providers.tf"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_data" {
  description = "Base64 CA cert — dùng cho kubernetes/helm provider ở environments/sandbox/foundation/providers.tf"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN — dùng bởi modules/karpenter, modules/ingress, modules/observability"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "OIDC issuer URL (without https://) — dùng cho IRSA trust policy conditions"
  value       = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

output "node_iam_role_arn" {
  description = "IAM role ARN của EKS node — Karpenter module cần để tạo EC2NodeClass"
  value       = aws_iam_role.node.arn
}

output "node_iam_role_name" {
  description = "IAM role NAME của EKS node — Karpenter EC2NodeClass spec.role field"
  value       = aws_iam_role.node.name
}

output "node_iam_instance_profile_name" {
  description = "Instance profile name — fallback nếu dùng instanceProfile thay vì role"
  value       = aws_iam_instance_profile.node.name
}
