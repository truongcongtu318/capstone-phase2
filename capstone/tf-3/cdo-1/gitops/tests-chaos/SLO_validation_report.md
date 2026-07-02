# SLO Validation & Chaos Testing Report

## Scope

Member 9 validates the CDO-01 self-heal evidence pack:

- security gate manifests from Member 7
- RBAC and Kyverno behavior for tenant-only remediation
- NetworkPolicy isolation for webhook receiver and AI engine
- monitoring contracts from Member 8
- OOM, DB network block, and queue backlog chaos triggers

This report does not claim full E2E success until alert delivery, remediation execution, and audit log delivery are observed on the target cluster.

## ST2 Handoff Status (received Sprint 2 → Sprint 3)

| Item | Status | Detail |
|---|---|---|
| App image spec (ECR registry, repo names, ports) | `RECEIVED_FROM_ST2` | Registry: 474013238625.dkr.ecr.us-east-1.amazonaws.com |
| Webhook image repo | `PENDING_SHA_TAG` | Repo: tf-3-webhook-receiver — SHA tag pending ST2 CI build |
| Worker image repo | `PENDING_SHA_TAG` | Repo: tf-3-self-heal-worker — SHA tag pending ST2 CI build |
| AI demo image repo | `PENDING_SHA_TAG` | Repo: tf-3-ai-engine-demo — SHA tag pending ST2 CI build |
| ServiceAccount/IRSA roles | `RECEIVED_FROM_ST2` | webhook-receiver, self-heal-executor IRSA ARNs confirmed |
| Metrics spec (Webhook + Worker) | `RECEIVED_FROM_ST2` | Metric names confirmed, analysis-template.yaml updated |
| Runtime E2E on EKS | `PENDING_EKS_DEPLOY` | Waiting: SHA tags + kubeconfig access |
| ARGOCD_AUTH_TOKEN secret | `PENDING_CREATION` | Pending ST2: manual token or ESO path |
| CodeCommit repo URL | `PENDING_ST2` | CODECOMMIT_REPO_URL placeholder in sqs-worker deployment |
| GitOps values.yaml path | `PRESENT_IN_GITHUB` | Created at gitops/tenant-payment/order-service/values.yaml |
| ArgoCD tenant-payment-app | `CREATED` | argo-apps/tenant-payment-app.yaml |
| ArgoCD tenant-checkout-app | `CREATED` | argo-apps/tenant-checkout-app.yaml |
| OOM alert fixture | `CREATED` | `tests-chaos/fixtures/oom-alert-payload.json` |

## E2E Test Checklist (theo ST2 Handoff)

```
[ ] 1. Verify image exists in ECR
        aws ecr describe-images --registry-id 474013238625 \
          --repository-name tf-3-webhook-receiver
        aws ecr describe-images --registry-id 474013238625 \
          --repository-name tf-3-self-heal-worker
        aws ecr describe-images --registry-id 474013238625 \
          --repository-name tf-3-ai-engine-demo

[ ] 2. Update SHA tags in overlay kustomization.yaml
        # Sửa newTag trong:
        # overlays/sandbox/webhook-receiver/kustomization.yaml
        # overlays/sandbox/sqs-worker/kustomization.yaml
        # overlays/sandbox/ai-engine/kustomization.yaml

[ ] 3. ArgoCD sync 3 apps
        argocd app sync webhook-receiver
        argocd app sync sqs-worker
        argocd app sync ai-engine

[ ] 4. Check pods healthy
        kubectl get pods -n self-heal-system
        kubectl get pods -n tenant-payment

[ ] 5. Send OOMKilled alert to /alerts endpoint
        curl -X POST https://<ALB-DNS>/alerts \
          -H "Content-Type: application/json" \
          -d @tests-chaos/fixtures/oom-alert-payload.json

[ ] 6. Check worker processes and patches deployment
        kubectl logs -n self-heal-system deployment/sqs-worker --tail=50
        kubectl get deployment order-service -n tenant-payment \
          -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
        # Expected: 512Mi after patch

[ ] 7. Check worker metrics
        kubectl port-forward -n self-heal-system svc/sqs-worker 9090:9090
        curl localhost:9090/metrics | grep worker_

[ ] 8. Verify Firehose/S3 audit log
        aws firehose describe-delivery-stream \
          --delivery-stream-name tf3-cdo1-sandbox-audit-stream
        # Check S3 bucket for audit records
```

## Runtime Environment Note

Latest local validation after pulling `origin/main` to `1a8d164` was run on 2026-07-02. `kubectl` was installed temporarily with `nix-shell -p kubectl` and the validator was re-run.

