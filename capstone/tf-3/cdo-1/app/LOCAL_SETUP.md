# Local Setup — Sub-team 2: Manual End-to-End Test Guide

Test toàn bộ pipeline **Webhook → SQS → Worker → AI Engine → Audit** trên máy local trước khi push lên EKS.

> **Chiến lược:** Dùng `DRY_RUN=true` để Worker bỏ qua K8s SDK và Git commit thật — toàn bộ phần còn lại (DynamoDB lock, SQS, AI Engine, Firehose, SNS) chạy thật với LocalStack và AI demo.

---

## Yêu cầu

**Cài đặt 1 lần:**
```bash
pip install fastapi uvicorn boto3 pydantic-settings httpx pytest pytest-cov \
            moto jsonschema python-dotenv pyyaml kubernetes
```

**Docker phải đang chạy.**  
**AWS CLI phải được cài:**
```bash
brew install awscli   # macOS
```

---

## Tổng quan — 5 tiến trình cần chạy

```
Terminal 1: DynamoDB Local      :8000   (idempotency lock + circuit breaker)
Terminal 2: LocalStack          :4566   (SQS + SNS + Firehose + S3)
Terminal 3: AI Engine Demo      :8080   (mock detect/decide/verify)
Terminal 4: Webhook Receiver    :8443   (nhận alert từ Alertmanager)
Terminal 5: SQS Worker                  (poll SQS → gọi AI → audit)
```

---

## Bước 1 — Khởi động services

Mở **5 terminal riêng**, mỗi terminal giữ nguyên (không đóng):

**Terminal 1 — DynamoDB Local:**
```bash
docker run --rm -p 8000:8000 amazon/dynamodb-local \
  -jar DynamoDBLocal.jar -sharedDb -inMemory
```

**Terminal 2 — LocalStack (SQS + SNS + Firehose + S3):**
```bash
docker run --rm -p 4566:4566 \
  -e SERVICES=sqs,sns,firehose,s3 \
  localstack/localstack:3.4.0
```
Chờ xuất hiện dòng `Ready.` (~15–30s) rồi mới tiếp tục.

**Terminal 3 — AI Engine Demo:**
```bash
cd /Users/tan/Desktop/teamwork-capstone/capstone-phase2/capstone/tf-3/ai/demo/app
pip install fastapi==0.111.0 uvicorn==0.30.1
python3 -m uvicorn main:app --host 0.0.0.0 --port 8080
```
Kiểm tra: `curl http://localhost:8080/health` → `{"status":"healthy",...}`

---

## Bước 2 — Tạo AWS resources trên LocalStack/DynamoDB

Chạy lệnh dưới đây **1 lần** sau mỗi lần khởi động lại Docker. Có thể chạy từ bất kỳ terminal nào.

```bash
# ── DynamoDB: bảng idempotency lock & circuit breaker ──
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws dynamodb create-table \
  --table-name tf-3-aiops-idempotency-lock \
  --attribute-definitions AttributeName=lock_key,AttributeType=S \
  --key-schema AttributeName=lock_key,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --endpoint-url http://localhost:8000 \
  --region us-east-1

# ── SQS: queue nhận alert từ Webhook ──
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws sqs create-queue \
  --queue-name alert-queue \
  --endpoint-url http://localhost:4566 \
  --region us-east-1

# ── SNS: topic nhận cảnh báo CB + escalation ──
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws sns create-topic \
  --name tf3-cdo1-sandbox-alerts-escalation \
  --endpoint-url http://localhost:4566 \
  --region us-east-1

# ── S3: bucket chứa audit logs từ Firehose ──
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws s3api create-bucket \
  --bucket tf-3-aiops-audit-trail \
  --endpoint-url http://localhost:4566 \
  --region us-east-1

# ── Kinesis Firehose: stream ghi audit → S3 ──
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws firehose create-delivery-stream \
  --delivery-stream-name tf3-cdo1-sandbox-audit-stream \
  --delivery-stream-type DirectPut \
  --s3-destination-configuration \
    "RoleARN=arn:aws:iam::000000000000:role/firehose-role,\
BucketARN=arn:aws:s3:::tf-3-aiops-audit-trail,\
Prefix=audit/,\
BufferingHints={SizeInMBs=1,IntervalInSeconds=10},\
CompressionFormat=UNCOMPRESSED" \
  --endpoint-url http://localhost:4566 \
  --region us-east-1
```

