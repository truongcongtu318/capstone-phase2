# ⚙️ Configuration management for Webhook Receiver
# Đọc và xác thực biến môi trường sử dụng Pydantic Settings.
# TODO: Hỗ trợ DYNAMODB_ENDPOINT_URL cho local development, fallback về native AWS client trên EKS.
from pydantic_settings import BaseSettings
from typing import Optional

class Settings(BaseSettings):
    # DynamoDB
    dynamodb_endpoint_url: Optional[str] = None
    dynamodb_table_name: str = "tf-3-aiops-idempotency-lock"

    # SQS
    sqs_endpoint_url: Optional[str] = None
    sqs_queue_url: str

    # App
    port: int = 8443
    aws_region: str = "us-east-1"

settings = Settings()