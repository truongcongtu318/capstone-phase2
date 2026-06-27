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

# 1. VPC
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.module_tags, {
    Name = "${var.name_prefix}-vpc"
  })
}

# 2. Private Subnets (NAT-less)
resource "aws_subnet" "private" {
  count                   = length(var.azs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.module_tags, {
    Name                                           = "${var.name_prefix}-subnet-private-${var.azs[count.index]}"
    "kubernetes.io/role/internal-elb"              = "1"
    "kubernetes.io/cluster/${var.name_prefix}-eks" = "shared"
    "karpenter.sh/discovery"                       = "${var.name_prefix}-eks"
  })
}

# 3. Public Subnets
resource "aws_subnet" "public" {
  count                   = length(var.azs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.module_tags, {
    Name                                           = "${var.name_prefix}-subnet-public-${var.azs[count.index]}"
    "kubernetes.io/role/elb"                       = "1"
    "kubernetes.io/cluster/${var.name_prefix}-eks" = "shared"
  })
}

# 4. Internet Gateway (Public routing only)
# resource "aws_internet_gateway" "this" {
#   vpc_id = aws_vpc.this.id

#   tags = merge(local.module_tags, {
#     Name = "${var.name_prefix}-igw"
#   })
# }

# 5. Route Tables & Associations
# resource "aws_route_table" "public" {
#   vpc_id = aws_vpc.this.id

#   route {
#     cidr_block = "0.0.0.0/0"
#     gateway_id = aws_internet_gateway.this.id
#   }

#   tags = merge(local.module_tags, {
#     Name = "${var.name_prefix}-rt-public"
#   })
# }

# resource "aws_route_table_association" "public" {
#   count          = length(var.azs)
#   subnet_id      = aws_subnet.public[count.index].id
#   route_table_id = aws_route_table.public.id
# }

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.module_tags, {
    Name = "${var.name_prefix}-rt-private"
  })
}

resource "aws_route_table_association" "private" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# 6. Gateway VPC Endpoints (S3, DynamoDB)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.module_tags, {
    Name = "${var.name_prefix}-vpce-s3"
  })
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.module_tags, {
    Name = "${var.name_prefix}-vpce-dynamodb"
  })
}

# 7. Interface VPC Endpoints (Internal communications)
resource "aws_vpc_endpoint" "interfaces" {
  for_each = local.interface_services

  vpc_id              = aws_vpc.this.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = var.sg_vpc_endpoint_id != null ? [var.sg_vpc_endpoint_id] : []
  private_dns_enabled = true

  tags = merge(local.module_tags, {
    Name = "${var.name_prefix}-vpce-${replace(each.key, "_", "-")}"
  })
}

