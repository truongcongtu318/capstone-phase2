# Deployment & CI/CD Design - Task force 3 · CDO 1
<!-- Doc owner: CDO-1
     Status: Draft (W11 T4) → Final (W11 T6 Pack #1) → Working (W12 T4 Pack #2)
     Word target: 1200-2000 từ
     Tier: Medium -->
Tài liệu mô tả cách triển khai **Self-Heal Engine** theo kiến trúc
**GitOps Hybrid AWS & K8s Stack** trên Amazon EKS.
Hai đường thực thi:
- **Urgent:** Worker gọi Direct Patch Engine.
- **Deferred:** Worker tạo Argo Workflow, cập nhật Git và chờ ArgoCD sync.

## 1. IaC strategy
### 1.1 Tool choice
- **IaC:** Terraform.
- **State backend:** S3 + Versioning + SSE-KMS + S3 lockfile.
- **CI authentication:** GitHub Actions OIDC.
- **Kubernetes bootstrap:** Terraform + Helm.
- **Application deployment:** Git + ArgoCD.
Terraform quản lý:
- VPC, subnet, route và VPC Endpoints;
- EKS, Managed Node Group và Karpenter permissions;
- ALB, ECR, RDS, DynamoDB, SQS và DLQ;
- Data Firehose, S3 Object Lock, KMS và Secrets Manager;
- CloudWatch resources;
- bootstrap ArgoCD, Argo Workflows, Argo Rollouts và ESO.

| Resource group | Owner |
|---|---|
| AWS infrastructure | Terraform |
| EKS, IAM, baseline nodes | Terraform |
| Platform bootstrap | Terraform + Helm |
| Self-Heal manifests | Git + ArgoCD |
| WorkflowTemplate | Git + ArgoCD |
| Tenant workloads | Git + ArgoCD |
Terraform và ArgoCD không cùng quản lý một Kubernetes resource.
### 1.2 Module structure

```text
infra/
├── bootstrap/
├── modules/
│   ├── networking/
│   ├── eks/
│   ├── karpenter/
│   ├── ingress/
│   ├── data/
│   ├── messaging/
│   ├── audit/
│   ├── security/
│   ├── observability/
│   └── tenant-bootstrap/
├── environments/
│   └── sandbox/
│       ├── foundation/
│       ├── platform/
│       └── tenants/
└── README.md
gitops/
├── platform/
│   ├── self-heal-controller/
│   ├── argo-workflows/
│   ├── analysis-templates/
│   ├── external-secrets/
│   └── monitoring/
└── tenants/
    ├── tenant-payment/
    └── tenant-checkout/
```

| Layer | Responsibility |
|---|---|
| `bootstrap` | State bucket, KMS và GitHub OIDC |
| `foundation` | VPC, EKS và AWS services |
| `platform` | Controllers và add-ons |
| `tenants` | Namespace, quota, RBAC, ArgoCD Application |
| `gitops` | Desired state của platform và tenant |
### 1.3 State management

```text
sandbox/foundation/terraform.tfstate
sandbox/platform/terraform.tfstate
sandbox/tenants/tenant-payment/terraform.tfstate
sandbox/tenants/tenant-checkout/terraform.tfstate
```

Quy tắc:
- state bucket bật Versioning, Block Public Access và SSE-KMS;
- mỗi root dùng state key riêng;
- commit `.terraform.lock.hcl`;
- không lưu secret thật trong `tfvars`;
- không sửa state thủ công;
- PR chạy `fmt`, `validate`, scan và `plan`;
- apply sau merge và approval;
- thay đổi EKS, RDS, IAM, KMS, network hoặc Object Lock cần review.
| Lock | Store | Purpose |
|---|---|---|
| Terraform state lock | S3 lockfile | Chặn apply đồng thời |
| Incident lock | DynamoDB | Chặn xử lý trùng incident |

## 2. CI/CD pipeline
### 2.1 Pipeline stages
Pipeline tách:
1. `controller/`: Receiver, Worker, Direct Patch Engine.
2. `infra/`: Terraform.
3. `gitops/`: Kubernetes và Argo manifests.

```text
PR
→ Detect paths
→ Lint / Test / Scan / Plan
→ Review
→ Merge
→ Publish
→ Terraform apply hoặc ArgoCD sync
→ Smoke test
```

| Stage | Tool | What it does | Quality gate |
|---|---|---|---|
| Lint | Ruff | Kiểm tra Python | Không lỗi |
| Test | Pytest | Unit + contract test | Pass, mục tiêu ≥ 70% |
| Secret scan | Gitleaks | Tìm secret | Không có secret thật |
| Build | Docker Buildx | Build image | Thành công |
| Image scan | Trivy | Quét CVE | Không CRITICAL |
| IaC | Terraform | Validate + plan | Plan được review |
| Manifest | Helm + Argo CLI | Render + lint | Không schema error |
| Publish | ECR | Push image theo SHA | Không dùng `latest` |
| Infra deploy | Terraform | Apply saved plan | Approval + success |
| App deploy | ArgoCD | Sync Git → EKS | Synced + Healthy |
| Smoke | curl, kubectl, pytest | Kiểm tra flow chính | Pass |
Sau merge:
- image push lên ECR theo `sha-<commit>`;
- manifest dùng image digest;
- Terraform tạo lại plan trước apply;
- ArgoCD triển khai Kubernetes manifest.
Smoke test:

```text
Receiver health/readiness
Receiver gửi được SQS message
Worker nhận canary message
DynamoDB lock hoạt động
ArgoCD Synced + Healthy
Argo Workflow controller Ready
ESO đồng bộ secret
Firehose ACTIVE và audit tới S3
```

E2E:

```text
Urgent:
Alert → Receiver → SQS → Worker → AI → Direct Patch → Verify → Audit
Deferred:
Alert → Receiver → SQS → Worker → AI → Workflow
→ Git → ArgoCD → Verify → Audit
```

### 2.2 Branch strategy
- `main`: deployable và là GitOps source of truth.
- `feature/*`: tính năng.
- `fix/*`: sửa lỗi.
- `docs/*`: tài liệu.
- `hotfix/*`: sửa lỗi khẩn cấp.
Không dùng `develop` vì Capstone chỉ có một sandbox.
`main`:
- bắt buộc Pull Request và một approval;
- required checks phải pass;
- cấm direct push và force push;
- CODEOWNERS cho `infra/`, `gitops/`, workflow;
- squash merge;
- không merge `latest`, secret hoặc kubeconfig.

## 3. GitOps
### 3.1 Tool
Nhóm dùng **ArgoCD** để đồng bộ desired state từ GitHub xuống EKS.
Terraform chỉ bootstrap controller. ArgoCD quản lý:
- Receiver và Worker;
- Service, Ingress, ConfigMap;
- WorkflowTemplate và AnalysisTemplate;
- monitoring manifests;
- tenant workloads.

```text
PR → Review → Merge main
→ ArgoCD refresh
→ Compare desired/live
→ Sync
→ Health check
```

Deferred remediation:

```text
Worker tạo Workflow
→ Workflow cập nhật Git
→ ArgoCD sync
→ Verify
→ Audit
```

Commit remediation chứa incident, correlation, tenant, action và target.
### 3.2 Sync waves

| Wave | Components |
|---:|---|
| `-4` | Namespace |
| `-3` | Quota, ServiceAccount, RBAC, NetworkPolicy |
| `-2` | ConfigMap, SecretStore, ExternalSecret |
| `-1` | Service, WorkflowTemplate, AnalysisTemplate |
| `0` | Receiver, Worker, tenant workload |
| `1` | Ingress |
| `2` | PostSync smoke test |
AWS services do Terraform quản lý, không nằm trong sync wave.
### 3.3 Drift detection
Platform Application:

```yaml
automated:
  prune: false
  selfHeal: true
```

Tenant workload không bật `selfHeal` ngay vì Direct Patch có thể thay đổi runtime.
Quy tắc:
- restart/delete Pod không cần commit Git;
- replicas, resources, HPA, image và config phải persist vào Git;
- persistent patch mục tiêu trở lại `Synced` trong 120 giây;
- Git/ArgoCD thất bại thì rollback hoặc escalation;
- resource quan trọng dùng `Prune=confirm`.

## 4. Deployment strategy
### 4.1 Strategy
| Component | Strategy |
|---|---|
| FastAPI Receiver | Argo Rollouts Canary qua ALB |
| SQS Worker | Kubernetes RollingUpdate |
| WorkflowTemplate/policy | GitOps sync |
| Platform controllers | Helm upgrade + approval |
Receiver canary:

```text
10% → 5 phút
50% → 10 phút
100%
```

Abort ban đầu:
- HTTP 5xx > 1%;
- P99 > 800 ms;
- canary Pod không Ready;
- SQS enqueue thất bại.
Worker:

```yaml
rollingUpdate:
  maxUnavailable: 0
  maxSurge: 1
```

SQS visibility timeout phải dài hơn thời gian xử lý.
DynamoDB lock ngăn thực thi trùng.
### 4.2 Rollback method
| Change | Rollback |
|---|---|
| Receiver canary | Abort, traffic về stable |
| Worker image | Revert image digest trong Git |
| Persistent K8s change | Khôi phục pre-state + Git revert |
| Deferred remediation | Revert Workflow commit |
| Terraform | Revert code, plan, apply forward |
Không khôi phục thủ công Terraform state cũ.
Mục tiêu Receiver: traffic về stable dưới 60 giây sau khi analysis fail;
cần kiểm chứng trong sandbox.

## 5. Environment separation
| Env | Purpose | Account | Auto-deploy |
|---|---|---|---|
| Sandbox | Dev và demo | Sandbox account | Merge + approval |
| Staging | Pre-production test | Chưa triển khai | Release + approval |
| Prod | Tenant thật | Ngoài phạm vi | Manual + canary |
Chỉ sandbox được triển khai trong Capstone.
Image build một lần và promote bằng digest.

## 6. Secrets in pipeline
- GitHub Actions dùng OIDC.
- Secret lưu trong AWS Secrets Manager.
- ESO đồng bộ secret vào đúng namespace.
- Git chỉ lưu `SecretStore` và `ExternalSecret`.
- Git read credential tách Git write credential.
- IAM giới hạn theo ARN prefix.
- Gitleaks chạy trên Pull Request.
- Secret bị lộ phải rotate.
- Rotation: Secrets Manager → ESO → restart nếu cần → health check.

| Secret | Consumer |
|---|---|
| Git read credential | ArgoCD |
| Git write credential | Argo Workflow |
| RDS credentials | Runtime |
| Slack webhook | Escalation |
| ArgoCD bootstrap credential | Platform admin |
| AI authentication | Worker nếu không dùng SigV4 |

## 7. Tenant onboarding deployment
Không dùng Step Functions.

```text
1. Thêm tenant config vào Git
2. CI validate ID, namespace, quota, policy
3. Review và merge
4. Terraform tạo namespace, quota, RBAC, registry
5. ArgoCD sync tenant Application
6. Smoke test + RBAC isolation
7. Tenant READY
```

| Tenant ID | Namespace |
|---|---|
| `tnt-payment-demo` | `tenant-payment` |
| `tnt-checkout-demo` | `tenant-checkout` |
Tenant config gồm:
- tenant ID, namespace, owner;
- quota và allowed pattern;
- secret prefix;
- workload path;
- escalation destination.
Tenant chỉ `READY` khi:
- namespace, quota và RBAC tồn tại;
- ArgoCD Synced + Healthy;
- ExternalSecret và workload Ready;
- request đúng tenant được nhận;
- tenant mismatch và cross-tenant action bị chặn.
Mục tiêu onboarding sandbox: dưới 30 phút sau merge và approval.
Đây là design target, cần đo bằng hai tenant demo.

## 8. Observability stack
| Component | Tool |
|---|---|
| Metrics | Prometheus + CloudWatch |
| Logs | CloudWatch Logs |
| Traces | OpenTelemetry → ADOT → X-Ray |
| Dashboards | Grafana + CloudWatch |
| Alerts | Alertmanager + CloudWatch Alarms |
| Audit | Firehose → S3 Object Lock → Athena |
Metric chính:
- alert, validation failure và incident result;
- action duration, rollback và AI latency;
- audit publish failure;
- SQS backlog và oldest message;
- ArgoCD sync/health;
- Workflow success/failure;
- Pod restart, OOMKilled và node readiness.
Log JSON chứa timestamp, service, tenant, incident, correlation,
event type, action, target và result.
Không ghi secret, token, password hoặc raw Kubernetes Secret.
Alert routing:

```text
Tenant workload alert
→ Alertmanager → Receiver → SQS → Worker
Self-Heal platform failure
→ Alertmanager/CloudWatch → Slack/on-call
```

Lỗi của Self-Heal Platform không quay lại Receiver để tránh vòng lặp.
| Endpoint | Purpose |
|---|---|
| `/healthz` | Process còn chạy |
| `/readyz` | Dependency sẵn sàng |
| `/metrics` | Prometheus scrape |
S3 Object Lock là canonical audit store.

## 9. Open questions
- [x] **Alertmanager dùng ClusterIP hay Internal ALB?**  
  *Giải quyết:* Chốt dùng **ClusterIP** nội bộ cụm để giảm latency và tăng bảo mật (bypass ALB).
- [x] **Private subnet truy cập GitHub qua NAT hay egress proxy?**  
  *Giải quyết:* Chốt không dùng internet/GitHub cho runtime. ArgoCD pull manifests từ **AWS CodeCommit** thông qua VPC Interface Endpoint.
- [x] **EKS kết nối AI Engine bằng Peering, PrivateLink hay public HTTPS?**  
  *Giải quyết:* Chốt **CDO tự host AI Engine** (Docker container) chạy trực tiếp trong cụm EKS (chung namespace `self-heal-system`), giao tiếp local API.
- [x] **AI authentication dùng SigV4, API key hay mTLS?**  
  *Giải quyết:* Chốt dùng **local authentication** (ServiceAccount token) do chạy in-cluster.
- [ ] Git write credential dùng GitHub App, token hay deploy key?
- [ ] RDS lưu dữ liệu nào mà DynamoDB/Git không đáp ứng?
- [ ] Chọn EKS Pod Identity hay IRSA?
- [x] **SQS dùng Standard hay FIFO?**  
  *Giải quyết:* Chốt dùng **SQS Standard** (trùng lặp/idempotency được xử lý ở app layer bằng DynamoDB Conditional Write).
- [ ] Chốt inventory sáu secret.
- [ ] Prometheus và CloudWatch Logs giữ dữ liệu bao lâu?
- [ ] Distributed tracing là deliverable hay target design?
- [ ] Cách benchmark P99, error rate, RTO và onboarding?

## Related documents
- [`02_infra_design.md`](02_infra_design.md)
- [`03_security_design.md`](03_security_design.md)
- [`05_cost_analysis.md`](05_cost_analysis.md)
- [`08_adrs.md`](08_adrs.md)
