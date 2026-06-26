"""
Minimal Webhook Receiver — Pack #1 luồng tối thiểu.

Nhận alert từ Alertmanager → gọi /v1/detect → nếu phát hiện anomaly → gọi /v1/decide
→ log quyết định (Pack #1 không execute action, đó là việc của Self-Heal Controller ở Pack #2).

Contract tham chiếu: lab-w11/Capstone-Phase-2-CodeAI/demo/app/main.py
  - /v1/detect  body: {idempotency_key, dry_run_mode, telemetry_window, correlation_id?}
                headers required: X-Tenant-Id, Idempotency-Key, X-Dry-Run-Mode
                response: {anomaly_detected, severity, anomaly_context, confidence, reasoning, correlation_id}

  - /v1/decide  body: {idempotency_key, correlation_id, anomaly_context, dry_run_mode}
                headers required: X-Tenant-Id, Idempotency-Key, X-Dry-Run-Mode, X-Correlation-Id
                response: {matched_runbook, pattern_type, action_plan, ...}

Port: 8443  Path: /alerts  (khớp alert_receiver_url trong modules/observability/main.tf)
"""

import uuid
import logging
import httpx
from datetime import datetime, timezone
from fastapi import FastAPI, Request, HTTPException

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s"
)
logger = logging.getLogger("webhook-receiver")

app = FastAPI(title="CDO Webhook Receiver", version="0.1.0-pack1")

AI_ENGINE_URL = "http://ai-engine.self-heal-system.svc.cluster.local:8080"
DEFAULT_TENANT_ID = "d3b07384-d113-495f-9f58-20d18d357d75"  # payment — docs/02_infra_design.md §4.1


@app.get("/health")
def health():
    return {"status": "healthy", "version": "pack1-minimal"}


@app.get("/ready")
def ready():
    return {"status": "ready"}


@app.post("/alerts")
async def receive_alert(request: Request):
    """Alertmanager webhook endpoint (docs/03_security_design.md §1.1: qua ClusterIP)."""
    try:
        payload = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")

    status = payload.get("status", "unknown")
    alerts = payload.get("alerts", [])
    logger.info("Received webhook: status=%s alerts=%d", status, len(alerts))

    for alert in alerts:
        if alert.get("status") == "firing":
            await _process_alert(alert)

    return {"received": True, "processed": sum(1 for a in alerts if a.get("status") == "firing")}


async def _process_alert(alert: dict):
    labels = alert.get("labels", {})
    alertname = labels.get("alertname", "UnknownAlert")
    namespace = labels.get("namespace", "unknown")
    pod = labels.get("pod", "unknown")
    started_at = alert.get("startsAt", datetime.now(timezone.utc).isoformat())
    idempotency_key = str(uuid.uuid4())
    correlation_id = str(uuid.uuid4())
    tenant_id = labels.get("tenant_id", DEFAULT_TENANT_ID)

    logger.info("[%s] Processing alert: %s namespace=%s pod=%s",
                idempotency_key, alertname, namespace, pod)

    # Chuyển đổi alert Alertmanager → telemetry format của AI Engine
    telemetry = [{
        "metric_name": alertname,
        "value": float(labels.get("value", 1)),
        "timestamp": started_at,
        "labels": {k: v for k, v in labels.items()}
    }]

    async with httpx.AsyncClient(timeout=15.0) as client:

        # ── Bước 1: /v1/detect ──────────────────────────────────────────────
        detect_headers = {
            "Content-Type": "application/json",
            "X-Tenant-Id": tenant_id,
            "Idempotency-Key": idempotency_key,
            "X-Dry-Run-Mode": "false",
            # Authorization header ĐÃ BỎ — Local Trust model (ai-api-contract.md)
        }
        try:
            detect_resp = await client.post(
                f"{AI_ENGINE_URL}/v1/detect",
                json={
                    "idempotency_key": idempotency_key,
                    "dry_run_mode": False,
                    "telemetry_window": telemetry,
                    "correlation_id": correlation_id,
                },
                headers=detect_headers,
            )
            detect_resp.raise_for_status()
        except httpx.HTTPStatusError as e:
            logger.error("[%s] /v1/detect HTTP %s: %s",
                         idempotency_key, e.response.status_code, e.response.text)
            return
        except httpx.RequestError as e:
            logger.error("[%s] /v1/detect connection error: %s", idempotency_key, e)
            return

        detect_result = detect_resp.json()
        # Dùng correlation_id từ response của AI Engine nếu có (họ có thể gán lại)
        ai_correlation_id = detect_result.get("correlation_id", correlation_id)

        logger.info("[%s] /v1/detect → anomaly_detected=%s confidence=%s",
                    idempotency_key,
                    detect_result.get("anomaly_detected"),
                    detect_result.get("confidence"))

        if not detect_result.get("anomaly_detected"):
            logger.info("[%s] No anomaly — skipping decide", idempotency_key)
            return

        anomaly_context = detect_result.get("anomaly_context", {})

        # ── Bước 2: /v1/decide ──────────────────────────────────────────────
        # X-Correlation-Id là header BẮT BUỘC theo main.py của AI team
        decide_headers = {
            "Content-Type": "application/json",
            "X-Tenant-Id": tenant_id,
            "Idempotency-Key": idempotency_key,
            "X-Dry-Run-Mode": "false",
            "X-Correlation-Id": ai_correlation_id,
        }
        try:
            decide_resp = await client.post(
                f"{AI_ENGINE_URL}/v1/decide",
                json={
                    "idempotency_key": idempotency_key,
                    "correlation_id": ai_correlation_id,
                    "anomaly_context": anomaly_context,   # trường đúng theo contract
                    "dry_run_mode": False,
                },
                headers=decide_headers,
            )
            decide_resp.raise_for_status()
        except httpx.HTTPStatusError as e:
            logger.error("[%s] /v1/decide HTTP %s: %s",
                         idempotency_key, e.response.status_code, e.response.text)
            return
        except httpx.RequestError as e:
            logger.error("[%s] /v1/decide connection error: %s", idempotency_key, e)
            return

        decide_result = decide_resp.json()
        action_plan = decide_result.get("action_plan", [])
        runbook = decide_result.get("matched_runbook", "N/A")

        logger.info(
            "[%s] /v1/decide → runbook=%s actions=%d pattern=%s "
            "[Pack#1: logged only — Pack#2 Self-Heal Controller will execute]",
            idempotency_key,
            runbook,
            len(action_plan),
            decide_result.get("pattern_type"),
        )
        for step in action_plan:
            logger.info("[%s]   step %s: %s → %s",
                        idempotency_key,
                        step.get("step"),
                        step.get("action"),
                        step.get("target"))
