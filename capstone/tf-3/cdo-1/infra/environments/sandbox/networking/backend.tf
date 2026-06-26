# 🌐 TODO: Cấu hình Backend State riêng biệt cho Networking
# Key: "sandbox/networking/terraform.tfstate"
terraform {
  backend "s3" {
    # Tự động import bucket & lock table từ bootstrap
  }
}
