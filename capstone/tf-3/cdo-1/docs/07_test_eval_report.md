# Test & Eval Report - Task force 3 · CDO 1

Tài liệu này ghi nhận kết quả kiểm thử thực tế đã chạy cho hệ thống Self-Heal Platform của CDO-01. Phạm vi gồm application tests, local E2E dry-run, GitOps/IaC validation, chaos dry-run và security scan. Các hạng mục cần EKS runtime/ALB/SSO được đánh dấu rõ là `BLOCKED_BY_INFRA`, không suy diễn số liệu production.

**Evidence snapshot**

| Field | Value |
|---|---|
| Run date | 2026-07-02 |
| Workspace | `/home/nvtank/year3/intern/w11/capstone-phase2` |
| Commit SHA | `7c298471cabae68fe2b572faa76b4f6b12165225` |
| Python | `3.13.12` |
| Terraform | `1.14.0` |
| Docker daemon | `29.5.2` |
| EKS/cluster context | `BLOCKED_BY_INFRA` - no reachable cluster context in this workspace |

---

## 1. Test Coverage

Hệ thống được kiểm thử theo 5 lớp: unit, integration/local E2E, GitOps/IaC static validation, security scan và chaos dry-run.

| Test type | Command / Tool | Measured result | Status |
|---|---|---|---|
| Unit test + coverage | `python -m pytest tests -q --cov=webhook-receiver/src --cov=sqs-worker/src --cov-report=term-missing` | `29 passed`, `1 warning`, total coverage `66%` | `PASS` |
| Webhook API behavior | `pytest tests/test_webhook.py` via full suite | Valid alert `202`; duplicate alert `409`; cross-tenant header/query `403` | `PASS` |
| Worker / AI client behavior | `pytest tests/test_worker.py` via full suite | AI headers, retries, schema validation, circuit breaker, telemetry window, execute/verify path covered | `PASS` |
| Local E2E dry-run | Docker DynamoDB Local + LocalStack + AI demo + webhook + worker | Webhook returned `202`; SQS drained to `0`; worker metric `worker_messages_processed_total{status="DRY_RUN"} 1.0` | `PASS_LOCAL` |
| GitOps validator | `nix-shell -p kubectl --run './capstone/tf-3/cdo-1/gitops/tests-chaos/validate-e2e-flow.sh'` | Local manifest checks `PASS`; `kubectl kustomize security-policies` `PASS`; cluster checks skipped | `PASS_LOCAL / BLOCKED_BY_INFRA` |
| Kustomize render | `kubectl kustomize` and `kubectl kustomize --enable-helm` | Base/overlay/security/monitoring render `PASS`; tenant charts render with `--enable-helm` | `PASS` |
| Helm lint | `helm lint` on 6 tenant charts | `6 chart(s) linted, 0 chart(s) failed` | `PASS` |
| Terraform validate | Temp copy + `terraform init -backend=false` + `terraform validate` | `bootstrap`, `networking`, `compute`, `services` valid | `PASS` |
| Terraform fmt gate | `terraform fmt -check -diff -recursive capstone/tf-3/cdo-1/infra` | 2 files need formatting: `services/operators.tf`, `modules/observability/main.tf` | `FAIL_FORMATTING` |
| Trivy filesystem scan | `trivy fs --skip-dirs app/.venv --scanners vuln,misconfig,secret --severity CRITICAL,HIGH` | Package vulns `0`; secrets `0`; misconfig `2 CRITICAL`, `22 HIGH` | `FAIL_SECURITY_MISCONFIG` |
| Chaos dry-runs | `oom-simulator.sh`, `network-blockade.sh`, `queue-backlog-stress.sh` with `DRY_RUN=true` | Manifest/message render successful | `PASS_DRY_RUN` |

### 1.1 Coverage Details