**Xác nhận resources đã tạo:**
```bash
# DynamoDB
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws dynamodb list-tables --endpoint-url http://localhost:8000 --region us-east-1

# SQS
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws sqs list-queues --endpoint-url http://localhost:4566 --region us-east-1

# SNS
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws sns list-topics --endpoint-url http://localhost:4566 --region us-east-1

# S3
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws s3 ls --endpoint-url http://localhost:4566

# Firehose
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws firehose list-delivery-streams --endpoint-url http://localhost:4566 --region us-east-1
```

---

## Bước 3 — Tạo file .env.local cho SQS Worker

Có 2 chế độ tùy mục đích test:

**Chế độ A — `DRY_RUN=true` (mặc định, an toàn):**  
K8s patch và Git commit chỉ log. **Firehose/SNS cũng bị skip** (audit_logger dùng cùng flag).  
Dùng khi: kiểm tra logic flow, CI, không cần verify audit trail thật.

**Chế độ B — `DRY_RUN=false` (test Firehose/SNS thật):**  
K8s patch sẽ thất bại (không có cluster local) → worker đi vào path EXECUTE_DONE(FAILED) → ESCALATE.  
Firehose và SNS gọi thật → audit records xuất hiện trong S3.  
Dùng khi: muốn verify Firehose flush vào S3 và SNS topic nhận được message.

```bash
# Tạo từ thư mục app/
cat > capstone/tf-3/cdo-1/app/sqs-worker/.env.local << 'EOF'
DYNAMODB_ENDPOINT_URL=http://localhost:8000
DYNAMODB_TABLE_NAME=tf-3-aiops-idempotency-lock

SQS_ENDPOINT_URL=http://localhost:4566
SQS_QUEUE_URL=http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/alert-queue

SNS_ENDPOINT_URL=http://localhost:4566
SNS_TOPIC_ARN=arn:aws:sns:us-east-1:000000000000:tf3-cdo1-sandbox-alerts-escalation

FIREHOSE_ENDPOINT_URL=http://localhost:4566
FIREHOSE_STREAM_NAME=tf3-cdo1-sandbox-audit-stream

AI_ENGINE_URL=http://localhost:8080

AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
AWS_DEFAULT_REGION=us-east-1

# Đổi thành false khi muốn test Firehose/SNS thật (K8s sẽ fail → path FAILED)
DRY_RUN=true
EOF
```

---

## Bước 4 — Chạy Webhook Receiver

**Terminal 4:**
```bash
cd /Users/tan/Desktop/teamwork-capstone/capstone-phase2/capstone/tf-3/cdo-1/app/webhook-receiver

SQS_QUEUE_URL=http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/alert-queue \
DYNAMODB_ENDPOINT_URL=http://localhost:8000 \
SQS_ENDPOINT_URL=http://localhost:4566 \
AWS_ACCESS_KEY_ID=test \
AWS_SECRET_ACCESS_KEY=test \
python3 -m uvicorn src.main:app --port 8443 --reload
```

Kiểm tra: `curl http://localhost:8443/health` → `{"status":"ok"}`

---

## Bước 5 — Chạy SQS Worker

**Terminal 5:**
```bash
cd /Users/tan/Desktop/teamwork-capstone/capstone-phase2/capstone/tf-3/cdo-1/app/sqs-worker

python3 src/main.py
```

Worker đang chạy khi thấy:
```
INFO cdo-self-heal-worker: Starting SQS Polling on: http://sqs...us-east-1...alert-queue
```

Worker sẽ poll liên tục (long-poll 20s). Để ý terminal này khi test các kịch bản bên dưới.

---

## Bước 6 — Test các kịch bản

Dùng terminal mới để chạy curl. Quan sát **Terminal 5 (worker)** sau mỗi lần gửi.

---

### 🟢 Kịch bản 1 — Happy Path: PodOOMKilled, tenant-payment

**Gửi alert:**
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
        "description": "Memory limit exceeded. Current: 256Mi. Usage: 257Mi."
      },
      "startsAt": "2026-06-29T10:00:00Z"
    }]
  }'
