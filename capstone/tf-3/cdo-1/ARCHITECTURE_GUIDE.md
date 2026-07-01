# CDO-01 Self-Heal Platform — Hướng Dẫn Kiến Trúc Chi Tiết

> **Dự án:** Capstone Phase 2 — CDO-01 AIOps Self-Healing System  
> **AWS Account:** `474013238625` | **Region:** `us-east-1`  
> **EKS Cluster:** `tf3-cdo1-sandbox-eks`  
> **Cập nhật lần cuối:** 2026-07-01

---

## 1. Tổng Quan Hệ Thống

CDO-01 là nền tảng **tự chữa lành (Self-Healing Platform)** dựa trên AI. Khi một ứng dụng Tenant gặp sự cố (OOMKilled, Service Stuck, Queue Backlog...), hệ thống tự động phát hiện, phân tích nguyên nhân bằng LLM (Amazon Bedrock) và khắc phục mà không cần can thiệp thủ công của kỹ sư.

### 1.1. Mô Hình Triển Khai

```
┌──────────────────────── AWS Cloud (us-east-1) ─────────────────────────────┐
│                                                                             │
│  VPC: 10.42.0.0/16 — ZERO Internet Egress (NAT-less)                       │
│                                                                             │
│  ┌─── Public Subnets ───┐    ┌──────────── Private Subnets ───────────────┐ │
│  │  Internal ALB        │    │                                            │ │
│  │  (sg-alb-internal)   │───▶│  EKS Cluster: tf3-cdo1-sandbox-eks        │ │
│  └──────────────────────┘    │  Nodes: 3x t3.large (max 105 pods)        │ │
│                              │                                            │ │
│                              │  ┌─────────────────────────────────────┐  │ │
│                              │  │ Namespaces & Workloads               │  │ │
│                              │  │  kube-system      (system daemons)  │  │ │
│                              │  │  argocd            (GitOps engine)  │  │ │
│                              │  │  kyverno           (policy engine)  │  │ │
│                              │  │  observability     (monitoring)     │  │ │
│                              │  │  external-secrets  (secrets sync)   │  │ │
│                              │  │  amazon-cloudwatch (log shipping)   │  │ │
│                              │  │  self-   (workload 1)     │  │ │
│                              │  │  tenant-checkout   (workload 2)     │  │ │
│                              │  └─────────────────────────────────────┘  │ │
│                              └────────────────────────────────────────────┘ │
│                                                                             │
│  ┌──────────────────────── VPC Endpoints (Private Link) ───────────────┐   │
│  │ ECR, S3, DynamoDB, Secrets Manager, SQS, SNS, CodeCommit, CW Logs  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Luồng Vận Hành Self-Heal (E2E Flow)

### 2.1. Sơ Đồ Tổng Quan

```
[Tenant Pod lỗi]
      │
      │ metrics / logs
      ▼
[Prometheus Alertmanager]
      │
      │ HTTP Webhook POST
      ▼
[webhook-receiver] ──────────────────▶ [AWS SQS Queue]
  (ClusterIP Service)                        │
  Namespace: self-heal-system                │ poll message
                                             ▼
                                       [sqs-worker]
                                             │
                                             │ gọi REST API
                                             ▼
                                       [ai-engine] ──▶ [Amazon Bedrock / Ollama]
                                             │           (LLM phân tích nguyên nhân)
                                             │
                          ┌──────────────────┴────────────────────┐
                          │ FAST LANE (Urgent)                     │ SLOW LANE (Deferred)
                          │ OOMKilled / Service Stuck              │ Queue Backlog Scale
                          ▼                                        ▼
                  [Tắt ArgoCD Auto-Sync]              [Argo Workflows Job]
                          │                                        │
                          ▼                                        ▼
                  [Patch EKS API trực tiếp]           [Commit config → CodeCommit]
                  (kubernetes-client ~0.03s)                       │
                          │                                        ▼
                          ▼                               [ArgoCD Reconcile]
                  [Commit limit mới → CodeCommit]        (sync về trạng thái mới)
                          │
                          ▼
                  [Bật lại ArgoCD Auto-Sync]
                  (Failsafe TTL: 5 phút nếu bị treo)
