data "aws_region" "current" {}

locals {
  interface_services = {
    sqs              = "com.amazonaws.${data.aws_region.current.name}.sqs"
    kinesis_firehose = "com.amazonaws.${data.aws_region.current.name}.kinesis-firehose"
    secretsmanager   = "com.amazonaws.${data.aws_region.current.name}.secretsmanager"
    kms              = "com.amazonaws.${data.aws_region.current.name}.kms"
    logs             = "com.amazonaws.${data.aws_region.current.name}.logs"
    monitoring       = "com.amazonaws.${data.aws_region.current.name}.monitoring"
    ecr_api          = "com.amazonaws.${data.aws_region.current.name}.ecr.api"
    ecr_dkr          = "com.amazonaws.${data.aws_region.current.name}.ecr.dkr"
    sts              = "com.amazonaws.${data.aws_region.current.name}.sts"
    git_codecommit   = "com.amazonaws.${data.aws_region.current.name}.git-codecommit"
    codecommit       = "com.amazonaws.${data.aws_region.current.name}.codecommit"
    sns              = "com.amazonaws.${data.aws_region.current.name}.sns"
  }
}

# 1. Gateway VPC Endpoints (S3, DynamoDB)
resource "aws_vpc_endpoint" "s3" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.module_tags, {
    Name = "${var.name_prefix}-vpce-s3"
  })
}

resource "aws_vpc_endpoint" "dynamodb" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.module_tags, {
    Name = "${var.name_prefix}-vpce-dynamodb"
  })
}

# 2. Interface VPC Endpoints (Internal communications)
resource "aws_vpc_endpoint" "interfaces" {
  for_each = var.enable_vpc_endpoints ? local.interface_services : {}

  vpc_id              = aws_vpc.this.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [var.sg_vpc_endpoint_id]
  private_dns_enabled = true

  tags = merge(local.module_tags, {
    Name = "${var.name_prefix}-vpce-${replace(each.key, "_", "-")}"
  })
}
