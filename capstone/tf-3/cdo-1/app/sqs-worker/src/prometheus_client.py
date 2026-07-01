# 📈 Prometheus Range Query Client
# Worker (Hands) tự truy vấn Prometheus lấy time series thật để build telemetry_window,
# thay vì gửi dữ liệu bịa lên AI Engine. AI Engine (Brain) không được phép tự query
# Prometheus hay gọi K8s API — đó là ranh giới Brain/Hands separation.

import logging
from datetime import datetime, timezone, timedelta
from typing import Any, Dict, List

import httpx

from src.config import settings

logger = logging.getLogger(__name__)

# signal_name (CONTRACT_SIGNAL_NAMES) -> PromQL query template
SIGNAL_TO_PROM_QUERY = {
    "pod_oom_event": (
        'kube_pod_container_status_last_terminated_reason'
        '{{reason="OOMKilled",namespace="{namespace}",pod=~"{service}.*"}} == 1'
    ),
    "container_restart_count": (
        'kube_pod_container_status_restarts_total'
        '{{namespace="{namespace}",pod=~"{service}.*"}}'
    ),
    "service_unhealthy": (
        'kube_deployment_status_replicas_available{{namespace="{namespace}",deployment="{service}"}}'
        ' / kube_deployment_spec_replicas{{namespace="{namespace}",deployment="{service}"}}'
    ),
    "queue_backlog": 'aws_sqs_approximate_number_of_messages_visible{{queue_name=~".*self-heal.*"}}',
}

_FALLBACK_VALUE = 1.0


def query_range(query: str, window_seconds: int, step_seconds: int) -> List[Dict[str, float]]:
    """Gọi Prometheus /api/v1/query_range. Trả về [] nếu không có data hoặc lỗi kết nối."""
    end = datetime.now(timezone.utc)
    start = end - timedelta(seconds=window_seconds)
    url = f"{settings.prometheus_url.rstrip('/')}/api/v1/query_range"
    params = {
        "query": query,
        "start": start.timestamp(),
        "end": end.timestamp(),
        "step": f"{step_seconds}s",
    }

    try:
        with httpx.Client(timeout=10.0) as client:
            response = client.get(url, params=params)
        response.raise_for_status()
        data = response.json()
    except httpx.HTTPError as exc:
        logger.warning(f"Prometheus query_range failed for query '{query}': {exc}")
        return []

    results = data.get("data", {}).get("result", [])
    if not results:
        return []

    values = results[0].get("values", [])
    return [{"ts": float(ts), "value": float(value)} for ts, value in values]


def build_telemetry_window(
    namespace: str,
    service: str,
    signal_name: str,
    tenant_id: str,
    point_labels: Dict[str, str],
) -> List[Dict[str, Any]]:
    """Build telemetry_window thật từ Prometheus cho signal_name tương ứng.

    Nếu không có mapping PromQL hoặc Prometheus không trả data (pod mới bị OOMKill,
    chưa có lịch sử) -> fallback về 1 điểm đơn hiện tại, để AI Engine vẫn nhận được
    tín hiệu thay vì request rỗng.
    """
    query_template = SIGNAL_TO_PROM_QUERY.get(signal_name)
    if not query_template:
        logger.warning(f"No Prometheus query mapping for signal_name '{signal_name}'. Using fallback point.")
        return [_fallback_point(tenant_id, service, signal_name, point_labels)]

    query = query_template.format(namespace=namespace, service=service)
    series = query_range(query, settings.prometheus_query_window_seconds, settings.prometheus_query_step_seconds)

    if not series:
        logger.warning(
            f"Prometheus returned no data for signal '{signal_name}' ({namespace}/{service}). Using fallback point."
        )
        return [_fallback_point(tenant_id, service, signal_name, point_labels)]

    return [
        {
            "ts": datetime.fromtimestamp(point["ts"], tz=timezone.utc).isoformat(),
            "tenant_id": tenant_id,
            "service": service,
            "signal_name": signal_name,
            "value": point["value"],
            "labels": point_labels,
        }
        for point in series
    ]


def _fallback_point(tenant_id: str, service: str, signal_name: str, point_labels: Dict[str, str]) -> Dict[str, Any]:
    return {
        "ts": datetime.now(timezone.utc).isoformat(),
        "tenant_id": tenant_id,
        "service": service,
        "signal_name": signal_name,
        "value": _FALLBACK_VALUE,
        "labels": point_labels,
    }
