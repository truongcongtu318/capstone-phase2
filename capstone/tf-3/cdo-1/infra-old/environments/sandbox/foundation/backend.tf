terraform {
  backend "s3" {
    bucket         = "tf3-cdo1-sandbox-tfstate-783459135560"
    key            = "sandbox/foundation/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf3-cdo1-sandbox-tfstate-lock"
    encrypt        = true
    kms_key_id     = "arn:aws:kms:us-east-1:783459135560:key/39943a9a-59dd-437a-9785-8fca7511c2ce"
  }
}
