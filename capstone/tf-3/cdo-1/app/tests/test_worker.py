# 🧪 Worker, AI Client, and Circuit Breaker Unit Tests

import pytest
import sys
import os
import time
import httpx
from unittest.mock import patch, MagicMock
import json

# Clear cached src modules and set path specifically for sqs-worker
for mod in list(sys.modules.keys()):
    if mod == 'src' or mod.startswith('src.'):
        del sys.modules[mod]

app_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sqs_worker_path = os.path.join(app_dir, 'sqs-worker')
webhook_path = os.path.join(app_dir, 'webhook-receiver')

if sqs_worker_path in sys.path:
    sys.path.remove(sqs_worker_path)
sys.path.insert(0, sqs_worker_path)

from src import ai_client
from src import circuit_breaker
from src import main
from src import patch_executor
from src import prometheus_query_client
from src.ai_client import AIClientError
from src.patch_executor import ExecutionResult, PreStateSnapshot
from src import main as worker_main

# ---------------------------------------------------------------------------
# 1. AI CLIENT TESTS
# ---------------------------------------------------------------------------

@patch("httpx.Client.post")
def test_ai_client_headers(mock_post):
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {
        "anomaly_detected": True,
        "severity": 0.8,
        "anomaly_context": {
            "target_service": "payment-api",
            "namespace": "tenant-payment",
            "deployment": "payment-api"
        }
    }
    mock_post.return_value = mock_response

    telemetry = [{"service": "payment-api"}]
    res = ai_client.detect(telemetry, "tenant-id-123", "idem-123", "corr-123", False)

    assert res["anomaly_detected"] is True
    
    # Kiểm tra xem header có được gửi đúng không
    called_headers = mock_post.call_args[1]["headers"]
    assert called_headers["X-Tenant-Id"] == "tenant-id-123"
    assert called_headers["Idempotency-Key"] == "idem-123"
    assert called_headers["X-Correlation-Id"] == "corr-123"
    assert called_headers["X-Dry-Run-Mode"] == "false"


@patch("httpx.Client.post")
@patch("time.sleep")
def test_ai_client_retries_on_500(mock_sleep, mock_post):
    mock_500 = MagicMock()
    mock_500.status_code = 500
    mock_500.text = "Internal Server Error"
    mock_post.return_value = mock_500

    with pytest.raises(AIClientError) as exc_info:
        ai_client.detect([], "t-1", "i-1", "c-1", False)
    
    assert exc_info.value.status_code == 500
    assert mock_post.call_count == 3  # Lần chạy đầu tiên + 2 lần retry


@patch("httpx.Client.post")
def test_ai_client_schema_validation(mock_post):
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {
        "invalid_field": True  # Thiếu anomaly_detected
    }
    mock_post.return_value = mock_response

    with pytest.raises(AIClientError) as exc_info:
        ai_client.detect([], "t-1", "i-1", "c-1", False)
    
    assert "Schema validation error" in exc_info.value.detail


# ---------------------------------------------------------------------------
# 2. CIRCUIT BREAKER TESTS
# ---------------------------------------------------------------------------

@patch.object(circuit_breaker, "_get_db_client")
def test_circuit_breaker_is_open(mock_get_db):
    mock_db = MagicMock()
    mock_get_db.return_value = mock_db
    
    # Case 1: CB CLOSED
    mock_db.get_item.return_value = {"Item": {"status": {"S": "CLOSED"}}}
    assert circuit_breaker.is_open("t1", "ns1", "s1") is False

    # Case 2: CB OPEN
    mock_db.get_item.return_value = {"Item": {"status": {"S": "OPEN"}}}
    assert circuit_breaker.is_open("t1", "ns1", "s1") is True

    # Case 3: Chưa tồn tại CB trong DB (mặc định CLOSED)
    mock_db.get_item.return_value = {}
    assert circuit_breaker.is_open("t1", "ns1", "s1") is False


