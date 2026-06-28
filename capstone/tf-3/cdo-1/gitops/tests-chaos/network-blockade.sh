#!/usr/bin/env bash
set -euo pipefail

# Apply a temporary NetworkPolicy that denies egress to a target DB CIDR.

NAMESPACE=${NAMESPACE:-tenant-payment}
APP_LABEL=${APP_LABEL:-payment-api}
DB_CIDR=${DB_CIDR:?DB_CIDR is required, example: 10.42.12.34/32}
POLICY_NAME=${POLICY_NAME:-chaos-deny-db-egress}
DRY_RUN=${DRY_RUN:-false}
AUTO_CLEANUP=${AUTO_CLEANUP:-false}

cleanup() {
  if [[ "${AUTO_CLEANUP}" == "true" && "${DRY_RUN}" != "true" ]]; then
    echo "Cleaning up NetworkPolicy..."
    kubectl delete networkpolicy "${POLICY_NAME}" -n "${NAMESPACE}" --ignore-not-found
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

echo "Applying DB network blockade..."
echo "Namespace: ${NAMESPACE}"
echo "App label: app=${APP_LABEL}"
echo "DB CIDR: ${DB_CIDR}"
echo "Policy: ${POLICY_NAME}"
echo "Dry run: ${DRY_RUN}"
echo "WARNING: Kubernetes NetworkPolicy is allow-list based. This blocks DB only if no other NetworkPolicy allows DB egress for the selected pods."

if [[ "${DRY_RUN}" == "true" ]]; then
  render_policy | kubectl apply --dry-run=client -f -
  echo "Dry run completed. NetworkPolicy was not applied."
  exit 0
fi

render_policy | kubectl apply -f -

echo "[PASS] NetworkPolicy ${POLICY_NAME} applied."
echo "--- EVIDENCE ---"
kubectl describe networkpolicy "${POLICY_NAME}" -n "${NAMESPACE}" || true

echo "Cleanup: kubectl delete networkpolicy ${POLICY_NAME} -n ${NAMESPACE} --ignore-not-found"
