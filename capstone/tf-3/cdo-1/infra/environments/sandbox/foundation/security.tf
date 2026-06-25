# INFRA-3 owner: chỉ sửa modules/security/*.tf, KHÔNG cần sửa file này.
module "security" {
  source = "../../../modules/security"

  vpc_id   = module.networking.vpc_id
  vpc_cidr = module.networking.vpc_cidr
  tags     = local.common_tags
}