| Area | Coverage evidence |
|---|---|
| Webhook Receiver | `main.py` 87%, `client_ddb.py` 100%, `config.py` 100%, `security.py` 61% |
| SQS Worker | `ai_client.py` 62%, `circuit_breaker.py` 82%, `main.py` 62%, `patch_executor.py` 60%, `prometheus_query_client.py` 100%, `config.py` 100%, `metrics.py` 91% |
| Gap | `sqs-worker/src/security.py` was reported as 0% because tests exercise scrub logic through the webhook security module path, not that duplicate worker-side file directly. |

---

## 2. SLO Evidence

Các số dưới đây là evidence local hoặc static. SLO production trên EKS vẫn cần chạy lại khi có kubeconfig/SSO, image SHA, ALB endpoint và monitoring runtime.

| SLO | Target | Measured | Window | Pass/Fail |
|---|---|---|---|---|
| API availability | >= 99.5% | Local smoke `3/3` endpoints healthy: AI `/health`, webhook `/health`, worker `/metrics` | Single local run | `PASS_LOCAL` |
| P99 Execution Latency - Direct Patch | < 15,000ms | Local dry-run single alert: worker receive at `23:29:41.493`, verify success at `23:29:42.028` -> about `535ms` | Single local dry-run | `PASS_LOCAL`, not production P99 |
| Error rate | < 0.5% | Unit tests `0/29` failed; local E2E `1/1` alert completed; queue visible/not-visible both `0` after processing | Local run | `PASS_LOCAL` |
| Tenant onboarding isolation | < 30 min | Cross-tenant API tests return `403`; namespace/RBAC manifests validated statically | Static + unit | `PARTIAL_PASS`; cluster RBAC still pending |

### 2.1 SLO Breach Analysis

No local SLO breach was observed in the unit/local E2E run. Runtime SLO breach analysis is still pending because the workspace cannot reach the target EKS cluster. The validator explicitly reported:

```text
[SKIP] BLOCKED_BY_INFRA: kubectl is installed but no reachable cluster context was found
```

---

## 3. Load Test Results

### 3.1 Test Setup

The planned load profile remains:

- Ramp from 0 to 100 RPS in 5 minutes.
- Sustain 100 RPS for 10 minutes.
- Simulate concurrent tenants against the ALB/Webhook Receiver entry layer.
- Collect p99 latency, error rate and autoscaling evidence from Prometheus/Karpenter.

### 3.2 Results

| Metric | Target | Achieved |
|---|---|---|
| RPS sustained | 100 | `BLOCKED_BY_INFRA` - no reachable ALB/EKS endpoint in workspace |
| P99 latency at peak | < 1500ms | `NOT_MEASURED` - no k6 run against deployed entry layer |
| Error rate at peak | < 1% | `NOT_MEASURED` - load test not executed |
| Auto-scale triggers | scale to >= 5 tasks / EC2 instances | `NOT_MEASURED` - Karpenter/runtime metrics require cluster |

### 3.3 Bottleneck Identified

No runtime bottleneck can be concluded from local dry-run. The local E2E only proves functional flow:

```text
Webhook /alerts -> 202
SQS ApproximateNumberOfMessages -> 0
worker_messages_processed_total{status="DRY_RUN"} -> 1.0
worker_executions_total{action="PATCH_MEMORY_LIMIT",lane="fast",status="DRY_RUN"} -> 1.0
```

The first real bottleneck investigation should target ALB/Webhook p99, SQS queue age/backlog, worker concurrency, DynamoDB conditional-write throttling and Karpenter node provisioning time.

---

## 4. Security Test

### 4.1 Penetration Touch Points

| Test | Evidence | Result |
|---|---|---|
| API auth / tenant bypass | `test_cross_tenant_returns_403` and `test_cross_tenant_query_param_returns_403` | `PASS` |
| Duplicate alert/idempotency bypass | `test_duplicate_alert_returns_409` | `PASS` |
| Alertmanager query-param tenant route | `test_valid_alert_with_tenant_id_query_param_returns_202` | `PASS` |
| Secret exposure via repo scan | Trivy secret scan excluding generated `.venv` | `PASS`: `secret_critical=0`, `secret_high=0` |
| IAM privilege escalation | Requires live EKS IRSA/RBAC checks | `BLOCKED_BY_INFRA` |
| Cross-tenant AWS/S3 prefix access | Requires live AWS tenant roles/policies | `BLOCKED_BY_INFRA` |
| NoSQL injection / parameter tampering | No dedicated negative payload test found in current suite | `TEST_GAP` |