Runtime check result:

```text
Local manifest checks: PASS
kubectl kustomize security-policies: PASS
Cluster checks: SKIP
```

Cluster checks are still skipped because no usable cluster context is available in this workspace. The current kubeconfig attempts to reach EKS, but AWS SSO credentials are expired, so `kubectl` discovery/API calls cannot prove runtime behavior. Therefore, static manifest checks, shell syntax checks, manifest-only dry-runs, and queue dry-run paths are PR-ready, while full E2E runtime validation remains pending EKS access.

## Infra-Derived Runtime Inputs

| Input | Status | Repo evidence |
|---|---|---|
| AWS region | KNOWN | `.github/workflows/terraform-pipeline.yml` sets `AWS_REGION=us-east-1` |
| CI plan/apply roles | KNOWN | `arn:aws:iam::474013238625:role/tf3-cdo1-sandbox-github-ci-plan/apply` |
| ECR registry (ST2 confirmed) | KNOWN | `474013238625.dkr.ecr.us-east-1.amazonaws.com` |
| VPC CIDR | KNOWN | `10.42.0.0/16` |
| Private subnet CIDRs | KNOWN | `10.42.0.0/20`, `10.42.16.0/20` |
| SQS queue URL | KNOWN | `https://sqs.us-east-1.amazonaws.com/474013238625/tf3-cdo1-sandbox-self-heal-queue` |
| DynamoDB idempotency lock table | KNOWN | `tf-3-aiops-app-idempotency-lock` |
| DynamoDB state table | KNOWN | `tf-3-aiops-app-state` |
| Firehose stream | KNOWN | `tf3-cdo1-sandbox-audit-stream` |
| SNS topic ARN | KNOWN | `arn:aws:sns:us-east-1:474013238625:tf3-cdo1-sandbox-alerts-escalation` |
| IRSA webhook-receiver role | KNOWN | `arn:aws:iam::474013238625:role/tf3-cdo1-sandbox-irsa-webhook-receiver` |
| IRSA self-heal-executor role | KNOWN | `arn:aws:iam::474013238625:role/tf3-cdo1-sandbox-irsa-audit-writer` |
| IRSA ai-engine role | KNOWN_IN_MANIFEST | `arn:aws:iam::474013238625:role/tf3-cdo1-sandbox-irsa-ai-engine-bedrock` |
| AWS Secrets Manager Secret | MISSING (ST1) | `tf3-cdo1-sandbox/argocd-auth-token` |
| EKS cluster access | BLOCKED_BY_INFRA | kubeconfig/SSO access is not usable for runtime evidence |
| ACM Certificate ARN | MISSING | needed for ALB Ingress HTTPS |
| CodeCommit repo URL | MISSING | CODECOMMIT_REPO_URL in sqs-worker env pending |
| ARGOCD_AUTH_TOKEN | MISSING | pending ST2 creation (manual or ESO) |

Note: Account ID `474013238625` is the ST2 confirmed account. Member 9 scripts and docs now default to this account. Legacy `544011261607` references that remain outside `tests-chaos` should be handled by the owning GitOps/monitoring workstream before final EKS deploy.

## Open Questions for ST2/ST1

### Cần hỏi ST2
1. **Image SHA tags**: SHA thật của 3 images (tf-3-webhook-receiver, tf-3-self-heal-worker, tf-3-ai-engine-demo)?
2. **ARGOCD_AUTH_TOKEN**: tạo bằng `argocd account generate-token` manual hay qua ESO Secret Manager? Secret Manager key path?
3. **CodeCommit repo URL**: URL HTTPS clone cuối cùng là gì?
4. **DRY_RUN khi demo**: để `false` (chạy thật) hay `true` (giả lập)?

### Cần hỏi ST1
1. **EKS cluster name + kubeconfig/SSO**: `aws eks update-kubeconfig --name <cluster-name> --region us-east-1` + working AWS SSO/profile
2. **ACM Certificate ARN**: cho ALB Ingress HTTPS (ingress.yaml hiện để trống)
3. **S3 audit bucket path**: bucket name và prefix để verify audit records

## Validation Summary

