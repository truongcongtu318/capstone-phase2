data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ─────────────────────────────────────────────
# 1. KMS KEY - mã hóa Terraform state bucket
# ─────────────────────────────────────────────

resource "aws_kms_key" "state" {
  description             = "KMS key for Terraform state bucket - ${var.name_prefix}-${var.environment}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "kms:Create*",
          "kms:Describe*",
          "kms:Enable*",
          "kms:Put*",
          "kms:Update*",
          "kms:Revoke*",
          "kms:Disable*",
          "kms:Get*",
          "kms:List*",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowCryptographicOperations"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.name_prefix}-${var.environment}-state-kms"
  target_key_id = aws_kms_key.state.key_id
}

# ─────────────────────────────────────────────
# 2. S3 BUCKET - Terraform state storage & Audit Logs
# ─────────────────────────────────────────────

resource "aws_s3_bucket" "state" {
  bucket              = "tf-3-aiops-audit-trail"
  object_lock_enabled = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_object_lock_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = 90
    }
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "state_deny_http" {
  bucket     = aws_s3_bucket.state.id
  depends_on = [aws_s3_bucket_public_access_block.state]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# ─────────────────────────────────────────────
# 3. DYNAMODB TABLE - Terraform state lock & SQS Idempotency Lock
# ─────────────────────────────────────────────

resource "aws_dynamodb_table" "state_lock" {
  name         = "tf-3-aiops-idempotency-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.state.arn
  }
}

# ─────────────────────────────────────────────
# 4. GITHUB ACTIONS OIDC PROVIDER
# ─────────────────────────────────────────────

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
  ]
}

# ─────────────────────────────────────────────
# 4a. IAM Role: CI PLAN - Read-only
# ─────────────────────────────────────────────

resource "aws_iam_role" "github_actions_plan" {
  name        = "${var.name_prefix}-${var.environment}-github-ci-plan"
  description = "GitHub Actions OIDC role - plan/validate only - ${var.github_repo}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAnyRefPlan"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
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
}

resource "aws_iam_role_policy" "plan_tfstate_read" {
  name = "tfstate-read"
  role = aws_iam_role.github_actions_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3StateRead"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketVersioning",
          "s3:GetEncryptionConfiguration",
          "s3:GetBucketPolicy",
          "s3:GetBucketAcl",
          "s3:GetBucketCORS",
          "s3:GetBucketLocation",
          "s3:GetBucketLogging",
          "s3:GetBucketNotification",
          "s3:GetBucketObjectLockConfiguration",
          "s3:GetBucketRequestPayment",
          "s3:GetBucketTagging",
          "s3:GetBucketWebsite",
          "s3:GetLifecycleConfiguration",
          "s3:GetReplicationConfiguration",
          "s3:GetAccelerateConfiguration",
          "s3:GetBucketPublicAccessBlock"
        ]
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*"
        ]
      },
      {
        Sid    = "DynamoDBLockAcquireRelease"
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeTable",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeContinuousBackups",
          "dynamodb:DescribeTimeToLive",
          "dynamodb:ListTagsOfResource"
        ]
        Resource = aws_dynamodb_table.state_lock.arn
      },
      {
        Sid      = "KMSDecryptForRead"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListResourceTags"]
        Resource = aws_kms_key.state.arn
      },
      {
        Sid    = "ReadOnlyForTerraformPlan"
        Effect = "Allow"
        Action = [
          "iam:GetRole", "iam:GetRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviders",
          "kms:DescribeKey", "kms:ListAliases", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListResourceTags",
          "ec2:DescribeVpcs", "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups", "ec2:DescribeRouteTables",
          "ec2:DescribeVpcEndpoints",
          "dynamodb:DescribeTable", "dynamodb:ListTables", "dynamodb:DescribeContinuousBackups", "dynamodb:DescribeTimeToLive", "dynamodb:ListTagsOfResource",
          "eks:DescribeCluster", "eks:ListClusters",
          "ecr:DescribeRepositories"
        ]
        Resource = "*"
      }
    ]
  })
}

# ─────────────────────────────────────────────
# 4b. IAM Role: CI APPLY - Write ops
# ─────────────────────────────────────────────

resource "aws_iam_role" "github_actions_apply" {
  name        = "${var.name_prefix}-${var.environment}-github-ci-apply"
  description = "GitHub Actions OIDC role - apply/push - ${var.github_repo}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowMainBranchOnly"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main"
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "apply_tfstate_write" {
  name = "tfstate-write"
  role = aws_iam_role.github_actions_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3StateReadWrite"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
          "s3:ListBucket", "s3:GetBucketVersioning",
          "s3:GetEncryptionConfiguration", "s3:GetBucketPolicy",
          "s3:GetBucketAcl", "s3:GetBucketCORS",
          "s3:GetBucketLocation", "s3:GetBucketLogging",
          "s3:GetBucketNotification", "s3:GetBucketObjectLockConfiguration",
          "s3:GetBucketRequestPayment", "s3:GetBucketTagging",
          "s3:GetBucketWebsite", "s3:GetLifecycleConfiguration",
          "s3:GetReplicationConfiguration", "s3:GetAccelerateConfiguration",
          "s3:GetBucketPublicAccessBlock"
        ]
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*"
        ]
      },
      {
        Sid    = "DynamoDBStateLock"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem",
          "dynamodb:DeleteItem", "dynamodb:DescribeTable",
          "dynamodb:DescribeContinuousBackups", "dynamodb:DescribeTimeToLive",
          "dynamodb:ListTagsOfResource"
        ]
        Resource = aws_dynamodb_table.state_lock.arn
      },
      {
        Sid      = "KMSStateOps"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListResourceTags"]
        Resource = aws_kms_key.state.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "apply_ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.github_actions_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuthToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPushToOwnedRepos"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/tf-3-*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "apply_eks_describe" {
  name = "eks-describe"
  role = aws_iam_role.github_actions_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EKSDescribeCluster"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster", "eks:ListClusters"]
        Resource = "arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.name_prefix}-${var.environment}-*"
      }
    ]
  })
}
