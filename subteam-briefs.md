# 📋 KẾ HOẠCH PHÂN CHIA NHIỆM VỤ & HỢP ĐỒNG GIAO TIẾP GIỮA CÁC NHÓM
**Dự án: Capstone Phase 2 — Hệ thống Tự Chữa Lành (Self-Heal System - CDO-01)**
*Bản Đặc Tả Nhiệm Vụ, Lý Thuyết Bắt Buộc Và Giải Pháp Phát Triển Song Song (Mocking)*

---

## 🔹 HỢP ĐỒNG GIAO TIẾP VÀ KHỚP PAYLOAD GIỮA CÁC SUB-TEAM

Để các sub-team làm việc không bị lệch pha, dưới đây là các API Payload Contracts và cấu trúc dữ liệu bắt buộc phải tuân thủ 100%.

### 1. Alert Payload Contract (Từ Prometheus Alertmanager gửi đến Webhook Receiver)
Định dạng JSON gửi đến `POST /alerts` (Port 8443) do Sub-team 3 cấu hình và Sub-team 2 tiếp nhận:
```json
{
  "receiver": "self-heal-webhook-receiver",
  "status": "firing",
  "alerts": [
    {
      "status": "firing",
      "labels": {
        "alertname": "PodOOMKilled",
        "severity": "critical",
        "namespace": "tenant-payment",
        "pod": "payment-api-7dbf8c495c-xyz12",
        "container": "payment-container",
        "service": "payment-api"
      },
      "annotations": {
        "summary": "Container payment-container in pod payment-api-7dbf8c495c-xyz12 was OOMKilled",
        "description": "Memory limit exceeded. Current limit: 256Mi. Usage: 257Mi."
      },
      "startsAt": "2026-06-26T12:00:00Z"
    }
  ]
}
```

### 2. AI Engine API Contract (Hợp đồng giữa Webhook/Worker và AI Engine)
Sub-team 2 gọi sang AI Engine chạy tại `http://ai-engine.self-heal-system.svc.cluster.local:8080` theo 3 bước tuần tự. **Không dùng AWS SigV4, chỉ dùng HTTP Headers**:
*   `X-Tenant-Id`: UUID v4 của tenant (Tra cứu từ DynamoDB table).
    *   `tenant-payment` $\rightarrow$ `d3b07384-d113-495f-9f58-20d18d357d75`
    *   `tenant-checkout` $\rightarrow$ `6c8b4b2b-4d45-4209-a1b4-4b532d56a31c`
*   `Idempotency-Key`: UUID v4 sinh mới cho mỗi chu kỳ giao dịch.
*   `X-Correlation-Id`: UUID v4 dùng để trace log xuyên suốt hệ thống.
*   `X-Dry-Run-Mode`: Chuỗi `"true"` hoặc `"false"` để xác định chế độ chạy thử nghiệm (simulation/dry-run).

#### Bước 2.1: Gọi `/v1/detect` (Kiểm tra xem alert có phải là sự cố cần xử lý)
*   **Request Method:** `POST`
*   **Request Payload JSON Schema:**
    ```json
    {
      "correlation_id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
      "idempotency_key": "d3b07384-d113-495f-9f58-20d18d357d75",
      "dry_run_mode": false,
      "telemetry_window": [
        {
          "ts": "2026-06-25T10:00:00.123Z",
          "tenant_id": "d3b07384-d113-495f-9f58-20d18d357d75",
          "service": "payment-api",
          "signal_name": "pod_oom_event",
          "value": 1.0,
          "labels": { 
            "system": "CDO-PAYMENT",
            "namespace": "tenant-payment",
            "deployment": "payment-api",
            "pod_name": "payment-api-7dbf8c495c-xyz12",
            "container": "payment-container"
          }
        }
      ]
    }
    ```
*   **Response Payload (200 OK):**
    ```json
    {
      "anomaly_detected": true,
      "severity": 0.85,
      "anomaly_context": {
        "target_service": "payment-api",
        "suspected_fault_type": "oom_killed",
        "system": "CDO-PAYMENT",
        "namespace": "tenant-payment",
        "deployment": "payment-api",
        "trigger_metric": "pod_oom_event",
        "trigger_value": 1.0
      },
      "confidence": 0.92,
      "reasoning": "Container payment-container in pod payment-api-7dbf8c495c-xyz12 was OOMKilled. Memory limit exceeded.",
      "correlation_id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d"
    }
    ```

