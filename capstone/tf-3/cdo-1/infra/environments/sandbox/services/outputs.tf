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

output "firehose_stream_arn" {
  description = "ARN của Kinesis Firehose delivery stream tf3-cdo1-sandbox-audit-stream"
  value       = module.observability.firehose_stream_arn
}
