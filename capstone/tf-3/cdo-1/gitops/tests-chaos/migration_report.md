# Báo Cáo Chi Tiết: Di Chuyển Từ Manifest Placeholder Sang Runtime Thật (Team 3)

Tài liệu này ghi nhận chi tiết toàn bộ các thay đổi và cấu hình đã thực hiện để chuyển đổi hệ thống tự sửa lỗi (Self-healing System) của Team 3 từ trạng thái giả lập (placeholder) sang các thông số kỹ thuật chạy thật (runtime) được bàn giao từ Sub-team 2 (ST2).

---

## 1. Mục Tiêu Đã Hoàn Thành
- Loại bỏ hoàn toàn các image placeholder (`nginx:1.25`, `busybox:1.36`).
- Chuyển cấu hình cổng mạng (ports) về đúng runtime thật của ứng dụng (`8443` cho Webhook Receiver, `9090` cho SQS Worker, và `8080` cho AI Engine).
- Tách bạch vai trò bảo mật của ServiceAccount và cấu hình IAM Roles cho ServiceAccounts (IRSA).
- Tạo tài nguyên phục vụ kiểm thử E2E hỗn loạn (Chaos Testing): Test workload (`order-service` trong `tenant-payment`), ArgoCD Applications cấu hình auto-sync, và file cấu hình GitOps `values.yaml`.
- Cập nhật tài liệu kiểm chứng SLO (`SLO_validation_report.md`) với danh sách kiểm tra (E2E Checklist) và các thông số metrics thật cần theo dõi.

---

## 2. Chi Tiết Các Thay Đổi Trong Manifests

### 2.1. Webhook Receiver Component
Webhook Receiver là điểm tiếp nhận cảnh báo từ Alertmanager, thực hiện ghi log và đẩy thông tin vào hàng đợi SQS.

- **Deployment**: [deployment.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/base/webhook-receiver/deployment.yaml)
  - Thay thế image `nginx:1.25` bằng ECR image thật: `474013238625.dkr.ecr.us-east-1.amazonaws.com/tf-3-webhook-receiver:sha-PENDING`.
  - Thay đổi cổng mạng của container từ `80` thành `8443` (tên cổng: `http-webhook`).
  - Xóa bỏ các annotation tạm thời của `kube-linter` trước đó dành cho Nginx.
  - Cấu hình các biến môi trường bắt buộc:
    - `AWS_DEFAULT_REGION=us-east-1`
    - `SQS_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/474013238625/tf3-cdo1-sandbox-self-heal-queue`
    - `DYNAMODB_TABLE_NAME=tf-3-aiops-idempotency-lock`
    - `DRY_RUN=false`
  - Thêm cấu hình thu thập dữ liệu giám sát (Prometheus scrape annotations):
    - `prometheus.io/scrape: "true"`
    - `prometheus.io/port: "8443"`
    - `prometheus.io/path: "/metrics"`
  - Cấu hình Liveness/Readiness Probes tại endpoint `/healthz` trên cổng `8443`.
  - Thiết lập Security Context hạn chế đặc quyền (non-root, read-only root filesystem).
- **Service**: [service.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/base/webhook-receiver/service.yaml)
  - Cập nhật `targetPort` từ `80` sang `8443`.
- **ServiceAccount**: [serviceaccount.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/base/webhook-receiver/serviceaccount.yaml)
  - Gắn annotation IRSA: `eks.amazonaws.com/role-arn: arn:aws:iam::474013238625:role/tf3-cdo1-sandbox-irsa-webhook-receiver`.
- **ConfigMap**: [configmap.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/base/webhook-receiver/configmap.yaml)
  - Thay thế `PLACEHOLDER_KEY` bằng cấu hình thật: vùng AWS, SQS Queue URL, DynamoDB Lock table và cấu hình Cooldown Time theo phân hạng Tenant (Basic/Pro).
- **AnalysisTemplate**: [analysis-template.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/base/webhook-receiver/analysis-template.yaml)
  - Thay thế các truy vấn metrics Nginx giả lập bằng các metrics thật của ứng dụng từ ST2: `http_request_duration_seconds{handler="/alerts"}` và `webhook_alerts_queued_total`.

### 2.2. SQS Worker Component
SQS Worker chịu trách nhiệm lắng nghe hàng đợi, phân tích cảnh báo với AI Engine và ra quyết định tự động vá lỗi (Remediation).

