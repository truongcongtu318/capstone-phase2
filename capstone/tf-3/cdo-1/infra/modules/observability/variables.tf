variable "cluster_name" {
  type        = string
  description = "Tên EKS Cluster — dùng để đặt tên CloudWatch Log Group /aws/eks/<cluster_name>/cluster"
}

variable "oidc_provider_arn" {
  type        = string
  description = "ARN của OIDC Provider gắn với EKS cluster — dùng cho IRSA trust policy của Worker (self-heal-executor)"
}

variable "kms_observability_arn" {
  type        = string
  description = "ARN của KMS Key alias/cdo-observability-kms — mã hóa CloudWatch Log Group observability"
}

variable "kms_audit_arn" {
  type        = string
  description = "ARN của KMS Key alias/cdo-audit-kms — mã hóa Kinesis Firehose delivery stream & S3 audit bucket"
}

variable "s3_audit_bucket_arn" {
  type        = string
  description = "ARN của S3 Audit Bucket tf-3-aiops-audit-trail — đích ghi log bất biến SOC2"
}

variable "name_prefix" {
  type        = string
  description = "Tiền tố đặt tên tài nguyên AWS — ví dụ: tf3-cdo1"
}

variable "environment" {
  type        = string
  description = "Tên môi trường triển khai — ví dụ: sandbox"
}

variable "global_tags" {
  type        = map(string)
  description = "Tags chung của dự án — truyền vào từ root module environment"
  default     = {}
}

variable "enabled" {
  type        = bool
  description = "Bật/tắt toàn bộ K8s/Helm resources trong module — đặt false khi chạy dry-run plan trước khi EKS tồn tại"
  default     = true
}
