#!/usr/bin/env bash
set -euo pipefail

TENANT_NAMESPACE=${TENANT_NAMESPACE:-tenant-payment}
SELF_HEAL_NAMESPACE=${SELF_HEAL_NAMESPACE:-self-heal-system}
OBSERVABILITY_NAMESPACE=${OBSERVABILITY_NAMESPACE:-observability}
WEBHOOK_LABEL=${WEBHOOK_LABEL:-app=webhook-receiver}
SQS_WORKER_LABEL=${SQS_WORKER_LABEL:-app=sqs-worker}
STRICT=${STRICT:-false}

FAILURES=0

pass() {
  echo "[PASS] $*"
}

skip() {
  echo "[SKIP] $*"
}

fail() {
  echo "[FAIL] $*"
  FAILURES=$((FAILURES + 1))
}

kubectl_available() {
  command -v kubectl >/dev/null 2>&1
}

cluster_available() {
  kubectl version --client >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1
}

namespace_exists() {
  local namespace=$1
  if kubectl get namespace "$namespace" >/dev/null 2>&1; then
    pass "namespace $namespace exists"
  else
    fail "namespace $namespace not found"
  fi
}

pods_exist() {
  local namespace=$1
  local selector=$2
  local component=$3

  if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
    skip "$component check skipped because namespace $namespace is missing"
    return
  fi

  local pod_count
  pod_count=$(kubectl get pods -n "$namespace" -l "$selector" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$pod_count" -gt 0 ]]; then
    pass "$component pod exists in $namespace with selector $selector"
  else
    skip "$component pod not found in $namespace with selector $selector"
  fi
}

crd_exists() {
  local crd=$1
  local component=$2
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    pass "$component CRD exists"
  else
    skip "$component CRD not installed yet"
  fi
}

prometheus_rule_exists() {
  if ! kubectl get crd prometheusrules.monitoring.coreos.com >/dev/null 2>&1; then
    skip "PrometheusRule check skipped because CRD is not installed"
    return
  fi

  local rule_count
  rule_count=$(kubectl get prometheusrule -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$rule_count" -gt 0 ]]; then
    pass "PrometheusRule resources exist"
  else
    skip "PrometheusRule resources not created yet"
  fi
}

firehose_config_exists() {
  if ! kubectl get namespace "$SELF_HEAL_NAMESPACE" >/dev/null 2>&1; then
    skip "Firehose check skipped because namespace $SELF_HEAL_NAMESPACE is missing"
    return
  fi

  if kubectl get configmap,secret -n "$SELF_HEAL_NAMESPACE" -o name 2>/dev/null | grep -qi firehose; then
    pass "Firehose config or secret exists in $SELF_HEAL_NAMESPACE"
  else
    skip "Firehose config not ready yet"
  fi
}

echo "Validating partial E2E self-heal flow..."
echo "Tenant namespace: $TENANT_NAMESPACE"
echo "Self-heal namespace: $SELF_HEAL_NAMESPACE"
echo "Observability namespace: $OBSERVABILITY_NAMESPACE"

if ! kubectl_available; then
  skip "kubectl is not installed; cluster checks were not executed"
  exit 0
fi

if ! cluster_available; then
  skip "kubectl is installed but no reachable cluster context was found"
  exit 0
fi

namespace_exists "$TENANT_NAMESPACE"
namespace_exists "$SELF_HEAL_NAMESPACE"
namespace_exists "$OBSERVABILITY_NAMESPACE"

pods_exist "$SELF_HEAL_NAMESPACE" "$WEBHOOK_LABEL" "webhook receiver"
pods_exist "$SELF_HEAL_NAMESPACE" "$SQS_WORKER_LABEL" "sqs worker"

crd_exists prometheuses.monitoring.coreos.com "Prometheus"
crd_exists alertmanagers.monitoring.coreos.com "Alertmanager"
crd_exists prometheusrules.monitoring.coreos.com "PrometheusRule"
prometheus_rule_exists
firehose_config_exists

if [[ "$FAILURES" -gt 0 && "$STRICT" == "true" ]]; then
  echo "Validation completed with $FAILURES failure(s)."
  exit 1
fi

echo "Validation completed with $FAILURES failure(s); skipped checks are expected until Member 7/8 components are ready."
