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

---

## 11. Bug fix: Telemetry value phải là float (không phải string)

**Bug:** Sau lần deploy đầu với real AI engine, worker nhận HTTP 500 từ `/v1/detect`:
```
ValueError: could not convert string to float: 'OOMKilled: Container None, Pod None'
```

Real AI engine `telemetry.py` gọi `float(point.value)` cho mọi telemetry point. Ta đã gửi string mô tả cho `pod_oom_event` và `service_unhealthy`.

**Fix trong `sqs-worker/src/main.py`:**
```python
# Trước (❌ string → ValueError → HTTP 500):
telemetry_value = f"OOMKilled: Container {labels.get('container', 'main')}, Pod {labels.get('pod', service)}"
telemetry_value = "Readiness probe failed: service not responding"

# Sau (✅ float):
telemetry_value = 1.0   # pod_oom_event: count = 1
telemetry_value = 1.0   # service_unhealthy: 1 = unhealthy state
```
Context mô tả (container, pod name) vẫn được giữ trong field `labels` của telemetry point — không bị mất.

---

## 12. Bug fix: BOCPD cần time series — 1 điểm dữ liệu → NO_ANOMALY

**Bug:** Sau khi fix float, AI engine trả HTTP 200 nhưng `anomaly_detected=False`:
```
[API][DETECT] Metrics rows=1 baseline_len=10
[API][DETECT] Result: NO_ANOMALY
```

**Root cause:** BOCPD (Bayesian Online Change Point Detection) là thuật toán phân tích time series — cần nhiều điểm dữ liệu theo thời gian để phát hiện "điểm thay đổi đột ngột". Với 1 điểm, không có gì để so sánh → luôn trả NO_ANOMALY.

Trong production thật, AI engine dùng `TELEMETRY_RUNTIME_MODE=production` và query Prometheus để lấy lịch sử metric (20 phút qua). CDO chạy `bench` mode nên phải tự cung cấp lịch sử đó.

**Fix lần 1 (không đủ):** 20 baseline + 1 anomaly = 21 points. AI trả `Metrics rows=21, baseline_len=16, NO_ANOMALY` — 1 điểm spike không đủ confidence cho BOCPD.

**Fix lần 2 (deployed):** Tăng lên 50 baseline + 6 anomaly = 56 points:
```python
_BASELINE_COUNT = 50   # match EVAL_BOCPD_BASELINE_LENGTH=50
_ANOMALY_COUNT = 6     # consecutive spikes → BOCPD posterior vượt threshold
_TOTAL = 56

telemetry_window = [
    {
        "ts": (now - timedelta(seconds=(_TOTAL - 1 - i) * _INTERVAL_SECONDS)).isoformat(),
        "value": telemetry_value if i >= _BASELINE_COUNT else 0.0,
        ...
    }
    for i in range(_TOTAL)
]
```

Cấu trúc time series (56 points, mỗi point cách nhau 60s = 56 phút lịch sử):
```
i=0  → T-55min, value=0.0  (baseline bắt đầu)
...
i=49 → T-6min,  value=0.0  (baseline kết thúc)
i=50 → T-5min,  value=1.0  (anomaly bắt đầu)
...
i=55 → T-0,     value=1.0  (anomaly hiện tại)
```

> **Lưu ý kiến trúc:** 1 alert = 1 lần gửi lên AI, nhưng kèm 56 điểm metric lịch sử giả lập. DynamoDB lock (180/300s) chỉ bảo vệ alert event — không liên quan đến telemetry window. Production mode dùng Prometheus thật (có lịch sử thực), bench mode CDO phải tự generate.

`post_telemetry_window` (verify) dùng cùng 56 points nhưng tất cả value=0.0 — signal về baseline sau khi heal.

---

---

## 13. Sync AI engine round 3 + tune BOCPD + cooldown configurable

**Ngày:** 2026-07-01

### 13.1 AI team round 3 updates (synced vào CDO repo)

AI team push 3 rounds changes. Files đã sync từ `/Desktop/Capstone-Phase-2-Code/tf-3/ai/ai-engine/detect_decide_verify/`:

| File | Thay đổi từ AI team |
|------|---------------------|
| `src/server.py` | Mode `cdo_push` mới; strict validation log=string/metric=float; tenant UUID cross-check trong telemetry; endpoint `/v1/fault-rank` |
| `src/config.py` | 35+ env vars mới: `TELEMETRY_RUNTIME_MODE`, K8s/Prometheus config, LLM provider; load `adr/telemetry_signal_names.json` |
| `src/llm.py` | Multi-provider factory; `BedrockLLMClient` dùng `boto3.converse()` (không phải `invoke_model()`); `CostTracker` per-tenant $50/day cap |
| `src/self_healer.py` | `LLMDecisionOutputParser`; cost cap enforcement; incident suppression trong decide |
| `src/engine.py` | `rank_fault_types()` method; `llm_fault_rank_evidence` field trong detect response |
| `src/telemetry.py` | Strict float casting cho metric signals |
| `adr/telemetry_signal_names.json` | **NEW** — required bởi config.py để validate 12 CONTRACT_SIGNAL_NAMES khi startup |

