# =============================================================================
# PROVIDERS — sandbox/services (Phase 4)
# =============================================================================

provider "aws" {
  region = var.aws_region
}

data "terraform_remote_state" "compute" {
  backend = "s3"
  config = {
    bucket = var.tf_state_bucket
    key    = "sandbox/compute/terraform.tfstate"
    region = var.aws_region
  }
}

data "aws_eks_cluster_auth" "this" {
  name = data.terraform_remote_state.compute.outputs.cluster_name
}

locals {
  cluster_name      = data.terraform_remote_state.compute.outputs.cluster_name
  cluster_endpoint  = data.terraform_remote_state.compute.outputs.cluster_endpoint
  cluster_ca_data   = data.terraform_remote_state.compute.outputs.cluster_ca_data
  token             = data.aws_eks_cluster_auth.this.token
  oidc_provider_arn = data.terraform_remote_state.compute.outputs.oidc_provider_arn
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca_data)
  token                  = local.token
}

provider "helm" {
  kubernetes {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = base64decode(local.cluster_ca_data)
    token                  = local.token
  }
}
