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

Do sử dụng mô hình **Multi-State Isolation**, hạ tầng sandbox được chia nhỏ thành 3 State độc lập và phải deploy tuần tự bằng cách kế thừa remote state:

1.  **networking/**:
    *   *Nhiệm vụ:* Triển khai trước tiên để dựng VPC và Security Groups/KMS.
    *   *State Key:* `sandbox/networking/terraform.tfstate`
2.  **compute/**:
    *   *Nhiệm vụ:* Đọc remote state từ `networking` (lấy VPC ID, Subnet IDs, SGs) để dựng EKS.
    *   *State Key:* `sandbox/compute/terraform.tfstate`
3.  **services/**:
    *   *Nhiệm vụ:* Đọc remote state từ `compute` (lấy EKS details) để kết nối Helm/Kubernetes provider và cài đặt các controller/monitoring tools.
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
