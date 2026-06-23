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
- ✅ **Chosen**: <!-- ... --> - Reason: <!-- ... -->

### 5.2 Database

- **Option A**: ... 
- **Option B**: ...
- ✅ **Chosen**: ...

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
