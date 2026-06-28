# =============================================================================
# PROVIDERS — sandbox/services (Phase 4)
# Fix #4: Giải pháp Mock Compute để CI plan chạy trước khi Phase 3 apply
# use_mock_compute = true → dùng mock EKS info, bỏ qua K8s/Helm resources
# use_mock_compute = false → đọc remote state Phase 3, deploy thực
# =============================================================================

provider "aws" {
  region = var.aws_region
}

# Chỉ đọc remote state Phase 3 khi use_mock_compute = false
data "terraform_remote_state" "compute" {
  count = var.use_mock_compute ? 0 : 1

  backend = "s3"
  config = {
    bucket = var.tf_state_bucket
    key    = "sandbox/compute/terraform.tfstate"
    region = var.aws_region
  }
}

# Chỉ lấy EKS token khi use_mock_compute = false
data "aws_eks_cluster_auth" "this" {
  count = var.use_mock_compute ? 0 : 1
  name  = data.terraform_remote_state.compute[0].outputs.cluster_name
}

# Locals cung cấp mock fallback khi chưa có Phase 3 state
locals {
  cluster_name      = var.use_mock_compute ? "mock-eks" : data.terraform_remote_state.compute[0].outputs.cluster_name
  cluster_endpoint  = var.use_mock_compute ? "https://localhost" : data.terraform_remote_state.compute[0].outputs.cluster_endpoint
  cluster_ca_data   = var.use_mock_compute ? base64encode("mock-ca") : data.terraform_remote_state.compute[0].outputs.cluster_ca_data
  token             = var.use_mock_compute ? "mock-token" : data.aws_eks_cluster_auth.this[0].token
  oidc_provider_arn = var.use_mock_compute ? "arn:aws:iam::474013238625:oidc-provider/mock.eks.example.com" : data.terraform_remote_state.compute[0].outputs.oidc_provider_arn
}

# Kubernetes provider — dùng mock values khi use_mock_compute = true
# insecure = true khi mock mode: bỏ qua TLS validation vì mock CA không phải PEM hợp lệ
provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = var.use_mock_compute ? null : base64decode(local.cluster_ca_data)
  token                  = local.token
  insecure               = var.use_mock_compute
}

# Helm provider — cùng credentials với kubernetes provider
provider "helm" {
  kubernetes {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = var.use_mock_compute ? null : base64decode(local.cluster_ca_data)
    token                  = local.token
    insecure               = var.use_mock_compute
  }
}