```

### 2.2. Chi Tiết Từng Bước

| Bước | Component | Hành động | Thời gian |
|------|-----------|-----------|-----------|
| 1 | Prometheus | Scrape metrics từ pods mỗi 15s | Continuous |
| 2 | Alertmanager | Phát hiện vượt ngưỡng → gửi Webhook | <30s |
| 3 | webhook-receiver | Nhận POST, validate, đóng gói payload | <1s |
| 4 | SQS | Buffer message, đảm bảo at-least-once delivery | Milliseconds |
| 5 | sqs-worker | Poll SQS mỗi 5s, gọi ai-engine | <5s |
| 6 | ai-engine + Bedrock | Phân tích nguyên nhân bằng LLM | 3–10s |
| 7a | Fast Lane | Patch K8s API trực tiếp | ~0.03s latency, tổng <15s |
| 7b | Slow Lane | Commit Git + ArgoCD sync | <120s |

### 2.3. Ba Kịch Bản Tự Chữa Lành Đã Triển Khai

#### Kịch Bản 1: OOMKilled (Fast Lane)
```
Trigger:  Pod bị kill do vượt memory limit
Action:   PATCH_MEMORY_LIMIT
Quy trình:
  1. ArgoCD Auto-Sync bị tắt tạm thời (API call)
  2. Patch memory limit lên x1.5 qua K8s API
  3. Commit memory limit mới lên AWS CodeCommit
  4. Bật lại ArgoCD Auto-Sync + Force Sync
Failsafe: CronJob TTL 5 phút tự động re-enable sync nếu bị treo
```

#### Kịch Bản 2: Service Stuck (Fast Lane)
```
Trigger:  Pod không respond, health check fail liên tục
Action:   ROLLOUT_RESTART
Quy trình:
  1. ArgoCD Auto-Sync bị tắt tạm thời
  2. Patch annotation restartedAt lên Deployment
  3. Commit annotation mới lên AWS CodeCommit
  4. Bật lại ArgoCD Auto-Sync + Force Sync
```

#### Kịch Bản 3: Queue Backlog (Slow Lane)
```
Trigger:  SQS Queue depth vượt ngưỡng, xử lý chậm
Action:   SCALE_REPLICAS
Quy trình:
  1. ai-engine trigger Argo Workflows Job
  2. Argo Workflows commit số replicas mới lên CodeCommit
  3. ArgoCD tự động Reconcile → K8s scale deployment
Không cần tắt Auto-Sync vì đây là GitOps thuần
```

---

## 3. Hạ Tầng Terraform — Multi-State Architecture

### 3.1. Tại Sao Dùng Multi-State?

Thay vì một file state duy nhất, hạ tầng được chia thành **4 State độc lập**:

```
AWS S3: tf-3-aiops-audit-trail (State Backend)
├── sandbox/networking/terraform.tfstate   # VPC, SG, KMS, Endpoints
├── sandbox/compute/terraform.tfstate      # EKS, Node Group, Karpenter
└── sandbox/services/terraform.tfstate     # Helm releases, Operators
```

**Lý do:**
- **Blast Radius nhỏ:** Lỗi ở Services không ảnh hưởng state Networking
- **Performance:** Plan/Apply chỉ quét ~20-30 resources thay vì 200+
- **Phân quyền:** Mỗi member chỉ có quyền write state của mình
- **Lock cô lập:** DynamoDB lock chỉ block cùng 1 state, không block state khác

### 3.2. Trình Tự Deploy Bắt Buộc

```
Phase 0 (Bootstrap) ──▶ Phase 1 (Networking) ──▶ Phase 2 (Compute) ──▶ Phase 3 (Services)
     ↓                         ↓                          ↓                      ↓
