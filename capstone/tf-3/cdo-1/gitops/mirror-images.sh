#!/bin/bash
# ==============================================================================
# 🌀 SCRIPT MIRROR DOCKER IMAGES CHO HỆ THỐNG CDO-01 NAT-LESS VPC
# ==============================================================================
# Người thực thi: Member 8 & 9 (Sub-team 3) và Member 3 (Sub-team 1)
# Nơi chạy: Chạy trên máy cá nhân có Internet và cấu hình AWS CLI có quyền đẩy ECR
# ==============================================================================
set -e

AWS_ACCOUNT="474013238625"
AWS_REGION="us-east-1"
TARGET_REGISTRY="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "🔐 Đăng nhập AWS ECR Private..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $TARGET_REGISTRY

# Khai báo mảng ánh xạ (Public Source Image -> ECR Private Path)
declare -A images=(
  # A. AWS Load Balancer Controller (1 Image)
  ["602401143452.dkr.ecr.us-west-2.amazonaws.com/amazon/aws-load-balancer-controller:v2.8.1"]="amazon/aws-load-balancer-controller:v2.8.1"
  
  # B. Karpenter Node Provisioner (1 Image)
  ["public.ecr.aws/karpenter/controller:0.37.0"]="karpenter/controller:0.37.0"
  
  # C. Kyverno Admission Controller (5 Images)
  ["ghcr.io/kyverno/kyverno:v1.12.5"]="kyverno/kyverno:v1.12.5"
  ["ghcr.io/kyverno/kyvernopre:v1.12.5"]="kyverno/kyvernopre:v1.12.5"
  ["ghcr.io/kyverno/background-controller:v1.12.5"]="kyverno/background-controller:v1.12.5"
  ["ghcr.io/kyverno/cleanup-controller:v1.12.5"]="kyverno/cleanup-controller:v1.12.5"
  ["ghcr.io/kyverno/reports-controller:v1.12.5"]="kyverno/reports-controller:v1.12.5"
  
  # D. Kube-Prometheus-Stack (9 Images)
  ["quay.io/prometheus-operator/prometheus-operator:v0.74.0"]="prometheus-operator/prometheus-operator:v0.74.0"
  ["quay.io/prometheus-operator/prometheus-config-reloader:v0.74.0"]="prometheus-operator/prometheus-config-reloader:v0.74.0"
  ["quay.io/prometheus/prometheus:v2.52.0"]="prometheus/prometheus:v2.52.0"
  ["quay.io/prometheus/alertmanager:v0.27.0"]="prometheus/alertmanager:v0.27.0"
  ["docker.io/grafana/grafana:10.4.3"]="grafana/grafana:10.4.3"
  ["registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.12.0"]="kube-state-metrics/kube-state-metrics:v2.12.0"
  ["quay.io/prometheus/node-exporter:v1.8.1"]="prometheus/node-exporter:v1.8.1"
  ["quay.io/kiwigrid/k8s-sidecar:1.27.4"]="kiwigrid/k8s-sidecar:1.27.4"
  ["registry.k8s.io/ingress-nginx/kube-webhook-certgen:v20221220-controller-v1.5.1-58-g787ea74b6"]="ingress-nginx/kube-webhook-certgen:v20221220-controller-v1.5.1-58-g787ea74b6"
  
  # E. Chaos Testing & Debugging (3 Images)
  ["docker.io/alexeiled/stress-ng:latest"]="alexeiled/stress-ng:latest"
  ["docker.io/library/alpine:3.19"]="alpine:3.19"
  ["docker.io/library/busybox:1.36"]="busybox:1.36"
)

# Tiến hành loop để pull, tạo ECR repository và push
for src in "${!images[@]}"; do
  dest_path="${images[$src]}"
  repo_name=$(echo "$dest_path" | cut -d':' -f1)
  target_img="${TARGET_REGISTRY}/${dest_path}"
  
  echo "========================================================"
  echo "Pulling: $src"
  docker pull "$src"
  
  echo "Checking/Creating ECR Repository: $repo_name"
  aws ecr describe-repositories --repository-name "$repo_name" --region $AWS_REGION >/dev/null 2>&1 || \
    aws ecr create-repository \
      --repository-name "$repo_name" \
      --region $AWS_REGION \
      --image-scanning-configuration scanOnPush=true \
      --encryption-configuration encryptionType=AES256
      
  echo "Tagging: $target_img"
  docker tag "$src" "$target_img"
  
  echo "Pushing: $target_img"
  docker push "$target_img"
  echo "✅ Hoàn thành sync: $repo_name"
done

echo "🎉 [SUCCESS] Đã tải tay và mirror hoàn tất toàn bộ 19/19 images lên ECR Private!"
