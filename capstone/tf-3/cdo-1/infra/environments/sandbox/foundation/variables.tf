variable "aws_region" {
  description = "AWS region cho toàn bộ sandbox"
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix dùng cho resource name — phải khớp với var.name_prefix trong module.eks"
  type        = string
  default     = "tf3-cdo1-sandbox"
}

locals {
  common_tags = {
    Project   = "self-heal-platform"
    TaskForce = "tf-3"
    Team      = "cdo-1"
    Env       = "sandbox"
    ManagedBy = "terraform"
  }
}
variable "tags" {
  type        = map(string)
  description = "Override tags — nếu không truyền, module dùng local.common_tags trực tiếp"
  default     = {}
}