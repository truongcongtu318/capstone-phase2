output "state_bucket_name" {
  description = "Copy giá trị này vào environments/sandbox/*/backend.tf"
  value       = aws_s3_bucket.state.id
}

output "state_lock_table_name" {
  description = "DynamoDB table cho Terraform state lock"
  value       = aws_dynamodb_table.state_lock.id
}

output "state_kms_key_arn" {
  description = "KMS Key ARN dùng mã hóa state bucket"
  value       = aws_kms_key.state.arn
}

output "github_oidc_provider_arn" {
  description = "OIDC Provider ARN của GitHub Actions"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "github_ci_plan_role_arn" {
  description = "IAM Role cho CI Plan/Validate"
  value       = aws_iam_role.github_actions_plan.arn
}

output "github_ci_apply_role_arn" {
  description = "IAM Role cho CI Apply/Push"
  value       = aws_iam_role.github_actions_apply.arn
}
