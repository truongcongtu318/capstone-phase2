# CDO-01 App — Thay đổi tích hợp Real AI Engine

Tài liệu này ghi lại tất cả thay đổi thực hiện để tích hợp CDO app (sqs-worker, webhook-receiver) với real AI engine (`detect_decide_verify`) thay thế demo stub.

---

## Tóm tắt nhanh: CDO app có cần sửa thêm không?

**Không.** Sau các thay đổi dưới đây, CDO app đã sẵn sàng test với real AI engine. Không cần sửa thêm code.

---

## 1. `sqs-worker/src/main.py`

### Thay đổi 1a: Fix `signal_name` mapping + telemetry value phải là float

**Vấn đề 1:** `signal_name = "queue_backlog_event"` (default cũ) **không có** trong `CONTRACT_SIGNAL_NAMES` của real AI engine. Real AI sẽ trả HTTP 400 khi nhận giá trị này.

**Vấn đề 2:** Real AI engine `telemetry.py` gọi `float(point.value)` cho mọi telemetry point. Các giá trị string như `"OOMKilled: Container None, Pod None"` hay `"Readiness probe failed..."` → `ValueError` → HTTP 500. Tất cả `value` phải là số (float).

**Enum hợp lệ** (12 giá trị từ `telemetry-contract.md`):
```
pod_oom_event, container_restart_count, service_unhealthy, queue_backlog,
service_error_rate, service_latency_p95, container_resource_usage,
application_log_event, distributed_trace_error_event, service_throughput_rps,
secret_expiry_warning, db_connection_pool_saturation
```

**Fix:**
```python
# Trước:
signal_name = "queue_backlog_event"  # ❌ không trong enum
if alertname == "PodOOMKilled":
    signal_name = "pod_oom_event"
    telemetry_value = f"OOMKilled: ..."  # ❌ string → float() fail → HTTP 500

# Sau:
signal_name = "queue_backlog"          # ✅ default đúng
telemetry_value: float = 1000.0        # ✅ float, không phải object/string
if alertname == "PodOOMKilled":
    signal_name = "pod_oom_event"
    telemetry_value = 1.0              # ✅ count; context đã có trong labels.pod_name/container
elif alertname == "PodCrashLooping":
    signal_name = "container_restart_count"
    telemetry_value = 5.0              # ✅ restart count
elif alertname == "ServiceStuck":
    signal_name = "service_unhealthy"  # ✅ mới
    telemetry_value = 1.0              # ✅ 1 = unhealthy state
```

### Thay đổi 1b: Truyền `namespace_override` vào patch_executor

**Vấn đề:** Real AI engine's `self_healer.py` dùng `params.setdefault("namespace", namespace)` — vì các runbook trong catalog có `"namespace": "production"` hardcoded, `setdefault` **không override** được. Real AI luôn trả `params.namespace = "production"`.

Nếu CDO dùng namespace này, `_guard_ns("production")` sẽ raise `PermissionError` và execution FAIL.

**Fix:**
```python
# Trước:
snapshot = patch_executor.capture_pre_state(decide_resp, settings.dry_run)
exec_result = patch_executor.execute(decide_resp, correlation_id, settings.dry_run)

# Sau:
snapshot = patch_executor.capture_pre_state(decide_resp, settings.dry_run,
                                            namespace_override=namespace)
exec_result = patch_executor.execute(decide_resp, correlation_id, settings.dry_run,
                                     namespace_override=namespace)
```

---

## 2. `sqs-worker/src/patch_executor.py`

### Thay đổi: Thêm `namespace_override` parameter

Cả `capture_pre_state()` và `execute()` nhận thêm param `namespace_override: str = ""`. Khi được truyền vào:

```python
# Trước:
ns = params.get("namespace", "")   # lấy từ AI response → "production"

# Sau:
ns = namespace_override or params.get("namespace", "")  # ưu tiên namespace từ alert gốc
```

`_guard_ns(ns)` chỉ cho phép `{"tenant-payment", "tenant-checkout"}`. Với `namespace_override` từ alert, luôn pass được guard.

---

## 3. `webhook-receiver/src/main.py`

### Thay đổi: Thêm `PodCrashLooping` vào alertname filter

**Vấn đề:** Worker `main.py` xử lý `PodCrashLooping` (→ `container_restart_count`) nhưng webhook **drop** nó trước khi đẩy vào SQS. Alert không bao giờ tới worker.

