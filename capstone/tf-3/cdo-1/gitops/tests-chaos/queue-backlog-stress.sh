#!/usr/bin/env bash
set -euo pipefail

# Send synthetic alert messages to the self-heal SQS queue to exercise QueueBacklog.

QUEUE_URL=${QUEUE_URL:-}
MESSAGE_COUNT=${MESSAGE_COUNT:-150}
AWS_REGION=${AWS_REGION:-us-east-1}
AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL:-}
DRY_RUN=${DRY_RUN:-true}

report_evidence() {
  echo "========================================"
  echo "Queue Backlog Stress Evidence"
  echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Commit SHA: $(git rev-parse HEAD)"
  fi
  echo "========================================"
}

message_body() {
  local index=$1
  cat <<EOF
{"source":"member-9-chaos","type":"QueueBacklog","sequence":${index},"service":"sqs-worker","severity":"warning"}
EOF
}

aws_args=(--region "${AWS_REGION}")
if [[ -n "${AWS_ENDPOINT_URL}" ]]; then
  aws_args+=(--endpoint-url "${AWS_ENDPOINT_URL}")
fi

report_evidence
echo "Running queue backlog stress..."
echo "Queue URL: ${QUEUE_URL:-<not-set>}"
echo "Message count: ${MESSAGE_COUNT}"
echo "Region: ${AWS_REGION}"
echo "Dry run: ${DRY_RUN}"

if [[ -z "${QUEUE_URL}" ]]; then
  echo "[SKIP] QUEUE_URL is required to send messages."
  exit 0
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "[SKIP] Dry run enabled. First synthetic message would be:"
  message_body 1
  exit 0
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "[FAIL] aws CLI is required when DRY_RUN=false."
  exit 1
fi

for i in $(seq 1 "${MESSAGE_COUNT}"); do
  aws "${aws_args[@]}" sqs send-message \
    --queue-url "${QUEUE_URL}" \
    --message-body "$(message_body "${i}")" >/dev/null
done

echo "[PASS] Sent ${MESSAGE_COUNT} synthetic backlog messages."

echo "Verifying queue backlog..."
sleep 2
attributes=$(aws "${aws_args[@]}" sqs get-queue-attributes --queue-url "${QUEUE_URL}" --attribute-names ApproximateNumberOfMessages)
count=$(echo "${attributes}" | grep -o '"ApproximateNumberOfMessages": "[0-9]*"' | awk -F '"' '{print $4}')
echo "ApproximateNumberOfMessages: ${count:-unknown}"
if [[ -n "${count}" && "${count}" -gt 100 ]]; then
  echo "[PASS] Backlog is greater than 100."
else
  echo "[WARNING] Backlog count ${count:-unknown} may not trigger alert (>100 required)."
fi
