#!/usr/bin/env bash
set -euo pipefail

# Apply a temporary NetworkPolicy that denies egress to a target DB CIDR.

NAMESPACE=${NAMESPACE:-tenant-payment}
APP_LABEL=${APP_LABEL:-payment-api}
DB_CIDR=${DB_CIDR:?DB_CIDR is required, example: 10.42.12.34/32}
DB_ENDPOINT=${DB_ENDPOINT:-}
POLICY_NAME=${POLICY_NAME:-chaos-deny-db-egress}
DRY_RUN=${DRY_RUN:-false}
AUTO_CLEANUP=${AUTO_CLEANUP:-false}
KUBECTL=${KUBECTL:-kubectl}
KUBECTL_VALIDATE=${KUBECTL_VALIDATE:-false}
KUBECTL_DRY_RUN=${KUBECTL_DRY_RUN:-false}

report_evidence() {
  echo "========================================"
  echo "Network Blockade Evidence"
  echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Commit SHA: $(git rev-parse HEAD)"
  fi
  echo "========================================"
}

probe_connection() {
  local phase=$1
  if [[ -z "${DB_ENDPOINT}" ]]; then
    echo "[NOT_VALIDATED] DB_ENDPOINT not set. Skipping probe (${phase})."
    return
  fi
  
  local pod_name
  pod_name=$("${KUBECTL}" get pod -n "${NAMESPACE}" -l "app=${APP_LABEL}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "${pod_name}" ]]; then
    echo "[NOT_VALIDATED] No pod found for app=${APP_LABEL}. Skipping probe (${phase})."
    return
  fi

  echo "Probing ${DB_ENDPOINT} from ${pod_name} (${phase})..."
  local host="${DB_ENDPOINT%:*}"
  local port="${DB_ENDPOINT##*:}"
  
  # Try nc first, fallback to wget if nc is missing
  local check_cmd="nc -z -w 3 ${host} ${port} || wget --spider -T 3 ${host}:${port} >/dev/null 2>&1"
  
  if "${KUBECTL}" exec -n "${NAMESPACE}" "${pod_name}" -- sh -c "${check_cmd}" >/dev/null 2>&1; then
    echo "[PROBE] ${phase}: Connection to ${DB_ENDPOINT} SUCCEEDED."
  else
    echo "[PROBE] ${phase}: Connection to ${DB_ENDPOINT} FAILED / BLOCKED."
  fi
}

cleanup() {
  if [[ "${AUTO_CLEANUP}" == "true" && "${DRY_RUN}" != "true" ]]; then
    echo "Cleaning up NetworkPolicy..."
    "${KUBECTL}" delete networkpolicy "${POLICY_NAME}" -n "${NAMESPACE}" --ignore-not-found
    probe_connection "AFTER_CLEANUP"
  fi
}
trap cleanup EXIT

render_policy() {
  cat <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${POLICY_NAME}
  namespace: ${NAMESPACE}
  labels:
    chaos.cdo1/member: "9"
spec:
  podSelector:
    matchLabels:
      app: ${APP_LABEL}
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - ${DB_CIDR}
EOF
}

report_evidence
echo "Applying DB network blockade..."
echo "Namespace: ${NAMESPACE}"
echo "App label: app=${APP_LABEL}"
echo "DB CIDR: ${DB_CIDR}"
echo "DB ENDPOINT: ${DB_ENDPOINT:-<not-set>}"
echo "Policy: ${POLICY_NAME}"
echo "Dry run: ${DRY_RUN}"
echo "WARNING: Kubernetes NetworkPolicy is allow-list based. This blocks DB only if no other NetworkPolicy allows DB egress for the selected pods."

if [[ "${DRY_RUN}" == "true" ]]; then
  if [[ "${KUBECTL_DRY_RUN}" == "true" ]]; then
    render_policy | "${KUBECTL}" apply --dry-run=client --validate="${KUBECTL_VALIDATE}" -f -
    echo "kubectl client dry-run completed. NetworkPolicy was not applied."
  else
    echo "--- RENDERED NETWORKPOLICY MANIFEST ---"
    render_policy
    echo "--- END MANIFEST ---"
    echo "Manifest-only dry run completed. Set KUBECTL_DRY_RUN=true to ask kubectl to validate it."
  fi
  exit 0
fi

probe_connection "BEFORE_APPLY"

render_policy | "${KUBECTL}" apply -f -

echo "[PASS] NetworkPolicy ${POLICY_NAME} applied."
probe_connection "AFTER_APPLY"

echo "--- EVIDENCE ---"
"${KUBECTL}" describe networkpolicy "${POLICY_NAME}" -n "${NAMESPACE}" || true

if [[ "${AUTO_CLEANUP}" != "true" ]]; then
  echo "Cleanup: kubectl delete networkpolicy ${POLICY_NAME} -n ${NAMESPACE} --ignore-not-found"
fi
