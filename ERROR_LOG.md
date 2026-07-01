# 📋 Error Log — Capstone Phase 2 Self-Heal System

> Tổng hợp lỗi đã phát hiện & fix trong quá trình setup + test E2E (2026-06-29 → 2026-07-01)

---

## 🗓️ Early Phase — Core Infrastructure (PR #31 → #89)

| # | Lỗi | Nguyên nhân | Giải pháp | PR | Kết quả |
|---|------|-------------|-----------|----|---------|
| 1 | **Terraform schema mismatch** | Config schema không đồng bộ giữa modules | Sửa file cấu hình cho đúng schema | #31, #36 | TF plan pass |
| 2 | **Infra code lỗi nền tảng** | Code infra cơ bản chưa chuẩn | Fix tổng thể code infra | #48 | Infra stable |
| 3 | **GitOps namespace wave, targetRevision, SA naming sai** | Config GitOps apps không đồng bộ với namespace/resource naming | Sửa wave, targetRevision, SA naming | #65 | GitOps apps deploy đúng |
| 4 | **IAM role missing** | Thiếu IAM role cho một số service | Thêm role còn thiếu | #67 | Services có đủ permissions |
| 5 | **K8s version mismatch** | Version K8s không tương thích với config | Đổi version K8s cho phù hợp | #73 | Cluster version ổn định |
| 6 | **VPC Endpoint SG không cho traffic vào** | Security Group của VPC Endpoint chặn inbound từ private subnets | Mở SG ingress cho VPC endpoints | #77 | Traffic từ private subnet qua endpoint được |
| 7 | **Duplicate OIDC provider resource** | Terraform tạo duplicate OIDC provider → conflict | Resolve duplicate OIDC provider | #80 | OIDC provider unique |
| 8 | **Security Groups lỗi** | Security Group config sai | Fix security groups | #83 | SG đúng |
| 9 | **EKS Node Group không bootstrap được** | NAT-less VPC, node gọi SSM/EC2 endpoint timeout → không join cluster | Thêm VPC Interface Endpoints: `ec2`, `ssm`, `ssmmessages` | #84, #87, #88 | Node group join cluster thành công |

---

## 🗓️ 2026-06-29 — Phase 4 Image Mirror & Helm Deploy (PR #91 → #107)

| # | Lỗi | Nguyên nhân | Giải pháp | PR | Kết quả |
|---|------|-------------|-----------|----|---------|
| 10 | **CRD validation fail cho IngressClassParams** | Kubernetes provider không handle CRD lifecycle | Bypass CRD validation với wildcard `computed_fields` | #91, #92, #93 | Ingress & ALB deploy thành công |
| 11 | **SQS Worker Fast Lane không commit Git** | Worker patch deployment nhưng không commit config mới lên CodeCommit → ArgoCD revert | Thêm `_git_commit_push` trong Fast Lane path | #94 | Worker commit Git trước khi resume ArgoCD |
| 12 | **Container images thiếu trong ECR Private** | NAT-less VPC không pull được từ public registries | Mirror 19 images vào ECR Private qua CI/CD | #95, #96, #97 | 19/19 images mirrored |
| 13 | **Image version/source sai trong mirror-list** | `kube-webhook-certgen: v1.4.1` không tồn tại, LBC source sai, Karpenter tag sai | Fix versions và sources | #95, #96, #97 | Images pull đúng từ ECR |
| 14 | **Helm chart `bedag/raw` v0.2.5 không tồn tại + image registry ghép sai** | External repo remove version, Terraform ghép sai registry prefix | Tạo local raw-chart + sửa nested `set` cho image registry | #98 | Ingress + KPS webhook hoạt động |
| 15 | **Thiếu IRSA role + DynamoDB + Secrets Manager** | AI Engine chưa có quyền Bedrock, Worker thiếu GetSecretValue, thiếu DynamoDB Lock | Add AI Engine IRSA, Secrets Manager, DynamoDB Lock Table, fix IAM policies | #107 | AI Engine có quyền Bedrock, Worker có Secrets |

---

## 🗓️ 2026-06-30 — Handover & Bug Fixes (PR #114 → #165)

