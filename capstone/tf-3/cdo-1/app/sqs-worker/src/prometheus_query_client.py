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
#
# pod_oom_event dùng chung metric với container_restart_count
# (kube_pod_container_status_restarts_total), KHÔNG dùng
# kube_pod_container_status_last_terminated_reason: metric đó chỉ tồn tại SAU
# lần terminate đầu tiên và luôn = 1 khi có (== 1 filter) — không có baseline
# "0" nào trong series để BOCPD so sánh, nên AI engine luôn trả NO_ANOMALY dù
# pod đang OOMKill loop thật. restarts_total là counter tăng dần từ 0 ngay từ
# khi container start, có baseline thật trước khi restart đầu tiên xảy ra.
# pod_oom_event/container_restart_count match CHÍNH XÁC theo tên pod (không
# phải regex prefix "{service}.*") — nếu 2 pod chia sẻ cùng prefix tên (vd pod
# thật "order-api-7d9b4895ff-xxx" và pod test "order-api-oomtest-abcde" đều bắt
# đầu bằng "order-api"), regex mờ sẽ khớp NHIỀU series cùng lúc; query_range()
# chỉ lấy results[0] (thứ tự Prometheus trả về không đảm bảo cố định) nên có
# thể vô tình lấy nhầm pod khoẻ mạnh thay vì pod đang thực sự bị alert.
SIGNAL_TO_PROM_QUERY = {
    "pod_oom_event": (
        'kube_pod_container_status_restarts_total'
        '{{namespace="{namespace}",pod="{pod}"}}'
    ),
    "container_restart_count": (
        'kube_pod_container_status_restarts_total'
        '{{namespace="{namespace}",pod="{pod}"}}'
    ),
    "service_unhealthy": (
        'kube_deployment_status_replicas_available{{namespace="{namespace}",deployment="{service}"}}'
        ' / kube_deployment_spec_replicas{{namespace="{namespace}",deployment="{service}"}}'
    ),
    "queue_backlog": 'aws_sqs_approximate_number_of_messages_visible{{queue_name=~".*self-heal.*"}}',
    # Tín hiệu THỨ 2 gửi kèm mọi alert (bất kể loại), cùng pod/service với signal
    # chính. AI Engine's correlation_analyzer.py chỉ cho service 1 điểm khi có cột
    # metric vượt RCA_ZSCORE_THRESHOLD; với đúng 1 cột mỏng (vd restart count tăng
    # từng đơn vị), rất dễ không cột nào vượt ngưỡng -> toàn bộ service_scores = 0
    # -> rơi vào fallback hardcode "checkoutservice" (không phải service thật của
    # CDO). Gửi thêm memory usage thật (biến thiên mạnh hơn nhiều) làm bằng chứng
    # thứ 2 để RCA có cơ hội gán đúng service ngay cả khi tín hiệu chính yếu.
    "container_resource_usage": (
        'container_memory_working_set_bytes'
        '{{namespace="{namespace}",pod="{pod}",container="main"}}'
    ),
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
    pod: str = "",
) -> List[Dict[str, Any]]:
    """Build telemetry_window thật từ Prometheus cho signal_name tương ứng.

    `pod` là tên pod CHÍNH XÁC lấy từ alert.labels.pod — bắt buộc cho các
    signal match theo pod (pod_oom_event, container_restart_count) để tránh
    khớp nhầm sang pod khác chia sẻ cùng prefix tên service.

    Nếu không có mapping PromQL hoặc Prometheus không trả data (pod mới bị OOMKill,
    chưa có lịch sử) -> fallback về 1 điểm đơn hiện tại, để AI Engine vẫn nhận được
    tín hiệu thay vì request rỗng.
    """
    query_template = SIGNAL_TO_PROM_QUERY.get(signal_name)
    if not query_template:
        logger.warning(f"No Prometheus query mapping for signal_name '{signal_name}'. Using fallback point.")
        return [_fallback_point(tenant_id, service, signal_name, point_labels)]

    query = query_template.format(namespace=namespace, service=service, pod=pod)
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
