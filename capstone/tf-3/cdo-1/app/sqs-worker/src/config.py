# ⚙️ Configuration management for SQS Worker
# Đọc và xác thực biến môi trường sử dụng Pydantic Settings.
# Hỗ trợ DYNAMODB_ENDPOINT_URL và các endpoints cho local development, fallback về native AWS client trên EKS.

from dotenv import load_dotenv

# Tải trước các biến môi trường từ .env.local vào os.environ để các module khác (ví dụ: audit_logger) có thể đọc qua os.getenv
load_dotenv(".env.local")
load_dotenv(".env")

from pydantic_settings import BaseSettings, SettingsConfigDict
from typing import Optional

class Settings(BaseSettings):
    # Cấu hình tự động đọc từ tệp tin env
    model_config = SettingsConfigDict(
        env_file=(".env", ".env.local"), 
        env_file_encoding="utf-8", 
        extra="ignore"
    )

    # AWS Services Endpoints (for local/mock development)
    dynamodb_endpoint_url: Optional[str] = None
    dynamodb_table_name: str = "tf-3-aiops-idempotency-lock"

    sqs_endpoint_url: Optional[str] = None
    # sqs_queue_url local: "http://localhost:4566/000000000000/alert-queue"
    sqs_queue_url: str

    sns_endpoint_url: Optional[str] = None
    # sns_topic_arn local: "arn:aws:sns:us-east-1:000000000000:tf3-cdo1-sandbox-alerts-escalation"
    sns_topic_arn: str

    firehose_endpoint_url: Optional[str] = None
    firehose_stream_name: str = "tf3-cdo1-sandbox-audit-stream"  # tên stream thật trên AWS

    # AI Engine Endpoint
    # ai_engine_url local: "http://localhost:8080"
    ai_engine_url: str

    aws_region: str = "us-east-1"
    dry_run: bool = False

settings = Settings()