```python
# Trước:
alertname in ["PodOOMKilled", "ServiceStuck", "SQSQueueBacklog"]

# Sau:
alertname in ["PodOOMKilled", "PodCrashLooping", "ServiceStuck", "SQSQueueBacklog"]
```

---

## 4. `app/platform_profile_cdo01.json` (file mới)

File cấu hình CDO-01 cho real AI engine, tuân theo `platform_profile.schema.json`.

**Cung cấp cho AI team** — họ đặt vào `adr/` trong repo AI engine và set env var:
```
PLATFORM_PROFILE_PATH=./adr/platform_profile_cdo01.json
```

Nội dung chính:
- `system`: `CDO-CHECKOUT-PAYMENT`
- `services`: `checkout-api`, `checkout-frontend`, `checkout-worker`, `order-api`, `payment-worker`
- `allowed_namespaces`: `tenant-checkout`, `tenant-payment`
- `default_namespace`: `tenant-checkout`
- `fault_runbook_mapping`: `mem → MemoryLeakRecoveryRunbook`, `delay → NetworkLatencyRecoveryRunbook`, etc.
- `runbooks`: 7 runbooks với namespace `tenant-checkout` (không phải "production")

---

## 5. GitOps & Pipeline changes

### `app-pipeline.yml`
- `paths`: thay `capstone/tf-3/ai/demo/**` → `capstone/tf-3/ai/ai-engine/detect_decide_verify/**`
- Matrix entry `ai-engine-demo` → `ai-engine`, dir `capstone/tf-3/ai/ai-engine/detect_decide_verify`, ECR `tf-3-ai-engine`

### `gitops/manifests/base/ai-engine/deployment.yaml`
- Image: `tf-3-ai-engine-demo` → `tf-3-ai-engine`
- Xóa `readOnlyRootFilesystem: true` (AI engine cần write access cho temp files)
- Thêm `envFrom: configMapRef: ai-engine-config`

### `gitops/manifests/base/ai-engine/configmap.yaml`
- Thêm toàn bộ env vars của real AI engine: `PLATFORM_PROFILE_PATH`, `SYSTEM_NAME`, `ALLOWED_NAMESPACES`, `API_PORT=8080`, `USE_LLM_DECISION`, `LLM_PROVIDER=bedrock`, etc.

### `gitops/manifests/overlays/sandbox/ai-engine/kustomization.yaml`
- Image name: `tf-3-ai-engine-demo` → `tf-3-ai-engine`

---

## Alert → signal_name mapping (reference)

| Alert name | `signal_name` | `value` |
|---|---|---|
| `PodOOMKilled` | `pod_oom_event` | String mô tả OOM (→ PATCH_MEMORY_LIMIT) |
| `PodCrashLooping` | `container_restart_count` | `5` (int) (→ RESTART_DEPLOYMENT) |
| `ServiceStuck` | `service_unhealthy` | String mô tả (→ RESTART_DEPLOYMENT) |
| `SQSQueueBacklog` | `queue_backlog` | `1000` (int) (→ SCALE_REPLICAS) |

---

## Note: LLM_MODEL cần điền thủ công

`.env` và configmap để `LLM_MODEL=` trống. Cần điền trước khi chạy với `USE_LLM_DECISION=True`. Ví dụ:
- `us.anthropic.claude-3-5-sonnet-20241022-v2:0` (Bedrock cross-region inference)
- `us.anthropic.claude-3-haiku-20240307-v1:0` (nhanh, rẻ hơn)

---

## 6. Kube-linter fix: `readOnlyRootFilesystem`

**Vấn đề:** kube-linter enforce policy `no-read-only-root-fs` — deployment phải có `readOnlyRootFilesystem: true`. AI engine ban đầu không có → CI fail.

**Fix trong `gitops/manifests/base/ai-engine/deployment.yaml`:**
```yaml
securityContext:
  readOnlyRootFilesystem: true      # bắt buộc theo policy
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
env:
  - name: HOME
    value: /tmp                     # Python libs write to /tmp thay vì root fs
volumeMounts:
  - name: tmp
    mountPath: /tmp
volumes:
  - name: tmp
    emptyDir: {}                    # /tmp cần writable cho temp files
```

> Note: AI engine (và Python nói chung) cần `/tmp` writable. Giải pháp đúng là mount emptyDir vào `/tmp` + set `HOME=/tmp` — không phải bỏ `readOnlyRootFilesystem`.

---

## 7. Gitleaks fix: False positive từ test JSON files

