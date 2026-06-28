from __future__ import annotations
import json
import logging
import os
import time
from datetime import datetime, timezone
from typing import Any
import boto3
logger = logging.getLogger(__name__)
# ---------------------------------------------------------------------------
# CONSTANTS
# ---------------------------------------------------------------------------
FIREHOSE_STREAM_NAME = os.getenv(
    "FIREHOSE_STREAM_NAME", "tf3-cdo1-sandbox-audit-stream"
)
FIREHOSE_ENDPOINT_URL = os.getenv("FIREHOSE_ENDPOINT_URL") or None
AWS_REGION = os.getenv("AWS_DEFAULT_REGION", "us-east-1")
# Event types — đầy đủ lifecycle self-heal
EVENT_INCIDENT_START = "INCIDENT_START"
EVENT_DETECT = "DETECT"
EVENT_DECIDE = "DECIDE"
EVENT_EXECUTE_START = "EXECUTE_START"
EVENT_EXECUTE_DONE = "EXECUTE_DONE"
EVENT_VERIFY = "VERIFY"
EVENT_ROLLBACK = "ROLLBACK"
EVENT_ESCALATE = "ESCALATE"
EVENT_CIRCUIT_BREAKER_OPEN = "CIRCUIT_BREAKER_OPEN"
# ---------------------------------------------------------------------------
# FIREHOSE CLIENT (lazy singleton)
# ---------------------------------------------------------------------------
_firehose_client = None
def _get_firehose_client():
    """Trả về boto3 Firehose client (singleton, lazy init)."""
    global _firehose_client
    if _firehose_client is None:
        _firehose_client = boto3.client(
            "firehose",
            endpoint_url=FIREHOSE_ENDPOINT_URL,
            region_name=AWS_REGION,
        )
    return _firehose_client
def reset_client() -> None:
    """Reset Firehose client — dùng trong testing để inject mock."""
    global _firehose_client
    _firehose_client = None
def set_client(client) -> None:
    """Inject Firehose client trực tiếp — dùng trong testing."""
    global _firehose_client
    _firehose_client = client
# ---------------------------------------------------------------------------
# SOC2 AUDIT RECORD FORMATTING
# ---------------------------------------------------------------------------
def _format_soc2_record(
    event_type: str,
    tenant_id: str,
    correlation_id: str,
    details: dict[str, Any] | None = None,
    action: str | None = None,
    target: str | None = None,
    status: str | None = None,
    error: str | None = None,
) -> dict[str, Any]:
    """
    Tạo audit record chuẩn SOC2.
    Record chứa đầy đủ context để truy vết (who, what, when, where, outcome).
    Partition key = tenant_id giúp Firehose ghi S3 theo thư mục tenant.
    Returns:
        Dict audit record sẵn sàng serialize JSON.
    """
    now = datetime.now(timezone.utc)
    record: dict[str, Any] = {
        "event_type": event_type,
        "tenant_id": tenant_id,
        "correlation_id": correlation_id,
        "timestamp": now.isoformat(),
        "epoch": int(now.timestamp()),
        "source": "cdo-self-heal-worker",
        "version": "1.0",
    }
    if action:
        record["action"] = action
    if target:
        record["target"] = target
    if status:
        record["status"] = status
    if error:
        record["error"] = error
    if details:
        record["details"] = details
    # S3 partition hints (Firehose dynamic partitioning)
    record["partition_keys"] = {
        "tenant_id": tenant_id,
        "year": str(now.year),
        "month": f"{now.month:02d}",
        "day": f"{now.day:02d}",
    }
    return record
# ---------------------------------------------------------------------------
# SCRUB INTEGRATION
# ---------------------------------------------------------------------------
def _scrub_record(record: dict[str, Any]) -> dict[str, Any]:
    """
    Áp dụng security.scrub() lên toàn bộ audit record trước khi gửi.
    Import security.scrub tại runtime để tránh circular import
    (security.py nằm ở webhook-receiver, nhưng có thể được copy/symlink
    hoặc import qua sys.path đã được thiết lập bởi Docker image).
    """
    try:
        # Import tại đây để module có thể hoạt động standalone khi test
        from security import scrub_dict  # type: ignore[import-untyped]
    except ImportError:
        try:
            # Fallback: nếu security nằm trong webhook-receiver src
            import sys
            import os as _os
            webhook_src = _os.path.join(
                _os.path.dirname(_os.path.dirname(_os.path.dirname(__file__))),
                "webhook-receiver", "src",
            )
            if webhook_src not in sys.path:
                sys.path.insert(0, webhook_src)
            from security import scrub_dict  # type: ignore[import-untyped]
        except ImportError:
            logger.warning(
                "security.scrub_dict not available — audit record sent without scrubbing"
            )
            return record
    return scrub_dict(record)