S3 + DynamoDB +          VPC + SG + KMS +           EKS Cluster +          Helm Releases
OIDC Roles              VPC Endpoints              Node Group +          (LBC, Prometheus,
(Chạy 1 lần)                                       Karpenter IAM         ESO, Kyverno...)
```

> **NGHIÊM CẤM** đảo thứ tự deploy. Nếu Networking chưa xong, Compute sẽ fail ngay ở `terraform init` vì không tìm thấy remote state trên S3.

### 3.3. Cơ Chế Kế Thừa State (Remote State)

Mỗi phase đọc output của phase trước qua `data.terraform_remote_state`:

```hcl
# Ví dụ: compute/main.tf đọc VPC từ networking state
data "terraform_remote_state" "networking" {
  backend = "s3"
  config = {
    bucket = "tf-3-aiops-audit-trail"
    key    = "sandbox/networking/terraform.tfstate"
    region = "us-east-1"
  }
}

# Sử dụng:
subnet_ids = data.terraform_remote_state.networking.outputs.private_subnet_ids
```

---

## 4. Chi Tiết Từng Phase Terraform

### Phase 0: Bootstrap (`infra/bootstrap/`)

**Mục đích:** Tạo nền tảng lưu trữ state và xác thực CI/CD. Chạy **một lần duy nhất**.

| Tài nguyên | Tên | Mục đích |
|------------|-----|----------|
| S3 Bucket | `tf-3-aiops-audit-trail` | Lưu `.tfstate` + Audit logs (Object Lock 90 ngày) |
| DynamoDB Table | `tf-3-aiops-idempotency-lock` | Lock state + Idempotency lock nghiệp vụ AI Engine |
| IAM OIDC Role | `tf3-cdo1-github-actions-role` | Cho phép GitHub Actions assume role qua OIDC (không cần Access Key) |

### Phase 1: Networking & Security (`infra/environments/sandbox/networking/`)

**Mục đích:** Dựng khung mạng và bảo mật. Không có Internet egress — mọi traffic nội bộ qua VPC Endpoints.

#### VPC & Subnets
```
VPC CIDR: 10.42.0.0/16
├── Public Subnets:  10.42.0.0/24, 10.42.1.0/24   → Chỉ dành cho ALB
└── Private Subnets: 10.42.8.0/21, 10.42.16.0/21   → EKS Nodes, Compute
```

#### VPC Endpoints (12 endpoints — thay thế hoàn toàn NAT Gateway)
| Endpoint | Loại | Dịch vụ thay thế |
|----------|------|------------------|
| `com.amazonaws.us-east-1.s3` | Gateway | Kéo image ECR layer, State Backend |
| `com.amazonaws.us-east-1.dynamodb` | Gateway | DynamoDB Lock Table |
| `com.amazonaws.us-east-1.ecr.api` | Interface | Pull image metadata |
| `com.amazonaws.us-east-1.ecr.dkr` | Interface | Pull image layer |
| `com.amazonaws.us-east-1.ec2` | Interface | EKS Node registration |
| `com.amazonaws.us-east-1.sts` | Interface | IRSA token exchange |
| `com.amazonaws.us-east-1.logs` | Interface | CloudWatch Logs |
| `com.amazonaws.us-east-1.monitoring` | Interface | CloudWatch Metrics |
| `com.amazonaws.us-east-1.secretsmanager` | Interface | Secrets Manager |
| `com.amazonaws.us-east-1.codecommit` | Interface | Git repo (GitOps) |
| `com.amazonaws.us-east-1.sqs` | Interface | SQS Queue |
| `com.amazonaws.us-east-1.sns` | Interface | SNS Alerts |

#### Security Groups
| Security Group | Tên | Cho phép traffic |
|----------------|-----|-----------------|
| ALB | `sg-alb-internal` | Port 443/80 từ EKS workload |
| EKS Workload | `sg-eks-workload` | Intra-cluster + ALB + VPC Endpoints |
| EKS Control Plane | `sg-eks-control-plane` | Kubelet (443, 10250) từ worker nodes |
| RDS | `sg-rds` | Port 5432 chỉ từ EKS workload |
| VPC Endpoints | `sg-vpc-endpoint` | Port 443 từ toàn bộ VPC CIDR |

#### KMS Keys (5 keys — mã hóa toàn bộ dữ liệu at-rest)
| Alias | Dùng cho |
|-------|----------|
| `alias/cdo-infra-kms` | EKS Secrets, EBS Volumes |
| `alias/cdo-observability-kms` | CloudWatch Logs, Prometheus |
| `alias/cdo-audit-kms` | S3 Audit Bucket (Object Lock) |
| `alias/cdo-secrets-kms` | Secrets Manager entries |
| `alias/cdo-app-data-kms` | Application data, RDS |

### Phase 2: Compute (`infra/environments/sandbox/compute/`)

**Mục đích:** Tạo Kubernetes cluster và cấu hình tự động scale nodes.

#### EKS Cluster
```
Tên:          tf3-cdo1-sandbox-eks
K8s Version:  1.33
Node Group:   tf3-cdo1-sandbox-eks-nodes
Instance:     t3.large (max 35 pods/node)
Scaling:      min=1, desired=3, max=5
Max pods:     3 nodes × 35 = 105 pods
```

#### IAM Roles for Service Accounts (IRSA)
Cho phép pod gọi AWS API mà không cần hardcode Access Key:
- **Karpenter:** Quyền EC2 để provision nodes mới
- **AWS Load Balancer Controller:** Quyền tạo/xóa ALB, Target Groups
- **External Secrets:** Quyền đọc Secrets Manager
- **CloudWatch Agent:** Quyền ghi metrics/logs
- **SQS Worker:** Quyền đọc SQS, ghi DynamoDB, đọc Secrets Manager
- **AI Engine:** Quyền gọi Bedrock, ghi S3 Audit, đọc CodeCommit

#### Karpenter
Tự động scale nodes khi pods không được schedule do thiếu tài nguyên. Sử dụng NodePool + EC2NodeClass để chọn instance type phù hợp.

### Phase 3: Services (`infra/environments/sandbox/services/`)

**Mục đích:** Cài đặt các operator và monitoring stack lên EKS qua Helm.

#### Danh sách Helm Releases

| Release | Chart | Namespace | Version | Chức năng |
|---------|-------|-----------|---------|-----------|
| `aws-load-balancer-controller` | eks/aws-load-balancer-controller | kube-system | v2.8.x | Tạo ALB tự động từ Ingress |
| `external-secrets` | external-secrets/external-secrets | external-secrets-system | 0.9.13 | Sync Secrets từ AWS Secrets Manager |
| `kyverno` | kyverno/kyverno | kyverno | 3.2.6 | Policy engine, giới hạn quyền patch pod |
| `kube-prometheus-stack` | prometheus-community/kube-prometheus-stack | observability | latest | Prometheus + Grafana + Alertmanager |
| `aws-cloudwatch-observability` | EKS Add-on | amazon-cloudwatch | latest | Fluent-bit log shipping → CloudWatch |

> **Lưu ý quan trọng:** Tất cả images phải được pull từ ECR Private (`474013238625.dkr.ecr.us-east-1.amazonaws.com`) do VPC không có internet egress. Xem `gitops/mirror-list.txt` để biết danh sách images đã mirror.

---

## 5. Chi Tiết Từng Namespace Kubernetes

### 5.1. `kube-system` — System Components
| Pod | Chức năng |
|-----|-----------|
| `coredns` (x2) | DNS resolution trong cluster |
| `kube-proxy` (x3, DaemonSet) | Network rules trên mỗi node |
| `aws-node` (x3, DaemonSet) | VPC CNI — gán IP cho pods |
| `metrics-server` (x2) | HPA metrics (CPU/Memory) |
| `aws-load-balancer-controller` (x2) | Tạo ALB từ Ingress resources |

### 5.2. `argocd` — GitOps Engine
| Pod | Chức năng |
|-----|-----------|
| `argocd-server` | UI + API Gateway ArgoCD |
| `argocd-application-controller` | Reconcile loop — sync K8s ↔ Git |
| `argocd-repo-server` | Clone & render Git manifests |
| `argocd-dex-server` | SSO/Auth provider |
| `argocd-redis` | Cache layer cho ArgoCD |
| `argocd-applicationset-controller` | Tạo Applications từ ApplicationSet |
| `argocd-notifications-controller` | Gửi notify khi sync thành công/thất bại |

**ArgoCD Apps đang quản lý:**
```
root-application        → App-of-Apps, quản lý tất cả apps bên dưới
├── argocd-config       → ArgoCD config itself (self-managed)
├── security-policies   → Kyverno ClusterPolicies
├── ai-engine           → Deployment self-heal-system/ai-engine
├── sqs-worker          → Deployment self-heal-system/sqs-worker
├── webhook-receiver    → Deployment self-heal-system/webhook-receiver
├── tenant-payment-app  → Tất cả manifests tenant-payment
└── tenant-checkout-app → Tất cả manifests tenant-checkout
```

### 5.3. `kyverno` — Policy Engine
| Pod | Chức năng |
|-----|-----------|
| `kyverno-admission-controller` | Webhook bắt mọi K8s API request, enforce policies |
| `kyverno-background-controller` | Background scan existing resources |
| `kyverno-cleanup-controller` | Quản lý lifecycle cleanup policies |
| `kyverno-reports-controller` | Tạo PolicyReport objects |

**Policies đang áp dụng (namespace: `self-heal-system`):**
```
restrict-mutations:
  Chỉ cho phép patch:
  - spec.replicas
  - containers[*].resources.limits (CPU & Memory)
  Các trường khác → DENY
