# Deployment & CI/CD Design - Task force 3 · CDO 1

<!-- Doc owner: <Nhóm CDO>
     Status: Draft (W11 T4) → Final (W11 T6 Pack #1) → Working (W12 T4 Pack #2)
     Word target: 1200-2000 từ
     Tier: Medium -->

## 1. IaC strategy

### 1.1 Tool choice

Nhóm sử dụng **Terraform** làm công cụ Infrastructure as Code chính để quản lý toàn bộ tài nguyên AWS và phần khởi tạo nền tảng Kubernetes.

Terraform chịu trách nhiệm tạo và cấu hình các thành phần sau:

- VPC, subnet công khai và subnet riêng tư;
- bảng định tuyến, Internet Gateway, NAT Gateway và VPC Endpoint;
- Amazon EKS và Managed Node Group nền;
- IAM Role, EKS Pod Identity hoặc IRSA;
- Karpenter và các quyền AWS cần thiết;
- Application Load Balancer;
- Amazon RDS PostgreSQL;
- Amazon DynamoDB;
- Amazon SQS và Dead-Letter Queue;
- Amazon Data Firehose;
- Amazon S3 với Object Lock;
- AWS KMS;
- AWS Secrets Manager;
- Amazon ECR;
- CloudWatch và các tài nguyên giám sát phía AWS.

Terraform được chọn thay vì AWS CloudFormation hoặc AWS CDK vì các lý do sau:

1. Nhóm đã có kinh nghiệm thực hành với Terraform, giúp giảm rủi ro học công cụ mới trong thời gian Capstone hai tuần.
2. Terraform có thể quản lý đồng thời tài nguyên AWS, Helm chart và tài nguyên khởi tạo Kubernetes.
3. Lệnh `terraform plan` cho phép nhóm xem trước thay đổi trước khi triển khai.
4. Cấu trúc module giúp tái sử dụng thành phần giữa các tenant và môi trường.
5. Terraform phù hợp với quy trình Pull Request trên GitHub Actions.

Tuy nhiên, Terraform không quản lý trực tiếp toàn bộ manifest ứng dụng sau khi nền tảng GitOps đã được khởi tạo. Quyền sở hữu tài nguyên được phân chia như sau:

| Nhóm tài nguyên                                              | Công cụ quản lý chính  |
| ------------------------------------------------------------ | ---------------------- |
| Hạ tầng AWS                                                  | Terraform              |
| EKS, IAM và Managed Node Group nền                           | Terraform              |
| Cài đặt ban đầu của ArgoCD, Argo Workflows, Karpenter và ESO | Terraform kết hợp Helm |
| Manifest của Self-Heal Controller                            | Git và ArgoCD          |
| WorkflowTemplate                                             | Git và ArgoCD          |
| Manifest workload của tenant                                 | Git và ArgoCD          |
| Thay đổi desired state khi self-heal                         | Git và ArgoCD          |

Việc phân chia này tránh tình trạng Terraform và ArgoCD cùng quản lý một tài nguyên Kubernetes, dẫn đến xung đột trạng thái hoặc liên tục ghi đè lẫn nhau.

#### Xác thực từ GitHub Actions tới AWS

GitHub Actions sử dụng **OpenID Connect** để lấy thông tin xác thực AWS có thời hạn ngắn thông qua IAM Role.

Không lưu các giá trị sau trong repository hoặc GitHub Secrets:

- AWS Access Key ID dài hạn;
- AWS Secret Access Key dài hạn;
- kubeconfig tĩnh;
- mật khẩu cơ sở dữ liệu;
- Git deploy key dạng văn bản thuần.

Các workflow được tách quyền theo mục đích:

| IAM Role                     | Phạm vi quyền                                                          |
| ---------------------------- | ---------------------------------------------------------------------- |
| `github-pr-validation-role`  | Đọc metadata cần thiết để validate và tạo Terraform plan               |
| `github-sandbox-deploy-role` | Triển khai tài nguyên vào môi trường sandbox sau khi được phê duyệt    |
| `github-ecr-publish-role`    | Build và push image vào đúng ECR repository                            |
| `github-audit-test-role`     | Ghi bản ghi kiểm thử vào audit prefix, không có quyền xóa audit object |

Các IAM Role phải giới hạn theo repository, branch và GitHub Environment tương ứng.

### 1.2 Module structure

Mã nguồn hạ tầng được tách thành bốn lớp:

1. **Bootstrap:** tạo nơi lưu Terraform state và quyền triển khai từ GitHub.
2. **Foundation:** tạo hạ tầng AWS và EKS.
3. **Platform:** cài các controller và add-on vào EKS.
4. **Tenant bootstrap:** tạo tài nguyên Kubernetes riêng cho từng tenant.

Cấu trúc đề xuất:

```text
infra/
├── bootstrap/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── providers.tf
│
├── modules/
│   ├── networking/
│   │   ├── vpc.tf
│   │   ├── subnets.tf
│   │   ├── route-tables.tf
│   │   ├── nat-gateway.tf
│   │   ├── vpc-endpoints.tf
│   │   └── security-groups.tf
│   │
│   ├── eks/
│   │   ├── cluster.tf
│   │   ├── managed-node-group.tf
│   │   ├── access-entries.tf
│   │   └── pod-identity.tf
│   │
│   ├── karpenter/
│   │   ├── controller.tf
│   │   ├── nodepool.tf
│   │   └── ec2nodeclass.tf
│   │
│   ├── ingress/
│   │   ├── load-balancer-controller.tf
│   │   └── internal-alb.tf
│   │
│   ├── data/
│   │   ├── rds.tf
│   │   └── dynamodb.tf
│   │
│   ├── messaging/
│   │   ├── sqs.tf
│   │   └── dead-letter-queue.tf
│   │
│   ├── audit/
│   │   ├── firehose.tf
│   │   ├── s3-object-lock.tf
│   │   └── athena.tf
│   │
│   ├── security/
│   │   ├── kms.tf
│   │   ├── secrets-manager.tf
│   │   ├── iam.tf
│   │   └── github-oidc.tf
│   │
│   ├── observability/
│   │   ├── cloudwatch.tf
│   │   └── alerting.tf
│   │
│   └── tenant-bootstrap/
│       ├── namespace.tf
│       ├── resource-quota.tf
│       ├── limit-range.tf
│       ├── rbac.tf
│       └── argocd-application.tf
│
├── environments/
│   └── sandbox/
│       ├── foundation/
│       │   ├── backend.tf
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── sandbox.tfvars
│       │
│       ├── platform/
│       │   ├── backend.tf
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── sandbox.tfvars
│       │
│       └── tenants/
│           ├── tenant-a/
│           └── tenant-b/
│
└── README.md
```

Các manifest do ArgoCD quản lý được đặt riêng:

```text
gitops/
├── platform/
│   ├── argocd/
│   ├── argo-workflows/
│   ├── karpenter/
│   ├── external-secrets/
│   ├── monitoring/
│   └── self-heal-controller/
│
└── tenants/
    ├── tenant-a/
    └── tenant-b/
```

#### Trách nhiệm của từng lớp

| Lớp               | Trách nhiệm                                                                                      |
| ----------------- | ------------------------------------------------------------------------------------------------ |
| `bootstrap`       | Tạo S3 bucket lưu state, KMS key và GitHub OIDC Role                                             |
| `foundation`      | Tạo VPC, EKS, Managed Node Group, RDS, DynamoDB, SQS, Firehose, S3, KMS và Secrets Manager       |
| `platform`        | Cài Karpenter, ArgoCD, Argo Workflows, External Secrets Operator và AWS Load Balancer Controller |
| `tenants`         | Tạo namespace, quota, RBAC và ArgoCD Application cho từng tenant                                 |
| `gitops/platform` | Lưu desired state của các thành phần nền tảng trong Kubernetes                                   |
| `gitops/tenants`  | Lưu manifest workload và cấu hình riêng của từng tenant                                          |

#### Phân chia năng lực node

EKS sử dụng mô hình kết hợp:

- **Managed Node Group dùng On-Demand:** chạy các controller quan trọng như Karpenter, ArgoCD, Argo Workflows Controller, External Secrets Operator và Self-Heal Receiver.
- **Node do Karpenter cấp phát:** chạy workload của tenant và các Workflow Pod ngắn hạn.
- **Spot capacity:** ưu tiên cho workload có thể bị gián đoạn.
- **On-Demand capacity:** dùng cho thành phần nền tảng hoặc workload không chấp nhận Spot interruption.

Karpenter sử dụng `NodePool` để định nghĩa yêu cầu scheduling và `EC2NodeClass` để định nghĩa cấu hình hạ tầng AWS, gồm subnet, security group, AMI, storage và IAM Role của node.

Cách tổ chức này tránh để Karpenter Controller phụ thuộc hoàn toàn vào chính các node động mà nó chịu trách nhiệm tạo và thu hồi.

### 1.3 State management

Terraform state được lưu từ xa trong một Amazon S3 bucket riêng do lớp `bootstrap` tạo.

Cấu hình bắt buộc của state bucket:

- bật S3 Versioning;
- bật Block Public Access;
- mã hóa bằng AWS KMS;
- từ chối request không sử dụng TLS;
- chỉ cho phép các IAM Role đã được phê duyệt truy cập;
- không cho phép developer truy cập công khai;
- bật cơ chế khóa state bằng S3 lockfile.

Ví dụ cấu hình backend:

```hcl
terraform {
  backend "s3" {
    bucket       = "tf3-cdo1-terraform-state"
    key          = "sandbox/foundation/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

Tên bucket và region trong ví dụ phải được thay bằng giá trị thực tế của sandbox khi triển khai.

#### Tách state theo phạm vi

Không lưu toàn bộ nền tảng trong một state duy nhất. State được tách như sau:

```text
sandbox/bootstrap/terraform.tfstate
sandbox/foundation/terraform.tfstate
sandbox/platform/terraform.tfstate
sandbox/tenants/tenant-a/terraform.tfstate
sandbox/tenants/tenant-b/terraform.tfstate
```

Lợi ích của việc tách state:

1. Giảm phạm vi ảnh hưởng nếu một lần apply thất bại.
2. Thay đổi tenant không yêu cầu khóa toàn bộ state nền tảng.
3. Giảm nguy cơ vô tình thay thế EKS hoặc RDS khi chỉ sửa manifest tenant.
4. Cho phép phân quyền IAM riêng theo từng phạm vi.
5. Giúp kế hoạch Terraform dễ review hơn.

#### Phân biệt Terraform lock và incident lock

Hệ thống có hai loại khóa khác nhau:

| Loại khóa               | Công nghệ                         | Mục đích                                        |
| ----------------------- | --------------------------------- | ----------------------------------------------- |
| Terraform state lock    | S3 lockfile                       | Ngăn hai tiến trình Terraform cùng sửa state    |
| Incident execution lock | DynamoDB conditional write và TTL | Ngăn hai remediation cùng tác động một workload |

DynamoDB trong kiến trúc Self-Heal không được dùng làm Terraform state lock. Bảng DynamoDB chỉ lưu:

- `incident_id`;
- trạng thái vòng đời incident;
- idempotency key;
- resource lock;
- thời điểm hết hạn khóa;
- số lần thử;
- trạng thái circuit breaker nếu được triển khai.

#### Quy trình thay đổi Terraform

Mọi thay đổi hạ tầng phải đi qua Pull Request:

```text
Mở Pull Request
→ terraform fmt -check
→ terraform init
→ terraform validate
→ quét cấu hình
→ terraform plan
→ review plan
→ merge
→ tạo lại plan từ nhánh main
→ phê duyệt môi trường sandbox
→ terraform apply
→ kiểm tra sau triển khai
```

Các thay đổi sau bắt buộc phải có reviewer phê duyệt thủ công:

- xóa hoặc thay thế EKS cluster;
- xóa hoặc thay thế RDS;
- thay đổi route table hoặc NAT Gateway;
- mở rộng quyền IAM;
- thay đổi KMS key policy;
- thay đổi cấu hình S3 Object Lock;
- xóa namespace tenant;
- thay đổi quyền của Self-Heal ServiceAccount;
- thay đổi cấu hình Karpenter có thể tạo số lượng node lớn.

Các quy tắc quản lý state:

1. Không chạy `terraform apply` trực tiếp từ máy cá nhân trong quy trình thông thường.
2. Không chỉnh sửa Terraform state bằng tay.
3. Không sử dụng `terraform state rm` hoặc `terraform import` nếu chưa có kế hoạch và reviewer phê duyệt.
4. Tệp `.terraform.lock.hcl` phải được commit vào Git.
5. Không in sensitive output vào log của GitHub Actions.
6. Không lưu secret thật trong `tfvars`.
7. Không áp dụng lại một Terraform plan đã cũ sau khi nhánh `main` thay đổi.
8. Sau khi merge, pipeline phải tạo lại plan và apply đúng plan đã được lưu.
9. Mỗi root module sử dụng một state key riêng.
10. Output giữa các root chỉ xuất các giá trị cần thiết như cluster name, subnet ID, security group ID và KMS key ARN.

---

## 2. CI/CD pipeline

Hệ thống sử dụng **GitHub Actions** cho Continuous Integration, **Amazon ECR** làm nơi lưu container image, **Terraform** để triển khai hạ tầng AWS và **ArgoCD** để triển khai các tài nguyên Kubernetes từ Git.

Pipeline tách biệt ba nhóm thay đổi:

1. **Application code:** mã nguồn FastAPI Receiver, SQS Worker, Direct Patch Engine, policy check và audit client.
2. **Infrastructure code:** Terraform trong thư mục `infra/`.
3. **GitOps configuration:** manifest Kubernetes, ArgoCD Application và Argo `WorkflowTemplate` trong thư mục `gitops/`.

Mã nguồn của Receiver, Worker và Direct Patch Engine nằm trong cùng một codebase và được đóng gói thành một container image. Khi triển khai, image này chạy theo hai chế độ:

- `receiver`: nhận alert HTTP, kiểm tra định dạng và quan hệ `tenant_id` với namespace, sau đó gửi message vào SQS;
- `worker`: long-poll SQS, gọi AI Engine, kiểm tra idempotency/circuit breaker, chụp pre-state và chọn Direct Patch hoặc tạo Argo `Workflow`.

Việc tách thành hai Deployment cho phép Receiver và Worker scale độc lập. Receiver không bị giữ kết nối lâu trong lúc remediation đang chạy, còn message trong SQS vẫn được giữ lại nếu Worker tạm thời restart.

### 2.1 Pipeline stages

```text
PR opened
    │
    ▼
Detect changed paths
    │
    ├── controller/** ──► Lint ─► Test ─► Build ─► Image scan
    ├── infra/**      ──► Format ─► Validate ─► IaC scan ─► Terraform plan
    └── gitops/**     ──► Render ─► Manifest validation ─► Argo lint
    │
    ▼
Required checks + reviewer approval
    │
    ▼
Merge to main
    │
    ├── Controller changed ──► Build once ─► Push ECR ─► Update image digest PR
    ├── Infrastructure changed ──► Re-plan ─► Approval ─► Terraform apply
    └── GitOps changed ──► ArgoCD auto-sync
    │
    ▼
Smoke test
    │
    ▼
Release evidence
```

| Stage                  | Tool                                                    | What it does                                                                                                                                   | Quality gate                                                                                          |
| ---------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Change detection       | GitHub Actions `paths` filters                          | Xác định thay đổi thuộc controller, Terraform, GitOps hay tài liệu để chỉ chạy các job cần thiết                                               | Job tổng hợp `ci-summary` luôn chạy và chỉ thành công khi toàn bộ job liên quan đã thành công         |
| Lint                   | Ruff                                                    | Kiểm tra cú pháp, import, format và quy tắc code của FastAPI Receiver, Worker và Direct Patch Engine                                           | Không có lint error                                                                                   |
| Test                   | Pytest                                                  | Chạy unit test và contract test cho alert schema, tenant validation, SQS message, action mapping, policy, idempotency, rollback và audit event | Tất cả test pass; mục tiêu line coverage tối thiểu 70%; các nhánh policy và rollback bắt buộc có test |
| Build                  | Docker Buildx                                           | Build một container image dùng chung cho Receiver và Worker                                                                                    | Build thành công; image chạy được bằng non-root user                                                  |
| Secret scan            | Gitleaks                                                | Phát hiện access key, token, private key và secret bị commit nhầm                                                                              | Không phát hiện secret chưa được xử lý                                                                |
| Image scan             | Trivy                                                   | Quét lỗ hổng trong OS package và Python dependency của container image                                                                         | Không có CRITICAL vulnerability; HIGH chỉ được chấp nhận khi có exception, owner và ngày hết hạn      |
| IaC format             | `terraform fmt -check`                                  | Kiểm tra định dạng Terraform                                                                                                                   | Không có formatting diff                                                                              |
| IaC validation         | `terraform init -backend=false` và `terraform validate` | Kiểm tra cú pháp, provider và module contract mà không thay đổi hạ tầng                                                                        | Tất cả module hợp lệ                                                                                  |
| IaC security scan      | Trivy configuration scan                                | Kiểm tra security misconfiguration trong Terraform                                                                                             | Không có CRITICAL finding; HIGH phải được review                                                      |
| Plan                   | `terraform plan -detailed-exitcode`                     | Tạo kế hoạch thay đổi cho đúng root module bị ảnh hưởng                                                                                        | Không có thay đổi `destroy` hoặc `replace` ngoài phạm vi PR; reviewer xác nhận plan                   |
| GitOps render          | `helm lint` và `helm template`                          | Kiểm tra chart và render manifest trước khi merge                                                                                              | Không có lỗi render hoặc giá trị bắt buộc bị thiếu                                                    |
| Argo validation        | `argo lint`                                             | Kiểm tra `Workflow` và `WorkflowTemplate`                                                                                                      | Không có lỗi schema hoặc tham chiếu template                                                          |
| Kubernetes validation  | `kubectl apply --dry-run=server`                        | Gửi manifest tới API server và admission chain nhưng không lưu resource                                                                        | Không có lỗi schema, RBAC hoặc admission policy                                                       |
| Review                 | GitHub Pull Request + CODEOWNERS                        | Review code, Terraform plan, manifest diff và exception bảo mật                                                                                | Required checks pass và có tối thiểu một approval                                                     |
| Publish                | GitHub Actions + Amazon ECR                             | Build lại từ commit đã merge và push image bất biến                                                                                            | Image được gắn tag `sha-<commit>`; không dùng `latest` trong manifest                                 |
| Promote image          | Automated GitHub Pull Request                           | Cập nhật image digest trong GitOps manifest                                                                                                    | PR promotion phải vượt qua manifest validation trước khi merge                                        |
| Infrastructure apply   | Terraform                                               | Tạo lại plan từ `main`, chờ approval rồi apply đúng saved plan                                                                                 | Apply thành công; không bỏ qua approval cho thay đổi có blast radius lớn                              |
| Kubernetes deployment  | ArgoCD                                                  | Phát hiện thay đổi trong Git và reconcile xuống EKS                                                                                            | Application đạt `Synced` và `Healthy`                                                                 |
| Smoke test             | Pytest, curl, kubectl và Argo CLI                       | Kiểm tra endpoint, controller, queue, lock, workflow và audit path                                                                             | Tất cả kiểm tra bắt buộc thành công                                                                   |
| End-to-end remediation | Manual release workflow                                 | Inject một known pattern và kiểm tra toàn bộ detect → decide → execute → verify → audit                                                        | Action đúng tenant, đúng allowlist, verify thành công và có audit object                              |

#### Pull Request pipeline

Pull Request chỉ thực hiện kiểm tra và tạo bằng chứng review. Pipeline PR không được triển khai workload mới hoặc chạy `terraform apply`.

Các job được chạy theo phạm vi thay đổi:

##### Thay đổi trong `controller/`

```text
Ruff
→ Pytest
→ Docker build
→ Gitleaks
→ Trivy image scan
```

Bộ test tối thiểu phải bao gồm:

- alert thiếu `tenant_id` bị từ chối;
- `tenant_id` không khớp namespace trả về `403 TENANT_NAMESPACE_MISMATCH`;
- cùng một idempotency key không tạo hai remediation;
- circuit breaker đang mở thì không execute;
- action ngoài allowlist bị từ chối;
- Direct Patch không thể tác động namespace ngoài tenant;
- audit event có đầy đủ `correlation_id`, `pre_state` và execution result;
- khi AI Engine lỗi, incident chuyển sang retry hoặc escalation theo policy;
- khi GitOps path được chọn, Worker tạo đúng Argo `Workflow` từ `WorkflowTemplate`.

##### Thay đổi trong `infra/`

```text
terraform fmt -check
→ terraform init -backend=false
→ terraform validate
→ Trivy configuration scan
→ terraform plan
```

Terraform plan phải được tạo riêng cho root bị ảnh hưởng:

- `sandbox/foundation`;
- `sandbox/platform`;
- hoặc `sandbox/tenants/<tenant-id>`.

PR phải hiển thị rõ:

- số resource được thêm, thay đổi và xóa;
- resource bị `replace`;
- thay đổi IAM policy;
- thay đổi Security Group hoặc route;
- thay đổi RDS;
- thay đổi S3 Object Lock;
- thay đổi Karpenter `NodePool` hoặc `EC2NodeClass`.

##### Thay đổi trong `gitops/`

```text
helm lint
→ helm template
→ argo lint
→ kubectl apply --dry-run=server
→ manifest diff
```

Pipeline không dùng `kubectl apply` thật để triển khai ứng dụng. Git là nguồn desired state và ArgoCD là thành phần duy nhất chịu trách nhiệm reconcile các manifest GitOps xuống EKS.

#### Merge and deployment pipeline

Sau khi PR được merge vào `main`, pipeline xử lý theo loại thay đổi.

##### Controller code

1. Build image một lần từ commit đã merge.
2. Chạy Trivy trên image cuối cùng.
3. Push image vào ECR riêng của CDO-1.
4. Gắn tag bất biến theo commit SHA.
5. Lấy image digest từ ECR.
6. Tạo Pull Request cập nhật digest trong manifest Receiver và Worker.
7. Sau khi PR promotion được merge, ArgoCD triển khai image mới.

Ví dụ image reference:

```yaml
image: <account-id>.dkr.ecr.<region>.amazonaws.com/self-heal-controller@sha256:<digest>
```

Không sử dụng:

```yaml
image: <repository>/self-heal-controller:latest
```

Cơ chế promotion bằng Pull Request giữ được lịch sử ai đã đưa image nào vào cluster và cho phép rollback bằng Git revert.

##### Infrastructure code

1. Pipeline dùng GitHub OIDC để assume `github-sandbox-deploy-role`.
2. Chạy lại `terraform plan` từ revision hiện tại của `main`.
3. Lưu plan dưới dạng artifact có thời hạn ngắn.
4. Chờ approval qua GitHub Environment `sandbox`.
5. Apply đúng saved plan.
6. Chạy kiểm tra hạ tầng sau apply.

Các thay đổi sau không được tự động apply nếu chưa có approval:

- xóa hoặc thay thế EKS;
- xóa hoặc thay thế RDS;
- mở rộng quyền IAM;
- thay đổi KMS key policy;
- thay đổi S3 Object Lock;
- thay đổi network route;
- tăng Karpenter limit;
- xóa namespace hoặc ArgoCD Application của tenant.

##### GitOps configuration

Khi thay đổi manifest được merge vào `main`:

1. ArgoCD phát hiện Git revision mới.
2. ArgoCD render desired state.
3. ArgoCD apply resource theo sync wave.
4. Pipeline theo dõi trạng thái `Synced` và `Healthy`.
5. Nếu health check không đạt trong timeout, release được đánh dấu thất bại và Git commit phải được revert.

CI không cần quyền gọi trực tiếp ArgoCD API để deploy nếu auto-sync đã bật. Deployment được kích hoạt bằng thay đổi đã review trong Git.

#### Smoke tests

Sau mỗi lần triển khai, pipeline kiểm tra tối thiểu:

```text
1. Receiver /healthz trả về HTTP 200
2. Receiver /readyz trả về HTTP 200
3. Receiver gửi được alert canary vào SQS
4. Worker nhận và xác nhận message canary
5. DynamoDB tạo và giải phóng idempotency lock thành công
6. Worker kết nối được tới AI Engine endpoint
7. Argo Workflows controller ở trạng thái Available
8. WorkflowTemplate bắt buộc tồn tại và lint hợp lệ
9. ArgoCD Application đạt Synced và Healthy
10. Karpenter NodePool và EC2NodeClass ở trạng thái Ready
11. External Secrets Operator đồng bộ được secret thử nghiệm
12. Data Firehose ở trạng thái ACTIVE
13. Audit canary event xuất hiện trong đúng S3 prefix
```

Smoke test không thực hiện action phá hoại workload thật. Full remediation test chỉ chạy trong manual release workflow hoặc buổi kiểm thử E2E có kiểm soát.

#### End-to-end release test

Manual release workflow inject ít nhất một pattern khẩn cấp và một pattern deferred:

```text
Urgent:
AlertManager
→ ALB
→ Receiver
→ SQS
→ Worker
→ AI /detect và /decide
→ Safety check + pre-state
→ Direct Patch
→ AI /verify
→ Audit

Deferred:
AlertManager
→ ALB
→ Receiver
→ SQS
→ Worker
→ AI /detect và /decide
→ Safety check + pre-state
→ Create Workflow CR
→ Argo Workflows
→ Git commit
→ ArgoCD sync
→ AI /verify
→ Audit
```

Bài kiểm thử phải xác nhận remediation chỉ tác động đúng namespace của tenant. Ví dụ, incident của `tnt-payment-demo` không được thay đổi resource thuộc `tenant-checkout`.

### 2.2 Branch strategy

Nhóm sử dụng mô hình phát triển gần với trunk-based development để phù hợp với team nhỏ, một môi trường sandbox và thời gian Capstone hai tuần.

Các branch được sử dụng:

| Branch pattern                   | Mục đích                                                                         |
| -------------------------------- | -------------------------------------------------------------------------------- |
| `main`                           | Trạng thái đã qua review, có thể triển khai vào sandbox và là nguồn GitOps chính |
| `feature/<ticket>-<description>` | Phát triển tính năng                                                             |
| `fix/<ticket>-<description>`     | Sửa lỗi                                                                          |
| `docs/<description>`             | Cập nhật tài liệu                                                                |
| `hotfix/<description>`           | Sửa lỗi khẩn cấp nhưng vẫn phải qua Pull Request                                 |
| `release/image-<sha>`            | Branch tự động cập nhật image digest sau khi image được push vào ECR             |

Không sử dụng branch `develop` trong phạm vi Capstone vì nhóm chỉ có một môi trường sandbox được triển khai thật. Việc duy trì thêm `develop` sẽ tạo thêm một điểm đồng bộ và tăng nguy cơ lệch branch mà không có staging environment riêng để tận dụng.

#### Protection rules for `main`

`main` được bảo vệ bằng GitHub Ruleset:

- cấm direct push;
- cấm force push;
- bắt buộc Pull Request;
- yêu cầu tối thiểu một approval;
- yêu cầu toàn bộ required status checks thành công;
- yêu cầu resolve toàn bộ review conversation;
- yêu cầu branch cập nhật với `main` trước khi merge;
- yêu cầu CODEOWNER approval cho đường dẫn nhạy cảm;
- sử dụng squash merge;
- tự động xóa source branch sau khi merge.

Các đường dẫn cần CODEOWNER approval:

```text
infra/**
gitops/platform/**
gitops/tenants/**
controller/policy/**
controller/executors/**
.github/workflows/**
```

#### Required checks

Required checks tối thiểu:

```text
ci-summary
controller-lint
controller-test
secret-scan
image-scan
terraform-validate
terraform-security
terraform-plan
gitops-render
argo-lint
manifest-validation
```

`ci-summary` phải luôn chạy, kể cả khi một số job được bỏ qua do không liên quan đến đường dẫn thay đổi. Cách này tránh trường hợp Pull Request bị treo vì một required workflow bị path filter bỏ qua.

#### Merge policy

- Chỉ merge khi tất cả required checks thành công.
- Không merge Terraform PR khi chưa đọc plan.
- Không merge thay đổi IAM hoặc network nếu không có mô tả blast radius.
- Không merge manifest sử dụng image tag `latest`.
- Không merge secret, private key hoặc kubeconfig vào repository.
- Không merge `WorkflowTemplate` mới nếu chưa có `argo lint` và test với tham số mẫu.
- Không merge action enum mới nếu chưa cập nhật action executor map, policy allowlist, rollback rule và audit schema.
- Một PR nên tập trung vào một mục tiêu; không trộn thay đổi hạ tầng lớn với thay đổi business logic không liên quan.

#### Repository choice

GitHub tiếp tục được sử dụng làm Git source of truth vì repository, Pull Request workflow và GitHub Actions của nhóm đã được thiết lập trên GitHub. Việc giữ GitHub tránh migration không cần thiết trong thời gian Capstone và cho phép dùng chung một quy trình review cho code, Terraform và GitOps manifest.

---

## 3. GitOps

### 3.1 Tool

Nhóm sử dụng **ArgoCD** làm công cụ GitOps để đồng bộ desired state từ GitHub xuống Amazon EKS.

ArgoCD được chọn vì các lý do sau:

- hỗ trợ tự động phát hiện khác biệt giữa manifest trong Git và trạng thái đang chạy trong cluster;
- hiển thị trực quan trạng thái `Synced`, `OutOfSync`, `Healthy` và `Degraded`;
- hỗ trợ Helm, Kustomize và manifest Kubernetes thuần;
- hỗ trợ sync wave, hook và health assessment;
- cho phép giới hạn repository, cluster và namespace bằng `AppProject`;
- phù hợp với mô hình một ArgoCD Application cho mỗi tenant;
- CI/CD chỉ cần commit vào Git, không cần giữ quyền triển khai trực tiếp vào Kubernetes API.

Terraform kết hợp Helm chỉ thực hiện bước bootstrap cho các controller nền tảng:

- ArgoCD;
- Argo Workflows;
- Argo Rollouts;
- Karpenter;
- AWS Load Balancer Controller;
- External Secrets Operator.

Sau khi các controller và CRD tương ứng đã sẵn sàng, ArgoCD quản lý các tài nguyên có vòng đời thay đổi thường xuyên:

- FastAPI Receiver;
- SQS Worker và Direct Patch Engine;
- Service, Ingress và cấu hình triển khai của Self-Heal Engine;
- Argo `WorkflowTemplate`;
- Argo Rollouts `AnalysisTemplate`;
- Prometheus rule và Alertmanager configuration;
- namespace policy và workload của tenant;
- ArgoCD Application của từng tenant.

Cách phân chia này giải quyết bài toán bootstrap: Terraform tạo ArgoCD trước, sau đó ArgoCD mới tiếp quản desired state của ứng dụng. Terraform và ArgoCD không được đồng thời quản lý cùng một Kubernetes resource.

#### Repo structure

Trong phạm vi Capstone, nhóm sử dụng một GitHub repository với các thư mục tách biệt thay vì duy trì hai repository độc lập. Cách này giảm số lượng deploy key, webhook và quy trình review phải quản lý trong thời gian hai tuần, nhưng vẫn tách rõ code, hạ tầng và desired state.

```text
controller/
├── app/
│   ├── receiver/
│   ├── worker/
│   ├── executors/
│   ├── policy/
│   └── audit/
├── tests/
├── Dockerfile
└── pyproject.toml

infra/
├── bootstrap/
├── modules/
└── environments/
    └── sandbox/

gitops/
├── bootstrap/
│   └── root-application.yaml
│
├── platform/
│   ├── self-heal-controller/
│   │   ├── receiver/
│   │   ├── worker/
│   │   ├── services/
│   │   └── ingress/
│   ├── workflow-templates/
│   ├── analysis-templates/
│   ├── monitoring/
│   └── external-secrets/
│
└── tenants/
    ├── tenant-payment/
    │   ├── application.yaml
    │   ├── namespace/
    │   └── workloads/
    └── tenant-checkout/
        ├── application.yaml
        ├── namespace/
        └── workloads/
```

`root-application.yaml` là ArgoCD Application gốc. Application này tham chiếu tới các Application con của platform và tenant. Terraform chỉ tạo ArgoCD và apply Application gốc lần đầu; các lần thay đổi tiếp theo được thực hiện qua Git.

#### Application ownership

| ArgoCD Application    | Namespace đích     | Nội dung quản lý                                                      |
| --------------------- | ------------------ | --------------------------------------------------------------------- |
| `self-heal-platform`  | `self-heal-system` | Receiver, Worker, Service, Ingress, ConfigMap và policy configuration |
| `self-heal-workflows` | `argo`             | `WorkflowTemplate` cho deferred remediation                           |
| `self-heal-analysis`  | `self-heal-system` | `AnalysisTemplate` dùng cho canary                                    |
| `monitoring`          | `observability`    | Prometheus, Grafana, Alertmanager rule và dashboard                   |
| `tenant-payment`      | `tenant-payment`   | Workload và policy của tenant payment                                 |
| `tenant-checkout`     | `tenant-checkout`  | Workload và policy của tenant checkout                                |

Mỗi tenant sử dụng một `AppProject` hoặc một nhóm rule tương đương để giới hạn:

- repository được phép đọc;
- namespace đích;
- loại tài nguyên được phép tạo;
- không cho tenant Application triển khai vào `kube-system`, `argocd`, `argo` hoặc `self-heal-system`;
- không cho tenant tạo hoặc sửa `ClusterRole`, `ClusterRoleBinding` và tài nguyên cluster-scoped ngoài allowlist.

#### GitOps flow

Luồng triển khai ứng dụng thông thường:

```text
Pull Request
→ Review
→ Merge vào main
→ GitHub webhook thông báo repository thay đổi
→ ArgoCD refresh
→ So sánh desired state và live state
→ Sync theo wave
→ Health assessment
→ PostSync smoke test
```

Luồng deferred remediation:

```text
Worker nhận AI decision
→ Tạo Argo Workflow từ WorkflowTemplate
→ Workflow cập nhật manifest trong Git
→ Commit kèm correlation_id và incident_id
→ Push GitHub
→ ArgoCD phát hiện revision mới
→ Sync tenant Application
→ Worker/Workflow kiểm tra Synced + Healthy
→ Thu thập post-state
→ Gọi AI /verify
→ Ghi audit
```

Commit do remediation tạo phải chứa tối thiểu:

```text
incident_id
correlation_id
tenant_id
action enum
resource target
giá trị trước thay đổi
giá trị sau thay đổi
```

Ví dụ commit message:

```text
fix(tenant-payment): increase order-service memory limit

Incident: inc-20260625-001
Correlation: corr-8f8c...
Action: ADJUST_MEMORY_LIMIT
Target: deployment/order-service
```

### 3.2 Sync waves

Các controller và CRD của ArgoCD, Argo Workflows, Argo Rollouts, ESO và Karpenter được Terraform/Helm bootstrap trước. Vì vậy, sync wave của ArgoCD chỉ bắt đầu sau khi các CRD bắt buộc đã tồn tại.

Thứ tự triển khai được chốt như sau:

| Wave | Components                                                                  | Reason                                                          |
| ---: | --------------------------------------------------------------------------- | --------------------------------------------------------------- |
| `-4` | Namespace                                                                   | Namespace phải tồn tại trước tất cả tài nguyên namespace-scoped |
| `-3` | ResourceQuota, LimitRange, ServiceAccount, Role, RoleBinding, NetworkPolicy | Thiết lập giới hạn và quyền trước khi workload được tạo         |
| `-2` | ConfigMap, SecretStore, ExternalSecret                                      | Cung cấp cấu hình và secret trước khi Pod khởi động             |
| `-1` | Service, WorkflowTemplate, AnalysisTemplate, PrometheusRule                 | Tạo endpoint nội bộ và template mà workload sẽ tham chiếu       |
|  `0` | Receiver Rollout, Worker Deployment, tenant workload                        | Triển khai workload chính                                       |
|  `1` | Ingress và cấu hình ALB traffic routing                                     | Chỉ expose traffic sau khi Service và workload đã tồn tại       |
|  `2` | PostSync smoke-test Job                                                     | Kiểm tra sau khi toàn bộ tài nguyên đã Healthy                  |

Sync wave được khai báo bằng annotation:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
```

Smoke test sử dụng `PostSync` hook:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
```

`PostSync` chỉ chạy sau khi các tài nguyên trong lần sync đã được apply thành công và đạt trạng thái Healthy. Nếu smoke test thất bại, Application được đánh dấu lỗi và pipeline không được xem release là thành công.

RDS, DynamoDB, SQS, Data Firehose, S3, KMS và Secrets Manager không nằm trong sync wave vì đây là tài nguyên AWS do Terraform quản lý.

### 3.3 Drift detection

ArgoCD tự động so sánh desired state trong Git với trạng thái thực tế trong EKS.

Nhóm sử dụng hai chính sách khác nhau để phù hợp với kiến trúc Hybrid.

#### Platform applications

Các Application nền tảng không được Direct Patch Engine thay đổi trực tiếp:

```yaml
spec:
  syncPolicy:
    automated:
      enabled: true
      prune: false
      selfHeal: true
```

Áp dụng cho:

- Argo WorkflowTemplate;
- AnalysisTemplate;
- monitoring configuration;
- namespace policy;
- Self-Heal platform configuration không thuộc danh sách emergency patch.

`selfHeal: true` cho phép ArgoCD đưa live state về lại Git khi có thay đổi ngoài quy trình.

#### Tenant workload applications

Tenant workload có thể bị Direct Patch Engine tác động khi xảy ra incident khẩn cấp:

```yaml
spec:
  syncPolicy:
    automated:
      enabled: true
      prune: false
      selfHeal: false
```

Lý do không bật `selfHeal` cho nhóm tài nguyên này là tránh ArgoCD lập tức ghi đè hot patch trước khi hệ thống hoàn tất verify và ghi cùng thay đổi vào Git.

Quy tắc Hybrid:

- action tạm thời như restart hoặc xóa Pod không cần commit Git vì không làm thay đổi desired state;
- action thay đổi lâu dài như memory limit, CPU limit, replicas, HPA hoặc image phải được ghi vào Git;
- persistent hot patch phải được đồng bộ lên Git trong thời hạn tối đa 120 giây của sandbox;
- nếu Git push hoặc ArgoCD sync không thành công trong thời hạn này, Worker phải rollback về pre-state hoặc chuyển incident sang escalation;
- incident không được đánh dấu `DONE` khi cluster vẫn `OutOfSync` đối với persistent change.

Không sử dụng `ignoreDifferences` để che các field mà Self-Heal Engine chủ động thay đổi. Ngoại lệ chỉ dành cho field thực sự được controller khác quản lý, ví dụ `/spec/replicas` của Deployment do HPA sở hữu.

#### Prune policy

Automated prune được tắt mặc định:

```yaml
automated:
  prune: false
```

Lý do là thao tác xóa có blast radius lớn hơn thao tác cập nhật. Các resource quan trọng phải dùng xác nhận thủ công:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Prune=confirm
```

Áp dụng cho:

- Namespace;
- PersistentVolumeClaim;
- SecretStore;
- ExternalSecret;
- ServiceAccount;
- Role và RoleBinding;
- tenant Application;
- resource chứa dữ liệu hoặc ảnh hưởng quyền truy cập.

#### Drift alert and reporting

ArgoCD phải phát cảnh báo khi:

- Application chuyển sang `OutOfSync`;
- sync thất bại;
- Application ở trạng thái `Degraded`;
- tenant workload còn drift quá 120 giây;
- một persistent hot patch chưa được persist vào Git.

Thông báo gửi tới Slack phải chứa:

- Application;
- tenant;
- namespace;
- Git revision;
- resource bị drift;
- thời điểm bắt đầu drift;
- incident/correlation ID nếu drift do remediation;
- liên kết tới ArgoCD UI.

Ngoài cảnh báo tức thời, một CronWorkflow chạy mỗi ngày để tổng hợp các Application còn `OutOfSync`, `Unknown` hoặc `Degraded`. Báo cáo này phục vụ kiểm tra drift tồn đọng, không thay thế cảnh báo thời gian thực.

---

## 4. Deployment strategy

### 4.1 Strategy

Nhóm không sử dụng một chiến lược duy nhất cho mọi thành phần. Chiến lược được chọn theo cách thành phần nhận lưu lượng và mức độ rủi ro khi cập nhật.

| Component                                | Strategy                                           | Reason                                                                                                        |
| ---------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| FastAPI Receiver                         | Argo Rollouts Canary qua ALB                       | Receiver nhận HTTP alert nên có thể chia traffic chính xác giữa stable và canary target group                 |
| SQS Worker + Direct Patch Engine         | Kubernetes RollingUpdate                           | Worker nhận message từ SQS, không có HTTP traffic để ALB chia theo tỷ lệ; idempotency lock bảo vệ xử lý trùng |
| WorkflowTemplate và policy configuration | GitOps sync + validation                           | Đây là cấu hình, không phải workload nhận traffic; phải lint và test trước khi merge                          |
| ArgoCD, Argo Workflows, Karpenter, ESO   | Helm upgrade có approval                           | Đây là controller nền tảng; thay đổi cần kiểm soát riêng, không áp dụng canary ứng dụng                       |
| Tenant workload mẫu                      | RollingUpdate hoặc Argo Rollouts tùy kịch bản test | Không ép mọi workload dùng cùng một kiểu rollout                                                              |

#### Receiver canary

Receiver sử dụng Argo Rollouts kết hợp AWS Load Balancer Controller. ALB duy trì hai target group:

- stable Service;
- canary Service.

Tiến trình canary:

```text
10% traffic
→ quan sát 5 phút
→ 50% traffic
→ quan sát 10 phút
→ 100% traffic
```

Tổng thời gian quan sát trước khi promote hoàn toàn là 15 phút.

Cấu trúc Rollout:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: self-heal-receiver
  namespace: self-heal-system
spec:
  replicas: 3
  revisionHistoryLimit: 5
  progressDeadlineSeconds: 600
  rollbackWindow:
    revisions: 3
  strategy:
    canary:
      stableService: self-heal-receiver-stable
      canaryService: self-heal-receiver-canary
      trafficRouting:
        alb:
          ingress: self-heal-receiver
          servicePort: 80
      steps:
        - setWeight: 10
        - pause:
            duration: 5m
        - analysis:
            templates:
              - templateName: receiver-canary-analysis
        - setWeight: 50
        - pause:
            duration: 10m
        - analysis:
            templates:
              - templateName: receiver-canary-analysis
        - setWeight: 100
```

Các giá trị 10%, 50% và thời gian 15 phút là tham số triển khai của dự án, không phải benchmark mặc định của Argo Rollouts.

#### Receiver analysis

Argo Rollouts dùng `AnalysisTemplate` để truy vấn Prometheus.

Các điều kiện abort tạm thời của sandbox:

| Metric                       | Abort criteria                                                          | Measurement           |
| ---------------------------- | ----------------------------------------------------------------------- | --------------------- |
| HTTP 5xx rate                | Lớn hơn `1%`                                                            | Hai lần đo liên tiếp  |
| P99 request latency          | Lớn hơn `800 ms`                                                        | Hai lần đo liên tiếp  |
| Receiver readiness           | Có Pod canary không Ready                                               | Quá 60 giây           |
| SQS enqueue failure          | Có lỗi gửi message trong cửa sổ đo                                      | Một lần xác nhận      |
| Tenant validation regression | Tỷ lệ response 5xx tăng; response 4xx hợp lệ không tính là lỗi hệ thống | Theo Prometheus query |

Ngưỡng `1%` và `800 ms` là quality gate ban đầu từ template dự án. Chúng phải được thay bằng SLO được client xác nhận nếu contract cuối cùng đưa ra ngưỡng khác.

Nếu Prometheus không có đủ dữ liệu để kết luận, rollout không tự promote. Trạng thái được giữ ở bước hiện tại để người vận hành kiểm tra.

Ví dụ khung `AnalysisTemplate`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: receiver-canary-analysis
  namespace: self-heal-system
spec:
  metrics:
    - name: error-rate
      interval: 30s
      count: 2
      failureLimit: 1
      successCondition: result[0] <= 0.01
      provider:
        prometheus:
          address: http://prometheus-operated.observability.svc:9090
          query: |
            sum(rate(http_requests_total{
              app="self-heal-receiver",
              status=~"5.."
            }[2m]))
            /
            sum(rate(http_requests_total{
              app="self-heal-receiver"
            }[2m]))

    - name: p99-latency
      interval: 30s
      count: 2
      failureLimit: 1
      successCondition: result[0] <= 0.8
      provider:
        prometheus:
          address: http://prometheus-operated.observability.svc:9090
          query: |
            histogram_quantile(
              0.99,
              sum by (le) (
                rate(http_request_duration_seconds_bucket{
                  app="self-heal-receiver"
                }[2m])
              )
            )
```

Tên metric thực tế phải khớp với instrumentation của Receiver. PromQL phải được kiểm thử trên Prometheus trước khi dùng làm automated gate.

#### Worker RollingUpdate

Worker không nhận HTTP traffic. Dùng ALB canary cho Worker không có ý nghĩa vì message được lấy trực tiếp từ SQS.

Worker sử dụng:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 1
```

Yêu cầu đi kèm:

- tối thiểu hai Worker replica trong giai đoạn deployment test;
- graceful shutdown dừng nhận message mới trước khi Pod kết thúc;
- `terminationGracePeriodSeconds` đủ để hoàn thành hoặc trả message về queue;
- SQS visibility timeout phải dài hơn thời gian xử lý tối đa của một remediation;
- chỉ xóa message sau khi incident state đã được cập nhật an toàn;
- DynamoDB conditional lock ngăn Worker cũ và Worker mới cùng execute một incident;
- message xử lý thất bại vượt quá `maxReceiveCount` được chuyển vào DLQ.

Worker deployment bị đánh dấu thất bại khi:

- Pod mới không Ready;
- queue consumer không nhận được canary message;
- số message vào DLQ tăng sau rollout;
- duplicate execution xảy ra;
- Worker không ghi được incident state hoặc audit event.

#### Platform controller upgrades

Các controller nền tảng được nâng cấp bằng Pull Request thay đổi phiên bản Helm chart.

Quy trình:

```text
Update chart version
→ Render manifest
→ Review CRD/change log
→ Apply vào sandbox
→ Kiểm tra controller Ready
→ Kiểm tra CRD và webhook
→ Chạy smoke test
```

Không tự động nâng phiên bản major/minor của ArgoCD, Argo Workflows, Argo Rollouts, Karpenter hoặc ESO nếu chưa review compatibility và CRD migration.

### 4.2 Rollback method

Rollback được chia thành ba lớp để tránh nhầm lẫn giữa runtime state, Git desired state và Terraform state.

#### Application runtime rollback

Khi Receiver canary vi phạm AnalysisTemplate:

1. Argo Rollouts đánh dấu AnalysisRun thất bại.
2. Rollout bị abort.
3. ALB đưa traffic trở lại stable target group.
4. Canary ReplicaSet không được promote.
5. Alert được gửi tới Slack.
6. Release được đánh dấu thất bại.

Mục tiêu thiết kế là đưa toàn bộ traffic về stable version trong vòng dưới 60 giây kể từ khi analysis xác nhận thất bại. Đây là RTO thiết kế cần được kiểm chứng bằng test trong sandbox, không phải số liệu production đã đo.

`rollbackWindow.revisions: 3` giữ ba revision gần nhất trong cửa sổ rollback nhanh. `revisionHistoryLimit: 5` giữ đủ ReplicaSet phục vụ điều tra nhưng không để lịch sử tăng không giới hạn.

#### Git source-of-truth rollback

Runtime abort không tự thay đổi Git. Vì Git vẫn đang chứa image digest mới, nhóm phải đưa desired state trở lại revision ổn định.

Phương pháp chính:

```text
Rollout abort
→ Tạo Git revert cho commit cập nhật image digest
→ Review/merge
→ ArgoCD sync
→ Xác nhận Synced + Healthy
```

Không sửa image trực tiếp bằng `kubectl set image` trong quy trình thông thường.

Thông tin rollback phải được ghi vào audit:

- Git SHA lỗi;
- Git SHA ổn định;
- Rollout revision;
- AnalysisRun result;
- thời điểm abort;
- thời điểm Git revert;
- thời điểm ArgoCD trở lại `Synced` và `Healthy`.

#### Worker rollback

Nếu Worker RollingUpdate thất bại:

1. dừng rollout bằng cách không tiếp tục thay Pod cũ;
2. revert image digest trong Git;
3. ArgoCD apply lại image ổn định;
4. kiểm tra SQS consumer và DLQ;
5. release lock hết hạn hoặc bị kẹt;
6. replay canary message;
7. chỉ mở lại full processing khi smoke test pass.

Do SQS giữ message chưa được delete, Worker crash không được làm mất incident. Tuy nhiên, hệ thống phải chấp nhận khả năng message được giao lại và dựa vào idempotency key để tránh execute action lần hai.

#### Self-heal action rollback

Rollback của remediation khác rollback của deployment.

| Action type                       | Rollback method                                                                |
| --------------------------------- | ------------------------------------------------------------------------------ |
| Restart hoặc delete Pod           | Không có inverse action; Kubernetes controller tạo Pod thay thế, sau đó verify |
| Patch memory/CPU                  | Patch lại giá trị trong pre-state và revert Git nếu đã commit                  |
| Scale replicas                    | Khôi phục replica count trước action; không ghi đè field do HPA sở hữu         |
| Update image                      | Revert Git về image digest ổn định rồi ArgoCD sync                             |
| GitOps change                     | Git revert commit do Workflow tạo                                              |
| Workflow failure trước khi commit | Không thay đổi cluster; ghi audit và escalation                                |
| Workflow failure sau khi commit   | Revert commit, chờ ArgoCD sync, sau đó verify rollback                         |

Mọi persistent action phải lưu pre-state trước khi execute. Incident chỉ chuyển sang `ROLLED_BACK` khi:

- runtime state đã trở về giá trị trước action;
- ArgoCD đạt `Synced` nếu resource do Git quản lý;
- verification sau rollback thành công;
- audit event `ROLLBACK_RESULT` đã được gửi tới Data Firehose.

Nếu rollback thất bại, circuit breaker được mở cho workload tương ứng và incident chuyển sang `ESCALATED`.

#### Infrastructure rollback

Terraform state file không được dùng như một bản backup để rollback hạ tầng.

Phương pháp đúng:

```text
Revert Terraform code
→ terraform plan
→ Review
→ Apply một forward change
→ Smoke test
```

Không thực hiện:

```text
Khôi phục thủ công file terraform.tfstate cũ
```

Việc thay state file có thể làm Terraform hiểu sai tài nguyên thực tế và tạo thay đổi phá hủy ở lần apply tiếp theo.

Đối với thay đổi không thể rollback trực tiếp, ví dụ:

- RDS schema migration;
- xóa dữ liệu;
- thay đổi S3 Object Lock retention;
- thay đổi KMS key;
- xóa EKS cluster;

pipeline phải dừng ở manual approval và yêu cầu kế hoạch phục hồi riêng trước khi apply.

---

## 5. Environment separation

Trong phạm vi Capstone, nhóm chỉ triển khai thật một môi trường **sandbox**. `staging` và `production` được mô tả như kiến trúc mục tiêu để chứng minh khả năng mở rộng, không được xem là tài nguyên đã tồn tại.

Mỗi môi trường phải sử dụng:

- AWS account riêng;
- Amazon EKS cluster riêng;
- VPC và CIDR riêng;
- Terraform state riêng;
- KMS key riêng;
- S3 audit bucket riêng;
- RDS, DynamoDB, SQS và Data Firehose riêng;
- GitHub Environment và IAM deployment role riêng;
- ArgoCD project và cấu hình GitOps riêng.

Không sử dụng namespace để thay thế hoàn toàn cho việc tách môi trường. Namespace được dùng để cô lập tenant bên trong cùng một môi trường; sandbox và production không được chạy chung một EKS cluster.

| Env     | Purpose                                                                              | Account                                                    | Auto-deploy                                                                                                           |
| ------- | ------------------------------------------------------------------------------------ | ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Sandbox | Phát triển, thử nghiệm Self-Heal Engine, inject incident và kiểm tra hai tenant demo | AWS sandbox account của nhóm                               | Sau khi merge vào `main`, có GitHub Environment approval trước Terraform apply; GitOps manifest được ArgoCD auto-sync |
| Staging | Kiểm thử tích hợp gần production, kiểm tra migration, canary và rollback             | AWS staging account riêng — chưa triển khai trong Capstone | Theo release candidate hoặc version tag; yêu cầu approval                                                             |
| Prod    | Tiếp nhận tenant và workload thật                                                    | AWS production account riêng — ngoài phạm vi Capstone      | Không auto-deploy trực tiếp từ commit; bắt buộc approval, canary analysis và change record                            |

### 5.1 Environment-specific configuration

Cấu hình dùng chung được đặt trong Terraform module và Helm chart. Giá trị khác nhau theo môi trường được đặt trong root module hoặc values file riêng:

```text
infra/
└── environments/
    ├── sandbox/
    │   ├── foundation/
    │   ├── platform/
    │   └── tenants/
    ├── staging/          # Target design
    └── prod/             # Target design

gitops/
└── environments/
    ├── sandbox/
    ├── staging/          # Target design
    └── prod/             # Target design
```

Không dùng một `tfvars` duy nhất cho mọi môi trường. Các giá trị sau phải tách riêng:

- AWS account ID;
- region;
- VPC CIDR;
- EKS cluster name;
- instance capacity và Karpenter limit;
- domain và ALB certificate;
- RDS endpoint;
- DynamoDB table;
- SQS queue và DLQ;
- S3 audit bucket;
- KMS key;
- Secrets Manager prefix;
- tenant list;
- log retention;
- Object Lock retention;
- feature flag và dry-run mode.

Terraform state sử dụng key riêng theo môi trường:

```text
sandbox/foundation/terraform.tfstate
sandbox/platform/terraform.tfstate
staging/foundation/terraform.tfstate
staging/platform/terraform.tfstate
prod/foundation/terraform.tfstate
prod/platform/terraform.tfstate
```

### 5.2 GitHub deployment environments

GitHub Actions sử dụng ba GitHub Environment độc lập:

```text
sandbox
staging
production
```

Mỗi environment có:

- IAM Role được phép assume bằng GitHub OIDC;
- biến cấu hình không nhạy cảm;
- protection rule;
- required reviewer;
- deployment history riêng.

Quy tắc đề xuất:

| GitHub Environment | Protection                                                                                            |
| ------------------ | ----------------------------------------------------------------------------------------------------- |
| `sandbox`          | Tối thiểu một reviewer cho Terraform apply; có thể auto-sync GitOps sau merge                         |
| `staging`          | Tối thiểu một reviewer; chỉ chấp nhận release candidate hoặc version tag                              |
| `production`       | Tối thiểu hai người tham gia quy trình review; cấm người kích hoạt tự phê duyệt; bắt buộc canary gate |

Trong phạm vi Capstone, chỉ `sandbox` được cấu hình và sử dụng thật. Không tạo credential giả hoặc mô tả staging/production như đã vận hành.

### 5.3 Promotion between environments

Không copy manifest thủ công giữa các môi trường. Image được build một lần và promote bằng **image digest**:

```text
Build image
→ Scan
→ Push ECR
→ Ghi nhận sha256 digest
→ Sandbox dùng digest đó
→ Staging dùng lại cùng digest
→ Production dùng lại cùng digest
```

Không build lại image riêng cho production vì cùng một commit có thể tạo artifact khác nếu dependency hoặc base image thay đổi.

Promotion thay đổi duy nhất:

- GitOps overlay hoặc values của môi trường;
- environment-specific endpoint;
- replica và resource sizing;
- feature flag;
- secret reference.

Secret value không được copy từ sandbox sang staging hoặc production.

---

## 6. Secrets in pipeline

GitHub Actions không được giữ AWS Access Key hoặc Secret Access Key dài hạn. Workflow sử dụng GitHub OIDC để assume IAM Role có thời hạn ngắn cho đúng environment.

Application secret được lưu trong **AWS Secrets Manager** và được **External Secrets Operator** đồng bộ vào Kubernetes Secret. Git chỉ lưu `ExternalSecret`, `SecretStore` và tên/ARN tham chiếu; Git không chứa giá trị secret.

### 6.1 Secret ownership

| Secret                           | Storage                                                                                                 | Consumer                                       | Deployment method                                               |
| -------------------------------- | ------------------------------------------------------------------------------------------------------- | ---------------------------------------------- | --------------------------------------------------------------- |
| Git credential đọc repository    | AWS Secrets Manager                                                                                     | ArgoCD repo-server                             | ESO đồng bộ vào namespace `argocd`                              |
| Git credential ghi repository    | AWS Secrets Manager                                                                                     | Argo Workflow thực hiện persistent remediation | ESO đồng bộ vào namespace `argo`; tách quyền với credential đọc |
| RDS credentials                  | AWS Secrets Manager                                                                                     | Thành phần cần truy cập PostgreSQL             | ESO đồng bộ vào namespace được phép                             |
| Slack webhook URL                | AWS Secrets Manager                                                                                     | Worker hoặc escalation step                    | ESO đồng bộ vào `self-heal-system`                              |
| ArgoCD administrative credential | Kubernetes Secret do quy trình bootstrap quản lý hoặc Secrets Manager nếu nhóm chốt external management | Quản trị ArgoCD                                | Không đưa vào Git dưới dạng plaintext                           |
| AI authentication configuration  | Theo deployment contract; nếu dùng AWS SigV4 thì dùng IAM Role thay vì API key                          | Receiver/Worker gọi AI Engine                  | EKS Pod Identity hoặc IRSA                                      |

Tài liệu chi phí hiện giả định có sáu secret nhưng mới xác định chắc chắn một phần danh sách. Hai secret chưa được chốt không được tự đặt tên để khớp số lượng. Nhóm phải cập nhật inventory và cost model sau khi AI authentication, Git write credential và ArgoCD bootstrap method được quyết định cuối cùng.

### 6.2 SecretStore model

Dùng `SecretStore` theo namespace thay vì cấp một `ClusterSecretStore` rộng cho mọi tenant.

Ví dụ:

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: self-heal-secrets
  namespace: self-heal-system
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-southeast-1
      auth:
        jwt:
          serviceAccountRef:
            name: selfheal-executor
```

Mỗi namespace chỉ được đọc secret dưới prefix được cấp:

```text
tf-3/cdo/sandbox/self-heal/*
tf-3/cdo/sandbox/argocd/*
tf-3/cdo/sandbox/argo/*
tf-3/cdo/sandbox/tenants/tnt-payment-demo/*
tf-3/cdo/sandbox/tenants/tnt-checkout-demo/*
```

IAM policy của ESO hoặc ServiceAccount phải giới hạn theo ARN prefix, không dùng:

```text
Resource: "*"
```

Ví dụ `ExternalSecret`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: self-heal-runtime
  namespace: self-heal-system
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: self-heal-secrets
    kind: SecretStore
  target:
    name: self-heal-runtime
    creationPolicy: Owner
  data:
    - secretKey: slack-webhook-url
      remoteRef:
        key: tf-3/cdo/sandbox/self-heal/slack
        property: webhook_url
```

`refreshInterval` là giá trị cấu hình, không phải cam kết rotation SLA. Chu kỳ thực tế phải được chốt theo từng secret.

### 6.3 Secret handling in CI

Pipeline phải tuân thủ các quy tắc:

1. Dùng GitHub OIDC cho AWS authentication.
2. Không echo token, password hoặc private key vào log.
3. Không truyền secret qua command-line argument nếu process list hoặc log có thể ghi lại.
4. Không lưu secret trong:
   - Dockerfile;
   - container image layer;
   - Terraform source;
   - `tfvars`;
   - Helm values được commit;
   - ConfigMap;
   - Pull Request comment;
   - workflow artifact.
5. Dùng `GITHUB_TOKEN` với permission tối thiểu cho thao tác trong repository.
6. Git write credential của Argo Workflow không được dùng chung với credential đọc của ArgoCD.
7. Không cấp Git write permission cho FastAPI Receiver nếu chỉ Workflow cần commit.
8. Terraform output chứa secret phải đánh dấu `sensitive = true`, nhưng vẫn tránh đưa secret value vào Terraform state khi có thể.
9. Secret rotation phải được kiểm tra bằng smoke test.
10. Khi secret bị thu hồi, Pod sử dụng secret qua environment variable phải được restart có kiểm soát để nhận giá trị mới.

### 6.4 Secret scanning

Mỗi Pull Request chạy **Gitleaks** trên:

- commit mới;
- file thay đổi;
- lịch sử liên quan nếu phát hiện pattern đáng ngờ.

Điều kiện thông qua:

```text
Không phát hiện secret
hoặc
Finding đã được xác nhận false positive bằng rule có lý do rõ ràng
```

Nếu secret thật đã bị commit:

1. block merge;
2. thu hồi hoặc rotate secret ngay;
3. xóa secret khỏi source;
4. kiểm tra Git history và workflow artifact;
5. không xem việc xóa chuỗi khỏi commit mới là đã xử lý xong.

Không dùng allowlist rộng để bỏ qua toàn bộ file `.yaml`, `.tfvars`, test fixture hoặc private key pattern.

### 6.5 Rotation and recovery

Rotation được thực hiện tại Secrets Manager trước. ESO đồng bộ phiên bản mới xuống Kubernetes.

Quy trình:

```text
Rotate secret trong Secrets Manager
→ ESO refresh
→ Xác nhận Kubernetes Secret có resourceVersion mới
→ Restart có kiểm soát nếu ứng dụng đọc qua environment variable
→ Health check
→ Thu hồi phiên bản cũ
→ Ghi audit
```

Nếu rotation làm workload lỗi:

- khôi phục secret version ổn định trong Secrets Manager;
- chờ ESO đồng bộ;
- restart workload;
- xác nhận health;
- ghi incident và audit.

---

## 7. Tenant onboarding deployment

Tenant onboarding trong Capstone là quy trình **Pull Request-driven**, không sử dụng Step Functions.

Hai tenant demo:

| Tenant ID           | Namespace         |
| ------------------- | ----------------- |
| `tnt-payment-demo`  | `tenant-payment`  |
| `tnt-checkout-demo` | `tenant-checkout` |

`tenant_id` và namespace là hai giá trị khác nhau nhưng có mapping bắt buộc. Receiver và Worker phải từ chối request nếu tenant không khớp namespace.

### 7.1 Tenant descriptor

Mỗi tenant được khai báo bằng một file descriptor trong Git:

```text
gitops/tenants/tnt-payment-demo/tenant.yaml
```

Ví dụ:

```yaml
apiVersion: platform.tf3.io/v1alpha1
kind: TenantDescriptor
metadata:
  name: tnt-payment-demo
spec:
  namespace: tenant-payment
  contact: payment-team
  environment: sandbox
  resourceQuota:
    requestsCpu: "2"
    requestsMemory: 4Gi
    limitsCpu: "4"
    limitsMemory: 8Gi
    pods: "20"
  allowedPatterns:
    - OOM_KILLED
    - SERVICE_STUCK
    - QUEUE_BACKLOG
```

`TenantDescriptor` ở đây là schema cấu hình trong Git; không bắt buộc phải triển khai thành Kubernetes CRD trong phạm vi Capstone. CI có thể validate file bằng JSON Schema hoặc script.

### 7.2 Onboarding flow

```text
1. Tạo Pull Request thêm TenantDescriptor và tenant overlay
2. CI validate tenant ID, namespace, quota và policy
3. Reviewer phê duyệt Pull Request
4. Merge vào main
5. GitHub Actions chạy Terraform tenant-bootstrap
6. Terraform tạo AWS/Kubernetes bootstrap resources
7. ArgoCD ApplicationSet tạo một Application cho tenant
8. ArgoCD sync workload và ExternalSecret
9. Chạy smoke test và RBAC isolation test
10. Ghi trạng thái tenant READY và gửi thông báo
```

#### Step 1 — Request and validation

Pull Request phải cung cấp:

- `tenant_id`;
- namespace;
- owner/contact;
- quota;
- allowed pattern;
- secret prefix;
- workload path;
- escalation destination.

CI kiểm tra:

- `tenant_id` chưa tồn tại;
- namespace chưa được tenant khác sử dụng;
- tên chỉ chứa ký tự hợp lệ;
- namespace không thuộc denylist:
  - `kube-system`;
  - `argocd`;
  - `argo`;
  - `self-heal-system`;
  - `observability`;
  - `external-secrets`;
- quota không vượt giới hạn sandbox;
- tenant không yêu cầu ClusterRole hoặc cluster-scoped resource ngoài allowlist;
- path Git không tham chiếu ra ngoài thư mục tenant;
- không có secret plaintext.

#### Step 2 — Terraform tenant bootstrap

Sau merge và GitHub Environment approval, Terraform module tạo:

- tenant registry record trong DynamoDB;
- namespace;
- ResourceQuota;
- LimitRange;
- Role;
- RoleBinding cho `selfheal-executor`;
- IAM policy hoặc secret access boundary cần thiết;
- Secrets Manager prefix hoặc secret metadata;
- ArgoCD AppProject/Application bootstrap nếu chưa dùng ApplicationSet hoàn toàn.

Không cấp `cluster-admin` cho tenant hoặc Self-Heal Executor.

RoleBinding của từng tenant chỉ cấp quyền vào namespace tương ứng.

#### Step 3 — ArgoCD ApplicationSet

ApplicationSet dùng Git directory generator để tạo một ArgoCD Application cho mỗi tenant folder:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tenants
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: <git-repository-url>
        revision: main
        directories:
          - path: gitops/tenants/*
  template:
    metadata:
      name: "{{path.basename}}"
    spec:
      project: tenants
      source:
        repoURL: <git-repository-url>
        targetRevision: main
        path: "{{path}}"
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{path.basenameNormalized}}"
      syncPolicy:
        automated:
          enabled: true
          prune: false
```

Template thực tế phải lấy namespace từ tenant descriptor hoặc mapping được validate, không giả định `tenant_id` luôn giống namespace.

Mỗi Application chỉ được:

- deploy vào namespace của tenant;
- đọc đúng path Git;
- tạo resource nằm trong allowlist;
- không sửa resource của tenant khác.

### 7.3 Onboarding smoke tests

Tenant chỉ được đánh dấu `READY` khi toàn bộ kiểm tra sau thành công:

```text
1. Namespace tồn tại
2. ResourceQuota và LimitRange đã apply
3. Role/RoleBinding tồn tại
4. selfheal-executor có quyền đúng trong tenant namespace
5. selfheal-executor không có quyền trong tenant khác
6. ArgoCD Application đạt Synced và Healthy
7. ExternalSecret đạt Ready
8. Workload mẫu đạt Ready
9. Alert chứa tenant_id được Receiver chấp nhận
10. Alert có tenant_id/namespace sai bị từ chối
11. Audit canary event có tenant_id đúng
12. Không có resource cluster-scoped ngoài allowlist
```

Kiểm tra RBAC bắt buộc:

```bash
kubectl auth can-i patch deployment \
  --as=system:serviceaccount:self-heal-system:selfheal-executor \
  -n tenant-payment
```

Phải trả về `yes` cho tenant được cấp.

Kiểm tra chéo:

```bash
kubectl auth can-i patch deployment \
  --as=system:serviceaccount:self-heal-system:selfheal-executor \
  -n tenant-checkout
```

Kết quả chỉ được là `yes` nếu RoleBinding cho namespace đó đã được tạo có chủ đích. Test phải chứng minh một action của `tnt-payment-demo` không thể tự đổi target sang namespace khác.

### 7.4 Time target

Mục tiêu thiết kế của sandbox là hoàn tất onboarding trong dưới 30 phút kể từ khi Pull Request đã được merge và deployment được phê duyệt.

| Stage                               | Target budget |
| ----------------------------------- | ------------: |
| Terraform tenant bootstrap          |     ≤ 10 phút |
| ArgoCD Application creation và sync |     ≤ 10 phút |
| Smoke test và RBAC isolation test   |      ≤ 8 phút |
| Status update và audit              |      ≤ 2 phút |
| **Total target**                    | **< 30 phút** |

Đây là design target theo template, chưa phải số liệu đã benchmark. Nhóm phải ghi lại timestamp của từng bước trong ít nhất hai lần onboarding tenant demo để xác nhận hoặc điều chỉnh mục tiêu.

### 7.5 Failure and rollback

Nếu Terraform thất bại:

- không đánh dấu tenant `READY`;
- giữ tenant registry ở trạng thái `PROVISIONING_FAILED`;
- không chạy manual fix ngoài Terraform;
- sửa code hoặc cấu hình rồi apply lại với cùng tenant ID.

Nếu ArgoCD sync thất bại:

- tenant registry chuyển sang `SYNC_FAILED`;
- giữ Application để điều tra;
- không mở alert/remediation traffic cho tenant;
- revert manifest hoặc sửa lỗi qua Pull Request.

Nếu smoke test hoặc RBAC isolation test thất bại:

- tenant chuyển sang `VALIDATION_FAILED`;
- khóa remediation tự động;
- không cấp trạng thái ready;
- rollback bằng Git revert và Terraform change đã review.

Không tự động xóa namespace sau một lỗi onboarding vì có thể làm mất bằng chứng điều tra hoặc tài nguyên đã tạo. Xóa tenant là một quy trình offboarding riêng và cần approval.

---

## 8. Observability stack

Observability được chia thành bốn lớp riêng biệt:

1. **Metrics của Kubernetes và ứng dụng:** Prometheus tự host trong EKS.
2. **Dashboard và phân tích trực quan:** Grafana tự host trong EKS.
3. **Metrics và logs của dịch vụ AWS:** Amazon CloudWatch.
4. **Distributed tracing:** OpenTelemetry thông qua ADOT Collector và AWS X-Ray nếu tracing được bật trong phạm vi triển khai.

S3 Object Lock là nơi lưu **canonical audit record**. Prometheus, Grafana, CloudWatch Logs và X-Ray chỉ phục vụ vận hành và điều tra; chúng không thay thế kho audit bất biến.

| Component       | Tool                                                                                     |
| --------------- | ---------------------------------------------------------------------------------------- |
| Metrics         | Prometheus cho Kubernetes/application; CloudWatch cho AWS managed services               |
| Logs            | Structured JSON logs → Fluent Bit hoặc CloudWatch Observability add-on → CloudWatch Logs |
| Traces          | OpenTelemetry SDK → ADOT Collector → AWS X-Ray                                           |
| Dashboards      | Grafana cho application/Kubernetes; CloudWatch Dashboard cho AWS resources               |
| Alerts          | Prometheus Alerting Rules → Alertmanager; CloudWatch Alarms cho AWS services             |
| Immutable audit | Amazon Data Firehose → S3 Object Lock → Athena                                           |

### 8.1 Metrics collection

Prometheus được triển khai trong namespace `observability` và scrape các endpoint nội bộ sau:

- FastAPI Receiver;
- SQS Worker và Direct Patch Engine;
- Kubernetes API metrics thông qua kube-state-metrics;
- node và container metrics;
- ArgoCD;
- Argo Workflows;
- Argo Rollouts;
- Karpenter;
- External Secrets Operator;
- Alertmanager;
- tenant workload mẫu.

Prometheus không scrape trực tiếp AWS managed services. Các dịch vụ như ALB, SQS, DynamoDB, RDS và Data Firehose được theo dõi bằng CloudWatch metrics.

#### Proposed custom application metrics

Các metric dưới đây là metric do nhóm phải instrument trong Receiver và Worker; đây không phải metric có sẵn từ AWS:

| Metric                                     | Type      | Purpose                                                         |
| ------------------------------------------ | --------- | --------------------------------------------------------------- |
| `selfheal_alerts_received_total`           | Counter   | Tổng số alert Receiver nhận được                                |
| `selfheal_alert_validation_failures_total` | Counter   | Alert bị từ chối do schema, authentication hoặc tenant mismatch |
| `selfheal_sqs_enqueue_failures_total`      | Counter   | Lỗi khi Receiver gửi message vào SQS                            |
| `selfheal_incidents_total`                 | Counter   | Số incident theo kết quả cuối cùng                              |
| `selfheal_incidents_in_progress`           | Gauge     | Số incident đang được Worker xử lý                              |
| `selfheal_action_duration_seconds`         | Histogram | Thời gian thực thi action                                       |
| `selfheal_action_results_total`            | Counter   | Kết quả action theo action type và status                       |
| `selfheal_rollbacks_total`                 | Counter   | Số rollback và kết quả rollback                                 |
| `selfheal_circuit_breaker_open`            | Gauge     | Circuit breaker đang mở cho resource hoặc tenant                |
| `selfheal_ai_request_duration_seconds`     | Histogram | Latency gọi AI `/detect`, `/decide` và `/verify`                |
| `selfheal_ai_requests_total`               | Counter   | Tổng request tới AI theo endpoint và status class               |
| `selfheal_audit_publish_failures_total`    | Counter   | Lỗi khi gửi audit event tới Data Firehose                       |
| `selfheal_gitops_persist_duration_seconds` | Histogram | Thời gian từ persistent patch tới khi Git và ArgoCD đồng bộ     |

Metric label chỉ sử dụng các giá trị có cardinality được kiểm soát:

- `service`;
- `environment`;
- `tenant_id`;
- `pattern_type`;
- `action`;
- `result`;
- HTTP status class.

Không dùng các giá trị sau làm Prometheus label:

- `incident_id`;
- `correlation_id`;
- `trace_id`;
- tên Pod có vòng đời ngắn;
- Git commit SHA;
- raw error message.

Các giá trị này được ghi vào log hoặc trace để tránh cardinality tăng không kiểm soát.

#### Kubernetes and controller metrics

Các nhóm metric cần theo dõi:

| Layer              | Metrics                                                                                                                        |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| Pod/Container      | CPU, memory, restart count, readiness, OOMKilled và pending Pod                                                                |
| Deployment/Rollout | available replica, unavailable replica, rollout phase và analysis result                                                       |
| Node               | CPU, memory, disk pressure, node readiness và pod capacity                                                                     |
| ArgoCD             | `argocd_app_info`, `argocd_app_condition`, `argocd_app_reconcile`, `argocd_app_sync_total`, `argocd_cluster_connection_status` |
| Argo Workflows     | controller metrics, workflow duration, workflow success/failure và custom remediation metrics                                  |
| Karpenter          | controller health, NodePool/NodeClaim state, provisioning error và pending Pod                                                 |
| ESO                | SecretStore/ExternalSecret readiness, reconcile error và sync status                                                           |

ArgoCD metric `argocd_app_info` được dùng để theo dõi `sync_status` và `health_status`. Không expose các Application label có cardinality cao vào Prometheus.

#### AWS service metrics

CloudWatch Dashboard và CloudWatch Alarms theo dõi:

| Service                   | Key metrics                                                                                                                                  |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Application Load Balancer | request count, target response time, HTTP 4xx/5xx và unhealthy host count                                                                    |
| Amazon SQS                | `ApproximateNumberOfMessagesVisible`, `ApproximateNumberOfMessagesNotVisible`, `ApproximateAgeOfOldestMessage`, message receive/delete count |
| SQS DLQ                   | `ApproximateNumberOfMessagesVisible`                                                                                                         |
| DynamoDB                  | consumed capacity, throttled requests, system error và successful request latency                                                            |
| RDS PostgreSQL            | CPU, free memory, free storage, database connections và read/write latency                                                                   |
| Data Firehose             | `IncomingRecords`, `IncomingBytes`, `DeliveryToS3.Records`, `DeliveryToS3.Success`, `DeliveryToS3.DataFreshness`                             |
| EKS                       | control-plane logs và cluster/node/container metrics khi Container Insights được bật                                                         |
| KMS                       | API error và throttling thông qua CloudWatch/CloudTrail                                                                                      |
| NAT Gateway nếu được dùng | bytes, packets, connection count và error port allocation                                                                                    |

`ApproximateNumberOfMessagesVisible` phản ánh backlog đang chờ xử lý. `ApproximateAgeOfOldestMessage` phản ánh tuổi của message chưa được xử lý. Đối với DLQ, metric chính để phát hiện message tồn đọng là `ApproximateNumberOfMessagesVisible`.

### 8.2 Logs

Receiver, Worker và Direct Patch Engine ghi log dạng JSON ra `stdout`/`stderr`. Log collector gửi container logs tới CloudWatch Logs.

Ví dụ schema:

```json
{
  "timestamp": "2026-06-25T10:30:00Z",
  "level": "INFO",
  "service": "self-heal-worker",
  "environment": "sandbox",
  "tenant_id": "tnt-payment-demo",
  "namespace": "tenant-payment",
  "incident_id": "inc-20260625-001",
  "correlation_id": "corr-8f8c2d",
  "trace_id": "1-...",
  "event_type": "EXECUTION_RESULT",
  "pattern_type": "urgent",
  "action": "PATCH_MEMORY_LIMIT",
  "target": "deployment/order-service",
  "result": "SUCCESS",
  "duration_ms": 842
}
```

Các trường bắt buộc:

- timestamp theo UTC;
- log level;
- service/component;
- environment;
- `tenant_id`;
- `incident_id`;
- `correlation_id`;
- `event_type`;
- action target nếu có;
- result;
- error code nếu thất bại.

Không ghi vào log:

- secret value;
- AWS temporary credential;
- Git private key hoặc token;
- RDS password;
- Slack webhook URL;
- full Authorization header;
- raw Kubernetes Secret;
- dữ liệu nhạy cảm không cần thiết từ AI request/response.

#### Log groups

Tách log group theo mục đích:

```text
/aws/eks/<cluster-name>/cluster
/tf3/cdo1/sandbox/receiver
/tf3/cdo1/sandbox/worker
/tf3/cdo1/sandbox/argo-workflows
/tf3/cdo1/sandbox/argocd
/tf3/cdo1/sandbox/firehose-errors
```

EKS control-plane logging nên bật tối thiểu:

- `api`;
- `audit`;
- `authenticator`.

`controllerManager` và `scheduler` được bật khi nhóm cần điều tra scheduling hoặc control-loop issue và đã đánh giá chi phí log ingestion.

CloudWatch log group phải có retention rõ ràng; không để `Never expire`. Số ngày retention cho operational logs cần được chốt trong §9. Audit record trên S3 Object Lock giữ 90 ngày theo yêu cầu dự án.

### 8.3 Distributed tracing

Receiver và Worker sử dụng OpenTelemetry SDK. ADOT Collector nhận OTLP qua:

- gRPC `4317`;
- HTTP `4318`.

Collector export trace sang AWS X-Ray.

Trace cần bao phủ:

```text
Alertmanager
→ Receiver
→ SQS SendMessage
→ Worker ReceiveMessage
→ AI /detect
→ AI /decide
→ DynamoDB lock/policy
→ Direct Patch hoặc Argo Workflow creation
→ AI /verify
→ Data Firehose audit publish
```

Do SQS là ranh giới bất đồng bộ, Receiver phải đưa trace context vào message attribute và Worker phải khôi phục context khi nhận message. `correlation_id` vẫn được giữ độc lập để truy vết ngay cả khi distributed trace bị sampling hoặc mất span.

Không đưa secret, raw token hoặc nội dung nhạy cảm vào span attribute.

Tracing không được xem là hoàn thành chỉ vì ADOT Collector đã được cài. Nhóm phải chứng minh ít nhất một trace xuyên qua:

```text
Receiver → SQS → Worker → AI call
```

Nếu không đủ thời gian triển khai X-Ray trong Capstone, bảng và sơ đồ phải ghi tracing là `planned`, không ghi như tính năng đã hoàn tất.

### 8.4 Dashboards

#### Grafana dashboard: Self-Heal Overview

Hiển thị:

- alert rate;
- incident theo trạng thái;
- tỷ lệ auto-resolve;
- urgent/deferred distribution;
- action success/failure;
- rollback count;
- AI latency;
- end-to-end remediation duration;
- audit publish failure.

Tỷ lệ auto-resolve:

```text
incident resolved automatically
/
all eligible incidents
```

Không tính incident bị policy từ chối hoặc ngoài known-pattern scope vào mẫu số nếu contract định nghĩa chúng không đủ điều kiện auto-remediation.

#### Grafana dashboard: Tenant Isolation

Hiển thị:

- incident count theo tenant;
- remediation action theo tenant;
- tenant mismatch rejection;
- resource usage và quota;
- circuit breaker state;
- cross-namespace authorization denial.

Dashboard chỉ dùng `tenant_id` có số lượng hữu hạn. Không dùng `incident_id` làm metric label.

#### Grafana dashboard: GitOps and Workflow

Hiển thị:

- ArgoCD sync/health status;
- Application `OutOfSync`;
- reconciliation duration;
- Workflow running/succeeded/failed;
- workflow duration;
- GitOps persist duration;
- persistent patch chưa trở về `Synced`.

#### CloudWatch dashboard: AWS Infrastructure

Hiển thị:

- ALB target health và error;
- SQS backlog, oldest message và DLQ;
- DynamoDB throttle/error;
- RDS CPU, connection và storage;
- Firehose incoming/delivery/data freshness;
- EKS/EC2 node health;
- NAT Gateway nếu được dùng.

### 8.5 Alert routing

Alertmanager thực hiện grouping, deduplication, inhibition và routing.

Cần tách hai nhóm alert:

#### Workload remediation alerts

Các known pattern của tenant được gửi tới Self-Heal Receiver:

```text
PrometheusRule
→ Alertmanager route `self-heal`
→ Receiver
→ SQS
→ Worker
```

Ví dụ:

- OOMKilled;
- service stuck;
- queue backlog;
- workload replica unavailable;
- resource threshold thuộc allowlist.

#### Platform health alerts

Lỗi của chính Self-Heal Engine phải gửi thẳng tới người vận hành, không quay lại Self-Heal Receiver:

```text
Prometheus/CloudWatch
→ Alertmanager or CloudWatch Alarm
→ Slack/on-call
```

Ví dụ:

- Receiver unavailable;
- Worker unavailable;
- SQS DLQ có message;
- DynamoDB lock store lỗi;
- audit publish thất bại;
- Data Firehose delivery bị đình trệ;
- ArgoCD mất kết nối cluster;
- Argo Workflow controller lỗi;
- rollback thất bại;
- RBAC hoặc tenant isolation violation.

Việc tách route này ngăn vòng lặp:

```text
Self-Heal platform failure
→ Self-Heal Receiver
→ Self-Heal platform failure
→ ...
```

#### Initial alert rules

| Alert                        | Condition                                                                                                     | Route                       |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------- | --------------------------- |
| `ReceiverHighErrorRate`      | HTTP 5xx rate lớn hơn 1% trong cửa sổ canary đã định nghĩa                                                    | Human + abort rollout       |
| `ReceiverHighP99Latency`     | P99 lớn hơn 800 ms trong cửa sổ canary đã định nghĩa                                                          | Human + abort rollout       |
| `ReceiverUnavailable`        | Không có Receiver Pod Ready                                                                                   | Human                       |
| `WorkerUnavailable`          | Không có Worker consumer healthy                                                                              | Human                       |
| `SQSBacklogGrowing`          | `ApproximateAgeOfOldestMessage` vượt incident-processing SLO                                                  | Human; có thể scale Worker  |
| `SQSDeadLetterQueueNotEmpty` | DLQ `ApproximateNumberOfMessagesVisible` lớn hơn 0                                                            | Human                       |
| `ArgoCDApplicationOutOfSync` | Persistent remediation còn `OutOfSync` quá 120 giây                                                           | Human + rollback/escalation |
| `ArgoWorkflowFailed`         | Workflow remediation kết thúc Failed/Error                                                                    | Human + incident escalation |
| `AuditPublishFailure`        | Custom audit publish failure tăng                                                                             | Human, mức nghiêm trọng cao |
| `FirehoseDeliveryStalled`    | Incoming records tiếp tục tăng nhưng S3 delivery không tiến triển, hoặc DataFreshness vượt audit delivery SLO | Human, mức nghiêm trọng cao |
| `CircuitBreakerOpen`         | Circuit breaker mở cho workload                                                                               | Human                       |
| `TenantNamespaceMismatch`    | Nhiều request bị từ chối do tenant/namespace mismatch                                                         | Security/Platform owner     |

Các ngưỡng ngoài `1%`, `800 ms` và thời hạn GitOps `120 giây` chưa được contract hóa phải được xác định bằng load test hoặc SLO, không tự đặt số trong alarm production.

### 8.6 Health endpoints

Receiver và Worker cung cấp endpoint riêng:

| Endpoint   | Meaning                                            |
| ---------- | -------------------------------------------------- |
| `/healthz` | Process còn hoạt động                              |
| `/readyz`  | Component sẵn sàng nhận traffic hoặc xử lý message |
| `/metrics` | Prometheus metrics                                 |

Receiver `/readyz` kiểm tra các dependency cần thiết để nhận alert nhưng không được thực hiện thao tác quá nặng trên mỗi probe.

Worker readiness phải phản ánh:

- cấu hình hợp lệ;
- có thể khởi tạo SQS client;
- có thể truy cập DynamoDB lock store;
- worker loop đã sẵn sàng.

Lỗi tạm thời của AI Engine không nhất thiết làm Worker Pod bị restart. Worker nên chuyển incident sang retry/escalation thay vì tạo restart loop cho Pod.

---

## 9. Open questions

- [ ] **Q1: Alertmanager có cần đi qua Internal ALB không?**  
      Prometheus và Alertmanager đã được chốt tự host trong EKS. Nếu Alertmanager chỉ gửi webhook tới Receiver trong cùng cluster, `ClusterIP Service` là đủ và có thể loại ALB khỏi alert path. Chỉ giữ Internal ALB nếu có alert source từ ngoài cluster/VPC cần gọi Receiver.

- [ ] **Q2: Private subnet truy cập GitHub bằng đường nào?**  
      ArgoCD cần pull GitHub và Argo Workflow cần push commit. GitHub không phải AWS service có VPC Endpoint trong kiến trúc hiện tại. Nhóm phải chọn một phương án rõ ràng: NAT Gateway, egress proxy có kiểm soát, hoặc thay đổi Git provider/network design. Không được vừa ghi “không có NAT” vừa giả định Pod truy cập GitHub được.

- [ ] **Q3: EKS kết nối AI Engine ECS Fargate bằng cơ chế mạng nào?**  
      Cần xác nhận AI Engine ở cùng VPC, VPC khác cùng account hay account khác; đồng thời chọn VPC Peering, Transit Gateway, PrivateLink hoặc HTTPS public endpoint. Route 53 private DNS không tự tạo kết nối mạng.

- [ ] **Q4: Cơ chế authentication giữa CDO Worker và AI Engine là gì?**  
      Nếu dùng AWS IAM SigV4, cần chốt service endpoint, IAM principal, resource policy và quyền tối thiểu. Nếu dùng API key hoặc mTLS, phải cập nhật Secrets Manager, rotation và deployment contract.

- [ ] **Q5: Git write credential của Argo Workflow dùng loại nào?**  
      Cần chọn GitHub App, fine-grained token hoặc SSH deploy key. Credential ghi phải tách khỏi credential chỉ đọc của ArgoCD, có phạm vi repository/branch tối thiểu và có rotation owner.
