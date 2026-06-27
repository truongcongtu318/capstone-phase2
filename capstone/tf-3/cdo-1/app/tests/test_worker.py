# 🧪 Worker, AI Client, and Circuit Breaker Unit Tests
# TODO: Viết unit tests kiểm thử Worker logic:
# - Test gọi HTTP API AI Engine truyền đúng 4 headers.
# - Test logic Circuit Breaker: mô phỏng 3 lần lỗi liên tục trong 1 giờ -> kiểm tra trạng thái lock trong DB & assert tin nhắn cảnh báo gửi qua SNS.
