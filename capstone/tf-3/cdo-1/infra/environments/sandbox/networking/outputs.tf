output "vpc_id" {
  description = "VPC ID dung boi compute/services remote state"
  value       = module.networking.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = module.networking.vpc_cidr
}

output "private_subnet_ids" {
  description = "Private subnet IDs cho EKS workloads/RDS"
  value       = module.networking.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.networking.public_subnet_ids
}

output "sg_eks_workload_id" {
  description = "SG cho EKS workload pods"
  value       = module.security.sg_eks_workload_id
}

output "sg_eks_control_plane_id" {
  description = "SG cho EKS control plane ENI"
  value       = module.security.sg_eks_control_plane_id
}

output "sg_alb_internal_id" {
  description = "SG cho Internal ALB"
  value       = module.security.sg_alb_internal_id
}

output "sg_rds_id" {
  description = "SG cho RDS sandbox PostgreSQL"
  value       = module.security.sg_rds_id
}

output "sg_vpc_endpoint_id" {
  description = "SG cho Interface VPC endpoints"
  value       = module.security.sg_vpc_endpoint_id
}

output "kms_infra_arn" {
  description = "KMS key ARN cho infra"
  value       = module.security.kms_infra_arn
}

output "kms_observability_arn" {
  description = "KMS key ARN cho observability"
  value       = module.security.kms_observability_arn
}
