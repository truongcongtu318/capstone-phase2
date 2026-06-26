terraform {
  required_version = ">= 1.7.0"

  # Bootstrap dùng LOCAL backend (chính nó tạo backend cho mọi state khác).
  # KHÔNG đổi sang remote backend cho module này.
  backend "local" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}
