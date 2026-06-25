# INFRA-2 owner: chỉ sửa modules/networking/*.tf, KHÔNG cần sửa file này.
module "networking" {
  source = "../../../modules/networking"

  tags = local.common_tags
}
