# TODO(INFRA-6): implement theo docs/02_infra_design.md §5.3 (Option B - FastAPI + ALB)
# và docs/03_security_design.md §1.1/§1.2 (Internal ALB only, không Public ALB).
#
# Resource cần có:
# - helm_release "aws-load-balancer-controller" (namespace kube-system, IRSA qua
#   var.oidc_provider_arn, clusterName = var.cluster_name)
# - Annotation chuẩn cho Service/Ingress loại ALB internal:
#   service.beta.kubernetes.io/aws-load-balancer-internal: "true"
#   service.beta.kubernetes.io/aws-load-balancer-security-groups: var.sg_alb_internal_id
# - Subnet cho ALB PHẢI là var.private_subnet_ids (internal-only, không public IP)

# Cost tracking: mọi resource hỗ trợ tag PHẢI dùng `tags = local.module_tags`
# (xem tags.tf) — không dùng var.tags trực tiếp, để Cost Explorer group theo Component.
