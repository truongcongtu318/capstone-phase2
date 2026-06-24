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

<!-- Tại sao chọn hướng tiếp cận này? Lý do chi tiết -->

### 3.2 Vượt trội ở đâu (số liệu)

| Axis | My number | Competing angle estimate |
|---|---|---|
| Cost / tenant / month | $X | $Y |
| P99 latency | Xms | Yms |
| Ops overhead (hr/week) | X | Y |
| Time to onboard tenant | X min | Y min |

### 3.3 Weakness chấp nhận

<!-- Honest về trade-off. Reviewer thích honesty hơn là "everything is great" -->

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

- **Vertical**: <!-- CPU/memory bump triggers -->
- **Horizontal**: <!-- auto-scaling rules -->
- **Triggers**: <!-- target CPU 70% / request count / queue depth -->

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
