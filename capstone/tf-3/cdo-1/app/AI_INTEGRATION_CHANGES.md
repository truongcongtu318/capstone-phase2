# CDO-01 App — Thay đổi tích hợp Real AI Engine

Tài liệu này ghi lại tất cả thay đổi thực hiện để tích hợp CDO app (sqs-worker, webhook-receiver) với real AI engine (`detect_decide_verify`) thay thế demo stub.

---

## Tóm tắt nhanh: CDO app có cần sửa thêm không?

**Không.** Sau các thay đổi dưới đây, CDO app đã sẵn sàng test với real AI engine. Không cần sửa thêm code.

---

## 1. `sqs-worker/src/main.py`

### Thay đổi 1a: Fix `signal_name` mapping

**Vấn đề:** `signal_name = "queue_backlog_event"` (default cũ) **không có** trong `CONTRACT_SIGNAL_NAMES` của real AI engine. Real AI sẽ trả HTTP 400 khi nhận giá trị này.

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
elif alertname == "PodCrashLooping":
    signal_name = "container_restart_count"

# Sau:
signal_name = "queue_backlog"        # ✅ default đúng
telemetry_value: object = 1000
if alertname == "PodOOMKilled":
    signal_name = "pod_oom_event"
    telemetry_value = f"OOMKilled: Container {labels.get('container', 'main')}, Pod {labels.get('pod', service)}"
elif alertname == "PodCrashLooping":
    signal_name = "container_restart_count"
    telemetry_value = 5
elif alertname == "ServiceStuck":
    signal_name = "service_unhealthy"    # ✅ mới
    telemetry_value = "Readiness probe failed: service not responding"
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
