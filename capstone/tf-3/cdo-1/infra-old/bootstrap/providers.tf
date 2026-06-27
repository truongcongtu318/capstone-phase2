provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.module_tags
  }
}
