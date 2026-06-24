# Security Design - Task force 3 · CDO 1

<!-- Doc owner: <Nhóm CDO>
     Status: Draft (W11 T4) → Final (W11 T6) → Refined (W12 T4)
     Word target: 1200-2000 từ
     Scope: Bảo mật ở tầng DevOps (network, IAM, secrets, encryption, audit, K8s nếu áp dụng).
     Tier: Medium -->

## 1. Network Security

### 1.1 Network Diagram

Lưu lượng runtime nằm trong CDO VPC. Thiết kế này chủ động không dùng NAT
Gateway cho workload runtime; các workload gọi AWS service thông qua VPC
Endpoint. GitOps runtime kéo manifest từ AWS CodeCommit qua private endpoint,
không dùng GitHub.

```mermaid
flowchart LR
    user[Operator / Mentor]
    alb[Public ALB<br/>TLS 1.2+]
    receiver[Patch Receiver<br/>EKS workload]
    controller[Patch Controller<br/>EKS workload]
    gitops[GitOps Engine<br/>ArgoCD]
    codecommit[(AWS CodeCommit<br/>private Git repo)]
    sns[SNS Escalation Topic]
    s3[(S3 Audit Bucket)]
    rds[(RDS PostgreSQL)]
    vpce[VPC Endpoints<br/>S3, DynamoDB, SQS, Firehose,<br/>Secrets Manager, KMS, CloudWatch,<br/>ECR, STS, CodeCommit, SNS]

    user -->|Luồng Direct Patch: HTTPS| alb --> receiver --> controller
    controller -->|Ghi audit| s3
    controller -->|Dữ liệu ứng dụng| rds
    gitops -->|Luồng GitOps: git pull| codecommit
    controller -->|Luồng escalation| sns
    receiver -. AWS API calls .-> vpce
    controller -. AWS API calls .-> vpce
    gitops -. AWS API calls .-> vpce
```

Ranh giới mạng:

- Public subnet chỉ chứa ALB và các thành phần routing cần internet-facing.
- Private application subnet chứa EKS managed node và node do Karpenter cấp phát.
- Isolated data subnet chứa RDS.
- Không workload nào cần internet egress trực tiếp trong quá trình runtime
  reconciliation.
- Direct Patch path, GitOps path và Escalation path được tách bằng Security
  Group rule và quyền IAM.

### 1.2 Security Groups

| SG name | Inbound | Outbound | Attached to |
|---|---|---|---|
| `sg-alb-public` | TCP 443 từ operator CIDR đã duyệt / WAF | TCP 8443 đến `sg-eks-workload` | Public ALB |
| `sg-eks-workload` | TCP 8443 từ `sg-alb-public`; pod-to-pod traffic chỉ được mở qua Kubernetes NetworkPolicy | TCP 443 đến VPC endpoint; TCP 5432 đến `sg-rds`; TCP 443 đến EKS control plane | Patch Receiver, Patch Controller, Audit Writer, GitOps Engine |
| `sg-eks-control-plane` | TCP 443 từ EKS node và admin role được phép | TCP 10250 đến EKS node; TCP 443 đến AWS API qua VPC endpoint | EKS control plane ENI |
| `sg-rds` | TCP 5432 chỉ từ `sg-eks-workload` | Không mở outbound rộng; chỉ dùng response traffic mặc định do AWS quản lý | RDS PostgreSQL |
| `sg-vpc-endpoint` | TCP 443 từ `sg-eks-workload` và `sg-eks-control-plane` | TCP 443 đến AWS service endpoint target | Interface VPC endpoint |

Security Group được quản lý bằng Terraform state và review qua cùng pull-request
path với application manifest. Không mở CIDR rộng trực tiếp vào workload; quyền
truy cập workload được biểu diễn bằng SG reference khi có thể.

### 1.3 Network ACL / VPC Endpoint

- Network ACL giữ ở mức stateless và chặt chẽ: public subnet cho phép ALB ingress
  trên cổng 443 và ephemeral response port; private/data subnet chỉ cho phép VPC
  CIDR traffic cần cho EKS, RDS và return traffic của interface endpoint.
- Runtime GitOps dùng AWS CodeCommit thông qua VPC endpoint. GitHub có thể dùng
  ở giai đoạn CI/CD bootstrap nếu deployment design cần, nhưng không dùng trong
  runtime reconciliation.
