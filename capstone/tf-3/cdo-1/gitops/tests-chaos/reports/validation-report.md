# Chaos & E2E Validation Report

## Scope

Validate the CDO self-heal flow through controlled chaos scenarios owned by Member 9.

Full E2E validation remains blocked until Member 7/8 finalize GitOps, Kyverno/Prometheus rules, Alertmanager routing, and Firehose audit delivery.

## Test Matrix

| Test case | Trigger | Expected alert | Expected action | Result | Recovery time | Evidence |
|---|---|---|---|---|---|---|
| Pod OOM | stress-ng memory pressure | PodOOMKilled / OOMKilled | PATCH_MEMORY_LIMIT | READY_FOR_CLUSTER_RUN | TBD | `simulate_oom.sh` syntax PASS |
| DB Network Block | deny egress to DB | DBConnectionFailed / ServiceUnavailable | Escalate / recover | READY_FOR_DRY_RUN | TBD | `simulate_db_network_block.sh` syntax PASS; `DRY_RUN=true` supported |
| E2E Flow | full alert-to-audit path | matched alert | remediation + verify + audit | BLOCKED | TBD | Waiting for Member 7/8 components |

## Current Validation Status

| Check | Status | Evidence |
|---|---|---|
| OOM script syntax | PASS | `bash -n capstone/tf-3/cdo-1/gitops/tests-chaos/scripts/simulate_oom.sh` |
| DB network block script syntax | PASS | `bash -n capstone/tf-3/cdo-1/gitops/tests-chaos/scripts/simulate_db_network_block.sh` |
| Partial E2E checker syntax | PASS | `bash -n capstone/tf-3/cdo-1/gitops/tests-chaos/scripts/validate_e2e_flow.sh` |
| Mirror script syntax | PASS | `bash -n capstone/tf-3/cdo-1/gitops/mirror-images.sh` |
| Mirror list shape | PASS | `awk 'NF && $1 !~ /^#/ {print "source="$1, "dest="$2}' capstone/tf-3/cdo-1/gitops/mirror-list.txt` |
| Full E2E SLO | BLOCKED | Requires finalized GitOps, monitoring routes, and Firehose evidence |

## Blockers

| Owner | Blocker | Required before full PASS |
|---|---|---|
| Member 7 | Final tenant namespace, labels, Kyverno/GitOps resources | Confirm namespace/label contract and remediation resources |
| Member 8 | PrometheusRule, Alertmanager route, Firehose stream/config | Provide firing alert, route, and audit delivery evidence |
| Member 9 | Cluster execution evidence | Run OOM, DB network block, and partial E2E checker on target cluster |

## Evidence Checklist

- kubectl get pods -A
- kubectl describe pod
- kubectl get events -A --sort-by=.lastTimestamp
- kubectl logs -n self-heal-system -l app=webhook-receiver
- kubectl logs -n self-heal-system -l app=sqs-worker
- Prometheus firing alert screenshot/log
- Alertmanager route evidence
- Firehose/S3 audit evidence

## Latest Local Validation Output

```text
bash -n capstone/tf-3/cdo-1/gitops/tests-chaos/scripts/*.sh
bash -n capstone/tf-3/cdo-1/gitops/mirror-images.sh
```

Both commands completed with exit code 0 during local validation.
