# Phase 3 Compute (EKS + Karpenter) — Implementation Plan
Date: 2026-06-28
Author: Tech Lead (anh Tú) + DevOps Agent

---

## Constraints (từ README.md + TUTORIAL_GITFLOW.md)

| Hạng mục | Giá trị bắt buộc |
|---|---|
| EKS version | `1.28` |
| Node Group chạy ở | Private Subnets (NAT-less) |
| AWS Resource Naming | `tf3-cdo1-sandbox-<component>` (kebab-case) |
| HCL Local Name | `snake_case`, không lặp loại resource |
| Tags | `local.module_tags` merge từ `var.global_tags` |
| Remote state đọc từ | `sandbox/networking/terraform.tfstate` trên S3 `tf-3-aiops-audit-trail` |
| Module outputs EKS | `cluster_name`, `cluster_endpoint`, `cluster_ca_data`, `oidc_provider_arn` |
| Module output Karpenter | `node_iam_role_arn` |
| Terraform version | `>= 1.7.0` |
| AWS Provider | `~> 5.60` |
| S3 State bucket | `tf-3-aiops-audit-trail` |
| DynamoDB Lock | `tf-3-aiops-idempotency-lock` |
| State key compute | `sandbox/compute/terraform.tfstate` |

## Mock Network Strategy (Phase 2 chưa deploy)

Dùng biến `use_mock_network = true` (default) để bypass `data.terraform_remote_state.networking`.
Khi Phase 2 deploy xong, đặt `use_mock_network = false` trong `terraform.tfvars`.

Chỉ Terraform plan/validate chạy khi mock. Không apply thật với mock values.

---

## File Layout

### modules/eks/
- `variables.tf` — inputs: vpc_id, private_subnet_ids, sg_eks_control_plane_id, sg_eks_workload_id, kms_key_arn, cluster_name, eks_version, global_tags
- `iam.tf` — Cluster Role + Node Role + policies
- `main.tf` — aws_eks_cluster, aws_eks_node_group, OIDC provider, addons
- `outputs.tf` — cluster_name, cluster_endpoint, cluster_ca_data, oidc_provider_arn, oidc_provider

### modules/karpenter/
- `variables.tf` — cluster_name, oidc_provider_arn, oidc_provider, node_role_name, global_tags
- `main.tf` — Controller Role (IRSA) + Node Role + Instance Profile
- `outputs.tf` — node_iam_role_arn, controller_role_arn

### environments/sandbox/compute/
- `versions.tf` — terraform >= 1.7.0, aws ~> 5.60
- `providers.tf` — aws provider + default_tags
- `variables.tf` — use_mock_network (bool, default=true), aws_region, name_prefix, environment, global_tags
- `main.tf` — remote_state data source + locals mock switch + module eks + module karpenter
- `outputs.tf` — re-export EKS + karpenter outputs
- `backend.tf` — (đã có sẵn)

---

## Resource Names (strict)

| Resource | AWS Name |
|---|---|
| EKS Cluster | `tf3-cdo1-sandbox-eks` |
| EKS Node Group | `tf3-cdo1-sandbox-eks-nodes` |
| EKS Cluster IAM Role | `tf3-cdo1-sandbox-eks-cluster-role` |
| EKS Node IAM Role | `tf3-cdo1-sandbox-eks-node-role` |
| Karpenter Controller Role | `tf3-cdo1-sandbox-karpenter-controller-role` |
| Karpenter Node Role | `tf3-cdo1-sandbox-karpenter-node-role` |
| Karpenter Instance Profile | `tf3-cdo1-sandbox-karpenter-node-profile` |

---

## Task Breakdown

### Task A — modules/eks/ (iam.tf + variables.tf + outputs.tf + main.tf)
### Task B — modules/karpenter/ (variables.tf + main.tf + outputs.tf)
### Task C — environments/sandbox/compute/ (versions.tf + providers.tf + variables.tf + main.tf + outputs.tf)
