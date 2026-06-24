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


## 5.1 Infrastructure Component Table (Bảng thành phần hạ tầng)

Dưới đây là bảng tổng hợp các dịch vụ hạ tầng được lựa chọn cho hệ thống, làm căn cứ cấu hình Terraform (Task 2/5/6) và tính toán tổng chi phí (Task 8):

| Thành phần nghiệp vụ | Dịch vụ AWS / K8s lựa chọn | Lý do lựa chọn & Phù hợp quy mô | Chi phí ước tính (Môi trường Sandbox / Tháng) |
| :--- | :--- | :--- | :--- |
| **Compute (Control Plane)** | **Amazon EKS v1.28** | K8s native giúp mô phỏng chính xác môi trường production của client (200+ microservices trên EKS). Hỗ trợ GitOps, IRSA, và K8s API patching native. | $73.00 (Fixed cost cố định từ AWS) |
| **Node Autoscaling** | **Karpenter** (với cụm node EC2 t3.medium Spot) | Tốc độ scale node cực nhanh (gấp 6-10x so với Cluster Autoscaler). Khả năng tự động gom cụm, tối ưu hóa mật độ pod giúp nén chi phí sandbox tối đa. | ~$50.00 (Giả lập chạy 3 node Spot t3.medium giá ~$0.023/giờ) |
| **API Ingress** | **Application Load Balancer (ALB)** | Tiếp nhận HTTP alerts từ AlertManager bên ngoài, hỗ trợ định tuyến nâng cao theo đường dẫn (path-based routing) và tích hợp xác thực bảo mật. | ~$22.50 + LCU phát sinh theo traffic |
| **Database (Sandbox)** | **RDS PostgreSQL Single-AZ (db.t3.micro)** | Lưu trữ các thông tin cấu hình hệ thống và dữ liệu phụ trợ của sandbox. Cấu hình Single-AZ nhỏ nhất để fit ngân sách (Môi trường Production target sẽ nâng cấp lên RDS Aurora Multi-AZ). | ~$15.00 |
| **State Machine** | **Amazon DynamoDB** (Mô hình On-Demand) | Lưu trữ chính xác trạng thái của từng sự cố xử lý (`Triggered -> Deciding -> Executing -> Verifying -> Done`). Kích hoạt TTL tự động để giải phóng lock nếu controller gặp sự cố crash. | ~$2.00 (Phụ thuộc vào số lượng request ghi dữ liệu lúc demo) |
| **Audit Storage** | **Amazon S3** + **S3 Object Lock** (Compliance Mode) | Nguồn dữ liệu kiểm toán bất biến duy nhất (Single Source of Truth) phục vụ chứng chỉ SOC2. Chế độ Compliance ngăn mọi hành vi xóa/sửa kể cả với root account. | $0.023 / GB-tháng |
| **Audit Streaming** | **Amazon Kinesis Data Firehose** | Stream trực tiếp các audit events từ Controller vào S3 ngay lập tức mà không đi qua Git path. Đảm bảo toàn bộ Raw Webhook Event + AI Decision JSON + K8s State đều được lưu vết tức thời. | $0.029 / GB-processed |
| **Secrets Management** | **AWS Secrets Manager** + External Secrets Operator (ESO) | Lưu trữ tập trung các thông tin nhạy cảm (AI Engine credentials, Git Deploy Key, DB creds). Dùng ESO để đồng bộ an toàn vào K8s Secret nội bộ. | $0.40 / secret-tháng |
| **Observability Layer** | **Prometheus** + **Grafana** + **Amazon CloudWatch** | Prometheus thu thập metrics nội bộ K8s, AlertManager kích hoạt luồng self-heal. CloudWatch Logs thu thập log hệ thống AWS-level (ALB, DynamoDB, Kinesis). | ~$8.00 |


## 5.2 Compute Layer & Node Provisioning (Nơi chạy code hệ thống)