```

### 5.4. `observability` — Monitoring Stack
| Pod | Chức năng |
|-----|-----------|
| `prometheus-*` | Thu thập metrics mỗi 15s từ tất cả pods/nodes |
| `alertmanager-*` | Nhận alerts từ Prometheus, route → webhook-receiver |
| `kube-prometheus-stack-grafana` | Dashboard visualization |
| `kube-prometheus-stack-operator` | Quản lý CRD ServiceMonitor, PrometheusRule |
| `kube-state-metrics` | Export K8s object metrics (replicas, pod status...) |
| `node-exporter` (x3, DaemonSet) | Export node-level metrics (CPU, RAM, Disk) |

**Alert Rules đã cấu hình:**
- `OOMKilled`: Pod bị kill do vượt memory limit
- `ServiceStuck`: Pod Ready=False > 2 phút
- `QueueBacklog`: SQS ApproximateNumberOfMessagesVisible > 100

### 5.5. `external-secrets-system` — Secrets Sync
| Pod | Chức năng |
|-----|-----------|
| `external-secrets` | Controller đồng bộ ExternalSecret → K8s Secret |
| `external-secrets-cert-controller` | Tự động gia hạn webhook TLS cert |
| `external-secrets-webhook` | Admission webhook validate ExternalSecret CRDs |

**Flow sync secrets:**
```
AWS Secrets Manager ──▶ ExternalSecret (CRD) ──▶ K8s Secret ──▶ Pod env/volume
                         (cập nhật mỗi 1h)
