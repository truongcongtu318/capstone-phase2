# Infrastructure Design - Task force 3 · CDO 1

<!-- Doc owner: <Nhóm CDO>
     Status: Draft (W11 T3-T4) → Final (W11 T6 Pack #1) → Updated (W12 T4 Pack #2)
     Word target: 1500-2500 từ
     Tier: Medium -->

## 1. Architecture diagram

<!-- Mermaid diagram thể hiện VPC layout, EKS cluster, subnets, data flow -->

*Caption: <giải thích flow + tại sao layout này>*

## 2. Component table

| Component | AWS Service | Reason | Cost note |
|---|---|---|---|
| Compute (EKS Control Plane) | Amazon EKS v1.28 | K8s native để mô phỏng chính xác môi trường production của client (200+ microservices trên EKS). Hỗ trợ GitOps, IRSA, và K8s API patching native. | $73/month (fixed) |
| Node Autoscaling | Karpenter (không dùng Cluster Autoscaler) | Karpenter scale nhanh hơn 6-10x so với Cluster Autoscaler (không cần chờ ASG warm up). Hỗ trợ Spot instance consolidation tối ưu chi phí sandbox. | ~$50/month (Spot `t3.medium` $0.023/hr x 3 node) |
| API Ingress | Application Load Balancer (ALB) | Tiếp nhận HTTP alerts từ AlertManager, hỗ trợ routing theo path và authentication. | $22.5/month + LCU |
| Database (Sandbox) | RDS PostgreSQL Single-AZ (`db.t3.micro`) | Lưu cấu hình hệ thống và dữ liệu phụ trợ của sandbox. Dùng phiên bản nhỏ nhất Single-AZ để tối ưu chi phí (Production target sẽ dùng RDS Aurora Multi-AZ). | ~$15/month |
| State Machine | DynamoDB (On-Demand) | Lưu trạng thái từng sự cố (Triggered -> Deciding -> Executing -> Verifying -> Done). TTL tự động giải phóng lock nếu controller crash. | On-Demand, ~$2/month |
| Audit Storage | Amazon S3 + Object Lock (COMPLIANCE mode) | Nguồn kiểm toán bất biến duy nhất (Single Source of Truth) cho SOC2. Compliance mode ngăn mọi xóa/sửa kể cả root account. | $0.023/GB-month |
| Audit Streaming | Kinesis Firehose | Stream audit events từ Controller vào S3 ngay lập tức mà không qua Git. Đảm bảo Raw Webhook Event + AI Decision JSON + Pre/Post K8s State đều được lưu. | $0.029/GB |
| Secrets Management | AWS Secrets Manager + ESO | Lưu credentials AI Engine, Git Deploy Key, DB creds. External Secrets Operator sync vào K8s Secret. Không dùng static env vars. | $0.40/secret-month |
| Observability | Prometheus + Grafana + CloudWatch | Prometheus thu thập K8s metrics, AlertManager kích hoạt luồng self-heal. CloudWatch cho AWS-level metrics (ALB, DynamoDB, Kinesis). | ~$8/month |

## 3. Differentiation angle deep-dive

### 3.1 Why this angle?

Nhóm chọn **GitOps Hybrid AWS & K8s Stack** vì hệ thống hơn 200 microservice có hai nhóm remediation với latency và governance requirement khác nhau. Incident ảnh hưởng trực tiếp đến người dùng được xử lý bằng Direct Patch Engine chạy trong EKS, trong khi thay đổi không khẩn cấp hoặc làm thay đổi desired state sẽ đi qua Git, Argo Workflows và ArgoCD để giữ Git là source of truth. Với mục tiêu auto-resolve tối thiểu 60%, AI chỉ đề xuất action; quyền thực thi cuối cùng vẫn bị kiểm soát bởi action allowlist, blast-radius policy, DynamoDB idempotency lock và verification rule. Mọi execution đều tạo canonical audit record trong S3 Object Lock; persistent change còn lưu Git commit SHA, ArgoCD revision và pre/post Kubernetes state để tạo tamper-evident provenance.

---

### 3.2 Vượt trội ở đâu?

**Competing angle:** AWS Serverless Orchestration — API Gateway, Step Functions và Lambda.

| Axis                                  | My number — GitOps Hybrid | Competing angle estimate — AWS Serverless |
| ------------------------------------- | ------------------------: | ----------------------------------------: |
| Cost / tenant / month                 |                **$86.78** |                                **$75.66** |
| P99 latency to emergency action start |           **≤ 15,000 ms** |                           **≤ 20,000 ms** |
| Ops overhead                          |           **2–3 hr/week** |                     **0.75–1.25 hr/week** |
| Time to onboard one tenant            |           **180–240 min** |                           **240–360 min** |

#### Cost assumptions

* Region: `us-east-1`.
* 730 hours/month.
* Hai tenant trong sandbox.
* Trung bình ba `t3.medium` Spot node hoạt động liên tục.
* Spot price assumption do Task 1 cung cấp: `$0.023/node-hour`.
* ALB sử dụng trung bình một LCU.
* 10 GB audit data/tháng.
* Sáu Secrets Manager secrets.
* Observability low-volume estimate: `$8/month`.
* Chưa gồm NAT Gateway, EBS volumes, RDS storage/backups, KMS requests, data transfer và support plan.

#### GitOps Hybrid calculation

| Component                     |  Monthly estimate |
| ----------------------------- | ----------------: |
| EKS control plane             |            $73.00 |
| 3 Spot `t3.medium` nodes      |            $50.37 |
| ALB base + 1 average LCU      |            $22.27 |
| RDS PostgreSQL Single-AZ      |            $15.00 |
| DynamoDB On-Demand            |             $2.00 |
| S3 audit storage — 10 GB      |             $0.23 |
| Data Firehose — 10 GB         |             $0.29 |
| Secrets Manager — 6 secrets   |             $2.40 |
| Prometheus/Grafana/CloudWatch |             $8.00 |
| **Total sandbox**             | **$173.56/month** |
| **Cost per tenant**           |  **$86.78/month** |

Node calculation:

```text
3 nodes × $0.023/hour × 730 hours
= $50.37/month
```

ALB calculation:

```text
Base:
$0.0225/hour × 730
= $16.43/month

1 average LCU:
$0.008/LCU-hour × 730
= $5.84/month

Total ALB:
$16.43 + $5.84
= $22.27/month
```

Audit calculation:

```text
S3:
10 GB × $0.023
= $0.23/month

Firehose:
10 GB × $0.029
= $0.29/month
```

Total per tenant:

```text
$173.56 / 2 tenants
= $86.78/tenant/month
```

#### Competing serverless estimate

Để so sánh công bằng, competing angle vẫn giữ các thành phần chung:

* EKS và Karpenter-managed workload nodes;
* RDS PostgreSQL;
* DynamoDB;
* S3 Object Lock;
* Data Firehose;
* Secrets Manager;
* Prometheus/Grafana/CloudWatch.

Các thành phần được thay đổi:

```text
FastAPI Receiver + Internal ALB
→ API Gateway

Argo Workflows orchestration
→ Step Functions

In-cluster workflow tasks
→ Lambda
```

Với 400 incident/tháng và 60% auto-resolve:

```text
240 auto-resolved × 14 transitions = 3,360
160 escalated × 8 transitions      = 1,280

Total = 4,640 transitions/month
```

Sau free tier, Step Functions cost được ước tính khoảng:

```text
(4,640 − 4,000) × $0.000025
= $0.016/month
```

Ở traffic sandbox, API Gateway và Lambda request/compute cost được làm tròn thành khoảng `$0.02/month`.

| Component                         |  Monthly estimate |
| --------------------------------- | ----------------: |
| EKS control plane                 |            $73.00 |
| 3 Spot `t3.medium` nodes          |            $50.37 |
| RDS PostgreSQL                    |            $15.00 |
| DynamoDB                          |             $2.00 |
| S3 audit storage                  |             $0.23 |
| Data Firehose                     |             $0.29 |
| Secrets Manager                   |             $2.40 |
| Observability                     |             $8.00 |
| Step Functions/Lambda/API Gateway |             $0.02 |
| **Total sandbox**                 | **$151.31/month** |
| **Cost per tenant**               |  **$75.66/month** |

#### P99 latency estimate

GitOps Hybrid emergency path:

```text
ALB routing                         ~100–300 ms
Receiver validation                ~100 ms
AI /detect + /decide               ≤800 ms
DynamoDB lock + policy checks      ~100–300 ms
In-cluster Kubernetes API patch    ~500–2,000 ms
Scheduling/network safety margin   remaining budget

P99 design target                  ≤15,000 ms
```

Serverless competing path:

```text
API Gateway
→ Lambda cold/warm invocation
→ Step Functions transitions
→ external authentication/network path to EKS
```

Do đó P99 design estimate được đặt ở `≤20,000 ms`.

Hai con số này đo từ lúc nhận alert đến lúc **bắt đầu action**, không phải đến lúc service được xác nhận hoàn toàn healthy. Pod rollout và verification window được đo riêng.

#### Ops overhead estimate

GitOps Hybrid cần khoảng `2–3 hr/week` để:

* kiểm tra Argo Workflows controller;
* theo dõi FastAPI Receiver và AlertManager integration;
* review WorkflowTemplate;
* review Karpenter NodePool/EC2NodeClass;
* kiểm tra Spot interruption và node consolidation;
* kiểm tra RBAC, ESO và DynamoDB stale lock;
* replay workflow thất bại.

Serverless angle cần khoảng `0.75–1.25 hr/week` để:

* kiểm tra failed Step Functions executions;
* review DLQ và CloudWatch alarms;
* cập nhật Lambda dependencies;
* kiểm tra IAM policy và API Gateway authentication.

#### Tenant onboarding estimate

GitOps Hybrid:

```text
Namespace, quota và RBAC                 30–45 min
Git path và ArgoCD Application           30–45 min
Secrets Manager + ESO mapping            20–30 min
Alert rules và workflow parameters       45–60 min
Audit, lock và remediation smoke test    45–60 min

Total                                    180–240 min
```

Serverless competing angle:

```text
Tenant configuration                     30–45 min
API Gateway/auth configuration           30–45 min
State machine and Lambda parameters       45–60 min
IAM role + EKS access/RBAC mapping        60–90 min
End-to-end remediation and audit test     75–120 min

Total                                     240–360 min
```

---

### 3.3 Weakness chấp nhận

#### Trade-off 1 — Chi phí cao hơn serverless

GitOps Hybrid có chi phí cao hơn:

```text
$86.78 − $75.66
= $11.12/tenant/month
```

Tương đương:

```text
$11.12 / $75.66 × 100
≈ 14.7%
```

Nhóm chấp nhận mức chênh lệch này để emergency remediation sử dụng in-cluster Kubernetes ServiceAccount/RBAC, giảm external-to-EKS execution path và giữ Argo Workflows, ArgoCD, Kubernetes event cùng một operational boundary.

**Mitigation:** ALB chỉ được giữ nếu AlertManager hoặc alert source nằm ngoài cluster. Nếu AlertManager chạy trong cùng EKS, Receiver sẽ dùng ClusterIP nội bộ và có thể loại bỏ khoảng `$22.27/month`, khiến Hybrid cost giảm xuống khoảng `$75.64/tenant/month`, gần tương đương competing angle.

#### Trade-off 2 — Tăng operational complexity và Spot interruption risk

Hybrid yêu cầu nhóm tự vận hành Argo Workflows, FastAPI Receiver, Karpenter, Kubernetes RBAC và node capacity. Việc dùng Spot node giúp giảm chi phí nhưng có nguy cơ interruption hoặc thiếu capacity đúng lúc workflow cần chạy.

**Mitigation:** duy trì một baseline On-Demand NodePool cho ArgoCD, Receiver, Argo Workflows controller và các platform component; Spot NodePool chỉ dùng cho application workloads và short-lived workflow pods. Karpenter NodePool phải cho phép nhiều instance family/type, sử dụng PodDisruptionBudget, topology spread và interruption handling để tránh phụ thuộc một loại Spot capacity duy nhất.


## 4. Multi-tenant approach

### 4.1. Mô hình định danh tenant

Trong hệ thống Self-Heal Platform, một tenant được định nghĩa là một khách hàng hoặc một team sở hữu một nhóm microservice chạy trên Kubernetes. 

Trong phạm vi capstone demo, hệ thống sẽ triển khai tối thiểu 2 tenant chạy song song nhằm chứng minh khả năng cách ly dữ liệu và phân quyền thực thi chặt chẽ:

| Tenant ID | Namespace | Service Demo | Subscription Tier |
| :--- | :--- | :--- | :--- |
| `tnt-payment-demo` | `tenant-payment` | `payment-api` | **Pro** |
| `tnt-checkout-demo` | `tenant-checkout` | `checkout-api` | **Basic** |

Mỗi tenant có một mã định danh duy nhất là `tenant_id`. Mọi request, alert signal, telemetry package, remediation action và audit log đều bắt buộc phải gắn kèm `tenant_id`. Nhờ đó, hệ thống luôn xác định chính xác ngữ cảnh: incident này thuộc về ai, policy nào cần được áp dụng, và giới hạn tài nguyên tương ứng là bao nhiêu.

#### Xác thực và Validate Tenant Context

Mọi alert gửi từ Prometheus Alertmanager vào Webhook Receiver đều phải đính kèm header:
```http
X-Tenant-Id: <tenant_id>
```

Tuy nhiên, hệ thống áp dụng nguyên tắc **Zero Trust** và không tin cậy header này một cách vô điều kiện. Trước khi bất kỳ alert nào được đưa vào xử lý, Webhook Receiver sẽ thực hiện validate ngữ cảnh thông qua FastAPI Middleware.

```mermaid
flowchart TD
    Req[Request Alert đi vào Internal ALB] --> MW[FastAPI Middleware đọc header X-Tenant-Id]
    MW --> Lookup[Lookup Registry trong DynamoDB / Namespace Label]
    Lookup --> CheckNamespace{tenant_id có khớp với
namespace & service?}
    CheckNamespace -- Không khớp (Mismatch) --> Deny[Trả về 403 Forbidden
Ghi Audit Event SECURITY_VIOLATION]
    CheckNamespace -- Khớp (Match) --> CheckPolicy{Tenant có policy cho
action đề xuất không?}
    CheckPolicy -- Không có policy --> Deny
    CheckPolicy -- Hợp lệ (Allow) --> Process[Cho request đi tiếp vào Webhook Receiver]
```

##### Ví dụ Request Không Hợp Lệ:
* **Header**: `X-Tenant-Id: tnt-payment-demo`
* **Target Namespace**: `tenant-checkout`

*Hành vi chặn request*: Do `tnt-payment-demo` không được phép thao tác trên namespace `tenant-checkout`, request sẽ lập tức bị chặn tại Middleware:

**Response (403 Forbidden)**:
```json
{
  "error": "TENANT_NAMESPACE_MISMATCH",
  "message": "Tenant is not allowed to operate on the requested namespace."
}
```

**Audit Log tương ứng (S3 Object Lock)**:
```json
{
  "event_type": "SECURITY_VIOLATION",
  "reason": "TENANT_NAMESPACE_MISMATCH",
  "tenant_id": "tnt-payment-demo",
  "requested_namespace": "tenant-checkout",
  "decision": "DENY"
}
```

#### Tầng Dịch Vụ (Subscription Tiers)

Hệ thống hỗ trợ 3 tier dịch vụ với các đặc quyền và giới hạn tài nguyên khác nhau:

| Tier | Mục đích | Đặc quyền & Giới hạn (Blast Radius) |
| :--- | :--- | :--- |
| **Basic** | Môi trường test, dev hoặc các dịch vụ không quan trọng | Quota thấp, cooldown duration lâu, ít tùy biến policy |
| **Pro** | Các microservice production thông thường | Quota trung bình, remediation tiêu chuẩn, hỗ trợ cấu hình cooldown ngắn hơn |
| **Enterprise** | Các dịch vụ lõi cực kỳ quan trọng | Quota cao, audit logs được kiểm soát chặt chẽ, custom policy linh hoạt |

---

### 4.2. Cách tách biệt dữ liệu và quyền giữa các tenant

Nhóm thiết kế quyết định chọn mô hình **Bridge Isolation** làm kiến trúc cốt lõi.

> [!IMPORTANT]
> **Bridge Isolation**: Toàn bộ hạ tầng dữ liệu (DynamoDB, SQS, S3) được dùng chung để tối ưu hóa chi phí vận hành và tài nguyên. Tuy nhiên, dữ liệu của mỗi tenant được phân vùng logic (partitioned) nghiêm ngặt bằng `tenant_id`. Ngược lại, quyền thực thi ở compute layer (Kubernetes, GitOps) được cách ly logic và enforce bằng Namespaces, RBAC, ArgoCD Applications và ArgoCD AppProjects.

#### So sánh các mô hình cách ly:

| Mô hình | Cơ chế hoạt động | Ưu điểm | Nhược điểm | Chọn |
| :--- | :--- | :--- | :--- | :---: |
| **Silo Isolation** | Mỗi tenant sở hữu database, queue, bucket và compute riêng biệt | Bảo mật tuyệt đối, không lo Noisy Neighbor | Chi phí hạ tầng cực lớn, quản lý phức tạp, không phù hợp cho sandbox | ❌ |
| **Pool Isolation** | Dùng chung toàn bộ hạ tầng từ compute tới database, chỉ lọc bằng tenant_id trong code | Chi phí rẻ nhất, triển khai cực nhanh | Rủi ro rò rỉ dữ liệu cao nếu logic filter trong code có lỗi | ❌ |
| **Bridge Isolation** | Dùng chung data layer (phân vùng bằng key) nhưng tách biệt compute layer (namespace/RBAC/GitOps) | Cân bằng hoàn hảo giữa chi phí tối ưu và tính an toàn bảo mật | Đòi hỏi kiểm tra tenant context và policy cực kỳ chặt chẽ | ✅ |

---

#### 4.2.1. Data isolation

Mặc dù sử dụng chung các dịch vụ lưu trữ dữ liệu để tiết kiệm chi phí, hệ thống thực thi các cơ chế phân cách sau:

##### 1. DynamoDB (Incident State & Locks)
DynamoDB lưu trữ thông tin vòng đời sự cố, idempotency locks và registry. Dữ liệu được cách ly logic bằng cách thiết kế khóa chính (Primary Key) chứa tiền tố `tenant_id`:
* **Incident State Key**: `PK = <tenant_id>#<incident_id>`
  * *Ví dụ*: `tnt-payment-demo#inc-001`
* **Idempotency Lock Key**: `lock_key = <tenant_id>#<namespace>#<service>#<alert_name>#<action_type>`
  * *Ví dụ*: `tnt-payment-demo#tenant-payment#payment-api#CrashLoopBackOff#RESTART_DEPLOYMENT`

##### 2. S3 Audit Log (Immutable Logs)
Toàn bộ log kiểm toán sự cố được đẩy về một S3 Bucket chung, tuy nhiên mỗi tenant sẽ ghi log vào một folder prefix riêng biệt. Cấu trúc path được định nghĩa như sau:
```
s3://selfheal-audit/<tenant_id>/<yyyy>/<mm>/<dd>/<incident_id>.json
```
* *Ví dụ*: `s3://selfheal-audit/tnt-payment-demo/2026/06/23/inc-001.json`

Cơ chế này giúp tách biệt dữ liệu hoàn toàn, đồng thời cho phép Amazon Athena phân vùng dữ liệu (Partition Projection) theo `tenant_id` để tăng tốc độ truy vấn và kiểm toán.

##### 3. SQS (Event Broker Queue)
SQS queue dùng chung để giảm chi phí queue. Tuy nhiên, để đảm bảo tính cô lập:
* **Message Attributes**: Mọi message gửi vào SQS bắt buộc phải đính kèm metadata của tenant trong `MessageAttributes` (bao gồm `tenant_id`, `incident_id`, `severity`, `action_type`).
* **Message Body**: Chứa payload chi tiết để xử lý.

```json
// Ví dụ Message Attributes gửi vào SQS:
{
  "tenant_id": { "DataType": "String", "StringValue": "tnt-payment-demo" },
  "incident_id": { "DataType": "String", "StringValue": "inc-001" },
  "action_type": { "DataType": "String", "StringValue": "RESTART_DEPLOYMENT" }
}
```
*Lý do tách Message Attributes*: Giúp các Worker nhanh chóng kiểm tra quyền sở hữu và route message mà không cần deserialize toàn bộ payload body, đồng thời hỗ trợ debug trên Dead Letter Queue (DLQ) dễ dàng hơn.

---

#### 4.2.2. Execution isolation

Hệ thống có hai luồng xử lý sự cố (Dual Execution Path), do đó quyền thực thi được thiết kế cô lập cho từng luồng:

```mermaid
flowchart TD
    subgraph Direct Patch Path [Luồng Direct Patch (Khẩn cấp)]
        WebhookA[Webhook Receiver] --> GuardA[Policy Guardrail]
        GuardA --> EngineA[Direct Patch Engine]
        EngineA -->|K8s API Patch| K8s[Kubernetes API]
        K8s --> RBAC{K8s Namespace RBAC}
        RBAC -- Hợp lệ --> Execute[Execute Action]
        RBAC -- Không hợp lệ --> Block[Block & Audit]
    end

    subgraph GitOps Path [Luồng GitOps (Thông thường)]
        WebhookB[Webhook Receiver] --> Workflow[Argo Workflows]
        Workflow --> CommitEngine[Git Commit Engine]
        CommitEngine -->|Commit manifests| GitRepo[GitHub GitOps Repo]
        GitRepo --> ArgoCD[ArgoCD Sync]
        ArgoCD --> AppProj{ArgoCD AppProject
Destinations Limit}
        AppProj -- Đúng Namespace --> Apply[Sync Workload]
        AppProj -- Sai Namespace --> Reject[Reject Sync & Alert]
    end
```

##### 1. Path 1: Direct Patch path (Xử lý nóng khẩn cấp)
Direct Patch Engine chạy cùng Pod với Webhook Receiver trong namespace `self-heal-system` và sử dụng `load_incluster_config()`. 

Để tránh việc Engine lạm dụng quyền hạn hoặc vô tình can thiệp chéo sang tenant khác, hệ thống không cấp quyền Cluster-wide. Thay vào đó, ServiceAccount thực thi được phân quyền cục bộ bằng **RoleBinding** tại từng namespace của tenant:
* **ServiceAccount**: `selfheal-executor` (nằm tại namespace `self-heal-system`)
* **RoleBinding (tại namespace `tenant-payment`)**: Liên kết `selfheal-executor` với Role `patch-deployments`.
* **RoleBinding (tại namespace `tenant-checkout`)**: Liên kết `selfheal-executor` với Role `patch-deployments`.

**Bảng phân quyền thực thi của Direct Patch Engine:**

| Quyền được phép (Allowed) | Quyền bị chặn hoàn toàn (Blocked) |
| :--- | :--- |
| `get`/`list`/`watch` Pods, Events, Deployments trong namespace của tenant | Truy cập namespace hệ thống (`kube-system`, `argocd`, `self-heal-system`) |
| `patch` Deployment & StatefulSet trong namespace được bind | Xóa Namespace (`delete namespace`) |
| `restart` Workload trong namespace của tenant | Sửa đổi hoặc tạo mới `ClusterRole` / `ClusterRoleBinding` |
| | Tác động sang namespace của tenant khác |

##### 2. Path 2: GitOps path (Thay đổi lâu dài / Auto-scaling)
Để tránh cấu hình sai hoặc tấn công leo thang đặc quyền qua GitOps, cấu trúc Git và ArgoCD được thiết kế độc lập hoàn toàn:

* **Phân vùng cấu trúc thư mục Git**:
  ```bash
  gitops-state/
  └── tenants/
      ├── tnt-payment-demo/
      │   └── manifests/
      └── tnt-checkout-demo/
          └── manifests/
  ```
* **ArgoCD Application riêng biệt**: Mỗi tenant sở hữu một thực thể ArgoCD Application riêng (`selfheal-tnt-payment-demo`, `selfheal-tnt-checkout-demo`).
* **ArgoCD AppProject**: Để triệt tiêu rủi ro ArgoCD sync nhầm manifest của tenant này sang namespace tenant khác, mỗi tenant được gắn với một `AppProject` quy định cứng target namespace.

*Ví dụ cấu hình AppProject cho `tnt-payment-demo`:*
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: selfheal-payment
  namespace: argocd
spec:
  sourceRepos:
    - https://github.com/my-org/gitops-state.git
  destinations:
    - namespace: tenant-payment
      server: https://kubernetes.default.svc
```
> [!TIP]
> Nhờ cấu hình `destinations` giới hạn cứng tại AppProject, ngay cả khi Git Commit Engine commit nhầm manifest của `tnt-payment-demo` với target namespace là `tenant-checkout`, ArgoCD sẽ lập tức từ chối đồng bộ (Out-of-Sync/Permission Denied) ở mức độ hạ tầng.

---

### 4.3. Quy trình thêm tenant mới (Onboarding Flow)

Khi có một tenant mới tham gia hệ thống Self-Heal Platform, quy trình onboarding tự động gồm 5 bước sau sẽ được kích hoạt để đảm bảo tính nhất quán và an toàn:

```mermaid
graph TD
    Step1[Bước 1: Đăng ký registry thông tin tenant] --> Step2[Bước 2: Provision Namespace & Gắn Labels]
    Step2 --> Step3[Bước 3: Cấu hình RBAC & Tenant Policy]
    Step3 --> Step4[Bước 4: Thiết lập Git Thư mục & ArgoCD AppProject]
    Step4 --> Step5[Bước 5: Chạy Smoke Test tự động]
    Step5 --> Active[Tenant chuyển sang trạng thái ACTIVE]
```

#### Chi tiết các bước onboarding:

##### Bước 1: Đăng ký thông tin Tenant (Register Registry)
Platform Admin đăng ký thông tin tenant vào DynamoDB registry table `tenant_registry`:
```json
{
  "tenant_id": "tnt-payment-demo",
  "tenant_name": "Payment Service Team",
  "tier": "pro",
  "namespace": "tenant-payment",
  "status": "PENDING"
}
```

##### Bước 2: Tạo Kubernetes Namespace và Labels
Terraform hoặc GitOps Controller provision namespace cho tenant với các labels quy chuẩn:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-payment
  labels:
    tenant_id: tnt-payment-demo
    tier: pro
    selfheal/enabled: "true"
```
*Các labels này giúp hệ thống tự động filter, validate request và áp dụng policy tương ứng.*

##### Bước 3: Tạo RBAC và Tenant Policy
Tạo Role, RoleBinding cho remediation executor (`selfheal-executor`) tại namespace mới và định nghĩa policy giới hạn trong registry:
```yaml
tenant_id: tnt-payment-demo
namespace: tenant-payment
allowed_actions:
  - RESTART_DEPLOYMENT
  - SCALE_UP_PODS
blocked_actions:
  - DELETE_NAMESPACE
  - ACCESS_KUBE_SYSTEM
limits:
  max_scale_multiplier: 2
  cooldown_minutes: 5
```

##### Bước 4: Tạo thư mục Git và ArgoCD AppProject
* Tạo thư mục `gitops-state/tenants/tnt-payment-demo/`.
* Khởi tạo ArgoCD `AppProject` giới hạn quyền deploy chỉ trong namespace `tenant-payment`.
* Khởi tạo ArgoCD `Application` liên kết thư mục Git với namespace tương ứng.

##### Bước 5: Chạy Smoke Test tự động
Trước khi chuyển trạng thái sang `ACTIVE`, hệ thống kích hoạt bộ smoke test tự động để xác minh:
1. Gửi alert giả lập đúng `tenant_id` và `namespace`  →  Expect: `ACCEPTED` (202).
2. Gửi alert giả lập sai `namespace`  →  Expect: `403 TENANT_NAMESPACE_MISMATCH`.
3. Yêu cầu restart workload trong namespace tenant  →  Expect: `ALLOWED` và thực thi thành công.
4. Yêu cầu restart workload sang namespace tenant khác  →  Expect: `DENIED` từ RBAC.
5. Kiểm tra audit log được ghi nhận đúng prefix trên S3 bucket.

*Chỉ khi 5 smoke test trên pass hoàn toàn, trạng thái tenant trong DynamoDB mới được chuyển thành `ACTIVE`.*

---

### 4.4. Chống một tenant chiếm hết tài nguyên (Noisy Neighbor Mitigation)

Trong mô hình multi-tenant dùng chung tài nguyên hạ tầng, hiện tượng **Noisy Neighbor** (một tenant gặp sự cố liên tục phát sinh hàng ngàn alert spam làm nghẽn hệ thống, khiến alert của các tenant khác bị chậm trễ) là cực kỳ nguy hiểm. 

Để giải quyết triệt để vấn đề này, Self-Heal Platform triển khai **5 cơ chế phòng vệ** độc lập:

```
[Request Alert] 
      │
      ├──> (1) Rate Limiting (FastAPI Middleware + DynamoDB Token Bucket)
      │
      ├──> (2) Idempotency Lock & Cooldown (DynamoDB Conditional Write)
      │
      ├──> (3) Concurrency Limit (asyncio Semaphores & Argo Workflows Semaphore)
      │
      ├──> (4) ResourceQuota & LimitRange (Kubernetes Namespace Hard Limits)
      │
      └──> (5) Blast-Radius Controls (Action Block Policy)
```

---

#### 4.4.1. Per-tenant rate limit

Hệ thống quy định quota số sự cố (incident) tối đa được xử lý trong mỗi phút dựa trên tier của tenant:

| Tier | Incident/Phút | Concurrent Remediation | Cooldown Duration |
| :--- | :---: | :---: | :---: |
| **Basic** | 10 | 2 | 10 phút |
| **Pro** | 30 | 5 | 5 phút |
| **Enterprise** | 60 | 10 | 2 phút |

Do Webhook Receiver tiếp nhận request trực tiếp từ Internal ALB (không qua API Gateway), cơ chế rate limit được viết trực tiếp tại FastAPI Middleware sử dụng thuật toán **DynamoDB Token Bucket**:
* **Table**: `tenant_rate_limits`
* **Schema**: `PK = tenant_id`, `SK = window_timestamp` (lưu count, quota, ttl).

##### Luồng xử lý Rate Limit:
FastAPI Middleware tăng biến đếm counter trong DynamoDB ứng với window 60s hiện tại. Nếu vượt quá quota cho phép của tier, request bị từ chối ngay lập tức:
* **HTTP Response**: `429 Too Many Requests` (Header: `Retry-After: 30`)
* **Audit Event**:
  ```json
  {
    "event_type": "RATE_LIMITED",
    "tenant_id": "tnt-checkout-demo",
    "tier": "basic",
    "quota": "10 incidents/minute",
    "decision": "DENY"
  }
  ```

---

#### 4.4.2. Idempotency lock và cooldown

Để ngăn chặn việc Alertmanager liên tục gửi các cảnh báo trùng lặp (ví dụ: pod bị CrashLoopBackOff liên tục) dẫn đến việc platform thực hiện restart workload lặp đi lặp lại vô ích, hệ thống áp dụng **Idempotency Lock** qua DynamoDB Conditional Write.

* Khóa Lock được thiết lập dựa trên: `tenant_id#namespace#service#alert_name#action_type`
* Khi nhận alert, hệ thống cố gắng tạo lock ghi nhận thời gian bắt đầu.
* Nếu lock đã tồn tại và cooldown window chưa kết thúc, hành động tự vá lỗi mới cho alert đó sẽ bị bỏ qua và đánh dấu trạng thái là `SUPPRESSED_DUPLICATE`.

**Audit log cho sự kiện bị duplicate:**
```json
{
  "event_type": "SUPPRESSED_DUPLICATE",
  "tenant_id": "tnt-payment-demo",
  "service": "payment-api",
  "action_type": "RESTART_DEPLOYMENT",
  "reason": "Existing cooldown lock is still active."
}
```

---

#### 4.4.3. Per-tenant concurrency limit

Hệ thống giới hạn số lượng tiến trình vá lỗi đang chạy đồng thời (in-flight remediation) của mỗi tenant để tránh quá tải cho Kubernetes API và AI Engine:
* **Direct Patch path**: FastAPI Webhook Receiver quản lý thông qua process-level `asyncio.Semaphore` dựa trên tier (Basic: 2, Pro: 5, Enterprise: 10).
* **GitOps path**: Sử dụng cơ chế semaphore cấp độ workflow của Argo Workflows để cấu hình số lượng workflow chạy đồng thời tối đa của từng tenant.

If vượt quá giới hạn concurrent, incident mới sẽ được đưa vào hàng đợi hoặc đánh dấu `TENANT_CONCURRENCY_LIMITED` kèm theo audit event:
```json
{
  "event_type": "TENANT_CONCURRENCY_LIMITED",
  "tenant_id": "tnt-payment-demo",
  "limit": 5,
  "decision": "DELAY"
}
```

---

#### 4.4.4. ResourceQuota trong namespace

Mỗi tenant được giới hạn tài nguyên tính toán nghiêm ngặt ở mức Kubernetes namespace để bảo vệ cluster không bị cạn kiệt tài nguyên (CPU, Memory, Pod count).

*Ví dụ cấu hình ResourceQuota cho namespace `tenant-payment`:*
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-payment-quota
  namespace: tenant-payment
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "40"
```
> [!IMPORTANT]
> Nhờ ResourceQuota, ngay cả khi AI Engine đưa ra hành động scale up quá mức do lỗi logic, Kubernetes Scheduler sẽ từ chối tạo thêm Pod mới nếu vượt ngưỡng cứng 40 Pods, đảm bảo blast radius luôn được kiểm soát trong phạm vi của tenant đó mà không gây ảnh hưởng đến các node dùng chung của cluster.

---

#### 4.4.5. Blast-radius policy theo action

Mỗi đề xuất tự vá lỗi từ AI Engine đều phải đi qua bộ lọc **Policy Guardrail** để phân loại mức độ rủi ro và giới hạn ảnh hưởng:

| Action (Remediation) | Blast-Radius Control (Giới hạn hành vi) |
| :--- | :--- |
| `RESTART_DEPLOYMENT` | Chỉ được phép restart deployment thuộc đúng namespace của tenant |
| `SCALE_UP_PODS` | Giới hạn tối đa không tăng quá 2 lần số lượng replicas hiện tại |
| `ADJUST_MEMORY_LIMIT` | Giới hạn tăng tối đa 50% cấu hình memory limit hiện tại mỗi lần |
| `ROLLBACK_DEPLOYMENT` | Chỉ được phép rollback về phiên bản stable gần nhất |
| *Unknown Action* | Bị block lập tức và chuyển tiếp escalate cho quản trị viên |
| *Tác động kube-system* | Bị cấm tuyệt đối |

* Nếu một hành động vi phạm policy, incident sẽ chuyển sang trạng thái `BLOCKED_BY_POLICY`.
* Nếu tự vá lỗi thất bại liên tiếp hoặc không vượt qua bước verify, incident được đánh dấu `ESCALATED` và đẩy thông báo khẩn cấp qua Slack/PagerDuty.

**Ví dụ Audit Event khi Action bị Block:**
```json
{
  "event_type": "BLOCKED_BY_POLICY",
  "tenant_id": "tnt-payment-demo",
  "service": "payment-api",
  "action_type": "SCALE_UP_PODS",
  "reason": "Requested scale exceeds max_scale_multiplier=2",
  "decision": "DENY"
}
```

---

### Tóm tắt thiết kế

Nhóm thiết kế CDO-1 thống nhất áp dụng mô hình **Bridge Isolation** vì nó phản ánh chính xác cấu trúc hạ tầng đã chọn:
* Tối ưu chi phí bằng cách dùng chung Data layer (phân vùng logic qua `tenant_id` trong DynamoDB, prefix trong S3, attributes trong SQS).
* Đảm bảo an toàn vận hành bằng cách cô lập Compute/Execution layer qua Kubernetes Namespace, K8s RBAC bindings, ArgoCD AppProjects và FastAPI Middleware / process-level semaphores.

Thiết kế này vừa đáp ứng đầy đủ yêu cầu khắt khe về bảo mật dữ liệu khách hàng vừa giữ chi phí sandbox trong mức tối thiểu, đồng thời khả thi để demo trọn vẹn trong thời gian 2 tuần của Capstone project.

# 5. Alternatives Considered & Infrastructure Components

Tài liệu này phân tích các giải pháp thay thế kỹ thuật đối với từng cấu phần (service) trong hệ thống tự chữa lành thuộc dự án Capstone, đồng thời biện luận dựa trên quy mô thực tế của doanh nghiệp SaaS B2B lớn (200+ microservices, lưu trữ 12TB dữ liệu với traffic biến động cao từ 120 khách hàng doanh nghiệp).

## 5.1 Compute Layer (EKS Compute Provisioning)

* **Option A — EKS Fargate Profile:**
    * *Pros:* Mô hình Serverless hoàn toàn cho Kubernetes, loại bỏ hoàn toàn công sức vận hành, vá lỗi và quản lý EC2 node phía dưới.
    * *Cons:* Gặp **technical blocker thực sự**: Fargate không hỗ trợ triển khai `DaemonSet`. Trong khi đó, hệ thống giám sát bắt buộc phải chạy ADOT/OTel Collector dưới dạng `DaemonSet` mức node để thu thập chỉ số hạ tầng theo deployment-contract. Ngoài ra, cấu phần `ArgoCD repo-server` cần một writable local filesystem ổn định, điều thường xuyên gây friction (xung đột/lỗi gán ổ đĩa) trên Fargate. Xét góc nhìn SaaS lớn, việc chạy Fargate sẽ khiến chi phí tích lũy theo từng Pod lẻ nhảy vọt lên mức khổng lồ, không có khả năng tối ưu hóa chia sẻ tài nguyên.
    * *Estimated Cost:* ~$120–180/tháng cho workload tương đương sandbox.
* **Option B — EKS Managed Node Group + Karpenter:**
    * *Pros:* Node provisioning thông minh, tự động phân tích nhu cầu của Pod để cấp phát các node EC2 với size tối ưu nhất (bin-packing), giúp tiết kiệm chi phí biên cực tốt cho môi trường Production dài hạn.
    * *Cons:* Độ dốc học tập (learning curve) cao, tốn nhiều thời gian cấu hình và kiểm thử vận hành lớn, tạo ra rủi ro trễ hạn đối với timeline 2 tuần của dự án Capstone.
    * *Estimated Cost:* ~$90–120/tháng.
* **Option C — EKS Managed Node Group + Cluster Autoscaler:**
    * *Pros:* Công nghệ mature và phổ biến, tài liệu module EKS và Terraform module hoạt động cực kỳ ổn định. Hỗ trợ đầy đủ và native cho các `DaemonSet` mức node. Cho phép **Resource Pooling** (gom nhiều microservices nhỏ vào chung các node EC2 lớn m5.large để tối ưu hóa hiệu năng phần cứng và tiết kiệm chi phí nền).
    * *Cons:* Tốc độ scale node chậm hơn Karpenter (phải chờ AWS ASG kích hoạt) và khả năng bin-packing chưa tối ưu bằng Karpenter ở quy mô siêu lớn.
    * *Estimated Cost:* ~$96–110/tháng (02 node m5.large chạy 24/7 trong 2 tuần demo + phí EKS Control Plane).

✅ **Chosen:** Option C — EKS Managed Node Group + Cluster Autoscaler
* **Reason:** Đáp ứng đầy đủ technical constraint của ADOT DaemonSet, triển khai nhanh bằng Terraform, phù hợp ngân sách sandbox và bảo toàn năng lực gom cụm tài nguyên cho 200+ microservices của SaaS lớn. Phương án Karpenter được ghi nhận và đẩy vào "production roadmap" trong tương lai.

## 5.2 State & Idempotency Database

* **Option A — Amazon ElastiCache Redis:**
    * *Pros:* Tốc độ phản hồi cực nhanh (in-memory latency < 1ms), hỗ trợ cơ chế thiết lập TTL native để tự động xóa khóa phân tán rất tiện lợi.
    * *Cons:* Phải duy trì cụm node chạy liên tục 24/7 (phát sinh chi phí cố định ngay cả khi hệ thống hoàn toàn idle), tăng tải vận hành (ops overhead). Với bài toán SaaS lớn chạm mốc 12TB dữ liệu, việc lưu trữ lượng lớn trạng thái transaction trên RAM của Redis sẽ đẩy chi phí hạ tầng tăng lên theo cấp số nhân.
    * *Estimated Cost:* ~$15–30/tháng.
* **Option B — DynamoDB On-Demand + Conditional Write:**
    * *Pros:* Cơ chế tính phí Pay-per-request giúp tối ưu hóa chi phí về $0 khi không có traffic (idle). Tính năng `conditional write` giải quyết trực tiếp yêu cầu làm Idempotency Lock Store chống xử lý trùng lặp alert. Khả năng scale-out vô hạn về cả dung lượng và throughput, hoàn toàn đáp ứng nhu cầu tăng trưởng dữ liệu 12TB của doanh nghiệp SaaS lớn. Đồng bộ pattern xử lý dữ liệu với AI team.
    * *Cons:* Latency cao hơn Redis vài mili-giây do truy xuất qua tầng HTTPS API và phải thiết kế cấu trúc Partition Key cẩn thận từ đầu.
    * *Estimated Cost:* ~$0–5/tháng (traffic sandbox nằm hoàn toàn trong Free Tier).

✅ **Chosen:** Option B — DynamoDB On-Demand
* **Reason:** Tối ưu chi phí sandbox về mức tối thiểu, đồng thời vẫn chứng minh được khả năng scale vượt trội cho bài toán SaaS lớn. Cơ chế conditional-write giải quyết triệt để yêu cầu chống xử lý trùng lặp lệnh khi xảy ra bão alert.

## 5.3 Webhook Receiver (Entry Layer)

* **Option A — AWS API Gateway + Lambda:**
    * *Pros:* Fully managed bởi AWS, tự động scale theo traffic, mô hình chi phí pay-per-use tối ưu.
    * *Cons:* Làm phức tạp hóa ranh giới bảo mật không cần thiết. Buộc phải thiết lập thêm một chuỗi kết nối phức tạp (`IAM ↔ K8s credential bridge`) để Lambda từ ngoài gọi ngược vào EKS API Server, làm mở rộng ranh giới bảo mật (Trust Boundary).
    * *Estimated Cost:* ~$0–10/tháng.
* **Option B — FastAPI Deployment trên EKS cụm nội bộ:**
    * *Pros:* Nằm trọn vẹn trong cùng một Trust Boundary bảo mật với hệ thống tự chữa lành (namespace `self-heal-system`). Sử dụng trực tiếp ServiceAccount nội bộ cụm thông qua hàm `load_incluster_config()`, loại bỏ hoàn toàn việc expose IAM credential ra ngoài. Đồng bộ stack code FastAPI với nhóm AI.
    * *Cons:* Phải tự quản lý manifest deployment và chạy liên tục trên cluster.
    * *Estimated Cost:* $0 thêm (Tận dụng không gian Compute Headroom của EKS Node Group có sẵn ở mục 5.1).

✅ **Chosen:** Option B — FastAPI Deployment
* **Reason:** Đơn giản hóa kiến trúc bảo mật, loại bỏ hoàn toàn cơ chế credential bridging phức tạp và tận dụng tối đa hạ tầng EKS sẵn có.
  
## 5.4 Orchestrator (GitOps Path)

* **Option A — AWS Step Functions + Lambda:**
    * *Pros:* Trạng thái xử lý (state machine), cơ chế retry và timeout được build-in sẵn. Quản lý luồng trực quan trực tiếp trên AWS Console UI, chi phí pay-per-use lý tưởng.
    * *Cons:* Bộ điều phối nằm ngoài cluster, làm tăng độ phức tạp khi phân quyền chéo. Bản chất luồng GitOps xử lý lỗi Loại 2 không cần chạm trực tiếp vào EKS API mà đi qua Git repository, nên việc đưa state machine ra ngoài không mang lại lợi ích bảo mật nào thực tế.
    * *Estimated Cost:* ~$0–5/tháng.
* **Option B — Argo Workflows (Self-hosted trên K8s):**
    * *Pros:* Native Kubernetes CRD chạy ngay trong cụm, hỗ trợ xử lý luồng phức tạp dạng DAG và retry container mạnh mẽ. Giao diện UI hiển thị real-time đồng bộ trong hệ sinh thái K8s giúp demo trực quan hơn. Đội dự án đã de-risked rủi ro nhân sự khi có 01 thành viên chủ chốt có kinh nghiệm vận hành thực tế.
    * *Cons:* Phải quản lý các CRD nội bộ trong cụm K8s.
    * *Estimated Cost:* $0 thêm (Compute overhead chạy trực tiếp trên EKS Node Group sẵn có, chi phí đã được gộp trọn gói vào mục 5.1).

✅ **Chosen:** Option B — Argo Workflows
* **Reason:** Toàn bộ bộ não điều phối nằm trong cùng một Trust Boundary bảo mật với ArgoCD và Direct Patch Engine, giúp giảm độ phức tạp vận hành và tăng tính đồng bộ, thuyết phục khi demo thực tế.

## 5.5 Direct Patch Engine — Loại 1 (Khẩn Cấp / Out-of-Band)

* **Option A — AWS Lambda gọi vào EKS API:**
    * *Pros:* Tách biệt hoàn toàn khỏi lifecycle của cụm K8s, khả năng tự động scale-out độc lập khi gặp bão alert sự cố.
    * *Cons:* Tốn thêm network hop từ ngoài vào mạng nội bộ cụm EKS, cần cấu hình phân quyền IRSA phức tạp và làm tăng độ trễ (latency) xử lý hành động khẩn cấp.
    * *Estimated Cost:* ~$0–5/tháng.
* **Option B — Python kubernetes-client chạy In-Process:**
    * *Pros:* Thực hiện same-cluster API call (gọi trực tiếp trong cụm), mang lại latency thực thi cực thấp nhằm đáp ứng cam kết mốc thời gian phản hồi hành động chữa lành khẩn cấp dưới 15 giây. Triển khai cực kỳ đơn giản.
    * *Cons:* Gắn chặt vào lifecycle của Webhook Receiver pod, không thể bóc tách để scale độc lập cấu phần.
    * *Estimated Cost:* $0 thêm (Chạy chung pod với Webhook Receiver).

✅ **Chosen:** Option B — Python kubernetes-client
* **Reason:** Ưu tiên tối thượng cho tốc độ phản hồi cực thấp để xử lý các sự cố khẩn cấp (như Pod bị OOMKilled hoặc Service stuck) ở quy mô môi trường sandbox.

## 5.6 Event Queue (Telemetry Pipeline)

* **Option A — SQS FIFO (First-In-First-Out):**
    * *Pros:* Đảm bảo thứ tự tin nhắn tuyệt đối (ordering guarantee) và hỗ trợ chống trùng lặp dữ liệu ở mức hạ tầng Cloud.
    * *Cons:* Throughput bị giới hạn nghiêm ngặt (300 - 3000 msg/s), không cần thiết khi hệ thống đã được thiết kế phòng vệ nhiều lớp ở tầng trên.
    * *Estimated Cost:* ~$0–2/tháng.
* **Option B — SQS Standard Queue:**
    * *Pros:* Thống số throughput gần như không giới hạn, chi phí tiệm cận mức $0, dễ dàng cấu hình bằng Terraform và đáp ứng hoàn hảo kịch bản bão alert (alert storm) của hệ thống SaaS gồm 200+ dịch vụ nhỏ.
    * *Cons:* Chấp nhận rủi ro nhỏ về at-least-once delivery (có thể phân phát lặp lại tin nhắn trong điều kiện mạng lỗi).
    * *Estimated Cost:* ~$0–2/tháng (nằm trong hạn mức 1 triệu request Free Tier của AWS).

✅ **Chosen:** Option B — SQS Standard
* **Reason:** Rủi ro trùng lặp hay sai thứ tự đã được xử lý triệt để bởi lớp ứng dụng nhờ sự kết hợp giữa `Idempotency-Key` và `DynamoDB conditional write`, do đó sử dụng SQS Standard là phương án tối ưu nhất về mặt kiến trúc phần cứng.


## 5.7 Audit Query Layer

* **Option A — OpenSearch Cluster / CloudWatch Logs Insights:**
    * *Pros:* Khả năng tìm kiếm text nâng cao mạnh mẽ, hỗ trợ dựng các hệ thống dashboard và analytics thời gian thực cho đội ngũ vận hành.
    * *Cons:* Chi phí duy trì cụm instance OpenSearch cực cao, tốn nhiều công sức vận hành hạ tầng nền và hoàn toàn vượt biên ngân sách $200 của sandbox. Không hỗ trợ native việc lưu trữ cô lập dạng dữ liệu bất biến chống sửa xóa theo yêu cầu compliance bằng S3 Object Lock.
    * *Estimated Cost:* ~$30–100+/tháng.
* **Option B — Amazon Athena (Serverless SQL):**
    * *Pros:* Kiến trúc Serverless hoàn toàn, mô hình tính phí pay-per-query (chỉ tính tiền dựa trên lượng dữ liệu quét qua lúc demo thực tế). Cho phép dùng cú pháp SQL tiêu chuẩn để truy vấn trực tiếp trên các file log tĩnh được lưu trữ nghiêm ngặt tại S3. 
    * *Cons:* Tốc độ truy vấn chậm hơn OpenSearch đối với các tác vụ tìm kiếm tương tác thời gian thực liên tục (interactive search).
    * *Estimated Cost:* ~$1–5/tháng (chỉ tốn vài cent cho vài chục câu lệnh demo lúc chấm pitch).

✅ **Chosen:** Option B — Athena
* **Reason:** Đáp ứng xuất sắc yêu cầu bài toán audit trail với chi phí thấp và không mất công vận hành cluster riêng. Đặc biệt, Athena cho phép truy vấn trực tiếp trên S3 đã kích hoạt cấu hình **S3 Object Lock (Compliance Mode)** khóa cứng dữ liệu trong 90 ngày, đảm bảo tính bất biến tuyệt đối của dữ liệu log chống sửa xóa (*tamper-evident*) theo đúng luật đề bài.


## 5.8 Observability Layer

* **Option A — Self-hosted kube-prometheus-stack:**
    * *Pros:* Miễn phí hoàn toàn về mặt bản quyền service, toàn quyền kiểm soát cấu hình metrics hệ thống.
    * *Cons:* Đội thêm quá nhiều công việc vận hành hạ tầng cho team trong vòng 2 tuần (phải tự size dung lượng lưu trữ ổ đĩa PVC, tự cấu hình cụm tính sẵn sàng cao HA cho Prometheus, tự quản lý chính sách nén dữ liệu).
    * *Estimated Cost:* ~$20–50/tháng cho phần compute + storage gán thêm.
* **Option B — Amazon Managed Prometheus (AMP) + Amazon Managed Grafana (AMG):**
    * *Pros:* Mô hình managed hoàn toàn từ AWS. AWS chịu toàn bộ trách nhiệm về tính sẵn sàng cao (HA), khả năng lưu trữ (retention) và vá lỗi hệ thống. Tích hợp mượt mà và bảo mật với ADOT Collector chạy dạng `DaemonSet` mức node.
    * *Cons:* Chi phí dịch vụ tính riêng biệt trên hóa đơn AWS, phụ thuộc chặt chẽ vào hệ sinh thái managed của nhà cung cấp Cloud.
    * *Estimated Cost:* ~$10–20/tháng (tính theo lượng metric nạp vào và phí không gian workspace).

✅ **Chosen:** Option B — AMP + AMG
* **Reason:** Giảm tối đa khối lượng công việc vận hành hạ tầng (ops effort) trong thời gian ngắn ngủi 2 tuần, giải phóng 100% thời gian của các thành viên để tập trung hoàn thiện logic cốt lõi của Self-Heal Engine nhằm bàn giao sản phẩm đúng hạn kỳ Capstone.

## 6. Scaling strategy

* **Option A — EKS Fargate Profile (Serverless Auto-scaling):**
  * *Pros:* Serverless, không cần quản lý node, tự động scale resource theo Pod.
  * *Cons:* **Không hỗ trợ DaemonSet**. OTel Collector (bắt buộc theo hợp đồng triển khai) cần chạy ở mức node. Thêm vào đó, ArgoCD repo-server cần writable local filesystem ổn định (vốn hay gặp friction khi chạy trên Fargate).
  * *Verdict:* **Loại**. Đây là technical blocker thực sự (giới hạn kỹ thuật cứng), không phải sự đánh đổi (trade-off) vì lý do chi phí hay sở thích.
* **Option B — EKS Managed Node Group + Karpenter (Advanced Provisioner):**
  * *Pros:* Là hướng tiếp cận production-mature hơn so với Cluster Autoscaler, khả năng scale nhạy bén và tối ưu chi phí cực tốt.
  * *Cons:* Tốn nhiều thời gian cấu hình, học thuật và vận hành.
  * *Verdict:* **Loại (tạm thời)**. Nằm ngoài phạm vi (off-scope) đối với thời lượng 2 tuần của dự án. Rủi ro thời gian không đáng để đánh đổi, hướng này được đưa vào "production roadmap" của hệ thống.
* ✅ **Chosen: Option B — EKS Managed Node Group + Karpenter:**
  * *Verdict cũ được cập nhật*: Sau khi xem xét lại, nhóm quyết định đưa Karpenter vào scope vì:
    1. **Tích hợp tốt với GitOps Hybrid stack**: Karpenter là thành phần native của EKS, hoạt động ổn định với ArgoCD, Argo Workflows và ADOT Collector DaemonSet — toàn bộ là các component cốt lõi của kiến trúc hiện tại.
    2. **Hỗ trợ Node-level DaemonSet**: Managed Node Group + Karpenter cho phép ADOT Collector (bắt buộc theo Deployment Contract) chạy ở mức node — điều Fargate không làm được.
    3. **Tối ưu chi phí tốt hơn Cluster Autoscaler**: Karpenter bin-pack Pod tốt hơn, scale node trong vài giây (không phải vài phút), consolidate node idle nhanh hơn — phù hợp với mục tiêu tiết kiệm chi phí sandbox đã trình bày ở Section 3.2.
    4. **Đủ tài liệu và tooling**: EKS Blueprint + Karpenter Helm chart có terraform module sẵn, rủi ro cấu hình được giảm thiểu bằng cách dùng NodePool/EC2NodeClass mẫu từ official docs.
  * *Option C (Cluster Autoscaler)*: Không chọn vì scale node chậm hơn (2–3 phút vs vài giây của Karpenter), không có khả năng bin-packing và consolidation tự động — kém tối ưu chi phí hơn trong sandbox có workload biến động.

### Quy tắc mở rộng hệ thống chi tiết

**Môi trường áp dụng**: EKS Managed Node Group + Karpenter (node provisioner) + HPA (Pod scaling). Instance type pool: `t3.medium`, `t3.large`, `t3.xlarge` (Karpenter tự chọn phù hợp nhất). Tối đa 5 Nodes tại bất kỳ thời điểm nào.

#### 1. Tăng tài nguyên cho 1 máy (Vertical Scaling)

**Khi nào cần tăng CPU/RAM cho 1 Pod (đơn vị chạy đơn lẻ):**

* Pod (bất kỳ component nào: Webhook Receiver, Direct Patch Engine, Argo Workflows controller, ArgoCD repo-server) **sử dụng RAM liên tục > 85% limit trong 3 phút** — dấu hiệu sắp OOMKilled.
* Kubernetes Event ghi nhận `OOMKilled` cho bất kỳ Pod nào — Self-Heal Engine tự detect và trigger.
* **Hành động**: Self-Heal Engine patch `resources.limits` của Deployment (tăng RAM × 1.5, CPU × 1.5), commit lại manifest vào GitOps repo, ArgoCD sync và rollout Pod mới. Karpenter tự động provision node lớn hơn nếu node hiện tại không đủ tài nguyên cho Pod mới.

**Khi nào cần node instance type lớn hơn:**

* Karpenter không tìm được node phù hợp trong pool `t3.medium` để schedule Pod — Karpenter tự động chọn `t3.large` hoặc `t3.xlarge` từ EC2NodeClass mà không cần operator can thiệp.
* **Hành động**: Karpenter provision node mới đúng size trong vòng **< 60 giây** (không cần drain/reschedule thủ công như Cluster Autoscaler).

> [!NOTE]
> Với Karpenter, "vertical scaling node" được thực hiện tự động thông qua cơ chế **node consolidation**: Karpenter drain node nhỏ, reschedule Pod sang node lớn hơn mà không cần human approval — khác với Cluster Autoscaler yêu cầu manual gate.

#### 2. Tăng số lượng máy (Horizontal Scaling)

**Tăng/giảm Pod Replicas (HPA):**

| Chiều | Điều kiện kích hoạt | Thời gian duy trì | Action |
|---|---|---|---|
| **Scale-Up** | CPU trung bình **> 70%** hoặc throughput **> 150 RPS/Pod** | 5 phút liên tục | +1 Pod replica (max 10 Pods) |
| **Scale-Down** | CPU trung bình **< 40%** | 10 phút liên tục | -1 Pod replica (min 2 Pods) |

*Cooldown scale-down 10 phút (dài hơn scale-up 5 phút) để tránh flapping khi traffic dao động.*

**Tăng/giảm Node (Karpenter):**

| Chiều | Điều kiện kích hoạt | Thời gian phản ứng | Action |
|---|---|---|---|
| **Scale-Up** | Bất kỳ Pod nào ở trạng thái `Pending` do thiếu CPU/RAM trên node hiện tại | **< 60 giây** (Karpenter watch API server liên tục) | Provision EC2 Node mới, kích thước tự động chọn từ NodePool (max 5 Nodes) |
| **Scale-Down (consolidation)** | Node có utilization thấp, các Pod có thể reschedule sang node khác an toàn | **< 30 giây** sau khi consolidation condition thỏa | Drain node, terminate instance, giải phóng chi phí |
| **Scale-Down (interruption)** | Spot instance bị AWS thu hồi (2 phút notice) | Ngay lập tức khi nhận interruption notice | Karpenter cordon + drain node trước khi bị thu hồi, reschedule Pod sang node khác |

#### 3. Ngưỡng kích hoạt cụ thể (tổng hợp)

| Chỉ số | Scale-Up Trigger | Scale-Down Trigger | Thời gian duy trì | Action |
|---|---|---|---|---|
| **CPU Pod** | `> 70%` | `< 40%` | 5 phút / 10 phút | HPA: ±1 Pod (Min 2, Max 10) |
| **RAM Pod** | `> 85% limit` | — | 3 phút | Self-Heal: Patch limits ×1.5, redeploy |
| **OOMKilled event** | Xuất hiện trong K8s Events | — | Ngay lập tức | Self-Heal: Patch limits ×1.5, redeploy |
| **Throughput (RPS)** | `> 150 RPS/Pod` | `< 50 RPS/Pod` | 3 phút | HPA: ±1 Pod |
| **SQS queue depth** | `> 1000 messages` | `< 100 messages` | 2 phút | HPA: ±2 Worker Pods |
| **Pod Pending** | Bất kỳ Pod `Pending` do resource | — | **< 60 giây** | Karpenter: Provision node mới (Max 5) |
| **Node consolidation** | — | Node có thể bin-pack sang node khác | **< 30 giây** | Karpenter: Drain + terminate node |
| **Spot interruption** | AWS thu hồi Spot instance | — | Ngay lập tức (2 min notice) | Karpenter: Cordon, drain, reschedule |

## 7. Failure modes + recovery

| Failure | Detection | Recovery | RTO | RPO |
|---|---|---|---|---|
| Single task crash | ECS/K8s health check | Auto-restart | < 60s | 0 |
| AZ outage | CloudWatch alarm | Multi-AZ failover | < 5min | < 1min |
| DB primary fail | RDS event | Read replica promotion | < 5min | < 1min |
| Region outage | External monitor | Manual region switch | TBD | TBD |

## Related documents

- [`03_security_design.md`](03_security_design.md)
- [`04_deployment_design.md`](04_deployment_design.md)
- [`05_cost_analysis.md`](05_cost_analysis.md)
- [`08_adrs.md`](08_adrs.md)
