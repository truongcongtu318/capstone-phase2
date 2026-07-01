# Handoff: SQS Worker — Remove Synthetic Baseline, Worker Queries Prometheus

## Trạng thái hiện tại

### Đã commit lên `app/tan-webhook`:
| Item | Trạng thái |
|------|-----------|
| Sync AI engine code round 3 (server, config, llm, self_healer, engine, telemetry) | ✅ |
| `adr/telemetry_signal_names.json` — file mới, required bởi config.py khi startup | ✅ |
| `ai-engine configmap`: BASELINE_LENGTH=50, BOCPD_HAZARD=10, ANALYSIS_WINDOW_SIZE=10 | ✅ |
| `webhook-receiver configmap`: COOLDOWN_PAYMENT/CHECKOUT_SECONDS=1 (test mode) | ✅ |
| `webhook-receiver/src/config.py + main.py`: cooldown đọc từ env var | ✅ |
| `prometheus-rules.yaml`: label_replace để extract service name từ pod name | ✅ |

### Đã hoàn thành session này (TDD — xem `sqs-worker/src/prometheus_query_client.py`):
| Item | Trạng thái |
|------|-----------|
| `sqs-worker/src/prometheus_query_client.py` — module mới: `query_range()` gọi Prometheus `/api/v1/query_range`, `build_telemetry_window()` build telemetry_window thật (fallback 1 điểm value=1.0 nếu Prometheus rỗng/lỗi/signal không map được) | ✅ |
| `sqs-worker/src/main.py` — xóa synthetic baseline (56 điểm giả), gọi `prometheus_query_client.build_telemetry_window()`; `post_telemetry_window` verify rút gọn còn 1 điểm value=0.0 | ✅ |
| `sqs-worker/src/config.py` — thêm `prometheus_url`, `prometheus_query_window_seconds` (600s), `prometheus_query_step_seconds` (30s) | ✅ |
| `gitops/manifests/base/sqs-worker/deployment.yaml` — thêm env `PROMETHEUS_URL`, `PROMETHEUS_QUERY_WINDOW_SECONDS`, `PROMETHEUS_QUERY_STEP_SECONDS` | ✅ |
| `tests/test_worker.py` — 6 test case mới cho prometheus_query_client (query_range success/empty/connection-error, build_telemetry_window success/fallback/unknown-signal) + cập nhật `test_worker_process_message_success` mock `prometheus_query_client.build_telemetry_window` và assert đúng namespace/service/signal_name được truyền vào | ✅ |
| `requirements.txt` (sqs-worker) — không cần đổi, `httpx` đã có sẵn | ✅ |
| NetworkPolicy — không cần đổi: `self-heal-system` chưa có NetworkPolicy nào target `app=sqs-worker`, nên egress ra `observability` namespace (Prometheus) không bị chặn | ✅ |

Toàn bộ 22 test pass, coverage 76.74% (>70% CI gate), `ruff check` sạch.

> ⚠️ Chưa test end-to-end trên cluster thật (cần EKS sandbox sống) — xem phần "Trigger real OOMKill" bên dưới, đây vẫn là việc cần làm tiếp theo.

### Round 2 — sau khi đọc lại code thật của team AI (`ai-engine/detect_decide_verify/src/`), phát hiện 2 bug + 1 gap và đã fix 2 bug:

| Item | Trạng thái |
|------|-----------|
| **Bug 1**: `execution_time_seconds` gửi lên `/v1/verify` là `float` (từ `time.monotonic()` diff), nhưng AI schema `ActionExecuted.execution_time_seconds` là `Optional[int]` (Pydantic strict — float có phần thập phân sẽ raise `int_from_float`). Verify thật (không dry-run) gần như luôn bị AI trả 422. | ✅ Fixed — `main.py::_to_ai_action_executed()` làm tròn bằng `round()` |
| **Bug 2**: Khi `DRY_RUN=true`, `patch_executor.execute()` trả `status="DRY_RUN"`, gửi thẳng lên `/v1/verify`, nhưng AI schema `ActionExecuted.status` là `Literal["COMPLETED","FAILED"]` — không có `DRY_RUN` → cũng 422. | ✅ Fixed — map `DRY_RUN` → `COMPLETED` trong `_to_ai_action_executed()` |
| Worker giờ chờ đúng `decide_resp["verify_policy"]["window_seconds"]` (do AI Engine chỉ định, mặc định 120s theo `runbook_catalog.py`) trước khi verify, thay vì verify ngay lập tức. Bỏ qua chờ khi `dry_run=True`. | ✅ Implemented — `main.py` gọi `time.sleep(wait_seconds)` |
| `post_telemetry_window` giờ re-query Prometheus thật qua `prometheus_query_client.build_telemetry_window()` (cùng hàm dùng cho detect), không còn gửi 1 điểm `0.0` bịa. | ✅ Implemented |
| **Gap chưa fix (cần trao đổi chéo team AI, CDO không tự sửa được)**: `verifier.py::verify_action()` chỉ coi `success=False`/`regression_detected=True` khi `signal_name` chứa chuỗi `"error"` hoặc `"latency"`. 4 signal của CDO (`pod_oom_event`, `container_restart_count`, `service_unhealthy`, `queue_backlog`) không chứa 2 từ đó → `/v1/verify` **luôn trả `success=True, next_action=DONE`** bất kể dữ liệu gửi lên là gì. Verify hiện tại không thực sự kiểm chứng được kết quả tự chữa lành cho các loại lỗi CDO đang xử lý. | ⚠️ Open — cần AI team mở rộng `verifier.py` hoặc CDO gửi thêm signal dạng `*_error_rate`/`*_latency` |
| **Gap khác đã ghi nhận (chưa fix)**: `engine.py::detect_anomalies()` tự tính `baseline_len = max(10, int(len(df_metrics)*0.8))`, **không dùng** biến `BASELINE_LENGTH` từ configmap cho API live (chỉ dùng cho benchmark offline `recovery_orchestrator.py`). Việc tune `BASELINE_LENGTH=50` trong round trước không có tác dụng với `/v1/detect` thật; chỉ `BOCPD_HAZARD` là thực sự ảnh hưởng. | ⚠️ Ghi nhận — cần theo dõi khi test OOMKill thật để biết cửa sổ 10 phút/30s-step (~20 điểm, baseline≈16) có đủ để BOCPD phát hiện hay không |

