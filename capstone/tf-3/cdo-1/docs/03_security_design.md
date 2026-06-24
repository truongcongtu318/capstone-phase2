# Security Design - Task force 3 · CDO 1

<!-- Doc owner: <Nhóm CDO>
     Status: Draft (W11 T4) → Final (W11 T6) → Refined (W12 T4)
     Word target: 1200-2000 từ
     Scope: DevOps-level security (network, IAM, secrets, encryption, audit, K8s if applicable).
     Tier: Medium -->

## 1. Network Security

### 1.1 Network Diagram

<!-- Mermaid diagram thể hiện VPC layout, subnet, SG, ALB, NAT, internet gateway -->

### 1.2 Security Groups

| SG name | Inbound | Outbound | Attached to |
|---|---|---|---|
| | | | |

### 1.3 Network ACL / VPC Endpoint

- VPC endpoint cho Bedrock runtime:
- VPC endpoint cho Secrets Manager:
- VPC endpoint cho S3 (audit storage):

---

## 2. IAM & Access Control

### 2.1 Service Roles

| Role | Used by | Permissions (least-privilege) |
|---|---|---|
| | | |

### 2.2 K8s RBAC

| Role | Subject | Verbs | Resources | Namespace scope |
|---|---|---|---|---|
| | | | | |

### 2.3 Cross-account Access

<!-- Nếu task force account khác với platform account, ghi rõ assume role pattern -->

---

## 3. Secrets Management

### 3.1 Secrets Inventory

| Secret | Storage | Rotation | Accessed by |
|---|---|---|---|
| | | | |

### 3.2 Inject Pattern

<!-- ECS task definition? Kubernetes External Secrets Operator? Env var via Init container? -->

### 3.3 Anti-leak Controls

- Secrets KHÔNG commit Git.
- Container image không bake credential.
- Application log redact pattern.

---

## 4. Encryption

Thiết kế mã hóa của Self-Heal Platform áp dụng nguyên tắc **encryption by default** cho dữ liệu lưu trữ và **TLS in transit** cho các kết nối đi qua trust boundary. Các dữ liệu nhạy cảm như tenant metadata, incident state, remediation decision, audit log, Terraform state và application secrets không được lưu dưới dạng plaintext.

Hệ thống sử dụng AWS Key Management Service (AWS KMS) để quản lý khóa mã hóa. Các nhóm dữ liệu có mức độ nhạy cảm và quyền truy cập khác nhau được tách sang các KMS key riêng nhằm giảm blast radius khi một workload hoặc IAM role bị compromise.

### 4.1. Encryption at Rest

