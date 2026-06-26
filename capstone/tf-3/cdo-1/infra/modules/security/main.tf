# Cấu hình Security Groups & KMS Customer Managed Keys (docs/03_security_design.md §1.2 & §4.1)

# =============================================================================
# 1. SECURITY GROUPS (Bám sát bảng Security Groups §1.2)
# =============================================================================

# sg-alb-internal: Inbound 443 từ client/VPN. Outbound 8443 đến workload pods.
resource "aws_security_group" "alb_internal" {
  name        = "sg-alb-internal"
  description = "Security group for Internal ALB"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow HTTPS inbound from VPC (VPN/Client CIDR) - TODO: Thu hẹp nguồn truy cập khi có SG của Alert Relay"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(
    local.module_tags,
    {
      Name = "sg-alb-internal"
    }
  )
}

# sg-eks-workload: Workload pods inbound 8443 từ ALB.
resource "aws_security_group" "eks_workload" {
  name        = "sg-eks-workload"
  description = "Security group for EKS workload pods"
  vpc_id      = var.vpc_id

  tags = merge(
    local.module_tags,
    {
      Name = "sg-eks-workload"
    }
  )
}

# sg-eks-control-plane: EKS Master node control plane.
resource "aws_security_group" "eks_control_plane" {
  name        = "sg-eks-control-plane"
  description = "Security group for EKS control plane ENI"
  vpc_id      = var.vpc_id

  tags = merge(
    local.module_tags,
    {
      Name = "sg-eks-control-plane"
    }
  )
}

# sg-rds: Inbound 5432 từ Workload. No outbound.
resource "aws_security_group" "rds" {
  name        = "sg-rds"
  description = "Security group for RDS PostgreSQL Sandbox DB"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Allow database access only from EKS workloads"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_workload.id]
  }

  tags = merge(
    local.module_tags,
    {
      Name = "sg-rds"
    }
  )
}

# sg-vpc-endpoint: Interface endpoints inbound 443 từ Workload và Control Plane.
resource "aws_security_group" "vpc_endpoint" {
  name        = "sg-vpc-endpoint"
  description = "Security group for Interface VPC endpoints"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Allow HTTPS from EKS workload pods"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_workload.id]
  }

  ingress {
    description     = "Allow HTTPS from EKS control plane"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_control_plane.id]
  }

  tags = merge(
    local.module_tags,
    {
      Name = "sg-vpc-endpoint"
    }
  )
}

# =============================================================================
# SECURITY GROUP RULES (Sử dụng resource riêng biệt để tránh lỗi circular dependency)
# =============================================================================

# ALB Outbound
resource "aws_security_group_rule" "alb_egress_to_workload" {
  type                     = "egress"
  description              = "Allow HTTPS outbound to EKS workload pods"
  from_port                = 8443
  to_port                  = 8443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb_internal.id
  source_security_group_id = aws_security_group.eks_workload.id
}

# Workload Inbound
resource "aws_security_group_rule" "workload_ingress_from_alb" {
  type                     = "ingress"
  description              = "Allow traffic from internal ALB on 8443"
  from_port                = 8443
  to_port                  = 8443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_workload.id
  source_security_group_id = aws_security_group.alb_internal.id
}

# Workload Outbound
resource "aws_security_group_rule" "workload_egress_to_endpoints" {
  type                     = "egress"
  description              = "Allow HTTPS outbound to VPC Endpoints"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_workload.id
  source_security_group_id = aws_security_group.vpc_endpoint.id
}

resource "aws_security_group_rule" "workload_egress_to_rds" {
  type                     = "egress"
  description              = "Allow PostgreSQL outbound to RDS"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_workload.id
  source_security_group_id = aws_security_group.rds.id
}

resource "aws_security_group_rule" "workload_egress_to_control_plane" {
  type                     = "egress"
  description              = "Allow HTTPS outbound to EKS Control Plane"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_workload.id
  source_security_group_id = aws_security_group.eks_control_plane.id
}

# Control Plane Inbound
resource "aws_security_group_rule" "control_plane_ingress_from_workload" {
  type                     = "ingress"
  description              = "Allow HTTPS inbound from EKS workloads"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_control_plane.id
  source_security_group_id = aws_security_group.eks_workload.id
}

# Control Plane Outbound
resource "aws_security_group_rule" "control_plane_egress_to_workload" {
  type                     = "egress"
  description              = "Allow outbound connection to worker nodes (kubelet)"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_control_plane.id
  source_security_group_id = aws_security_group.eks_workload.id
}

# Control Plane Outbound to Endpoints (docs/03_security_design.md §1.2 hàng 38)
resource "aws_security_group_rule" "control_plane_egress_to_endpoints" {
  type                     = "egress"
  description              = "Allow HTTPS outbound to VPC Endpoints"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_control_plane.id
  source_security_group_id = aws_security_group.vpc_endpoint.id
}

# =============================================================================
# 2. KMS KEYS (Bám sát thiết kế KMS §4.1 & CLAUDE.md)
# =============================================================================

locals {
  kms_aliases = [
    "cdo-audit-kms",
    "cdo-app-data-kms",
    "cdo-secrets-kms",
    "cdo-infra-kms",
    "cdo-observability-kms"
  ]
}

resource "aws_kms_key" "keys" {
  for_each = toset(local.kms_aliases)

  description             = "KMS key managed by Terraform for ${each.key}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(
    local.module_tags,
    {
      Name = "${var.name_prefix}-${each.key}"
    }
  )
}

resource "aws_kms_alias" "aliases" {
  for_each = toset(local.kms_aliases)

  name          = "alias/${each.key}"
  target_key_id = aws_kms_key.keys[each.key].key_id
}
