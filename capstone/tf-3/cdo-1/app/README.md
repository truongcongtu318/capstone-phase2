# 💻 Application Development Guide (Sub-team 2)

Thư mục này chứa mã nguồn ứng dụng tự chữa lành (Self-Heal System) phục vụ Capstone Phase 2. Toàn bộ mã nguồn viết bằng Python sử dụng FastAPI (Webhook) và Boto3 SDK (Worker).

## 📂 Cấu Trúc Mã Nguồn & Phân Chia Module

Lập trình viên bắt buộc phải viết code phân rã theo cấu trúc sau, **không được dồn toàn bộ code vào một file**.

```text
app/
├── webhook-receiver/             # 1. FastAPI Webhook tiếp nhận alerts (Port 8443)
│   ├── src/                      # Thư mục mã nguồn chính
│   │   ├── __init__.py
│   │   ├── main.py               # Khởi tạo FastAPI, cấu hình endpoint HTTP POST /alerts
│   │   ├── config.py             # Đọc và xác thực biến môi trường (Pydantic Settings)
│   │   ├── security.py           # Log scrubbing regex sanitization middleware (SOC2)
│   │   └── client_ddb.py         # Kết nối DynamoDB kiểm soát Idempotency & Cooldown
│   ├── Dockerfile
│   └── requirements.txt
│
├── sqs-worker/                   # 2. SQS Worker xử lý và điều phối luồng tự vá lỗi
│   ├── src/                      # Thư mục mã nguồn chính
│   │   ├── __init__.py
│   │   ├── main.py               # Vòng lặp polling tin nhắn từ SQS, bắt lỗi chung
│   │   ├── config.py             # Đọc biến môi trường (SQS_ENDPOINT_URL, AI_ENGINE_URL...)
│   │   ├── ai_client.py          # HTTP Client gọi API AI Engine (/detect, /decide, /verify)
│   │   ├── circuit_breaker.py    # Kiểm soát tần suất lỗi (3 lỗi/giờ) & bắn cảnh báo SNS
│   │   ├── patch_executor.py     # Gọi Kubernetes Python SDK (vá limits/replicas) & push CodeCommit
│   │   └── audit_logger.py       # Format log chuẩn hóa (SOC2) & ghi vào Kinesis Data Firehose
│   ├── Dockerfile
│   └── requirements.txt
│
└── tests/                        # 🧪 Bộ kiểm thử tập trung (Pytest Suite)
    ├── conftest.py               # Thiết lập LocalStack & DynamoDB local fixtures dùng chung
    ├── test_webhook.py           # Unit tests kiểm tra idempotency, cooldown logic
    └── test_worker.py            # Unit tests kiểm tra AI API headers, Circuit Breaker logic
```

---

## 🛠️ Hướng Dẫn Phát Triển Local-First (Mocking)

Để phát triển và kiểm thử code tại local máy tính cá nhân mà không cần kết nối AWS Cloud thật, ứng dụng được thiết kế để kết nối qua các mock endpoints:

### 1. Biến Môi Trường overrides (Local development)
Khi chạy ở local (hoặc trong pytest), ứng dụng sẽ đọc các biến môi trường để trỏ tới LocalStack hoặc DynamoDB Local thay vì AWS:
*   `DYNAMODB_ENDPOINT_URL`: Trỏ về DynamoDB Local (mặc định: `http://localhost:8000` hoặc LocalStack `http://localhost:4566`).
*   `SQS_ENDPOINT_URL`: Trỏ về SQS LocalStack (mặc định: `http://localhost:4566`).
*   `FIREHOSE_ENDPOINT_URL` / `SNS_ENDPOINT_URL`: Trỏ về LocalStack (mặc định: `http://localhost:4566`).
*   `KUBERNETES_SERVICE_HOST` / `KUBERNETES_SERVICE_PORT`: Khi chạy local, K8s SDK sẽ tự động fallback đọc từ file cấu hình kubeconfig local (`~/.kube/config`).

### 2. Auto-Discovery trên EKS Cluster (Production)
Khi deploy lên cụm EKS của AWS Cloud, lập trình viên **không cấu hình** các biến endpoint trên. Python code (boto3) sẽ tự động bỏ qua endpoint override để sử dụng AWS IRSA (IAM Roles for Service Accounts) tự động nhận diện và kết nối trực tiếp vào các tài nguyên AWS thật bằng credential do ServiceAccount cấp.

---

## 🔒 Quy Định Giao Tiếp & Bảo Mật (Strict Contracts)

Lập trình viên khi triển khai code bắt buộc phải tuân thủ các quy định nghiệp vụ sau:

### 1. Log Scrubbing Compliance (SOC2)
Mọi log ghi ra console hoặc đẩy lên Firehose phải chạy qua middleware lọc dữ liệu nhạy cảm (PII). Sử dụng Regex để thay thế các thông tin sau bằng dấu `[SCRUBBED]`:
*   AWS Access Key ID, Secret Access Key.
*   Bearer Tokens, JWT Tokens, Basic Authentication Headers.
*   Thông tin thẻ tín dụng, email hoặc mật khẩu (nếu có trong payload).

### 2. AI Engine Call Headers
Khi gọi API đến container AI Engine, bắt buộc phải truyền đầy đủ 4 custom HTTP Headers sau (định dạng String):
*   `X-Tenant-Id`: ID của tenant liên quan đến lỗi (ví dụ: `d3b07384-d113-495f-9f58-20d18d357d75`).
*   `Idempotency-Key`: Khóa chống trùng lặp (UUIDv4 được tạo ngẫu nhiên cho mỗi phiên làm việc).
*   `X-Correlation-Id`: ID theo vết phiên (UUIDv4 truyền từ Webhook sang Worker qua SQS).
*   `X-Dry-Run-Mode`: Chế độ chạy thử nghiệm (Giá trị: `"true"` hoặc `"false"`).