# ---------------------------------------------------------------------------
# CORE EMIT FUNCTION
# ---------------------------------------------------------------------------
def emit(
    event_type: str,
    tenant_id: str,
    correlation_id: str,
    details: dict[str, Any] | None = None,
    action: str | None = None,
    target: str | None = None,
    status: str | None = None,
    error: str | None = None,
    dry_run: bool = False,
) -> dict[str, Any]:
    """
    Ghi một audit record vào Kinesis Data Firehose.
    SUBTEAM2_WORKING_DOC §3.6:
      record = scrub(format_soc2(event, tenant_id, correlation_id, ts))
      firehose.put_record(stream="tf3-cdo1-sandbox-audit-stream", data=record)
    Args:
        event_type:     Loại sự kiện (INCIDENT_START, DETECT, DECIDE, ...).
        tenant_id:      UUID v4 của tenant (partition key).
        correlation_id: UUID v4 trace log xuyên suốt hệ thống.
        details:        Dict chứa thông tin chi tiết bổ sung (optional).
        action:         Tên hành động (PATCH_MEMORY_LIMIT, SCALE_REPLICAS, ...).
        target:         Đối tượng bị tác động (deployment/payment-api, ...).
        status:         Trạng thái (COMPLETED, FAILED, DRY_RUN, ...).
        error:          Thông tin lỗi nếu có.
        dry_run:        Nếu True thì chỉ log, không gửi Firehose thật.
    Returns:
        Dict audit record đã gửi (sau khi scrub).
    """
    # 1. Format record chuẩn SOC2
    record = _format_soc2_record(
        event_type=event_type,
        tenant_id=tenant_id,
        correlation_id=correlation_id,
        details=details,
        action=action,
        target=target,
        status=status,
        error=error,
    )
    # 2. Scrub PII/secrets trước khi gửi
    record = _scrub_record(record)
    # 3. Serialize → JSON (1 record per line, newline-delimited)
    record_data = json.dumps(record, ensure_ascii=False, default=str) + "\n"
    # 4. Gửi lên Firehose (hoặc dry_run log)
    if dry_run:
        logger.info(
            "[DRY_RUN] audit_emit event_type=%s tenant=%s correlation_id=%s",
            event_type, tenant_id, correlation_id,
        )
        return record
    try:
        client = _get_firehose_client()
        response = client.put_record(
            DeliveryStreamName=FIREHOSE_STREAM_NAME,
            Record={"Data": record_data.encode("utf-8")},
        )
        logger.info(
            "audit_emit_ok event_type=%s tenant=%s correlation_id=%s record_id=%s",
            event_type,
            tenant_id,
            correlation_id,
            response.get("RecordId", "unknown"),
        )
    except Exception as exc:
        # Audit failure là critical — log nhưng không crash worker
        # (project-rules.md §Failure Modes: đóng băng nếu Firehose down)
        logger.error(
            "audit_emit_FAILED event_type=%s tenant=%s correlation_id=%s error=%s",
            event_type, tenant_id, correlation_id, exc,
        )
        raise
    return record
# ---------------------------------------------------------------------------
# CONVENIENCE WRAPPERS — gọi nhanh cho từng lifecycle event
# ---------------------------------------------------------------------------
def log_incident_start(
    tenant_id: str,
    correlation_id: str,
    alert_payload: dict[str, Any],
    dry_run: bool = False,
) -> dict[str, Any]:
    """Ghi log khi nhận alert mới → bắt đầu chu kỳ self-heal."""
    return emit(
        event_type=EVENT_INCIDENT_START,
        tenant_id=tenant_id,
        correlation_id=correlation_id,
        details={"alert_payload": alert_payload},
        status="TRIGGERED",
        dry_run=dry_run,
    )
