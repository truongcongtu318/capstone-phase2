variable "cluster_name" {
  type        = string
  description = "Tên EKS Cluster — lấy từ data.terraform_remote_state.compute.outputs.cluster_name"
}

variable "oidc_provider_arn" {
  type        = string
  description = "ARN của OIDC Provider gắn với EKS cluster — dùng cho IRSA trust policy của AWS LBC"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID — lấy từ data.terraform_remote_state.networking.outputs.vpc_id"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Danh sách Private Subnet IDs để đặt Internal ALB — KHÔNG dùng public subnet"
}

variable "sg_alb_internal_id" {
  type        = string
  description = "Security Group ID của Internal ALB — lấy từ data.terraform_remote_state.networking.outputs.sg_alb_internal_id"
}

variable "global_tags" {
  type        = map(string)
  description = "Tags chung của dự án — truyền vào từ root module environment"
  default     = {}
}

variable "enabled" {
  type        = bool
  description = "Bật/tắt toàn bộ K8s/Helm/IAM resources trong module — đặt false khi chạy dry-run plan trước khi EKS tồn tại"
  default     = true
}