| Area | Status | Evidence |
|---|---|---|
| Static shell syntax | PASS | `bash -n tests-chaos/*.sh`, `bash -n tests-chaos/scripts/*.sh` |
| Mirror script syntax | PASS | `bash -n gitops/mirror-images.sh` |
| Mirror list shape | PASS | `awk 'NF && $1 !~ /^#/ {print "source="$1, "dest="$2}' gitops/mirror-list.txt` |
| Local manifest checks | PASS | `validate-e2e-flow.sh` local checks completed with `0 failure(s)` |
| kubectl client kustomize | PASS | Installed via `nix-shell -p kubectl`; `kubectl kustomize security-policies` passed |
| Core self-heal placeholder cleanup | PASS | webhook-receiver, sqs-worker, and ai-engine base/overlay manifests use ECR images, service ports, and IRSA annotations |
| OOM Alertmanager fixture | PASS | `tests-chaos/fixtures/oom-alert-payload.json` exists and is valid JSON |
| Chaos manifest-only dry-runs | PASS | OOM pod, DB blockade NetworkPolicy, and SQS backlog dry-run commands completed locally |
| IRSA annotations | PASS | webhook-receiver, self-heal-executor, ai-engine all have IRSA annotations |
| Env vars complete | PASS | All ST2 env vars injected in base manifests |
| Prometheus scrape annotations | PASS | webhook (8443/metrics), worker (9090/metrics) annotated |
| Alertmanager tenant scoping | PASS | `tenant_id` query params declared for tenant-payment and tenant-checkout routes |
| Cluster context | BLOCKED_BY_INFRA | Current kubeconfig/SSO cannot reach the cluster for runtime checks |
| Cluster kustomize / server dry-run | BLOCKED_BY_INFRA | Requires reachable cluster context |
| RBAC behavior | BLOCKED_BY_INFRA | Requires `kubectl auth can-i` on target cluster |
| Namespace wave -4 manifests | PASS | `security-policies/namespaces.yaml` declares `self-heal-system`, `observability`, `tenant-payment`, `tenant-checkout` |
| Kyverno policy manifest | PASS | `security-policies/restrict-mutations.yaml` declares `ClusterPolicy/restrict-mutations` |
| RBAC self-heal executor manifests | PASS | `security-policies/rbac.yaml` declares `self-heal-executor-role` and tenant RoleBindings |
| NetworkPolicy manifests | PASS | `webhook-netpolicy` and `ai-engine-netpolicy` declared |
| Prometheus alerts | PASS | `PodOOMKilled`, `PodCrashLooping`, and `SQSQueueBacklog` declared |
| Alertmanager route | PASS | `cdo1-self-heal-routing` routes to `webhook-receiver.self-heal-system.svc.cluster.local:8443/alerts?tenant_id=...` |
| ArgoCD tenant-payment-app | PASS | argo-apps/tenant-payment-app.yaml created |
| ArgoCD tenant-checkout-app | PASS | argo-apps/tenant-checkout-app.yaml created |
| GitOps values.yaml path | PASS | gitops/tenant-payment/order-service/values.yaml created |
| OOM trigger | READY_FOR_CLUSTER_RUN | `DRY_RUN=true` renders the manifest locally; cluster run still needs EKS access |
| DB network block | READY_FOR_DRY_RUN | `DRY_RUN=true` renders the NetworkPolicy; real run needs DB CIDR/endpoint and EKS access |
| Queue backlog | READY_FOR_DRY_RUN | `DRY_RUN=true` prints the first synthetic SQS message with the confirmed queue URL |
| Prometheus alert fired | PENDING | Requires target cluster monitoring evidence |
| Webhook received alert | PENDING | Requires app and Alertmanager route evidence |
| Worker remediation action | PENDING | Requires sqs-worker runtime evidence |
| Audit log written | PENDING | Waiting for EKS deploy + Firehose stream active |

## Monitoring Metrics (ST2 Handoff — theo dõi bắt buộc)

### Webhook Receiver Metrics (port 8443/metrics)
| Metric | Ý nghĩa |
|---|---|
| `http_request_duration_seconds{handler="/alerts"}` | Latency endpoint nhận alert |
| `webhook_alerts_queued_total{tenant_id}` | Số alert đã queue thành công theo tenant |
| `webhook_security_violations_total` | Số vi phạm security (auth fail, HMAC bad...) |
| `webhook_duplicate_alerts_total{tenant_id}` | Số alert trùng lặp đã filter (idempotency) |

