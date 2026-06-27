output "sg_alb_internal_id" {
  description = "SG cho Internal ALB — dùng bởi modules/ingress"
  value       = aws_security_group.alb_internal.id
}

output "sg_eks_workload_id" {
  description = "SG cho EKS workload pods — dùng bởi modules/eks, modules/karpenter, modules/ingress"
  value       = aws_security_group.eks_workload.id
}

output "sg_eks_control_plane_id" {
  description = "SG cho EKS control plane ENI — dùng bởi modules/eks"
  value       = aws_security_group.eks_control_plane.id
}

output "sg_rds_id" {
  description = "SG cho RDS sandbox (optional, dùng từ Pack #2)"
  value       = aws_security_group.rds.id
}

output "sg_vpc_endpoint_id" {
  description = "SG cho Interface VPC Endpoint — dùng bởi modules/networking"
  value       = aws_security_group.vpc_endpoint.id
}

output "kms_infra_arn" {
  description = "KMS key ARN cho infra state/artifacts — dùng bởi modules/eks"
  value       = aws_kms_key.keys["cdo-infra-kms"].arn
}

output "kms_observability_arn" {
  description = "KMS key ARN cho observability logs — dùng bởi modules/observability"
  value       = aws_kms_key.keys["cdo-observability-kms"].arn
}
