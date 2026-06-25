output "sg_alb_internal_id" {
  description = "SG cho Internal ALB — dùng bởi modules/ingress"
  value       = null # TODO(INFRA-3)
}

output "sg_eks_workload_id" {
  description = "SG cho EKS workload pods — dùng bởi modules/eks, modules/karpenter, modules/ingress"
  value       = null # TODO(INFRA-3)
}

output "sg_eks_control_plane_id" {
  description = "SG cho EKS control plane ENI — dùng bởi modules/eks"
  value       = null # TODO(INFRA-3)
}

output "sg_rds_id" {
  description = "SG cho RDS sandbox (optional, dùng từ Pack #2)"
  value       = null # TODO(INFRA-3)
}

output "sg_vpc_endpoint_id" {
  description = "SG cho Interface VPC Endpoint — dùng bởi modules/networking"
  value       = null # TODO(INFRA-3)
}

output "kms_infra_arn" {
  description = "KMS key ARN cho infra state/artifacts — dùng bởi modules/eks"
  value       = null # TODO(INFRA-3)
}

output "kms_observability_arn" {
  description = "KMS key ARN cho observability logs — dùng bởi modules/observability"
  value       = null # TODO(INFRA-3)
}
