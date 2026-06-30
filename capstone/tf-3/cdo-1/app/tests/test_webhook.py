# 🧪 FastAPI & Idempotency Unit Tests
import sys
import os
from unittest.mock import patch
from fastapi.testclient import TestClient

# Clear cached src modules and set path specifically for webhook-receiver
for mod in list(sys.modules.keys()):
    if mod == 'src' or mod.startswith('src.'):
        del sys.modules[mod]

app_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
webhook_path = os.path.join(app_dir, 'webhook-receiver')
if webhook_path in sys.path:
    sys.path.remove(webhook_path)
sys.path.insert(0, webhook_path)

from src.main import app
from src import main as webhook_main

client = TestClient(app)

VALID_PAYLOAD = {
    "alerts": [{
        "status": "firing",
        "labels": {
            "alertname": "PodOOMKilled",
            "namespace": "tenant-payment",
            "service": "payment-api",
            "severity": "critical"
        }
    }]
}

VALID_HEADERS = {
    "X-Tenant-Id": "d3b07384-d113-495f-9f58-20d18d357d75"
}

# Test 1: Alert hợp lệ → 202
@patch.object(webhook_main, "_push_sqs")
@patch.object(webhook_main, "acquire_lock", return_value=True)
def test_valid_alert_returns_202(mock_lock, mock_sqs):
    response = client.post("/alerts", json=VALID_PAYLOAD, headers=VALID_HEADERS)
    assert response.status_code == 202
    assert mock_lock.called        # DynamoDB lock đã được gọi
    assert mock_sqs.called         # SQS push đã được gọi

# Test 2: Alert trùng (đang cooldown) → 409
@patch.object(webhook_main, "acquire_lock", return_value=False)
def test_duplicate_alert_returns_409(mock_lock):
    response = client.post("/alerts", json=VALID_PAYLOAD, headers=VALID_HEADERS)
    assert response.status_code == 409

# Test 3: Tenant ID sai namespace → 403
def test_cross_tenant_returns_403():
    response = client.post(
        "/alerts",
        json=VALID_PAYLOAD,
        headers={"X-Tenant-Id": "6c8b4b2b-4d45-4209-a1b4-4b532d56a31c"}  # checkout ID nhưng payload là payment
    )
    assert response.status_code == 403