#### Bước 2.2: Gọi `/v1/decide` (Lấy kịch bản tự vá lỗi)
*   **Request Method:** `POST`
*   **Request Payload:**
    ```json
    {
      "correlation_id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
      "idempotency_key": "d3b07384-d113-495f-9f58-20d18d357d75",
      "dry_run_mode": false,
      "anomaly_context": {
        "target_service": "payment-api",
        "suspected_fault_type": "oom_killed",
        "system": "CDO-PAYMENT",
        "namespace": "tenant-payment",
        "deployment": "payment-api"
      }
    }
    ```
*   **Response Payload (200 OK):**
    ```json
    {
      "matched_runbook": "MemoryLimitTuningRunbook",
      "pattern_type": "urgent",
      "action_plan": [
        {
          "step": 1,
          "action": "PATCH_MEMORY_LIMIT",
          "target": "deployment/payment-api",
          "params": {
            "namespace": "tenant-payment",
            "container": "payment-container",
            "memory_request_mb": 256,
            "memory_limit_mb": 384
          }
        }
      ],
      "blast_radius_config": {
        "max_pod_impact_pct": 25,
        "circuit_breaker_error_rate": 0.20,
        "allowed_namespaces": ["tenant-payment"]
      },
      "verify_policy": {
        "window_seconds": 120,
        "success_conditions": [
          "pod_ready == true",
          "restart_count_no_increase == true"
        ]
      },
      "correlation_id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
      "idempotency_key": "d3b07384-d113-495f-9f58-20d18d357d75",
      "dry_run_mode": false
    }
    ```

#### Bước 2.3: Gọi `/v1/verify` (Xác thực sau khi vá lỗi)
*   **Request Method:** `POST`
*   **Request Payload:**
    ```json
    {
      "correlation_id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
      "idempotency_key": "d3b07384-d113-495f-9f58-20d18d357d75",
      "dry_run_mode": false,
      "action_executed": {
        "action": "PATCH_MEMORY_LIMIT",
        "target": "deployment/payment-api",
        "status": "COMPLETED",
        "execution_time_seconds": 12
      },
      "post_telemetry_window": [
        {
          "ts": "2026-06-25T10:02:00.123Z",
          "tenant_id": "d3b07384-d113-495f-9f58-20d18d357d75",
          "service": "payment-api",
          "signal_name": "container_restart_count",
          "value": 0.0,
          "labels": {
            "system": "CDO-PAYMENT",
            "namespace": "tenant-payment",
            "deployment": "payment-api"
          }
        }
      ]
    }
    ```
*   **Response Payload (200 OK):**
    ```json
    {
      "incident_id": "inc-oom-payment-20260626",
      "status": "RESOLVED",
      "verified_at": "2026-06-26T12:02:00Z"
    }
    ```

---

## 🔹 NHIỆM VỤ CHI TIẾT VÀ BẢN ĐỒ LÀM VIỆC CỦA 3 SUB-TEAMS

---

## 🔹 SUB-TEAM 1: Platform & Cloud Infrastructure (3 Members)
*Mảng phụ trách: AWS Network Security, KMS, EKS Cluster, Karpenter, Ingress Controller*

### 1. Lý thuyết cốt lõi & Điểm nghẽn kỹ thuật cần nắm
*   **VPC NAT-less Routing & Private DNS:** Cụm EKS chạy hoàn toàn trong các Private Subnets không có Internet. Mọi liên kết ra bên ngoài tới AWS Services bắt buộc phải đi qua các VPC Interface Endpoints (cổng PrivateLink). 
    *   *Điểm nghẽn:* Option `private_dns_enabled` trên các Interface Endpoints phải bằng `true`. Nếu không, Kubernetes pods sẽ không phân giải được DNS từ các service endpoint mặc định (ví dụ: `sqs.us-east-1.amazonaws.com`) về IP nội bộ của endpoint ENI, gây lỗi timeout kết nối.
