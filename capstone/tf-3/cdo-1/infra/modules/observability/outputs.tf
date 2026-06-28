output "grafana_service_name" {
  description = "K8s Service name của Grafana — dùng cho smoke test sau khi deploy"
  value       = local.grafana_service
}

output "firehose_stream_arn" {
  description = "ARN của Kinesis Firehose delivery stream tf3-cdo1-sandbox-audit-stream"
  value       = var.enabled ? aws_kinesis_firehose_delivery_stream.audit_stream[0].arn : ""
}

output "worker_irsa_role_arn" {
  description = "ARN của IAM Role IRSA cho self-heal-executor — Sub-team 2 dùng để gắn annotation vào ServiceAccount"
  value       = aws_iam_role.worker_irsa.arn
}

output "webhook_irsa_role_arn" {
  description = "ARN của IAM Role IRSA cho webhook-receiver — Sub-team 2 dùng để gắn annotation vào ServiceAccount"
  value       = aws_iam_role.webhook_irsa.arn
}

output "sqs_queue_arn" {
  description = "ARN của SQS Queue chính của self-heal pipeline"
  value       = aws_sqs_queue.self_heal_queue.arn
}

output "sqs_queue_id" {
  description = "URL / Name của SQS Queue chính"
  value       = aws_sqs_queue.self_heal_queue.id
}

output "sns_topic_arn" {
  description = "ARN của SNS Topic để leo thang cảnh báo"
  value       = aws_sns_topic.alerts_escalation.arn
}
