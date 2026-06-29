# 🧠 AI Engine HTTP API Client
# API Client thực hiện gọi các API chẩn đoán của AI Engine:
# 1. POST /v1/detect (Phân tích lỗi)
# 2. POST /v1/decide (Quyết định hành động vá)
# 3. POST /v1/verify (Xác minh sau khi vá)
# Ràng buộc bắt buộc gửi kèm 4 custom headers: X-Tenant-Id, Idempotency-Key, X-Correlation-Id, X-Dry-Run-Mode.

import time
import logging
import httpx
import jsonschema
from typing import Dict, Any, List, Optional
from src.config import settings

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# JSON SCHEMAS FOR RESPONSE VALIDATION
# ---------------------------------------------------------------------------

DETECT_SCHEMA = {
    "type": "object",
    "properties": {
        "anomaly_detected": {"type": "boolean"},
        "severity": {"type": "number"},
        "anomaly_context": {
            "type": "object",
            "properties": {
                "target_service": {"type": "string"},
                "suspected_fault_type": {"type": "string"},
                "system": {"type": "string"},
                "namespace": {"type": "string"},
                "deployment": {"type": "string"},
                "trigger_metric": {"type": "string"},
                "trigger_value": {"type": "number"}
            },
            "required": ["target_service", "namespace", "deployment"]
        },
        "confidence": {"type": "number"},
        "reasoning": {"type": "string"},
        "correlation_id": {"type": "string"}
    },
    "required": ["anomaly_detected"]
}

DECIDE_SCHEMA = {
    "type": "object",
    "properties": {
        "matched_runbook": {"type": "string"},
        "pattern_type": {"type": "string", "enum": ["urgent", "deferred"]},
        "action_plan": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "step": {"type": "integer"},
                    "action": {"type": "string"},
                    "target": {"type": "string"},
                    "params": {"type": "object"}
                },
                "required": ["action", "target"]
            }
        },
        "blast_radius_config": {"type": "object"},
        "verify_policy": {"type": "object"},
        "correlation_id": {"type": "string"},
        "idempotency_key": {"type": "string"},
        "dry_run_mode": {"type": "boolean"}
    },
    "required": ["pattern_type", "action_plan"]
}

VERIFY_SCHEMA = {
    "type": "object",
    "properties": {
        "success": {"type": "boolean"},
        "regression_detected": {"type": "boolean"},
        "next_action": {"type": "string", "enum": ["DONE", "RETRY", "ROLLBACK", "ESCALATE"]}
    },
    "required": ["next_action", "success"]
}

# ---------------------------------------------------------------------------
# CUSTOM EXCEPTIONS
# ---------------------------------------------------------------------------

class AIClientError(Exception):
    """Exception raised for AI API Client errors."""
    def __init__(
        self,
        status_code: int,
        detail: str,
        retryable: bool = False,
        retry_after: Optional[int] = None
    ):
        super().__init__(f"AI Engine returned {status_code}: {detail}")
        self.status_code = status_code
        self.detail = detail
        self.retryable = retryable
        self.retry_after = retry_after

# ---------------------------------------------------------------------------
# CORE REQUEST EXECUTION
# ---------------------------------------------------------------------------