- Gateway VPC Endpoint:
  - S3 cho audit storage, tải ECR layer và Terraform state nếu state nằm trong
    account.
  - DynamoDB cho lock table và service integration khi áp dụng.
- Interface VPC Endpoint:
  - SQS cho asynchronous patch workflow.
  - Kinesis Firehose cho audit delivery.
  - Secrets Manager để lấy secret.
  - KMS cho encrypt/decrypt call.
  - CloudWatch Logs và CloudWatch Metrics cho observability.
  - ECR API và ECR Docker để pull private image.
  - STS cho IRSA token exchange.
  - CodeCommit Git và CodeCommit API cho ArgoCD Git pull.
  - SNS cho escalation notification.
- Endpoint policy chặn repository, bucket, topic và key không liên quan. S3
  endpoint policy chỉ cho phép các audit, artifact và state bucket cần thiết.

---

## 2. IAM & Access Control

### 2.1 Service Roles

| Role | Used by | Permissions (least-privilege) |
|---|---|---|
| `irsa-patch-receiver` | Receiver ServiceAccount | Đọc request configuration, ghi sanitized request metadata, không có quyền mutation trên infrastructure resource |
| `irsa-patch-controller` | Controller ServiceAccount | Đọc approved patch intent, tạo thay đổi Kubernetes có giới hạn trong namespace được sở hữu, gọi STS, đọc Secrets Manager entry cần thiết |
| `irsa-audit-writer` | Audit Writer ServiceAccount | `firehose:PutRecord`, `firehose:PutRecordBatch`, ghi S3 có scope qua Firehose delivery role, KMS encrypt với audit key |
| `irsa-gitops-engine` | ArgoCD / GitOps Engine ServiceAccount | `codecommit:GitPull` và read-only CodeCommit API access chỉ cho CDO repository |
| `irsa-karpenter-controller` | Karpenter ServiceAccount | Provision/terminate EC2 node class được phép, đọc SSM AMI parameter, chỉ pass EKS node instance profile đã duyệt |
| `eks-node-role` | EKS managed node group và Karpenter node | Pull image từ ECR, publish CloudWatch agent, CNI permission, không có quyền truy cập application data |
| `irsa-escalation-notifier` | Escalation worker ServiceAccount | `sns:Publish` chỉ đến escalation topic đã duyệt |
| `firehose-delivery-role` | Kinesis Firehose | Ghi vào audit S3 bucket prefix, dùng audit KMS key, gửi delivery error vào CloudWatch |

Ghi chú về ownership của AI Engine: nếu AIOps sở hữu model runtime, CDO service
role không có `bedrock:InvokeModel`. CDO gửi request đã duyệt và nhận decision
qua integration contract đã thống nhất, thay vì gọi model trực tiếp.

### 2.2 K8s RBAC

| Role | Subject | Verbs | Resources | Namespace scope |
|---|---|---|---|---|
| `patch-receiver-readonly` | `sa/patch-receiver` | `get`, `list` | `configmaps`, `services`, `endpoints` | `cdo-system` |
| `patch-controller-ns-editor` | `sa/patch-controller` | `get`, `list`, `watch`, `patch`, `update` | `deployments`, `statefulsets`, `configmaps`, `horizontalpodautoscalers` | Tenant namespace do CDO sở hữu |
| `audit-writer-runtime` | `sa/audit-writer` | `create` | `events` | `cdo-system` |
| `argocd-application-sync` | `sa/argocd-application-controller` | `get`, `list`, `watch`, `patch`, `update`, `create` | Chỉ resource được khai báo cho application | Namespace được liệt kê trong ArgoCD AppProject |
| `karpenter-controller` | `sa/karpenter` | `get`, `list`, `watch`, `create`, `delete` | `nodes`, `nodeclaims`, `nodepools`, `events` | Cluster-scoped khi Karpenter yêu cầu |
| `escalation-notifier-readonly` | `sa/escalation-notifier` | `get`, `list` | `configmaps`, `events` | `cdo-system` |

RBAC không cấp `cluster-admin` cho CDO workload. Việc mutation tenant bị giới hạn
trong các namespace được gán rõ cho CDO, và cross-tenant mutation bị chặn bằng
namespace scope, admission policy và giới hạn destination trong ArgoCD
AppProject.

### 2.3 Cross-account Access

Nếu platform, AIOps và CDO nằm ở các account khác nhau, cross-account access dùng
assume-role pattern rõ ràng:

- CDO workload role chỉ assume các target role được đặt tên cụ thể, có external
  ID và session tag (`tenant_id`, `service`, `purpose`).
