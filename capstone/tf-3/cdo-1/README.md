# Capstone Phase 2 - Self-Heal System (CDO-01) 🚀

Dự án CDO-01 thiết lập **Platform Infrastructure tự chữa lành (Self-Heal Platform)** dành cho hệ thống SaaS platform B2B. Hệ thống tự động hóa xử lý 80% sự cố quen thuộc (`OOMKilled`, `Service Stuck`, `Queue Backlog`) một cách an toàn, có kiểm toán chặt chẽ (tamper-evident audit logs) nhằm đáp ứng tiêu chuẩn chứng chỉ SOC2 Type II.

Môi trường chạy thử nghiệm Sandbox hỗ trợ 2 Tenants:
1.  **tenant-payment** (`d3b07384-d113-495f-9f58-20d18d357d75`)
2.  **tenant-checkout** (`6c8b4b2b-4d45-4209-a1b4-4b532d56a31c`)

---

## 📂 Sơ đồ cấu trúc toàn bộ Monorepo

Dự án được quy hoạch thành một monorepo thống nhất phân chia trách nhiệm rõ ràng cho 3 sub-teams:

```text
capstone/tf-3/cdo-1/
├── assets/                          # Bản vẽ kiến trúc & Sơ đồ hạ tầng của dự án
│
├── contracts/                       # Các văn bản cam kết giao tiếp (API, Deployment, Telemetry)
│   ├── ai-api-contract.md           # Hợp đồng gọi API tới AI Engine
│   ├── deployment-contract.md       # Ràng buộc deploy ứng dụng Webhook & Worker
│   └── telemetry-contract.md        # Ràng buộc format log bất biến & log scrubbing
│
├── docs/                            # Tài liệu thiết kế hệ thống chi tiết (Kiến trúc, Bảo mật, Chi phí)
│
├── infra/                           # 🏗️ IaC Terraform (Sub-team 1 - Platform & Cloud Infra)
│   ├── bootstrap/                   # Tạo S3 State, DynamoDB Lock table & OIDC Roles cho GitHub Actions
│   ├── modules/                     # Các Child Modules tái sử dụng (Networking, Security, EKS, Karpenter, Ingress, Observability)
│   └── environments/                # Deployment Root Modules (Networking -> Compute -> Services)
│
├── app/                             # 💻 Application Source Code (Sub-team 2 - Application & AI Integration)
│   ├── webhook-receiver/            # FastAPI Webhook tiếp nhận alerts (Port 8443, path /alerts)
│   │   ├── src/                     # Logic chính (DynamoDB lock, Log scrubbing)
│   │   ├── Dockerfile
│   │   └── requirements.txt
│   ├── sqs-worker/                  # SQS Worker xử lý tự vá lỗi (Đọc queue -> Gọi AI Engine -> Patch & Commit)
│   │   ├── src/                     # Logic chính (Circuit Breaker, AI Client, Patch Executor, Audit Logger)
│   │   ├── Dockerfile
│   │   └── requirements.txt
│   └── tests/                       # Bộ kiểm thử tập trung (Mock LocalStack & DynamoDB Local)
│
├── gitops/                          # ☸️ Kubernetes Manifests & GitOps (Sub-team 3 - GitOps, Observability & Validation)
│   ├── argo-apps/                   # Cấu hình ArgoCD App-of-Apps
│   ├── manifests/                   # Kustomize Base & Overlays (sandbox, dev, prod)
│   ├── security-policies/           # Kyverno ClusterPolicies & NetworkPolicies giới hạn traffic
│   └── monitoring/                  # Prometheus Alertmanager & Grafana configurations
│
└── infra-old/                       # 📦 Thư viện tham khảo tĩnh (Legacy single-state code)
```

---

## 🔄 Luồng hoạt động tự chữa lành (Self-Heal Lifecycle Flow)

Hệ thống vận hành theo chu kỳ vòng lặp kín tuần tự dưới đây:

### 1. Phát hiện sự cố (Detect)
- Prometheus AlertManager / AWS CloudWatch giám sát hệ thống và phát hiện các sự cố (`OOMKilled`, `Service Stuck`, `Queue Backlog`).
- AlertManager gửi HTTP POST payload chứa alert dạng JSON trực tiếp đến **FastAPI Webhook Receiver** (Internal ClusterIP, Port 8443).

### 2. Kiểm soát trùng lặp & Khóa sự cố (Idempotency Lock)
- FastAPI Webhook Receiver tiếp nhận alert, trích xuất `tenant_id` và tên microservice bị lỗi.
- Đẩy một bản ghi Lock sự cố xuống DynamoDB Table `tf-3-aiops-idempotency-lock` bằng cơ chế Conditional Write.
- **Quy tắc Cooldown:** Nếu có alert trùng lặp trong thời gian cooldown quy định, request mới sẽ bị loại bỏ lập tức để chống alert spam.
- Nếu ghi Lock thành công, Webhook Receiver đẩy alert message vào **Amazon SQS Standard Queue**.

