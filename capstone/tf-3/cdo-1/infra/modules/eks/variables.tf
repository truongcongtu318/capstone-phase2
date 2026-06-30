variable "sg_vpc_endpoint_id" {
  description = "Security group ID for VPC Endpoints to configure Egress rules for Cluster SG"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EKS"
  type        = list(string)
}

variable "sg_eks_control_plane_id" {
  description = "Security group ID for EKS control plane"
  type        = string
}

variable "sg_eks_workload_id" {
  description = "Security group ID for EKS workloads"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for secrets encryption"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "tf3-cdo1-sandbox-eks"
}

variable "eks_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "global_tags" {
  description = "Global tags applied to all resources"
  type        = map(string)
  default     = {}
}
