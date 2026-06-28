#!/usr/bin/env bash
set -e

# Usage instructions:
# Local Kind có thể dùng public image.
# EKS NAT-less bắt buộc dùng ECR private image.

NAMESPACE=${NAMESPACE:-tenant-payment}
APP_NAME=${APP_NAME:-oom-chaos}
ECR_REGISTRY=${ECR_REGISTRY:-544011261607.dkr.ecr.us-east-1.amazonaws.com}
IMAGE=${IMAGE:-${ECR_REGISTRY}/alexeiled/stress-ng:latest}
MEM_LIMIT=${MEM_LIMIT:-64Mi}

echo "Deploying OOM Chaos Test..."
echo "Namespace: $NAMESPACE"
echo "App Name: $APP_NAME"
echo "Image: $IMAGE"
echo "Memory Limit: $MEM_LIMIT"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $APP_NAME
  namespace: $NAMESPACE
  labels:
    app: $APP_NAME
spec:
  containers:
  - name: stress-ng
    image: $IMAGE
    command: ["stress-ng"]
    args: ["--vm", "1", "--vm-bytes", "128M", "--vm-keep", "--timeout", "60s"]
    resources:
      limits:
        memory: "$MEM_LIMIT"
      requests:
        memory: "32Mi"
  restartPolicy: Never
EOF

echo "Waiting for pod to be created..."
sleep 5

echo "Pod Status:"
kubectl get pod $APP_NAME -n $NAMESPACE || true

echo "Waiting for pod to be OOMKilled..."
OOM_DETECTED=false
for i in {1..60}; do
  REASON_LAST=$(kubectl get pod "$APP_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || true)
  REASON_CURR=$(kubectl get pod "$APP_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)

  if [[ "$REASON_LAST" == "OOMKilled" || "$REASON_CURR" == "OOMKilled" ]]; then
    echo "OOMKilled detected"
    OOM_DETECTED=true
    break
  fi

  sleep 2
done

if [ "$OOM_DETECTED" = false ]; then
  echo "Error: OOMKilled not detected within timeout."
  exit 1
fi

# Check evidence
echo "--- EVIDENCE ---"
echo "1. Pod Status:"
kubectl get pod $APP_NAME -n $NAMESPACE || true
echo "2. Events:"
kubectl get events -n $NAMESPACE --sort-by=.lastTimestamp | grep $APP_NAME || true
echo "3. Describe Pod:"
kubectl describe pod $APP_NAME -n $NAMESPACE | grep -A 10 "State" || true

echo "To cleanup run: kubectl delete pod $APP_NAME -n $NAMESPACE"
