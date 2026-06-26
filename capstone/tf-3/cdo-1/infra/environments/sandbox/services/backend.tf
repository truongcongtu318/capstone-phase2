# 🌐 TODO: Cấu hình Backend State riêng biệt cho Services
# Key: "sandbox/services/terraform.tfstate"
terraform {
  backend "s3" {
    # Tự động import bucket & lock table từ bootstrap
  }
}
