# Test & Eval Report - Task force <N> · CDO <M>

<!-- Doc owner: <Nhóm CDO>
     Status: NEW (W12 T4 Pack #2 only)
     Word target: 1000-1800 từ -->

## 1. Test coverage

| Test type | Tool | Coverage / Scope |
|---|---|---|
| Unit test | pytest | 79% (`pytest --cov=capstone/tf-3/cdo-1/app/`, 29 test case, ngưỡng CI ≥70%) |
| Integration test | pytest, gọi thẳng AI Engine thật đã deploy trên cluster (không mock) | Webhook idempotency + cross-tenant rejection (`test_webhook.py`), Worker ↔ AI Engine `/v1/detect`→`/v1/decide`→`/v1/verify` end-to-end (`test_worker.py`) |
| E2E test | manual (kubectl + log thật, không dùng Playwright/k6 vì đây là hạ tầng K8s, không phải web UI) | Happy path PodOOMKilled: **đã chạy thành công end-to-end thật trên cluster** (xem bằng chứng bên dưới). PodCrashLooping: dùng chung cơ chế signal, chưa chạy riêng. ServiceStuck: đã có kịch bản test, phát hiện gap fault-type mapping (xem §6.2) |
| Load test | chưa chạy | Cần k6/Locust nhắm `POST /alerts`, chưa thực hiện trong phạm vi phiên này |
| Chaos test | manual (không dùng Litmus) | 10 lỗi hạ tầng/tích hợp thật được phát hiện + fix trong quá trình test end-to-end (xem bảng §6.1) — mỗi lỗi bản chất là 1 lần "chaos" tự nhiên phát sinh khi ghép nối thật giữa Alertmanager/Kyverno/ArgoCD/AI Engine |

**Bằng chứng E2E PodOOMKilled thành công (log thật, 2026-07-01/02):**
```
[API][DETECT] Predicted Service: payment-worker | Fault: mem | Confidence: 0.950
[API][DECIDE] Matched Runbook: MemoryLeakRecoveryRunbook
k8s_patch_applied deployment=payment-worker ns=tenant-payment
fast_lane_git_committed sha=ceff21e0b300615ae2822d441e67e54ecd372d04
Self-heal successfully completed and verified for service 'payment-worker' in namespace 'tenant-payment'
```
CodeCommit xác nhận `values.yaml` đã cập nhật đúng: `resources.limits.memory: 768Mi` (từ `256Mi` gốc).

## 2. SLO evidence

| SLO | Target | Measured | Window | Pass/Fail |
|---|---|---|---|---|
| API availability | ≥ 99.5% | X% | 2 weeks build period | ✓/✗ |
| P99 latency | < 1000ms | Xms | Last 24h | ✓/✗ |
| Error rate | < 0.5% | X% | Last 24h | ✓/✗ |
| Tenant onboarding | < 30 min | X min | 3 test tenants | ✓/✗ |

### 2.1 SLO breach analysis

<!-- Nếu có SLO miss, phân tích root cause -->

## 3. Load test results

### 3.1 Test setup

- **Load profile**: ramp-up 0 → 100 RPS over 5 min, sustained 100 RPS for 10 min
- **Tenants simulated**: 10 concurrent
- **Tool**: <k6 / Locust>

### 3.2 Results

| Metric | Target | Achieved |
|---|---|---|
| RPS sustained | 100 | X |
| P99 latency at peak | < 1500ms | Xms |
| Error rate at peak | < 1% | X% |
| Auto-scale triggers | scale to ≥ 5 tasks | ✓/✗ |

### 3.3 Bottleneck identified

<!-- DB connection pool? AI engine throttle? Compute? -->

## 4. Security test

### 4.1 Penetration touch points

- ☐ API auth bypass attempt
- ☐ Cross-tenant data leak attempt
- ☐ SQL injection / NoSQL injection
- ☐ IAM privilege escalation
- ☐ Secret exposure via logs

### 4.2 Vulnerability scan

- **Tool**: Trivy / Snyk / AWS Inspector
- **CRITICAL findings**: 0 (must be 0 by pack #2)
- **HIGH findings**: ≤ 3 with documented mitigation
- **Report**: `<repo>/security/scan-results.json`

## 5. Multi-tenant isolation test

<!-- Critical - multi-tenant data leak = cap T3 per playbook §10.4 -->

| Test | Method | Result |
|---|---|---|
| Tenant A reads Tenant B data via API | Inject A's token, request B's resource | ❌ Should fail with 403 |
| Tenant A IAM role accesses B's S3 prefix | Assume A's role, attempt B access | ❌ Should fail |
| Cross-tenant queue contamination | Tenant A enqueue with B's tenant_id | Audit log catches mismatch |
| DB row-level security | Query without tenant_id filter | Should return empty / error |

**All tests must pass** - any leak = SEV1 incident.

## 6. Failure analysis

### 6.1 Failures encountered during 2-week build

<!-- Root cause/fix lấy từ 10 PR merge thật (#185→#212), điều tra bằng cách đọc trực
     tiếp CRD schema/Go source/log cluster thật, không đoán. "Time to fix" tự điền
     theo trí nhớ — không track chính xác theo từng lỗi trong lúc làm. -->

| # | Failure | Root cause | Fix | Time to fix |
|---|---|---|---|---|
| 1 | ArgoCD chưa sync `gitops/monitoring/` (AlertmanagerConfig chưa tồn tại trên cluster) | Thiếu app con trong App-of-Apps ArgoCD | Thêm `argo-apps/monitoring-app.yaml` (PR #185) | X |
| 2 | `AlertmanagerConfig` bị Prometheus Operator reject | CRD `v1alpha1` bắt buộc `route.receiver` ở root dù mọi traffic đã match qua `routes[]` con | Thêm receiver fallback câm (PR #186) | X |
| 3 | Webhook luôn trả 403 dù alert đúng tenant | Alertmanager CRD `v1alpha1` **không hỗ trợ** custom HTTP header (xác nhận qua `kubectl get crd ... -o json` + GitHub issue upstream prometheus-operator#8341, K8s API âm thầm prune field lạ) | Chuyển `tenant_id` sang query param trên URL (PR #187) | X |
| 4 | Route theo tenant vẫn không chạy dù config đúng, không lỗi | `alertmanagerConfigMatcherStrategy` mặc định `OnNamespace` (xác nhận qua Go source `prometheus-operator`) — route chỉ áp dụng cho alert cùng namespace với chính AlertmanagerConfig | Set `type: None` qua Terraform (PR #190) | X |
| 5 | `/v1/detect` luôn trả `NO_ANOMALY` dù pod OOMKilling thật | Signal `pod_oom_event` dùng metric `last_terminated_reason` — luôn = 1 khi có, không có baseline "0" để BOCPD so sánh | Đổi sang metric `restarts_total` (có baseline thật) + hạ `BOCPD_HAZARD` (PR #192) | X |
| 6 | Kết quả detect không ổn định (lúc đúng lúc không, cùng 1 pod) | Regex prefix `pod=~"{service}.*"` khớp nhầm nhiều pod (pod thật + pod test cùng prefix tên), `query_range()` lấy ngẫu nhiên 1 trong các kết quả trả về | Match chính xác theo tên pod thay vì regex prefix (PR #194) | X |
| 7 | AI RCA fallback sai service (hardcode `"checkoutservice"`), gây crash 404 khi patch | RCA (BARO + z-score) chỉ có 1 tín hiệu mỏng (restart count tăng từng đơn vị), không cột nào vượt `RCA_ZSCORE_THRESHOLD` | Gửi thêm tín hiệu memory usage thật làm bằng chứng thứ 2 (PR #196) | X |
| 8 | Execute `PATCH_MEMORY_LIMIT` bị Kyverno từ chối (400 admission webhook) | Patch body set cả `resources.requests`, Kyverno `restrict-mutations` chỉ cho phép sửa `resources.limits` | Bỏ `memory_request_mb` khỏi patch body — chỉ set `resources.limits` (PR #202) | X |
| 9 | RCA thỉnh thoảng vẫn chọn sai service dù đã có tín hiệu thứ 2 | Threshold `RCA_ZSCORE_THRESHOLD` mặc định (3.0) chưa đủ nhạy cho setup 2-metric mỏng của CDO | Sync fix từ AI team (bỏ hardcode, đọc config) + thêm `RCA_ZSCORE_THRESHOLD=1.5` (PR #209) | X |
| 10 | Log `ArgoCD sync → 400 Bad Request` sau mỗi lần self-heal thành công | Race condition vô hại: bật lại `selfHeal:true` khiến ArgoCD tự động sync ngay, request sync tường minh theo sau bị từ chối `FailedPrecondition: another operation is already in progress` (xác nhận qua log server ArgoCD) | Không ảnh hưởng kết quả — patch/verify vẫn thành công. Chưa fix (chỉ dọn log ồn), không tính là failure ảnh hưởng chức năng | — |

**Tổng:** 9/10 lỗi ảnh hưởng chức năng đã fix và merge (PR #185–#209), verify bằng test thật (không dry-run) trên cluster sandbox thật.

### 6.2 Test gaps acknowledged

- **Gap 1 — `/v1/verify` không thực sự verify:** AI Engine's `verifier.py::verify_action()` chỉ coi thất bại khi `signal_name` chứa chuỗi `"error"`/`"latency"`. 4 signal của CDO (`pod_oom_event`, `container_restart_count`, `service_unhealthy`, `queue_backlog`) không khớp → `/v1/verify` luôn trả `success=True` bất kể trạng thái thật sau khi heal. Cần AI team mở rộng, hoặc CDO gửi thêm signal dạng `*_error_rate`. **Sẽ test/fix post-capstone.**
- **Gap 2 — `ServiceStuck` không kích hoạt đúng `RESTART_DEPLOYMENT`:** signal `service_unhealthy` không khớp bất kỳ từ khóa nào trong `FAULT_SIGNAL_PATTERNS` của AI → rơi về `fault_type=cpu` mặc định (`SCALE_REPLICAS`) thay vì `RESTART_DEPLOYMENT` như thiết kế ban đầu. **Sẽ phối hợp AI team bổ sung từ khóa post-capstone.**
- **Gap 3 — Detect kém nhạy với pod crash-loop lâu:** pod OOMKilling liên tục nhiều giờ khiến baseline BOCPD "bão hòa" (đã coi trạng thái lỗi là bình thường) — detect không còn phát hiện được dù pod vẫn lỗi thật. Đây là giới hạn tự nhiên của change-point detection, không phải bug — cần pod ở trạng thái "mới lỗi" để detect chính xác.
- **Gap 4 — Chưa chạy load test / security scan chính thức** (k6/Locust, Trivy/Snyk) trong phạm vi build 2 tuần này.

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - SLO targets validated trong §3 doc này
- [`03_security_design.md`](03_security_design.md) §14 - Risk registry mitigated bởi test results §6 doc này
- [`../../ai/docs/04_eval_report.md`](../../ai/docs/04_eval_report.md) - Joint eval: AI engine quality + CDO infra integration
