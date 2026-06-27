# 📖 Hướng Dẫn Git-flow & Phân Chia Công Việc - Sub-team 1 (IaC & Cloud Infra)

Tài liệu này quy định quy trình làm việc trên Git và phân chia nhiệm vụ cho các thành viên Sub-team 1 để phát triển hạ tầng hệ thống **CDO-01 Self-Heal Platform**.

---

## 🔀 Quy Trình Git-flow Cho Thành Viên (Developer Workflow)

Nhánh **`infra/platform-base`** là nhánh tích hợp chung của Sub-team 1. Nghiêm cấm mọi hành vi commit trực tiếp lên nhánh này hoặc tạo PR trực tiếp từ nhánh cá nhân vào nhánh `main`.

### Bước 1: Đồng bộ nhánh base chung về máy
Trước khi làm task mới, hãy đảm bảo nhánh base ở local của bạn là mới nhất:
```bash
git checkout infra/platform-base
git pull origin infra/platform-base
```

### Bước 2: Tạo nhánh con theo đúng chuẩn đặt tên
Checkout nhánh mới từ `infra/platform-base` để thực hiện task của bạn:
* **Networking & Security**: `infra/networking-setup`
* **EKS & Karpenter**: `infra/eks-setup`
* **Services & Observability**: `infra/services-setup`
* *Cú pháp chung: `infra/<tên-thành-phần>-setup`*
```bash
git checkout -b infra/<tên-thành-phần>-setup
```

### Bước 3: Phát triển và Kiểm thử cục bộ (Plan Local)
* Viết code module hạ tầng của bạn.
* Cấu hình backend state trong thư mục môi trường tương ứng đã được khai báo sẵn S3/DynamoDB của dự án.
* Chạy kiểm tra cú pháp và plan local:
  ```bash
  terraform init
  terraform validate
  terraform plan
  ```
  *(Lưu ý: Chỉ chạy `terraform plan`, **KHÔNG** tự ý chạy `terraform apply` ở máy cá nhân lên tài nguyên chung).*

### Bước 4: Tạo Pull Request (PR) về nhánh Base của Team
Khi hoàn thành code, push nhánh của bạn lên GitHub và tạo Pull Request:
* **Source branch**: `infra/<tên-thành-phần>-setup`
* **Target branch**: `infra/platform-base` ⚠️ *(Không chọn main)*

> ℹ️ **Hệ thống CI tự động**: Khi PR được tạo, GitHub Actions sẽ tự động chạy song song job `terraform plan` cho cả 4 phase để kiểm tra xem code của bạn có lỗi gì không. Kết quả plan sẽ hiển thị ngay dưới phần kiểm tra của PR.

### Bước 5: Đợi Tech Lead duyệt và Merge
* Liên hệ Tech Lead (anh Tú) review code và kết quả plan trên GitHub.
* Sau khi Tech Lead approve và merge PR của bạn vào `infra/platform-base`, task của bạn chính thức hoàn thành trên Git.

---

## 👑 Quy Trình Deploy Lên AWS Sandbox (Dành riêng cho Tech Lead)

Khi các thành viên đã merge code hoàn chỉnh vào nhánh `infra/platform-base` và anh Tú muốn deploy thực tế lên AWS Sandbox:

1. Tạo một Pull Request trên GitHub:
   * **Source branch**: `infra/platform-base`
   * **Target branch**: `main`
2. Review lại toàn bộ plan tổng hợp một lần cuối.
3. Nhấp chọn **Merge Pull Request**.
4. **Hệ thống CD tự động**: Khi code được merge vào `main`, GitHub Actions sẽ tự động login OIDC vào AWS Sandbox Account (`474013238625`) và chạy tuần tự lệnh `terraform apply -auto-approve` từ Phase 1 đến Phase 4 để đưa hạ tầng lên Cloud một cách an toàn.

---

## 📋 Phân Chia Công Việc Cụ Thể (Sub-team 1)

| Vai trò | Thành viên | Phạm vi file thực thi (`capstone/tf-3/cdo-1/`) |
| :--- | :--- | :--- |
| **Networking & Security Lead** | **Thành viên A** | 📂 `infra/modules/networking/` (VPC, Subnets, 12 VPC Endpoints)<br>📂 `infra/modules/security/` (KMS Keys, Security Groups)<br>📂 `infra/environments/sandbox/networking/` |
| **Compute & Karpenter Lead** | **Thành viên B** | 📂 `infra/modules/eks/` (EKS Cluster, Nodes, IAM)<br>📂 `infra/modules/karpenter/` (IAM, Provisioner template)<br>📂 `infra/environments/sandbox/compute/` |
| **Services & Observability Lead** | **Thành viên C** | 📂 `infra/modules/ingress/` (AWS Load Balancer Controller)<br>📂 `infra/modules/observability/` (Prometheus Helm Stack, ADOT)<br>📂 `infra/environments/sandbox/services/` |
