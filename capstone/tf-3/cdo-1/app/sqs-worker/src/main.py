# 🔄 SQS Worker Polling Loop Entrypoint
# Khởi động vòng lặp liên tục polling tin nhắn từ SQS Queue.
# Phân tích tin nhắn alert, gọi module ai_client chẩn đoán lỗi.
# Gọi module patch_executor để vá lỗi, và ghi nhận audit logs bất biến qua audit_logger.

import os
import sys
import json
import time
import uuid
import logging
from datetime import datetime, timezone

# Cấu hình log
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("cdo-self-heal-worker")

# Đảm bảo import đúng cấu trúc thư mục của dự án
current_dir = os.path.dirname(os.path.abspath(__file__))
parent_dir = os.path.dirname(current_dir)
if parent_dir not in sys.path:
    sys.path.insert(0, parent_dir)

# Add webhook-receiver src path so audit_logger can import security.py
webhook_src = os.path.join(os.path.dirname(parent_dir), "webhook-receiver", "src")
if os.path.exists(webhook_src) and webhook_src not in sys.path:
    sys.path.insert(0, webhook_src)

import boto3
from src.config import settings
from src import ai_client
from src import circuit_breaker
from src import patch_executor
from src.metrics import (
    start_metrics_server,
    MESSAGES_PROCESSED, CB_SKIPS, EXECUTIONS, ESCALATIONS, ROLLBACKS,
)
from src.audit_logger import (
    log_incident_start,
    log_detect,
    log_decide,
    log_execute_start,
    log_execute_done,
    log_verify,
    log_rollback,
    log_escalate
)

TENANT_ID_BY_NAMESPACE = {
    "tenant-payment":  "d3b07384-d113-495f-9f58-20d18d357d75",
    "tenant-checkout": "6c8b4b2b-4d45-4209-a1b4-4b532d56a31c",
}

