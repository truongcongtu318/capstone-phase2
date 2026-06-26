output "state_bucket_name" {
  description = "Copy giá trị này vào environments/sandbox/foundation/backend.tf sau khi apply"
  value       = aws_s3_bucket.state.id
}

output "state_lock_table_name" {
  description = "DynamoDB table cho Terraform state lock (KHÔNG phải tf-3-aiops-idempotency-lock)"
  value       = aws_dynamodb_table.state_lock.id
}

output "state_kms_key_arn" {
  description = "KMS Key ARN dùng mã hóa state bucket"
  value       = aws_kms_key.state.arn
}

output "github_oidc_provider_arn" {
  description = "OIDC Provider ARN của GitHub Actions — tham khảo khi tạo thêm role CI"
  value       = aws_iam_openid_connect_provider.github.arn
}

# ── 2 role tách biệt theo mức quyền ──

output "github_ci_plan_role_arn" {
  description = "IAM Role cho CI Plan/Validate — any branch/PR có thể assume, chỉ read-only. Gán vào GitHub secret AWS_ROLE_ARN_PLAN"
  value       = aws_iam_role.github_actions_plan.arn
}

output "github_ci_apply_role_arn" {
  description = "IAM Role cho CI Apply/Push — CHỈ main branch. Gán vào GitHub secret AWS_ROLE_ARN_APPLY"
  value       = aws_iam_role.github_actions_apply.arn
}
