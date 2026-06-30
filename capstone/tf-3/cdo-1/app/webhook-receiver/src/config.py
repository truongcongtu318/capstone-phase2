# ⚙️ Configuration management for Webhook Receiver
# Đọc và xác thực biến môi trường sử dụng Pydantic Settings.
# Hỗ trợ DYNAMODB_ENDPOINT_URL và SQS_ENDPOINT_URL cho local development,
# fallback về native AWS client (IRSA) trên EKS khi không set *_ENDPOINT_URL.
from pydantic_settings import BaseSettings, SettingsConfigDict
from typing import Optional

class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=(".env", ".env.local"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # DynamoDB
    dynamodb_endpoint_url: Optional[str] = None
    dynamodb_table_name: str = "tf-3-aiops-app-idempotency-lock"

    # SQS
    sqs_endpoint_url: Optional[str] = None
    # sqs_queue_url local: "http://localhost:4566/000000000000/alert-queue"
    sqs_queue_url: str

    # App
    port: int = 8443
    aws_region: str = "us-east-1"

settings = Settings()