**Vấn đề:** gitleaks quét git history và phát hiện UUID trong `cdo_simulator/test_jsons/*.json` là "generic-api-key" (15 findings). Đây là `idempotency_key` test fixture, không phải secret thật.

**Fix 1: `.gitleaks.toml`** (tạo mới ở repo root):
```toml
[allowlist]
  description = "Ignore test fixture JSON files — UUIDs flagged as generic-api-key are idempotency keys"
  paths = [
    '''.*/cdo_simulator/test_jsons/.*\.json''',
    '''.*/test_jsons/.*\.json''',
  ]
```

**Fix 2: `.gitignore`** — thêm dòng để ngăn commit test JSON vào tương lai:
```
**/cdo_simulator/test_jsons/
```

---

## 8. Terraform IAM: Allow cross-region inference profile (Llama 4 Scout)

**Vấn đề:** Llama 4 Scout (`us.meta.llama4-scout-17b-instruct-v1:0`) dùng cross-region inference — ARN type là `inference-profile/*`, không phải `foundation-model/*`. IAM policy cũ chỉ có `foundation-model/*` → Bedrock API trả `AccessDeniedException`.

**File:** `capstone/tf-3/cdo-1/infra/modules/observability/main.tf`

```hcl
# Trước:
Resource = [
  "arn:aws:bedrock:us-east-1::foundation-model/*",
]

# Sau:
Resource = [
  "arn:aws:bedrock:us-east-1::foundation-model/*",
  "arn:aws:bedrock:us-east-1::inference-profile/*",
]
```

> Apply qua `cd infra/environments/sandbox/services && terraform apply`

---

## 9. LLM_MODEL: Chọn Llama 4 Scout

**Cập nhật tại 2 chỗ:**

**`capstone/tf-3/cdo-1/gitops/manifests/base/ai-engine/configmap.yaml`** (cho EKS):
```yaml
LLM_MODEL: "us.meta.llama4-scout-17b-instruct-v1:0"
```

**`capstone/tf-3/ai/ai-engine/detect_decide_verify/.env`** (cho local test, gitignored):
```
LLM_MODEL=us.meta.llama4-scout-17b-instruct-v1:0
```

> Model ID phải có prefix `us.` để dùng cross-region inference profile. Không dùng `meta.llama4-scout-17b-instruct-v1:0` (thiếu prefix → fallback về foundation-model ARN → fail với model này).

---

## 10. AI engine `.env` local testing

**File:** `capstone/tf-3/ai/ai-engine/detect_decide_verify/.env` (gitignored — không push lên)

Config chính cho local dev:
- `PLATFORM_PROFILE_PATH=./adr/platform_profile_cdo01.json`
- `TELEMETRY_RUNTIME_MODE=bench` — CDO gửi telemetry_window trực tiếp trong request body
- `USE_LLM_DECISION=True`, `LLM_PROVIDER=bedrock`, `LLM_MODEL=us.meta.llama4-scout-17b-instruct-v1:0`
- `AWS_ACCESS_KEY_ID=`, `AWS_SECRET_ACCESS_KEY=` (trống — dùng IRSA trên EKS / `AWS_PROFILE` local)

> Config trên EKS đến từ `configmap.yaml`, không phải `.env`. `.env` chỉ dùng khi chạy AI engine local.

---

## Tổng hợp: Files đã thay đổi

| File | Loại thay đổi |
|---|---|
| `app/sqs-worker/src/main.py` | signal_name fix + namespace_override |
| `app/sqs-worker/src/patch_executor.py` | namespace_override parameter |
| `app/webhook-receiver/src/main.py` | thêm PodCrashLooping |
| `app/platform_profile_cdo01.json` | file mới — CDO platform profile |
| `gitops/manifests/base/ai-engine/deployment.yaml` | image + readOnlyRootFilesystem + emptyDir |
| `gitops/manifests/base/ai-engine/configmap.yaml` | env vars cho real AI engine |
| `gitops/manifests/overlays/sandbox/ai-engine/kustomization.yaml` | image name tf-3-ai-engine |
| `.github/workflows/app-pipeline.yml` | build real AI engine, not demo |
| `infra/modules/observability/main.tf` | inference-profile/* IAM resource |
| `capstone/tf-3/ai/ai-engine/detect_decide_verify/adr/platform_profile_cdo01.json` | copy vào AI engine image |
| `capstone/tf-3/ai/ai-engine/detect_decide_verify/.env` | local config (gitignored) |
| `.gitleaks.toml` | allowlist test fixture UUIDs |
| `.gitignore` | ignore cdo_simulator/test_jsons/ |