@patch.object(circuit_breaker, "_get_db_client")
@patch.object(circuit_breaker, "_get_sns_client")
@patch.object(circuit_breaker, "log_circuit_breaker_open")
def test_circuit_breaker_record_failure_opens_circuit(mock_log_cb, mock_get_sns, mock_get_db):
    mock_db = MagicMock()
    mock_get_db.return_value = mock_db
    mock_sns = MagicMock()
    mock_get_sns.return_value = mock_sns

    # Giả lập có 2 lỗi trước đó trong vòng 1 giờ gần đây
    now = int(time.time())
    mock_db.get_item.return_value = {
        "Item": {
            "status": {"S": "CLOSED"},
            "failure_timestamps": {"SS": [str(now - 200), str(now - 100)]}
        }
    }

    # Báo lỗi lần thứ 3 (kích hoạt mở mạch)
    circuit_breaker.record_failure("t1", "ns1", "s1", "corr1")

    # Xác nhận put_item cập nhật status sang OPEN
    called_item = mock_db.put_item.call_args[1]["Item"]
    assert called_item["status"]["S"] == "OPEN"
    
    # Xác nhận đã gửi tin nhắn SNS Escalation
    assert mock_sns.publish.called
    message_sent = json.loads(mock_sns.publish.call_args[1]["Message"])
    assert message_sent["status"] == "OPEN"
    assert message_sent["service"] == "s1"

    # Xác nhận log audit đã được phát
    assert mock_log_cb.called


# ---------------------------------------------------------------------------
# 3. WORKER FLOW TESTS
# ---------------------------------------------------------------------------

def test_to_ai_action_executed_rounds_time_and_maps_dry_run_status():
    """AI Engine's ActionExecuted schema chỉ nhận status COMPLETED|FAILED (không có
    DRY_RUN) và execution_time_seconds kiểu int (không nhận float lẻ) — gửi sai kiểu
    sẽ bị AI Engine trả 422."""
    dry_run_result = ExecutionResult("PATCH_MEMORY_LIMIT", "deployment/payment-api", "DRY_RUN", 3.456)
    mapped = worker_main._to_ai_action_executed(dry_run_result)
    assert mapped["status"] == "COMPLETED"
    assert mapped["execution_time_seconds"] == 3
    assert isinstance(mapped["execution_time_seconds"], int)

    completed_result = ExecutionResult("RESTART_DEPLOYMENT", "deployment/order-api", "COMPLETED", 7.9)
    mapped2 = worker_main._to_ai_action_executed(completed_result)
    assert mapped2["status"] == "COMPLETED"
    assert mapped2["execution_time_seconds"] == 8


