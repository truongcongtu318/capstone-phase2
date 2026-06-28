# KMS Customer Managed Keys (docs/03_security_design.md §4.1)

locals {
  kms_aliases = [
    "cdo-audit-kms",
    "cdo-app-data-kms",
    "cdo-secrets-kms",
    "cdo-infra-kms",
    "cdo-observability-kms"
  ]
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_kms_key" "keys" {
  for_each = toset(local.kms_aliases)

  description             = "KMS key managed by Terraform for ${each.key}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
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
  })

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
