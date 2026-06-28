output "grafana_service_name" {
  description = "K8s Service name của Grafana — dùng cho smoke test sau khi deploy"
  value       = local.grafana_service
}

output "firehose_stream_arn" {
  description = "ARN của Kinesis Firehose delivery stream tf3-cdo1-sandbox-audit-stream"
  value       = aws_kinesis_firehose_delivery_stream.audit_stream.arn
}

output "worker_irsa_role_arn" {
  description = "ARN của IAM Role IRSA cho self-heal-executor — Sub-team 2 dùng để gắn annotation vào ServiceAccount"
  value       = aws_iam_role.worker_irsa.arn
}