def _process_message(sqs_client, message) -> None:
    """Xử lý chi tiết một message nhận được từ SQS."""
    receipt_handle = message["ReceiptHandle"]
    body_str = message["Body"]

    correlation_id = str(uuid.uuid4())
    tenant_id = "unknown"
    namespace = "unknown"
    service = "unknown"

    try:
        alert = json.loads(body_str)
        labels = alert.get("labels", {})
        namespace = labels.get("namespace", "unknown")
        service = labels.get("service", "unknown")
        alertname = labels.get("alertname", "unknown")

        tenant_id = TENANT_ID_BY_NAMESPACE.get(namespace)
        if not tenant_id:
            logger.error(f"Unknown namespace '{namespace}' in alert. Message skipped and deleted.")
            sqs_client.delete_message(QueueUrl=settings.sqs_queue_url, ReceiptHandle=receipt_handle)
            return

        # 1. Log incident start
        log_incident_start(tenant_id, correlation_id, alert, settings.dry_run)

        # 2. Check circuit breaker status
        if circuit_breaker.is_open(tenant_id, namespace, service):
            reason = f"Circuit Breaker is OPEN for service '{service}' in namespace '{namespace}'. Skipping automatic recovery."
            logger.warning(reason)
            CB_SKIPS.labels(tenant_id=tenant_id).inc()
            log_escalate(tenant_id, correlation_id, reason, service, settings.dry_run)
            ESCALATIONS.labels(reason="CB_OPEN").inc()
            sqs_client.delete_message(QueueUrl=settings.sqs_queue_url, ReceiptHandle=receipt_handle)
            return

        # 3. Build telemetry window payload for AI Engine
        signal_name = "queue_backlog_event"
        if alertname == "PodOOMKilled":
            signal_name = "pod_oom_event"
        elif alertname == "PodCrashLooping":
            signal_name = "container_restart_count"

        telemetry_window = [{
            "ts": alert.get("startsAt") or datetime.now(timezone.utc).isoformat(),
            "tenant_id": tenant_id,
            "service": service,
            "signal_name": signal_name,
            "value": 1.0,
            "labels": {
                "system": "CDO-PAYMENT" if namespace == "tenant-payment" else "CDO-CHECKOUT",
                "namespace": namespace,
                "deployment": service,
                "pod_name": labels.get("pod", f"{service}-pod"),
                "container": labels.get("container", "main")
            }
        }]

        # 4. Invoke AI Engine /v1/detect
        # Mỗi API call có idempotency_key riêng độc lập (UUIDv4 per-call).
        # Lý do: key dùng cho idempotency lock tại server AI, không nên share giữa các bước khác nhau.
        detect_idem_key = str(uuid.uuid4())
        logger.info(f"Invoking /v1/detect for {service}...")
        detect_resp = ai_client.detect(telemetry_window, tenant_id, detect_idem_key, correlation_id, settings.dry_run)
        log_detect(tenant_id, correlation_id, detect_resp, settings.dry_run)

        if not detect_resp.get("anomaly_detected"):
            logger.info("AI Engine did not detect any anomaly. Ending flow.")
            MESSAGES_PROCESSED.labels(status="COMPLETED").inc()
            sqs_client.delete_message(QueueUrl=settings.sqs_queue_url, ReceiptHandle=receipt_handle)
            return

        # 5. Invoke AI Engine /v1/decide
        decide_idem_key = str(uuid.uuid4())
        logger.info(f"Invoking /v1/decide for {service}...")
        decide_resp = ai_client.decide(detect_resp.get("anomaly_context"), tenant_id, decide_idem_key, correlation_id, settings.dry_run)
        log_decide(tenant_id, correlation_id, decide_resp, settings.dry_run)

        action_plan = decide_resp.get("action_plan", [])
        if not action_plan:
            reason = "AI Engine decide returned empty action plan."
            logger.warning(reason)
            log_escalate(tenant_id, correlation_id, reason, service, settings.dry_run)
            ESCALATIONS.labels(reason="EMPTY_PLAN").inc()
            MESSAGES_PROCESSED.labels(status="FAILED").inc()
            sqs_client.delete_message(QueueUrl=settings.sqs_queue_url, ReceiptHandle=receipt_handle)
            return

        # 6. Capture pre-state snapshot for rollback
        snapshot = patch_executor.capture_pre_state(decide_resp, settings.dry_run)

        # 7. Execute self-healing action
        action_item = action_plan[0]
        action = action_item.get("action", "UNKNOWN")
        target = action_item.get("target", "UNKNOWN")
        pattern_type = decide_resp.get("pattern_type", "urgent")
        lane = "slow" if pattern_type == "deferred" else "fast"

        log_execute_start(tenant_id, correlation_id, action, target, pattern_type, settings.dry_run)

        logger.info(f"Executing self-heal action {action} on {target} ({pattern_type})...")
        exec_result = patch_executor.execute(decide_resp, correlation_id, settings.dry_run)
        log_execute_done(
            tenant_id, correlation_id, exec_result.action, exec_result.target,
            exec_result.status, exec_result.execution_time_seconds, exec_result.error, settings.dry_run
        )
        EXECUTIONS.labels(action=action, lane=lane, status=exec_result.status).inc()

        if exec_result.status == "FAILED":
            reason = f"Self-heal execution failed: {exec_result.error}"
            logger.error(reason)
            circuit_breaker.record_failure(tenant_id, namespace, service, correlation_id)
            log_escalate(tenant_id, correlation_id, reason, service, settings.dry_run)
            ESCALATIONS.labels(reason="EXEC_FAILED").inc()
            MESSAGES_PROCESSED.labels(status="FAILED").inc()
            sqs_client.delete_message(QueueUrl=settings.sqs_queue_url, ReceiptHandle=receipt_handle)
            return

        # 8. Build post-remediation telemetry & Call /v1/verify
        post_telemetry_window = [{
            "ts": datetime.now(timezone.utc).isoformat(),
            "tenant_id": tenant_id,
            "service": service,
            "signal_name": signal_name,
            "value": 0.0,  # remediated
            "labels": {
                "system": "CDO-PAYMENT" if namespace == "tenant-payment" else "CDO-CHECKOUT",
                "namespace": namespace,
                "deployment": service
            }
        }]

        action_executed = {
            "action": exec_result.action,
            "target": exec_result.target,
            "status": exec_result.status,
            "execution_time_seconds": exec_result.execution_time_seconds
        }

        verify_idem_key = str(uuid.uuid4())
        logger.info("Invoking /v1/verify...")
        verify_resp = ai_client.verify(action_executed, post_telemetry_window, tenant_id, verify_idem_key, correlation_id, settings.dry_run)
        log_verify(tenant_id, correlation_id, verify_resp, settings.dry_run)

        # 9. Process verification result
        success = verify_resp.get("success", False)
        next_action = verify_resp.get("next_action", "DONE")

        if not success or next_action in ("ROLLBACK", "ESCALATE"):
            reason = f"Verification failed. next_action = {next_action}"
            logger.error(reason)
            circuit_breaker.record_failure(tenant_id, namespace, service, correlation_id)

            if next_action == "ROLLBACK":
                logger.warning(f"Initiating rollback for deployment {service}...")
                log_rollback(tenant_id, correlation_id, "Verification failed, rolling back", {"pre_state": vars(snapshot)}, settings.dry_run)
                rb_result = patch_executor.rollback(snapshot, correlation_id, settings.dry_run)
                ROLLBACKS.labels(status=rb_result.status).inc()
                if rb_result.status == "FAILED":
                    logger.error(f"Rollback failed: {rb_result.error}")

            log_escalate(tenant_id, correlation_id, reason, service, settings.dry_run)
            ESCALATIONS.labels(reason="VERIFY_FAILED").inc()
            MESSAGES_PROCESSED.labels(status="FAILED").inc()
        else:
            logger.info(f"Self-heal successfully completed and verified for service '{service}' in namespace '{namespace}'.")
            status = "DRY_RUN" if settings.dry_run else "COMPLETED"
            MESSAGES_PROCESSED.labels(status=status).inc()

        # Delete message from SQS upon successful completion of the self-heal attempt
        sqs_client.delete_message(QueueUrl=settings.sqs_queue_url, ReceiptHandle=receipt_handle)

    except Exception as e:
        logger.exception(f"Unhandled exception processing message: {e}")
        # Ghi nhận lỗi vào circuit breaker nếu xác định được thông tin
        if tenant_id != "unknown" and namespace != "unknown" and service != "unknown":
            try:
                circuit_breaker.record_failure(tenant_id, namespace, service, correlation_id)
                log_escalate(tenant_id, correlation_id, f"Unhandled exception: {e}", service, settings.dry_run)
                ESCALATIONS.labels(reason="EXCEPTION").inc()
            except Exception as cb_err:
                logger.error(f"Failed to record failure in circuit breaker: {cb_err}")
        MESSAGES_PROCESSED.labels(status="FAILED").inc()

        # Xóa message tránh lặp vòng vô hạn (poison pill)
        try:
            sqs_client.delete_message(QueueUrl=settings.sqs_queue_url, ReceiptHandle=receipt_handle)
        except Exception as sqs_err:
            logger.error(f"Failed to delete message from SQS after failure: {sqs_err}")

def poll_messages() -> None:
    """Hàm polling liên tục tin nhắn từ SQS queue."""
    sqs_client = boto3.client(
        "sqs",
        region_name=settings.aws_region,
        endpoint_url=settings.sqs_endpoint_url
    )

    logger.info(f"Starting SQS Polling on : {settings.sqs_queue_url}")
    while True:
        try:
            response = sqs_client.receive_message(
                QueueUrl=settings.sqs_queue_url,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=20
            )

            messages = response.get("Messages", [])
            for message in messages:
                logger.info(f"Received message ID: {message.get('MessageId')}")
                _process_message(sqs_client, message)

        except Exception as e:
            logger.error(f"Error polling from SQS: {e}")
            time.sleep(5)

if __name__ == "__main__":
    start_metrics_server(9090)
    logger.info("Prometheus metrics server started on port 9090 (/metrics)")
    poll_messages()