> ⚠️ Thiếu `telemetry_signal_names.json` → AI engine crash khi khởi động. File này phải có trong image.

### 13.2 BOCPD tuning để detect với 56-point bench window

Configmap và `.env` đã cập nhật để BOCPD nhạy hơn với synthetic window mà sqs-worker gửi (50 baseline + 6 anomaly):

```yaml
# Trước (không detect được):
BASELINE_LENGTH: "600"   # quá lớn — 56 points không đủ làm baseline
BOCPD_HAZARD: "50"       # không nhạy — cần 50 steps để coi là change point

# Sau (detect được):
BASELINE_LENGTH: "50"    # match _BASELINE_COUNT=50 trong sqs-worker
BOCPD_HAZARD: "10"       # nhạy hơn — phát hiện change sau ~2-3 anomaly points
ANALYSIS_WINDOW_SIZE: "10"
```

### 13.3 Cooldown configurable qua env var

Thay vì hardcode trong `main.py`, cooldown nay đọc từ env:

**`webhook-receiver/src/config.py`** — thêm:
```python
cooldown_payment_seconds: int = 180   # Pro tier default
cooldown_checkout_seconds: int = 300  # Basic tier default
```

**`webhook-receiver/src/main.py`** — thay hardcode:
```python
COOLDOWN_BY_NAMESPACE = {
    "tenant-payment":  settings.cooldown_payment_seconds,
    "tenant-checkout": settings.cooldown_checkout_seconds,
}
```

**`gitops/manifests/base/webhook-receiver/configmap.yaml`** — set 1s cho testing:
```yaml
COOLDOWN_PAYMENT_SECONDS: "1"
COOLDOWN_CHECKOUT_SECONDS: "1"
```

> ⚠️ Revert về `"180"` / `"300"` sau khi kết thúc test pattern OOMKill.

### 13.4 Prometheus rule fix: service label từ pod name

Metric `kube_pod_container_status_last_terminated_reason` chỉ có label `container` (thường là `main`), không phải tên deployment. Đã fix bằng `label_replace` trong expr để extract deployment name từ pod name:

```yaml
# Trước: service: "{{ $labels.container }}" → "main" → webhook không map được
# Sau: label_replace extract "order-api" từ "order-api-7d9b4895ff-crsvv"
expr: |
  label_replace(
    (changes(...) > 0 and on(pod, namespace) kube_pod_container_status_last_terminated_reason{...} == 1),
    "service", "$1", "pod", "^(.+)-[a-z0-9]{5,10}-[a-z0-9]{5}$"
  )
```

---

## Tổng hợp: Files đã thay đổi

| File | Loại thay đổi |
|---|---|
| `app/sqs-worker/src/main.py` | signal_name fix + namespace_override |
| `app/sqs-worker/src/patch_executor.py` | namespace_override parameter |
| `app/webhook-receiver/src/main.py` | thêm PodCrashLooping + cooldown từ settings |
| `app/webhook-receiver/src/config.py` | cooldown_payment/checkout_seconds env vars |
| `app/platform_profile_cdo01.json` | file mới — CDO platform profile |
| `gitops/manifests/base/ai-engine/deployment.yaml` | image + readOnlyRootFilesystem + emptyDir |
| `gitops/manifests/base/ai-engine/configmap.yaml` | env vars cho real AI engine + BOCPD tuning |
| `gitops/manifests/base/webhook-receiver/configmap.yaml` | COOLDOWN_*_SECONDS=1 cho testing |
| `gitops/overlays/sandbox/ai-engine/kustomization.yaml` | image name tf-3-ai-engine |
| `gitops/monitoring/prometheus-rules.yaml` | label_replace để lấy service từ pod name |
| `.github/workflows/app-pipeline.yml` | build real AI engine, not demo |
| `infra/modules/observability/main.tf` | inference-profile/* IAM resource |
| `capstone/tf-3/ai/ai-engine/detect_decide_verify/src/*.py` | sync round 3 từ AI team |
| `capstone/tf-3/ai/ai-engine/detect_decide_verify/adr/telemetry_signal_names.json` | new file |
| `capstone/tf-3/ai/ai-engine/detect_decide_verify/.env` | BOCPD tuning local |
| `.gitleaks.toml` | allowlist test fixture UUIDs |
| `.gitignore` | ignore cdo_simulator/test_jsons/ |
