#!/bin/bash
# ==============================================================================
# 🌀 SCRIPT MIRROR DOCKER IMAGES CHO HỆ THỐNG CDO-01 NAT-LESS VPC
# ==============================================================================
# Người thực thi: Member 8 & 9 (Sub-team 3) và Member 3 (Sub-team 1)
# Nơi chạy: Chạy trên máy cá nhân có Internet và cấu hình AWS CLI có quyền đẩy ECR
# ==============================================================================
set -euo pipefail

AWS_ACCOUNT="544011261607"
AWS_REGION="${AWS_REGION:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIRROR_LIST="${MIRROR_LIST:-${SCRIPT_DIR}/mirror-list.txt}"
TARGET_REGISTRY="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "🔐 Đăng nhập AWS ECR Private..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$TARGET_REGISTRY"

if [[ ! -f "$MIRROR_LIST" ]]; then
  echo "Error: mirror list not found: $MIRROR_LIST" >&2
  exit 1
fi

echo "📄 Mirror list: $MIRROR_LIST"

# Định dạng mỗi dòng: <public_source_image> <target_path_with_tag>
while read -r src dest_path extra; do
  [[ -z "${src:-}" || "$src" =~ ^# ]] && continue

  if [[ -z "${dest_path:-}" || -n "${extra:-}" ]]; then
    echo "Error: invalid mirror-list line. Expected: <source> <dest>, got: $src ${dest_path:-} ${extra:-}" >&2
    exit 1
  fi

  repo_name=$(echo "$dest_path" | cut -d':' -f1)
  target_img="${TARGET_REGISTRY}/${dest_path}"

  echo "========================================================"
  echo "Pulling: $src"
  docker pull "$src"

  echo "Checking/Creating ECR Repository: $repo_name"
  aws ecr describe-repositories --repository-name "$repo_name" --region "$AWS_REGION" >/dev/null 2>&1 || \
    aws ecr create-repository \
      --repository-name "$repo_name" \
      --region "$AWS_REGION" \
      --image-scanning-configuration scanOnPush=true \
      --encryption-configuration encryptionType=AES256

  echo "Tagging: $target_img"
  docker tag "$src" "$target_img"

  echo "Pushing: $target_img"
  docker push "$target_img"
  echo "✅ Hoàn thành sync: $repo_name"
done < "$MIRROR_LIST"

echo "🎉 [SUCCESS] Đã tải tay và mirror hoàn tất toàn bộ images lên ECR Private!"
