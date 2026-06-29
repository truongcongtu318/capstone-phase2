#!/usr/bin/env bash
set -euo pipefail

# Simulate an OOMKilled pod in a tenant namespace.
# Local Kind can override IMAGE to a public image. NAT-less EKS should use ECR.

NAMESPACE=${NAMESPACE:-tenant-payment}
APP_NAME=${APP_NAME:-oom-chaos}
ECR_REGISTRY=${ECR_REGISTRY:-544011261607.dkr.ecr.us-east-1.amazonaws.com}
IMAGE=${IMAGE:-${ECR_REGISTRY}/alexeiled/stress-ng:latest}
MEM_LIMIT=${MEM_LIMIT:-64Mi}
VM_BYTES=${VM_BYTES:-128M}
TIMEOUT=${TIMEOUT:-60s}
DRY_RUN=${DRY_RUN:-false}

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
      command: ["stress-ng"]
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
  render_pod | kubectl apply --dry-run=client -f -
  echo "Dry run completed. OOM pod was not applied."
  exit 0
fi

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
render_pod | kubectl apply -f -

echo "Waiting for pod to be created..."
sleep 5

echo "--- POD STATUS ---"
kubectl get pod "${APP_NAME}" -n "${NAMESPACE}" || true

echo "Waiting for OOMKilled..."
OOM_DETECTED=false
for _ in {1..60}; do
  REASON_LAST=$(kubectl get pod "${APP_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || true)
  REASON_CURR=$(kubectl get pod "${APP_NAME}" -n "${NAMESPACE}" \
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
kubectl get pod "${APP_NAME}" -n "${NAMESPACE}" -o wide || true
echo "2. Events:"
kubectl get events -n "${NAMESPACE}" --sort-by=.lastTimestamp | grep "${APP_NAME}" || true
echo "3. Container state:"
kubectl describe pod "${APP_NAME}" -n "${NAMESPACE}" | grep -A 12 "State" || true

echo "Cleanup: kubectl delete pod ${APP_NAME} -n ${NAMESPACE} --ignore-not-found"
