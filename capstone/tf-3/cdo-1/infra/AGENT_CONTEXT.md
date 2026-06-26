# Agent Context — CDO-01 Base Infra Pack #1

Đọc file này khi bắt đầu session mới. Nó tóm tắt trạng thái hiện tại của toàn bộ
infrastructure, các vấn đề đã phát hiện qua review, và những gì cần làm tiếp.

---

## 1. Tổng quan dự án

**Capstone Phase 2 — Self-Healing Platform**
- Team CDO-01 xây base infra trên AWS/EKS cho hệ thống tự phục hồi.
- AI Engine (do AI team cung cấp image) chạy trong EKS, nhận lệnh từ CDO Self-Heal Controller.
- Repo: `truongcongtu318/capstone-phase2`, nhánh chính: `main`, nhánh làm việc: `tan-1`.
- Tất cả infra code nằm trong: `capstone/tf-3/cdo-1/infra/`

**Tài liệu thiết kế quan trọng:**
| File | Nội dung |
|---|---|
| `docs/02_infra_design.md` | Kiến trúc tổng thể, VPC design, subnet, EKS config |
| `docs/03_security_design.md` | Security Groups (§1.2), KMS (§4.1), IAM (§2), trust model |
| `docs/04_deployment_design.md` | Thứ tự deploy, module layout, CI/CD pipeline |
| `contracts/ai-api-contract.md` | API contract giữa CDO và AI Engine (ĐÃ THAY ĐỔI — xem §3) |
| `contracts/telemetry-contract.md` | Contract telemetry (ĐÃ THAY ĐỔI — xem §3) |
| `contracts/deployment-contract.md` | NetworkPolicy spec §5.A/§5.B cho AI Engine |
| `infra/CLAUDE.md` | **Rules bắt buộc cho toàn bộ module** — đọc trước khi code bất cứ gì |

---

## 2. Cấu trúc module và ticket phân công

```
bootstrap/                  → INFRA-1 (state backend, OIDC, CI IAM roles)
modules/networking/         → INFRA-2 (VPC, subnet, VPC endpoint)
modules/security/           → INFRA-3 (Security Groups, KMS CMKs)
modules/eks/                → INFRA-4 (EKS cluster)
modules/karpenter/          → INFRA-4 (Karpenter, gộp với EKS vì dependency chặt)
modules/ingress/            → INFRA-5 (AWS Load Balancer Controller)
modules/observability/      → INFRA-6 (kube-prometheus-stack, CloudWatch)
*/tags.tf                   → INFRA-7 (Cost allocation tagging)
manifests/ai-engine/        → INFRA-8 (NetworkPolicy AI Engine)
```

Thứ tự apply:
```
bootstrap → networking + security (song song) → eks → karpenter + ingress + observability (song song)
```
Lần apply đầu: `terraform apply -target=module.eks` trước (EKS vừa là resource vừa là
provider target cho kubernetes/helm), rồi apply phần còn lại.

Wiring đã có sẵn tại: `environments/sandbox/foundation/*.tf` — không sửa file này.

---

## 3. THAY ĐỔI CONTRACT QUAN TRỌNG (ảnh hưởng đến security model)

AI team đã thay đổi 2 contract, không còn lớp bảo vệ tầng app:

| Contract | Thay đổi | Tác động |
|---|---|---|
| `ai-api-contract.md` | Bỏ `Authorization: AWS Signature Version 4` header ở 3 endpoints (`/v1/detect`, `/v1/decide`, `/v1/verify`) | Không còn auth tầng app |
| `telemetry-contract.md` | Đổi kênh từ HTTPS → HTTP nội bộ thuần ("giao thức HTTP nội bộ") | Không còn TLS |

**Hệ quả:** Trust model chuyển sang "Local Trust" — bảo vệ duy nhất là **K8s NetworkPolicy**.
Đây là lý do INFRA-8 tồn tại và là blocking requirement trước khi merge code AI Engine vào cluster.

File đã cập nhật để phản ánh thay đổi này:
- `manifests/ai-engine/service.yaml` — comment đã sửa, ghi đúng trust model mới
- `manifests/ai-engine/networkpolicy.yaml` — mới tạo (xem §5)

---

## 4. Trạng thái PR hiện tại (tính đến session này)

