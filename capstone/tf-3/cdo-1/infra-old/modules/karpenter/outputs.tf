output "node_iam_role_arn" {
  description = "IAM role ARN của node do Karpenter provision — tham khảo nếu module khác cần attach policy"
  value       = var.node_iam_role_arn # Karpenter uses the shared EKS node role from module.eks
}

output "karpenter_controller_role_arn" {
  description = "IAM role ARN của Karpenter controller (IRSA) — để debug/audit IRSA"
  value       = aws_iam_role.karpenter_controller.arn
}

output "interruption_queue_url" {
  description = "SQS queue URL cho Spot interruption — dùng bởi Karpenter controller settings"
  value       = aws_sqs_queue.karpenter_interruption.url
}
