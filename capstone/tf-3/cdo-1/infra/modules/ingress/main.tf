# =============================================================================
# MODULE: ingress — AWS Load Balancer Controller (IRSA + Helm + IngressClass)
# NAT-less: image phải trỏ về ECR Private 474013238625.dkr.ecr.us-east-1.amazonaws.com
# =============================================================================

data "aws_region" "current" {}

locals {
  service_account_name = "aws-load-balancer-controller"
  service_account_ns   = "kube-system"
  oidc_provider_url    = replace(var.oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")
  ecr_registry         = "474013238625.dkr.ecr.us-east-1.amazonaws.com"
}

# =============================================================================
# IAM ROLE — IRSA cho AWS Load Balancer Controller
# =============================================================================

data "aws_iam_policy_document" "lbc_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${local.service_account_ns}:${local.service_account_name}"]
    }
  }
}

resource "aws_iam_role" "lbc" {
  name               = "${var.cluster_name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume_role.json
  tags               = local.module_tags
}

# =============================================================================
# IAM POLICY — Quyền tối thiểu cho AWS LBC quản lý ALB/NLB
# =============================================================================

data "aws_iam_policy_document" "lbc" {
  statement {
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeCoipPools",
      "ec2:DescribeInstances",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeTags",
      "ec2:DescribeVpcs",
      "ec2:GetCoipPoolUsage",
      "ec2:GetSecurityGroupsForVpc",
      "elasticloadbalancing:DescribeListenerAttributes",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeSSLPolicies",
      "elasticloadbalancing:DescribeTags",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:CreateSecurityGroup",
      "ec2:RevokeSecurityGroupIngress",
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:*:*:security-group/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSecurityGroup"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
    resources = ["arn:aws:ec2:*:*:security-group/*"]

    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:DeleteSecurityGroup",
      "ec2:RevokeSecurityGroupIngress",
    ]
    resources = ["*"]

    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:CreateTargetGroup",
    ]
    resources = ["*"]

    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:DeleteRule",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
    ]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
      "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
    ]

    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["true"]
    }

    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
    ]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:SetIpAddressType",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:SetWebAcl",
    ]
    resources = ["*"]

    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["elasticloadbalancing:DeregisterTargets"]
    resources = ["arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:ModifyRule",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lbc" {
  name   = "${var.cluster_name}-aws-load-balancer-controller"
  policy = data.aws_iam_policy_document.lbc.json
  tags   = local.module_tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

# =============================================================================
# KUBERNETES SERVICE ACCOUNT — gắn annotation IRSA
# =============================================================================

resource "kubernetes_service_account" "lbc" {
  metadata {
    name      = local.service_account_name
    namespace = local.service_account_ns
    labels = {
      "app.kubernetes.io/component" = "controller"
      "app.kubernetes.io/name"      = local.service_account_name
    }
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.lbc.arn
    }
  }
}

# =============================================================================
# HELM RELEASE — AWS Load Balancer Controller
# NAT-less: image.repository trỏ về ECR Private
# =============================================================================

resource "helm_release" "lbc" {
  name      = "aws-load-balancer-controller"
  chart     = "aws-load-balancer-controller"
  namespace = local.service_account_ns
  version   = "1.8.1"

  # NAT-less: repository phải là S3 Helm repo nội bộ hoặc chart path local.
  # Tạm thời khai báo repository public để validate — Sub-team 3 sẽ mirror chart vào S3.
  repository = "https://aws.github.io/eks-charts"

  values = [
    yamlencode({
      clusterName = var.cluster_name
      region      = data.aws_region.current.name
      vpcId       = var.vpc_id

      # NAT-less: override image về ECR Private
      image = {
        repository = "${local.ecr_registry}/amazon/aws-load-balancer-controller"
        tag        = "v2.8.1"
      }

      serviceAccount = {
        create = false
        name   = kubernetes_service_account.lbc.metadata[0].name
      }

      # Không cần Shield/WAF trong sandbox
      enableShield = false
      enableWaf    = false
      enableWafv2  = false

      defaultTags = local.module_tags
    })
  ]

  depends_on = [
    aws_iam_role_policy_attachment.lbc,
    kubernetes_service_account.lbc,
  ]
}

# =============================================================================
# INGRESS CLASS — alb-internal (scheme: internal, dùng Private Subnets)
# =============================================================================

resource "kubernetes_ingress_class_v1" "alb_internal" {
  metadata {
    name = "alb-internal"
    annotations = {
      "ingressclass.kubernetes.io/is-default-class" = "false"
    }
  }
  spec {
    controller = "elbv2.k8s.aws/alb"
    parameters {
      api_group = "elbv2.k8s.aws"
      kind      = "IngressClassParams"
      name      = kubernetes_manifest.alb_internal_params.manifest.metadata.name
    }
  }
  depends_on = [kubernetes_manifest.alb_internal_params]
}

# IngressClassParams — ràng buộc ALB luôn là Internal + Private Subnets
resource "kubernetes_manifest" "alb_internal_params" {
  manifest = {
    apiVersion = "elbv2.k8s.aws/v1beta1"
    kind       = "IngressClassParams"
    metadata = {
      name = "alb-internal-params"
    }
    spec = {
      scheme = "internal"
      subnets = {
        ids = var.private_subnet_ids
      }
      securityGroups = {
        ids = [var.sg_alb_internal_id]
      }
      tags = [
        {
          key   = "Component"
          value = "ingress"
        }
      ]
    }
  }
  depends_on = [helm_release.lbc]
}
