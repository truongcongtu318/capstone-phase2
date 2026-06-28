# =============================================================================
# ROOT MODULE — sandbox/services (Phase 4: Services & Observability)
# Fix #1: S3 Audit bucket đọc từ data.aws_s3_bucket (Phase 1) — không phải networking remote state
# Fix #4: Networking remote state dùng count, module calls truyền enabled flag
# =============================================================================

# Fix #1: S3 Audit bucket được tạo từ Phase 1 (bootstrap) — luôn available
# KHÔNG đọc từ networking remote state (Phase 2 không export biến này)
data "aws_s3_bucket" "audit" {
  bucket = "tf-3-aiops-audit-trail"
}

# -----------------------------------------------------------------------------
# REMOTE STATE — Phase 2: Networking & Security
# count = var.use_mock_compute ? 0 : 1: bỏ qua khi mock mode
# -----------------------------------------------------------------------------

data "terraform_remote_state" "networking" {
  count = var.use_mock_compute ? 0 : 1

  backend = "s3"
  config = {
    bucket = var.tf_state_bucket
    key    = "sandbox/networking/terraform.tfstate"
    region = var.aws_region
  }
}

# Locals cho networking outputs — mock fallback khi use_mock_compute = true
locals {
  vpc_id                = var.use_mock_compute ? "vpc-mock" : data.terraform_remote_state.networking[0].outputs.vpc_id
  private_subnet_ids    = var.use_mock_compute ? ["subnet-mock"] : data.terraform_remote_state.networking[0].outputs.private_subnet_ids
  sg_alb_internal_id    = var.use_mock_compute ? "sg-mock" : data.terraform_remote_state.networking[0].outputs.sg_alb_internal_id
  kms_observability_arn = var.use_mock_compute ? "arn:aws:kms:us-east-1:474013238625:key/mock-obs" : data.terraform_remote_state.networking[0].outputs.kms_observability_arn
  kms_audit_arn         = var.use_mock_compute ? "arn:aws:kms:us-east-1:474013238625:key/mock-audit" : data.terraform_remote_state.networking[0].outputs.kms_audit_arn
}

# -----------------------------------------------------------------------------
# MODULE: ingress — AWS Load Balancer Controller
# enabled = false khi mock mode → tất cả K8s/Helm/IAM resources bị skip (count=0)
# -----------------------------------------------------------------------------

module "ingress" {
  source = "../../../modules/ingress"

  enabled            = !var.use_mock_compute
  cluster_name       = local.cluster_name
  oidc_provider_arn  = local.oidc_provider_arn
  vpc_id             = local.vpc_id
  private_subnet_ids = local.private_subnet_ids
  sg_alb_internal_id = local.sg_alb_internal_id
  global_tags        = var.global_tags
}

# -----------------------------------------------------------------------------
# MODULE: observability — Kube-Prometheus-Stack + Kinesis Firehose Audit
# enabled = false khi mock mode → K8s/Helm resources bị skip, AWS resources vẫn plan
# Fix #1: s3_audit_bucket_arn lấy từ data.aws_s3_bucket.audit.arn (Phase 1)
# -----------------------------------------------------------------------------

module "observability" {
  source = "../../../modules/observability"

  enabled               = !var.use_mock_compute
  cluster_name          = local.cluster_name
  oidc_provider_arn     = local.oidc_provider_arn
  kms_observability_arn = local.kms_observability_arn
  kms_audit_arn         = local.kms_audit_arn
  s3_audit_bucket_arn   = data.aws_s3_bucket.audit.arn
  name_prefix           = var.name_prefix
  environment           = var.environment
  global_tags           = var.global_tags
}
