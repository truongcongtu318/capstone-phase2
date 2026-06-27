# 🚀 FastAPI Webhook Receiver Entrypoint
# TODO: Khởi tạo FastAPI app lắng nghe trên Port 8443.
# Định nghĩa POST route `/alerts` nhận Alertmanager JSON payload.
# Thực hiện gọi client_ddb để tạo idempotency lock, sau đó push message vào SQS Queue.
