provider "aws" {
  region = var.aws_region
}

# kubernetes/helm/kubectl provider phụ thuộc module.eks đã apply xong (chicken-and-egg
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
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

# kubectl provider — used by modules/karpenter for NodePool + EC2NodeClass CRDs
# (gavinbunney/kubectl handles unknown CRD schemas that hashicorp/kubernetes rejects)
provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "tls" {}