```

**Kết quả mong đợi từ webhook:** `{"status":"accepted","queued":1}`  
**Kết quả mong đợi ở worker (Terminal 5):**
```
INFO: Received message ID: ...
INFO: audit_emit_ok event_type=INCIDENT_START
INFO: Invoking /v1/detect for payment-api...
INFO: audit_emit_ok event_type=DETECT
INFO: Invoking /v1/decide for payment-api...
INFO: audit_emit_ok event_type=DECIDE
INFO: audit_emit_ok event_type=EXECUTE_START
INFO [DRY_RUN] k8s patch deployment=payment-api ns=tenant-payment ...
INFO [DRY_RUN] fast_lane_git_commit ...
INFO [DRY_RUN] argocd PATCH ...
INFO: audit_emit_ok event_type=EXECUTE_DONE
INFO: Invoking /v1/verify...
INFO: audit_emit_ok event_type=VERIFY
INFO: Self-heal successfully completed and verified for service 'payment-api'
```

---

### 🟢 Kịch bản 2 — Happy Path: PodCrashLooping, tenant-checkout

```bash
curl -s -X POST http://localhost:8443/alerts \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: 6c8b4b2b-4d45-4209-a1b4-4b532d56a31c" \
  -d '{
    "alerts": [{
      "status": "firing",
      "labels": {
        "alertname": "PodCrashLooping",
        "namespace": "tenant-checkout",
        "service": "checkout-api",
        "severity": "critical",
        "pod": "checkout-api-abc123",
        "container": "checkout-main"
      },
      "annotations": { "summary": "Pod crash looping" },
      "startsAt": "2026-06-29T10:05:00Z"
    }]
  }'
```

**Kết quả mong đợi:** 202, worker xử lý tương tự kịch bản 1 nhưng với `tenant-checkout` và `signal_name=container_restart_count`.

---

### 🔴 Kịch bản 3 — 409 Duplicate (idempotency lock)

Gửi lại **đúng payload** của Kịch bản 1 (cùng namespace + service + alertname) **trong vòng 180 giây**:

```bash
curl -s -X POST http://localhost:8443/alerts \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: d3b07384-d113-495f-9f58-20d18d357d75" \
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

**Kết quả mong đợi:** HTTP 409 `{"detail":"alert already being processed"}`. Worker không nhận thêm message.

**Xác nhận lock trong DynamoDB:**
```bash
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws dynamodb scan \
  --table-name tf-3-aiops-idempotency-lock \
  --endpoint-url http://localhost:8000 \
  --region us-east-1
```
Thấy item với `lock_key` là SHA256 của `tenant-payment#tenant-payment#payment-api#PodOOMKilled`.

---

### 🔴 Kịch bản 4 — 403 Cross-tenant (header sai)

Header `X-Tenant-Id` là checkout nhưng payload namespace là payment:

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

**Kết quả mong đợi:** HTTP 403 `{"detail":"SECURITY_VIOLATION: ..."}`. Không có message nào trên SQS.

---

### 🟣 Kịch bản 5 — Namespace không thuộc tenant nào

```bash
curl -s -X POST http://localhost:8443/alerts \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: d3b07384-d113-495f-9f58-20d18d357d75" \
  -d '{
    "alerts": [{
      "status": "firing",
      "labels": {
        "alertname": "PodOOMKilled",
        "namespace": "some-unknown-namespace",
        "service": "random-service",
        "severity": "critical"
      }
    }]
  }'
```

**Kết quả mong đợi:** HTTP **403 SECURITY_VIOLATION** từ webhook — KHÔNG phải 202.

**Lý do:** Webhook kiểm tra namespace ngay ở bước 1 (`TENANT_ID_BY_NAMESPACE.get(namespace)` → `None`) → không khớp tenant header → 403. Không có message nào được đẩy lên SQS.

> **Lưu ý về code worker:** Worker có đoạn `if not tenant_id: skip message` là safety net cho edge case (ví dụ ai đó bypass webhook và push thẳng vào SQS). Đoạn code này không reachable qua webhook bình thường nên không test được theo con đường này.

---

### 🟠 Kịch bản 6 — Circuit Breaker đang OPEN

**Bước 1 — Inject CB OPEN vào DynamoDB thủ công:**
```bash
# Dùng tenant-payment và service payment-api (thay UUID nếu cần)
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws dynamodb put-item \
  --table-name tf-3-aiops-idempotency-lock \
  --item '{
    "lock_key":            {"S": "cb#d3b07384-d113-495f-9f58-20d18d357d75#tenant-payment#payment-api"},
    "status":             {"S": "OPEN"},
    "failure_timestamps": {"SS": ["1751191200","1751192400","1751193600"]},
    "expiration_time":    {"N": "9999999999"}
  }' \
  --endpoint-url http://localhost:8000 \
  --region us-east-1
```