* **Option A — EKS Fargate Profile:**
    * *Pros:* Mô hình Serverless hoàn toàn cho Kubernetes, loại bỏ hoàn toàn gánh nặng vận hành, vá lỗi hệ điều hành và quản lý hệ thống node EC2 phía dưới.
    * *Cons:* Gặp **technical blocker thực sự**: Fargate không hỗ trợ triển khai `DaemonSet`. Trong khi đó, hệ thống giám sát bắt buộc phải chạy Prometheus Node Exporter / ADOT Collector dưới dạng `DaemonSet` mức node để thu thập chỉ số hạ tầng theo deployment-contract. Ngoài ra, cấu phần `ArgoCD repo-server` cần một writable local filesystem hoạt động ổn định, điều thường xuyên gây xung đột hệ thống tệp trên Fargate. Xét quy mô lớn của doanh nghiệp SaaS (200+ dịch vụ nhỏ), chạy Fargate theo pod lẻ sẽ đẩy chi phí tích lũy hàng tháng lên mức khổng lồ.
    * *Estimated Cost:* ~$120–180/tháng cho workload tương đương sandbox.
* **Option B — EKS Managed Node Group + Cluster Autoscaler:**
    * *Pros:* Công nghệ mature, tài liệu module EKS và Terraform module hoạt động ổn định. Hỗ trợ đầy đủ và native cho các `DaemonSet` mức node.
    * *Cons:* Tốc độ scale node chậm do phải phụ thuộc và chờ đợi AWS Auto Scaling Group (ASG) warm up. Cơ chế bin-packing (gom pod) kém linh hoạt, dễ gây lãng phí tài nguyên và không tối ưu chi phí biên cho môi trường production siêu lớn.
    * *Estimated Cost:* ~$96–110/tháng.
* **Option C — EKS + Karpenter (Sử dụng Spot Instance EC2):**
    * *Pros:* Karpenter loại bỏ sự phụ thuộc vào ASG, tự động giao tiếp trực tiếp với AWS EC2 API để cấp phát node, giúp tốc độ scale nhanh hơn từ **6-10x** so với Cluster Autoscaler. Khả năng tự động gom cụm Pod và thực hiện `Spot instance consolidation` (hạ cấp/thay thế node linh hoạt) giúp nén chi phí sandbox xuống mức tối thiểu mà vẫn đảm bảo hiệu năng cao. Phù hợp hoàn hảo với kiến trúc thực tế của client (200+ microservices trên EKS).
    * *Cons:* Độ dốc học tập (learning curve) cao, đòi hỏi cấu hình chính xác các CRD như NodePool / EC2NodeClass.
    * *Estimated Cost:* ~$50/tháng (Tối ưu nhờ tận dụng giá rẻ của 3 node Spot `t3.medium` ở mức ~$0.023/giờ).

✅ **Chosen:** Option C — EKS + Karpenter (Sử dụng Spot Instance)
* **Reason:** Khắc phục triệt để technical blocker của Fargate (Option A), đồng thời đem lại tốc độ scale vượt trội để đạt mốc phản hồi khẩn cấp. Mô hình nén tài nguyên của Karpenter là chìa khóa giải quyết bài toán kinh tế khi chạy nền hệ thống 200+ microservices cho doanh nghiệp SaaS B2B lớn.


## 5.3 State & Idempotency Database

* **Option A — Amazon ElastiCache Redis:**
    * *Pros:* Tốc độ phản hồi cực nhanh (in-memory latency < 1ms), hỗ trợ cơ chế thiết lập TTL native để tự động giải phóng lock key rất tiện lợi.
    * *Cons:* Phải duy trì cụm node chạy liên tục 24/7 gây phát sinh chi phí cố định ngay cả khi hệ thống hoàn toàn idle. Với bài toán SaaS lớn chạm mốc 12TB dữ liệu, việc lưu giữ toàn bộ dữ liệu lưu vết transaction trên RAM của Redis cực kỳ tốn kém và không có khả năng scale kinh tế.
    * *Estimated Cost:* ~$15–30/tháng.
