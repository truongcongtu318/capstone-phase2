# ⚡ Circuit Breaker & Alerts Escalation
# TODO: Quản lý trạng thái đếm lỗi của từng microservice bằng DynamoDB.
# Nếu xảy ra liên tiếp 3 lỗi tự vá thất bại trong vòng 1 giờ cho cùng 1 service:
# Kích hoạt ngắt mạch (Circuit Open), khóa tự động vá lỗi, gửi thông báo khẩn cấp qua AWS SNS Topic `tf3-cdo1-sandbox-alerts-escalation`.
