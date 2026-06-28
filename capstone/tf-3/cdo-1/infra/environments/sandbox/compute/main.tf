locals {
  module_tags = merge(var.global_tags, {
    Environment = "sandbox"
    ManagedBy   = "terraform"
    Module      = "compute"
  })
}

data "terraform_remote_state" "networking" {
  backend = "s3"

  config = {
    bucket = "tf-3-aiops-audit-trail"
    key    = "sandbox/networking/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  vpc_id                  = data.terraform_remote_state.networking.outputs.vpc_id
  private_subnet_ids      = data.terraform_remote_state.networking.outputs.private_subnet_ids
  sg_eks_control_plane_id = data.terraform_remote_state.networking.outputs.sg_eks_control_plane_id
  sg_eks_workload_id      = data.terraform_remote_state.networking.outputs.sg_eks_workload_id
  sg_vpc_endpoint_id      = data.terraform_remote_state.networking.outputs.sg_vpc_endpoint_id
  kms_key_arn             = data.terraform_remote_state.networking.outputs.kms_infra_arn
}

module "eks" {
  source = "../../../modules/eks"

  vpc_id                  = local.vpc_id
  private_subnet_ids      = local.private_subnet_ids
  sg_eks_control_plane_id = local.sg_eks_control_plane_id
  sg_eks_workload_id      = local.sg_eks_workload_id
  sg_vpc_endpoint_id      = local.sg_vpc_endpoint_id
  kms_key_arn             = local.kms_key_arn
  cluster_name            = "${var.name_prefix}-eks"
  global_tags             = local.module_tags
}

module "karpenter" {
  source = "../../../modules/karpenter"

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider     = module.eks.oidc_provider
  name_prefix       = var.name_prefix
  global_tags       = local.module_tags
}