def _send_request(
    endpoint: str,
    body: Dict[str, Any],
    headers: Dict[str, str],
    schema: Dict[str, Any]
) -> Dict[str, Any]:
    """
    Gửi HTTP POST request sang AI Engine, xử lý lỗi, retry 500, và validate JSON response schema.
    """
    url = f"{settings.ai_engine_url.rstrip('/')}{endpoint}"
    max_retries = 2

    for attempt in range(max_retries + 1):
        try:
            with httpx.Client(timeout=10.0) as client:
                response = client.post(url, json=body, headers=headers)

            status_code = response.status_code
            if status_code == 200:
                resp_json = response.json()
                
                # Validate response schema
                try:
                    jsonschema.validate(instance=resp_json, schema=schema)
                except jsonschema.ValidationError as schema_err:
                    logger.error(f"AI response schema validation failed for {endpoint}: {schema_err}")
                    raise AIClientError(400, f"Schema validation error: {schema_err}")
                return resp_json

            # Error mapping §3.3
            if status_code == 400:
                logger.error(f"AI Client 400 Bad Request on {endpoint}: {response.text}")
                raise AIClientError(400, response.text, retryable=False)
            elif status_code == 403:
                logger.error(f"AI Client 403 Tenant Mismatch on {endpoint}: {response.text}")
                raise AIClientError(403, response.text, retryable=False)
            elif status_code == 409:
                logger.warning(f"AI Client 409 Idempotency Conflict on {endpoint}: {response.text}")
                raise AIClientError(409, response.text, retryable=False)
            elif status_code == 429:
                retry_after_val = response.headers.get("Retry-After")
                retry_after = int(retry_after_val) if retry_after_val and retry_after_val.isdigit() else 5
                logger.warning(f"AI Client 429 Rate Limited on {endpoint}. Retry after {retry_after}s: {response.text}")
                raise AIClientError(429, response.text, retryable=False, retry_after=retry_after)
            elif status_code == 503:
                logger.error(f"AI Client 503 Service Unavailable on {endpoint}: {response.text}")
                raise AIClientError(503, response.text, retryable=False)
            elif status_code == 500:
                logger.warning(f"AI Client 500 on {endpoint} (Attempt {attempt+1}/{max_retries+1}): {response.text}")
                if attempt < max_retries:
                    sleep_time = 1 if attempt == 0 else 3
                    time.sleep(sleep_time)
                    continue
                else:
                    raise AIClientError(500, response.text, retryable=False)
            else:
                logger.error(f"AI Client unexpected status {status_code} on {endpoint}: {response.text}")
                raise AIClientError(status_code, response.text, retryable=False)

        except httpx.RequestError as exc:
            logger.warning(f"AI Client connection error on {endpoint} (Attempt {attempt+1}/{max_retries+1}): {exc}")
            if attempt < max_retries:
                sleep_time = 1 if attempt == 0 else 3
                time.sleep(sleep_time)
                continue
            else:
                raise AIClientError(500, f"Connection error: {exc}", retryable=False)

    raise AIClientError(500, "Max retries exceeded")

# ---------------------------------------------------------------------------
# PUBLIC ENDPOINTS
# ---------------------------------------------------------------------------

def detect(
    telemetry_window: List[Dict[str, Any]],
    tenant_id: str,
    idempotency_key: str,
    correlation_id: str,
    dry_run_mode: bool
) -> Dict[str, Any]:
    """Gọi POST /v1/detect để chẩn đoán xem có lỗi/sự cố bất thường không."""
    headers = {
        "X-Tenant-Id": tenant_id,
        "Idempotency-Key": idempotency_key,
        "X-Correlation-Id": correlation_id,
        "X-Dry-Run-Mode": "true" if dry_run_mode else "false",
        "Content-Type": "application/json"
    }
    body = {
        "idempotency_key": idempotency_key,
        "dry_run_mode": dry_run_mode,
        "telemetry_window": telemetry_window,
        "correlation_id": correlation_id
    }
    return _send_request("/v1/detect", body, headers, DETECT_SCHEMA)

def decide(
    anomaly_context: Dict[str, Any],
    tenant_id: str,
    idempotency_key: str,
    correlation_id: str,
    dry_run_mode: bool
) -> Dict[str, Any]:
    """Gọi POST /v1/decide để lấy phương án/kịch bản tự sửa lỗi (action plan)."""
    headers = {
        "X-Tenant-Id": tenant_id,
        "Idempotency-Key": idempotency_key,
        "X-Correlation-Id": correlation_id,
        "X-Dry-Run-Mode": "true" if dry_run_mode else "false",
        "Content-Type": "application/json"
    }
    body = {
        "idempotency_key": idempotency_key,
        "correlation_id": correlation_id,
        "anomaly_context": anomaly_context,
        "dry_run_mode": dry_run_mode
    }
    return _send_request("/v1/decide", body, headers, DECIDE_SCHEMA)

def verify(
    action_executed: Dict[str, Any],
    post_telemetry_window: List[Dict[str, Any]],
    tenant_id: str,
    idempotency_key: str,
    correlation_id: str,
    dry_run_mode: bool
) -> Dict[str, Any]:
    """Gọi POST /v1/verify để xác minh xem lỗi đã được vá thành công chưa."""
    headers = {
        "X-Tenant-Id": tenant_id,
        "Idempotency-Key": idempotency_key,
        "X-Correlation-Id": correlation_id,
        "X-Dry-Run-Mode": "true" if dry_run_mode else "false",
        "Content-Type": "application/json"
    }
    body = {
        "idempotency_key": idempotency_key,
        "correlation_id": correlation_id,
        "dry_run_mode": dry_run_mode,
        "action_executed": action_executed,
        "post_telemetry_window": post_telemetry_window
    }
    return _send_request("/v1/verify", body, headers, VERIFY_SCHEMA)