*   **KMS Key Policy & CloudWatch Logs Collision:** Khi cấu hình mã hóa log cho CloudWatch Logs Group sử dụng KMS Key, KMS policy của key đó bắt buộc phải grant quyền cho service principal `logs.amazonaws.com` (hoặc `logs.<region>.amazonaws.com`).
    *   *Lỗi kinh điển:* Không thể phân quyền này qua IAM Policy thông thường vì CloudWatch là một AWS service chạy ngầm. Cấu hình KMS key policy phải chứa block sau:
        ```json
        {
          "Sid": "AllowCloudWatchLogs",
          "Effect": "Allow",
          "Principal": { "Service": "logs.us-east-1.amazonaws.com" },
          "Action": [
            "kms:Encrypt*",
            "kms:Decrypt*",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:Describe*"
          ],
          "Resource": "*"
        }
        ```
*   **Chiến lược EKS Provider Chicken-and-Egg:**
    *   *Mô tả:* Terraform cần thông tin kết nối EKS (Endpoint, CA Data) để khởi tạo provider `kubernetes` và `helm`. Nhưng khi chạy lần đầu, EKS chưa được tạo, dẫn đến việc Terraform validate provider thất bại và block toàn bộ quá trình.
    *   *Giải pháp:* Tách biệt Phase 3 (EKS) và Phase 4 (Services/Helm). Phase 3 chỉ xuất ra Output. Phase 4 khởi tạo Kubernetes/Helm provider thông qua Data Source đọc Remote State của Phase 3.

### 2. Chi tiết phân chia công việc & Đầu ra (Deliverables)
*   **Member 1 (Cloud Network & Endpoints Lead):**
    *   Tái cấu trúc Phase 2: Thiết lập VPC, Private Subnets, Route Tables, và 12 Interface/Gateway Endpoints bảo mật kết nối nội bộ.
    *   *Đầu ra (Output):* `vpc_id`, `private_subnet_ids`, `public_subnet_ids`.
*   **Member 2 (Cryptography & Security Group Lead):**
    *   Cấu hình 5 KMS Keys (`alias/cdo-audit-kms`, `alias/cdo-app-data-kms`, `alias/cdo-secrets-kms`, `alias/cdo-infra-kms`, `alias/cdo-observability-kms`) kèm Key Policies chuẩn hóa.
    *   Cấu hình 5 Security Groups cốt lõi (`sg-alb-internal`, `sg-eks-workload`, `sg-eks-control-plane`, `sg-rds`, `sg-vpc-endpoint`) với Ingress/Egress nghiêm ngặt.
    *   *Đầu ra (Output):* Tất cả KMS Key ARNs và Security Group IDs.
*   **Member 3 (Compute Cluster & Ingress Lead):**
    *   Tái cấu trúc Phase 3: EKS Cluster v1.28, Karpenter IAM Roles, OIDC provider, và Phase 4: AWS Load Balancer Controller (LBC).
    *   *Đầu ra (Output):* `cluster_name`, `cluster_endpoint`, `cluster_ca_data`, `oidc_provider_arn`.

### 3. Giải pháp làm việc song song khi bị tắc nghẽn (Block Mitigation)
*   *Nếu AWS Account Sandbox chưa sẵn sàng:* Cả team dùng công cụ **LocalStack** hoặc viết code Terraform mock sử dụng Local Provider (`null_resource`, `local_file`) để thiết lập cấu trúc khung (Skeleton) các file `main.tf`, `variables.tf`, `outputs.tf` và chạy `terraform validate` offline.
*   *Nếu EKS Cluster chưa được tạo (Block Member 3 làm Ingress):* Viết code Helm Release cho AWS LBC và Karpenter NodePool dưới dạng một module Terraform riêng, giả lập các biến đầu vào (`cluster_name`, `oidc_provider_arn`) bằng chuỗi text giả (mock variables) để chạy trước `terraform plan` trên GitHub Actions.

---

## 🔹 SUB-TEAM 2: Application & AI Integration (3 Members)
*Mảng phụ trách: FastAPI Webhook Receiver, SQS Worker, AI API integration, K8s SDK Patching, Git Committer*

### 1. Lý thuyết cốt lõi & Điểm nghẽn kỹ thuật cần nắm
*   **DynamoDB Conditional Write (Idempotency & Cooldown Lock):** 
    *   *Mô tả:* Prometheus Alertmanager bắn alert liên tục. Webhook phải chặn trùng lặp trước khi gửi đi. Webhook sử dụng lệnh ghi có điều kiện lên DynamoDB table `tf-3-aiops-idempotency-lock`.
    *   *Logic Code:* (Xem chi tiết cú pháp tại `project-rules.md` mục V.1).
