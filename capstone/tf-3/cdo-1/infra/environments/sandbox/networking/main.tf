module "networking" {
  source = "../../../modules/networking"

  name_prefix          = var.name_prefix
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  private_subnet_cidrs = var.private_subnet_cidrs
  public_subnet_cidrs  = var.public_subnet_cidrs
  github_repo          = var.github_repo
  create_vpc_endpoints = false
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

data "aws_region" "current" {}

data "aws_route_table" "private" {
  vpc_id = module.networking.vpc_id

  filter {
    name   = "tag:Name"
    values = ["${var.name_prefix}-rt-private"]
  }
}

locals {
  interface_endpoint_services = {
    sqs              = "com.amazonaws.${data.aws_region.current.name}.sqs"
    kinesis_firehose = "com.amazonaws.${data.aws_region.current.name}.kinesis-firehose"
    secretsmanager   = "com.amazonaws.${data.aws_region.current.name}.secretsmanager"
    kms              = "com.amazonaws.${data.aws_region.current.name}.kms"
    logs             = "com.amazonaws.${data.aws_region.current.name}.logs"
    monitoring       = "com.amazonaws.${data.aws_region.current.name}.monitoring"
    ecr_api          = "com.amazonaws.${data.aws_region.current.name}.ecr.api"
    ecr_dkr          = "com.amazonaws.${data.aws_region.current.name}.ecr.dkr"
    sts              = "com.amazonaws.${data.aws_region.current.name}.sts"
    sns              = "com.amazonaws.${data.aws_region.current.name}.sns"
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.networking.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_route_table.private.id]

  tags = merge(local.module_tags, {
    Name = "${var.name_prefix}-vpce-s3"
  })
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = module.networking.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_route_table.private.id]

  tags = merge(local.module_tags, {
    Name = "${var.name_prefix}-vpce-dynamodb"
  })
}

resource "aws_vpc_endpoint" "interfaces" {
  for_each = local.interface_endpoint_services

  vpc_id              = module.networking.vpc_id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.networking.private_subnet_ids
  security_group_ids  = [module.security.sg_vpc_endpoint_id]
  private_dns_enabled = true

  tags = merge(local.module_tags, {
    Name = "${var.name_prefix}-vpce-${replace(each.key, "_", "-")}"
  })
}
