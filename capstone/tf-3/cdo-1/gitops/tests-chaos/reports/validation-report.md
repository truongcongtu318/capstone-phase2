# Chaos & E2E Validation Report

## Scope

Validate CDO self-heal flow through controlled chaos scenarios.

## Test Matrix

| Test case | Trigger | Expected alert | Expected action | Result | Recovery time | Evidence |
|---|---|---|---|---|---|---|
| Pod OOM | stress-ng memory pressure | PodOOMKilled / OOMKilled | PATCH_MEMORY_LIMIT | TBD | TBD | TBD |
| DB Network Block | deny egress to DB | DBConnectionFailed / ServiceUnavailable | Escalate / recover | TBD | TBD | TBD |
| E2E Flow | full alert-to-audit path | matched alert | remediation + verify + audit | TBD | TBD | TBD |

## Evidence Checklist

- kubectl get pods -A
- kubectl describe pod
- kubectl get events -A --sort-by=.lastTimestamp
- kubectl logs webhook-receiver
- kubectl logs sqs-worker
- Prometheus firing alert screenshot/log
- Alertmanager route evidence
- Firehose/S3 audit evidence
