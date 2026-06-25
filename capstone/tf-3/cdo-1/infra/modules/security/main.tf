# TODO(INFRA-3): implement theo docs/03_security_design.md §1.2 (Security Groups)
# và §4.1 (KMS key). Tên PHẢI đúng theo infra/CLAUDE.md mục 1 — không tự đặt tên khác.
#
# Security Group cần có:
# - sg-alb-internal       : inbound 443 từ Internal Alert Relay/VPN, outbound 8443 -> sg-eks-workload
# - sg-eks-workload       : inbound 8443 từ sg-alb-internal, outbound 443 VPC endpoint + 5432 sg-rds
# - sg-eks-control-plane  : inbound 443 từ node/admin role, outbound 10250 đến node
# - sg-rds                : inbound 5432 chỉ từ sg-eks-workload
# - sg-vpc-endpoint       : inbound 443 từ sg-eks-workload + sg-eks-control-plane
#
# KMS key (customer-managed, bật automatic rotation) cần có:
# - alias/cdo-audit-kms, alias/cdo-app-data-kms, alias/cdo-secrets-kms,
#   alias/cdo-infra-kms, alias/cdo-observability-kms

# Cost tracking: mọi resource hỗ trợ tag PHẢI dùng `tags = local.module_tags`
# (xem tags.tf) — không dùng var.tags trực tiếp, để Cost Explorer group theo Component.