22 → 23 test pass, coverage 77.21%, ruff sạch.

---

## (Lịch sử) Việc đã lên kế hoạch — nay đã implement ở trên

### Task: Bỏ synthetic baseline khỏi sqs-worker, thay bằng real Prometheus data

**File cần sửa:** `capstone/tf-3/cdo-1/app/sqs-worker/src/main.py`

**Vấn đề hiện tại:**

Sqs-worker đang hardcode 50 baseline + 6 anomaly = 56 điểm giả lập cho mỗi alert:

```python
# Dòng 106-132 — CẦN XÓA PHẦN NÀY:
_BASELINE_COUNT = 50
_ANOMALY_COUNT = 6
_INTERVAL_SECONDS = 60
_TOTAL = _BASELINE_COUNT + _ANOMALY_COUNT
now = datetime.now(timezone.utc)
telemetry_window = [
    {
        "ts": (now - timedelta(seconds=(_TOTAL - 1 - i) * _INTERVAL_SECONDS)).isoformat(),
        ...
        "value": telemetry_value if i >= _BASELINE_COUNT else 0.0,
    }
    for i in range(_TOTAL)
]
```

**Tại sao sai:** Dữ liệu giả lập không phản ánh thực tế pod đang chạy. AI engine nhận 56 điểm nhân tạo thay vì time series thực từ pod đang OOMKill.

**Hướng fix:** Worker (Hands component) tự query Prometheus lấy time series thực, build `telemetry_window` từ đó, rồi gửi lên AI engine ở bench/cdo_push mode.

**Kiến trúc đúng (Brain/Hands separation):**
```
Pod OOMKill → Prometheus có metric thực
                    ↓
Worker (Hands) query Prometheus → build telemetry_window từ real data
                    ↓
AI engine (Brain) nhận real time series → BOCPD phân tích → detect anomaly
```

Worker được phép query Prometheus vì:
- Prometheus là HTTP endpoint (port 9090), không phải K8s API
- Worker (Hands) được phép gọi bất kỳ HTTP internal service nào
- AI engine (Brain) KHÔNG được gọi K8s API hoặc query Prometheus trực tiếp

### Chi tiết implementation

**Prometheus endpoint trong cluster:**
```
http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090
```

**Env var cần thêm vào sqs-worker config:**
```python
prometheus_url: str = "http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090"
prometheus_query_window_seconds: int = 600   # 10 phút lịch sử
prometheus_query_step_seconds: int = 30      # 1 điểm/30s → 20 điểm
```

**Signal → Prometheus query mapping:**

| signal_name | alertname | Prometheus query |
|-------------|-----------|-----------------|
| `pod_oom_event` | PodOOMKilled | `kube_pod_container_status_last_terminated_reason{reason="OOMKilled",namespace="<ns>",pod=~"<service>.*"} == 1` |
| `container_restart_count` | PodCrashLooping | `kube_pod_container_status_restarts_total{namespace="<ns>",pod=~"<service>.*"}` |
| `service_unhealthy` | ServiceStuck | `kube_deployment_status_replicas_available{namespace="<ns>",deployment="<service>"} / kube_deployment_spec_replicas{namespace="<ns>",deployment="<service>"}` |
| `queue_backlog` | SQSQueueBacklog | `aws_sqs_approximate_number_of_messages_visible{queue_name=~".*self-heal.*"}` |

**Logic build telemetry_window từ Prometheus response:**