* **Option B — DynamoDB On-Demand + Conditional Write:**
    * *Pros:* Cơ chế tính phí Pay-per-request giúp tối ưu hóa chi phí về $0 khi không có traffic. Sử dụng tính năng `conditional write` giải quyết trực tiếp yêu cầu làm Idempotency Lock Store chống xử lý trùng lặp alert khi bão cảnh báo xảy ra. Hỗ trợ TTL tự động xóa dữ liệu để giải phóng lock nếu controller bị crash giữa chừng. Khả năng scale-out vô hạn về cả dung lượng và throughput, đáp ứng hoàn hảo bài toán tăng trưởng dữ liệu của doanh nghiệp SaaS lớn.
    * *Cons:* Latency cao hơn Redis vài mili-giây do truy xuất qua tầng HTTPS API.
    * *Estimated Cost:* ~$2/tháng (phụ thuộc vào lượng request ghi dữ liệu lúc demo).

✅ **Chosen:** Option B — DynamoDB On-Demand
* **Reason:** Thỏa mãn bài toán tối ưu chi phí sandbox nhờ cơ chế On-Demand, đồng thời chứng minh được năng lực xử lý quy mô lớn của công ty SaaS doanh nghiệp nhờ khả năng lưu trữ scale-out vô hạn không phụ thuộc bộ nhớ RAM.


## 5.4 Webhook Receiver (Entry Layer)

* **Option A — AWS API Gateway + Lambda:**
    * *Pros:* Fully managed bởi AWS, tự động scale theo traffic, mô hình chi phí pay-per-use tối ưu.
    * *Cons:* Làm phức tạp hóa ranh giới bảo mật không cần thiết. Buộc phải thiết lập thêm một chuỗi kết nối phức tạp (`IAM ↔ K8s credential bridge`) để Lambda từ ngoài gọi ngược vào EKS API Server, làm mở rộng ranh giới bảo mật (Trust Boundary).
    * *Estimated Cost:* ~$0–10/tháng.
* **Option B — FastAPI Deployment trên EKS tích hợp Application Load Balancer (ALB):**
    * *Pros:* Nằm trọn vẹn trong cùng một Trust Boundary bảo mật với hệ thống tự chữa lành (namespace `self-heal-system`). Sử dụng trực tiếp ServiceAccount nội bộ cụm thông qua hàm `load_incluster_config()`, loại bỏ hoàn toàn việc expose IAM credential ra ngoài. ALB tiếp nhận tín hiệu HTTP alerts từ AlertManager, hỗ trợ routing theo path và tích hợp authentication bảo mật cao.
    * *Cons:* Phải tự quản lý manifest deployment và tốn chi phí cố định cho ALB.
    * *Estimated Cost:* ~$22.50/tháng (Phí cố định của ALB, phần code FastAPI chạy chung trên tài nguyên Node Group được Karpenter cấp phát).

✅ **Chosen:** Option B — FastAPI Deployment kết hợp AWS ALB
* **Reason:** Đơn giản hóa kiến trúc bảo mật, loại bỏ hoàn toàn cơ chế credential bridging phức tạp, tận dụng hạ tầng ALB để định tuyến alerts an toàn và chính xác.


## 5.5 Orchestrator (GitOps Path)

* **Option A — AWS Step Functions + Lambda:**
    * *Pros:* Trạng thái xử lý (state machine), cơ chế retry và timeout được build-in sẵn. Quản lý luồng trực quan trực tiếp trên AWS Console UI, chi phí pay-per-use lý tưởng.
    * *Cons:* Bộ điều phối nằm ngoài cluster, làm tăng độ phức tạp khi phân quyền chéo. Bản chất luồng GitOps xử lý lỗi Loại 2 không cần chạm trực tiếp vào EKS API mà đi qua Git repository, nên việc đưa state machine ra ngoài không mang lại lợi ích bảo mật nào thực tế.
    * *Estimated Cost:* ~$0–5/tháng.
