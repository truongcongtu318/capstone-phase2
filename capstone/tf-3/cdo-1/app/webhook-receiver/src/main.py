from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
from typing import List, Optional
import boto3
import json
from prometheus_fastapi_instrumentator import Instrumentator
from prometheus_client import Counter
from src.config import settings
from src.security import scrub_dict
from src.client_ddb import build_lock_key, acquire_lock

app = FastAPI()
Instrumentator().instrument(app).expose(app)  # /metrics: HTTP latency, request count by status

SECURITY_VIOLATIONS = Counter(
    "webhook_security_violations_total",
    "Number of 403 SECURITY_VIOLATION rejections",
)
DUPLICATE_ALERTS = Counter(
    "webhook_duplicate_alerts_total",
    "Number of 409 duplicate idempotency lock rejections",
    ["tenant_id"],
)
ALERTS_QUEUED = Counter(
    "webhook_alerts_queued_total",
    "Number of alerts successfully pushed to SQS",
    ["tenant_id"],
)


class AlertLabel(BaseModel):
    alertname: str
    namespace: Optional[str] = None
    service: Optional[str] = None
    severity: Optional[str] = None
    pod: Optional[str] = None
    container: Optional[str] = None

class Annotations(BaseModel):
    summary: Optional[str] = None
    description: Optional[str] = None

class Alert(BaseModel):
    status: str
    labels: AlertLabel
    annotations: Optional[Annotations] = None
    startsAt: Optional[str] = None

class AlertmanagerPayload(BaseModel):
    receiver: Optional[str] = None
    status: Optional[str] = None
    alerts: List[Alert]

COOLDOWN_BY_NAMESPACE = {
    "tenant-payment":  settings.cooldown_payment_seconds,
    "tenant-checkout": settings.cooldown_checkout_seconds,
}

TENANT_ID_BY_NAMESPACE = {
    "tenant-payment":  "d3b07384-d113-495f-9f58-20d18d357d75",
    "tenant-checkout": "6c8b4b2b-4d45-4209-a1b4-4b532d56a31c",
}

@app.get("/health")
def health():
    return {"status": "healthy"}

@app.post("/alerts", status_code=202)
async def receive_alerts(
    payload: dict,
    x_tenant_id: Optional[str] = Header(None)
):
    import logging
    try:
        parsed_payload = AlertmanagerPayload(**payload)
    except Exception as e:
        logging.error(f"VALIDATION ERROR: {str(e)}")
        raise HTTPException(status_code=422, detail=str(e))
        
    for alert in parsed_payload.alerts:
        if alert.status != "firing":
            continue
            
        if alert.labels.alertname not in ["PodOOMKilled", "PodCrashLooping", "ServiceStuck", "SQSQueueBacklog"]:
            continue
            
        namespace = alert.labels.namespace
        if not namespace:
            continue

        # Bước 1: kiểm tra tenant_id khớp namespace
        expected_tenant_id = TENANT_ID_BY_NAMESPACE.get(namespace)
        if not expected_tenant_id:
            continue
            
        if x_tenant_id != expected_tenant_id:
            SECURITY_VIOLATIONS.inc()
            raise HTTPException(status_code=403, detail="SECURITY_VIOLATION")

        # Bước 2: DynamoDB lock
        service_name = alert.labels.service or "unknown-service"
        lock_key = build_lock_key(
            tenant_id=expected_tenant_id,
            namespace=namespace,
            service_name=service_name,
            alert_name=alert.labels.alertname
        )
        cooldown = COOLDOWN_BY_NAMESPACE.get(namespace, 300)
        if not acquire_lock(lock_key, cooldown):
            DUPLICATE_ALERTS.labels(tenant_id=expected_tenant_id).inc()
            raise HTTPException(status_code=409, detail="Alert already being processed")

        # Bước 3: scrub + push SQS
        message = json.dumps(scrub_dict(alert.model_dump()))
        _push_sqs(message)
        ALERTS_QUEUED.labels(tenant_id=expected_tenant_id).inc()

    return {"status": "accepted"}


def _push_sqs(message: str):
    client = boto3.client(
        "sqs",
        region_name=settings.aws_region,
        endpoint_url=settings.sqs_endpoint_url
    )
    client.send_message(
        QueueUrl=settings.sqs_queue_url,
        MessageBody=message
    )