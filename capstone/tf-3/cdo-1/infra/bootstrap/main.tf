# INFRA-1: Bootstrap — State Backend + GitHub Actions OIDC
# Theo docs/04_deployment_design.md §1.1 và §1.3
# Không phụ thuộc module nào khác — apply đầu tiên bằng local backend.
#
# SAU KHI apply xong, copy output vào environments/sandbox/foundation/backend.tf

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ─────────────────────────────────────────────
# 1. KMS KEY — mã hóa Terraform state bucket
#    Riêng biệt với 5 KMS key của app (security module)
# ─────────────────────────────────────────────

resource "aws_kms_key" "state" {
  description             = "KMS key for Terraform state bucket — ${var.name_prefix}-${var.environment}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  # KMS key policy: root account có full access để delegate xuống IAM.
  # Quyền cụ thể (GenerateDataKey, Decrypt) cho GitHub Actions role
  # được delegate qua IAM identity-based policy (aws_iam_role_policy.*).
  # Không reference ARN của role ở đây để tránh circular dependency
  # (KMS key được tạo trước role).
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
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
# 2. S3 BUCKET — Terraform state storage
#    Naming: tf3-cdo1-<env>-tfstate-<account_id>
#    Theo CLAUDE.md §4: tf3-cdo1-sandbox-<component>
# ─────────────────────────────────────────────

resource "aws_s3_bucket" "state" {
  # Tên bucket phải globally unique — thêm account id để tránh conflict
  bucket = "${var.name_prefix}-${var.environment}-tfstate-${data.aws_caller_identity.current.account_id}"

  # Bảo vệ khỏi xóa nhầm (state bucket là critical)
  lifecycle {
    prevent_destroy = true
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
    bucket_key_enabled = true # giảm chi phí KMS API call
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# DenyInsecureTransport — theo docs/03_security_design.md §4.2
resource "aws_s3_bucket_policy" "state_deny_http" {
  bucket = aws_s3_bucket.state.id

  # aws_s3_bucket_public_access_block phải được tạo trước khi gắn policy
  depends_on = [aws_s3_bucket_public_access_block.state]

  # Bucket policy chỉ chứa DenyInsecureTransport.
  # Quyền S3 cho GitHub Actions được cấp qua IAM identity-based policy
  # (aws_iam_role_policy.*) — không cần Allow ở đây.
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
# 3. DYNAMODB TABLE — Terraform state lock
#    KHÔNG nhầm với tf-3-aiops-idempotency-lock (app)
#    Theo CLAUDE.md §1: bảng app lock đặt tên riêng
# ─────────────────────────────────────────────

resource "aws_dynamodb_table" "state_lock" {
  name         = "${var.name_prefix}-${var.environment}-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID" # Terraform yêu cầu đúng tên này

  attribute {
    name = "LockID"
    type = "S"
  }

  # Mã hóa bằng KMS state key — theo docs/03_security_design.md §4.1
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.state.arn
  }
}

# ─────────────────────────────────────────────
# 4. GITHUB ACTIONS OIDC PROVIDER
#    Theo docs/04_deployment_design.md §1.1 + §6
# ─────────────────────────────────────────────

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # Thumbprint của GitHub Actions OIDC certificate (cố định, GitHub quản lý)
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
  ]
}

# ─────────────────────────────────────────────
# 4a. IAM Role: CI PLAN — Read-only, trust mọi ref
#     Dùng cho: Lint / Test / Scan / Plan (docs §2.1)
#     Bất kỳ branch/tag/PR nào trong repo đều có thể assume role này
#     vì chỉ có quyền đọc — không thể thay đổi state hay push image.
# ─────────────────────────────────────────────

resource "aws_iam_role" "github_actions_plan" {
  name        = "${var.name_prefix}-${var.environment}-github-ci-plan"
  description = "GitHub Actions OIDC role — plan/validate only, any ref — ${var.github_repo}"

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
          # Cho phép mọi branch/tag/PR — role này chỉ có quyền đọc
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

# Plan role: đọc state (GetObject/ListBucket) + describe AWS resource cho plan
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
          "s3:GetEncryptionConfiguration"
        ]
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*"
        ]
      },
      {
        # terraform plan cũng acquire + release state lock theo mặc định của S3 backend:
        #   PutItem   → ghi lock record (acquire)
        #   GetItem   → đọc lock record (check existing lock)
        #   DeleteItem → xóa lock record (release sau khi plan xong)
        # Thiếu PutItem/DeleteItem → AccessDeniedException ngay lúc acquire lock.
        # KHÔNG dùng -lock=false vì CI có thể chạy concurrent → race condition trên state.
        Sid    = "DynamoDBLockAcquireRelease"
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeTable",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem"
        ]
        Resource = aws_dynamodb_table.state_lock.arn
      },
      {
        Sid      = "KMSDecryptForRead"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"]
        Resource = aws_kms_key.state.arn
      },
      {
        Sid    = "ReadOnlyForTerraformPlan"
        Effect = "Allow"
        Action = [
          "iam:GetRole", "iam:GetRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviders",
          "kms:DescribeKey", "kms:ListAliases",
          "ec2:DescribeVpcs", "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups", "ec2:DescribeRouteTables",
          "ec2:DescribeVpcEndpoints",
          "dynamodb:DescribeTable", "dynamodb:ListTables",
          "eks:DescribeCluster", "eks:ListClusters",
          "ecr:DescribeRepositories"
        ]
        Resource = "*"
      }
    ]
  })
}

# ─────────────────────────────────────────────
# 4b. IAM Role: CI APPLY — Write ops, chỉ trust main branch
#     Dùng cho: Terraform Apply + ECR Push + Smoke test (docs §2.1)
#     CHỈ main branch được assume role này —
#     PR từ fork hoặc feature branch KHÔNG thể mutate state hay push image.
# ─────────────────────────────────────────────

resource "aws_iam_role" "github_actions_apply" {
  name        = "${var.name_prefix}-${var.environment}-github-ci-apply"
  description = "GitHub Actions OIDC role — apply/push, main branch only — ${var.github_repo}"

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
          # Giới hạn chặt: CHỈ merge vào main branch mới được apply/push
          StringEquals = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main"
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Apply role: đọc + ghi state (PutObject/DeleteObject + DynamoDB lock)
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
          "s3:GetEncryptionConfiguration"
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
          "dynamodb:DeleteItem", "dynamodb:DescribeTable"
        ]
        Resource = aws_dynamodb_table.state_lock.arn
      },
      {
        Sid      = "KMSStateOps"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
        Resource = aws_kms_key.state.arn
      }
    ]
  })
}

# Apply role: ECR push — Stage "Publish" (docs §2.1)
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
        Resource = "*" # GetAuthorizationToken không hỗ trợ resource-level permission
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
        # Scope chỉ repo tf-3-* prefix trong account này
        Resource = "arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/tf-3-*"
      }
    ]
  })
}

# Apply role: EKS describe — Terraform provider config + smoke test
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
