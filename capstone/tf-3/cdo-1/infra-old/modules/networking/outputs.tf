output "vpc_id" {
  description = "VPC ID — dùng bởi modules/security, modules/eks, modules/ingress"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block — dùng bởi modules/security (SG self-reference nếu cần)"
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs — dùng bởi modules/eks, modules/karpenter, modules/ingress"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (hiện tại ít dùng vì ALB là internal)"
  value       = aws_subnet.public[*].id
}

