# Cấu hình Security Groups & KMS Customer Managed Keys (docs/03_security_design.md §1.2 & §4.1)

# =============================================================================
# 1. SECURITY GROUPS (Bám sát bảng Security Groups §1.2)
# =============================================================================

# sg-alb-internal: Inbound 443 từ client/VPN. Outbound 8443 đến workload pods.
resource "aws_security_group" "alb_internal" {
  name        = "${var.name_prefix}-alb-internal"
  description = "Security group for Internal ALB"
  vpc_id      = var.vpc_id

  # WARNING: Sandbox tạm mở 443 cho toàn bộ vpc_cidr. Trước khi merge lên
  # staging/production, PHẢI thu hẹp source về SG của Internal Alert Relay
  # và/hoặc VPN client SG. Track tại: docs/03_security_design.md §1.2 hàng 36
  # và Open Question §8 (mục "Xác nhận SG/CIDR cụ thể của Internal Alert Relay").
  ingress {
    description = "Allow HTTPS inbound from VPC (VPN/Client CIDR) - TODO(pre-prod): Thu hẹp về SG relay/VPN, xem 03_security_design.md §8"
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

# Workload Ingress kubelet (matching egress ở trên)
# EKS-managed cluster SG có thể đã cover, nhưng khai báo rõ ràng để:
# 1. Không phụ thuộc ngầm vào cluster SG mà EKS tự quản lý.
# 2. Dễ review/audit — nhìn SG rules là thấy đủ flow, không cần đoán.
resource "aws_security_group_rule" "workload_ingress_kubelet_from_control_plane" {
  type                     = "ingress"
  description              = "Allow kubelet inbound from EKS control plane (port 10250)"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_workload.id
  source_security_group_id = aws_security_group.eks_control_plane.id
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

# Lấy account ID và region hiện tại để dùng trong KMS key policy
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_kms_key" "keys" {
  for_each = toset(local.kms_aliases)

  description             = "KMS key managed by Terraform for ${each.key}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  # Key policy: cấp quyền admin cho root account (mặc định) và cấp quyền
  # cho CloudWatch Logs service principal nếu key là cdo-observability-kms.
  # Nếu thiếu policy này, terraform apply sẽ fail với InvalidParameterException
  # khi aws_cloudwatch_log_group (PR #47) dùng kms_key_id trỏ vào key này.
  policy = each.key == "cdo-observability-kms" ? jsonencode({
    Version = "2012-10-17"
    Id      = "${each.key}-policy"
    Statement = [
      {
        Sid       = "EnableRootAccountFullAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid    = "AllowCloudWatchLogsEncryption"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.name}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:*"
          }
        }
      }
    ]
  }) : null

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