- Target account role trust CDO account OIDC provider hoặc deployment role,
  không trust principal AWS rộng.
- Session duration ngắn và khớp với reconciliation job.
- CloudTrail ghi lại `AssumeRole` và downstream action ở cả source account và
  target account.
- CDO role không được assume AIOps model-owner role trừ khi ADR chuyển ownership
  AI Engine sang CDO.

---

## 3. Secrets Management

### 3.1 Secrets Inventory

| Secret | Storage | Rotation | Accessed by |
|---|---|---|---|
| Database application credential | AWS Secrets Manager | 30-90 ngày, phối hợp với RDS user rotation | Patch Controller thông qua Kubernetes Secret do ESO tạo |
| Webhook signing key | AWS Secrets Manager | Manual rotation theo release hoặc incident | Patch Receiver |
| CodeCommit access | IRSA + STS, không dùng static secret | AWS-managed token exchange | ArgoCD GitOps Engine |
| SNS escalation topic ARN/config | Kubernetes ConfigMap; không chứa secret value | Kiểm soát theo release | Escalation notifier |
| Firehose delivery config | IAM role và environment config | Kiểm soát theo release | Audit Writer |

### 3.2 Inject Pattern

Secret được lưu trong AWS Secrets Manager và đồng bộ vào Kubernetes bằng
External Secrets Operator (ESO):

1. Mỗi workload có Kubernetes ServiceAccount riêng, map với IRSA role có scope
   hẹp.
2. ESO chỉ đọc các Secrets Manager ARN đã duyệt cho namespace đó.
3. ESO tạo Kubernetes Secret trong workload namespace.
4. Pod ưu tiên consume secret dưới dạng mounted file; environment variable chỉ
   dùng khi thư viện không hỗ trợ file-based credential.
5. Tên secret ổn định, nhưng giá trị secret được rotate trong Secrets Manager.

Runtime GitOps không dùng GitHub Deploy Key. ArgoCD xác thực với CodeCommit qua
IRSA và STS, vì vậy cluster không lưu long-lived Git credential.

### 3.3 Anti-leak Controls

- Secrets KHÔNG commit Git.
- Container image không bake credential.
- Application log áp dụng redact pattern.
- CI chạy Gitleaks trước khi merge và block credential bị phát hiện.
- Kubernetes Secret do ESO quản lý được scope theo namespace và loại khỏi ArgoCD
  diff output nếu output có thể render giá trị secret.
- Incident response bao gồm rotate ngay trong Secrets Manager và restart pod cho
  mọi credential bị lộ.

---

## 4. Encryption

### 4.1 At Rest

| Data | Storage | KMS key | Notes |
|---|---|---|---|
| Audit events | S3 bucket với Object Lock | `alias/cdo-audit-kms` | Firehose ghi object đã mã hóa; Athena read được log lại |
| Application data | RDS PostgreSQL / EBS volume | `alias/cdo-app-data-kms` | Bật RDS storage encryption |
| Runtime secrets | Secrets Manager và EKS Secrets | `alias/cdo-secrets-kms` | Bật EKS envelope encryption at rest cho Kubernetes Secrets |
| Infrastructure state/artifacts | S3 / DynamoDB / ECR | `alias/cdo-infra-kms` | Terraform state, lock table và private image |
| Observability logs | CloudWatch Logs / Firehose backup | `alias/cdo-observability-kms` | Log group dùng customer-managed key khi service hỗ trợ |
| Node root volume | Karpenter EC2 EBS root volume | `alias/cdo-infra-kms` | Karpenter EC2NodeClass bắt buộc root volume được mã hóa |

### 4.2 In Transit

- ALB listener dùng certificate do ACM quản lý và TLS security policy hiện hành
  của AWS, bắt buộc TLS 1.2 trở lên.
- Internal service-to-service call dùng HTTPS khi service expose HTTP API;
  Kubernetes NetworkPolicy vẫn kiểm soát lateral movement.
- AWS service call dùng HTTPS thông qua VPC endpoint.
- CodeCommit Git traffic dùng HTTPS qua private CodeCommit endpoint.
- S3 bucket policy chặn request không dùng HTTPS:

```json
{
  "Sid": "DenyInsecureTransport",
  "Effect": "Deny",
  "Principal": "*",
  "Action": "s3:*",
  "Resource": [
    "arn:aws:s3:::cdo-audit-bucket",
    "arn:aws:s3:::cdo-audit-bucket/*"
  ],
  "Condition": {
    "Bool": {
      "aws:SecureTransport": "false"
    }
  }
}
```

