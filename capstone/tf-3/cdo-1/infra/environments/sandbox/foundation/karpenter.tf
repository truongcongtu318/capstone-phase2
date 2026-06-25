# INFRA-4 owner (cùng người làm eks.tf — 2 module gộp 1 ticket): chỉ sửa
# modules/karpenter/*.tf, KHÔNG cần sửa file này.
module "karpenter" {
  source = "../../../modules/karpenter"

  cluster_name       = module.eks.cluster_name
  oidc_provider_arn  = module.eks.oidc_provider_arn
  private_subnet_ids = module.networking.private_subnet_ids
  sg_eks_workload_id = module.security.sg_eks_workload_id
  tags               = local.common_tags
}
