from prometheus_client import Counter, Histogram, start_http_server as _start

MESSAGES_PROCESSED = Counter(
    "worker_messages_processed_total",
    "Total SQS messages processed",
    ["status"],  # COMPLETED, FAILED, SKIPPED_CB, DRY_RUN
)

AI_CALL_DURATION = Histogram(
    "worker_ai_call_duration_seconds",
    "Latency of AI Engine HTTP calls",
    ["endpoint"],  # /v1/detect, /v1/decide, /v1/verify
)

AI_ERRORS = Counter(
    "worker_ai_errors_total",
    "AI Engine errors by endpoint and HTTP status code",
    ["endpoint", "status_code"],
)

EXECUTIONS = Counter(
    "worker_executions_total",
    "Self-heal executions by action, lane and outcome",
    ["action", "lane", "status"],  # lane: fast | slow
)

CB_OPENS = Counter(
    "worker_circuit_breaker_open_total",
    "Number of times Circuit Breaker flipped to OPEN",
    ["tenant_id"],
)

CB_SKIPS = Counter(
    "worker_circuit_breaker_skips_total",
    "Messages skipped because Circuit Breaker is OPEN",
    ["tenant_id"],
)

ESCALATIONS = Counter(
    "worker_escalations_total",
    "Self-heal escalations to SRE",
    ["reason"],  # CB_OPEN, EXEC_FAILED, VERIFY_FAILED, EMPTY_PLAN, EXCEPTION
)

ROLLBACKS = Counter(
    "worker_rollbacks_total",
    "Rollback attempts",
    ["status"],  # COMPLETED, FAILED
)


def start_metrics_server(port: int = 9090) -> None:
    _start(port)