### 4.3 Key Management

- Customer-managed KMS key được nhóm theo mục đích: audit, app-data, secrets,
  infra và observability.
- Bật automatic key rotation khi service hỗ trợ.
- Key policy cấp quyền admin cho platform security role và chỉ cấp quyền use cho
  IRSA hoặc AWS service role thật sự cần key đó.
- Không cấp `kms:Decrypt` với wildcard resource scope.
- KMS API call được audit trong CloudTrail và correlate với service audit event
  bằng `correlation_id` khi có thể.

---

## 5. Audit Logging

### 5.1 What to Log

Audit logging phải đủ để giải thích ai yêu cầu thay đổi, hệ thống quyết định gì,
đã apply gì, và control bảo mật có can thiệp hay không.

Events:

- Nhận patch request.
- Kết quả policy evaluation.
- AI decision nhận từ AIOps, nếu áp dụng.
- Direct patch được approve, reject hoặc block.
- GitOps reconciliation bắt đầu và hoàn tất.
- Kubernetes resource mutation được attempt và hoàn tất.
- Cross-account role assumption.
- Workload role đọc secret.
- Escalation notification được publish đến SNS.
- Security violation hoặc policy block.
- Firehose delivery failure.

Các audit field bắt buộc:

| Field | Purpose |
|---|---|
| `event_id` | Định danh duy nhất của event |
| `timestamp` | Thời điểm event theo UTC |
| `severity` | `INFO`, `WARN`, `ERROR`, `SECURITY` |
| `correlation_id` | Trace một request qua receiver, controller, GitOps và audit writer |
| `tenant_id` | Xác định tenant / namespace ownership |
| `actor` | Human, workload hoặc assumed role khởi tạo action |
| `action_type` | Request, decision, mutation, escalation hoặc control event |
| `resource_ref` | Kubernetes, AWS hoặc Git resource bị tác động |
| `decision` | `APPROVED`, `REJECTED`, `POLICY_BLOCKED`, `SECURITY_VIOLATION` |
| `reason` | Giải thích an toàn để ghi log |

Ví dụ audit event:

```json
{
  "event_id": "evt-01JZ7X6YQ5G7Y7V9VK2P0S6E2A",
  "timestamp": "2026-06-25T09:30:00Z",
  "severity": "SECURITY",
  "correlation_id": "corr-cdo-20260625-0017",
  "tenant_id": "tenant-a",
  "actor": "arn:aws:sts::111122223333:assumed-role/irsa-patch-controller/session",
  "action_type": "K8S_MUTATION",
  "resource_ref": "deployment/tenant-a/api",
  "decision": "POLICY_BLOCKED",
  "reason": "Attempted mutation outside approved namespace"
}
```

### 5.2 Storage + Retention

| Log type | Storage | Retention | Query interface |
|---|---|---|---|
| Application audit events | Kinesis Firehose đến S3 Object Lock bucket | 1 năm hot query, archive lâu hơn theo compliance policy | Athena |
| EKS API server audit logs | CloudWatch Logs encrypted log group | 90 ngày hot retention | CloudWatch Logs Insights |
| CloudTrail management events | CloudTrail organization trail đến S3 | 1 năm hot query, sau đó archive | Athena / CloudTrail Lake nếu bật |
| CloudTrail S3 data events | CloudTrail data event trail cho audit bucket | 1 năm hot query | Athena |
| Secrets Manager access events | CloudTrail management events | 1 năm hot query | Athena / CloudWatch metric filter |
| Security alerts | CloudWatch Alarm và SNS notification | Alarm history theo retention của CloudWatch | CloudWatch |

Pipeline:

1. Workload emit structured JSON audit event.
2. Audit Writer gửi event đến Kinesis Firehose qua private endpoint.
3. Firehose buffer, mã hóa và ghi object đã partition vào S3 audit bucket.
4. S3 Object Lock bảo vệ audit record khỏi bị xóa hoặc overwrite trong retention
   window.
5. Athena external table query audit partition theo date, tenant, severity và
   action type.

Xử lý Firehose failed delivery:

- Firehose ghi failed record vào S3 error prefix riêng.
- CloudWatch metric theo dõi delivery failure và throttling.
- CloudWatch Alarm publish đến escalation SNS topic khi số delivery failure lớn
  hơn 0 trong evaluation window đã cấu hình.