| Data / Resource                                                                                     | Storage                               | Encryption mechanism                           | KMS key                                                                                      | Notes                                                                                                                                                                           |
| --------------------------------------------------------------------------------------------------- | ------------------------------------- | ---------------------------------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Immutable audit log, AI remediation decision, pre/post Kubernetes state và security violation event | Amazon S3 bucket `selfheal-audit`     | SSE-KMS kết hợp S3 Object Lock Compliance Mode | Customer-managed key `alias/selfheal-audit`                                                  | Object Lock giữ log bất biến trong 90 ngày. Bucket policy từ chối request không dùng HTTPS hoặc không chỉ định `aws:kms`. Bật S3 Bucket Key để giảm số lượng KMS request.       |
| Incident state, tenant registry, idempotency lock và rate-limit counter                             | Amazon DynamoDB                       | Server-side encryption bằng AWS KMS            | Customer-managed key `alias/selfheal-app-data`                                               | Áp dụng cho các bảng `incident_state`, `tenant_registry`, `incident_locks` và `tenant_rate_limits`. Dữ liệu được phân vùng logic bằng `tenant_id`.                              |
| Alert event, remediation job và Dead Letter Queue message                                           | Amazon SQS Standard Queue và DLQ      | SSE-KMS                                        | Customer-managed key `alias/selfheal-app-data`                                               | Message body và message attributes được mã hóa khi lưu. SQS message không được chứa password, token hoặc credential dạng plaintext.                                             |
| Database password, API token, GitHub credential và integration secret                               | AWS Secrets Manager                   | Envelope encryption bằng AWS KMS               | Customer-managed key `alias/selfheal-secrets`                                                | Chỉ External Secrets Operator và workload được cấp IRSA tương ứng mới có quyền `secretsmanager:GetSecretValue`. Secret không được commit vào Git hoặc bake vào container image. |
| Kubernetes PersistentVolume và dữ liệu tạm trên worker node                                         | Amazon EBS thông qua EBS CSI Driver   | EBS encryption at rest                         | AWS-managed key `aws/ebs` cho sandbox; customer-managed key khi triển khai production        | Bật EBS encryption by default cho account/region. StorageClass phải khai báo encrypted volume và không cho phép tạo PVC không mã hóa.                                           |
| Terraform state chứa resource identifier và infrastructure metadata                                 | Amazon S3 Terraform backend           | SSE-KMS, S3 Versioning và Block Public Access  | Customer-managed key `alias/selfheal-infra`                                                  | Chỉ CI/CD role và platform administrator được đọc hoặc ghi state. Không lưu secret plaintext trong Terraform output hoặc state nếu có thể tránh được.                           |
| Terraform state lock                                                                                | Amazon DynamoDB                       | Server-side encryption bằng AWS KMS            | Customer-managed key `alias/selfheal-infra`                                                  | Chỉ Terraform execution role được phép đọc, tạo và xóa lock record.                                                                                                             |
| Application log, Kubernetes control-plane log và security log                                       | Amazon CloudWatch Logs                | KMS encryption cho log group                   | Customer-managed key `alias/selfheal-observability`                                          | Log group đặt retention theo loại log. Application phải redact password, access token, authorization header và secret value trước khi ghi log.                                  |
| Metrics và telemetry phục vụ monitoring                                                             | Amazon Managed Service for Prometheus | Service-managed encryption at rest             | AWS service-managed encryption                                                               | Metrics label không được chứa secret, raw credential hoặc toàn bộ request payload. `tenant_id` chỉ được dùng như metadata phục vụ filter và phân quyền.                         |
| Container image của FastAPI Receiver, worker và remediation engine                                  | Amazon ECR                            | Server-side encryption                         | AWS-owned encryption cho sandbox; customer-managed key nếu production yêu cầu key separation | Bật image scanning. Không copy `.env`, kubeconfig, AWS credential hoặc private key vào image layer.                                                                             |

Các bucket S3 quan trọng phải có policy từ chối kết nối không mã hóa:

```json
{
  "Effect": "Deny",
  "Principal": "*",
  "Action": "s3:*",
  "Resource": [
    "arn:aws:s3:::selfheal-audit",
    "arn:aws:s3:::selfheal-audit/*"
  ],
  "Condition": {
    "Bool": {
      "aws:SecureTransport": "false"
    }
  }
}
```

Riêng bucket audit phải từ chối thao tác `PutObject` không sử dụng SSE-KMS. S3 Object Lock được sử dụng để đảm bảo tính bất biến của audit record, nhưng không thay thế cho mã hóa bằng KMS.

### 4.2. Encryption in Transit