*   **ArgoCD Sync Suspension (Tránh Race Condition):**
    *   *Mô tả:* Khi vá nóng EKS (Fast Lane), nếu không tắt ArgoCD Auto-Sync, ArgoCD sẽ lập tức phát hiện lệch cấu hình (drift) và ghi đè lại limits cũ từ Git lên EKS trong vòng vài giây, làm mất tác dụng của bản vá nóng.
    *   *Quy trình:*
        1. Gọi API của ArgoCD để đặt trạng thái sync của app thành `Manual`.
        2. Chạy Python Kubernetes SDK thực hiện `patch_namespaced_deployment` để tăng giới hạn tài nguyên (RAM/CPU limit x1.5).
        3. Tạo commit thay đổi file limits bền vững và push lên AWS CodeCommit Git Repo.
        4. Gọi API ArgoCD để bật lại trạng thái `Automatic` sync và ra lệnh `sync` thủ công để đồng bộ hoàn toàn.
*   **Failsafe TTL / Auto-Recovery:**
    *   *Mô tả:* Nếu SQS Worker crash đột ngột ở bước 2 hoặc 3 (khi Auto-Sync đang bị tắt), cụm EKS sẽ bị mất khả năng reconcile mãi mãi (lock leak).
    *   *Giải pháp:* Thiết lập một Cronjob trong Kubernetes (do Sub-team 3 cài đặt) chạy mỗi phút, kiểm tra xem có ứng dụng nào bị tắt Auto-Sync quá 5 phút hay không. Nếu có, cronjob tự động gọi API ArgoCD kích hoạt lại Auto-Sync.

### 2. Chi tiết phân chia công việc & Đầu ra (Deliverables)
*   **Member 4 (FastAPI Webhook & Deduplication Lead):**
    *   Viết Webhook Receiver (FastAPI, Port 8443, Path `/alerts`).
    *   Tích hợp DynamoDB Lock Cooldown logic.
    *   Thực hiện lọc bảo mật (Scrubbing Regex) loại bỏ credentials/tokens nhạy cảm khỏi telemetry trước khi gửi đi.
    *   Đẩy alert an toàn vào SQS Queue.
    *   *Đầu ra (Deliverables):* FastAPI Docker Image, app code, unit tests.
*   **Member 5 (SQS Worker & AI Client Lead):**
    *   Viết SQS Worker Daemon đọc tin nhắn từ SQS.
    *   Viết Client gọi API AI Engine theo đúng Contract `/v1/detect`, `/v1/decide` và `/v1/verify` (Header: `X-Tenant-Id`, `Idempotency-Key` UUID v4, `X-Correlation-Id`, `X-Dry-Run-Mode`).
    *   Xây dựng bộ lọc validate JSON Schema đối với response từ AI Engine.
    *   *Đầu ra (Deliverables):* Worker Docker Image, mock AI API test suite.
*   **Member 6 (Action Execution & Git Committer Lead):**
    *   Viết module Python tương tác Kubernetes SDK (Patch limits, restart deployment).
    *   Viết module kết nối AWS CodeCommit Repo (Clone, modify YAML, commit, push).
    *   *Đầu ra (Deliverables):* Execution Python module, integration tests.

### 3. Giải pháp làm việc song song khi bị tắc nghẽn (Block Mitigation)
*   *Nếu EKS Cluster chưa có (Block Member 4 & 5 chạy app):*
    *   Cài đặt **DynamoDB Local** (Docker image: `amazon/dynamodb-local`) chạy trên cổng `8000`.
    *   Cài đặt **LocalStack** chạy local SQS trên cổng `4566`.
    *   Chạy và test toàn bộ logic FastAPI, ghi lock DynamoDB, đẩy SQS hoàn toàn offline trên máy cá nhân.
*   *Nếu AI Team chưa bàn giao AI Engine (Block Member 5 gọi API):*
    *   Tự viết một file FastAPI mock (`mock_ai_engine.py`) chạy cổng `8080` mô phỏng chính xác các phản hồi JSON của `/v1/detect`, `/v1/decide` và `/v1/verify` theo đúng API Contract.

---

