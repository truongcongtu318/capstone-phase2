# TODO(INFRA-1): implement theo docs/04_deployment_design.md §1.1 / §1.3.
#
# Resource cần có:
# - aws_s3_bucket (Terraform state) + aws_s3_bucket_versioning + SSE-KMS +
#   aws_s3_bucket_public_access_block (block public access)
# - aws_dynamodb_table (Terraform state lock — KHÔNG nhầm với bảng
#   `tf-3-aiops-idempotency-lock` của app, xem infra/CLAUDE.md mục 1)
# - aws_iam_openid_connect_provider cho GitHub Actions OIDC (var.github_repo)
# - aws_iam_role cho CI assume qua OIDC, least-privilege theo từng pipeline stage
#   (đúng docs/04_deployment_design.md §1.1 "CI authentication: GitHub Actions OIDC")

# Cost tracking: mọi resource hỗ trợ tag PHẢI dùng `tags = local.module_tags` (xem tags.tf).
