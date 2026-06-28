# 🧪 Pytest Suite Configuration
# TODO: Cấu hình pytest fixtures để dựng mock resources cho kiểm thử:
# Dựng mock SQS Queue, mock DynamoDB Lock Table, mock SNS Topic sử dụng LocalStack / Moto.
import os
import sys

os.environ.setdefault("SQS_QUEUE_URL", "http://localhost:4566/000000000000/alert-queue")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "test")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "test")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'webhook-receiver'))