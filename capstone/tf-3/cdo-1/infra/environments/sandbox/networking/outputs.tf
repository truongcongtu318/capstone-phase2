output "vpc_id" {
  description = "VPC ID used by downstream compute and services states"
  value       = module.networking.vpc_id
}

output "vpc_cidr" {
  description = "CIDR block of the sandbox VPC"
  value       = module.networking.vpc_cidr
}

output "private_subnet_ids" {
  description = "Private subnet IDs for EKS workloads and private data services"
  value       = module.networking.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs for public-facing or edge resources"
  value       = module.networking.public_subnet_ids
}

output "sg_eks_workload_id" {
  description = "Security group ID for EKS workloads"
  value       = module.security.sg_eks_workload_id
}

output "sg_eks_control_plane_id" {
  description = "Security group ID for EKS control plane ENIs"
  value       = module.security.sg_eks_control_plane_id
}

output "sg_rds_id" {
  description = "Security group ID for RDS"
  value       = module.security.sg_rds_id
}

output "sg_vpc_endpoint_id" {
  description = "Security group ID for Interface VPC endpoints"
  value       = module.security.sg_vpc_endpoint_id
}

output "kms_infra_arn" {
  description = "KMS key ARN for infrastructure resources"
  value       = module.security.kms_infra_arn
}

output "kms_observability_arn" {
  description = "KMS key ARN for observability log encryption"
  value       = module.security.kms_observability_arn
}

output "kms_audit_arn" {
  description = "KMS key ARN for audit trail log encryption"
  value       = module.security.kms_audit_arn
}