* **Option B — Argo Workflows (Self-hosted trên K8s):**
    * *Pros:* Native Kubernetes CRD chạy ngay trong cụm, hỗ trợ xử lý luồng phức tạp dạng DAG và retry container mạnh mẽ. Giao diện UI hiển thị real-time đồng bộ trong hệ sinh thái K8s giúp demo trực quan hơn. Đội dự án đã de-risked rủi ro nhân sự khi có 01 thành viên chủ chốt có kinh nghiệm vận hành thực tế.
    * *Cons:* Phải quản lý các CRD nội bộ trong cụm K8s.
    * *Estimated Cost:* $0 thêm (Compute overhead chạy trực tiếp trên tài nguyên EC2 do Karpenter quản lý ở mục 5.1).

✅ **Chosen:** Option B — Argo Workflows
* **Reason:** Toàn bộ bộ não điều phối nằm trong cùng một Trust Boundary bảo mật với ArgoCD và Direct Patch Engine, giúp giảm độ phức tạp vận hành và tăng tính đồng bộ, thuyết phục khi demo thực tế.


## 5.6 Direct Patch Engine — Loại 1 (Khẩn Cấp / Out-of-Band)

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


## 5.7 Event Queue (Telemetry Pipeline)

* **Option A — SQS FIFO (First-In-First-Out):**
    * *Pros:* Đảm bảo thứ tự tin nhắn tuyệt đối (ordering guarantee) và hỗ trợ chống trùng lặp dữ liệu ở mức hạ tầng Cloud.
    * *Cons:* Throughput bị giới hạn nghiêm ngặt (300 - 3000 msg/s), không cần thiết khi hệ thống đã được thiết kế phòng vệ nhiều lớp ở tầng trên.
    * *Estimated Cost:* ~$0–2/tháng.
* **Option B — SQS Standard Queue:**
    * *Pros:* Thông số throughput gần như không giới hạn, chi phí tiệm cận mức $0, dễ dàng cấu hình bằng Terraform và đáp ứng hoàn hảo kịch bản bão alert (alert storm) của hệ thống SaaS gồm 200+ dịch vụ nhỏ.
    * *Cons:* Chấp nhận rủi ro nhỏ về at-least-once delivery (có thể phân phát lặp lại tin nhắn trong điều kiện mạng lỗi).
    * *Estimated Cost:* ~$0–2/tháng (nằm trong hạn mức 1 triệu request Free Tier của AWS).

✅ **Chosen:** Option B — SQS Standard
* **Reason:** Rủi ro trùng lặp hay sai thứ tự đã được xử lý triệt để bởi lớp ứng dụng nhờ sự kết hợp giữa `Idempotency-Key` và `DynamoDB conditional write`, do đó sử dụng SQS Standard là phương án tối ưu nhất về mặt kiến trúc phần cứng.

## 5.8 Audit Query & Streaming Layer

* **Option A — OpenSearch Cluster / CloudWatch Logs Insights:**
    * *Pros:* Khả năng tìm kiếm text nâng cao mạnh mẽ, hỗ trợ dựng các hệ thống dashboard và analytics thời gian thực cho đội ngũ vận hành.
    * *Cons:* Chi phí duy trì cụm instance OpenSearch cực cao, tốn nhiều công sức vận hành hạ tầng nền và hoàn toàn vượt biên ngân sách $200 của sandbox. Không hỗ trợ native việc lưu trữ cô lập dữ liệu bất biến chống sửa xóa theo yêu cầu SOC2 bằng S3 Object Lock.
    * *Estimated Cost:* ~$30–100+/tháng.
