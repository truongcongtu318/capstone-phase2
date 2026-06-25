# Requirements Analysis - Task force 3 · CDO 1

<!-- Doc owner: CDO Team TF3
     Status: Final (W11 T6 Pack #1) → Refined (W12 T4 Pack #2)
     Word target: 800-1500 từ
     Tier: Light -->

## 1. Đề tài context

Client là **VP Engineering của một SaaS platform B2B** vận hành 200+ microservice trên Kubernetes (AWS EKS, us-east-1). Production traffic peak ~8K RPS, 120paying tenants enterprise, data layer ~12TB live state. Hiện tại, kỹ sư trực on-call nhận 2-4 alerts/đêm, trong đó 80% là các sự cố quen thuộc (Known Patterns) như OOMKilled, Service Stuck, Queue Backlog, Cert Expiring, Disk Space Exceeded. Tình trạng này gây burnout nghiêm trọng (eNPS giảm từ 42 xuống 11, retention giảm 30% YoY).

CDO-01 có nhiệm vụ xây dựng **Platform Infrastructure điều phối luồng tự chữa lành (Self-Heal Platform)** theo quy trình: `detect ➔ match runbook ➔ execute (audited) ➔ verify ➔ escalate`. Mục tiêu là tự động hóa xử lý 80% sự cố quen thuộc một cách an toàn, có audit logs tamper-evident phục vụ chứng chỉ SOC2 Type II.

---

## 2. Infra non-functional requirements

| NFR | Target | Justification |
|---|---|---|
| **Multi-tenant scale** | $\ge$ 2 tenants (sandbox), thiết kế hỗ trợ $\ge$ 50 tenants (production) | Đáp ứng quy mô 120 tenants enterprise của client |
| **SLO p99 latency (AI API)** | < 1,000 ms | Thời gian AI xử lý chẩn đoán (/detect và /decide) |
| **Detect-to-action total latency** | **Fast Lane (Direct Patch): < 15 giây** <br> **Slow Lane (GitOps Commit): < 120 giây** | Phục hồi khẩn cấp tức thời cho lỗi sập nguồn; đồng bộ Git Ops cho lỗi cấu hình lâu dài |
| **Availability** | $\ge$ 99.5% | Subscription SLA của client cho platform |
| **Error rate (API Ingress)** | < 0.5% | Đảm bảo độ tin cậy kết nối của cổng alert |
| **Auto-resolve rate** | $\ge$ 60% trên $\ge$ 10 scenarios injected | Hard requirement kiểm định tính khả thi của hệ thống |
| **Cost per tenant/month** | **< $6.00** (production forecast) | Tối ưu hóa ngân sách vận hành của doanh nghiệp |
| **Onboarding tenant SLA** | < 30 phút | Tự động hóa provision hạ tầng cho tenant mới |
| **Security baseline** | IAM least-privilege + 90 ngày audit logs immutable | Đảm bảo tiêu chuẩn SOC2 Type II compliance |
| **Safety sub-checkpoints** | Dry-run, Blast-radius, Verify, Rollback, Circuit Breaker | 5 chốt chặn an toàn bắt buộc khi tự chữa lành |

### Ràng buộc an toàn (Safety & Blast-radius limits):
- **Namespace Lock:** Cấm tuyệt đối Direct Patch Engine can thiệp hoặc thay đổi tài nguyên trong các namespace hệ thống (`kube-system`, `argocd`, `observability`).
- **Resource Limits:** Giới hạn tăng CPU/Memory limits tối đa 50% mỗi lần patch và không vượt quá limits phần cứng của Node.
- **Kyverno Policy Guardrail:** Cấu hình admission controller trong EKS cluster chỉ cho phép patch các trường `spec.replicas` và `resources.limits`. Mọi request thay đổi image hay security context nhạy cảm đều bị chặn ngay ở API Server.
- **Idempotency Lock:** Khóa sự cố bằng DynamoDB Conditional Write. Receiver tự check cooldown timestamp để chặn alert spam.
- **Circuit Breaker:** Tự động ngắt tự vá lỗi và gửi cảnh báo tới SNS topic (escalate) nếu sự cố trên 1 microservice fail liên tiếp 3 lần trong 1 giờ.

---

## 3. Differentiation angle (KEY)

- **Angle chọn:** **GitOps Hybrid (Webhook Receiver + Direct K8s API Patch cho khẩn cấp + GitOps Commit cho thông thường)**.
- **Why this angle:**
  - *Fast Lane (Direct Patch):* Cho lỗi khẩn cấp (OOMKilled, Service Stuck). Vá nóng trực tiếp vào Kubernetes API qua Python client chỉ mất **~0.03 giây** (E2E sync hoàn tất trong ~14 giây, đạt SLO < 15s) rồi đồng bộ ngược cấu hình lên Git.
  - *Slow Lane (GitOps Commit):* Cho lỗi thông thường (Queue Backlog scale). Commit cấu hình lên AWS CodeCommit và ArgoCD tự động reconcile.
  - *Sync Suspension:* Sử dụng ArgoCD API tắt/bật auto-sync khi patch nóng để tránh ArgoCD revert trạng thái OutOfSync.
- **Trade-off chấp nhận:** Chấp nhận chi phí cố định sandbox cao hơn Serverless (tốn thêm EKS Node Group và VPC Endpoints) để giữ toàn bộ ranh giới mạng, compute và credentials của hệ thống tự chữa lành chạy an toàn nội bộ (in-cluster).

---

## 4. Constraints

- **AWS only** (Không sử dụng đa đám mây).
- **Region:** `us-east-1` (khớp với production EKS và RDS của client).
- **NAT-less VPC:** Workloads chạy hoàn toàn trong Private Subnets không có NAT Gateway. Giao tiếp AWS services qua VPC Endpoints (S3, DynamoDB, Secrets Manager, CodeCommit, SQS, SNS).
- **Budget:** $200 cho 2 tuần sandbox.
- **Code freeze:** 08:00 Thứ 5 W12.

---

## 5. Open questions

- [x] **Alertmanager dùng ClusterIP hay Internal ALB?**  
  *Giải quyết:* Chốt dùng **ClusterIP** nội bộ cụm để giảm latency và tăng bảo mật (bypass ALB).
- [x] **Private subnet truy cập GitHub qua NAT hay egress proxy?**  
  *Giải quyết:* Chốt không dùng internet/GitHub cho runtime. ArgoCD pull manifests từ **AWS CodeCommit** thông qua VPC Interface Endpoint.
- [x] **EKS kết nối AI Engine bằng Peering, PrivateLink hay public HTTPS?**  
  *Giải quyết:* Chốt **CDO tự host AI Engine** (Docker container) chạy trực tiếp trong cụm EKS (chung namespace `self-heal-system`), giao tiếp local API.
- [x] **AI authentication dùng SigV4, API key hay mTLS?**  
  *Giải quyết:* Chốt dùng **local authentication** (ServiceAccount token) do chạy in-cluster.
- [x] **SQS dùng Standard hay FIFO?**  
  *Giải quyết:* Chốt dùng **SQS Standard** (trùng lặp/idempotency được xử lý ở app layer bằng DynamoDB Conditional Write).
- [x] **Xác nhận retention period và Object Lock mode cho audit S3 bucket.**  
  *Giải quyết:* Chốt dùng **COMPLIANCE mode, 90 days retention** cho capstone sandbox.

## Related documents
- [`02_infra_design.md`](02_infra_design.md)
- [`03_security_design.md`](03_security_design.md)
- [`04_deployment_design.md`](04_deployment_design.md)
- [`08_adrs.md`](08_adrs.md)
