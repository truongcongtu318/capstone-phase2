provider "aws" {
  region = var.aws_region
}

# kubernetes/helm provider phụ thuộc module.eks đã apply xong (chicken-and-egg
# kinh điển: cluster vừa là resource vừa là provider target). Lần apply đầu tiên
# cần `terraform apply -target=module.eks` trước, sau đó apply phần còn lại.

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}
