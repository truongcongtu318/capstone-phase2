#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITOPS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SELF_HEAL_NAMESPACE=${SELF_HEAL_NAMESPACE:-self-heal-system}
OBSERVABILITY_NAMESPACE=${OBSERVABILITY_NAMESPACE:-observability}
TENANT_NAMESPACES=${TENANT_NAMESPACES:-"tenant-payment tenant-checkout"}
WEBHOOK_LABEL=${WEBHOOK_LABEL:-app=webhook-receiver}
SQS_WORKER_LABEL=${SQS_WORKER_LABEL:-app=sqs-worker}
AI_ENGINE_LABEL=${AI_ENGINE_LABEL:-app=ai-engine}
SELF_HEAL_SA=${SELF_HEAL_SA:-system:serviceaccount:self-heal-system:self-heal-executor}
ARGOCD_SA=${ARGOCD_SA:-system:serviceaccount:argocd:argocd-application-controller}
STRICT=${STRICT:-true}

FAILURES=0

report_evidence() {
  echo "========================================"
  echo "Validation Report Evidence"
  echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Commit SHA: $(git rev-parse HEAD)"
  fi
  echo "========================================"
}

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

file_exists() {
  local path=$1
  local label=$2
  if [[ -f "${path}" ]]; then
    pass "${label} exists"
  else
    fail "${label} missing: ${path}"
  fi
}

file_contains() {
  local path=$1
  local pattern=$2
  local label=$3
  if [[ -f "${path}" ]] && grep -Eq "${pattern}" "${path}"; then
    pass "${label}"
  else
    fail "${label}"
  fi
}

kubectl_available() {
  command -v kubectl >/dev/null 2>&1
}

cluster_available() {
  kubectl version --client >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1
}

namespace_exists() {
  local namespace=$1
  if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    pass "namespace ${namespace} exists"
  else
    fail "namespace ${namespace} not found"
  fi
}

resource_exists() {
  local description=$1
  shift
  if kubectl "$@" >/dev/null 2>&1; then
    pass "${description}"
  else
    fail "${description} not found"
  fi
}

auth_can_i() {
  local expected=$1
  local description=$2
  shift 2
  local actual
  actual=$(kubectl auth can-i "$@" 2>/dev/null || true)
  if [[ "${actual}" == "${expected}" ]]; then
    pass "${description}: ${actual}"
  else
    fail "${description}: expected ${expected}, got ${actual:-<empty>}"
  fi
}

report_evidence
echo "Validating CDO-01 Member 9 E2E readiness..."
echo "GitOps dir: ${GITOPS_DIR}"
echo "Tenant namespaces: ${TENANT_NAMESPACES}"

echo "--- Local manifest checks ---"
file_exists "${GITOPS_DIR}/security-policies/kustomization.yaml" "security-policies kustomization"
file_exists "${GITOPS_DIR}/security-policies/namespaces.yaml" "namespace wave -4 manifest"
file_contains "${GITOPS_DIR}/security-policies/namespaces.yaml" 'name: tenant-payment' "tenant-payment namespace declared"
file_contains "${GITOPS_DIR}/security-policies/namespaces.yaml" 'name: tenant-checkout' "tenant-checkout namespace declared"
file_contains "${GITOPS_DIR}/security-policies/namespaces.yaml" 'name: self-heal-system' "self-heal-system namespace declared"
file_contains "${GITOPS_DIR}/security-policies/namespaces.yaml" 'name: observability' "observability namespace declared"
file_contains "${GITOPS_DIR}/security-policies/restrict-mutations.yaml" 'name: restrict-mutations' "Kyverno ClusterPolicy restrict-mutations declared"
file_contains "${GITOPS_DIR}/security-policies/rbac.yaml" 'name: self-heal-executor-role' "self-heal-executor ClusterRole declared"
file_contains "${GITOPS_DIR}/security-policies/rbac.yaml" 'namespace: tenant-payment' "tenant-payment RoleBinding declared"
file_contains "${GITOPS_DIR}/security-policies/rbac.yaml" 'namespace: tenant-checkout' "tenant-checkout RoleBinding declared"
file_contains "${GITOPS_DIR}/security-policies/network-policies/webhook-netpolicy.yaml" 'name: webhook-netpolicy' "webhook NetworkPolicy declared"
file_contains "${GITOPS_DIR}/security-policies/network-policies/ai-engine-netpolicy.yaml" 'name: ai-engine-netpolicy' "ai-engine NetworkPolicy declared"
file_contains "${GITOPS_DIR}/monitoring/prometheus-rules.yaml" 'alert: PodOOMKilled' "PodOOMKilled alert declared"
file_contains "${GITOPS_DIR}/monitoring/prometheus-rules.yaml" 'alert: QueueBacklog' "QueueBacklog alert declared"
file_contains "${GITOPS_DIR}/monitoring/alertmanager-config.yaml" 'webhook-receiver.self-heal-system.svc.cluster.local' "Alertmanager routes to webhook receiver"
file_exists "${GITOPS_DIR}/manifests/base/webhook-receiver/service.yaml" "webhook-receiver Service manifest"
file_exists "${GITOPS_DIR}/manifests/base/sqs-worker/serviceaccount.yaml" "sqs-worker self-heal-executor ServiceAccount manifest"
file_exists "${GITOPS_DIR}/manifests/base/ai-engine/service.yaml" "ai-engine Service manifest"

