# 🌐 TODO: Cấu hình Backend State riêng biệt cho Compute
# Key: "sandbox/compute/terraform.tfstate"
terraform {
  backend "s3" {
    # Tự động import bucket & lock table từ bootstrap
  }
}
