# ⚡ Circuit Breaker & Alerts Escalation
# Quản lý trạng thái đếm lỗi của từng microservice bằng DynamoDB.
# Nếu xảy ra liên tiếp 3 lỗi tự vá thất bại trong vòng 1 giờ cho cùng 1 service:
# Kích hoạt ngắt mạch (Circuit Open), khóa tự động vá lỗi, gửi thông báo khẩn cấp qua AWS SNS Topic.

import time
import json
import logging
import boto3
from src.config import settings
from src.audit_logger import log_circuit_breaker_open

logger = logging.getLogger(__name__)

def _get_db_client():
    return boto3.client(
        "dynamodb",
        region_name=settings.aws_region,
        endpoint_url=settings.dynamodb_endpoint_url
    )

def _get_sns_client():
    return boto3.client(
        "sns",
        region_name=settings.aws_region,
        endpoint_url=settings.sns_endpoint_url
    )

def _build_cb_key(tenant_id: str, namespace: str, service: str) -> str:
    """Tạo lock key đặc trưng cho circuit breaker của service/tenant."""
    return f"cb#{tenant_id}#{namespace}#{service}"

def is_open(tenant_id: str, namespace: str, service: str) -> bool:
    """
    Kiểm tra trạng thái Circuit Breaker của dịch vụ.
    Nếu status = OPEN, trả về True để chặn tự chữa lành.
    """
    client = _get_db_client()
    key = _build_cb_key(tenant_id, namespace, service)
    try:
        response = client.get_item(
            TableName=settings.dynamodb_table_name,
            Key={"lock_key": {"S": key}}
        )
        item = response.get("Item")
        if item and item.get("status", {}).get("S") == "OPEN":
            return True
        return False
    except Exception as e:
        logger.error(f"Error checking circuit breaker status for {service}: {e}")
        return False

def record_failure(tenant_id: str, namespace: str, service: str, correlation_id: str) -> None:
    """
    Ghi nhận lỗi tự vá thất bại.
    - Cộng dồn lỗi trong vòng 1 giờ gần nhất.
    - Nếu >= 3 lỗi, chuyển trạng thái sang OPEN và bắn tin nhắn SNS Escalation + ghi log audit.
    """
    client = _get_db_client()
    key = _build_cb_key(tenant_id, namespace, service)
    now = int(time.time())
    one_hour_ago = now - 3600

    try:
        # Lấy thông tin circuit breaker hiện tại từ DynamoDB
        response = client.get_item(
            TableName=settings.dynamodb_table_name,
            Key={"lock_key": {"S": key}}
        )
        item = response.get("Item")

        failures = []
        if item and "failure_timestamps" in item:
            ts_set = item["failure_timestamps"].get("SS", [])
            for ts_str in ts_set:
                if ts_str.isdigit():
                    ts = int(ts_str)
                    if ts > one_hour_ago:
                        failures.append(ts)

        failures.append(now)
        failures = sorted(failures)

        status = "CLOSED"
        if len(failures) >= 3:
            status = "OPEN"

        # Cập nhật DynamoDB với thời gian sống (TTL) 24 giờ
        expiration = now + 86400

        item_data = {
            "lock_key": {"S": key},
            "status": {"S": status},
            "failure_timestamps": {"SS": [str(f) for f in failures]},
            "expiration_time": {"N": str(expiration)}
        }

        client.put_item(
            TableName=settings.dynamodb_table_name,
            Item=item_data
        )

        if status == "OPEN":
            logger.critical(f"Circuit Breaker OPEN for service {service} in namespace {namespace} due to 3 failures in 1 hour.")
            # Gửi cảnh báo SNS
            _trigger_sns_escalation(tenant_id, namespace, service, correlation_id, len(failures))
            # Ghi log audit
            try:
                log_circuit_breaker_open(tenant_id, correlation_id, service, len(failures))
            except Exception as audit_err:
                logger.error(f"Failed to log circuit breaker open event to audit log: {audit_err}")

    except Exception as e:
        logger.error(f"Error recording failure in circuit breaker for {service}: {e}")
        raise

def _trigger_sns_escalation(tenant_id: str, namespace: str, service: str, correlation_id: str, failure_count: int):
    """Gửi tin nhắn cảnh báo khẩn cấp qua AWS SNS Topic."""
    sns_client = _get_sns_client()
    subject = f"CRITICAL: Circuit Breaker OPEN for {service} ({namespace})"

    message_dict = {
        "event": "CIRCUIT_BREAKER_OPEN",
        "tenant_id": tenant_id,
        "namespace": namespace,
        "service": service,
        "correlation_id": correlation_id,
        "failure_count": failure_count,
        "error_window_seconds": 3600,
        "status": "OPEN",
        "timestamp": int(time.time()),
        "description": f"The service '{service}' in namespace '{namespace}' has failed automatic self-healing {failure_count} times within 1 hour. "
                       f"The circuit breaker is now OPEN and all automated healing actions for this service are suspended. "
                       f"Please perform manual verification and troubleshooting."
    }

    try:
        sns_client.publish(
            TopicArn=settings.sns_topic_arn,
            Subject=subject,
            Message=json.dumps(message_dict, indent=2, ensure_ascii=False)
        )
        logger.info(f"SNS escalation sent to topic {settings.sns_topic_arn}")
    except Exception as e:
        logger.error(f"Failed to send SNS escalation: {e}")
