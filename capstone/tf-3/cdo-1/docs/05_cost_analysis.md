# Cost Analysis - Task force 3 · CDO 1

<!-- Doc owner: <Nhóm CDO>
     Status: Skeleton (W11 T6 Pack #1) → Measured actual (W12 T4 Pack #2)
     Word target: 800-1500 từ -->

## 1. Cost model per tenant (forecast)

Mô hình dự toán chi phí vận hành cho 1 tenant trên môi trường Sandbox thử nghiệm (phân bổ chia đều từ cụm Sandbox chạy song song 2 tenants).

| Component | Unit cost | Tenant avg usage | $/tenant/month |
|---|---|---|---|
| Compute (EKS/Karpenter nodes) | EKS Control Plane ($73.00/month) + Spot Nodes (`t3.medium` $0.023/hr) | 1/2 EKS Control Plane ($36.50) + 1.5 Spot nodes 24/7 ($25.19) | $61.69 |
| Database & Queue | RDS PostgreSQL `db.t3.micro` ($15.44/month) + DynamoDB On-Demand + SQS ($2.00/month) | 1/2 RDS ($7.72) + 1/2 DynamoDB ($1.00) + 1/2 SQS queue ($1.00) | $9.72 |
| Storage (S3) | Amazon S3 Standard + Object Lock ($0.023/GB-month) + Kinesis Firehose ($0.029/GB) | 1/2 (S3 $0.23 + Firehose $0.29) = 10 GB audit log toàn cụm | $0.26 |
| Data transfer | Internal ALB ($22.27/month) + VPC Endpoints PrivateLink ($29.30/month, 2 AZs) | 1/2 ALB ($11.14) + 1/2 VPC Endpoints ($14.65) — thay thế hoàn toàn NAT Gateway | $25.79 |
| AI inference (Bedrock) | AWS Bedrock Claude 3 Haiku ($0.25/1M Input, $1.25/1M Output tokens) | ~200 incidents/month, ~600 LLM calls, ~1.5M input + 500K output tokens | $1.00 |
| Observability | Prometheus/Grafana (in-cluster, $0) + AWS Secrets Manager ($2.40/month, 6 secrets) + CloudWatch | 1/2 Prometheus+CloudWatch ($4.00) + 1/2 Secrets Manager ($1.20) | $5.20 |
| **Total / tenant / month** | | | **$103.65** |

> [!NOTE]
> **Minh chứng cấu hình thực tế và Giải trình chênh lệch (Cost Variance Note):**
> * **Link AWS Pricing Calculator**: [Chi tiết cấu hình cụm Sandbox CDO-01](https://calculator.aws/#/estimate?id=285ed34cc0a8f2ae45b8eb183f3356838c817242) với tổng chi phí thực tế đo đạc là **$188.84 USD/tháng** cho toàn cụm 2 tenants $\rightarrow$ **$94.42 USD / tenant / tháng** (chưa gồm $1.00 chi phí biến đổi AI inference).
> [!NOTE]
> **Minh chứng cấu hình thực tế và Giải trình chênh lệch (Cost Variance Note):**
> * **Link AWS Pricing Calculator**: [Chi tiết cấu hình cụm Sandbox CDO-01](https://calculator.aws/#/estimate?id=285ed34cc0a8f2ae45b8eb183f3356838c817242) với tổng chi phí thực tế đo đạc là **$188.84 USD/tháng** (có Free Tier mặc định cho 10 custom metrics) $\rightarrow$ **$94.42 USD / tenant / tháng**.
> * **Giải trình chênh lệch (Giữa dự toán $102.65 và thực tế)**: 
>   1. **Trường hợp không dùng Free Tier**: Chi phí thực tế tăng nhẹ lên **$191.84 USD/tháng** (+$3.00 cho 10 custom metrics) $\rightarrow$ **$95.92 USD / tenant / tháng**, vẫn thấp hơn hạn mức dự toán an toàn ($102.65) nhờ tối ưu hóa Spot discount thực tế (giảm 60% cho `t3.medium`).
>   2. **Trường hợp có Free Tier**: Tiết kiệm thêm cho CloudWatch logs và SQS, đưa chi phí thực tế về mức **$94.42 USD / tenant / tháng**.

---

## 2. Cost at scale

Dự báo tổng chi phí vận hành hệ thống hàng tháng theo quy mô số lượng tenants (đã tính gộp cả chi phí cố định nền hạ tầng là $146.57/tháng bao gồm EKS control plane, database baseline, ALB base, Secrets Manager, VPC Endpoints, Amazon SQS, và Observability dashboards):

| Tenant count | Monthly total cost | Avg per-tenant |
|---|---|---|
| 10 | $328.31 | $32.83 |
| 50 | $803.42 | $16.07 |
| 200 | $2,453.17 | $12.27 |

*\*Lưu ý: per-tenant cost giảm dần do shared fixed cost amortize.*

---

## 3. Cost optimization applied

Để tối ưu hóa chi phí vận hành cho Sandbox và Production, nhóm đã triển khai và áp dụng các giải pháp tối ưu sau:

- **[x] Spot instances cho non-critical workload**: Sử dụng Karpenter để tự động cấp phát Spot instances cho các application workload và workflow ngắn hạn của sandbox, giúp giảm tới 70% chi phí compute so với việc sử dụng On-Demand instances.
- **[x] Reserved capacity cho baseline**: Đề xuất áp dụng Reserved Instances hoặc Savings Plans cho các cụm baseline node chạy 24/7 cố định (như control plane, database, logging/monitoring) để tối ưu chi phí dài hạn.
- **[x] S3 lifecycle tiering (Standard → IA → Glacier)**: Thiết lập Lifecycle Policy tự động chuyển đổi các audit logs cũ hơn 30 ngày từ S3 Standard sang S3 Infrequent Access (IA), và lưu trữ lâu dài tại S3 Glacier Deep Archive sau 90 ngày (tiết kiệm ~60% chi phí lưu trữ).
- **[x] DynamoDB on-demand vs provisioned**: Sử dụng chế độ On-demand cho môi trường Sandbox để tối ưu hóa chi phí về $0 khi không có tải. Đối với môi trường Production, chuyển sang chế độ Provisioned Capacity kết hợp Auto-scaling để giảm chi phí đọc/ghi lên tới 50%.
- **[x] Bedrock prompt caching (Anthropic prompt cache)**: Áp dụng prompt caching trên AWS Bedrock (Claude 3) đối với các runbooks/playbooks mẫu có dung lượng lớn và ngữ cảnh alert lặp lại, giúp tiết kiệm tới 50% chi phí input tokens cho các cuộc gọi AI.
- **[x] Right-sizing per K8s deployment / Karpenter node pool**: Thiết lập cấu hình Resource Requests/Limits chính xác cho các microservices, tránh việc over-provisioning tài nguyên và giúp Karpenter bin-pack tối đa công suất của các Spot nodes.
- **[x] Log retention tiering**: Giới hạn thời gian lưu giữ log (retention limit) trên CloudWatch Logs xuống mức 7 ngày thay vì lưu trữ vô hạn để ngăn ngừa phát sinh chi phí lưu trữ log tích lũy.
- **[x] Data transfer optimization (VPC endpoints to avoid NAT)**: Loại bỏ hoàn toàn NAT Gateway (tiết kiệm cố định ~$32/month/gateway). Thiết kế các VPC Interface/Gateway Endpoints để định tuyến nội bộ trong mạng AWS với chi phí data transfer tối thiểu.

---

## 4. Cost vs alternatives (cùng task force)

* **GitOps Hybrid (Direct Patch + GitOps - Giải pháp của nhóm)**: **$102.65/tenant/tháng** (môi trường Sandbox). Chi phí cố định nền hạ tầng cao hơn ở quy mô nhỏ do sử dụng cụm EKS chuyên dụng và các VPC Endpoints riêng biệt, nhưng tối ưu hơn ở quy mô lớn nhờ Karpenter spot consolidation và chia sẻ tài nguyên compute.
* **AWS Serverless (API Gateway + Step Functions + Lambda)**: Ước tính **$91.53/tenant/tháng** (môi trường Sandbox). Tiết kiệm hơn ở quy mô nhỏ nhờ cơ chế pay-per-use, nhưng dễ phát sinh overhead về quản trị bảo mật (IAM) và độ trễ lạnh (cold start) khi xử lý sự cố quy mô lớn.

---

## 5. Measured actual (Pack #2 only - fill in W12)

### 5.1 2-week capstone spend

| Service | Forecast | Actual | Delta |
|---|---|---|---|
| Compute | $61.69 | $X | ±X% |
| Database & Queue | $9.72 | $X | ±X% |
| Storage | $0.26 | $X | ±X% |
| Network (Data transfer) | $25.79 | $X | ±X% |
| AI inference | $1.00 | $X | ±X% |
| Observability | $5.20 | $X | ±X% |
| **Total** | **$103.65** | $X | ±X% |

### 5.2 Per-tenant actual

<!-- Sau khi onboard ≥3 tenant test, measure real consumption -->

| Tenant test | Service mix | $/day | Extrapolate $/month |
|---|---|---|---|
| Tenant-1 | small load | $X | $X |
| Tenant-2 | medium load | $X | $X |
| Tenant-3 | enterprise load | $X | $X |

### 5.3 Cost-per-correct-decision (joint with AI eval)

| Metric | Value |
|---|---|
| Total AI calls in capstone | N |
| Correct decisions | M |
| Total AI cost | $X |
| **Cost per correct decision** | **$X / M** |

---

## 6. Cost guardrails

* **Monthly budget alert at 70%, 90%, 100%**: Thiết lập ngân sách cảnh báo tự động gửi email/Slack khi chi phí thực tế hoặc chi phí dự báo vượt quá các ngưỡng **70% ($140)**, **90% ($180)**, và **100% ($200)** của ngân sách sandbox tháng ($200).
* **Per-tenant quota enforced via API rate limit**: Tích hợp middleware kiểm soát tần suất gửi alert (Rate Limit 10-30 request/phút tùy theo tier) và cơ chế cooldown qua DynamoDB conditional write.
* **Bedrock daily spend cap (CloudWatch alarm)**: Alarm CloudWatch giám sát số lượng token Bedrock tiêu thụ mỗi giờ, tự động chặn gọi API Bedrock nếu chi phí vượt quá $10/ngày.

---

## 7. Cost recommendations for production

* **Reserved capacity sau 3 tháng usage baseline**: Đăng ký Reserved Instances cho các EC2 baseline nodes chạy 24/7 cố định để giảm chi phí compute lên tới 72%.
* **Savings Plan cho Fargate**: Sử dụng Compute Savings Plans cho Fargate/EC2 nếu mở rộng hạ tầng Serverless để tối ưu hóa chi phí linh hoạt hơn.
* **Cross-region replication chỉ enable cho enterprise tier**: Giới hạn phân vùng replication dữ liệu logs bất biến qua các regions khác chỉ dành riêng cho phân khúc khách hàng Enterprise để tối ưu chi phí băng thông truyền tải liên vùng (Cross-Region Data Transfer).

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - Infra design drives compute/storage cost
- [`../../ai/docs/03_ai_engine_spec.md`](../../ai/docs/03_ai_engine_spec.md) §8 - AI inference cost feeds row "AI inference" trong §1 doc này
- [`07_test_eval_report.md`](07_test_eval_report.md) - Load test results validate cost assumptions