---

## 👥 Phân Vai Chi Tiết Trong Sub-team 2 (Member Responsibilities)

Để đảm bảo hiệu quả làm việc nhóm song song và tránh giẫm chân lên nhau, các thành viên Sub-team 2 được phân công nhiệm vụ cụ thể và tương ứng với từng file như sau:

### 1. **Member 4 (App & AI API Lead) - Nhóm trưởng kỹ thuật ứng dụng**
*   **Trách nhiệm chính:**
    *   Thiết lập khung FastAPI Webhook, quản lý cấu hình tập trung.
    *   Tích hợp HTTP client kết nối AI Engine và đảm bảo truyền chuẩn xác 4 Custom HTTP Headers.
*   **Các file đảm nhiệm:**
    *   `app/webhook-receiver/src/main.py` (FastAPI endpoints)
    *   `app/webhook-receiver/src/config.py` & `app/sqs-worker/src/config.py` (Quản lý env/config)
    *   `app/sqs-worker/src/ai_client.py` (AI API Client)
    *   `app/webhook-receiver/Dockerfile` & `app/sqs-worker/Dockerfile`

### 2. **Member 5 (Idempotency & Incident Flow Lead) - Chuyên gia luồng xử lý & DB**
*   **Trách nhiệm chính:**
    *   Thiết kế logic DynamoDB conditional write để ghi lock sự cố và xử lý thời gian cooldown.
    *   Phát triển logic polling chính của SQS Worker và cơ chế Circuit Breaker (ngắt mạch khi lỗi 3 lần/giờ) kết hợp đẩy thông báo khẩn qua SNS.
*   **Các file đảm nhiệm:**
    *   `app/webhook-receiver/src/client_ddb.py` (DynamoDB locking logic)
    *   `app/sqs-worker/src/main.py` (SQS Polling Loop)
    *   `app/sqs-worker/src/circuit_breaker.py` (Circuit Breaker & SNS Alerts)

### 3. **Member 6 (SOC2 Auditing & Platform Integration Lead) - Chuyên gia bảo mật & Tự vá EKS**
*   **Trách nhiệm chính:**
    *   Xây dựng bộ lọc log scrubbing tuân thủ SOC2 (lọc PII & secrets bằng Regex).
    *   Tích hợp K8s Python SDK thực thi vá tài nguyên (limits, replicas) và Git push lên AWS CodeCommit (Dual Execution Path).
    *   Phát triển module đẩy telemetry log bất biến qua Kinesis Data Firehose lên S3.
*   **Các file đảm nhiệm:**
    *   `app/webhook-receiver/src/security.py` (Log scrubbing middleware)
    *   `app/sqs-worker/src/patch_executor.py` (K8s Patching & Git Commit logic)
    *   `app/sqs-worker/src/audit_logger.py` (Kinesis Firehose integrations)

### 4. **Hợp tác viết Unit Tests (`app/tests/`):**
Cả 3 thành viên cùng phối hợp viết tests tương ứng với code mình phụ trách trong thư mục `app/tests/` (sử dụng fixture trong `conftest.py` làm mock AWS endpoints).
*   Member 4 $\rightarrow$ `test_webhook.py` (FastAPI test).
*   Member 5 $\rightarrow$ `test_webhook.py` & `test_worker.py` (DynamoDB Lock & Circuit Breaker tests).
*   Member 6 $\rightarrow$ `test_worker.py` (Log scrubbing & execution tests).
---

## 🔌 Giải pháp xử lý Phụ thuộc & Đấu nối hệ thống (Dependencies & Integration Steps)

Do **Sub-team 2** bị phụ thuộc hoàn toàn vào hạ tầng EKS/VPC của Sub-team 1 và API của team AI, quy trình code và đấu nối được phân rã như sau:

### 1. Khi chưa có EKS Cluster & DynamoDB thật (Chạy Local-First)
*   **Vấn đề:** Không có môi trường cloud thật để test Webhook Receiver và SQS Worker.
*   **Giải pháp:** 
    *   Sử dụng **DynamoDB Local** (Docker) để chạy và test conditional write lock.
    *   Sử dụng **LocalStack** để giả lập SQS queue, SNS topic và Firehose audit stream.
    *   Kích hoạt các biến môi trường `DYNAMODB_ENDPOINT_URL=http://localhost:8000` và `SQS_ENDPOINT_URL=http://localhost:4566` trong file cấu hình local.
    *   Sử dụng code mock AI Engine (`mock_ai_engine.py` chạy trên port `8080`) để giả lập các phản hồi API.

### 2. Quy trình đấu nối lên EKS (Transition to AWS Cloud)
*   **Vấn đề:** Khi deploy lên cụm thật, làm sao để code tự động chuyển hướng kết nối sang tài nguyên AWS mà không phải sửa code?
*   **Giải pháp (Auto-Discovery):**
    *   Trong file `config.py`, chỉ khởi tạo `endpoint_url` trong boto3 client **nếu** biến môi trường tương ứng có giá trị. Nếu rỗng, boto3 sẽ tự động sử dụng AWS SDK credential chain mặc định.
    *   Khi viết Dockerfile và Helm chart deploy lên Sandbox EKS, **Sub-team 3** sẽ không truyền các biến endpoint local. 
    *   Pods chạy trên EKS sẽ tự động sử dụng **IAM Roles for Service Accounts (IRSA)** thông qua ServiceAccount `sa-patch-controller` để phân quyền và tự động route thông qua các VPC PrivateLink Endpoints nội bộ cụm.
