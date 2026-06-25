output "state_bucket_name" {
  description = "Copy giá trị này vào environments/sandbox/foundation/backend.tf sau khi apply"
  value       = null # TODO(INFRA-1)
}

output "state_lock_table_name" {
  value = null # TODO(INFRA-1)
}

output "github_oidc_role_arn" {
  value = null # TODO(INFRA-1)
}
