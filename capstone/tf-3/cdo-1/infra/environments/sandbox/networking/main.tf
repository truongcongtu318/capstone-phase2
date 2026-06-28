module "networking" {
  source = "../../../modules/networking"

  name_prefix          = var.name_prefix
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  private_subnet_cidrs = var.private_subnet_cidrs
  public_subnet_cidrs  = var.public_subnet_cidrs
  sg_vpc_endpoint_id   = module.security.sg_vpc_endpoint_id
  enable_vpc_endpoints = true
  tags                 = var.tags
}

module "security" {
  source = "../../../modules/security"

  name_prefix = var.name_prefix
  environment = var.environment
  vpc_id      = module.networking.vpc_id
  vpc_cidr    = module.networking.vpc_cidr
  tags        = var.tags
}
