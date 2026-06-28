# Local Development Setup — Sub-team 2

Hướng dẫn chạy toàn bộ stack local để test trước khi push code lên.

---

## Yêu cầu

```bash
pip install fastapi uvicorn boto3 pydantic-settings httpx pytest pytest-cov moto
```

Docker đang chạy (dùng để chạy DynamoDB Local và LocalStack).

---

## Bước 1 — Khởi động mock AWS services

Mở **2 terminal riêng** và chạy:

**Terminal 1 — DynamoDB Local:**
```bash
docker run --rm -p 8000:8000 amazon/dynamodb-local \
  -jar DynamoDBLocal.jar -sharedDb -inMemory
```

**Terminal 2 — LocalStack (SQS):**
```bash
docker run --rm -p 4566:4566 localstack/localstack:3.4.0
```

Chờ LocalStack in ra `Ready.` (~15 giây) rồi mới sang bước tiếp.

---

## Bước 2 — Tạo bảng DynamoDB và SQS queue

Chạy một lần duy nhất sau mỗi lần restart Docker:

```bash
# Tạo bảng DynamoDB
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws dynamodb create-table \
  --table-name tf-3-aiops-idempotency-lock \
  --attribute-definitions AttributeName=lock_key,AttributeType=S \
  --key-schema AttributeName=lock_key,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --endpoint-url http://localhost:8000 \
  --region us-east-1

# Tạo SQS queue
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws sqs create-queue \
  --queue-name alert-queue \
  --endpoint-url http://localhost:4566 \
  --region us-east-1
```

---

## Bước 3 — Chạy Webhook Receiver

```bash
cd capstone/tf-3/cdo-1/app/webhook-receiver

SQS_QUEUE_URL=http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/alert-queue \
DYNAMODB_ENDPOINT_URL=http://localhost:8000 \
SQS_ENDPOINT_URL=http://localhost:4566 \
AWS_ACCESS_KEY_ID=test \
AWS_SECRET_ACCESS_KEY=test \
python3 -m uvicorn src.main:app --port 8443 --reload
```

Webhook đang chạy khi thấy: `Uvicorn running on http://127.0.0.1:8443`

---

## Bước 4 — Gửi alert test để tạo message trên SQS

Dùng curl để gửi alert hợp lệ. Đây là các case cần test:

**Case 1 — Alert hợp lệ (kỳ vọng: 202 Accepted + message xuất hiện trên SQS):**
```bash
curl -s -X POST http://localhost:8443/alerts \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: d3b07384-d113-495f-9f58-20d18d357d75" \
  -d '{
    "receiver": "self-heal-webhook-receiver",
    "status": "firing",
    "alerts": [{
      "status": "firing",
      "labels": {
        "alertname": "PodOOMKilled",
        "namespace": "tenant-payment",
        "service": "payment-api",
        "severity": "critical",
        "pod": "payment-api-7dbf8c495c-xyz12",
        "container": "payment-container"
      },
      "annotations": {
        "summary": "Container was OOMKilled",
        "description": "Memory limit exceeded. Current limit: 256Mi. Usage: 257Mi."
      },
      "startsAt": "2026-06-28T00:00:00Z"
    }]
  }'
```

**Case 2 — Alert trùng trong cooldown (kỳ vọng: 409 Conflict):**
```bash
# Gửi lại đúng payload trên lần thứ 2 trong vòng 180 giây
```

**Case 3 — Sai tenant (kỳ vọng: 403 Forbidden):**
```bash
curl -s -X POST http://localhost:8443/alerts \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: 6c8b4b2b-4d45-4209-a1b4-4b532d56a31c" \
  -d '{
    "alerts": [{
      "status": "firing",
      "labels": {
        "alertname": "PodOOMKilled",
        "namespace": "tenant-payment",
        "service": "payment-api",
        "severity": "critical"
      }
    }]
  }'
```

**Case 4 — Alert tenant-checkout (kỳ vọng: 202 Accepted, cooldown 300s):**
```bash
curl -s -X POST http://localhost:8443/alerts \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: 6c8b4b2b-4d45-4209-a1b4-4b532d56a31c" \
  -d '{
    "alerts": [{
      "status": "firing",
      "labels": {
        "alertname": "PodOOMKilled",
        "namespace": "tenant-checkout",
        "service": "checkout-api",
        "severity": "critical"
      }
    }]
  }'
```

---

## Bước 5 — Kiểm tra message đã có trên SQS (dành cho Member 5)

Sau khi gửi alert thành công (202), đọc message từ SQS để verify:

```bash
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws sqs receive-message \
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/alert-queue \
  --endpoint-url http://localhost:4566 \
  --region us-east-1 \
  --max-number-of-messages 10
```

Message body là JSON đã scrub PII, sẵn sàng cho SQS Worker xử lý.

---

## Bước 6 — Chạy unit tests

```bash
cd capstone/tf-3/cdo-1/app
python3 -m pytest tests/ -v --cov=. --cov-fail-under=70
```

Tests không cần Docker chạy — dùng mock hoàn toàn.

---

## Env vars tham chiếu

| Biến | Local | EKS (để trống) |
|---|---|---|
| `DYNAMODB_ENDPOINT_URL` | `http://localhost:8000` | không set |
| `SQS_ENDPOINT_URL` | `http://localhost:4566` | không set |
| `SQS_QUEUE_URL` | URL LocalStack ở trên | URL SQS thật từ ST1 |
| `AWS_ACCESS_KEY_ID` | `test` | không set (dùng IRSA) |
| `AWS_SECRET_ACCESS_KEY` | `test` | không set (dùng IRSA) |

**Không bao giờ hardcode endpoint URL trong code** — chỉ đọc từ env var.
