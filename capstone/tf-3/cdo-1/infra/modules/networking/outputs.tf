output "vpc_id" {
  description = "VPC ID — dung boi modules/security, modules/eks, modules/ingress"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block — dung boi modules/security"
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs — dung boi modules/eks, modules/karpenter, modules/ingress"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (hien tai it dung vi ALB la internal)"
  value       = aws_subnet.public[*].id
}