### PR #45 — `bootstrap/main.tf` (INFRA-1) — đã merge
- **Vấn đề đã review:** CI plan role (`tfstate-read`) thiếu `dynamodb:PutItem` và
  `dynamodb:DeleteItem` → `terraform plan` bị lỗi `AccessDeniedException` khi acquire
  state lock (mặc định Terraform lock trước khi plan). Apply role có đủ quyền.
- **Fix cần làm:** Thêm 2 action đó vào policy plan role, hoặc document rõ phải
  chạy `terraform plan -lock=false`.
- **File:** `bootstrap/main.tf` line ~221-223

### PR #46 — `modules/security/main.tf` (INFRA-3) — OPEN, head `709e009`
**Author:** truongcongtu318 | **Branch:** `infra/infra-3-security`

Implement 5 Security Groups + standalone SG rules + 5 KMS CMKs via `for_each`.

**Vấn đề tìm được qua review:**

1. **[HIGH — CONFIRMED]** `aws_kms_key.keys` không có `policy` argument.
   CloudWatch Logs yêu cầu explicit key policy grant cho service principal
   `logs.<region>.amazonaws.com`. Không thể grant qua IAM identity policy.
   Khi observability module (PR #47) apply `aws_cloudwatch_log_group` với
   `kms_key_id = kms_observability_arn`, sẽ fail với
   `InvalidParameterException: The specified KMS key cannot be accessed`.
   **Fix:** Thêm `policy` hoặc `aws_kms_key_policy` resource cho `cdo-observability-kms`
   với statement grant `logs.*.amazonaws.com` đủ 5 actions.

2. **[MEDIUM — PLAUSIBLE]** `sg-eks-workload` không có ingress rule port 10250 từ
   `sg-eks-control-plane`. Code có `control_plane_egress_to_workload` (egress 10250
   control-plane → workload) nhưng thiếu chiều ngược lại (ingress 10250 trên workload
   từ control-plane). Trong EKS tiêu chuẩn, EKS-managed cluster SG bù được gap này,
   nhưng nếu worker node không attach cluster SG thì kubelet (`kubectl logs`, `exec`,
   health probe) sẽ fail.
   **Fix:** Thêm `aws_security_group_rule "workload_ingress_from_control_plane"` port 10250,
   hoặc comment rõ "cluster SG handles this".

3. **[MEDIUM]** `aws_security_group.alb_internal` ingress mở 443 cho toàn bộ
   `var.vpc_cidr` thay vì scoped SG của Alert Relay/VPN. Design §1.2: "SG của Internal
   Alert Relay hoặc VPN/Internal Client CIDR". PR có TODO comment nhận biết vấn đề này.
   File: `main.tf:18`.

### PR #47 — `modules/ingress/` + `modules/observability/` (INFRA-5 + INFRA-6) — OPEN
**Author:** ngochieu45 | **Branch:** `hieu`

**Vấn đề tìm được:**

1. **[HIGH — CONFIRMED]** CloudWatch log group (`/aws/eks/${cluster_name}/cluster`)
   dùng `kms_key_id = var.kms_observability_arn` sẽ fail vì KMS key policy thiếu
   CloudWatch Logs service grant (root cause ở PR #46, blocker cho PR #47).

2. **[HIGH]** Alertmanager webhook target hardcode:
   `http://patch-receiver.self-heal-system.svc.cluster.local:8443/alerts`
   — tên service, port 8443, path `/alerts` chưa được định nghĩa ở bất kỳ đâu trong
   contracts hay manifests. Port 8443 là ALB→workload port (không phải in-cluster).
   Nếu sai, Alertmanager silently fail → alert không bao giờ đến receiver → pipeline
   self-heal không kích hoạt.

3. **[HIGH]** `aws_cloudwatch_log_group` tạo group `/aws/eks/<cluster>/cluster` — group
   này EKS sẽ auto-create khi `enabled_cluster_log_types` được bật. Nếu EKS create
   trước (unencrypted, no retention), Terraform apply sẽ fail với
   `ResourceAlreadyExistsException`.

4. **[MEDIUM]** AWS LBC module không enforce "Internal ALB only": `sg_alb_internal_id`
   và `private_subnet_ids` đã khai báo trong `variables.tf` nhưng không dùng trong
   `main.tf`. Không có default `IngressClassParams` với `scheme: internal`. Workload
   thiếu annotation sẽ tạo public ALB, vi phạm `docs/03_security_design.md §1.1`.

---

## 5. Files đã tạo/sửa trong session này (branch `tan-1`)

### `manifests/ai-engine/service.yaml` — sửa comment
Ghi đúng trust model: HTTP nội bộ thuần, đã bỏ SigV4, mTLS chỉ tùy chọn,
bảo vệ cổng 8080 dựa hoàn toàn vào NetworkPolicy.

### `manifests/ai-engine/` — source đầy đủ
Copy từ `lab-w11/Capstone-Phase-2-CodeAI/demo/app/`. Folder giờ có:
`main.py` (FastAPI dummy, luôn trả anomaly detected) + `Dockerfile` (python:3.11-slim,
port 8080) + `requirements.txt` + `deployment.yaml` (placeholder `<ECR_IMAGE_URI>`)
+ `service.yaml` + `networkpolicy.yaml`.

### `manifests/ai-engine/networkpolicy.yaml` — file mới
3 NetworkPolicy cho namespace `self-heal-system`:
- `ai-engine-default-deny`: deny-all ingress+egress làm nền (áp cho TẤT CẢ pod).
- `ai-engine-allow-ingress`: chỉ pod label `app=cdo-self-heal-controller` → port 8080.
- `ai-engine-allow-egress`: DNS (53) + HTTPS 443 ra VPC Endpoints, chặn K8s API server.

**2 TODO trước khi policy có tác dụng:**
- Bật NetworkPolicy enforcement: `enableNetworkPolicy: true` trong EKS addon `vpc-cni`
  (nhờ owner INFRA-4).
- Điền `<CLUSTER_POD_CIDR>` từ output `modules/networking`.

### `manifests/webhook-receiver/` — thư mục mới (Pack #1 minimal receiver)
Webhook receiver nhận alert Alertmanager → gọi AI Engine `/v1/detect` + `/v1/decide` → log.
- `app.py` — FastAPI, port 8443, path `/alerts`
- `Dockerfile` — python:3.11-slim
- `requirements.txt` — fastapi, uvicorn, httpx, pydantic
- `k8s.yaml` — Deployment + Service `patch-receiver:8443` + 2 NetworkPolicy
- `test-alert-rule.yaml` — PrometheusRule: `TestAlwaysFiring` (luôn fire) + `PodCrashLooping`

**Label strategy:** pod nhận `app=cdo-self-heal-controller` (để AI Engine NetworkPolicy
cho phép gọi vào 8080) + `component=patch-receiver` (để policy riêng target đúng pod).

**ECR repo:** `tf-3-webhook-receiver` (CDO tự tạo, dùng cùng registry với `tf-3-ai-engine`).

### `infra/README.md` — thêm INFRA-8
Ticket INFRA-8 đã được thêm vào bảng phân công. Cập nhật "7 → 8 ticket".

### `infra/INTEGRATION_WITH_AI.md` — cập nhật
Bỏ reference path cũ (`lab-w11/...`) không còn tồn tại. Cập nhật đúng topology,
trust model Local Trust, và note AI team chưa push app source.

### `infra/DEPLOY_AND_TEST_GUIDE.md` — tạo mới
Hướng dẫn build 2 images (ECR login 1 lần, 2 repo), deploy, 7 test case bao gồm
E2E test với Alertmanager → receiver → AI Engine.

---

## 6. Nơi nên xem khi review/debug

| Vấn đề | Xem ở đâu |
|---|---|
| SG rule thiếu / sai chiều | `modules/security/main.tf` + `docs/03_security_design.md §1.2` |
| KMS key policy | `modules/security/main.tf` (KMS block cuối file) |
| IAM permissions cho CI | `bootstrap/main.tf` lines ~200-230 |
| NetworkPolicy AI Engine | `manifests/ai-engine/networkpolicy.yaml` |
| Trust model AI Engine | `contracts/ai-api-contract.md`, `contracts/telemetry-contract.md`, `contracts/deployment-contract.md §5` |
| Alertmanager webhook URL | `modules/observability/main.tf` local `alert_receiver_url` |
| Apply order / wiring | `environments/sandbox/foundation/*.tf` + `infra/README.md` |
| Naming rules | `infra/CLAUDE.md §1` (tên SG, KMS alias, namespace phải đúng từng ký tự) |

---

## 7. Câu lệnh hay dùng

```bash
# Xem PR đang mở
gh pr list --repo truongcongtu318/capstone-phase2 --state open

# Xem diff của PR
gh pr diff <number>

# Xem metadata PR
gh pr view <number> --json title,body,author,headRefName,headRefOid,state

# Validate Terraform (chạy trong module)
terraform fmt -check && terraform validate
```
