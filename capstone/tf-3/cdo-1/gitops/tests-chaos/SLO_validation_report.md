# SLO Validation & Chaos Testing Report

## Scope

Member 9 validates the CDO-01 self-heal evidence pack:

- security gate manifests from Member 7
- RBAC and Kyverno behavior for tenant-only remediation
- NetworkPolicy isolation for webhook receiver and AI engine
- monitoring contracts from Member 8
- OOM, DB network block, and queue backlog chaos triggers

This report does not claim full E2E success until alert delivery, remediation execution, and audit log delivery are observed on the target cluster.

## Runtime Environment Note

`kubectl` was installed temporarily with `nix-shell -p kubectl` and the validator was re-run.

Runtime check result:

```text
Client Version: v1.34.3
Kustomize Version: v5.7.1
Local manifest checks: PASS
Cluster checks: SKIP
```

Cluster checks are still skipped because no reachable kubeconfig / cluster context is configured. Therefore, static manifest checks, shell syntax checks, and dry-run script paths are PR-ready, while full E2E runtime validation remains pending EKS cluster access.

## Validation Summary

| Area | Status | Evidence |
|---|---|---|
| Static shell syntax | PASS | `bash -n tests-chaos/*.sh`, `bash -n tests-chaos/scripts/*.sh` |
| Mirror script syntax | PASS | `bash -n gitops/mirror-images.sh` |
| Mirror list shape | PASS | `awk 'NF && $1 !~ /^#/ {print "source="$1, "dest="$2}' gitops/mirror-list.txt` |
| Local manifest checks | PASS | `validate-e2e-flow.sh` local checks completed with `0 failure(s)` |
| kubectl client | PASS | Installed via `nix-shell -p kubectl`; client `v1.34.3`, kustomize `v5.7.1` |
| Cluster context | BLOCKED_BY_INFRA | No reachable kubeconfig / cluster context |
| Cluster kustomize / server dry-run | BLOCKED_BY_INFRA | Requires reachable cluster context |
| Namespace wave -4 manifests | PASS | `security-policies/namespaces.yaml` declares `self-heal-system`, `observability`, `tenant-payment`, `tenant-checkout` |
| Kyverno policy manifest | PASS | `security-policies/restrict-mutations.yaml` declares `ClusterPolicy/restrict-mutations` |
| RBAC self-heal executor manifests | PASS | `security-policies/rbac.yaml` declares `self-heal-executor-role` and tenant RoleBindings |
| NetworkPolicy manifests | PASS | `webhook-netpolicy` and `ai-engine-netpolicy` declared |
| Prometheus alerts | PASS | `PodOOMKilled`, `PodCrashLooping`, and `QueueBacklog` declared |
| Alertmanager route | PASS | `cdo1-self-heal-routing` routes to `webhook-receiver.self-heal-system.svc.cluster.local:8443/alerts` |
| RBAC behavior | PENDING | Run `kubectl auth can-i` checks from `validate-e2e-flow.sh` |
| OOM trigger | READY | Run `oom-simulator.sh`; collect pod/events evidence |
| DB network block | READY_FOR_DRY_RUN | Run `network-blockade.sh` with `DRY_RUN=true`; actual run waits for real DB CIDR |
| Queue backlog | READY_FOR_DRY_RUN | Run `queue-backlog-stress.sh` with `DRY_RUN=true`; actual run waits for real queue URL |
| Prometheus alert fired | PENDING | Requires target cluster monitoring evidence |
| Webhook received alert | PENDING | Requires app and Alertmanager route evidence |
| Worker remediation action | PENDING | Requires sqs-worker runtime evidence |
| Audit log written | PENDING | Requires Firehose/S3 evidence |

## Expected RBAC Behavior

| Command | Expected |
|---|---|
| `self-heal-executor` patch deployment in `tenant-payment` | `yes` |
| `self-heal-executor` patch deployment in `tenant-checkout` | `yes` |
| `self-heal-executor` patch deployment in `argocd` | `no` |
| `self-heal-executor` patch deployment in `observability` | `no` |
| `argocd-application-controller` patch deployment in `tenant-payment` | `yes` |

## Chaos Test Matrix

| Test case | Trigger | Expected alert | Expected action | Current result | Recovery time | Evidence |
|---|---|---|---|---|---|---|
| Pod OOM | `oom-simulator.sh` creates stress-ng pod | `PodOOMKilled` | PATCH_MEMORY_LIMIT or escalation | READY_FOR_CLUSTER_RUN | TBD | syntax PASS; dry-run supported |
| DB Network Block | `network-blockade.sh` denies DB CIDR egress | DB connection failure / service unavailable | Escalate or recover | READY_FOR_DRY_RUN | TBD | syntax PASS; `DRY_RUN=true` supported |
| Queue Backlog | `queue-backlog-stress.sh` sends SQS messages | `QueueBacklog` | Scale worker or escalate | READY_FOR_DRY_RUN | TBD | syntax PASS; waits for queue URL |
| Full E2E | Alertmanager -> webhook -> worker -> audit | matched alert | remediation + verify + audit | PENDING | TBD | waiting for cluster runtime evidence |

## Evidence Commands

```bash
./capstone/tf-3/cdo-1/gitops/tests-chaos/validate-e2e-flow.sh

kubectl kustomize capstone/tf-3/cdo-1/gitops/security-policies
kubectl apply --dry-run=server -k capstone/tf-3/cdo-1/gitops/security-policies

kubectl get ns self-heal-system observability tenant-payment tenant-checkout
kubectl get clusterpolicy restrict-mutations
kubectl get networkpolicy -n self-heal-system
kubectl get prometheusrule -n observability cdo1-self-heal-alerts
kubectl get alertmanagerconfig -n observability cdo1-self-heal-routing
```

## Blockers Before Full PASS

| Owner | Blocker | Required evidence |
|---|---|---|
| Member 7 | Cluster-applied security gate | `kubectl kustomize`, server dry-run, RBAC/Kyverno behavior |
| Member 8 | Monitoring runtime | firing Prometheus alert and Alertmanager delivery |
| App team | Self-heal runtime | webhook log, sqs-worker log, remediation action |
| Audit owner | Firehose/S3 delivery | audit object/log for incident lifecycle |
