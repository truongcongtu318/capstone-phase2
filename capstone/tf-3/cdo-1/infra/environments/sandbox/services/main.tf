# =============================================================================
# ROOT MODULE — sandbox/services (Phase 4: Services & Observability)
# Đọc remote state từ Phase 2 (Networking) và Phase 3 (Compute)
# Gọi module ingress (AWS LBC) và module observability (Prometheus Stack)
# =============================================================================

# -----------------------------------------------------------------------------
# REMOTE STATE — Phase 2: Networking & Security
# Lấy: vpc_id, private_subnet_ids, sg_alb_internal_id, kms keys, s3_audit_bucket_arn
# -----------------------------------------------------------------------------

data "terraform_remote_state" "networking" {
  backend = "s3"
  config = {
    bucket = var.tf_state_bucket
    key    = "sandbox/networking/terraform.tfstate"
    region = var.aws_region
  }
}

# -----------------------------------------------------------------------------
# MODULE: ingress — AWS Load Balancer Controller
# IRSA role, ServiceAccount, Helm release, IngressClass alb-internal
# -----------------------------------------------------------------------------

module "ingress" {
  source = "../../../modules/ingress"

  cluster_name       = data.terraform_remote_state.compute.outputs.cluster_name
  oidc_provider_arn  = data.terraform_remote_state.compute.outputs.oidc_provider_arn
  vpc_id             = data.terraform_remote_state.networking.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.networking.outputs.private_subnet_ids
  sg_alb_internal_id = data.terraform_remote_state.networking.outputs.sg_alb_internal_id
  global_tags        = var.global_tags
}

# -----------------------------------------------------------------------------
# MODULE: observability — Kube-Prometheus-Stack + Kinesis Firehose Audit
# Prometheus, Alertmanager, Grafana, KSM, NodeExporter (ECR Private images)
# Kinesis Firehose → S3 Audit Bucket (SOC2 Object Lock COMPLIANCE 90 days)
# IRSA role cho self-heal-executor (SQS Worker)
# -----------------------------------------------------------------------------

module "observability" {
  source = "../../../modules/observability"

  cluster_name          = data.terraform_remote_state.compute.outputs.cluster_name
  oidc_provider_arn     = data.terraform_remote_state.compute.outputs.oidc_provider_arn
  kms_observability_arn = data.terraform_remote_state.networking.outputs.kms_observability_arn
  kms_audit_arn         = data.terraform_remote_state.networking.outputs.kms_audit_arn
  s3_audit_bucket_arn   = data.terraform_remote_state.networking.outputs.s3_audit_bucket_arn
  name_prefix           = var.name_prefix
  environment           = var.environment
  global_tags           = var.global_tags
}