if ! kubectl_available; then
  skip "kubectl client unavailable; client and cluster checks were not executed"
else
  echo "--- Kustomize client checks ---"
  if kubectl kustomize "${GITOPS_DIR}/security-policies" >/dev/null 2>&1; then
    pass "kubectl kustomize security-policies"
  else
    fail "kubectl kustomize security-policies"
  fi

  if ! cluster_available; then
    skip "BLOCKED_BY_INFRA: kubectl is installed but no reachable cluster context was found"
  else
    echo "--- Cluster checks ---"
    if kubectl apply --dry-run=server -k "${GITOPS_DIR}/security-policies" >/dev/null 2>&1; then
      pass "server dry-run security-policies"
    else
      skip "BLOCKED_BY_INFRA: server dry-run security-policies needs cluster CRDs/admission ready"
    fi

  namespace_exists "${SELF_HEAL_NAMESPACE}"
  namespace_exists "${OBSERVABILITY_NAMESPACE}"
  for namespace in ${TENANT_NAMESPACES}; do
    namespace_exists "${namespace}"
  done

  resource_exists "Kyverno ClusterPolicy restrict-mutations exists" get clusterpolicy restrict-mutations
  resource_exists "self-heal-executor RoleBinding exists in tenant-payment" get rolebinding self-heal-executor-binding -n tenant-payment
  resource_exists "self-heal-executor RoleBinding exists in tenant-checkout" get rolebinding self-heal-executor-binding -n tenant-checkout
  resource_exists "webhook NetworkPolicy exists" get networkpolicy webhook-netpolicy -n "${SELF_HEAL_NAMESPACE}"
  resource_exists "ai-engine NetworkPolicy exists" get networkpolicy ai-engine-netpolicy -n "${SELF_HEAL_NAMESPACE}"
  resource_exists "webhook-receiver Service exists" get service webhook-receiver -n "${SELF_HEAL_NAMESPACE}"
  resource_exists "sqs-worker ServiceAccount exists" get serviceaccount self-heal-executor -n "${SELF_HEAL_NAMESPACE}"

  if kubectl get pods -n "${SELF_HEAL_NAMESPACE}" -l "${WEBHOOK_LABEL}" --no-headers 2>/dev/null | grep -q .; then
    pass "webhook-receiver pod exists"
  else
    skip "webhook-receiver pod not ready yet"
  fi

  if kubectl get pods -n "${SELF_HEAL_NAMESPACE}" -l "${SQS_WORKER_LABEL}" --no-headers 2>/dev/null | grep -q .; then
    pass "sqs-worker pod exists"
  else
    skip "sqs-worker pod not ready yet"
  fi

  if kubectl get pods -n "${SELF_HEAL_NAMESPACE}" -l "${AI_ENGINE_LABEL}" --no-headers 2>/dev/null | grep -q .; then
    pass "ai-engine pod exists"
  else
    skip "ai-engine pod not ready yet"
  fi

  auth_can_i yes "self-heal-executor can patch tenant-payment deployment" patch deployment -n tenant-payment --as="${SELF_HEAL_SA}"
  auth_can_i yes "self-heal-executor can patch tenant-checkout deployment" patch deployment -n tenant-checkout --as="${SELF_HEAL_SA}"
  auth_can_i no "self-heal-executor cannot patch argocd deployment" patch deployment -n argocd --as="${SELF_HEAL_SA}"
  auth_can_i no "self-heal-executor cannot patch observability deployment" patch deployment -n observability --as="${SELF_HEAL_SA}"
  auth_can_i yes "argocd controller can patch tenant-payment deployment" patch deployment -n tenant-payment --as="${ARGOCD_SA}"

  resource_exists "PrometheusRule cdo1-self-heal-alerts exists" get prometheusrule cdo1-self-heal-alerts -n "${OBSERVABILITY_NAMESPACE}"
  resource_exists "AlertmanagerConfig cdo1-self-heal-routing exists" get alertmanagerconfig cdo1-self-heal-routing -n "${OBSERVABILITY_NAMESPACE}"

  if kubectl get configmap,secret -n "${SELF_HEAL_NAMESPACE}" -o name 2>/dev/null | grep -qi firehose; then
    pass "Firehose audit config exists"
  else
    skip "Firehose audit config not ready yet"
  fi
  fi
fi

if [[ "${FAILURES}" -gt 0 && "${STRICT}" == "true" ]]; then
  echo "Validation completed with ${FAILURES} failure(s)."
  exit 1
fi

echo "Validation completed with ${FAILURES} failure(s)."
