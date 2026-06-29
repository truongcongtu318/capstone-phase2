# 🧪 Pytest Suite Configuration
import os
import sys

# Thiết lập các biến môi trường mặc định cho tests (giá trị local/mock)
os.environ.setdefault("SQS_QUEUE_URL", "http://localhost:4566/000000000000/alert-queue")
os.environ.setdefault("SNS_TOPIC_ARN", "arn:aws:sns:us-east-1:000000000000:tf3-cdo1-sandbox-alerts-escalation")
os.environ.setdefault("AI_ENGINE_URL", "http://localhost:8080")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "test")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "test")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

# Thêm webhook-receiver và sqs-worker vào sys.path
app_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(app_dir, 'webhook-receiver'))
sys.path.insert(0, os.path.join(app_dir, 'sqs-worker'))