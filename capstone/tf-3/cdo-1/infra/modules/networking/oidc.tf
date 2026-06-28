# NOTE: OIDC Provider da duoc dinh nghia o bootstrap/main.tf
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "github_ci_plan" {
  name        = "github-ci-plan"
  description = "GitHub Actions OIDC role for Terraform plan - ${var.github_repo}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRepoPlan"
        Effect = "Allow"
        Principal = {
          Federated = data.aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
          }
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(local.module_tags, {
    Name = "github-ci-plan"
  })
}

resource "aws_iam_role" "github_ci_apply" {
  name        = "github-ci-apply"
  description = "GitHub Actions OIDC role for Terraform apply - ${var.github_repo}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowMainApply"
        Effect = "Allow"
        Principal = {
          Federated = data.aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main"
          }
        }
      }
    ]
  })

  tags = merge(local.module_tags, {
    Name = "github-ci-apply"
  })
}

resource "aws_iam_role_policy_attachment" "github_ci_plan_read_only" {
  role       = aws_iam_role.github_ci_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "github_ci_plan_state_lock" {
  name = "terraform-state-read-lock"
  role = aws_iam_role.github_ci_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowStateRead"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:GetEncryptionConfiguration"
        ]
        Resource = [
          "arn:aws:s3:::tf-3-aiops-audit-trail",
          "arn:aws:s3:::tf-3-aiops-audit-trail/*"
        ]
      },
      {
        Sid    = "AllowStateLock"
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeTable",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem"
        ]
        Resource = "arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/tf-3-aiops-idempotency-lock"
      },
      {
        Sid    = "AllowKmsStateRead"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "github_ci_apply_networking" {
  name = "networking-security-apply"
  role = aws_iam_role.github_ci_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowNetworkingSecurityApply"
        Effect = "Allow"
        Action = [
          "ec2:*Vpc*",
          "ec2:*Subnet*",
          "ec2:*RouteTable*",
          "ec2:*SecurityGroup*",
          "ec2:*Tags",
          "ec2:Describe*",
          "iam:*OpenIDConnectProvider*",
          "iam:*Role*",
          "iam:*RolePolicy*",
          "iam:List*",
          "iam:Get*",
          "kms:*",
          "s3:Get*",
          "s3:List*",
          "s3:PutObject",
          "s3:DeleteObject",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable"
        ]
        Resource = "*"
      }
    ]
  })
}
