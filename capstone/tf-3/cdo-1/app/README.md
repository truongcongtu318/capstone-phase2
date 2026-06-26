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