@patch("time.sleep")
@patch.object(worker_main.prometheus_query_client, "build_telemetry_window")
@patch.object(worker_main.ai_client, "detect")
@patch.object(worker_main.ai_client, "decide")
@patch.object(worker_main.ai_client, "verify")
@patch.object(worker_main.patch_executor, "capture_pre_state")
@patch.object(worker_main.patch_executor, "execute")
@patch.object(worker_main.circuit_breaker, "is_open", return_value=False)
@patch.object(worker_main, "log_incident_start")
@patch.object(worker_main, "log_detect")
@patch.object(worker_main, "log_decide")
@patch.object(worker_main, "log_execute_start")
@patch.object(worker_main, "log_execute_done")
@patch.object(worker_main, "log_verify")
def test_worker_process_message_success(
    mock_log_verify, mock_log_exec_done, mock_log_exec_start, mock_log_decide, mock_log_detect, mock_log_inc_start,
    mock_cb_is_open, mock_exec, mock_capture, mock_verify, mock_decide, mock_detect, mock_build_window, mock_sleep
):
    mock_sqs = MagicMock()

    # Worker phải hỏi Prometheus lấy telemetry_window thật thay vì tự bịa dữ liệu
    mock_build_window.return_value = [
        {"ts": "2026-07-01T00:00:00+00:00", "tenant_id": "tenant-id",
         "service": "payment-api", "signal_name": "pod_oom_event", "value": 1.0, "labels": {}}
    ]

    # Cấu hình mock responses thành công
    mock_detect.return_value = {
        "anomaly_detected": True,
        "anomaly_context": {"target_service": "payment-api", "namespace": "tenant-payment", "deployment": "payment-api"}
    }
    mock_decide.return_value = {
        "pattern_type": "urgent",
        "action_plan": [{"action": "PATCH_MEMORY_LIMIT", "target": "deployment/payment-api"}],
        "verify_policy": {"window_seconds": 120}
    }
    mock_capture.return_value = PreStateSnapshot("urgent", "tenant-payment", "payment-api")
    mock_exec.return_value = ExecutionResult("PATCH_MEMORY_LIMIT", "deployment/payment-api", "COMPLETED", 5.0)
    mock_verify.return_value = {"success": True, "next_action": "DONE"}

    alert_message = {
        "ReceiptHandle": "receipt_123",
        "Body": json.dumps({
            "status": "firing",
            "labels": {
                "alertname": "PodOOMKilled",
                "namespace": "tenant-payment",
                "service": "payment-api"
            }
        })
    }

    main._process_message(mock_sqs, alert_message)

    # Message SQS phải được delete và quy trình đi qua đầy đủ
    mock_sqs.delete_message.assert_called_once_with(
        QueueUrl=main.settings.sqs_queue_url,
        ReceiptHandle="receipt_123"
    )
    assert mock_detect.called
    assert mock_decide.called
    assert mock_exec.called
    assert mock_verify.called

    # Telemetry phải đến từ Prometheus (signal_name đúng theo alertname PodOOMKilled)
    assert mock_build_window.called
    _, build_window_kwargs = mock_build_window.call_args_list[0]
    assert build_window_kwargs["namespace"] == "tenant-payment"
    assert build_window_kwargs["service"] == "payment-api"
    assert build_window_kwargs["signal_name"] == "pod_oom_event"
    # detect() phải nhận đúng telemetry_window trả về từ Prometheus, không phải dữ liệu bịa
    detect_call_args = mock_detect.call_args[0]
    assert detect_call_args[0] == mock_build_window.return_value

    # Worker phải chờ đúng verify_policy.window_seconds AI Engine chỉ định trước khi verify
    mock_sleep.assert_called_once_with(120)

    # post_telemetry_window cho /v1/verify phải là dữ liệu Prometheus thật re-query lại
    # (không phải 1 điểm 0.0 bịa), nên build_telemetry_window phải được gọi lần 2
    assert mock_build_window.call_count == 2
    verify_call_args = mock_verify.call_args[0]
    action_executed_sent, post_window_sent = verify_call_args[0], verify_call_args[1]
    assert post_window_sent == mock_build_window.return_value

    # action_executed gửi cho AI Engine phải khớp schema ActionExecuted (status
    # COMPLETED|FAILED, execution_time_seconds là int)
    assert action_executed_sent["status"] == "COMPLETED"
    assert action_executed_sent["execution_time_seconds"] == 5
    assert isinstance(action_executed_sent["execution_time_seconds"], int)


@patch.object(worker_main.circuit_breaker, "is_open", return_value=True)
@patch.object(worker_main, "log_incident_start")
@patch.object(worker_main, "log_escalate")
def test_worker_process_message_skips_if_cb_open(mock_log_escalate, mock_log_inc_start, mock_cb_open):
    mock_sqs = MagicMock()
    
    alert_message = {
        "ReceiptHandle": "receipt_123",
        "Body": json.dumps({
            "status": "firing",
            "labels": {
                "alertname": "PodOOMKilled",
                "namespace": "tenant-payment",
                "service": "payment-api"
            }
        })
    }

    main._process_message(mock_sqs, alert_message)

    # Skip nhưng vẫn phải xoá SQS message để không bị lặp lại
    mock_sqs.delete_message.assert_called_once_with(
        QueueUrl=main.settings.sqs_queue_url,
        ReceiptHandle="receipt_123"
    )
    assert mock_log_escalate.called
    assert mock_log_inc_start.called


# ---------------------------------------------------------------------------
# 4. ADDITIONAL COVERAGE TESTS (Audit Log, Patch Executor, Security, DDB Lock)
# ---------------------------------------------------------------------------

