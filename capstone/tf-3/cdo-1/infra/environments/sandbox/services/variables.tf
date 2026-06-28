variable "aws_region" {
  type        = string
  description = "AWS Region triển khai hạ tầng"
  default     = "us-east-1"
}

variable "tf_state_bucket" {
  type        = string
  description = "Tên S3 bucket chứa Terraform remote state của tất cả các phase"
  default     = "tf-3-aiops-audit-trail"
}

variable "environment" {
  type        = string
  description = "Tên môi trường triển khai"
  default     = "sandbox"
}

variable "name_prefix" {
  type        = string
  description = "Tiền tố đặt tên tài nguyên AWS"
  default     = "tf3-cdo1"
}

variable "global_tags" {
  type        = map(string)
  description = "Tags chung áp dụng cho tất cả tài nguyên trong phase này"
  default = {
    Project   = "CDO-01"
    TaskForce = "TF-3"
    Team      = "SubTeam1"
    Env       = "sandbox"
    ManagedBy = "terraform"
  }
}
