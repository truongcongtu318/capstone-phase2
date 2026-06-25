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