### 4.2 Vulnerability Scan

Command:

```bash
nix-shell -p trivy --run \
  "trivy fs --skip-dirs capstone/tf-3/cdo-1/app/.venv \
   --scanners vuln,misconfig,secret \
   --severity CRITICAL,HIGH \
   --format json --output /tmp/trivy-cdo1.json \
   --exit-code 0 capstone/tf-3/cdo-1"
```

Measured summary:

| Category | CRITICAL | HIGH | Result |
|---|---:|---:|---|
| Package vulnerabilities | 0 | 0 | `PASS` |
| Secrets | 0 | 0 | `PASS` |
| Misconfigurations | 2 | 22 | `FAIL` |

Main findings:

| Severity | Finding | Location | Mitigation |
|---|---|---|---|
| CRITICAL | EKS public endpoint enabled | `infra/modules/eks/main.tf` | Restrict public CIDR or disable public endpoint after sandbox access path is finalized |
| CRITICAL | EKS public CIDR effectively open | `infra/modules/eks/main.tf` | Set `public_access_cidrs` to admin/VPN CIDRs only |
| HIGH | Public subnets map public IP on launch | `infra/modules/networking/main.tf` | Keep only ALB-facing public subnet use case documented, disable where not required |
| HIGH | Tenant Helm deployments use default security context / writable root FS | `gitops/tenant-*/*/templates/deployment.yaml` | Add pod/container `securityContext`, `runAsNonRoot`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true` where compatible |
| HIGH | `apt-get` without `--no-install-recommends` | `app/sqs-worker/Dockerfile` | Add `--no-install-recommends` and clean apt lists |

---

## 5. Multi-Tenant Isolation Test

| Test | Method | Result |
|---|---|---|
| Tenant A reads Tenant B data via API | Unit tests send tenant-checkout ID with tenant-payment payload via header and query param | `PASS`: API returns `403 SECURITY_VIOLATION` |
| Tenant A IAM role accesses Tenant B S3 prefix | Requires real tenant IAM roles and S3 bucket policy | `BLOCKED_BY_INFRA` |
| Cross-tenant queue contamination | Local E2E proved queue delivery/worker processing for valid tenant; no forged-tenant queue message test currently exists | `TEST_GAP` |
| DB row-level / DynamoDB partition isolation | Local DynamoDB lock table validates idempotency write/read path; no tenant bypass scan/query test exists | `TEST_GAP` |
| Namespace-level remediation boundary | `validate-e2e-flow.sh` validates RBAC manifests statically; cluster `kubectl auth can-i` skipped | `PASS_STATIC / BLOCKED_BY_INFRA` |

**Current conclusion:** API-level tenant isolation is covered and passing. AWS IAM/S3/DynamoDB runtime isolation still requires cluster/account access.

---

## 6. Failure Analysis

### 6.1 Failures Encountered During Validation

| # | Failure | Root cause | Fix / next action | Time to fix |
|---|---|---|---|---|
| 1 | Cluster checks skipped | No reachable EKS cluster context / AWS SSO in workspace | Provide working kubeconfig/profile, then run `validate-e2e-flow.sh` and RBAC `kubectl auth can-i` commands | TBD |
| 2 | Load test not executed | No deployed ALB/Webhook endpoint available | Deploy image SHA tags, sync ArgoCD apps, run k6 against ALB | TBD |
| 3 | Terraform format gate failed | 2 Terraform files need `terraform fmt` | Run `terraform fmt` on `infra/environments/sandbox/services/operators.tf` and `infra/modules/observability/main.tf` | < 0.5h |
| 4 | Trivy misconfiguration failures | EKS endpoint/public CIDR and default K8s security contexts | Add documented sandbox exception or harden manifests before final acceptance | 1-2h |
| 5 | Runtime Firehose/S3 audit not proven | Local E2E ran with `DRY_RUN=true`; Firehose skipped by design | Run E2E with `DRY_RUN=false` on deployed cluster and verify S3 audit object | TBD |

### 6.2 Test Gaps Acknowledged

- Full 100 RPS load test is pending deployed ALB/EKS access.
- Karpenter scale-out behavior is pending cluster metrics.
- Firehose/S3 immutable audit evidence is pending runtime `DRY_RUN=false`.
- IAM/S3 tenant boundary checks are pending real AWS tenant roles.
- Dedicated NoSQL injection / forged queue tenant tests are not yet present in the suite.
- Trivy currently fails misconfiguration policy and must be either fixed or explicitly risk-accepted for sandbox.

---

## 7. Evidence Commands

Commands run successfully unless marked otherwise:

```bash
# Unit tests and coverage
cd capstone/tf-3/cdo-1/app
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -U pip
python -m pip install -r webhook-receiver/requirements.txt -r sqs-worker/requirements.txt
python -m pytest tests -q --cov=webhook-receiver/src --cov=sqs-worker/src --cov-report=term-missing

