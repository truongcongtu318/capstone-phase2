#!/bin/bash
# ============================================================
# POC: GitOps Hybrid Self-Heal - Setup Script
# TF3 - CDO-1 | Capstone Phase 2
# ============================================================
set -e

echo "=========================================="
echo "  Kiểm tra môi trường..."
echo "=========================================="

# Kiểm tra Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Docker chưa được cài đặt. Vui lòng cài Docker Desktop trước."
    exit 1
fi
echo "✅ Docker đã sẵn sàng"

# Kiểm tra Minikube
if ! command -v minikube &> /dev/null; then
    echo "❌ Minikube chưa được cài đặt."
    echo "   Cài đặt: brew install minikube (Mac) hoặc choco install minikube (Windows)"
    exit 1
fi
echo "✅ Minikube đã sẵn sàng"

# Kiểm tra kubectl
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl chưa được cài đặt."
    exit 1
fi
echo "✅ kubectl đã sẵn sàng"

# Kiểm tra Python3
if ! command -v python3 &> /dev/null; then
    echo "❌ python3 chưa được cài đặt."
    exit 1
fi
echo "✅ Python3 đã sẵn sàng"

echo ""
echo "=========================================="
echo "  Bước 1: Khởi động Minikube..."
echo "=========================================="
minikube status &> /dev/null || minikube start --cpus 4 --memory 4096 --driver=docker
echo "✅ Minikube đã chạy"

echo ""
echo "=========================================="
echo "  Bước 2: Cài đặt ArgoCD..."
echo "=========================================="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Chờ ArgoCD pods ready
echo "⏳ Chờ ArgoCD khởi động (khoảng 2 phút)..."
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=180s
echo "✅ ArgoCD đã sẵn sàng"

# Lấy password admin
echo ""
echo "📝 ArgoCD Admin Password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo ""

echo ""
echo "=========================================="
echo "  Bước 3: Cài đặt Python packages..."
echo "=========================================="
pip3 install kubernetes pyyaml --quiet
echo "✅ Python packages đã sẵn sàng"

echo ""
echo "=========================================="
echo "  Bước 4: Deploy app test..."
echo "=========================================="
kubectl apply -f poc/deployment.yaml
echo "✅ App test đã deploy"

echo ""
echo "=========================================="
echo "  Bước 5: Chạy port-forward cho ArgoCD..."
echo "  Mở terminal mới và chạy:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo ""
echo "  Sau đó đăng nhập ArgoCD CLI:"
echo "  argocd login localhost:8080 --username admin --password <pass_trên> --insecure"
echo ""
echo "  Rồi tạo Application từ repo gitops-test:"
echo "  argocd app create my-app --repo https://github.com/<your-github>/gitops-test.git --path apps/my-app --dest-server https://kubernetes.default.svc --dest-namespace default --sync-policy automated --self-heal"
echo ""
echo "  Cuối cùng chạy test:"
echo "  python3 poc/self_heal.py"
echo "=========================================="
