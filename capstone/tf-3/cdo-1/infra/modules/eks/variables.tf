variable "name_prefix" {
  type    = string
  default = "tf3-cdo1-sandbox"
}

variable "cluster_version" {
  description = "EKS version — chốt theo docs/02_infra_design.md §2 Component table"
  type        = string
  default     = "1.28"
}

variable "vpc_id" {
  description = "Từ module.networking.vpc_id"
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

variable "sg_eks_control_plane_id" {
  description = "Từ module.security.sg_eks_control_plane_id"
  type        = string
}

variable "kms_infra_arn" {
  description = "Từ module.security.kms_infra_arn — dùng cho EKS secrets envelope encryption"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
