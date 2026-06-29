#!/bin/bash
set -e

export AWS_PROFILE=tutruong
export REGISTRY="474013238625.dkr.ecr.us-east-1.amazonaws.com"

# 1. Login to ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $REGISTRY

# 2. Create repositories if not exist
for repo in argoproj/argocd dexidp/dex redis; do
  aws ecr describe-repositories --repository-names $repo --region us-east-1 || \
  aws ecr create-repository --repository-name $repo --region us-east-1
done

# 3. Pull images
docker pull quay.io/argoproj/argocd:v3.4.4
docker pull ghcr.io/dexidp/dex:v2.45.0
docker pull public.ecr.aws/docker/library/redis:8.2.3-alpine

# 4. Tag and push images
docker tag quay.io/argoproj/argocd:v3.4.4 $REGISTRY/argoproj/argocd:v3.4.4
docker push $REGISTRY/argoproj/argocd:v3.4.4

docker tag ghcr.io/dexidp/dex:v2.45.0 $REGISTRY/dexidp/dex:v2.45.0
docker push $REGISTRY/dexidp/dex:v2.45.0

docker tag public.ecr.aws/docker/library/redis:8.2.3-alpine $REGISTRY/redis:8.2.3-alpine
docker push $REGISTRY/redis:8.2.3-alpine

# 5. Patch install.yaml
curl -sL https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml > install.yaml
sed -i "s|quay.io/argoproj/argocd:v3.4.4|$REGISTRY/argoproj/argocd:v3.4.4|g" install.yaml
sed -i "s|ghcr.io/dexidp/dex:v2.45.0|$REGISTRY/dexidp/dex:v2.45.0|g" install.yaml
sed -i "s|public.ecr.aws/docker/library/redis:8.2.3-alpine|$REGISTRY/redis:8.2.3-alpine|g" install.yaml

# 6. Apply to cluster
kubectl apply --server-side --force-conflicts -n argocd -f install.yaml
