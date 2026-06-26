# Infrastructure Directory (Monorepo Standard Structure)

Thư mục này chứa toàn bộ mã nguồn Infrastructure-as-Code (IaC) của dự án **CDO-01** sử dụng Terraform. Nhóm **Sub-team 1** chịu trách nhiệm hoàn thiện hạ tầng dựa trên cấu trúc bên dưới.

## 📂 Tổ chức Thư mục & Best Practices

Thư mục được chia rõ ràng thành `modules/` (các tài nguyên dùng chung, có thể tái sử dụng) và `environments/` (nơi cấu hình và thực thi `plan`/`apply` cho từng môi trường cụ thể).

```text
infra/
├── bootstrap/                        # Khởi tạo S3 backend, DynamoDB Lock table và OIDC Roles (Đã dựng)
│
├── modules/                          # Các child modules định nghĩa tài nguyên (Reusable)
│   ├── networking/                   # Cấu hình VPC, Subnets, Route Tables, Internet/NAT Gateway
│   ├── security/                     # Cấu hình KMS Keys (audit, secrets, app) & 5 Security Groups cốt lõi
│   ├── eks/                          # EKS Cluster, OIDC integration, Node Groups và IAM roles liên quan
│   ├── karpenter/                    # IAM Role & Instance Profile cho Karpenter controller
│   ├── ingress/                      # AWS Load Balancer Controller (LBC) Helm integration
│   └── observability/                # Prometheus Helm Stack & ADOT (Collector config)
│
└── environments/                     # Triển khai thực tế theo môi trường (Root Modules)
    └── sandbox/                      # Môi trường kiểm thử Sandbox
        ├── networking/               # Gọi module networking & security (Tạo VPC, KMS, SGs)
        ├── compute/                  # Gọi module eks & karpenter (Tạo EKS, gán node roles)
        └── services/                 # Gọi module ingress & observability (Cài đặt LBC & Prometheus)
```

## 🛠️ Trình Tự Triển Khai Hạ Tầng (Sequential Deployment)

Do sử dụng mô hình **Multi-State Isolation**, hạ tầng sandbox được chia nhỏ thành 3 State độc lập và phải deploy tuần tự bằng cách kế thừa remote state thông qua data source:

