# Session Handoff — 2026-07-01 — CDO-01 Self-Heal E2E Pipeline

> Đọc file này trước khi làm gì khác. Mục tiêu: đưa 1 AI/session mới vào guồng ngay,
> không cần đọc lại toàn bộ lịch sử chat. Chi tiết kỹ thuật đầy đủ (root cause, code
> snippet) nằm ở `/Users/tan/Desktop/teamwork-capstone/CDO01_BUG_FIXES.md` (BUG 13→20)
> — file này chỉ tóm tắt + trỏ đường.

## Bối cảnh dự án

CDO-01 TF3 Self-Heal Engine (capstone, deadline 02/07/2026 08:00 — **đã sát nút**).
Pipeline: `Alertmanager → webhook-receiver → SQS → sqs-worker → AI Engine (detect/decide/verify) → K8s patch/GitOps → audit`.
Đọc `/Users/tan/Desktop/teamwork-capstone/CLAUDE.md` để biết kiến trúc đầy đủ, resource
names, tenant UUID, v.v. — không lặp lại ở đây.

## Việc đã làm hôm nay (theo đúng thứ tự phát hiện — 6 PR, tất cả đã MERGE)

Mục tiêu ban đầu: test end-to-end 1 lần OOMKill thật (không mock) cho tới khi AI Engine
xác nhận được anomaly đầu tiên. Mỗi PR sau vá đúng 1 tầng lỗi lộ ra sau khi tầng trước
đã thông:

