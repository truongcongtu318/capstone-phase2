locals {
  module_tags = merge(var.global_tags, {
    Component = "karpenter"
  })
}

# ── Controller Role (IRSA) ────────────────────────────────────────────────────

resource "aws_iam_role" "controller" {
  name        = "${var.name_prefix}-karpenter-controller-role"
  description = "Karpenter Controller IRSA Role"
  tags        = local.module_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider}:sub" = "system:serviceaccount:karpenter:karpenter"
          "${var.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  inline_policy {
    name = "karpenter-controller-policy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid    = "KarpenterEC2"
          Effect = "Allow"
          Action = [
            "ec2:CreateFleet",
            "ec2:RunInstances",
            "ec2:CreateLaunchTemplate",
            "ec2:DeleteLaunchTemplate",
            "ec2:DescribeInstanceTypes",
            "ec2:DescribeInstances",
            "ec2:DescribeSubnets",
            "ec2:DescribeSecurityGroups",
            "ec2:DescribeImages",
            "ec2:DescribeSpotPriceHistory",
            "ec2:CreateTags",
            "ec2:DeleteTags",
            "ec2:TerminateInstances",
            "ec2:DescribeAvailabilityZones",
            "ec2:DescribeLaunchTemplates",
            "ec2:DescribeInstanceTypeOfferings",
            "ec2:DescribeKeyPairs"
          ]
          Resource = "*"
        },
        {
          Sid    = "KarpenterEKS"
          Effect = "Allow"
          Action = [
            "eks:DescribeCluster"
          ]
          Resource = "arn:aws:eks:*:*:cluster/*"
        },
        {
          Sid    = "KarpenterPricing"
          Effect = "Allow"
          Action = [
            "pricing:GetProducts"
          ]
          Resource = "*"
        },
        {
          Sid    = "KarpenterSSM"
          Effect = "Allow"
          Action = [
            "ssm:GetParameter"
          ]
          Resource = "arn:aws:ssm:*:*:parameter/aws/service/*"
        },
        {
          Sid    = "KarpenterIAM"
          Effect = "Allow"
          Action = [
            "iam:CreateInstanceProfile",
            "iam:DeleteInstanceProfile",
            "iam:AddRoleToInstanceProfile",
            "iam:RemoveRoleFromInstanceProfile",
            "iam:TagInstanceProfile",
            "iam:GetInstanceProfile"
          ]
          Resource = "*"
        },
        {
          Sid      = "KarpenterPassRole"
          Effect   = "Allow"
          Action   = "iam:PassRole"
          Resource = aws_iam_role.node.arn
        },
        {
          Sid    = "KarpenterSLR"
          Effect = "Allow"
          Action = [
            "iam:CreateServiceLinkedRole"
          ]
          Resource = "arn:aws:iam::*:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot"
        }
      ]
    })
  }
}

# ── Node Role ─────────────────────────────────────────────────────────────────

resource "aws_iam_role" "node" {
  name        = "${var.name_prefix}-karpenter-node-role"
  description = "Karpenter Node Role"
  tags        = local.module_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ── Instance Profile ──────────────────────────────────────────────────────────

resource "aws_iam_instance_profile" "karpenter" {
  name = "${var.name_prefix}-karpenter-node-profile"
  role = aws_iam_role.node.name
  tags = local.module_tags
}
