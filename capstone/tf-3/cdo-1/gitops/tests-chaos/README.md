# 💥 Hướng dẫn chạy Chaos Testing & Validation (Member 9)

Thư mục này chứa các kịch bản kiểm thử độ bền bỉ (Chaos Engineering) để xác thực SLO của hệ thống tự chữa lành CDO-01.

## 🏃 Quy trình chạy thực tế (GameDay execution)
1. Dựng hạ tầng mock local (LocalStack + Minikube) hoặc truy cập sandbox cluster.
2. Thực thi một trong các file script simulator bên cạnh (`oom-simulator.sh`, `queue-backlog-stress.sh`, `network-blockade.sh`).
3. Theo dõi log của `sqs-worker` và trạng thái DynamoDB Lock Table để xác minh tính đúng đắn.
4. Đối chiếu thời gian xử lý sự cố với SLO đề ra và ghi chép vào `SLO_validation_report.md`.