```

### 5.6. `amazon-cloudwatch` — Log Shipping
| Pod | Chức năng |
|-----|-----------|
| `cloudwatch-agent` (x3, DaemonSet) | Thu thập metrics node, gửi lên CloudWatch |
| `fluent-bit` (x3, DaemonSet) | Tail log container từ `/var/log/containers/*.log`, ship → CloudWatch Logs |
| `cloudwatch-observability-controller` | Quản lý add-on lifecycle |

**Log Groups tạo ra:**
```
/aws/containerinsights/tf3-cdo1-sandbox-eks/application   → App logs
/aws/containerinsights/tf3-cdo1-sandbox-eks/host          → Node system logs
/aws/containerinsights/tf3-cdo1-sandbox-eks/performance   → Performance metrics
```

### 5.7. `self-heal-system` — AI Self-Healing Core

Đây là namespace trung tâm, chứa 3 components của hệ thống tự chữa lành.

#### webhook-receiver
```
Loại:     Deployment (1 replica)
Image:    ECR/webhook-receiver:latest
Expose:   ClusterIP Service (port 8080)
Chức năng:
  - Nhận HTTP POST từ Alertmanager
  - Validate payload (HMAC signature)
  - Push message vào AWS SQS queue
  - Trả về 200 OK nhanh (không block)
```

#### sqs-worker
```
Loại:     Deployment (1 replica)
Image:    ECR/sqs-worker:latest
Chức năng:
  - Long-poll SQS queue (WaitTimeSeconds=20)
  - Parse message, xác định loại incident
  - Gọi ai-engine REST API
  - Delete message khỏi SQS sau khi xử lý thành công
  - Ghi idempotency record vào DynamoDB (tránh xử lý 2 lần)
```

#### ai-engine
```
Loại:     Deployment (2 replicas)
Image:    ECR/ai-engine:latest
Chức năng:
  - Nhận incident từ sqs-worker
  - Query Prometheus để lấy metrics context (memory, CPU, replicas)
  - Gọi Amazon Bedrock (Claude/Titan) hoặc Ollama (in-cluster LLM)
  - LLM phân tích nguyên nhân + đề xuất action
  - Thực thi action:
    Fast Lane → patch K8s API trực tiếp
    Slow Lane → trigger Argo Workflows
  - Ghi audit log lên S3 Audit Bucket (Kinesis Firehose)
```

**IRSA Permissions của ai-engine:**
```
bedrock:InvokeModel           → Gọi LLM
eks:*                         → Patch K8s resources
s3:PutObject (tf-3-aiops-*)  → Ghi audit log
codecommit:GitPull/GitPush    → Commit config mới (GitOps)
secretsmanager:GetSecret      → Đọc credentials
```

### 5.8. `tenant-payment` — Tenant 1 (Demo Workload)
| Pod | Chức năng |
|-----|-----------|
| `order-api` | REST API nhận đơn hàng |
| `order-service` | Xử lý business logic đơn hàng |
| `payment-worker` | Worker xử lý thanh toán async |

**Tenant ID:** `d3b07384-d113-495f-9f58-20d18d357d75`

### 5.9. `tenant-checkout` — Tenant 2 (Demo Workload)
| Pod | Chức năng |
|-----|-----------|
| `checkout-api` | REST API checkout flow |
| `checkout-frontend` | Frontend service (BFF) |
| `checkout-worker` | Worker xử lý async checkout |

**Tenant ID:** `6c8b4b2b-4d45-4209-a1b4-4b532d56a31c`

---

## 6. GitOps Flow — Cách Code Được Triển Khai

### 6.1. Cấu Trúc Git Repository
```
capstone-phase2/
├── capstone/tf-3/cdo-1/
│   ├── infra/          → Terraform IaC (Sub-team 1)
│   ├── gitops/         → K8s manifests (ArgoCD quản lý)
│   │   ├── argo-apps/  → ArgoCD Application definitions
│   │   ├── manifests/  → Kustomize base + overlays
│   │   │   ├── base/   → Base manifests (ai-engine, sqs-worker, webhook-receiver)
│   │   │   └── overlays/sandbox/  → Sandbox-specific patches
│   │   ├── tenants/    → Tenant namespaces + RBAC
│   │   ├── security-policies/  → Kyverno ClusterPolicies
│   │   └── mirror-list.txt     → Danh sách images cần mirror vào ECR
│   └── app/            → Application source code
└── .github/workflows/  → GitHub Actions CI/CD pipelines
```

### 6.2. Luồng Deploy Ứng Dụng (GitOps)
```
Developer push code
      │
      ▼
GitHub Actions (CI):
  1. Build Docker image
  2. Push lên ECR Private
  3. Update image tag trong gitops/overlays/sandbox/*/kustomization.yaml
      │
      ▼
