# Chaos Testing & E2E Validation (Member 9)

This folder is the Member 9 evidence pack for CDO-01. It validates the GitOps, Kyverno, NetworkPolicy, monitoring, and chaos flow delivered by Member 7/8 without taking ownership of their manifests.

## Source Of Truth

Use the root-level scripts in this folder:

| Script | Purpose |
|---|---|
| `validate-e2e-flow.sh` | Partial real checker for security gate, RBAC, GitOps, monitoring, and app readiness |
| `oom-simulator.sh` | Trigger an OOMKilled pod in a tenant namespace |
| `network-blockade.sh` | Dry-run or apply a DB egress blockade NetworkPolicy |
| `queue-backlog-stress.sh` | Dry-run or send synthetic SQS backlog messages |

The `scripts/` folder only contains backward-compatible wrappers for older command names.

## Prerequisites

- `kubectl` points to the target cluster for cluster checks.
- `security-policies` from Member 7 are applied or available for dry-run.
- Monitoring CRDs from Member 8 are installed for PrometheusRule and AlertmanagerConfig checks.
- On NAT-less EKS, chaos/debug images must be mirrored to private ECR.
- Default private registry:

```bash
544011261607.dkr.ecr.us-east-1.amazonaws.com
```

If `kubectl` is not installed locally, use:

```bash
nix-shell -p kubectl
```

Current infra-derived values:

| Input | Value / Status |
|---|---|
| AWS region | `us-east-1` |
| VPC CIDR | `10.42.0.0/16` |
| Private subnet / endpoint CIDRs | `10.42.0.0/20`, `10.42.16.0/20` |
| SQS queue name | `tf3-cdo1-sandbox-alert-queue` |
| EKS cluster name | pending infra compute/EKS implementation |
| kubeconfig command | pending infra compute/EKS implementation |
| DB CIDR | pending DB endpoint/CIDR confirmation |
| SQS queue URL | pending queue URL/account confirmation |

## Static Validation

Run before opening or updating the PR:

```bash
bash -n capstone/tf-3/cdo-1/gitops/tests-chaos/*.sh
bash -n capstone/tf-3/cdo-1/gitops/tests-chaos/scripts/*.sh
bash -n capstone/tf-3/cdo-1/gitops/mirror-images.sh
```

Validate `mirror-list.txt` shape:

```bash
awk 'NF && $1 !~ /^#/ {print "source="$1, "dest="$2}' capstone/tf-3/cdo-1/gitops/mirror-list.txt
```

## Security Gate Validation

Run the partial checker:

```bash
./capstone/tf-3/cdo-1/gitops/tests-chaos/validate-e2e-flow.sh
```

It checks:

- namespace wave `-4`: `self-heal-system`, `observability`, `tenant-payment`, `tenant-checkout`
- Kyverno ClusterPolicy `restrict-mutations`
- RBAC `self-heal-executor-role` and tenant RoleBindings
- NetworkPolicies `webhook-netpolicy` and `ai-engine-netpolicy`
- webhook receiver, sqs-worker, and ai-engine manifests/resources
- PrometheusRule `cdo1-self-heal-alerts`
- AlertmanagerConfig `cdo1-self-heal-routing`
- Firehose audit config presence, reported as `SKIP` until ready

When a cluster is reachable, it also runs the expected RBAC checks:

```bash
kubectl auth can-i patch deployment -n tenant-payment \
  --as=system:serviceaccount:self-heal-system:self-heal-executor

kubectl auth can-i patch deployment -n tenant-checkout \
  --as=system:serviceaccount:self-heal-system:self-heal-executor

kubectl auth can-i patch deployment -n argocd \
  --as=system:serviceaccount:self-heal-system:self-heal-executor

kubectl auth can-i patch deployment -n observability \
  --as=system:serviceaccount:self-heal-system:self-heal-executor

kubectl auth can-i patch deployment -n tenant-payment \
  --as=system:serviceaccount:argocd:argocd-application-controller
```

Expected behavior:

| Check | Expected |
|---|---|
| self-heal-executor patch tenant-payment | `yes` |
| self-heal-executor patch tenant-checkout | `yes` |
| self-heal-executor patch argocd | `no` |
| self-heal-executor patch observability | `no` |
| argocd controller patch tenant-payment | `yes` |

## OOM Chaos

Dry-run first:

```bash
DRY_RUN=true \
NAMESPACE=tenant-payment \
APP_NAME=oom-chaos \
./capstone/tf-3/cdo-1/gitops/tests-chaos/oom-simulator.sh
```

Run on cluster:

```bash
NAMESPACE=tenant-payment \
APP_NAME=oom-chaos \
IMAGE=544011261607.dkr.ecr.us-east-1.amazonaws.com/alexeiled/stress-ng:latest \
MEM_LIMIT=64Mi \
./capstone/tf-3/cdo-1/gitops/tests-chaos/oom-simulator.sh
```

Evidence:

```bash
kubectl get pod -n tenant-payment oom-chaos -o wide
kubectl describe pod -n tenant-payment oom-chaos
kubectl get events -n tenant-payment --sort-by=.lastTimestamp | tail -30
```

Cleanup:

```bash
kubectl delete pod oom-chaos -n tenant-payment --ignore-not-found
```

## DB Network Block

Dry-run first:

```bash
DRY_RUN=true \
NAMESPACE=tenant-payment \
APP_LABEL=payment-api \
DB_CIDR=10.42.12.34/32 \
./capstone/tf-3/cdo-1/gitops/tests-chaos/network-blockade.sh
```

Apply only after Sub-team 1 confirms the real DB CIDR:

```bash
AUTO_CLEANUP=true \
NAMESPACE=tenant-payment \
APP_LABEL=payment-api \
DB_CIDR=<REAL_DB_CIDR>/32 \
./capstone/tf-3/cdo-1/gitops/tests-chaos/network-blockade.sh
```

Warning: Kubernetes NetworkPolicy is allow-list based. This blocks DB only if no other NetworkPolicy allows DB egress for the selected pods.

## Queue Backlog

Dry-run:

```bash
QUEUE_URL=https://sqs.us-east-1.amazonaws.com/544011261607/tf3-cdo1-sandbox-alert-queue \
DRY_RUN=true \
./capstone/tf-3/cdo-1/gitops/tests-chaos/queue-backlog-stress.sh
```

Send synthetic messages:

```bash
QUEUE_URL=<REAL_QUEUE_URL> \
MESSAGE_COUNT=150 \
DRY_RUN=false \
./capstone/tf-3/cdo-1/gitops/tests-chaos/queue-backlog-stress.sh
```

## Report

Use `SLO_validation_report.md` as the main report. Mark full alert, remediation, and audit as `PENDING` or `BLOCKED` until monitoring routes, app handlers, and Firehose evidence are available.
