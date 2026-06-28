output "grafana_service_name" {
  description = "K8s Service name cua Grafana dung cho smoke test"
  value       = local.grafana_service
}

output "firehose_stream_arn" {
  description = "ARN of Kinesis Firehose delivery stream for audit logs"
  value       = aws_kinesis_firehose_delivery_stream.audit_stream.arn
}

output "worker_irsa_role_arn" {
  description = "ARN of IAM Role for EKS SQS Worker (self-heal-executor)"
  value       = aws_iam_role.worker_irsa.arn
}