| Connection                                                                 | Protocol / Encryption                                                                  | Identity / Certificate                                    | Enforcement                                                                                                                                                         |
| -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prometheus Alertmanager hoặc alert source → Internal ALB                   | HTTPS với TLS 1.2 trở lên                                                              | ACM certificate gắn trên ALB HTTPS listener               | Không mở HTTP listener; hoặc HTTP chỉ dùng để redirect sang HTTPS. Security Group chỉ cho phép traffic từ approved alert sources.                                   |
| Internal ALB → FastAPI Webhook Receiver                                    | HTTPS target group với TLS 1.2 trở lên                                                 | Internal certificate được cấp cho FastAPI service         | ALB chỉ forward traffic tới target group trong private subnet. Pod port không được expose trực tiếp ra Internet.                                                    |
| FastAPI Receiver / Direct Patch Engine → Kubernetes API Server             | HTTPS trên TCP 443                                                                     | Kubernetes ServiceAccount token và cluster CA certificate | Sử dụng `load_incluster_config()`. Kubernetes API xác thực ServiceAccount và enforce namespace-scoped RBAC trước khi thực thi action.                               |
| Argo Workflows / ArgoCD → Kubernetes API Server                            | HTTPS trên TCP 443                                                                     | Kubernetes ServiceAccount và RBAC                         | Không sử dụng cluster-admin cho workflow thông thường. Mỗi controller chỉ được cấp các verbs và resources cần thiết.                                                |
| ArgoCD / Git Commit Engine → GitHub repository                             | HTTPS TLS 1.2+ hoặc SSH                                                                | GitHub App, deploy key hoặc short-lived token             | Không lưu personal access token trong manifest. Credential được lấy từ Secrets Manager thông qua ESO.                                                               |
| EKS workloads → DynamoDB, SQS, S3, Secrets Manager, KMS và Bedrock Runtime | HTTPS TLS 1.2+ qua AWS SDK                                                             | AWS Signature Version 4 và IRSA temporary credentials     | Workload không dùng static AWS access key. VPC Endpoint được ưu tiên cho service hỗ trợ để traffic không đi qua public Internet.                                    |
| External Secrets Operator → AWS Secrets Manager                            | HTTPS TLS 1.2+                                                                         | IRSA role của ESO                                         | IAM policy giới hạn secret ARN và KMS key cụ thể. Không cấp wildcard `secretsmanager:*` hoặc `kms:*`.                                                               |
| ADOT Collector → Amazon Managed Service for Prometheus và CloudWatch       | HTTPS TLS 1.2+                                                                         | SigV4 và IRSA role của ADOT Collector                     | Chỉ mở egress tới AWS service endpoint cần thiết. Telemetry payload phải được redact trước khi gửi.                                                                 |
| GitHub Actions → AWS STS                                                   | HTTPS TLS 1.2+                                                                         | GitHub OIDC federation và short-lived STS credentials     | Không lưu AWS access key dài hạn trong GitHub Secrets. IAM trust policy giới hạn repository, branch và workflow được phép assume role.                              |
| Platform administrator → ArgoCD, Grafana và AWS Console                    | HTTPS TLS 1.2+                                                                         | SSO/MFA và certificate hợp lệ                             | Không expose dashboard qua HTTP. Administrative endpoint chỉ cho phép VPN, corporate CIDR hoặc approved identity-aware access path.                                 |
| Pod → Pod trong EKS                                                        | Network traffic trong VPC; HTTPS đối với control-plane hoặc sensitive application call | Kubernetes Service identity; mTLS là production hardening | NetworkPolicy giới hạn namespace và port. Capstone không bắt buộc triển khai service mesh; production roadmap áp dụng mTLS cho service-to-service traffic nhạy cảm. |

Việc ALB terminate TLS không có nghĩa là backend connection mặc định được mã hóa. Vì vậy target group của FastAPI Receiver được cấu hình sử dụng HTTPS để tránh truyền alert payload dạng plaintext từ ALB đến workload.

Các cuộc gọi tới AWS service bắt buộc sử dụng HTTPS endpoint. Khi VPC Endpoint được triển khai cho S3, Secrets Manager, DynamoDB hoặc Bedrock, endpoint policy tiếp tục giới hạn service, resource ARN và IAM principal được phép truy cập.

### 4.3. Key Management

