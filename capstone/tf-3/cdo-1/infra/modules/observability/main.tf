# TODO(INFRA-7): implement theo docs/02_infra_design.md §2 (Observability row)
# và docs/04_deployment_design.md §8 (Observability stack).
#
# Resource cần có:
# - helm_release "kube-prometheus-stack" (Prometheus + Grafana + AlertManager,
#   namespace "observability")
# - AlertManager route alert qua ClusterIP tới Webhook Receiver, bypass ALB
#   (docs/03_security_design.md §1.1)
# - aws_cloudwatch_log_group cho EKS control plane logs, encrypt bằng
#   var.kms_observability_arn
# - ADOT Collector (OpenTelemetry) nếu kịp — Pack #2 mới bắt buộc đầy đủ tracing
#
# Namespace `observability` là platform-critical — self-heal action KHÔNG được
# patch/delete resource trong namespace này (docs/03_security_design.md §2.2).

# Cost tracking: mọi resource hỗ trợ tag PHẢI dùng `tags = local.module_tags`
# (xem tags.tf) — không dùng var.tags trực tiếp, để Cost Explorer group theo Component.
