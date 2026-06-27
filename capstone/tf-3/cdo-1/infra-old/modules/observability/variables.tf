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

variable "kms_observability_arn" {
  description = "Từ module.security.kms_observability_arn — encrypt CloudWatch log group"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