## 🔹 SUB-TEAM 3: GitOps, Observability & Validation (3 Members)
*Mảng phụ trách: ArgoCD App-of-Apps, Prometheus/Grafana, Kyverno Policies, Kinesis Audit Stream, Chaos Tests*

### 1. Lý thuyết cốt lõi & Điểm nghẽn kỹ thuật cần nắm
*   **ArgoCD Sync Waves Order:**
    *   *Mô tả:* Các tài nguyên trong cụm phải được tạo theo đúng trình tự để tránh lỗi dependency. Chúng ta sử dụng annotation `argocd.argoproj.io/sync-wave` trong các file manifest.
    *   *Thứ tự Sync Waves chuẩn:*
        *   `Wave -4`: Khởi tạo Namespaces (`self-heal-system`, `observability`).
        *   `Wave -3`: Cấu hình Security (Kubernetes NetworkPolicies, ServiceAccounts, RBAC Roles, RoleBindings).
        *   `Wave -2`: Cấu hình Configuration (ConfigMaps, SecretStores, ExternalSecrets kết nối Secrets Manager).
        *   `Wave -1`: Cấu hình Services & Templates (ClusterIP Services, Argo WorkflowTemplates).
        *   `Wave 0`: Deploy Webhook Receiver, SQS Worker, và workloads của Tenant.
        *   `Wave 1`: Deploy Ingress (ALB Ingress resource).
*   **Kyverno Policy Enforcement:**
    *   *Mô tả:* Viết ClusterPolicy để kiểm tra (validate) hoặc tự động thay đổi (mutate) các request gọi vào K8s API. Enforce chính sách: chỉ ServiceAccount `self-heal-executor` mới có quyền thay đổi `spec.replicas` và `resources.limits`.
*   **Kinesis Firehose Audit Streaming:**
    *   *Mô tả:* Logs của Worker phải được lưu bất biến vào S3 Audit Bucket. Worker sẽ push log định dạng JSON trực tiếp vào Kinesis Firehose thông qua quyền IAM IRSA `irsa-audit-writer`. Kinesis Firehose tự động ghi log xuống S3.

### 2. Chi tiết phân chia công việc & Đầu ra (Deliverables)
*   **Member 7 (GitOps & Security Policy Lead):**
    *   Thiết lập cấu trúc thư mục repo `gitops/` (Argo App-of-Apps).
    *   Cấu hình External Secrets Operator (ESO) và các Kyverno ClusterPolicies bảo vệ cụm.
    *   *Đầu ra (Deliverables):* GitOps Argo Manifests, Kyverno policy files.
*   **Member 8 (Observability & Audit Stream Lead):**
    *   Triển khai Kube-Prometheus-Stack qua Helm.
    *   Viết Prometheus Alert Rules (`OOMKilled`, `PodCrashLooping`, `QueueBacklog`).
    *   Thiết lập Kinesis Firehose stream logs về S3 Audit Bucket.
    *   *Đầu ra (Deliverables):* Helm configuration values, Alertmanager route config, Firehose Terraform code.
*   **Member 9 (QA, Chaos & Validation Lead):**
    *   Viết scripts chaos testing (Pod OOM simulator, DB network block simulator).
    *   Viết script E2E testing tự động đo đạc thời gian khôi phục lỗi (SLO check).
    *   *Đầu ra (Deliverables):* Chaos scripts, validation report templates.

### 3. Giải pháp làm việc song song khi bị tắc nghẽn (Block Mitigation)
*   *Nếu EKS Cluster chưa có (Block Member 7 & 8 install Argo/Prometheus):*
    *   Sử dụng công cụ **Kind** (Kubernetes in Docker) hoặc **Minikube** để dựng cụm K8s local ngay trên máy cá nhân.
    *   Cài đặt ArgoCD, Prometheus Stack, Kyverno local để thử nghiệm cú pháp YAML, kiểm tra tính đúng đắn của Sync Waves và thử nghiệm Kyverno policy chặn đặc quyền.
*   *Nếu Webhook Receiver của Sub-team 2 chưa code xong (Block Member 8 test Alert):*
    *   Cấu hình Alertmanager tạm thời gửi alert đến một dịch vụ mock online như `webhook.site` để kiểm tra định dạng JSON payload bắn ra từ Prometheus có khớp với mong đợi hay không.
