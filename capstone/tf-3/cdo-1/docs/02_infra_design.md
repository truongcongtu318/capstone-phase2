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

## 5. Alternatives considered

### 5.1 Compute layer

- **Option A**: <!-- Lambda + API GW - Pros: cost-tight, ops-light · Cons: cold start, 15min limit -->
- **Option B**: <!-- ECS Fargate + ALB - Pros: longer runtime, predictable latency · Cons: higher fixed cost -->
- **Option C**: <!-- EKS + Karpenter - Pros: K8s native, GitOps support · Cons: control plane cost -->
- ✅ **Chosen**: EKS Managed Node Group + Cluster Autoscaler (Xem chi tiết tại Section 6) - Reason: Hỗ trợ Native K8s, tích hợp chặt chẽ với ArgoCD GitOps, hỗ trợ DaemonSet (để cài đặt OTel Collector ở mức Node). Dù chi phí control plane cao hơn nhưng đáp ứng hoàn chỉnh các yêu cầu kỹ thuật và vận hành của hệ thống Self-Heal. Cơ chế autoscaling sandbox sẽ dùng Cluster Autoscaler thay vì Karpenter để giảm thiểu rủi ro triển khai trong 2 tuần sandbox.

### 5.2 Database

- **Option A**: RDS Aurora (Silo/Pool) - Pros: SQL support, strong consistency · Cons: High idle cost, slower provisioning.
- **Option B**: DynamoDB (Single Table) - Pros: Serverless, scale seamlessly, low latency, native TTL support, conditional writes · Cons: No complex queries.
- ✅ **Chosen**: Option B (DynamoDB) - Reason: Thích hợp cho việc lưu trữ state của Incident, hỗ trợ cơ chế Conditional Write Lock (tránh race condition khi multiple self-heal workers cùng xử lý một incident) và Auto-Expiry TTL để tự động dọn dẹp các incident cũ, giúp tối ưu hóa chi phí.

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