| PR | Tầng lỗi | Root cause |
|----|----------|-----------|
| [#185](https://github.com/truongcongtu318/capstone-phase2/pull/185) | GitOps wiring | `gitops/monitoring/` (chứa AlertmanagerConfig routing theo tenant) chưa từng được ArgoCD sync — thiếu app con trong App-of-Apps |
| [#186](https://github.com/truongcongtu318/capstone-phase2/pull/186) | CRD validation | `AlertmanagerConfig.spec.route` thiếu `receiver` bắt buộc (Prometheus Operator reject) |
| [#187](https://github.com/truongcongtu318/capstone-phase2/pull/187) | Alertmanager capability | `httpConfig.headers` **không tồn tại** trong CRD `v1alpha1` (xác nhận qua `kubectl get crd ... -o json` + GitHub issue prometheus-operator#8341, CLOSED nhưng CHƯA implement) — K8s âm thầm prune field lạ. Chuyển tenant_id sang query param `?tenant_id=...` trên URL |
| [#190](https://github.com/truongcongtu318/capstone-phase2/pull/190) (Terraform, infra) | Operator default behavior | `alertmanagerConfigMatcherStrategy` mặc định `OnNamespace` (xác nhận từ Go source `pkg/apis/monitoring/v1/alertmanager_types.go`) — route của CR chỉ áp dụng cho alert có `namespace` label = namespace của chính CR (`observability`), không bao giờ khớp alert thật (`tenant-payment`/`tenant-checkout`). Set `type: None` |
| [#192](https://github.com/truongcongtu318/capstone-phase2/pull/192) | Tín hiệu AI nhận | `pod_oom_event` dùng `kube_pod_container_status_last_terminated_reason == 1` — metric này luôn phẳng (giá trị 1 khi có, không tồn tại trước đó) → bị `anomaly_detector.py` loại vì `nunique()<=1` → luôn NO_ANOMALY. Đổi sang `kube_pod_container_status_restarts_total` (counter thật, có baseline). Kèm tune `BOCPD_HAZARD` 10→3, `PROMETHEUS_QUERY_STEP_SECONDS` 30→10 |
| [#194](https://github.com/truongcongtu318/capstone-phase2/pull/194) | Query precision | `pod=~"{service}.*"` (regex prefix) khớp NHẦM cả pod thật (`order-api-7d9b4895ff-xxx`, khoẻ mạnh) lẫn pod test (`order-api-oomtest-abcde`) — `query_range()` chỉ lấy `results[0]`, thứ tự Prometheus trả không đảm bảo. Đổi sang match chính xác `pod="{pod}"` dùng `alert.labels.pod` có sẵn |

**Kết quả:** pipeline chạy end-to-end thật lần đầu tiên — `/v1/detect` trả
`anomaly_detected=true` (log: `Metrics rows=61 baseline_len=48`, `Anomaly index: 58`).

## Vấn đề đang mở (CHƯA fix, phát hiện ngay sau khi detect thành công)

### RCA đoán sai target_service — gây crash worker (đã được catch, không treo hệ thống)

**Log:**
```
[API][DETECT] Predicted Service: checkoutservice
[API][DETECT] Predicted Fault:   cpu
[API][DETECT] Reasoning: No strong metric deviation or log correlation found. Defaulting to checkoutservice cpu.
...
[API][DECIDE] Matched Runbook: CPUSaturationRecoveryRunbook
...
sqs-worker: kubernetes.client.exceptions.NotFoundException: (404)
deployments.apps "checkoutservice" not found
```

**Root cause (đọc trực tiếp `ai-engine/detect_decide_verify/src/correlation_analyzer.py:230-234`):**
```python
if not best_service or max_service_score <= 0.0:
    best_service = "checkoutservice"   # ← HARDCODE, không đọc platform_profile
    suspected_fault_type = "cpu"
    confidence = 0.50
    reasoning = "No strong metric deviation or log correlation found. Defaulting to checkoutservice cpu."
```
`"checkoutservice"` là tên service từ demo gốc "Online Boutique" của AI team, hoàn toàn
không nằm trong `platform_profile_cdo01.json` (services thật: `checkout-api,
checkout-frontend, checkout-worker, order-api, payment-worker`). Đây là fallback cứng
khi RCA (BARO + z-score/log correlation) không tìm được tín hiệu đủ mạnh.

**Vì sao RCA không tìm được tín hiệu đủ mạnh:** CDO chỉ gửi **1 cột metric duy nhất**
(`order-api_pod_oom_event`, tức restart count) mỗi lần alert. Thuật toán RCA
(`RCA_ZSCORE_THRESHOLD=3.0` mặc định, không override trong configmap) được thiết kế cho
telemetry nhiều cột (cpu, mem, disk, socket, latency, error_rate...) để so sánh chéo —
với đúng 1 cột, bước nhảy nhỏ (12→13→14, ~1 đơn vị) khó vượt ngưỡng 3-sigma, và
`BARO robust_scorer` cũng cần nhiều series để rank có ý nghĩa. Đây khác biệt với
**DETECT** (chỉ cần BOCPD tìm change-point trên 1 cột, đã fix xong ở #192/#194) —
**DECIDE's RCA (target_service/fault_type) là bài toán khác, cần nhiều tín hiệu hơn.**

**Vì sao không "treo" hệ thống:** `sqs-worker/src/main.py::_process_message()` có
`except Exception` bao toàn bộ — 404 bị bắt, ghi `circuit_breaker.record_failure()`,
`log_escalate()`, xoá message khỏi SQS. Không crash loop, không treo. **Nhưng** đây là
false failure — self-heal không hề "thất bại", AI chỉ đoán sai target — 3 lần như vậy
trong 1 giờ sẽ mở circuit breaker THẬT cho namespace/service đó, chặn nhầm các lần tự
chữa lành hợp lệ sau này.

**Chưa fix vì:** đây là giao điểm 2 lựa chọn kiến trúc, cần bạn quyết định trước khi
code tiếp:
1. **Fix nông (CDO tự làm được):** thêm validation trong `main.py`/`patch_executor.py` —
   nếu `decide_resp`'s target service không khớp `service` gốc từ alert (hoặc không có
   trong `ALLOWED_NAMESPACES`/services CDO biết), coi là "AI decide sai", `log_escalate`
   trực tiếp (không tính vào circuit breaker `EXEC_FAILED`) thay vì để crash xuống tận
   `patch_executor`. Giảm thiệt hại nhưng KHÔNG giúp AI đoán đúng hơn.
2. **Fix gốc (cần AI team hoặc gửi thêm tín hiệu):** gửi thêm 1-2 signal khác cùng
   alert (vd CPU/memory usage thật của pod, không chỉ restart count) để RCA có nhiều
   cột hơn để so sánh — HOẶC yêu cầu AI team đổi fallback từ hardcode "checkoutservice"
   sang đọc `DEFAULT_SERVICE`/service gốc từ `anomaly_context` (đã có `target_service`
   đúng ngay từ bước DETECT — nghịch lý là DETECT đã tìm đúng lúc quét BOCPD, nhưng
   DECIDE's RCA lại tự chạy lại từ đầu và có thể đoán khác đi).

Đã note thêm vào `CDO01_BUG_FIXES.md` phần "GAP CHƯA FIX — Cần AI team" (gap thứ 2, sau
gap `verifier.py` rubber-stamp).

## Gap cross-team đã biết từ trước (chưa đổi, xem chi tiết CDO01_BUG_FIXES.md)

1. **`verifier.py::verify_action()`** chỉ nhận diện signal_name chứa `"error"`/`"latency"`
   — 4 signal CDO không khớp → `/v1/verify` LUÔN trả `success=True` bất kể thật hay
   không. Cần AI team mở rộng, hoặc CDO gửi thêm signal `*_error_rate`.
2. **`engine.py::detect_anomalies()`** tự tính `baseline_len` từ số điểm nhận được,
   KHÔNG dùng `BASELINE_LENGTH` từ configmap cho API live (chỉ ảnh hưởng benchmark
   offline). Không phải bug, chỉ là hiểu nhầm phổ biến — đừng chỉnh biến này mong đổi
   hành vi live.
3. **RCA hardcode "checkoutservice"** (gap mới, mục trên) — cần quyết định hướng fix.

## Cách test lại từ đầu (nếu pod test đã bị xoá/reset)

```bash
# 1. Tạo pod OOM test độc lập (KHÔNG đụng Deployment order-api thật — Kyverno chặn
#    mọi mutation Deployment/StatefulSet trừ self-heal-executor/ArgoCD)
cat > /tmp/oom-test-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: order-api-oomtest-abcde   # đúng regex label_replace "^(.+)-[a-z0-9]{5,10}-[a-z0-9]{5}$"
  namespace: tenant-payment
  labels:
    app: order-api-oomtest        # KHÔNG dùng app: order-api (tránh dính Service selector)
spec:
  restartPolicy: Always
  containers:
    - name: main
      image: 474013238625.dkr.ecr.us-east-1.amazonaws.com/busybox:1.36
      command: ["sh", "-c", "a=\"\"; i=0; while true; do a=\"$a$(head -c 1048576 /dev/zero | tr '\\0' 'x')\"; i=$((i+1)); echo allocated ${i}MB; done"]
      resources:
        limits: {memory: "50Mi", cpu: "200m"}
        requests: {memory: "20Mi", cpu: "50m"}
EOF
kubectl apply -f /tmp/oom-test-pod.yaml

# 2. Theo dõi 3 terminal
kubectl logs -n self-heal-system deployment/webhook-receiver -f
kubectl logs -n self-heal-system deployment/sqs-worker -f
kubectl logs -n self-heal-system deployment/ai-engine -f

# 3. Chờ vài phút cho restart count đủ lớn (cần backoff CHƯA giãn quá xa — xem caveat dưới)
kubectl get pod order-api-oomtest-abcde -n tenant-payment -w

# Dọn dẹp
kubectl delete pod order-api-oomtest-abcde -n tenant-payment
```

**Caveat quan trọng:** `CrashLoopBackOff` tăng dần khoảng cách giữa các lần restart
(10s→20s→...→5min). BOCPD chỉ quét 20% cuối cửa sổ (600s/10s step = 61 điểm,
baseline_len≈48, quét 13 điểm cuối ≈ 130s). Nếu lần restart gần nhất đã hơn ~2 phút
trước khi alert tới worker, bước nhảy nằm trong baseline thay vì vùng quét →
NO_ANOMALY dù có transition thật. Muốn chắc detect, trigger lúc pod VỪA mới restart.

## File tham khảo quan trọng

| File | Nội dung |
|------|---------|
| `/Users/tan/Desktop/teamwork-capstone/CDO01_BUG_FIXES.md` | BUG 1-20 đầy đủ, root cause + code, đây là log kỹ thuật chính |
| `/Users/tan/Desktop/teamwork-capstone/CLAUDE.md` | Kiến trúc, resource names, tenant UUID, quy tắc git |
| `capstone/tf-3/cdo-1/app/sqs-worker/src/prometheus_query_client.py` | Module query Prometheus (đã fix 3 lần hôm nay: metric đúng, exact pod match) |
| `capstone/tf-3/ai/ai-engine/detect_decide_verify/src/correlation_analyzer.py` | RCA — nơi có hardcode "checkoutservice" (KHÔNG sửa file này, đây là code AI team, chỉ đọc tham khảo) |
| `capstone/tf-3/ai/contracts/` | Contract mới hơn bản `cdo-1/contracts/` — có ghi chú rollback snapshot, tenant cross-check |

## Việc cần làm tiếp theo (ưu tiên theo thời gian còn lại tới freeze)

1. **Quyết định hướng xử lý gap RCA "checkoutservice"** (xem 2 lựa chọn ở trên) — đây là
   việc chưa code, cần trả lời trước khi làm tiếp.
2. Test lại full loop (detect → decide → execute → verify) 1 lần sau khi có target
   service đúng, xác nhận patch_executor thực sự patch được `order-api` thật.
3. Nhớ rằng `verify` hiện tại luôn `success=True` (gap đã biết #1) — đừng lấy đó làm
   bằng chứng self-heal thành công thật, chỉ là chưa bị AI cross-check.
4. Trước khi nộp bài, kiểm tra lại `COOLDOWN_PAYMENT_SECONDS=1`/`COOLDOWN_CHECKOUT_SECONDS=1`
   trong `webhook-receiver` configmap — đang để 1s cho test, cần revert về 180/300 nếu
   muốn đúng SLA tier như thiết kế gốc (đã note trong `AI_INTEGRATION_CHANGES.md` §13.3).
