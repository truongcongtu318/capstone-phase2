# INFRA-6 owner: chỉ sửa modules/observability/*.tf, KHÔNG cần sửa file này.
module "observability" {
  source = "../../../modules/observability"

  cluster_name          = module.eks.cluster_name
  cluster_endpoint      = module.eks.cluster_endpoint
  oidc_provider_arn     = module.eks.oidc_provider_arn
  kms_observability_arn = module.security.kms_observability_arn
  tags                  = local.common_tags
}
