variable "cluster_name" {
  description = "Từ module.eks.cluster_name"
  type        = string
}

variable "cluster_endpoint" {
  description = "Từ module.eks.cluster_endpoint"
  type        = string
}

variable "oidc_provider_arn" {
  description = "Từ module.eks.oidc_provider_arn"
  type        = string
}

variable "vpc_id" {
  description = "Từ module.networking.vpc_id"
  type        = string
}

variable "private_subnet_ids" {
  description = "Internal ALB đặt ở private subnet — KHÔNG public (docs/03_security_design.md §1.1)"
  type        = list(string)
}

variable "sg_alb_internal_id" {
  description = "Từ module.security.sg_alb_internal_id"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