### 3. Điều phối chẩn đoán & Đưa ra quyết định (AI Analysis & Decide)
- **SQS Worker** liên tục poll tin nhắn từ SQS Queue. Khi nhận được alert:
  - Worker thực hiện gọi API tới **AI Engine** (Self-hosted container in-cluster tại Port 8080).
  - Đầu tiên, gửi alert data tới `/v1/detect` để AI Engine phân tích và chẩn đoán nguyên nhân.
  - Tiếp theo, gửi dữ liệu tới `/v1/decide` để AI Engine đưa ra hành động khắc phục cụm (Runbook action).
  - **Ràng buộc HTTP Header bắt buộc:** `Idempotency-Key` (UUIDv4), `X-Tenant-Id` (UUIDv4), `X-Correlation-Id` (UUIDv4), và `X-Dry-Run-Mode` (dạng chuỗi `"true"`/`"false"`).

### 4. Thực thi sửa lỗi tự động (Execute & Audit)
Dựa trên loại hành động AI Engine trả về, Worker điều phối qua 2 luồng (Dual Execution Path):
*   **Fast Lane (Direct Patch - Urgent):** Dành cho lỗi khẩn cấp (`OOMKilled`, `Service Stuck`).
    1.  Worker gọi API ArgoCD tắt tạm thời tính năng Auto-Sync của App.
    2.  Dùng thư viện Python K8s client cập nhật nóng trực tiếp tài nguyên trên EKS API (ví dụ: nhân 1.5 lần Memory Limit, cập nhật `restartedAt` annotation).
    3.  Tạo Git Commit chứa cấu hình giới hạn mới push lên kho lưu trữ **AWS CodeCommit** (môi trường GitOps).
    4.  Bật lại Auto-Sync trên ArgoCD và kích hoạt Sync cưỡng bức.
    5.  *Failsafe TTL:* Một CronJob in-cluster chạy ngầm quét trạng thái, tự động khôi phục Auto-Sync sau 5 phút nếu xảy ra lỗi nghẽn/crash giữa chừng.
*   **Slow Lane (GitOps Commit - Deferred):** Dành cho lỗi thông thường (`Queue Backlog scale`).
    1.  Worker khởi chạy một Argo Workflow.
    2.  Workflow thực hiện Git Commit cập nhật số lượng `replicas` trực tiếp lên **AWS CodeCommit**.
    3.  ArgoCD tự động phát hiện thay đổi và đồng bộ xuống cụm EKS (Reconcile trong vòng < 120s).

### 5. Kiểm tra kết quả & Đóng sự cố (Verify & Close)
- Worker thực hiện kiểm tra sức khỏe của Pod/Service vừa vá lỗi.
- Gửi yêu cầu tới `/v1/verify` để AI Engine xác nhận xem sự cố đã thực sự được giải quyết hay chưa.
- Cập nhật trạng thái sự cố trong DynamoDB Table thành `RESOLVED` và đóng Lock.

### 6. Ngắt mạch an toàn & Cảnh báo leo thang (Circuit Breaker & Escalation)
- Nếu một microservice gặp lỗi tự vá thất bại hoặc xảy ra lỗi liên tiếp **3 lần trong vòng 1 giờ**:
  - Cơ chế **Circuit Breaker** (quản lý bằng DynamoDB state) sẽ được kích hoạt.
  - Tự động khóa và ngắt toàn bộ hành động tự vá nóng đối với microservice đó.
  - Đẩy tin nhắn khẩn cấp lên AWS SNS Topic `tf3-cdo1-sandbox-alerts-escalation` để định tuyến cảnh báo trực tiếp về kênh Slack của đội kỹ sư trực on-call xử lý thủ công.

### 7. Ghi nhật ký bất biến SOC2 Compliance (Immutable Audit Trail)
- Xuyên suốt quá trình từ bước tiếp nhận đến bước kết thúc sự cố, SQS Worker liên tục ghi nhận nhật ký hoạt động.
- Mọi dữ liệu telemetry trước khi gửi đi đều chạy qua module **Log Scrubbing** áp dụng Regex để lọc sạch thông tin cá nhân (PII) hoặc token nhạy cảm.
- Telemetry sau khi làm sạch được stream qua **AWS Kinesis Data Firehose** đẩy thẳng trực tiếp vào **S3 Audit Bucket** (`tf-3-aiops-audit-trail`).
- S3 Bucket được khóa chặt bằng tính năng **S3 Object Lock ở chế độ COMPLIANCE mode với thời hạn retention 90 ngày** (Không một ai, kể cả tài khoản root, có quyền xóa/sửa dữ liệu audit này).

---

## 👥 Phân chia trách nhiệm các Sub-teams

Chi tiết phân công nhiệm vụ, API contracts và checklist bàn giao kỹ thuật cụ thể cho từng thành viên đã được quy định chi tiết tại tệp tin:
👉 **[`subteam-briefs.md`](../../../subteam-briefs.md)**