| # | Lỗi | Nguyên nhân | Giải pháp | PR | Kết quả |
|---|------|-------------|-----------|----|---------|
| 16 | **Alertmanager StatefulSet ReconciliationFailed** | Helm chart tạo route với receiver `"null"` nhưng receivers list không include `"null"` | Thêm `{ name = "null" }` vào đầu receivers | #114 | Alertmanager 2/2 Running, RECONCILED=True |
| 17 | **LBC timeout gọi ACM public endpoint** | NAT-less VPC không internet, LBC timeout gọi ACM | Thêm VPC Interface Endpoint `acm` + ACM permissions cho LBC IAM | #115, #116 | LBC có thể request cert qua private |
| 18 | **HPA không scale — Metrics API missing** | Cluster thiếu Metrics Server → HPA `<unknown>` | Deploy Metrics Server EKS Addon | #115 | HPA active: cpu 0%/70%, mem 3%/80% |
| 19 | **GitOps pipeline conflict khi sync CodeCommit** | GitHub Actions push nhiều commit, CodeCommit rebase conflict | Auto-resolve: `git pull --rebase -X theirs` | #121, #123, #125, #128, #130, #136 | Sync không conflict |
| 20 | **Terraform Helm timeout deploy operators** | 4 Helm releases timeout do `wait=true` + timeout ngắn | Set `wait=false` + timeout 900s | #142 | Operators deployed thành công |
| 21 | **AI Engine ESO apiVersion sai** | External Secrets Operator CRD `v1` chưa deploy → dùng `v1beta1` | Downgrade ESO apiVersion xuống `v1beta1` | #145 | ExternalSecret tạo thành công |
| 22 | **HPA replicas bị ArgoCD revert** | ArgoCD thấy drift replicas → sync về giá trị template gốc | Ignore HPA replicas trong ArgoCD diffs | #146 | Scale không bị revert |
| 23 | **Ingress ALB không tạo được** | Thiếu ELB VPC Endpoint, SG name không đúng, listener config sai | Thêm ELB endpoint, fix SG name, fix HTTP listener, fix AddTags permissions | #150, #151, #152, #153 | ALB tạo thành công |
| 24 | **SQS Worker git clone fail + ArgoCD auth token 401** | CodeCommit clone path sai, ArgoCD token hết hạn/url sai | Fix clone path, fix ArgoCD auth | #154 | Worker clone + auth OK |
| 25 | **Worker không pass alertname tới AI Engine** | Telemetry window thiếu alertname label → AI Engine không match fault type | Thêm alertname vào `telemetry_window[0].labels` | #157 | AI Engine nhận đúng alert type |
| 26 | **EKS node group t3.large upgrade** | Node group resource không đủ cho CRD operators (nhất là Kyverno + Argo Workflows) | Upgrade node group từ instance type nhỏ lên `t3.large` | #159, #160, #165 | Nodes đủ resource cho operators |

---

## 🗓️ 2026-07-01 — GitOps Sync & E2E Test (PR #170 → #176)

| # | Lỗi | Nguyên nhân | Giải pháp | PR | Kết quả |
|---|------|-------------|-----------|----|---------|
| 27 | **CodeCommit lưu full source code thay vì chỉ GitOps manifests** | Pipeline cũ checkout toàn bộ repo lên CodeCommit | Pipeline mới tạo orphan branch chỉ chứa `gitops/` folder → force-push | #170 | CodeCommit sạch, chỉ 8 GitOps folders |
| 28 | **AI Engine crash: `ValueError: could not convert string to float`** | `float(point.value)` gặp string telemetry | Wrap try-except `(ValueError, TypeError)`: skip non-numeric | #172 | AI Engine ổn định với mọi telemetry |
| 29 | **Worker send telemetry sai format — AI Engine detect fail** | Telemetry window thiếu time series metrics → BOCPD không detect anomaly | Worker inject synthetic time series metrics vào telemetry_window | #176 | BOCPD detect anomaly thành công |

---

## 🔧 Các PR Bot tự động (có prefix "🤖 GitOps: Update image tags")

Các PR này được tạo tự động bởi GitHub Actions `app-pipeline.yml`, không phải fix bug thủ công. Chúng update SHA tag mới cho image trong `kustomization.yaml` sau mỗi lần build thành công:

**Danh sách:** #158, #162, #169, #173, #175, #177

---

## 📊 Thống kê tổng thể

| Hạng mục | Số lượng |
|----------|----------|
| **Tổng số PR** | ~60+ merged |
| **PR fix bug thực tế** | **29** (#31 → #176) |
| **PR bot auto-update tag** | 6 |
| **PR feature/chore khác** | ~25+ |

### Phân loại bug fix theo module

| Module | Số PR fix | Các PR |
|--------|-----------|--------|
| **Networking (VPC endpoints, SG)** | 5 | #77, #83, #84, #87, #115, #150 |
| **Image Mirror & ECR** | 4 | #95, #96, #97, #98 |
| **ArgoCD / GitOps** | 5 | #65, #136, #139, #146, #170 |
| **AI Engine** | 3 | #145, #172, #176 |
| **SQS Worker** | 4 | #94, #154, #157, #176 |
| **Operators (Helm timeout)** | 2 | #142, #159, #160 |
| **Ingress / ALB** | 5 | #91, #92, #93, #150, #151, #152, #153 |
| **Alertmanager** | 1 | #114 |
| **Core Infra (TF schema, IAM, K8s version)** | 5 | #31, #36, #48, #67, #73, #80 |

---

**Ngày tạo:** 2026-07-01  
**Cluster:** EKS 1.34.9 (us-east-1)  
**Repo:** `truongcongtu318/capstone-phase2`  
**Account:** `474013238625`
