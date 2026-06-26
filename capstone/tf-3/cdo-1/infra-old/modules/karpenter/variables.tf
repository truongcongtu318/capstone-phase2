variable "cluster_name" {
  description = "Từ module.eks.cluster_name"
  type        = string
}

variable "oidc_provider_arn" {
  description = "Từ module.eks.oidc_provider_arn"
  type        = string
}

variable "private_subnet_ids" {
  description = "Từ module.networking.private_subnet_ids"
  type        = list(string)
}

variable "sg_eks_workload_id" {
  description = "Từ module.security.sg_eks_workload_id"
  type        = string
}

variable "node_iam_role_arn" {
  description = "Từ module.eks.node_iam_role_arn — ARN của EKS node IAM role, dùng cho iam:PassRole"
  type        = string
}

variable "node_iam_role_name" {
  description = "Từ module.eks — tên IAM role của node, dùng trong EC2NodeClass spec.role"
  type        = string
}

variable "instance_types" {
  description = "Instance pool cho Karpenter NodePool — theo docs/02_infra_design.md §6"
  type        = list(string)
  default     = ["t3.medium", "t3.large", "t3.xlarge"]
}

variable "max_nodes" {
  description = "Giới hạn số node tối đa (sandbox cost control) — docs/02_infra_design.md §6"
  type        = number
  default     = 5
}

variable "karpenter_version" {
  description = "Helm chart version của Karpenter — pin để tránh breaking changes"
  type        = string
  default     = "1.0.6" # Karpenter v1.0.x GA (latest stable khi code)
}

variable "tags" {
  type    = map(string)
  default = {}
}