# GitOps / chaos static checks
bash -n capstone/tf-3/cdo-1/gitops/tests-chaos/*.sh
bash -n capstone/tf-3/cdo-1/gitops/tests-chaos/scripts/*.sh
bash -n capstone/tf-3/cdo-1/gitops/mirror-images.sh
python3 -m json.tool capstone/tf-3/cdo-1/gitops/tests-chaos/fixtures/oom-alert-payload.json >/dev/null
nix-shell -p kubectl --run './capstone/tf-3/cdo-1/gitops/tests-chaos/validate-e2e-flow.sh'

# Chaos dry-runs
DRY_RUN=true NAMESPACE=tenant-payment APP_NAME=oom-chaos \
  ./capstone/tf-3/cdo-1/gitops/tests-chaos/oom-simulator.sh
DRY_RUN=true NAMESPACE=tenant-payment APP_LABEL=payment-api DB_CIDR=10.42.12.34/32 \
  ./capstone/tf-3/cdo-1/gitops/tests-chaos/network-blockade.sh
QUEUE_URL=https://sqs.us-east-1.amazonaws.com/474013238625/tf3-cdo1-sandbox-self-heal-queue \
  DRY_RUN=true ./capstone/tf-3/cdo-1/gitops/tests-chaos/queue-backlog-stress.sh

# Render/lint
nix-shell -p kubectl --run 'kubectl kustomize capstone/tf-3/cdo-1/gitops/security-policies >/dev/null'
nix-shell -p kubectl kubernetes-helm --run 'kubectl kustomize --enable-helm capstone/tf-3/cdo-1/gitops/tenant-payment >/dev/null'
nix-shell -p kubernetes-helm --run 'helm lint capstone/tf-3/cdo-1/gitops/tenant-payment/order-service'

# Terraform
terraform fmt -check -diff -recursive capstone/tf-3/cdo-1/infra   # FAIL_FORMATTING
terraform init -backend=false -input=false && terraform validate  # run in /tmp copy for root modules

# Security
nix-shell -p trivy --run 'trivy fs --skip-dirs capstone/tf-3/cdo-1/app/.venv --scanners vuln,misconfig,secret --severity CRITICAL,HIGH capstone/tf-3/cdo-1'
```

---

## Related Documents

- [`02_infra_design.md`](02_infra_design.md) - SLO targets and infrastructure design.
- [`03_security_design.md`](03_security_design.md) - Security design and risk registry.
- [`04_deployment_design.md`](04_deployment_design.md) - GitOps deployment flow.
- [`05_cost_analysis.md`](05_cost_analysis.md) - Sandbox cost assumptions.
- [`08_adrs.md`](08_adrs.md) - Architecture decision records.
- [`../../ai/docs/04_eval_report.md`](../../ai/docs/04_eval_report.md) - AI Engine evaluation report.
