#!/usr/bin/env bash
set -e

# Default ECR registry to mirror images to
ECR_REGISTRY=${ECR_REGISTRY:-"544011261607.dkr.ecr.us-east-1.amazonaws.com"}

# Ensure aws cli is authenticated or docker login is performed before running this script
echo "Logging into ECR..."
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$ECR_REGISTRY"

LIST_FILE="mirror-list.txt"
if [ ! -f "$LIST_FILE" ]; then
    echo "Error: $LIST_FILE not found in the current directory."
    exit 1
fi

echo "Starting image mirroring to $ECR_REGISTRY..."

while read -r source_image dest_image; do
    # Skip empty lines and comments
    if [[ -z "$source_image" || "$source_image" == \#* ]]; then
        continue
    fi

    echo "Mirroring: $source_image -> $ECR_REGISTRY/$dest_image"
    
    echo "  1. Pulling $source_image..."
    docker pull "$source_image"
    
    echo "  2. Ensuring ECR repository exists..."
    repo_name="$(echo "$dest_image" | cut -d: -f1)"
    aws ecr describe-repositories --repository-name "$repo_name" --region us-east-1 >/dev/null 2>&1 || \
    aws ecr create-repository \
      --repository-name "$repo_name" \
      --region us-east-1 \
      --image-scanning-configuration scanOnPush=true \
      --encryption-configuration encryptionType=AES256

    echo "  3. Tagging..."
    docker tag "$source_image" "$ECR_REGISTRY/$dest_image"
    
    echo "  4. Pushing..."
    docker push "$ECR_REGISTRY/$dest_image"
    
    echo "  Done mirroring $source_image"
    echo "-----------------------------------"
done < "$LIST_FILE"

echo "Mirroring complete."
