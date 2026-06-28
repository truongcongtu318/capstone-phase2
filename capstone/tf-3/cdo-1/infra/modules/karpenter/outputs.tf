output "node_iam_role_arn" {
  value       = aws_iam_role.node.arn
  description = "ARN of Karpenter node role"
}

output "controller_role_arn" {
  value       = aws_iam_role.controller.arn
  description = "ARN of Karpenter controller role"
}
