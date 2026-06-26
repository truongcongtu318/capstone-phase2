variable "name_prefix" {
  description = "Prefix cho resource name"
  type        = string
  default     = "tf3-cdo1"
}

variable "aws_region" {
  description = "AWS region cho toàn bộ sandbox"
  type        = string
  default     = "us-east-1"
}

variable "github_repo" {
  description = "org/repo cho GitHub OIDC trust policy (CI auth) — vd \"truongcongtu318/capstone-phase2\""
  type        = string
}
variable "tags" {
  type        = map(string)
  description = "Map tags truyền từ root (để trống hoặc không dùng ở module bootstrap)"
  default     = {}
}