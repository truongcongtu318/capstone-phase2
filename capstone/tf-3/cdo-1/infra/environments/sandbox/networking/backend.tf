terraform {
  backend "s3" {
    bucket         = "tf3-cdo1-sandbox-tfstate-474013238625"
    key            = "sandbox/networking/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf3-cdo1-sandbox-tfstate-lock"
    encrypt        = true
  }
}