- **Deployment**: [deployment.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/base/sqs-worker/deployment.yaml)
  - Thay thế image `busybox:1.36` bằng ECR image thật: `474013238625.dkr.ecr.us-east-1.amazonaws.com/tf-3-self-heal-worker:sha-PENDING`.
  - Loại bỏ lệnh ngủ vô hạn `["sleep", "infinity"]` để chạy tiến trình worker thật.
  - Cấu hình cổng giám sát (metrics) của Container là `9090`.
  - Bổ sung cấu hình kéo token xác thực ArgoCD `ARGOCD_AUTH_TOKEN` từ Secret `sqs-worker-argocd-secret` (thông qua `envFrom`).
  - Cấu hình các biến môi trường phục vụ kết nối AWS SDK và điều phối hệ thống:
    - `AWS_DEFAULT_REGION=us-east-1`
    - `SQS_QUEUE_URL`, `SNS_TOPIC_ARN`, `FIREHOSE_STREAM_NAME`, `DYNAMODB_TABLE_NAME`
    - `AI_ENGINE_URL=http://ai-engine.self-heal-system.svc.cluster.local:8080`
    - `ARGOCD_SERVER_URL=http://argocd-server.argocd.svc.cluster.local`
    - `CODECOMMIT_REPO_URL` & `CODECOMMIT_BRANCH=main`
  - Thêm cấu hình Prometheus scrape annotations cho pod trên cổng `9090`.
- **Service**: [service.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/base/sqs-worker/service.yaml)
  - Thay đổi cổng dịch vụ và `targetPort` từ `8080` thành `9090`.
- **ServiceAccount**: [serviceaccount.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/base/sqs-worker/serviceaccount.yaml)
  - Gắn annotation IRSA: `eks.amazonaws.com/role-arn: arn:aws:iam::474013238625:role/tf3-cdo1-sandbox-irsa-audit-writer`.
- **ExternalSecret**: [external-secret.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/base/sqs-worker/external-secret.yaml)
  - Đồng bộ và kéo khoá bí mật `ARGOCD_AUTH_TOKEN` một cách an toàn từ AWS Secrets Manager đường dẫn `tf3-cdo1-sandbox/argocd-auth-token`.
  - Tích hợp tài nguyên này vào danh sách kịch bản kustomize gốc ([kustomization.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/base/sqs-worker/kustomization.yaml)).

### 2.3. AI Engine Demo Component
AI Engine Demo cung cấp API phán đoán nguyên nhân gây lỗi dựa trên dữ liệu logs và đưa ra khuyến nghị sửa đổi.

- **Deployment**: [deployment.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/base/ai-engine/deployment.yaml)
  - Thay thế image `nginx:1.25` bằng ECR image thật: `474013238625.dkr.ecr.us-east-1.amazonaws.com/tf-3-ai-engine-demo:sha-PENDING`.
  - Chuyển cổng mạng container từ `80` sang `8080`.
  - Thay đổi cổng kiểm tra trạng thái liveness/readiness probe sang cổng `8080` ở các đường dẫn `/health` và `/ready`.
- **Service**: [service.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/base/ai-engine/service.yaml)
  - Thay đổi `targetPort` từ `80` thành `8080`. Cổng dịch vụ bên ngoài giữ nguyên là `8080`.
- **ServiceAccount**: [serviceaccount.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/base/ai-engine/serviceaccount.yaml)
  - Cập nhật annotation IRSA trỏ đến đúng Role ARN của sandbox ECR/Bedrock: `eks.amazonaws.com/role-arn: arn:aws:iam::474013238625:role/tf3-cdo1-sandbox-irsa-ai-engine-bedrock`.
- **ConfigMap**: [configmap.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/base/ai-engine/configmap.yaml)
  - Thay cấu hình fake bằng biến thật: `AWS_REGION=us-east-1` và `BEDROCK_MODEL_ID=anthropic.claude-3-sonnet-20240229-v1:0`.

---

## 3. Cấu Hình Từng Overlay Môi Trường (Sandbox)
Nhằm giữ các tài nguyên cơ bản (base) độc lập và cho phép gán nhãn tag thay đổi liên tục theo quy trình CI/CD, hệ thống gán ảnh (image pin) đã được đưa vào các file overlays:

- **Webhook Receiver Overlay**: [kustomization.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/overlays/sandbox/webhook-receiver/kustomization.yaml)
- **SQS Worker Overlay**: [kustomization.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/overlays/sandbox/sqs-worker/kustomization.yaml)
- **AI Engine Overlay**: [kustomization.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/overlays/sandbox/ai-engine/kustomization.yaml)

Các tệp này khai báo cấu trúc `images` ghi đè tag mặc định thành `sha-PENDING` (sẽ được thay thế tự động bằng ID commit SHA thực tế khi chạy pipeline CI/CD).

---

## 4. Dọn Dẹp và Đồng Bộ Hoá Tên Gọi ServiceAccount (RBAC Naming)

Sau khi đối chiếu tài liệu bàn giao về phân quyền Zero-Trust:
- `webhook-receiver` chỉ có quyền thao tác trên DynamoDB (PutItem) và SQS (SendMessage).
- `self-heal-executor` (SQS Worker) nắm toàn bộ quyền quản trị K8s Deployment để thực hiện vá lỗi, cùng các quyền đọc/ghi trên Firehose/SQS/SNS/DynamoDB.
- `ai-engine` tuyệt đối không có quyền thao tác trên K8s API.

