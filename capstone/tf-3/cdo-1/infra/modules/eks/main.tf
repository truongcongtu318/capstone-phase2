# TODO(INFRA-4): implement theo docs/02_infra_design.md §2 + §5.1 (Option C: EKS + Karpenter)
# và docs/03_security_design.md §2.1/§2.2 (IRSA, RBAC least-privilege).
#
# Resource cần có:
# - aws_eks_cluster (version = var.cluster_version, subnet = var.private_subnet_ids,
#   security_group = var.sg_eks_control_plane_id, encryption_config dùng var.kms_infra_arn)
# - aws_eks_node_group nhỏ on-demand (chỉ cho system pods: CoreDNS, kube-proxy, ADOT,
#   Karpenter controller) — Karpenter quản lý phần node còn lại (xem modules/karpenter)
# - aws_iam_openid_connect_provider (IRSA) — output oidc_provider_arn cho
#   karpenter/ingress/observability dùng
# - K8s namespace `self-heal-system` (tạo ở đây hoặc GitOps layer — quyết định ghi
#   vào docs/08_adrs.md, không tự quyết một mình)
#
# Sandbox = 1 node group nhỏ on-demand làm baseline platform (theo docs/02_infra_design.md
# §3.3 Trade-off 2), không phải production sizing.

# Cost tracking: mọi resource hỗ trợ tag PHẢI dùng `tags = local.module_tags`
# (xem tags.tf) — không dùng var.tags trực tiếp, để Cost Explorer group theo Component.