1.  **networking/**:
    *   *Nhiệm vụ:* Triển khai trước tiên để dựng VPC, Security Groups, KMS Keys, và VPC Endpoints.
    *   *State Key:* `sandbox/networking/terraform.tfstate`
2.  **compute/**:
    *   *Nhiệm vụ:* Sử dụng `data.terraform_remote_state` đọc output từ `networking` (lấy VPC ID, Subnet IDs, SGs, KMS Keys) để khởi dựng EKS cluster và Karpenter IAM roles.
    *   *State Key:* `sandbox/compute/terraform.tfstate`
3.  **services/**:
    *   *Nhiệm vụ:* Sử dụng `data.terraform_remote_state` đọc output từ `compute` (lấy EKS endpoint, OIDC ARN) và `networking` (lấy VPC/Security Groups) để cấu hình Kubernetes & Helm providers, cài đặt các controller/observability stack.
    *   *State Key:* `sandbox/services/terraform.tfstate`

---

## 📜 Quy định Tệp tin trong các Thư mục (Terraform File Layout)

Để đảm bảo code sạch, mỗi thư mục làm việc (ở cả `modules/` và `environments/`) bắt buộc phải được chia nhỏ thành các file chuyên trách:
*   `main.tf`: Chứa logic khai báo tài nguyên chính hoặc gọi modules.
*   `providers.tf`: Khai báo và cấu hình các providers (`aws`, `kubernetes`, `helm`).
*   `versions.tf`: Ràng buộc version tối thiểu của Terraform (>= 1.7.0) và các providers (AWS ~> 5.60, Kubernetes ~> 2.31).
*   `variables.tf`: Định nghĩa tất cả các biến đầu vào cùng kiểu dữ liệu (type) và mô tả (description).
*   `outputs.tf`: Khai báo các đầu ra cần export để module khác kế thừa.
*   `backend.tf` (Chỉ có ở root modules): Định nghĩa S3 Backend và DynamoDB Table Lock.
*   `terraform.tfvars` (Chỉ có ở root modules): Định nghĩa giá trị cụ thể cho các biến đầu vào.

---

## 🏷️ Quy Tắc Đặt Tên & Viết Code Terraform (Terraform Naming Rules)

Nhóm **Sub-team 1** bắt buộc phải tuân thủ nghiêm ngặt các quy tắc đặt tên (Best Practices) sau để đảm bảo tính đồng bộ và sạch sẽ của mã nguồn:

### 1. Quy tắc viết Hoa/Thường (Casing Rule)
*   **HCL Identifiers (Resource local name, Variable name, Output name):** Bắt buộc dùng **`snake_case`** (chữ thường và dấu gạch dưới).
    *   *Đúng:* `resource "aws_vpc" "main_vpc"` | `variable "vpc_cidr"`
    *   *Sai:* `resource "aws_vpc" "main-vpc"` | `variable "vpcCidr"`
*   **AWS Cloud Resource Name (Name tag, SG name, IAM role name):** Bắt buộc dùng **`kebab-case`** (chữ thường và dấu gạch ngang) theo định dạng chuẩn hóa của dự án.
    *   *Đúng:* `tf3-cdo1-sandbox-vpc` | `sg-eks-workload`
    *   *Sai:* `tf3_cdo1_sandbox_vpc` | `sg_eks_workload`

### 2. Quy tắc đặt tên Local Name (Resource & Data Blocks)
*   Không lặp lại loại tài nguyên trong tên local để tránh dư thừa thông tin.
    *   *Đúng:* `resource "aws_route_table" "private"`
    *   *Sai:* `resource "aws_route_table" "private_route_table"` (Từ `route_table` đã có sẵn trong loại resource).
*   Nếu tài nguyên là duy nhất hoặc mang tính đại diện cho module, dùng tên `this` hoặc `main`.
    *   *Đúng:* `resource "aws_vpc" "this"`

### 3. Quy tắc đặt tên Biến (Variables)
*   Biến boolean phải bắt đầu bằng tiền tố mô tả trạng thái như `is_`, `has_`, hoặc `enable_`.
    *   *Đúng:* `variable "enable_encryption"`
*   Mọi khai báo biến bắt buộc phải chứa thuộc tính `type` và `description` mô tả chi tiết.
    *   *Đúng:*
        ```hcl
        variable "vpc_cidr" {
          type        = string
          description = "The CIDR block for the primary VPC"
        }
        ```

### 4. Quy tắc quản lý Output (Outputs)
*   Tên output phải tự giải nghĩa được kiểu dữ liệu và tài nguyên nó đại diện.
    *   *Đúng:* `output "vpc_id"` | `output "private_subnet_ids"`
*   Mọi output phải có thuộc tính `description` đi kèm để hỗ trợ IDE hiển thị gợi ý.

### 5. Khai báo Tagging tập trung (Global Tags)
*   Sử dụng `local.module_tags` để merge các tags mặc định của hệ thống với tag đặc thù của từng module:
    ```hcl
    locals {
      module_tags = merge(
        var.global_tags,
        {
          Component = "networking"
        }
      )
    }
    ```
*   Không khai báo tags thủ công rải rác ở từng resource. Truyền `local.module_tags` vào block `tags` của resource.

---

## 🔒 Danh Sách Tên Tài Nguyên Bắt Buộc (Strict Resource Name Registry)

Để tránh lỗi phân quyền IAM Policy của AI Engine hoặc lỗi mismatch cấu hình, toàn bộ tài nguyên cốt lõi phải sử dụng chính xác các tên gọi sau đây (CẤM tự ý thay đổi):

### 1. Tài nguyên AWS (Infrastructure Level)
| Loại Tài Nguyên | Tên Gọi / ID Bắt Buộc (Strict Name) | File Khai Báo (Khu Vực Phụ Trách) |
|---|---|---|
| **DynamoDB Lock Table** | `tf-3-aiops-idempotency-lock` | `infra/bootstrap/` |
| **S3 Audit Bucket** | `tf-3-aiops-audit-trail` | `infra/bootstrap/` |
| **KMS Key Alias (Infra)** | `alias/cdo-infra-kms` | `infra/modules/security/` |
| **KMS Key Alias (Observability)**| `alias/cdo-observability-kms` | `infra/modules/security/` |
| **KMS Key Alias (Audit Logs)** | `alias/cdo-audit-kms` | `infra/modules/security/` |
| **KMS Key Alias (App Secrets)** | `alias/cdo-secrets-kms` | `infra/modules/security/` |
| **KMS Key Alias (App Data)** | `alias/cdo-app-data-kms` | `infra/modules/security/` |
| **Security Group (ALB)** | `sg-alb-internal` | `infra/modules/security/security-groups.tf` |
| **Security Group (Workload)** | `sg-eks-workload` | `infra/modules/security/security-groups.tf` |
| **Security Group (EKS Control)** | `sg-eks-control-plane` | `infra/modules/security/security-groups.tf` |
| **Security Group (RDS)** | `sg-rds` | `infra/modules/security/security-groups.tf` |
| **Security Group (Endpoints)** | `sg-vpc-endpoint` | `infra/modules/security/security-groups.tf` |
| **AWS ECR Registries** | `544011261607.dkr.ecr.us-east-1.amazonaws.com` | `infra-old/` (Image registry của dự án) |

### 2. Tài nguyên Kubernetes (K8s Level)
| Loại Tài Nguyên | Tên Gọi / ID Bắt Buộc (Strict Name) | File Khai Báo (Khu Vực Phụ Trách) |
|---|---|---|
| **AI Engine Namespace** | `self-heal-system` | `gitops/manifests/base/ai-engine/` |
| **Webhook Service** | `webhook-receiver` | `gitops/manifests/base/webhook-receiver/` |
| **SQS Worker ServiceAccount**| `sa-patch-controller` | `gitops/manifests/base/sqs-worker/` |
| **Tenant 1 Namespace** | `tenant-payment` | `gitops/tenants/` |
| **Tenant 1 ID (UUID)** | `d3b07384-d113-495f-9f58-20d18d357d75` | *Đăng ký trong DB & Header gọi API* |
| **Tenant 2 Namespace** | `tenant-checkout` | `gitops/tenants/` |
| **Tenant 2 ID (UUID)** | `6c8b4b2b-4d45-4209-a1b4-4b532d56a31c` | *Đăng ký trong DB & Header gọi API* |

### 3. Giao diện Đầu ra Module bắt buộc (Module Outputs Contracts)
Các output của module con không được đổi tên để bảo đảm kết nối Remote State hoạt động ổn định:
*   `networking` $\rightarrow `vpc_id`, `vpc_cidr`, `private_subnet_ids`, `public_subnet_ids``
*   `security` $\rightarrow `sg_eks_workload_id`, `sg_eks_control_plane_id`, `sg_alb_internal_id`, `sg_rds_id`, `sg_vpc_endpoint_id`, `kms_infra_arn`, `kms_observability_arn``
*   `eks` $\rightarrow `cluster_name`, `cluster_endpoint`, `cluster_ca_data`, `oidc_provider_arn``
*   `karpenter` $\rightarrow `node_iam_role_arn``
*   `ingress` $\rightarrow `alb_dns_name``
*   `observability` $\rightarrow `grafana_service_name``

---

## 👥 Phân Vai Chi Tiết Trong Sub-team 1 (Member Responsibilities & Deliverables)

Để đảm bảo hiệu quả làm việc nhóm song song và tránh chồng chéo code, các thành viên Sub-team 1 được phân chia trách nhiệm và yêu cầu đầu ra (output) chi tiết như sau:

### 1. **Member 1 (Cloud Network & Endpoints Lead)**
*   **Trách nhiệm chính:**
    *   Tái cấu trúc Phase 2: Triển khai VPC, Private Subnets, Route Tables và 12 AWS VPC Endpoints (S3, DynamoDB, SecretsManager, v.v.) đảm bảo kết nối NAT-less.
    *   Khởi tạo AWS OIDC IAM Roles cho GitHub Actions (`github-ci-plan`/`github-ci-apply`) liên kết với AWS không dùng static key.
    *   Cấu hình pipeline tự động chạy `terraform plan/apply` trên `terraform-pipeline.yml` đối với Phase 1 & 2.
*   **Đầu ra (Deliverables):**
    *   Mã nguồn module mạng tại `infra/modules/networking/` (`main.tf`, `endpoints.tf`, v.v.).
    *   Mã nguồn environment tại `infra/environments/sandbox/networking/`.
    *   Các outputs: `vpc_id`, `private_subnet_ids`, `public_subnet_ids`, `vpc_cidr`.
*   **Các file đảm nhiệm:**
    *   `infra/modules/networking/*`
    *   `infra/environments/sandbox/networking/*`

### 2. **Member 2 (Cryptography, Security Groups & Escalation Network Lead)**
*   **Trách nhiệm chính:**
    *   Triển khai 5 KMS Keys (`alias/cdo-audit-kms`, `alias/cdo-app-data-kms`, v.v.) kèm KMS Key Policies cho phép CloudWatch Logs Group truy cập ghi nhận dữ liệu mã hóa.
    *   Triển khai 5 Security Groups cốt lõi (`sg-alb-internal`, `sg-eks-workload`, `sg-eks-control-plane`, `sg-rds`, `sg-vpc-endpoint`) với luật Ingress/Egress nghiêm ngặt.
    *   Thiết lập AWS SNS Topic `tf3-cdo1-sandbox-alerts-escalation` kết nối tự động để đẩy thông báo lên Slack khi Circuit Breaker nổ.
*   **Đầu ra (Deliverables):**
    *   Mã nguồn module bảo mật tại `infra/modules/security/` (`main.tf`, `security-groups.tf`).
    *   KMS policies, Security Group rules và SNS Topic Terraform resources.
    *   Các outputs: Tất cả KMS Key ARNs, Security Group IDs và SNS Topic ARN.
*   **Các file đảm nhiệm:**
    *   `infra/modules/security/*`

### 3. **Member 3 (Compute Cluster & Ingress Lead)**
*   **Trách nhiệm chính:**
    *   Tái cấu trúc Phase 3: Khởi dựng cụm EKS Cluster v1.28, Node Groups, gán OIDC provider cho ServiceAccount (IRSA) và Karpenter IAM Roles.
    *   Cấu hình Phase 4: Triển khai Helm chart cho AWS Load Balancer Controller (LBC) và Karpenter.
    *   Cấu hình pipeline tự động chạy `terraform plan/apply` trên `terraform-pipeline.yml` đối với Phase 3 & 4.
*   **Đầu ra (Deliverables):**
    *   Mã nguồn module EKS tại `infra/modules/eks/` (`main.tf`, `iam.tf`), module Karpenter tại `infra/modules/karpenter/` và module Ingress tại `infra/modules/ingress/`.
    *   Mã nguồn các environments tại `infra/environments/sandbox/compute/` và `infra/environments/sandbox/services/`.
    *   Các outputs: `cluster_name`, `cluster_endpoint`, `cluster_ca_data`, `oidc_provider_arn`, `node_iam_role_arn`, `alb_dns_name`.
*   **Các file đảm nhiệm:**
    *   `infra/modules/eks/*`
    *   `infra/modules/karpenter/*`
    *   `infra/modules/ingress/*`
    *   `infra/environments/sandbox/compute/*`
    *   `infra/environments/sandbox/services/*`
---

## 🔌 Quy trình chuyển đổi & Kết nối tích hợp (Transition & Integration Path)

Hạ tầng của Sub-team 1 được triển khai theo mô hình **Multi-State** để tránh xung đột. Trình tự đấu nối và giải phóng phụ thuộc (dependencies) thực hiện như sau:

### 1. Vấn đề phụ thuộc (Dependencies)
*   **Networking (Phase 2)** hoàn toàn độc lập, có thể deploy ngay.
*   **Compute (Phase 3)** phụ thuộc vào VPC ID, Subnet IDs và Security Group IDs của Phase 2.
*   **Services (Phase 4)** phụ thuộc vào EKS Cluster Endpoint, CA Data và OIDC Provider của Phase 3.

### 2. Giải pháp chuyển đổi & Kết nối (Integration Steps)
*   **Bước 1 (Giải phóng Phase 2 -> 3):** Member 3 khi viết code compute/main.tf sử dụng data source:
    ```hcl
    data "terraform_remote_state" "networking" {
      backend = "s3"
      config = {
        bucket = var.tf_state_bucket
        key    = "sandbox/networking/terraform.tfstate"
        region = var.aws_region
      }
    }
    ```
    Trỏ trực tiếp các biến vpc_id và subnet_ids vào output của data source này. Khi Member 1 chạy pipeline deploy xong Networking, Member 3 mới kích hoạt pipeline deploy Compute.
*   **Bước 2 (Giải phóng Phase 3 -> 4):** Member 3 cấu hình providers.tf của services/ kế thừa động CA cert và token của EKS Cluster:
    ```hcl
    data "aws_eks_cluster_auth" "this" {
      name = data.terraform_remote_state.compute.outputs.cluster_name
    }
    provider "kubernetes" {
      host                   = data.terraform_remote_state.compute.outputs.cluster_endpoint
      cluster_ca_certificate = base64decode(data.terraform_remote_state.compute.outputs.cluster_ca_data)
      token                  = data.aws_eks_cluster_auth.this.token
    }
    ```
    Cách thiết lập này giúp Helm provider tự động nhận diện và kết nối cụm EKS thật một cách an toàn mà không cần ổ đĩa local phải có file kubeconfig.
