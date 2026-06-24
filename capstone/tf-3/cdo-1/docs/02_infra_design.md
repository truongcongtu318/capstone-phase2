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
| Compute | | | $X |
| API entry | | | $X |
| Database | | | $X |
| Storage | | | $X |
| Event bus | | | $X |
| Observability | | | $X |

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

### 4.1 Tenant model

- **Tenant ID format**: UUID v4
- **Header**: `X-Tenant-Id` mandatory all API calls
- **Subscription tiers**: basic / pro / enterprise (impact: quota, feature flags)

### 4.2 Isolation pattern

- **Data isolation**: <!-- silo (per-tenant DB) / pool (shared with row-level) / bridge (hybrid) -->
- **Compute isolation**: <!-- shared / per-tenant container / per-tenant account -->
- **Why this pattern**: <!-- cost vs isolation strength trade-off -->

### 4.3 Tenant onboarding flow

```
1. POST /platform/v1/tenants (tenant_name, contact, tier)
2. ...
3. ...
```

### 4.4 Noisy neighbor mitigation

- **Per-tenant quota**: <!-- vd 1000 req/min / tenant -->
- **Rate limiting**: <!-- API Gateway usage plan / custom Lambda -->
- **Resource reservation**: <!-- vd dedicated resources for enterprise tier -->

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
* ✅ **Chosen: Option C — EKS Managed Node Group + Cluster Autoscaler:**
  * *Reason:* Option A bị loại hoàn toàn vì blocker kỹ thuật. Giữa B và C, chọn C vì đây là giải pháp quen thuộc, thời gian setup nhanh nhất. Mặc dù kém tối ưu hơn Karpenter ở môi trường production thực tế, nhưng nó đáp ứng hoàn hảo bài toán tiết kiệm thời gian và yêu cầu auto-scaling cơ bản trong 2 tuần sandbox.

### Quy tắc mở rộng hệ thống chi tiết (EKS Managed Node Group + Cluster Autoscaler)

#### 1. Tăng tài nguyên cho 1 máy (Vertical Scaling)
* **Cấp độ Pod (Đơn vị chạy đơn lẻ)**:
  * Khi Pod chạy đơn lẻ (Self-Heal Engine, Prometheus, ArgoCD, App workload) sử dụng RAM liên tục **> 85%** giới hạn (limit) hoặc CPU liên tục **> 90%** trong **3 phút** liên tục.
  * Khi phát hiện sự kiện `OOMKilled` từ Kubernetes Event.
  * **Hành động**: Tự động cập nhật `resource limits` của Pod (tăng RAM/CPU lên 1.5x lần) thông qua Self-Heal Engine và deploy lại.
* **Cấp độ Node (Máy ảo EC2)**:
  * Khi số lượng Node trong Managed Node Group đã đạt mức tối đa (5 Nodes) nhưng tổng CPU/RAM request của toàn cluster vẫn **> 80%** liên tục trong **10 phút**.
  * **Hành động**: Thực hiện nâng cấp loại cấu hình máy (Instance Type) từ `t3.medium` lên `t3.large`.

#### 2. Tăng số lượng máy (Horizontal Scaling)
* **Tăng/giảm Pod Replicas (HPA - Horizontal Pod Autoscaler)**:
  * **Tăng (Scale-Up)**: Tăng thêm **1 Pod replica** khi CPU trung bình của các Pod hiện tại **> 70%** hoặc số lượng yêu cầu trung bình **> 150 RPS/Pod** liên tục trong **5 phút**. Giới hạn tối đa: 10 Pods.
  * **Giảm (Scale-Down)**: Giảm bớt **1 Pod replica** khi CPU trung bình **< 40%** liên tục trong **10 phút** (giãn cách để tránh tình trạng scale liên tục gây trồi sụt hệ thống). Giới hạn tối thiểu: 2 Pods.
* **Tăng/giảm EC2 Nodes (Cluster Autoscaler - CA)**:
  * **Tăng (Scale-Up node)**: Tự động thêm **1 EC2 Node** vào Managed Node Group ngay khi có bất kỳ Pod nào ở trạng thái `Pending` do thiếu hụt tài nguyên (CPU/RAM) trên Node hiện tại. Giới hạn tối đa: 5 Nodes.
  * **Giảm (Scale-Down node)**: Tự động giảm bớt **1 EC2 Node** khi tổng tài nguyên CPU & RAM được request trên một Node **< 50%** liên tục trong **10 phút** và các Pod trên Node đó có thể dồn (reschedule) sang các Node khác an toàn.

#### 3. Ngưỡng kích hoạt cụ thể (Activation Thresholds)

| Chỉ số (Metric) | Ngưỡng Tăng (Scale-Up Trigger) | Ngưỡng Giảm (Scale-Down Trigger) | Thời gian duy trì | Hành động (Action) |
|---|---|---|---|---|
| **CPU Pod** | `> 70%` | `< 40%` | HPA: `5 phút` | Tăng/Giảm Pod replica (+1 / -1 Pod, Min: 2, Max: 10) |
| **RAM Pod** | `> 85%` | N/A | `3 phút` | Vertical Pod: Restart với RAM limit x1.5 |
| **Request Rate (RPS)** | `> 150 RPS/Pod` | `< 50 RPS/Pod` | HPA: `3 phút` | Tăng/Giảm Pod replica (+1 / -1 Pod) |
| **Hàng đợi (Queue backlog)** | `> 1000 messages` | `< 100 messages` | Worker scale: `2 phút` | HPA: Tăng/Giảm số lượng worker (+2 / -2 workers) |
| **Trạng thái Pod** | `Pending` (thiếu tài nguyên) | N/A | Ngay lập tức | Cluster Autoscaler: +1 EC2 Node (Max: 5) |
| **Tài nguyên Node** | N/A | `< 50% CPU & RAM requested` | `10 phút` | Cluster Autoscaler: Drain và terminate 1 EC2 Node |

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