```python
import httpx

def query_prometheus_range(prom_url: str, query: str, window_seconds: int, step: int) -> list[dict]:
    """Query Prometheus range API, return list of (timestamp, value) tuples."""
    end = datetime.now(timezone.utc)
    start = end - timedelta(seconds=window_seconds)
    resp = httpx.get(f"{prom_url}/api/v1/query_range", params={
        "query": query,
        "start": start.isoformat(),
        "end": end.isoformat(),
        "step": f"{step}s",
    }, timeout=10)
    resp.raise_for_status()
    data = resp.json()
    results = data.get("data", {}).get("result", [])
    if not results:
        return []
    # Lấy time series đầu tiên match
    values = results[0].get("values", [])
    return [(float(ts), float(v)) for ts, v in values]

def build_telemetry_window(prom_url, namespace, service, signal_name, alertname, 
                            tenant_id, point_labels, window_seconds=600, step=30):
    """Query Prometheus và build telemetry_window list."""
    query = SIGNAL_TO_PROM_QUERY[signal_name].format(namespace=namespace, service=service)
    series = query_prometheus_range(prom_url, query, window_seconds, step)
    
    if not series:
        # Fallback: 1 điểm nếu Prometheus không có data
        return [{
            "ts": datetime.now(timezone.utc).isoformat(),
            "tenant_id": tenant_id,
            "service": service,
            "signal_name": signal_name,
            "value": 1.0,
            "labels": point_labels,
        }]
    
    return [
        {
            "ts": datetime.fromtimestamp(ts, tz=timezone.utc).isoformat(),
            "tenant_id": tenant_id,
            "service": service,
            "signal_name": signal_name,
            "value": value,
            "labels": point_labels,
        }
        for ts, value in series
    ]
```

**Phần cần xóa trong main.py (dòng 106-132):**
```
- _BASELINE_COUNT = 50
- _ANOMALY_COUNT = 6
- _INTERVAL_SECONDS = 60
- _TOTAL = _BASELINE_COUNT + _ANOMALY_COUNT
- Toàn bộ list comprehension tạo telemetry_window giả
```

**Thay bằng:**
```python
telemetry_window = build_telemetry_window(
    prom_url=settings.prometheus_url,
    namespace=namespace,
    service=service,
    signal_name=signal_name,
    alertname=alertname,
    tenant_id=tenant_id,
    point_labels=point_labels,
)
```

**Cũng cần xóa phần post_telemetry_window giả (dòng 199-209):**
```python
# Thay bằng 1 điểm đơn giản (sau khi heal, signal = 0.0):
verify_now = datetime.now(timezone.utc)
post_telemetry_window = [{
    "ts": verify_now.isoformat(),
    "tenant_id": tenant_id,
    "service": service,
    "signal_name": signal_name,
    "value": 0.0,
    "labels": point_labels,
}]
```

**Import thêm:** `import httpx` (thêm vào requirements.txt của sqs-worker)

---

### Task: Trigger real OOMKill để test end-to-end

Sau khi sqs-worker đã query Prometheus thực:

```bash
# 1. Hạ memory limit → pod sẽ OOMKill liên tục
kubectl set resources deployment/order-api -n tenant-payment \
  --limits=memory=50Mi --requests=memory=30Mi

# 2. Watch OOMKill events
kubectl get events -n tenant-payment --field-selector reason=OOMKilling -w

# 3. Theo dõi luồng
kubectl logs -n self-heal-system deployment/webhook-receiver -f &
kubectl logs -n self-heal-system deployment/sqs-worker -f &
kubectl logs -n self-heal-system deployment/ai-engine -f &
```

**Expected flow:**
```
OOMKill → kube-state-metrics → Prometheus có data
Alertmanager fires PodOOMKilled (groupWait=10s)
→ webhook (1s cooldown) → SQS
→ worker query Prometheus: kube_pod_container_status_last_terminated_reason
→ build real telemetry_window (lịch sử 10 phút)
→ AI detect: BOCPD phát hiện spike → anomaly_detected=True
→ AI decide: PATCH_MEMORY_LIMIT → Fast Lane
→ kubectl patch deployment order-api resources.limits.memory=1024Mi
→ AI verify: success=True
```

**Reset sau test:**
```bash
kubectl set resources deployment/order-api -n tenant-payment \
  --limits=memory=256Mi --requests=memory=128Mi
# Và revert webhook cooldown về 180/300 trong configmap
```

---

## Cấu trúc file hiện tại quan trọng

| File | Mô tả |
|------|-------|
| `capstone/tf-3/cdo-1/app/sqs-worker/src/main.py` | Xóa dòng 106-132 (synthetic baseline), thêm Prometheus query |
| `capstone/tf-3/cdo-1/app/sqs-worker/src/config.py` | Thêm `prometheus_url`, `prometheus_query_window_seconds` |
| `capstone/tf-3/cdo-1/app/sqs-worker/requirements.txt` | Thêm `httpx` |
| `capstone/tf-3/cdo-1/gitops/manifests/base/sqs-worker/configmap.yaml` | Thêm `PROMETHEUS_URL` |

---

## Thông số đã có trong ai-engine configmap (không thay đổi)

```yaml
TELEMETRY_RUNTIME_MODE: "bench"     # AI không tự query Prometheus
BASELINE_LENGTH: "50"               # phù hợp với real series 10 phút/30s step = 20 điểm
BOCPD_HAZARD: "10"                  # nhạy, detect sau vài anomaly points
ANALYSIS_WINDOW_SIZE: "10"
```
