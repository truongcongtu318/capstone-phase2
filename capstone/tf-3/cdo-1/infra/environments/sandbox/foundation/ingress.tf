# INFRA-5 owner: chỉ sửa modules/ingress/*.tf, KHÔNG cần sửa file này.
module "ingress" {
  source = "../../../modules/ingress"

  cluster_name       = module.eks.cluster_name
  cluster_endpoint   = module.eks.cluster_endpoint
  oidc_provider_arn  = module.eks.oidc_provider_arn
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  sg_alb_internal_id = module.security.sg_alb_internal_id
  tags               = local.common_tags
}