ArgoCD phát hiện thay đổi trong Git (polling mỗi 3 phút)
      │
      ▼
ArgoCD Apply manifests lên EKS cluster
      │
      ▼
Pods rolling update với image mới
```

### 6.3. Luồng Deploy Hạ Tầng (IaC)
```
Developer tạo PR thay đổi infra/
      │
      ▼
GitHub Actions (terraform-pipeline.yml):
  1. terraform fmt + validate
  2. terraform plan (comment vào PR)
      │
      ▼ (sau khi merge vào main)
GitHub Actions:
  1. Detect path changes (networking/ compute/ services/)
  2. Chạy terraform apply theo đúng thứ tự phase
  3. Update remote state trên S3
```

---

## 7. Image Mirror Strategy (NAT-less ECR)

Do VPC không có Internet egress, **tất cả** Docker images phải được mirror vào ECR Private trước khi deploy.

### 7.1. Danh Sách Images Đã Mirror (`gitops/mirror-list.txt`)

| Source (Public) | ECR Destination |
|-----------------|-----------------|
| `ghcr.io/kyverno/kyverno:v1.12.5` | `474013238625.dkr.ecr.us-east-1.amazonaws.com/kyverno/kyverno:v1.12.5` |
| `ghcr.io/kyverno/kyvernopre:v1.12.5` | `474013238625.dkr.ecr.us-east-1.amazonaws.com/kyverno/kyvernopre:v1.12.5` |
| `ghcr.io/kyverno/background-controller:v1.12.5` | `474013238625.dkr.ecr.us-east-1.amazonaws.com/kyverno/background-controller:v1.12.5` |
| `ghcr.io/kyverno/cleanup-controller:v1.12.5` | `474013238625.dkr.ecr.us-east-1.amazonaws.com/kyverno/cleanup-controller:v1.12.5` |
| `ghcr.io/kyverno/reports-controller:v1.12.5` | `474013238625.dkr.ecr.us-east-1.amazonaws.com/kyverno/reports-controller:v1.12.5` |
| `registry.k8s.io/metrics-server/metrics-server` | `474013238625.dkr.ecr.us-east-1.amazonaws.com/metrics-server/metrics-server` |
| `quay.io/prometheus/prometheus` | `474013238625.dkr.ecr.us-east-1.amazonaws.com/prometheus/prometheus` |
| `quay.io/prometheus/alertmanager` | `474013238625.dkr.ecr.us-east-1.amazonaws.com/prometheus/alertmanager` |
| `grafana/grafana` | `474013238625.dkr.ecr.us-east-1.amazonaws.com/grafana/grafana` |
| `amazon/aws-load-balancer-controller` | `474013238625.dkr.ecr.us-east-1.amazonaws.com/amazon/aws-load-balancer-controller` |

### 7.2. Script Mirror
```bash
# infra/scripts/mirror-operator-images.sh
# Chạy bởi GitHub Actions khi có image mới cần mirror
REGISTRY="474013238625.dkr.ecr.us-east-1.amazonaws.com"
aws ecr get-login-password | docker login --username AWS --password-stdin $REGISTRY
docker pull <source-image>
docker tag <source-image> $REGISTRY/<dest-image>
docker push $REGISTRY/<dest-image>
```

---

## 8. Tên Tài Nguyên Bắt Buộc (Strict Name Registry)

> **NGHIÊM CẤM** đổi tên các tài nguyên dưới đây. IAM policies của ai-engine được hardcode theo tên này.

### AWS Resources
| Tài nguyên | Tên bắt buộc |
|------------|-------------|
| S3 State + Audit Bucket | `tf-3-aiops-audit-trail` |
| DynamoDB Lock | `tf-3-aiops-idempotency-lock` |
| EKS Cluster | `tf3-cdo1-sandbox-eks` |
| KMS (Infra) | `alias/cdo-infra-kms` |
| KMS (Observability) | `alias/cdo-observability-kms` |
| KMS (Audit) | `alias/cdo-audit-kms` |
| KMS (Secrets) | `alias/cdo-secrets-kms` |
| KMS (App Data) | `alias/cdo-app-data-kms` |
| SG ALB | `sg-alb-internal` |
| SG EKS Workload | `sg-eks-workload` |
| SG EKS Control Plane | `sg-eks-control-plane` |
| SG RDS | `sg-rds` |
| SG VPC Endpoints | `sg-vpc-endpoint` |

### Kubernetes Resources
| Tài nguyên | Tên bắt buộc |
|------------|-------------|
| Self-Heal Namespace | `self-heal-system` |
| Tenant 1 Namespace | `tenant-payment` |
| Tenant 1 UUID | `d3b07384-d113-495f-9f58-20d18d357d75` |
| Tenant 2 Namespace | `tenant-checkout` |
| Tenant 2 UUID | `6c8b4b2b-4d45-4209-a1b4-4b532d56a31c` |

### Terraform Module Outputs (không được đổi tên)
| Module | Outputs |
|--------|---------|
| `networking` | `vpc_id`, `vpc_cidr`, `private_subnet_ids`, `public_subnet_ids` |
| `security` | `sg_eks_workload_id`, `sg_eks_control_plane_id`, `sg_alb_internal_id`, `sg_rds_id`, `sg_vpc_endpoint_id`, `kms_infra_arn`, `kms_observability_arn` |
| `eks` | `cluster_name`, `cluster_endpoint`, `cluster_ca_data`, `oidc_provider_arn` |
| `karpenter` | `node_iam_role_arn` |
| `ingress` | `alb_dns_name` |
| `observability` | `grafana_service_name` |

---

## 9. Quy Tắc Vận Hành

### 9.1. Lệnh Kiểm Tra Nhanh
```bash
# Check tất cả pods
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# Check nodes
kubectl get nodes -o custom-columns="NODE:.metadata.name,INSTANCE:.metadata.labels.node\.kubernetes\.io/instance-type,MAX-PODS:.status.allocatable.pods"