**Hành động dọn dẹp**:
- Đã quét toàn bộ mã nguồn của phần manifest runtime.
- Xóa sạch các ServiceAccount cũ/thừa và các tham chiếu liên quan đến `patch-controller` và `patch-receiver`.
- Đồng bộ hóa toàn bộ `serviceAccountName` trong deployments về đúng 3 tên chuẩn: `webhook-receiver`, `self-heal-executor` và `ai-engine`.

---

## 5. Thiết Lập Tài Nguyên Phục Vụ Kiểm Thử E2E Chaos

Để chuẩn bị chạy thử nghiệm kịch bản lỗi OOMKilled trên môi trường Sandbox:

1. **Test Workload**: [order-service](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/manifests/base/tenant-payment/order-service/)
   - Tạo mới một deployment giả định nằm trong namespace `tenant-payment`.
   - Cấu hình tài nguyên container `order-service` ban đầu có Memory Limit là `256Mi`.
   - Trực quan hoá kết quả: Khi kịch bản lỗi OOM xảy ra, worker sẽ can thiệp và nâng thông số limit này lên `512Mi`.
2. **ArgoCD Applications**:
   - Tạo mới ứng dụng ArgoCD [tenant-payment-app.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/argo-apps/tenant-payment-app.yaml) quản trị tài nguyên của tenant payment.
   - Tạo mới ứng dụng ArgoCD [tenant-checkout-app.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/argo-apps/tenant-checkout-app.yaml) quản trị tài nguyên của tenant checkout.
   - *Lý do*: Quy tắc của SQS Worker yêu cầu tự động suy đoán tên ArgoCD App theo định dạng `{namespace}-app` để thực hiện tạm dừng (suspend) auto-sync trước khi vá lỗi và kích hoạt lại (resume) sau đó.
3. **Commit Path (GitOps)**:
   - Tạo tệp cấu hình tham số [values.yaml](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/tenant-payment/order-service/values.yaml). Đây là file đích để SQS Worker thực hiện tự động tạo commit và push ngược lại kho lưu trữ CodeCommit trong quá trình khắc phục sự cố.

---

## 6. Cập Nhật Báo Cáo SLO và Giám Sát Metrics

Báo cáo [SLO_validation_report.md](file:///home/nvtank/year3/intern/w11/capstone-phase2/capstone/tf-3/cdo-1/gitops/tests-chaos/SLO_validation_report.md) đã được cập nhật sâu rộng:
- **Trạng thái bàn giao ứng dụng**: Được cập nhật thành `RECEIVED_FROM_ST2` cho các đặc tả ảnh ứng dụng, cổng mạng, IRSA và metrics. Các SHA tags thật được đánh dấu là `PENDING_SHA_TAG` cho tới khi có build ECR hoàn thiện.
- **Danh sách metrics chi tiết cần giám sát**:
  - Webhook Receiver: Theo dõi tần suất alert, tỷ lệ trùng lặp (Idempotency) và các vi phạm bảo mật.
  - SQS Worker: Theo dõi trạng thái thông điệp xử lý, thời gian gọi AI Engine, trạng thái đóng/mở của Circuit Breaker, số lần escalate và rollback.
- **Quy trình E2E Checklist**: Tích hợp danh sách 8 bước cụ thể từ kiểm tra ECR, cập nhật tags, sync ArgoCD, trigger lỗi giả lập bằng lệnh POST cho đến khâu kiểm tra nhật ký kiểm toán (Audit Logs) trên S3.

---

## 7. Kết Quả Kiểm Chứng Tĩnh (Static Verification)

Các bài kiểm tra cú pháp và cấu trúc manifests đã được chạy cục bộ thông qua kịch bản kiểm tra:

1. **Kiểm tra Kustomize Build**:
   Tất cả các tài nguyên overlays sandbox đều biên dịch thành công mà không gặp bất kỳ lỗi cú pháp nào:
   ```bash
   kubectl kustomize capstone/tf-3/cdo-1/gitops/manifests/overlays/sandbox/webhook-receiver
   kubectl kustomize capstone/tf-3/cdo-1/gitops/manifests/overlays/sandbox/sqs-worker
   kubectl kustomize capstone/tf-3/cdo-1/gitops/manifests/overlays/sandbox/ai-engine
   ```
2. **Kiểm tra Dấu Vết Placeholder**:
   Tìm kiếm chuỗi tĩnh khẳng định không còn bất kỳ tệp cấu hình runtime nào sử dụng các thiết lập tạm thời:
   - Cú pháp `targetPort: 80` không còn tồn tại trong base manifests của Webhook/Worker/AI.
   - Các ServiceAccount `patch-controller`/`patch-receiver` đã được dọn sạch hoàn toàn khỏi cấu hình triển khai.
3. **Kiểm tra IRSA**:
   Xác minh cả 3 ServiceAccounts trong `base` đều đã được gán nhãn IAM Role ARN hợp lệ từ Account ID `474013238625`.