* **Option B — Amazon Kinesis Data Firehose + S3 Object Lock + Amazon Athena:**
    * *Pros:* **Kinesis Firehose** thực hiện stream trực tiếp các audit events (Raw Webhook Event + AI Decision JSON + Pre/Post K8s State) từ Controller vào S3 ngay lập tức mà không đi qua Git path để bảo vệ dữ liệu tuyệt đối. File log tĩnh được lưu trữ nghiêm ngặt tại S3 kết hợp cấu hình kích hoạt **S3 Object Lock (COMPLIANCE Mode)** khóa cứng dữ liệu, ngăn chặn mọi hành vi xóa/sửa kể cả với root account. **Amazon Athena** (Serverless SQL) cho phép dùng cú pháp SQL tiêu chuẩn để truy vấn log trực tiếp trên S3 theo mô hình pay-per-query siêu tiết kiệm chi phí.
    * *Cons:* Athena sẽ có độ trễ cao hơn OpenSearch với các tác vụ tìm kiếm tương tác (interactive search) thời gian thực liên tục mức mili-giây.
    * *Estimated Cost:* ~$1–5/tháng cho toàn cụm Streaming + Query (Kinesis Firehose tính phí $0.029/GB-processed, S3 tính phí $0.023/GB-tháng, Athena tính phí theo lượng dữ liệu quét qua thực tế).

✅ **Chosen:** Option B — Kinesis Firehose + S3 Object Lock + Athena
* **Reason:** Tạo lập nguồn kiểm toán bất biến duy nhất (Single Source of Truth) phục vụ chứng chỉ bảo mật SOC2 của doanh nghiệp lớn với mức chi phí sandbox tối ưu, loại bỏ hoàn toàn gánh nặng phải tự vận hành cluster riêng.

## 5.9 Observability & Secrets Management Layer

* **Option A — Toàn bộ Self-hosted Stack (Prometheus/Grafana trong cụm + K8s Static Secrets):**
    * *Pros:* Miễn phí hoàn toàn về mặt bản quyền service Cloud, tự do cấu hình metrics hệ thống.
    * *Cons:* Tốn rất nhiều công sức vận hành (ops effort) để duy trì tính sẵn sàng cao (HA) cho Prometheus và cấu hình lưu trữ PVC. Sử dụng static environment variables hoặc K8s Secrets thông thường để lưu credentials (AI Engine credentials, Git Deploy Key, DB creds) tạo ra lỗ hổng bảo mật nghiêm trọng, không đáp ứng tiêu chuẩn SaaS lớn.
    * *Estimated Cost:* ~$20–50/tháng cho phần compute + storage gán thêm.
* **Option B — Prometheus/Grafana (Metrics) + CloudWatch (AWS Services) + AWS Secrets Manager kết hợp External Secrets Operator (ESO):**
    * *Pros:* Giám sát đa lớp toàn diện: Prometheus thu thập K8s metrics, AlertManager kích hoạt luồng tự chữa lành; CloudWatch quản lý chỉ số ở mức AWS infra (ALB, DynamoDB, Kinesis). Bảo mật thông tin nhạy cảm tuyệt đối bằng **AWS Secrets Manager**, dùng **ESO** để sync an toàn vào K8s Secret động, triệt tiêu hoàn toàn static env vars.
    * *Cons:* Phụ thuộc vào các dịch vụ tính phí của AWS.
    * *Estimated Cost:* ~$8.40/tháng (Prometheus/Grafana/CloudWatch logs tốn ~$8.00/tháng; AWS Secrets Manager tính phí cố định $0.40/secret-tháng).

✅ **Chosen:** Option B — Prometheus/Grafana/CloudWatch + AWS Secrets Manager (với ESO)
* **Reason:** Giảm tối đa khối lượng vận hành hạ tầng trong thời gian ngắn ngủi 2 tuần, đồng thời kiên cố hóa lỗ hổng bảo mật về quản lý thông tin nhạy cảm theo đúng tiêu chuẩn vận hành Enterprise của client.

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
