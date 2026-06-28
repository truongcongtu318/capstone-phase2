# =============================================================================
# PROVIDERS — sandbox/services (Phase 4)
# Giải pháp Chicken-and-Egg: đọc EKS endpoint/CA từ remote state Phase 3
# thay vì tham chiếu trực tiếp module.eks (chưa tồn tại trong state này)
# =============================================================================

provider "aws" {
  region = var.aws_region
}

# Đọc remote state Phase 3 (Compute) để lấy EKS connection info
# Phải chạy SAU KHI Phase 3 đã apply thành công lên AWS
data "terraform_remote_state" "compute" {
  backend = "s3"
  config = {
    bucket = var.tf_state_bucket
    key    = "sandbox/compute/terraform.tfstate"
    region = var.aws_region
  }
}

# Lấy token xác thực EKS qua AWS SDK (dùng OIDC credentials của CI pipeline)
# An toàn hơn exec{aws eks get-token} trong môi trường CI/CD
data "aws_eks_cluster_auth" "this" {
  name = data.terraform_remote_state.compute.outputs.cluster_name
}

# Kubernetes provider — kết nối cụm EKS qua remote state
provider "kubernetes" {
  host                   = data.terraform_remote_state.compute.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.compute.outputs.cluster_ca_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

# Helm provider — cùng credentials với kubernetes provider
provider "helm" {
  kubernetes {
    host                   = data.terraform_remote_state.compute.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.compute.outputs.cluster_ca_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
