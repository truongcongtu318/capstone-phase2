terraform {
  backend "s3" {
    # TODO(sau khi INFRA-1 apply xong): điền giá trị thật từ bootstrap output.
    # bucket         = "<state_bucket_name>"
    # key            = "sandbox/foundation/terraform.tfstate"
    # region         = "us-east-1"
    # dynamodb_table = "<state_lock_table_name>"
    # encrypt        = true
  }
}
