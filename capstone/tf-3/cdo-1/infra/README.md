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
