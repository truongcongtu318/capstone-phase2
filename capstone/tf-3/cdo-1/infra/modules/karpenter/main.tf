# TODO(INFRA-5): implement theo docs/02_infra_design.md §5.1 và §6 (Scaling strategy).
#
# Resource cần có:
# - IAM role cho Karpenter controller (IRSA, dùng var.oidc_provider_arn) + node
#   instance profile cho EC2NodeClass
# - helm_release "karpenter" (namespace kube-system, version_arn = var.cluster_name)
# - kubernetes_manifest / kubectl_manifest cho NodePool + EC2NodeClass:
#   instance_types = var.instance_types, subnet = var.private_subnet_ids,
#   security_group = var.sg_eks_workload_id, limits.cpu theo var.max_nodes
# - Dùng Spot instance theo docs/02_infra_design.md §5.1 Option C reasoning;
#   baseline platform pods (ArgoCD, Webhook) PHẢI pin vào NodePool On-Demand riêng
#   (xem docs/02_infra_design.md §3.3 Trade-off 2)

# Cost tracking: mọi resource hỗ trợ tag PHẢI dùng `tags = local.module_tags`
# (xem tags.tf) — không dùng var.tags trực tiếp, để Cost Explorer group theo Component.
