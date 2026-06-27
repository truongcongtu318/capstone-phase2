#!/bin/bash
# 💥 Simulator: Giả lập lỗi OOMKilled trên pod tenant
# TODO: Script này thực hiện deploy một pod chạy stress-ng ngốn RAM vượt hạn mức 256Mi trên namespace `tenant-payment`.
# Giám sát Alertmanager bắn alert PodOOMKilled và đo SLO thời gian vá lỗi của hệ thống (< 15s).
