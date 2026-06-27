#!/usr/bin/env bash
set -e

# Usage instructions:
# Local Kind có thể dùng public image.
# EKS NAT-less bắt buộc dùng ECR private image.

NAMESPACE=${NAMESPACE:-tenant-payment}
APP_NAME=${APP_NAME:-oom-chaos}
IMAGE=${IMAGE:-544011261607.dkr.ecr.us-east-1.amazonaws.com/stress-ng:latest}
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
    args: ["--vm", "1", "--vm-bytes", "128M", "--vm-keep"]
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
kubectl get pod $APP_NAME -n $NAMESPACE

echo "Waiting for pod to be OOMKilled..."
kubectl wait --for=condition=Ready pod/$APP_NAME -n $NAMESPACE --timeout=60s || true

# Check evidence
echo "--- EVIDENCE ---"
echo "1. Pod Status:"
kubectl get pod $APP_NAME -n $NAMESPACE
echo "2. Events:"
kubectl get events -n $NAMESPACE --sort-by=.lastTimestamp | grep $APP_NAME || true
echo "3. Describe Pod:"
kubectl describe pod $APP_NAME -n $NAMESPACE | grep -A 10 "State" || true

echo "To cleanup run: kubectl delete pod $APP_NAME -n $NAMESPACE"