**Bước 2 — Đợi cooldown lock cũ hết (>180s) hoặc đổi service name:**
```bash
# Gửi alert cho payment-api (đã bị CB OPEN)
curl -s -X POST http://localhost:8443/alerts \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: d3b07384-d113-495f-9f58-20d18d357d75" \
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

**Kết quả mong đợi ở worker:**
```
WARNING: Circuit Breaker is OPEN for service 'payment-api'... Skipping.
INFO: audit_emit_ok event_type=INCIDENT_START
INFO: audit_emit_ok event_type=ESCALATE
```

**Dọn dẹp sau khi test (reset CB về CLOSED):**
```bash
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws dynamodb delete-item \
  --table-name tf-3-aiops-idempotency-lock \
  --key '{"lock_key": {"S": "cb#d3b07384-d113-495f-9f58-20d18d357d75#tenant-payment#payment-api"}}' \
  --endpoint-url http://localhost:8000 \
  --region us-east-1
```

---

## Bước 7 — Kiểm tra kết quả

### Kiểm tra SQS (messages đã được xử lý chưa)

Sau khi worker xử lý xong, queue phải trống:
```bash
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws sqs get-queue-attributes \
  --queue-url http://localhost:4566/000000000000/alert-queue \
  --attribute-names ApproximateNumberOfMessages \
  --endpoint-url http://localhost:4566 \
  --region us-east-1
```
`ApproximateNumberOfMessages: 0` = worker đã xử lý và xóa message.

### Kiểm tra Firehose → S3 (audit logs)

> **Quan trọng:** Với `DRY_RUN=true`, worker log sẽ in `[DRY_RUN] audit_emit` — Firehose **không** được gọi và S3 sẽ **luôn trống**. Đây là hành vi đúng.

**Để test Firehose thật, đổi sang `DRY_RUN=false`** trong `.env.local`, khởi động lại worker.  
K8s patch sẽ thất bại (không có cluster) → nhưng tất cả audit logs trước đó (`INCIDENT_START`, `DETECT`, `DECIDE`, `EXECUTE_START`, `EXECUTE_DONE(FAILED)`, `ESCALATE`) vẫn được gửi Firehose thật.

```bash
# Sau khi gửi alert với DRY_RUN=false, đợi ~15s rồi kiểm tra:
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws s3 ls s3://tf-3-aiops-audit-trail/audit/ --recursive \
  --endpoint-url http://localhost:4566

# Đọc nội dung file audit (thay <key> bằng path từ lệnh ls trên)
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws s3 cp "s3://tf-3-aiops-audit-trail/audit/<key>" - \
  --endpoint-url http://localhost:4566 | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if line:
        print(json.dumps(json.loads(line), indent=2, ensure_ascii=False))
        print('---')
"
```

Mỗi dòng trong file là 1 JSON record. Với `DRY_RUN=false` và K8s không có, thứ tự sẽ là:  
`INCIDENT_START → DETECT → DECIDE → EXECUTE_START → EXECUTE_DONE(FAILED) → ESCALATE`

**Phân biệt 2 chế độ qua worker log:**
- `DRY_RUN=true` → `[DRY_RUN] audit_emit event_type=INCIDENT_START ...` (không gửi Firehose)
- `DRY_RUN=false` → `audit_emit_ok event_type=INCIDENT_START ... record_id=xxx` (gửi Firehose thật)

### Kiểm tra DynamoDB (idempotency lock)

```bash
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws dynamodb scan \
  --table-name tf-3-aiops-idempotency-lock \
  --endpoint-url http://localhost:8000 \
  --region us-east-1 \
  --output json | python3 -m json.tool
```

Mỗi item là 1 lock (idempotency) hoặc CB state. Field `lock_key`:
- Bắt đầu bằng `cb#` → Circuit Breaker entry
- Không có prefix → Idempotency lock (SHA256 của `tenant#namespace#service#alertname`)

### Kiểm tra SNS — Escalation (kịch bản CB)