| KMS key                        | Protected resources                                                  | Rotation                        | Key policy / Access control                                                                                                                                             | Audit and recovery                                                                                                                       |
| ------------------------------ | -------------------------------------------------------------------- | ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `alias/selfheal-audit`         | S3 audit bucket và immutable remediation records                     | Bật automatic rotation hằng năm | Audit writer role chỉ có `kms:Encrypt` và `kms:GenerateDataKey`. Audit reader role chỉ có `kms:Decrypt`. Application workload không có quyền quản trị key.              | CloudTrail ghi nhận Encrypt, Decrypt, GenerateDataKey, DisableKey và ScheduleKeyDeletion. Cảnh báo khi key bị disable hoặc lên lịch xóa. |
| `alias/selfheal-app-data`      | DynamoDB tables, SQS queue và DLQ                                    | Bật automatic rotation hằng năm | Chỉ IRSA role của Receiver, worker và remediation engine được sử dụng key. Quyền được giới hạn theo resource và encryption context khi phù hợp.                         | Theo dõi KMS access-denied event và mức tăng bất thường của Decrypt request.                                                             |
| `alias/selfheal-secrets`       | Secrets Manager secrets                                              | Bật automatic rotation hằng năm | ESO role chỉ có quyền decrypt các secret thuộc prefix của Self-Heal Platform. Platform administrator quản lý metadata nhưng không cấp quyền decrypt rộng cho developer. | CloudTrail và CloudWatch Alarm phát hiện secret access bất thường. Secret rotation được thực hiện độc lập với KMS key rotation.          |
| `alias/selfheal-infra`         | Terraform state bucket và DynamoDB state lock                        | Bật automatic rotation hằng năm | Chỉ Terraform CI/CD role và break-glass platform administrator được encrypt/decrypt. Developer thông thường không được đọc state production.                            | Bật CloudTrail data event cho state bucket. Theo dõi hành vi đọc state, thay đổi bucket policy và thay đổi KMS key policy.               |
| `alias/selfheal-observability` | CloudWatch Logs chứa application, audit forwarding và Kubernetes log | Bật automatic rotation hằng năm | CloudWatch Logs service principal được sử dụng key thông qua điều kiện `kms:ViaService`. Operator role chỉ có quyền decrypt khi thực hiện điều tra sự cố.               | Log toàn bộ thay đổi retention, key association và quyền đọc log.                                                                        |

#### Key ownership và separation of duties

KMS key được chia thành các nhóm riêng thay vì sử dụng một key duy nhất cho toàn bộ hệ thống:

* Audit key bảo vệ bằng chứng kiểm toán và không được cấp cho workload đọc thông thường.
* Application-data key phục vụ các hoạt động runtime của DynamoDB và SQS.
* Secrets key chỉ phục vụ Secrets Manager và ESO.
* Infrastructure key bảo vệ Terraform state.
* Observability key bảo vệ log vận hành.

IAM role sử dụng key và IAM role quản trị key phải được tách biệt. Application role chỉ được sử dụng các action cần thiết như:

```text
kms:Encrypt
kms:Decrypt
kms:GenerateDataKey
kms:DescribeKey
```

Application role không được cấp:

```text
kms:CreateKey
kms:PutKeyPolicy
kms:DisableKey
kms:ScheduleKeyDeletion
```

Key policy không sử dụng principal wildcard nếu không có condition giới hạn. Mọi quyền truy cập phải được gắn với IAM role cụ thể, AWS service principal cụ thể hoặc IRSA role của workload.

#### Rotation và deletion protection

Automatic key rotation được bật cho tất cả symmetric customer-managed keys. Việc rotate KMS key không yêu cầu mã hóa lại ngay toàn bộ dữ liệu cũ; AWS KMS giữ key material version cũ để tiếp tục decrypt ciphertext đã tồn tại.

Việc disable hoặc schedule deletion một KMS key phải:

1. Được platform administrator có quyền phù hợp thực hiện.
2. Có approval từ ít nhất một thành viên khác.
3. Tạo CloudTrail event và CloudWatch alert.
4. Sử dụng waiting period trước khi key bị xóa.
5. Kiểm tra dependency của S3, DynamoDB, SQS, Secrets Manager và CloudWatch Logs trước khi thay đổi.

#### Secret rotation và KMS rotation

KMS key rotation và secret rotation là hai quy trình khác nhau:

* **KMS rotation** thay đổi key material dùng để bảo vệ dữ liệu.
* **Secret rotation** thay đổi password, API token hoặc credential mà application sử dụng.

Secrets Manager secret cần có rotation policy riêng theo loại credential. Sau khi secret được rotate, External Secrets Operator đồng bộ giá trị mới vào Kubernetes Secret. Workload phải đọc secret từ mounted volume hoặc cơ chế reload phù hợp thay vì yêu cầu bake credential vào image.

