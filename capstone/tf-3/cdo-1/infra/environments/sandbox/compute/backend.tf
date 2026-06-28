terraform {
  backend "s3" {
    bucket         = "tf-3-aiops-audit-trail"
    key            = "sandbox/compute/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-3-aiops-idempotency-lock"
    encrypt        = true
  }
}
