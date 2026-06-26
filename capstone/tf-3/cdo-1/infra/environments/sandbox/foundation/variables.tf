variable "aws_region" {
  description = "AWS region cho toàn bộ sandbox"
  type        = string
  default     = "us-east-1"
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
  description = "Cấu hình bộ tags chung bắt buộc của dự án cho INFRA-7"
}