- Replay được thực hiện từ error prefix sau khi lỗi delivery đã được xử lý.

### 5.3 PII Handling (basic)

- Schema whitelist.
- Redaction at ingest.
- Audit payload chỉ lưu resource identifier và policy outcome, không lưu request
  body chứa user data.
- Tenant identifier là thông tin bắt buộc để accountability nhưng được xem là
  sensitive operational metadata.

### 5.4 Security Alerting

CloudWatch Metric Filter theo dõi structured audit event cho:

- `decision = "SECURITY_VIOLATION"`
- `decision = "POLICY_BLOCKED"`
- `severity = "SECURITY"`
- Firehose delivery failure.
- `secretsmanager:GetSecretValue` bất thường từ role nằm ngoài IRSA allowlist đã
  duyệt.

Alert được publish đến escalation SNS topic. SNS subscription chỉ giới hạn cho
incident response channel và on-call recipient đã duyệt. Alert message bao gồm
`event_id`, `correlation_id`, `tenant_id`, `severity`, `action_type` và
`resource_ref` để responder query audit trail đầy đủ mà không expose secret
value.

---

## 6. Container & K8s Security (chỉ áp dụng nếu CDO chọn K8s/EKS angle)

- Container image được scan bằng Trivy trong CI trước khi merge. Critical và high
  vulnerability sẽ block promotion trừ khi có exception được approve và có thời
  hạn.
- Gitleaks chạy trong CI để chặn secret bị commit trước khi manifest hoặc source
  code vào GitOps repository.
- Admission control dùng Kyverno hoặc Gatekeeper để enforce security baseline:
  không privileged pod, không hostPath volume trừ khi được approve rõ ràng,
  không dùng image tag `latest`, bắt buộc resource requests/limits và label cho
  tenant ownership.
- Namespace dùng Pod Security `restricted` baseline. Exception cần lý do workload
  được document và expiry date.
- Pod đặt `securityContext.seccompProfile.type: RuntimeDefault` mặc định.
- NetworkPolicy bắt đầu bằng default deny ingress/egress, sau đó chỉ allow
  ALB-to-receiver, workload-to-VPC-endpoint, workload-to-RDS và traffic nội bộ
  namespace thật sự cần.
- Mỗi workload có ServiceAccount và IRSA role riêng. Không dùng shared
  ServiceAccount cho application workload.
- ResourceQuota và LimitRange được cấu hình theo từng tenant namespace để một
  tenant không thể dùng hết node, CPU, memory hoặc object count capacity.
- ArgoCD AppProject giới hạn source repository, destination namespace, sync
  window và cluster-scoped resource kind được phép.
- EKS node group và Karpenter node pool dùng hardened AMI, encrypted root EBS
  volume, IMDSv2 và node IAM permission tối thiểu.

---

## 7. Compliance Touchpoints

| Standard | Relevant controls (capstone scope) |
|---|---|
| SOC2 Type II | IAM/RBAC least privilege, immutable audit logs, change traceability, security alerting, encrypted storage, kiểm soát truy cập secrets |
| GDPR | Data minimization trong audit logs, tenant identifier được xử lý như sensitive metadata, encryption in transit và at rest, chính sách deletion/retention phù hợp |
| ISO 27001 | Access control, logging and monitoring, cryptographic controls, network segmentation, vulnerability management |
| CIS Kubernetes Benchmark | Pod Security restricted baseline, không privileged workload, NetworkPolicy default deny, audit logging, RBAC least privilege |

---

## 8. Open Questions

- [ ] Xác nhận tên CodeCommit repository cuối cùng và branch protection model cho
      runtime GitOps.
- [ ] Xác nhận SNS escalation subscriber, owner on-call và alert sẽ fan out sang
      Slack hay chỉ email.
- [ ] Xác nhận mô hình exposure của ALB: chỉ approved operator CIDR, WAF
      allowlist, hoặc private ALB sau VPN / corporate network.
- [ ] Xác nhận AIOps có tiếp tục là owner duy nhất của AI Engine invocation hay
      không. Nếu sau này CDO gọi Bedrock trực tiếp, cần cập nhật IAM, endpoint,
      audit và ownership section.
- [ ] Xác nhận retention period và Object Lock mode cho audit S3 bucket.

---

## 9. Related documents

- `02_infra_design.md`
- `04_deployment_design.md`
- `08_adrs.md`