#### Audit

Các sự kiện sau phải được theo dõi bằng AWS CloudTrail:

* `Encrypt`
* `Decrypt`
* `GenerateDataKey`
* `CreateGrant`
* `RevokeGrant`
* `PutKeyPolicy`
* `DisableKey`
* `ScheduleKeyDeletion`
* `CancelKeyDeletion`

CloudWatch Alarm phải cảnh báo khi xảy ra:

* KMS key bị disable.
* KMS key được schedule deletion.
* Key policy bị chỉnh sửa.
* Có số lượng lớn `Decrypt` request bất thường.
* Một IAM principal không thuộc allowlist cố gắng truy cập key.
* Secrets Manager secret bị đọc bởi role không đúng workload.

Thiết kế này đảm bảo dữ liệu tenant và audit trail được bảo vệ cả khi lưu trữ lẫn khi truyền, đồng thời giới hạn khả năng một workload bị compromise có thể sử dụng hoặc quản trị khóa mã hóa ngoài phạm vi được cấp.

---
## 5. Audit Logging

### 5.1 What to Log
* **AI engine decision**: Ghi lại toàn bộ lịch sử các cuộc gọi qua endpoint nội bộ (`/v1/detect`, `/v1/decide`, `/v1/verify`) của AI Engine. Các trường dữ liệu bắt buộc bao gồm: `timestamp` (định dạng RFC3339 UTC), `tenant_id` (UUID v4), `correlation_id` (hoặc `Idempotency-Key` dùng chung xuyên suốt luồng xử lý sự cố), `input hash` (mã băm cấu hình request/header), `output` (cấu trúc JSON hành động chi tiết như `suggested_action`, `target`, `action_params` từ response), `confidence` (độ tin cậy từ 0.0 - 1.0), `model version` / `runbook_id` và `latency` / `execution_time_seconds`.
* **Infrastructure change**: Giám sát và ghi nhận toàn bộ các sự kiện thay đổi, khởi tạo hoặc phá hủy tài nguyên hạ tầng AWS (AWS-level management events) thông qua CloudTrail, bao gồm: thực thi `Terraform apply` cập nhật cụm EKS, can thiệp thay đổi cấu hình hoặc dữ liệu thông qua RDS PostgreSQL, DynamoDB, AWS Secrets Manager hoặc chỉnh sửa cấu hình Amazon Kinesis Data Firehose.
* **K8s API audit**: Bật tính năng Kubernetes Audit Log mức cluster. Áp dụng chính sách `audit-policy` nhằm ghi vết tất cả các thao tác thay đổi trạng thái tài nguyên (Mutations) thực hiện bởi cả 2 luồng: **Path B** (Direct K8s API Patch/Restart như `patch`, `update` Deployments/Scale từ ServiceAccount `selfheal-executor`) và **Path A** (GitOps/ArgoCD controller đồng bộ trạng thái mong muốn từ config-repo vào cluster).
* **Application error**: Ghi log cấu trúc (Structured JSON) đối với toàn bộ các lỗi phát sinh từ các thành phần core nền tảng (FastAPI Webhook Receiver, Self-Heal Controller, Karpenter) và log lỗi từ workload demo của tenant (ví dụ: `checkout-api`, `order-worker`). Mọi log lỗi bắt buộc phải đính kèm `correlation_id` hoặc `tenant_id` để phục vụ truy vết phân tán xuyên suốt hệ thống (cross-service distributed tracing).

### 5.2 Storage + Retention

