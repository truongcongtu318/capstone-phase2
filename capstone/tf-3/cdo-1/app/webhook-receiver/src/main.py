from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
from typing import List, Optional
import boto3
import json
from src.config import settings
from src.security import scrub
from src.client_ddb import build_lock_key, acquire_lock

app = FastAPI()


class AlertLabel(BaseModel):
    alertname: str
    namespace: str
    service: str
    severity: Optional[str] = None
    pod: Optional[str] = None
    container: Optional[str] = None

class Alert(BaseModel):
    status: str
    labels: AlertLabel

class AlertmanagerPayload(BaseModel):
    alerts: List[Alert]

COOLDOWN_BY_NAMESPACE = {
    "tenant-payment":  180,
    "tenant-checkout": 300,
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
    payload: AlertmanagerPayload,
    x_tenant_id: Optional[str] = Header(None)
):
    for alert in payload.alerts:
        if alert.status != "firing":
            continue

        namespace = alert.labels.namespace

        # Bước 1: kiểm tra tenant_id khớp namespace
        expected_tenant_id = TENANT_ID_BY_NAMESPACE.get(namespace)
        if not expected_tenant_id or x_tenant_id != expected_tenant_id:
            raise HTTPException(status_code=403, detail="SECURITY_VIOLATION")

        # Bước 2: DynamoDB lock
        lock_key = build_lock_key(
            tenant_id=expected_tenant_id,
            namespace=namespace,
            service_name=alert.labels.service,
            alert_name=alert.labels.alertname
        )
        cooldown = COOLDOWN_BY_NAMESPACE.get(namespace, 300)
        if not acquire_lock(lock_key, cooldown):
            raise HTTPException(status_code=409, detail="Alert already being processed")

        # Bước 3: scrub + push SQS
        message = scrub(json.dumps(alert.model_dump()))
        _push_sqs(message)

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
