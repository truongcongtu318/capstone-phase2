output "alb_dns_name" {
  description = "Internal ALB DNS name — populated after a workload Ingress using the alb-internal IngressClass is created"
  value       = module.ingress.alb_dns_name
}

output "grafana_service_name" {
  description = "K8s Service name của Grafana — dùng cho smoke test sau khi deploy"
  value       = module.observability.grafana_service_name
}

output "worker_irsa_role_arn" {
  description = "ARN của IAM Role IRSA cho self-heal-executor — Sub-team 2 dùng để gắn annotation vào ServiceAccount"
  value       = module.observability.worker_irsa_role_arn
}

output "webhook_irsa_role_arn" {
  description = "ARN của IAM Role IRSA cho webhook-receiver — Sub-team 2 dùng để gắn annotation vào ServiceAccount"
  value       = module.observability.webhook_irsa_role_arn
}

output "sqs_queue_arn" {
  description = "ARN của SQS Queue chính của self-heal pipeline"
  value       = module.observability.sqs_queue_arn
}

output "sqs_queue_id" {
  description = "URL / Name của SQS Queue chính"
  value       = module.observability.sqs_queue_id
}

output "sns_topic_arn" {
  description = "ARN của SNS Topic để leo thang cảnh báo"
  value       = module.observability.sns_topic_arn
}

output "firehose_stream_arn" {
  description = "ARN của Kinesis Firehose delivery stream tf3-cdo1-sandbox-audit-stream"
  value       = module.observability.firehose_stream_arn
}

# -----------------------------------------------------------------------------
# DYNAMODB: App Idempotency Lock Table
# -----------------------------------------------------------------------------

output "app_idempotency_table_name" {
  description = "DynamoDB table name for application idempotency lock"
  value       = aws_dynamodb_table.app_idempotency.name
}

output "app_idempotency_table_arn" {
  description = "DynamoDB table ARN for application idempotency lock"
  value       = aws_dynamodb_table.app_idempotency.arn
}

# -----------------------------------------------------------------------------
# CODECOMMIT: GitOps Repository
# -----------------------------------------------------------------------------

output "gitops_repo_name" {
  description = "CodeCommit repository name for GitOps manifests"
  value       = aws_codecommit_repository.gitops.repository_name
}

output "gitops_repo_clone_url" {
  description = "CodeCommit repository clone URL (HTTPS)"
  value       = aws_codecommit_repository.gitops.clone_url_http
}

# -----------------------------------------------------------------------------
# IAM ROLE � AI Engine IRSA
# -----------------------------------------------------------------------------

output "ai_engine_irsa_role_arn" {
  description = "IAM role ARN for AI Engine to call Bedrock API"
  value       = module.observability.ai_engine_irsa_role_arn
}