### SQS Worker Metrics (port 9090/metrics)
| Metric | Ý nghĩa |
|---|---|
| `worker_messages_processed_total{status}` | Số message xử lý (success/failed) |
| `worker_ai_call_duration_seconds{endpoint}` | Latency gọi AI Engine |
| `worker_ai_errors_total{endpoint,status_code}` | Số lỗi gọi AI Engine |
| `worker_executions_total{action,lane,status}` | Số lần thực thi remediation |
| `worker_circuit_breaker_open_total{tenant_id}` | Số lần circuit breaker mở |
| `worker_circuit_breaker_skips_total{tenant_id}` | Số lần skip do circuit breaker |
| `worker_escalations_total{reason}` | Số lần escalate lên SNS |
| `worker_rollbacks_total{status}` | Số lần rollback (success/failed) |

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
| Pod OOM | `oom-simulator.sh` creates stress-ng pod | `PodOOMKilled` | PATCH_MEMORY_LIMIT or escalation | READY_FOR_CLUSTER_RUN | TBD | syntax PASS; manifest-only dry-run PASS; fixture created |
| DB Network Block | `network-blockade.sh` denies DB CIDR egress | DB connection failure | Escalate or recover | READY_FOR_DRY_RUN | TBD | syntax PASS; manifest-only dry-run PASS |
| Queue Backlog | `queue-backlog-stress.sh` sends SQS messages | `SQSQueueBacklog` | Scale worker or escalate | READY_FOR_DRY_RUN | TBD | syntax PASS; dry-run message PASS |
| Full E2E | Alertmanager → webhook → worker → audit | matched alert | remediation + verify + audit | PENDING_EKS_DEPLOY | TBD | waiting for SHA tags + cluster access |

## Evidence Commands

```bash
./capstone/tf-3/cdo-1/gitops/tests-chaos/validate-e2e-flow.sh

# Validate fixture JSON
python -m json.tool \
  capstone/tf-3/cdo-1/gitops/tests-chaos/fixtures/oom-alert-payload.json >/dev/null

# Manifest-only dry-runs, no cluster contact
DRY_RUN=true NAMESPACE=tenant-payment APP_NAME=oom-chaos \
  ./capstone/tf-3/cdo-1/gitops/tests-chaos/oom-simulator.sh

DRY_RUN=true NAMESPACE=tenant-payment APP_LABEL=payment-api DB_CIDR=10.42.12.34/32 \
  ./capstone/tf-3/cdo-1/gitops/tests-chaos/network-blockade.sh

QUEUE_URL=https://sqs.us-east-1.amazonaws.com/474013238625/tf3-cdo1-sandbox-self-heal-queue \
  DRY_RUN=true ./capstone/tf-3/cdo-1/gitops/tests-chaos/queue-backlog-stress.sh

# Optional once kubeconfig/SSO works
KUBECTL_DRY_RUN=true DRY_RUN=true NAMESPACE=tenant-payment APP_NAME=oom-chaos \
  ./capstone/tf-3/cdo-1/gitops/tests-chaos/oom-simulator.sh

# Kustomize build check
kubectl kustomize capstone/tf-3/cdo-1/gitops/manifests/overlays/sandbox/webhook-receiver
kubectl kustomize capstone/tf-3/cdo-1/gitops/manifests/overlays/sandbox/sqs-worker
kubectl kustomize capstone/tf-3/cdo-1/gitops/manifests/overlays/sandbox/ai-engine
kubectl kustomize capstone/tf-3/cdo-1/gitops/security-policies
kubectl kustomize capstone/tf-3/cdo-1/gitops/monitoring

kubectl get ns self-heal-system observability tenant-payment tenant-checkout
kubectl get clusterpolicy restrict-mutations
kubectl get networkpolicy -n self-heal-system
kubectl get prometheusrule -n observability cdo1-self-heal-alerts
kubectl get alertmanagerconfig -n observability cdo1-self-heal-routing
```

## Blockers Before Full PASS

| Owner | Blocker | Required evidence |
|---|---|---|
| ST2 | Image SHA tags (3 images) | ECR image tags to update overlay kustomization.yaml |
| ST2 | ARGOCD_AUTH_TOKEN | Token value or ESO secret path |
| ST2 | CodeCommit repo URL | CODECOMMIT_REPO_URL env var in sqs-worker |
| ST1 | EKS cluster access | cluster name, kubeconfig command, working AWS SSO/profile |
| ST1 | ACM Certificate ARN | For ALB Ingress HTTPS (ingress.yaml line 32) |
| Member 7 | Cluster-applied security gate | `kubectl kustomize`, server dry-run, RBAC/Kyverno behavior |
| Member 8 | Monitoring runtime | firing Prometheus alert and Alertmanager delivery |
| App team | Self-heal runtime | webhook log, sqs-worker log, remediation action |
| Audit owner | Firehose/S3 delivery | audit object/log for incident lifecycle |
