#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=${NAMESPACE:-tenant-payment}
APP_LABEL=${APP_LABEL:-payment-api}
DB_CIDR=${DB_CIDR:?DB_CIDR is required, example: 10.42.12.34/32}
POLICY_NAME=${POLICY_NAME:-chaos-deny-db-egress}
DRY_RUN=${DRY_RUN:-false}

cleanup() {
  if [[ "${AUTO_CLEANUP:-false}" == "true" ]]; then
    echo "Cleaning up NetworkPolicy..."
    kubectl delete networkpolicy "$POLICY_NAME" -n "$NAMESPACE" --ignore-not-found
  fi
}
trap cleanup EXIT

echo "Applying NetworkPolicy to block DB traffic..."
echo "Namespace: $NAMESPACE"
echo "App Label: $APP_LABEL"
echo "DB CIDR: $DB_CIDR"
echo "Dry Run: $DRY_RUN"
echo "WARNING: Kubernetes NetworkPolicy is allow-list based. This test blocks DB only if no other NetworkPolicy allows DB egress for selected pods."

render_policy() {
  cat <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: $POLICY_NAME
  namespace: $NAMESPACE
spec:
  podSelector:
    matchLabels:
      app: $APP_LABEL
  policyTypes:
  - Egress
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - $DB_CIDR
EOF
}

if [[ "$DRY_RUN" == "true" ]]; then
  render_policy | kubectl apply --dry-run=client -f -
  echo "Dry run completed. NetworkPolicy was not applied."
  exit 0
fi

render_policy | kubectl apply -f -

echo "NetworkPolicy $POLICY_NAME applied."
echo "Waiting for app to report DB connection failure..."

echo "--- EVIDENCE ---"
echo "1. NetworkPolicy Status:"
kubectl describe networkpolicy "$POLICY_NAME" -n "$NAMESPACE" || true

echo "To cleanup manually run (or set AUTO_CLEANUP=true): kubectl delete networkpolicy $POLICY_NAME -n $NAMESPACE"
