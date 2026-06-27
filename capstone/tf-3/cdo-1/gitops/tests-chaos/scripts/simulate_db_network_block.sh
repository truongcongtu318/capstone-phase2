#!/usr/bin/env bash
set -e

NAMESPACE=${NAMESPACE:-tenant-payment}
APP_LABEL=${APP_LABEL:-payment-api}
DB_CIDR=${DB_CIDR:-10.42.0.0/16}
POLICY_NAME=${POLICY_NAME:-chaos-deny-db-egress}

echo "Applying NetworkPolicy to block DB traffic..."
echo "Namespace: $NAMESPACE"
echo "App Label: $APP_LABEL"
echo "DB CIDR: $DB_CIDR"

cat <<EOF | kubectl apply -f -
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

echo "NetworkPolicy $POLICY_NAME applied."
echo "Waiting for app to report DB connection failure..."

echo "--- EVIDENCE ---"
echo "1. NetworkPolicy Status:"
kubectl describe networkpolicy $POLICY_NAME -n $NAMESPACE || true

echo "To cleanup run: kubectl delete networkpolicy $POLICY_NAME -n $NAMESPACE"
