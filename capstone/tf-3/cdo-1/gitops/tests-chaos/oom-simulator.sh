#!/usr/bin/env bash
set -euo pipefail

# Simulate an OOMKilled pod in a tenant namespace.
# Local Kind can override IMAGE to a public image. NAT-less EKS should use ECR.

NAMESPACE=${NAMESPACE:-tenant-payment}
APP_NAME=${APP_NAME:-oom-chaos}
AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID:-474013238625}
AWS_REGION=${AWS_REGION:-us-east-1}
ECR_REGISTRY=${ECR_REGISTRY:-${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com}
IMAGE=${IMAGE:-${ECR_REGISTRY}/alexeiled/stress-ng:latest}
MEM_LIMIT=${MEM_LIMIT:-64Mi}
VM_BYTES=${VM_BYTES:-128M}
TIMEOUT=${TIMEOUT:-60s}
DRY_RUN=${DRY_RUN:-false}
KUBECTL=${KUBECTL:-kubectl}
KUBECTL_VALIDATE=${KUBECTL_VALIDATE:-false}
KUBECTL_DRY_RUN=${KUBECTL_DRY_RUN:-false}

render_pod() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
    chaos.cdo1/member: "9"
spec:
  containers:
    - name: stress-ng
      image: ${IMAGE}
      args: ["--vm", "1", "--vm-bytes", "${VM_BYTES}", "--vm-keep", "--timeout", "${TIMEOUT}"]
      resources:
        limits:
          memory: "${MEM_LIMIT}"
        requests:
          memory: "32Mi"
  restartPolicy: Never
EOF
}

echo "Deploying OOM chaos test..."
echo "Namespace: ${NAMESPACE}"
echo "Pod: ${APP_NAME}"
echo "Image: ${IMAGE}"
echo "Memory limit: ${MEM_LIMIT}"
echo "VM bytes: ${VM_BYTES}"
echo "Dry run: ${DRY_RUN}"

if [[ "${DRY_RUN}" == "true" ]]; then
  if [[ "${KUBECTL_DRY_RUN}" == "true" ]]; then
    render_pod | "${KUBECTL}" apply --dry-run=client --validate="${KUBECTL_VALIDATE}" -f -
    echo "kubectl client dry-run completed. OOM pod was not applied."
  else
    echo "--- RENDERED POD MANIFEST ---"
    render_pod
    echo "--- END MANIFEST ---"
    echo "Manifest-only dry run completed. Set KUBECTL_DRY_RUN=true to ask kubectl to validate it."
  fi
  exit 0
fi

"${KUBECTL}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL}" apply -f -
render_pod | "${KUBECTL}" apply -f -

echo "Waiting for pod to be created..."
sleep 5

echo "--- POD STATUS ---"
"${KUBECTL}" get pod "${APP_NAME}" -n "${NAMESPACE}" || true

echo "Waiting for OOMKilled..."
OOM_DETECTED=false
for _ in {1..60}; do
  REASON_LAST=$("${KUBECTL}" get pod "${APP_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || true)
  REASON_CURR=$("${KUBECTL}" get pod "${APP_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)

  if [[ "${REASON_LAST}" == "OOMKilled" || "${REASON_CURR}" == "OOMKilled" ]]; then
    echo "[PASS] OOMKilled detected"
    OOM_DETECTED=true
    break
  fi

  sleep 2
done

if [[ "${OOM_DETECTED}" == "false" ]]; then
  echo "[FAIL] OOMKilled not detected within timeout."
  exit 1
fi

echo "--- EVIDENCE ---"
echo "1. Pod:"
"${KUBECTL}" get pod "${APP_NAME}" -n "${NAMESPACE}" -o wide || true
echo "2. Events:"
"${KUBECTL}" get events -n "${NAMESPACE}" --sort-by=.lastTimestamp | grep "${APP_NAME}" || true
echo "3. Container state:"
"${KUBECTL}" describe pod "${APP_NAME}" -n "${NAMESPACE}" | grep -A 12 "State" || true

echo "Cleanup: kubectl delete pod ${APP_NAME} -n ${NAMESPACE} --ignore-not-found"
