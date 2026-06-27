#!/bin/bash
# 💥 Simulator: Giả lập lỗi mất kết nối mạng (Network Blockade)
# TODO: Block cổng 8080 của AI Engine sử dụng NetworkPolicy tạm thời.
# Mở luồng lỗi liên tiếp 3 lần để kiểm tra Circuit Breaker chuyển sang trạng thái OPEN và gửi SNS alarm tới Slack.