def test_audit_logger_dry_run():
    """Gọi trực tiếp audit_logger với dry_run=True để bao phủ 100% dòng log audit."""
    from src import audit_logger
    
    tenant = "d3b07384-d113-495f-9f58-20d18d357d75"
    corr = "correlation-id-test"

    # Test all wrapper functions with dry_run=True
    r1 = audit_logger.log_incident_start(tenant, corr, {"status": "firing"}, dry_run=True)
    assert r1["event_type"] == "INCIDENT_START"

    r2 = audit_logger.log_detect(tenant, corr, {"anomaly_detected": True}, dry_run=True)
    assert r2["event_type"] == "DETECT"

    r3 = audit_logger.log_decide(tenant, corr, {"pattern_type": "urgent"}, dry_run=True)
    assert r3["event_type"] == "DECIDE"

    r4 = audit_logger.log_execute_start(tenant, corr, "PATCH_MEMORY_LIMIT", "deployment/payment-api", "urgent", dry_run=True)
    assert r4["event_type"] == "EXECUTE_START"

    r5 = audit_logger.log_execute_done(tenant, corr, "PATCH_MEMORY_LIMIT", "deployment/payment-api", "COMPLETED", 1.5, dry_run=True)
    assert r5["event_type"] == "EXECUTE_DONE"

    r6 = audit_logger.log_verify(tenant, corr, {"success": True}, dry_run=True)
    assert r6["event_type"] == "VERIFY"

    r7 = audit_logger.log_rollback(tenant, corr, "Verification failed", {"pre_state": {}}, dry_run=True)
    assert r7["event_type"] == "ROLLBACK"

    r8 = audit_logger.log_escalate(tenant, corr, "escalating limit", "payment-api", dry_run=True)
    assert r8["event_type"] == "ESCALATE"

    r9 = audit_logger.log_circuit_breaker_open(tenant, corr, "payment-api", 3, dry_run=True)
    assert r9["event_type"] == "CIRCUIT_BREAKER_OPEN"


def test_patch_executor_helpers():
    """Bao phủ các helper logic trong patch_executor."""
    # 1. Test mi parser (memory parser)
    assert patch_executor._mi("512Mi") == 512
    assert patch_executor._mi("2Gi") == 2048
    assert patch_executor._mi("1024Ki") == 1
    assert patch_executor._mi("1G") == 1000
    assert patch_executor._mi(None) is None

    # 2. Test patch body generators
    body_mem = patch_executor._patch_body(
        "PATCH_MEMORY_LIMIT", 
        {"memory_limit_mb": 384, "memory_request_mb": 256}, 
        "container-api"
    )
    assert body_mem["spec"]["template"]["spec"]["containers"][0]["resources"]["limits"]["memory"] == "384Mi"

    body_scale = patch_executor._patch_body("SCALE_REPLICAS", {"replicas": 5}, "container-api")
    assert body_scale["spec"]["replicas"] == 5

    body_restart = patch_executor._patch_body("RESTART_DEPLOYMENT", {}, "container-api")
    assert "cdo.self-heal/restart-at" in body_restart["spec"]["template"]["metadata"]["annotations"]

    with pytest.raises(ValueError):
        patch_executor._patch_body("INVALID", {}, "container-api")

    # 3. Guard namespace
    patch_executor._guard_ns("tenant-payment")  # Valid
    with pytest.raises(PermissionError):
        patch_executor._guard_ns("invalid-namespace")


def test_patch_executor_dry_run():
    """Bao phủ các flow capture_pre_state, execute và rollback với dry_run=True."""
    decide_urgent = {
        "pattern_type": "urgent",
        "action_plan": [{
            "action": "PATCH_MEMORY_LIMIT",
            "target": "deployment/payment-api",
            "params": {"namespace": "tenant-payment", "container": "payment-container", "memory_limit_mb": 384}
        }]
    }
    
    snap = patch_executor.capture_pre_state(decide_urgent, dry_run=True)
    assert snap.pattern_type == "urgent"
    assert snap.namespace == "tenant-payment"
    assert snap.deployment_name == "payment-api"
    
    res = patch_executor.execute(decide_urgent, "corr-123", dry_run=True)
    assert res.status == "DRY_RUN"
    
    rb = patch_executor.rollback(snap, "corr-123", dry_run=True)
    assert rb.status == "DRY_RUN"

    decide_deferred = {
        "pattern_type": "deferred",
        "action_plan": [{
            "action": "PATCH_MEMORY_LIMIT",
            "target": "deployment/payment-api",
            "params": {"namespace": "tenant-payment", "container": "payment-container", "memory_limit_mb": 384}
        }]
    }
    
    snap_def = patch_executor.capture_pre_state(decide_deferred, dry_run=True)
    assert snap_def.pattern_type == "deferred"
    
    res_def = patch_executor.execute(decide_deferred, "corr-123", dry_run=True)
    assert res_def.status == "DRY_RUN"
    
    rb_def = patch_executor.rollback(snap_def, "corr-123", dry_run=True)
    assert rb_def.status == "DRY_RUN"


