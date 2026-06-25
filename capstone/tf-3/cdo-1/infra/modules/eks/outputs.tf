output "cluster_name" {
  description = "Dùng bởi modules/karpenter, modules/ingress, modules/observability, providers.tf ở root"
  value       = null # TODO(INFRA-4)
}

output "cluster_endpoint" {
  value = null # TODO(INFRA-4)
}

output "cluster_ca_data" {
  description = "Base64 CA cert — dùng cho kubernetes/helm provider ở environments/sandbox/foundation/providers.tf"
  value       = null # TODO(INFRA-4)
}

output "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN — dùng bởi modules/karpenter, modules/ingress, modules/observability"
  value       = null # TODO(INFRA-4)
}