def log_detect(
    tenant_id: str,
    correlation_id: str,
    detect_response: dict[str, Any],
    dry_run: bool = False,
) -> dict[str, Any]:
    """Ghi log kết quả /v1/detect."""
    return emit(
        event_type=EVENT_DETECT,
        tenant_id=tenant_id,
        correlation_id=correlation_id,
        details={"detect_response": detect_response},
        status="ANOMALY_DETECTED" if detect_response.get("anomaly_detected") else "NO_ANOMALY",
        dry_run=dry_run,
    )
def log_decide(
    tenant_id: str,
    correlation_id: str,
    decide_response: dict[str, Any],
    dry_run: bool = False,
) -> dict[str, Any]:
    """Ghi log kết quả /v1/decide (action plan)."""
    return emit(
        event_type=EVENT_DECIDE,
        tenant_id=tenant_id,
        correlation_id=correlation_id,
        details={"decide_response": decide_response},
        action=decide_response.get("action_plan", [{}])[0].get("action")
        if decide_response.get("action_plan") else None,
        target=decide_response.get("action_plan", [{}])[0].get("target")
        if decide_response.get("action_plan") else None,
        status="PLANNED",
        dry_run=dry_run,
    )
def log_execute_start(
    tenant_id: str,
    correlation_id: str,
    action: str,
    target: str,
    pattern_type: str,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Ghi log bắt đầu thực thi action."""
    return emit(
        event_type=EVENT_EXECUTE_START,
        tenant_id=tenant_id,
        correlation_id=correlation_id,
        action=action,
        target=target,
        status="IN_PROGRESS",
        details={"pattern_type": pattern_type},
        dry_run=dry_run,
    )
def log_execute_done(
    tenant_id: str,
    correlation_id: str,
    action: str,
    target: str,
    status: str,
    execution_time_seconds: float,
    error: str | None = None,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Ghi log kết quả thực thi action."""
    return emit(
        event_type=EVENT_EXECUTE_DONE,
        tenant_id=tenant_id,
        correlation_id=correlation_id,
        action=action,
        target=target,
        status=status,
        error=error,
        details={"execution_time_seconds": execution_time_seconds},
        dry_run=dry_run,
    )
def log_verify(
    tenant_id: str,
    correlation_id: str,
    verify_response: dict[str, Any],
    dry_run: bool = False,
) -> dict[str, Any]:
    """Ghi log kết quả /v1/verify."""
    return emit(
        event_type=EVENT_VERIFY,
        tenant_id=tenant_id,
        correlation_id=correlation_id,
        details={"verify_response": verify_response},
        status=verify_response.get("status", "UNKNOWN"),
        dry_run=dry_run,
    )
def log_rollback(
    tenant_id: str,
    correlation_id: str,
    reason: str,
    snapshot_info: dict[str, Any] | None = None,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Ghi log khi thực hiện rollback."""
    return emit(
        event_type=EVENT_ROLLBACK,
        tenant_id=tenant_id,
        correlation_id=correlation_id,
        action="ROLLBACK",
        status="ROLLBACK_INITIATED",
        details={"reason": reason, "snapshot": snapshot_info},
        dry_run=dry_run,
    )
def log_escalate(
    tenant_id: str,
    correlation_id: str,
    reason: str,
    service: str | None = None,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Ghi log khi escalate lên SRE (Circuit Breaker hoặc verify thất bại)."""
    return emit(
        event_type=EVENT_ESCALATE,
        tenant_id=tenant_id,
        correlation_id=correlation_id,
        action="ESCALATE",
        target=service,
        status="ESCALATED",
        details={"reason": reason},
        dry_run=dry_run,
    )
def log_circuit_breaker_open(
    tenant_id: str,
    correlation_id: str,
    service: str,
    failure_count: int,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Ghi log khi Circuit Breaker kích hoạt."""
    return emit(
        event_type=EVENT_CIRCUIT_BREAKER_OPEN,
        tenant_id=tenant_id,
        correlation_id=correlation_id,
        action="CIRCUIT_BREAKER_OPEN",
        target=service,
        status="CIRCUIT_BREAKER_OPEN",
        details={"failure_count": failure_count, "window": "1h"},
        dry_run=dry_run,
    )
    return _git_output(["rev-parse", "HEAD"], cwd=repo_dir)