| Log type | Storage | Retention | Query interface |
| :--- | :--- | :--- | :--- |
| **AI decision audit** | **Amazon S3** kết hợp kích hoạt **S3 Object Lock** (Chế độ `COMPLIANCE` bảo vệ dữ liệu bất biến, chống sửa/xóa tuyệt đối). Đường dẫn lưu trữ được phân vùng logic theo folder prefix: `s3://tf3-sh-audit-logs/tenant_id=<tenant_uuid>/dt=YYYY-MM-DD/`. Luồng đẩy log đi trực tiếp từ `Self-Heal Controller -> Kinesis Data Firehose -> S3`. | **90 ngày** lưu trữ nóng (hot retention) đáp ứng tiêu chuẩn SOC2 của sandbox, **1 năm** lưu trữ lạnh (cold retention) qua S3 Lifecycle chuyển đổi sang Glacier. | **Amazon Athena** (Tạo bảng Schema đè lên các phân vùng S3 để truy vấn bằng cú pháp SQL tiêu chuẩn). Có thể tích hợp bảng panel Grafana/Athena để hiển thị lúc demo. |
| **CloudTrail** | **Amazon S3** + **AWS CloudTrail Lake** (Ghi nhận toàn bộ các thao tác API mức hạ tầng AWS của Sandbox). | **90 ngày** mặc định cho môi trường thử nghiệm và đánh giá. | **CloudTrail console** hoặc CloudTrail Lake SQL Queries để kiểm tra lịch sử thao tác của các AWS IAM User/Role. |
| **Application log** | **Amazon CloudWatch Logs** (Thu thập tập trung log từ tác vụ container thông qua FluentBit agent chạy dưới dạng DaemonSet trong cụm). | **14 ngày** (Phù hợp cho mục đích debug, giám sát thời gian thực và tối ưu chi phí lưu trữ cho môi trường sandbox). | **CloudWatch Logs Insights** (Sử dụng cú pháp filter lọc log theo level, container_name, pod_name và `correlation_id`). |
| **K8s audit** | **Amazon CloudWatch Logs** (Tích hợp trực tiếp từ EKS Control Plane Logging sang CloudWatch log groups) hoặc stream qua S3. | **30 ngày** (Đủ để theo dõi lịch sử thao tác K8s API trong các đợt chạy mô phỏng sự cố `W12 simulation`). | **CloudWatch Logs Insights** để phân tích cú pháp truy cập Kubernetes API và kiểm tra tính hợp lệ của RBAC Contract. |

---
> [!NOTE]
> **Ghi chú kỹ thuật từ CDOps**: Toàn bộ dữ liệu logs lưu chuyển trong pipeline đều được kiên cố hóa bằng mã hóa tại chỗ bằng các KMS Key tương ứng (`alias/selfheal-audit` và `alias/selfheal-observability`), mã hóa trên đường truyền (TLS in transit), đồng thời bộ ship log FluentBit sẽ thực hiện lọc bỏ thông tin nhạy cảm (PII Redaction) nhằm đảm bảo không ghi lọt secret hay thông tin credential vào audit body.

### 5.3 PII Handling (basic)

- **Schema whitelist**: Định nghĩa cứng các cấu trúc trường dữ liệu (JSON Schema) cho payload alert và log sự cố. Mọi trường lạ nằm ngoài whitelist chứa thông tin tự do (free-text) đều bị từ chối tiếp nhận nhằm ngăn chặn việc lọt dữ liệu nhạy cảm của khách hàng.
- **Redaction at ingest**: Bộ thu thập log FluentBit tích hợp các bộ lọc Regex filter tại tầng Webhook Receiver. Các chuỗi ký tự khớp với pattern của định danh cá nhân, Password, Database Token, Authorization Header hoặc AWS Access Key sẽ tự động bị thay thế bằng chuỗi `[REDACTED]` trước khi gửi vào S3 hoặc CloudWatch Logs.

---

## 6. Container & K8s Security (chỉ áp dụng nếu CDO chọn K8s/EKS angle)

- Image scan rules.
- Image signing.
- Pod Security Standard profiles.
- NetworkPolicies.
- IRSA (IAM Roles for Service Accounts).

---

## 7. Compliance Touchpoints

| Standard | Relevant controls (capstone scope) |
|---|---|
| SOC2 Type II | |
| GDPR | |

---

## 8. Open Questions

- [ ] Q1: ...
- [ ] Q2: ...

## Related documents

- `02_infra_design.md`
- `04_deployment_design.md`
- `08_adrs.md`
