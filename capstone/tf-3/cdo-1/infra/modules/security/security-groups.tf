# Security Groups (docs/03_security_design.md §1.2 & §4.1)

# sg-alb-internal: Inbound 443 từ client/VPN. Outbound 8443 đến workload pods.
resource "aws_security_group" "alb_internal" {
  name        = "${var.name_prefix}-alb-internal"
  description = "Security group for Internal ALB"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow HTTPS inbound from VPC (VPN/Client CIDR)"
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
  name        = "${var.name_prefix}-eks-workload"
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
  name        = "${var.name_prefix}-eks-control-plane"
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
  name        = "${var.name_prefix}-rds"
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
  name        = "${var.name_prefix}-vpc-endpoint"
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

# Workload Ingress kubelet
resource "aws_security_group_rule" "workload_ingress_kubelet_from_control_plane" {
  type                     = "ingress"
  description              = "Allow kubelet inbound from EKS control plane (port 10250)"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_workload.id
  source_security_group_id = aws_security_group.eks_control_plane.id
}

# Control Plane Outbound to Endpoints
resource "aws_security_group_rule" "control_plane_egress_to_endpoints" {
  type                     = "egress"
  description              = "Allow HTTPS outbound to VPC Endpoints"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_control_plane.id
  source_security_group_id = aws_security_group.vpc_endpoint.id
}

# Workload Self-Communication (node-to-node, pod-to-pod, CoreDNS)
resource "aws_security_group_rule" "workload_ingress_self" {
  type              = "ingress"
  description       = "Allow node-to-node and pod-to-pod communication"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.eks_workload.id
  self              = true
}

# Admission Webhooks: Control Plane → Workload (Karpenter 8443, Kyverno 9443)
resource "aws_security_group_rule" "workload_ingress_webhooks_from_control_plane" {
  type                     = "ingress"
  description              = "Allow admission webhooks (Karpenter 8443, Kyverno 9443) from control plane"
  from_port                = 443
  to_port                  = 9443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_workload.id
  source_security_group_id = aws_security_group.eks_control_plane.id
}
