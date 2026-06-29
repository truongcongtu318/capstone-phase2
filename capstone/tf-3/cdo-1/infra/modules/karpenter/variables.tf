variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
}

variable "oidc_provider_arn" {
  type        = string
  description = "ARN of the OIDC provider for the EKS cluster"
}

variable "oidc_provider" {
  type        = string
  description = "OIDC provider URL (without https://)"
}

variable "name_prefix" {
  type        = string
  default     = "tf3-cdo1-sandbox"
  description = "Prefix for all resource names"
}

variable "global_tags" {
  type        = map(string)
  default     = {}
  description = "Global tags to merge into all resources"
}