def test_security_scrubbing():
    """Bao phủ các regex và dict scrubbing trong webhook-receiver/src/security.py."""
    # Trỏ sys.path tạm thời về webhook-receiver để import trực tiếp security
    if webhook_path not in sys.path:
        sys.path.insert(0, webhook_path)
    import security
    
    # 1. Scrub keys
    assert security.scrub("AWS keys AKIAIOSFODNN7EXAMPLE and secret") == "AWS keys [SCRUBBED] and secret"
    assert security.scrub("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c") == "[SCRUBBED]"
    
    # 2. Scrub dict
    dirty_dict = {
        "user_email": "test@example.com",
        "aws_secret": "password123",
        "nested": {
            "credit_card": "1234-5678-9012-3456"
        }
    }
    cleaned = security.scrub_dict(dirty_dict)
    assert cleaned["user_email"] == "[SCRUBBED]"
    assert cleaned["aws_secret"] == "[SCRUBBED]"
    assert cleaned["nested"]["credit_card"] == "[SCRUBBED]"


@patch("boto3.client")
def test_webhook_client_ddb_acquire_lock(mock_boto):
    """Bao phủ client_ddb.acquire_lock."""
    if webhook_path not in sys.path:
        sys.path.insert(0, webhook_path)
    import client_ddb
    
    mock_db = MagicMock()
    mock_boto.return_value = mock_db
    
    # Success case
    mock_db.put_item.return_value = {}
    assert client_ddb.acquire_lock("lock1", 300) is True

    # Conditional check failed case (returns False)
    from botocore.exceptions import ClientError
    err = ClientError(
        error_response={"Error": {"Code": "ConditionalCheckFailedException", "Message": "Conflict"}},
        operation_name="PutItem"
    )
    mock_db.put_item.side_effect = err
    assert client_ddb.acquire_lock("lock1", 300) is False

    # Other ClientError (raises exception)
    err_other = ClientError(
        error_response={"Error": {"Code": "SomeOtherException", "Message": "Error"}},
        operation_name="PutItem"
    )
    mock_db.put_item.side_effect = err_other
    with pytest.raises(ClientError):
        client_ddb.acquire_lock("lock1", 300)


def test_webhook_client_ddb_lock_key():
    """Bao phủ client_ddb build key."""
    if webhook_path not in sys.path:
        sys.path.insert(0, webhook_path)
    import client_ddb

    key = client_ddb.build_lock_key("tenant", "namespace", "service", "alert")
    assert len(key) == 64  # SHA-256 hex digest length


# ---------------------------------------------------------------------------
# 5. PROMETHEUS CLIENT TESTS
# ---------------------------------------------------------------------------

def test_pod_oom_event_queries_restarts_total_not_last_terminated_reason():
    """kube_pod_container_status_last_terminated_reason chỉ tồn tại SAU lần OOMKill
    đầu tiên và luôn bằng 1 khi có — không có baseline "0" nào để BOCPD so sánh,
    nên AI engine luôn trả NO_ANOMALY. kube_pod_container_status_restarts_total là
    counter tăng dần từ 0 ngay từ khi container start — có baseline thật."""
    query_template = prometheus_query_client.SIGNAL_TO_PROM_QUERY["pod_oom_event"]
    assert "kube_pod_container_status_restarts_total" in query_template
    assert "last_terminated_reason" not in query_template