Để xem SNS nhận được message, subscribe 1 SQS queue vào topic trước khi test:
```bash
# Tạo queue hứng SNS
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws sqs create-queue --queue-name escalation-monitor \
  --endpoint-url http://localhost:4566 --region us-east-1

# Subscribe queue vào SNS topic
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws sns subscribe \
  --topic-arn arn:aws:sns:us-east-1:000000000000:tf3-cdo1-sandbox-alerts-escalation \
  --protocol sqs \
  --notification-endpoint arn:aws:sqs:us-east-1:000000000000:escalation-monitor \
  --endpoint-url http://localhost:4566 --region us-east-1

# Sau khi test kịch bản CB, đọc messages:
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
aws sqs receive-message \
  --queue-url http://localhost:4566/000000000000/escalation-monitor \
  --endpoint-url http://localhost:4566 --region us-east-1
```

---

## Bước 8 — Chạy automated tests (không cần Docker)

```bash
cd capstone/tf-3/cdo-1/app
python3 -m pytest tests/ -v --cov=. --cov-fail-under=70
```

Tests dùng `moto` mock hoàn toàn — không cần LocalStack hay DynamoDB Local đang chạy.

---

## Env vars tham chiếu

| Biến | Local | EKS (không set) |
|---|---|---|
| `DYNAMODB_ENDPOINT_URL` | `http://localhost:8000` | — |
| `SQS_ENDPOINT_URL` | `http://localhost:4566` | — |
| `SNS_ENDPOINT_URL` | `http://localhost:4566` | — |
| `FIREHOSE_ENDPOINT_URL` | `http://localhost:4566` | — |
| `SQS_QUEUE_URL` | LocalStack URL ở trên | URL SQS thật từ ST1 |
| `SNS_TOPIC_ARN` | `arn:aws:sns:us-east-1:000000000000:tf3-cdo1-sandbox-alerts-escalation` | ARN thật từ ST1 |
| `AI_ENGINE_URL` | `http://localhost:8080` | `http://ai-engine.self-heal-system.svc.cluster.local:8080` |
| `DRY_RUN` | `true` | `false` |
| `AWS_ACCESS_KEY_ID` | `test` | — (IRSA) |
| `AWS_SECRET_ACCESS_KEY` | `test` | — (IRSA) |

**Nguyên tắc Zero-Code-Change:** Không bao giờ hardcode endpoint URL trong code — chỉ đọc từ env var. Khi không có `*_ENDPOINT_URL`, boto3 tự dùng IRSA trên EKS.

---

---

## Test /metrics endpoint (sau khi setup xong)

### Webhook receiver /metrics

```bash
# Terminal 6 — webhook
cd capstone/tf-3/cdo-1/app/webhook-receiver
python3 -m uvicorn src.main:app --port 8443 --reload &

# Xem raw Prometheus text format
curl -s http://localhost:8443/metrics | head -40
```

**Output mong đợi** (dạng Prometheus text format):
```
# HELP http_requests_total Total number of HTTP requests
# TYPE http_requests_total counter
http_requests_total{handler="/alerts",method="POST",status_code="202"} 0.0
...
# HELP webhook_alerts_queued_total Number of alerts successfully pushed to SQS
# TYPE webhook_alerts_queued_total counter
webhook_security_violations_total 0.0
webhook_duplicate_alerts_total{tenant_id="..."} 0.0
webhook_alerts_queued_total{tenant_id="..."} 0.0
```

**Gửi 1 alert để counter tăng:**
```bash
curl -s -X POST http://localhost:8443/alerts \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: d3b07384-d113-495f-9f58-20d18d357d75" \
  -d '{"alerts":[{"status":"firing","labels":{"alertname":"PodOOMKilled","namespace":"tenant-payment","service":"order-service"},"annotations":{"summary":"OOM"}}]}'

# Sau khi gửi xong, curl /metrics lại và thấy counter tăng:
curl -s http://localhost:8443/metrics | grep webhook_alerts_queued
# webhook_alerts_queued_total{tenant_id="d3b07384-d113-495f-9f58-20d18d357d75"} 1.0
```

**Test security violation counter:**
```bash
curl -s -X POST http://localhost:8443/alerts \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: wrong-id" \
  -d '{"alerts":[{"status":"firing","labels":{"alertname":"PodOOMKilled","namespace":"tenant-payment","service":"order-service"}}]}'

curl -s http://localhost:8443/metrics | grep webhook_security_violations
# webhook_security_violations_total 1.0
```

---

### SQS Worker /metrics