# Check ArgoCD apps
kubectl get applications -n argocd -o custom-columns="NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status"

# Check Kyverno policies
kubectl get clusterpolicies

# Check External Secrets
kubectl get externalsecrets -A
```

### 9.2. Quy Tắc Bắt Buộc
- **KHÔNG** chạy `terraform apply` local trên `environments/sandbox/foundation` — chỉ qua CI/CD
- **KHÔNG** commit, push, merge PR, hoặc thay đổi remote repo nếu không có lệnh của Tech Lead
- **KHÔNG** gọi `gateway restart` hay `openclaw gateway restart` nếu không có lệnh
- **KHÔNG** print, log, commit credentials, tokens, private keys, hoặc giá trị `.env`
- **KHÔNG** thay đổi tên tài nguyên trong phần "Strict Name Registry" ở trên
- **LUÔN** chạy `terraform fmt` + `terraform validate` trước khi commit
- **LUÔN** chạy `terraform plan` và review output trước khi `apply`

### 9.3. Provider Versions Bắt Buộc
```hcl
terraform >= 1.7.0
hashicorp/aws ~> 5.60
hashicorp/kubernetes ~> 2.31
hashicorp/helm ~> 2.14
```

---

## 10. Troubleshooting Nhanh

| Triệu chứng | Nguyên nhân | Fix |
|-------------|-------------|-----|
| Pod `ImagePullBackOff` | Image chưa mirror vào ECR | Thêm vào `mirror-list.txt`, chạy mirror pipeline |
| Pod `Pending` - `Too many pods` | Node hết slot IP/pods | Nâng instance type hoặc scale thêm nodes |
| Pod `Pending` - `Insufficient memory/cpu` | Node hết tài nguyên | Giảm requests hoặc thêm node |
| Terraform `state lock` | Apply bị kill giữa chừng | `terraform force-unlock <lock-id>` |
| Helm `another operation in progress` | Helm release kẹt `pending-upgrade` | Xóa secret `sh.helm.release.v1.<name>.v<N>` trong namespace |
| ArgoCD `OutOfSync` | Manifest Git ≠ Cluster | Kiểm tra diff, fix code, push lại |
| Kyverno block patch | Patch sai field không được phép | Chỉ patch `spec.replicas` hoặc `resources.limits` |
| SQS Worker không nhận messages | IRSA role sai hoặc VPC endpoint SQS down | Check IRSA annotation + `kubectl describe pod sqs-worker` |

---

*Tài liệu này được tạo tự động từ source code thực tế ngày 2026-07-01.*  
*Để cập nhật: chỉnh sửa file và commit vào nhánh `main`.*
