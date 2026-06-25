# Infra Rules — tf-3 / cdo-1 (Base Infra Pack #1)

Đọc file này trước khi code bất kỳ module nào trong `infra/`. Mục tiêu: 8 người
(+ AI assistant của mỗi người) code song song mà gộp lại không vỡ, không lệch tên.

## 1. Không tự đặt tên — copy nguyên văn từ docs đã chốt

Tránh lặp lại lỗi mismatch contract-vs-docs đã từng xảy ra giữa AI team và CDO team.
Mọi resource name/alias PHẢI lấy nguyên văn từ các file dưới, không tự nghĩ tên mới:

| Resource | Tên bắt buộc | Nguồn |
|---|---|---|
| K8s namespace AI Engine | `self-heal-system` | `docs/04_deployment_design.md` |
| DynamoDB idempotency lock (app) | `tf-3-aiops-idempotency-lock` | `contracts/deployment-contract.md` §3.C |
| S3 audit bucket | `tf-3-aiops-audit-trail` | **Chốt theo `contracts/deployment-contract.md` §3.C**, không dùng `cdo-audit-bucket` ở `docs/03_security_design.md` — AI Engine's IAM policy hardcode đúng ARN này (xem `lab-w11/.../demo/terraform/iam.tf`), đặt tên khác = AccessDenied khi AI Engine chạy thật. Cần sync lại `03_security_design.md` cho khớp. |
| KMS alias | `alias/cdo-audit-kms`, `alias/cdo-app-data-kms`, `alias/cdo-secrets-kms`, `alias/cdo-infra-kms`, `alias/cdo-observability-kms` | `docs/03_security_design.md` §4.1 |
| Security Group | `sg-alb-internal`, `sg-eks-workload`, `sg-eks-control-plane`, `sg-rds`, `sg-vpc-endpoint` | `docs/03_security_design.md` §1.2 |
| Tenant namespace | `tenant-payment`, `tenant-checkout` | `docs/02_infra_design.md` §4.1 |
| Tenant ID (UUID v4) | `d3b07384-d113-495f-9f58-20d18d357d75` (payment), `6c8b4b2b-4d45-4209-a1b4-4b532d56a31c` (checkout) | `docs/02_infra_design.md` §4.1 |

Cần resource mới chưa có trong docs? Thêm vào doc tương ứng trong cùng PR — không
âm thầm đặt tên riêng rồi để docs/infra lệch nhau.

## 2. Module contract — KHÔNG tự đổi tên output

Output mỗi module đã chốt cứng và đã được wire sẵn trong
`environments/sandbox/foundation/*.tf`. Đổi tên output = breaking change cho người
khác, phải báo trong standup trước khi đổi.

- `networking` → `vpc_id`, `vpc_cidr`, `private_subnet_ids`, `public_subnet_ids`
- `security` → `sg_eks_workload_id`, `sg_eks_control_plane_id`, `sg_alb_internal_id`, `sg_rds_id`, `sg_vpc_endpoint_id`, `kms_infra_arn`, `kms_observability_arn`
- `eks` → `cluster_name`, `cluster_endpoint`, `cluster_ca_data`, `oidc_provider_arn`
- `karpenter` → `node_iam_role_arn`
- `ingress` → `alb_dns_name`
- `observability` → `grafana_service_name`

## 3. File layout cố định mỗi module

```
modules/<name>/
├── versions.tf   # required_providers + required_version — pin giống nhau toàn repo
├── variables.tf  # input — mọi var phải có description + type
├── main.tf       # resource thật — code vào đây, theo đúng TODO trong file
└── outputs.tf    # output đúng theo mục 2, value tạm null cho tới khi implement
```

Không thêm resource trực tiếp ở `environments/` — mọi resource đi qua module.
File trong `environments/sandbox/foundation/` đã tách theo từng module
(`networking.tf`, `eks.tf`...) — chỉ sửa file đúng module bạn được giao.

## 4. Naming & tagging convention

- Resource name pattern: `tf3-cdo1-sandbox-<component>` (vd `tf3-cdo1-sandbox-vpc`).
- Tag bắt buộc trên mọi resource hỗ trợ tag — lấy từ `local.common_tags` ở
  `environments/sandbox/foundation/variables.tf`, truyền qua `var.tags`. Không
  hardcode tag riêng trong module.
- **Cost Explorer**: mỗi module có sẵn `tags.tf` merge thêm `Component = "<module>"`
  vào `var.tags` → dùng `tags = local.module_tags` (không phải `var.tags`) trên
  MỌI resource hỗ trợ tag. Thiếu bước này = Cost Explorer không group được chi
  phí theo service.
- Tag key (`Project`, `TaskForce`, `Team`, `Env`, `Component`) phải được "Activate"
  ở Billing/Cost Explorer mới filter được — đã có sẵn
  `environments/sandbox/foundation/cost-allocation-tags.tf` (ticket INFRA-7), chỉ
  apply được SAU KHI các resource khác đã mang tag thật (đọc comment trong file đó).

## 5. Provider version — pin giống nhau toàn bộ repo

```hcl
terraform {
  required_version = ">= 1.7.0"
}

required_providers {
  aws        = { source = "hashicorp/aws", version = "~> 5.60" }
  kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
  helm       = { source = "hashicorp/helm", version = "~> 2.14" }
}
```

Copy đúng block vào `versions.tf` của module bạn — không tự nâng/hạ version.

## 6. Quy tắc cho AI / "vibe code"

Khi prompt AI để sinh resource cho module của bạn:

1. Dán kèm đúng section liên quan trong `docs/02_infra_design.md` /
   `docs/03_security_design.md` / `docs/04_deployment_design.md` — không để AI tự
   suy ra kiến trúc từ training data.
2. Luôn nói rõ: "dùng đúng input/output variable đã khai báo sẵn trong
   `variables.tf`/`outputs.tf` của module này, không đổi tên, không thêm field
   ngoài interface đã chốt ở mục 2."
3. Không cho AI tự chọn region/account id/CIDR/instance type — luôn lấy qua
   `var.*`, không hardcode literal trong `main.tf`.
4. Chạy `terraform fmt -recursive && terraform validate` trước khi commit.

## 7. Quy tắc PR / state

- Branch: `infra/<TICKET-ID>-<module-name>` (vd `infra/infra-4-eks`).
- KHÔNG `terraform apply` từ máy cá nhân vào state chung
  (`environments/sandbox/foundation`) — chỉ apply qua CI sau merge, tránh state
  lock đụng nhau giữa 8 người.
- Test module riêng lẻ: viết `*.tfvars` test cục bộ trong chính folder module,
  chạy `terraform plan`, KHÔNG commit file `*.tfvars` có giá trị thật.
- PR phải pass `terraform fmt -check`, `terraform validate`, `tfsec`/`checkov`
  trước khi merge (đúng pipeline ở `docs/04_deployment_design.md` §2.1).