Worker expose metrics qua port riêng **9090** (background thread — không ảnh hưởng SQS poll loop):

```bash
# Terminal 7 — worker (DynamoDB Local + LocalStack phải đang chạy)
cd capstone/tf-3/cdo-1/app/sqs-worker
cp ../webhook-receiver/src/security.py src/security.py   # cần thiết
python3 src/main.py &
# Log xuất hiện: "Prometheus metrics server started on port 9090 (/metrics)"

# Xem metrics ngay (ngay cả khi chưa có message nào)
curl -s http://localhost:9090/metrics | grep -E "^(# HELP|worker_)"
```

**Output mong đợi:**
```
# HELP worker_messages_processed_total Total SQS messages processed
# TYPE worker_messages_processed_total counter
# HELP worker_ai_call_duration_seconds Latency of AI Engine HTTP calls
# TYPE worker_ai_call_duration_seconds histogram
# HELP worker_ai_errors_total AI Engine errors by endpoint and HTTP status code
# TYPE worker_ai_errors_total counter
# HELP worker_executions_total Self-heal executions by action, lane and outcome
# TYPE worker_executions_total counter
# HELP worker_circuit_breaker_open_total ...
# HELP worker_circuit_breaker_skips_total ...
# HELP worker_escalations_total ...
# HELP worker_rollbacks_total ...
```

**Sau khi gửi alert từ webhook và worker xử lý xong:**
```bash
# Counter sẽ có giá trị
curl -s http://localhost:9090/metrics | grep -v "^#" | grep worker_
```

**Ví dụ output sau 1 happy path (với AI demo → exception path do namespace="production"):**
```
worker_messages_processed_total{status="FAILED"} 1.0
worker_escalations_total{reason="EXCEPTION"} 1.0
worker_ai_call_duration_seconds_count{endpoint="/v1/detect"} 1.0
worker_ai_call_duration_seconds_count{endpoint="/v1/decide"} 1.0
```

> **Lưu ý:** AI demo luôn trả `namespace="production"` → `_guard_ns()` raise PermissionError → worker vào exception path → counter `status="FAILED"`. Đây là behavior đúng với AI demo. Khi dùng AI Engine thật trên EKS → worker sẽ trả `status="COMPLETED"`.

---

## EKS Production — Giá trị thật từ Infra (ST1)

Khi deploy lên EKS, điền các giá trị sau vào K8s ConfigMap/Secret (ST3 lo phần này):

```
SQS_QUEUE_URL     = https://sqs.us-east-1.amazonaws.com/474013238625/tf3-cdo1-sandbox-self-heal-queue
SNS_TOPIC_ARN     = arn:aws:sns:us-east-1:474013238625:tf3-cdo1-sandbox-alerts-escalation
FIREHOSE_STREAM   = tf3-cdo1-sandbox-audit-stream
AI_ENGINE_URL     = http://ai-engine.self-heal-system.svc.cluster.local:8080
DRY_RUN           = false
AWS_DEFAULT_REGION = us-east-1
```

**Không set** `*_ENDPOINT_URL` trên EKS — boto3 sẽ tự dùng IRSA credentials.

**IRSA roles (ST1 đã tạo):**
- Webhook Receiver: `arn:aws:iam::474013238625:role/tf3-cdo1-sandbox-irsa-webhook-receiver`
- SQS Worker: `arn:aws:iam::474013238625:role/tf3-cdo1-sandbox-irsa-audit-writer`

**Metrics endpoints (cho ST3 cấu hình Prometheus scrape):**
- Webhook Receiver: `http://<pod-ip>:8443/metrics`
- SQS Worker: `http://<pod-ip>:9090/metrics`

---

## Ghi chú — Giới hạn khi test local

| Giới hạn | Lý do | Cách xử lý |
|---|---|---|
| AI luôn trả `anomaly_detected=true` | Demo skeleton cứng kết quả | Không test được kịch bản "no anomaly" — cần AI thật |
| AI luôn trả `next_action=DONE` | Demo skeleton không có verify logic | Không test được ROLLBACK/ESCALATE từ verify — cần AI thật |
| K8s patch và Git commit không thật | `DRY_RUN=true` | Xem log `[DRY_RUN]` để xác nhận logic đúng |
| Execute không thể thật sự FAILED | DRY_RUN skip K8s call | Inject CB OPEN trực tiếp vào DynamoDB (xem kịch bản 6) |
