# INFRA-2 owner: chỉ sửa modules/networking/*.tf, KHÔNG cần sửa file này.
module "networking" {
  source = "../../../modules/networking"

  sg_vpc_endpoint_id = module.security.sg_vpc_endpoint_id
  tags               = local.common_tags
}

