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
# -----------------------------------------------------------------------------

data "terraform_remote_state" "networking" {
  backend = "s3"
  config = {
    bucket = var.tf_state_bucket
    key    = "sandbox/networking/terraform.tfstate"
    region = var.aws_region
  }
}

# Locals cho networking outputs
locals {
  vpc_id                = data.terraform_remote_state.networking.outputs.vpc_id
  private_subnet_ids    = data.terraform_remote_state.networking.outputs.private_subnet_ids
  sg_alb_internal_id    = data.terraform_remote_state.networking.outputs.sg_alb_internal_id
  kms_observability_arn = data.terraform_remote_state.networking.outputs.kms_observability_arn
  kms_audit_arn         = data.terraform_remote_state.networking.outputs.kms_audit_arn
}

# -----------------------------------------------------------------------------
# MODULE: ingress — AWS Load Balancer Controller
# -----------------------------------------------------------------------------

module "ingress" {
  source = "../../../modules/ingress"

  enabled            = true
  cluster_name       = local.cluster_name
  oidc_provider_arn  = local.oidc_provider_arn
  vpc_id             = local.vpc_id
  private_subnet_ids = local.private_subnet_ids
  sg_alb_internal_id = local.sg_alb_internal_id
  global_tags        = var.global_tags
}

# -----------------------------------------------------------------------------
# MODULE: observability — Kube-Prometheus-Stack + Kinesis Firehose Audit
# Fix #1: s3_audit_bucket_arn lấy từ data.aws_s3_bucket.audit.arn (Phase 1)
# -----------------------------------------------------------------------------

module "observability" {
  source = "../../../modules/observability"

  enabled               = true
  cluster_name          = local.cluster_name
  oidc_provider_arn     = local.oidc_provider_arn
  kms_observability_arn = local.kms_observability_arn
  kms_audit_arn         = local.kms_audit_arn
  s3_audit_bucket_arn   = data.aws_s3_bucket.audit.arn
  name_prefix           = var.name_prefix
  environment           = var.environment
  global_tags           = var.global_tags
}