@patch.object(prometheus_query_client, "query_range")
def test_build_telemetry_window_matches_exact_pod_name(mock_query_range):
    """pod=~"{service}.*" là regex mờ — nếu 2 pod cùng prefix (vd pod thật
    order-api-7d9b4895ff-xxx và pod test order-api-oomtest-abcde) đều khớp,
    Prometheus trả về nhiều series và query_range() chỉ lấy results[0] — có thể
    vô tình lấy nhầm pod khoẻ mạnh thay vì pod đang alert. Phải match CHÍNH XÁC
    theo tên pod lấy từ alert.labels.pod, không dùng regex prefix mờ."""
    mock_query_range.return_value = [{"ts": 1700000000.0, "value": 5.0}]

    prometheus_query_client.build_telemetry_window(
        namespace="tenant-payment",
        service="order-api",
        signal_name="pod_oom_event",
        tenant_id="tenant-id-123",
        point_labels={},
        pod="order-api-oomtest-abcde",
    )

    query_sent = mock_query_range.call_args[0][0]
    assert query_sent == (
        'kube_pod_container_status_restarts_total'
        '{namespace="tenant-payment",pod="order-api-oomtest-abcde"}'
    )


@patch("httpx.Client.get")
def test_prometheus_query_range_parses_values(mock_get):
    mock_response = MagicMock()
    mock_response.raise_for_status.return_value = None
    mock_response.json.return_value = {
        "status": "success",
        "data": {
            "resultType": "matrix",
            "result": [
                {"metric": {}, "values": [[1700000000, "0"], [1700000030, "1"]]}
            ]
        }
    }
    mock_get.return_value = mock_response

    points = prometheus_query_client.query_range("up", window_seconds=60, step_seconds=30)

    assert points == [
        {"ts": 1700000000.0, "value": 0.0},
        {"ts": 1700000030.0, "value": 1.0},
    ]


@patch("httpx.Client.get")
def test_prometheus_query_range_empty_result_returns_empty_list(mock_get):
    mock_response = MagicMock()
    mock_response.raise_for_status.return_value = None
    mock_response.json.return_value = {"status": "success", "data": {"resultType": "matrix", "result": []}}
    mock_get.return_value = mock_response

    assert prometheus_query_client.query_range("up", window_seconds=60, step_seconds=30) == []


@patch("httpx.Client.get")
def test_prometheus_query_range_connection_error_returns_empty_list(mock_get):
    mock_get.side_effect = httpx.ConnectError("connection refused")

    assert prometheus_query_client.query_range("up", window_seconds=60, step_seconds=30) == []


@patch.object(prometheus_query_client, "query_range")
def test_build_telemetry_window_uses_prometheus_series(mock_query_range):
    mock_query_range.return_value = [
        {"ts": 1700000000.0, "value": 0.0},
        {"ts": 1700000030.0, "value": 1.0},
    ]

    window = prometheus_query_client.build_telemetry_window(
        namespace="tenant-payment",
        service="order-api",
        signal_name="pod_oom_event",
        tenant_id="tenant-id-123",
        point_labels={"deployment": "order-api"},
    )

    assert len(window) == 2
    assert window[0]["signal_name"] == "pod_oom_event"
    assert window[0]["tenant_id"] == "tenant-id-123"
    assert window[0]["service"] == "order-api"
    assert window[0]["value"] == 0.0
    assert window[1]["value"] == 1.0
    assert window[0]["labels"] == {"deployment": "order-api"}


@patch.object(prometheus_query_client, "query_range", return_value=[])
def test_build_telemetry_window_falls_back_when_prometheus_empty(mock_query_range):
    window = prometheus_query_client.build_telemetry_window(
        namespace="tenant-payment",
        service="order-api",
        signal_name="pod_oom_event",
        tenant_id="tenant-id-123",
        point_labels={},
    )

    assert len(window) == 1
    assert window[0]["value"] == 1.0
    assert window[0]["signal_name"] == "pod_oom_event"
    assert window[0]["tenant_id"] == "tenant-id-123"


def test_build_telemetry_window_unknown_signal_returns_fallback():
    window = prometheus_query_client.build_telemetry_window(
        namespace="tenant-payment",
        service="order-api",
        signal_name="not_a_real_signal",
        tenant_id="tenant-id-123",
        point_labels={},
    )

    assert len(window) == 1
    assert window[0]["value"] == 1.0
