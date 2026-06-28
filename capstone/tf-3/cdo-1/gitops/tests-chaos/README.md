# Chaos Testing & E2E Validation (Member 9)

This folder contains the Member 9 validation assets for CDO-01:

- controlled chaos scripts for OOM and DB egress failure scenarios
- partial E2E readiness checks for the self-heal flow
- validation evidence and blocker tracking

Member 9 owns the validation evidence. GitOps, Kyverno, Prometheus, Alertmanager, and Firehose implementation remain owned by Member 7/8.

## Prerequisites

- `kubectl` points to the target cluster.
- The target namespaces and labels are confirmed with Member 7/8.
- On NAT-less EKS, chaos/debug images must already be mirrored to private ECR.
- Default private registry:

```bash
544011261607.dkr.ecr.us-east-1.amazonaws.com
```

## Syntax Validation

Run this before opening or updating the PR:

```bash
bash -n capstone/tf-3/cdo-1/gitops/tests-chaos/scripts/*.sh
bash -n capstone/tf-3/cdo-1/gitops/mirror-images.sh
```

Validate the mirror list shape:

```bash
awk 'NF && $1 !~ /^#/ {print "source="$1, "dest="$2}' capstone/tf-3/cdo-1/gitops/mirror-list.txt
```

## Mirror Images

`../mirror-images.sh` mirrors the images listed in `../mirror-list.txt` to ECR private registry.

Important variables:

| Variable | Default | Purpose |
|---|---|---|
| `AWS_REGION` | `us-east-1` | ECR region |
| `AWS_ACCOUNT` | `544011261607` | ECR account used by the chaos image defaults |

Run:

```bash
AWS_REGION=us-east-1 bash capstone/tf-3/cdo-1/gitops/mirror-images.sh
```

## OOM Chaos

Simulates an OOMKilled pod with `stress-ng`.

```bash
NAMESPACE=tenant-payment \
APP_NAME=oom-chaos \
bash capstone/tf-3/cdo-1/gitops/tests-chaos/scripts/simulate_oom.sh
```

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `NAMESPACE` | `tenant-payment` | Namespace for the chaos pod |
| `APP_NAME` | `oom-chaos` | Pod name and app label |
| `ECR_REGISTRY` | `544011261607.dkr.ecr.us-east-1.amazonaws.com` | Private ECR registry |
| `IMAGE` | `$ECR_REGISTRY/alexeiled/stress-ng:latest` | Stress image |
| `MEM_LIMIT` | `64Mi` | Memory limit used to trigger OOM |

Cleanup:

```bash
kubectl delete pod oom-chaos -n tenant-payment --ignore-not-found
```

## DB Network Block

Applies a temporary `NetworkPolicy` that allows egress to everything except the provided DB CIDR.

Warning: Kubernetes NetworkPolicy is allow-list based. This test blocks DB traffic only if no other NetworkPolicy allows DB egress for the selected pods.

Dry run first:

```bash
DRY_RUN=true \
NAMESPACE=tenant-payment \
APP_LABEL=payment-api \
DB_CIDR=10.42.12.34/32 \
bash capstone/tf-3/cdo-1/gitops/tests-chaos/scripts/simulate_db_network_block.sh
```

Apply:

```bash
NAMESPACE=tenant-payment \
APP_LABEL=payment-api \
DB_CIDR=10.42.12.34/32 \
bash capstone/tf-3/cdo-1/gitops/tests-chaos/scripts/simulate_db_network_block.sh
```

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `NAMESPACE` | `tenant-payment` | Target app namespace |
| `APP_LABEL` | `payment-api` | App label matched as `app=$APP_LABEL` |
| `DB_CIDR` | required | DB CIDR to exclude from egress |
| `POLICY_NAME` | `chaos-deny-db-egress` | NetworkPolicy name |
| `DRY_RUN` | `false` | Use `kubectl apply --dry-run=client` |
| `AUTO_CLEANUP` | `false` | Delete policy on script exit |

Cleanup:

```bash
kubectl delete networkpolicy chaos-deny-db-egress -n tenant-payment --ignore-not-found
```

## Partial E2E Validation

Runs checks that can pass independently while Member 7/8 finish the platform components.

```bash
bash capstone/tf-3/cdo-1/gitops/tests-chaos/scripts/validate_e2e_flow.sh
```

Output uses:

- `[PASS]` for detected resources
- `[SKIP]` for components not installed or not ready yet
- `[FAIL]` for required namespaces missing when a cluster is reachable

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `TENANT_NAMESPACE` | `tenant-payment` | Tenant app namespace |
| `SELF_HEAL_NAMESPACE` | `self-heal-system` | Self-heal components namespace |
| `OBSERVABILITY_NAMESPACE` | `observability` | Prometheus/Alertmanager namespace |
| `WEBHOOK_LABEL` | `app=webhook-receiver` | Webhook pod selector |
| `SQS_WORKER_LABEL` | `app=sqs-worker` | Worker pod selector |
| `STRICT` | `false` | Exit non-zero when failures are found |

## Evidence

Record command output and screenshots in `reports/validation-report.md`. Do not mark full E2E as PASS until GitOps, monitoring routes, and Firehose audit evidence are available.
